#include "rgb_tile.h"

#include "qrcodegen.h"
#include "bsp_display.h"
#include "particle.h"

#define QR_MAX_MODULES   qrcodegen_BUFFER_LEN_FOR_VERSION(40) // generous upper bound
#define QR_VISIBLE_SECONDS 60  // how long the QR code stays on screen
#define QR_BACKLIGHT     20    // backlight % while a QR code is on screen

// The encoder is allowed to pick any version in this range -- it always
// picks the smallest one the text (plus ECC) actually fits in, so short URLs
// get a coarser, more scannable code and only long ones grow. Capped at 10
// (57x57) since that's already tight on this display -- see
// qr_fit_px_per_module()'s own module-size floor for what happens if a
// caller ever ignores that cap.
#define QR_MIN_VERSION   1
#define QR_MAX_VERSION   10

// Purpose icon (see docs/ble-provisioning.md's ShowQR `purpose` field):
// a small pictogram to the right of the code, in the space freed up by
// left- instead of center-aligning the code horizontally. QR_PURPOSE_NONE
// is a sentinel distinct from every real purpose byte (0x00-0x06 today) --
// draw_qr() only left-aligns (and draw_purpose_icon() only draws anything)
// when qr_purpose is a real value, so the pairing/demo QRs (which never set
// a purpose) stay centered exactly as before.
#define QR_PURPOSE_NONE  0xFF
#define QR_PURPOSE_ICON_SIZE 32

// Generic particle-effect rendering. This file has no idea which effect is
// running (starfield, sphere, flock, ...) -- that's entirely decided in Swift
// (see main/ParticleEffects.swift). Each tick we ask Swift to fill
// `particle_buf`, then just draw whatever came back.
#define PARTICLE_TICK_MS     50    // ~20 fps simulate + redraw
#define PARTICLE_BACKLIGHT   100   // backlight % while a particle effect is showing
#define PARTICLE_VALUE       100   // fixed HSV V for every particle -- per-particle sat/hue vary

static uint8_t qr_buf[177][177]; // 177 = max modules at version 40
static int qr_modules = 0;
static bool qr_visible = false;        // whether draw_qr should paint anything (the "real", BLE-triggered display)
static uint8_t qr_purpose = QR_PURPOSE_NONE;   // set by rgb_tile_show_qr_timed(); QR_PURPOSE_NONE elsewhere

// Solid-QR overlay for the particle effect's QR case: once its particles
// settle into the silhouette, Swift crossfades this in on top (reusing the
// same draw_qr renderer, border and all) rather than trying to draw one
// particle per module -- a real QR at our forced version has ~850 dark
// modules, far more than this hardware can redraw every tick. Independent of
// qr_visible/the BLE-triggered display above; only one of the two is ever
// non-zero-opacity at a time in practice, since they're driven by mutually
// exclusive modes (see stop_particles()/rgb_tile_show_qr()).
static uint8_t particle_qr_overlay_opa = 0;

static lv_obj_t *obj_rgb_tile;
static lv_obj_t *qr_progress_bar;      // shrinks from full width as the QR's countdown runs out, hidden while no QR
static lv_obj_t *pairing_message_label;   // pairing flow's "scan this" helper text, hidden otherwise
static lv_timer_t *qr_tick_timer;      // 1 Hz countdown timer, paused while no QR
static int qr_seconds_left;

static particle_t particle_buf[PARTICLE_MAX_COUNT];
static int32_t particle_count = 0;
static bool particles_active = false;      // whether draw_particles should paint anything
static bool particle_needs_reset = false;  // true for exactly the first tick after activation
static lv_timer_t *particle_tick_timer;    // ~20 Hz simulation timer, paused while inactive
static int32_t particle_tile_w = 280, particle_tile_h = 240; // set from the real tile size on activation

/* Single source of truth for "how many pixels is one module" -- used by
 * draw_qr() itself and exposed to Swift (particle_qr_px_per_module()) so the
 * particle skeleton lines up with whatever size the solid renderer actually
 * draws at. Fits `modules` (plus the quiet zone on both sides) into the
 * tile's *shorter* dimension, floor-divided -- floor rather than round so
 * the block never overflows. Floored to a minimum of 1px/module so a
 * pathological tiny tile still draws something instead of dividing to 0. */
