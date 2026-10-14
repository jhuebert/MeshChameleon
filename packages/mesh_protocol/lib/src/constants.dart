/// MeshCore companion + on-air protocol constants.
///
/// Command/response/push codes are ported from the MeshCore firmware
/// (`examples/companion_radio/MyMesh.cpp`) and cross-checked against
/// `meshcore-open` and `openhop_core`.
library;

// ---------------------------------------------------------------------------
// Frame delimiters (USB serial / TCP: '<' inbound, '>' outbound)
// ---------------------------------------------------------------------------
const int frameInboundPrefix = 0x3C; // '<'
const int frameOutboundPrefix = 0x3E; // '>'

/// Firmware `MAX_FRAME_SIZE`. A framed payload is at most this many bytes.
const int maxFrameSize = 172;

/// Max bytes of payload after the prefix + 2-byte length header.
const int maxPayloadSize = maxFrameSize - 3;

// ---------------------------------------------------------------------------
// Commands (app -> radio)
// ---------------------------------------------------------------------------
const int cmdAppStart = 1;
const int cmdSendTxtMsg = 2;
const int cmdSendChannelTxtMsg = 3;
const int cmdGetContacts = 4;
const int cmdGetDeviceTime = 5;
const int cmdSetDeviceTime = 6;
const int cmdSendSelfAdvert = 7;
const int cmdSetAdvertName = 8;
const int cmdAddUpdateContact = 9;
const int cmdSyncNextMessage = 10;
const int cmdSetRadioParams = 11;
const int cmdSetRadioTxPower = 12;
const int cmdResetPath = 13;
const int cmdSetAdvertLatLon = 14;
const int cmdRemoveContact = 15;
const int cmdShareContact = 16;
const int cmdExportContact = 17;
const int cmdImportContact = 18;
const int cmdReboot = 19;
const int cmdGetBattAndStorage = 20;
const int cmdSetTuningParams = 21;
const int cmdDeviceQuery = 22;
const int cmdExportPrivateKey = 23;
const int cmdImportPrivateKey = 24;
const int cmdSendRawData = 25;
const int cmdSendLogin = 26;
const int cmdSendStatusReq = 27;
const int cmdHasConnection = 28;
const int cmdLogout = 29;
const int cmdGetContactByKey = 30;
const int cmdGetChannel = 31;
const int cmdSetChannel = 32;
const int cmdSignStart = 33;
const int cmdSignData = 34;
const int cmdSignFinish = 35;
const int cmdSendTracePath = 36;
const int cmdSetDevicePin = 37;
const int cmdSetOtherParams = 38;
const int cmdSendTelemetryReq = 39;
const int cmdGetCustomVars = 40;
const int cmdSetCustomVar = 41;
const int cmdGetAdvertPath = 42;
const int cmdGetTuningParams = 43;
const int cmdSendBinaryReq = 50;
const int cmdFactoryReset = 51;
const int cmdSendPathDiscoveryReq = 52;
const int cmdSendRawPacket = 65;
const int cmdSetFloodScope = 54;
const int cmdSendControlData = 55;
const int cmdGetStats = 56;
const int cmdSendAnonReq = 57;
const int cmdSetAutoAddConfig = 58;
const int cmdGetAutoAddConfig = 59;
const int cmdGetAllowedRepeatFreq = 60;
const int cmdSetPathHashMode = 61;
const int cmdSendChannelData = 62;
const int cmdSetDefaultFloodScope = 63;
const int cmdGetDefaultFloodScope = 64;
const int cmdRunCliCommand = 66;

// ---------------------------------------------------------------------------
// Response codes (radio -> app)
// ---------------------------------------------------------------------------
const int respCodeOk = 0;
const int respCodeErr = 1;
const int respCodeContactsStart = 2;
const int respCodeContact = 3;
const int respCodeEndOfContacts = 4;
const int respCodeSelfInfo = 5;
const int respCodeSent = 6;
const int respCodeContactMsgRecv = 7;
const int respCodeChannelMsgRecv = 8;
const int respCodeCurrTime = 9;
const int respCodeNoMoreMessages = 10;
const int respCodeExportContact = 11;
const int respCodeBattAndStorage = 12;
const int respCodeDeviceInfo = 13;
const int respCodePrivateKey = 14;
const int respCodeDisabled = 15;
const int respCodeContactMsgRecvV3 = 16;
const int respCodeChannelMsgRecvV3 = 17;
const int respCodeChannelInfo = 18;
const int respCodeSignStart = 19;
const int respCodeSignature = 20;
const int respCodeCustomVars = 21;
const int respCodeAdvertPath = 22;
const int respCodeTuningParams = 23;
const int respCodeStats = 24;
const int respCodeAutoAddConfig = 25;
const int respCodeChannelDataRecv = 27;
const int respCodeDefaultFloodScope = 28;

