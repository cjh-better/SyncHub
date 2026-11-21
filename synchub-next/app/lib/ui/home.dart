import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import '../core/hub_api.dart';
import '../core/manifest.dart';
import '../core/proto.dart';
import '../platform/platform_bridge.dart';
import 'clipboard_page.dart';
import 'cloud_page.dart';
import 'settings.dart';
import 'theme.dart';

bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

class HomePage extends StatefulWidget {
  final Engine engine;
  const HomePage({super.key, required this.engine});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    PlatformBridge.instance?.onSelectTab = _selectTab;
  }

  @override
  void dispose() {
    if (PlatformBridge.instance?.onSelectTab == _selectTab) {
      PlatformBridge.instance?.onSelectTab = null;
    }
    super.dispose();
  }

  void _selectTab(int idx) {
    if (!mounted) return;
    if (idx >= 0 && idx <= 4) {
      setState(() => _tab = idx);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    final pages = <Widget>[
      RepaintBoundary(
        child: DevicesPage(
          engine: e,
          onSent: () => setState(() => _tab = 1),
          onOpenCloudTab: () => setState(() => _tab = 2),
        ),
      ),
      RepaintBoundary(
        child: TransfersPage(engine: e),
      ),
      CloudPage(
        hub: e.hub,
        deviceName: e.cfg?.name ?? '本机',
        deviceId: e.self,
        recvDir: e.cfg?.recvDir ?? '',
        onCopyText: (text) async {
          await e.clipSync.copyToLocalClipboard(text);
        },
      ),
      ClipboardPage(
        clipSync: e.clipSync,
        hub: e.hub,
        deviceName: e.cfg?.name ?? '本机',
        onToggleSync: (v) => e.updateConfig((c) => c.clipSync = v),
        onToggleImages: (v) => e.updateConfig((c) => c.clipImages = v),
        onConfigureEndpoint: (ep) => e.configureClipboardEndpoint(ep),
      ),
      SettingsPage(engine: e),
    ];

    const dests = [
      (Icons.devices_outlined, Icons.devices, '设备'),
      (Icons.swap_vert_outlined, Icons.swap_vert, '传输'),
      (Icons.cloud_outlined, Icons.cloud, '云端'),
      (Icons.content_paste_outlined, Icons.content_paste, '剪贴板'),
      (Icons.settings_outlined, Icons.settings, '设置'),
    ];
    final active = e.transfers.values.where((t) => !t.finished).length;
    final pendingCount = e.pendingOffers.length;
    Widget badge(Widget icon, int i) {
      if (i == 1 && (active + pendingCount) > 0) {
        return Badge(label: Text('${active + pendingCount}'), child: icon);
      }
      return icon;
    }

    final mainContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (e.pendingOffers.isNotEmpty)
          _IncomingOffersBanner(
            engine: e,
            onAccepted: () => setState(() => _tab = 1),
          ),
        Expanded(child: pages[_tab]),
      ],
    );

    final wide = MediaQuery.sizeOf(context).width >= 720;
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: _StatusDot(engine: e),
            ),
            destinations: [
              for (var i = 0; i < dests.length; i++)
                NavigationRailDestination(
                  icon: badge(Icon(dests[i].$1), i),
                  selectedIcon: badge(Icon(dests[i].$2), i),
                  label: Text(dests[i].$3),
                ),
            ],
          ),
          const VerticalDivider(width: 0.6),
          Expanded(child: mainContent),
        ]),
      );
    }
    return Scaffold(
      body: SafeArea(child: mainContent),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (var i = 0; i < dests.length; i++)
            NavigationDestination(
              icon: badge(Icon(dests[i].$1), i),
              selectedIcon: badge(Icon(dests[i].$2), i),
              label: dests[i].$3,
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Engine engine;
  const _StatusDot({required this.engine});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: engine,
        builder: (context, _) => Tooltip(
          message: engine.status,
          child: Icon(Icons.circle, size: 12, color: engine.connected ? kGreen : kOrange),
        ),
      );
}

class _IncomingOffersBanner extends StatelessWidget {
  final Engine engine;
  final VoidCallback onAccepted;
  const _IncomingOffersBanner({required this.engine, required this.onAccepted});

