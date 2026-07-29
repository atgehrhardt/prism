/**
 * @file prism-input-bridge.c
 * @brief Forward Prism-owned evdev mouse and keyboard events to private labwc.
 */

#define _GNU_SOURCE
#include "virtual-keyboard-unstable-v1.h"
#include "wlr-virtual-pointer-unstable-v1.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#define LOG_PREFIX "prism-input-bridge: "
#define MAX_EVDEV 1024  ///< Maximum evdev minor probed for Prism devices.
#define MAX_POLL_FDS (MAX_EVDEV + 1)  ///< Wayland descriptor plus evdev sources.
#define ACTIVATION_INTERVAL_MS 50  ///< Maximum override deactivation latency.
#define DEVICE_RESCAN_INTERVAL_MS 1000  ///< Prism evdev discovery interval.
#define RECONNECT_DELAY_MS 250  ///< Delay before reconnecting to owned labwc.

/**
 * @brief One Prism-owned evdev source.
 */
struct source {
  int fd;  ///< Open evdev descriptor, or negative one.
  bool keyboard;  ///< Device provides keyboard keys.
  bool pointer;  ///< Device provides pointer input.
  struct input_absinfo abs_x;  ///< Absolute X coordinate range.
  struct input_absinfo abs_y;  ///< Absolute Y coordinate range.
};

/**
 * @brief Process-wide bridge state.
 */
static struct {
  struct wl_display *display;  ///< Connection to the exact private compositor.
  struct wl_registry *registry;  ///< Wayland global registry.
  struct wl_seat *seat;  ///< Labwc seat receiving virtual devices.
  struct zwlr_virtual_pointer_manager_v1 *pointer_manager;  ///< wlroots pointer manager.
  struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;  ///< wlroots keyboard manager.
  struct zwlr_virtual_pointer_v1 *pointer;  ///< Virtual pointer sent to labwc.
  struct zwp_virtual_keyboard_v1 *keyboard;  ///< Virtual keyboard sent to labwc.
  struct source sources[MAX_EVDEV];  ///< Open Prism evdev sources.
  char session_id[129];  ///< Expected Prism session identifier.
  char wayland_socket[64];  ///< Exact session-owned labwc socket.
  char override_path[4096];  ///< Capture override activation path.
  char ready_path[4096];  ///< Input readiness marker path.
  bool active;  ///< Whether the matching capture override is committed.
  bool pointer_emitted;  ///< Whether the current frame contains pointer data.
  double dx;  ///< Accumulated relative X motion.
  double dy;  ///< Accumulated relative Y motion.
  int32_t abs_x;  ///< Latest absolute X coordinate.
  int32_t abs_y;  ///< Latest absolute Y coordinate.
  uint32_t abs_width;  ///< Absolute X extent.
  uint32_t abs_height;  ///< Absolute Y extent.
  bool have_abs_x;  ///< Whether absolute X changed in the frame.
  bool have_abs_y;  ///< Whether absolute Y changed in the frame.
  int32_t wheel_x;  ///< Low-resolution horizontal wheel steps.
  int32_t wheel_y;  ///< Low-resolution vertical wheel steps.
  int32_t wheel_hi_x;  ///< High-resolution horizontal wheel units.
  int32_t wheel_hi_y;  ///< High-resolution vertical wheel units.
  bool have_wheel_hi_x;  ///< Whether high-resolution horizontal data exists.
  bool have_wheel_hi_y;  ///< Whether high-resolution vertical data exists.
} bridge;

/**
 * @brief Set when normal process termination is requested.
 */
static volatile sig_atomic_t stop_requested;

/**
 * @brief Handle a normal termination signal.
 *
 * @param signal_number Delivered signal number.
 */
static void handle_signal(int signal_number) {
  (void) signal_number;
  stop_requested = 1;
}

/**
 * @brief Test one bit in a Linux input capability bitmap.
 *
 * @param bit Capability bit.
 * @param bits Capability bitmap.
 * @return True when the bit is set.
 */
static bool test_bit(int bit, const unsigned long *bits) {
  return (bits[bit / (8 * sizeof(unsigned long))] >>
          (bit % (8 * sizeof(unsigned long)))) &
         1UL;
}

