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
        title: 'evcc Pi-Tool',
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
  });

  final AppConfigStore? store;
  final EvccUpdater? updater;
  final UpdateChecker? updateChecker;
  final Authenticator? authenticator;
  final EvccApiClient? apiClient;

  /// Discovers reachable SSH hosts on the local network. Injectable for tests.
  final Future<List<String>> Function()? piFinder;

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

  void _deleteActiveProfile() {
    if (_profiles.length <= 1) return;
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
      final ok = await _authenticator.authenticate('evcc Pi-Tool entsperren');
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
      _appendLog('FEHLER: $e');
      if (!mounted) return;
      setState(() {
        _statusMessage =
            redactPassword('Unerwarteter Fehler: $e', _password.text);
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
      final rel = await fetchEvccRelease();
      if (!mounted) return;
      final proceed = rel == null ||
          await _confirm(
              'evcc ${rel.version} installieren?', _notesExcerpt(rel.notes));
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
          'evcc-Repo hinzu, installiert das Paket und startet den Dienst.',
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
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: _ScanProgressDialog(),
      ),
    );
    var hosts = const <String>[];
    try {
      hosts = await _piFinder();
    } catch (_) {
      // fail-soft: treated as "nothing found" below
    }
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('evcc ',
                style: TextStyle(
                    fontWeight: FontWeight.w800, letterSpacing: 0.3)),
            Text('Pi-Tool',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: theme.colorScheme.primary)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
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
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'api', child: Text('evcc-Status (Live)')),
              PopupMenuItem(
                  value: 'status', child: Text('Status / Logs anzeigen')),
              PopupMenuItem(
                  value: 'restart', child: Text('evcc-Dienst neustarten')),
              PopupMenuItem(value: 'reboot', child: Text('Pi neustarten')),
              PopupMenuDivider(),
              PopupMenuItem(
                  value: 'find', child: Text('Pi im Netzwerk suchen')),
              PopupMenuItem(value: 'share', child: Text('Log teilen')),
              PopupMenuItem(value: 'history', child: Text('Verlauf')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'settings', child: Text('Einstellungen')),
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
              label: Text(_busy ? 'Läuft …' : 'evcc aktualisieren'),
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

class _ProfileBar extends StatelessWidget {
  const _ProfileBar({
    required this.profiles,
    required this.activeIndex,
    required this.enabled,
    required this.onSwitch,
    required this.onAdd,
    required this.onRename,
    this.onDelete,
  });

  final List<Profile> profiles;
  final int activeIndex;
  final bool enabled;
  final ValueChanged<int> onSwitch;
  final VoidCallback onAdd;
  final VoidCallback onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.dns_outlined, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<int>(
            value: activeIndex,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            onChanged: enabled
                ? (i) {
                    if (i != null) onSwitch(i);
                  }
                : null,
            items: [
              for (var i = 0; i < profiles.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(profiles[i].name,
                      overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: enabled ? onRename : null,
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Profil umbenennen',
        ),
        IconButton(
          onPressed: enabled ? onAdd : null,
          icon: const Icon(Icons.add),
          tooltip: 'Neues Profil',
        ),
        IconButton(
          onPressed: (enabled && onDelete != null) ? onDelete : null,
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Profil löschen',
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.privateKey,
    required this.keyPassphrase,
    required this.authMode,
    required this.obscure,
    required this.enabled,
    required this.onToggleObscure,
    required this.onAuthMode,
  });

  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final TextEditingController password;
  final TextEditingController privateKey;
  final TextEditingController keyPassphrase;
  final AuthMode authMode;
  final bool obscure;
  final bool enabled;
  final VoidCallback onToggleObscure;
  final ValueChanged<AuthMode> onAuthMode;

  @override
  Widget build(BuildContext context) {
    final keyMode = authMode == AuthMode.key;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: dark ? kCard : cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: dark ? Colors.white10 : cs.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            TextField(
              controller: host,
              enabled: enabled,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Host / IP',
                hintText: 'z. B. 192.168.178.64 oder Tailscale-IP',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: user,
                    enabled: enabled,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Benutzer',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: port,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<AuthMode>(
              segments: const [
                ButtonSegment(
                    value: AuthMode.password,
                    label: Text('Passwort'),
                    icon: Icon(Icons.password)),
                ButtonSegment(
                    value: AuthMode.key,
                    label: Text('SSH-Key'),
                    icon: Icon(Icons.vpn_key_outlined)),
              ],
              selected: {authMode},
              onSelectionChanged:
                  enabled ? (s) => onAuthMode(s.first) : null,
            ),
            if (keyMode) ...[
              TextField(
                controller: privateKey,
                enabled: enabled,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Privater SSH-Key (PEM)',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY----- …',
                  alignLabelWithHint: true,
                ),
              ),
              TextField(
                controller: keyPassphrase,
                enabled: enabled,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Key-Passphrase (optional)',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
            ],
            TextField(
              controller: password,
              enabled: enabled,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: keyMode ? 'sudo-Passwort' : 'Passwort',
                helperText: keyMode
                    ? 'für sudo auf dem Pi (leer lassen bei NOPASSWD-sudo)'
                    : null,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: onToggleObscure,
                  icon: Icon(
                      obscure ? Icons.visibility : Icons.visibility_off),
                  tooltip: obscure ? 'Anzeigen' : 'Verbergen',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog that owns its text controller (disposed via its own State lifecycle,
/// so it isn't used-after-dispose during the dialog's exit animation).
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBlack,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, color: kGreen, size: 56),
            const SizedBox(height: 12),
            const Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: 'evcc ',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: Colors.white)),
                TextSpan(
                    text: 'Pi-Tool',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: kGreen)),
              ]),
              style: TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 6),
            const Text('Gesperrt', style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.lock_open),
              label: const Text('Entsperren'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge({required this.before, required this.after});

  final String? before;
  final String? after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changed = after != null && before != after;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt, size: 18),
          const SizedBox(width: 8),
          Text('evcc ', style: theme.textTheme.bodyMedium),
          Text(before ?? '—',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (changed) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward, size: 16),
            ),
            Text(after!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                )),
          ],
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.ok});

  final String message;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = ok ? scheme.primaryContainer : scheme.errorContainer;
    final fg = ok ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: fg))),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.release,
    required this.onDownload,
    required this.onDismiss,
  });

  final ReleaseInfo release;
  final VoidCallback onDownload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Update ${release.version} verfügbar',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
          TextButton(onPressed: onDownload, child: const Text('Laden')),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onTertiaryContainer),
            tooltip: 'Ausblenden',
          ),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines, required this.controller});

  final List<String> lines;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 240,
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF11140F),
        borderRadius: BorderRadius.circular(10),
      ),
      child: lines.isEmpty
          ? const Text(
              'Noch keine Ausgabe. Tippe „evcc aktualisieren" oder „Probelauf".',
              style: TextStyle(color: Color(0xFF8A8F84), fontSize: 13),
            )
          : SingleChildScrollView(
              controller: controller,
              child: SelectableText(
                lines.join('\n'),
                style: const TextStyle(
                  color: Color(0xFFB8F2C9),
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
    );
  }
}