static int32_t qr_fit_px_per_module(int32_t modules, int32_t tile_w, int32_t tile_h)
{
    if (modules <= 0) return 0;
    int32_t short_dim = tile_w < tile_h ? tile_w : tile_h;
    int32_t px = short_dim / (modules + 2 * QR_LAYOUT_QUIET_MODULES);
    return px < 1 ? 1 : px;
}

static bool qr_generate(const char * text)
{
    uint8_t qrcode[qrcodegen_BUFFER_LEN_FOR_VERSION(QR_MAX_VERSION)];
    uint8_t tempBuffer[qrcodegen_BUFFER_LEN_FOR_VERSION(QR_MAX_VERSION)];

    // minVersion/maxVersion span QR_MIN_VERSION..QR_MAX_VERSION -- qrcodegen
    // itself picks the smallest version in that range the text (plus ECC)
    // actually fits in, so this is the entire "dynamic version" feature on
    // the encode side; module count (and everything downstream: on-screen
    // pixel size, particle skeleton layout) just follows whatever came back.
    bool ok = qrcodegen_encodeText(
        text,
        tempBuffer,
        qrcode,
        qrcodegen_Ecc_MEDIUM,
        QR_MIN_VERSION, QR_MAX_VERSION,
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

int32_t particle_qr_modules(void)
{
    return qr_modules;
}

int32_t particle_qr_px_per_module(int32_t tile_w, int32_t tile_h)
{
    return qr_fit_px_per_module(qr_modules, tile_w, tile_h);
}

/* Everything draw_qr() and draw_purpose_icon() both need to agree on pixel-
 * for-pixel -- computed once so the icon can never drift out of sync with
 * where the code it's supposed to sit next to actually lands. */
typedef struct {
    int32_t px_per_module;
    int32_t qr_px;      // code-only size (no quiet zone)
    int32_t quiet_px;
    int32_t origin_x;   // the code's own top-left corner (not the quiet zone's)
    int32_t origin_y;
} qr_layout_t;

static qr_layout_t compute_qr_layout(const lv_area_t *obj_coords)
{
    qr_layout_t L;
    int32_t obj_w = lv_area_get_width(obj_coords);
    int32_t obj_h = lv_area_get_height(obj_coords);
    L.px_per_module = qr_fit_px_per_module(qr_modules, obj_w, obj_h);
    L.qr_px = qr_modules * L.px_per_module;
    L.quiet_px = QR_LAYOUT_QUIET_MODULES * L.px_per_module;

    // Flush to the top vertically always (origin_y is exactly quiet_px down
    // from the tile's own top edge -- the white quiet-zone border's top
    // edge sits flush at y1, no extra margin above it), which leaves every
    // bit of *vertical* leftover space below the code for the progress bar
    // (qr_progress_bar) instead of splitting it above+below where the bar
    // can't use it.
    //
    // Horizontally: centered, UNLESS a purpose icon is being shown, in
    // which case flush-left instead (same reasoning as vertical, but for
    // the icon area on the right instead of the progress bar below) --
    // gating this on qr_purpose keeps the pairing/demo QRs (which never
    // set a purpose) centered exactly as before this feature existed.
    if (qr_purpose != QR_PURPOSE_NONE) {
        L.origin_x = obj_coords->x1 + L.quiet_px;
    } else {
        L.origin_x = obj_coords->x1 + (obj_w - L.qr_px) / 2;
    }
    L.origin_y = obj_coords->y1 + L.quiet_px;
    return L;
}

/* Draws the fully-detailed, solid QR (border included) at `overlay_opa`
 * (0 = skip entirely, 255 = fully opaque). Used both for the "real"
 * BLE-triggered display (always LV_OPA_COVER) and, at a Swift-ramped partial
 * opacity, as the particle effect's crossfade-in overlay. */
static void draw_qr(lv_layer_t *layer, const lv_area_t *obj_coords, lv_opa_t overlay_opa)
{
    if (overlay_opa == LV_OPA_TRANSP || qr_modules <= 0) return;

    qr_layout_t L = compute_qr_layout(obj_coords);
    int32_t px_per_module = L.px_per_module;
    int32_t qr_px = L.qr_px;
    int32_t quiet_px = L.quiet_px;
    int32_t origin_x = L.origin_x;
    int32_t origin_y = L.origin_y;

    lv_draw_rect_dsc_t bg_dsc;
    lv_draw_rect_dsc_init(&bg_dsc);
    bg_dsc.bg_color = lv_color_white();
    bg_dsc.bg_opa = overlay_opa;
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
    dsc.bg_opa = overlay_opa;
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
            module_area.x1 = origin_x + run_start * px_per_module;
            module_area.y1 = origin_y + r * px_per_module;
            module_area.x2 = module_area.x1 + run_len * px_per_module - 1;
            module_area.y2 = module_area.y1 + px_per_module - 1;

            lv_draw_rect(layer, &dsc, &module_area);
        }
    }
}