  @override
  Widget build(BuildContext context) {
    final offers = engine.pendingOffers.values.toList();
    final compact = MediaQuery.sizeOf(context).width < 520;
    return Container(
      color: const Color(0xFFEAF3FF),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final po in offers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.move_to_inbox_rounded, color: kAccent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${po.fromName} 请求发送「${po.title}」',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    '共 ${po.fileCount} 个文件 · ${humanBytes(po.totalSize)}',
                                    style: const TextStyle(color: kText2, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                              onPressed: () => engine.respondOffer(po.transferId, false),
                              child: const Text('拒绝'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                              onPressed: () {
                                engine.respondOffer(po.transferId, true);
                                onAccepted();
                              },
                              child: const Text('接收'),
                            ),
                          ],
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        const Icon(Icons.move_to_inbox_rounded, color: kAccent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${po.fromName} 请求发送「${po.title}」',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                '共 ${po.fileCount} 个文件 · ${humanBytes(po.totalSize)}',
                                style: const TextStyle(color: kText2, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => engine.respondOffer(po.transferId, false),
                          child: const Text('拒绝'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            engine.respondOffer(po.transferId, true);
                            onAccepted();
                          },
                          child: const Text('接收'),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ devices

class DevicesPage extends StatelessWidget {
  final Engine engine;
  final VoidCallback onSent;
  final VoidCallback onOpenCloudTab;
  const DevicesPage({
    super.key,
    required this.engine,
    required this.onSent,
    required this.onOpenCloudTab,
  });

  Future<void> _pickAndSend(BuildContext context, DeviceInfo d, {bool folder = false}) async {
    List<String> paths = [];
    if (folder) {
      final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择要发送给 ${d.name} 的文件夹');
      if (dir != null) paths = [dir];
    } else {
      final r = await FilePicker.pickFiles(dialogTitle: '选择要发送给 ${d.name} 的文件');
      paths = r.map((f) => f.path).whereType<String>().toList();
    }
    if (paths.isEmpty) return;
    await engine.sendPaths(d.id, paths);
    onSent();
  }

  Future<void> _pickAndSendCloud() async {
    final r = await FilePicker.pickFiles(dialogTitle: '选择要上传到云端收藏的文件');
    final paths = r.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    await engine.sendPaths(kCloudTargetId, paths, star: true);
    onSent();
  }

  void _openCloudWebOrTab() {
    if (_desktop) {
      final origin = HubApi.deriveOrigin(engine.cfg?.server ?? 'https://020814.xyz/gw');
      PlatformBridge.openUrl('$origin/hub/');
    } else {
      onOpenCloudTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final others = engine.devices.values.where((d) => d.id != engine.self).toList()
          ..sort((a, b) => a.online == b.online ? a.name.compareTo(b.name) : (a.online ? -1 : 1));
        final totalCards = others.length + 1;

        final compact = MediaQuery.sizeOf(context).width < 600;
        final hPad = compact ? 16.0 : 24.0;
        final gridGap = compact ? 12.0 : 16.0;

        return CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, compact ? 16 : 24, hPad, 4),
              child: Row(children: [
                Text(
                  '我的设备',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600, fontSize: compact ? 22 : null),
                ),
                const Spacer(),
                Text(engine.connected ? '已连接' : engine.status, style: const TextStyle(color: kText2)),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 16),
              child: Text(
                _desktop
                    ? '把文件或文件夹拖到设备或云端卡片上即可发送；点击选择文件，右键设备选择文件夹。'
                    : '点击设备或云端收藏选择要发送的文件；长按设备发送文件夹。',
                style: const TextStyle(color: kText2),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 16),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: gridGap,
                crossAxisSpacing: gridGap,
                childAspectRatio: compact ? 0.90 : 0.95,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  if (i < others.length) {
                    final dev = others[i];
                    return DeviceCard(
                      engine: engine,
                      device: dev,
                      onTap: () => _pickAndSend(context, dev),
                      onFolder: () => _pickAndSend(context, dev, folder: true),
                      onDropped: (paths) async {
                        await engine.sendPaths(dev.id, paths);
                        onSent();
                      },
                    );
                  }
                  return CloudTargetCard(
                    engine: engine,
                    onTap: _pickAndSendCloud,
                    onOpenHub: _openCloudWebOrTab,
                    onDropped: (paths) async {
                      await engine.sendPaths(kCloudTargetId, paths, star: true);
                      onSent();
                    },
                  );
                },
                childCount: totalCards,
              ),
            ),
          ),
          if (others.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 32),
                child: Text(
                  '提示：在另一台 Android / Mac / Windows 设备上登录同一账号，或在「设置 → 添加设备」获取 6 位配对码登录，即可出现在上方直连互传。',
                  style: TextStyle(color: kText2, fontSize: 13),
                ),
              ),
            ),
        ]);
      },
    );
  }
}

