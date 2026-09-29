import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const String _kPrefix = 'v10';
const String _kSalt = 'saltysalt';
const int _kIterations = 1003;
const int _kKeyLength = 16;

/// Grok Bot 0.61.0이 쓰는 Chromium `safeStorage` `v10` 암호문을 푼다.
/// 접두가 다르거나 패딩이 깨지면 null이다. 예외 문구에 암호와 토큰을 넣지 않는다.
String? decryptGrokBotCiphertext(String ciphertextBase64, String password) {
  if (password.isEmpty) return null;
  try {
    final blob = base64Decode(ciphertextBase64);
    if (blob.length <= _kPrefix.length ||
        utf8.decode(blob.sublist(0, _kPrefix.length)) != _kPrefix) {
      return null;
    }
    final key = _deriveKey(password);
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV(
            KeyParameter(key),
            Uint8List(_kKeyLength)..fillRange(0, _kKeyLength, 0x20),
          ),
          null,
        ),
      );
    return utf8.decode(cipher.process(blob.sublist(_kPrefix.length)));
  } catch (_) {
    return null;
  }
}

Uint8List _deriveKey(String password) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
    ..init(
      Pbkdf2Parameters(
        Uint8List.fromList(utf8.encode(_kSalt)),
        _kIterations,
        _kKeyLength,
      ),
    );
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}
