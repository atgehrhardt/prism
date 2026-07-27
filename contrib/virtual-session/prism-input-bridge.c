/**
 * @file prism-input-bridge.c
 * @brief Forward Prism's uinput evdev devices into the headless labwc session.
 *
 * labwc runs with WLR_BACKENDS=headless and has no libinput seat, so it cannot
 * read the "* passthrough" evdev devices that Prism (via inputtino) creates
 * ("Keyboard passthrough", "Mouse passthrough", "Touch passthrough", ...).
 * labwc does, however, advertise zwlr_virtual_pointer_manager_v1 and
 * zwp_virtual_keyboard_manager_v1, so this bridge reads the evdev devices
 * directly and replays the events over those virtual-input protocols.
 *
 * Usage: prism-input-bridge [wayland-socket-name]
 *        (defaults to $PRISM_WAYLAND_SOCKET, then "wayland-prism")
 */

#define _GNU_SOURCE
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#define LOG_PREFIX "prism-input-bridge: "
#define MAX_EVDEV 1024  ///< probe /dev/input/event0..1023 (uinput nodes get high minors)
#define MAX_FDS (MAX_EVDEV + 1)  ///< poll capacity: evdev fds + wayland fd
#define RESCAN_INTERVAL_MS 5000  ///< how often to look for new evdev devices
#define RECONNECT_DELAY_MS 2000  ///< delay between wayland reconnect attempts
#define DEFAULT_WIDTH 1920  ///< pointer x extent before any output mode arrives
#define DEFAULT_HEIGHT 1080  ///< pointer y extent before any output mode arrives

/**
 * @brief One open evdev source device.
 */
struct source {
  int fd;  ///< open file descriptor, or -1 when the slot is free
  bool keyboard;  ///< device reports alphanumeric keys (KEY_A..KEY_Z)
  bool pointer;  ///< device reports pointer motion and BTN_LEFT
};

/**
 * @brief Global bridge state.
 */
static struct {
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_seat *seat;
  struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
  struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
  struct zwlr_virtual_pointer_v1 *pointer;
  struct zwp_virtual_keyboard_v1 *keyboard;

  int output_width;  ///< current mode width of the first output
  int output_height;  ///< current mode height of the first output
  bool output_bound;  ///< whether we already bound an output

  struct source sources[MAX_EVDEV];

  /* accumulated pointer state, flushed on EV_SYN/SYN_REPORT */
  double dx;
  double dy;
  int32_t abs_x;
  int32_t abs_y;
  bool have_abs;
  double wheel_v;
  double wheel_h;

  int grabbed;  ///< whether our evdev sources are currently EVIOCGRABed
  char override_path[256];  ///< path of the prism-capture-override flag file
} g;

/**
 * @brief Whether a headless (capture-override) stream is currently active.
 *
 * While active we exclusively grab Prism's evdev devices so events reach
 * only the headless compositor, not the desktop. During normal desktop
 * streams the devices must stay ungrabbed so the desktop compositor sees them.
 */
static int override_active(void) {
  /* Only the headless wlroots override needs the grab+forward: when the
   * override targets a portal output (virtual display mode), input must
   * stay with the desktop session, which owns that output. */
  FILE *f = fopen(g.override_path, "r");
  if (!f) {
    return 0;
  }
  char line[256] = {0};
  char *got = fgets(line, sizeof(line), f);
  fclose(f);
  if (!got) {
    return 0;
  }
  return strncmp(line, "portal:", 7) != 0;
}

/**
 * @brief Apply or release the exclusive grab on all open sources.
 */
static void apply_grab(int grab) {
  for (int i = 0; i < MAX_EVDEV; i++) {
    if (g.sources[i].fd >= 0) {
      ioctl(g.sources[i].fd, EVIOCGRAB, grab);
    }
  }
  g.grabbed = grab;
  fprintf(stderr, LOG_PREFIX "%s evdev grab\n", grab ? "acquired" : "released");
}

static void log_err(const char *msg) {
  fprintf(stderr, LOG_PREFIX "%s: %s\n", msg, strerror(errno));
}

/**
 * @brief Convert an evdev timestamp to milliseconds.
 * @param ev The input event.
 * @return Timestamp in milliseconds.
 */
static uint32_t event_time_ms(const struct input_event *ev) {
  return (uint32_t) (ev->input_event_sec * 1000ULL + ev->input_event_usec / 1000ULL);
}

