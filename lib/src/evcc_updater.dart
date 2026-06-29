import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'commands.dart';
import 'dartssh2_runner.dart';
import 'host_key.dart';
import 'parsing.dart';
import 'settings_store.dart';
import 'ssh_runner.dart';

/// Categories of failure surfaced to the user with a clear message.
enum UpdateErrorKind {
  connection,
  auth,
  sudo,
  serviceInactive,
  packageMissing,
  hostKeyChanged,
  unknown,
}

/// A failure during the update, carrying a user-facing German [message].
class EvccUpdateException implements Exception {
  final UpdateErrorKind kind;
  final String message;

  const EvccUpdateException(this.kind, this.message);

  @override
  String toString() => 'EvccUpdateException($kind): $message';
}

/// Result of a successful connection test.
class ConnectionInfo {
  final String version;
  final bool serviceActive;

  const ConnectionInfo({required this.version, required this.serviceActive});
}

/// Result of a successful evcc installation.
class InstallResult {
  final String version;
  final bool serviceActive;

  const InstallResult({required this.version, required this.serviceActive});
}

/// How evcc is installed on a given Pi, with the facts needed to update it.
class InstallDetection {
  final InstallKind kind;

  /// apt: the installed package version + service state.
  final String? aptVersion;
  final bool serviceActive;

  /// docker: the running evcc container, and whether docker needs sudo here.
  final EvccDocker? container;
  final bool dockerNeedsSudo;

  const InstallDetection({
    required this.kind,
    this.aptVersion,
    this.serviceActive = false,
    this.container,
    this.dockerNeedsSudo = false,
  });
}

/// Builds the [SshRunner] for a given config (injected so tests can fake SSH).
typedef SshRunnerFactory = SshRunner Function(SshConfig config);

/// Orchestrates the validated evcc update sequence over SSH.
class EvccUpdater {
  final SshRunnerFactory runnerFactory;

  /// Used by [forgetHostKey] to re-trust a changed host key. The same store
  /// instance is wired into the real runner so reads/writes stay consistent.
  final HostKeyStore? hostKeyStore;

  const EvccUpdater({required this.runnerFactory, this.hostKeyStore});

  /// Production updater backed by the real dartssh2 adapter.
  factory EvccUpdater.real() {
    final store = SecureHostKeyStore();
    return EvccUpdater(
      runnerFactory: (config) => Dartssh2Runner(config, hostKeyStore: store),
      hostKeyStore: store,
    );
  }

  /// Forgets the trusted host key for [config] so the next connect re-trusts
  /// (TOFU) the current key. Use after the user confirms a changed key is legit.
  Future<void> forgetHostKey(SshConfig config) async {
    await hostKeyStore?.remove(hostKeyId(config.host, config.port));
  }

