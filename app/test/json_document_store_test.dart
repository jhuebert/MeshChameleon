import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/json_document_store.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('json_document_store_');
    file = File('${dir.path}/document.json');
  });

  tearDown(() => dir.delete(recursive: true));

  JsonDocumentStore<int> store({File? target}) => JsonDocumentStore<int>(
        resolveFile: () async => target ?? file,
        decode: (json) => json is Map ? json['value'] as int? : null,
        encode: (value) => {'value': value},
      );

  test('a missing document loads as null', () async {
    expect(await store().load(), isNull);
  });

  test('saves and reloads a document', () async {
    final subject = store();
    await subject.save(42);
    expect(jsonDecode(await file.readAsString()), {'value': 42});
    expect(await subject.load(), 42);
  });

  test('corrupt or non-object documents load as null', () async {
    await file.writeAsString('{');
    expect(await store().load(), isNull);

    await file.writeAsString('[1, 2, 3]');
    expect(await store().load(), isNull);
  });

  test('delete removes the document', () async {
    final subject = store();
    await subject.save(1);
    await subject.delete();
    expect(await file.exists(), isFalse);
    expect(await subject.load(), isNull);
  });

  test('write failures propagate to the caller', () async {
    final blocker = File('${dir.path}/blocker');
    await blocker.writeAsString('x');
    final target = File('${blocker.path}/document.json');
    await expectLater(
      store(target: target).save(1),
      throwsA(isA<FileSystemException>()),
    );
  });
}
