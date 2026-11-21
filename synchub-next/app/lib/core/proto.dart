// Wire types of the SyncHub protocol v1. Mirrors
// server/gateway/internal/proto/proto.go — keep field names in sync.

const int kDefaultChunkSize = 4 << 20;
const int kMaxChunkSize = 16 << 20;
const int kAeadOverhead = 16;

DateTime _parseTime(dynamic v) =>
    v is String ? (DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0)) : DateTime.fromMillisecondsSinceEpoch(0);

class DeviceInfo {
  final String id;
  final String name;
  final String platform;
  final String publicKey;
  final bool online;
  final DateTime lastSeen;
  final List<String> lan;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.online,
    required this.lastSeen,
    this.lan = const [],
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        platform: (j['platform'] ?? '') as String,
        publicKey: (j['public_key'] ?? '') as String,
        online: (j['online'] ?? false) as bool,
        lastSeen: _parseTime(j['last_seen']),
        lan: ((j['lan'] ?? []) as List).cast<String>(),
      );

  DeviceInfo copyWith({bool? online, List<String>? lan}) {
    final nextOnline = online ?? this.online;
    return DeviceInfo(
      id: id,
      name: name,
      platform: platform,
      publicKey: publicKey,
      online: nextOnline,
      lastSeen: lastSeen,
      lan: lan ?? (nextOnline ? this.lan : const []),
    );
  }
}

class FileEntry {
  final int index;
  final String path; // relative, '/'-separated
  final int size;
  final int mtime; // unix ms
  final String sha256;

  const FileEntry({required this.index, required this.path, required this.size, required this.mtime, required this.sha256});

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        index: j['index'] as int,
        path: j['path'] as String,
        size: j['size'] as int,
        mtime: (j['mtime'] ?? 0) as int,
        sha256: j['sha256'] as String,
      );

  Map<String, dynamic> toJson() => {'index': index, 'path': path, 'size': size, 'mtime': mtime, 'sha256': sha256};
}

class Offer {
  final String transferId;
  final String session;
  final String title;
  final int chunkSize;
  final int totalSize;
  final List<FileEntry> files;
  final List<String> dirs;
  final String ephemeralKey;
  final List<String> routes;
  final String relay;
  final String route; // 'lan' | 'relay'
  final DateTime createdAt;

  Offer({
    required this.transferId,
    required this.session,
    required this.title,
    required this.chunkSize,
    required this.totalSize,
    required this.files,
    required this.dirs,
    required this.ephemeralKey,
    required this.routes,
    required this.relay,
    this.route = 'relay',
    required this.createdAt,
  });

  factory Offer.fromJson(Map<String, dynamic> j) => Offer(
        transferId: j['transfer_id'] as String,
        session: j['session'] as String,
        title: (j['title'] ?? '') as String,
        chunkSize: j['chunk_size'] as int,
        totalSize: j['total_size'] as int,
        files: ((j['files'] ?? []) as List).map((e) => FileEntry.fromJson(e as Map<String, dynamic>)).toList(),
        dirs: ((j['dirs'] ?? []) as List).cast<String>(),
        ephemeralKey: j['ephemeral_key'] as String,
        routes: ((j['routes'] ?? []) as List).cast<String>(),
        relay: (j['relay'] ?? '') as String,
        route: (j['route'] ?? 'relay') as String,
        createdAt: _parseTime(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'session': session,
        'title': title,
        'chunk_size': chunkSize,
        'total_size': totalSize,
        'files': files.map((f) => f.toJson()).toList(),
        if (dirs.isNotEmpty) 'dirs': dirs,
        'ephemeral_key': ephemeralKey,
        'routes': routes,
        if (relay.isNotEmpty) 'relay': relay,
        'route': route,
        'created_at': createdAt.toUtc().toIso8601String(),
      };
}

class NeedRange {
  final int file;
  final int from;
  final int to; // exclusive
  const NeedRange(this.file, this.from, this.to);
  factory NeedRange.fromJson(Map<String, dynamic> j) => NeedRange(j['file'] as int, j['from'] as int, j['to'] as int);
  Map<String, dynamic> toJson() => {'file': file, 'from': from, 'to': to};
}

class Answer {
  final String transferId;
  final String session;
  final bool accept;
  final String reason;
  final String route;
  final List<NeedRange> need;
  const Answer(
      {required this.transferId, required this.session, required this.accept, this.reason = '', this.route = '', this.need = const []});

