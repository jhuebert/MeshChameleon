# Device link tools

All endpoints are explicit arguments; no host or device is built in.

| Tool | Purpose |
|---|---|
| `probe_device.dart` | Handshake with a stock companion over TCP, read device/SELF_INFO/battery, and watch raw RX; opt-in `tx` sends one throwaway-channel group text. |
| `hil_relay.dart` | TCP relay and fault injector between a proxy and a device link. Can delay, drop, truncate, or replace replies and redacts secrets in its log. |
| `hil_raw_tx_probe.dart` | Sends one raw-packet frame per requested size on a throwaway channel to test the firmware's frame limit, then checks device liveness. |

Examples:

```sh
dart run tool/probe_device.dart <host> 5000 10 rx
dart run tool/hil_relay.dart --listen 127.0.0.1:15000 \
  --upstream <host>:5000 --log /tmp/relay.jsonl --delay-reply 12=3000
dart run tool/hil_raw_tx_probe.dart <host> 5000 157 165
```

`probe_device tx` and `hil_raw_tx_probe` transmit on air; use a random/throwaway
channel and an isolated rig.
