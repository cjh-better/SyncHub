import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// Local-network peer discovery & IP-roaming monitor (`B3`).
///
/// Combines:
/// 1. **UDP multicast + broadcast beacons** on port `53319`
///    (`239.255.77.88`, `224.0.0.251`, `255.255.255.255`, and `/24` subnet
///    broadcasts) carrying `{"synchub": 1, "device_id": selfId, "port": lanPort, "urls": lanUrls}`
///    every 8 seconds and immediately via [announceNow].
/// 2. **Optional mDNS (`_synchub._tcp.local`) lookup** via `package:multicast_dns`,
///    safely guarded against `:5353` port-sharing restrictions on Windows.
/// 3. **Network interface roaming monitor** polling `NetworkInterface.list`
///    every 10 seconds to detect Wi-Fi / subnet switches and trigger
///    [onLocalUrlsChanged].
class MdnsDiscovery {
  static const int defaultDiscoveryPort = 53319;
  static const String multicastGroupPrimary = '239.255.77.88';
  static const String multicastGroupMdns = '224.0.0.251';
  static const String globalBroadcast = '255.255.255.255';
  static const String mdnsServiceName = '_synchub._tcp.local';

  String selfId;
  int lanPort;
  List<String> lanUrls;
  final int discoveryPort;
  final Duration beaconInterval;
  final Duration interfacePollInterval;
  final Duration mdnsScanInterval;
  final bool enableMdnsClient;

  final void Function(String deviceId, List<String> urls)? onPeerDiscovered;
  final void Function(List<String> newUrls)? onLocalUrlsChanged;
  final void Function(String message)? onLog;

  RawDatagramSocket? _udpSocket;
  Timer? _beaconTimer;
  Timer? _ifaceTimer;
  Timer? _mdnsTimer;
  bool _running = false;
  bool _mdnsScanning = false;
  List<InternetAddress> _subnetBroadcasts = const <InternetAddress>[];

  MdnsDiscovery({
    required this.selfId,
    required this.lanPort,
    List<String> initialLanUrls = const <String>[],
    this.discoveryPort = defaultDiscoveryPort,
    this.beaconInterval = const Duration(seconds: 8),
    this.interfacePollInterval = const Duration(seconds: 10),
    this.mdnsScanInterval = const Duration(seconds: 30),
    this.enableMdnsClient = true,
    this.onPeerDiscovered,
    this.onLocalUrlsChanged,
    this.onLog,
  }) : lanUrls = List<String>.from(initialLanUrls);

  bool get isRunning => _running;
  bool get isSocketBound => _udpSocket != null;

  @visibleForTesting
  RawDatagramSocket? get udpSocketForTest => _udpSocket;

  /// Forces immediate re-evaluation of network interfaces and re-binds UDP socket if needed.
  Future<void> refresh() => _checkInterfaces();

  void _log(String msg) => onLog?.call('[discovery] $msg');

