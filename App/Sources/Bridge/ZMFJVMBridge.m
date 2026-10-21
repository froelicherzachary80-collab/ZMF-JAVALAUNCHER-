#import "ZMFJVMBridge.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <jni.h>
#include <stdatomic.h>

typedef jint (JNICALL *CreateJavaVM_t)(JavaVM **, void **, void *);

@implementation ZMFJVMLaunchRequest
@end

static BOOL gLaunched = NO;
static _Atomic(ZMFTelemetryHandler) gTelemetryHandler = NULL;

void ZMFSetTelemetryHandler(ZMFTelemetryHandler handler) {
    gTelemetryHandler = handler;
}

// dev.zmf.support.telemetry.NativeBridge.publish(String, double, double, double, float)
static void JNICALL zmf_native_publish(JNIEnv *env, jclass cls, jstring world, jdouble x, jdouble y, jdouble z, jfloat yaw) {
    (void)cls;
    ZMFTelemetryHandler handler = gTelemetryHandler;
    if (!handler) return;
    if (!world) {
        handler(NULL, x, y, z, yaw);
        return;
    }
    const char *utf = (*env)->GetStringUTFChars(env, world, NULL);
    if (!utf) return;
    handler(utf, x, y, z, yaw);
    (*env)->ReleaseStringUTFChars(env, world, utf);
}

static void register_natives(JNIEnv *env) {
    jclass bridge = (*env)->FindClass(env, "dev/zmf/support/telemetry/NativeBridge");
    if (!bridge) {
        (*env)->ExceptionClear(env);
        return;
    }
    JNINativeMethod methods[] = {
        { "publish", "(Ljava/lang/String;DDDF)V", (void *)zmf_native_publish },
    };
    if ((*env)->RegisterNatives(env, bridge, methods, 1) != 0) {
        (*env)->ExceptionClear(env);
        fprintf(stderr, "[ZMF] RegisterNatives for telemetry failed\n");
    }
}
static char gExitStatusPath[1024];

static void JNICALL zmf_vm_exit_hook(jint code) {
    // The VM is about to call exit(): record why so the launcher can tell a
    // normal quit from a crash on its next start.
    if (gExitStatusPath[0]) {
        FILE *f = fopen(gExitStatusPath, "w");
        if (f) {
            fprintf(f, "%d\n", (int)code);
            fclose(f);
        }
    }
    fprintf(stderr, "[ZMF] JVM exit(%d)\n", (int)code);
    fflush(stderr);
}

static void JNICALL zmf_vm_abort_hook(void) {
    fprintf(stderr, "[ZMF] JVM abort()\n");
    fflush(stderr);
    if (gExitStatusPath[0]) {
        FILE *f = fopen(gExitStatusPath, "w");
        if (f) {
            fputs("abort\n", f);
            fclose(f);
        }
    }
}

@interface ZMFJVMThreadContext : NSObject
@property (nonatomic, strong) ZMFJVMLaunchRequest *request;
@property (nonatomic, copy) ZMFJVMCompletion completion;
@end
@implementation ZMFJVMThreadContext
@end

static void finish(ZMFJVMThreadContext *ctx, int code, NSString *error) {
    if (error) fprintf(stderr, "[ZMF] %s\n", error.UTF8String);
    fflush(stdout);
    fflush(stderr);
    ZMFJVMCompletion completion = ctx.completion;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(code, error); });
}

