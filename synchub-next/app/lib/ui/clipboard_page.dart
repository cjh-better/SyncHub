import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/clipboard_sync.dart';
import '../core/hub_api.dart';
import '../core/manifest.dart';
import 'theme.dart';

enum _ClipHistoryFilter { all, text, image, starred }

class _PendingHistoryDelete {
  final int itemId;
  Timer? timer;

  _PendingHistoryDelete(this.itemId);
}

/// Native SyncClipboard v3.1.1 / v3.3.3 Bidirectional Sync & History Tab (`S1`).
class ClipboardPage extends StatefulWidget {
  final ClipboardSync clipSync;
  final HubApi hub;
  final String deviceName;
  final ValueChanged<bool> onToggleSync;
  final ValueChanged<bool> onToggleImages;
  final ValueChanged<ClipEndpointConfig>? onConfigureEndpoint;

  const ClipboardPage({
    super.key,
    required this.clipSync,
    required this.hub,
    required this.deviceName,
    required this.onToggleSync,
    required this.onToggleImages,
    this.onConfigureEndpoint,
  });

  @override
  State<ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<ClipboardPage> {
  late TextEditingController _customUrlCtl;
  late TextEditingController _customUserCtl;
  late TextEditingController _customPassCtl;
  late bool _editingCustomMode;
  bool _obscurePass = true;
  bool _testingEndpoint = false;
  String? _endpointTestMessage;
  bool? _endpointTestOk;

  _ClipHistoryFilter _historyFilter = _ClipHistoryFilter.all;
  bool _loadingHistory = true;
  String? _historyError;
  List<HubItem> _historyItems = <HubItem>[];

  bool _syncingNow = false;
  bool _pushingCurrent = false;
  final Set<int> _copyingIds = <int>{};
  final Map<int, _PendingHistoryDelete> _pendingDeletes =
      <int, _PendingHistoryDelete>{};

  @override
  void initState() {
    super.initState();
    final ep = widget.clipSync.endpoint;
    _editingCustomMode = ep.useCustomServer;
    _customUrlCtl = TextEditingController(text: ep.customServerUrl);
    _customUserCtl = TextEditingController(text: ep.customUsername);
    _customPassCtl = TextEditingController(text: ep.customPassword);
    widget.clipSync.addListener(_onClipSyncChanged);
    unawaited(_loadHistory());
  }

  @override
  void didUpdateWidget(covariant ClipboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clipSync, widget.clipSync)) {
      oldWidget.clipSync.removeListener(_onClipSyncChanged);
      widget.clipSync.addListener(_onClipSyncChanged);
    }
    if (oldWidget.hub.base != widget.hub.base ||
        oldWidget.hub.token != widget.hub.token) {
      unawaited(_loadHistory());
    }
  }

  @override
  void dispose() {
    widget.clipSync.removeListener(_onClipSyncChanged);
    _customUrlCtl.dispose();
    _customUserCtl.dispose();
    _customPassCtl.dispose();
    final pending = _pendingDeletes.values.toList();
    _pendingDeletes.clear();
    for (final p in pending) {
      p.timer?.cancel();
      unawaited(widget.hub.deleteItem(p.itemId).catchError((_) {}));
    }
    super.dispose();
  }

  DateTime? _lastObservedSyncAt;
  void _onClipSyncChanged() {
    final latest = widget.clipSync.lastSyncedAt;
    if (latest != null && latest != _lastObservedSyncAt) {
      _lastObservedSyncAt = latest;
      unawaited(_loadHistory(silent: true));
    }
  }

  Future<void> _loadHistory({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loadingHistory = true;
        _historyError = null;
      });
    }
    try {
      final res = await widget.hub.listItems(limit: 200);
      final clipRecords =
          res.items.where((it) => it.isText || it.isImage).toList();
      if (!mounted) return;
      setState(() {
        _historyItems = clipRecords;
        _loadingHistory = false;
        _historyError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
        _historyError = '$e';
      });
    }
  }

  List<HubItem> get _filteredHistory {
    return _historyItems.where((it) {
      if (_pendingDeletes.containsKey(it.id)) return false;
      return switch (_historyFilter) {
        _ClipHistoryFilter.all => true,
        _ClipHistoryFilter.text => it.isText,
        _ClipHistoryFilter.image => it.isImage && !it.isText,
        _ClipHistoryFilter.starred => it.starred,
      };
    }).toList();
  }

  void _showToast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: isError ? kRed : null,
          content: Text(msg),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  Future<void> _handleSyncNow() async {
    if (_syncingNow) return;
    setState(() => _syncingNow = true);
    try {
      final change = await widget.clipSync.kick();
      await _loadHistory(silent: true);
      if (change == null) {
        _showToast('已与云剪贴板同步（已是最新内容）');
      } else {
        _showToast('已拉取最新云剪贴板内容');
      }
    } catch (e) {
      _showToast('同步失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _syncingNow = false);
    }
  }

  Future<void> _handlePushCurrent() async {
    if (_pushingCurrent) return;
    setState(() => _pushingCurrent = true);
    try {
      final res = await widget.clipSync.pushCurrentClipboard(force: true);
      await _loadHistory(silent: true);
      switch (res) {
        case ClipLocalPushed():
          _showToast('已将当前系统剪贴板发送到云端');
        case ClipLocalSkipped(:final reason):
          _showToast(reason);
      }
    } catch (e) {
      _showToast('发送当前剪贴板失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _pushingCurrent = false);
    }
  }

  ClipEndpointConfig _draftEndpointConfig() {
    final current = widget.clipSync.endpoint;
    return current.copyWith(
      useCustomServer: _editingCustomMode,
      customServerUrl: _customUrlCtl.text.trim(),
      customUsername: _customUserCtl.text.trim(),
      customPassword: _customPassCtl.text,
    );
  }

  Future<void> _testCustomServer() async {
    final draft = _draftEndpointConfig();
    if (_editingCustomMode && draft.customServerUrl.isEmpty) {
      setState(() {
        _endpointTestOk = false;
        _endpointTestMessage = '请填写 SyncClipboard 服务器地址（例如 https://example.com:5033）';
      });
      return;
    }
    setState(() {
      _testingEndpoint = true;
      _endpointTestMessage = null;
      _endpointTestOk = null;
    });
    final transport = SyncClipboardHttpTransport(draft);
    try {
      final prof = await transport.getProfile();
      if (!mounted) return;
      setState(() {
        _endpointTestOk = true;
        _endpointTestMessage =
            '连接成功 · 当前远端类型: ${prof.type}${prof.hash.isEmpty ? '（空记录）' : ' (#${prof.hash.substring(0, prof.hash.length < 8 ? prof.hash.length : 8)})'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _endpointTestOk = false;
        _endpointTestMessage = '连接失败：$e';
      });
    } finally {
      transport.close();
      if (mounted) setState(() => _testingEndpoint = false);
    }
  }

  Future<void> _applyEndpointConfig() async {
    final next = _draftEndpointConfig();
    if (next.useCustomServer && next.customServerUrl.isEmpty) {
      _showToast('请先填写自定义服务器地址', isError: true);
      return;
    }
    await widget.clipSync.configure(next);
    widget.onConfigureEndpoint?.call(next);
    if (!mounted) return;
    setState(() {
      _endpointTestOk = true;
      _endpointTestMessage = next.useCustomServer
          ? '已切换到独立 SyncClipboard 服务器'
          : '已切换回 SyncHub 网关免密模式';
    });
    _showToast(_endpointTestMessage!);
  }

  Future<void> _copyHistoryItem(HubItem item) async {
    if (_copyingIds.contains(item.id)) return;
    setState(() => _copyingIds.add(item.id));
    try {
      if (item.isText) {
        final ok = await widget.clipSync.copyToLocalClipboard(item.text);
        _showToast(ok ? '文字已复制到系统剪贴板' : '复制失败', isError: !ok);
      } else if (item.hasFile) {
        final Uint8List bytes = await widget.hub.downloadBytes(item);
        final ok = await widget.clipSync.copyImageToLocalClipboard(
          bytes,
          fileName: item.filename,
        );
        _showToast(ok ? '图片已复制到系统剪贴板' : '系统不支持直接写入图片剪贴板', isError: !ok);
      }
    } catch (e) {
      _showToast('复制失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _copyingIds.remove(item.id));
    }
  }

  Future<void> _toggleHistoryStar(HubItem item) async {
    final nextStar = !item.starred;
    final idx = _historyItems.indexWhere((e) => e.id == item.id);
    final prev = item;
    if (idx >= 0) {
      setState(() => _historyItems[idx] = item.copyWith(starred: nextStar));
    }
    try {
      final updated =
          await widget.hub.updateItem(item.id, starred: nextStar);
      if (!mounted) return;
      final i2 = _historyItems.indexWhere((e) => e.id == item.id);
      if (i2 >= 0) setState(() => _historyItems[i2] = updated);
    } catch (e) {
      if (!mounted) return;
      final i2 = _historyItems.indexWhere((e) => e.id == item.id);
      if (i2 >= 0) setState(() => _historyItems[i2] = prev);
      _showToast('操作失败：$e', isError: true);
    }
  }

  void _deleteHistoryItem(HubItem item) {
    final op = _PendingHistoryDelete(item.id);
    setState(() => _pendingDeletes[item.id] = op);

    op.timer = Timer(const Duration(seconds: 5), () async {
      final removed = _pendingDeletes.remove(item.id);
      if (removed == null) return;
      try {
        await widget.hub.deleteItem(item.id);
        if (!mounted) return;
        setState(() {
          _historyItems.removeWhere((e) => e.id == item.id);
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {});
        _showToast('删除失败：$e', isError: true);
      }
    });

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          content: const Text('已删除 1 条剪贴板记录'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              final pending = _pendingDeletes.remove(item.id);
              if (pending != null) {
                pending.timer?.cancel();
                if (mounted) setState(() {});
              }
            },
          ),
        ),
      );
  }

  // ----------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final history = _filteredHistory;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final hPad = compact ? 16.0 : 20.0;

    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 16 : 24, compact ? 16 : 24, compact ? 12 : 24, 10),
            child: Row(
              children: <Widget>[
                Text(
                  '剪贴板同步',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600, fontSize: compact ? 22 : null),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新历史记录',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _loadHistory(),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: ListenableBuilder(
              listenable: widget.clipSync,
              builder: (_, _) => _buildStatusAndControlsCard(),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 0),
            child: _buildCustomServerExpansionCard(),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 18, hPad, 8),
            child: _buildHistoryHeader(),
          ),
        ),
        if (_loadingHistory && _historyItems.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_historyError != null && _historyItems.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '加载剪贴板历史失败：$_historyError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kRed),
                ),
              ),
            ),
          )
        else if (history.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '暂无剪贴板历史记录。\n在任一设备复制文字或截图后即可自动同步并显示在此处。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kText2),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 28),
            sliver: SliverList.separated(
              itemCount: history.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _buildHistoryTile(history[i]),
            ),
          ),
      ],
    );
  }

  Widget _buildStatusAndControlsCard() {
    final cs = widget.clipSync;
    final st = cs.status;
    final isCustom = cs.isCustomServer;
    final statusColor =
        st.isError ? kRed : (cs.enabled ? kGreen : kText2);
    final dirIcon = switch (st.direction) {
      ClipDirection.up => Icons.north_east_rounded,
      ClipDirection.down => Icons.south_west_rounded,
      ClipDirection.none => cs.enabled ? Icons.sync_rounded : Icons.pause_circle_outline,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: cs.enabled
                        ? (st.isError
                            ? const Color(0x1AFF3B30)
                            : const Color(0x1A34C759))
                        : const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.circle, size: 8, color: statusColor),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          isCustom
                              ? '独立 SyncClipboard 服务器 (Basic)'
                              : 'SyncHub 网关直连 (Bearer 免密)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: st.isError ? kRed : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (cs.lastSyncedAt != null)
                  Text(
                    '最近同步 ${_formatClock(cs.lastSyncedAt!)}',
                    style: const TextStyle(fontSize: 12, color: kText2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(dirIcon, size: 18, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    st.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: st.isError ? kRed : Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _syncingNow ? null : _handleSyncNow,
                  icon: _syncingNow
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('立即同步'),
                ),
                OutlinedButton.icon(
                  onPressed: _pushingCurrent ? null : _handlePushCurrent,
                  icon: _pushingCurrent
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_outlined, size: 18),
                  label: const Text('发送当前剪贴板'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                '双向自动同步剪贴板',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                '复制文字或截图时自动上传到云剪贴板，并在其他设备自动粘贴就绪（兼容 SyncClipboard v3.1.1 / v3.3.3）',
              ),
              value: cs.enabled,
              onChanged: (v) {
                unawaited(cs.setEnabled(v));
                widget.onToggleSync(v);
              },
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                '同步剪贴板图片（≤ 20 MB）',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('关闭后仅同步纯文本，节省移动网络流量'),
              value: cs.syncImages,
              onChanged: (v) {
                cs.setSyncImages(v);
                widget.onToggleImages(v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomServerExpansionCard() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.dns_outlined, color: kAccent, size: 20),
          title: const Text(
            '自定义 SyncClipboard 服务器',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            widget.clipSync.isCustomServer
                ? '当前使用：${widget.clipSync.endpoint.baseUrl}'
                : '默认使用当前已登录的 SyncHub 网关（无需额外填写密码），也可混搭独立 SyncClipboard 服务端',
            style: const TextStyle(fontSize: 12, color: kText2),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          children: <Widget>[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('使用独立 SyncClipboard 服务器 (Basic Auth)'),
              subtitle: const Text('关闭则使用 SyncHub 网关设备令牌自动鉴权'),
              value: _editingCustomMode,
              onChanged: (v) => setState(() {
                _editingCustomMode = v;
                _endpointTestMessage = null;
              }),
            ),
            if (_editingCustomMode) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                controller: _customUrlCtl,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'https://your-host:5033',
                ),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final userField = TextField(
                    controller: _customUserCtl,
                    decoration: const InputDecoration(
                      labelText: '用户名 (Basic Auth)',
                    ),
                  );
                  final passField = TextField(
                    controller: _customPassCtl,
                    obscureText: _obscurePass,
                    decoration: InputDecoration(
                      labelText: '密码',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePass
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () =>
                            setState(() => _obscurePass = !_obscurePass),
                      ),
                    ),
                  );
                  if (constraints.maxWidth < 460) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        userField,
                        const SizedBox(height: 10),
                        passField,
                      ],
                    );
                  }
                  return Row(
                    children: <Widget>[
                      Expanded(child: userField),
                      const SizedBox(width: 10),
                      Expanded(child: passField),
                    ],
                  );
                },
              ),
            ],
            if (_endpointTestMessage != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _endpointTestMessage!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: _endpointTestOk == true ? kGreen : kRed,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _testingEndpoint ? null : _testCustomServer,
                  icon: _testingEndpoint
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check_rounded, size: 18),
                  label: const Text('测试连接'),
                ),
                FilledButton(
                  onPressed: _applyEndpointConfig,
                  child: const Text('保存并应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryHeader() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(right: 6),
          child: Text(
            '剪贴板历史',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        ChoiceChip(
          label: const Text('全部', style: TextStyle(fontSize: 12.5)),
          selected: _historyFilter == _ClipHistoryFilter.all,
          onSelected: (_) =>
              setState(() => _historyFilter = _ClipHistoryFilter.all),
          visualDensity: VisualDensity.compact,
        ),
        ChoiceChip(
          label: const Text('文字', style: TextStyle(fontSize: 12.5)),
          selected: _historyFilter == _ClipHistoryFilter.text,
          onSelected: (_) =>
              setState(() => _historyFilter = _ClipHistoryFilter.text),
          visualDensity: VisualDensity.compact,
        ),
        ChoiceChip(
          label: const Text('图片', style: TextStyle(fontSize: 12.5)),
          selected: _historyFilter == _ClipHistoryFilter.image,
          onSelected: (_) =>
              setState(() => _historyFilter = _ClipHistoryFilter.image),
          visualDensity: VisualDensity.compact,
        ),
        ChoiceChip(
          label: const Text('已收藏', style: TextStyle(fontSize: 12.5)),
          selected: _historyFilter == _ClipHistoryFilter.starred,
          onSelected: (_) =>
              setState(() => _historyFilter = _ClipHistoryFilter.starred),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildHistoryTile(HubItem item) {
    final copying = _copyingIds.contains(item.id);
    final isImg = item.isImage && !item.isText;
    final metaText = <String>[
      if (item.fromDevice.isNotEmpty) item.fromDevice,
      if (item.createTimeLocal.isNotEmpty) item.createTimeLocal,
      if (item.size > 0) humanBytes(item.size),
    ].join(' · ');

    final badge = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: item.isPermanent
            ? const Color(0x1A34C759)
            : const Color(0xFFF2F2F7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        item.isPermanent ? '永久保存' : (isImg ? '图片' : '文字'),
        style: TextStyle(
          fontSize: 11,
          color: item.isPermanent ? kGreen : kText2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 540) {
            final btnStyle = IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(34, 34),
              fixedSize: const Size(34, 34),
              padding: EdgeInsets.zero,
            );
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: const Color(0x14007AFF),
                        child: Icon(
                          isImg ? Icons.image_outlined : Icons.content_paste_rounded,
                          size: 17,
                          color: kAccent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            SelectableText(
                              item.isText ? item.text.trim() : item.displayTitle,
                              maxLines: 4,
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                fontWeight:
                                    isImg ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                            if (metaText.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 5),
                              Text(
                                metaText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5, color: kText2),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Flexible(child: badge),
                      const Spacer(),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        ),
                        onPressed: copying ? null : () => _copyHistoryItem(item),
                        icon: copying
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('复制', style: TextStyle(fontSize: 13)),
                      ),
                      IconButton(
                        style: btnStyle,
                        tooltip: item.starred ? '取消收藏' : '收藏',
                        icon: Icon(
                          item.starred
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: item.starred ? kOrange : kText2,
                          size: 19,
                        ),
                        onPressed: () => _toggleHistoryStar(item),
                      ),
                      IconButton(
                        style: btnStyle,
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline, color: kRed, size: 18),
                        onPressed: () => _deleteHistoryItem(item),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0x14007AFF),
                  child: Icon(
                    isImg ? Icons.image_outlined : Icons.content_paste_rounded,
                    size: 18,
                    color: kAccent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SelectableText(
                        item.isText ? item.text.trim() : item.displayTitle,
                        maxLines: 3,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          fontWeight:
                              isImg ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          badge,
                          Text(
                            metaText,
                            style: const TextStyle(fontSize: 11.5, color: kText2),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: copying ? null : () => _copyHistoryItem(item),
                      icon: copying
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.copy_rounded, size: 17),
                      label: const Text('复制'),
                    ),
                    IconButton(
                      tooltip: item.starred ? '取消收藏' : '收藏',
                      icon: Icon(
                        item.starred
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: item.starred ? kOrange : kText2,
                        size: 20,
                      ),
                      onPressed: () => _toggleHistoryStar(item),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline, color: kRed, size: 19),
                      onPressed: () => _deleteHistoryItem(item),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _formatClock(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final l = dt.toLocal();
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}
