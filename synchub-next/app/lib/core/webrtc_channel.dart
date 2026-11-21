import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'proto.dart';

/// DataChannel label used by SyncHub WebRTC P2P chunk transport.
const String kWebRtcChannelLabel = 'synchub-chunks';

/// Maximum binary frame size sent over `RTCDataChannel` (`64 KiB`), safely
/// below SCTP message fragmentation limits across Chromium/libwebrtc builds.
const int kWebRtcMaxFrameBytes = 64 * 1024;

/// 16-byte big-endian frame header:
/// `[uint32 fileIdx, uint32 chunkIdx, uint32 totalSealedLen, uint32 offset]`.
const int kWebRtcFrameHeaderBytes = 16;

/// Maximum payload slice carried per binary frame (`65,520` bytes).
const int kWebRtcMaxSliceBytes = kWebRtcMaxFrameBytes - kWebRtcFrameHeaderBytes;

/// 8-byte big-endian ACK / NACK frame:
/// `[uint32 fileIdx, uint32 (chunkIdx | (nack ? 0x80000000 : 0))]`.
const int kWebRtcAckBytes = 8;

/// Flow-control high-water mark (`2 MiB`) for `RTCDataChannel.bufferedAmount`.
const int kWebRtcHighWaterMark = 2 * 1024 * 1024;

/// Flow-control low-water mark (`512 KiB`) for `bufferedAmountLowThreshold`.
const int kWebRtcLowWaterMark = 512 * 1024;

/// Callback invoked to send a `'webrtc'` signaling payload to [to] over the
/// Gateway WebSocket (`Signal(kind: 'webrtc', ...)`).
typedef WebRtcSendSignal = void Function(
  String to,
  Map<String, dynamic> webrtcPayload,
);

/// Callback invoked on the receiver when a complete sealed chunk `(fileIdx, chunkIdx)`
/// has been reassembled from DataChannel frames.
typedef WebRtcOnChunk = Future<void> Function(
  int fileIdx,
  int chunkIdx,
  Uint8List sealed,
);

// ---------------------------------------------------------------------------
// Pure Binary Framing, Reassembly & ACK/NACK Codec
// ---------------------------------------------------------------------------

/// Splits `(fileIdx, chunkIdx, sealedBytes)` into `<= 64 KiB` binary frames
/// prefixed with the 16-byte big-endian header
/// `[uint32 fileIdx, uint32 chunkIdx, uint32 totalSealedLen, uint32 offset]`.
List<Uint8List> encodeWebRtcChunkFrames(
  int fileIdx,
  int chunkIdx,
  Uint8List sealedBytes,
) {
  final total = sealedBytes.length;
  if (total == 0) {
    final frame = Uint8List(kWebRtcFrameHeaderBytes);
    ByteData.sublistView(frame)
      ..setUint32(0, fileIdx)
      ..setUint32(4, chunkIdx)
      ..setUint32(8, 0)
      ..setUint32(12, 0);
    return <Uint8List>[frame];
  }

  final frameCount = (total + kWebRtcMaxSliceBytes - 1) ~/ kWebRtcMaxSliceBytes;
  final out = <Uint8List>[];
  for (var i = 0; i < frameCount; i++) {
    final offset = i * kWebRtcMaxSliceBytes;
    final end = (offset + kWebRtcMaxSliceBytes < total)
        ? offset + kWebRtcMaxSliceBytes
        : total;
    final sliceLen = end - offset;
    final frame = Uint8List(kWebRtcFrameHeaderBytes + sliceLen);
    ByteData.sublistView(frame, 0, kWebRtcFrameHeaderBytes)
      ..setUint32(0, fileIdx)
      ..setUint32(4, chunkIdx)
      ..setUint32(8, total)
      ..setUint32(12, offset);
    frame.setRange(
      kWebRtcFrameHeaderBytes,
      kWebRtcFrameHeaderBytes + sliceLen,
      sealedBytes,
      offset,
    );
    out.add(frame);
  }
  return out;
}

/// Encodes an 8-byte big-endian ACK (`nack: false`) or NACK (`nack: true`,
/// setting bit 31 on `chunkIdx`).
Uint8List encodeWebRtcAck(int fileIdx, int chunkIdx, {bool nack = false}) {
  final frame = Uint8List(kWebRtcAckBytes);
  final rawChunk = nack ? ((chunkIdx & 0x7fffffff) | 0x80000000) : (chunkIdx & 0x7fffffff);
  ByteData.sublistView(frame)
    ..setUint32(0, fileIdx)
    ..setUint32(4, rawChunk);
  return frame;
}

