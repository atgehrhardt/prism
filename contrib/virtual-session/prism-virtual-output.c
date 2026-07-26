/**
 * @file prism-virtual-output.c
 * @brief Create a KWin virtual output at a requested size and keep it alive.
 *
 * Uses zkde_screencast_unstable_v1.stream_virtual_output_with_description
 * (falling back to stream_virtual_output on compositors advertising < v4).
 * The virtual output exists while the returned stream is held open, so this
 * process simply parks in a dispatch loop until killed.
 *
 * Usage: prism-virtual-output <name> <width> <height>
 *
 * Connects to $WAYLAND_DISPLAY, defaulting to "wayland-0".
 */

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wayland-client.h>

#include "zkde-screencast-unstable-v1-client-protocol.h"

#define LOG_PREFIX "prism-virtual-output: "

/**
 * @brief Global client state.
 */
static struct {
  struct wl_display *display;
  struct zkde_screencast_unstable_v1 *screencast;
  struct zkde_screencast_stream_unstable_v1 *stream;
  uint32_t screencast_version; ///< bound version of zkde_screencast_unstable_v1
  volatile sig_atomic_t stop;  ///< set by SIGTERM/SIGINT handler
  bool closed;                 ///< server closed the stream
  bool failed;                 ///< server reported a stream error
} g;

static void on_signal(int sig) {
  (void) sig;
  g.stop = 1;
}

/* --------------------------------------------------------------------------
 * zkde_screencast_stream_unstable_v1
 * ------------------------------------------------------------------------ */

static void stream_closed(void *data, struct zkde_screencast_stream_unstable_v1 *stream) {
  (void) data; (void) stream;
  fprintf(stderr, LOG_PREFIX "stream closed by compositor\n");
  g.closed = true;
}

static void stream_created(void *data, struct zkde_screencast_stream_unstable_v1 *stream,
                           uint32_t node) {
  (void) data; (void) stream;
  fprintf(stderr, LOG_PREFIX "pipewire node: %u\n", node);
}

static void stream_failed(void *data, struct zkde_screencast_stream_unstable_v1 *stream,
                          const char *error) {
  (void) data; (void) stream;
  fprintf(stderr, LOG_PREFIX "stream failed: %s\n", error ? error : "(no message)");
  g.failed = true;
}

static void stream_serial(void *data, struct zkde_screencast_stream_unstable_v1 *stream,
                          uint32_t hi, uint32_t low) {
  (void) data; (void) stream;
  fprintf(stderr, LOG_PREFIX "pipewire object serial: %llu\n",
          (unsigned long long) ((uint64_t) hi << 32 | low));
}

static const struct zkde_screencast_stream_unstable_v1_listener stream_listener = {
  .closed = stream_closed,
  .created = stream_created,
  .failed = stream_failed,
  .serial = stream_serial,
};

/* --------------------------------------------------------------------------
 * wl_registry
 * ------------------------------------------------------------------------ */

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
  (void) data;
  if (strcmp(interface, zkde_screencast_unstable_v1_interface.name) == 0) {
    g.screencast_version = version < 6 ? version : 6;
    g.screencast = wl_registry_bind(registry, name,
                                    &zkde_screencast_unstable_v1_interface,
                                    g.screencast_version);
  }
}

static void registry_global_remove(void *data, struct wl_registry *registry,
                                   uint32_t name) {
  (void) data; (void) registry; (void) name;
}

static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
  .global_remove = registry_global_remove,
};

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: prism-virtual-output <name> <width> <height>\n");
    return 2;
  }
  const char *output_name = argv[1];
  int width = atoi(argv[2]);
  int height = atoi(argv[3]);
  if (width <= 0 || height <= 0) {
    fprintf(stderr, LOG_PREFIX "invalid size %sx%s\n", argv[2], argv[3]);
    return 2;
  }

  const char *socket = getenv("WAYLAND_DISPLAY");
  if (!socket || !*socket) {
    socket = "wayland-0";
  }
  g.display = wl_display_connect(socket);
  if (!g.display) {
    fprintf(stderr, LOG_PREFIX "cannot connect to wayland display '%s'\n", socket);
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(g.display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(g.display);
  wl_registry_destroy(registry);
  if (!g.screencast) {
    fprintf(stderr, LOG_PREFIX "compositor lacks zkde_screencast_unstable_v1\n");
    return 1;
  }
  if (g.screencast_version < 2) {
    fprintf(stderr, LOG_PREFIX "zkde_screencast_unstable_v1 v%u has no virtual output support\n",
            g.screencast_version);
    return 1;
  }

  if (g.screencast_version >= 4) {
    g.stream = zkde_screencast_unstable_v1_stream_virtual_output_with_description(
      g.screencast, output_name, "Prism virtual display", width, height,
      wl_fixed_from_int(1), 0);
  } else {
    g.stream = zkde_screencast_unstable_v1_stream_virtual_output(
      g.screencast, output_name, width, height, wl_fixed_from_int(1), 0);
  }
  zkde_screencast_stream_unstable_v1_add_listener(g.stream, &stream_listener, NULL);
  wl_display_flush(g.display);
  fprintf(stderr, LOG_PREFIX "requested virtual output '%s' %dx%d (protocol v%u)\n",
          output_name, width, height, g.screencast_version);

  struct sigaction sa = { .sa_handler = on_signal };
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);

  /* Hold the stream open: the virtual output lives while the stream does. */
  while (!g.stop && !g.closed && !g.failed) {
    if (wl_display_dispatch(g.display) < 0) {
      if (g.stop) {
        break; /* dispatch interrupted by our own signal handler */
      }
      fprintf(stderr, LOG_PREFIX "wayland dispatch failed\n");
      return 1;
    }
  }

  if (g.closed || g.failed) {
    return 1;
  }
  zkde_screencast_stream_unstable_v1_close(g.stream);
  wl_display_roundtrip(g.display); /* let the compositor process the close */
  wl_display_disconnect(g.display);
  fprintf(stderr, LOG_PREFIX "stream closed, virtual output removed\n");
  return 0;
}