/* --------------------------------------------------------------------------
 * wl_output: track the current mode of the first output for pointer extents.
 * ------------------------------------------------------------------------ */

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y, int32_t physical_width, int32_t physical_height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
  (void) data;
  (void) output;
  (void) x;
  (void) y;
  (void) physical_width;
  (void) physical_height;
  (void) subpixel;
  (void) make;
  (void) model;
  (void) transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
  (void) data;
  (void) output;
  (void) refresh;
  if (flags & WL_OUTPUT_MODE_CURRENT) {
    g.output_width = width;
    g.output_height = height;
    fprintf(stderr, LOG_PREFIX "output mode: %dx%d\n", width, height);
  }
}

static void output_done(void *data, struct wl_output *output) {
  (void) data;
  (void) output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
  (void) data;
  (void) output;
  (void) factor;
}

static const struct wl_output_listener output_listener = {
  .geometry = output_geometry,
  .mode = output_mode,
  .done = output_done,
  .scale = output_scale,
};

/* --------------------------------------------------------------------------
 * wl_registry
 * ------------------------------------------------------------------------ */

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  (void) data;
  if (strcmp(interface, wl_seat_interface.name) == 0 && g.seat == NULL) {
    g.seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
  } else if (strcmp(interface, wl_output_interface.name) == 0 && !g.output_bound) {
    struct wl_output *output = wl_registry_bind(registry, name, &wl_output_interface, version < 2 ? version : 2);
    wl_output_add_listener(output, &output_listener, NULL);
    g.output_bound = true;
  } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
    g.pointer_manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, version < 2 ? version : 2);
  } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
    g.keyboard_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
  }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void) data;
  (void) registry;
  (void) name;
}

static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
  .global_remove = registry_global_remove,
};

/* --------------------------------------------------------------------------
 * Virtual keyboard keymap (default xkb keymap, shared via memfd)
 * ------------------------------------------------------------------------ */

/**
 * @brief Upload the default XKB keymap to the virtual keyboard.
 * @return 0 on success, -1 on failure.
 */
static int send_keymap(void) {
  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (!ctx) {
    fprintf(stderr, LOG_PREFIX "failed to create xkb context\n");
    return -1;
  }
  struct xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!keymap) {
    fprintf(stderr, LOG_PREFIX "failed to compile default xkb keymap\n");
    xkb_context_unref(ctx);
    return -1;
  }
  char *str = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  if (!str) {
    fprintf(stderr, LOG_PREFIX "failed to serialize xkb keymap\n");
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);
    return -1;
  }
  size_t size = strlen(str) + 1;

  int fd = memfd_create("prism-keymap", MFD_CLOEXEC);
  if (fd < 0) {
    log_err("memfd_create");
    free(str);
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);
    return -1;
  }
  bool ok = ftruncate(fd, (off_t) size) == 0 && write(fd, str, size) == (ssize_t) size;
  if (!ok) {
    log_err("keymap memfd write");
  } else {
    lseek(fd, 0, SEEK_SET);
    zwp_virtual_keyboard_v1_keymap(g.keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, (uint32_t) fd, (uint32_t) size);
  }
  close(fd);
  free(str);
  xkb_keymap_unref(keymap);
  xkb_context_unref(ctx);
  return ok ? 0 : -1;
}

/* --------------------------------------------------------------------------
 * Wayland connection setup/teardown
 * ------------------------------------------------------------------------ */

/**
 * @brief Connect to the compositor and create the virtual input devices.
 * @param name Wayland socket name.
 * @return 0 on success, -1 on failure.
 */
static int wayland_connect(const char *name) {
  g.display = wl_display_connect(name);
  if (!g.display) {
    log_err("wl_display_connect");
    return -1;
  }
  g.registry = wl_display_get_registry(g.display);
  wl_registry_add_listener(g.registry, &registry_listener, NULL);
  /* roundtrip twice: once to learn globals, once for initial output modes */
  if (wl_display_roundtrip(g.display) < 0 || wl_display_roundtrip(g.display) < 0) {
    fprintf(stderr, LOG_PREFIX "wayland roundtrip failed\n");
    return -1;
  }
  if (!g.seat || !g.pointer_manager || !g.keyboard_manager) {
    fprintf(stderr, LOG_PREFIX
            "compositor is missing wl_seat, "
            "zwlr_virtual_pointer_manager_v1 or zwp_virtual_keyboard_manager_v1\n");
    return -1;
  }
  g.pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(g.pointer_manager, g.seat);
  g.keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(g.keyboard_manager, g.seat);
  if (!g.pointer || !g.keyboard) {
    fprintf(stderr, LOG_PREFIX "failed to create virtual input devices\n");
    return -1;
  }
  if (send_keymap() < 0) {
    return -1;
  }
  wl_display_flush(g.display);
  fprintf(stderr, LOG_PREFIX "connected to wayland display '%s'\n", name);
  return 0;
}