/**
 * @brief Return monotonic time in milliseconds.
 *
 * @return Monotonic millisecond timestamp.
 */
static int64_t monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t) now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/**
 * @brief Convert an evdev timestamp to milliseconds.
 *
 * @param event Input event.
 * @return Event timestamp in milliseconds.
 */
static uint32_t event_time_ms(const struct input_event *event) {
  return (uint32_t) (event->input_event_sec * 1000ULL +
                     event->input_event_usec / 1000ULL);
}

/**
 * @brief Atomically publish the exact session identifier.
 *
 * @return Zero on success, otherwise negative one.
 */
static int publish_ready(void) {
  char temporary[sizeof(bridge.ready_path) + 32];
  int length = snprintf(temporary, sizeof(temporary), "%s.tmp.%ld", bridge.ready_path, (long) getpid());
  if (length < 0 || (size_t) length >= sizeof(temporary)) {
    return -1;
  }
  mode_t old_umask = umask(0077);
  int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  umask(old_umask);
  if (fd < 0) {
    return -1;
  }
  size_t session_length = strlen(bridge.session_id);
  bool success = write(fd, bridge.session_id, session_length) == (ssize_t) session_length &&
                 write(fd, "\n", 1) == 1 && fsync(fd) == 0;
  int saved_errno = success ? 0 : errno;
  close(fd);
  if (success && rename(temporary, bridge.ready_path) < 0) {
    saved_errno = errno;
    success = false;
  }
  if (!success) {
    unlink(temporary);
    errno = saved_errno;
    return -1;
  }
  return 0;
}

/**
 * @brief Return whether the committed override belongs to this exact session.
 *
 * @return True only for a strict matching wlroots override.
 */
static bool matching_override(void) {
  char line[512] = {0};
  char expected[256];
  FILE *file = fopen(bridge.override_path, "re");
  if (file == NULL) {
    return false;
  }
  bool read_ok = fgets(line, sizeof(line), file) != NULL;
  bool eof_ok = fgetc(file) == EOF;
  fclose(file);
  if (!read_ok || !eof_ok) {
    return false;
  }
  size_t length = strlen(line);
  if (length == 0 || line[length - 1] != '\n') {
    return false;
  }
  line[length - 1] = '\0';
  if (strchr(line, '\r') != NULL) {
    return false;
  }
  snprintf(expected, sizeof(expected), "wlroots:%s", bridge.session_id);
  return strcmp(line, expected) == 0;
}

/**
 * @brief Apply or release exclusive evdev grabs.
 *
 * @param active Whether matching headless capture is active.
 * @return Zero when all requested grabs succeeded.
 */
static int set_active(bool active) {
  int result = 0;
  if (bridge.active == active) {
    return 0;
  }
  for (int index = 0; index < MAX_EVDEV; ++index) {
    if (bridge.sources[index].fd >= 0 &&
        ioctl(bridge.sources[index].fd, EVIOCGRAB, active ? 1 : 0) < 0) {
      fprintf(stderr, LOG_PREFIX "EVIOCGRAB failed for event%d: %s\n", index, strerror(errno));
      result = -1;
    }
  }
  if (active && result < 0) {
    for (int index = 0; index < MAX_EVDEV; ++index) {
      if (bridge.sources[index].fd >= 0) {
        ioctl(bridge.sources[index].fd, EVIOCGRAB, 0);
      }
    }
  }
  bridge.active = active && result == 0;
  fprintf(
    stderr,
    LOG_PREFIX "%s evdev forwarding for session %s\n",
    bridge.active ? "activated" : "deactivated",
    bridge.session_id
  );
  return result;
}

/**
 * @brief Close one evdev source and release its grab.
 *
 * @param source Source to close.
 */
static void close_source(struct source *source) {
  if (source->fd >= 0) {
    ioctl(source->fd, EVIOCGRAB, 0);
    close(source->fd);
    source->fd = -1;
  }
}

/**
 * @brief Open an evdev device only when it is a Prism mouse or keyboard.
 *
 * @param index evdev minor number.
 */
