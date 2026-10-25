import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

/// The complete R1 command-ID table from the 1.18 handoff contract.
const Map<int, String> _pinnedCommandIds = {
  1: 'cmdAppStart',
  2: 'cmdSendTxtMsg',
  3: 'cmdSendChannelTxtMsg',
  4: 'cmdGetContacts',
  5: 'cmdGetDeviceTime',
  6: 'cmdSetDeviceTime',
  7: 'cmdSendSelfAdvert',
  8: 'cmdSetAdvertName',
  9: 'cmdAddUpdateContact',
  10: 'cmdSyncNextMessage',
  11: 'cmdSetRadioParams',
  12: 'cmdSetRadioTxPower',
  13: 'cmdResetPath',
  14: 'cmdSetAdvertLatLon',
  15: 'cmdRemoveContact',
  16: 'cmdShareContact',
  17: 'cmdExportContact',
  18: 'cmdImportContact',
  19: 'cmdReboot',
  20: 'cmdGetBattAndStorage',
  21: 'cmdSetTuningParams',
  22: 'cmdDeviceQuery',
  23: 'cmdExportPrivateKey',
  24: 'cmdImportPrivateKey',
  25: 'cmdSendRawData',
  26: 'cmdSendLogin',
  27: 'cmdSendStatusReq',
  28: 'cmdHasConnection',
  29: 'cmdLogout',
  30: 'cmdGetContactByKey',
  31: 'cmdGetChannel',
  32: 'cmdSetChannel',
  33: 'cmdSignStart',
  34: 'cmdSignData',
  35: 'cmdSignFinish',
  36: 'cmdSendTracePath',
  37: 'cmdSetDevicePin',
  38: 'cmdSetOtherParams',
  39: 'cmdSendTelemetryReq',
  40: 'cmdGetCustomVars',
  41: 'cmdSetCustomVar',
  42: 'cmdGetAdvertPath',
  43: 'cmdGetTuningParams',
  50: 'cmdSendBinaryReq',
  51: 'cmdFactoryReset',
  52: 'cmdSendPathDiscoveryReq',
  54: 'cmdSetFloodScope',
  55: 'cmdSendControlData',
  56: 'cmdGetStats',
  57: 'cmdSendAnonReq',
  58: 'cmdSetAutoAddConfig',
  59: 'cmdGetAutoAddConfig',
  60: 'cmdGetAllowedRepeatFreq',
  61: 'cmdSetPathHashMode',
  62: 'cmdSendChannelData',
  63: 'cmdSetDefaultFloodScope',
  64: 'cmdGetDefaultFloodScope',
  65: 'cmdSendRawPacket',
  66: 'cmdRunCliCommand',
};

const Map<String, int> _actualCommandIds = {
  'cmdAppStart': cmdAppStart,
  'cmdSendTxtMsg': cmdSendTxtMsg,
  'cmdSendChannelTxtMsg': cmdSendChannelTxtMsg,
  'cmdGetContacts': cmdGetContacts,
  'cmdGetDeviceTime': cmdGetDeviceTime,
  'cmdSetDeviceTime': cmdSetDeviceTime,
  'cmdSendSelfAdvert': cmdSendSelfAdvert,
  'cmdSetAdvertName': cmdSetAdvertName,
  'cmdAddUpdateContact': cmdAddUpdateContact,
  'cmdSyncNextMessage': cmdSyncNextMessage,
  'cmdSetRadioParams': cmdSetRadioParams,
  'cmdSetRadioTxPower': cmdSetRadioTxPower,
  'cmdResetPath': cmdResetPath,
  'cmdSetAdvertLatLon': cmdSetAdvertLatLon,
  'cmdRemoveContact': cmdRemoveContact,
  'cmdShareContact': cmdShareContact,
  'cmdExportContact': cmdExportContact,
  'cmdImportContact': cmdImportContact,
  'cmdReboot': cmdReboot,
  'cmdGetBattAndStorage': cmdGetBattAndStorage,
  'cmdSetTuningParams': cmdSetTuningParams,
  'cmdDeviceQuery': cmdDeviceQuery,
  'cmdExportPrivateKey': cmdExportPrivateKey,
  'cmdImportPrivateKey': cmdImportPrivateKey,
  'cmdSendRawData': cmdSendRawData,
  'cmdSendLogin': cmdSendLogin,
  'cmdSendStatusReq': cmdSendStatusReq,
  'cmdHasConnection': cmdHasConnection,
  'cmdLogout': cmdLogout,
  'cmdGetContactByKey': cmdGetContactByKey,
  'cmdGetChannel': cmdGetChannel,
  'cmdSetChannel': cmdSetChannel,
  'cmdSignStart': cmdSignStart,
  'cmdSignData': cmdSignData,
  'cmdSignFinish': cmdSignFinish,
  'cmdSendTracePath': cmdSendTracePath,
  'cmdSetDevicePin': cmdSetDevicePin,
  'cmdSetOtherParams': cmdSetOtherParams,
  'cmdSendTelemetryReq': cmdSendTelemetryReq,
  'cmdGetCustomVars': cmdGetCustomVars,
  'cmdSetCustomVar': cmdSetCustomVar,
  'cmdGetAdvertPath': cmdGetAdvertPath,
  'cmdGetTuningParams': cmdGetTuningParams,
  'cmdSendBinaryReq': cmdSendBinaryReq,
  'cmdFactoryReset': cmdFactoryReset,
  'cmdSendPathDiscoveryReq': cmdSendPathDiscoveryReq,
  'cmdSetFloodScope': cmdSetFloodScope,
  'cmdSendControlData': cmdSendControlData,
  'cmdGetStats': cmdGetStats,
  'cmdSendAnonReq': cmdSendAnonReq,
  'cmdSetAutoAddConfig': cmdSetAutoAddConfig,
  'cmdGetAutoAddConfig': cmdGetAutoAddConfig,
  'cmdGetAllowedRepeatFreq': cmdGetAllowedRepeatFreq,
  'cmdSetPathHashMode': cmdSetPathHashMode,
  'cmdSendChannelData': cmdSendChannelData,
  'cmdSetDefaultFloodScope': cmdSetDefaultFloodScope,
  'cmdGetDefaultFloodScope': cmdGetDefaultFloodScope,
  'cmdSendRawPacket': cmdSendRawPacket,
  'cmdRunCliCommand': cmdRunCliCommand,
};

void main() {
  test('pinned R1 command IDs match the protocol constants', () {
    expect(_actualCommandIds.keys.toSet(), _pinnedCommandIds.values.toSet());
    for (final entry in _pinnedCommandIds.entries) {
      expect(
        _actualCommandIds[entry.value],
        entry.key,
        reason: '${entry.value} must be command ${entry.key}',
      );
    }
    expect(_pinnedCommandIds.keys.toSet(), hasLength(59));
    for (final unlisted in [44, 45, 46, 47, 48, 49, 53]) {
      expect(_actualCommandIds.values, isNot(contains(unlisted)));
    }
  });

  test('every pinned R1 command has an explicit server dispatch case', () {
    final source = File('../companion_server/lib/src/server.dart')
        .readAsStringSync();
    for (final name in _pinnedCommandIds.values) {
      expect(source, contains('case $name:'),
          reason: 'server dispatch is missing $name');
    }
  });
}
