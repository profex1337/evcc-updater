import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

// Exact command strings the updater is expected to run (see commands.dart).
const _vQuery = r"dpkg-query -W -f='${Version}' evcc";
const _aptUpdate = 'sudo -S apt-get update -qq';
const _aptUpgrade = 'sudo -S apt-get install --only-upgrade -y evcc';
const _aptDryRun = 'sudo -S apt-get install --only-upgrade --dry-run evcc';
const _svc = 'systemctl is-active evcc';

const _config = SshConfig(
  host: '192.168.178.64',
  port: 22,
  username: 'pi',
  password: 'sekret',
  timeout: Duration(seconds: 10),
);

CommandResult _r(String stdout, {String stderr = '', int exitCode = 0}) =>
    CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr);

/// In-memory [SshRunner] that returns scripted output per command. A command
/// listed with several results yields them in order on successive calls (the
/// version query runs twice: before and after).
class FakeSshRunner implements SshRunner {
  final Map<String, List<CommandResult>> responses;
  final Object? connectError;

  /// Per-command error to throw from [run] (e.g. simulate a dropped connection).
  final Map<String, Object> runErrors;

  final List<String> commandsRun = [];
  final Map<String, String?> stdinByCommand = {};
  bool closed = false;
  bool connected = false;

  FakeSshRunner(this.responses,
      {this.connectError, this.runErrors = const {}});

  @override
  Future<void> connect() async {
    if (connectError != null) throw connectError!;
    connected = true;
  }

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    commandsRun.add(command);
    stdinByCommand[command] = stdin;

    if (runErrors.containsKey(command)) throw runErrors[command]!;

    final queue = responses[command];
    final CommandResult result;
    if (queue == null || queue.isEmpty) {
      result = _r('');
    } else {
      result = queue.length > 1 ? queue.removeAt(0) : queue.first;
    }

    if (onOutput != null) {
      if (result.stdout.isNotEmpty) onOutput(result.stdout);
      if (result.stderr.isNotEmpty) onOutput(result.stderr);
    }
    return result;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

EvccUpdater _updaterWith(FakeSshRunner runner) =>
    EvccUpdater(runnerFactory: (_) => runner);

FakeSshRunner _happyRunner() => FakeSshRunner({
      _vQuery: [_r('0.310.0\n'), _r('0.311.0\n')],
      _aptUpdate: [_r('')],
      _aptUpgrade: [
        _r('Setting up evcc (0.311.0) ...\n'
            '1 upgraded, 0 newly installed, 0 to remove and 27 not upgraded.')
      ],
      _svc: [_r('active\n')],
    });

void main() {
  group('EvccUpdater happy paths', () {
    test('real run upgrades evcc and reports the version change', () async {
      final runner = _happyRunner();
      final log = <String>[];

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: log.add,
      );

      expect(result.status, UpdateStatus.updated);
      expect(result.before, '0.310.0');
      expect(result.after, '0.311.0');
      expect(result.message, 'evcc 0.310.0 → 0.311.0 aktualisiert.');
      expect(runner.closed, isTrue);
    });

    test('real run without a newer version reports already current', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [
          _r('evcc is already the newest version (0.310.0).\n'
              '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: (_) {},
      );

      expect(result.status, UpdateStatus.alreadyCurrent);
    });

    test('full system upgrade: evcc unchanged, system packages upgraded',
        () async {
      const fullCmd = 'sudo -S apt-get full-upgrade -y';
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('')],
        fullCmd: [
          _r('The following packages will be upgraded:\n  libfoo libbar\n'
              '12 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: true,
        dryRun: false,
        onLog: (_) {},
      );

      expect(runner.commandsRun, contains(fullCmd));
      expect(result.status, UpdateStatus.alreadyCurrent);
      expect(result.message, contains('System-Pakete'));
    });

    test('dry-run uses the --dry-run command and reports a probe', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptDryRun: [
          _r('Inst evcc [0.310.0] (0.311.0 ...)\n'
              '1 upgraded, 0 newly installed, 0 to remove.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: true,
        onLog: (_) {},
      );

      expect(runner.commandsRun, contains(_aptDryRun));
      expect(result.status, UpdateStatus.dryRunWouldUpdate);
    });
  });

