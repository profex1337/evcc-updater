import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/dartssh2_runner.dart';
import 'package:evcc_updater/src/host_key.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHostKeyStore implements HostKeyStore {
  final Map<String, String> data;
  FakeHostKeyStore([Map<String, String>? initial]) : data = {...?initial};
  @override
  Future<String?> get(String id) async => data[id];
  @override
  Future<void> set(String id, String fingerprint) async =>
      data[id] = fingerprint;
  @override
  Future<void> remove(String id) async => data.remove(id);
}

const _config =
    SshConfig(host: '192.168.178.64', port: 22, username: 'pi', password: 'pw');

Uint8List _fp(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('Dartssh2Runner.checkAndRecordHostKey (TOFU glue)', () {
    final id = hostKeyId(_config.host, _config.port);

    test('first use: records the key and accepts', () async {
      final store = FakeHostKeyStore();
      final runner = Dartssh2Runner(_config, hostKeyStore: store);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:aaa'));

      expect(accepted, isTrue);
      expect(store.data[id], 'SHA256:aaa'); // trusted on first use
    });

    test('match: accepts without rewriting the store', () async {
      final store = FakeHostKeyStore({id: 'SHA256:aaa'});
      final runner = Dartssh2Runner(_config, hostKeyStore: store);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:aaa'));

      expect(accepted, isTrue);
      expect(store.data[id], 'SHA256:aaa');
      expect(runner.changedFingerprint, isNull);
    });

    test('changed: rejects, leaves the stored key, records the new fingerprint',
        () async {
      final store = FakeHostKeyStore({id: 'SHA256:old'});
      final runner = Dartssh2Runner(_config, hostKeyStore: store);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:new'));

      expect(accepted, isFalse); // aborts the handshake → no password sent
      expect(store.data[id], 'SHA256:old'); // NOT overwritten
      expect(runner.changedFingerprint, 'SHA256:new');
    });
  });

  group('LineBuffer (per-line redaction guard)', () {
    test('holds a partial line until the newline, then emits it whole', () {
      final lines = <String>[];
      final lb = LineBuffer(lines.add);
      lb.add('sek'); // a secret split across two chunks…
      lb.add('ret\n'); // …only surfaces once the whole line is complete
      expect(lines, ['sekret\n']);
    });

    test('a redactor applied per whole line cannot be defeated by a chunk split',
        () {
      final out = <String>[];
      final lb = LineBuffer((line) => out.add(redactPassword(line, 'sekret')));
      lb.add('pw=sek');
      lb.add('ret done\n');
      expect(out, ['pw=$passwordMask done\n']); // masked despite the split
    });

    test('splits multiple newlines in one chunk and flushes the tail', () {
      final lines = <String>[];
      final lb = LineBuffer(lines.add);
      lb.add('a\nb\nc'); // 'c' has no trailing newline yet
      expect(lines, ['a\n', 'b\n']);
      lb.flush();
      expect(lines, ['a\n', 'b\n', 'c']);
    });
  });

  group('Dartssh2Runner.run / connect guards', () {
    test('run() before connect() throws StateError', () {
      final runner = Dartssh2Runner(_config, hostKeyStore: FakeHostKeyStore());
      expect(() => runner.run('echo hi'), throwsStateError);
    });

    test('connect() with a malformed private key throws SSHKeyDecodeError',
        () async {
      const cfg = SshConfig(
        host: '192.168.178.64',
        port: 22,
        username: 'pi',
        password: 'pw',
        privateKey: 'not a real pem key',
      );
      final runner = Dartssh2Runner(cfg, hostKeyStore: FakeHostKeyStore());
      // The key is parsed before any socket is opened, so this fails fast with
      // a clear typed error and never touches the network.
      await expectLater(runner.connect(), throwsA(isA<SSHKeyDecodeError>()));
    });
  });
}
