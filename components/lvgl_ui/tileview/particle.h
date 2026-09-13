#ifndef __PARTICLE_H__
#define __PARTICLE_H__

#include <stdint.h>
#include <stdbool.h>

/* Plain-data particle record shared between the C/LVGL rendering side
 * (rgb_tile.c) and the Swift simulation side (main/ParticleEffects.swift, via
 * BridgingHeader.h). Deliberately has no LVGL types in it -- only C's
 * fixed-width integers cross the Swift <-> C boundary, so Swift never needs
 * to see (and Embedded Swift's ClangImporter never needs to parse) any of
 * LVGL's headers. */
typedef struct {
    int32_t sx, sy;   // screen-space position, tile-relative pixels
    int32_t size;     // on-screen size in px
    uint16_t hue;     // 0-359; C turns this into an lv_color_t right before drawing
    uint8_t sat;      // 0-100 HSV saturation -- the QR effect uses ~0 for a white look
    uint8_t opa;      // 0-255 opacity
} particle_t;

/* 160 comfortably covers the QR effect's skeleton (152 particles: 3 finder
 * corners x (16 real inner-ring + 32 synthetic outer-ring) + 8 alignment
 * dots) with a little headroom. particle_t is 12 bytes, so even this is
 * under 2KB total -- the limiting factor is never memory, it's wanting the
 * per-tick spring-physics loop to stay cheap; 160 is still trivial there. */
#define PARTICLE_MAX_COUNT 160

/* QR layout, shared so the particle-effect's silhouette (Swift) roughly lines
 * up with the solid renderer (rgb_tile.c's draw_qr) it crossfades into.
 * QR_LAYOUT_MODULES matches the fixed qrcodegen version both sides encode at.
 *
 * At 41 modules (version 6) and 5px/module, the code area alone is 205px;
 * with the spec-recommended 4-module quiet zone (+40px) that's 245px square
 * -- 5px too tall for this display's 240px-short dimension (280x240, rotated).
 * Quiet zone trimmed to 3 modules (+30px = 235px) to fit, since neither the
 * version nor the module size had room to give on their own:
 *   version 6, 5px/module, quiet 4 -> 245px (5px over)
 *   version 6, 5px/module, quiet 3 -> 235px (fits, 5px to spare)
 *   version 5, 5px/module, quiet 4 -> 225px (fits, but lower QR capacity) */
#define QR_LAYOUT_MODULES       41   // qrcodegen version 6
#define QR_LAYOUT_PX_PER_MODULE 5
#define QR_LAYOUT_QUIET_MODULES 3

/* Implemented in Swift (see main/ParticleEffects.swift). Called once per tick
 * by rgb_tile.c's particle timer: fills particles[0 ..< *out_count] (out_count
 * clamped to `capacity`) for whichever effect is currently selected on the
 * Swift side -- C has no idea which effect that is, or how many exist.
 * `reset` is true on the first tick after rgb_tile_show_particles() is
 * called, so the effect can (re)initialize its state. */
void particle_effect_tick(
    particle_t *particles,
    int32_t capacity,
    int32_t *out_count,
    int32_t tile_w,
    int32_t tile_h,
    bool reset
);

/* Implemented in rgb_tile.c. Called by Swift's QR particle effect once its
 * particles have settled into the QR silhouette: (re)generates the solid,
 * fully-detailed QR (same renderer rgb_tile_show_qr() uses, border included)
 * so it's ready to crossfade in via particle_qr_set_overlay_opacity(). Safe
 * to call repeatedly with the same text (cheap no-op-ish; qrcodegen still
 * re-encodes, but nothing else changes). */
void particle_qr_prepare(const char *text);

/* 0 (fully hidden) .. 255 (fully opaque). Swift ramps this itself, tick by
 * tick, to crossfade the solid QR in over the particle silhouette and back
 * out again before the particle effect moves on to the next shape. */
void particle_qr_set_overlay_opacity(uint8_t opa);

#endif
