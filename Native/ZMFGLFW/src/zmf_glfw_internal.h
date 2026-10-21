// Internal helpers shared between the GLFW implementation and GL interposers.
#ifndef ZMF_GLFW_INTERNAL_H
#define ZMF_GLFW_INTERNAL_H

#include <OpenGLES/gltypes.h>

typedef void (*zmf_bind_framebuffer_fn)(GLenum target, GLuint framebuffer);

// Framebuffer object standing in for the window-system framebuffer (EAGL).
GLuint zmf_default_framebuffer(void);
// glBindFramebuffer from OpenGLES.framework, bypassing our interposer.
zmf_bind_framebuffer_fn zmf_real_bind_framebuffer(void);
// Returns our replacement for a GL entry point, or NULL.
void *zmf_interposed_proc(const char *name);

#endif