static void open_source(int index) {
  char path[64];
  char name[256] = {0};
  struct input_id identity = {0};
  unsigned long key_bits[(KEY_MAX + 8 * sizeof(unsigned long)) / (8 * sizeof(unsigned long))] = {0};
  unsigned long rel_bits[(REL_MAX + 8 * sizeof(unsigned long)) / (8 * sizeof(unsigned long))] = {0};
  unsigned long abs_bits[(ABS_MAX + 8 * sizeof(unsigned long)) / (8 * sizeof(unsigned long))] = {0};
  struct source *source = &bridge.sources[index];

  if (source->fd >= 0) {
    return;
  }
  snprintf(path, sizeof(path), "/dev/input/event%d", index);
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    return;
  }
  if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0 ||
      ioctl(fd, EVIOCGID, &identity) < 0 ||
      (strncmp(name, "Keyboard passthrough", 20) != 0 &&
       strncmp(name, "Mouse passthrough", 17) != 0) ||
      identity.vendor != 0xBEEF || identity.product != 0xDEAD ||
      identity.version != 0x0111) {
    close(fd);
    return;
  }
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
  source->fd = fd;
  source->keyboard = keyboard;
  source->pointer = pointer;
  if (pointer && test_bit(ABS_X, abs_bits) && test_bit(ABS_Y, abs_bits)) {
    ioctl(fd, EVIOCGABS(ABS_X), &source->abs_x);
    ioctl(fd, EVIOCGABS(ABS_Y), &source->abs_y);
  }
  if (bridge.active && ioctl(fd, EVIOCGRAB, 1) < 0) {
    fprintf(stderr, LOG_PREFIX "could not grab %s: %s\n", path, strerror(errno));
    close_source(source);
    return;
  }
  fprintf(
    stderr,
    LOG_PREFIX "opened %s (%s)%s%s\n",
    path,
    name,
    keyboard ? " keyboard" : "",
    pointer ? " pointer" : ""
  );
}

/**
 * @brief Rescan Prism-owned keyboard and mouse sources.
 */
static void rescan_sources(void) {
  for (int index = 0; index < MAX_EVDEV; ++index) {
    struct source *source = &bridge.sources[index];
    if (source->fd >= 0) {
      char unused;
      if (ioctl(source->fd, EVIOCGNAME(0), &unused) < 0 && errno == ENODEV) {
        close_source(source);
      }
    }
    open_source(index);
  }
}

/**
 * @brief Clear partially accumulated input frame state.
 */
static void clear_frame(void) {
  bridge.dx = 0;
  bridge.dy = 0;
  bridge.have_abs_x = false;
  bridge.have_abs_y = false;
  bridge.wheel_x = 0;
  bridge.wheel_y = 0;
  bridge.wheel_hi_x = 0;
  bridge.wheel_hi_y = 0;
  bridge.have_wheel_hi_x = false;
  bridge.have_wheel_hi_y = false;
  bridge.pointer_emitted = false;
}

/**
 * @brief Clamp an absolute coordinate into its advertised evdev range.
 *
 * @param value Raw evdev coordinate.
 * @param range Advertised evdev absolute range.
 * @return Coordinate relative to the minimum.
 */
static uint32_t clamp_absolute(int32_t value, const struct input_absinfo *range) {
  if (value <= range->minimum) {
    return 0;
  }
  if (value >= range->maximum) {
    return (uint32_t) (range->maximum - range->minimum);
  }
  return (uint32_t) (value - range->minimum);
}

/**
 * @brief Emit one pointer scroll axis without duplicating high-resolution data.
 *
 * @param time_ms Frame timestamp.
 * @param axis Wayland pointer axis.
 * @param low_steps Low-resolution wheel steps.
 * @param high_units High-resolution wheel units.
 * @param have_high Whether high-resolution units were reported.
 */
static void emit_scroll(
  uint32_t time_ms,
  uint32_t axis,
  int32_t low_steps,
  int32_t high_units,
  bool have_high
) {
  if (have_high && high_units != 0) {
    double value = -(double) high_units / 12.0;
    if (low_steps != 0) {
      zwlr_virtual_pointer_v1_axis_discrete(
        bridge.pointer,
        time_ms,
        axis,
        wl_fixed_from_double(value),
        -low_steps
      );
    } else {
      zwlr_virtual_pointer_v1_axis(
        bridge.pointer,
        time_ms,
        axis,
        wl_fixed_from_double(value)
      );
    }
    bridge.pointer_emitted = true;
  } else if (low_steps != 0) {
    zwlr_virtual_pointer_v1_axis_discrete(
      bridge.pointer,
      time_ms,
      axis,
      wl_fixed_from_double(-10.0 * low_steps),
      -low_steps
    );
    bridge.pointer_emitted = true;
  }
}

