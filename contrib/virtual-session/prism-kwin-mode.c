/**
 * @file prism-kwin-mode.c
 * @brief Configure KWin outputs at runtime via kde-output-management-v2.
 *
 * Replaces kscreen-doctor for Prism's session scripts and adds custom-mode
 * support (kde_output_configuration_v2.set_custom_modes, since v18) so
 * arbitrary client resolutions can be set instead of only EDID modes.
 *
 * Commands:
 *   prism-kwin-mode list
 *   prism-kwin-mode current <output-name>
 *   prism-kwin-mode apply <output-name> <W>x<H>@<refresh> [hdr=enable|disable] [wcg=enable|disable]
 *
 * Refresh is in Hz when < 1000 (matched with ±50 mHz tolerance against the
 * advertised mHz rates), otherwise exact mHz.
 *
 * Connects to $WAYLAND_DISPLAY, defaulting to "wayland-0".
 */

#define _GNU_SOURCE
#include "kde-output-device-v2-client-protocol.h"
#include "kde-output-management-v2-client-protocol.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#define LOG_PREFIX "prism-kwin-mode: "

/** @brief Bind version for kde_output_device_registry_v2 (>= 21 required). */
#define DEVICE_REGISTRY_VERSION 21
/** @brief Bind version for kde_output_management_v2 (>= 18 for set_custom_modes). */
#define MANAGEMENT_VERSION 21

/**
 * @brief One advertised mode of an output device.
 */
struct mode {
  struct kde_output_device_mode_v2 *proxy;  ///< mode object, NULL once removed
  int32_t width;  ///< mode width in hardware units
  int32_t height;  ///< mode height in hardware units
  int32_t refresh;  ///< vertical refresh rate in mHz
  uint32_t flags;  ///< kde_output_device_mode_v2.flags bitmask
  bool preferred;  ///< mode was advertised as preferred
};

/**
 * @brief One output device announced by kde_output_device_registry_v2.
 */
struct device {
  struct kde_output_device_v2 *proxy;
  char name[64];
  char make[128];
  char model[128];
  uint32_t capabilities;
  int hdr;  ///< 1 enabled, 0 disabled, -1 not yet known
  int wcg;  ///< 1 enabled, 0 disabled, -1 not yet known
  bool enabled;
  bool done;  ///< initial batch of events fully received
  bool removed;
  struct mode **modes;  ///< individually heap-allocated (stable listener data)
  size_t nmodes;
  struct mode *current;  ///< points to one of modes[], NULL if unknown/removed
};

/**
 * @brief Global client state.
 */
static struct {
  struct wl_display *display;
  struct kde_output_management_v2 *management;
  struct kde_output_device_registry_v2 *device_registry;

  struct device *devices;
  size_t ndevices;

  /* per-configuration apply result */
  int apply_result;  ///< 0 pending, 1 applied, -1 failed
  char failure_reason[256];
} g;

/* --------------------------------------------------------------------------
 * kde_output_device_mode_v2
 * ------------------------------------------------------------------------ */

static void mode_size(void *data, struct kde_output_device_mode_v2 *proxy, int32_t width, int32_t height) {
  (void) proxy;
  struct mode *m = data;
  m->width = width;
  m->height = height;
}

static void mode_refresh(void *data, struct kde_output_device_mode_v2 *proxy, int32_t refresh) {
  (void) proxy;
  ((struct mode *) data)->refresh = refresh;
}

static void mode_preferred(void *data, struct kde_output_device_mode_v2 *proxy) {
  (void) proxy;
  ((struct mode *) data)->preferred = true;
}

static void mode_removed(void *data, struct kde_output_device_mode_v2 *proxy) {
  struct mode *m = data;
  m->proxy = NULL; /* server destroys the object right after this event */
  kde_output_device_mode_v2_destroy(proxy);
  /* device.current is repaired in device_done() via the current_mode event */
}

static void mode_flags(void *data, struct kde_output_device_mode_v2 *proxy, uint32_t flags) {
  (void) proxy;
  ((struct mode *) data)->flags = flags;
}

static const struct kde_output_device_mode_v2_listener mode_listener = {
  .size = mode_size,
  .refresh = mode_refresh,
  .preferred = mode_preferred,
  .removed = mode_removed,
  .flags = mode_flags,
};

/* --------------------------------------------------------------------------
 * kde_output_device_v2
 * ------------------------------------------------------------------------ */