/* Small pictogram to the right of the code for ShowQR's `purpose` field
 * (see docs/ble-provisioning.md) -- a no-op unless qr_purpose is a
 * recognized value (only Receipt and MobilePay have icons so far; every
 * other purpose byte just leaves the area blank, same as QR_PURPOSE_NONE,
 * until it gets one). Reuses compute_qr_layout() so it can never disagree
 * with draw_qr() about where the code's own right edge actually is.
 * Coordinates are simple fractions of QR_PURPOSE_ICON_SIZE rather than
 * hardcoded pixels, so resizing the icon later is a one-constant change. */
static void draw_purpose_icon(lv_layer_t *layer, const lv_area_t *obj_coords)
{
    if (qr_purpose == QR_PURPOSE_NONE || qr_modules <= 0) return;

    qr_layout_t L = compute_qr_layout(obj_coords);
    int32_t obj_w = lv_area_get_width(obj_coords);
    int32_t block_right = L.origin_x + L.qr_px + L.quiet_px;   // right edge of the white quiet-zone border
    int32_t avail_w = (obj_coords->x1 + obj_w) - block_right;

    const int32_t S = QR_PURPOSE_ICON_SIZE;
    if (avail_w < S) return;   // shouldn't happen at any supported QR version, but never draw off/overlapping the code
    int32_t icon_x = block_right + (avail_w - S) / 2;               // centered in the leftover width
    int32_t icon_y = L.origin_y + L.qr_px / 2 - S / 2;               // centered on the code's own vertical middle

    lv_draw_rect_dsc_t white;
    lv_draw_rect_dsc_init(&white);
    white.bg_color = lv_color_white();
    white.bg_opa = LV_OPA_COVER;
    white.border_width = 0;

    lv_draw_rect_dsc_t black;
    lv_draw_rect_dsc_init(&black);
    black.bg_color = lv_color_black();
    black.bg_opa = LV_OPA_COVER;
    black.border_width = 0;

    switch (qr_purpose) {
    case 0x00: {   // Receipt: a white "paper" slip with a few printed-line bars
        lv_area_t paper = {
            .x1 = icon_x + S * 1 / 8, .y1 = icon_y + S * 1 / 16,
            .x2 = icon_x + S * 7 / 8, .y2 = icon_y + S * 15 / 16,
        };
        white.radius = S / 16;
        lv_draw_rect(layer, &white, &paper);

        black.radius = 0;
        for (int i = 0; i < 4; i++) {
            int32_t line_y = paper.y1 + S * 3 / 16 + i * (S * 3 / 16);
            bool shorter = (i == 3);   // "total" line, a bit shorter than the item lines above it
            lv_area_t line = {
                .x1 = paper.x1 + S * 1 / 8,
                .y1 = line_y,
                .x2 = shorter ? (paper.x1 + S * 4 / 8) : (paper.x2 - S * 1 / 8),
                .y2 = line_y + S / 16,
            };
            lv_draw_rect(layer, &black, &line);
        }
        break;
    }
    case 0x01: {   // MobilePay: a phone silhouette with a coin/payment dot on its screen
        lv_area_t phone = {
            .x1 = icon_x + S * 2 / 8, .y1 = icon_y + S * 1 / 16,
            .x2 = icon_x + S * 6 / 8, .y2 = icon_y + S * 15 / 16,
        };
        white.radius = S / 8;
        lv_draw_rect(layer, &white, &phone);

        lv_area_t screen = {
            .x1 = phone.x1 + S / 16, .y1 = phone.y1 + S * 3 / 16,
            .x2 = phone.x2 - S / 16, .y2 = phone.y2 - S * 3 / 16,
        };
        black.radius = S / 32;
        lv_draw_rect(layer, &black, &screen);

        int32_t coin_r = S / 8;
        int32_t coin_cx = (screen.x1 + screen.x2) / 2;
        int32_t coin_cy = (screen.y1 + screen.y2) / 2;
        lv_area_t coin = {
            .x1 = coin_cx - coin_r, .y1 = coin_cy - coin_r,
            .x2 = coin_cx + coin_r, .y2 = coin_cy + coin_r,
        };
        white.radius = coin_r;   // radius >= half the box's width/height draws a circle, not just a rounded square
        lv_draw_rect(layer, &white, &coin);

        int32_t home_r = S / 24;
        int32_t home_cy = phone.y2 - S / 16 - home_r;
        lv_area_t home_button = {
            .x1 = coin_cx - home_r, .y1 = home_cy - home_r,
            .x2 = coin_cx + home_r, .y2 = home_cy + home_r,
        };
        black.radius = home_r;
        lv_draw_rect(layer, &black, &home_button);
        break;
    }
    default:
        break;   // AccountPay/GiftCard/LoyaltyCard/Coupon/MembershipSignup -- no icon yet
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

        dsc.bg_color = lv_color_hsv_to_rgb(p->hue, p->sat, PARTICLE_VALUE);
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
        draw_qr(layer, &obj_coords, LV_OPA_COVER);
        draw_purpose_icon(layer, &obj_coords);   // only the "real" display ever has a purpose set -- see rgb_tile_show_qr()/_persistent()
    } else {
        if (particles_active) {
            draw_particles(layer, &obj_coords);
        }
        if (particle_qr_overlay_opa != 0) {
            draw_qr(layer, &obj_coords, particle_qr_overlay_opa);
        }
    }
}

