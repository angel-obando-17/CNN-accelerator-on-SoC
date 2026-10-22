#ifndef __LCD_DRIVER_H__
#define __LCD_DRIVER_H__

#include <stdint.h>

#define LCD_I2C_ADDRESS	0x27U
#define LCD_I2C_SCLK_HZ	100000U

int lcd_i2c_init( void );
int lcd_i2c_scan( void );
int lcd_i2c_write( uint8_t value );
int lcd_clear( void );
int lcd_init( void );
int lcd_set_cursor( uint8_t row, uint8_t col );
int lcd_print( const char* text );

#endif
