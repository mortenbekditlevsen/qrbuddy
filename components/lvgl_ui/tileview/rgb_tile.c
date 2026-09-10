#include "rgb_tile.h"

lv_timer_t *rgb_tile_timer;

#define BG_COLOR_MAX 3
uint32_t bg_color_arr[BG_COLOR_MAX] = {0x000000, 0x000000, 0x000000};
uint16_t bg_color_index = 1;

#include "qrcodegen.h"

#define QR_PX_PER_MODULE 3
#define QR_MAX_MODULES   qrcodegen_BUFFER_LEN_FOR_VERSION(40) // generous upper bound

static uint8_t qr_buf[177][177]; // 177 = max modules at version 40
static int qr_modules = 0;

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

    lv_obj_t * obj = lv_event_get_target(e);
    lv_layer_t * layer = lv_event_get_layer(e);

    lv_area_t obj_coords;
    lv_obj_get_coords(obj, &obj_coords);

    int32_t obj_w = lv_area_get_width(&obj_coords);
    int32_t obj_h = lv_area_get_height(&obj_coords);
    int32_t qr_px = qr_modules * QR_PX_PER_MODULE;

    // Center the QR code's origin within obj
    int32_t origin_x = obj_coords.x1 + (obj_w - qr_px) / 2;
    int32_t origin_y = obj_coords.y1 + (obj_h - qr_px) / 2;

    // White background, sized exactly to the QR code
    lv_draw_rect_dsc_t bg_dsc;
    lv_draw_rect_dsc_init(&bg_dsc);
    bg_dsc.bg_color = lv_color_white();
    bg_dsc.bg_opa = LV_OPA_COVER;
    bg_dsc.radius = 0;
    bg_dsc.border_width = 0;

    lv_area_t bg_area;
    bg_area.x1 = origin_x;
    bg_area.y1 = origin_y;
    bg_area.x2 = origin_x + qr_px - 1;
    bg_area.y2 = origin_y + qr_px - 1;

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
static lv_obj_t *obj_rgb_tile;
void lv_timer_show_color_tile_cb(lv_timer_t *timer)
{
    lv_obj_set_style_bg_color(obj_rgb_tile, lv_color_hex(bg_color_arr[bg_color_index]), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(obj_rgb_tile, LV_OPA_COVER, LV_PART_MAIN);

    if (++bg_color_index >= BG_COLOR_MAX)
    {
        bg_color_index = 0;
    }
}
void rgb_tile_init(lv_obj_t *parent)
{
    obj_rgb_tile = parent;
    lv_obj_set_style_bg_color(obj_rgb_tile, lv_color_hex(bg_color_arr[0]), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(obj_rgb_tile, LV_OPA_COVER, LV_PART_MAIN);
    rgb_tile_timer = lv_timer_create(lv_timer_show_color_tile_cb, 2000, NULL);

    qr_generate("https://firebasestorage.googleapis.com/v0/b/ka-ching-base-staging.appspot.com/o/r%2F-LQ8SQzDKW9pej0jK7cE%2FE377645E%2FC9385D73.html?alt=media");
    lv_obj_add_event_cb(parent, qr_draw_event_cb, LV_EVENT_DRAW_POST, NULL);
}

/* Regenerate the QR code and repaint the tile.
 * The caller MUST already hold the LVGL port lock (lvgl_port_lock), because this
 * mutates qr_buf/qr_modules which qr_draw_event_cb reads on the LVGL task. */
void rgb_tile_show_qr(const char *text)
{
    if (!qr_generate(text)) {
        return; /* text too long for the fixed QR version; keep the previous code */
    }
    if (obj_rgb_tile) {
        lv_obj_invalidate(obj_rgb_tile);
    }
}

