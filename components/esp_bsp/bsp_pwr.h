#ifndef __BSP_PWR_H__
#define __BSP_PWR_H__


#define PWR_KEY_PIN GPIO_NUM_18
#define BAT_EN_PIN  GPIO_NUM_15

#ifdef __cplusplus
extern "C" {
#endif

void bsp_pwr_init(void);

#ifdef __cplusplus
}
#endif



#endif