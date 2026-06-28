import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store so the widget test never touches platform channels.
class _FakeStore extends SettingsStore {
  Settings saved = Settings.empty;

  @override
  Future<Settings> load() async => Settings.empty;

  @override
  Future<void> save(Settings s) async => saved = s;
}

/// Update checker that never hits the network in tests.
final _noUpdateChecker =
    UpdateChecker(getJson: (_) async => <String, dynamic>{});

Widget _page() =>
    MaterialApp(home: UpdaterPage(store: _FakeStore(), updateChecker: _noUpdateChecker));

void main() {
  testWidgets('renders the single-screen updater UI', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('evcc Updater'), findsOneWidget); // app bar title
    expect(find.text('evcc aktualisieren'), findsOneWidget);
    expect(find.text('Verbindung testen'), findsOneWidget);
    expect(find.text('Probelauf (ändert nichts)'), findsOneWidget);
    expect(find.text('Komplettes System-Upgrade'), findsOneWidget);
    expect(find.text('Live-Log'), findsOneWidget);
    // Host/IP, Benutzer, Port, Passwort.
    expect(find.byType(TextField), findsNWidgets(4));
  });

  testWidgets('blocks the update and warns when the host is empty',
      (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(
        find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    await tester.pump(); // surface the SnackBar

    expect(find.text('Bitte Host/IP eintragen.'), findsOneWidget);
  });
}