/**
 * @brief Flush accumulated events as one Wayland input frame.
 *
 * @param time_ms Frame timestamp.
 */
static void flush_frame(uint32_t time_ms) {
  if (!bridge.active || bridge.pointer == NULL || bridge.keyboard == NULL) {
    clear_frame();
    return;
  }
  if (bridge.dx != 0 || bridge.dy != 0) {
    zwlr_virtual_pointer_v1_motion(
      bridge.pointer,
      time_ms,
      wl_fixed_from_double(bridge.dx),
      wl_fixed_from_double(bridge.dy)
    );
    bridge.pointer_emitted = true;
  }
  if ((bridge.have_abs_x || bridge.have_abs_y) &&
      bridge.abs_width > 0 && bridge.abs_height > 0) {
    zwlr_virtual_pointer_v1_motion_absolute(
      bridge.pointer,
      time_ms,
      (uint32_t) bridge.abs_x,
      (uint32_t) bridge.abs_y,
      bridge.abs_width,
      bridge.abs_height
    );
    bridge.pointer_emitted = true;
  }
  if (bridge.wheel_x != 0 || bridge.wheel_y != 0 ||
      bridge.wheel_hi_x != 0 || bridge.wheel_hi_y != 0) {
    zwlr_virtual_pointer_v1_axis_source(
      bridge.pointer,
      WL_POINTER_AXIS_SOURCE_WHEEL
    );
  }
  emit_scroll(
    time_ms,
    WL_POINTER_AXIS_HORIZONTAL_SCROLL,
    bridge.wheel_x,
    bridge.wheel_hi_x,
    bridge.have_wheel_hi_x
  );
  emit_scroll(
    time_ms,
    WL_POINTER_AXIS_VERTICAL_SCROLL,
    bridge.wheel_y,
    bridge.wheel_hi_y,
    bridge.have_wheel_hi_y
  );
  if (bridge.pointer_emitted) {
    zwlr_virtual_pointer_v1_frame(bridge.pointer);
  }
  wl_display_flush(bridge.display);
  clear_frame();
}

/**
 * @brief Forward one active evdev event to labwc.
 *
 * @param source Event source.
 * @param event Linux input event.
 */
static void forward_event(const struct source *source, const struct input_event *event) {
  if (!bridge.active || bridge.pointer == NULL || bridge.keyboard == NULL) {
    return;
  }
  uint32_t time_ms = event_time_ms(event);
  switch (event->type) {
    case EV_KEY:
      if (source->pointer && event->code >= BTN_MOUSE &&
          event->code < BTN_JOYSTICK && event->value <= 1) {
        zwlr_virtual_pointer_v1_button(
          bridge.pointer,
          time_ms,
          event->code,
          event->value ? WL_POINTER_BUTTON_STATE_PRESSED :
                         WL_POINTER_BUTTON_STATE_RELEASED
        );
        bridge.pointer_emitted = true;
      } else if (source->keyboard && event->code < BTN_MISC &&
                 event->value <= 2) {
        zwp_virtual_keyboard_v1_key(
          bridge.keyboard,
          time_ms,
          event->code,
          event->value ? WL_KEYBOARD_KEY_STATE_PRESSED :
                         WL_KEYBOARD_KEY_STATE_RELEASED
        );
      }
      break;
    case EV_REL:
      switch (event->code) {
        case REL_X:
          bridge.dx += event->value;
          break;
        case REL_Y:
          bridge.dy += event->value;
          break;
        case REL_WHEEL:
          bridge.wheel_y += event->value;
          break;
        case REL_HWHEEL:
          bridge.wheel_x += event->value;
          break;
        case REL_WHEEL_HI_RES:
          bridge.wheel_hi_y += event->value;
          bridge.have_wheel_hi_y = true;
          break;
        case REL_HWHEEL_HI_RES:
          bridge.wheel_hi_x += event->value;
          bridge.have_wheel_hi_x = true;
          break;
        default:
          break;
      }
      break;
    case EV_ABS:
      if (event->code == ABS_X && source->abs_x.maximum > source->abs_x.minimum) {
        bridge.abs_x = (int32_t) clamp_absolute(event->value, &source->abs_x);
        bridge.abs_width = (uint32_t) (source->abs_x.maximum - source->abs_x.minimum);
        bridge.have_abs_x = true;
      } else if (event->code == ABS_Y && source->abs_y.maximum > source->abs_y.minimum) {
        bridge.abs_y = (int32_t) clamp_absolute(event->value, &source->abs_y);
        bridge.abs_height = (uint32_t) (source->abs_y.maximum - source->abs_y.minimum);
        bridge.have_abs_y = true;
      }
      break;
    case EV_SYN:
      if (event->code == SYN_DROPPED) {
        clear_frame();
      } else if (event->code == SYN_REPORT) {
        flush_frame(time_ms);
      }
      break;
    default:
      break;
  }
}

