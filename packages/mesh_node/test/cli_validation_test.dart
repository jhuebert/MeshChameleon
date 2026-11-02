import 'package:mesh_node/mesh_node.dart';
import 'package:test/test.dart';

void main() {
  test('CliFormatException exposes its message and prefix', () {
    const error = CliFormatException('bad input', prefix: 'AB');
    expect(error.message, 'bad input');
    expect(error.prefix, 'AB');
    expect(error.toString(), contains('bad input'));
  });

  test('the empty sensor provider supports no keys', () {
    const provider = EmptyVirtualSensorSettingsProvider();
    expect(provider.initialSettings, isEmpty);
    expect(provider.supports('gps'), isFalse);
    expect(provider.normalize('gps', '1'), isNull);
  });

  group('CliPhysicalValidator invalid arguments', () {
    void rejects(String command) {
      expect(
        () => CliPhysicalValidator.validate(command, maxTxPower: 22),
        throwsA(isA<CliFormatException>()),
        reason: command,
      );
    }

    test('radio and TX values', () {
      rejects('set radio 900,125,11');
      rejects('set radio 900,125,11,6,1');
      rejects('set freq 100');
      rejects('set tx 23');
      rejects('set tx not-a-number');
    });

    test('tuning values', () {
      rejects('set af 10');
      rejects('set af nope');
      rejects('set dutycycle 0');
      rejects('set dutycycle 101');
      rejects('set rxdelay -1');
      rejects('set rxdelay 21');
      rejects('set int.thresh 256');
      rejects('set int.thresh -1');
      rejects('set cad maybe');
      rejects('set radio.rxgain maybe');
      rejects('set agc.reset.interval abc');
      rejects('set txdelay -0.1');
      rejects('set txdelay 2.1');
      rejects('set direct.txdelay 3');
    });

    test('WiFi values', () {
      rejects('set wifi.ssid ${'a' * 33}');
      rejects('set wifi.pwd ${'a' * 64}');
      rejects('set wifi.enabled 2');
    });
  });

  group('CliPhysicalValidator normalizes', () {
    test('AGC interval clamps to the firmware range', () {
      expect(
        CliPhysicalValidator.validate('set agc.reset.interval -5',
                maxTxPower: 22)
            .command,
        'set agc.reset.interval 0',
      );
      expect(
        CliPhysicalValidator.validate('set agc.reset.interval 5000',
                maxTxPower: 22)
            .command,
        'set agc.reset.interval 1020',
      );
      expect(
        CliPhysicalValidator.validate('set agc.reset.interval 42',
                maxTxPower: 22)
            .command,
        'set agc.reset.interval 42',
      );
    });

    test('on/off and delay commands are accepted at their bounds', () {
      expect(
        CliPhysicalValidator.validate('set cad on', maxTxPower: 22).command,
        'set cad on',
      );
      expect(
        CliPhysicalValidator.validate('set radio.rxgain off', maxTxPower: 22)
            .command,
        'set radio.rxgain off',
      );
      expect(
        CliPhysicalValidator.validate('set txdelay 2', maxTxPower: 22).command,
        'set txdelay 2',
      );
      expect(
        CliPhysicalValidator.validate('set direct.txdelay 0', maxTxPower: 22)
            .command,
        'set direct.txdelay 0',
      );
    });

    test('unknown physical arguments are rejected as illegal', () {
      expect(
        () => CliPhysicalValidator.validate('get radio extra', maxTxPower: 22),
        throwsA(isA<CliFormatException>()),
      );
    });
  });
}