class DeviceCard extends StatefulWidget {
  final Engine engine;
  final DeviceInfo device;
  final VoidCallback onTap;
  final VoidCallback onFolder;
  final void Function(List<String>) onDropped;
  const DeviceCard({
    super.key,
    required this.engine,
    required this.device,
    required this.onTap,
    required this.onFolder,
    required this.onDropped,
  });

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final active = widget.engine.transfers.values.where((t) => !t.finished && t.peerId == d.id).toList();
    final progress = active.isEmpty
        ? null
        : active.fold<int>(0, (a, t) => a + t.done) / active.fold<int>(1, (a, t) => a + t.total);
    final offlineFallback = widget.engine.cfg?.offlineFallback ?? true;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: _hover ? const Color(0xFFEAF3FF) : kCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _hover ? kAccent : kHair, width: _hover ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: widget.onTap,
        onLongPress: widget.onFolder,
        onSecondaryTap: widget.onFolder,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 76,
                height: 76,
                child: CircularProgressIndicator(
                  value: progress ?? 0,
                  strokeWidth: 4,
                  backgroundColor: progress == null ? Colors.transparent : kHair,
                  color: kAccent,
                ),
              ),
              CircleAvatar(
                radius: 32,
                backgroundColor: d.online ? const Color(0x14007AFF) : const Color(0xFFF2F2F7),
                child: Icon(platformIcon(d.platform), size: 32, color: d.online ? kAccent : kText2),
              ),
            ]),
            const SizedBox(height: 12),
            Text(
              d.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 8, color: d.online ? kGreen : const Color(0xFFC7C7CC)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  progress != null
                      ? '传输中 ${(progress * 100).toStringAsFixed(0)}%'
                      : d.online
                          ? (d.lan.isNotEmpty ? '在线 · 可局域网直连' : '在线')
                          : (offlineFallback ? '离线 · 自动云端投递' : '离线 · 上线后发送'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kText2, fontSize: 12),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    if (!_desktop) return card;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (detail) {
        setState(() => _hover = false);
        final paths = detail.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
        if (paths.isNotEmpty) widget.onDropped(paths);
      },
      child: card,
    );
  }
}

class CloudTargetCard extends StatefulWidget {
  final Engine engine;
  final VoidCallback onTap;
  final VoidCallback onOpenHub;
  final void Function(List<String>) onDropped;
  const CloudTargetCard({
    super.key,
    required this.engine,
    required this.onTap,
    required this.onOpenHub,
    required this.onDropped,
  });

  @override
  State<CloudTargetCard> createState() => _CloudTargetCardState();
}

class _CloudTargetCardState extends State<CloudTargetCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.engine.transfers.values
        .where((t) => !t.finished && t.peerId == kCloudTargetId)
        .toList();
    final progress = active.isEmpty
        ? null
        : active.fold<int>(0, (a, t) => a + t.done) / active.fold<int>(1, (a, t) => a + t.total);
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: _hover ? const Color(0xFFFFF8EB) : kCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _hover ? kOrange : kHair, width: _hover ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: widget.onTap,
        onSecondaryTap: widget.onOpenHub,
        onLongPress: widget.onOpenHub,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 76,
                height: 76,
                child: CircularProgressIndicator(
                  value: progress ?? 0,
                  strokeWidth: 4,
                  backgroundColor: progress == null ? Colors.transparent : kHair,
                  color: kOrange,
                ),
              ),
              const CircleAvatar(
                radius: 32,
                backgroundColor: Color(0x1FFF9500),
                child: Icon(Icons.cloud_upload_rounded, size: 32, color: kOrange),
              ),
            ]),
            const SizedBox(height: 12),
            const Text(
              '云端收藏',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              progress != null
                  ? '上传中 ${(progress * 100).toStringAsFixed(0)}%'
                  : (_desktop ? '拖入收藏 · 右键开网页' : '点击上传 · 长按查看云端'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kText2, fontSize: 12),
            ),
          ]),
        ),
      ),
    );
    if (!_desktop) return card;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (detail) {
        setState(() => _hover = false);
        final paths = detail.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
        if (paths.isNotEmpty) widget.onDropped(paths);
      },
      child: card,
    );
  }
}

// ---------------------------------------------------------------- transfers

