import 'dart:async';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'services/ble_device_link.dart';
import 'services/identity_store.dart';

enum ProxyStatus { stopped, running }

/// Owns the identity, the device link, the mesh node, and the companion server,
/// and exposes them to the UI.
class AppState extends ChangeNotifier {
  AppState({IdentityStore? store}) : store = store ?? IdentityStore();

  final IdentityStore store;

  LocalIdentity? identity;
  RadioLink? link;
  MeshNode? node;
  CompanionServer? server;

  int port = defaultCompanionPort;
  ProxyStatus proxyStatus = ProxyStatus.stopped;
  String? deviceLabel;
  bool deviceConnected = false;
  bool busy = false;

  final List<String> logs = [];

  void log(String message) {
    logs.add('${DateTime.now().toIso8601String()}  $message');
    if (logs.length > 500) logs.removeAt(0);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Identity
  // -------------------------------------------------------------------------

  Future<void> loadIdentity() async {
    identity = await store.load();
    notifyListeners();
  }

  Future<void> generateIdentity() async {
    identity = await store.generate();
    log('Generated identity ${_pubkeyPrefix()}');
    notifyListeners();
  }

  Future<void> importIdentity(Uint8List key) async {
    identity = await store.import(key);
    log('Imported identity ${_pubkeyPrefix()}');
    notifyListeners();
  }

  Future<Uint8List?> exportIdentity() => store.exportKey();

  String _pubkeyPrefix() {
    final key = identity?.publicKey;
    if (key == null) return '(none)';
    return bytesToHex(key.sublist(0, 4));
  }

  // -------------------------------------------------------------------------
  // Device link
  // -------------------------------------------------------------------------

  Future<void> connectTcp({required String host, int? tcpPort}) async {
    final link = TcpDeviceLink(
      host: host,
      port: tcpPort ?? defaultCompanionPort,
      onLog: log,
    );
    await _attachLink(link, 'TCP $host:${tcpPort ?? defaultCompanionPort}');
  }

  Future<void> connectBle(BluetoothDevice device) async {
    final link = BleDeviceLink(device: device, onLog: log);
    await _attachLink(link, 'BLE ${device.platformName.isEmpty ? device.remoteId : device.platformName}');
  }

  Future<void> _attachLink(RadioLink link, String label) async {
    if (identity == null) {
      log('Generate or import an identity first');
      return;
    }
    busy = true;
    notifyListeners();
    try {
      await disconnectDevice();
      log('Connecting to $label ...');
      await link.connect();
      this.link = link;
      deviceLabel = label;
      deviceConnected = true;

      final deviceInfo = await link.deviceInfo();
      final params = await link.radioParams();
      log('Device: fw ${deviceInfo.firmwareVerCode}, '
          '${deviceInfo.manufacturer} ${deviceInfo.version}');

      final prefs = NodePrefs(
        frequencyHz: params.frequencyHz,
        bandwidthHz: params.bandwidthHz,
        spreadingFactor: params.spreadingFactor,
        codingRate: params.codingRate,
        txPowerDbm: params.txPowerDbm,
      );
      final node = MeshNode(identity: identity!, link: link, prefs: prefs, deviceInfo: deviceInfo)
        ..start();
      this.node = node;
      log('Device link ready; mesh node started');
    } catch (e) {
      log('Device connection failed: $e');
      await disconnectDevice();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnectDevice() async {
    node?.stop();
    node = null;
    await link?.disconnect();
    link = null;
    deviceConnected = false;
    deviceLabel = null;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Proxy server
  // -------------------------------------------------------------------------

  Future<void> startProxy({int? serverPort}) async {
    if (node == null) {
      log('Connect a device first');
      return;
    }
    server ??= CompanionServer(
      bridge: node!,
      config: CompanionServerConfig(port: serverPort ?? port),
      onLog: log,
    );
    try {
      await server!.start();
      port = server!.port ?? port;
      proxyStatus = ProxyStatus.running;
      log('Proxy server listening on port $port');
    } catch (e) {
      log('Failed to start proxy: $e');
    }
    notifyListeners();
  }

  Future<void> stopProxy() async {
    await server?.stop();
    server = null;
    proxyStatus = ProxyStatus.stopped;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(server?.stop());
    node?.stop();
    unawaited(link?.disconnect());
    super.dispose();
  }
}
