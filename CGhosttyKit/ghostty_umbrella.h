#if __has_include("../ghostty/macos/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h")
#include "../ghostty/macos/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h"
#elif __has_include("../../../ghostty/macos/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h")
#include "../../../ghostty/macos/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h"
#else
#error "GhosttyKit umbrella header not found. Ensure the ghostty checkout is present."
#endif
