/**
 * @file tests/integration/hdr_keyboard.c
 * @brief Inject calibration keys into an isolated test compositor through its virtual keyboard protocol.
 */
#include "virtual-keyboard-unstable-v1.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

static struct wl_seat *seat;  ///< Test compositor's keyboard seat.
static struct zwp_virtual_keyboard_manager_v1 *manager;  ///< Virtual keyboard factory.

/**
 * @brief Bind test input interfaces.
 *
 * @param data Unused data.
 * @param registry Global registry.
 * @param name Global ID.
 * @param interface Protocol name.
 * @param version Unused advertised version.
 */
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  if (!strcmp(interface, "wl_seat") && !seat) {
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
  } else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1")) {
    manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
  }
}

/**
 * @brief Ignore removal in the short-lived test client.
 *
 * @param data Unused data.
 * @param registry Unused registry.
 * @param name Removed ID.
 */
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}

/**
 * @brief Send each supplied evdev key as a press and release.
 *
 * @param argc Argument count.
 * @param argv Key numbers.
 * @return Zero on successful protocol delivery.
 */
int main(int argc, char **argv) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  const struct wl_registry_listener listener = {global, removed};
  wl_registry_add_listener(registry, &listener, NULL);
  if (wl_display_roundtrip(display) < 0 || !seat || !manager) {
    return 2;
  }
  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
  char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t length = strlen(text) + 1;
  int fd = memfd_create("test-keymap", MFD_CLOEXEC);
  if (fd < 0 || write(fd, text, length) != (ssize_t) length) {
    return 3;
  }
  struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
  zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, length);
  close(fd);
  free(text);
  xkb_keymap_unref(keymap);
  xkb_context_unref(context);
  wl_display_roundtrip(display);
  // Allow the application to bind wl_keyboard after the seat gains capability.
  usleep(300000);
  for (int i = 1; i < argc; ++i) {
    uint32_t key = strtoul(argv[i], NULL, 10);
    zwp_virtual_keyboard_v1_key(keyboard, 0, key, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_key(keyboard, 1, key, WL_KEYBOARD_KEY_STATE_RELEASED);
    wl_display_roundtrip(display);
    usleep(200000);
  }
  zwp_virtual_keyboard_v1_destroy(keyboard);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