class TransfersPage extends StatelessWidget {
  final Engine engine;
  const TransfersPage({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final list = engine.transfers.values.toList()
          ..sort((a, b) {
            if (a.finished != b.finished) return a.finished ? 1 : -1;
            return b.updated.compareTo(a.updated);
          });
        final compact = MediaQuery.sizeOf(context).width < 600;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 16 : 24, compact ? 16 : 24, 16, 12),
            child: Row(children: [
              Text(
                '传输',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600, fontSize: compact ? 22 : null),
              ),
              const Spacer(),
              if (list.any((t) => t.finished)) TextButton(onPressed: engine.clearHistory, child: const Text('清除记录')),
            ]),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('暂无传输记录', style: TextStyle(color: kText2)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => TransferTile(engine: engine, t: list[i]),
                  ),
          ),
        ]);
      },
    );
  }
}

class TransferTile extends StatelessWidget {
  final Engine engine;
  final TransferView t;
  const TransferTile({super.key, required this.engine, required this.t});

  String get _routeLabel => switch (t.route) {
        'lan' => '局域网直连',
        'webrtc' => '直连 (WebRTC)',
        'cloud' => '云端投递',
        '' => '',
        _ when t.route.startsWith('relay:la') => '中继 · 洛杉矶',
        _ when t.route.startsWith('relay:main') => '中继 · 主服务器',
        _ => t.route,
      };

  String get _stateLabel => switch (t.state) {
        TransferState.hashing => '准备中…',
        TransferState.queued => '排队中',
        TransferState.connecting => '连接中…',
        TransferState.active => '${humanBytes(t.done)} / ${humanBytes(t.total)} · ${humanBytes(t.speed)}/s',
        TransferState.waiting => t.error.isEmpty ? '等待对方上线' : '已中断，将自动续传',
        TransferState.paused => '已手动暂停 · ${humanBytes(t.done)} / ${humanBytes(t.total)}',
        TransferState.done => '已完成 · ${humanBytes(t.total)}',
        TransferState.failed => t.error.isEmpty ? '失败' : t.error,
      };

  @override
  Widget build(BuildContext context) {
    final color = switch (t.state) {
      TransferState.failed => kRed,
      TransferState.done => kGreen,
      TransferState.waiting || TransferState.paused => kOrange,
      _ => kAccent,
    };
    final canResend = t.direction == 'send' && t.sourcePaths.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(children: [
          Icon(t.direction == 'send' ? Icons.north_east_rounded : Icons.south_west_rounded, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                '${t.direction == 'send' ? '发往' : '来自'} ${t.peer}${_routeLabel.isEmpty ? '' : ' · $_routeLabel'}',
                style: const TextStyle(color: kText2, fontSize: 12),
              ),
              if (!t.finished) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: t.state == TransferState.hashing && t.total == 0 ? null : t.fraction,
                    minHeight: 5,
                    color: color,
                    backgroundColor: kHair,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                _stateLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.state == TransferState.failed ? kRed : kText2, fontSize: 12),
              ),
            ]),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (t.state == TransferState.paused) ...[
                IconButton(
                  tooltip: '继续传输',
                  icon: const Icon(Icons.play_arrow_rounded, color: kAccent),
                  onPressed: () => engine.resumeTransfer(t.id),
                ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: () => engine.cancelTransfer(t.id),
                ),
              ] else if (!t.finished) ...[
                if (t.state != TransferState.hashing)
                  IconButton(
                    tooltip: '暂停传输',
                    icon: const Icon(Icons.pause_rounded),
                    onPressed: () => engine.pauseTransfer(t.id),
                  ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: () => engine.cancelTransfer(t.id),
                ),
              ] else if (t.state == TransferState.failed) ...[
                if (canResend)
                  IconButton(
                    tooltip: '重试发送',
                    icon: const Icon(Icons.refresh_rounded, color: kAccent),
                    onPressed: () => engine.retryOrResend(t.id),
                  ),
              ] else if (t.state == TransferState.done) ...[
                if (t.saved.isNotEmpty) ...[
                  IconButton(
                    tooltip: '打开文件',
                    icon: const Icon(Icons.open_in_new_rounded),
                    onPressed: () => PlatformBridge.openFile(t.saved.first),
                  ),
                  if (_desktop)
                    IconButton(
                      tooltip: '在文件夹中显示',
                      icon: const Icon(Icons.folder_open_outlined),
                      onPressed: () => PlatformBridge.revealInFolder(t.saved.first),
                    )
                  else
                    IconButton(
                      tooltip: '复制路径',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => Clipboard.setData(ClipboardData(text: t.saved.join('\n'))),
                    ),
                ],
                if (canResend)
                  IconButton(
                    tooltip: '再次发送',
                    icon: const Icon(Icons.replay_rounded),
                    onPressed: () => engine.retryOrResend(t.id),
                  ),
              ],
            ],
          ),
        ]),
      ),
    );
  }
}
