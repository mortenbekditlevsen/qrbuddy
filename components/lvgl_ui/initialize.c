#include <stdio.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_check.h"

#include "nvs_flash.h"

#include "esp_lvgl_port.h"

#include "bsp_display.h"
#include "bsp_i2c.h"
#include "bsp_battery.h"

#include "tileview/rgb_tile.h"
#include "lvgl_ui.h"

#include "bsp_pwr.h"
#include "bsp_i2c.h"
#include "bsp_qmi8658.h"

#include "device_config.h"

// The panel's native (rotation-0) resolution is 240 wide x 280 tall;
// 90/270 present it to LVGL as landscape 280x240 instead. Which of these
// applies is now a runtime choice (device_config_get_orientation(), see
// initialize()) instead of the compile-time EXAMPLE_DISPLAY_ROTATION this
// used to be -- both bsp_display_init()'s buffer sizing and
// app_lvgl_init()'s disp_cfg need the resolved h/v-res, so initialize()
// computes them once and passes them to both.
#define EXAMPLE_LCD_DRAW_BUFF_HEIGHT (50)
#define EXAMPLE_LCD_DRAW_BUFF_DOUBLE (1)

static char *TAG = "factory";

/* LCD IO and panel */
static esp_lcd_panel_io_handle_t io_handle = NULL;
static esp_lcd_panel_handle_t panel_handle = NULL;

/* LVGL display and touch */
static lv_display_t *lvgl_disp = NULL;

static esp_err_t app_lvgl_init(uint8_t orientation, int32_t lcd_h_res, int32_t lcd_v_res);


void show_qr(const char * text) {
    /* Called from another task (the Swift main loop), so take the LVGL port lock
     * before touching any LVGL state. lvgl_port_lock(0) blocks until acquired. */
    if (lvgl_port_lock(0)) {
        rgb_tile_show_qr(text);
        lvgl_port_unlock();
    } else {
        ESP_LOGW(TAG, "show_qr: could not acquire LVGL lock");
    }
}

void show_qr_persistent(const char * text) {
    if (lvgl_port_lock(0)) {
        rgb_tile_show_qr_persistent(text);
        lvgl_port_unlock();
    } else {
        ESP_LOGW(TAG, "show_qr_persistent: could not acquire LVGL lock");
    }
}

void show_qr_timed(const char * text, int32_t display_seconds, uint8_t purpose) {
    if (lvgl_port_lock(0)) {
        rgb_tile_show_qr_timed(text, display_seconds, purpose);
        lvgl_port_unlock();
    } else {
        ESP_LOGW(TAG, "show_qr_timed: could not acquire LVGL lock");
    }
}

void show_message_persistent(const char * text) {
    if (lvgl_port_lock(0)) {
        rgb_tile_show_message(text);
        lvgl_port_unlock();
    } else {
        ESP_LOGW(TAG, "show_message_persistent: could not acquire LVGL lock");
    }
}

void show_particles(void) {
    if (lvgl_port_lock(0)) {
        rgb_tile_show_particles();
        lvgl_port_unlock();
    } else {
        ESP_LOGW(TAG, "show_particles: could not acquire LVGL lock");
    }
}

void enter_idle(void) {
    if (lvgl_port_lock(0)) {
        rgb_tile_idle();
        lvgl_port_unlock();
    } else {
        ESP_LOGW(TAG, "enter_idle: could not acquire LVGL lock");
    }
}

/* Sticky across calls: bsp_qmi8658_read_data() only actually has a fresh
 * sample some of the time (gated by the sensor's own data-ready status
 * bits), and returns false the rest -- if we reported "not upside-down" on
 * every such call instead of holding the last known reading, a boot-time
 * "held upside-down for N seconds" poll (see Main.swift) could flicker and
 * never accumulate a continuous streak. */
static bool s_last_upside_down = false;

bool qmi8658_is_upside_down(void)
{
    qmi8658_data_t data;
    if (bsp_qmi8658_read_data(&data)) {
        // Verified against a real unit: resting upside-down settles to
        // roughly +8199 raw (~+1g at this driver's fixed +-4g range), so
        // face-up must settle to roughly -8192 -- the opposite of this
        // function's first guess. +4096 (half of 1g's raw magnitude) sits
        // well clear of noise/tilt near the on-edge case rather than right
        // at the boundary.
        s_last_upside_down = data.acc_z > 4096;
    }
    return s_last_upside_down;
}

