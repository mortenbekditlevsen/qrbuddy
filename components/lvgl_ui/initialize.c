#include <stdio.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_check.h"

#include "nvs_flash.h"

#include "esp_lvgl_port.h"

#include "bsp_display.h"
#include "bsp_i2c.h"
#include "bsp_wifi.h" 
#include "bsp_battery.h"
#include "bsp_qmi8658.h"
#include "bsp_pcf85063.h"

#include "iot_button.h"
#include "button_gpio.h"
#include "tileview/rgb_tile.h"
#include "demos/lv_demos.h"
#include "bsp_es8311.h"
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

SemaphoreHandle_t touch_int_BinarySemaphore;
SemaphoreHandle_t es8311_recording_BinarySemaphore;
SemaphoreHandle_t es8311_stop_BinarySemaphore;

static esp_err_t app_lvgl_init(void);
static void button_init(void);

void es8311_test_task(void *arg)
{
    const int limit_size_max = 1000;
    uint8_t data[limit_size_max];
    while (1)
    {
        if (xSemaphoreTake(es8311_recording_BinarySemaphore, portMAX_DELAY) == pdTRUE)
        {
            bsp_es8311_set_out_volume(70.0);
            bsp_es8311_set_in_volume(50.0);
            while (1)
            {
                bsp_es8311_recording(data, limit_size_max);
                bsp_es8311_playing(data, limit_size_max);
                if (xSemaphoreTake(es8311_stop_BinarySemaphore, 0) == pdTRUE)
                {
                    bsp_es8311_set_out_volume(0.0);
                    bsp_es8311_set_in_volume(0.0);
                    break;
                }
            }
        }
    }
}

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
    i2c_master_bus_handle_t i2c_bus_handle;
    bsp_pwr_init();
    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    i2c_bus_handle = bsp_i2c_init();

    bsp_battery_init();
    bsp_qmi8658_init(i2c_bus_handle);
    bsp_pcf85063_init(i2c_bus_handle);
    bsp_es8311_init(i2c_bus_handle);

    bsp_wifi_init("WSTEST", "waveshare0755");
    bsp_display_init(&io_handle, &panel_handle, EXAMPLE_LCD_H_RES * EXAMPLE_LCD_DRAW_BUFF_HEIGHT);
    ESP_ERROR_CHECK(app_lvgl_init());

    bsp_display_brightness_init();
    bsp_display_set_brightness(100);

    touch_int_BinarySemaphore = xSemaphoreCreateBinary();
    es8311_recording_BinarySemaphore = xSemaphoreCreateBinary();
    es8311_stop_BinarySemaphore = xSemaphoreCreateBinary();

    xTaskCreate(es8311_test_task, "es8311_test_task", 4096, NULL, 5, NULL);
    button_init();

    if (lvgl_port_lock(0))
    {
        // lv_demo_benchmark();
        // lv_demo_music();
        // lv_demo_widgets();
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

static void button_event_cb(void *arg, void *data)
{
    button_event_t event = iot_button_get_event((button_handle_t)arg);
    ESP_LOGI(TAG, "BOOT KEY %s", iot_button_get_event_str(event));
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;
    static uint32_t col_id = 0;
    static bool long_press_flag = false;

    if (event == BUTTON_SINGLE_CLICK)
    {

        if (++col_id > 3)
        {
            col_id = 0;
        }
        lv_obj_set_tile_id(tileview, col_id, 0, LV_ANIM_ON);
    }
    else if (event == BUTTON_LONG_PRESS_START)
    {
        long_press_flag = true;
        xSemaphoreGiveFromISR(es8311_recording_BinarySemaphore, &xHigherPriorityTaskWoken);
    }
    else if (event == BUTTON_PRESS_END)
    {
        if (long_press_flag)
        {
            long_press_flag = false;
            xSemaphoreGiveFromISR(es8311_stop_BinarySemaphore, &xHigherPriorityTaskWoken);
        }
    }
}

static void button_init(void)
{
    button_config_t btn_cfg = {};
    button_gpio_config_t btn_gpio_cfg = {};
    btn_gpio_cfg.gpio_num = GPIO_NUM_9;
    btn_gpio_cfg.active_level = 0;
    static button_handle_t btn = NULL;
    ESP_ERROR_CHECK(iot_button_new_gpio_device(&btn_cfg, &btn_gpio_cfg, &btn));
    iot_button_register_cb(btn, BUTTON_SINGLE_CLICK, NULL, button_event_cb, NULL);
    iot_button_register_cb(btn, BUTTON_LONG_PRESS_START, NULL, button_event_cb, NULL);
    // iot_button_register_cb(btn, BUTTON_LONG_PRESS_HOLD, NULL, button_event_cb, NULL);
    // iot_button_register_cb(btn, BUTTON_LONG_PRESS_UP, NULL, button_event_cb, NULL);
    iot_button_register_cb(btn, BUTTON_PRESS_END, NULL, button_event_cb, NULL);
}