/**
 * @brief Tear down the wayland connection so it can be re-established.
 */
static void wayland_disconnect(void) {
  if (g.pointer) {
    zwlr_virtual_pointer_v1_destroy(g.pointer);
  }
  if (g.keyboard) {
    zwp_virtual_keyboard_v1_destroy(g.keyboard);
  }
  if (g.registry) {
    wl_registry_destroy(g.registry);
  }
  if (g.display) {
    wl_display_disconnect(g.display);
  }
  g.pointer = NULL;
  g.keyboard = NULL;
  g.registry = NULL;
  g.display = NULL;
  g.seat = NULL;
  g.pointer_manager = NULL;
  g.keyboard_manager = NULL;
  g.output_bound = false;
}

/* --------------------------------------------------------------------------
 * evdev source discovery
 * ------------------------------------------------------------------------ */

/**
 * @brief Test whether a capability bitmap contains a bit.
 * @param bit Bit index (e.g. KEY_A).
 * @param array Bitmap as returned by EVIOCGBIT.
 * @return True if the bit is set.
 */
static bool test_bit(int bit, const unsigned long *array) {
  return (array[bit / (8 * sizeof(unsigned long))] >>
          (bit % (8 * sizeof(unsigned long)))) &
         1;
}

/**
 * @brief Open one evdev device if it is a Prism keyboard/pointer source.
 * @param index Device index (0..MAX_EVDEV-1).
 */
static void try_open_source(int index) {
  struct source *src = &g.sources[index];
  if (src->fd >= 0) {
    return; /* already open */
  }
  char path[32];
  snprintf(path, sizeof(path), "/dev/input/event%d", index);
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    if (errno != ENOENT && errno != ENODEV) {
      static int perm_warned = 0;
      if (!perm_warned) {
        perm_warned = 1;
        fprintf(stderr, LOG_PREFIX "cannot open %s: %s (check uaccess/permissions)\n", path, strerror(errno));
      }
    }
    return;
  }
  char name[256] = {0};
  if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0 ||
      strstr(name, "passthrough") == NULL) {
    close(fd);
    return;
  }
  unsigned long key_bits[(KEY_MAX + 8 * sizeof(unsigned long)) / (8 * sizeof(unsigned long))] = {0};
  unsigned long rel_bits[(REL_MAX + 8 * sizeof(unsigned long)) / (8 * sizeof(unsigned long))] = {0};
  unsigned long abs_bits[(ABS_MAX + 8 * sizeof(unsigned long)) / (8 * sizeof(unsigned long))] = {0};
  ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits);
  ioctl(fd, EVIOCGBIT(EV_REL, sizeof(rel_bits)), rel_bits);
  ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits);

  bool keyboard = test_bit(KEY_A, key_bits) && test_bit(KEY_Z, key_bits);
  bool pointer = test_bit(BTN_LEFT, key_bits) &&
                 ((test_bit(REL_X, rel_bits) && test_bit(REL_Y, rel_bits)) ||
                  (test_bit(ABS_X, abs_bits) && test_bit(ABS_Y, abs_bits)));
  if (!keyboard && !pointer) {
    close(fd);
    return;
  }
  src->fd = fd;
  src->keyboard = keyboard;
  src->pointer = pointer;
  if (g.grabbed) {
    ioctl(fd, EVIOCGRAB, 1);
  }
  fprintf(stderr, LOG_PREFIX "opened %s (%s)%s%s\n", path, name, keyboard ? " keyboard" : "", pointer ? " pointer" : "");
}

/**
 * @brief Scan for new Prism evdev devices and prune dead fds.
 */