  /// Runs the update (or a dry-run probe) and returns a result summary.
  ///
  /// Streams every command and its output to [onLog] (with the password
  /// redacted). Throws [EvccUpdateException] on any failure.
  Future<UpdateSummary> run({
    required SshConfig config,
    required bool fullUpgrade,
    required bool dryRun,
    required void Function(String line) onLog,
  }) {
    return _withConnection<UpdateSummary>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Verbunden. Starte ${dryRun ? 'Probelauf' : 'Update'} …');

        final steps = buildUpdateSteps(fullUpgrade: fullUpgrade, dryRun: dryRun);
        String? before;
        String? after;
        var upgradeOutput = '';

        for (var i = 0; i < steps.length; i++) {
          final step = steps[i];
          log('\$ ${step.command}');

          final result = await runner.run(
            step.command,
            stdin: step.needsSudoPassword ? '${config.password}\n' : null,
            onOutput: (chunk) {
              final trimmed = chunk.trimRight();
              if (trimmed.isNotEmpty) log(trimmed);
            },
          );
          final combined = '${result.stdout}\n${result.stderr}';

          if (step.needsSudoPassword && isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(
              UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
            );
          }

          // A non-zero UPGRADE step (held dpkg lock, full disk, broken deps)
          // must be a hard error — otherwise version-before == version-after and
          // the run is falsely reported as "already current". Scoped to the
          // upgrade step (i == 2): `apt-get update` (i == 1) can legitimately
          // exit non-zero when an unrelated third-party repo is unreachable, and
          // that must not block an otherwise-fine evcc upgrade.
          if (i == 2 && result.exitCode != null && result.exitCode != 0) {
            throw EvccUpdateException(
              UpdateErrorKind.unknown,
              '${step.label} fehlgeschlagen (Exit ${result.exitCode}). '
              'Details im Log.',
            );
          }

          switch (i) {
            case 0:
              before = parseInstalledVersion(result.stdout);
              if (before == null) {
                throw const EvccUpdateException(
                  UpdateErrorKind.packageMissing,
                  'evcc ist auf dem Pi nicht installiert (apt-Paket fehlt).',
                );
              }
            case 2:
              upgradeOutput = combined;
            case 3:
              if (!dryRun && !isServiceActive(result.stdout)) {
                throw const EvccUpdateException(
                  UpdateErrorKind.serviceInactive,
                  'evcc-Dienst ist nach dem Update nicht aktiv '
                  '(systemctl is-active ≠ active).',
                );
              }
            case 4:
              after = parseInstalledVersion(result.stdout);
          }
        }

        final summary = summarize(
          before: before,
          after: after,
          dryRun: dryRun,
          fullUpgrade: fullUpgrade,
          alreadyNewest: isAlreadyNewest(upgradeOutput),
        );
        log(summary.message);
        return summary;
      },
    );
  }

  /// Quick reachability/auth check: connects, reads the evcc version and the
  /// service state. Uses no sudo and changes nothing. Throws
  /// [EvccUpdateException] when the host is unreachable, auth fails, or evcc is
  /// not installed.
  Future<ConnectionInfo> testConnection({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<ConnectionInfo>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Verbunden. Prüfe evcc …');

        log('\$ $versionQuery');
        final versionResult = await runner.run(versionQuery);
        final version = parseInstalledVersion(versionResult.stdout);
        if (version == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'Verbindung steht, aber evcc ist auf dem Pi nicht installiert.',
          );
        }

        log('\$ $serviceStatus');
        final serviceResult = await runner.run(serviceStatus);
        final active = isServiceActive(serviceResult.stdout);

        log('OK: evcc $version, Dienst ${active ? 'aktiv' : 'inaktiv'}.');
        return ConnectionInfo(version: version, serviceActive: active);
      },
    );
  }

  /// Installs evcc on a freshly-configured Pi: adds the official apt repo,
  /// installs the package and enables the service — all as root via one
  /// `sudo -S bash -s` call (password fed as the first stdin line, never on the
  /// command line). Then verifies the installed version and service state.
  ///
  /// Experimental: built from evcc's official docs but not validated against a
  /// fresh Pi end-to-end. Throws [EvccUpdateException] on failure.
  Future<InstallResult> install({
    required SshConfig config,
    required void Function(String line) onLog,
    String channel = 'stable',
  }) {
    return _withConnection<InstallResult>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Installiere evcc … (Repo einrichten + Paket installieren, '
            'das dauert ein paar Minuten)');

        final result = await runner.run(
          installShellCommand,
          stdin: '${config.password}\n${buildInstallScript(channel: channel)}\n',
          onOutput: (chunk) {
            final trimmed = chunk.trimRight();
            if (trimmed.isNotEmpty) log(trimmed);
          },
        );
        final combined = '${result.stdout}\n${result.stderr}';

        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        if (result.exitCode != null && result.exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Installation fehlgeschlagen (Exit ${result.exitCode}). '
            'Details im Log.',
          );
        }

        final versionResult = await runner.run(versionQuery);
        final version = parseInstalledVersion(versionResult.stdout);
        if (version == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'Installation lief durch, aber evcc ist nicht auffindbar.',
          );
        }

        final serviceResult = await runner.run(serviceStatus);
        final active = isServiceActive(serviceResult.stdout);

        log('evcc $version installiert, Dienst ${active ? 'aktiv' : 'inaktiv'}.');
        return InstallResult(version: version, serviceActive: active);
      },
    );
  }

  /// Detects how evcc is installed on the Pi (apt package, Docker container, or
  /// neither) using only read-only probes. Used to pick the right update path.
  ///
  /// apt wins when the package is present. Otherwise it lists running
  /// containers — first without sudo, then via `sudo -S docker ps` if the
  /// daemon denies access — and reports a Docker install when an evcc container
  /// is running. Nothing is changed.
  Future<InstallDetection> detectInstall({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
  }) {
    return _withConnection<InstallDetection>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Erkenne Installationsart …');

        final dpkg = await runner.run(versionQuery);
        final aptVersion = parseInstalledVersion(dpkg.stdout);
        if (aptVersion != null) {
          final svc = await runner.run(serviceStatus);
          log('Gefunden: evcc $aptVersion als apt-Paket.');
          return InstallDetection(
            kind: InstallKind.apt,
            aptVersion: aptVersion,
            serviceActive: isServiceActive(svc.stdout),
          );
        }

        // No apt package — look for a running evcc Docker container.
        var listing = await runner.run(dockerListCommand);
        var needsSudo = false;
        // Retry via sudo only when explicitly allowed — the silent launch check
        // must never send the sudo password without a user action.
        if (allowSudoForDocker &&
            isDockerPermissionError('${listing.stdout}\n${listing.stderr}')) {
          needsSudo = true;
          listing = await runner.run(
            dockerListSudoCommand,
            stdin: '${config.password}\n',
          );
          if (isSudoPasswordFailure('${listing.stdout}\n${listing.stderr}')) {
            throw const EvccUpdateException(
              UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
            );
          }
        }

        final container = parseEvccDocker(listing.stdout);
        if (container != null) {
          log('Gefunden: evcc im Docker-Container "${container.name}".');
          return InstallDetection(
            kind: InstallKind.docker,
            container: container,
            dockerNeedsSudo: needsSudo,
          );
        }

        log('Weder ein evcc-apt-Paket noch ein evcc-Docker-Container gefunden.');
        return const InstallDetection(kind: InstallKind.unknown);
      },
    );
  }

  /// Updates a Docker-deployed evcc. Inspects the container once: if it's
  /// compose-managed, it pulls + recreates the evcc service via `docker compose`
  /// (project/file pinned, v1 fallback); otherwise it reconstructs an equivalent
  /// `docker run` from the inspect data and recreates the container, keeping the
  /// old one (renamed) as a rollback — volumes are reused, so no data is lost.
  /// Experimental: not validated against a real Docker host. Throws on failure.
  Future<void> updateDocker({
    required SshConfig config,
    required InstallDetection detection,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        final container = detection.container;
        if (container == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Kein evcc-Docker-Container erkannt.',
          );
        }
        final sudo = detection.dockerNeedsSudo;
        log('evcc-Container "${container.name}" (${container.image}).');

        final inspectCmd = sudo
            ? dockerInspectJsonSudoCommand(container.name)
            : dockerInspectJsonCommand(container.name);
        log('\$ $inspectCmd');
        final inspect = await runner.run(
          inspectCmd,
          stdin: sudo ? '${config.password}\n' : null,
        );
        if (sudo &&
            isSudoPasswordFailure('${inspect.stdout}\n${inspect.stderr}')) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        final obj = firstInspectObject(inspect.stdout);
        if (obj == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.unknown,
            'Konnte den Docker-Container nicht inspizieren.',
          );
        }

        final compose = composeInfoFromInspect(obj);
        final String script;
        if (compose != null) {
          log('Aktualisiere via docker compose in ${compose.workingDir} '
              '(Dienst ${compose.service}) …');
          script = dockerComposeUpdateScript(compose);
        } else {
          log('Container ohne docker compose – aktualisiere per Image-Pull + '
              'Neuanlage. Der alte Container bleibt als Backup erhalten.');
          final image =
              ((obj['Config'] is Map) ? (obj['Config'] as Map)['Image'] : null)
                      ?.toString() ??
                  container.image;
          if (image.contains('@sha256:')) {
            throw const EvccUpdateException(
              UpdateErrorKind.unknown,
              'Das Image ist per Digest gepinnt (@sha256:…) und kann nicht '
              'automatisch aktualisiert werden – bitte in der Container-'
              'Definition ein Image-Tag setzen und manuell neu ziehen.',
            );
          }
          script = dockerRunRecreateScript(
            name: container.name,
            image: image,
            runCommand: buildDockerRunCommand(obj, image: image),
          );
        }

        await _runRootScript(runner, log, config, sudo: sudo, script: script);

        final verify = await runner.run(
          sudo ? dockerListSudoCommand : dockerListCommand,
          stdin: sudo ? '${config.password}\n' : null,
        );
        if (parseEvccDocker(verify.stdout) == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'evcc-Container läuft nach dem Update nicht. Der vorherige Container '
            'wurde als Backup (Suffix "-evccpitool-old") behalten.',
          );
        }
        log('Fertig – evcc-Container läuft wieder.');
      },
    );
  }

  /// Runs a multi-line root [script] via `bash -s` (or `sudo -S bash -s`),
  /// streaming output and mapping a rejected sudo password / non-zero exit to a
  /// clear error. Shared by the compose and `docker run` update paths.
  Future<void> _runRootScript(
    SshRunner runner,
    void Function(String) log,
    SshConfig config, {
    required bool sudo,
    required String script,
  }) async {
    final shell = sudo ? installShellCommand : 'bash -s';
    final result = await runner.run(
      shell,
      stdin: sudo ? '${config.password}\n$script\n' : '$script\n',
      onOutput: (chunk) {
        final t = chunk.trimRight();
        if (t.isNotEmpty) log(t);
      },
    );
    final combined = '${result.stdout}\n${result.stderr}';
    if (sudo && isSudoPasswordFailure(combined)) {
      throw const EvccUpdateException(
        UpdateErrorKind.sudo,
        'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
      );
    }
    if (result.exitCode != null && result.exitCode != 0) {
      throw EvccUpdateException(
        UpdateErrorKind.unknown,
        'Docker-Update fehlgeschlagen (Exit ${result.exitCode}). '
        'Details im Log.',
      );
    }
  }

  /// Restarts the evcc service and verifies it comes back active.
  Future<void> restartService({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Starte evcc-Dienst neu …');
        log('\$ $serviceRestartCommand');
        final result = await runner.run(
          serviceRestartCommand,
          stdin: '${config.password}\n',
          onOutput: (chunk) {
            final t = chunk.trimRight();
            if (t.isNotEmpty) log(t);
          },
        );
        if (isSudoPasswordFailure('${result.stdout}\n${result.stderr}')) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        // A non-zero restart command (e.g. an undetected sudo rejection) must
        // not be swallowed — otherwise the old instance keeps running and
        // is-active still reports 'active', a false "Dienst läuft wieder".
        if (result.exitCode != null && result.exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Neustart fehlgeschlagen (Exit ${result.exitCode}). Details im Log.',
          );
        }
        final svc = await runner.run(serviceStatus);
        if (!isServiceActive(svc.stdout)) {
          throw const EvccUpdateException(
            UpdateErrorKind.serviceInactive,
            'evcc-Dienst ist nach dem Neustart nicht aktiv.',
          );
        }
        log('evcc-Dienst läuft wieder.');
      },
    );
  }

  /// Reboots the Pi. The SSH connection drops as a result — that's treated as
  /// success. A rejected sudo password (no disconnect) is reported.
  Future<void> reboot({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<void>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Starte den Pi neu …');
        log('\$ $rebootCommand');
        var combined = '';
        try {
          final result = await runner.run(
            rebootCommand,
            stdin: '${config.password}\n',
            onOutput: (chunk) {
              final t = chunk.trimRight();
              if (t.isNotEmpty) log(t);
            },
          );
          combined = '${result.stdout}\n${result.stderr}';
        } catch (_) {
          // The reboot drops the SSH connection — expected, treat as success.
        }
        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        log('Neustart ausgelöst – der Pi ist gleich kurz offline.');
      },
    );
  }

  /// Fetches `systemctl status evcc` (incl. recent log lines) for diagnostics.
  Future<String> fetchStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<String>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('\$ $statusCommand');
        final result = await runner.run(
          statusCommand,
          onOutput: (chunk) {
            final t = chunk.trimRight();
            if (t.isNotEmpty) log(t);
          },
        );
        return result.stdout.isNotEmpty ? result.stdout : result.stderr;
      },
    );
  }

  /// Opens the connection, runs [body], and maps any SSH/IO failure to an
  /// [EvccUpdateException]. The runner is always closed afterwards.
  Future<T> _withConnection<T>({
    required SshConfig config,
    required void Function(String line) onLog,
    required Future<T> Function(SshRunner runner, void Function(String) log)
        body,
  }) async {
    final runner = runnerFactory(config);
    void log(String s) => onLog(redactPassword(s, config.password));

    try {
      log('Verbinde mit ${config.username}@${config.host}:${config.port} …');
      await runner.connect();
      return await body(runner, log);
    } on EvccUpdateException {
      rethrow;
    } on HostKeyChangedException catch (e) {
      throw EvccUpdateException(
        UpdateErrorKind.hostKeyChanged,
        'Der SSH-Host-Key von ${e.host} hat sich geändert! Entweder wurde der '
        'Pi neu aufgesetzt – oder jemand täuscht ihn vor. Aus Sicherheit wurde '
        'KEIN Passwort gesendet.\nNeuer Fingerprint: ${e.presented}',
      );
    } on SSHAuthError {
      throw const EvccUpdateException(
        UpdateErrorKind.auth,
        'Anmeldung fehlgeschlagen – Benutzer/Passwort bzw. SSH-Key prüfen.',
      );
    } on SSHKeyDecodeError {
      throw const EvccUpdateException(
        UpdateErrorKind.auth,
        'Privater SSH-Key ungültig oder falsche Passphrase.',
      );
    } on SocketException {
      throw const EvccUpdateException(
        UpdateErrorKind.connection,
        'Verbindung fehlgeschlagen – IP/Port korrekt, Pi online im Netz?',
      );
    } on TimeoutException {
      throw const EvccUpdateException(
        UpdateErrorKind.connection,
        'Zeitüberschreitung – Pi nicht erreichbar.',
      );
    } on SSHError catch (e) {
      throw EvccUpdateException(UpdateErrorKind.unknown, 'SSH-Fehler: $e');
    } catch (e) {
      throw EvccUpdateException(
          UpdateErrorKind.unknown, 'Unerwarteter Fehler: $e');
    } finally {
      await runner.close();
    }
  }
}