/// Decodes an 8-byte big-endian ACK / NACK frame from the receiver.
({int fileIdx, int chunkIdx, bool isNack})? decodeWebRtcAck(Uint8List frame) {
  if (frame.length != kWebRtcAckBytes) return null;
  final bd = ByteData.sublistView(frame);
  final fileIdx = bd.getUint32(0);
  final rawChunk = bd.getUint32(4);
  final isNack = (rawChunk & 0x80000000) != 0;
  final chunkIdx = rawChunk & 0x7fffffff;
  return (fileIdx: fileIdx, chunkIdx: chunkIdx, isNack: isNack);
}

class _PartialChunkBuffer {
  final int totalLen;
  final Uint8List buffer;
  final Set<int> seenOffsets = <int>{};
  int receivedBytes = 0;

  _PartialChunkBuffer(this.totalLen) : buffer = Uint8List(totalLen);
}

/// Stateful reassembler for `<= 64 KiB` WebRTC chunk frames.
class WebRtcFrameReassembler {
  final int maxSealedBytes;
  final int maxConcurrentChunks;
  final Map<int, _PartialChunkBuffer> _partials = <int, _PartialChunkBuffer>{};

  WebRtcFrameReassembler({
    this.maxSealedBytes = kMaxChunkSize + kAeadOverhead,
    this.maxConcurrentChunks = 64,
  });

  int get pendingCount => _partials.length;

  static int _key(int fileIdx, int chunkIdx) => (fileIdx << 31) ^ chunkIdx;

  void clear() => _partials.clear();

  /// Feeds one binary [frame]. Returns `(fileIdx, chunkIdx, sealed)` as soon as
  /// all slices of that chunk have arrived; returns `null` if still incomplete.
  /// Throws [FormatException] on malformed or out-of-bounds headers.
  ({int fileIdx, int chunkIdx, Uint8List sealed})? addFrame(Uint8List frame) {
    if (frame.length < kWebRtcFrameHeaderBytes) {
      throw FormatException('webrtc frame too short (${frame.length} bytes)');
    }
    final bd = ByteData.sublistView(frame, 0, kWebRtcFrameHeaderBytes);
    final fileIdx = bd.getUint32(0);
    final chunkIdx = bd.getUint32(4);
    final totalLen = bd.getUint32(8);
    final offset = bd.getUint32(12);
    final sliceLen = frame.length - kWebRtcFrameHeaderBytes;

    if (totalLen > maxSealedBytes) {
      throw FormatException('webrtc chunk totalLen $totalLen > $maxSealedBytes');
    }
    if (offset + sliceLen > totalLen) {
      throw FormatException(
        'webrtc slice out of range (offset=$offset + len=$sliceLen > total=$totalLen)',
      );
    }
    if (totalLen == 0) {
      if (offset != 0 || sliceLen != 0) {
        throw const FormatException('non-empty slice for zero-length chunk');
      }
      return (fileIdx: fileIdx, chunkIdx: chunkIdx, sealed: Uint8List(0));
    }
    if (sliceLen == 0) {
      return null;
    }

    final k = _key(fileIdx, chunkIdx);
    var partial = _partials[k];
    if (partial == null || partial.totalLen != totalLen) {
      if (partial == null && _partials.length >= maxConcurrentChunks) {
        _partials.remove(_partials.keys.first);
      }
      partial = _PartialChunkBuffer(totalLen);
      _partials[k] = partial;
    }

    if (partial.seenOffsets.add(offset)) {
      partial.buffer.setRange(
        offset,
        offset + sliceLen,
        frame,
        kWebRtcFrameHeaderBytes,
      );
      partial.receivedBytes += sliceLen;
    }

    if (partial.receivedBytes >= totalLen) {
      _partials.remove(k);
      return (fileIdx: fileIdx, chunkIdx: chunkIdx, sealed: partial.buffer);
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Gateway /api/v1/ice Fetcher & Cache
// ---------------------------------------------------------------------------

const List<Map<String, dynamic>> _fallbackIceServers = <Map<String, dynamic>>[
  <String, dynamic>{
    'urls': <String>['stun:stun.cloudflare.com:3478'],
  },
];

/// Fetches and caches TURN/STUN credentials from `GET /api/v1/ice`.
class WebRtcIceCache {
  String gatewayBase;
  String token;
  final Duration cacheTtl;
  final HttpClient _http;

  List<Map<String, dynamic>>? _cached;
  DateTime? _expiresAt;

  WebRtcIceCache({
    required String gatewayBase,
    required this.token,
    this.cacheTtl = const Duration(minutes: 5),
    HttpClient? httpClient,
  })  : gatewayBase = gatewayBase.replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 8)
              ..idleTimeout = const Duration(seconds: 30));

  Future<List<Map<String, dynamic>>> getIceServers() async {
    final now = DateTime.now();
    if (_cached != null && _expiresAt != null && now.isBefore(_expiresAt!)) {
      return _cached!;
    }
    if (gatewayBase.isEmpty) {
      return _fallbackIceServers;
    }
    try {
      final req = await _http
          .getUrl(Uri.parse('$gatewayBase/api/v1/ice'))
          .timeout(const Duration(seconds: 6));
      if (token.isNotEmpty) {
        req.headers.set('authorization', 'Bearer $token');
      }
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 6))) {
        builder.add(chunk);
        if (builder.length > 65536) break;
      }
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
        final rawList = (j['ice_servers'] ?? j['iceServers']) as List?;
        if (rawList != null && rawList.isNotEmpty) {
          final parsed = <Map<String, dynamic>>[];
          for (final item in rawList) {
            if (item is! Map) continue;
            final urlsRaw = item['urls'];
            final urls = urlsRaw is List
                ? urlsRaw.map((e) => '$e').where((s) => s.isNotEmpty).toList()
                : (urlsRaw is String && urlsRaw.isNotEmpty ? <String>[urlsRaw] : <String>[]);
            if (urls.isEmpty) continue;
            final entry = <String, dynamic>{'urls': urls};
            final user = item['username'] as String?;
            final cred = item['credential'] as String?;
            if (user != null && user.isNotEmpty) entry['username'] = user;
            if (cred != null && cred.isNotEmpty) entry['credential'] = cred;
            parsed.add(entry);
          }
          if (parsed.isNotEmpty) {
            _cached = parsed;
            _expiresAt = now.add(cacheTtl);
            return parsed;
          }
        }
      }
    } catch (_) {
      // Fall back to public STUN if `/api/v1/ice` is unreachable.
    }
    return _fallbackIceServers;
  }

  Map<String, dynamic> buildPeerConfiguration(List<Map<String, dynamic>> iceServers) =>
      <String, dynamic>{
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
      };

  void close() => _http.close(force: true);
}

