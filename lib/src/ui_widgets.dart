part of '../main.dart';

// Presentational widgets + sheets for the updater screen, split out of
// main.dart. Kept as a part so they stay library-private and share the
// top-level theme constants (kGreen/kBlack/kCard) without re-importing.

enum _ProfileAction { rename, delete }

/// Active-Pi selector. A bordered card matching [_ConnectionCard]; each profile
/// is a one-tap ChoiceChip (active one filled green), with a tinted "+ Profil"
/// add chip and rename/delete folded into a single overflow menu.
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
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final chips = <Widget>[
      for (var i = 0; i < profiles.length; i++)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(profiles[i].name, overflow: TextOverflow.ellipsis),
            selected: i == activeIndex,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selectedColor: kGreen,
            backgroundColor: Colors.transparent,
            labelStyle: TextStyle(
              color: i == activeIndex ? kBlack : cs.onSurface,
              fontWeight:
                  i == activeIndex ? FontWeight.w600 : FontWeight.w500,
            ),
            shape: StadiumBorder(
              side: BorderSide(
                color: i == activeIndex
                    ? Colors.transparent
                    : (dark ? Colors.white24 : cs.outlineVariant),
              ),
            ),
            onSelected: enabled ? (_) => onSwitch(i) : null,
          ),
        ),
      Tooltip(
        message: 'Neues Profil',
        child: ActionChip(
          avatar: Icon(Icons.add,
              size: 18, color: enabled ? kGreen : cs.onSurfaceVariant),
          label: const Text('Profil'),
          visualDensity: VisualDensity.compact,
          backgroundColor: kGreen.withValues(alpha: dark ? 0.10 : 0.08),
          shape: StadiumBorder(
              side: BorderSide(color: kGreen.withValues(alpha: 0.5))),
          onPressed: enabled ? onAdd : null,
        ),
      ),
    ];

    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.6,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: dark ? kCard : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: dark ? Colors.white10 : cs.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: chips),
                ),
              ),
              PopupMenuButton<_ProfileAction>(
                enabled: enabled,
                tooltip: 'Profil-Aktionen',
                icon: const Icon(Icons.more_vert),
                onSelected: (a) {
                  switch (a) {
                    case _ProfileAction.rename:
                      onRename();
                    case _ProfileAction.delete:
                      onDelete?.call();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _ProfileAction.rename,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Profil umbenennen'),
                    ),
                  ),
                  if (onDelete != null)
                    PopupMenuItem(
                      value: _ProfileAction.delete,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline, color: cs.error),
                        title: Text('Profil löschen',
                            style: TextStyle(color: cs.error)),
                      ),
                    ),
                ],
              ),
            ],
          ),
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
            const Text('Pi-Tool',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, color: kGreen)),
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
  const _ScanProgressDialog({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: const Row(
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
      actions: [
        TextButton(onPressed: onCancel, child: const Text('Abbrechen')),
      ],
    );
  }
}