static struct mode *device_find_proxy(struct device *d, struct kde_output_device_mode_v2 *proxy) {
  for (size_t i = 0; i < d->nmodes; i++) {
    if (d->modes[i]->proxy == proxy) {
      return d->modes[i];
    }
  }
  return NULL;
}

static void device_geometry(void *data, struct kde_output_device_v2 *proxy, int32_t x, int32_t y, int32_t physical_width, int32_t physical_height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
  (void) proxy;
  (void) x;
  (void) y;
  (void) physical_width;
  (void) physical_height;
  (void) subpixel;
  (void) transform;
  struct device *d = data;
  snprintf(d->make, sizeof(d->make), "%s", make ? make : "");
  snprintf(d->model, sizeof(d->model), "%s", model ? model : "");
}

static void device_current_mode(void *data, struct kde_output_device_v2 *proxy, struct kde_output_device_mode_v2 *mode) {
  (void) proxy;
  struct device *d = data;
  d->current = device_find_proxy(d, mode);
}

static void device_mode(void *data, struct kde_output_device_v2 *proxy, struct kde_output_device_mode_v2 *mode) {
  (void) proxy;
  struct device *d = data;
  d->modes = realloc(d->modes, (d->nmodes + 1) * sizeof(*d->modes));
  struct mode *m = calloc(1, sizeof(*m));
  m->proxy = mode;
  d->modes[d->nmodes++] = m;
  kde_output_device_mode_v2_add_listener(mode, &mode_listener, m);
}

static void device_done(void *data, struct kde_output_device_v2 *proxy) {
  (void) proxy;
  struct device *d = data;
  d->done = true;
  /* drop stale current pointer if its mode was removed */
  if (d->current && d->current->proxy == NULL) {
    d->current = NULL;
  }
}

static void device_scale(void *data, struct kde_output_device_v2 *proxy, wl_fixed_t factor) {
  (void) data;
  (void) proxy;
  (void) factor;
}

static void device_edid(void *data, struct kde_output_device_v2 *proxy, const char *raw) {
  (void) data;
  (void) proxy;
  (void) raw;
}

static void device_enabled(void *data, struct kde_output_device_v2 *proxy, int32_t enabled) {
  (void) proxy;
  ((struct device *) data)->enabled = enabled != 0;
}

static void device_uuid(void *data, struct kde_output_device_v2 *proxy, const char *uuid) {
  (void) data;
  (void) proxy;
  (void) uuid;
}

static void device_serial_number(void *data, struct kde_output_device_v2 *proxy, const char *serial) {
  (void) data;
  (void) proxy;
  (void) serial;
}

static void device_eisa_id(void *data, struct kde_output_device_v2 *proxy, const char *eisa) {
  (void) data;
  (void) proxy;
  (void) eisa;
}

static void device_capabilities(void *data, struct kde_output_device_v2 *proxy, uint32_t flags) {
  (void) proxy;
  ((struct device *) data)->capabilities = flags;
}

static void device_overscan(void *data, struct kde_output_device_v2 *proxy, uint32_t overscan) {
  (void) data;
  (void) proxy;
  (void) overscan;
}

static void device_vrr_policy(void *data, struct kde_output_device_v2 *proxy, uint32_t policy) {
  (void) data;
  (void) proxy;
  (void) policy;
}

static void device_rgb_range(void *data, struct kde_output_device_v2 *proxy, uint32_t range) {
  (void) data;
  (void) proxy;
  (void) range;
}

static void device_name(void *data, struct kde_output_device_v2 *proxy, const char *name) {
  (void) proxy;
  struct device *d = data;
  snprintf(d->name, sizeof(d->name), "%s", name ? name : "");
}

static void device_hdr(void *data, struct kde_output_device_v2 *proxy, uint32_t hdr_enabled) {
  (void) proxy;
  ((struct device *) data)->hdr = hdr_enabled ? 1 : 0;
}

static void device_sdr_brightness(void *data, struct kde_output_device_v2 *proxy, uint32_t sdr_brightness) {
  (void) data;
  (void) proxy;
  (void) sdr_brightness;
}

static void device_wcg(void *data, struct kde_output_device_v2 *proxy, uint32_t wcg_enabled) {
  (void) proxy;
  ((struct device *) data)->wcg = wcg_enabled ? 1 : 0;
}

