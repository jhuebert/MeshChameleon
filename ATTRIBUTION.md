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
- Companion contact flags, message/push layouts, and response semantics adapted
  from `lib/connector/meshcore_protocol.dart` and
  `lib/connector/meshcore_connector.dart`.

## openhop_core

<https://github.com/openhop-dev/openhop_core> — MIT

- Companion command semantics, model layouts, and packet/crypto structure
  ported from `src/pymc_core/companion/` and `src/pymc_core/protocol/`.

## MeshCore firmware

<https://github.com/meshcore-dev/MeshCore> — MIT

- Protocol ground truth for the companion radio command set and packet routing
  (`examples/companion_radio/MyMesh.cpp`, `src/helpers/BaseChatMesh.cpp`,
  `src/helpers/ContactInfo.h`, `src/Mesh.cpp`, `docs/payloads.md`,
  `docs/companion_protocol.md`).
- 64-byte private-key validation algorithm and its known test keypair
  (`src/Identity.cpp:67-109`).
- Remote CLI type-3 dispatch, endpoint ACK/CLI/telemetry return-path behavior,
  contact permission bits, and discovery/raw-custom push layouts adapted from
  `BaseChatMesh.cpp`/`MyMesh.cpp`.
- CayenneLPP telemetry encoding and sensor subscribe/unsubscribe request shapes
  adapted from `src/helpers/SensorManager.h` and
  `examples/simple_sensor/SensorMesh.cpp`.
