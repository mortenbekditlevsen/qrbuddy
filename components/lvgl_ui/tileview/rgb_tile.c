#include "rgb_tile.h"

#include "qrcodegen.h"
#include "bsp_display.h"
#include "particle.h"

#define QR_PX_PER_MODULE 3
#define QR_QUIET_MODULES 4   // spec-recommended quiet zone (white border) on every side
#define QR_MAX_MODULES   qrcodegen_BUFFER_LEN_FOR_VERSION(40) // generous upper bound
#define QR_VISIBLE_SECONDS 60  // how long the QR code stays on screen
#define QR_BACKLIGHT     20    // backlight % while a QR code is on screen

// Generic particle-effect rendering. This file has no idea which effect is
// running (starfield, sphere, flock, ...) -- that's entirely decided in Swift
// (see main/ParticleEffects.swift). Each tick we ask Swift to fill
// `particle_buf`, then just draw whatever came back.
#define PARTICLE_TICK_MS     50    // ~20 fps simulate + redraw
#define PARTICLE_BACKLIGHT   100   // backlight % while a particle effect is showing
#define PARTICLE_SATURATION  55    // fixed HSV S/V for every particle -- bright, near-white dots
#define PARTICLE_VALUE       100

static uint8_t qr_buf[177][177]; // 177 = max modules at version 40
static int qr_modules = 0;
static bool qr_visible = false;        // whether draw_qr should paint anything

static lv_obj_t *obj_rgb_tile;
static lv_obj_t *qr_countdown_label;   // "seconds left" label, hidden while no QR
static lv_timer_t *qr_tick_timer;      // 1 Hz countdown timer, paused while no QR
static int qr_seconds_left;

static particle_t particle_buf[PARTICLE_MAX_COUNT];
static int32_t particle_count = 0;
static bool particles_active = false;      // whether draw_particles should paint anything
static bool particle_needs_reset = false;  // true for exactly the first tick after activation
static lv_timer_t *particle_tick_timer;    // ~20 Hz simulation timer, paused while inactive
static int32_t particle_tile_w = 280, particle_tile_h = 240; // set from the real tile size on activation

static bool qr_generate(const char * text)
{
    uint8_t qrcode[qrcodegen_BUFFER_LEN_FOR_VERSION(10)];
    uint8_t tempBuffer[qrcodegen_BUFFER_LEN_FOR_VERSION(10)];

    // Forcing version 10 keeps it at 57x57 to match what we've been drawing.
    // "https://ka-ching.dk" easily fits at version 10 with room to spare.
    bool ok = qrcodegen_encodeText(
        text,
        tempBuffer,
        qrcode,
        qrcodegen_Ecc_MEDIUM,
        10, 10,                 // minVersion, maxVersion — locked to 57x57
        qrcodegen_Mask_AUTO,
        true);

    if (!ok) return false;

    qr_modules = qrcodegen_getSize(qrcode);
    for (int y = 0; y < qr_modules; y++) {
        for (int x = 0; x < qr_modules; x++) {
            qr_buf[y][x] = qrcodegen_getModule(qrcode, x, y) ? 1 : 0;
        }
    }
    return true;
}

