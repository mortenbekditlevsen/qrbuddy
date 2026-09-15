#ifndef __RGB_TILE_H__
#define __RGB_TILE_H__

#include "../lvgl_ui.h"


#ifdef __cplusplus
extern "C" {
#endif

void rgb_tile_init(lv_obj_t *parent);

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
 * progress bar). `purpose` is stored but not yet used for anything visual
 * -- plumbed through now so the wire format doesn't need to change again
 * once it is (see docs/ble-provisioning.md's ShowQR purpose enum). Caller
 * must hold the LVGL port lock (lvgl_port_lock). */
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


#ifdef __cplusplus
}
#endif



#endif