/* Stop each effect without touching the backlight — used when the other
 * effect is about to take over and will set its own brightness right after. */
static void stop_qr(void)
{
    if (qr_tick_timer) lv_timer_pause(qr_tick_timer);
    qr_visible = false;
    if (qr_progress_bar) {
        lv_obj_add_flag(qr_progress_bar, LV_OBJ_FLAG_HIDDEN);
    }
}

static void stop_particles(void)
{
    if (particle_tick_timer) lv_timer_pause(particle_tick_timer);
    particles_active = false;
    particle_qr_overlay_opa = 0;   // don't let a stale crossfade linger into the next activation
}

static void stop_message(void)
{
    if (pairing_message_label) lv_obj_add_flag(pairing_message_label, LV_OBJ_FLAG_HIDDEN);
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
    if (qr_progress_bar) lv_bar_set_value(qr_progress_bar, qr_seconds_left, LV_ANIM_ON);
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

    // Starts full-width and shrinks from the right as qr_tick_cb counts
    // down -- lv_bar's default mode fills from the range's minimum (0) up
    // to the current value, so decreasing the value from QR_VISIBLE_SECONDS
    // to 0 recedes the filled portion back toward the left, exactly the
    // usual "depleting" progress-bar look.
    qr_progress_bar = lv_bar_create(parent);
    lv_bar_set_range(qr_progress_bar, 0, QR_VISIBLE_SECONDS);
    lv_obj_set_size(qr_progress_bar, lv_pct(80), 8);
    lv_obj_align(qr_progress_bar, LV_ALIGN_BOTTOM_MID, 0, -10);
    lv_obj_set_style_bg_color(qr_progress_bar, lv_color_hex(0x404040), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(qr_progress_bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_bg_color(qr_progress_bar, lv_color_white(), LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(qr_progress_bar, LV_OPA_COVER, LV_PART_INDICATOR);
    // Read by lv_bar_set_value(..., LV_ANIM_ON) below -- one full second so
    // each 1 Hz tick's shrink reads as continuous motion, not a once-a-second jump.
    lv_obj_set_style_anim_duration(qr_progress_bar, 1000, LV_PART_MAIN);
    lv_obj_add_flag(qr_progress_bar, LV_OBJ_FLAG_HIDDEN);

    qr_tick_timer = lv_timer_create(qr_tick_cb, 1000, NULL);
    lv_timer_pause(qr_tick_timer);

    particle_tick_timer = lv_timer_create(particle_tick_cb, PARTICLE_TICK_MS, NULL);
    lv_timer_pause(particle_tick_timer);

    // A plain wrapped/centered label, not custom-drawn like the QR/particles
    // -- used for the pairing flow's "scan this in <app>" helper screen,
    // which Swift alternates with the pairing QR (see Main.swift). 80%
    // width leaves a margin so long strings wrap instead of clipping.
    pairing_message_label = lv_label_create(parent);
    lv_obj_set_style_text_font(pairing_message_label, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_style_text_color(pairing_message_label, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_text_align(pairing_message_label, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
    lv_label_set_long_mode(pairing_message_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(pairing_message_label, lv_pct(80));
    lv_obj_center(pairing_message_label);
    lv_obj_add_flag(pairing_message_label, LV_OBJ_FLAG_HIDDEN);

    lv_obj_add_event_cb(parent, rgb_tile_draw_event_cb, LV_EVENT_DRAW_POST, NULL);

    rgb_tile_show_qr("https://ka-ching.dk");
}

/* Shared by rgb_tile_show_qr()/rgb_tile_show_qr_persistent()/
 * rgb_tile_show_qr_timed() -- `display_seconds <= 0` means "don't time
 * out" (skips arming the progress bar/timer, so the code stays up until
 * something else explicitly takes the tile back -- see
 * docs/ble-provisioning.md for why the pairing QR needs this), otherwise
 * the countdown runs for exactly that many seconds instead of a single
 * fixed duration. The caller MUST already hold the LVGL port lock
 * (lvgl_port_lock), because this mutates qr_buf/qr_modules which draw_qr
 * reads on the LVGL task. */
static void show_qr_internal(const char *text, int32_t display_seconds)
{
    if (!qr_generate(text)) {
        return; /* text too long for the fixed QR version; keep the previous code */
    }
    stop_particles();  // mutually exclusive with the QR code on this tile
    stop_message();

    qr_visible = true;
    bsp_display_set_brightness(QR_BACKLIGHT);   // wake the backlight for the QR

    if (display_seconds <= 0) {
        if (qr_tick_timer) lv_timer_pause(qr_tick_timer);
        if (qr_progress_bar) lv_obj_add_flag(qr_progress_bar, LV_OBJ_FLAG_HIDDEN);
    } else {
        qr_seconds_left = display_seconds;
        if (qr_progress_bar) {
            if (obj_rgb_tile) {
                // As wide as the QR *code* itself, quiet zone excluded --
                // including the quiet zone (an earlier version of this) was
                // mathematically flush with the white border but read as
                // visually too wide. Centering a narrower width within the
                // same tile still lands exactly on the code's own left edge
                // (origin_x in draw_qr is centered the same way), no
                // separate offset needed.
                int32_t tile_w = lv_obj_get_width(obj_rgb_tile);
                int32_t tile_h = lv_obj_get_height(obj_rgb_tile);
                int32_t px_per_module = qr_fit_px_per_module(qr_modules, tile_w, tile_h);
                int32_t code_width = qr_modules * px_per_module;
                lv_obj_set_width(qr_progress_bar, code_width);
            }
            // Range varies per call now (display_seconds is caller-chosen,
            // not always QR_VISIBLE_SECONDS), so it's set fresh every time
            // rather than once at init.
            lv_bar_set_range(qr_progress_bar, 0, display_seconds);
            // LV_ANIM_OFF: snap to full immediately rather than animating
            // in from wherever the bar last was (e.g. nearly empty, if this
            // QR replaced one that had almost timed out).
            lv_bar_set_value(qr_progress_bar, qr_seconds_left, LV_ANIM_OFF);
            lv_obj_remove_flag(qr_progress_bar, LV_OBJ_FLAG_HIDDEN);
        }
        if (qr_tick_timer) {
            lv_timer_reset(qr_tick_timer);    // full 1 s before the first decrement
            lv_timer_resume(qr_tick_timer);
        }
    }

    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
}

void rgb_tile_show_qr(const char *text)
{
    qr_purpose = QR_PURPOSE_NONE;   // no purpose concept on this path -- stay centered, no icon
    show_qr_internal(text, QR_VISIBLE_SECONDS);
}

void rgb_tile_show_qr_persistent(const char *text)
{
    qr_purpose = QR_PURPOSE_NONE;   // ditto -- the pairing QR never carries a purpose
    show_qr_internal(text, 0);
}

void rgb_tile_show_qr_timed(const char *text, int32_t display_seconds, uint8_t purpose)
{
    qr_purpose = purpose;   // draw_qr()/draw_purpose_icon() left-align + draw the icon whenever this isn't QR_PURPOSE_NONE
    show_qr_internal(text, display_seconds);
}

/* A plain, persistent, centered/wrapped text screen -- the pairing flow's
 * "scan this in <app>" helper text, which Swift alternates with the
 * pairing QR (see Main.swift). Mutually exclusive with the QR and particle
 * effect, same as those are with each other. The caller MUST already hold
 * the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_message(const char *text)
{
    stop_qr();
    stop_particles();

    bsp_display_set_brightness(QR_BACKLIGHT);   // same level as the QR screen it alternates with -- no brightness flicker
    if (pairing_message_label) {
        lv_label_set_text(pairing_message_label, text);
        lv_obj_remove_flag(pairing_message_label, LV_OBJ_FLAG_HIDDEN);
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
 * A no-op if particles are already active (e.g. a repeated DemoEffects
 * command) -- otherwise this would force Swift to reset its running effect
 * (particle_needs_reset) and restart the crossfade/timer state, which reads
 * as an unwanted restart rather than "yes, still doing that". The caller
 * MUST already hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_particles(void)
{
    if (particles_active) return;

    stop_qr();  // mutually exclusive with the QR code on this tile
    stop_message();

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

/* The command interface's Idle: blank the tile and turn the backlight off,
 * regardless of whichever of QR/particles/message was showing -- unlike
 * hide_qr()/rgb_tile_hide_particles(), which only ever needed to stop their
 * own mode since nothing else could have been active at the same time. */
void rgb_tile_idle(void)
{
    stop_qr();
    stop_particles();
    stop_message();
    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
    bsp_display_set_brightness(0);
}

/* (Re)generate the solid QR for the particle effect's crossfade overlay.
 * Shares qr_buf/qr_modules with the "real" BLE-triggered display -- safe,
 * since the two are mutually exclusive (only one of qr_visible / the
 * particle effect is ever active) and each resets the other's leftovers when
 * it takes over (see stop_qr()/stop_particles()). If encoding fails, the
 * overlay just keeps showing whatever it last had. */
void particle_qr_prepare(const char *text)
{
    qr_generate(text);
}

void particle_qr_set_overlay_opacity(uint8_t opa)
{
    // Called from within particle_effect_tick(), i.e. from inside
    // particle_tick_cb() -- which already invalidates the tile once it
    // regains control, so no need to do it again here.
    particle_qr_overlay_opa = opa;

    // Ride the backlight down to QR-presentation brightness in step with the
    // solid QR fading in over the particles, and back up to full as it fades
    // back out -- driven by the same opacity Swift is already ramping tick by
    // tick (see qrCrossfade in ParticleEffects.swift), so the brightness
    // change tracks the visual crossfade exactly instead of needing its own
    // timer. opa 0 (pure particles) -> PARTICLE_BACKLIGHT; opa 255 (fully
    // solid QR) -> QR_BACKLIGHT.
    int brightness = PARTICLE_BACKLIGHT - (PARTICLE_BACKLIGHT - QR_BACKLIGHT) * opa / 255;
    bsp_display_set_brightness(brightness);
}
