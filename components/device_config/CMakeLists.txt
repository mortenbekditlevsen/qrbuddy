idf_component_register(SRCS "device_config.c"
                    INCLUDE_DIRS "."
                    REQUIRES "nvs_flash" "esp_timer" "esp_system")