void initialize(void)
{
    bsp_pwr_init();
    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Persisted orientation (device_config_*, NVS-backed) -- see
    // docs/ble-provisioning.md's SetConfig command. Resolved once, here,
    // and fed into both bsp_display_init()'s buffer sizing and
    // app_lvgl_init()'s disp_cfg below.
    uint8_t orientation = device_config_get_orientation();
    int32_t lcd_h_res, lcd_v_res;
    if (orientation == DEVICE_ORIENTATION_90 || orientation == DEVICE_ORIENTATION_270) {
        lcd_h_res = 280;
        lcd_v_res = 240;
    } else {
        lcd_h_res = 240;
        lcd_v_res = 280;
    }

    bsp_battery_init();
    bsp_display_init(&io_handle, &panel_handle, lcd_h_res * EXAMPLE_LCD_DRAW_BUFF_HEIGHT);
    ESP_ERROR_CHECK(app_lvgl_init(orientation, lcd_h_res, lcd_v_res));

    // Accelerometer -- currently only used for the "held upside-down at
    // boot" pairing-reset gesture (see Main.swift / qmi8658_is_upside_down()).
    i2c_master_bus_handle_t i2c_bus_handle = bsp_i2c_init();
    bsp_qmi8658_init(i2c_bus_handle);

    bsp_display_brightness_init();
    bsp_display_set_brightness(40);

    if (lvgl_port_lock(0))
    {
        lvgl_ui_init();
        rgb_tile_show_particles();  // must run inside the lock, same as show_qr()
        lvgl_port_unlock();
    }
}

static esp_err_t app_lvgl_init(uint8_t orientation, int32_t lcd_h_res, int32_t lcd_v_res)
{
    /* Initialize LVGL */
    const lvgl_port_cfg_t lvgl_cfg = {
        .task_priority = 4,       /* LVGL task priority */
        .task_stack = 4096,       /* LVGL task stack size */
        .task_affinity = -1,      /* LVGL task pinned to core (-1 is no affinity) */
        .task_max_sleep_ms = 500, /* Maximum sleep in LVGL task */
        .timer_period_ms = 5      /* LVGL timer tick period in ms */
    };
    ESP_RETURN_ON_ERROR(lvgl_port_init(&lvgl_cfg), TAG, "LVGL port initialization failed");

    /* Add LCD screen */
    ESP_LOGD(TAG, "Add LCD screen");
    lvgl_port_display_cfg_t disp_cfg = {
        .io_handle = io_handle,
        .panel_handle = panel_handle,
        .buffer_size = lcd_h_res * EXAMPLE_LCD_DRAW_BUFF_HEIGHT,
        .double_buffer = EXAMPLE_LCD_DRAW_BUFF_DOUBLE,
        .hres = lcd_h_res,
        .vres = lcd_v_res,
        .monochrome = false,
        /* Rotation values must be same as used in esp_lcd for initial settings of the screen */
        .rotation = {
            .swap_xy = false,
            .mirror_x = false,
            .mirror_y = false,
        },
        .flags = {
            .buff_dma = true,
#if LVGL_VERSION_MAJOR >= 9
            .swap_bytes = true,
#endif
        }};
    // Same four cases as before, just a runtime switch on the persisted
    // orientation (device_config_get_orientation(), resolved by the
    // caller) instead of a compile-time EXAMPLE_DISPLAY_ROTATION.
    switch (orientation) {
    case DEVICE_ORIENTATION_90:
        disp_cfg.rotation.swap_xy = true;
        disp_cfg.rotation.mirror_x = true;
        disp_cfg.rotation.mirror_y = false;
        ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 20, 0));
        break;
    case DEVICE_ORIENTATION_180:
        disp_cfg.rotation.swap_xy = false;
        disp_cfg.rotation.mirror_x = true;
        disp_cfg.rotation.mirror_y = true;
        ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 0, 20));
        break;
    case DEVICE_ORIENTATION_270:
        disp_cfg.rotation.swap_xy = true;
        disp_cfg.rotation.mirror_x = false;
        disp_cfg.rotation.mirror_y = true;
        ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 20, 0));
        break;
    default:   // DEVICE_ORIENTATION_0
        ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 0, 20));
        break;
    }
    lvgl_disp = lvgl_port_add_disp(&disp_cfg);

    // static lv_indev_drv_t indev_drv = {};
    // lv_indev_drv_init(&indev_drv);
    // indev_drv.disp = lvgl_disp;
    // indev_drv.type = LV_INDEV_TYPE_POINTER;
    // indev_drv.read_cb = lvgl_port_touchpad_read;
    // indev_drv.user_data = touch_handle;
    // lvgl_touch_indev = lv_indev_drv_register(&indev_drv);

    return ESP_OK;
}
