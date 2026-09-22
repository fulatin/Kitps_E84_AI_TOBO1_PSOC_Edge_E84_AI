idf_component_register(SRCS
    "../Core/main.c"
    "../Core/system.c"
    "../Communication/frame.c"
    "../Communication/protocol.c"
    "../Communication/network_manager.c"
    "../Drivers/gpio/gpio.c"
    "../Drivers/uart/uart.c"
    "../Drivers/pwm/pwm.c"
    "../Drivers/ov2640/camera_io.c"
    "../Drivers/ov2640/ov2640.c"
    "../Vision/capture.c"
    "../Vision/preprocess.c"
    "../Vision/feature.c"
    "../Vision/roi/roi_select.c"
    "../Vision/roi/gradient.c"
    "../algorithm/filter.c"
    "../algorithm/predict.c"
    "../algorithm/track_algorithm.c"
    "../tracking/tracker.c"
    "../tracking/closed_loop.c"
    "../tracking/relock.c"
    "../tracking/assist_pos.c"
    "../data_logger/logger.c"
    "../data_logger/error_rate.c"
    "../data_logger/performance.c"
    INCLUDE_DIRS ".."
    REQUIRES driver esp_camera esp_timer esp_http_server esp_wifi esp_netif nvs_flash heap freertos log lwip hal mdns
    # ESP-IDF 5.3+ 把 driver 拆分成独立组件；6.x 起 driver/gpio.h、driver/uart.h、
    # driver/i2c.h、driver/ledc.h、hal/uart_types.h 不再由 driver/hal 转发，需显式声明。
    REQUIRES esp_driver_gpio esp_driver_uart esp_driver_i2c esp_driver_ledc esp_hal_uart
)

