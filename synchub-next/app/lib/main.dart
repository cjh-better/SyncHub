import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/engine.dart';
import 'platform/platform_bridge.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(kLightOverlayStyle);
  final dir = await getApplicationSupportDirectory();
  final engine = await Engine.open(dir.path);
  final bridge = PlatformBridge(engine);
  Engine.beforeStart = bridge.prepareBeforeStart;
  if (engine.registered) await engine.start();
  runApp(SyncHubApp(engine: engine, bridge: bridge));
}

class SyncHubApp extends StatefulWidget {
  final Engine engine;
  final PlatformBridge? bridge;
  const SyncHubApp({super.key, required this.engine, this.bridge});

  @override
  State<SyncHubApp> createState() => _SyncHubAppState();
}

class _SyncHubAppState extends State<SyncHubApp> {
  @override
  void initState() {
    super.initState();
    final bridge = widget.bridge;
    if (bridge != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(bridge.attach());
      });
    }
  }

  @override
  void dispose() {
    widget.bridge?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    return MaterialApp(
      navigatorKey: widget.bridge?.navigatorKey,
      title: 'SyncHub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        value: kLightOverlayStyle,
        child: ValueListenableBuilder<bool>(
          valueListenable: e.registeredNotifier,
          builder: (context, registered, _) => registered
              ? HomePage(engine: e)
              : OnboardingPage(
                  engine: e,
                  platformIsMobile: Platform.isAndroid || Platform.isIOS,
                ),
        ),
      ),
    );
  }
}
