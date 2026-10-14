import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('DeviceFrames.sendRawPacket wraps the packet', () {
    final packet = Uint8List.fromList([0x04, 0x00, 0x01, 0x02]);
    final frame = DeviceFrames.sendRawPacket(packet, 1);
    expect(frame[0], cmdSendRawPacket);
    expect(frame[1], 1);
    expect(frame.sublist(2), packet);
  });

  test('DeviceFrames.setRadioParams encodes kHz frequency', () {
    final frame = DeviceFrames.setRadioParams(
      const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      ),
    );
    expect(frame[0], cmdSetRadioParams);
    final r = BufferReader(frame)..skipBytes(1);
    expect(r.readUInt32Le(), 915000); // kHz
    expect(r.readUInt32Le(), 250000); // Hz
  });

  test('ParsedSelfInfo normalises frequency to Hz', () {
    final w = BufferWriter()
      ..writeByte(respCodeSelfInfo)
      ..writeByte(advTypeChat)
      ..writeByte(20)
      ..writeByte(22)
      ..writeBytes(Uint8List(32)..[0] = 7)
      ..writeInt32Le(0)
      ..writeInt32Le(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeUInt32Le(915000) // kHz
      ..writeUInt32Le(250000) // Hz
      ..writeByte(10)
      ..writeByte(5)
      ..writeCString('dev', 4);
    final info = ParsedSelfInfo.parse(w.toBytes());
    expect(info, isNotNull);
    expect(info!.radioParams.frequencyHz, 915000000);
    expect(info.radioParams.bandwidthHz, 250000);
    expect(info.nodeName, 'dev');
    expect(info.publicKey[0], 7);
  });

  test('RawRxFrame parses SNR/RSSI and payload', () {
    final frame = Uint8List.fromList([pushCodeLogRxData, 24, 0xFF & -70, 1, 2, 3]);
    final parsed = RawRxFrame.parse(frame);
    expect(parsed, isNotNull);
    expect(parsed!.snr, 6.0);
    expect(parsed.rssi, -70);
    expect(parsed.raw, [1, 2, 3]);
  });

  test('FakeRadioBus delivers frames between links', () async {
    final bus = FakeRadioBus();
    final a = FakeDeviceLink(bus: bus);
    final b = FakeDeviceLink(bus: bus);
    await a.connect();
    await b.connect();
    final received = <Uint8List>[];
    b.setRawRxListener((snr, rssi, raw) => received.add(raw));
    await a.sendRawPacket(Uint8List.fromList([9, 8, 7]));
    expect(received.single, [9, 8, 7]);
  });

  test('TcpDeviceLink parses DEVICE_INFO', () {
    final w = BufferWriter()
      ..writeByte(respCodeDeviceInfo)
      ..writeByte(11)
      ..writeByte(255)
      ..writeByte(8)
      ..writeUInt32Le(0)
      ..writeCString('build', 12)
      ..writeCString('Acme', 40)
      ..writeCString('fw 1.0', 20)
      ..writeByte(0)
      ..writeByte(1);
    final info = TcpDeviceLink.parseDeviceInfo(w.toBytes());
    expect(info.firmwareVerCode, 11);
    expect(info.maxContacts, 510);
    expect(info.maxChannels, 8);
    expect(info.manufacturer, 'Acme');
    expect(info.version, 'fw 1.0');
    expect(info.pathHashMode, 1);
  });
}