static void *zmf_jvm_thread(void *arg) {
    ZMFJVMThreadContext *ctx = (__bridge_transfer ZMFJVMThreadContext *)arg;
    ZMFJVMLaunchRequest *req = ctx.request;

    NSString *libjvm = [ZMFJVMBridge libjvmPathForJavaHome:req.javaHome];
    if (!libjvm) {
        finish(ctx, -1, [NSString stringWithFormat:@"libjvm.dylib not found in %@", req.javaHome]);
        return NULL;
    }
    void *handle = dlopen(libjvm.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        finish(ctx, -1, [NSString stringWithFormat:@"dlopen(libjvm) failed: %s", dlerror()]);
        return NULL;
    }
    CreateJavaVM_t createVM = (CreateJavaVM_t)dlsym(handle, "JNI_CreateJavaVM");
    if (!createVM) {
        finish(ctx, -1, @"JNI_CreateJavaVM symbol missing");
        return NULL;
    }

    NSUInteger count = req.jvmArguments.count + 2;
    JavaVMOption *options = calloc(count, sizeof(JavaVMOption));
    NSUInteger i = 0;
    for (NSString *arg in req.jvmArguments) {
        options[i++].optionString = strdup(arg.UTF8String);
    }
    options[i].optionString = "exit";
    options[i++].extraInfo = (void *)zmf_vm_exit_hook;
    options[i].optionString = "abort";
    options[i++].extraInfo = (void *)zmf_vm_abort_hook;

    JavaVMInitArgs vmArgs;
    vmArgs.version = JNI_VERSION_1_6;
    vmArgs.nOptions = (jint)count;
    vmArgs.options = options;
    vmArgs.ignoreUnrecognized = JNI_TRUE;

    fprintf(stderr, "[ZMF] Creating JVM from %s with %lu options\n", libjvm.UTF8String, (unsigned long)count);
    for (NSString *arg in req.jvmArguments) {
        // Never log session tokens.
        if ([arg containsString:@"accessToken"]) continue;
        fprintf(stderr, "[ZMF]   %s\n", arg.UTF8String);
    }

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint rc = createVM(&vm, (void **)&env, &vmArgs);
    if (rc != JNI_OK || !env) {
        finish(ctx, (int)rc, [NSString stringWithFormat:@"JNI_CreateJavaVM failed (%d)", (int)rc]);
        return NULL;
    }

    register_natives(env);

    NSString *internalName = [req.mainClass stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    jclass mainClass = (*env)->FindClass(env, internalName.UTF8String);
    if (!mainClass) {
        (*env)->ExceptionDescribe(env);
        finish(ctx, 1, [NSString stringWithFormat:@"Main class %@ not found", req.mainClass]);
        return NULL;
    }
    jmethodID mainMethod = (*env)->GetStaticMethodID(env, mainClass, "main", "([Ljava/lang/String;)V");
    if (!mainMethod) {
        (*env)->ExceptionDescribe(env);
        finish(ctx, 1, @"main(String[]) not found");
        return NULL;
    }
    jclass stringClass = (*env)->FindClass(env, "java/lang/String");
    jobjectArray jargs = (*env)->NewObjectArray(env, (jsize)req.applicationArguments.count, stringClass, NULL);
    jsize index = 0;
    for (NSString *arg in req.applicationArguments) {
        jstring s = (*env)->NewStringUTF(env, arg.UTF8String);
        (*env)->SetObjectArrayElement(env, jargs, index++, s);
        (*env)->DeleteLocalRef(env, s);
    }

    (*env)->CallStaticVoidMethod(env, mainClass, mainMethod, jargs);
    int exitCode = 0;
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        exitCode = 1;
    }
    // Wait for remaining non-daemon threads like the desktop launcher does.
    (*vm)->DestroyJavaVM(vm);
    finish(ctx, exitCode, exitCode ? @"Java main() ended with an uncaught exception" : nil);
    return NULL;
}

@implementation ZMFJVMBridge

+ (NSString *)libjvmPathForJavaHome:(NSString *)javaHome {
    NSArray<NSString *> *candidates = @[
        @"lib/server/libjvm.dylib",
        @"lib/zero/libjvm.dylib",
        @"lib/client/libjvm.dylib",
        @"jre/lib/server/libjvm.dylib",
        @"lib/aarch64/server/libjvm.dylib",
        @"jre/lib/aarch64/server/libjvm.dylib",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *rel in candidates) {
        NSString *path = [javaHome stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

+ (BOOL)hasLaunchedInThisProcess {
    return gLaunched;
}

+ (void)launch:(ZMFJVMLaunchRequest *)request completion:(ZMFJVMCompletion)completion {
    if (gLaunched) {
        completion(-1, @"A Java VM was already started in this app session. Restart the app to launch again.");
        return;
    }
    gLaunched = YES;
    strlcpy(gExitStatusPath, request.exitStatusPath.fileSystemRepresentation, sizeof gExitStatusPath);
    [NSFileManager.defaultManager removeItemAtPath:request.exitStatusPath error:nil];

    // Route the VM's console output into the session log.
    int fd = open(request.logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        close(fd);
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }
    chdir(request.workingDirectory.fileSystemRepresentation);
    setenv("JAVA_HOME", request.javaHome.fileSystemRepresentation, 1);

    ZMFJVMThreadContext *ctx = [ZMFJVMThreadContext new];
    ctx.request = request;
    ctx.completion = completion;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    // HotSpot's main thread needs far more than the default 512 KiB.
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, zmf_jvm_thread, (__bridge_retained void *)ctx);
    pthread_attr_destroy(&attr);
    if (err != 0) {
        gLaunched = NO;
        completion(-1, [NSString stringWithFormat:@"pthread_create failed (%d)", err]);
        return;
    }
    pthread_detach(thread);
}

@end