// ---------------------------------------------------------------------------
// Push codes (radio -> app, unsolicited)
// ---------------------------------------------------------------------------
const int pushCodeAdvert = 0x80;
const int pushCodePathUpdated = 0x81;
const int pushCodeSendConfirmed = 0x82;
const int pushCodeMsgWaiting = 0x83;
const int pushCodeRawData = 0x84;
const int pushCodeLoginSuccess = 0x85;
const int pushCodeLoginFail = 0x86;
const int pushCodeStatusResponse = 0x87;
const int pushCodeLogRxData = 0x88;
const int pushCodeTraceData = 0x89;
const int pushCodeNewAdvert = 0x8A;
const int pushCodeTelemetryResponse = 0x8B;
const int pushCodeBinaryResponse = 0x8C;
const int pushCodePathDiscoveryResponse = 0x8D;
const int pushCodeControlData = 0x8E;

// ---------------------------------------------------------------------------
// Error codes
// ---------------------------------------------------------------------------
const int errCodeUnsupportedCmd = 1;
const int errCodeNotFound = 2;
const int errCodeTableFull = 3;
const int errCodeBadState = 4;
const int errCodeFileIoError = 5;
const int errCodeIllegalArg = 6;

// ---------------------------------------------------------------------------
// Stats / telemetry / advert constants
// ---------------------------------------------------------------------------
const int statsTypeCore = 0;
const int statsTypeRadio = 1;
const int statsTypePackets = 2;

const int advTypeChat = 1;
const int advTypeRepeater = 2;
const int advTypeRoom = 3;
const int advTypeSensor = 4;

// On-air request/response types (carried inside PAYLOAD_TYPE_REQ / _RESPONSE).
const int reqTypeGetStatus = 0x01;
const int reqTypeKeepAlive = 0x02;
const int reqTypeGetTelemetryData = 0x03;

// Server login response codes (`RESP_SERVER_*` in the firmware).
const int respServerLoginOk = 0x00;

// Telemetry permission bits (`TELEM_PERM_*` in the firmware).
const int telemPermBase = 0x01;
const int telemPermLocation = 0x02;
const int telemPermEnvironment = 0x04;

const int txtTypePlain = 0;
const int txtTypeCliData = 1;
const int txtTypeSigned = 2;

const int teleModeDeny = 0;
const int teleModeAllowFlags = 1;
const int teleModeAllowAll = 2;

const int advertLocNone = 0;
const int advertLocShare = 1;

const int autoAddOverwriteOldest = 0x01;
const int autoAddChat = 0x02;
const int autoAddRepeater = 0x04;
const int autoAddRoom = 0x08;
const int autoAddSensor = 0x10;

// Advert flags
const int advertFlagIsChatNode = 0x01;
const int advertFlagIsRepeater = 0x02;
const int advertFlagIsRoomServer = 0x03;
const int advertFlagIsSensor = 0x04;
const int advertFlagHasLocation = 0x10;
const int advertFlagHasName = 0x80;

// ---------------------------------------------------------------------------
// On-air payload types
// ---------------------------------------------------------------------------
const int payloadTypeReq = 0x00;
const int payloadTypeResponse = 0x01;
const int payloadTypeTxtMsg = 0x02;
const int payloadTypeAck = 0x03;
const int payloadTypeAdvert = 0x04;
const int payloadTypeGrpTxt = 0x05;
const int payloadTypeGrpData = 0x06;
const int payloadTypeAnonReq = 0x07;
const int payloadTypePath = 0x08;
const int payloadTypeTrace = 0x09;
const int payloadTypeMultipart = 0x0A;
const int payloadTypeControl = 0x0B;
const int payloadTypeRawCustom = 0x0F;

// Route types
const int routeTypeTransportFlood = 0x00;
const int routeTypeFlood = 0x01;
const int routeTypeDirect = 0x02;
const int routeTypeTransportDirect = 0x03;

// Header bit layout
const int phRouteMask = 0x03;
const int phTypeShift = 2;
const int phTypeMask = 0x0F;
const int phVerShift = 6;
const int phVerMask = 0x03;

// ---------------------------------------------------------------------------
// Sizes
// ---------------------------------------------------------------------------
const int pubKeySize = 32;
const int signatureSize = 64;
const int maxPathSize = 64;
const int pathHashSize = 1;
const int maxNameSize = 32;
const int cipherMacSize = 2;
const int cipherBlockSize = 16;
const int timestampSize = 4;

/// Firmware version code reported to the client in `RESP_CODE_DEVICE_INFO`.
const int defaultFirmwareVerCode = 11;

/// Companion protocol version the client advertises in `CMD_DEVICE_QUERY`.
const int appProtocolVersion = 4;

/// Default companion TCP port (matches firmware and CLI default).
const int defaultCompanionPort = 5000;

/// Default public channel PSK (from the MeshCore companion_radio example).
const String publicGroupPsk = 'izOH6cXN6mrJ5e26oRXNcg==';
