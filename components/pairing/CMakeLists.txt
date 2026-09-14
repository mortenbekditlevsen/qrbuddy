idf_component_register(SRCS "pairing.c"
                    INCLUDE_DIRS "."
                    REQUIRES "mbedtls" "nvs_flash" "esp_hw_support" "esp_timer")
