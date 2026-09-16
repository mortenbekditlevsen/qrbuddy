#ifndef __RGB_TILE_H__
#define __RGB_TILE_H__

#include "../lvgl_ui.h"


#ifdef __cplusplus
extern "C" {
#endif

void rgb_tile_init(lv_obj_t *parent);

/* Shown once, at the very start of boot (see initialize()), before
 * anything else on the tile has run -- taken down automatically the first
 * time any other rgb_tile_show_*() call happens (they all route through
 * stop_qr()/stop_particles()/stop_message(), which now also clear this).
 * Caller must hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_boot_logo(void);

/* Regenerate the QR code from `text` and repaint the tile.
 * Caller must hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_qr(const char *text);

/* Same as rgb_tile_show_qr(), but never auto-hides (no countdown label, no
 * QR_VISIBLE_SECONDS timeout) -- for the pairing QR (see
 * docs/ble-provisioning.md), which needs to stay up for as long as the
 * pairing window is open, not a fixed short display time. Caller must hold
 * the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_qr_persistent(const char *text);

/* Like rgb_tile_show_qr(), but with a caller-chosen display duration
 * instead of the fixed QR_VISIBLE_SECONDS -- the command interface's
 * ShowQR (see docs/ble-provisioning.md §5b). `display_seconds <= 0` means
 * "don't time out" (same as rgb_tile_show_qr_persistent(), including no
 * progress bar). `purpose` drives a short caption below the code, but only
 * in portrait orientation, and only for the purposes that have one so far
 * (see docs/ble-provisioning.md's ShowQR purpose table) -- every other
 * value is accepted and stored but shows nothing yet. Caller must hold the
 * LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_qr_timed(const char *text, int32_t display_seconds, uint8_t purpose);

/* A plain, persistent, centered/wrapped text screen -- see
 * rgb_tile_show_qr_persistent()'s docs/ble-provisioning.md reference; this
 * is that flow's "scan this in <app>" helper text, alternated with the QR
 * from Swift. Caller must hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_message(const char *text);

/* Ambient particle idle effect. Which effect actually runs (starfield, or
 * anything added later) is decided entirely on the Swift side -- see
 * particle.h's particle_effect_tick() and main/ParticleEffects.swift.
 * Not auto-triggered by anything yet -- call show/hide from wherever you want
 * it kicked off. Caller must hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_particles(void);
void rgb_tile_hide_particles(void);

/* The command interface's Idle -- blank the tile and turn the backlight
 * off, whichever of QR/particles/message was showing. Caller must hold the
 * LVGL port lock (lvgl_port_lock). */
void rgb_tile_idle(void);

/* Re-applies device_config_get_qr_brightness() to the backlight right now,
 * if (and only if) a QR is currently on screen (the "real" one or the
 * pairing/message screens that share its brightness) -- so a SetConfig
 * QRBrightness change is visible immediately rather than waiting for the
 * next QR to be shown. A no-op otherwise. Caller must hold the LVGL port
 * lock (lvgl_port_lock). */
void rgb_tile_apply_qr_brightness(void);


#ifdef __cplusplus
}
#endif



#endif