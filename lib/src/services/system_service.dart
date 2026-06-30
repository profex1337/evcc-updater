/// The "System (Pi)" service: OS info, pending apt updates, uptime — and the
/// whole-system upgrade / reboot actions. Pure parsers + command strings here;
/// the SSH orchestration is added in a later phase. See
/// design/2026-06-30-multi-service.md.
library;

/// Reads `/etc/os-release` (no sudo).
const String systemOsCommand = 'cat /etc/os-release';

/// Simulates an upgrade to count pending updates (no sudo, no list refresh).
const String systemPendingCommand = 'LC_ALL=C apt-get -s upgrade';

/// Human-readable uptime (no sudo).
const String systemUptimeCommand = 'uptime -p';

final _prettyName = RegExp(r'^\s*PRETTY_NAME="?([^"\n]+)"?', multiLine: true);
final _name = RegExp(r'^\s*NAME="?([^"\n]+)"?', multiLine: true);
final _upgraded = RegExp(r'(\d+) upgraded');

/// Extracts a friendly OS name from `/etc/os-release` (PRETTY_NAME, else NAME).
String? parseOsPrettyName(String osRelease) {
  final pretty = _prettyName.firstMatch(osRelease);
  if (pretty != null) return pretty.group(1)!.trim();
  final name = _name.firstMatch(osRelease);
  return name?.group(1)?.trim();
}

/// The "N upgraded" count from an `apt-get -s upgrade` summary, or null when no
/// summary line is present.
int? parsePendingUpdates(String aptSimulateOutput) {
  final m = _upgraded.firstMatch(aptSimulateOutput);
  return m == null ? null : int.tryParse(m.group(1)!);
}
