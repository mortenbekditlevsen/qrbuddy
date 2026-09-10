#include "bsp_pwr.h"

#include "iot_button.h"
#include "button_gpio.h"
#include "driver/gpio.h"
#include "bsp_display.h"
#include "esp_log.h"

static char *TAG = "bsp_pwr";

static void button_event_cb(void *arg, void *data)
{
    button_event_t event = iot_button_get_event((button_handle_t)arg);
    ESP_LOGI(TAG, "PWR KEY %s", iot_button_get_event_str(event));

    static uint8_t display_brightness_last = 0;


    if (event == BUTTON_SINGLE_CLICK)
    {
        if (display_brightness_last)
        {
            bsp_display_set_brightness(display_brightness_last);
            display_brightness_last = 0;
        }
        else 
        {
            display_brightness_last = bsp_display_get_brightness();
            bsp_display_set_brightness(0);
        }
    }
    // else if (event == BUTTON_LONG_PRESS_START)
    // { 
    //     gpio_set_level(BAT_EN_PIN, 0);
    // }
}

void bsp_pwr_task(void *arg)
{
    gpio_set_direction(BAT_EN_PIN, GPIO_MODE_OUTPUT);
    gpio_set_level(BAT_EN_PIN, 1);

    gpio_set_direction(PWR_KEY_PIN, GPIO_MODE_INPUT);
    while (gpio_get_level(PWR_KEY_PIN) == 0)
    {
        vTaskDelay(100 / portTICK_PERIOD_MS);
    }
    button_config_t btn_cfg = {};
    button_gpio_config_t btn_gpio_cfg = {};
    btn_gpio_cfg.gpio_num = PWR_KEY_PIN;
    btn_gpio_cfg.active_level = 0;
    static button_handle_t btn = NULL;
    ESP_ERROR_CHECK(iot_button_new_gpio_device(&btn_cfg, &btn_gpio_cfg, &btn));
    iot_button_register_cb(btn, BUTTON_SINGLE_CLICK, NULL, button_event_cb, NULL);
    // iot_button_register_cb(btn, BUTTON_LONG_PRESS_START, NULL, button_event_cb, NULL);
    // iot_button_register_cb(btn, BUTTON_LONG_PRESS_HOLD, NULL, button_event_cb, NULL);
    // iot_button_register_cb(btn, BUTTON_LONG_PRESS_UP, NULL, button_event_cb, NULL);
    // iot_button_register_cb(btn, BUTTON_PRESS_END, NULL, button_event_cb, NULL);
    vTaskDelete(NULL);
    // while (1)
    // {
    //     vTaskDelay(100 / portTICK_PERIOD_MS);
    // }
}

void bsp_pwr_init(void)
{
    xTaskCreate(bsp_pwr_task, "bsp_pwr_task", 2048, NULL, 0, NULL);
}