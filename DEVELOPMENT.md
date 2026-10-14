# Development notes

## Running an end-to-end test without hardware

The pure-Dart packages include a stock-companion simulator (`FakeDeviceLink`)
and a shared radio bus (`FakeRadioBus`). The highest-value end-to-end test is
`packages/mesh_node/test/integration_test.dart`: a framed TCP client (a stand-in
for `meshcore-cli` / `meshcore-open`) connects to the proxy's `CompanionServer`,
which drives a `MeshNode` over a simulated device link, against a peer node on
the same simulated bus.

Run everything:

```sh
DART=~/dev/flutter/bin/dart FLUTTER=~/dev/flutter/bin/flutter ./scripts/check.sh
```

## Connecting a real client

Start the proxy (port defaults to 5000), then point a client at the phone's IP:

```sh
meshcli -t <phone-ip> -p 5000 infos ver clock contacts get_channels adv
```

`CLI_OK` for `infos` means the proxy's `SELF_INFO` (identity + radio params) is
correct.

## Radio units

The companion protocol is inconsistent: `SELF_INFO` and `CMD_SET_RADIO_PARAMS`
encode frequency in **kHz** (915000) and bandwidth in **Hz** (250000). The Dart
core normalises `RadioParams.frequencyHz` to true Hz and converts at the wire
boundary.

## 64-byte identity import

Fresh identities are generated from a 32-byte seed and can sign. Importing only
the 64-byte MeshCore expanded key (`[scalar][nonce]`) allows advertising,
public-key derivation, and ECDH, but not signing — the seed is not recoverable
from the expanded form. Re-import the 32-byte seed to retain signing.
