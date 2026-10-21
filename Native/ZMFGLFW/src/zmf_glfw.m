// ZMF Java Launcher — GLFW 3.4 API implemented on top of iOS.
//
// LWJGL 3 binds GLFW by dlopen()ing the library named by the system property
// `org.lwjgl.glfw.libname` and resolving every glfw* entry point with dlsym().
// The launcher points that property at this framework, so Minecraft's own
// window, context, input and timer calls land here. There is exactly one
// window: the full-screen game surface owned by the host app.
//
// Threading model: the game (Java) thread calls the GLFW API; the iOS main
// thread only pushes input events into a locked queue (zmf_input_*), which
// glfwPollEvents() drains on the game thread and dispatches to the callbacks
// Minecraft registered — exactly like a desktop GLFW event loop.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES2/glext.h>
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>

#include "zmf_bridge.h"
#include "zmf_glfw_internal.h"

// ---------------------------------------------------------------------------
// GLFW constants (subset of glfw3.h needed by this implementation)

#define GLFW_TRUE 1
#define GLFW_FALSE 0
#define GLFW_RELEASE 0
#define GLFW_PRESS 1
#define GLFW_REPEAT 2
#define GLFW_KEY_LAST 348
#define GLFW_MOUSE_BUTTON_LAST 7
#define GLFW_MOD_SHIFT 0x0001
#define GLFW_MOD_CONTROL 0x0002
#define GLFW_MOD_ALT 0x0004
#define GLFW_MOD_SUPER 0x0008
#define GLFW_KEY_LEFT_SHIFT 340
#define GLFW_KEY_LEFT_CONTROL 341
#define GLFW_KEY_LEFT_ALT 342
#define GLFW_KEY_LEFT_SUPER 343
#define GLFW_KEY_RIGHT_SHIFT 344
#define GLFW_KEY_RIGHT_CONTROL 345
#define GLFW_KEY_RIGHT_ALT 346
#define GLFW_KEY_RIGHT_SUPER 347

#define GLFW_FOCUSED 0x00020001
#define GLFW_ICONIFIED 0x00020002
#define GLFW_RESIZABLE 0x00020003
#define GLFW_VISIBLE 0x00020004
#define GLFW_DECORATED 0x00020005
#define GLFW_MAXIMIZED 0x00020008
#define GLFW_HOVERED 0x0002000B
#define GLFW_CLIENT_API 0x00022001
#define GLFW_CONTEXT_VERSION_MAJOR 0x00022002
#define GLFW_CONTEXT_VERSION_MINOR 0x00022003
#define GLFW_OPENGL_PROFILE 0x00022008
#define GLFW_OPENGL_API 0x00030001
#define GLFW_OPENGL_CORE_PROFILE 0x00032001

#define GLFW_CURSOR 0x00033001
#define GLFW_STICKY_KEYS 0x00033002
#define GLFW_STICKY_MOUSE_BUTTONS 0x00033003
#define GLFW_LOCK_KEY_MODS 0x00033004
#define GLFW_RAW_MOUSE_MOTION 0x00033005
#define GLFW_CURSOR_NORMAL 0x00034001
#define GLFW_CURSOR_HIDDEN 0x00034002
#define GLFW_CURSOR_DISABLED 0x00034003

#define GLFW_NOT_INITIALIZED 0x00010001
#define GLFW_PLATFORM_COCOA 0x00060002
#define GLFW_PLATFORM_NULL 0x00060005

// ---------------------------------------------------------------------------
// Types

typedef void (*GLFWglproc)(void);
typedef void (*GLFWvkproc)(void);
typedef void (*GLFWerrorfun)(int, const char *);
typedef void (*GLFWwindowposfun)(void *, int, int);
typedef void (*GLFWwindowsizefun)(void *, int, int);
typedef void (*GLFWwindowclosefun)(void *);
typedef void (*GLFWwindowrefreshfun)(void *);
typedef void (*GLFWwindowfocusfun)(void *, int);
typedef void (*GLFWwindowiconifyfun)(void *, int);
typedef void (*GLFWwindowmaximizefun)(void *, int);
typedef void (*GLFWframebuffersizefun)(void *, int, int);
typedef void (*GLFWwindowcontentscalefun)(void *, float, float);
typedef void (*GLFWmousebuttonfun)(void *, int, int, int);
typedef void (*GLFWcursorposfun)(void *, double, double);
typedef void (*GLFWcursorenterfun)(void *, int);
typedef void (*GLFWscrollfun)(void *, double, double);
typedef void (*GLFWkeyfun)(void *, int, int, int, int);
typedef void (*GLFWcharfun)(void *, unsigned int);
typedef void (*GLFWcharmodsfun)(void *, unsigned int, int);
typedef void (*GLFWdropfun)(void *, int, const char **);
typedef void (*GLFWmonitorfun)(void *, int);
typedef void (*GLFWjoystickfun)(int, int);

typedef struct { int width, height, redBits, greenBits, blueBits, refreshRate; } GLFWvidmode;
typedef struct { unsigned short *red, *green, *blue; unsigned int size; } GLFWgammaramp;
typedef struct { int width, height; unsigned char *pixels; } GLFWimage;
typedef struct { unsigned char buttons[15]; float axes[6]; } GLFWgamepadstate;

typedef struct {
    char name[32];
    GLFWvidmode mode;
    void *user;
} zmf_monitor;

