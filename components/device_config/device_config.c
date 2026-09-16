#include "device_config.h"

#include "nvs.h"
#include "esp_timer.h"
#include "esp_system.h"

#define NVS_NAMESPACE          "qrb_cfg"
#define NVS_KEY_ORIENTATION    "orient"
#define NVS_KEY_QR_BRIGHTNESS  "qr_bright"

uint8_t device_config_get_orientation(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return DEVICE_ORIENTATION_DEFAULT;
    }

    uint8_t value = DEVICE_ORIENTATION_DEFAULT;
    esp_err_t err = nvs_get_u8(h, NVS_KEY_ORIENTATION, &value);
    nvs_close(h);

    return (err == ESP_OK) ? value : DEVICE_ORIENTATION_DEFAULT;
}

bool device_config_set_orientation(uint8_t orientation)
{
    if (orientation > DEVICE_ORIENTATION_270) return false;

    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) return false;

    esp_err_t err = nvs_set_u8(h, NVS_KEY_ORIENTATION, orientation);
    if (err == ESP_OK) nvs_commit(h);
    nvs_close(h);

    return err == ESP_OK;
}

uint8_t device_config_get_qr_brightness(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return DEVICE_QR_BRIGHTNESS_DEFAULT;
    }

    uint8_t value = DEVICE_QR_BRIGHTNESS_DEFAULT;
    esp_err_t err = nvs_get_u8(h, NVS_KEY_QR_BRIGHTNESS, &value);
    nvs_close(h);

    return (err == ESP_OK) ? value : DEVICE_QR_BRIGHTNESS_DEFAULT;
}

bool device_config_set_qr_brightness(uint8_t percent)
{
    if (percent > 100) return false;

    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) return false;

    esp_err_t err = nvs_set_u8(h, NVS_KEY_QR_BRIGHTNESS, percent);
    if (err == ESP_OK) nvs_commit(h);
    nvs_close(h);

    return err == ESP_OK;
}

static void restart_timer_cb(void *arg)
{
    (void) arg;
    esp_restart();
}

void device_config_schedule_restart(void)
{
    const esp_timer_create_args_t args = {
        .callback = restart_timer_cb,
        .name = "cfg_restart",
    };
    esp_timer_handle_t timer;
    if (esp_timer_create(&args, &timer) == ESP_OK) {
        esp_timer_start_once(timer, 300 * 1000);   // 300ms, in microseconds
    }
}
