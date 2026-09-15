#ifndef __DEVICE_CONFIG_H__
#define __DEVICE_CONFIG_H__

#include <stdint.h>
#include <stdbool.h>

/* Persisted (NVS) device configuration -- the BLE command interface's
 * SetConfig opcode (see docs/ble-provisioning.md §5b) writes here. This
 * header is plain C, safe for Swift's ClangImporter to parse directly
 * (same as particle.h/pairing.h) -- Swift calls these functions straight
 * from GATTServer.swift, no C-side wrapper needed (unlike the LVGL-facing
 * functions in initialize.h, nothing here touches LVGL or needs its port
 * lock).
 *
 * Only one config exists so far (orientation); more are expected (per the
 * SetConfig wire format's own config-type byte) -- each new one is its own
 * get/set pair here plus a new Command case in GATTServer.swift, not a
 * generic blob store. That's deliberate: there's nothing to generalize
 * *from* yet with only one real config type, and each concrete config is
 * different enough (orientation needs a restart to apply; others might
 * not) that a generic store would just hide that per-config behavior
 * rather than simplify anything. */

// Device orientation, in degrees clockwise. Applied once at boot
// (components/lvgl_ui/initialize.c) from whatever's persisted here --
// changing it via device_config_set_orientation() takes effect only after
// the next restart (device_config_schedule_restart()), not live: this
// display stack (esp_lvgl_port's HW-rotation mode) doesn't expose a
// supported API for changing hardware rotation at runtime, and re-deriving
// it live (swapping hres/vres, resizing LVGL's draw buffers, redoing the
// panel gap) is close enough to "just reboot" in complexity that going
// through the already-correct boot-time path is the safer choice.
#define DEVICE_ORIENTATION_0   0
#define DEVICE_ORIENTATION_90  1
#define DEVICE_ORIENTATION_180 2
#define DEVICE_ORIENTATION_270 3

// Factory-fresh / never-configured default -- matches this project's
// original hardcoded rotation, so units already in the field keep their
// current physical orientation the first time they run firmware that
// includes this feature, rather than silently rotating on an OTA/reflash.
#define DEVICE_ORIENTATION_DEFAULT DEVICE_ORIENTATION_270

/* Returns the persisted orientation, or DEVICE_ORIENTATION_DEFAULT if none
 * is stored yet. Never fails -- there's no meaningful error path for a
 * boot-time read with a well-defined default. */
uint8_t device_config_get_orientation(void);

/* Persists a new orientation. Returns false (and doesn't touch NVS) if
 * `orientation` isn't one of the DEVICE_ORIENTATION_* values above --
 * callers must reject the write, not clamp to something valid. Doesn't
 * apply it or restart -- call device_config_schedule_restart() for that,
 * once you're ready to. */
bool device_config_set_orientation(uint8_t orientation);

/* Restarts the device shortly (not immediately -- gives NimBLE a moment to
 * actually transmit the write's ATT response before the SoC resets,
 * rather than cutting it off mid-transmit) after a config change that
 * needs a reboot to take effect. */
void device_config_schedule_restart(void);

#endif