static void device_auto_rotate_policy(void *data, struct kde_output_device_v2 *proxy, uint32_t policy) {
  (void) data;
  (void) proxy;
  (void) policy;
}

static void device_icc_profile_path(void *data, struct kde_output_device_v2 *proxy, const char *path) {
  (void) data;
  (void) proxy;
  (void) path;
}

static void device_brightness_metadata(void *data, struct kde_output_device_v2 *proxy, uint32_t peak, uint32_t avg, uint32_t min) {
  (void) data;
  (void) proxy;
  (void) peak;
  (void) avg;
  (void) min;
}

static void device_brightness_overrides(void *data, struct kde_output_device_v2 *proxy, int32_t peak, int32_t avg, int32_t min) {
  (void) data;
  (void) proxy;
  (void) peak;
  (void) avg;
  (void) min;
}

static void device_sdr_gamut_wideness(void *data, struct kde_output_device_v2 *proxy, uint32_t wideness) {
  (void) data;
  (void) proxy;
  (void) wideness;
}

static void device_color_profile_source(void *data, struct kde_output_device_v2 *proxy, uint32_t source) {
  (void) data;
  (void) proxy;
  (void) source;
}

static void device_brightness(void *data, struct kde_output_device_v2 *proxy, uint32_t brightness) {
  (void) data;
  (void) proxy;
  (void) brightness;
}

static void device_color_power_tradeoff(void *data, struct kde_output_device_v2 *proxy, uint32_t preference) {
  (void) data;
  (void) proxy;
  (void) preference;
}

static void device_dimming(void *data, struct kde_output_device_v2 *proxy, uint32_t multiplier) {
  (void) data;
  (void) proxy;
  (void) multiplier;
}

static void device_replication_source(void *data, struct kde_output_device_v2 *proxy, const char *source) {
  (void) data;
  (void) proxy;
  (void) source;
}

static void device_ddc_ci_allowed(void *data, struct kde_output_device_v2 *proxy, uint32_t allowed) {
  (void) data;
  (void) proxy;
  (void) allowed;
}

static void device_max_bpc(void *data, struct kde_output_device_v2 *proxy, uint32_t max_bpc) {
  (void) data;
  (void) proxy;
  (void) max_bpc;
}

static void device_max_bpc_range(void *data, struct kde_output_device_v2 *proxy, uint32_t min_value, uint32_t max_value) {
  (void) data;
  (void) proxy;
  (void) min_value;
  (void) max_value;
}

static void device_auto_max_bpc_limit(void *data, struct kde_output_device_v2 *proxy, uint32_t limit) {
  (void) data;
  (void) proxy;
  (void) limit;
}

static void device_edr_policy(void *data, struct kde_output_device_v2 *proxy, uint32_t policy) {
  (void) data;
  (void) proxy;
  (void) policy;
}

static void device_sharpness(void *data, struct kde_output_device_v2 *proxy, uint32_t sharpness) {
  (void) data;
  (void) proxy;
  (void) sharpness;
}

static void device_priority(void *data, struct kde_output_device_v2 *proxy, uint32_t priority) {
  (void) data;
  (void) proxy;
  (void) priority;
}

static void device_auto_brightness(void *data, struct kde_output_device_v2 *proxy, uint32_t enabled) {
  (void) data;
  (void) proxy;
  (void) enabled;
}

static void device_removed(void *data, struct kde_output_device_v2 *proxy) {
  (void) proxy;
  ((struct device *) data)->removed = true;
}

static void device_hdr_icc_profile_path(void *data, struct kde_output_device_v2 *proxy, const char *path) {
  (void) data;
  (void) proxy;
  (void) path;
}

static void device_hdr_color_profile_source(void *data, struct kde_output_device_v2 *proxy, uint32_t source) {
  (void) data;
  (void) proxy;
  (void) source;
}

static void device_abm_level(void *data, struct kde_output_device_v2 *proxy, uint32_t level) {
  (void) data;
  (void) proxy;
  (void) level;
}

