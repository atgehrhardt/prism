/**
 * @file tests/unit/platform/test_graphics.cpp
 * @brief Verify framebuffer orientation without losing HDR component precision.
 */
#ifdef __linux__
  #include "src/platform/linux/graphics.h"

  #include <array>
  #include <dlfcn.h>
  #include <gtest/gtest.h>

/** @brief Offscreen OpenGL fixture, usable with Mesa software rendering in CI. */
class GraphicsCopyTest: public testing::Test {
protected:
  /** @brief Open an isolated surfaceless context or skip if EGL cannot provide it. */
  void SetUp() override {
    saved_gl = gl::ctx;
    egl_library = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!egl_library) {
      GTEST_SKIP() << "EGL library is unavailable";
    }
    auto get_platform = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYPROC>(dlsym(egl_library, "eglGetPlatformDisplay"));
    auto initialize = reinterpret_cast<PFNEGLINITIALIZEPROC>(dlsym(egl_library, "eglInitialize"));
    if (!get_platform || !initialize) {
      GTEST_SKIP() << "EGL 1.5 is unavailable";
    }
    constexpr EGLenum surfaceless_mesa = 0x31DD;
    display = get_platform(surfaceless_mesa, nullptr, nullptr);
    if (display == EGL_NO_DISPLAY || !initialize(display, nullptr, nullptr)) {
      display = EGL_NO_DISPLAY;
      GTEST_SKIP() << "Surfaceless EGL is unavailable";
    }
    ASSERT_NE(gladLoaderLoadEGL(display), 0);
    ASSERT_TRUE(eglBindAPI(EGL_OPENGL_API));
    const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
    EGLConfig config;
    EGLint count = 0;
    ASSERT_TRUE(eglChooseConfig(display, config_attributes, &config, 1, &count));
    ASSERT_GT(count, 0);
    const EGLint context_attributes[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    ASSERT_NE(context, EGL_NO_CONTEXT);
    ASSERT_TRUE(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context));
    ASSERT_NE(gladLoadGLContext(&gl::ctx, eglGetProcAddress), 0);
  }

  /** @brief Restore the process GL dispatch table after releasing the test context. */
  void TearDown() override {
    if (display != EGL_NO_DISPLAY) {
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (context != EGL_NO_CONTEXT) {
        eglDestroyContext(display, context);
      }
      eglTerminate(display);
    }
    gl::ctx = saved_gl;
    if (egl_library) {
      dlclose(egl_library);
    }
  }

  /** @brief Copy distinctive 10-bit values and verify exact orientation and precision. */
  void check_copy(bool invert) {
    // Adjacent values differ below eight-bit precision; an eight-bit staging
    // texture would lose this distinction even when row order was correct.
    const std::array<uint32_t, 4> source = {1u | (3u << 30), 2u | (3u << 30), 1001u | (3u << 30), 1002u | (3u << 30)};
    auto textures = gl::tex_t::make(2);
    gl::ctx.BindTexture(GL_TEXTURE_2D, textures[0]);
    gl::ctx.TexImage2D(GL_TEXTURE_2D, 0, GL_RGB10_A2, 2, 2, 0, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, source.data());
    gl::ctx.BindTexture(GL_TEXTURE_2D, textures[1]);
    gl::ctx.TexImage2D(GL_TEXTURE_2D, 0, GL_RGB10_A2, 2, 2, 0, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, nullptr);
    auto framebuffer = gl::frame_buf_t::make(1);
    framebuffer.bind(textures.begin(), textures.begin() + 1);
    ASSERT_EQ(gl::ctx.CheckFramebufferStatus(GL_FRAMEBUFFER), GL_FRAMEBUFFER_COMPLETE);
    framebuffer.copy(0, textures[1], 0, 0, 2, 2, invert);
    std::array<uint32_t, 4> result {};
    gl::ctx.BindTexture(GL_TEXTURE_2D, textures[1]);
    gl::ctx.GetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, result.data());
    ASSERT_EQ(gl::ctx.GetError(), GL_NO_ERROR);
    const std::array<uint32_t, 4> reversed = {source[2], source[3], source[0], source[1]};
    EXPECT_EQ(result, invert ? reversed : source);
  }

  EGLDisplay display = EGL_NO_DISPLAY;  ///< Offscreen display, including failed initialization.
  EGLContext context = EGL_NO_CONTEXT;  ///< Context owned by this fixture.
  GladGLContext saved_gl {};  ///< Previous process dispatch table.
  void *egl_library = nullptr;  ///< Loader used to initialize EGL before GLAD queries its version.
};

TEST_F(GraphicsCopyTest, PreservesTenBitPixelsWithoutInversion) {
  check_copy(false);
}

TEST_F(GraphicsCopyTest, ReversesRowsWithoutReducingTenBitPrecision) {
  check_copy(true);
}
#endif
