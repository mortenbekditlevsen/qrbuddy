#ifndef __INITIALIZE_H__
#define __INITIALIZE_H__

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void initialize(void);
void show_qr(const char * text);
void show_qr_persistent(const char * text);   // see rgb_tile_show_qr_persistent()
void show_qr_timed(const char * text, int32_t display_seconds, uint8_t purpose);   // see rgb_tile_show_qr_timed()
void show_message_persistent(const char * text);   // see rgb_tile_show_message()
void show_particles(void);                    // resume the idle particle effect (e.g. after pairing completes)
void enter_idle(void);                        // command interface's Idle: backlight off, blank the tile
void apply_qr_brightness(void);               // re-applies a just-changed QRBrightness config live, if a QR is on screen

/* Cached QMI8658 orientation, refreshed each call -- see qmi8658_is_upside_down()
 * in initialize.c for the exact criterion. Never blocks/waits; a boot-time
 * "held upside-down for N seconds" gesture (see Main.swift) is Swift's own
 * polling loop around this, not something this function does itself. */
bool qmi8658_is_upside_down(void);


#ifdef __cplusplus
} /* extern "C" */
#endif

#endif