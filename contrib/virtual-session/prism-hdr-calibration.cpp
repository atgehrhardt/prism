/**
 * @file contrib/virtual-session/prism-hdr-calibration.cpp
 * @brief Fullscreen HDR10 calibration surface controlled by arrows, Enter and Escape.
 */
#include "color-management-v1.h"
#include "src/headless_hdr.h"
#include "xdg-shell.h"

#include <array>
#include <cairo/cairo.h>
#include <cstring>
#include <iostream>
#include <linux/input-event-codes.h>
#include <memory>
#include <sys/mman.h>
#include <unistd.h>
#include <unordered_map>
#include <wayland-client.h>

namespace {
  /**
   * @brief A shared-memory image retained until the compositor releases it.
   */
  struct buffer_t {
    wl_buffer *buffer = nullptr;  ///< Wayland buffer object.
    uint32_t *pixels = nullptr;  ///< Packed XRGB2101010 pixel storage.
    size_t size = 0;  ///< Mapping length in bytes.
    bool busy = false;  ///< Whether the compositor still owns this frame.

    /**
     * @brief Release the Wayland buffer and shared memory.
     */
    ~buffer_t() {
      if (buffer) {
        wl_buffer_destroy(buffer);
      }
      if (pixels) {
        munmap(pixels, size);
      }
    }
  };

  /**
   * @brief Native Wayland calibration application; all callbacks run on its display thread.
   */
  class application_t {
  public:
    wl_display *display = nullptr;  ///< Owned private-compositor connection.
    wl_compositor *compositor = nullptr;  ///< Surface factory.
    wl_shm *shm = nullptr;  ///< Shared-memory buffer factory.
    xdg_wm_base *shell = nullptr;  ///< Desktop surface factory.
    wp_color_manager_v1 *colors = nullptr;  ///< HDR surface-description factory.
    wl_seat *seat = nullptr;  ///< Keyboard input seat.
    wl_keyboard *keyboard = nullptr;  ///< Keyboard used by Iris controller translation.
    wl_surface *surface = nullptr;  ///< Fullscreen surface.
    xdg_surface *xdg = nullptr;  ///< Configure/acknowledgement state.
    xdg_toplevel *toplevel = nullptr;  ///< Fullscreen role.
    wp_color_management_surface_v1 *color_surface = nullptr;  ///< HDR color-management state.
    wp_image_description_v1 *description = nullptr;  ///< BT.2020/PQ source description.
    std::array<buffer_t, 2> buffers;  ///< Double-buffered frames.
    prism::hdr::calibration_t model;  ///< Wizard state and unsaved values.
    prism::hdr::profile_t original;  ///< Values restored if the wizard is cancelled.
    std::filesystem::path profile_path;  ///< Paired-device profile selected by Prism.
    std::filesystem::path live_path;  ///< Session-local preview settings.
    int width = 1280;  ///< Surface width requested by the compositor.
    int height = 720;  ///< Surface height requested by the compositor.
    bool configured = false;  ///< Whether the initial configure was acknowledged.
    bool hdr_ready = false;  ///< Whether the HDR description was accepted.
    bool supports_ten_bit = false;  ///< Whether shm advertises XRGB2101010.
    bool running = true;  ///< Whether the event loop should continue.
    bool dirty = true;  ///< Whether another frame must be drawn.
    std::string message;  ///< Recoverable save/preview error shown in the wizard.

    /**
     * @brief Draw one line using the wizard's logical 1280x720 coordinates.
     *
     * @param cr Cairo canvas.
     * @param x Horizontal position.
     * @param y Baseline.
     * @param size Font size.
     * @param value Text to draw.
     */
    static void text(cairo_t *cr, double x, double y, double size, const std::string &value) {
      cairo_set_font_size(cr, size);
      cairo_move_to(cr, x, y);
      cairo_show_text(cr, value.c_str());
    }

    /**
     * @brief Convert a normalized sRGB component into linear light.
     *
     * @param value Encoded component.
     * @return Linear-light component.
     */
    static double linear(double value) {
      return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4);
    }

    /**
     * @brief Encode a grayscale luminance into XRGB2101010.
     *
     * @param nits Absolute luminance.
     * @return Packed HDR pixel.
     */
    static uint32_t gray(double nits) {
      const auto value = static_cast<uint32_t>(std::lround(prism::hdr::pq(nits) * 1023));
      return (value << 20) | (value << 10) | value;
    }