/**
 * @brief Drain pending events from one evdev source.
 *
 * @param source Source to drain.
 */
static void drain_source(struct source *source) {
  while (source->fd >= 0) {
    struct input_event event;
    ssize_t size = read(source->fd, &event, sizeof(event));
    if (size == (ssize_t) sizeof(event)) {
      forward_event(source, &event);
    } else if (size < 0 && errno == EINTR) {
      continue;
    } else if (size < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      break;
    } else if (size < 0 && errno == ENODEV) {
      close_source(source);
      break;
    } else {
      break;
    }
  }
}

/**
 * @brief Bind required wlroots virtual-input globals.
 *
 * @param data Unused callback data.
 * @param registry Wayland registry.
 * @param name Numeric global name.
 * @param interface Global interface name.
 * @param version Advertised interface version.
 */
static void registry_global(
  void *data,
  struct wl_registry *registry,
  uint32_t name,
  const char *interface,
  uint32_t version
) {
  (void) data;
  if (strcmp(interface, wl_seat_interface.name) == 0 && bridge.seat == NULL) {
    bridge.seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 1 ? version : 1);
  } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0 &&
             bridge.pointer_manager == NULL && version >= 2) {
    bridge.pointer_manager = wl_registry_bind(
      registry,
      name,
      &zwlr_virtual_pointer_manager_v1_interface,
      version < 2 ? version : 2
    );
  } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0 &&
             bridge.keyboard_manager == NULL) {
    bridge.keyboard_manager = wl_registry_bind(
      registry,
      name,
      &zwp_virtual_keyboard_manager_v1_interface,
      1
    );
  }
}

/**
 * @brief Ignore removal of compositor globals during teardown.
 *
 * @param data Unused callback data.
 * @param registry Wayland registry.
 * @param name Numeric global name.
 */
static void registry_global_remove(
  void *data,
  struct wl_registry *registry,
  uint32_t name
) {
  (void) data;
  (void) registry;
  (void) name;
}

/**
 * @brief Registry callback table.
 */
static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
  .global_remove = registry_global_remove,
};

/**
 * @brief Install the default XKB keymap on the virtual keyboard.
 *
 * @return Zero on success, otherwise negative one.
 */
static int send_keymap(void) {
  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (context == NULL) {
    return -1;
  }
  struct xkb_keymap *keymap = xkb_keymap_new_from_names(
    context,
    NULL,
    XKB_KEYMAP_COMPILE_NO_FLAGS
  );
  if (keymap == NULL) {
    xkb_context_unref(context);
    return -1;
  }
  char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  if (text == NULL) {
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return -1;
  }
  size_t size = strlen(text) + 1;
  int fd = memfd_create("prism-keymap", MFD_CLOEXEC);
  bool success = fd >= 0 && ftruncate(fd, (off_t) size) == 0 &&
                 write(fd, text, size) == (ssize_t) size;
  if (success) {
    lseek(fd, 0, SEEK_SET);
    zwp_virtual_keyboard_v1_keymap(
      bridge.keyboard,
      WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
      fd,
      (uint32_t) size
    );
  }
  if (fd >= 0) {
    close(fd);
  }
  free(text);
  xkb_keymap_unref(keymap);
  xkb_context_unref(context);
  return success ? 0 : -1;
}

