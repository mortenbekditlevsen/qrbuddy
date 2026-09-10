#ifndef __RGB_TILE_H__
#define __RGB_TILE_H__

#include "../lvgl_ui.h"


#ifdef __cplusplus
extern "C" {
#endif

void rgb_tile_init(lv_obj_t *parent);

/* Regenerate the QR code from `text` and repaint the tile.
 * Caller must hold the LVGL port lock (lvgl_port_lock). */
void rgb_tile_show_qr(const char *text);


#ifdef __cplusplus
}
#endif



#endif