static void draw_qr(lv_layer_t *layer, const lv_area_t *obj_coords)
{
    if (!qr_visible || qr_modules <= 0) return;

    int32_t obj_w = lv_area_get_width(obj_coords);
    int32_t qr_px = qr_modules * QR_PX_PER_MODULE;
    int32_t quiet_px = QR_QUIET_MODULES * QR_PX_PER_MODULE;

    // Center horizontally; sit near the top so the countdown label has room below.
    int32_t origin_x = obj_coords->x1 + (obj_w - qr_px) / 2;
    int32_t origin_y = obj_coords->y1 + quiet_px + 20;

    lv_draw_rect_dsc_t bg_dsc;
    lv_draw_rect_dsc_init(&bg_dsc);
    bg_dsc.bg_color = lv_color_white();
    bg_dsc.bg_opa = LV_OPA_COVER;
    // Round the corners, but no more than the quiet zone is wide so the rounding
    // stays in the white border and never clips a QR finder pattern.
    bg_dsc.radius = quiet_px;
    bg_dsc.border_width = 0;

    lv_area_t bg_area;
    bg_area.x1 = origin_x - quiet_px;
    bg_area.y1 = origin_y - quiet_px;
    bg_area.x2 = origin_x + qr_px + quiet_px - 1;
    bg_area.y2 = origin_y + qr_px + quiet_px - 1;

    lv_draw_rect(layer, &bg_dsc, &bg_area);

    // Black modules
    lv_draw_rect_dsc_t dsc;
    lv_draw_rect_dsc_init(&dsc);
    dsc.bg_color = lv_color_black();
    dsc.bg_opa = LV_OPA_COVER;
    dsc.radius = 0;
    dsc.border_width = 0;

    for (int r = 0; r < qr_modules; r++) {
        int c = 0;
        while (c < qr_modules) {
            if (!qr_buf[r][c]) { c++; continue; }

            int run_start = c;
            while (c < qr_modules && qr_buf[r][c]) c++;
            int run_len = c - run_start;

            lv_area_t module_area;
            module_area.x1 = origin_x + run_start * QR_PX_PER_MODULE;
            module_area.y1 = origin_y + r * QR_PX_PER_MODULE;
            module_area.x2 = module_area.x1 + run_len * QR_PX_PER_MODULE - 1;
            module_area.y2 = module_area.y1 + QR_PX_PER_MODULE - 1;

            lv_draw_rect(layer, &dsc, &module_area);
        }
    }
}

/* Draws whatever Swift put in particle_buf last tick. Genuinely doesn't know
 * (and doesn't need to know) which effect produced it. */
static void draw_particles(lv_layer_t *layer, const lv_area_t *obj_coords)
{
    if (!particles_active) return;

    lv_draw_rect_dsc_t dsc;
    lv_draw_rect_dsc_init(&dsc);
    dsc.radius = 0;
    dsc.border_width = 0;

    for (int32_t i = 0; i < particle_count; i++) {
        const particle_t *p = &particle_buf[i];
        if (p->opa < 6) continue;  // ~0.02 alpha cutoff

        dsc.bg_color = lv_color_hsv_to_rgb(p->hue, PARTICLE_SATURATION, PARTICLE_VALUE);
        dsc.bg_opa = p->opa;

        int32_t s = p->size;
        lv_area_t area;
        area.x1 = obj_coords->x1 + p->sx - s / 2;
        area.y1 = obj_coords->y1 + p->sy - s / 2;
        area.x2 = area.x1 + s - 1;
        area.y2 = area.y1 + s - 1;

        lv_draw_rect(layer, &dsc, &area);
    }
}

static void rgb_tile_draw_event_cb(lv_event_t * e)
{
    if (lv_event_get_code(e) != LV_EVENT_DRAW_POST) return;

    lv_obj_t * obj = lv_event_get_target(e);
    lv_layer_t * layer = lv_event_get_layer(e);

    lv_area_t obj_coords;
    lv_obj_get_coords(obj, &obj_coords);

    if (qr_visible) {
        draw_qr(layer, &obj_coords);
    } else if (particles_active) {
        draw_particles(layer, &obj_coords);
    }
}

/* Stop each effect without touching the backlight — used when the other
 * effect is about to take over and will set its own brightness right after. */
static void stop_qr(void)
{
    if (qr_tick_timer) lv_timer_pause(qr_tick_timer);
    qr_visible = false;
    if (qr_countdown_label) {
        lv_obj_add_flag(qr_countdown_label, LV_OBJ_FLAG_HIDDEN);
    }
}

static void stop_particles(void)
{
    if (particle_tick_timer) lv_timer_pause(particle_tick_timer);
    particles_active = false;
}

/* Take the QR code off screen: stop the countdown, blank the tile, backlight off. */
static void hide_qr(void)
{
    stop_qr();
    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
    bsp_display_set_brightness(0);
}

/* 1 Hz while a QR code is showing. Runs on the LVGL task (holding the port
 * lock), same as draw_qr. */
static void qr_tick_cb(lv_timer_t *timer)
{
    LV_UNUSED(timer);
    qr_seconds_left--;
    if (qr_seconds_left <= 0) {
        hide_qr();
        return;
    }
    lv_label_set_text_fmt(qr_countdown_label, "%d", qr_seconds_left);
}