typedef struct {
    int shouldClose;
    void *user;
    char title[256];
    int cursorMode;
    double cursorX, cursorY;
    int keys[GLFW_KEY_LAST + 1];
    int buttons[GLFW_MOUSE_BUTTON_LAST + 1];
    int width, height;
    int focused;
    GLFWwindowposfun posCb;
    GLFWwindowsizefun sizeCb;
    GLFWwindowclosefun closeCb;
    GLFWwindowrefreshfun refreshCb;
    GLFWwindowfocusfun focusCb;
    GLFWwindowiconifyfun iconifyCb;
    GLFWwindowmaximizefun maximizeCb;
    GLFWframebuffersizefun fbSizeCb;
    GLFWwindowcontentscalefun scaleCb;
    GLFWmousebuttonfun mouseButtonCb;
    GLFWcursorposfun cursorPosCb;
    GLFWcursorenterfun cursorEnterCb;
    GLFWscrollfun scrollCb;
    GLFWkeyfun keyCb;
    GLFWcharfun charCb;
    GLFWcharmodsfun charModsCb;
    GLFWdropfun dropCb;
} zmf_window;

// ---------------------------------------------------------------------------
// Event queue (main thread -> game thread)

typedef enum { EV_KEY, EV_CHAR, EV_BUTTON, EV_POS, EV_DELTA, EV_SCROLL, EV_FOCUS, EV_RESIZE, EV_CLOSE } ev_type;
typedef struct { ev_type type; int a, b, c; double x, y; } zmf_event;

#define QUEUE_CAP 4096
static zmf_event g_queue[QUEUE_CAP];
static int g_qhead = 0, g_qtail = 0;
static pthread_mutex_t g_qlock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_qcond = PTHREAD_COND_INITIALIZER;

static void push_event(zmf_event ev) {
    pthread_mutex_lock(&g_qlock);
    int next = (g_qtail + 1) % QUEUE_CAP;
    if (next != g_qhead) { // drop when full rather than block the UI thread
        g_queue[g_qtail] = ev;
        g_qtail = next;
    }
    pthread_cond_broadcast(&g_qcond);
    pthread_mutex_unlock(&g_qlock);
}

static int pop_event(zmf_event *out) {
    pthread_mutex_lock(&g_qlock);
    int ok = g_qhead != g_qtail;
    if (ok) {
        *out = g_queue[g_qhead];
        g_qhead = (g_qhead + 1) % QUEUE_CAP;
    }
    pthread_mutex_unlock(&g_qlock);
    return ok;
}

// ---------------------------------------------------------------------------
// Global state

static int g_initialized = 0;
static GLFWerrorfun g_errorCb = NULL;
static GLFWmonitorfun g_monitorCb = NULL;
static zmf_monitor g_monitor = { "ZMF iPhone Display", { 0, 0, 8, 8, 8, 120 }, NULL };
static zmf_monitor *g_monitorList[1] = { &g_monitor };
static zmf_window *g_window = NULL;
static double g_timeOffset = 0;
static char g_clipboard[65536];
static int g_lastError = 0;
static const char *g_lastErrorDesc = NULL;

// Surface
static pthread_mutex_t g_surfaceLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_surfaceCond = PTHREAD_COND_INITIALIZER;
static void *g_layer = NULL;
static int g_surfaceW = 0, g_surfaceH = 0;
static volatile int g_windowCreated = 0;
static volatile int g_cursorGrabbed = 0;

// Renderer configuration
static zmf_renderer_config g_renderer = { ZMF_CONTEXT_EAGL_GLES3, NULL, NULL, NULL };
static char g_glLibPath[1024], g_eglLibPath[1024], g_initSymbol[128];
static void *g_glHandle = NULL;

// EAGL backend
static EAGLContext *g_eaglContext = nil;
static GLuint g_fbo = 0, g_colorRb = 0, g_depthRb = 0;
static int g_rbWidth = 0, g_rbHeight = 0;
static void (*real_glBindFramebuffer)(GLenum, GLuint) = NULL;

// EGL backend (resolved dynamically; ANGLE / MetalANGLE)
static void *g_eglHandle = NULL;
static void *g_eglDisplay = NULL, *g_eglSurface = NULL, *g_eglContext = NULL;
static void *(*p_eglGetDisplay)(void *);
static unsigned (*p_eglInitialize)(void *, int *, int *);
static unsigned (*p_eglBindAPI)(unsigned);
static unsigned (*p_eglChooseConfig)(void *, const int *, void **, int, int *);
static void *(*p_eglCreateWindowSurface)(void *, void *, void *, const int *);
static void *(*p_eglCreateContext)(void *, void *, void *, const int *);
static unsigned (*p_eglMakeCurrent)(void *, void *, void *, void *);
static unsigned (*p_eglSwapBuffers)(void *, void *);
static unsigned (*p_eglSwapInterval)(void *, int);
static void *(*p_eglGetProcAddress)(const char *);

// Frame pacing
static volatile int g_fpsCap = 0;
static double g_nextFrameDeadline = 0;
static double g_fpsWindowStart = 0;
static int g_fpsFrames = 0;
static volatile double g_currentFps = 0;
static volatile uint64_t g_framesPresented = 0;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void report_error(int code, const char *desc) {
    g_lastError = code;
    g_lastErrorDesc = desc;
    NSLog(@"[ZMFGLFW] error 0x%x: %s", code, desc);
    if (g_errorCb) g_errorCb(code, desc);
}

static void zmf_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void zmf_log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    // stderr is redirected to the game log by the JVM bridge.
    fprintf(stderr, "[ZMFGLFW] %s\n", s.UTF8String);
}

// ---------------------------------------------------------------------------
// Bridge API (host app)