    /**
     * @brief Allocate a compositor-compatible ten-bit shared memory buffer.
     *
     * @param target Frame storage to initialize.
     */
    void allocate(buffer_t &target) {
      target.size = static_cast<size_t>(width) * height * 4;
      const int fd = memfd_create("prism-hdr-pattern", MFD_CLOEXEC);
      if (fd < 0) {
        throw std::runtime_error("Cannot allocate calibration image");
      }
      if (ftruncate(fd, target.size) != 0) {
        close(fd);
        throw std::runtime_error("Cannot size calibration image");
      }
      auto *mapping = mmap(nullptr, target.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
      if (mapping == MAP_FAILED) {
        close(fd);
        throw std::runtime_error("Cannot map calibration image");
      }
      target.pixels = static_cast<uint32_t *>(mapping);
      auto *pool = wl_shm_create_pool(shm, fd, target.size);
      close(fd);
      target.buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB2101010);
      wl_shm_pool_destroy(pool);
      static const wl_buffer_listener listener = {
        .release = [](void *data, wl_buffer *) {
          static_cast<buffer_t *>(data)->busy = false;
        },
      };
      wl_buffer_add_listener(target.buffer, &listener, &target);
    }

    /**
     * @brief Render UI as SDR reference white and test patches as absolute PQ luminance.
     */
    void draw() {
      if (!dirty || !configured || !hdr_ready || !running) {
        return;
      }
      auto available = std::find_if(buffers.begin(), buffers.end(), [](const auto &buffer) {
        return !buffer.busy;
      });
      if (available == buffers.end()) {
        return;
      }
      auto &target = *available;
      if (!target.buffer) {
        allocate(target);
      }
      auto *canvas = cairo_image_surface_create(CAIRO_FORMAT_RGB24, width, height);
      auto *cr = cairo_create(canvas);
      cairo_scale(cr, width / 1280.0, height / 720.0);
      cairo_set_source_rgb(cr, 0.055, 0.07, 0.10);
      cairo_paint(cr);
      cairo_select_font_face(cr, "sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
      cairo_set_source_rgb(cr, 0.4, 0.8, 1.0);
      text(cr, 64, 65, 19, "HEADLESS HDR CONFIGURATION     /     " + std::to_string(model.page + 1) + " OF 3");
      cairo_set_source_rgb(cr, 1, 1, 1);
      const std::array<std::string, 3> titles {"SDR brightness", "Highlight clipping", "Ready to save"};
      text(cr, 64, 125, 42, titles[model.page]);
      if (model.page == 0) {
        text(cr, 64, 172, 21, "Adjust until white text and the white patch feel comfortably bright.");
        text(cr, 64, 205, 21, "Use your usual device brightness. This sets SDR game brightness inside HDR.");
      } else if (model.page == 1) {
        text(cr, 64, 172, 21, "Increase until the brighter cross is barely distinguishable from its square.");
        text(cr, 64, 205, 21, "If it never disappears, use your display's rated peak; do not force the maximum.");
      } else {
        text(cr, 64, 172, 21, "Saved on this host for this paired device. Other devices keep their settings.");
        text(cr, 64, 205, 21, "Future headless HDR streams use these values. Native HDR games still need setup.");
      }
      cairo_set_source_rgb(cr, 0.7, 0.76, 0.84);
      text(cr, 64, 570, 25, "SDR white: " + std::to_string(model.profile.sdr_white) + " nits     Peak: " + std::to_string(model.profile.peak) + " nits");
      text(cr, 64, 625, 21, model.page == 2 ? "A / Enter: save and close     B / Esc: back     Y / R: reset" : "D-pad left / right: adjust     A / Enter: next     B / Esc: back or cancel");
      if (!message.empty()) {
        cairo_set_source_rgb(cr, 1, 0.45, 0.35);
        text(cr, 64, 680, 18, message);
      }
      cairo_destroy(cr);
      cairo_surface_flush(canvas);
      const auto *pixels = reinterpret_cast<const uint32_t *>(cairo_image_surface_get_data(canvas));
      std::array<double, 256> lut {};
      for (size_t i = 0; i < lut.size(); ++i) {
        lut[i] = linear(i / 255.0);
      }
      std::unordered_map<uint32_t, uint32_t> encoded_colors;
      const auto patch = gray(model.page == 1 ? model.profile.peak : model.profile.sdr_white);
      const auto cross = gray(model.profile.peak * 1.04);
      std::array<uint32_t, 8> ramp {};
      for (size_t i = 0; i < ramp.size(); ++i) {
        ramp[i] = gray(linear(i / 7.0) * model.profile.sdr_white);
      }
      for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
          const auto source = pixels[y * width + x];
          auto [cached, inserted] = encoded_colors.try_emplace(source, 0);
          if (inserted) {
            const double r = lut[(source >> 16) & 255], g = lut[(source >> 8) & 255], b = lut[source & 255];
            const auto encode = [&](double value) {
              return static_cast<uint32_t>(std::lround(prism::hdr::pq(value * model.profile.sdr_white) * 1023));
            };
            // Linear-light sRGB -> BT.2020; no gamma operation is applied to PQ pixels.
            cached->second = (encode(.627404 * r + .329283 * g + .043313 * b) << 20) |
                             (encode(.069097 * r + .91954 * g + .011362 * b) << 10) |
                             encode(.016391 * r + .088013 * g + .895595 * b);
          }
          uint32_t pixel = cached->second;
          const double px = x * 1280.0 / width, py = y * 720.0 / height;
          if (px >= 480 && px < 800 && py >= 250 && py < 490) {
            pixel = patch;
            if (model.page == 1 && ((px > 624 && px < 656) || (py > 354 && py < 386))) {
              pixel = cross;
            }
          }
          if (model.page != 1 && px >= 64 && px < 400 && py >= 250 && py < 490) {
            pixel = ramp[static_cast<size_t>((px - 64) / 42)];
          }
          target.pixels[y * width + x] = pixel;
        }
      }
      cairo_surface_destroy(canvas);
      wl_surface_attach(surface, target.buffer, 0, 0);
      wl_surface_damage_buffer(surface, 0, 0, width, height);
      wl_surface_commit(surface);
      target.busy = true;
      dirty = false;
    }

    /**
     * @brief Process one controller-translated keyboard press.
     *
     * @param key Linux evdev key code.
     */
    void key(uint32_t key) {
      try {
        message.clear();
        if (key == KEY_LEFT || key == KEY_RIGHT) {
          model.adjust(key == KEY_LEFT ? -1 : 1);
          prism::hdr::write(live_path, model.profile);
        } else if (key == KEY_R) {
          model.profile = {};
          prism::hdr::write(live_path, model.profile);
        } else if (key == KEY_ENTER || key == KEY_KPENTER) {
          if (model.page < 2) {
            ++model.page;
          } else {
            prism::hdr::write(profile_path, model.profile);
            running = false;
          }
        } else if (key == KEY_ESC) {
          if (model.page > 0) {
            --model.page;
          } else {
            prism::hdr::write(live_path, original);
            running = false;
          }
        }
      } catch (const std::exception &) {
        message = "Could not save settings. Check host storage and try again.";
      }
      dirty = true;
    }

    /**
     * @brief Bind an advertised private compositor interface.
     *
     * @param registry Registry object.
     * @param name Interface ID.
     * @param interface Protocol name.
     * @param version Advertised version.
     */
    void bind(wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
      if (std::strcmp(interface, "wl_compositor") == 0) {
        compositor = static_cast<wl_compositor *>(wl_registry_bind(registry, name, &wl_compositor_interface, std::min(version, 4u)));
      } else if (std::strcmp(interface, "wl_shm") == 0) {
        shm = static_cast<wl_shm *>(wl_registry_bind(registry, name, &wl_shm_interface, 1));
        static const wl_shm_listener listener = {
          .format = [](void *data, wl_shm *, uint32_t format) {
            if (format == WL_SHM_FORMAT_XRGB2101010) {
              static_cast<application_t *>(data)->supports_ten_bit = true;
            }
          },
        };
        wl_shm_add_listener(shm, &listener, this);
      } else if (std::strcmp(interface, "xdg_wm_base") == 0) {
        shell = static_cast<xdg_wm_base *>(wl_registry_bind(registry, name, &xdg_wm_base_interface, 1));
        static const xdg_wm_base_listener listener = {
          .ping = [](void *, xdg_wm_base *shell, uint32_t serial) {
            xdg_wm_base_pong(shell, serial);
          },
        };
        xdg_wm_base_add_listener(shell, &listener, this);
      } else if (std::strcmp(interface, "wp_color_manager_v1") == 0) {
        colors = static_cast<wp_color_manager_v1 *>(wl_registry_bind(registry, name, &wp_color_manager_v1_interface, 1));
      } else if (std::strcmp(interface, "wl_seat") == 0 && !seat) {
        seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
        static const wl_seat_listener listener = {
          .capabilities = [](void *data, wl_seat *seat, uint32_t capabilities) {
            auto &app = *static_cast<application_t *>(data);
            if ((capabilities & WL_SEAT_CAPABILITY_KEYBOARD) && !app.keyboard) {
              app.keyboard = wl_seat_get_keyboard(seat);
              static const wl_keyboard_listener keys = {
                .keymap = [](void *, wl_keyboard *, uint32_t, int32_t fd, uint32_t) {
                  close(fd);
                },
                .enter = [](void *, wl_keyboard *, uint32_t, wl_surface *, wl_array *) {
                },
                .leave = [](void *, wl_keyboard *, uint32_t, wl_surface *) {
                },
                .key = [](void *data, wl_keyboard *, uint32_t, uint32_t, uint32_t key, uint32_t state) {
                  if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
                    static_cast<application_t *>(data)->key(key);
                  }
                },
                .modifiers = [](void *, wl_keyboard *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) {
                },
                .repeat_info = [](void *, wl_keyboard *, int32_t, int32_t) {
                },
              };
              wl_keyboard_add_listener(app.keyboard, &keys, &app);
            }
          },
          .name = [](void *, wl_seat *, const char *) {
          },
        };
        wl_seat_add_listener(seat, &listener, this);
      }
    }

    /**
     * @brief Create a verified HDR surface and run until saved, cancelled, or disconnected.
     *
     * @return Process exit code.
     */
    int run() {
      const char *path = std::getenv("PRISM_HDR_PROFILE");
      const char *runtime = std::getenv("XDG_RUNTIME_DIR");
      if (!path || !*path || !runtime || !std::getenv("WAYLAND_DISPLAY")) {
        throw std::runtime_error("Launch HDR calibration from Iris on a paired headless HDR session");
      }
      profile_path = path;
      live_path = std::filesystem::path(runtime) / "prism-headless-hdr";
      model.profile = original = prism::hdr::read(profile_path).value_or(prism::hdr::profile_t {});
      display = wl_display_connect(nullptr);
      if (!display) {
        throw std::runtime_error("Cannot connect to private compositor");
      }
      auto *registry = wl_display_get_registry(display);
      static const wl_registry_listener registry_listener = {
        .global = [](void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
          static_cast<application_t *>(data)->bind(registry, name, interface, version);
        },
        .global_remove = [](void *, wl_registry *, uint32_t) {
        },
      };
      wl_registry_add_listener(registry, &registry_listener, this);
      if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0 ||
          !compositor || !shm || !shell || !colors || !supports_ten_bit) {
        throw std::runtime_error("Calibration requires color-management-v1 and ten-bit shared memory");
      }
      surface = wl_compositor_create_surface(compositor);
      color_surface = wp_color_manager_v1_get_surface(colors, surface);
      auto *params = wp_color_manager_v1_create_parametric_creator(colors);
      wp_image_description_creator_params_v1_set_tf_named(params, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ);
      wp_image_description_creator_params_v1_set_primaries_named(params, WP_COLOR_MANAGER_V1_PRIMARIES_BT2020);
      description = wp_image_description_creator_params_v1_create(params);
      static const wp_image_description_v1_listener description_listener = {
        .failed = [](void *, wp_image_description_v1 *, uint32_t, const char *error) {
          std::cerr << "HDR description rejected: " << error << '\n';
        },
        .ready = [](void *data, wp_image_description_v1 *, uint32_t) {
          static_cast<application_t *>(data)->hdr_ready = true;
        },
      };
      wp_image_description_v1_add_listener(description, &description_listener, this);
      if (wl_display_roundtrip(display) < 0 || !hdr_ready) {
        throw std::runtime_error("Compositor rejected HDR calibration surface");
      }
      wp_color_management_surface_v1_set_image_description(color_surface, description, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
      xdg = xdg_wm_base_get_xdg_surface(shell, surface);
      static const xdg_surface_listener surface_listener = {
        .configure = [](void *data, xdg_surface *surface, uint32_t serial) {
          xdg_surface_ack_configure(surface, serial);
          static_cast<application_t *>(data)->configured = true;
          static_cast<application_t *>(data)->dirty = true;
        },
      };
      xdg_surface_add_listener(xdg, &surface_listener, this);
      toplevel = xdg_surface_get_toplevel(xdg);
      static const xdg_toplevel_listener toplevel_listener = {
        .configure = [](void *data, xdg_toplevel *, int32_t width, int32_t height, wl_array *) {
          auto &app = *static_cast<application_t *>(data);
          // The owned output does not resize during calibration. Ignore repeated configures.
          if (!app.configured && width > 0 && height > 0 && width <= 7680 && height <= 4320) {
            app.width = width;
            app.height = height;
          }
        },
        .close = [](void *data, xdg_toplevel *) {
          static_cast<application_t *>(data)->running = false;
        },
        .configure_bounds = nullptr,
        .wm_capabilities = nullptr,
      };
      xdg_toplevel_add_listener(toplevel, &toplevel_listener, this);
      xdg_toplevel_set_title(toplevel, prism::hdr::app_name);
      xdg_toplevel_set_app_id(toplevel, "prism.hdr-calibration");
      xdg_toplevel_set_fullscreen(toplevel, nullptr);
      wl_surface_commit(surface);
      while (running) {
        draw();
        if (wl_display_dispatch(display) < 0) {
          return 1;
        }
      }
      return 0;
    }
  };
}  // namespace

/**
 * @brief Run the controller-compatible headless HDR wizard.
 *
 * @return Zero on save/cancel; nonzero on startup failure.
 */
int main() {
  try {
    application_t app;
    return app.run();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
