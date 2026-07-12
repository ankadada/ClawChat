import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final class TlsTestFixture {
  TlsTestFixture._(this._directory, this.certificatePath, this.privateKeyPath);

  final Directory _directory;
  final String certificatePath;
  final String privateKeyPath;

  static Future<TlsTestFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'clawchat_tls_test_',
    );
    final certificatePath = '${directory.path}/certificate.pem';
    final privateKeyPath = '${directory.path}/private-key.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-sha256',
      '-nodes',
      '-keyout',
      privateKeyPath,
      '-out',
      certificatePath,
      '-days',
      '1',
      '-subj',
      '/CN=public.example/O=ClawChat Test',
      '-addext',
      'subjectAltName=DNS:public.example,DNS:source.example,DNS:target.example',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
      '-addext',
      'extendedKeyUsage=serverAuth',
    ]);
    if (result.exitCode != 0) {
      await directory.delete(recursive: true);
      fail('Unable to create the ephemeral TLS test fixture.');
    }
    return TlsTestFixture._(
      directory,
      certificatePath,
      privateKeyPath,
    );
  }

  SecurityContext serverContext() => SecurityContext()
    ..useCertificateChain(certificatePath)
    ..usePrivateKey(privateKeyPath);

  SecurityContext trustedClientContext() =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(certificatePath);

  Future<void> dispose() async {
    if (await _directory.exists()) {
      await _directory.delete(recursive: true);
    }
  }
}
