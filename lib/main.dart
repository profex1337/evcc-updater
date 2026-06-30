import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/authenticator.dart';
import 'src/commands.dart';
import 'src/evcc_api.dart';
import 'src/evcc_updater.dart';
import 'src/history.dart';
import 'src/network_scan.dart';
import 'src/parsing.dart';
import 'src/profiles.dart';
import 'src/settings_store.dart';
import 'src/ssh_runner.dart';
import 'src/update_check.dart';

part 'src/ui_widgets.dart';

void main() {
  runApp(const EvccPiToolApp());
}

/// Clean minimal dark: near-black canvas, a single vivid green accent.
const kGreen = Color(0xFF1FD65F);
const kBlack = Color(0xFF0B0E0C);
const kCard = Color(0xFF161A17);

const kEvccPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=io.evcc.android';
const kPrivacyUrl = 'https://profex1337.github.io/evcc-pi-tool/privacy.html';
const kImpressumUrl = 'https://profex1337.github.io/evcc-pi-tool/impressum.html';
const kReleasesUrl = 'https://github.com/profex1337/evcc-pi-tool/releases';

/// Drives MaterialApp.themeMode; updated from the loaded setting + the picker.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode parseThemeMode(String s) => switch (s) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };

ThemeData _buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.dark)
          .copyWith(primary: kGreen, onPrimary: Colors.black, surface: kBlack)
      : ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.light);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? kBlack : null,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? kBlack : scheme.surface,
      foregroundColor: dark ? Colors.white : scheme.onSurface,
      elevation: 0,
    ),
  );
}

class EvccPiToolApp extends StatelessWidget {
  const EvccPiToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (_, mode, _) => MaterialApp(
        title: 'Pi-Tool',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: const UpdaterPage(),
      ),
    );
  }
}

class UpdaterPage extends StatefulWidget {
  /// All collaborators are injectable so widget tests avoid real platform
  /// channels, SSH, network and biometrics.
  const UpdaterPage({
    super.key,
    this.store,
    this.updater,
    this.updateChecker,
    this.authenticator,
    this.apiClient,
    this.piFinder,
    this.evccReleaseFetcher,
  });

  final AppConfigStore? store;
  final EvccUpdater? updater;
  final UpdateChecker? updateChecker;
  final Authenticator? authenticator;
  final EvccApiClient? apiClient;

  /// Discovers reachable SSH hosts on the local network. Injectable for tests.
  final Future<List<String>> Function()? piFinder;

  /// Fetches evcc's latest release (for the pre-update notes). Injectable so
  /// tests can drive the confirm/cancel flow without a live GitHub call.
  final Future<EvccRelease?> Function()? evccReleaseFetcher;

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage>
    with WidgetsBindingObserver {
  late final AppConfigStore _store = widget.store ?? AppConfigStore();
  late final EvccUpdater _updater = widget.updater ?? EvccUpdater.real();
  late final UpdateChecker _updateChecker =
      widget.updateChecker ?? UpdateChecker();
  late final Authenticator _authenticator =
      widget.authenticator ?? LocalAuthenticator();
  late final EvccApiClient _apiClient = widget.apiClient ?? EvccApiClient();
  late final Future<List<String>> Function() _piFinder =
      widget.piFinder ?? findSshHosts;
  late final Future<EvccRelease?> Function() _fetchEvccRelease =
      widget.evccReleaseFetcher ?? fetchEvccRelease;
  final HistoryStore _historyStore = HistoryStore();

  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'pi');
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _uiPort = TextEditingController(text: '7070');
  final _logScroll = ScrollController();

  bool _fullUpgrade = false;
  bool _obscure = true;
  bool _busy = false;
  AuthMode _authMode = AuthMode.password;
  String _uiScheme = 'http';
  bool _lockEnabled = false;
  bool _locked = false;
  bool _unlocking = false;
  String _themeMode = 'system';
  String _channel = 'stable';
  bool _autoCheck = false;
  bool _backupBeforeUpdate = true;
  List<Profile> _profiles = [const Profile(name: 'Standard')]; // growable
  int _activeIndex = 0;

