// ZMF Java Launcher — GL entry points interposed for EAGL rendering.
//
// Desktop GL and EGL expose the window's framebuffer as object 0. EAGL has no
// such thing: we render into an FBO backed by the CAEAGLLayer. When the game
// binds framebuffer 0 it means "the screen", so we redirect it to that FBO.
// LWJGL resolves GL symbols from this image (org.lwjgl.opengl.libname points
// at ZMFGLFW when the built-in EAGL path is used), so these definitions win
// over OpenGLES.framework, which is still searched for everything else.

#include <dlfcn.h>
#include <string.h>
#include "zmf_glfw_internal.h"

#define GL_FRAMEBUFFER 0x8D40
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#define GL_READ_FRAMEBUFFER 0x8CA8

zmf_bind_framebuffer_fn zmf_real_bind_framebuffer(void) {
    static zmf_bind_framebuffer_fn real = NULL;
    if (!real) {
        void *gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_GLOBAL);
        if (gles) real = (zmf_bind_framebuffer_fn)dlsym(gles, "glBindFramebuffer");
    }
    return real;
}

__attribute__((visibility("default")))
void glBindFramebuffer(GLenum target, GLuint framebuffer) {
    zmf_bind_framebuffer_fn real = zmf_real_bind_framebuffer();
    if (!real) return;
    if (framebuffer == 0 && (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER)) {
        framebuffer = zmf_default_framebuffer();
    }
    real(target, framebuffer);
}

void *zmf_interposed_proc(const char *name) {
    if (name && strcmp(name, "glBindFramebuffer") == 0) return (void *)&glBindFramebuffer;
    return NULL;
}
