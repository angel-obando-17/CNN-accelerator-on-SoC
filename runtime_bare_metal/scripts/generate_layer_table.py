import os, json, zipfile

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

def check_limits( table : list[ dict ], geometry : list[ dict ] ) -> None:
    for row, layer in zip( table, geometry ):
        name = row[ "name" ]
        cin_groups  = ( row[ "common_cin" ] + 15 ) // 16
        cout_groups = row[ "cnn_max_co" ] + 1
        tile_w_out  = row[ "cnn_max_x" ] + 1
        tile_h_out  = row[ "cnn_max_y" ] + 1
        tile_w_in   = row[ "dma_tile_w" ]
        tile_h_in   = row[ "dma_tile_h" ]

        # Asserts.
        assert row[ "dma_weight_words" ] <= 256, f"{name}: weight_words={row[ 'dma_weight_words' ]} > 256 (weight_buf)"
        assert row[ "dma_bias_words" ]   <= 16,  f"{name}: bias_words={row[ 'dma_bias_words' ]} > 16 (bias_buf)"
        assert row[ "common_cin" ]       <= 64,  f"{name}: Cin={row[ 'common_cin' ]} > 64"
        assert row[ "dma_cout" ]         <= 64,  f"{name}: Cout={row[ 'dma_cout' ]} > 64"
        assert tile_w_out <= 128, f"{name}: tile_w_out={tile_w_out} > 128 (max_x, 7 bits)"
        assert tile_h_out <= 8,   f"{name}: tile_h_out={tile_h_out} > 8 (max_y, 3 bits)"
        assert tile_w_in  <= 255, f"{name}: tile_w_in={tile_w_in} > 255 (DMA_TILE_W, 8 bits)"
        assert tile_h_in  <= 15,  f"{name}: tile_h_in={tile_h_in} > 15 (DMA_TILE_H, 4 bits)"
        assert row[ "dma_num_tile_x" ] <= 2,  f"{name}: num_tile_x={row[ 'dma_num_tile_x' ]} > 2 (max_tile_x, 1 bit)"
        assert row[ "dma_num_tile_y" ] <= 32, f"{name}: num_tile_y={row[ 'dma_num_tile_y' ]} > 32 (max_tile_y, 5 bits)"
        assert row[ "dma_img_w" ] <= 511, f"{name}: img_w={row[ 'dma_img_w' ]} > 511 (DMA_IMG_W, 9 bits)"
        assert ( tile_w_in + 2 ) * cin_groups * ( tile_h_in + 2 ) <= 8192, \
            f"{name}: IFBuffer necesita {( tile_w_in + 2 ) * cin_groups * ( tile_h_in + 2 )} de 8192 palabras"
        assert tile_w_out * tile_h_out * cout_groups <= 4096, \
            f"{name}: OFBuffer necesita {tile_w_out * tile_h_out * cout_groups} de 4096 palabras"

def check_consistency( 
        table      : list[ dict ],
        geometry   : list[ dict ],
        input_base : int = 0x02000000    
    ) -> None:

    assert table[ 0 ][ "dma_addr_in" ] == input_base, "conv1 no lee el frame de entrada."

    out = { row[ "dma_addr_out" ] : layer for row, layer in zip( table, geometry ) }

    for i, ( row, layer ) in enumerate( zip( table, geometry ) ):
        name = layer[ "name" ]

        assert ( row[ "cnn_max_x" ] + 1 ) * row[ "dma_num_tile_x" ] == layer[ "res_out" ], \
            f"{name}: los tiles de salida no cubren res_out={layer[ 'res_out' ]}"
        assert ( row[ "cnn_max_y" ] + 1 ) * row[ "dma_num_tile_y" ] == layer[ "res_out" ], \
            f"{name}: las filas de salida no cubren res_out={layer[ 'res_out' ]}"
        assert row[ "dma_tile_w" ] * row[ "dma_num_tile_x" ] == layer[ "res_in" ], \
            f"{name}: los tiles de entrada no cubren res_in={layer[ 'res_in' ]}"
        assert row[ "dma_tile_h" ] * row[ "dma_num_tile_y" ] == layer[ "res_in" ], \
            f"{name}: las filas de entrada no cubren res_in={layer[ 'res_in' ]}"
        
        for field in ( "dma_addr_w", "dma_addr_bias", "dma_addr_in", "dma_addr_out", "dma_addr_res" ):
            assert row[ field ] % 16 == 0, f"{name}: {field}=0x{row[ field ]:08X} no esta alineada a 16 B"

        if i > 0:
            assert row[ "dma_addr_in" ] == table[ i - 1 ][ "dma_addr_out" ], \
                f"{name}: no lee la salida de {table[ i - 1 ][ 'name' ]}"

        if row[ "common_has_residual" ]:
            source = out[ row[ "dma_addr_res" ] ]
            assert source[ "res_out" ] == layer[ "res_out" ] and source[ "cout" ] == layer[ "cout" ], \
                f"{name}: el residual {source[ 'name' ]} es {source[ 'res_out' ]}x{source[ 'cout' ]}, la capa es {layer[ 'res_out' ]}x{layer[ 'cout' ]}"
            assert row[ "dma_addr_res" ] < row[ "dma_addr_out" ], \
                f"{name}: el residual 0x{row[ 'dma_addr_res' ]:08X} no fue escrito antes que la salida 0x{row[ 'dma_addr_out' ]:08X}"
            
        assert not ( layer[ "pool_en" ] and not layer[ "pool_type" ] ), \
            f"{name}: MaxPool no soportado por el generador (habria que halvear res_out)"

