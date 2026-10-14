import 'constants.dart';

/// Multi-byte path encode/decode matching the MeshCore firmware `Packet.h`.
///
/// The encoded `path_len` byte packs both hash size and hop count:
///  * bits 0-5: hop count (0-63)
///  * bits 6-7: hash size - 1 (so hash size is 1, 2, or 3)
class PathUtils {
  const PathUtils._();

  static int getHashSize(int pathLenByte) => (pathLenByte >> 6) + 1;

  static int getHashCount(int pathLenByte) => pathLenByte & 0x3F;

  static int getByteLength(int pathLenByte) =>
      getHashCount(pathLenByte) * getHashSize(pathLenByte);

  static int encodePathLen(int hashSize, int hashCount) {
    if (hashCount < 0 || hashCount > 63) {
      throw ArgumentError('hop count must be 0-63, got $hashCount');
    }
    return ((hashSize - 1) << 6) | (hashCount & 0x3F);
  }

  static bool isValidPathLen(int pathLenByte) {
    final hashSize = getHashSize(pathLenByte);
    if (hashSize > 3) return false;
    return getByteLength(pathLenByte) <= maxPathSize;
  }
}
