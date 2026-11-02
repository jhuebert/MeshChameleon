/// The highest virtual path-hash mode (1/2/3-byte hashes).
const int maxPathHashMode = 2;

/// Whether [mode] selects a supported virtual path-hash width.
bool isValidPathHashMode(int mode) => mode >= 0 && mode <= maxPathHashMode;

/// Clamp [mode] into the supported range for defensive internal callers.
int clampPathHashMode(int mode) => mode.clamp(0, maxPathHashMode);