def load_weights_manifest( json_path : str ) -> dict:
    with open( json_path ) as file:
        return json.load( file )

def check_against_manifest( 
        table        : list[ dict ],
        manifest     : dict,
        keras_path   : str,
        weights_base : int = 0x01000000,
        bias_base    : int = 0x01010000    
    ) -> None:

    assert manifest[ "modelo" ] == os.path.basename( keras_path ), \
        f"los pesos se exportaron de {manifest[ 'modelo' ]} pero la geometria sale de {os.path.basename( keras_path )}"

    layers = { row[ "layer" ] : row for row in manifest[ "capas" ] }

    assert [ row[ "name" ] for row in table ] == list( layers ), \
        "las capas del manifiesto no son las mismas, o no estan en el mismo orden"

    for row in table:
        name = row[ "name" ]
        mode = layers[ name ]

        assert row[ "common_cin" ] == mode[ "cin" ], f"{name}: Cin={row[ 'common_cin' ]} pero el manifiesto dice {mode[ 'cin' ]}"
        assert row[ "dma_cout" ] == mode[ "cout" ],  f"{name}: Cout={row[ 'dma_cout' ]} pero el manifiesto dice {mode[ 'cout' ]}"
        assert row[ "cnn_max_co" ] + 1 == mode[ "num_co" ], \
            f"{name}: num_co={row[ 'cnn_max_co' ] + 1} pero el manifiesto dice {mode[ 'num_co' ]}"
        assert row[ "dma_weight_words" ] == mode[ "weight_words" ], \
            f"{name}: weight_words={row[ 'dma_weight_words' ]} pero el .bin trae {mode[ 'weight_words' ]}"
        assert row[ "dma_bias_words" ] == mode[ "bias_words" ], \
            f"{name}: bias_words={row[ 'dma_bias_words' ]} pero el .bin trae {mode[ 'bias_words' ]}"
        assert row[ "dma_addr_w" ] - weights_base == mode[ "weight_offset" ], \
            f"{name}: offset de pesos {row[ 'dma_addr_w' ] - weights_base} pero el .bin lo tiene en {mode[ 'weight_offset' ]}"
        assert row[ "dma_addr_bias" ] - bias_base == mode[ "bias_offset" ], \
            f"{name}: offset de bias {row[ 'dma_addr_bias' ] - bias_base} pero el .bin lo tiene en {mode[ 'bias_offset' ]}"

    total_weight = sum( row[ "dma_weight_words" ] for row in table ) * 16
    total_bias = sum( row[ "dma_bias_words" ] for row in table ) * 16

    assert total_weight == manifest[ "bytes_pesos" ], f"pesos: la tabla cubre {total_weight} B y el archivo tiene {manifest[ 'bytes_pesos' ]} B"
    assert total_bias == manifest[ "bytes_bias" ],  f"bias: la tabla cubre {total_bias} B y el archivo tiene {manifest[ 'bytes_bias' ]} B"

# def main( ) -> None:

if __name__ == "__main__":
    keras_path = "CNN/results/hsv/model_MobileNetV2_HSV_256x256.keras"
    geometry = load_model_geometry( keras_path )

    assert len( geometry ) == 28, f"esperaba 28 capas, salieron {len( geometry )}"
    assert geometry[ 0 ][ "cin" ] == 3
    assert geometry[ -1 ][ "name" ] == "conv_last" and geometry[ -1 ][ "res_out" ] == 16

    for capa in geometry:
        print( capa )

    params = load_quant_params( "CNN/results/ptq_simple_v2/layer_quant_params.json" )

    assert len( params ) == 29, f"esperaba 29 filas, salieron {len( params )}"
    assert "gap" in params

    nombres_geom = [ c[ "name" ] for c in geometry ]
    nombres_json = [ k for k in params if k != "gap" ]
    assert nombres_geom == nombres_json, "los nombres del .keras y del JSON no coinciden"

    print( params[ "conv1" ][ "mult" ], params[ "conv1" ][ "shift" ], len( params[ "conv1" ][ "bias" ] ) )
    print( "gap shift:", params[ "gap" ][ "shift" ] )

    tabla = map_register( geometry, params )
    print( tabla[ 0 ] )
    print( tabla[ 3 ] )

    tabla = map_addresses( tabla, geometry )
    check_limits( tabla, geometry )
    print( "los 12 limites de hardware: OK en las 28 capas" )
    check_consistency( tabla, geometry )
    print( "invariantes entre capas: OK" )
    manifest = load_weights_manifest( "CNN/results/ptq_simple_v2/weights_manifest.json" )
    check_against_manifest( tabla, manifest, keras_path )
    print( "contra el manifiesto de pesos: OK" )