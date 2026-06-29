/// Pure parsing and summarising of the output produced by the update sequence.
///
/// Kept free of I/O so every edge case can be unit-tested without a real SSH
/// session.
library;

/// Fixed-length mask used to redact the password from any visible text.
const String passwordMask = '********';

/// Parses the `dpkg-query` version output.
///
/// Returns the trimmed version string, or `null` when the package is not
/// installed (empty / whitespace-only output).
String? parseInstalledVersion(String dpkgOutput) {
  final trimmed = dpkgOutput.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Matches apt's "0 upgraded, 0 newly installed" summary, but only when the
/// count is a real zero — a leading digit (e.g. "10 upgraded") must not match.
final _nothingToUpgrade =
    RegExp(r'(?<!\d)0 upgraded, 0 newly installed');

/// Whether apt reports that nothing needs upgrading.
///
/// Note: for a full-upgrade this reflects the WHOLE system, not just evcc.
bool isAlreadyNewest(String aptOutput) {
  final out = aptOutput.toLowerCase();
  // A held-back package means an upgrade exists but is blocked — not "current".
  if (out.contains('kept back')) return false;
  return out.contains('is already the newest version') ||
      _nothingToUpgrade.hasMatch(out);
}

/// Extracts the backup archive path from the backup script's success marker
/// (`EVCC_BACKUP_OK ...`), or null when no backup was written.
String? parseBackupPath(String output) {
  const marker = 'EVCC_BACKUP_OK ';
  for (final line in output.split('\n')) {
    final t = line.trim();
    if (t.startsWith(marker)) {
      final path = t.substring(marker.length).trim();
      if (path.isNotEmpty) return path;
    }
  }
  return null;
}

/// Whether `systemctl is-active` reports the service as running.
bool isServiceActive(String systemctlOutput) {
  return systemctlOutput.trim() == 'active';
}

/// Whether the output indicates that sudo rejected the password.
bool isSudoPasswordFailure(String output) {
  final out = output.toLowerCase();
  return out.contains('incorrect password') || out.contains('sorry, try again');
}

/// Replaces every literal occurrence of [password] in [text] with
/// [passwordMask]. An empty [password] leaves [text] untouched.
String redactPassword(String text, String password) {
  if (password.isEmpty) return text;
  return text.replaceAll(password, passwordMask);
}

/// Outcome category of a completed update run.
enum UpdateStatus {
  updated,
  alreadyCurrent,
  dryRunWouldUpdate,
  dryRunNoChange,
}

/// A human-facing summary of the run.
class UpdateSummary {
  final UpdateStatus status;
  final String message;
  final String? before;
  final String? after;

  const UpdateSummary({
    required this.status,
    required this.message,
    required this.before,
    required this.after,
  });
}

/// Turns the collected facts into a clear German result message.
///
/// [alreadyNewest] is interpreted in the scope of the chosen mode: for an
/// evcc-only run it means "evcc is current", for a [fullUpgrade] it means "the
/// whole system is current". The wording is branched accordingly so a
/// system-wide plan is never misreported as an evcc-specific update.
UpdateSummary summarize({
  required String? before,
  required String? after,
  required bool dryRun,
  required bool fullUpgrade,
  required bool alreadyNewest,
}) {
  if (dryRun) {
    if (fullUpgrade) {
      return UpdateSummary(
        status: alreadyNewest
            ? UpdateStatus.dryRunNoChange
            : UpdateStatus.dryRunWouldUpdate,
        message: alreadyNewest
            ? 'Probelauf: System ist komplett aktuell (evcc $before).'
            : 'Probelauf: System-Updates verfügbar (evcc installiert: $before).',
        before: before,
        after: after,
      );
    }
    return UpdateSummary(
      status: alreadyNewest
          ? UpdateStatus.dryRunNoChange
          : UpdateStatus.dryRunWouldUpdate,
      message: alreadyNewest
          ? 'Probelauf: evcc ist bereits aktuell ($before).'
          : 'Probelauf: Update für evcc verfügbar (installiert: $before).',
      before: before,
      after: after,
    );
  }

  final evccChanged = after != null && before != after;
  if (evccChanged) {
    return UpdateSummary(
      status: UpdateStatus.updated,
      message: 'evcc $before → $after aktualisiert.',
      before: before,
      after: after,
    );
  }

  if (fullUpgrade && !alreadyNewest) {
    return UpdateSummary(
      status: UpdateStatus.alreadyCurrent,
      message: 'evcc war schon aktuell ($before); '
          'übrige System-Pakete wurden aktualisiert.',
      before: before,
      after: after,
    );
  }

  return UpdateSummary(
    status: UpdateStatus.alreadyCurrent,
    message: 'evcc war schon aktuell ($before).',
    before: before,
    after: after,
  );
}
