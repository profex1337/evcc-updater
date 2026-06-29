import 'package:flutter_test/flutter_test.dart';
import 'package:evcc_updater/src/commands.dart';

void main() {
  group('buildUpdateSteps', () {
    test('evcc-only real run produces the validated SSH sequence in order', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: false);

      expect(steps.map((s) => s.command).toList(), [
        r"dpkg-query -W -f='${Version}' evcc",
        'LC_ALL=C sudo -S apt-get update -qq',
        'LC_ALL=C sudo -S apt-get install --only-upgrade -y evcc',
        'systemctl is-active evcc',
        r"dpkg-query -W -f='${Version}' evcc",
      ]);
    });

    test('only the two apt-get steps require the sudo password on stdin', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: false);

      expect(steps.map((s) => s.needsSudoPassword).toList(),
          [false, true, true, false, false]);
    });

    test('full upgrade swaps the upgrade step for apt-get full-upgrade -y', () {
      final steps = buildUpdateSteps(fullUpgrade: true, dryRun: false);

      expect(steps[2].command, 'LC_ALL=C sudo -S apt-get full-upgrade -y');
    });

    test('dry-run (evcc-only) adds --dry-run and drops -y', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: true);

      expect(steps[2].command,
          'LC_ALL=C sudo -S apt-get install --only-upgrade --dry-run evcc');
    });

    test('dry-run (full upgrade) uses full-upgrade --dry-run', () {
      final steps = buildUpdateSteps(fullUpgrade: true, dryRun: true);

      expect(steps[2].command, 'LC_ALL=C sudo -S apt-get full-upgrade --dry-run');
    });

    test('every step carries a non-empty human label', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: false);

      expect(steps.every((s) => s.label.trim().isNotEmpty), isTrue);
    });
  });

  group('buildInstallScript', () {
    final script = buildInstallScript();

    test('installs the evcc package', () {
      expect(script, contains('apt-get install -y evcc'));
    });

    test('adds the official evcc apt repo via the setup script', () {
      expect(
        script,
        contains('https://dl.evcc.io/public/evcc/stable/setup.deb.sh'),
      );
    });

    test('uses the unstable (nightly) repo when channel is unstable', () {
      final nightly = buildInstallScript(channel: 'unstable');
      expect(
        nightly,
        contains('https://dl.evcc.io/public/evcc/unstable/setup.deb.sh'),
      );
    });

    test('enables and starts the service', () {
      expect(script, contains('systemctl enable --now evcc'));
    });

    test('installs prerequisites including curl', () {
      expect(script, contains('curl'));
    });

    test('aborts on the first error', () {
      expect(script, contains('set -e'));
    });

    test('runs non-interactively (no apt prompts)', () {
      expect(script, contains('DEBIAN_FRONTEND=noninteractive'));
    });
  });
}
