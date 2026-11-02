import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/identity_store.dart';

void main() {
  test('an unreadable secure slot is reported as unavailable', () async {
    final store = IdentityStore(storage: const _ThrowingStorage());
    const id = '0123456789abcdef0123456789abcdef';

    expect(await store.loadById(id), isNull);
    expect(await store.hasById(id), isFalse);
  });
}

class _ThrowingStorage extends FlutterSecureStorage {
  const _ThrowingStorage();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('secure storage unavailable');
  }
}