void zmf_set_renderer(const zmf_renderer_config *config) {
    g_renderer.api = config->api;
    g_renderer.gl_library_path = NULL;
    g_renderer.egl_library_path = NULL;
    g_renderer.init_symbol = NULL;
    if (config->gl_library_path) {
        strlcpy(g_glLibPath, config->gl_library_path, sizeof g_glLibPath);
        g_renderer.gl_library_path = g_glLibPath;
    }
    if (config->egl_library_path) {
        strlcpy(g_eglLibPath, config->egl_library_path, sizeof g_eglLibPath);
        g_renderer.egl_library_path = g_eglLibPath;
    }
    if (config->init_symbol) {
        strlcpy(g_initSymbol, config->init_symbol, sizeof g_initSymbol);
        g_renderer.init_symbol = g_initSymbol;
    }
}

void zmf_attach_layer(void *layer, int width, int height) {
    pthread_mutex_lock(&g_surfaceLock);
    g_layer = layer;
    g_surfaceW = width;
    g_surfaceH = height;
    g_monitor.mode.width = width;
    g_monitor.mode.height = height;
    pthread_cond_broadcast(&g_surfaceCond);
    pthread_mutex_unlock(&g_surfaceLock);
}

void zmf_surface_resized(int width, int height) {
    pthread_mutex_lock(&g_surfaceLock);
    g_surfaceW = width;
    g_surfaceH = height;
    g_monitor.mode.width = width;
    g_monitor.mode.height = height;
    pthread_mutex_unlock(&g_surfaceLock);
    push_event((zmf_event){ EV_RESIZE, width, height, 0, 0, 0 });
}

void zmf_input_key(int key, int action, int mods) { push_event((zmf_event){ EV_KEY, key, action, mods, 0, 0 }); }
void zmf_input_char(uint32_t cp) { push_event((zmf_event){ EV_CHAR, (int)cp, 0, 0, 0, 0 }); }
void zmf_input_mouse_button(int button, int action) { push_event((zmf_event){ EV_BUTTON, button, action, 0, 0, 0 }); }
void zmf_input_cursor_pos(double x, double y) { push_event((zmf_event){ EV_POS, 0, 0, 0, x, y }); }
void zmf_input_cursor_delta(double dx, double dy) { push_event((zmf_event){ EV_DELTA, 0, 0, 0, dx, dy }); }
void zmf_input_scroll(double dx, double dy) { push_event((zmf_event){ EV_SCROLL, 0, 0, 0, dx, dy }); }
void zmf_input_window_focus(bool focused) { push_event((zmf_event){ EV_FOCUS, focused ? 1 : 0, 0, 0, 0, 0 }); }
void zmf_request_close(void) { push_event((zmf_event){ EV_CLOSE, 0, 0, 0, 0, 0 }); }
bool zmf_cursor_grabbed(void) { return g_cursorGrabbed != 0; }
bool zmf_window_created(void) { return g_windowCreated != 0; }
void zmf_set_fps_cap(int fps) { g_fpsCap = fps < 0 ? 0 : fps; }
double zmf_current_fps(void) { return g_currentFps; }
uint64_t zmf_frames_presented(void) { return g_framesPresented; }

// ---------------------------------------------------------------------------
// Context backends

static int current_mods(zmf_window *w) {
    int mods = 0;
    if (w->keys[GLFW_KEY_LEFT_SHIFT] || w->keys[GLFW_KEY_RIGHT_SHIFT]) mods |= GLFW_MOD_SHIFT;
    if (w->keys[GLFW_KEY_LEFT_CONTROL] || w->keys[GLFW_KEY_RIGHT_CONTROL]) mods |= GLFW_MOD_CONTROL;
    if (w->keys[GLFW_KEY_LEFT_ALT] || w->keys[GLFW_KEY_RIGHT_ALT]) mods |= GLFW_MOD_ALT;
    if (w->keys[GLFW_KEY_LEFT_SUPER] || w->keys[GLFW_KEY_RIGHT_SUPER]) mods |= GLFW_MOD_SUPER;
    return mods;
}

static void *gl_handle(void) {
    if (g_glHandle) return g_glHandle;
    if (g_renderer.gl_library_path) {
        g_glHandle = dlopen(g_renderer.gl_library_path, RTLD_NOW | RTLD_GLOBAL);
        if (!g_glHandle) zmf_log(@"dlopen(%s) failed: %s", g_renderer.gl_library_path, dlerror());
    }
    if (!g_glHandle) g_glHandle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_GLOBAL);
    return g_glHandle;
}

GLuint zmf_default_framebuffer(void) { return g_fbo; }

static int eagl_allocate_storage(void) {
    CAEAGLLayer *layer = (__bridge CAEAGLLayer *)g_layer;
    if (!real_glBindFramebuffer) real_glBindFramebuffer = zmf_real_bind_framebuffer();
    if (!real_glBindFramebuffer) return 0;
    if (!g_fbo) {
        glGenFramebuffers(1, &g_fbo);
        glGenRenderbuffers(1, &g_colorRb);
        glGenRenderbuffers(1, &g_depthRb);
    }
    real_glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glBindRenderbuffer(GL_RENDERBUFFER, g_colorRb);
    if (![g_eaglContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) {
        zmf_log(@"renderbufferStorage:fromDrawable: failed");
        return 0;
    }
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, g_colorRb);
    GLint w = 0, h = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
    glBindRenderbuffer(GL_RENDERBUFFER, g_depthRb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, g_depthRb);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, g_depthRb);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        zmf_log(@"framebuffer incomplete: 0x%x", status);
        return 0;
    }
    glBindRenderbuffer(GL_RENDERBUFFER, g_colorRb);
    g_rbWidth = w;
    g_rbHeight = h;
    zmf_log(@"EAGL drawable %dx%d (fbo %u)", w, h, g_fbo);
    return 1;
}