static void rescan_sources(void) {
  int want_grab = override_active();
  if (want_grab != g.grabbed) {
    apply_grab(want_grab);
  }
  for (int i = 0; i < MAX_EVDEV; i++) {
    struct source *src = &g.sources[i];
    if (src->fd >= 0) {
      /* uinput devices disappear when Prism tears them down; a read on a
       * revoked fd fails with ENODEV, handled in the poll loop. Also probe
       * here so a vanished device is dropped even if it goes quiet. */
      char name[1];
      if (ioctl(src->fd, EVIOCGNAME(0), name) < 0 && errno == ENODEV) {
        fprintf(stderr, LOG_PREFIX "/dev/input/event%d disappeared\n", i);
        close(src->fd);
        src->fd = -1;
      }
    }
    try_open_source(i);
  }
}

/* --------------------------------------------------------------------------
 * Event forwarding
 * ------------------------------------------------------------------------ */

/**
 * @brief Flush accumulated pointer deltas/axes and end the frame.
 * @param time_ms Timestamp for the frame's events.
 */
static void pointer_frame(uint32_t time_ms) {
  if (g.dx != 0 || g.dy != 0) {
    zwlr_virtual_pointer_v1_motion(g.pointer, time_ms, wl_fixed_from_double(g.dx), wl_fixed_from_double(g.dy));
    g.dx = g.dy = 0;
  }
  if (g.have_abs) {
    int width = g.output_width > 0 ? g.output_width : DEFAULT_WIDTH;
    int height = g.output_height > 0 ? g.output_height : DEFAULT_HEIGHT;
    zwlr_virtual_pointer_v1_motion_absolute(g.pointer, time_ms, (uint32_t) g.abs_x, (uint32_t) g.abs_y, (uint32_t) width, (uint32_t) height);
    g.have_abs = false;
  }
  if (g.wheel_v != 0) {
    zwlr_virtual_pointer_v1_axis_source(g.pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
    zwlr_virtual_pointer_v1_axis(g.pointer, time_ms, WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(-g.wheel_v));
    g.wheel_v = 0;
  }
  if (g.wheel_h != 0) {
    zwlr_virtual_pointer_v1_axis_source(g.pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
    zwlr_virtual_pointer_v1_axis(g.pointer, time_ms, WL_POINTER_AXIS_HORIZONTAL_SCROLL, wl_fixed_from_double(-g.wheel_h));
    g.wheel_h = 0;
  }
  zwlr_virtual_pointer_v1_frame(g.pointer);
  wl_display_flush(g.display);
}

/**
 * @brief Forward one evdev event to the virtual keyboard or pointer.
 * @param src The source device the event came from.
 * @param ev The input event.
 */
static void forward_event(const struct source *src, const struct input_event *ev) {
  uint32_t t = event_time_ms(ev);
  switch (ev->type) {
    case EV_KEY:
      if (ev->code == BTN_LEFT || ev->code == BTN_RIGHT || ev->code == BTN_MIDDLE ||
          ev->code == BTN_SIDE || ev->code == BTN_EXTRA) {
        if (src->pointer && (ev->value == 0 || ev->value == 1)) {
          zwlr_virtual_pointer_v1_button(g.pointer, t, ev->code, ev->value ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
          zwlr_virtual_pointer_v1_frame(g.pointer);
          wl_display_flush(g.display);
        }
      } else if (src->keyboard && ev->value <= 2) {
        zwp_virtual_keyboard_v1_key(g.keyboard, t, ev->code, ev->value ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
      }
      break;
    case EV_REL:
      switch (ev->code) {
        case REL_X:
          g.dx += ev->value;
          break;
        case REL_Y:
          g.dy += ev->value;
          break;
        case REL_WHEEL:
          g.wheel_v += ev->value;
          break;
        case REL_HWHEEL:
          g.wheel_h += ev->value;
          break;
        default:
          break;
      }
      break;
    case EV_ABS:
      if (ev->code == ABS_X) {
        g.abs_x = ev->value;
        g.have_abs = true;
      } else if (ev->code == ABS_Y) {
        g.abs_y = ev->value;
        g.have_abs = true;
      }
      break;
    case EV_SYN:
      if (ev->code == SYN_REPORT && src->pointer) {
        pointer_frame(t);
      }
      break;
    default:
      break;
  }
}

/**
 * @brief Drain all pending events from one evdev fd.
 * @param src The source device.
 * @return False if the device vanished (fd closed).
 */
static bool drain_source(struct source *src) {
  for (;;) {
    struct input_event ev;
    ssize_t n = read(src->fd, &ev, sizeof(ev));
    if (n == (ssize_t) sizeof(ev)) {
      forward_event(src, &ev);
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return true;
    } else if (n < 0 && errno == ENODEV) {
      fprintf(stderr, LOG_PREFIX "source device revoked, closing\n");
      close(src->fd);
      src->fd = -1;
      return false;
    } else if (n < 0 && errno == EINTR) {
      continue;
    } else {
      return true; /* short read or other error; try again next poll */
    }
  }
}

/**
 * @brief Main loop: poll wayland + evdev fds until the wayland connection dies.
 * @return -1 when the wayland connection is lost (caller reconnects).
 */
static int run_loop(void) {
  int wl_fd = wl_display_get_fd(g.display);
  struct timespec last_scan = {0, 0};
  rescan_sources();
  clock_gettime(CLOCK_MONOTONIC, &last_scan);

  for (;;) {
    while (wl_display_prepare_read(g.display) != 0) {
      wl_display_dispatch_pending(g.display);
    }
    wl_display_flush(g.display);

    struct pollfd fds[MAX_FDS];
    struct source *map[MAX_FDS];
    fds[0] = (struct pollfd) {.fd = wl_fd, .events = POLLIN};
    int nfds = 1;
    for (int i = 0; i < MAX_EVDEV; i++) {
      if (g.sources[i].fd >= 0) {
        map[nfds] = &g.sources[i];
        fds[nfds] = (struct pollfd) {.fd = g.sources[i].fd, .events = POLLIN};
        nfds++;
      }
    }

    /* timeout = min(time to next rescan, 1s) so we also notice revoked fds */
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long since_scan = (now.tv_sec - last_scan.tv_sec) * 1000 +
                      (now.tv_nsec - last_scan.tv_nsec) / 1000000;
    int timeout = (int) (RESCAN_INTERVAL_MS - since_scan);
    if (timeout < 0 || timeout > 1000) {
      timeout = timeout < 0 ? 0 : 1000;
    }

    int ret = poll(fds, (nfds_t) nfds, timeout);
    if (ret < 0) {
      if (errno == EINTR) {
        wl_display_cancel_read(g.display);
        continue;
      }
      log_err("poll");
      wl_display_cancel_read(g.display);
      return -1;
    }

    if (fds[0].revents & POLLIN) {
      if (wl_display_read_events(g.display) < 0) {
        fprintf(stderr, LOG_PREFIX "wayland connection lost\n");
        return -1;
      }
    } else {
      wl_display_cancel_read(g.display);
    }
    if (fds[0].revents & (POLLERR | POLLHUP)) {
      fprintf(stderr, LOG_PREFIX "wayland connection lost\n");
      return -1;
    }
    wl_display_dispatch_pending(g.display);

    if (ret > 0) {
      for (int i = 1; i < nfds; i++) {
        if (fds[i].revents & POLLIN) {
          drain_source(map[i]);
        }
      }
    }

    if (timeout == 0 || since_scan >= RESCAN_INTERVAL_MS) {
      rescan_sources();
      clock_gettime(CLOCK_MONOTONIC, &last_scan);
    }
  }
}

int main(int argc, char **argv) {
  const char *socket = argc > 1 ? argv[1] : getenv("PRISM_WAYLAND_SOCKET");
  if (!socket || !*socket) {
    socket = "wayland-prism";
  }

  for (int i = 0; i < MAX_EVDEV; i++) {
    g.sources[i].fd = -1;
  }
  g.output_width = DEFAULT_WIDTH;
  g.output_height = DEFAULT_HEIGHT;

  const char *runtime = getenv("XDG_RUNTIME_DIR");
  if (!runtime || !*runtime) {
    runtime = "/run/user/1000";
  }
  snprintf(g.override_path, sizeof(g.override_path), "%s/prism-capture-override", runtime);

  for (;;) {
    if (wayland_connect(socket) == 0) {
      run_loop();
      wayland_disconnect();
    }
    fprintf(stderr, LOG_PREFIX "retrying wayland connection in %d ms\n", RECONNECT_DELAY_MS);
    struct timespec ts = {RECONNECT_DELAY_MS / 1000, (long) (RECONNECT_DELAY_MS % 1000) * 1000000L};
    nanosleep(&ts, NULL);
  }
}
