// ZMF Java Launcher — in-process Java virtual machine host.
//
// Loads libjvm from an embedded Java runtime with dlopen(), creates the VM via
// the JNI invocation API (JNI_CreateJavaVM) on a dedicated large-stack thread
// and invokes a static main(String[]) — the same thing the `java` launcher
// does on desktop, without spawning a process (iOS forbids that).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZMFJVMLaunchRequest : NSObject
@property (nonatomic, copy) NSString *javaHome;
@property (nonatomic, copy) NSArray<NSString *> *jvmArguments;
@property (nonatomic, copy) NSString *mainClass;
@property (nonatomic, copy) NSArray<NSString *> *applicationArguments;
@property (nonatomic, copy) NSString *workingDirectory;
/// stdout and stderr of the whole process are redirected here once the VM starts.
@property (nonatomic, copy) NSString *logPath;
/// Written with the exit code if the VM calls exit(); read on next app start.
@property (nonatomic, copy) NSString *exitStatusPath;
@end

typedef void (^ZMFJVMCompletion)(int exitCode, NSString *_Nullable errorMessage);

/// Receives the local player's state from the game (ZMF telemetry thread,
/// ~10 Hz). world is NULL when the player is not in a world. Called on a Java
/// thread: implementations must be thread-safe and fast.
typedef void (*ZMFTelemetryHandler)(const char *_Nullable world, double x, double y, double z, float yaw);
void ZMFSetTelemetryHandler(ZMFTelemetryHandler _Nullable handler);

@interface ZMFJVMBridge : NSObject
/// Locates libjvm.dylib inside a Java home (JDK 8 and 9+ layouts).
+ (nullable NSString *)libjvmPathForJavaHome:(NSString *)javaHome;
/// A JVM can be created only once per process.
+ (BOOL)hasLaunchedInThisProcess;
/// Starts the VM asynchronously. The completion runs on the main queue when
/// main() returns or the VM fails to start.
+ (void)launch:(ZMFJVMLaunchRequest *)request completion:(ZMFJVMCompletion)completion;
@end

NS_ASSUME_NONNULL_END
