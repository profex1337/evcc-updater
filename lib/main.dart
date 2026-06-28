import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/evcc_updater.dart';
import 'src/parsing.dart';
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

/// evcc web UI port + the official evcc app in the Play Store.
const kEvccPort = 7070;
const kEvccPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=io.evcc.android';

class EvccPiToolApp extends StatelessWidget {
  const EvccPiToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kGreen,
      brightness: Brightness.dark,
    ).copyWith(primary: kGreen, onPrimary: Colors.black, surface: kBlack);

    return MaterialApp(
      title: 'evcc Pi-Tool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: kBlack,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBlack,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const UpdaterPage(),
    );
  }
}

class UpdaterPage extends StatefulWidget {
  /// [store], [updater] and [updateChecker] are injectable so widget tests can
  /// avoid real platform channels, real SSH and real network calls.
  const UpdaterPage({
    super.key,
    this.store,
    this.updater,
    this.updateChecker,
  });

  final SettingsStore? store;
  final EvccUpdater? updater;
  final UpdateChecker? updateChecker;

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage>
    with WidgetsBindingObserver {
  late final SettingsStore _store = widget.store ?? SettingsStore();
  late final EvccUpdater _updater = widget.updater ?? EvccUpdater.real();
  late final UpdateChecker _updateChecker =
      widget.updateChecker ?? UpdateChecker();

  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'pi');
  final _password = TextEditingController();
  final _logScroll = ScrollController();

  bool _fullUpgrade = false;
  bool _obscure = true;
  bool _busy = false;

  final List<String> _log = [];
  String? _versionBefore;
  String? _versionAfter;
  String? _statusMessage;
  bool _statusOk = true;
  ReleaseInfo? _update;
  String? _setupUrl;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _checkForUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist immediately when the app leaves the foreground.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveDebounce?.cancel();
      _persistSettings();
    }
  }

  /// Debounced auto-save: persists ~0.8s after the last edit.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _persistSettings);
  }

  Future<void> _persistSettings() => _store.save(_currentSettings());

  /// Fail-soft update check: if a newer GitHub release exists, surface a banner.
  /// Any error (no network, running under Play/F-Droid, test env) is ignored.
  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final release = await _updateChecker.checkForUpdate(info.version);
      if (release != null && mounted) {
        setState(() => _update = release);
      }
    } catch (_) {
      // never let the update check disrupt the app
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _snack('Konnte den Link nicht öffnen.');
    }
  }

  /// Opens the evcc web UI at the entered host (default scheme http on :7070,
  /// the evcc default; adjust if you run evcc behind https).
  void _openEvccUi() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    _openUrl('http://$host:$kEvccPort');
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _persistSettings(); // reads controllers synchronously before they're gone
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final s = await _store.load();
    if (!mounted) return;
    setState(() {
      _host.text = s.host;
      _port.text = s.port;
      _user.text = s.username;
      _password.text = s.password;
      _fullUpgrade = s.fullUpgrade;
    });
    // Attach auto-save listeners AFTER the initial values are in place, so the
    // load itself doesn't trigger a redundant save.
    _host.addListener(_scheduleSave);
    _port.addListener(_scheduleSave);
    _user.addListener(_scheduleSave);
    _password.addListener(_scheduleSave);
  }

  Settings _currentSettings() => Settings(
        host: _host.text.trim(),
        port: _port.text.trim().isEmpty ? '22' : _port.text.trim(),
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        fullUpgrade: _fullUpgrade,
      );

  /// Validates the inputs and returns the port, or null (after a SnackBar) when
  /// something is missing/invalid.
  int? _validatedPort() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte Host/IP eintragen.');
      return null;
    }
    if (_password.text.isEmpty) {
      _snack('Bitte Pi-Passwort eintragen.');
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
        timeout: const Duration(seconds: 15),
      );

  void _beginBusy() {
    setState(() {
      _busy = true;
      _log.clear();
      _statusMessage = null;
      _versionAfter = null;
      _setupUrl = null;
    });
  }

  void _appendLog(String line) {
    if (!mounted) return;
    // Defense in depth: redact the live password from anything we log, so even
    // UI-originated lines (e.g. error messages) can never leak it.
    setState(() => _log.add(redactPassword(line, _password.text)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run({required bool dryRun}) async {
    final port = _validatedPort();
    if (port == null) return;
    await _store.save(_currentSettings());
    _beginBusy();

    try {
      final summary = await _updater.run(
        config: _configFor(port),
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
    } on EvccUpdateException catch (e) {
      _appendLog('FEHLER: ${e.message}');
      if (!mounted) return;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
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

  Future<void> _testConnection() async {
    final port = _validatedPort();
    if (port == null) return;
    await _store.save(_currentSettings());
    _beginBusy();

    try {
      final info = await _updater.testConnection(
        config: _configFor(port),
        onLog: _appendLog,
      );
      if (!mounted) return;
      setState(() {
        _versionBefore = info.version;
        _versionAfter = null;
        _statusMessage = 'Verbindung OK – evcc ${info.version}, '
            'Dienst ${info.serviceActive ? 'aktiv' : 'inaktiv'}.';
        _statusOk = true;
      });
    } on EvccUpdateException catch (e) {
      _appendLog('FEHLER: ${e.message}');
      if (!mounted) return;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
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

  Future<void> _install() async {
    final port = _validatedPort();
    if (port == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('evcc installieren?'),
        content: Text(
          'Installiert evcc auf ${_host.text.trim()}: fügt das offizielle '
          'evcc-Repo hinzu, installiert das Paket und startet den Dienst.\n\n'
          'Experimentell — nach offizieller evcc-Doku gebaut, aber noch nicht '
          'gegen einen frischen Pi getestet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Installieren'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _store.save(_currentSettings());
    _beginBusy();

    try {
      final res = await _updater.install(
        config: _configFor(port),
        onLog: _appendLog,
      );
      if (!mounted) return;
      setState(() {
        _versionBefore = res.version;
        _versionAfter = null;
        _statusMessage = 'evcc ${res.version} installiert, '
            'Dienst ${res.serviceActive ? 'aktiv' : 'inaktiv'}. '
            'Jetzt im Browser einrichten.';
        _statusOk = true;
        _setupUrl = 'http://${_host.text.trim()}:7070';
      });
    } on EvccUpdateException catch (e) {
      _appendLog('FEHLER: ${e.message}');
      if (!mounted) return;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
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

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('evcc ',
                style: TextStyle(
                    fontWeight: FontWeight.w800, letterSpacing: 0.3)),
            Text('Pi-Tool',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: kGreen)),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
              obscure: _obscure,
              enabled: !_busy,
              onToggleObscure: () => setState(() => _obscure = !_obscure),
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
                const Expanded(child: Divider(color: Colors.white12)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('Erstinstallation auf neuem Pi',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.white54)),
                ),
                const Expanded(child: Divider(color: Colors.white12)),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _install,
              icon: const Icon(Icons.install_mobile),
              label: const Text('evcc installieren (experimentell)'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              _StatusBanner(message: _statusMessage!, ok: _statusOk),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.obscure,
    required this.enabled,
    required this.onToggleObscure,
  });

  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final TextEditingController password;
  final bool obscure;
  final bool enabled;
  final VoidCallback onToggleObscure;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: kCard,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Colors.white10),
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
                    decoration: const InputDecoration(
                      labelText: 'Port',
                    ),
                  ),
                ),
              ],
            ),
            TextField(
              controller: password,
              enabled: enabled,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Passwort',
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