static const struct kde_output_device_v2_listener device_listener = {
  .geometry = device_geometry,
  .current_mode = device_current_mode,
  .mode = device_mode,
  .done = device_done,
  .scale = device_scale,
  .edid = device_edid,
  .enabled = device_enabled,
  .uuid = device_uuid,
  .serial_number = device_serial_number,
  .eisa_id = device_eisa_id,
  .capabilities = device_capabilities,
  .overscan = device_overscan,
  .vrr_policy = device_vrr_policy,
  .rgb_range = device_rgb_range,
  .name = device_name,
  .high_dynamic_range = device_hdr,
  .sdr_brightness = device_sdr_brightness,
  .wide_color_gamut = device_wcg,
  .auto_rotate_policy = device_auto_rotate_policy,
  .icc_profile_path = device_icc_profile_path,
  .brightness_metadata = device_brightness_metadata,
  .brightness_overrides = device_brightness_overrides,
  .sdr_gamut_wideness = device_sdr_gamut_wideness,
  .color_profile_source = device_color_profile_source,
  .brightness = device_brightness,
  .color_power_tradeoff = device_color_power_tradeoff,
  .dimming = device_dimming,
  .replication_source = device_replication_source,
  .ddc_ci_allowed = device_ddc_ci_allowed,
  .max_bits_per_color = device_max_bpc,
  .max_bits_per_color_range = device_max_bpc_range,
  .automatic_max_bits_per_color_limit = device_auto_max_bpc_limit,
  .edr_policy = device_edr_policy,
  .sharpness = device_sharpness,
  .priority = device_priority,
  .auto_brightness = device_auto_brightness,
  .removed = device_removed,
  .hdr_icc_profile_path = device_hdr_icc_profile_path,
  .hdr_color_profile_source = device_hdr_color_profile_source,
  .abm_level = device_abm_level,
};

/* --------------------------------------------------------------------------
 * kde_output_device_registry_v2 / wl_registry
 * ------------------------------------------------------------------------ */

static void device_registry_output(void *data, struct kde_output_device_registry_v2 *registry, struct kde_output_device_v2 *output) {
  (void) data;
  (void) registry;
  g.devices = realloc(g.devices, (g.ndevices + 1) * sizeof(*g.devices));
  struct device *d = &g.devices[g.ndevices++];
  *d = (struct device) {.proxy = output, .hdr = -1, .wcg = -1};
  kde_output_device_v2_add_listener(output, &device_listener, d);
}

static void device_registry_finished(void *data, struct kde_output_device_registry_v2 *registry) {
  (void) data;
  (void) registry;
}

