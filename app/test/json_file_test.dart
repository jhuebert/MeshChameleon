import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/json_file.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mesh_json_file_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('separate instances targeting one path serialize their writes',
      () async {
    final file = File('${dir.path}/shared.json');
    final gate = Completer<void>();
    final firstStarted = Completer<void>();
    final order = <String>[];

    final first = JsonFile(file).write(
      {'value': 1},
      beforeRename: () async {
        order.add('first');
        firstStarted.complete();
        await gate.future;
      },
    );
    final second = JsonFile(file).write(
      {'value': 2},
      beforeRename: () async => order.add('second'),
    );

    // Wait for the first write to reach its rename instead of guessing how
    // long its file I/O takes on a loaded runner.
    await firstStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(order, ['first']);
    expect(await file.exists(), isFalse,
        reason: 'the second write must queue behind the first instance');

    gate.complete();
    await Future.wait([first, second]);

    expect(order, ['first', 'second']);
    expect(jsonDecode(await file.readAsString()), {'value': 2});
  });

  test('delete queues behind a pending write instead of racing it', () async {
    final file = File('${dir.path}/delete.json');
    final json = JsonFile(file);
    final gate = Completer<void>();

    final write = json.write(
      {'value': 1},
      beforeRename: () => gate.future,
    );
    final delete = json.delete();

    gate.complete();
    await Future.wait([write, delete]);

    expect(await file.exists(), isFalse,
        reason: 'delete must run after the write it replaced');
  });

  test('a failed write does not poison later writes', () async {
    final file = File('${dir.path}/recover.json');
    final json = JsonFile(file);

    await expectLater(
      json.write(
        {'value': 1},
        beforeRename: () => throw StateError('rename preparation failed'),
      ),
      throwsStateError,
    );
    await json.write({'value': 2});

    expect(jsonDecode(await file.readAsString()), {'value': 2});
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });
}
