import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synchub/core/clipboard_sync.dart';
import 'package:synchub/core/hub_api.dart';
import 'package:synchub/ui/clipboard_page.dart';
import 'package:synchub/ui/cloud_page.dart';
import 'package:synchub/ui/theme.dart';

class _FakeHubApi extends HubApi {
  final List<HubItem> sampleItems;

  _FakeHubApi(this.sampleItems)
      : super(
          gatewayServerUrl: 'https://020814.xyz/gw',
          token: 'fixture-token',
        );

  @override
  Future<HubListResult> listItems({
    String category = '',
    String q = '',
    bool starred = false,
    bool pinned = false,
    int limit = 300,
  }) async {
    return HubListResult(
      retentionHours: 72,
      counts: <String, int>{
        '全部': sampleItems.length,
        '文本': sampleItems.where((e) => e.category == '文本').length,
        '文档': sampleItems.where((e) => e.category == '文档').length,
      },
      items: sampleItems,
    );
  }

  @override
  Future<HubStorageInfo> storageInfo() async {
    return const HubStorageInfo(
      total: 63243395072,
      used: 15999000000,
      free: 47244395072,
      hubBytes: 524288000,
    );
  }
}

List<HubItem> _buildSampleItems() => const <HubItem>[
      HubItem(
        id: 1062,
        type: 0,
        typeName: 'Text',
        text: '生成一段用于跨端剪贴板测试的较长中文内容示例\n第二行详细补充内容不会把卡片挤成竖排窄条',
        filename: '',
        size: 44,
        hash: 'CAB63F4C',
        createTimeUtc: '2026-11-13T15:27:20Z',
        createTimeLocal: '2026-11-13 23:27:20',
        starred: true,
        pinned: true,
        isPermanent: true,
        remainingSeconds: null,
        fromDevice: 'Clipboard',
        sourceDeviceId: 'dev_win',
        targetDevice: '',
        category: '文本',
        tags: <String>['clipboard'],
        hasFile: false,
        downloadUrl: null,
      ),
      HubItem(
        id: 1061,
        type: 0,
        typeName: 'Text',
        text: 'ip地址 203.0.113.10 域名 clipboard.example',
        filename: '',
        size: 52,
        hash: 'D5D56CB9',
        createTimeUtc: '2026-11-11T01:40:36Z',
        createTimeLocal: '2026-11-11 09:40:36',
        starred: true,
        pinned: false,
        isPermanent: true,
        remainingSeconds: null,
        fromDevice: 'Clipboard',
        sourceDeviceId: 'dev_android',
        targetDevice: '',
        category: '文本',
        tags: <String>['clipboard'],
        hasFile: false,
        downloadUrl: null,
      ),
      HubItem(
        id: 1060,
        type: 1,
        typeName: 'File',
        text: '',
        filename: 'SyncHub-跨端项目需求说明文档_v2.pdf',
        size: 2458624,
        hash: 'AABBCCDD',
        createTimeUtc: '2026-11-15T06:00:00Z',
        createTimeLocal: '2026-11-15 14:00:00',
        starred: false,
        pinned: false,
        isPermanent: false,
        remainingSeconds: 18 * 3600,
        fromDevice: 'MacBook Pro',
        sourceDeviceId: 'dev_mac',
        targetDevice: '',
        category: '文档',
        tags: <String>[],
        hasFile: true,
        downloadUrl: '/api/hub/download/1060',
      ),
    ];

void main() {
  for (final screenSize in const <Size>[Size(360, 800), Size(392, 873)]) {
    testWidgets(
      'CloudPage mobile layout has full-width text & single-line badges at ${screenSize.width.toInt()}x${screenSize.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(screenSize);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final hub = _FakeHubApi(_buildSampleItems());
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: SafeArea(
                child: CloudPage(
                  hub: hub,
                  deviceName: 'realme RMX3888',
                  deviceId: 'dev_android',
                  recvDir: '/tmp',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Verify metadata and title get full horizontal width (>= 220dp, never squished <40dp).
        final metaFinder = find.text('Clipboard · 2026-11-13 23:27:20 · 44 B');
        expect(metaFinder, findsOneWidget);
        final metaSize = tester.getSize(metaFinder);
        expect(metaSize.width, greaterThan(220));
        expect(metaSize.height, lessThan(26));

        // Verify "永久保存" badge stays on one horizontal line instead of stacking vertically.
        final permBadges = find.text('永久保存');
        expect(permBadges, findsWidgets);
        final badgeSize = tester.getSize(permBadges.first);
        expect(badgeSize.height, lessThan(26));
        expect(badgeSize.width, greaterThan(40));

        // Switch to batch selection mode and ensure zero overflow.
        await tester.tap(find.byTooltip('批量管理'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Exit batch mode and switch to Grid mode on narrow mobile screen.
        await tester.tap(find.byTooltip('退出批量选择'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('切换为网格视图'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ClipboardPage mobile layout renders history & custom server fields cleanly at ${screenSize.width.toInt()}x${screenSize.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(screenSize);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final hub = _FakeHubApi(_buildSampleItems());
        final clipSync = ClipboardSync(
          supportDir: '/tmp',
          endpoint: const ClipEndpointConfig(
            gatewayServerUrl: 'https://020814.xyz/gw',
            bearerToken: 'fixture-token',
          ),
          stateStore: MemoryClipStateStore(),
          enabled: false,
        );
        addTearDown(clipSync.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: SafeArea(
                child: ClipboardPage(
                  clipSync: clipSync,
                  hub: hub,
                  deviceName: 'realme RMX3888',
                  onToggleSync: (_) {},
                  onToggleImages: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Expand custom server card and toggle Basic Auth fields on narrow screen.
        await tester.tap(find.text('自定义 SyncClipboard 服务器'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('使用独立 SyncClipboard 服务器 (Basic Auth)'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Scroll down so SliverList builds history cards even on short 800dp viewports.
        final historyMeta = find.text('Clipboard · 2026-11-13 23:27:20 · 44 B');
        await tester.scrollUntilVisible(
          historyMeta,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Verify clipboard history card text gets generous horizontal width.
        expect(historyMeta, findsOneWidget);
        expect(tester.getSize(historyMeta).width, greaterThan(210));
        expect(tester.getSize(historyMeta).height, lessThan(26));
      },
    );
  }
}
