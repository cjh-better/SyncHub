import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/hub_api.dart';
import '../core/manifest.dart';
import 'theme.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

enum _CloudLibraryView { all, pinned, starred, expiring }

class _PendingDeleteBatch {
  final String id;
  final List<int> itemIds;
  Timer? timer;

  _PendingDeleteBatch({required this.id, required this.itemIds});
}

class _PendingUnstarOp {
  final int itemId;
  final HubItem previous;
  Timer? timer;

  _PendingUnstarOp({required this.itemId, required this.previous});
}

class _UploadOptions {
  final bool starred;
  final bool pinned;
  final String category;

  const _UploadOptions({
    required this.starred,
    required this.pinned,
    required this.category,
  });
}

/// Native SyncHub Cloud Center (`S2`) — library views, 8 categories with live
/// counts, disk storage meter, drag-and-drop / pre-upload options, quick-look
/// preview, multi-select batch actions, 5s Undo Delete, and 6s Undo on expired
/// unstar.
class CloudPage extends StatefulWidget {
  final HubApi hub;
  final String deviceName;
  final String deviceId;
  final String recvDir;
  final void Function(String savedPath)? onDownloaded;
  final Future<void> Function(String text)? onCopyText;

  const CloudPage({
    super.key,
    required this.hub,
    required this.deviceName,
    required this.deviceId,
    required this.recvDir,
    this.onDownloaded,
    this.onCopyText,
  });

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  final TextEditingController _searchCtl = TextEditingController();
  Timer? _searchDebounce;

  _CloudLibraryView _libraryView = _CloudLibraryView.all;
  String _selectedCategory = ''; // '' means no category filter
  bool _gridMode = false;
  bool _batchMode = false;
  bool _dragHover = false;

  bool _loading = true;
  String? _error;
  int _retentionHours = 72;
  List<HubItem> _items = <HubItem>[];
  Map<String, int> _counts = <String, int>{};
  HubStorageInfo? _storage;

  final Set<int> _selectedIds = <int>{};
  final Set<int> _busyDownloadIds = <int>{};

  // Active upload state
  bool _uploading = false;
  String _uploadingLabel = '';
  double? _uploadFraction;

