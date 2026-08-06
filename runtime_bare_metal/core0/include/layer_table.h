#ifndef __LAYER_TABLE_H__
#define __LAYER_TABLE_H__

#include <stdbool.h>
#include <stdint.h>

struct layer_config_t {
    /* Common registers. */
    uint8_t     common_mode;
    uint8_t     common_cin;
    bool        common_has_residual;
    bool        common_pool_en;
    bool        common_pool_type;

    /* CNN registers. */
    uint16_t    cnn_max_inner;
    uint8_t     cnn_max_co;
    uint8_t     cnn_max_x;
    uint8_t     cnn_max_y;
    uint8_t     cnn_max_tile_x;
    uint8_t     cnn_max_tile_y;
    uint8_t     cnn_shift;
    int8_t      cnn_relu6_val;
    uint8_t     cnn_gap_shift;
    uint16_t    cnn_mult;

    /* DMA registers. */
    uint8_t     dma_cout;
    uint16_t    dma_img_w;
    uint16_t    dma_img_h;
    uint8_t     dma_tile_w;
    uint8_t     dma_tile_h;
    uint8_t     dma_num_tile_x;
    uint8_t     dma_num_tile_y;
    uint8_t     dma_weight_words;
    uint8_t     dma_bias_words;
    uint32_t    dma_addr_w;
    uint32_t    dma_addr_in;
    uint32_t    dma_addr_out;
    uint32_t    dma_addr_res;
    uint32_t    dma_addr_bias;
};

#endif