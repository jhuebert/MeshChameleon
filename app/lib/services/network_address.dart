/// Whether [host] is a non-empty TCP/IP host name or address.
bool isValidTcpHost(String host) => host.trim().isNotEmpty;

/// Whether [port] is a usable non-zero TCP port.
bool isValidTcpPort(int port) => port >= 1 && port <= 65535;

/// Formats a TCP target, bracketing IPv6 literals (for example
/// `[fe80::1]:5000`).
String formatNetworkAddress(String host, int port) {
  final trimmed = host.trim();
  if (trimmed.contains(':') && !trimmed.startsWith('[')) {
    return '[$trimmed]:$port';
  }
  return '$trimmed:$port';
}
