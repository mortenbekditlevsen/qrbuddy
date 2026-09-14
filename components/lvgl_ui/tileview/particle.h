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

/* 200 comfortably covers the QR effect's skeleton at its worst case --
 * version 7-10 codes have 6 alignment patterns instead of 1: 3 finder
 * corners x (16 real inner-ring + 32 synthetic outer-ring) + 6 alignment
 * patterns x 8 dots = 192, plus a little headroom. particle_t is 12 bytes,
 * so even this is under 2.5KB total -- the limiting factor is never memory,
 * it's wanting the per-tick spring-physics loop to stay cheap; 200 is still
 * trivial there. */
#define PARTICLE_MAX_COUNT 200

/* The QR encoder picks the smallest version (1-10) that fits the text (see
 * qr_generate() in rgb_tile.c) -- module count is therefore a runtime value,
 * not a compile-time constant, and so is the on-screen pixel size per module
 * (rgb_tile.c fits whatever version came back into the tile's short
 * dimension; see particle_qr_px_per_module()). Only the quiet zone width is
 * still fixed: 3 modules, chosen (same reasoning as the old fixed-version
 * comment this replaced) so the largest supported version still fits this
 * display without the quiet zone needing to shrink further. */
#define QR_LAYOUT_QUIET_MODULES 3

/* Implemented in rgb_tile.c, for the Swift particle skeleton (qrTargets() in
 * ParticleEffects.swift) to lay itself out identically to the solid QR it
 * crossfades into. Both are 0 until particle_qr_prepare() has been called at
 * least once (see beginTransition()'s .qr case -- it's called immediately on
 * entering the QR effect, not lazily at crossfade time, precisely so these
 * are valid from the skeleton's very first tick). */
int32_t particle_qr_modules(void);
int32_t particle_qr_px_per_module(int32_t tile_w, int32_t tile_h);

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