static int eagl_create(void) {
    EAGLRenderingAPI api = g_renderer.api == ZMF_CONTEXT_EAGL_GLES2 ? kEAGLRenderingAPIOpenGLES2 : kEAGLRenderingAPIOpenGLES3;
    g_eaglContext = [[EAGLContext alloc] initWithAPI:api];
    if (!g_eaglContext) {
        report_error(0x00010008, "EAGLContext creation failed");
        return 0;
    }
    [EAGLContext setCurrentContext:g_eaglContext];
    return eagl_allocate_storage();
}

static int egl_create(void) {
    g_eglHandle = dlopen(g_renderer.egl_library_path, RTLD_NOW | RTLD_GLOBAL);
    if (!g_eglHandle) {
        zmf_log(@"dlopen EGL failed: %s", dlerror());
        report_error(0x00010006, "EGL library not available");
        return 0;
    }
#define LOAD(sym) p_##sym = dlsym(g_eglHandle, #sym); if (!p_##sym) { report_error(0x00010008, "missing " #sym); return 0; }
    LOAD(eglGetDisplay) LOAD(eglInitialize) LOAD(eglBindAPI) LOAD(eglChooseConfig)
    LOAD(eglCreateWindowSurface) LOAD(eglCreateContext) LOAD(eglMakeCurrent)
    LOAD(eglSwapBuffers) LOAD(eglSwapInterval) LOAD(eglGetProcAddress)
#undef LOAD
    g_eglDisplay = p_eglGetDisplay(NULL);
    int major = 0, minor = 0;
    if (!p_eglInitialize(g_eglDisplay, &major, &minor)) { report_error(0x00010008, "eglInitialize failed"); return 0; }
    p_eglBindAPI(0x30A0 /* EGL_OPENGL_ES_API */);
    const int attribs[] = {
        0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, // RGBA
        0x3025, 24, 0x3026, 8,                      // depth, stencil
        0x3040, 0x40,                               // EGL_RENDERABLE_TYPE = ES3
        0x3033, 0x4,                                // EGL_SURFACE_TYPE = WINDOW
        0x3038
    };
    void *config = NULL;
    int count = 0;
    if (!p_eglChooseConfig(g_eglDisplay, attribs, &config, 1, &count) || count < 1) { report_error(0x00010008, "eglChooseConfig failed"); return 0; }
    g_eglSurface = p_eglCreateWindowSurface(g_eglDisplay, config, g_layer, NULL);
    if (!g_eglSurface) { report_error(0x00010008, "eglCreateWindowSurface failed"); return 0; }
    const int ctxAttribs[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 3, 0x3038 };
    g_eglContext = p_eglCreateContext(g_eglDisplay, config, NULL, ctxAttribs);
    if (!g_eglContext) { report_error(0x00010008, "eglCreateContext failed"); return 0; }
    zmf_log(@"EGL %d.%d context created", major, minor);
    return 1;
}

static void run_renderer_init(void) {
    if (!g_renderer.init_symbol) return;
    void (*initFn)(void) = dlsym(gl_handle(), g_renderer.init_symbol);
    if (initFn) {
        zmf_log(@"calling renderer init %s", g_renderer.init_symbol);
        initFn();
    } else {
        zmf_log(@"renderer init symbol %s not found", g_renderer.init_symbol);
    }
}

// ---------------------------------------------------------------------------
// GLFW: initialization, version, errors

int glfwInit(void) {
    if (g_initialized) return GLFW_TRUE;
    g_initialized = 1;
    g_timeOffset = now_seconds();
    zmf_log(@"glfwInit (ZMF GLFW 3.4 for iOS)");
    return GLFW_TRUE;
}
void glfwTerminate(void) {
    if (g_window) { free(g_window); g_window = NULL; }
    g_initialized = 0;
}
void glfwInitHint(int hint, int value) { (void)hint; (void)value; }
void glfwInitAllocator(const void *allocator) { (void)allocator; }
void glfwInitVulkanLoader(void *loader) { (void)loader; }
void glfwGetVersion(int *major, int *minor, int *rev) {
    if (major) *major = 3;
    if (minor) *minor = 4;
    if (rev) *rev = 0;
}
const char *glfwGetVersionString(void) { return "3.4.0 ZMF iOS EAGL/EGL"; }
int glfwGetError(const char **description) {
    int code = g_lastError;
    if (description) *description = g_lastErrorDesc;
    g_lastError = 0;
    g_lastErrorDesc = NULL;
    return code;
}
GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun cb) { GLFWerrorfun old = g_errorCb; g_errorCb = cb; return old; }
int glfwGetPlatform(void) { return GLFW_PLATFORM_COCOA; }
int glfwPlatformSupported(int platform) { return platform == GLFW_PLATFORM_COCOA || platform == GLFW_PLATFORM_NULL; }

// ---------------------------------------------------------------------------
// Monitors

