import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synchub/core/e2e.dart';

List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('../protocol/test-vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('public keys and fingerprint match Go', () async {
    final s = await DeviceKey.fromPrivate(_hex(v['sender_private_hex']));
    final r = await DeviceKey.fromPrivate(_hex(v['receiver_private_hex']));
    expect(s.publicB64, v['sender_public_b64']);
    expect(r.publicB64, v['receiver_public_b64']);
    expect(fingerprint(r.publicB64), v['receiver_fingerprint']);
  });

  test('sender derivation + AES-GCM produce Go ciphertexts byte-for-byte', () async {
    final s = await DeviceKey.fromPrivate(_hex(v['sender_private_hex']));
    final (eph, c) = await SessionCipher.sender(s, v['receiver_public_b64'], v['transfer_id'], v['session'],
        ephemeralPrivate: _hex(v['ephemeral_private_hex']));
    expect(eph, v['ephemeral_public_b64']);
    for (final ch in (v['chunks'] as List).cast<Map<String, dynamic>>()) {
      final ct = await c.seal(ch['file'], ch['chunk'], _hex(ch['plaintext_hex']));
      expect(_toHex(ct), ch['ciphertext_hex']);
    }
  });

  test('receiver opens Go ciphertexts and rejects tampering', () async {
    final r = await DeviceKey.fromPrivate(_hex(v['receiver_private_hex']));
    final c = await SessionCipher.receiver(
        r, v['ephemeral_public_b64'], v['sender_public_b64'], v['transfer_id'], v['session']);
    final ch = (v['chunks'] as List).first as Map<String, dynamic>;
    final pt = await c.open(ch['file'], ch['chunk'], _hex(ch['ciphertext_hex']));
    expect(_toHex(pt), ch['plaintext_hex']);
    expect(() => c.open(ch['file'], ch['chunk'] + 1, _hex(ch['ciphertext_hex'])), throwsA(isA<ChunkAuthException>()));
  });
}