  factory Answer.fromJson(Map<String, dynamic> j) => Answer(
        transferId: j['transfer_id'] as String,
        session: j['session'] as String,
        accept: (j['accept'] ?? false) as bool,
        reason: (j['reason'] ?? '') as String,
        route: (j['route'] ?? '') as String,
        need: ((j['need'] ?? []) as List).map((e) => NeedRange.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'session': session,
        'accept': accept,
        if (reason.isNotEmpty) 'reason': reason,
        if (route.isNotEmpty) 'route': route,
        if (need.isNotEmpty) 'need': need.map((n) => n.toJson()).toList(),
      };
}

class Done {
  final String transferId;
  final String session;
  final bool ok;
  final String reason;
  final List<String> saved;
  const Done({required this.transferId, required this.session, required this.ok, this.reason = '', this.saved = const []});

  factory Done.fromJson(Map<String, dynamic> j) => Done(
        transferId: j['transfer_id'] as String,
        session: j['session'] as String,
        ok: (j['ok'] ?? false) as bool,
        reason: (j['reason'] ?? '') as String,
        saved: ((j['saved'] ?? []) as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'session': session,
        'ok': ok,
        if (reason.isNotEmpty) 'reason': reason,
        if (saved.isNotEmpty) 'saved': saved,
      };
}

class Cancel {
  final String transferId;
  final String reason;
  const Cancel(this.transferId, [this.reason = '']);
  factory Cancel.fromJson(Map<String, dynamic> j) => Cancel(j['transfer_id'] as String, (j['reason'] ?? '') as String);
  Map<String, dynamic> toJson() => {'transfer_id': transferId, if (reason.isNotEmpty) 'reason': reason};
}

/// Device-to-device payload of a "signal" envelope.
class Signal {
  final String kind; // offer | answer | done | cancel | webrtc
  final Offer? offer;
  final Answer? answer;
  final Done? done;
  final Cancel? cancel;
  final Map<String, dynamic>? webrtc;

  const Signal._(this.kind, {this.offer, this.answer, this.done, this.cancel, this.webrtc});
  factory Signal.offer(Offer o) => Signal._('offer', offer: o);
  factory Signal.answer(Answer a) => Signal._('answer', answer: a);
  factory Signal.done(Done d) => Signal._('done', done: d);
  factory Signal.cancel(Cancel c) => Signal._('cancel', cancel: c);
  factory Signal.webrtc(Map<String, dynamic> w) => Signal._('webrtc', webrtc: w);

  factory Signal.fromJson(Map<String, dynamic> j) {
    final k = j['kind'] as String? ?? '';
    final rawRtc = j['webrtc'];
    Map<String, dynamic>? rtc;
    if (rawRtc is Map<String, dynamic>) {
      rtc = rawRtc;
    } else if (rawRtc is Map) {
      rtc = rawRtc.map((key, value) => MapEntry('$key', value));
    }
    return Signal._(
      k,
      offer: j['offer'] != null ? Offer.fromJson(j['offer'] as Map<String, dynamic>) : null,
      answer: j['answer'] != null ? Answer.fromJson(j['answer'] as Map<String, dynamic>) : null,
      done: j['done'] != null ? Done.fromJson(j['done'] as Map<String, dynamic>) : null,
      cancel: j['cancel'] != null ? Cancel.fromJson(j['cancel'] as Map<String, dynamic>) : null,
      webrtc: rtc,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (offer != null) 'offer': offer!.toJson(),
        if (answer != null) 'answer': answer!.toJson(),
        if (done != null) 'done': done!.toJson(),
        if (cancel != null) 'cancel': cancel!.toJson(),
        if (webrtc != null) 'webrtc': webrtc,
      };
}

class RelayInfo {
  final String id;
  final String url; // '' = gateway base URL
  final String certSha256;
  final String region;
  const RelayInfo({required this.id, required this.url, this.certSha256 = '', this.region = ''});
  factory RelayInfo.fromJson(Map<String, dynamic> j) => RelayInfo(
        id: j['id'] as String,
        url: (j['url'] ?? '') as String,
        certSha256: (j['cert_sha256'] ?? '') as String,
        region: (j['region'] ?? '') as String,
      );
}

class RelayGrant {
  final List<RelayInfo> relays;
  final String ticket;
  const RelayGrant(this.relays, this.ticket);
  factory RelayGrant.fromJson(Map<String, dynamic> j) => RelayGrant(
        ((j['relays'] ?? []) as List).map((e) => RelayInfo.fromJson(e as Map<String, dynamic>)).toList(),
        j['ticket'] as String,
      );
}

int chunkCount(int size, int chunk) => size == 0 ? 0 : (size + chunk - 1) ~/ chunk;

int chunkLen(int size, int cs, int c) {
  final rem = size - c * cs;
  return rem < cs ? rem : cs;
}