void **glfwGetMonitors(int *count) { if (count) *count = 1; return (void **)g_monitorList; }
void *glfwGetPrimaryMonitor(void) { return &g_monitor; }
void glfwGetMonitorPos(void *m, int *x, int *y) { (void)m; if (x) *x = 0; if (y) *y = 0; }
void glfwGetMonitorWorkarea(void *m, int *x, int *y, int *w, int *h) {
    (void)m;
    if (x) *x = 0;
    if (y) *y = 0;
    if (w) *w = g_monitor.mode.width;
    if (h) *h = g_monitor.mode.height;
}
void glfwGetMonitorPhysicalSize(void *m, int *w, int *h) { (void)m; if (w) *w = 149; if (h) *h = 70; }
void glfwGetMonitorContentScale(void *m, float *x, float *y) { (void)m; if (x) *x = 1; if (y) *y = 1; }
const char *glfwGetMonitorName(void *m) { return ((zmf_monitor *)m)->name; }
void glfwSetMonitorUserPointer(void *m, void *p) { ((zmf_monitor *)m)->user = p; }
void *glfwGetMonitorUserPointer(void *m) { return ((zmf_monitor *)m)->user; }
GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun cb) { GLFWmonitorfun old = g_monitorCb; g_monitorCb = cb; return old; }
const GLFWvidmode *glfwGetVideoModes(void *m, int *count) { if (count) *count = 1; return &((zmf_monitor *)m)->mode; }
const GLFWvidmode *glfwGetVideoMode(void *m) { return &((zmf_monitor *)m)->mode; }
void glfwSetGamma(void *m, float gamma) { (void)m; (void)gamma; }
static unsigned short g_ramp[256];
static GLFWgammaramp g_gammaRamp = { g_ramp, g_ramp, g_ramp, 256 };
const GLFWgammaramp *glfwGetGammaRamp(void *m) {
    (void)m;
    for (int i = 0; i < 256; i++) g_ramp[i] = (unsigned short)(i * 257);
    return &g_gammaRamp;
}
void glfwSetGammaRamp(void *m, const GLFWgammaramp *ramp) { (void)m; (void)ramp; }

// ---------------------------------------------------------------------------
// Windows

void glfwDefaultWindowHints(void) {}
void glfwWindowHint(int hint, int value) {
    if (hint == GLFW_CONTEXT_VERSION_MAJOR || hint == GLFW_CONTEXT_VERSION_MINOR || hint == GLFW_OPENGL_PROFILE) {
        zmf_log(@"window hint 0x%x = %d", hint, value);
    }
}
void glfwWindowHintString(int hint, const char *value) { (void)hint; (void)value; }

void *glfwCreateWindow(int width, int height, const char *title, void *monitor, void *share) {
    (void)monitor; (void)share;
    if (!g_initialized) { report_error(GLFW_NOT_INITIALIZED, "GLFW is not initialized"); return NULL; }
    if (g_window) { report_error(0x00010008, "ZMF supports a single window"); return NULL; }
    zmf_log(@"glfwCreateWindow %dx%d \"%s\" — waiting for host surface", width, height, title ? title : "");

    pthread_mutex_lock(&g_surfaceLock);
    while (!g_layer) pthread_cond_wait(&g_surfaceCond, &g_surfaceLock);
    int w = g_surfaceW, h = g_surfaceH;
    pthread_mutex_unlock(&g_surfaceLock);

    zmf_window *win = calloc(1, sizeof(zmf_window));
    win->cursorMode = GLFW_CURSOR_NORMAL;
    win->width = w;
    win->height = h;
    win->focused = 1;
    if (title) strlcpy(win->title, title, sizeof win->title);
    g_window = win;

    // Contexts are created on the calling (game) thread so they are current
    // where Minecraft renders.
    int ok = g_renderer.api == ZMF_CONTEXT_EGL ? egl_create() : eagl_create();
    if (!ok) {
        free(win);
        g_window = NULL;
        return NULL;
    }
    g_windowCreated = 1;
    return win;
}