  // Client-side 5-second Undo Delete & 6-second Undo Unstar
  final Map<String, _PendingDeleteBatch> _pendingDeletes =
      <String, _PendingDeleteBatch>{};
  final Map<int, _PendingUnstarOp> _pendingUnstars = <int, _PendingUnstarOp>{};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant CloudPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hub.base != widget.hub.base ||
        oldWidget.hub.token != widget.hub.token) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    _flushPendingOperationsOnDispose();
    super.dispose();
  }

  void _flushPendingOperationsOnDispose() {
    final deletes = _pendingDeletes.values.toList();
    _pendingDeletes.clear();
    for (final batch in deletes) {
      batch.timer?.cancel();
      final ids = batch.itemIds;
      if (ids.length == 1) {
        unawaited(widget.hub.deleteItem(ids.first).catchError((_) {}));
      } else if (ids.length > 1) {
        unawaited(widget.hub.batchDelete(ids).catchError((_) => 0));
      }
    }

    final unstars = _pendingUnstars.values.toList();
    _pendingUnstars.clear();
    for (final op in unstars) {
      op.timer?.cancel();
      unawaited(
        widget.hub
            .updateItem(op.itemId, starred: false)
            .then<void>((_) {})
            .catchError((_) {}),
      );
    }
  }

  Set<int> get _hiddenDeleteIds {
    final out = <int>{};
    for (final b in _pendingDeletes.values) {
      out.addAll(b.itemIds);
    }
    return out;
  }

  List<HubItem> get _visibleItems {
    final hidden = _hiddenDeleteIds;
    return _items.where((item) {
      if (hidden.contains(item.id)) return false;
      if (_selectedCategory.isNotEmpty && item.category != _selectedCategory) {
        return false;
      }
      switch (_libraryView) {
        case _CloudLibraryView.all:
          return true;
        case _CloudLibraryView.pinned:
          return item.pinned;
        case _CloudLibraryView.starred:
          return item.starred;
        case _CloudLibraryView.expiring:
          return !item.isPermanent &&
              item.remainingSeconds != null &&
              item.remainingSeconds! < 12 * 3600;
      }
    }).toList();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final listFuture = widget.hub.listItems(
        category: _selectedCategory,
        q: _searchCtl.text.trim(),
        starred: _libraryView == _CloudLibraryView.starred,
        pinned: _libraryView == _CloudLibraryView.pinned,
        limit: 300,
      );
      final storageFuture = widget.hub
          .storageInfo()
          .then<HubStorageInfo?>((v) => v)
          .catchError((_) => null);

      final res = await listFuture;
      final storage = await storageFuture;
      if (!mounted) return;
      setState(() {
        _retentionHours = res.retentionHours;
        _items = res.items;
        if (res.counts.isNotEmpty) {
          _counts = res.counts;
        }
        if (storage != null) {
          _storage = storage;
        }
        _selectedIds.removeWhere((id) => !_items.any((it) => it.id == id));
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) unawaited(_refresh());
    });
    setState(() {});
  }

  void _selectLibraryView(_CloudLibraryView view) {
    setState(() {
      _libraryView = view;
      _selectedCategory = '';
      _selectedIds.clear();
    });
    unawaited(_refresh());
  }

  void _selectCategory(String category) {
    setState(() {
      _selectedCategory = category;
      _libraryView = _CloudLibraryView.all;
      _selectedIds.clear();
    });
    unawaited(_refresh());
  }

  void _showToast(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          backgroundColor: isError ? kRed : null,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _replaceLocalItem(HubItem updated) {
    final idx = _items.indexWhere((it) => it.id == updated.id);
    if (idx >= 0) {
      _items[idx] = updated;
    }
  }

  // ------------------------------------------------------------------ Actions

  Future<void> _copyText(String text) async {
    if (widget.onCopyText != null) {
      await widget.onCopyText!(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _showToast('已复制到剪贴板');
  }

  Future<void> _togglePin(HubItem item) async {
    final nextPinned = !item.pinned;
    final prev = item;
    setState(() {
      _replaceLocalItem(item.copyWith(pinned: nextPinned));
    });
    try {
      final updated = await widget.hub.updateItem(item.id, pinned: nextPinned);
      if (!mounted) return;
      setState(() => _replaceLocalItem(updated));
    } catch (e) {
      if (!mounted) return;
      setState(() => _replaceLocalItem(prev));
      _showToast('操作失败：$e', isError: true);
    }
  }

  bool _wouldExpireImmediatelyOnUnstar(HubItem item) {
    if (item.pinned) return false;
    if (item.remainingSeconds != null && item.remainingSeconds! <= 0) {
      return true;
    }
    final created = item.createdAt;
    if (created != null) {
      final ageSecs = DateTime.now().toUtc().difference(created).inSeconds;
      if (ageSecs >= _retentionHours * 3600) return true;
    }
    return false;
  }

  Future<void> _toggleStar(HubItem item) async {
    // Cancel any pending delayed unstar for this item first.
    final existingPending = _pendingUnstars.remove(item.id);
    if (existingPending != null) {
      existingPending.timer?.cancel();
      setState(() => _replaceLocalItem(existingPending.previous));
      return;
    }

    if (item.starred && _wouldExpireImmediatelyOnUnstar(item)) {
      // 6-second client-side Undo before committing unstar on an expired item!
      final op = _PendingUnstarOp(itemId: item.id, previous: item);
      _pendingUnstars[item.id] = op;
      setState(() {
        _replaceLocalItem(
          item.copyWith(
            starred: false,
            isPermanent: false,
            remainingSeconds: 0,
          ),
        );
      });

      op.timer = Timer(const Duration(seconds: 6), () async {
        final removed = _pendingUnstars.remove(item.id);
        if (removed == null) return;
        try {
          final updated = await widget.hub.updateItem(item.id, starred: false);
          if (!mounted) return;
          setState(() => _replaceLocalItem(updated));
          unawaited(_refresh(silent: true));
        } catch (e) {
          if (!mounted) return;
          setState(() => _replaceLocalItem(item));
          _showToast('取消收藏失败：$e', isError: true);
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            content: Text('已取消收藏「${item.displayTitle}」（已满 $_retentionHours 小时，即将被清理）'),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () {
                final pending = _pendingUnstars.remove(item.id);
                if (pending != null) {
                  pending.timer?.cancel();
                  if (mounted) {
                    setState(() => _replaceLocalItem(pending.previous));
                  }
                }
              },
            ),
          ),
        );
      return;
    }

    final nextStarred = !item.starred;
    final prev = item;
    setState(() {
      _replaceLocalItem(item.copyWith(starred: nextStarred));
    });
    try {
      final updated = await widget.hub.updateItem(item.id, starred: nextStarred);
      if (!mounted) return;
      setState(() => _replaceLocalItem(updated));
      unawaited(_refresh(silent: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _replaceLocalItem(prev));
      _showToast('操作失败：$e', isError: true);
    }
  }

  Future<void> _changeCategory(HubItem item, String newCategory) async {
    if (newCategory == item.category) return;
    final prev = item;
    setState(() => _replaceLocalItem(item.copyWith(category: newCategory)));
    try {
      final updated =
          await widget.hub.updateItem(item.id, category: newCategory);
      if (!mounted) return;
      setState(() => _replaceLocalItem(updated));
      unawaited(_refresh(silent: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _replaceLocalItem(prev));
      _showToast('修改分类失败：$e', isError: true);
    }
  }

  /// 5-second client-side Undo Delete: hides items immediately, shows `SnackBar`
  /// `"已删除 N 项"` with `撤销` action, and commits after 5 seconds unless undone.
  void _stageDelete(List<HubItem> targets) {
    final ids = targets.map((e) => e.id).toSet().toList();
    if (ids.isEmpty) return;

    final batchKey =
        '${DateTime.now().microsecondsSinceEpoch}_${ids.first}_${ids.length}';
    final batch = _PendingDeleteBatch(id: batchKey, itemIds: ids);
    setState(() {
      _pendingDeletes[batchKey] = batch;
      _selectedIds.removeAll(ids);
      if (_selectedIds.isEmpty && _batchMode) {
        _batchMode = false;
      }
    });

    batch.timer = Timer(const Duration(seconds: 5), () async {
      final pending = _pendingDeletes.remove(batchKey);
      if (pending == null) return;
      try {
        if (ids.length == 1) {
          await widget.hub.deleteItem(ids.first);
        } else {
          await widget.hub.batchDelete(ids);
        }
        if (!mounted) return;
        setState(() {
          _items.removeWhere((it) => ids.contains(it.id));
        });
        unawaited(_refresh(silent: true));
      } catch (e) {
        if (!mounted) return;
        setState(() {});
        _showToast('删除失败：$e', isError: true);
      }
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          content: Text('已删除 ${ids.length} 项'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              final pending = _pendingDeletes.remove(batchKey);
              if (pending != null) {
                pending.timer?.cancel();
                if (mounted) setState(() {});
              }
            },
          ),
        ),
      );
  }

  Future<void> _batchSetStarred(bool starred) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    setState(() {
      for (var i = 0; i < _items.length; i++) {
        if (_selectedIds.contains(_items[i].id)) {
          _items[i] = _items[i].copyWith(starred: starred);
        }
      }
    });
    var okCount = 0;
    for (final id in ids) {
      try {
        final updated = await widget.hub.updateItem(id, starred: starred);
        if (mounted) _replaceLocalItem(updated);
        okCount++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _batchMode = false;
    });
    _showToast(starred ? '已批量收藏 $okCount 项' : '已取消收藏 $okCount 项');
    unawaited(_refresh(silent: true));
  }

  Future<void> _downloadItem(HubItem item) async {
    if (_busyDownloadIds.contains(item.id)) return;
    setState(() => _busyDownloadIds.add(item.id));
    try {
      final savedPath = await widget.hub.downloadToDir(item, widget.recvDir);
      widget.onDownloaded?.call(savedPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('已保存到 $savedPath'),
            action: _isDesktop
                ? SnackBarAction(
                    label: '显示',
                    onPressed: () => _revealFile(savedPath),
                  )
                : null,
          ),
        );
    } catch (e) {
      _showToast('下载失败：$e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busyDownloadIds.remove(item.id));
      }
    }
  }

  static void _revealFile(String path) {
    if (Platform.isWindows) {
      unawaited(Process.run('explorer', <String>['/select,', path]));
    } else if (Platform.isMacOS) {
      unawaited(Process.run('open', <String>['-R', path]));
    }
  }

  // --------------------------------------------------- Upload / Text / Cleanup

  Future<void> _openPostTextDialog() async {
    final textCtl = TextEditingController();
    var starred = false;
    var pinned = false;
    var syncClip = true;
    var category = _selectedCategory.isNotEmpty ? _selectedCategory : '文本';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('发送文字到云端'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextField(
                    controller: textCtl,
                    minLines: 5,
                    maxLines: 10,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '输入或粘贴要保存到云端的文字、链接或代码片段…',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: const InputDecoration(labelText: '分类'),
                    items: <DropdownMenuItem<String>>[
                      for (final c in kHubCategories)
                        DropdownMenuItem<String>(value: c, child: Text(c)),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => category = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('收藏（永久保存）'),
                    subtitle: Text('免于 $_retentionHours 小时自动清理'),
                    value: starred,
                    onChanged: (v) => setDialogState(() => starred = v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('置顶显示'),
                    value: pinned,
                    onChanged: (v) => setDialogState(() => pinned = v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('同时写入云剪贴板'),
                    value: syncClip,
                    onChanged: (v) => setDialogState(() => syncClip = v),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('发送'),
            ),
          ],
        ),
      ),
    );

    final content = textCtl.text;
    textCtl.dispose();
    if (ok != true) return;
    if (content.trim().isEmpty) {
      _showToast('文字内容不能为空', isError: true);
      return;
    }

    try {
      await widget.hub.postText(
        content,
        from: widget.deviceName,
        starred: starred,
        pinned: pinned,
        category: category,
        syncClipboard: syncClip,
      );
      _showToast('文字已保存到云端');
      await _refresh(silent: true);
    } catch (e) {
      _showToast('发送失败：$e', isError: true);
    }
  }

  Future<void> _pickAndUploadFiles() async {
    final picked = await FilePicker.pickFiles(dialogTitle: '选择要上传到云端的文件');
    final paths = picked
        .map((f) => f.path)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    if (paths.isEmpty || !mounted) return;

    final opts = await _promptUploadOptions(paths);
    if (opts == null || !mounted) return;
    await _uploadFilePaths(
      paths,
      starred: opts.starred,
      pinned: opts.pinned,
      category: opts.category,
    );
  }

  Future<_UploadOptions?> _promptUploadOptions(List<String> paths) async {
    var starred = false;
    var pinned = false;
    var category = _selectedCategory; // '' = auto classify by server

    final previewTitle = paths.length == 1
        ? p.basename(paths.first)
        : '${p.basename(paths.first)} 等 ${paths.length} 个文件';

    return showDialog<_UploadOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('上传文件到云端'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  previewTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                      value: '',
                      child: Text('自动识别分类'),
                    ),
                    for (final c in kHubCategories)
                      DropdownMenuItem<String>(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setDialogState(() => category = v ?? ''),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('收藏永久保存'),
                  subtitle: Text('关闭则默认保留 $_retentionHours 小时后自动清理'),
                  value: starred,
                  onChanged: (v) => setDialogState(() => starred = v),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('置顶显示'),
                  value: pinned,
                  onChanged: (v) => setDialogState(() => pinned = v),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(
                ctx,
                _UploadOptions(
                  starred: starred,
                  pinned: pinned,
                  category: category,
                ),
              ),
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('开始上传'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadFilePaths(
    List<String> rawPaths, {
    bool starred = false,
    bool pinned = false,
    String category = '',
  }) async {
    if (_uploading) {
      _showToast('已有文件正在上传，请稍候');
      return;
    }

    // Collect regular files (expand one level if user dropped a directory).
    final files = <File>[];
    for (final raw in rawPaths) {
      final type = await FileSystemEntity.type(raw);
      if (type == FileSystemEntityType.file) {
        files.add(File(raw));
      } else if (type == FileSystemEntityType.directory) {
        await for (final ent in Directory(raw).list(followLinks: false)) {
          if (ent is File) files.add(ent);
        }
      }
    }

    if (files.isEmpty) {
      _showToast('没有可上传的文件', isError: true);
      return;
    }

    setState(() {
      _uploading = true;
      _uploadingLabel = '准备上传 ${files.length} 个文件…';
      _uploadFraction = 0.0;
    });

    var uploaded = 0;
    try {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final name = p.basename(f.path);
        await widget.hub.uploadFile(
          f,
          filename: name,
          from: widget.deviceName,
          fromId: widget.deviceId,
          starred: starred,
          pinned: pinned,
          category: category,
          onProgress: (sent, total) {
            if (!mounted) return;
            final fileFrac = total > 0 ? sent / total : 0.0;
            setState(() {
              _uploadingLabel =
                  '正在上传 (${i + 1}/${files.length})：$name · ${humanBytes(sent)} / ${humanBytes(total)}';
              _uploadFraction = ((i + fileFrac) / files.length).clamp(0.0, 1.0);
            });
          },
        );
        uploaded++;
      }
      _showToast('已上传 $uploaded 个文件到云端');
      await _refresh(silent: true);
    } catch (e) {
      _showToast('上传失败：$e', isError: true);
      if (uploaded > 0) unawaited(_refresh(silent: true));
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadingLabel = '';
          _uploadFraction = null;
        });
      }
    }
  }

  Future<void> _confirmCleanupUnstarred() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理全部临时项？'),
        content: const Text(
          '将立即从云端删除所有「未收藏」且「未置顶」的临时条目与文件。\n已收藏或已置顶的永久条目不会受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final count = await widget.hub.cleanupUnstarred();
      _showToast('已清理 $count 个临时条目');
      await _refresh();
    } catch (e) {
      _showToast('清理失败：$e', isError: true);
    }
  }

  Future<void> _openPreview(HubItem item) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _HubQuickLookDialog(
        hub: widget.hub,
        item: item,
        onCopy: _copyText,
        onDownload: () => _downloadItem(item),
      ),
    );
  }

  // ----------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 880;
    final visible = _visibleItems;

    final mainColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeaderToolbar(wide: wide),
        if (!wide) _buildCompactFilterBar(),
        if (_batchMode) _buildBatchActionBar(visible),
        if (_uploading) _buildUploadProgressBanner(),
        Expanded(child: _buildContentArea(visible)),
      ],
    );

    final body = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: 220, child: _buildSidebar()),
              const VerticalDivider(width: 0.6),
              Expanded(child: mainColumn),
            ],
          )
        : mainColumn;

    if (!_isDesktop) return body;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragHover = true),
      onDragExited: (_) => setState(() => _dragHover = false),
      onDragDone: (detail) {
        setState(() => _dragHover = false);
        final paths = detail.files
            .map((f) => f.path)
            .where((s) => s.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) {
          unawaited(
            _uploadFilePaths(
              paths,
              starred: _libraryView == _CloudLibraryView.starred,
              pinned: _libraryView == _CloudLibraryView.pinned,
              category: _selectedCategory,
            ),
          );
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          body,
          if (_dragHover)
            IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x14007AFF),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: kAccent, width: 2),
                ),
                child: const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 20,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.cloud_upload_rounded,
                            size: 44,
                            color: kAccent,
                          ),
                          SizedBox(height: 10),
                          Text(
                            '松开即可上传到 SyncHub 云端',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final totalCount = _counts['全部'] ?? _items.length;
    return Container(
      color: kBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 22, 16, 8),
            child: Text(
              '云端收藏',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              children: <Widget>[
                _sidebarSectionLabel('资料库'),
                _sidebarTile(
                  icon: Icons.inbox_outlined,
                  label: '全部',
                  count: totalCount,
                  selected: _selectedCategory.isEmpty &&
                      _libraryView == _CloudLibraryView.all,
                  onTap: () => _selectLibraryView(_CloudLibraryView.all),
                ),
                _sidebarTile(
                  icon: Icons.push_pin_outlined,
                  label: '置顶',
                  selected: _selectedCategory.isEmpty &&
                      _libraryView == _CloudLibraryView.pinned,
                  onTap: () => _selectLibraryView(_CloudLibraryView.pinned),
                ),
                _sidebarTile(
                  icon: Icons.star_outline_rounded,
                  label: '收藏',
                  selected: _selectedCategory.isEmpty &&
                      _libraryView == _CloudLibraryView.starred,
                  onTap: () => _selectLibraryView(_CloudLibraryView.starred),
                ),
                _sidebarTile(
                  icon: Icons.schedule_outlined,
                  label: '即将清理 (<12h)',
                  selected: _selectedCategory.isEmpty &&
                      _libraryView == _CloudLibraryView.expiring,
                  onTap: () => _selectLibraryView(_CloudLibraryView.expiring),
                ),
                const SizedBox(height: 12),
                _sidebarSectionLabel('分类'),
                for (final cat in kHubCategories)
                  _sidebarTile(
                    icon: _categoryIcon(cat),
                    label: cat,
                    count: _counts[cat] ?? 0,
                    selected: _selectedCategory == cat,
                    onTap: () => _selectCategory(cat),
                  ),
              ],
            ),
          ),
          if (_storage != null && _storage!.total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
              child: _buildStorageCard(_storage!),
            ),
        ],
      ),
    );
  }

  Widget _sidebarSectionLabel(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: kText2,
          ),
        ),
      );

  Widget _sidebarTile({
    required IconData icon,
    required String label,
    int? count,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Material(
          color: selected ? const Color(0x1F007AFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? kAccent : kText2,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? kAccent : Colors.black87,
                      ),
                    ),
                  ),
                  if (count != null)
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12,
                        color: selected ? kAccent : kText2,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildStorageCard(HubStorageInfo s) {
    final frac = s.usedFraction;
    final barColor = frac > 0.9 ? kRed : (frac > 0.75 ? kOrange : kAccent);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.storage_rounded, size: 15, color: kText2),
                const SizedBox(width: 6),
                const Text(
                  '云端磁盘空间',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${(frac * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 11, color: kText2),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 5,
                color: barColor,
                backgroundColor: kHair,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '可用 ${humanBytes(s.free)} / 共 ${humanBytes(s.total)}',
              style: const TextStyle(fontSize: 11, color: kText2),
            ),
            if (s.hubBytes != null)
              Text(
                'SyncHub 占用 ${humanBytes(s.hubBytes!)}',
                style: const TextStyle(fontSize: 11, color: kText2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderToolbar({required bool wide}) {
    final searchField = TextField(
      controller: _searchCtl,
      onChanged: _onSearchChanged,
      onSubmitted: (_) => _refresh(),
      decoration: InputDecoration(
        hintText: '搜索文件名、内容或来源设备…',
        prefixIcon: const Icon(Icons.search, size: 18),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: _searchCtl.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 16),
                onPressed: () {
                  _searchCtl.clear();
                  _onSearchChanged('');
                },
              ),
      ),
    );

    if (!wide) {
      final compactBtnPadding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text(
                  '云端收藏',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _batchMode ? '退出批量选择' : '批量管理',
                  icon: Icon(
                    _batchMode ? Icons.checklist_rtl : Icons.checklist_outlined,
                    color: _batchMode ? kAccent : null,
                  ),
                  onPressed: () => setState(() {
                    _batchMode = !_batchMode;
                    if (!_batchMode) _selectedIds.clear();
                  }),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _gridMode ? '切换为列表视图' : '切换为网格视图',
                  icon: Icon(
                    _gridMode ? Icons.view_list_outlined : Icons.grid_view_outlined,
                  ),
                  onPressed: () => setState(() => _gridMode = !_gridMode),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _refresh(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            searchField,
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: compactBtnPadding,
                  ),
                  onPressed: _uploading ? null : _pickAndUploadFiles,
                  icon: const Icon(Icons.upload_file_outlined, size: 17),
                  label: const Text('传文件'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: compactBtnPadding,
                  ),
                  onPressed: _openPostTextDialog,
                  icon: const Icon(Icons.notes_rounded, size: 17),
                  label: const Text('发文字'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: compactBtnPadding,
                  ),
                  onPressed: _confirmCleanupUnstarred,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                  label: const Text('清理临时项'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SizedBox(width: 260, child: searchField),
          FilledButton.icon(
            onPressed: _uploading ? null : _pickAndUploadFiles,
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('传文件'),
          ),
          OutlinedButton.icon(
            onPressed: _openPostTextDialog,
            icon: const Icon(Icons.notes_rounded, size: 18),
            label: const Text('发文字'),
          ),
          OutlinedButton.icon(
            onPressed: _confirmCleanupUnstarred,
            icon: const Icon(Icons.cleaning_services_outlined, size: 17),
            label: const Text('清理临时项…'),
          ),
          IconButton(
            tooltip: _batchMode ? '退出批量选择' : '批量管理',
            icon: Icon(
              _batchMode ? Icons.checklist_rtl : Icons.checklist_outlined,
              color: _batchMode ? kAccent : null,
            ),
            onPressed: () => setState(() {
              _batchMode = !_batchMode;
              if (!_batchMode) _selectedIds.clear();
            }),
          ),
          IconButton(
            tooltip: _gridMode ? '切换为列表视图' : '切换为网格视图',
            icon: Icon(
              _gridMode ? Icons.view_list_outlined : Icons.grid_view_outlined,
            ),
            onPressed: () => setState(() => _gridMode = !_gridMode),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactFilterBar() {
    final s = _storage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            children: <Widget>[
              _filterChip(
                label: '全部 (${_counts['全部'] ?? _items.length})',
                selected: _selectedCategory.isEmpty &&
                    _libraryView == _CloudLibraryView.all,
                onTap: () => _selectLibraryView(_CloudLibraryView.all),
              ),
              _filterChip(
                label: '置顶',
                selected: _selectedCategory.isEmpty &&
                    _libraryView == _CloudLibraryView.pinned,
                onTap: () => _selectLibraryView(_CloudLibraryView.pinned),
              ),
              _filterChip(
                label: '收藏',
                selected: _selectedCategory.isEmpty &&
                    _libraryView == _CloudLibraryView.starred,
                onTap: () => _selectLibraryView(_CloudLibraryView.starred),
              ),
              _filterChip(
                label: '即将清理',
                selected: _selectedCategory.isEmpty &&
                    _libraryView == _CloudLibraryView.expiring,
                onTap: () => _selectLibraryView(_CloudLibraryView.expiring),
              ),
              for (final cat in kHubCategories)
                _filterChip(
                  label: '$cat (${_counts[cat] ?? 0})',
                  selected: _selectedCategory == cat,
                  onTap: () => _selectCategory(cat),
                ),
            ],
          ),
        ),
        if (s != null && s.total > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Row(
              children: <Widget>[
                const Icon(Icons.storage_rounded, size: 14, color: kText2),
                const SizedBox(width: 6),
                Text(
                  '云端可用 ${humanBytes(s.free)} / ${humanBytes(s.total)}',
                  style: const TextStyle(fontSize: 11.5, color: kText2),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12.5)),
          selected: selected,
          onSelected: (_) => onTap(),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _buildBatchActionBar(List<HubItem> visible) {
    final allSelected =
        visible.isNotEmpty && visible.every((it) => _selectedIds.contains(it.id));
    final selectedItems =
        visible.where((it) => _selectedIds.contains(it.id)).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x12007AFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33007AFF)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          TextButton.icon(
            onPressed: visible.isEmpty
                ? null
                : () => setState(() {
                      if (allSelected) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(visible.map((e) => e.id));
                      }
                    }),
            icon: Icon(
              allSelected
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              size: 18,
            ),
            label: Text(allSelected ? '取消全选' : '全选'),
          ),
          Text(
            '已选 ${_selectedIds.length} 项',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          TextButton.icon(
            onPressed: selectedItems.isEmpty
                ? null
                : () => _batchSetStarred(true),
            icon: const Icon(Icons.star_rounded, size: 18, color: kOrange),
            label: const Text('批量收藏'),
          ),
          TextButton.icon(
            onPressed: selectedItems.isEmpty
                ? null
                : () => _batchSetStarred(false),
            icon: const Icon(Icons.star_outline_rounded, size: 18),
            label: const Text('批量取消收藏'),
          ),
          TextButton.icon(
            onPressed: selectedItems.isEmpty
                ? null
                : () => _stageDelete(selectedItems),
            icon: const Icon(Icons.delete_outline, size: 18, color: kRed),
            label: const Text('批量删除', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadProgressBanner() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _uploadingLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _uploadFraction,
                    minHeight: 5,
                    color: kAccent,
                    backgroundColor: kHair,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _buildContentArea(List<HubItem> visible) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off_outlined, size: 44, color: kRed),
              const SizedBox(height: 10),
              Text(
                '无法连接云端收藏中心\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kText2),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_queue_rounded, size: 48, color: kText2),
              const SizedBox(height: 10),
              Text(
                _searchCtl.text.trim().isNotEmpty
                    ? '没有找到匹配的云端条目'
                    : (_isDesktop
                        ? '暂无条目 · 拖入文件或点击上方「传文件 / 发文字」即可上传'
                        : '暂无条目 · 点击上方「传文件 / 发文字」即可上传'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: kText2),
              ),
            ],
          ),
        ),
      );
    }

    if (_gridMode) {
      final compactGrid = MediaQuery.sizeOf(context).width < 600;
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: compactGrid ? 220 : 300,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: compactGrid ? 190 : 205,
        ),
        itemCount: visible.length,
        itemBuilder: (_, i) => _buildGridCard(visible[i]),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _buildListRow(visible[i]),
    );
  }

  Widget _buildListRow(HubItem item) {
    final selected = _selectedIds.contains(item.id);
    final downloading = _busyDownloadIds.contains(item.id);

    void handleTap() {
      if (_batchMode) {
        setState(() {
          if (selected) {
            _selectedIds.remove(item.id);
          } else {
            _selectedIds.add(item.id);
          }
        });
      } else {
        unawaited(_openPreview(item));
      }
    }

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? kAccent : kHair,
          width: selected ? 1.6 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: handleTap,
        onLongPress: () => setState(() {
          _batchMode = true;
          _selectedIds.add(item.id);
        }),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactCard = constraints.maxWidth < 560;
            if (compactCard) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (_batchMode)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: selected,
                                onChanged: (_) => handleTap(),
                              ),
                            ),
                          ),
                        CircleAvatar(
                          radius: 19,
                          backgroundColor: const Color(0x14007AFF),
                          child: Icon(
                            _categoryIcon(item.category),
                            size: 19,
                            color: kAccent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  if (item.pinned)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 2, right: 4),
                                      child: Icon(
                                        Icons.push_pin_rounded,
                                        size: 15,
                                        color: kAccent,
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      item.displayTitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                        height: 1.32,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (item.isText && item.text.contains('\n')) ...<Widget>[
                                const SizedBox(height: 3),
                                Text(
                                  item.text.trim().replaceAll(RegExp(r'\s+'), ' '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kText2,
                                    fontSize: 12.5,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 5),
                              Text(
                                _metaLine(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: kText2, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              _buildCategoryBadge(item.category),
                              _buildRetentionBadge(item),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        _buildCompactMobileActions(
                          item,
                          downloading: downloading,
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (_batchMode)
                    Checkbox(
                      value: selected,
                      onChanged: (_) => handleTap(),
                    ),
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0x14007AFF),
                    child: Icon(
                      _categoryIcon(item.category),
                      size: 20,
                      color: kAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            if (item.pinned)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.push_pin_rounded,
                                  size: 15,
                                  color: kAccent,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                item.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (item.isText && item.text.contains('\n')) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            item.text.trim().replaceAll(RegExp(r'\s+'), ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kText2, fontSize: 12.5),
                          ),
                        ],
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            _buildCategoryBadge(item.category),
                            _buildRetentionBadge(item),
                            Text(
                              _metaLine(item),
                              style: const TextStyle(color: kText2, fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _buildItemActions(item, downloading: downloading),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildGridCard(HubItem item) {
    final selected = _selectedIds.contains(item.id);
    final downloading = _busyDownloadIds.contains(item.id);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? kAccent : kHair,
          width: selected ? 1.6 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (_batchMode) {
            setState(() {
              if (selected) {
                _selectedIds.remove(item.id);
              } else {
                _selectedIds.add(item.id);
              }
            });
          } else {
            unawaited(_openPreview(item));
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0x14007AFF),
                    child: Icon(
                      _categoryIcon(item.category),
                      size: 17,
                      color: kAccent,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      alignment: WrapAlignment.end,
                      children: <Widget>[
                        _buildCategoryBadge(item.category),
                        _buildRetentionBadge(item),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  item.isText && item.text.trim().isNotEmpty
                      ? item.text.trim()
                      : item.displayTitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight:
                        item.isText ? FontWeight.w400 : FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _metaLine(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kText2, fontSize: 11.5),
              ),
              const Divider(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: _buildCompactMobileActions(
                  item,
                  downloading: downloading,
                  showDeleteDirect: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactMobileActions(
    HubItem item, {
    required bool downloading,
    bool showDeleteDirect = true,
  }) {
    final btnStyle = IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(32, 32),
      fixedSize: const Size(32, 32),
      padding: EdgeInsets.zero,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          style: btnStyle,
          tooltip: item.pinned ? '取消置顶' : '置顶',
          icon: Icon(
            item.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 18,
            color: item.pinned ? kAccent : kText2,
          ),
          onPressed: () => _togglePin(item),
        ),
        IconButton(
          style: btnStyle,
          tooltip: item.starred ? '取消收藏' : '收藏（永久保存）',
          icon: Icon(
            item.starred ? Icons.star_rounded : Icons.star_outline_rounded,
            size: 19,
            color: item.starred ? kOrange : kText2,
          ),
          onPressed: () => _toggleStar(item),
        ),
        if (item.isText)
          IconButton(
            style: btnStyle,
            tooltip: '复制文字',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () => _copyText(item.text),
          )
        else if (item.hasFile)
          IconButton(
            style: btnStyle,
            tooltip: '下载到接收文件夹',
            icon: downloading
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 19),
            onPressed: downloading ? null : () => _downloadItem(item),
          ),
        if (showDeleteDirect)
          IconButton(
            style: btnStyle,
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 18, color: kRed),
            onPressed: () => _stageDelete(<HubItem>[item]),
          ),
        SizedBox(
          width: 30,
          height: 32,
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            style: btnStyle,
            tooltip: '更多操作 / 修改分类',
            icon: const Icon(Icons.more_vert, size: 18, color: kText2),
            onSelected: (action) {
              if (action == '__preview') {
                unawaited(_openPreview(item));
              } else if (action == '__delete') {
                _stageDelete(<HubItem>[item]);
              } else if (action.startsWith('cat:')) {
                unawaited(_changeCategory(item, action.substring(4)));
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: '__preview',
                child: Text('快速预览'),
              ),
              const PopupMenuDivider(),
              for (final c in kHubCategories)
                CheckedPopupMenuItem<String>(
                  value: 'cat:$c',
                  checked: item.category == c,
                  child: Text('分类：$c'),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: '__delete',
                child: Text('删除', style: TextStyle(color: kRed)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildItemActions(
    HubItem item, {
    required bool downloading,
    bool compact = false,
  }) {
    final density =
        compact ? VisualDensity.compact : VisualDensity.standard;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          visualDensity: density,
          tooltip: item.pinned ? '取消置顶' : '置顶',
          icon: Icon(
            item.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 19,
            color: item.pinned ? kAccent : kText2,
          ),
          onPressed: () => _togglePin(item),
        ),
        IconButton(
          visualDensity: density,
          tooltip: item.starred ? '取消收藏' : '收藏（永久保存）',
          icon: Icon(
            item.starred ? Icons.star_rounded : Icons.star_outline_rounded,
            size: 20,
            color: item.starred ? kOrange : kText2,
          ),
          onPressed: () => _toggleStar(item),
        ),
        if (item.isText)
          IconButton(
            visualDensity: density,
            tooltip: '复制文字',
            icon: const Icon(Icons.copy_outlined, size: 19),
            onPressed: () => _copyText(item.text),
          )
        else if (item.hasFile)
          IconButton(
            visualDensity: density,
            tooltip: '下载到接收文件夹',
            icon: downloading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 20),
            onPressed: downloading ? null : () => _downloadItem(item),
          ),
        if (!compact)
          IconButton(
            visualDensity: density,
            tooltip: '预览',
            icon: const Icon(Icons.visibility_outlined, size: 19),
            onPressed: () => _openPreview(item),
          ),
        PopupMenuButton<String>(
          tooltip: '更多操作 / 修改分类',
          icon: const Icon(Icons.more_vert, size: 19, color: kText2),
          onSelected: (action) {
            if (action == '__preview') {
              unawaited(_openPreview(item));
            } else if (action == '__delete') {
              _stageDelete(<HubItem>[item]);
            } else if (action.startsWith('cat:')) {
              unawaited(_changeCategory(item, action.substring(4)));
            }
          },
          itemBuilder: (_) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(
              value: '__preview',
              child: Text('快速预览'),
            ),
            const PopupMenuDivider(),
            for (final c in kHubCategories)
              CheckedPopupMenuItem<String>(
                value: 'cat:$c',
                checked: item.category == c,
                child: Text('分类：$c'),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: '__delete',
              child: Text('删除', style: TextStyle(color: kRed)),
            ),
          ],
        ),
        if (!compact)
          IconButton(
            visualDensity: density,
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 19, color: kRed),
            onPressed: () => _stageDelete(<HubItem>[item]),
          ),
      ],
    );
  }

  Widget _buildCategoryBadge(String category) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F2F7),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          category,
          style: const TextStyle(fontSize: 11, color: kText2),
        ),
      );

  Widget _buildRetentionBadge(HubItem item) {
    final (String label, Color fg, Color bg) = _retentionStyle(item);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  static (String, Color, Color) _retentionStyle(HubItem item) {
    if (item.isPermanent || item.starred || item.pinned) {
      return ('永久保存', kGreen, const Color(0x1A34C759));
    }
    final rem = item.remainingSeconds;
    if (rem == null) {
      return ('临时', kText2, const Color(0xFFF2F2F7));
    }
    if (rem <= 0) {
      return ('即将清理', kRed, const Color(0x1AFF3B30));
    }
    final hours = rem ~/ 3600;
    final mins = (rem % 3600) ~/ 60;
    final text = hours > 0 ? '剩余 ${hours}h' : '剩余 ${mins}m';
    if (rem < 2 * 3600) {
      return (text, kRed, const Color(0x1AFF3B30));
    }
    if (rem < 12 * 3600) {
      return (text, kOrange, const Color(0x1AFF9500));
    }
    return (text, kText2, const Color(0xFFF2F2F7));
  }

  static String _metaLine(HubItem item) {
    final parts = <String>[
      if (item.fromDevice.isNotEmpty) item.fromDevice,
      if (item.createTimeLocal.isNotEmpty) item.createTimeLocal,
      if (item.size > 0) humanBytes(item.size),
    ];
    return parts.join(' · ');
  }

  static IconData _categoryIcon(String category) => switch (category) {
        '文档' => Icons.description_outlined,
        '视频' => Icons.movie_outlined,
        '压缩包' => Icons.folder_zip_outlined,
        '图片' => Icons.image_outlined,
        '安装包' => Icons.install_desktop_outlined,
        '音频' => Icons.audiotrack_outlined,
        '文本' => Icons.notes_rounded,
        _ => Icons.insert_drive_file_outlined,
      };
}

// ---------------------------------------------------------------------------
// Quick-Look Preview Dialog (Image / Text / File Metadata)
// ---------------------------------------------------------------------------

class _HubQuickLookDialog extends StatefulWidget {
  final HubApi hub;
  final HubItem item;
  final Future<void> Function(String text) onCopy;
  final VoidCallback onDownload;

  const _HubQuickLookDialog({
    required this.hub,
    required this.item,
    required this.onCopy,
    required this.onDownload,
  });

  @override
  State<_HubQuickLookDialog> createState() => _HubQuickLookDialogState();
}

class _HubQuickLookDialogState extends State<_HubQuickLookDialog> {
  Future<Uint8List>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    if (it.isImage && it.hasFile && it.size <= (20 << 20)) {
      _bytesFuture = widget.hub.downloadBytes(it);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              it.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      content: SizedBox(
        width: 580,
        child: _buildBody(it),
      ),
      actions: <Widget>[
        if (it.isText)
          FilledButton.icon(
            onPressed: () async {
              await widget.onCopy(it.text);
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('复制全部文字'),
          ),
        if (it.hasFile)
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              widget.onDownload();
            },
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text('下载 (${humanBytes(it.size)})'),
          ),
      ],
    );
  }

  Widget _buildBody(HubItem it) {
    if (_bytesFuture != null) {
      return FutureBuilder<Uint8List>(
        future: _bytesFuture,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 260,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snap.hasError || snap.data == null) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '图片加载失败：${snap.error}',
                style: const TextStyle(color: kRed),
              ),
            );
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 440),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: InteractiveViewer(
                child: Image.memory(snap.data!, fit: BoxFit.contain),
              ),
            ),
          );
        },
      );
    }

    if (it.isText) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kHair),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              it.text,
              style: const TextStyle(fontSize: 13.5, height: 1.45),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _metaRow('文件名', it.filename),
        _metaRow('分类', it.category),
        _metaRow('文件大小', humanBytes(it.size)),
        if (it.fromDevice.isNotEmpty) _metaRow('来源设备', it.fromDevice),
        if (it.createTimeLocal.isNotEmpty) _metaRow('上传时间', it.createTimeLocal),
        _metaRow('状态', it.isPermanent ? '永久保存' : '72 小时自动清理'),
        if (it.hash.isNotEmpty) _metaRow('SHA-256', it.hash),
      ],
    );
  }

  Widget _metaRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 76,
              child: Text(
                label,
                style: const TextStyle(color: kText2, fontSize: 12.5),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
}