/**
 * @brief Tear down one private Wayland connection.
 */
static void disconnect_wayland(void) {
  unlink(bridge.ready_path);
  set_active(false);
  clear_frame();
  if (bridge.pointer != NULL) {
    zwlr_virtual_pointer_v1_destroy(bridge.pointer);
  }
  if (bridge.keyboard != NULL) {
    zwp_virtual_keyboard_v1_destroy(bridge.keyboard);
  }
  if (bridge.pointer_manager != NULL) {
    zwlr_virtual_pointer_manager_v1_destroy(bridge.pointer_manager);
  }
  if (bridge.keyboard_manager != NULL) {
    zwp_virtual_keyboard_manager_v1_destroy(bridge.keyboard_manager);
  }
  if (bridge.seat != NULL) {
    wl_seat_destroy(bridge.seat);
  }
  if (bridge.registry != NULL) {
    wl_registry_destroy(bridge.registry);
  }
  if (bridge.display != NULL) {
    wl_display_disconnect(bridge.display);
  }
  bridge.pointer = NULL;
  bridge.keyboard = NULL;
  bridge.pointer_manager = NULL;
  bridge.keyboard_manager = NULL;
  bridge.seat = NULL;
  bridge.registry = NULL;
  bridge.display = NULL;
}

/**
 * @brief Connect virtual devices to the exact session-owned labwc socket.
 *
 * @return Zero on success, otherwise negative one.
 */
static int connect_wayland(void) {
  bridge.display = wl_display_connect(bridge.wayland_socket);
  if (bridge.display == NULL) {
    return -1;
  }
  bridge.registry = wl_display_get_registry(bridge.display);
  if (bridge.registry == NULL) {
    disconnect_wayland();
    return -1;
  }
  wl_registry_add_listener(bridge.registry, &registry_listener, NULL);
  if (wl_display_roundtrip(bridge.display) < 0 ||
      bridge.seat == NULL || bridge.pointer_manager == NULL ||
      bridge.keyboard_manager == NULL) {
    disconnect_wayland();
    return -1;
  }
  bridge.pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
    bridge.pointer_manager,
    bridge.seat
  );
  bridge.keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(
    bridge.keyboard_manager,
    bridge.seat
  );
  if (bridge.pointer == NULL || bridge.keyboard == NULL || send_keymap() < 0 ||
      wl_display_roundtrip(bridge.display) < 0 || publish_ready() < 0) {
    disconnect_wayland();
    return -1;
  }
  fprintf(
    stderr,
    LOG_PREFIX "Wayland virtual input ready for session %s on %s\n",
    bridge.session_id,
    bridge.wayland_socket
  );
  return 0;
}

/**
 * @brief Run one connection to the exact owned labwc socket.
 *
 * @return Zero on requested shutdown, otherwise negative one on disconnect.
 */
static int run_connection(void) {
  if (connect_wayland() < 0) {
    return -1;
  }
  rescan_sources();
  int64_t next_device_scan = monotonic_ms() + DEVICE_RESCAN_INTERVAL_MS;
  int result = -1;
  while (!stop_requested) {
    struct pollfd descriptors[MAX_POLL_FDS];
    struct source *source_map[MAX_POLL_FDS] = {0};
    int descriptor_count = 1;
    descriptors[0] = (struct pollfd) {
      .fd = wl_display_get_fd(bridge.display),
      .events = POLLIN,
    };
    for (int index = 0; index < MAX_EVDEV; ++index) {
      if (bridge.sources[index].fd >= 0) {
        source_map[descriptor_count] = &bridge.sources[index];
        descriptors[descriptor_count++] = (struct pollfd) {
          .fd = bridge.sources[index].fd,
          .events = POLLIN,
        };
      }
    }
    int poll_result = poll(
      descriptors,
      (nfds_t) descriptor_count,
      ACTIVATION_INTERVAL_MS
    );
    if (poll_result < 0 && errno != EINTR) {
      break;
    }
    if ((descriptors[0].revents & (POLLHUP | POLLERR)) != 0) {
      break;
    }
    if ((descriptors[0].revents & POLLIN) != 0 &&
        wl_display_dispatch(bridge.display) < 0) {
      break;
    }
    bool should_activate = matching_override();
    if (should_activate != bridge.active && set_active(should_activate) < 0) {
      break;
    }
    for (int index = 1; index < descriptor_count; ++index) {
      if ((descriptors[index].revents & POLLIN) != 0) {
        drain_source(source_map[index]);
      }
    }
    if (monotonic_ms() >= next_device_scan) {
      rescan_sources();
      next_device_scan = monotonic_ms() + DEVICE_RESCAN_INTERVAL_MS;
    }
  }
  if (stop_requested) {
    result = 0;
  }
  disconnect_wayland();
  return result;
}

