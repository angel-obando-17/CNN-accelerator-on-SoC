import os, re, json

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

def check_inputs( geometry : list[ dict ], params : dict[ str, dict ] ) -> None:
    assert  len( geometry ) == 28, f"esperaba 28 capas, salieron {len( geometry )}"
    assert geometry[ 0 ][ "cin" ] == 3, f"conv1 deberia tener Cin = 3, tiene {geometry[ 0 ][ 'cin' ]}"
    assert geometry[ -1 ][ "name" ] == "conv_last", f"la ultima capa no es conv_last"
    assert "gap" in params, f"falta la fila 'gap' en el JSON de cuantización"
    assert [ layer[ "name" ] for layer in geometry ] == [ name for name in params if name != "gap" ], \
        f"los nombres del .keras y del JSON de cuantizacion no coinciden"

def read_header_fields( header_path : str ) -> list[ str ]:
    fields = [ ]

    pattern = r"^\s*(\w+)\s+(\w+)\s*;"

    with open( header_path, "r" ) as file:
        for line in file:
            matched = re.match( pattern, line )
            if matched is not None:
                fields.append( matched.group( 2 ) )

    return fields

def read_num_layers( header_path : str ) -> int:

    pattern = r"#define\s+NUM_LAYERS\s+(\d+)"

    with open( header_path, "r" ) as file:
        read_file = file.read( )
        matched = re.search( pattern, read_file )
        assert matched is not None, \
            f"Hace falta la macro en el header file, NUM_LAYERS en {header_path}"
        return int( matched.group( 1 ) )

def check_header( table : list[ dict ], header_path : str ) -> None:
    header_fields = set( read_header_fields( header_path ) )
    generator_fields = set( table[ 0 ] ) - { "name" }
    not_match_declared = header_fields - generator_fields
    not_match_issued = generator_fields - header_fields

    assert read_num_layers( header_path ) == len( table ), \
        f"Header file declara {read_num_layers( header_path )} y el generador arma {len( table )} capas."
    assert not not_match_declared, \
        f"Campos no emitidos que el header esta esperando, campos faltantes: {not_match_declared}"
    assert not not_match_issued, \
        f"Campos emitidos que el header no esta esperando, campos sobrantes: {not_match_issued}"

    for i, row in enumerate( table ):
        assert set( row ) == set( table[ 0 ] ), \
            f"Index = {i}, Name = {row[ 'name' ]}, { set( row ) ^ set( table[ 0 ] ) }"