  final List<String> _log = [];
  String? _versionBefore;
  String? _versionAfter;
  String? _statusMessage;
  bool _statusOk = true;
  ReleaseInfo? _update;
  String? _setupUrl;
  Timer? _saveDebounce;
  bool _hostKeyIssue = false;
  SshConfig? _lastConfig;
  Future<void> Function()? _lastAction;

  List<TextEditingController> get _savedControllers =>
      [_host, _port, _user, _password, _privateKey, _keyPassphrase, _uiPort];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _checkForUpdate();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _persistSettings(); // reads controllers synchronously before disposal
    for (final c in _savedControllers) {
      c.dispose();
    }
    _logScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist on any background-ish transition (cheap, safe).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveDebounce?.cancel();
      _persistSettings();
    }
    // Lock only on REAL backgrounding (paused/hidden), not on transient
    // `inactive` (notification shade, system dialogs, the auth prompt itself),
    // and not while an unlock is already in progress.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_lockEnabled && !_unlocking && mounted) {
        // Dismiss any open sheet/dialog (API status, history, settings, find-Pi)
        // so it can't stay readable above the lock screen on resume.
        Navigator.of(context, rootNavigator: true)
            .popUntil((r) => r.isFirst);
        setState(() => _locked = true);
      }
    } else if (state == AppLifecycleState.resumed && _locked && !_unlocking) {
      _tryUnlock();
    }
  }

  Future<void> _loadSettings() async {
    final cfg = await _store.load();
    if (!mounted) return;
    setState(() {
      _profiles = List.of(cfg.profiles); // always growable, never the const fallback
      _activeIndex = cfg.safeIndex;
      _uiScheme = cfg.uiScheme;
      _uiPort.text = cfg.uiPort;
      _lockEnabled = cfg.lockEnabled;
      _themeMode = cfg.themeMode;
      _channel = cfg.channel;
      _autoCheck = cfg.autoCheck;
      _backupBeforeUpdate = cfg.backupBeforeUpdate;
      _applyProfile(cfg.active);
      if (_lockEnabled) _locked = true;
    });
    themeModeNotifier.value = parseThemeMode(_themeMode);
    // Attach auto-save listeners after initial values are set.
    for (final c in _savedControllers) {
      c.addListener(_scheduleSave);
    }
    if (_locked) {
      _tryUnlock();
    } else {
      _autoStatus();
    }
  }

  /// Loads a profile's connection fields into the controllers/state.
  void _applyProfile(Profile p) {
    _host.text = p.host;
    _port.text = p.port;
    _user.text = p.username;
    _password.text = p.password;
    _privateKey.text = p.privateKey;
    _keyPassphrase.text = p.keyPassphrase;
    _authMode = p.authMode;
    _fullUpgrade = p.fullUpgrade;
  }

  /// Debounced auto-save: persists ~0.8s after the last edit.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _persistSettings);
  }

  Future<void> _persistSettings() => _store.save(_currentConfig());

  /// The active profile rebuilt from the live controller values.
  Profile _currentProfile() => Profile(
        name: _activeIndex < _profiles.length
            ? _profiles[_activeIndex].name
            : 'Standard',
        host: _host.text.trim(),
        port: _port.text.trim().isEmpty ? '22' : _port.text.trim(),
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        authMode: _authMode,
        privateKey: _privateKey.text,
        keyPassphrase: _keyPassphrase.text,
        fullUpgrade: _fullUpgrade,
      );

  AppConfig _currentConfig() {
    final profiles = [..._profiles];
    if (_activeIndex < profiles.length) {
      profiles[_activeIndex] = _currentProfile();
    }
    return AppConfig(
      profiles: profiles,
      activeIndex: _activeIndex,
      uiScheme: _uiScheme,
      uiPort: _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim(),
      lockEnabled: _lockEnabled,
      themeMode: _themeMode,
      channel: _channel,
      autoCheck: _autoCheck,
      backupBeforeUpdate: _backupBeforeUpdate,
    );
  }

  // ---- profile management --------------------------------------------------

  void _switchProfile(int i) {
    if (i == _activeIndex || i < 0 || i >= _profiles.length) return;
    _profiles[_activeIndex] = _currentProfile(); // capture outgoing edits
    setState(() {
      _activeIndex = i;
      _applyProfile(_profiles[i]);
    });
    _persistSettings();
  }

  Future<void> _addProfile() async {
    final name = await _promptName('Neues Profil', '');
    if (name == null || !mounted) return;
    _profiles[_activeIndex] = _currentProfile();
    final next = [..._profiles, Profile(name: name)];
    setState(() {
      _profiles = next;
      _activeIndex = next.length - 1;
      _applyProfile(_profiles[_activeIndex]);
    });
    _persistSettings();
  }

  Future<void> _renameActiveProfile() async {
    final current =
        _activeIndex < _profiles.length ? _profiles[_activeIndex].name : '';
    final name = await _promptName('Profil umbenennen', current);
    if (name == null || !mounted) return;
    setState(() {
      _profiles[_activeIndex] = _currentProfile().copyWith(name: name);
    });
    _persistSettings();
  }

  Future<void> _deleteActiveProfile() async {
    if (_profiles.length <= 1) return;
    final name =
        _activeIndex < _profiles.length ? _profiles[_activeIndex].name : '';
    // Destructive + irreversible (wipes host, credentials and any SSH key) —
    // always confirm, like reboot/install.
    if (!await _confirm(
      'Profil „$name" löschen?',
      'Entfernt das Profil samt gespeicherter Zugangsdaten und SSH-Key. '
          'Das kann nicht rückgängig gemacht werden.',
    )) {
      return;
    }
    if (_profiles.length <= 1) return; // re-check after the async gap
    final next = [..._profiles]..removeAt(_activeIndex);
    setState(() {
      _profiles = next;
      _activeIndex = _activeIndex.clamp(0, next.length - 1);
      _applyProfile(_profiles[_activeIndex]);
    });
    _persistSettings();
  }

  Future<String?> _promptName(String title, String initial) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(title: title, initial: initial),
    );
    return (name != null && name.trim().isNotEmpty) ? name.trim() : null;
  }

  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final release = await _updateChecker.checkForUpdate(info.version);
      if (release != null && mounted) setState(() => _update = release);
    } catch (_) {
      // never let the update check disrupt the app
    }
  }

  Future<void> _tryUnlock() async {
    if (!_lockEnabled) {
      if (mounted) setState(() => _locked = false);
      return;
    }
    if (_unlocking) return; // re-entrancy guard: avoid overlapping prompts
    _unlocking = true;
    try {
      final ok = await _authenticator.authenticate('Pi-Tool entsperren');
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _unlocking = false;
    }
  }

  // ---- actions -------------------------------------------------------------

  int? _validatedPort() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte Host/IP eintragen.');
      return null;
    }
    if (_authMode == AuthMode.password && _password.text.isEmpty) {
      _snack('Bitte Pi-Passwort eintragen.');
      return null;
    }
    if (_authMode == AuthMode.key && _privateKey.text.trim().isEmpty) {
      _snack('Bitte privaten SSH-Key einfügen.');
      return null;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      _snack('Port ist ungültig (1–65535).');
      return null;
    }
    return port;
  }

  SshConfig _configFor(int port) => SshConfig(
        host: _host.text.trim(),
        port: port,
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        privateKey: _authMode == AuthMode.key ? _privateKey.text : '',
        keyPassphrase: _authMode == AuthMode.key ? _keyPassphrase.text : '',
        timeout: const Duration(seconds: 15),
      );

  /// Validates, builds the config, remembers it, saves settings and enters the
  /// busy state. Returns the config, or null when validation failed.
  SshConfig? _prepare() {
    final port = _validatedPort();
    if (port == null) return null;
    final config = _configFor(port);
    _lastConfig = config;
    _persistSettings();
    _beginBusy();
    return config;
  }

  void _beginBusy() {
    setState(() {
      _busy = true;
      _log.clear();
      _statusMessage = null;
      _versionAfter = null;
      _setupUrl = null;
      _hostKeyIssue = false;
    });
  }

  /// Shared error handling + busy-reset for every action.
  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } on EvccUpdateException catch (e) {
      _appendLog('FEHLER: ${e.message}');
      if (!mounted) return;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
        _hostKeyIssue = e.kind == UpdateErrorKind.hostKeyChanged;
      });
    } catch (e) {
      _appendLog('FEHLER: $e'); // _appendLog redacts the password
      if (!mounted) return;
      setState(() {
        // Keep the raw exception in the (redacted) log, not in the headline.
        _statusMessage = 'Unerwarteter Fehler – Details im Live-Log.';
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run({required bool dryRun}) async {
    if (_busy) return;
    // Before a real update, show evcc's latest release notes (fail-soft). Mark
    // busy during the fetch/confirm so all action buttons disable — otherwise
    // the network await opens a window for double-taps / concurrent SSH ops.
    if (!dryRun) {
      setState(() => _busy = true);
      final rel = await _fetchEvccRelease();
      if (!mounted) return;
      // Always warn when full-upgrade is on (it touches ALL packages, not just
      // evcc) — even if the release-notes fetch failed.
      final warn = _fullUpgrade
          ? 'Achtung: „Komplettes System-Upgrade" aktualisiert ALLE '
              'System-Pakete auf dem Pi, nicht nur evcc.'
          : '';
      final notes = rel != null ? _notesExcerpt(rel.notes) : '';
      final body = [warn, notes].where((s) => s.isNotEmpty).join('\n\n');
      // Confirm whenever there's something to say (a warning or notes);
      // otherwise (plain evcc update, no notes) proceed silently as before.
      final proceed = body.isEmpty ||
          await _confirm(
            rel != null ? 'evcc ${rel.version} installieren?' : 'evcc aktualisieren?',
            body,
          );
      if (!proceed) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    }
    final config = _prepare();
    if (config == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    _lastAction = () => _run(dryRun: dryRun);
    await _guard(() async {
      // Auto-detect how evcc is installed, then take the matching update path.
      final detection =
          await _updater.detectInstall(config: config, onLog: _appendLog);
      switch (detection.kind) {
        case InstallKind.unknown:
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'evcc wurde nicht gefunden – weder als apt-Paket noch als '
            'Docker-Container.',
          );
        case InstallKind.docker:
          if (dryRun) {
            if (!mounted) return;
            setState(() {
              _statusMessage =
                  'Probelauf für Docker-Installationen nicht verfügbar – evcc '
                  'läuft hier im Container "${detection.container!.name}".';
              _statusOk = true;
            });
            return;
          }
          await _updater.updateDocker(
            config: config,
            detection: detection,
            onLog: _appendLog,
          );
          if (!mounted) return;
          setState(() {
            _versionBefore = null; // version badge is apt-only
            _versionAfter = null;
            _statusMessage =
                'evcc-Container aktualisiert (docker compose pull + up).';
            _statusOk = true;
          });
          _addHistory('evcc-Docker-Container aktualisiert.');
        case InstallKind.apt:
          // Back up config + DB first (opt-out). A backup failure throws here
          // and is surfaced by _guard — the update does NOT proceed, so you're
          // never updated without the safety net you enabled. ("Nichts zu
          // sichern" returns null and is not an error.)
          if (!dryRun && _backupBeforeUpdate) {
            await _updater.backup(config: config, onLog: _appendLog);
            if (!mounted) return;
          }
          final summary = await _updater.run(
            config: config,
            fullUpgrade: _fullUpgrade,
            dryRun: dryRun,
            onLog: _appendLog,
          );
          if (!mounted) return;
          setState(() {
            _versionBefore = summary.before;
            _versionAfter = summary.after;
            _statusMessage = summary.message;
            _statusOk = true;
          });
          if (!dryRun) _addHistory(summary.message);
      }
    });
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _testConnection;
    await _guard(() async {
      final d = await _updater.detectInstall(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        switch (d.kind) {
          case InstallKind.apt:
            _versionBefore = d.aptVersion;
            _versionAfter = null;
            _statusMessage = 'Verbindung OK – evcc ${d.aptVersion} (apt), '
                'Dienst ${d.serviceActive ? 'aktiv' : 'inaktiv'}.';
            _statusOk = true;
          case InstallKind.docker:
            _versionBefore = null;
            _versionAfter = null;
            _statusMessage =
                'Verbindung OK – evcc läuft via Docker (Container '
                '"${d.container!.name}", Image ${d.container!.image}).';
            _statusOk = true;
          case InstallKind.unknown:
            _versionBefore = null;
            _versionAfter = null;
            _statusMessage = 'Verbindung steht, aber evcc wurde nicht gefunden '
                '(weder apt-Paket noch Docker-Container).';
            _statusOk = false;
        }
      });
    });
  }

  Future<void> _install() async {
    if (_busy) return;
    if (!await _confirm(
      'evcc installieren?',
      'Installiert evcc auf ${_host.text.trim()}: fügt das offizielle '
          'evcc-Repo hinzu, installiert das Paket und startet den Dienst.\n\n'
          'Experimentell: gegen eine frische Pi-Installation nicht vollständig '
          'getestet.',
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _install;
    await _guard(() async {
      final res = await _updater.install(
        config: config,
        onLog: _appendLog,
        channel: _channel,
      );
      if (!mounted) return;
      setState(() {
        _versionBefore = res.version;
        _versionAfter = null;
        _statusMessage = 'evcc ${res.version} installiert, '
            'Dienst ${res.serviceActive ? 'aktiv' : 'inaktiv'}. '
            'Jetzt im Browser einrichten.';
        _statusOk = true;
        _setupUrl = _evccUiUrl();
      });
      _addHistory('evcc ${res.version} installiert.');
    });
  }

  Future<void> _restartService() async {
    if (_busy) return;
    if (!await _confirm('evcc-Dienst neu starten?',
        'Laufende Ladevorgänge werden dabei kurz unterbrochen.')) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _restartService;
    await _guard(() async {
      await _updater.restartService(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'evcc-Dienst neu gestartet.';
        _statusOk = true;
      });
      _addHistory('evcc-Dienst neu gestartet.');
    });
  }

  Future<void> _reboot() async {
    if (_busy) return;
    if (!await _confirm(
      'Pi neustarten?',
      'Startet den Raspberry Pi neu. Die Verbindung bricht dabei kurz ab.',
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _reboot;
    await _guard(() async {
      await _updater.reboot(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Neustart ausgelöst – der Pi ist gleich kurz offline.';
        _statusOk = true;
      });
      _addHistory('Pi-Neustart ausgelöst.');
    });
  }

  Future<void> _showStatus() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _showStatus;
    await _guard(() async {
      await _updater.fetchStatus(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Status abgerufen (siehe Live-Log).';
        _statusOk = true;
      });
    });
  }

  /// Re-trust a changed host key, then retry the action that hit it.
  Future<void> _trustAndRetry() async {
    if (_busy) return; // synchronous re-entrancy guard: forgetHostKey is async
    final config = _lastConfig;
    final action = _lastAction;
    if (config == null || action == null) return;
    setState(() => _busy = true);
    try {
      await _updater.forgetHostKey(config);
    } catch (_) {
      // proceed to retry regardless — forgetting is best-effort
    }
    if (!mounted) return;
    // Hand control to the original action, which re-enters the normal
    // busy/_guard lifecycle (it sets _busy synchronously before its first await,
    // so there is no concurrency gap here).
    setState(() => _busy = false);
    await action();
  }

  void _shareLog() {
    if (_log.isEmpty) {
      _snack('Das Log ist leer.');
      return;
    }
    SharePlus.instance.share(ShareParams(text: _log.join('\n')));
  }

  /// Read-only live status straight from evcc's Web-API (no SSH, no creds).
  void _showApiStatus() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    final port = _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ApiStatusSheet(
        future: _apiClient.fetchState(
            scheme: _uiScheme, host: host, port: port),
      ),
    );
  }

  /// Scans the local /24 for hosts with SSH open, then lets the user pick one.
  Future<void> _findPi() async {
    // Capture the navigator up front and block back-dismissal, so the dialog we
    // pop after the scan is guaranteed to be this progress dialog (never some
    // other topmost route).
    final navigator = Navigator.of(context, rootNavigator: true);
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _ScanProgressDialog(onCancel: () {
          if (cancelled) return; // guard: a double-tap must not pop the page too
          cancelled = true;
          navigator.pop();
        }),
      ),
    );
    var hosts = const <String>[];
    try {
      hosts = await _piFinder();
    } catch (_) {
      // fail-soft: treated as "nothing found" below
    }
    // The (bounded) scan still finishes in the background; if the user already
    // cancelled, the dialog is gone — just drop the result.
    if (cancelled) return;
    navigator.pop(); // dismiss the progress dialog (topmost by construction)
    if (!mounted) return;
    if (hosts.isEmpty) {
      _snack('Keine SSH-Geräte im WLAN gefunden – IP bitte manuell eintragen.');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Gefundene Geräte (SSH offen)',
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: const Text('Nur im selben WLAN. Tippen zum Übernehmen.'),
            ),
            for (final ip in hosts)
              ListTile(
                dense: true,
                leading: const Icon(Icons.dns_outlined, size: 18),
                title: Text(ip),
                onTap: () {
                  setState(() => _host.text = ip);
                  _scheduleSave();
                  Navigator.pop(ctx);
                  _snack('Host auf $ip gesetzt.');
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Silent read-only status check on launch (opt-in). Pre-fills the version
  /// badge + status without entering the busy state or clearing the log.
  Future<void> _autoStatus() async {
    if (_busy || !_autoCheck || _host.text.trim().isEmpty) return;
    final port = int.tryParse(_port.text.trim());
    if (port == null) return;
    if (_authMode == AuthMode.password && _password.text.isEmpty) return;
    if (_authMode == AuthMode.key && _privateKey.text.trim().isEmpty) return;
    try {
      // Silent launch check stays password-free: never escalate docker to sudo
      // here (that only happens on an explicit "Verbindung testen"/update).
      final d = await _updater.detectInstall(
        config: _configFor(port),
        onLog: (_) {},
        allowSudoForDocker: false,
      );
      // Don't clobber the banner if the user kicked off a real action meanwhile.
      if (!mounted || _busy) return;
      setState(() {
        switch (d.kind) {
          case InstallKind.apt:
            _versionBefore = d.aptVersion;
            _versionAfter = null;
            _statusMessage = 'evcc ${d.aptVersion} (apt), '
                'Dienst ${d.serviceActive ? 'aktiv' : 'inaktiv'}.';
            _statusOk = true;
          case InstallKind.docker:
            _versionBefore = null;
            _versionAfter = null;
            _statusMessage =
                'evcc via Docker (Container "${d.container!.name}").';
            _statusOk = true;
          case InstallKind.unknown:
            break; // stay silent at launch when nothing is found
        }
      });
    } catch (_) {
      // silent — never disrupt launch
    }
  }

  void _addHistory(String text) {
    _historyStore.add(HistoryEntry(
      when: formatTimestamp(DateTime.now()),
      text: text,
    ));
  }

  String _notesExcerpt(String s) {
    final t = s.trim();
    if (t.isEmpty) return 'Neue evcc-Version verfügbar.';
    return t.length > 500 ? '${t.substring(0, 500)} …' : t;
  }

  Future<void> _showHistory() async {
    final entries = await _historyStore.load();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: entries.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch kein Verlauf.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text('Verlauf',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    trailing: TextButton(
                      onPressed: () async {
                        await _historyStore.clear();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Leeren'),
                    ),
                  ),
                  for (final e in entries.reversed)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(e.text),
                      subtitle: Text(e.when),
                    ),
                ],
              ),
      ),
    );
  }

  // ---- helpers -------------------------------------------------------------

  void _appendLog(String line) {
    if (!mounted) return;
    // Defense in depth: redact the live password from anything we log.
    setState(() => _log.add(redactPassword(line, _password.text)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  String _evccUiUrl() {
    final port = _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim();
    return '$_uiScheme://${_host.text.trim()}:$port';
  }

  void _openEvccUi() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    _openUrl(_evccUiUrl());
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _snack('Konnte den Link nicht öffnen.');
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Weiter'),
          ),
        ],
      ),
    );
    return r == true && mounted;
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Einstellungen',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('App mit Biometrie/PIN sperren'),
                  subtitle: const Text('Beim Öffnen & nach dem Wechsel'),
                  value: _lockEnabled,
                  onChanged: (v) async {
                    if (v && !await _authenticator.canAuthenticate()) {
                      _snack('Keine Biometrie/PIN auf dem Gerät eingerichtet.');
                      return;
                    }
                    setState(() => _lockEnabled = v);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Beim Start Status prüfen'),
                  subtitle:
                      const Text('Liest evcc-Version + Dienststatus automatisch'),
                  value: _autoCheck,
                  onChanged: (v) {
                    setState(() => _autoCheck = v);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Vor Update Backup anlegen'),
                  subtitle: const Text(
                      'Sichert evcc.yaml + Datenbank auf dem Pi (apt-Update)'),
                  value: _backupBeforeUpdate,
                  onChanged: (v) {
                    setState(() => _backupBeforeUpdate = v);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('evcc-Oberfläche über HTTPS'),
                  subtitle: Text(_uiScheme == 'https'
                      ? 'https://…'
                      : 'http://… (Standard)'),
                  value: _uiScheme == 'https',
                  onChanged: (v) {
                    setState(() => _uiScheme = v ? 'https' : 'http');
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _uiPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'evcc-Oberfläche: Port',
                    helperText: 'Standard 7070',
                  ),
                ),
                const SizedBox(height: 16),
                Text('Design', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('System')),
                    ButtonSegment(value: 'light', label: Text('Hell')),
                    ButtonSegment(value: 'dark', label: Text('Dunkel')),
                  ],
                  selected: {_themeMode},
                  onSelectionChanged: (s) {
                    setState(() => _themeMode = s.first);
                    themeModeNotifier.value = parseThemeMode(s.first);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('evcc-Nightly installieren'),
                  subtitle: const Text(
                      'unstable-Kanal statt stable (nur bei Neuinstallation)'),
                  value: _channel == 'unstable',
                  onChanged: (v) {
                    setState(() => _channel = v ? 'unstable' : 'stable');
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_locked) return _LockScreen(onUnlock: _tryUnlock);

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Pi-Tool',
            style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
                color: theme.colorScheme.primary)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'api':
                  _showApiStatus();
                case 'status':
                  _showStatus();
                case 'restart':
                  _restartService();
                case 'reboot':
                  _reboot();
                case 'find':
                  _findPi();
                case 'share':
                  _shareLog();
                case 'history':
                  _showHistory();
                case 'settings':
                  _openSettings();
              }
            },
            // Read-only / local items stay usable during an update; only the
            // SSH-mutating items (status/restart/reboot/find) are disabled.
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'api', child: Text('evcc-Status (Live)')),
              PopupMenuItem(
                  value: 'status',
                  enabled: !_busy,
                  child: const Text('Status / Logs anzeigen')),
              PopupMenuItem(
                  value: 'restart',
                  enabled: !_busy,
                  child: const Text('evcc-Dienst neustarten')),
              PopupMenuItem(
                  value: 'reboot',
                  enabled: !_busy,
                  child: const Text('Pi neustarten')),
              const PopupMenuDivider(),
              PopupMenuItem(
                  value: 'find',
                  enabled: !_busy,
                  child: const Text('Pi im Netzwerk suchen')),
              const PopupMenuItem(value: 'share', child: Text('Log teilen')),
              const PopupMenuItem(value: 'history', child: Text('Verlauf')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'settings', child: Text('Einstellungen')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ProfileBar(
              profiles: _profiles,
              activeIndex: _activeIndex.clamp(0, _profiles.length - 1),
              enabled: !_busy,
              onSwitch: _switchProfile,
              onAdd: _addProfile,
              onRename: _renameActiveProfile,
              onDelete: _profiles.length > 1 ? _deleteActiveProfile : null,
            ),
            const SizedBox(height: 8),
            if (_update != null) ...[
              _UpdateBanner(
                release: _update!,
                onDownload: () => _openUrl(_update!.downloadUrl),
                onDismiss: () => setState(() => _update = null),
              ),
              const SizedBox(height: 8),
            ],
            _ConnectionCard(
              host: _host,
              port: _port,
              user: _user,
              password: _password,
              privateKey: _privateKey,
              keyPassphrase: _keyPassphrase,
              authMode: _authMode,
              obscure: _obscure,
              enabled: !_busy,
              onToggleObscure: () => setState(() => _obscure = !_obscure),
              onAuthMode: (m) {
                setState(() => _authMode = m);
                _scheduleSave();
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _fullUpgrade,
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _fullUpgrade = v);
                      _scheduleSave();
                    },
              title: const Text('Komplettes System-Upgrade'),
              subtitle: Text(_fullUpgrade
                  ? 'apt-get full-upgrade (alle Pakete)'
                  : 'Aus → nur evcc wird aktualisiert'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            const SizedBox(height: 8),
            if (_versionBefore != null)
              _VersionBadge(before: _versionBefore, after: _versionAfter),
            if (_versionBefore != null) const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(dryRun: false),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt),
              label: Text(_busy
                  ? 'Läuft …'
                  : (_fullUpgrade
                      ? 'Alle Pakete aktualisieren'
                      : 'evcc aktualisieren')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testConnection,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Verbindung testen'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(dryRun: true),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Probelauf (ändert nichts)'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('Erstinstallation auf neuem Pi',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _install,
              icon: const Icon(Icons.install_mobile),
              label: const Text('evcc installieren'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              _StatusBanner(message: _statusMessage!, ok: _statusOk),
            ],
            if (_hostKeyIssue) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _trustAndRetry,
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('Pi neu aufgesetzt → neuen Key vertrauen'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
            if (_setupUrl != null) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => _openUrl(_setupUrl!),
                icon: const Icon(Icons.open_in_new),
                label: const Text('evcc-Einrichtung öffnen'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
            const SizedBox(height: 12),
            Text('Live-Log', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            _LogView(lines: _log, controller: _logScroll),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _openEvccUi,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('evcc-Oberfläche öffnen'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kEvccPlayStoreUrl),
                  icon: const Icon(Icons.shop_outlined, size: 18),
                  label: const Text('Offizielle evcc-App'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kReleasesUrl),
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Changelog'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kPrivacyUrl),
                  icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                  label: const Text('Datenschutz'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kImpressumUrl),
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('Impressum'),
                ),
                TextButton.icon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'Pi-Tool (inoffiziell, für evcc)',
                    applicationLegalese:
                        '© 2026 KYTH. Systems UG (haftungsbeschränkt) i.G.',
                  ),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('Open-Source-Lizenzen'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Nutzung auf eigene Gefahr – keine Haftung für Schäden am '
              'System. Inoffizielles Tool, nicht mit evcc verbunden.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