void glfwDestroyWindow(void *w) {
    if (!w) return;
    if (w == g_window) {
        g_window = NULL;
        g_windowCreated = 0;
    }
    free(w);
}
int glfwWindowShouldClose(void *w) { return ((zmf_window *)w)->shouldClose; }
void glfwSetWindowShouldClose(void *w, int v) { ((zmf_window *)w)->shouldClose = v; }
const char *glfwGetWindowTitle(void *w) { return ((zmf_window *)w)->title; }
void glfwSetWindowTitle(void *w, const char *t) { if (t) strlcpy(((zmf_window *)w)->title, t, 256); }
void glfwSetWindowIcon(void *w, int count, const GLFWimage *images) { (void)w; (void)count; (void)images; }
void glfwGetWindowPos(void *w, int *x, int *y) { (void)w; if (x) *x = 0; if (y) *y = 0; }
void glfwSetWindowPos(void *w, int x, int y) { (void)w; (void)x; (void)y; }
void glfwGetWindowSize(void *w, int *width, int *height) {
    zmf_window *win = w;
    if (width) *width = win->width;
    if (height) *height = win->height;
}
void glfwSetWindowSizeLimits(void *w, int a, int b, int c, int d) { (void)w; (void)a; (void)b; (void)c; (void)d; }
void glfwSetWindowAspectRatio(void *w, int n, int d) { (void)w; (void)n; (void)d; }
void glfwSetWindowSize(void *w, int width, int height) { (void)w; (void)width; (void)height; }
void glfwGetFramebufferSize(void *w, int *width, int *height) { glfwGetWindowSize(w, width, height); }
void glfwGetWindowFrameSize(void *w, int *l, int *t, int *r, int *b) {
    (void)w;
    if (l) *l = 0;
    if (t) *t = 0;
    if (r) *r = 0;
    if (b) *b = 0;
}
void glfwGetWindowContentScale(void *w, float *x, float *y) { (void)w; if (x) *x = 1; if (y) *y = 1; }
float glfwGetWindowOpacity(void *w) { (void)w; return 1.0f; }
void glfwSetWindowOpacity(void *w, float o) { (void)w; (void)o; }
void glfwIconifyWindow(void *w) { (void)w; }
void glfwRestoreWindow(void *w) { (void)w; }
void glfwMaximizeWindow(void *w) { (void)w; }
void glfwShowWindow(void *w) { (void)w; }
void glfwHideWindow(void *w) { (void)w; }
void glfwFocusWindow(void *w) { (void)w; }
void glfwRequestWindowAttention(void *w) { (void)w; }
void *glfwGetWindowMonitor(void *w) { (void)w; return &g_monitor; }
void glfwSetWindowMonitor(void *w, void *m, int x, int y, int width, int height, int rate) {
    (void)w; (void)m; (void)x; (void)y; (void)width; (void)height; (void)rate;
}
int glfwGetWindowAttrib(void *w, int attrib) {
    zmf_window *win = w;
    switch (attrib) {
        case GLFW_FOCUSED: return win->focused;
        case GLFW_VISIBLE: return GLFW_TRUE;
        case GLFW_HOVERED: return GLFW_TRUE;
        case GLFW_ICONIFIED: return GLFW_FALSE;
        case GLFW_MAXIMIZED: return GLFW_TRUE;
        case GLFW_RESIZABLE: return GLFW_FALSE;
        case GLFW_DECORATED: return GLFW_FALSE;
        case GLFW_CLIENT_API: return GLFW_OPENGL_API;
        case GLFW_CONTEXT_VERSION_MAJOR: return 3;
        case GLFW_CONTEXT_VERSION_MINOR: return 2;
        case GLFW_OPENGL_PROFILE: return GLFW_OPENGL_CORE_PROFILE;
        default: return 0;
    }
}
void glfwSetWindowAttrib(void *w, int attrib, int value) { (void)w; (void)attrib; (void)value; }
void glfwSetWindowUserPointer(void *w, void *p) { ((zmf_window *)w)->user = p; }
void *glfwGetWindowUserPointer(void *w) { return ((zmf_window *)w)->user; }

#define SETCB(fn, type, field) \
    type fn(void *w, type cb) { zmf_window *win = w; type old = win->field; win->field = cb; return old; }
SETCB(glfwSetWindowPosCallback, GLFWwindowposfun, posCb)
SETCB(glfwSetWindowSizeCallback, GLFWwindowsizefun, sizeCb)
SETCB(glfwSetWindowCloseCallback, GLFWwindowclosefun, closeCb)
SETCB(glfwSetWindowRefreshCallback, GLFWwindowrefreshfun, refreshCb)
SETCB(glfwSetWindowFocusCallback, GLFWwindowfocusfun, focusCb)
SETCB(glfwSetWindowIconifyCallback, GLFWwindowiconifyfun, iconifyCb)
SETCB(glfwSetWindowMaximizeCallback, GLFWwindowmaximizefun, maximizeCb)
SETCB(glfwSetFramebufferSizeCallback, GLFWframebuffersizefun, fbSizeCb)
SETCB(glfwSetWindowContentScaleCallback, GLFWwindowcontentscalefun, scaleCb)
SETCB(glfwSetKeyCallback, GLFWkeyfun, keyCb)
SETCB(glfwSetCharCallback, GLFWcharfun, charCb)
SETCB(glfwSetCharModsCallback, GLFWcharmodsfun, charModsCb)
SETCB(glfwSetMouseButtonCallback, GLFWmousebuttonfun, mouseButtonCb)
SETCB(glfwSetCursorPosCallback, GLFWcursorposfun, cursorPosCb)
SETCB(glfwSetCursorEnterCallback, GLFWcursorenterfun, cursorEnterCb)
SETCB(glfwSetScrollCallback, GLFWscrollfun, scrollCb)
SETCB(glfwSetDropCallback, GLFWdropfun, dropCb)
#undef SETCB

// ---------------------------------------------------------------------------
// Events

static void dispatch(zmf_window *w, zmf_event *ev) {
    switch (ev->type) {
        case EV_KEY: {
            if (ev->a < 0 || ev->a > GLFW_KEY_LAST) break;
            w->keys[ev->a] = ev->b != GLFW_RELEASE;
            int mods = ev->c | current_mods(w);
            if (w->keyCb) w->keyCb(w, ev->a, ev->a, ev->b, mods);
            break;
        }
        case EV_CHAR:
            if (w->charCb) w->charCb(w, (unsigned)ev->a);
            if (w->charModsCb) w->charModsCb(w, (unsigned)ev->a, current_mods(w));
            break;
        case EV_BUTTON:
            if (ev->a < 0 || ev->a > GLFW_MOUSE_BUTTON_LAST) break;
            w->buttons[ev->a] = ev->b;
            if (w->mouseButtonCb) w->mouseButtonCb(w, ev->a, ev->b, current_mods(w));
            break;
        case EV_POS:
            if (w->cursorMode == GLFW_CURSOR_DISABLED) break;
            w->cursorX = ev->x;
            w->cursorY = ev->y;
            if (w->cursorPosCb) w->cursorPosCb(w, w->cursorX, w->cursorY);
            break;
        case EV_DELTA:
            w->cursorX += ev->x;
            w->cursorY += ev->y;
            if (w->cursorPosCb) w->cursorPosCb(w, w->cursorX, w->cursorY);
            break;
        case EV_SCROLL:
            if (w->scrollCb) w->scrollCb(w, ev->x, ev->y);
            break;
        case EV_FOCUS:
            w->focused = ev->a;
            if (w->focusCb) w->focusCb(w, ev->a);
            break;
        case EV_RESIZE:
            if (g_renderer.api != ZMF_CONTEXT_EGL && g_eaglContext) {
                eagl_allocate_storage();
                w->width = g_rbWidth;
                w->height = g_rbHeight;
            } else {
                w->width = ev->a;
                w->height = ev->b;
            }
            if (w->fbSizeCb) w->fbSizeCb(w, w->width, w->height);
            if (w->sizeCb) w->sizeCb(w, w->width, w->height);
            break;
        case EV_CLOSE:
            w->shouldClose = 1;
            if (w->closeCb) w->closeCb(w);
            break;
    }
}

