/// Pure construction of the SSH command sequence that updates evcc on a Pi.
///
/// No I/O happens here so the exact commands can be unit-tested without a real
/// SSH connection. The sequence mirrors the facts validated against the real
/// evcc-Pi on 2026-06-28.
library;

import 'dart:convert';

/// A single command in the update sequence.
class SshStep {
  /// Short human-readable label shown in the live log.
  final String label;

  /// The exact shell command to run on the Pi.
  final String command;

  /// Whether the sudo password must be fed to this command via stdin.
  ///
  /// The password is written to the command's stdin (for `sudo -S`) instead of
  /// being embedded in [command], so it can never end up in the command string
  /// or the visible log.
  final bool needsSudoPassword;

  const SshStep({
    required this.label,
    required this.command,
    required this.needsSudoPassword,
  });
}

/// How evcc is installed on the Pi.
enum InstallKind { apt, docker, unknown }

/// Reads the installed version of the `evcc` package (no sudo needed).
const String versionQuery = r"dpkg-query -W -f='${Version}' evcc";

/// Lists running containers as `name|image` lines (no sudo).
const String dockerListCommand = "docker ps --format '{{.Names}}|{{.Image}}'";

/// Same, but via sudo for hosts where the user isn't in the `docker` group.
const String dockerListSudoCommand =
    "sudo -S docker ps --format '{{.Names}}|{{.Image}}'";

/// A running evcc Docker container (its name + image).
class EvccDocker {
  final String name;
  final String image;
  const EvccDocker({required this.name, required this.image});
}

/// docker-compose project metadata read off a container's labels.
class DockerComposeInfo {
  final String workingDir;
  final String configFile;
  final String service;

  /// The compose project name (`com.docker.compose.project`). Empty if unknown.
  /// Pinned with `-p` so the update can never spawn a duplicate project.
  final String project;

  const DockerComposeInfo({
    required this.workingDir,
    required this.configFile,
    required this.service,
    this.project = '',
  });
}

/// Decides how evcc is installed from a `dpkg-query` result and a `docker ps`
/// listing. apt takes precedence (it's the supported install); a running evcc
/// container is the Docker case; otherwise unknown.
InstallKind classifyInstall({
  required String dpkgOutput,
  required String dockerPs,
}) {
  if (dpkgOutput.trim().isNotEmpty) return InstallKind.apt;
  if (parseEvccDocker(dockerPs) != null) return InstallKind.docker;
  return InstallKind.unknown;
}

/// Wraps [s] in single quotes, safely escaping any embedded single quote so the
/// value cannot break out of the quoting in a shell command (`'\''` idiom).
String shSingleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Finds the evcc container in a `name|image`-per-line listing. Prefers an
/// **image** match (the reliable signal) and only falls back to a name match,
/// so a sibling container like `evcc-db` (image `postgres`) is never mistaken
/// for the evcc install. Returns null when none is present.
EvccDocker? parseEvccDocker(String dockerPs) {
  final entries = <EvccDocker>[];
  for (final line in dockerPs.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split('|');
    if (parts.length < 2) continue;
    entries.add(EvccDocker(name: parts[0].trim(), image: parts[1].trim()));
  }
  for (final e in entries) {
    if (e.image.toLowerCase().contains('evcc')) return e;
  }
  for (final e in entries) {
    if (e.name.toLowerCase().contains('evcc')) return e;
  }
  return null;
}

/// Whether docker output indicates the user lacks daemon access (so the command
/// should be retried via sudo). Distinct from "docker not installed".
bool isDockerPermissionError(String output) {
  final o = output.toLowerCase();
  return o.contains('permission denied') &&
          (o.contains('docker daemon') || o.contains('docker.sock')) ||
      o.contains('cannot connect to the docker daemon');
}

/// `docker inspect <name>` — the full container JSON (parsed in Dart). Used for
/// both compose-label detection and `docker run` reconstruction.
String dockerInspectJsonCommand(String container) =>
    'docker inspect ${shSingleQuote(container)}';