  static bool _isPrivateIPv4(List<int> b) =>
      b.length == 4 &&
      (b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168));

  /// Enumerates private IPv4 LAN endpoints (`http://<ip>:<port>`) and `/24`
  /// directed broadcast addresses for all active network interfaces.
  static Future<(List<String> urls, List<InternetAddress> broadcasts, List<NetworkInterface> interfaces)>
      inspectInterfaces(int port) async {
    final urls = <String>[];
    final bcasts = <String, InternetAddress>{};
    var ifaces = <NetworkInterface>[];
    try {
      ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final ni in ifaces) {
        for (final addr in ni.addresses) {
          final raw = addr.rawAddress;
          if (!addr.isLoopback && _isPrivateIPv4(raw)) {
            if (port > 0) {
              urls.add('http://${addr.address}:$port');
            }
            final subBcast = '${raw[0]}.${raw[1]}.${raw[2]}.255';
            bcasts[subBcast] = InternetAddress(subBcast);
          }
        }
      }
    } catch (_) {}
    urls.sort();
    return (urls.take(8).toList(), bcasts.values.toList(), ifaces);
  }

  /// Starts UDP multicast/broadcast listener, periodic beacons, mDNS lookup,
  /// and the 10-second Wi-Fi / IP roaming watcher.
  Future<void> start() async {
    if (_running) return;
    _running = true;

    final (initialUrls, bcasts, ifaces) = await inspectInterfaces(lanPort);
    _subnetBroadcasts = bcasts;
    if (lanUrls.isEmpty && initialUrls.isNotEmpty) {
      lanUrls = initialUrls;
    }

    await _bindUdpSocket(ifaces);
    announceNow();

    _beaconTimer = Timer.periodic(beaconInterval, (_) => announceNow());
    _ifaceTimer = Timer.periodic(interfacePollInterval, (_) {
      unawaited(_checkInterfaces());
    });

    if (enableMdnsClient) {
      unawaited(_scanMdnsOnce());
      _mdnsTimer = Timer.periodic(mdnsScanInterval, (_) {
        unawaited(_scanMdnsOnce());
      });
    }
  }

  Future<void> stop() async {
    _running = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _ifaceTimer?.cancel();
    _ifaceTimer = null;
    _mdnsTimer?.cancel();
    _mdnsTimer = null;
    try {
      _udpSocket?.close();
    } catch (_) {}
    _udpSocket = null;
  }

  void updateSelf({String? selfId, int? lanPort, List<String>? lanUrls}) {
    if (selfId != null) this.selfId = selfId;
    if (lanPort != null) this.lanPort = lanPort;
    if (lanUrls != null) this.lanUrls = List<String>.from(lanUrls);
    if (_running) announceNow();
  }

  Future<void> _bindUdpSocket(List<NetworkInterface> ifaces) async {
    try {
      _udpSocket?.close();
    } catch (_) {}
    _udpSocket = null;

    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
    } catch (_) {
      try {
        sock = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
      } catch (e) {
        try {
          sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
          _log('UDP :$discoveryPort busy ($e); bound ephemeral sender :${sock.port}');
        } catch (e2) {
          _log('UDP discovery unavailable: $e2');
          return;
        }
      }
    }

    _udpSocket = sock;
    try {
      sock.broadcastEnabled = true;
    } catch (_) {}
    try {
      sock.multicastLoopback = false;
    } catch (_) {}
    try {
      sock.multicastHops = 2;
    } catch (_) {}

    _joinMulticastGroups(sock, ifaces);
    sock.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          _onDatagramReadable(sock!);
        }
      },
      onError: (Object _) {},
    );
  }

  void _joinMulticastGroups(RawDatagramSocket sock, List<NetworkInterface> ifaces) {
    final groups = <InternetAddress>[
      InternetAddress(multicastGroupPrimary),
      InternetAddress(multicastGroupMdns),
    ];
    for (final g in groups) {
      try {
        sock.joinMulticast(g);
      } catch (_) {}
      for (final ni in ifaces) {
        try {
          sock.joinMulticast(g, ni);
        } catch (_) {}
      }
    }
  }

  void _onDatagramReadable(RawDatagramSocket sock) {
    while (true) {
      Datagram? dg;
      try {
        dg = sock.receive();
      } catch (_) {
        return;
      }
      if (dg == null) return;
      _parseBeacon(dg.data, sourceIp: dg.address);
    }
  }

  /// Parses an incoming UDP beacon payload (exposed for deterministic unit tests).
  void handleRawBeacon(List<int> bytes, {InternetAddress? sourceIp}) =>
      _parseBeacon(bytes, sourceIp: sourceIp);

  void _parseBeacon(List<int> bytes, {InternetAddress? sourceIp}) {
    if (bytes.isEmpty || bytes.length > 4096) return;
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['synchub'] != 1) return;

      final peerId = (decoded['device_id'] as String? ?? '').trim();
      if (peerId.isEmpty || peerId == selfId) return;

      final portVal = (decoded['port'] as num?)?.toInt() ?? 0;
      final candidateUrls = <String>[];

      if (sourceIp != null &&
          sourceIp.type == InternetAddressType.IPv4 &&
          !sourceIp.isLoopback &&
          portVal > 0 &&
          portVal <= 65535) {
        candidateUrls.add('http://${sourceIp.address}:$portVal');
      }

      final rawUrls = decoded['urls'];
      if (rawUrls is List) {
        for (final item in rawUrls) {
          if (item is String &&
              (item.startsWith('http://') || item.startsWith('https://')) &&
              !candidateUrls.contains(item)) {
            candidateUrls.add(item);
          }
        }
      }

      if (candidateUrls.isNotEmpty) {
        onPeerDiscovered?.call(peerId, candidateUrls.take(8).toList());
      }
    } catch (_) {
      // Ignore malformed / foreign UDP traffic on the multicast group.
    }
  }

  /// Immediately broadcasts this device's LAN beacon over UDP multicast &
  /// broadcast addresses on port `53319`.
  void announceNow() {
    final sock = _udpSocket;
    if (!_running || sock == null || selfId.isEmpty || lanPort <= 0) return;
    if (lanUrls.isEmpty) return;

    final payload = utf8.encode(jsonEncode(<String, dynamic>{
      'synchub': 1,
      'device_id': selfId,
      'port': lanPort,
      'urls': lanUrls,
    }));

    final targets = <InternetAddress>[
      InternetAddress(multicastGroupPrimary),
      InternetAddress(multicastGroupMdns),
      InternetAddress(globalBroadcast),
      ..._subnetBroadcasts,
    ];

    var failedCount = 0;
    for (final addr in targets) {
      try {
        final sent = sock.send(payload, addr, discoveryPort);
        if (sent <= 0) failedCount++;
      } catch (_) {
        failedCount++;
      }
    }
    if (failedCount == targets.length && targets.isNotEmpty) {
      _log('UDP send failed on all targets; invalidating socket for re-bind');
      try {
        _udpSocket?.close();
      } catch (_) {}
      _udpSocket = null;
    }
  }

  Future<void> _checkInterfaces() async {
    if (!_running || lanPort <= 0) return;
    final (freshUrls, bcasts, ifaces) = await inspectInterfaces(lanPort);
    _subnetBroadcasts = bcasts;

    final currentSorted = List<String>.from(lanUrls)..sort();
    var changed = currentSorted.length != freshUrls.length;
    if (!changed) {
      for (var i = 0; i < freshUrls.length; i++) {
        if (currentSorted[i] != freshUrls[i]) {
          changed = true;
          break;
        }
      }
    }

    // Dynamic recovery: If socket is null and interfaces are available, re-bind
    if (_udpSocket == null && ifaces.isNotEmpty) {
      _log('UDP socket null; dynamically re-binding on available interfaces');
      await _bindUdpSocket(ifaces);
    }

    if (changed) {
      lanUrls = freshUrls;
      final sock = _udpSocket;
      if (sock != null) {
        _joinMulticastGroups(sock, ifaces);
      } else {
        await _bindUdpSocket(ifaces);
      }
      _log('network interfaces updated: ${lanUrls.join(', ')}');
      onLocalUrlsChanged?.call(List<String>.unmodifiable(lanUrls));
      announceNow();
    }
  }

  Future<void> _scanMdnsOnce() async {
    if (!_running || _mdnsScanning || !enableMdnsClient) return;
    _mdnsScanning = true;
    final client = MDnsClient();
    try {
      await client.start(onError: (Object _) {});
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(mdnsServiceName),
        timeout: const Duration(seconds: 3),
      )) {
        if (!_running) break;
        await _resolveMdnsInstance(client, ptr.domainName);
      }
    } catch (_) {
      // Windows Dnscache / Bonjour may hold :5353 exclusively; UDP 53319 continues unaffected.
    } finally {
      try {
        client.stop();
      } catch (_) {}
      _mdnsScanning = false;
    }
  }

  Future<void> _resolveMdnsInstance(MDnsClient client, String domainName) async {
    var peerId = '';
    final dotIdx = domainName.indexOf('._synchub._tcp');
    if (dotIdx > 0) {
      peerId = domainName.substring(0, dotIdx).trim();
    }

    try {
      await for (final txt in client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(domainName),
        timeout: const Duration(seconds: 2),
      )) {
        for (final line in txt.text.split(RegExp(r'[\r\n;]+'))) {
          final kv = line.trim();
          if (kv.startsWith('device_id=')) {
            peerId = kv.substring('device_id='.length).trim();
          } else if (kv.startsWith('id=') && peerId.isEmpty) {
            peerId = kv.substring('id='.length).trim();
          }
        }
      }
    } catch (_) {}

    if (peerId.isEmpty || peerId == selfId) return;

    final urls = <String>[];
    try {
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(domainName),
        timeout: const Duration(seconds: 2),
      )) {
        if (srv.port <= 0 || srv.port > 65535) continue;
        await for (final ip in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target),
          timeout: const Duration(seconds: 2),
        )) {
          if (!ip.address.isLoopback) {
            final u = 'http://${ip.address.address}:${srv.port}';
            if (!urls.contains(u)) urls.add(u);
          }
        }
      }
    } catch (_) {}

    if (urls.isNotEmpty) {
      onPeerDiscovered?.call(peerId, urls.take(8).toList());
    }
  }
}
