// Device facts the launcher reports honestly in its UI.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when the process has the CS_DEBUGGED code-signing flag, i.e. a debugger
/// (for example a JIT enabler such as StikDebug) attached and the kernel now
/// allows writable+executable mappings. This is the only legitimate way a
/// sideloaded app gets JIT; on iOS 26 devices with TXM (A15 and newer,
/// including iPhone 16 Pro) the flag alone is not sufficient — the enabler
/// must also service the JIT region requests the runtime makes.
BOOL ZMFProcessHasDebuggerJIT(void);

/// Physical memory footprint of this process in bytes (what jetsam counts).
uint64_t ZMFMemoryFootprint(void);

/// Remaining memory the OS lets this process allocate before jetsam (iOS 13+).
uint64_t ZMFAvailableMemory(void);

NS_ASSUME_NONNULL_END