// ---------------------------------------------------------------------------
// Signaling Payload Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> buildWebRtcSdpPayload({
  required String transferId,
  required String session,
  required RTCSessionDescription description,
}) =>
    <String, dynamic>{
      'transfer_id': transferId,
      'session': session,
      'subtype': 'sdp',
      'sdp': <String, dynamic>{
        'type': description.type ?? '',
        'sdp': description.sdp ?? '',
      },
    };

Map<String, dynamic> buildWebRtcIcePayload({
  required String transferId,
  required String session,
  required RTCIceCandidate candidate,
}) =>
    <String, dynamic>{
      'transfer_id': transferId,
      'session': session,
      'subtype': 'ice',
      'candidate': <String, dynamic>{
        'candidate': candidate.candidate ?? '',
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      },
    };

RTCIceCandidate? _parseIceCandidate(Map<String, dynamic>? m) {
  if (m == null) return null;
  final cand = (m['candidate'] as String?) ?? '';
  if (cand.isEmpty) return null;
  final sdpMid = m['sdpMid'] as String?;
  final idxRaw = m['sdpMLineIndex'];
  final sdpMLineIndex = idxRaw is int ? idxRaw : (idxRaw is num ? idxRaw.toInt() : null);
  return RTCIceCandidate(cand, sdpMid, sdpMLineIndex);
}

// ---------------------------------------------------------------------------
// Sender Side: WebRtcChunkPusher implements ChunkPusher
// ---------------------------------------------------------------------------

/// WebRTC DataChannel sender implementing [ChunkPusher] (`name => 'webrtc'`).
///
/// Splits sealed chunks into `<= 64 KiB` frames, applies `2 MiB`
/// `bufferedAmount` backpressure, and resolves `put(...)` only once the
/// receiver sends back an 8-byte ACK after `_Sink.accept(...)` succeeds.
class WebRtcChunkPusher implements ChunkPusher {
  final String peerId;
  final String transferId;
  final String session;
  final WebRtcSendSignal sendSignal;
  final Duration ackTimeout;
  final void Function(String message)? onLog;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  bool _closed = false;
  bool _remoteDescSet = false;
  final List<RTCIceCandidate> _queuedRemoteCandidates = <RTCIceCandidate>[];
  final Completer<bool> _openCompleter = Completer<bool>();
  final Map<String, Completer<void>> _pendingAcks = <String, Completer<void>>{};
  Completer<void>? _bufferLowWaiter;
  Future<void> _sendChain = Future<void>.value();

