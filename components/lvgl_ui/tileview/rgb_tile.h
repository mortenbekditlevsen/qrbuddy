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

/* Ambient particle idle effect. Which effect actually runs (starfield, or
 * anything added later) is decided entirely on the Swift side -- see
 * particle.h's particle_effect_tick() and main/ParticleEffects.swift.
 * Not auto-triggered by anything yet -- call show/hide from wherever you want
 * it kicked off. Caller must hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_particles(void);
void rgb_tile_hide_particles(void);


#ifdef __cplusplus
}
#endif



#endif