/// sudo variant of [dockerInspectJsonCommand].
String dockerInspectJsonSudoCommand(String container) =>
    'sudo -S ${dockerInspectJsonCommand(container)}';

/// `docker inspect --format` that prints `workingDir|configFile|service` from
/// the compose labels. Retained for the string-based parser/tests.
String dockerInspectCommand(String container) =>
    'docker inspect ${shSingleQuote(container)} --format '
    '\'{{ index .Config.Labels "com.docker.compose.project.working_dir"}}|'
    '{{ index .Config.Labels "com.docker.compose.project.config_files"}}|'
    '{{ index .Config.Labels "com.docker.compose.service"}}\'';

/// sudo variant of [dockerInspectCommand].
String dockerInspectSudoCommand(String container) =>
    'sudo -S ${dockerInspectCommand(container)}';

/// Decodes `docker inspect` output (a JSON array, or a bare object) and returns
/// the first container object, or null on empty/garbage.
Map<String, dynamic>? firstInspectObject(String json) {
  try {
    final decoded = jsonDecode(json.trim());
    if (decoded is List) {
      final first = decoded.firstWhere((e) => e is Map, orElse: () => null);
      return first == null ? null : Map<String, dynamic>.from(first as Map);
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  } catch (_) {
    return null;
  }
}

/// Builds a validated [DockerComposeInfo] or null. The working dir must be an
/// absolute path and the service must match compose's charset — anything odd
/// falls through to a non-compose path rather than into a shell script (the
/// escaping in [dockerComposeUpdateScript] is the primary protection; this
/// rejects obviously-tampered labels early).
DockerComposeInfo? _composeInfo({
  required String workingDir,
  required String configFile,
  required String service,
  String project = '',
}) {
  if (workingDir.isEmpty || service.isEmpty) return null;
  final validService = RegExp(r'^[A-Za-z0-9._-]+$');
  if (!workingDir.startsWith('/') || !validService.hasMatch(service)) {
    return null;
  }
  return DockerComposeInfo(
    workingDir: workingDir,
    configFile: configFile,
    service: service,
    project: project,
  );
}

/// Parses the `workingDir|configFile|service` line from [dockerInspectCommand]
/// (the templated form). Returns null unless it's really compose-managed.
DockerComposeInfo? parseComposeInfo(String inspectOutput) {
  final line = inspectOutput
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.isEmpty) return null;
  final parts = line.split('|');
  String at(int i) {
    if (i >= parts.length) return '';
    final v = parts[i].trim();
    return v == '<no value>' ? '' : v;
  }

  return _composeInfo(
    workingDir: at(0),
    configFile: at(1),
    service: at(2),
  );
}

/// Reads the docker-compose labels off a full `docker inspect` object. Returns
/// null for a plain `docker run` container (no compose labels).
DockerComposeInfo? composeInfoFromInspect(Map<String, dynamic> container) {
  final config = container['Config'];
  final labels = (config is Map && config['Labels'] is Map)
      ? Map<String, dynamic>.from(config['Labels'] as Map)
      : <String, dynamic>{};
  String lab(String k) => (labels[k] ?? '').toString().trim();
  return _composeInfo(
    workingDir: lab('com.docker.compose.project.working_dir'),
    configFile: lab('com.docker.compose.project.config_files'),
    service: lab('com.docker.compose.service'),
    project: lab('com.docker.compose.project'),
  );
}