/* ~20 Hz while a particle effect is active. Runs on the LVGL task (holding
 * the port lock), same as draw_particles. Hands off entirely to Swift: this
 * file only owns the buffer, the timer, and drawing whatever comes back. */
static void particle_tick_cb(lv_timer_t *timer)
{
    LV_UNUSED(timer);
    if (!obj_rgb_tile) return;

    particle_effect_tick(
        particle_buf, PARTICLE_MAX_COUNT, &particle_count,
        particle_tile_w, particle_tile_h,
        particle_needs_reset
    );
    particle_needs_reset = false;

    lv_obj_invalidate(obj_rgb_tile);
}

void rgb_tile_init(lv_obj_t *parent)
{
    obj_rgb_tile = parent;
    lv_obj_set_style_bg_color(obj_rgb_tile, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(obj_rgb_tile, LV_OPA_COVER, LV_PART_MAIN);

    qr_countdown_label = lv_label_create(parent);
    lv_obj_set_style_text_font(qr_countdown_label, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_style_text_color(qr_countdown_label, lv_color_white(), LV_PART_MAIN);
    lv_obj_align(qr_countdown_label, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_add_flag(qr_countdown_label, LV_OBJ_FLAG_HIDDEN);

    qr_tick_timer = lv_timer_create(qr_tick_cb, 1000, NULL);
    lv_timer_pause(qr_tick_timer);

    particle_tick_timer = lv_timer_create(particle_tick_cb, PARTICLE_TICK_MS, NULL);
    lv_timer_pause(particle_tick_timer);

    lv_obj_add_event_cb(parent, rgb_tile_draw_event_cb, LV_EVENT_DRAW_POST, NULL);

    rgb_tile_show_qr("https://ka-ching.dk");
}

/* Regenerate the QR code, repaint the tile, and (re)start the countdown.
 * The caller MUST already hold the LVGL port lock (lvgl_port_lock), because this
 * mutates qr_buf/qr_modules which draw_qr reads on the LVGL task. */
void rgb_tile_show_qr(const char *text)
{
    if (!qr_generate(text)) {
        return; /* text too long for the fixed QR version; keep the previous code */
    }
    stop_particles();  // mutually exclusive with the QR code on this tile

    qr_visible = true;
    bsp_display_set_brightness(QR_BACKLIGHT);   // wake the backlight for the QR

    qr_seconds_left = QR_VISIBLE_SECONDS;
    if (qr_countdown_label) {
        lv_label_set_text_fmt(qr_countdown_label, "%d", qr_seconds_left);
        lv_obj_remove_flag(qr_countdown_label, LV_OBJ_FLAG_HIDDEN);
    }
    if (qr_tick_timer) {
        lv_timer_reset(qr_tick_timer);    // full 1 s before the first decrement
        lv_timer_resume(qr_tick_timer);
    }

    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
}

/* Start whichever particle effect Swift currently has selected. This file
 * doesn't know or care which one that is -- it just owns the LVGL lifecycle
 * (timer, backlight, QR mutual-exclusion) and a buffer Swift fills in.
 * Not wired to any auto-trigger yet -- call this from wherever you want it
 * kicked off (a button, a BLE property, a timer in initialize.c, ...).
 * The caller MUST already hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_particles(void)
{
    stop_qr();  // mutually exclusive with the QR code on this tile

    if (obj_rgb_tile) {
        int32_t w = lv_obj_get_width(obj_rgb_tile);
        int32_t h = lv_obj_get_height(obj_rgb_tile);
        if (w > 0) particle_tile_w = w;
        if (h > 0) particle_tile_h = h;
    }

    particle_count = 0;
    particle_needs_reset = true;   // tell Swift to (re)initialize on the next tick
    particles_active = true;
    bsp_display_set_brightness(PARTICLE_BACKLIGHT);

    if (particle_tick_timer) {
        lv_timer_reset(particle_tick_timer);
        lv_timer_resume(particle_tick_timer);
    }
    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
}

/* Stop the particle effect and blank the tile (backlight off), mirroring hide_qr(). */
void rgb_tile_hide_particles(void)
{
    stop_particles();
    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
    bsp_display_set_brightness(0);
}
