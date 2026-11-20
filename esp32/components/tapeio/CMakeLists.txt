# Tape signal I/O on the ESP32: RMT transmitter (-> Spectrum EAR) and a GPIO
# edge-timestamp receiver (<- Spectrum MIC). Needs ESP-IDF 5.3+ (RMT simple encoder).
idf_component_register(SRCS "tapeio_tx.c" "tapeio_rx.c"
                       INCLUDE_DIRS "include"
                       REQUIRES tape esp_driver_rmt esp_driver_gpio esp_rom)
