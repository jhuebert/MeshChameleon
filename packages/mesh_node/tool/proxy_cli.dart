// Headless MeshChameleon proxy: serves the companion-protocol TCP endpoint to
// a client while holding the proxy identity here, with no Flutter and no phone.
//
//   dart run tool/proxy_cli.dart --simulated
//   dart run tool/proxy_cli.dart --device 192.168.1.50:5000
//
// The identity is ephemeral unless --identity-file is passed; state is
// in-memory unless --state-dir is passed. Read-only against the mesh: this
// never transmits on its own.
import 'dart:async';
import 'dart:io';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

const String _usage = '''
Headless MeshChameleon proxy.

Usage: dart run tool/proxy_cli.dart [options]

Options:
  --simulated              Use the in-memory simulated companion (default).
  --device HOST[:PORT]     Use a stock companion over TCP (PORT defaults to
                           $defaultCompanionPort).
  --proxy-port PORT        App-facing companion port (default $defaultCompanionPort,
                           0 picks a free port).
  --identity-file PATH     Persist the proxy identity as plaintext hex (atomic
                           replace, mode 0600). Without this the identity is
                           ephemeral, including network imports.
  --state-dir PATH         Persist contacts/channels/queue as JSON there.
  -h, --help               Show this message.
''';

/// Parsed command line for the headless proxy.
class ProxyCliOptions {
  const ProxyCliOptions({
    this.simulated = false,
    this.deviceHost,
    this.devicePort = defaultCompanionPort,
    this.proxyPort = defaultCompanionPort,
    this.identityFile,
    this.stateDir,
  });

  /// Explicitly requested the simulated companion.
  final bool simulated;
  final String? deviceHost;
  final int devicePort;
  final int proxyPort;
  final String? identityFile;
  final String? stateDir;

  bool get usesSimulatedCompanion => deviceHost == null;

  /// Throws [FormatException] on an unknown flag or bad value.
  static ProxyCliOptions parse(List<String> args) {
    var simulated = false;
    String? deviceHost;
    var devicePort = defaultCompanionPort;
    var proxyPort = defaultCompanionPort;
    String? identityFile;
    String? stateDir;

    for (var i = 0; i < args.length; i++) {
      final flag = args[i];
      switch (flag) {
        case '--simulated':
          simulated = true;
        case '--device':
          final target = _value(args, i++, flag);
          final separator = target.lastIndexOf(':');
          if (separator < 0) {
            deviceHost = target;
          } else {
            deviceHost = target.substring(0, separator);
            devicePort = _port(target.substring(separator + 1), '--device');
          }
        case '--proxy-port':
          proxyPort = _port(_value(args, i++, flag), flag, allowZero: true);
        case '--identity-file':
          identityFile = _value(args, i++, flag);
        case '--state-dir':
          stateDir = _value(args, i++, flag);
        default:
          throw FormatException('unknown argument "$flag"');
      }
    }

    if (simulated && deviceHost != null) {
      throw const FormatException('--simulated and --device are exclusive');
    }
    if (deviceHost != null && deviceHost.isEmpty) {
      throw const FormatException('--device needs a host');
    }
    return ProxyCliOptions(
      simulated: simulated,
      deviceHost: deviceHost,
      devicePort: devicePort,
      proxyPort: proxyPort,
      identityFile: identityFile,
      stateDir: stateDir,
    );
  }

  static String _value(List<String> args, int index, String flag) {
    if (index + 1 >= args.length) {
      throw FormatException('$flag needs a value');
    }
    return args[index + 1];
  }

  static int _port(String raw, String flag, {bool allowZero = false}) {
    final value = int.tryParse(raw);
    final min = allowZero ? 0 : 1;
    if (value == null || value < min || value > 65535) {
      throw FormatException('$flag needs a port in $min..65535');
    }
    return value;
  }
}

/// A running proxy, with the pieces a caller (or the CLI) needs to shut down.
class ProxyCliHandle {
  ProxyCliHandle({
    required this.server,
    required this.node,
    required this.link,
  });

