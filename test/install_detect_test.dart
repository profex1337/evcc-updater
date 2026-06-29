import 'package:evcc_updater/src/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyInstall', () {
    test('apt wins when dpkg reports a version', () {
      expect(
        classifyInstall(dpkgOutput: '0.123.1', dockerPs: 'evcc|evcc/evcc'),
        InstallKind.apt,
      );
    });
    test('docker when no apt package but an evcc container runs', () {
      expect(
        classifyInstall(
          dpkgOutput: '',
          dockerPs: 'db|postgres:16\nevcc|evcc/evcc:latest',
        ),
        InstallKind.docker,
      );
    });
    test('unknown when neither is present', () {
      expect(
        classifyInstall(dpkgOutput: '   ', dockerPs: 'db|postgres:16'),
        InstallKind.unknown,
      );
    });
  });

  group('parseEvccDocker', () {
    test('finds the evcc container by image among others', () {
      final d = parseEvccDocker('db|postgres:16\nmy-evcc|evcc/evcc:0.123');
      expect(d, isNotNull);
      expect(d!.name, 'my-evcc');
      expect(d.image, 'evcc/evcc:0.123');
    });
    test('matches on the container name too', () {
      final d = parseEvccDocker('evcc|ghcr.io/foo/bar:1');
      expect(d!.name, 'evcc');
    });
    test('returns null when no evcc container is present', () {
      expect(parseEvccDocker('db|postgres:16\nweb|nginx'), isNull);
      expect(parseEvccDocker(''), isNull);
    });

    test('prefers the image match over a sibling matching only by name', () {
      // evcc-db (postgres) sorts first but is NOT the evcc install.
      final d = parseEvccDocker('evcc-db|postgres:16\nevcc|evcc/evcc:latest');
      expect(d!.name, 'evcc');
      expect(d.image, 'evcc/evcc:latest');
    });
  });

  group('isDockerPermissionError', () {
    test('detects the daemon permission / socket errors', () {
      expect(
        isDockerPermissionError(
            'permission denied while trying to connect to the Docker daemon socket'),
        isTrue,
      );
      expect(
        isDockerPermissionError(
            'Cannot connect to the Docker daemon at unix:///var/run/docker.sock'),
        isTrue,
      );
    });
    test('a normal listing is not a permission error', () {
      expect(isDockerPermissionError('evcc|evcc/evcc:latest'), isFalse);
      expect(isDockerPermissionError('bash: docker: command not found'), isFalse);
    });
  });

  group('parseComposeInfo', () {
    test('parses working dir + config file + service', () {
      final c = parseComposeInfo(
          '/home/pi/evcc|/home/pi/evcc/docker-compose.yml|evcc');
      expect(c, isNotNull);
      expect(c!.workingDir, '/home/pi/evcc');
      expect(c.configFile, '/home/pi/evcc/docker-compose.yml');
      expect(c.service, 'evcc');
    });
    test('returns null for a non-compose container (<no value> labels)', () {
      expect(parseComposeInfo('<no value>|<no value>|<no value>'), isNull);
      expect(parseComposeInfo('||'), isNull);
      expect(parseComposeInfo(''), isNull);
    });
    test('requires both working dir and service', () {
      expect(parseComposeInfo('/home/pi/evcc|<no value>|<no value>'), isNull);
    });
    test('rejects a tampered service name or a non-absolute working dir', () {
      // A service containing shell metacharacters is refused outright.
      expect(parseComposeInfo('/home/pi/evcc|x|evcc;reboot'), isNull);
      expect(parseComposeInfo("/home/pi/evcc|x|ev'cc"), isNull);
      // Working dir must be an absolute path.
      expect(parseComposeInfo('home/pi/evcc|x|evcc'), isNull);
    });
  });

  group('dockerComposeUpdateScript', () {
    test('pulls then recreates only the evcc service in the project dir', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: '/home/pi/evcc',
        configFile: '/home/pi/evcc/docker-compose.yml',
        service: 'evcc',
      ));
      expect(script, contains("cd '/home/pi/evcc'"));
      expect(script, contains('set -e'));
      // v2 is probed; falls back to the v1 standalone binary.
      expect(script, contains('docker compose version'));
      expect(script, contains('docker-compose'));
      expect(script, contains(r'$DC'));
      // config file pinned with -f so a custom filename can't double-spawn.
      expect(script, contains("-f '/home/pi/evcc/docker-compose.yml'"));
      expect(script, contains("pull 'evcc'"));
      expect(script, contains("up -d 'evcc'"));
    });

    test('pins the compose project with -p when known', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: '/srv/evcc',
        configFile: '/srv/evcc/compose.yaml',
        service: 'evcc',
        project: 'myevcc',
      ));
      expect(script, contains("-p 'myevcc'"));
    });

    test('escapes single quotes so a label cannot break out of the shell', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: "/x';reboot;'",
        configFile: '',
        service: 'evcc',
      ));
      // The dangerous quote is escaped via the '\'' idiom, NOT left to close
      // the cd quoting and start a new `reboot` command.
      expect(script, contains(r"cd '/x'\''"));
      expect(script, isNot(contains("cd '/x';reboot")));
    });
  });

  group('shSingleQuote', () {
    test('wraps plain values and escapes embedded quotes', () {
      expect(shSingleQuote('evcc'), "'evcc'");
      expect(shSingleQuote("a'b"), r"'a'\''b'");
    });
  });

  group('firstInspectObject', () {
    test('takes the first element of the inspect array', () {
      final o = firstInspectObject('[{"Name":"/evcc"},{"Name":"/other"}]');
      expect(o, isNotNull);
      expect(o!['Name'], '/evcc');
    });
    test('accepts a bare object too', () {
      expect(firstInspectObject('{"Name":"/evcc"}')!['Name'], '/evcc');
    });
    test('returns null on empty / garbage / empty array', () {
      expect(firstInspectObject(''), isNull);
      expect(firstInspectObject('not json'), isNull);
      expect(firstInspectObject('[]'), isNull);
    });
  });

  group('composeInfoFromInspect', () {
    test('reads compose labels into DockerComposeInfo', () {
      final c = composeInfoFromInspect({
        'Config': {
          'Labels': {
            'com.docker.compose.project.working_dir': '/home/pi/evcc',
            'com.docker.compose.project.config_files':
                '/home/pi/evcc/docker-compose.yml',
            'com.docker.compose.service': 'evcc',
            'com.docker.compose.project': 'evcc',
          }
        },
      });
      expect(c, isNotNull);
      expect(c!.workingDir, '/home/pi/evcc');
      expect(c.service, 'evcc');
      expect(c.project, 'evcc');
    });
    test('returns null for a plain docker-run container (no compose labels)',
        () {
      expect(composeInfoFromInspect({'Config': {'Labels': {}}}), isNull);
      expect(composeInfoFromInspect({'Config': {}}), isNull);
      expect(composeInfoFromInspect({}), isNull);
    });
  });

  group('buildDockerRunCommand', () {
    final evccInspect = {
      'Name': '/evcc',
      'Config': {
        'Image': 'evcc/evcc:latest',
        'Env': ['TZ=Europe/Berlin', 'PATH=/usr/local/sbin:/usr/local/bin'],
        'Labels': <String, dynamic>{},
      },
      'HostConfig': {
        'RestartPolicy': {'Name': 'unless-stopped', 'MaximumRetryCount': 0},
        'PortBindings': {
          '7070/tcp': [
            {'HostIp': '', 'HostPort': '7070'}
          ]
        },
        'Binds': ['/home/pi/evcc.yaml:/etc/evcc.yaml'],
        'NetworkMode': 'default',
      },
    };

    test('reconstructs the run command faithfully from inspect', () {
      final cmd = buildDockerRunCommand(evccInspect);
      expect(cmd, startsWith('docker run -d'));
      expect(cmd, contains("--name 'evcc'"));
      expect(cmd, contains('--restart unless-stopped'));
      expect(cmd, contains("-p '7070:7070'"));
      expect(cmd, contains("-v '/home/pi/evcc.yaml:/etc/evcc.yaml'"));
      expect(cmd, contains("-e 'TZ=Europe/Berlin'"));
      expect(cmd, endsWith("'evcc/evcc:latest'"));
    });
    test('drops pure image-default env vars like PATH', () {
      expect(buildDockerRunCommand(evccInspect), isNot(contains('PATH=')));
    });
    test('lets the image be overridden with a new tag', () {
      expect(buildDockerRunCommand(evccInspect, image: 'evcc/evcc:0.999'),
          endsWith("'evcc/evcc:0.999'"));
    });
    test('host network mode is preserved and -p is dropped', () {
      final hostNet = {
        'Name': '/evcc',
        'Config': {'Image': 'evcc/evcc:latest', 'Labels': <String, dynamic>{}},
        'HostConfig': {
          'NetworkMode': 'host',
          'PortBindings': {
            '7070/tcp': [
              {'HostIp': '', 'HostPort': '7070'}
            ]
          },
          'RestartPolicy': {'Name': 'always'},
        },
      };
      final cmd = buildDockerRunCommand(hostNet);
      expect(cmd, contains("--network 'host'"));
      expect(cmd, isNot(contains('-p ')));
      expect(cmd, contains('--restart always'));
    });
  });

  group('dockerRunRecreateScript', () {
    test('pulls, backs up the old container by rename, then runs the new one',
        () {
      final script = dockerRunRecreateScript(
        name: 'evcc',
        image: 'evcc/evcc:latest',
        runCommand: "docker run -d --name 'evcc' 'evcc/evcc:latest'",
      );
      expect(script, contains("docker pull 'evcc/evcc:latest'"));
      expect(script, contains("docker stop 'evcc'"));
      expect(script, contains("docker rename 'evcc' 'evcc-evccpitool-old'"));
      expect(script, contains("docker run -d --name 'evcc'"));
      expect(script, contains('set -e'));
    });
  });
}
