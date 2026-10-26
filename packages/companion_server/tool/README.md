# Companion server tools

All of these take an explicit `host port`; nothing is built in. They speak the
normal companion protocol and may detach whichever client currently owns the
target.

| Tool | Purpose |
|---|---|
| `companion_client.dart` | Minimal laptop-side handshake for checking a running proxy, useful during Android background/Doze tests. |
| `companion_inspect.dart` | Read-only dump of a companion's channels, contacts, or queued messages. |
| `hil_client.dart` | Protocol conformance client with raw frames, scripted scenarios, fuzzing, key import/export, signing, and concurrency checks. |
| `hil_peer.dart` | Ordinary companion peer driver for RF tests: contacts, channels, DMs, adverts, telemetry, path discovery, raw packets, CLI, and queue draining. |

Examples:

```sh
dart run tool/companion_client.dart <host> <port>
dart run tool/hil_client.dart handshake <host> <port>
dart run tool/hil_client.dart contacts <host> <port>
dart run tool/hil_peer.dart contacts <host> <port>
dart run tool/hil_peer.dart dm <host> <port> <pubkey-hex> "hello" --await-ack 10
```

`hil_peer` never changes radio settings. Peers that share one physical radio must
serialize their transmissions. See `hil_client.dart` and `hil_peer.dart` for the
full command reference.