static const struct kde_output_device_registry_v2_listener device_registry_listener = {
  .output = device_registry_output,
  .finished = device_registry_finished,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  (void) data;
  if (strcmp(interface, kde_output_management_v2_interface.name) == 0) {
    uint32_t v = version < MANAGEMENT_VERSION ? version : MANAGEMENT_VERSION;
    g.management = wl_registry_bind(registry, name, &kde_output_management_v2_interface, v);
  } else if (strcmp(interface, kde_output_device_registry_v2_interface.name) == 0) {
    uint32_t v = version < DEVICE_REGISTRY_VERSION ? version : DEVICE_REGISTRY_VERSION;
    g.device_registry = wl_registry_bind(registry, name, &kde_output_device_registry_v2_interface, v);
    kde_output_device_registry_v2_add_listener(g.device_registry, &device_registry_listener, NULL);
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
 * kde_output_configuration_v2 apply result
 * ------------------------------------------------------------------------ */

static void config_applied(void *data, struct kde_output_configuration_v2 *config) {
  (void) data;
  (void) config;
  g.apply_result = 1;
}

static void config_failed(void *data, struct kde_output_configuration_v2 *config) {
  (void) data;
  (void) config;
  if (g.apply_result == 0) {
    g.apply_result = -1;
  }
}

static void config_failure_reason(void *data, struct kde_output_configuration_v2 *config, const char *reason) {
  (void) data;
  (void) config;
  snprintf(g.failure_reason, sizeof(g.failure_reason), "%s", reason ? reason : "");
}

static const struct kde_output_configuration_v2_listener config_listener = {
  .applied = config_applied,
  .failed = config_failed,
  .failure_reason = config_failure_reason,
};

/**
 * @brief Apply one configuration and block until KWin reports the result.
 * @param config The configuration object (already populated; apply() is called here).
 * @return 0 on applied, -1 on failed.
 */
static int apply_and_wait(struct kde_output_configuration_v2 *config) {
  g.apply_result = 0;
  g.failure_reason[0] = '\0';
  kde_output_configuration_v2_apply(config);
  while (g.apply_result == 0) {
    if (wl_display_dispatch(g.display) < 0) {
      fprintf(stderr, LOG_PREFIX "wayland dispatch failed while waiting for apply result\n");
      kde_output_configuration_v2_destroy(config);
      return -1;
    }
  }
  kde_output_configuration_v2_destroy(config);
  if (g.apply_result < 0) {
    fprintf(stderr, LOG_PREFIX "configuration failed%s%s\n", g.failure_reason[0] ? ": " : "", g.failure_reason);
    return -1;
  }
  return 0;
}

/* --------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------ */

/**
 * @brief Find an alive mode matching size and refresh (±tolerance mHz).
 * @param d The output device.
 * @param width Mode width.
 * @param height Mode height.
 * @param refresh_mhz Target refresh rate in mHz.
 * @param tolerance Match tolerance in mHz.
 * @return The mode, or NULL.
 */
static struct mode *find_mode(struct device *d, int width, int height, int refresh_mhz, int tolerance) {
  struct mode *best = NULL;
  int best_delta = tolerance + 1;
  for (size_t i = 0; i < d->nmodes; i++) {
    struct mode *m = d->modes[i];
    if (m->proxy == NULL || m->width != width || m->height != height) {
      continue;
    }
    int delta = abs(m->refresh - refresh_mhz);
    if (delta <= tolerance && delta < best_delta) {
      best = m;
      best_delta = delta;
    }
  }
  return best;
}

static struct device *find_device(const char *name) {
  for (size_t i = 0; i < g.ndevices; i++) {
    if (!g.devices[i].removed && strcmp(g.devices[i].name, name) == 0) {
      return &g.devices[i];
    }
  }
  return NULL;
}

static const char *onoff(int v) {
  return v > 0 ? "enable" : v == 0 ? "disable" :
                                     "unknown";
}

/**
 * @brief Parse a "WxH@refresh" mode specification.
 * @param spec The spec string.
 * @param width Parsed width (out).
 * @param height Parsed height (out).
 * @param refresh_mhz Parsed refresh in mHz (out).
 * @param tolerance Suggested match tolerance in mHz (out): 50 for Hz input, 1 for mHz.
 * @return 0 on success, -1 on parse error.
 */
static int parse_mode_spec(const char *spec, int *width, int *height, int *refresh_mhz, int *tolerance) {
  int w, h, r;
  char extra;
  if (sscanf(spec, "%dx%d@%d%c", &w, &h, &r, &extra) != 3 || w <= 0 || h <= 0 || r <= 0) {
    fprintf(stderr, LOG_PREFIX "invalid mode spec '%s' (expected WxH@refresh)\n", spec);
    return -1;
  }
  *width = w;
  *height = h;
  if (r < 1000) { /* Hz input: KWin's generated timings can deviate ~200 mHz */
    *refresh_mhz = r * 1000;
    *tolerance = 250;
  } else {
    *refresh_mhz = r;
    *tolerance = 1;
  }
  return 0;
}

/* --------------------------------------------------------------------------
 * Commands
 * ------------------------------------------------------------------------ */

static int cmd_list(void) {
  for (size_t i = 0; i < g.ndevices; i++) {
    struct device *d = &g.devices[i];
    if (d->removed) {
      continue;
    }
    printf("%s \"%s %s\"%s\n", d->name, d->make, d->model, d->enabled ? "" : " (disabled)");
    int id = 0;
    for (size_t j = 0; j < d->nmodes; j++) {
      struct mode *m = d->modes[j];
      if (m->proxy == NULL) {
        continue;
      }
      printf("  mode %d: %dx%d@%d%s%s%s\n", id++, m->width, m->height, m->refresh, m == d->current ? " current" : "", m->preferred ? " preferred" : "", (m->flags & KDE_OUTPUT_DEVICE_MODE_V2_FLAGS_CUSTOM) ? " custom" : "");
    }
    printf("  hdr=%s wcg=%s\n", onoff(d->hdr), onoff(d->wcg));
  }
  return 0;
}

static int cmd_current(const char *name) {
  struct device *d = find_device(name);
  if (!d) {
    fprintf(stderr, LOG_PREFIX "no output named '%s'\n", name);
    return 1;
  }
  if (!d->current) {
    fprintf(stderr, LOG_PREFIX "output '%s' has no current mode (disabled?)\n", name);
    return 1;
  }
  /* id = index among alive modes, matching cmd_list numbering */
  int id = 0;
  for (size_t j = 0; j < d->nmodes; j++) {
    if (d->modes[j]->proxy == NULL) {
      continue;
    }
    if (d->modes[j] == d->current) {
      break;
    }
    id++;
  }
  printf("%d %dx%d@%d hdr=%s wcg=%s\n", id, d->current->width, d->current->height, d->current->refresh, onoff(d->hdr), onoff(d->wcg));
  return 0;
}

/**
 * @brief Add one mode to a custom mode list object.
 * @param list The kde_mode_list_v2 being populated.
 * @param width Mode width.
 * @param height Mode height.
 * @param refresh_mhz Refresh rate in mHz.
 * @param reduced_blanking Whether to use reduced blanking timings.
 */
static void mode_list_add(struct kde_mode_list_v2 *list, int width, int height, int refresh_mhz, bool reduced_blanking) {
  kde_mode_list_v2_set_resolution(list, (uint32_t) width, (uint32_t) height);
  kde_mode_list_v2_set_refresh_rate(list, (uint32_t) refresh_mhz);
  kde_mode_list_v2_set_reduced_blanking(list, reduced_blanking ? 1 : 0);
  kde_mode_list_v2_add_mode(list);
}

static int cmd_apply(const char *name, const char *spec, int hdr, int wcg, bool rb) {
  struct device *d = find_device(name);
  if (!d) {
    fprintf(stderr, LOG_PREFIX "no output named '%s'\n", name);
    return 1;
  }
  int width, height, refresh_mhz, tolerance;
  if (parse_mode_spec(spec, &width, &height, &refresh_mhz, &tolerance) < 0) {
    return 1;
  }

  struct mode *target = find_mode(d, width, height, refresh_mhz, tolerance);

  if (!target) {
    /* create the mode as a custom mode first */
    if (!(d->capabilities & KDE_OUTPUT_DEVICE_V2_CAPABILITY_CUSTOM_MODES)) {
      fprintf(stderr, LOG_PREFIX
              "%dx%d@%d not advertised and output '%s' "
              "lacks the custom_modes capability\n",
              width,
              height,
              refresh_mhz,
              name);
      return 1;
    }
    fprintf(stderr, LOG_PREFIX "creating custom mode %dx%d@%d on %s\n", width, height, refresh_mhz, name);

    struct kde_mode_list_v2 *list = kde_output_management_v2_create_mode_list(g.management);
    /* set_custom_modes replaces the whole list: keep existing custom modes */
    for (size_t i = 0; i < d->nmodes; i++) {
      struct mode *m = d->modes[i];
      if (m->proxy && (m->flags & KDE_OUTPUT_DEVICE_MODE_V2_FLAGS_CUSTOM) &&
          !(m->width == width && m->height == height &&
            abs(m->refresh - refresh_mhz) <= tolerance)) {
        mode_list_add(list, m->width, m->height, m->refresh, (m->flags & KDE_OUTPUT_DEVICE_MODE_V2_FLAGS_REDUCED_BLANKING) != 0);
      }
    }
    mode_list_add(list, width, height, refresh_mhz, rb);

    struct kde_output_configuration_v2 *config =
      kde_output_management_v2_create_configuration(g.management);
    kde_output_configuration_v2_add_listener(config, &config_listener, NULL);
    kde_output_configuration_v2_set_custom_modes(config, d->proxy, list);
    int rc = apply_and_wait(config);
    kde_mode_list_v2_destroy(list);
    if (rc < 0) {
      return 1;
    }

    /* the device was re-announced before the applied event; find the new mode */
    target = find_mode(d, width, height, refresh_mhz, tolerance);
    if (!target) {
      fprintf(stderr, LOG_PREFIX "custom mode %dx%d@%d was not advertised after apply\n", width, height, refresh_mhz);
      return 1;
    }
  }

  struct kde_output_configuration_v2 *config =
    kde_output_management_v2_create_configuration(g.management);
  kde_output_configuration_v2_add_listener(config, &config_listener, NULL);
  kde_output_configuration_v2_mode(config, d->proxy, target->proxy);
  if (hdr >= 0) {
    kde_output_configuration_v2_set_high_dynamic_range(config, d->proxy, (uint32_t) hdr);
  }
  if (wcg >= 0) {
    kde_output_configuration_v2_set_wide_color_gamut(config, d->proxy, (uint32_t) wcg);
  }
  if (apply_and_wait(config) < 0) {
    return 1;
  }
  fprintf(stderr, LOG_PREFIX "applied %dx%d@%d on %s (hdr=%s wcg=%s)\n", width, height, refresh_mhz, name, hdr >= 0 ? onoff(hdr) : "unchanged", wcg >= 0 ? onoff(wcg) : "unchanged");
  return 0;
}

/* --------------------------------------------------------------------------
 * Setup / main
 * ------------------------------------------------------------------------ */

/**
 * @brief Connect to the compositor and synchronize the initial device state.
 * @return 0 on success, -1 on failure.
 */
static int setup(void) {
  const char *socket = getenv("WAYLAND_DISPLAY");
  if (!socket || !*socket) {
    socket = "wayland-0";
  }
  g.display = wl_display_connect(socket);
  if (!g.display) {
    fprintf(stderr, LOG_PREFIX "cannot connect to wayland display '%s'\n", socket);
    return -1;
  }
  struct wl_registry *registry = wl_display_get_registry(g.display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(g.display); /* learn globals, bind device registry */
  if (!g.management || !g.device_registry) {
    fprintf(stderr, LOG_PREFIX
            "compositor lacks kde_output_management_v2 or "
            "kde_output_device_registry_v2\n");
    return -1;
  }
  /* dispatch until every announced device sent its first done event */
  for (int tries = 0; tries < 10; tries++) {
    bool all_done = g.ndevices > 0;
    for (size_t i = 0; i < g.ndevices; i++) {
      all_done &= g.devices[i].done;
    }
    if (all_done) {
      break;
    }
    wl_display_roundtrip(g.display);
  }
  wl_registry_destroy(registry);
  if (g.ndevices == 0) {
    fprintf(stderr, LOG_PREFIX "no output devices announced\n");
    return -1;
  }
  return 0;
}

static int parse_onoff(const char *arg, const char *key, int *out) {
  size_t len = strlen(key);
  if (strncmp(arg, key, len) != 0 || arg[len] != '=') {
    return 0;
  }
  const char *val = arg + len + 1;
  if (strcmp(val, "enable") == 0) {
    *out = 1;
  } else if (strcmp(val, "disable") == 0) {
    *out = 0;
  } else {
    fprintf(stderr, LOG_PREFIX "invalid value '%s' for %s (enable|disable)\n", val, key);
    return -1;
  }
  return 1;
}

static void usage(FILE *out) {
  fprintf(out,
          "usage:\n"
          "  prism-kwin-mode list\n"
          "  prism-kwin-mode current <output-name>\n"
          "  prism-kwin-mode apply <output-name> <WxH@refresh> [hdr=enable|disable] [wcg=enable|disable] [rb=enable|disable]\n"
          "\n"
          "refresh is in Hz when < 1000 (matched with ±50 mHz tolerance), else exact mHz.\n");
}

int main(int argc, char **argv) {
  if (argc < 2) {
    usage(stderr);
    return 2;
  }
  const char *cmd = argv[1];
  int rc;

  if (strcmp(cmd, "list") == 0 && argc == 2) {
    if (setup() < 0) {
      return 1;
    }
    rc = cmd_list();
  } else if (strcmp(cmd, "current") == 0 && argc == 3) {
    if (setup() < 0) {
      return 1;
    }
    rc = cmd_current(argv[2]);
  } else if (strcmp(cmd, "apply") == 0 && argc >= 4) {
    int hdr = -1, wcg = -1, rb = 0;
    for (int i = 4; i < argc; i++) {
      int r;
      if ((r = parse_onoff(argv[i], "hdr", &hdr)) != 0 ||
          (r = parse_onoff(argv[i], "wcg", &wcg)) != 0 ||
          (r = parse_onoff(argv[i], "rb", &rb)) != 0) {
        if (r < 0) {
          return 2;
        }
      } else {
        fprintf(stderr, LOG_PREFIX "unknown argument '%s'\n", argv[i]);
        return 2;
      }
    }
    if (setup() < 0) {
      return 1;
    }
    rc = cmd_apply(argv[2], argv[3], hdr, wcg, rb != 0);
  } else {
    usage(stderr);
    return 2;
  }

  if (g.display) {
    wl_display_disconnect(g.display);
  }
  return rc;
}
