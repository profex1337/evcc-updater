import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHomeAssistant', () {
    test('finds the homeassistant container in docker ps output', () {
      const out = 'pihole|pihole/pihole:latest\n'
          'homeassistant|ghcr.io/home-assistant/home-assistant:stable\n'
          'evcc|evcc/evcc:0.123';
      final c = parseHomeAssistant(out);
      expect(c, isNotNull);
      expect(c!.name, 'homeassistant');
      expect(c.image, 'ghcr.io/home-assistant/home-assistant:stable');
      expect(c.version, 'stable');
    });

    test('matches by image even with a non-standard container name', () {
      final c = parseHomeAssistant(
          'hass|ghcr.io/home-assistant/home-assistant:2024.6');
      expect(c, isNotNull);
      expect(c!.name, 'hass');
      expect(c.version, '2024.6');
    });

    test('untagged image falls back to the full image as version', () {
      final c = parseHomeAssistant(
          'homeassistant|ghcr.io/home-assistant/home-assistant');
      expect(c, isNotNull);
      expect(c!.version, isNotEmpty);
    });

    test('digest-pinned image shows a label, not the raw sha256 hex', () {
      final c = parseHomeAssistant('homeassistant|ghcr.io/home-assistant/'
          'home-assistant@sha256:0123456789abcdef0123456789abcdef0123456789'
          'abcdef0123456789abcdef01');
      expect(c, isNotNull);
      expect(c!.version, 'digest-pinned');
    });

    test('null when no Home Assistant container is present', () {
      expect(
          parseHomeAssistant('evcc|evcc/evcc:latest\npihole|pihole/pihole'),
          isNull);
      expect(parseHomeAssistant(''), isNull);
    });
  });

  group('buildHomeAssistantInstallScript', () {
    final s = buildHomeAssistantInstallScript();

    test('runs the official container with host network + /config volume', () {
      expect(s, contains('ghcr.io/home-assistant/home-assistant:stable'));
      expect(s, contains('--name homeassistant'));
      expect(s, contains('--network=host'));
      expect(s, contains(':/config'));
      expect(s, contains('--restart=unless-stopped'));
    });

    test('installs Docker when missing and is idempotent', () {
      expect(s, contains('get.docker.com'));
      expect(s, contains('grep -qx homeassistant'));
    });
  });
}
