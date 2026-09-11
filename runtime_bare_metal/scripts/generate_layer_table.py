import os, json, zipfile
import checks

def load_model_geometry( keras_path : str, input_size : int=256 ) -> list[ dict ]:
    config_json = zipfile.ZipFile( keras_path ).read( "config.json" )
    cfg = json.loads( config_json )

    layers = cfg[ "config" ][ "layers" ]

    block_with_residual = set( )
    # Primera pasada.
    for layer in layers:
        if layer[ "class_name" ] == "Add":
            name = layer[ "config" ][ "name" ]
            block_with_residual.add( name.rsplit( "_", 1 )[ 0 ] )

    cin = 3
    res = input_size

    geometry = [ ]
    # Segunda pasada.
    for layer in layers:
        if layer[ "class_name" ] in ( "Conv2D", "DepthwiseConv2D" ):
            cfg_layer = layer[ "config" ]
            stride = cfg_layer[ "strides" ][ 0 ]
            name = cfg_layer[ "name" ]
            has_residual = name.endswith( "_pw" ) and name.rsplit( "_", 1 )[ 0 ] in block_with_residual
            res_in = res
            is_last = ( name == "conv_last" )
            pool_en   = is_last
            pool_type = is_last

            if layer[ "class_name" ] == "DepthwiseConv2D":
                mode = 1 
            elif layer[ "class_name" ] == "Conv2D" and cfg_layer[ "kernel_size" ] == [ 3, 3 ]:
                mode = 0
            else:
                mode = 2

            cout = cfg_layer.get( "filters", cin )
            res_out = res // stride

            geometry.append( {
                "name"         : name,
                "mode"         : mode,
                "cin"          : cin,
                "cout"         : cout,
                "res_in"       : res_in,
                "res_out"      : res_out,
                "stride"       : stride,
                "has_residual" : has_residual,
                "pool_en"      : pool_en,
                "pool_type"    : pool_type
            } )

            cin = cout
            res = res_out

    return geometry

def load_quant_params( json_path : str ) -> dict[ str, dict ]:
    with open( json_path ) as file:
        rows = json.load( file )
        return { row[ "layer" ] : row for row in rows }

def map_register( geometry : list[ dict ], params : dict[ str, dict ] ) -> list[ dict ]:
    table = [ ]
    for layer in geometry:
        param = params[ layer[ "name" ] ]
        num_co = ( layer[ "cout" ] + 15 ) // 16 

        if layer[ "mode" ] == 0:
            max_inner = layer[ "cin" ] * 9
        elif layer[ "mode" ] == 1:
            max_inner = 9
        else:
            max_inner = layer[ "cin" ]

        downsample = layer[ "stride" ] == 2 or ( layer[ "pool_en" ] and not layer[ "pool_type" ] )
        tile_h_out = 4 if downsample else 8
        num_tile_x = 2 if layer[ "name" ] == "conv1" else 1
        tile_w_out = layer[ "res_out" ] // num_tile_x
        num_tile_y = layer[ "res_out" ] // tile_h_out
        factor = 2 if downsample else 1

        row = {
            "name"                : layer[ "name" ],
            # Common registers.
            "common_mode"         : layer[ "mode" ],
            "common_cin"          : layer[ "cin" ],
            "common_has_residual" : layer[ "has_residual" ],
            "common_pool_en"      : layer[ "pool_en" ],
            "common_stride_en"    : layer[ "stride" ] == 2,
            "common_relu_en"      : param[ "relu_en" ],
            "common_pool_type"    : layer[ "pool_type" ],
            # CNN registers.
            "cnn_max_inner"       : max_inner,
            "cnn_max_co"          : num_co - 1,
            "cnn_max_x"           : tile_w_out - 1,
            "cnn_max_y"           : tile_h_out - 1,
            "cnn_max_tile_x"      : num_tile_x - 1,
            "cnn_max_tile_y"      : num_tile_y - 1,
            "cnn_shift"           : param[ "shift" ],
            "cnn_relu6_val"       : param[ "relu6_val" ],
            "cnn_gap_shift"       : params[ "gap" ][ "shift" ] if layer[ "name" ] == "conv_last" else 0,
            "cnn_mult"            : param[ "mult" ],
            # DMA registers.
            "dma_cout"            : layer[ "cout" ],
            "dma_img_w"           : layer[ "res_in" ],
            "dma_img_h"           : layer[ "res_in" ],
            "dma_tile_w"          : tile_w_out * factor,
            "dma_tile_h"          : tile_h_out * factor,
            "dma_num_tile_x"      : num_tile_x,
            "dma_num_tile_y"      : num_tile_y,
            "dma_weight_words"    : num_co * max_inner,
            "dma_bias_words"      : 4 * num_co,
        }

        table.append( row )
    return table

