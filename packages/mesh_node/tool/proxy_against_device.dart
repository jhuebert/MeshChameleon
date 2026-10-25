// M0/M2 end-to-end check: boot the proxy (CompanionServer + MeshNode) on a
// real stock companion over TCP, then drive a meshcore-cli style handshake
// against the app-facing port.
//
//   dart run tool/proxy_against_device.dart [host] [port]
//
// Read-only against the mesh: it never transmits and never changes radio
// settings. The proxy identity is ephemeral (in-memory) for this run.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : 'aries.huebert.org';
  final port = args.length > 1 ? int.parse(args[1]) : 9505;

  final identity = await LocalIdentity.generate();
  final link = TcpDeviceLink(
    host: host,
    port: port,
    onLog: (m) => stdout.writeln('[device] $m'),
  );
  stdout.writeln('connecting device $host:$port ...');
  await link.connect();
  final info = await link.deviceInfo();
  final deviceSelfInfo = await link.selfInfo();
  final params = deviceSelfInfo.radioParams;
  final physical = PhysicalCapabilities.fromDeviceInfo(
    info,
    maxTxPower: deviceSelfInfo.maxTxPower,
  );
  stdout.writeln('device fw=${info.firmwareVerCode} '
      'freq=${params.frequencyHz} name="${info.manufacturer}"');

  final node = MeshNode(
    identity: identity,
    link: link,
    physical: physical,
    store: InMemoryNodeStore(),
  );
  await node.load();
  node.adoptPhysicalCapabilities(physical);
  node.syncRadioParams(params);
  node.start();

  final server = CompanionServer(
    bridge: node,
    config: const CompanionServerConfig(port: 0),
    onLog: (m) => stdout.writeln('[server] $m'),
  );
  await server.start();
  stdout.writeln('proxy listening on 127.0.0.1:${server.port}');

  final socket = await Socket.connect('127.0.0.1', server.port!);
  socket.setOption(SocketOption.tcpNoDelay, true);
  final codec = SerialFrameCodec.bidirectional();
  final buffer = <Uint8List>[];
  final waiters = <Completer<Uint8List>>[];
  socket.listen((data) {
    for (final frame in codec.ingest(data)) {
      if (waiters.isNotEmpty) {
        waiters.removeAt(0).complete(frame);
      } else {
        buffer.add(frame);
      }
    }
  });

  Future<Uint8List> next() {
    if (buffer.isNotEmpty) return Future.value(buffer.removeAt(0));
    final c = Completer<Uint8List>();
    waiters.add(c);
    return c.future;
  }

  void send(List<int> payload) =>
      socket.add(codec.encodeFrame(payload, prefix: frameInboundPrefix));

  // Handshake, exactly as meshcore-open does.
  send([cmdDeviceQuery, appProtocolVersion]);
  final deviceInfo = await next();
  stdout.writeln('client DEVICE_INFO code=${deviceInfo[0]} fw=${deviceInfo[1]} '
      'maxContacts=${deviceInfo[2] * 2} maxChannels=${deviceInfo[3]}');

  send([cmdAppStart, appProtocolVersion]);
  final selfInfo = await next();
  final self = ParsedSelfInfo.parse(selfInfo);
  if (self == null) {
    stderr.writeln('client SELF_INFO parse failed');
    exit(1);
  }
  stdout.writeln('client SELF_INFO code=${selfInfo[0]} name="${self.nodeName}" '
      'freq=${self.radioParams.frequencyHz} '
      'proxyIdentity=${bytesToHex(self.publicKey) == bytesToHex(identity.publicKey)}');

  send([cmdGetBattAndStorage]);
  final batt = await next();
  stdout.writeln('client BATT_AND_STORAGE code=${batt[0]}');

  send([cmdGetCustomVars]);
  stdout.writeln('client CUSTOM_VARS code=${(await next())[0]}');

  send([cmdGetAutoAddConfig]);
  stdout.writeln('client AUTOADD_CONFIG code=${(await next())[0]}');

  send([cmdGetContacts, 0, 0, 0, 0]);
  final contactsStart = await next();
  final cr = BufferReader(contactsStart)..skipBytes(1);
  final count = cr.readUInt32Le();
  stdout.writeln('client CONTACTS_START code=${contactsStart[0]} count=$count');

  await socket.close();
  await server.stop();
  node.stop();
  await link.disconnect();
  stdout.writeln('done');
}