  final CompanionServer server;
  final MeshNode node;
  final RadioLink link;

  int? get port => server.port;

  Future<void> close() async {
    await server.stop();
    node.stop();
    await link.disconnect();
  }
}

/// Boot the device link, mesh node, and companion server.
///
/// [log] receives human-readable progress; it never sees key material.
Future<ProxyCliHandle> startProxyCli(
  ProxyCliOptions options, {
  void Function(String message)? log,
}) async {
  final identityPersistence = _openIdentityPersistence(
    options.identityFile,
    log,
  );
  var identity = await identityPersistence.load();
  if (identity == null) {
    identity = await LocalIdentity.generate();
    await identityPersistence.save(identity);
  }

  final RadioLink link;
  final host = options.deviceHost;
  if (host == null) {
    link = FakeDeviceLink(deviceNodeName: 'Simulated companion');
    log?.call('using the simulated companion (no radio hardware)');
  } else {
    link = TcpDeviceLink(host: host, port: options.devicePort, onLog: log);
    log?.call('connecting device $host:${options.devicePort} ...');
  }
  await connectWithBackoff(link, onLog: log);

  final deviceInfo = await link.deviceInfo();
  final selfInfo = await link.selfInfo();
  final params = selfInfo.radioParams;
  final physical = PhysicalCapabilities.fromDeviceInfo(
    deviceInfo,
    maxTxPower: selfInfo.maxTxPower,
  );
  log?.call('device fw=${deviceInfo.firmwareVerCode} '
      'radio=${params.frequencyHz ~/ 1000} kHz sf${params.spreadingFactor}');

  final store = await _openStore(options.stateDir);
  final node = MeshNode(
    identity: identity,
    link: link,
    physical: physical,
    store: store,
    identityPersistence: identityPersistence,
    attachedDevicePublicKey: selfInfo.publicKey,
  );
  await node.load();
  node.adoptPhysicalCapabilities(physical);
  node.syncRadioParams(params);
  node.start();

  final server = CompanionServer(
    bridge: node,
    config: CompanionServerConfig(port: options.proxyPort),
    onLog: log,
  );
  await server.start();

  return ProxyCliHandle(server: server, node: node, link: link);
}

Future<NodeStore> _openStore(String? stateDir) async {
  if (stateDir == null) return InMemoryNodeStore();
  final dir = Directory(stateDir);
  await dir.create(recursive: true);
  return JsonNodeStore(file: File('${dir.path}/node_state.json'));
}

/// Open the headless identity backend and describe the persistence choice.
///
/// The identity is the proxy's private key: it is only written when the caller
/// asks for a file, and the warning makes the plaintext trade-off explicit.
VirtualIdentityPersistence _openIdentityPersistence(
  String? path,
  void Function(String message)? log,
) {
  if (path == null) {
    log?.call('using an ephemeral identity; network imports last until exit '
        '(pass --identity-file to keep it)');
    return MemoryIdentityPersistence();
  }
  log?.call('warning: storing the private identity as plaintext hex at $path '
      '(atomic replace, mode 0600)');
  return FileIdentityPersistence(File(path));
}

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }

  final ProxyCliOptions options;
  try {
    options = ProxyCliOptions.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n');
    stderr.writeln(_usage);
    exit(64);
  }

  final ProxyCliHandle handle;
  try {
    handle = await startProxyCli(
      options,
      log: (message) => stdout.writeln('[proxy] $message'),
    );
  } catch (e) {
    stderr.writeln('failed to start: $e');
    exit(1);
  }

  stdout.writeln('MeshChameleon proxy listening on port ${handle.port}');
  stdout.writeln('Point a companion client at this host; Ctrl-C to stop.');

  final stopped = Completer<void>();
  final signal = ProcessSignal.sigint.watch().listen((_) {
    if (!stopped.isCompleted) stopped.complete();
  });
  await stopped.future;
  await signal.cancel();
  await handle.close();
  stdout.writeln('stopped');
}