def map_addresses(
        table        : list[ dict ],
        geometry     : list[ dict ],
        weights_base : int = 0x01000000,
        bias_base    : int = 0x01010000,
        input_base   : int = 0x02000000,
        act_base     : int = 0x02100000        
    ) -> list[ dict ]:

    weight_offset = 0
    bias_offset = 0
    act_offset = 0
    prev_out = input_base
    prev_pw_out = 0

    for row, layer in zip( table, geometry ):
        row[ "dma_addr_w" ] = weights_base + weight_offset
        row[ "dma_addr_in" ] = prev_out
        row[ "dma_addr_out" ] = act_base + act_offset
        row[ "dma_addr_res" ] = prev_pw_out if row[ "common_has_residual" ] else 0
        row[ "dma_addr_bias" ] = bias_base + bias_offset

        bytes_per_pixel = ( ( layer[ "cout" ] + 15 ) // 16 ) * 16

        if layer[ "pool_en" ] and layer[ "pool_type" ]:
            size = bytes_per_pixel
        else:
            size = ( layer[ "res_out" ] ** 2 ) * bytes_per_pixel

        weight_offset += row[ "dma_weight_words" ] * 16
        bias_offset += row[ "dma_bias_words" ] * 16
        act_offset += size
        prev_out = row[ "dma_addr_out" ]

        if layer[ "name" ].endswith( "_pw" ):
            prev_pw_out = row[ "dma_addr_out" ]

    return table

def format_value( key : str, value : int | bool ) -> str:
    if isinstance( value, bool ):
        return "true" if value else "false"
    elif key.startswith( "dma_addr" ):
        return f"0x{value:08X}"
    else:
        return str( value )
    
def emit_layer_table( table : list[ dict ], keras_path : str, out_path : str ) -> None:
    with open( out_path, "w" ) as file:
        file.write( 
f"""/*
 * layer_table.c - Configuration of the {len( table )} CNN layers.
 *
 * AUTOMATICALLY GENERATED FILE - DO NOT EDIT MANUALLY.
 * Any changes made here will be lost during the next generator run.
 *
 * Generator: runtime_bare_metal/scripts/generate_layer_table.py
 * Model:     {os.path.basename( keras_path )}
 *
 * To change a value, correct the generator and run it again.
 *
 *     Author: Angel Obando
 *
 */

""" )
        file.write( '#include "layer_table.h"\n' )
        file.write( "\n" )
        file.write( "const struct layer_config_t layer_table[ NUM_LAYERS ] = {\n" )
        for i, row in enumerate( table ):
            file.write( f"    /* [{i:2}] {row[ 'name' ]} */\n" )
            file.write( "    {\n" )
            for key, value in row.items( ):
                if key == "name": continue
                file.write( f"        .{key:<20} = {format_value( key, value )},\n" )
            file.write( "    },\n" )
        file.write( "};\n" )

def main(
        keras_path    : str = "CNN/results/hsv/model_MobileNetV2_HSV_256x256.keras",
        params_path   : str = "CNN/results/ptq_simple_v2/layer_quant_params.json",
        manifest_path : str = "CNN/results/ptq_simple_v2/weights_manifest.json"
    ) -> None:

    repo_root = os.path.dirname( os.path.dirname( os.path.dirname( __file__ ) ) )

    keras_path = os.path.join( repo_root, keras_path )
    params_path = os.path.join( repo_root, params_path )
    manifest_path = os.path.join( repo_root, manifest_path )

    geometry = load_model_geometry( keras_path )
    params = load_quant_params( params_path )
    manifest = checks.load_weights_manifest( manifest_path )

    checks.check_inputs( geometry, params )

    table = map_register( geometry, params )
    table = map_addresses( table, geometry )

    checks.check_limits( table, geometry )
    checks.check_consistency( table, geometry )
    checks.check_against_manifest( table, manifest, keras_path )

    header_path = "runtime_bare_metal/core0/include/layer_table.h"
    header_path = os.path.join( repo_root, header_path )

    out_path = "runtime_bare_metal/core0/src/layer_table.c"
    out_path = os.path.join( repo_root, out_path )

    checks.check_header( table, header_path )

    print( f"{len( table )} capas x {len( table[ 0 ] )} campos: todos los chequeos OK." )

    emit_layer_table( table, keras_path, out_path )


if __name__ == "__main__":
    main( )