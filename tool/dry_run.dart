// Lokales Validierungs-Tool: führt EINEN Dry-Run (apt-get ... --dry-run) gegen
// den echten Pi aus — über exakt denselben Code wie die App (Dartssh2Runner +
// EvccUpdater). Es ändert NICHTS auf dem Pi.
//
// Nutzung (PowerShell):
//   $env:Path = "C:\Users\stefa\flutterdev\flutter\bin;" + $env:Path
//   dart run tool/dry_run.dart            # nur evcc
//   dart run tool/dry_run.dart --full     # System-Voll-Upgrade (Probelauf)
//
// Host/User/Port via Umgebungsvariablen überschreibbar (EVCC_HOST/EVCC_USER/
// EVCC_PORT). Das Passwort wird interaktiv abgefragt und NICHT gespeichert.
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/ssh_runner.dart';

Future<void> main(List<String> args) async {
  final host = Platform.environment['EVCC_HOST'] ?? '192.168.178.64';
  final user = Platform.environment['EVCC_USER'] ?? 'pi';
  final port = int.tryParse(Platform.environment['EVCC_PORT'] ?? '22') ?? 22;
  final fullUpgrade = args.contains('--full');

  var pass = Platform.environment['EVCC_PASS'];
  if (pass == null || pass.isEmpty) {
    stdout.write('Pi-Passwort für $user@$host:$port: ');
    try {
      stdin.echoMode = false; // Passwort nicht im Terminal anzeigen
    } catch (_) {/* manche Terminals unterstützen das nicht */}
    pass = stdin.readLineSync() ?? '';
    try {
      stdin.echoMode = true;
    } catch (_) {/* echo restore is best-effort */}
    stdout.writeln();
  }

  print('--- DRY-RUN (ändert nichts) gegen $user@$host:$port '
      '${fullUpgrade ? '[Voll-Upgrade]' : '[nur evcc]'} ---');

  try {
    final summary = await EvccUpdater.real().run(
      config: SshConfig(
        host: host,
        port: port,
        username: user,
        password: pass,
      ),
      fullUpgrade: fullUpgrade,
      dryRun: true,
      onLog: print,
    );
    print('');
    print('--- ERGEBNIS: ${summary.status.name} ---');
    print(summary.message);
  } on EvccUpdateException catch (e) {
    print('');
    print('--- FEHLER (${e.kind.name}) ---');
    print(e.message);
    exitCode = 1;
  } catch (e) {
    print('');
    print('--- UNERWARTETER FEHLER ---');
    print('$e');
    exitCode = 1;
  }
}
