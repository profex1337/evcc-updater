/// Core, Flutter-free model for the multi-service Pi-Tool (see
/// design/2026-06-30-multi-service.md). A "service" is something the app can
/// detect, install, update and show status for on the Pi (evcc, Pi-hole,
/// System). UI-specific bits (icons, actions) live in the widget layer.
library;

/// Health/status of one service as detected on the Pi.
class ServiceStatus {
  /// Stable id: 'evcc' | 'pihole' | 'system'.
  final String id;

  /// Display name shown on the card.
  final String name;

  final bool installed;
  final String? version;

  /// Running/healthy (e.g. systemd active, DNS resolving). Meaningless when not
  /// [installed].
  final bool active;

  /// A newer version / pending updates exist. Only meaningful when
  /// [updateKnown] is true.
  final bool updateAvailable;

  /// Whether the app actually determined update availability for this service.
  /// True for apt-evcc / Pi-hole / System (we check); false where we can't know
  /// cheaply (Docker-based evcc / Home Assistant), so the UI keeps offering a
  /// plain "Aktualisieren" instead of claiming it is up to date.
  final bool updateKnown;

  /// Short human status line (mono), e.g. "Dienst aktiv" or "3 Updates".
  final String detail;

  const ServiceStatus({
    required this.id,
    required this.name,
    required this.installed,
    this.version,
    this.active = false,
    this.updateAvailable = false,
    this.updateKnown = false,
    this.detail = '',
  });

  /// A "not installed" status for a service the app knows about but didn't find.
  factory ServiceStatus.absent(String id, String name) =>
      ServiceStatus(id: id, name: name, installed: false);
}
