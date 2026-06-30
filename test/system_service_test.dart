import 'package:evcc_updater/src/services/system_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseOsPrettyName', () {
    test('reads PRETTY_NAME from os-release', () {
      const out = 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'
          'NAME="Debian GNU/Linux"\nVERSION_ID="12"\n';
      expect(parseOsPrettyName(out), 'Debian GNU/Linux 12 (bookworm)');
    });
    test('falls back to NAME when PRETTY_NAME is absent', () {
      expect(parseOsPrettyName('NAME="Raspbian"\nVERSION_ID="11"'), 'Raspbian');
    });
    test('null on empty / unrecognised', () {
      expect(parseOsPrettyName(''), isNull);
      expect(parseOsPrettyName('garbage'), isNull);
    });
  });

  group('parsePendingUpdates', () {
    test('reads the upgraded count from an apt-get -s upgrade summary', () {
      const out = 'Reading package lists...\n'
          '12 upgraded, 0 newly installed, 0 to remove and 3 not upgraded.';
      expect(parsePendingUpdates(out), 12);
    });
    test('zero when nothing is pending', () {
      expect(
        parsePendingUpdates('0 upgraded, 0 newly installed, 0 to remove.'),
        0,
      );
    });
    test('null when the summary line is missing', () {
      expect(parsePendingUpdates('Reading package lists...'), isNull);
    });
  });

  group('parseAptUpgrades', () {
    test('lists the packages a full-upgrade simulation would upgrade', () {
      const out = 'Reading package lists...\n'
          'Inst evcc [0.310.0] (0.311.0 evcc:armhf [armhf])\n'
          'Inst libfoo [1.0] (1.1 Debian:armhf [armhf])\n'
          'Conf evcc (0.311.0 evcc:armhf [armhf])\n'
          '2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.';
      final pkgs = parseAptUpgrades(out);
      expect(pkgs, containsAll(['evcc', 'libfoo']));
      expect(pkgs.length, 2);
    });
    test('empty when nothing is upgraded', () {
      expect(parseAptUpgrades('0 upgraded, 0 newly installed, 0 to remove.'),
          isEmpty);
    });
  });
}