/// The root/bash script that updates a compose-managed evcc: pull the image,
/// then recreate only the evcc service in its project directory.
///
/// Pins the project (`-p`) and config file(s) (`-f`, comma-separated supported)
/// so a custom project name/filename can't make `up -d` spawn a *second*
/// container. Falls back to the v1 standalone binary when the v2 plugin is
/// absent. Every interpolated value is shell-escaped against label tampering.
String dockerComposeUpdateScript(DockerComposeInfo info) {
  final dir = shSingleQuote(info.workingDir);
  final svc = shSingleQuote(info.service);
  final opts = <String>[];
  if (info.project.isNotEmpty) {
    opts.addAll(['-p', shSingleQuote(info.project)]);
  }
  for (final cf in info.configFile.split(',')) {
    final f = cf.trim();
    if (f.isNotEmpty) opts.addAll(['-f', shSingleQuote(f)]);
  }
  final dc = opts.isEmpty ? r'$DC' : '\$DC ${opts.join(' ')}';
  return '''
set -e
cd $dir
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
$dc pull $svc
$dc up -d $svc
''';
}

/// Environment variables that are image/base defaults, not user config — these
/// are dropped when reconstructing a `docker run`, since the image re-applies
/// them anyway and re-passing a stale value could clobber the new image's.
const _imageDefaultEnv = {'PATH'};

/// Reconstructs an equivalent `docker run -d …` command from a full
/// `docker inspect` object, preserving name, restart policy, port bindings,
/// bind/volume mounts, user env and a non-default network. [image] overrides
/// the image reference (e.g. to pin a freshly-pulled tag). Used to update a
/// plain (non-compose) container by recreating it.
String buildDockerRunCommand(Map<String, dynamic> container, {String? image}) {
  final config = (container['Config'] is Map)
      ? Map<String, dynamic>.from(container['Config'] as Map)
      : <String, dynamic>{};
  final host = (container['HostConfig'] is Map)
      ? Map<String, dynamic>.from(container['HostConfig'] as Map)
      : <String, dynamic>{};

  final name =
      (container['Name'] ?? '').toString().replaceFirst(RegExp(r'^/'), '');
  final img = (image ?? config['Image'] ?? '').toString();
  final networkMode = (host['NetworkMode'] ?? '').toString();
  final hostNetwork = networkMode == 'host';

  final args = <String>['docker', 'run', '-d'];
  if (name.isNotEmpty) args.addAll(['--name', shSingleQuote(name)]);

  final rp = (host['RestartPolicy'] is Map)
      ? Map<String, dynamic>.from(host['RestartPolicy'] as Map)
      : <String, dynamic>{};
  final rpName = (rp['Name'] ?? '').toString();
  if (rpName.isNotEmpty && rpName != 'no') {
    final retries = rp['MaximumRetryCount'];
    if (rpName == 'on-failure' && retries is int && retries > 0) {
      args.addAll(['--restart', '$rpName:$retries']);
    } else {
      args.addAll(['--restart', rpName]);
    }
  }

  // Published ports are discarded under host networking, so skip them there.
  if (!hostNetwork && host['PortBindings'] is Map) {
    final pb = Map<String, dynamic>.from(host['PortBindings'] as Map);
    for (final entry in pb.entries) {
      final cport = entry.key; // e.g. "7070/tcp"
      final num = cport.split('/').first;
      final proto = cport.endsWith('/udp') ? '/udp' : '';
      final bindings = entry.value;
      if (bindings is List) {
        for (final b in bindings) {
          if (b is Map) {
            final hostIp = (b['HostIp'] ?? '').toString();
            final hostPort = (b['HostPort'] ?? '').toString();
            final spec = hostIp.isNotEmpty
                ? '$hostIp:$hostPort:$num$proto'
                : '$hostPort:$num$proto';
            args.addAll(['-p', shSingleQuote(spec)]);
          }
        }
      }
    }
  }

  final binds = host['Binds'];
  if (binds is List) {
    for (final b in binds) {
      args.addAll(['-v', shSingleQuote(b.toString())]);
    }
  }

  final env = config['Env'];
  if (env is List) {
    for (final e in env) {
      final s = e.toString();
      if (_imageDefaultEnv.contains(s.split('=').first)) continue;
      args.addAll(['-e', shSingleQuote(s)]);
    }
  }

  if (networkMode.isNotEmpty &&
      networkMode != 'default' &&
      networkMode != 'bridge') {
    args.addAll(['--network', shSingleQuote(networkMode)]);
  }

  args.add(shSingleQuote(img));
  return args.join(' ');
}

