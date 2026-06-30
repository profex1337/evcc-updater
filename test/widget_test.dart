import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/authenticator.dart';
import 'package:evcc_updater/src/evcc_api.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory config store so the widget test never touches platform channels.
class _FakeStore extends AppConfigStore {
  _FakeStore([this._initial = AppConfig.initial]);

  final AppConfig _initial;
  AppConfig saved = AppConfig.initial;

  @override
  Future<AppConfig> load() async => _initial;

  @override
  Future<void> save(AppConfig c) async => saved = c;
}

/// Authenticator that is available but always denies — keeps the app locked.
class _DenyAuth implements Authenticator {
  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// Update checker that never hits the network in tests.
final _noUpdateChecker =
    UpdateChecker(getJson: (_) async => <String, dynamic>{});

Widget _page() => MaterialApp(
    home: UpdaterPage(store: _FakeStore(), updateChecker: _noUpdateChecker));

void main() {
  // A tall phone-sized surface so the whole single screen fits (the ListView
  // builds lazily, so off-screen widgets wouldn't exist on the default surface).
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders the single-screen updater UI', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('Pi-Tool'), findsOneWidget); // app bar wordmark
    expect(find.text('evcc aktualisieren'), findsOneWidget);
    expect(find.text('Verbindung testen'), findsOneWidget);
    expect(find.text('Probelauf (ändert nichts)'), findsOneWidget);
    expect(find.text('evcc installieren'), findsOneWidget);
    expect(find.text('Komplettes System-Upgrade'), findsOneWidget);
    expect(find.text('Live-Log'), findsOneWidget);
    // Host/IP, Benutzer, Port, Passwort.
    expect(find.byType(TextField), findsNWidgets(4));
  });

  testWidgets('blocks the update and warns when the host is empty',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    await tester.pump(); // surface the SnackBar

    expect(find.text('Bitte Host/IP eintragen.'), findsOneWidget);
  });

  testWidgets('auto-saves the active profile shortly after a field is edited',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.1.50');
    await tester.pump(const Duration(seconds: 1)); // past the 800ms debounce

    expect(store.saved.active.host, '192.168.1.50');
  });

  testWidgets('adds a profile from the default config without crashing',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(); // AppConfig.initial → const profiles list
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Neues Profil'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Eltern');
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.profiles.length, 2);
    expect(store.saved.profiles.last.name, 'Eltern');
  });

  testWidgets('opens the bundled open-source licenses page', (tester) async {
    // Extra-tall surface so the footer (bottom of the ListView) is built.
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open-Source-Lizenzen'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('tapping a profile chip switches the active Pi', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [
        Profile(name: 'Standard', host: '1.1.1.1'),
        Profile(name: 'Eltern', host: '2.2.2.2'),
      ],
      activeIndex: 0,
    ));
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Eltern')); // the inactive profile chip
    await tester.pumpAndSettle();

    expect(store.saved.activeIndex, 1); // switch persisted immediately
    expect(store.saved.active.host, '2.2.2.2');
  });

  testWidgets('the update button label tracks the full-upgrade toggle',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('evcc aktualisieren'), findsOneWidget);
    expect(find.text('Alle Pakete aktualisieren'), findsNothing);

    await tester.tap(find.text('Komplettes System-Upgrade'));
    await tester.pumpAndSettle();

    expect(find.text('Alle Pakete aktualisieren'), findsOneWidget);
    expect(find.text('evcc aktualisieren'), findsNothing);
  });

  testWidgets('Pi finden fills the host field from a scan result',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        piFinder: () async => ['192.168.178.50'],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi im Netzwerk suchen'));
    await tester.pumpAndSettle();

    // Results sheet lists the host; tapping it adopts the IP.
    await tester.tap(find.text('192.168.178.50'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.active.host, '192.168.178.50');
  });

  testWidgets('evcc-Status sheet renders live values from the API',
      (tester) async {
    useTallScreen(tester);
    final api = EvccApiClient(getJson: (_) async => {
          'result': {
            'version': '0.123.1',
            'siteTitle': 'Zuhause',
            'pvPower': 2500,
            'gridPower': -1000,
            'homePower': 800,
            'loadpoints': [
              {
                'title': 'Garage',
                'charging': true,
                'chargePower': 11000,
                'vehicleSoc': 62,
                'mode': 'pv',
              }
            ],
          }
        });
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard', host: '192.168.178.64')],
      activeIndex: 0,
    ));
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        apiClient: api,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('evcc-Status (Live)'));
    await tester.pumpAndSettle();

    expect(find.text('Zuhause'), findsOneWidget);
    expect(find.text('Garage'), findsOneWidget);
    expect(find.text('2,5 kW'), findsOneWidget); // PV
  });

  testWidgets('shows the lock screen when app-lock is on and not unlocked',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard')],
      activeIndex: 0,
      lockEnabled: true,
    ));
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        authenticator: _DenyAuth(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Gesperrt'), findsOneWidget);
    expect(find.text('Entsperren'), findsOneWidget);
    // Main UI must be hidden behind the lock.
    expect(find.text('evcc aktualisieren'), findsNothing);
  });
}