  group('EvccUpdater password handling', () {
    test('feeds the sudo password via stdin only for the apt-get steps',
        () async {
      final runner = _happyRunner();

      await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: (_) {},
      );

      expect(runner.stdinByCommand[_aptUpdate], 'sekret\n');
      expect(runner.stdinByCommand[_aptUpgrade], 'sekret\n');
      expect(runner.stdinByCommand[_vQuery], isNull);
      expect(runner.stdinByCommand[_svc], isNull);
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('redacts the password if it ever surfaces in command output',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('', stderr: 'oops leaked sekret here')],
        _aptUpgrade: [
          _r('evcc is already the newest version (0.310.0).\n'
              '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });
      final log = <String>[];

      await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: log.add,
      );

      expect(log.any((l) => l.contains('sekret')), isFalse);
      expect(log.any((l) => l.contains(passwordMask)), isTrue);
    });
  });

  group('EvccUpdater.testConnection', () {
    test('reports evcc version and service state without using sudo', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final info = await _updaterWith(runner)
          .testConnection(config: _config, onLog: (_) {});

      expect(info.version, '0.310.0');
      expect(info.serviceActive, isTrue);
      expect(runner.commandsRun, isNot(contains(_aptUpdate)));
      expect(runner.commandsRun, isNot(contains(_aptUpgrade)));
      expect(runner.stdinByCommand[_vQuery], isNull);
      expect(runner.stdinByCommand[_svc], isNull);
      expect(runner.closed, isTrue);
    });

    test('an inactive service is reported, not treated as an error', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('inactive\n')],
      });

      final info = await _updaterWith(runner)
          .testConnection(config: _config, onLog: (_) {});

      expect(info.version, '0.310.0');
      expect(info.serviceActive, isFalse);
    });

    test('maps an auth failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHAuthFailError('no auth'));

      await expectLater(
        _updaterWith(runner).testConnection(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('fails clearly when evcc is not installed', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('', stderr: 'no packages found', exitCode: 1)],
      });

      await expectLater(
        _updaterWith(runner).testConnection(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.packageMissing)),
      );
    });
  });

  group('EvccUpdater.install', () {
    const installCmd = 'sudo -S bash -s';

    test('runs the install script as root, then verifies version + service',
        () async {
      final runner = FakeSshRunner({
        installCmd: [_r('Setting up evcc ...', exitCode: 0)],
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final res =
          await _updaterWith(runner).install(config: _config, onLog: (_) {});

      expect(res.version, '0.310.0');
      expect(res.serviceActive, isTrue);
      // Password is the FIRST stdin line (for sudo -S), not in the command.
      expect(runner.stdinByCommand[installCmd], startsWith('sekret\n'));
      expect(runner.stdinByCommand[installCmd], contains('apt-get install -y evcc'));
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('detects a rejected sudo password', () async {
      final runner = FakeSshRunner({
        installCmd: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).install(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('fails when the install script exits non-zero', () async {
      final runner = FakeSshRunner({
        installCmd: [_r('E: Unable to locate package evcc', exitCode: 100)],
      });

      await expectLater(
        _updaterWith(runner).install(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater error handling', () {
    test('maps a socket failure to a connection error', () async {
      final runner = FakeSshRunner({}, connectError: SocketException('refused'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.connection)),
      );
    });

    test('maps an SSH auth failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHAuthFailError('no auth methods'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('detects a rejected sudo password and still cleans up', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _aptUpdate: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
      expect(runner.closed, isTrue);
    });

    test('a non-zero apt step is a hard error, not a false "already current"',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [
          _r('E: Could not get lock /var/lib/dpkg/lock-frontend', exitCode: 100)
        ],
        _svc: [_r('active\n')],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'message', contains('fehlgeschlagen'))),
      );
    });

    test('fails when the service is not active after a real upgrade', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.311.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [_r('1 upgraded, 0 newly installed')],
        _svc: [_r('inactive\n', exitCode: 3)],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('fails clearly when evcc is not installed', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('', stderr: 'no packages found matching evcc', exitCode: 1)],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.packageMissing)),
      );
    });

    test('maps a private-key decode failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHKeyDecodeError('malformed key'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('maps a changed host key to a hostKeyChanged error', () async {
      final runner = FakeSshRunner({},
          connectError: const HostKeyChangedException(
            host: '192.168.178.64',
            port: 22,
            presented: 'SHA256:new',
            stored: 'SHA256:old',
          ));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.hostKeyChanged)),
      );
    });
  });

  group('EvccUpdater admin actions', () {
    test('restartService restarts (sudo) and confirms the service is active',
        () async {
      final runner = FakeSshRunner({
        serviceRestartCommand: [_r('')],
        _svc: [_r('active\n')],
      });

      await _updaterWith(runner)
          .restartService(config: _config, onLog: (_) {});

      expect(runner.commandsRun, contains(serviceRestartCommand));
      expect(runner.stdinByCommand[serviceRestartCommand], 'sekret\n');
    });

    test('restartService reports a rejected sudo password', () async {
      final runner = FakeSshRunner({
        serviceRestartCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).restartService(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('restartService fails if the service is not active afterwards',
        () async {
      final runner = FakeSshRunner({
        serviceRestartCommand: [_r('')],
        _svc: [_r('inactive\n')],
      });

      await expectLater(
        _updaterWith(runner).restartService(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('reboot tolerates the connection dropping (success)', () async {
      final runner = FakeSshRunner({},
          runErrors: {rebootCommand: const SocketException('connection closed')});

      // Must NOT throw — a dropped connection is the expected outcome.
      await _updaterWith(runner).reboot(config: _config, onLog: (_) {});
    });

    test('reboot reports a rejected sudo password (no disconnect)', () async {
      final runner = FakeSshRunner({
        rebootCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).reboot(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('fetchStatus returns the systemctl status output', () async {
      final runner = FakeSshRunner({
        statusCommand: [
          _r('● evcc.service - evcc\n   Active: active (running) since ...')
        ],
      });

      final status =
          await _updaterWith(runner).fetchStatus(config: _config, onLog: (_) {});

      expect(status, contains('active (running)'));
      expect(runner.commandsRun, contains(statusCommand));
    });
  });

  group('EvccUpdater.detectInstall', () {
    test('apt: a dpkg version means an apt install + service state', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.apt);
      expect(d.aptVersion, '0.310.0');
      expect(d.serviceActive, isTrue);
      // Detection must not touch docker when apt is present.
      expect(runner.commandsRun, isNot(contains(dockerListCommand)));
    });

    test('docker: no apt package but an evcc container (no sudo needed)',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [_r('db|postgres:16\nevcc|evcc/evcc:latest\n')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.docker);
      expect(d.container!.name, 'evcc');
      expect(d.dockerNeedsSudo, isFalse);
    });

    test('docker: retries via sudo when the daemon denies access', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [
          _r('',
              stderr: 'permission denied while trying to connect to the '
                  'Docker daemon socket',
              exitCode: 1)
        ],
        dockerListSudoCommand: [_r('evcc|evcc/evcc:latest\n')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.docker);
      expect(d.dockerNeedsSudo, isTrue);
      expect(runner.stdinByCommand[dockerListSudoCommand], 'sekret\n');
    });

    test('unknown: neither apt package nor docker container', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [_r('', stderr: 'bash: docker: command not found')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.unknown);
    });

    test('allowSudoForDocker:false never escalates to sudo (no password sent)',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [
          _r('',
              stderr: 'permission denied while trying to connect to the '
                  'Docker daemon socket',
              exitCode: 1)
        ],
        dockerListSudoCommand: [_r('evcc|evcc/evcc:latest\n')],
      });

      final d = await _updaterWith(runner).detectInstall(
        config: _config,
        onLog: (_) {},
        allowSudoForDocker: false,
      );

      // No sudo retry → can't see the container → unknown, and crucially the
      // sudo command (which carries the password) was never run.
      expect(d.kind, InstallKind.unknown);
      expect(runner.commandsRun, isNot(contains(dockerListSudoCommand)));
    });
  });

  group('EvccUpdater.updateDocker', () {
    final detection = InstallDetection(
      kind: InstallKind.docker,
      container: const EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'),
    );
    final sudoDetection = InstallDetection(
      kind: InstallKind.docker,
      container: const EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'),
      dockerNeedsSudo: true,
    );
    final jsonCmd = dockerInspectJsonCommand('evcc');
    final jsonSudoCmd = dockerInspectJsonSudoCommand('evcc');
    const shell = 'bash -s';
    const sudoShell = 'sudo -S bash -s';

    String composeInspect() => jsonEncode([
          {
            'Name': '/evcc',
            'Config': {
              'Image': 'evcc/evcc:0.123',
              'Labels': {
                'com.docker.compose.project.working_dir': '/home/pi/evcc',
                'com.docker.compose.project.config_files':
                    '/home/pi/evcc/docker-compose.yml',
                'com.docker.compose.service': 'evcc',
                'com.docker.compose.project': 'evcc',
              },
            },
            'HostConfig': <String, dynamic>{},
          }
        ]);

    String runInspect() => jsonEncode([
          {
            'Name': '/evcc',
            'Config': {
              'Image': 'evcc/evcc:latest',
              'Env': ['TZ=Europe/Berlin'],
              'Labels': <String, dynamic>{},
            },
            'HostConfig': {
              'RestartPolicy': {'Name': 'unless-stopped', 'MaximumRetryCount': 0},
              'PortBindings': {
                '7070/tcp': [
                  {'HostIp': '', 'HostPort': '7070'}
                ]
              },
              'Binds': ['/home/pi/evcc.yaml:/etc/evcc.yaml'],
              'NetworkMode': 'default',
            },
          }
        ]);

    test('compose-managed: pulls + recreates the service, then verifies',
        () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(composeInspect())],
        shell: [_r('Pulling evcc ... done', exitCode: 0)],
        dockerListCommand: [_r('evcc|evcc/evcc:0.123\n')],
      });

      await _updaterWith(runner).updateDocker(
          config: _config, detection: detection, onLog: (_) {});

      final stdin = runner.stdinByCommand[shell]!;
      expect(stdin, contains("pull 'evcc'"));
      expect(stdin, contains("up -d 'evcc'"));
      expect(stdin, contains("-f '/home/pi/evcc/docker-compose.yml'"));
    });

    test('plain docker-run container: pulls + recreates from inspect data',
        () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(runInspect())],
        shell: [_r('recreated', exitCode: 0)],
        dockerListCommand: [_r('evcc|evcc/evcc:latest\n')],
      });

      await _updaterWith(runner).updateDocker(
          config: _config, detection: detection, onLog: (_) {});

      final stdin = runner.stdinByCommand[shell]!;
      expect(stdin, contains("docker pull 'evcc/evcc:latest'"));
      expect(stdin, contains("docker rename 'evcc' 'evcc-evccpitool-old'"));
      expect(stdin, contains("docker run -d --name 'evcc'"));
      expect(stdin, contains("-v '/home/pi/evcc.yaml:/etc/evcc.yaml'"));
    });

    test('sudo branch feeds the password as the first stdin line only',
        () async {
      final runner = FakeSshRunner({
        jsonSudoCmd: [_r(composeInspect())],
        sudoShell: [_r('done', exitCode: 0)],
        dockerListSudoCommand: [_r('evcc|evcc/evcc:0.123\n')],
      });

      await _updaterWith(runner).updateDocker(
          config: _config, detection: sudoDetection, onLog: (_) {});

      expect(runner.stdinByCommand[jsonSudoCmd], 'sekret\n');
      expect(runner.stdinByCommand[sudoShell], startsWith('sekret\n'));
      // password never appears in any command string
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('container missing in detection is a clear error', () async {
      final runner = FakeSshRunner({});
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config,
            detection: const InstallDetection(kind: InstallKind.docker),
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('a non-zero update script is reported as a failure', () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(composeInspect())],
        shell: [_r('boom', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: detection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'm', contains('fehlgeschlagen'))),
      );
    });

    test('container gone after the update is reported (not silent success)',
        () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(composeInspect())],
        shell: [_r('done', exitCode: 0)],
        dockerListCommand: [_r('')], // no evcc container after
      });
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: detection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });
  });
}
