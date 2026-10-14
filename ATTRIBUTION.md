# Attribution

Parts of this repository are adapted from the following MIT-licensed projects.
Original copyright notices are retained below.

## meshcore-open

<https://github.com/zjs81/meshcore-open> — MIT

- Serial/TCP frame codec (`'<'`/`'>'` framing) adapted from
  `lib/services/usb_serial_frame_codec.dart`.
- Command/response/push code constants and frame layouts adapted from
  `lib/connector/meshcore_protocol.dart`.
- MeshCore 64-byte key handling adapted from `lib/utils/keys.dart`.

## openhop_core

<https://github.com/openhop-dev/openhop_core> — MIT

- Companion command semantics, model layouts, and packet/crypto structure
  ported from `src/pymc_core/companion/` and `src/pymc_core/protocol/`.

## MeshCore firmware

<https://github.com/meshcore-dev/MeshCore> — MIT

- Protocol ground truth for the companion radio command set
  (`examples/companion_radio/MyMesh.cpp`, `docs/companion_protocol.md`).