  WebRtcChunkPusher._({
    required this.peerId,
    required this.transferId,
    required this.session,
    required this.sendSignal,
    required this.ackTimeout,
    this.onLog,
  });

  @override
  String get name => 'webrtc';

  bool get isOpen =>
      !_closed && _dc?.state == RTCDataChannelState.RTCDataChannelOpen;

  void _log(String msg) => onLog?.call('[webrtc:send] $msg');

  /// Negotiates a WebRTC DataChannel session with [peerId].
  ///
  /// [onCreated] is invoked synchronously once the session is ready to accept
  /// incoming `'webrtc'` answer/ICE signals via [handleSignal], BEFORE sending
  /// the SDP offer over the signaling channel so zero trickle-ICE messages can
  /// race ahead of registration.
  ///
  /// Returns `null` cleanly if `flutter_webrtc` is unavailable on the host
  /// platform or if the DataChannel does not open within [connectTimeout].
  static Future<WebRtcChunkPusher?> connect({
    required String peerId,
    required String transferId,
    required String session,
    required WebRtcSendSignal sendSignal,
    List<Map<String, dynamic>> iceServers = _fallbackIceServers,
    Duration connectTimeout = const Duration(seconds: 12),
    Duration ackTimeout = const Duration(seconds: 60),
    void Function(WebRtcChunkPusher session)? onCreated,
    void Function(String message)? onLog,
  }) async {
    final pusher = WebRtcChunkPusher._(
      peerId: peerId,
      transferId: transferId,
      session: session,
      sendSignal: sendSignal,
      ackTimeout: ackTimeout,
      onLog: onLog,
    );
    onCreated?.call(pusher);
    final ok = await pusher._negotiate(
      iceServers: iceServers,
      connectTimeout: connectTimeout,
    );
    if (!ok) {
      await pusher.close();
      return null;
    }
    return pusher;
  }