/// The root/bash script that updates a plain `docker run` container: pull the
/// new image, keep the old container as a rollback by renaming it (never
/// deleting data), then start the recreated container. [runCommand] is the
/// reconstructed `docker run` from [buildDockerRunCommand].
String dockerRunRecreateScript({
  required String name,
  required String image,
  required String runCommand,
}) {
  final n = shSingleQuote(name);
  final backup = shSingleQuote('$name-evccpitool-old');
  final img = shSingleQuote(image);
  return '''
set -e
docker pull $img
docker rm -f $backup >/dev/null 2>&1 || true
docker stop $n
docker rename $n $backup
$runCommand
''';
}

/// Queries whether the evcc service is running (no sudo needed).
const String serviceStatus = 'systemctl is-active evcc';

/// Restarts the evcc service (needs sudo).
const String serviceRestartCommand = 'sudo -S systemctl restart evcc';

/// Reboots the Pi (needs sudo). The SSH connection drops as a result.
const String rebootCommand = 'sudo -S reboot';

/// evcc service status incl. the last log lines (no sudo needed).
const String statusCommand = 'systemctl status evcc --no-pager';

/// Builds the ordered update sequence.
///
/// - [fullUpgrade] `false` upgrades only evcc; `true` upgrades the whole system.
/// - [dryRun] `true` makes apt simulate the upgrade without changing anything.
List<SshStep> buildUpdateSteps({
  required bool fullUpgrade,
  required bool dryRun,
}) {
  return [
    const SshStep(
      label: 'Version vorher',
      command: versionQuery,
      needsSudoPassword: false,
    ),
    const SshStep(
      label: 'Paketliste aktualisieren',
      command: 'sudo -S apt-get update -qq',
      needsSudoPassword: true,
    ),
    SshStep(
      label: fullUpgrade ? 'System-Upgrade' : 'evcc aktualisieren',
      command: _upgradeCommand(fullUpgrade: fullUpgrade, dryRun: dryRun),
      needsSudoPassword: true,
    ),
    const SshStep(
      label: 'Dienststatus',
      command: serviceStatus,
      needsSudoPassword: false,
    ),
    const SshStep(
      label: 'Version nachher',
      command: versionQuery,
      needsSudoPassword: false,
    ),
  ];
}

/// The remote command that runs the install script as root: `sudo -S bash -s`.
///
/// The caller feeds `<password>\n<script>` to stdin — `sudo -S` consumes the
/// first line as the password, then `bash -s` executes the rest as root. This
/// keeps the password out of the command line entirely.
const String installShellCommand = 'sudo -S bash -s';

/// The root install script: official evcc apt-repo setup + package install +
/// service enable. Mirrors https://docs.evcc.io/en/installation/linux.
/// Runs as root (via [installShellCommand]), so it uses no inner `sudo`.
///
/// [channel] selects the apt repo: 'stable' (default) or 'unstable' (nightly).
String buildInstallScript({String channel = 'stable'}) {
  final repo = channel == 'unstable' ? 'unstable' : 'stable';
  return '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.evcc.io/public/evcc/$repo/setup.deb.sh' -o /tmp/evcc-setup.sh
bash /tmp/evcc-setup.sh
rm -f /tmp/evcc-setup.sh
apt-get update
apt-get install -y evcc
systemctl enable --now evcc
''';
}

String _upgradeCommand({required bool fullUpgrade, required bool dryRun}) {
  if (fullUpgrade) {
    return dryRun
        ? 'sudo -S apt-get full-upgrade --dry-run'
        : 'sudo -S apt-get full-upgrade -y';
  }
  return dryRun
      ? 'sudo -S apt-get install --only-upgrade --dry-run evcc'
      : 'sudo -S apt-get install --only-upgrade -y evcc';
}
