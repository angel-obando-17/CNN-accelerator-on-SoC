#ifndef __SW_INFERENCE_H__
#define __SW_INFERENCE_H__

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "layer_table.h"

void sw_inference_run( const struct layer_config_t* table, const int8_t* frame, int8_t* gap_out );

#endif
