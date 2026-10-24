#include "lcd_driver.h"

#include "xiicps.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "sleep.h"

#define CHECK_STATUS( status, is_valid ) \
	do{ 								 \
		if( ( status ) != ( is_valid ) ) \
			return ( status ); 			 \
	} while( 0 )

#define LCD_RS			0x01U
#define LCD_EN			0x04U
#define LCD_BACKLIGHT	0x08U

#define LCD_CMD_CLEAR			0x01U
#define LCD_CMD_ENTRY_MODE		0x06U
#define LCD_CMD_DISPLAY_OFF		0x08U
#define LCD_CMD_DISPLAY_ON		0x0CU
#define LCD_CMD_FUNCTION_SET	0x28U
#define LCD_CMD_SET_DDRAM		0x80U
#define LCD_INIT_8BIT			0x03U
#define LCD_INIT_4BIT			0x02U

#define LCD_I2C_BUS_TIMEOUT		1000U

static XIicPs Iic_Instance;

static int i2c_wait_bus_free( void ) {
	for( uint32_t counter = 0; counter < LCD_I2C_BUS_TIMEOUT; counter++ ) {
		if( !XIicPs_BusIsBusy( &Iic_Instance ) )
			return XST_SUCCESS;
		usleep( 10 );
	}

	return XST_FAILURE;
}

static int i2c_send( uint8_t address, uint8_t value ) {
	int status = XIicPs_MasterSendPolled( &Iic_Instance, &value, 1, address );

	int bus_status = i2c_wait_bus_free( );
	CHECK_STATUS( status, XST_SUCCESS );

	return bus_status;
}

int lcd_i2c_init( void ) {
	XIicPs_Config* Iic_Config = XIicPs_LookupConfig( XPAR_XIICPS_0_DEVICE_ID );
	if( Iic_Config == NULL )
		return XST_FAILURE;

	if( XIicPs_CfgInitialize( &Iic_Instance, Iic_Config, Iic_Config -> BaseAddress ) != XST_SUCCESS )
		return XST_FAILURE;

	if( XIicPs_SetSClk( &Iic_Instance, LCD_I2C_SCLK_HZ ) != XST_SUCCESS )
		return XST_FAILURE;

	return i2c_wait_bus_free( );
}

int lcd_i2c_scan( void ) {
	int devices = 0;

	for( uint8_t address = 0x08; address <= 0x77; address++ ) {
		if( i2c_send( address, 0x00U ) == XST_SUCCESS ) {
			xil_printf( "I2C Device at 0x%02x\n", address );
			devices++;
		}
	}

	xil_printf( "Total Devices Found = %d\n", devices );

	return devices;
}

int lcd_i2c_write( uint8_t value ) {
	return i2c_send( LCD_I2C_ADDRESS, value );
}

static int lcd_pulse_enable( uint8_t data ) {
	int status = lcd_i2c_write( data | LCD_EN );
	CHECK_STATUS( status, XST_SUCCESS );

	return lcd_i2c_write( data & (uint8_t) ~LCD_EN );
}

static inline int lcd_write_nibble( uint8_t nibble, uint8_t rs ) {
	return lcd_pulse_enable( (uint8_t) ( nibble << 4 ) | rs | LCD_BACKLIGHT );
}

static int lcd_write_byte( uint8_t value, uint8_t rs ) {
	int status = lcd_write_nibble( value >> 4, rs );
	CHECK_STATUS( status, XST_SUCCESS );

	return lcd_write_nibble( value & 0x0FU, rs );
}

static inline int lcd_command( uint8_t command ) {
	return lcd_write_byte( command, 0 );
}

static inline int lcd_data( uint8_t character ) {
	return lcd_write_byte( character, LCD_RS );
}

int lcd_clear( void ) {
	int status = lcd_command( LCD_CMD_CLEAR );
	CHECK_STATUS( status, XST_SUCCESS );

	usleep( 2000 );
	return XST_SUCCESS;
}

int lcd_init( void ) {
	usleep( 50000 );
	int status = lcd_i2c_write( LCD_BACKLIGHT );
	CHECK_STATUS( status, XST_SUCCESS );

	status = lcd_write_nibble( LCD_INIT_8BIT, 0 );
	CHECK_STATUS( status, XST_SUCCESS );
	usleep( 4500 );

	status = lcd_write_nibble( LCD_INIT_8BIT, 0 );
	CHECK_STATUS( status, XST_SUCCESS );
	usleep( 150 );

	status = lcd_write_nibble( LCD_INIT_8BIT, 0 );
	CHECK_STATUS( status, XST_SUCCESS );
	usleep( 150 );

	status = lcd_write_nibble( LCD_INIT_4BIT, 0 );
	CHECK_STATUS( status, XST_SUCCESS );
	usleep( 150 );

	status = lcd_command( LCD_CMD_FUNCTION_SET );
	CHECK_STATUS( status, XST_SUCCESS );

	status = lcd_command( LCD_CMD_DISPLAY_OFF );
	CHECK_STATUS( status, XST_SUCCESS );

	status = lcd_clear( );
	CHECK_STATUS( status, XST_SUCCESS );

	status = lcd_command( LCD_CMD_ENTRY_MODE );
	CHECK_STATUS( status, XST_SUCCESS );

	status = lcd_command( LCD_CMD_DISPLAY_ON );
	CHECK_STATUS( status, XST_SUCCESS );

	return XST_SUCCESS;
}

int lcd_set_cursor( uint8_t row, uint8_t col ) {
	static const uint8_t rows[ 4 ]  = { 0x00, 0x40, 0x14, 0x54 };

	return lcd_command( (uint8_t) ( LCD_CMD_SET_DDRAM | ( rows[ row ] + col ) ) );
}

int lcd_print( const char* text ) {
	int status;
	while( *text != '\0' ) {
		status = lcd_data( (uint8_t) *text++ );
		CHECK_STATUS( status, XST_SUCCESS );
	}

	return XST_SUCCESS;
}
