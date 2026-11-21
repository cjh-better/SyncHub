// End-to-end chunk encryption, byte-compatible with
// server/gateway/internal/e2e (see protocol/PROTOCOL.md §6 and
// protocol/test-vectors.json).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
const _info = 'synchub-e2e-v1';

class DeviceKey {
  final SimpleKeyPair pair;
  final Uint8List privateBytes;
  final Uint8List publicBytes;
  DeviceKey._(this.pair, this.privateBytes, this.publicBytes);

  String get publicB64 => base64.encode(publicBytes);
  String get privateB64 => base64.encode(privateBytes);

  static Future<DeviceKey> fromPrivate(List<int> priv) async {
    final kp = await _x25519.newKeyPairFromSeed(priv);
    final pub = await kp.extractPublicKey();
    return DeviceKey._(kp, Uint8List.fromList(priv), Uint8List.fromList(pub.bytes));
  }

  static Future<DeviceKey> fromPrivateB64(String b64) => fromPrivate(base64.decode(b64));

  static Future<DeviceKey> generate() async {
    final kp = await _x25519.newKeyPair();
    return fromPrivate(await kp.extractPrivateKeyBytes());
  }
}

String fingerprint(String pubB64) {
  final d = hash.sha256.convert(base64.decode(pubB64)).bytes.sublist(0, 9);
  final s = base64.encode(d).replaceAll('=', '');
  return '${s.substring(0, 4)}-${s.substring(4, 8)}-${s.substring(8, 12)}';
}

/// AEAD bound to one transfer session.
class SessionCipher {
  final SecretKey _key;
  final Uint8List keyBytes;
  final String transferId;
  final String session;
  SessionCipher._(this.keyBytes, this.transferId, this.session) : _key = SecretKey(keyBytes);

  /// Rebuild from raw key bytes (used inside crypto worker isolates).
  factory SessionCipher.fromKey(Uint8List key, String tid, String session) => SessionCipher._(key, tid, session);

  static Future<SessionCipher> _derive(List<int> ikm, String tid, String session) async {
    final k = await _hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: utf8.encode('$tid|$session'),
      info: utf8.encode(_info),
    );
    return SessionCipher._(Uint8List.fromList(await k.extractBytes()), tid, session);
  }

  Future<List<int>> _dh(SimpleKeyPair kp, List<int> pub) async =>
      (await _x25519.sharedSecretKey(keyPair: kp, remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519)))
          .extractBytes();

  /// Sender side: returns (ephemeral public key b64, cipher).
  static Future<(String, SessionCipher)> sender(DeviceKey me, String receiverPubB64, String tid, String session,
      {List<int>? ephemeralPrivate}) async {
    final eph = ephemeralPrivate != null ? await DeviceKey.fromPrivate(ephemeralPrivate) : await DeviceKey.generate();
    final rpub = base64.decode(receiverPubB64);
    final a = await (await _x25519.sharedSecretKey(
            keyPair: eph.pair, remotePublicKey: SimplePublicKey(rpub, type: KeyPairType.x25519)))
        .extractBytes();
    final b = await (await _x25519.sharedSecretKey(
            keyPair: me.pair, remotePublicKey: SimplePublicKey(rpub, type: KeyPairType.x25519)))
        .extractBytes();
    return (eph.publicB64, await _derive([...a, ...b], tid, session));
  }

  /// Receiver side.
  static Future<SessionCipher> receiver(
      DeviceKey me, String ephemeralPubB64, String senderPubB64, String tid, String session) async {
    final tmp = SessionCipher._(Uint8List(32), tid, session);
    final a = await tmp._dh(me.pair, base64.decode(ephemeralPubB64));
    final b = await tmp._dh(me.pair, base64.decode(senderPubB64));
    return _derive([...a, ...b], tid, session);
  }

  (List<int>, List<int>) _nonceAad(int file, int chunk) {
    final n = ByteData(12)
      ..setUint32(0, file)
      ..setUint64(4, chunk);
    final aad = utf8.encode('synchub/v1|$transferId|$session|$file|$chunk');
    return (n.buffer.asUint8List(), aad);
  }

  Future<Uint8List> seal(int file, int chunk, List<int> plain) async {
    final (nonce, aad) = _nonceAad(file, chunk);
    final box = await _aes.encrypt(plain, secretKey: _key, nonce: nonce, aad: aad);
    final out = Uint8List(box.cipherText.length + 16);
    out.setAll(0, box.cipherText);
    out.setAll(box.cipherText.length, box.mac.bytes);
    return out;
  }

  Future<Uint8List> open(int file, int chunk, List<int> sealed) async {
    if (sealed.length < 16) throw const ChunkAuthException();
    final (nonce, aad) = _nonceAad(file, chunk);
    final ct = sealed.sublist(0, sealed.length - 16);
    final mac = Mac(sealed.sublist(sealed.length - 16));
    try {
      final p = await _aes.decrypt(SecretBox(ct, nonce: nonce, mac: mac), secretKey: _key, aad: aad);
      return Uint8List.fromList(p);
    } on SecretBoxAuthenticationError {
      throw const ChunkAuthException();
    }
  }
}

class ChunkAuthException implements Exception {
  const ChunkAuthException();
  @override
  String toString() => 'chunk authentication failed';
}
