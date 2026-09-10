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

#define EXAMPLE_DISPLAY_ROTATION 270

#if EXAMPLE_DISPLAY_ROTATION == 90 || EXAMPLE_DISPLAY_ROTATION == 270
#define EXAMPLE_LCD_H_RES (280)
#define EXAMPLE_LCD_V_RES (240)
#else
#define EXAMPLE_LCD_H_RES (240)
#define EXAMPLE_LCD_V_RES (280)
#endif

#define EXAMPLE_LCD_DRAW_BUFF_HEIGHT (50)
#define EXAMPLE_LCD_DRAW_BUFF_DOUBLE (1)

static char *TAG = "factory";

/* LCD IO and panel */
static esp_lcd_panel_io_handle_t io_handle = NULL;
static esp_lcd_panel_handle_t panel_handle = NULL;

/* LVGL display and touch */
static lv_display_t *lvgl_disp = NULL;

static esp_err_t app_lvgl_init(void);


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

    bsp_battery_init();
    bsp_display_init(&io_handle, &panel_handle, EXAMPLE_LCD_H_RES * EXAMPLE_LCD_DRAW_BUFF_HEIGHT);
    ESP_ERROR_CHECK(app_lvgl_init());

    bsp_display_brightness_init();
    bsp_display_set_brightness(40);

    if (lvgl_port_lock(0))
    {
        lvgl_ui_init();
        lvgl_port_unlock();
    }
}

static esp_err_t app_lvgl_init(void)
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
        .buffer_size = EXAMPLE_LCD_H_RES * EXAMPLE_LCD_DRAW_BUFF_HEIGHT,
        .double_buffer = EXAMPLE_LCD_DRAW_BUFF_DOUBLE,
        .hres = EXAMPLE_LCD_H_RES,
        .vres = EXAMPLE_LCD_V_RES,
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
#if EXAMPLE_DISPLAY_ROTATION == 90
    disp_cfg.rotation.swap_xy = true;
    disp_cfg.rotation.mirror_x = true;
    disp_cfg.rotation.mirror_y = false;
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 20, 0));
#elif EXAMPLE_DISPLAY_ROTATION == 180
    disp_cfg.rotation.swap_xy = false;
    disp_cfg.rotation.mirror_x = true;
    disp_cfg.rotation.mirror_y = true;
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 0, 20));
#elif EXAMPLE_DISPLAY_ROTATION == 270
    disp_cfg.rotation.swap_xy = true;
    disp_cfg.rotation.mirror_x = false;
    disp_cfg.rotation.mirror_y = true;
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 20, 0));
#else
    ESP_ERROR_CHECK(esp_lcd_panel_set_gap(panel_handle, 0, 20));
#endif
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
