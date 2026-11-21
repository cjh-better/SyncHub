import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/engine.dart';
import '../platform/platform_bridge.dart';
import '../platform/win_integration.dart';
import 'theme.dart';

class OnboardingPage extends StatefulWidget {
  final Engine engine;
  final bool platformIsMobile;
  const OnboardingPage({super.key, required this.engine, required this.platformIsMobile});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _server = TextEditingController(text: 'https://020814.xyz/gw');
  final _name = TextEditingController(text: _defaultName());
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  bool _useCode = false;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(_prefillLegacyAccount());
    }
  }

  Future<void> _prefillLegacyAccount() async {
    if (Platform.isWindows) {
      final acct = await WinIntegration.readLegacySyncClipboardAccount();
      if (!mounted || acct == null) return;
      if (_user.text.isEmpty && acct.username.isNotEmpty) {
        setState(() => _user.text = acct.username);
      }
      return;
    }
    if (Platform.isMacOS) {
      var info = PlatformBridge.instance?.legacyMacInfo;
      if (info == null) {
        try {
          final raw = await PlatformBridge.desktopChannel
              .invokeMethod<dynamic>('migrateLegacyMacState');
          if (raw is Map) {
            info = raw.map((k, v) => MapEntry('$k', v));
          }
        } catch (_) {}
      }
      if (!mounted || info == null) return;
      final u = (info['username'] as String? ?? '').trim();
      if (_user.text.isEmpty && u.isNotEmpty) {
        setState(() => _user.text = u);
      }
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _name.dispose();
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  static String _defaultName() {
    final h = Platform.localHostname;
    if (Platform.isAndroid) return 'Android 手机';
    return h.isEmpty ? AppConfig.platformLabel() : h;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.engine.register(
        server: _server.text.trim(),
        name: _name.text.trim(),
        user: _useCode ? '' : _user.text.trim(),
        pass: _useCode ? '' : _pass.text,
        code: _useCode ? _code.text.trim() : '',
      );
      await widget.engine.start();
      unawaited(PlatformBridge.instance?.syncAndroidService(forceStart: true));
    } catch (e) {
      setState(() => _error = e.toString().contains('401')
          ? (_useCode ? '配对码无效或已过期' : '账号或密码错误')
          : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.swap_horiz_rounded, size: 48, color: kAccent),
                    const SizedBox(height: 12),
                    Text('SyncHub', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    const Text('Android · Mac · Windows 互传文件与剪贴板', textAlign: TextAlign.center, style: TextStyle(color: kText2)),
                    const SizedBox(height: 24),
                    TextField(controller: _server, decoration: const InputDecoration(labelText: '服务器地址')),
                    const SizedBox(height: 12),
                    TextField(controller: _name, decoration: const InputDecoration(labelText: '这台设备的名称')),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('账号密码'), icon: Icon(Icons.person_outline)),
                        ButtonSegment(value: true, label: Text('配对码'), icon: Icon(Icons.pin_outlined)),
                      ],
                      selected: {_useCode},
                      onSelectionChanged: (s) => setState(() => _useCode = s.first),
                    ),
                    const SizedBox(height: 12),
                    if (_useCode)
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '6 位配对码', helperText: '在已登录设备的「设置 → 添加设备」中获取'),
                      )
                    else ...[
                      TextField(controller: _user, decoration: const InputDecoration(labelText: '用户名')),
                      const SizedBox(height: 12),
                      TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: '密码')),
                    ],
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(_error, style: const TextStyle(color: kRed)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('登录这台设备'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