void glfwPollEvents(void) {
    zmf_window *w = g_window;
    zmf_event ev;
    while (pop_event(&ev)) {
        if (w) dispatch(w, &ev);
    }
}

void glfwWaitEventsTimeout(double timeout) {
    pthread_mutex_lock(&g_qlock);
    if (g_qhead == g_qtail) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        double t = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9 + (timeout > 0 ? timeout : 0);
        ts.tv_sec = (time_t)t;
        ts.tv_nsec = (long)((t - (double)ts.tv_sec) * 1e9);
        pthread_cond_timedwait(&g_qcond, &g_qlock, &ts);
    }
    pthread_mutex_unlock(&g_qlock);
    glfwPollEvents();
}
void glfwWaitEvents(void) { glfwWaitEventsTimeout(0.1); }
void glfwPostEmptyEvent(void) {
    pthread_mutex_lock(&g_qlock);
    pthread_cond_broadcast(&g_qcond);
    pthread_mutex_unlock(&g_qlock);
}

// ---------------------------------------------------------------------------
// Input

int glfwGetInputMode(void *w, int mode) {
    zmf_window *win = w;
    if (mode == GLFW_CURSOR) return win->cursorMode;
    return 0;
}
void glfwSetInputMode(void *w, int mode, int value) {
    zmf_window *win = w;
    if (mode == GLFW_CURSOR) {
        win->cursorMode = value;
        g_cursorGrabbed = value == GLFW_CURSOR_DISABLED;
    }
}
int glfwRawMouseMotionSupported(void) { return GLFW_TRUE; }

const char *glfwGetKeyName(int key, int scancode) {
    static char name[2];
    if (key == -1) key = scancode;
    if ((key >= 48 && key <= 57) || (key >= 65 && key <= 90)) {
        name[0] = (char)(key >= 65 ? key + 32 : key);
        name[1] = 0;
        return name;
    }
    switch (key) {
        case 39: return "'";
        case 44: return ",";
        case 45: return "-";
        case 46: return ".";
        case 47: return "/";
        case 59: return ";";
        case 61: return "=";
        case 91: return "[";
        case 92: return "\\";
        case 93: return "]";
        case 96: return "`";
        default: return NULL;
    }
}
int glfwGetKeyScancode(int key) { return key; }
int glfwGetKey(void *w, int key) {
    if (key < 0 || key > GLFW_KEY_LAST) return GLFW_RELEASE;
    return ((zmf_window *)w)->keys[key] ? GLFW_PRESS : GLFW_RELEASE;
}
int glfwGetMouseButton(void *w, int button) {
    if (button < 0 || button > GLFW_MOUSE_BUTTON_LAST) return GLFW_RELEASE;
    return ((zmf_window *)w)->buttons[button];
}
void glfwGetCursorPos(void *w, double *x, double *y) {
    zmf_window *win = w;
    if (x) *x = win->cursorX;
    if (y) *y = win->cursorY;
}
void glfwSetCursorPos(void *w, double x, double y) {
    zmf_window *win = w;
    win->cursorX = x;
    win->cursorY = y;
}
static int g_cursorDummy;
void *glfwCreateCursor(const GLFWimage *image, int xhot, int yhot) { (void)image; (void)xhot; (void)yhot; return &g_cursorDummy; }
void *glfwCreateStandardCursor(int shape) { (void)shape; return &g_cursorDummy; }
void glfwDestroyCursor(void *c) { (void)c; }
void glfwSetCursor(void *w, void *c) { (void)w; (void)c; }

// Joysticks: physical controllers are mapped by the host app onto keyboard and
// mouse events (GameController.framework), so GLFW reports none.
int glfwJoystickPresent(int jid) { (void)jid; return GLFW_FALSE; }
const float *glfwGetJoystickAxes(int jid, int *count) { (void)jid; if (count) *count = 0; return NULL; }
const unsigned char *glfwGetJoystickButtons(int jid, int *count) { (void)jid; if (count) *count = 0; return NULL; }
const unsigned char *glfwGetJoystickHats(int jid, int *count) { (void)jid; if (count) *count = 0; return NULL; }
const char *glfwGetJoystickName(int jid) { (void)jid; return NULL; }
const char *glfwGetJoystickGUID(int jid) { (void)jid; return NULL; }
void glfwSetJoystickUserPointer(int jid, void *p) { (void)jid; (void)p; }
void *glfwGetJoystickUserPointer(int jid) { (void)jid; return NULL; }
int glfwJoystickIsGamepad(int jid) { (void)jid; return GLFW_FALSE; }
GLFWjoystickfun glfwSetJoystickCallback(GLFWjoystickfun cb) { (void)cb; return NULL; }
int glfwUpdateGamepadMappings(const char *s) { (void)s; return GLFW_TRUE; }
const char *glfwGetGamepadName(int jid) { (void)jid; return NULL; }
int glfwGetGamepadState(int jid, GLFWgamepadstate *state) { (void)jid; (void)state; return GLFW_FALSE; }

