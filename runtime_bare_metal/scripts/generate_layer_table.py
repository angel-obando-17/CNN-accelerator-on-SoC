import json, zipfile

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