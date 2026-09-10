#include "rgb_tile.h"

#include "qrcodegen.h"
#include "bsp_display.h"

#define QR_PX_PER_MODULE 3
#define QR_QUIET_MODULES 4   // spec-recommended quiet zone (white border) on every side
#define QR_MAX_MODULES   qrcodegen_BUFFER_LEN_FOR_VERSION(40) // generous upper bound
#define QR_VISIBLE_SECONDS 60  // how long the QR code stays on screen
#define QR_BACKLIGHT     20    // backlight % while a QR code is on screen

static uint8_t qr_buf[177][177]; // 177 = max modules at version 40
static int qr_modules = 0;
static bool qr_visible = false;        // whether qr_draw_event_cb should paint anything

static lv_obj_t *obj_rgb_tile;
static lv_obj_t *qr_countdown_label;   // "seconds left" label, hidden while no QR
static lv_timer_t *qr_tick_timer;      // 1 Hz countdown timer, paused while no QR
static int qr_seconds_left;

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
static void qr_draw_event_cb(lv_event_t * e)
{
    if (lv_event_get_code(e) != LV_EVENT_DRAW_POST) return;
    if (!qr_visible || qr_modules <= 0) return;

    lv_obj_t * obj = lv_event_get_target(e);
    lv_layer_t * layer = lv_event_get_layer(e);

    lv_area_t obj_coords;
    lv_obj_get_coords(obj, &obj_coords);

    int32_t obj_w = lv_area_get_width(&obj_coords);
    int32_t qr_px = qr_modules * QR_PX_PER_MODULE;
    int32_t quiet_px = QR_QUIET_MODULES * QR_PX_PER_MODULE;

    // Center horizontally; sit near the top so the countdown label has room below.
    int32_t origin_x = obj_coords.x1 + (obj_w - qr_px) / 2;
    int32_t origin_y = obj_coords.y1 + quiet_px;

    lv_draw_rect_dsc_t bg_dsc;
    lv_draw_rect_dsc_init(&bg_dsc);
    bg_dsc.bg_color = lv_color_white();
    bg_dsc.bg_opa = LV_OPA_COVER;
    bg_dsc.radius = 0;
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

/* Take the QR code off screen: stop the countdown, blank the tile, backlight off. */
static void hide_qr(void)
{
    lv_timer_pause(qr_tick_timer);
    qr_visible = false;
    if (qr_countdown_label) {
        lv_obj_add_flag(qr_countdown_label, LV_OBJ_FLAG_HIDDEN);
    }
    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
    bsp_display_set_brightness(0);
}

/* 1 Hz while a QR code is showing. Runs on the LVGL task (holding the port
 * lock), same as qr_draw_event_cb. */
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

void rgb_tile_init(lv_obj_t *parent)
{
    obj_rgb_tile = parent;
    lv_obj_set_style_bg_color(obj_rgb_tile, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(obj_rgb_tile, LV_OPA_COVER, LV_PART_MAIN);

    qr_countdown_label = lv_label_create(parent);
    lv_obj_set_style_text_font(qr_countdown_label, &lv_font_montserrat_20, LV_PART_MAIN);
    lv_obj_set_style_text_color(qr_countdown_label, lv_color_white(), LV_PART_MAIN);
    lv_obj_align(qr_countdown_label, LV_ALIGN_BOTTOM_MID, 0, -8);
    lv_obj_add_flag(qr_countdown_label, LV_OBJ_FLAG_HIDDEN);

    qr_tick_timer = lv_timer_create(qr_tick_cb, 1000, NULL);
    lv_timer_pause(qr_tick_timer);

    lv_obj_add_event_cb(parent, qr_draw_event_cb, LV_EVENT_DRAW_POST, NULL);

    rgb_tile_show_qr("https://ka-ching.dk");
}

/* Regenerate the QR code, repaint the tile, and (re)start the countdown.
 * The caller MUST already hold the LVGL port lock (lvgl_port_lock), because this
 * mutates qr_buf/qr_modules which qr_draw_event_cb reads on the LVGL task. */
void rgb_tile_show_qr(const char *text)
{
    if (!qr_generate(text)) {
        return; /* text too long for the fixed QR version; keep the previous code */
    }
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
