import 'dart:async';
import 'dart:io';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path_provider/path_provider.dart';

import 'services/ble_device_link.dart';
import 'services/foreground_service.dart';
import 'services/identity_store.dart';

enum ProxyStatus { stopped, running }

/// Owns the identity, the device link, the mesh node, and the companion server,
/// and exposes them to the UI.
class AppState extends ChangeNotifier {
  AppState({IdentityStore? store}) : store = store ?? IdentityStore();

  final IdentityStore store;

  /// Foreground service that keeps the process alive while backgrounded.
  final ForegroundService _foreground = ForegroundService();

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

  NodeStore? _nodeStoreInstance;

  /// Lazily create the on-disk node-state store (contacts, channels, queue,
  /// prefs) under the app's support directory.
  Future<NodeStore> _nodeStore() async {
    final existing = _nodeStoreInstance;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    final store = JsonNodeStore(file: File('${dir.path}/node_state.json'));
    _nodeStoreInstance = store;
    return store;
  }

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

      final node = MeshNode(
        identity: identity!,
        link: link,
        deviceInfo: deviceInfo,
        store: await _nodeStore(),
      );
      await node.load();
      // The device is the source of truth for the radio at connect time.
      node.syncRadioParams(params);
      node.start();
      this.node = node;
      log('Device link ready; mesh node started');
      await _startForegroundService();
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
    try {
      await _foreground.stop();
    } catch (_) {
      // The service may already be stopped.
    }
    notifyListeners();
  }

  /// Persistent-notification text reflecting the current link/server state.
  String _notificationText() {
    final linkPart = deviceConnected ? 'device linked' : 'no device';
    final serverPart = proxyStatus == ProxyStatus.running
        ? 'serving :$port'
        : 'server stopped';
    return '$linkPart · $serverPart';
  }

  Future<void> _startForegroundService() async {
    try {
      await _foreground.start(
        title: 'Companion Proxy',
        text: _notificationText(),
      );
    } catch (e) {
      log('Foreground service unavailable: $e');
    }
  }

  Future<void> _updateNotification() async {
    try {
      await _foreground.update(
        title: 'Companion Proxy',
        text: _notificationText(),
      );
    } catch (e) {
      log('Foreground service update failed: $e');
    }
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
      await _updateNotification();
    } catch (e) {
      log('Failed to start proxy: $e');
    }
    notifyListeners();
  }

  Future<void> stopProxy() async {
    await server?.stop();
    server = null;
    proxyStatus = ProxyStatus.stopped;
    await _updateNotification();
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
