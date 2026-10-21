// ZMF Java Launcher — native bridge between the iOS host app and the GLFW
// implementation that LWJGL loads inside the Java game process.
//
// The host app (Swift) uses these functions to attach a render surface,
// inject touch / keyboard / gamepad input and read frame statistics.
// The Java side never calls them directly: it only sees the standard GLFW API
// exported by this framework (see zmf_glfw.c).

#ifndef ZMF_BRIDGE_H
#define ZMF_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// GLFW constants the host app needs (values match glfw3.h).
#define ZMF_PRESS 1
#define ZMF_RELEASE 0
#define ZMF_MOUSE_LEFT 0
#define ZMF_MOUSE_RIGHT 1
#define ZMF_MOUSE_MIDDLE 2

// Context creation strategies. Which one is usable depends on which renderer
// libraries are embedded in the app bundle (see docs/RUNTIME.md).
typedef enum {
    ZMF_CONTEXT_EAGL_GLES2 = 2,   // EAGLContext ES2 (used under GL4ES)
    ZMF_CONTEXT_EAGL_GLES3 = 3,   // EAGLContext ES3 (native GLES / translators on top of GLES3)
    ZMF_CONTEXT_EGL = 10          // EGL (ANGLE / MetalANGLE) on a CAMetalLayer
} zmf_context_api;

typedef struct {
    zmf_context_api api;
    // Absolute path of the library providing GL entry points. NULL means
    // OpenGLES.framework (only valid for EAGL contexts).
    const char *gl_library_path;
    // Absolute path of the EGL library (ZMF_CONTEXT_EGL only).
    const char *egl_library_path;
    // Optional symbol in gl_library_path called once after the context is
    // current (e.g. "initialize_gl4es").
    const char *init_symbol;
} zmf_renderer_config;

// Surface ---------------------------------------------------------------------

// Configure the renderer. Must be called before the game creates its window.
void zmf_set_renderer(const zmf_renderer_config *config);

// Attach the CALayer (CAEAGLLayer or CAMetalLayer) the game renders into.
// width/height are drawable pixels. Unblocks a pending glfwCreateWindow().
void zmf_attach_layer(void *layer, int width, int height);

// Report a new drawable size (rotation / resolution scale change).
void zmf_surface_resized(int width, int height);

// Input -----------------------------------------------------------------------

void zmf_input_key(int glfw_key, int action, int mods);
void zmf_input_char(uint32_t codepoint);
void zmf_input_mouse_button(int button, int action);
// Absolute pointer position in drawable pixels (menus).
void zmf_input_cursor_pos(double x, double y);
// Relative motion in pixels (in-game camera while the cursor is grabbed).
void zmf_input_cursor_delta(double dx, double dy);
void zmf_input_scroll(double dx, double dy);
void zmf_input_window_focus(bool focused);
void zmf_request_close(void);

// True while the game has the cursor disabled (in-world camera control).
bool zmf_cursor_grabbed(void);
// True once the game created its window.
bool zmf_window_created(void);

// Frame pacing & statistics -----------------------------------------------------

// 0 = unlimited.
void zmf_set_fps_cap(int fps);
double zmf_current_fps(void);
uint64_t zmf_frames_presented(void);

#ifdef __cplusplus
}
#endif

#endif