/**
 * @brief Validate and copy one required environment variable.
 *
 * @param name Environment variable name.
 * @param destination Destination buffer.
 * @param size Destination buffer size.
 * @return Zero on success, otherwise negative one.
 */
static int require_environment(
  const char *name,
  char *destination,
  size_t size
) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0' || strlen(value) >= size) {
    fprintf(stderr, LOG_PREFIX "missing or invalid %s\n", name);
    return -1;
  }
  memcpy(destination, value, strlen(value) + 1);
  return 0;
}

/**
 * @brief Validate a Prism session identifier.
 *
 * @param value Session identifier.
 * @return True when the value is safe for state and unit names.
 */
static bool valid_session_id(const char *value) {
  for (const char *character = value; *character != '\0'; ++character) {
    if (!isalnum((unsigned char) *character) &&
        *character != '_' && *character != '.' && *character != '-') {
      return false;
    }
  }
  return value[0] != '\0';
}

/**
 * @brief Validate a labwc Wayland socket name.
 *
 * @param value Socket name.
 * @return True for `wayland-<number>` within the supported range.
 */
static bool valid_wayland_socket(const char *value) {
  if (strncmp(value, "wayland-", 8) != 0) {
    return false;
  }
  const char *digits = value + 8;
  if (*digits == '\0') {
    return false;
  }
  for (const char *character = digits; *character != '\0'; ++character) {
    if (!isdigit((unsigned char) *character)) {
      return false;
    }
  }
  errno = 0;
  char *end = NULL;
  unsigned long index = strtoul(digits, &end, 10);
  return errno == 0 && end != digits && *end == '\0' && index <= 127;
}

/**
 * @brief Program entry point.
 *
 * @param argc Argument count.
 * @param argv Argument vector.
 * @return Zero on normal termination, otherwise nonzero.
 */
int main(int argc, char **argv) {
  (void) argc;
  (void) argv;
  if (require_environment(
        "PRISM_SESSION_ID",
        bridge.session_id,
        sizeof(bridge.session_id)
      ) < 0 ||
      require_environment(
        "PRISM_WAYLAND_SOCKET",
        bridge.wayland_socket,
        sizeof(bridge.wayland_socket)
      ) < 0 ||
      require_environment(
        "PRISM_HEADLESS_INPUT_READY_FILE",
        bridge.ready_path,
        sizeof(bridge.ready_path)
      ) < 0 ||
      require_environment(
        "PRISM_CAPTURE_OVERRIDE_FILE",
        bridge.override_path,
        sizeof(bridge.override_path)
      ) < 0) {
    return 2;
  }
  if (!valid_session_id(bridge.session_id) ||
      !valid_wayland_socket(bridge.wayland_socket)) {
    fprintf(stderr, LOG_PREFIX "invalid session or Wayland socket identity\n");
    return 2;
  }
  for (int index = 0; index < MAX_EVDEV; ++index) {
    bridge.sources[index].fd = -1;
  }
  signal(SIGINT, handle_signal);
  signal(SIGTERM, handle_signal);
  unlink(bridge.ready_path);

  while (!stop_requested) {
    if (run_connection() == 0) {
      break;
    }
    if (!stop_requested) {
      struct timespec delay = {
        .tv_sec = 0,
        .tv_nsec = RECONNECT_DELAY_MS * 1000000L,
      };
      nanosleep(&delay, NULL);
    }
  }
  for (int index = 0; index < MAX_EVDEV; ++index) {
    close_source(&bridge.sources[index]);
  }
  disconnect_wayland();
  return 0;
}