void glfwSetClipboardString(void *w, const char *s) {
    (void)w;
    if (!s) return;
    strlcpy(g_clipboard, s, sizeof g_clipboard);
    NSString *str = [NSString stringWithUTF8String:s];
    dispatch_async(dispatch_get_main_queue(), ^{ UIPasteboard.generalPasteboard.string = str; });
}
const char *glfwGetClipboardString(void *w) {
    (void)w;
    __block NSString *str = nil;
    if ([NSThread isMainThread]) {
        str = UIPasteboard.generalPasteboard.string;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ str = UIPasteboard.generalPasteboard.string; });
    }
    strlcpy(g_clipboard, str ? str.UTF8String : "", sizeof g_clipboard);
    return g_clipboard;
}

// ---------------------------------------------------------------------------
// Time

double glfwGetTime(void) { return now_seconds() - g_timeOffset; }
void glfwSetTime(double t) { g_timeOffset = now_seconds() - t; }
uint64_t glfwGetTimerValue(void) { return (uint64_t)(now_seconds() * 1e9); }
uint64_t glfwGetTimerFrequency(void) { return 1000000000ULL; }

// ---------------------------------------------------------------------------
// Context

void glfwMakeContextCurrent(void *w) {
    if (!w) {
        if (g_renderer.api == ZMF_CONTEXT_EGL) {
            if (p_eglMakeCurrent) p_eglMakeCurrent(g_eglDisplay, NULL, NULL, NULL);
        } else {
            [EAGLContext setCurrentContext:nil];
        }
        return;
    }
    if (g_renderer.api == ZMF_CONTEXT_EGL) {
        p_eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext);
    } else {
        [EAGLContext setCurrentContext:g_eaglContext];
        if (real_glBindFramebuffer) real_glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    }
    static int initDone = 0;
    if (!initDone) {
        initDone = 1;
        run_renderer_init();
    }
}
void *glfwGetCurrentContext(void) { return g_window; }

static void pace_and_count(void) {
    double now = now_seconds();
    int cap = g_fpsCap;
    if (cap > 0) {
        double frame = 1.0 / cap;
        if (g_nextFrameDeadline > now) {
            double wait = g_nextFrameDeadline - now;
            struct timespec ts = { (time_t)wait, (long)((wait - (double)(time_t)wait) * 1e9) };
            nanosleep(&ts, NULL);
            now = now_seconds();
        }
        g_nextFrameDeadline = (g_nextFrameDeadline > now - frame ? g_nextFrameDeadline : now) + frame;
    }
    g_framesPresented++;
    g_fpsFrames++;
    if (g_fpsWindowStart == 0) g_fpsWindowStart = now;
    if (now - g_fpsWindowStart >= 1.0) {
        g_currentFps = g_fpsFrames / (now - g_fpsWindowStart);
        g_fpsFrames = 0;
        g_fpsWindowStart = now;
    }
}

void glfwSwapBuffers(void *w) {
    (void)w;
    if (g_renderer.api == ZMF_CONTEXT_EGL) {
        if (p_eglSwapBuffers) p_eglSwapBuffers(g_eglDisplay, g_eglSurface);
    } else if (g_eaglContext) {
        glBindRenderbuffer(GL_RENDERBUFFER, g_colorRb);
        [g_eaglContext presentRenderbuffer:GL_RENDERBUFFER];
        if (real_glBindFramebuffer) real_glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    }
    pace_and_count();
}
void glfwSwapInterval(int interval) {
    if (g_renderer.api == ZMF_CONTEXT_EGL && p_eglSwapInterval) p_eglSwapInterval(g_eglDisplay, interval);
}
int glfwExtensionSupported(const char *ext) {
    const char *(*getString)(unsigned) = dlsym(gl_handle(), "glGetString");
    if (!getString || !ext) return GLFW_FALSE;
    const char *exts = getString(0x1F03 /* GL_EXTENSIONS */);
    return exts && strstr(exts, ext) ? GLFW_TRUE : GLFW_FALSE;
}
GLFWglproc glfwGetProcAddress(const char *name) {
    // Interposed entry points (see zmf_gl_interpose.c) take priority so the
    // game's "default framebuffer" maps onto our EAGL drawable.
    if (g_renderer.api != ZMF_CONTEXT_EGL && !g_renderer.gl_library_path) {
        void *own = zmf_interposed_proc(name);
        if (own) return (GLFWglproc)own;
    }
    if (g_renderer.api == ZMF_CONTEXT_EGL && p_eglGetProcAddress) {
        void *p = p_eglGetProcAddress(name);
        if (p) return (GLFWglproc)p;
    }
    return (GLFWglproc)dlsym(gl_handle(), name);
}

// Vulkan is not available through GLFW on iOS.
int glfwVulkanSupported(void) { return GLFW_FALSE; }
const char **glfwGetRequiredInstanceExtensions(uint32_t *count) { if (count) *count = 0; return NULL; }
GLFWvkproc glfwGetInstanceProcAddress(void *instance, const char *name) { (void)instance; (void)name; return NULL; }
int glfwGetPhysicalDevicePresentationSupport(void *i, void *d, uint32_t q) { (void)i; (void)d; (void)q; return GLFW_FALSE; }
int glfwCreateWindowSurface(void *i, void *w, const void *a, void *s) { (void)i; (void)w; (void)a; (void)s; return -7; }