  Future<bool> _negotiate({
    required List<Map<String, dynamic>> iceServers,
    required Duration connectTimeout,
  }) async {
    try {
      final pc = await createPeerConnection(<String, dynamic>{
        'iceServers': iceServers.isEmpty ? _fallbackIceServers : iceServers,
        'sdpSemantics': 'unified-plan',
      });
      if (_closed) {
        await pc.close();
        await pc.dispose();
        return false;
      }
      _pc = pc;

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        if (_closed || (candidate.candidate?.isEmpty ?? true)) return;
        try {
          sendSignal(
            peerId,
            buildWebRtcIcePayload(
              transferId: transferId,
              session: session,
              candidate: candidate,
            ),
          );
        } catch (_) {}
      };

      pc.onConnectionState = (RTCPeerConnectionState state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (!_openCompleter.isCompleted &&
              state != RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            _openCompleter.complete(false);
          }
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
            _failPendingAcks('webrtc peer connection $state');
          }
        }
      };

      final dcInit = RTCDataChannelInit()
        ..ordered = true
        ..binaryType = 'binary';
      final dc = await pc.createDataChannel(kWebRtcChannelLabel, dcInit);
      _dc = dc;
      try {
        dc.bufferedAmountLowThreshold = kWebRtcLowWaterMark;
      } catch (_) {}

      dc.onBufferedAmountLow = (_) {
        final w = _bufferLowWaiter;
        if (w != null && !w.isCompleted) w.complete();
      };

      dc.onDataChannelState = (RTCDataChannelState state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          if (!_openCompleter.isCompleted) _openCompleter.complete(true);
        } else if (state == RTCDataChannelState.RTCDataChannelClosing ||
            state == RTCDataChannelState.RTCDataChannelClosed) {
          if (!_openCompleter.isCompleted) _openCompleter.complete(false);
          _failPendingAcks('webrtc data channel closed');
        }
      };

      dc.onMessage = (RTCDataChannelMessage msg) {
        if (!msg.isBinary) return;
        final ack = decodeWebRtcAck(msg.binary);
        if (ack == null) return;
        final key = '${ack.fileIdx}:${ack.chunkIdx}';
        final waiter = _pendingAcks.remove(key);
        if (waiter == null || waiter.isCompleted) return;
        if (ack.isNack) {
          waiter.completeError(
            ApiException(502, 'webrtc receiver NACK for chunk $key'),
          );
        } else {
          waiter.complete();
        }
      };

      if (dc.state == RTCDataChannelState.RTCDataChannelOpen &&
          !_openCompleter.isCompleted) {
        _openCompleter.complete(true);
      }

      final offer = await pc.createOffer(<String, dynamic>{
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });
      await pc.setLocalDescription(offer);

      sendSignal(
        peerId,
        buildWebRtcSdpPayload(
          transferId: transferId,
          session: session,
          description: offer,
        ),
      );

      final opened = await _openCompleter.future.timeout(
        connectTimeout,
        onTimeout: () => false,
      );
      if (opened) {
        _log('DataChannel open for $transferId/$session');
      }
      return opened;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _log('platform unavailable: ${e.message}');
      return false;
    } on UnimplementedError {
      return false;
    } catch (e) {
      _log('negotiate failed: $e');
      return false;
    }
  }

  /// Processes an incoming `'webrtc'` signal (`sdp` answer or `ice` candidate)
  /// belonging to `(transferId, session)`.
  Future<void> handleSignal(Map<String, dynamic> payload) async {
    if (_closed) return;
    final pc = _pc;
    if (pc == null) return;

    final subtype = payload['subtype'] as String? ?? '';
    try {
      if (subtype == 'sdp') {
        final sdpMap = payload['sdp'] as Map<String, dynamic>?;
        if (sdpMap == null) return;
        final type = sdpMap['type'] as String? ?? '';
        final sdp = sdpMap['sdp'] as String? ?? '';
        if (type != 'answer' || sdp.isEmpty) return;
        await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
        _remoteDescSet = true;
        final queued = List<RTCIceCandidate>.from(_queuedRemoteCandidates);
        _queuedRemoteCandidates.clear();
        for (final c in queued) {
          await pc.addCandidate(c);
        }
      } else if (subtype == 'ice') {
        final cand = _parseIceCandidate(payload['candidate'] as Map<String, dynamic>?);
        if (cand == null) return;
        if (_remoteDescSet) {
          await pc.addCandidate(cand);
        } else if (_queuedRemoteCandidates.length < 64) {
          _queuedRemoteCandidates.add(cand);
        }
      }
    } catch (e) {
      _log('signal error ($subtype): $e');
    }
  }

  Future<int> _currentBufferedAmount(RTCDataChannel dc) async {
    final cached = dc.bufferedAmount;
    if (cached != null) return cached;
    try {
      return await dc.getBufferedAmount();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _waitForBackpressure(RTCDataChannel dc) async {
    var loops = 0;
    while (!_closed && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      final buffered = await _currentBufferedAmount(dc);
      if (buffered <= kWebRtcHighWaterMark) return;
      if (++loops > 400) {
        // ~10s stalled send buffer
        throw TimeoutException('webrtc send buffer stalled ($buffered bytes)');
      }
      final waiter = Completer<void>();
      _bufferLowWaiter = waiter;
      await Future.any<void>(<Future<void>>[
        waiter.future,
        Future<void>.delayed(const Duration(milliseconds: 25)),
      ]);
      if (identical(_bufferLowWaiter, waiter)) {
        _bufferLowWaiter = null;
      }
    }
  }

  @override
  Future<void> put(
    String tid,
    String session,
    int file,
    int chunk,
    Uint8List data,
  ) async {
    final dc = _dc;
    if (_closed || dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('webrtc channel is not open');
    }

    final key = '$file:$chunk';
    final ackCompleter = Completer<void>();
    _pendingAcks[key] = ackCompleter;

    final frames = encodeWebRtcChunkFrames(file, chunk, data);

    Future<void> sendFrames() async {
      for (final frame in frames) {
        if (_closed || dc.state != RTCDataChannelState.RTCDataChannelOpen) {
          throw StateError('webrtc channel closed mid-chunk');
        }
        await _waitForBackpressure(dc);
        await dc.send(RTCDataChannelMessage.fromBinary(frame));
      }
    }

    // Serialize frame bursts across concurrent chunk workers so each chunk's
    // slices traverse SCTP contiguously while ACKs overlap in flight.
    final prev = _sendChain;
    final done = Completer<void>();
    _sendChain = done.future;
    try {
      await prev;
      await sendFrames();
    } catch (e) {
      _pendingAcks.remove(key);
      if (!done.isCompleted) done.complete();
      rethrow;
    }
    if (!done.isCompleted) done.complete();

    try {
      await ackCompleter.future.timeout(ackTimeout);
    } finally {
      _pendingAcks.remove(key);
    }
  }

  void _failPendingAcks(String reason) {
    final waiters = _pendingAcks.values.toList();
    _pendingAcks.clear();
    for (final w in waiters) {
      if (!w.isCompleted) {
        w.completeError(StateError(reason));
      }
    }
    final bw = _bufferLowWaiter;
    if (bw != null && !bw.isCompleted) bw.complete();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_openCompleter.isCompleted) _openCompleter.complete(false);
    _failPendingAcks('webrtc session closed');
    final dc = _dc;
    _dc = null;
    final pc = _pc;
    _pc = null;
    try {
      await dc?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
    try {
      await pc?.dispose();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Receiver Side: WebRtcReceiverSession
// ---------------------------------------------------------------------------

/// Accepts an incoming SDP offer + trickle ICE candidates for `(transferId, session)`,
/// reassembles framed chunks from `synchub-chunks`, invokes [onChunk], and sends
/// an 8-byte ACK (or NACK) back over the DataChannel.
class WebRtcReceiverSession {
  final String peerId;
  final String transferId;
  final String session;
  final WebRtcSendSignal sendSignal;
  final WebRtcOnChunk onChunk;
  final List<Map<String, dynamic>> iceServers;
  final void Function(String message)? onLog;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  bool _closed = false;
  bool _remoteDescSet = false;
  final List<RTCIceCandidate> _queuedRemoteCandidates = <RTCIceCandidate>[];
  final WebRtcFrameReassembler _reassembler = WebRtcFrameReassembler();
  Future<void> _signalChain = Future<void>.value();

  WebRtcReceiverSession({
    required this.peerId,
    required this.transferId,
    required this.session,
    required this.sendSignal,
    required this.onChunk,
    this.iceServers = _fallbackIceServers,
    this.onLog,
  });

  bool get isClosed => _closed;

  /// Pre-initializes the underlying native [RTCPeerConnection] so callers can
  /// confirm `flutter_webrtc` is operational on this platform before advertising
  /// `'webrtc'` in `Answer`.
  Future<bool> warmUp() => _ensurePeerConnection();

  void _log(String msg) => onLog?.call('[webrtc:recv] $msg');

  /// Feeds an incoming `'webrtc'` signal (`sdp` offer or `ice` candidate).
  /// Returns `false` if `flutter_webrtc` is unavailable on this platform.
  Future<bool> handleSignal(Map<String, dynamic> payload) {
    final prev = _signalChain;
    final next = Completer<void>();
    _signalChain = next.future;
    return prev.then((_) async {
      try {
        return await _handleSignalSerial(payload);
      } finally {
        if (!next.isCompleted) next.complete();
      }
    });
  }

  Future<bool> _ensurePeerConnection() async {
    if (_pc != null) return true;
    try {
      final pc = await createPeerConnection(<String, dynamic>{
        'iceServers': iceServers.isEmpty ? _fallbackIceServers : iceServers,
        'sdpSemantics': 'unified-plan',
      });
      if (_closed) {
        await pc.close();
        await pc.dispose();
        return false;
      }
      _pc = pc;

      pc.onIceCandidate = (RTCIceCandidate candidate) {
        if (_closed || (candidate.candidate?.isEmpty ?? true)) return;
        try {
          sendSignal(
            peerId,
            buildWebRtcIcePayload(
              transferId: transferId,
              session: session,
              candidate: candidate,
            ),
          );
        } catch (_) {}
      };

      pc.onDataChannel = (RTCDataChannel channel) {
        if (channel.label != null &&
            channel.label!.isNotEmpty &&
            channel.label != kWebRtcChannelLabel) {
          return;
        }
        _attachDataChannel(channel);
      };

      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _log('platform unavailable: ${e.message}');
      return false;
    } on UnimplementedError {
      return false;
    } catch (e) {
      _log('createPeerConnection failed: $e');
      return false;
    }
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dc = channel;
    channel.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _log('DataChannel open for $transferId/$session');
      } else if (state == RTCDataChannelState.RTCDataChannelClosing ||
          state == RTCDataChannelState.RTCDataChannelClosed) {
        _reassembler.clear();
      }
    };

    channel.onMessage = (RTCDataChannelMessage msg) {
      if (_closed || !msg.isBinary) return;
      final frame = msg.binary;
      ({int fileIdx, int chunkIdx, Uint8List sealed})? complete;
      try {
        complete = _reassembler.addFrame(frame);
      } catch (e) {
        _log('frame decode error: $e');
        if (frame.length >= 8) {
          final bd = ByteData.sublistView(frame, 0, 8);
          unawaited(_sendAck(channel, bd.getUint32(0), bd.getUint32(4), nack: true));
        }
        return;
      }
      if (complete == null) return;
      final f = complete.fileIdx;
      final c = complete.chunkIdx;
      final sealed = complete.sealed;
      unawaited(() async {
        try {
          await onChunk(f, c, sealed);
          await _sendAck(channel, f, c, nack: false);
        } catch (e) {
          _log('chunk accept failed ($f/$c): $e');
          await _sendAck(channel, f, c, nack: true);
        }
      }());
    };
  }

  Future<void> _sendAck(
    RTCDataChannel channel,
    int fileIdx,
    int chunkIdx, {
    required bool nack,
  }) async {
    if (_closed || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    try {
      final ackBytes = encodeWebRtcAck(fileIdx, chunkIdx, nack: nack);
      await channel.send(RTCDataChannelMessage.fromBinary(ackBytes));
    } catch (_) {}
  }

  Future<bool> _handleSignalSerial(Map<String, dynamic> payload) async {
    if (_closed) return false;
    final subtype = payload['subtype'] as String? ?? '';
    if (subtype == 'sdp') {
      final sdpMap = payload['sdp'] as Map<String, dynamic>?;
      if (sdpMap == null) return false;
      final type = sdpMap['type'] as String? ?? '';
      final sdp = sdpMap['sdp'] as String? ?? '';
      if (type != 'offer' || sdp.isEmpty) return false;

      if (!await _ensurePeerConnection()) return false;
      final pc = _pc;
      if (pc == null || _closed) return false;

      try {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
        _remoteDescSet = true;
        final queued = List<RTCIceCandidate>.from(_queuedRemoteCandidates);
        _queuedRemoteCandidates.clear();
        for (final cand in queued) {
          await pc.addCandidate(cand);
        }
        final answer = await pc.createAnswer(<String, dynamic>{
          'offerToReceiveAudio': false,
          'offerToReceiveVideo': false,
        });
        await pc.setLocalDescription(answer);
        sendSignal(
          peerId,
          buildWebRtcSdpPayload(
            transferId: transferId,
            session: session,
            description: answer,
          ),
        );
        return true;
      } catch (e) {
        _log('answer negotiation failed: $e');
        return false;
      }
    } else if (subtype == 'ice') {
      final cand = _parseIceCandidate(payload['candidate'] as Map<String, dynamic>?);
      if (cand == null) return false;
      if (_remoteDescSet && _pc != null) {
        try {
          await _pc!.addCandidate(cand);
          return true;
        } catch (e) {
          _log('addCandidate failed: $e');
          return false;
        }
      } else {
        if (_queuedRemoteCandidates.length < 64) {
          _queuedRemoteCandidates.add(cand);
        }
        return true;
      }
    }
    return false;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reassembler.clear();
    _queuedRemoteCandidates.clear();
    final dc = _dc;
    _dc = null;
    final pc = _pc;
    _pc = null;
    try {
      await dc?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
    try {
      await pc?.dispose();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Session Router (`WebRtcCoordinator`) for Seamless Engine Integration
// ---------------------------------------------------------------------------

/// High-level coordinator managing ICE caching, sender/receiver sessions, and
/// early trickle-ICE buffering keyed by `"$transferId:$session"`.
class WebRtcCoordinator {
  final WebRtcIceCache iceCache;
  final WebRtcSendSignal sendSignal;
  final void Function(String message)? onLog;

  final Map<String, WebRtcChunkPusher> _senders = <String, WebRtcChunkPusher>{};
  final Map<String, WebRtcReceiverSession> _receivers = <String, WebRtcReceiverSession>{};
  final Map<String, List<(String from, Map<String, dynamic> payload)>> _earlySignals =
      <String, List<(String, Map<String, dynamic>)>>{};
  bool? _supportedCache;

  WebRtcCoordinator({
    required String gatewayBase,
    required String token,
    required this.sendSignal,
    this.onLog,
    HttpClient? httpClient,
  }) : iceCache = WebRtcIceCache(
          gatewayBase: gatewayBase,
          token: token,
          httpClient: httpClient,
        );

  static String _key(String transferId, String session) => '$transferId:$session';

  /// Probes once whether the native `flutter_webrtc` plugin is available in the
  /// current runtime (returns `false` immediately in headless `flutter test`).
  Future<bool> isSupported() async {
    if (_supportedCache != null) return _supportedCache!;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _supportedCache = false;
      return false;
    }
    try {
      final pc = await createPeerConnection(const <String, dynamic>{
        'iceServers': <Map<String, dynamic>>[],
        'sdpSemantics': 'unified-plan',
      });
      await pc.close();
      await pc.dispose();
      _supportedCache = true;
      return true;
    } catch (_) {
      _supportedCache = false;
      return false;
    }
  }

  void updateCredentials({required String gatewayBase, required String token}) {
    iceCache.gatewayBase = gatewayBase.replaceAll(RegExp(r'/+$'), '');
    iceCache.token = token;
  }

  /// Attempts to open a P2P WebRTC `ChunkPusher` for `(transferId, session)`.
  /// Returns `null` on timeout or unsupported platform so `Engine` seamlessly
  /// falls back to `relay:la` -> `relay:main`.
  Future<WebRtcChunkPusher?> connectSender({
    required String peerId,
    required String transferId,
    required String session,
    Duration connectTimeout = const Duration(seconds: 12),
    Duration ackTimeout = const Duration(seconds: 60),
  }) async {
    final key = _key(transferId, session);
    final iceServers = await iceCache.getIceServers();
    final pusher = await WebRtcChunkPusher.connect(
      peerId: peerId,
      transferId: transferId,
      session: session,
      sendSignal: sendSignal,
      iceServers: iceServers,
      connectTimeout: connectTimeout,
      ackTimeout: ackTimeout,
      onLog: onLog,
      onCreated: (s) {
        _senders[key] = s;
      },
    );
    if (pusher == null) {
      _senders.remove(key);
    }
    return pusher;
  }

  /// Registers a receiver session for `(transferId, session)` and replays any
  /// `'webrtc'` signals that arrived right after `offer`. Returns `null` if
  /// `flutter_webrtc` is unavailable on this runtime.
  Future<WebRtcReceiverSession?> registerReceiver({
    required String peerId,
    required String transferId,
    required String session,
    required WebRtcOnChunk onChunk,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final key = _key(transferId, session);
    await _receivers.remove(key)?.close();
    final iceServers = await iceCache.getIceServers();
    final recv = WebRtcReceiverSession(
      peerId: peerId,
      transferId: transferId,
      session: session,
      sendSignal: sendSignal,
      onChunk: onChunk,
      iceServers: iceServers,
      onLog: onLog,
    );
    if (!await recv.warmUp()) {
      await recv.close();
      return null;
    }
    _receivers[key] = recv;

    final early = _earlySignals.remove(key);
    if (early != null) {
      for (final (from, pl) in early) {
        if (from == peerId) {
          await recv.handleSignal(pl);
        }
      }
    }
    return recv;
  }

  /// Routes an incoming `Signal(kind: 'webrtc')` payload from [from].
  Future<void> onSignal(String from, Map<String, dynamic> payload) async {
    final tid = payload['transfer_id'] as String? ?? '';
    final session = payload['session'] as String? ?? '';
    if (tid.isEmpty || session.isEmpty) return;
    final key = _key(tid, session);

    final sender = _senders[key];
    if (sender != null && sender.peerId == from) {
      await sender.handleSignal(payload);
      return;
    }

    final receiver = _receivers[key];
    if (receiver != null && receiver.peerId == from) {
      await receiver.handleSignal(payload);
      return;
    }

    // Buffer early offer/ICE signals that arrive slightly before _handleOffer
    // finishes registering the receiver session.
    if (_earlySignals.length >= 32) {
      _earlySignals.remove(_earlySignals.keys.first);
    }
    final list = _earlySignals.putIfAbsent(
      key,
      () => <(String, Map<String, dynamic>)>[],
    );
    if (list.length < 32) {
      list.add((from, payload));
    }
  }

  /// Closes and removes any active sender/receiver session for `(transferId, session)`.
  Future<void> closeSession(String transferId, [String? session]) async {
    if (session != null) {
      final key = _key(transferId, session);
      _earlySignals.remove(key);
      await _senders.remove(key)?.close();
      await _receivers.remove(key)?.close();
      return;
    }
    final prefix = '$transferId:';
    final sKeys = _senders.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in sKeys) {
      await _senders.remove(k)?.close();
    }
    final rKeys = _receivers.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in rKeys) {
      await _receivers.remove(k)?.close();
    }
    _earlySignals.removeWhere((k, _) => k.startsWith(prefix));
  }

  Future<void> closeAll() async {
    _earlySignals.clear();
    final senders = _senders.values.toList();
    _senders.clear();
    final receivers = _receivers.values.toList();
    _receivers.clear();
    for (final s in senders) {
      await s.close();
    }
    for (final r in receivers) {
      await r.close();
    }
    iceCache.close();
  }
}
