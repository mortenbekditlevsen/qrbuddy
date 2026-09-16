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
 * Each config is its own get/set pair here plus a new Command case in
 * GATTServer.swift, not a generic blob store. That's deliberate: each
 * concrete config behaves differently enough on top of its own storage
 * (orientation needs a restart to apply; QR brightness applies live) that
 * a generic store would just hide that per-config behavior rather than
 * simplify anything. */

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
 * needs a reboot to take effect. Marks the upcoming boot so
 * device_config_consume_restart_skip() reads true exactly once on the
 * other side -- see that function's own comment. */
void device_config_schedule_restart(void);

/* True if the boot currently in progress was caused by
 * device_config_schedule_restart() (an intentional, BLE-triggered restart
 * to apply a config change) rather than a real power-on/reset -- for
 * initialize.c to skip anything that only makes sense on a fresh power-up
 * (currently: the boot logo -- the user just saw it seconds ago, right
 * before the restart that got them here). One-shot: reading this clears
 * it, so only the single boot right after a scheduled restart reads true,
 * never any boot after that. Backed by RTC memory, not NVS -- it only
 * needs to survive esp_restart() (a software reset), not a real power
 * cycle, and RTC memory is zeroed by the bootloader on power-on, so a
 * genuine fresh boot always reads false here with no extra bookkeeping. */
bool device_config_consume_restart_skip(void);

// LCD backlight percentage (0-100) while a QR code is on screen -- both
// the BLE/command-triggered display and the pairing QR use this (see
// rgb_tile.c's show_qr_internal()/rgb_tile_show_message()). Unlike
// orientation, this applies live: rgb_tile.c re-reads it every time it's
// about to light up the backlight for a QR, and rgb_tile_apply_qr_
// brightness() (see rgb_tile.h) re-applies it immediately if a QR happens
// to already be on screen when it's changed -- there's no hardware
// constraint here forcing a restart the way orientation has.
#define DEVICE_QR_BRIGHTNESS_DEFAULT 20   // matches this project's original hardcoded QR_BACKLIGHT

/* Returns the persisted QR brightness (0-100), or
 * DEVICE_QR_BRIGHTNESS_DEFAULT if none is stored yet. */
uint8_t device_config_get_qr_brightness(void);

/* Persists a new QR brightness. Returns false (and doesn't touch NVS) if
 * `percent` is out of the 0-100 range -- callers must reject the write,
 * not clamp it. Doesn't apply it -- see rgb_tile_apply_qr_brightness(). */
bool device_config_set_qr_brightness(uint8_t percent);

#endif