/// Bottom sheet that shows evcc's live state, fetched read-only from its
/// Web-API. Loading / error / data are all rendered defensively.
class _ApiStatusSheet extends StatelessWidget {
  const _ApiStatusSheet({required this.future});

  final Future<EvccState> future;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: FutureBuilder<EvccState>(
          future: future,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              final e = snap.error;
              final msg = e is EvccApiException
                  ? e.message
                  : 'Live-Status nicht verfügbar.';
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('evcc-Live-Status', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(child: Text(msg)),
                    ],
                  ),
                ],
              );
            }
            return _stateView(ctx, snap.data!);
          },
        ),
      ),
    );
  }

  Widget _stateView(BuildContext ctx, EvccState s) {
    final theme = Theme.of(ctx);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, color: kGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.siteTitle ?? 'evcc-Status',
                    style: theme.textTheme.titleMedium),
              ),
              if (s.version != null)
                Text('v${s.version}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          _metric(ctx, Icons.solar_power_outlined, 'PV-Erzeugung',
              formatPower(s.pvPower)),
          _metric(ctx, Icons.swap_vert, 'Netz', formatPower(s.gridPower)),
          _metric(ctx, Icons.home_outlined, 'Hausverbrauch',
              formatPower(s.homePower)),
          if (s.batteryConfigured)
            _metric(
              ctx,
              Icons.battery_charging_full,
              'Batterie',
              '${s.batterySoc != null ? '${s.batterySoc!.round()} %' : '—'}'
                  '  ·  ${formatPower(s.batteryPower)}',
            ),
          if (s.loadpoints.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Ladepunkte', style: theme.textTheme.labelLarge),
            for (final lp in s.loadpoints) _loadpoint(ctx, lp),
          ],
          const SizedBox(height: 8),
          Text('Live aus der evcc-Web-API (nur Anzeige).',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _metric(BuildContext ctx, IconData icon, String label, String value) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _loadpoint(BuildContext ctx, EvccLoadpoint lp) {
    final theme = Theme.of(ctx);
    final bits = <String>[];
    if (lp.mode != null) bits.add('Modus ${lp.mode}');
    bits.add(lp.charging
        ? 'lädt ${formatPower(lp.chargePower)}'
        : (lp.connected ? 'verbunden' : 'frei'));
    if (lp.vehicleSoc != null) bits.add('Fahrzeug ${lp.vehicleSoc!.round()} %');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        lp.charging ? Icons.ev_station : Icons.ev_station_outlined,
        color: lp.charging ? kGreen : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(lp.title),
      subtitle: Text(bits.join('  ·  ')),
    );
  }
}

/// Modal progress shown while the local network is being scanned for Pis.
class _ScanProgressDialog extends StatelessWidget {
  const _ScanProgressDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Flexible(child: Text('Suche SSH-Geräte im WLAN …')),
        ],
      ),
    );
  }
}
