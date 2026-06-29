import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory config store seeded with a ready-to-use profile.
class _FakeStore extends AppConfigStore {
  _FakeStore([this._initial = AppConfig.initial]);
  final AppConfig _initial;
  AppConfig saved = AppConfig.initial;
  @override
  Future<AppConfig> load() async => _initial;
  @override
  Future<void> save(AppConfig c) async => saved = c;
}

/// Updater test double — override the public surface the UI dispatches to.
class FakeEvccUpdater extends EvccUpdater {
  FakeEvccUpdater() : super(runnerFactory: _noRunner);
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  InstallDetection detection = const InstallDetection(
      kind: InstallKind.apt, aptVersion: '0.310.0', serviceActive: true);
  Object? detectError;
  UpdateSummary summary = const UpdateSummary(
      status: UpdateStatus.updated,
      message: 'evcc 0.310.0 → 0.311.0 aktualisiert.',
      before: '0.310.0',
      after: '0.311.0');

  int runCalls = 0;
  int dockerCalls = 0;
  int forgetCalls = 0;
  int backupCalls = 0;
  Object? backupError;
  SshConfig? forgotConfig;

  @override
  Future<String?> backup({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    backupCalls++;
    if (backupError != null) throw backupError!;
    return '/var/backups/evcc/evcc-backup-test.tar.gz';
  }

  @override
  Future<InstallDetection> detectInstall({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
  }) async {
    if (detectError != null) throw detectError!;
    return detection;
  }

  @override
  Future<UpdateSummary> run({
    required SshConfig config,
    required bool fullUpgrade,
    required bool dryRun,
    required void Function(String line) onLog,
  }) async {
    runCalls++;
    return summary;
  }

  @override
  Future<void> updateDocker({
    required SshConfig config,
    required InstallDetection detection,
    required void Function(String line) onLog,
  }) async {
    dockerCalls++;
  }

  @override
  Future<void> forgetHostKey(SshConfig config) async {
    forgetCalls++;
    forgotConfig = config;
  }
}

final _noUpdateChecker =
    UpdateChecker(getJson: (_) async => <String, dynamic>{});

const _ready = AppConfig(
  profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
  activeIndex: 0,
);

void main() {
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget page(FakeEvccUpdater updater, {Future<EvccRelease?> Function()? rel}) =>
      MaterialApp(
        home: UpdaterPage(
          store: _FakeStore(_ready),
          updater: updater,
          updateChecker: _noUpdateChecker,
          // Default: no release notes → update proceeds without a confirm.
          evccReleaseFetcher: rel ?? () async => null,
        ),
      );

  testWidgets('apt update surfaces the summary message + version badge',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater();
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    await tester.pumpAndSettle();

    expect(updater.backupCalls, 1); // backup runs first (toggle on by default)
    expect(updater.runCalls, 1);
    expect(find.text('evcc 0.310.0 → 0.311.0 aktualisiert.'), findsOneWidget);
  });

  testWidgets('a failed backup is shown and the update does NOT run',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater()
      ..backupError = const EvccUpdateException(
          UpdateErrorKind.unknown, 'Backup fehlgeschlagen (Exit 1).');
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    await tester.pumpAndSettle();

    expect(updater.backupCalls, 1);
    expect(updater.runCalls, 0); // halted — never updated without a backup
    // Shown in the status banner (and the live log).
    expect(find.textContaining('Backup fehlgeschlagen'), findsWidgets);
  });

  testWidgets('docker install: update button recreates the container',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater()
      ..detection = const InstallDetection(
          kind: InstallKind.docker,
          container: EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'));
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    await tester.pumpAndSettle();

    expect(updater.dockerCalls, 1);
    expect(updater.runCalls, 0);
    expect(find.textContaining('Container aktualisiert'), findsOneWidget);
  });

  testWidgets('docker install: dry-run reports it is unavailable, no-op',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater()
      ..detection = const InstallDetection(
          kind: InstallKind.docker,
          container: EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'));
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(
        find.widgetWithText(OutlinedButton, 'Probelauf (ändert nichts)'));
    await tester.pumpAndSettle();

    expect(updater.dockerCalls, 0);
    expect(find.textContaining('Docker-Installationen nicht verfügbar'),
        findsOneWidget);
  });

  testWidgets('test-connection: unknown install is a non-OK banner',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater()
      ..detection = const InstallDetection(kind: InstallKind.unknown);
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbindung testen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('nicht gefunden'), findsOneWidget);
  });

  testWidgets('a changed host key surfaces the trust-and-retry button',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbindung testen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);
  });

  testWidgets('trust-and-retry forgets the key and replays the action',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.pumpWidget(page(updater));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbindung testen'));
    await tester.pumpAndSettle();

    // The retry now succeeds (key trusted, apt found).
    updater
      ..detectError = null
      ..detection = const InstallDetection(
          kind: InstallKind.apt, aptVersion: '0.311.0', serviceActive: true);
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();

    expect(updater.forgetCalls, 1);
    expect(updater.forgotConfig!.host, '192.168.178.64');
    expect(find.textContaining('evcc 0.311.0 (apt)'), findsOneWidget);
  });

  testWidgets('update is cancellable from the release-notes confirm',
      (tester) async {
    useTallScreen(tester);
    final updater = FakeEvccUpdater();
    await tester.pumpWidget(page(updater,
        rel: () async => const EvccRelease(version: '0.311.0', notes: 'x')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    // Not pumpAndSettle: the busy spinner animates forever while the confirm
    // dialog is open, so settle never completes. Drive frames manually.
    await tester.pump(); // _busy=true frame
    await tester.pump(); // release-notes microtask resolves → dialog shows
    await tester.pump(const Duration(milliseconds: 300)); // dialog transition
    expect(find.text('evcc 0.311.0 installieren?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(updater.runCalls, 0); // cancelled → no SSH run
  });

  testWidgets('Pi finden with no results shows the manual-entry hint',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(_ready),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
        piFinder: () async => <String>[],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi im Netzwerk suchen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Keine SSH-Geräte'), findsOneWidget);
  });
}
