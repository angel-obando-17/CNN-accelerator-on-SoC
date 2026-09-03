library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench de integracion para el soporte de stride real ( ver
-- accelerator/cnn_accelerator/docs/stride_support_gap.md, Parte 4, y los
-- 4 puntos de implementacion: registros / wiring / addr_generator.vhd /
-- generalizacion de pool_en en ddr_addr_gen.vhd+dma_fsm.vhd ). Mismo
-- patron que tb_cnn_top.vhd / tb_cnn_top_bias.vhd / tb_cnn_top_hardcore.vhd
-- ( acelerador + DMA reales contra DDR falsa bidireccional ), pero con una
-- red mas densa/pesada: mas capas encadenadas con datos REALES propagados,
-- 2 tiles horizontales con stride, y una capa de regresion explicita con
-- stride_en=0 para confirmar que nada de lo ya verificado se rompio.
--
--   CASO A: Conv3x3 + stride_en=1, tile de salida 2x2, UN solo tile.
--           Activacion VARIA por FILA de imagen (no uniforme) -- elegido
--           a proposito para que el resultado sea DISTINTO entre la formula
--           correcta ( row = 2*y_counter + sig_ky ) y una formula con bug
--           que "olvide" escalar por stride ( row = y_counter + sig_ky ).
--           Con activacion uniforme ambas formulas coinciden por casualidad
--           en este tile tan chico -- ver el analisis completo mas abajo.
--   CASO B: DW3x3 + stride_en=1, mismo tile 2x2, misma idea pero variando
--           por COLUMNA en vez de por fila -- cubre la mitad del calculo
--           ( col = 2*x_counter + sig_kx ) que el Caso A no ejercita, y de
--           paso confirma que DW3x3 (addr_w por canal, no tocado en este
--           cambio) sigue funcionando bien combinado con stride.
--   CASO C: Conv3x3 + stride_en=1, DOS tiles horizontales ( TILE_WAIT ).
--           Ejercita el supuesto de diseno central de la Opcion 2 ( ver
--           "Hallazgo clave 1" en stride_support_gap.md ): el tile que pide
--           el DMA ( DMA_TILE_W = doble del tile de salida, con halo ) y el
--           tile que itera el acelerador ( MAX_X/MAX_Y, tamano de salida )
--           son registros independientes. Confirma ademas que tile1 lee su
--           halo IZQUIERDO como pixel real vecino (no cero, a diferencia
--           del halo del borde verdadero de la imagen) y que el OFM de
--           ambos tiles queda escrito CONTIGUO en la imagen de salida
--           ( sin hueco ni superposicion ) -- eso es lo que confirma que
--           tile_w_out (mitad de tile_w, generalizacion de pool_en) quedo
--           bien generalizado en ddr_addr_gen.vhd.
--   CASO D: cadena real de 2 capas ( Conv3x3 stride=2 -> DW3x3 stride=1 ),
--           igual patron que MobileNetV2 real ( ej. conv1 -> primera capa
--           del siguiente bloque ): la Capa 2 consume la salida REAL
--           ( ya a mitad de resolucion ) de la Capa 1, no datos por
--           defecto. Confirma que una capa con stride puede alimentar
--           directamente a una capa SIN stride, sin ningun paso intermedio.
--   CASO E: regresion explicita. Mismo caso y misma matematica que el
--           CASO K de tb_cnn_top_hardcore.vhd ( PW1x1 + Residual, bias que
--           deja el valor cerca del techo + residual que fuerza saturacion
--           en add_unit ), reubicado a direcciones nuevas y con
--           stride_en=0 escrito EXPLICITAMENTE en los dos lados ( acelerador
--           y DMA ). El objetivo es confirmar que, con stride_en en 0, la
--           generalizacion "pool_en OR stride_en" y el nuevo `if` de
--           addr_generator.vhd no cambiaron en NADA el comportamiento ya
--           verificado -- mismo resultado exacto (satura a 0x7F) que antes
--           de tocar una sola linea de este cambio.
--
-- NOTA IMPORTANTE: stride_en es un registro que persiste entre capas
-- ( no hay reset entre "run_layer_and_ack" ) -- por eso CADA caso escribe
-- stride_en explicitamente en los dos lados ( REG_STRIDE_EN offset 0x44 del
-- acelerador, DMA_STRIDE_EN offset 0x54 del DMA ), incluso cuando el valor
-- que necesita es el mismo que dejo el caso anterior. Nunca se asume el
-- valor por defecto de reset ni el valor que dejo el caso previo.
--
-- HALLAZGO DE DISENO (no es bug, descubierto al dimensionar el Caso A):
-- con stride_en='1', el DMA sigue fetcheando el mismo halo SIMETRICO de
-- siempre ( tile_h(core) + 2 filas, una arriba y una abajo -- ver
-- row_words_padded en ddr_addr_gen.vhd, sin tocar por este cambio ), pero
-- la formula de addr_generator.vhd ( row = 2*y_counter + sig_ky ) solo
-- necesita halo arriba -- la ultima fila fetcheada (indice tile_h_pad-1)
-- nunca se lee para ningun y_counter/sig_ky posible. Mismo razonamiento
-- aplica a la columna derecha. Es inofensivo (esa fila/columna de mas
-- simplemente no se usa, y en el borde real de la imagen igual se rellena
-- con cero por el mecanismo de zero-fill existente), pero es un desperdicio
-- de ancho de banda de 1 fila y 1 columna por tile con stride que no se
-- corrigio en este cambio -- queda documentado por si se quiere optimizar
-- despues.
--
-- Direcciones: bloques de 0x4000 bytes por caso, mismo esquema que
-- tb_cnn_top_hardcore.vhd, a partir de 0x40000 (para no chocar con ningun
-- otro testbench). +0x0000=W, +0x1000=IN, +0x2000=OUT, +0x3000=RES,
-- +0x3800=BIAS. Todos los valores se calcularon para division EXACTA por
-- 2**shift (o directamente shift=0 cuando no hace falta).

entity tb_cnn_top_stride is
end tb_cnn_top_stride;

architecture Behavioral of tb_cnn_top_stride is

    constant CLK_PERIOD : time := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '0'; -- Low Active.

    -- AXI-Lite #1 ( acelerador ).
    signal axi_awaddr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal axi_awvalid : std_logic := '0';
    signal axi_awready : std_logic;
    signal axi_wdata   : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal axi_wstrb   : std_logic_vector(  3 downto 0 ) := ( others => '1' );
    signal axi_wvalid  : std_logic := '0';
    signal axi_wready  : std_logic;
    signal axi_bresp   : std_logic_vector(  1 downto 0 );
    signal axi_bvalid  : std_logic;
    signal axi_bready  : std_logic := '0';
    signal axi_araddr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal axi_arvalid : std_logic := '0';
    signal axi_arready : std_logic;
    signal axi_rdata   : std_logic_vector( 31 downto 0 );
    signal axi_rresp   : std_logic_vector(  1 downto 0 );
    signal axi_rvalid  : std_logic;
    signal axi_rready  : std_logic := '0';

    -- AXI-Lite #2 ( DMA ).
    signal s_axi_awaddr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal s_axi_awvalid : std_logic := '0';
    signal s_axi_awready : std_logic;
    signal s_axi_wdata   : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal s_axi_wstrb   : std_logic_vector(  3 downto 0 ) := ( others => '1' );
    signal s_axi_wvalid  : std_logic := '0';
    signal s_axi_wready  : std_logic;
    signal s_axi_bresp   : std_logic_vector(  1 downto 0 );
    signal s_axi_bvalid  : std_logic;
    signal s_axi_bready  : std_logic := '0';
    signal s_axi_araddr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal s_axi_arvalid : std_logic := '0';
    signal s_axi_arready : std_logic;
    signal s_axi_rdata   : std_logic_vector( 31 downto 0 );
    signal s_axi_rresp   : std_logic_vector(  1 downto 0 );
    signal s_axi_rvalid  : std_logic;
    signal s_axi_rready  : std_logic := '0';

    -- AXI4 to DDR, Read.
    signal m_axi_r_arid    : std_logic_vector(  3 downto 0 );
    signal m_axi_r_araddr  : std_logic_vector( 31 downto 0 );
    signal m_axi_r_arlen   : std_logic_vector(  7 downto 0 );
    signal m_axi_r_arsize  : std_logic_vector(  2 downto 0 );
    signal m_axi_r_arburst : std_logic_vector(  1 downto 0 );
    signal m_axi_r_arvalid : std_logic;
    signal m_axi_r_arready : std_logic := '0';
    signal m_axi_r_rid     : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal m_axi_r_rdata   : std_logic_vector( 63 downto 0 ) := ( others => '0' );
    signal m_axi_r_rresp   : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal m_axi_r_rlast   : std_logic := '0';
    signal m_axi_r_rvalid  : std_logic := '0';
    signal m_axi_r_rready  : std_logic;

    -- AXI4 to DDR, Write.
    signal m_axi_w_awid    : std_logic_vector(  3 downto 0 );
    signal m_axi_w_awaddr  : std_logic_vector( 31 downto 0 );
    signal m_axi_w_awlen   : std_logic_vector(  7 downto 0 );
    signal m_axi_w_awsize  : std_logic_vector(  2 downto 0 );
    signal m_axi_w_awburst : std_logic_vector(  1 downto 0 );
    signal m_axi_w_awvalid : std_logic;
    signal m_axi_w_awready : std_logic := '0';
    signal m_axi_w_wdata   : std_logic_vector( 63 downto 0 );
    signal m_axi_w_wstrb   : std_logic_vector(  7 downto 0 );
    signal m_axi_w_wlast   : std_logic;
    signal m_axi_w_wvalid  : std_logic;
    signal m_axi_w_wready  : std_logic := '0';
    signal m_axi_w_bid     : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal m_axi_w_bresp   : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal m_axi_w_bvalid  : std_logic := '0';
    signal m_axi_w_bready  : std_logic;

    signal dma_done : std_logic;

    constant DDR_WORDS : integer := 49152;
    type ddr_mem_array is array( 0 to DDR_WORDS - 1 ) of std_logic_vector( 63 downto 0 );

    signal ddr_mem : ddr_mem_array := (
        -- CASO A ( Conv3x3 stride, activacion varia por FILA ). Imagen
        -- 4x4, Cin=16: imgrow0=imgrow1=2, imgrow2=imgrow3=6. Base IN
        -- word 33280 ( addr 0x41000 ), 8 words por fila ( 4 pixeles x
        -- 2 words/pixel ).
        33280 => x"0202020202020202", 33281 => x"0202020202020202",
        33282 => x"0202020202020202", 33283 => x"0202020202020202",
        33284 => x"0202020202020202", 33285 => x"0202020202020202",
        33286 => x"0202020202020202", 33287 => x"0202020202020202",
        33288 => x"0202020202020202", 33289 => x"0202020202020202",
        33290 => x"0202020202020202", 33291 => x"0202020202020202",
        33292 => x"0202020202020202", 33293 => x"0202020202020202",
        33294 => x"0202020202020202", 33295 => x"0202020202020202",
        33296 => x"0606060606060606", 33297 => x"0606060606060606",
        33298 => x"0606060606060606", 33299 => x"0606060606060606",
        33300 => x"0606060606060606", 33301 => x"0606060606060606",
        33302 => x"0606060606060606", 33303 => x"0606060606060606",
        33304 => x"0606060606060606", 33305 => x"0606060606060606",
        33306 => x"0606060606060606", 33307 => x"0606060606060606",
        33308 => x"0606060606060606", 33309 => x"0606060606060606",
        33310 => x"0606060606060606", 33311 => x"0606060606060606",
        -- CASO A, bias = 0 ( addr 0x43800, word 34560 ).
        34560 => x"0000000000000000", 34561 => x"0000000000000000",
        34562 => x"0000000000000000", 34563 => x"0000000000000000",
        34564 => x"0000000000000000", 34565 => x"0000000000000000",
        34566 => x"0000000000000000", 34567 => x"0000000000000000",

        -- CASO B ( DW3x3 stride, activacion varia por COLUMNA ). Imagen
        -- 4x4, 4 FILAS completas ( imgrow0..3 ), cada una: imgcol0=imgcol1=3,
        -- imgcol2=imgcol3=9. Base IN word 35328 ( addr 0x45000 ), 8 words
        -- por fila ( 4 pixeles x 2 words/pixel ), 32 words en total.
        35328 => x"0303030303030303", 35329 => x"0303030303030303",
        35330 => x"0303030303030303", 35331 => x"0303030303030303",
        35332 => x"0909090909090909", 35333 => x"0909090909090909",
        35334 => x"0909090909090909", 35335 => x"0909090909090909",
        35336 => x"0303030303030303", 35337 => x"0303030303030303",
        35338 => x"0303030303030303", 35339 => x"0303030303030303",
        35340 => x"0909090909090909", 35341 => x"0909090909090909",
        35342 => x"0909090909090909", 35343 => x"0909090909090909",
        35344 => x"0303030303030303", 35345 => x"0303030303030303",
        35346 => x"0303030303030303", 35347 => x"0303030303030303",
        35348 => x"0909090909090909", 35349 => x"0909090909090909",
        35350 => x"0909090909090909", 35351 => x"0909090909090909",
        35352 => x"0303030303030303", 35353 => x"0303030303030303",
        35354 => x"0303030303030303", 35355 => x"0303030303030303",
        35356 => x"0909090909090909", 35357 => x"0909090909090909",
        35358 => x"0909090909090909", 35359 => x"0909090909090909",
        -- CASO B, bias = 0 ( addr 0x47800, word 36608 ).
        36608 => x"0000000000000000", 36609 => x"0000000000000000",
        36610 => x"0000000000000000", 36611 => x"0000000000000000",
        36612 => x"0000000000000000", 36613 => x"0000000000000000",
        36614 => x"0000000000000000", 36615 => x"0000000000000000",

        -- CASO C ( 2 tiles horizontales, stride ). Activacion/pesos por
        -- defecto ( uniforme = 1 ) -- no hace falta sobreescribir IN/W,
        -- solo el bias ( addr 0x4B800, word 38656 ).
        38656 => x"0000000000000000", 38657 => x"0000000000000000",
        38658 => x"0000000000000000", 38659 => x"0000000000000000",
        38660 => x"0000000000000000", 38661 => x"0000000000000000",
        38662 => x"0000000000000000", 38663 => x"0000000000000000",

        -- CASO D, Capa 1 ( Conv3x3 stride ). Activacion por defecto
        -- ( uniforme = 1 ) -- solo bias = 0 ( addr 0x4F800, word 40704 ).
        40704 => x"0000000000000000", 40705 => x"0000000000000000",
        40706 => x"0000000000000000", 40707 => x"0000000000000000",
        40708 => x"0000000000000000", 40709 => x"0000000000000000",
        40710 => x"0000000000000000", 40711 => x"0000000000000000",
        -- CASO D, Capa 2 ( DW3x3, sin stride ). IN = OUT real de Capa 1
        -- ( no se sobreescribe aparte ). bias = 3 ( addr 0x52800, word
        -- 42240 ).
        42240 => x"0000000300000003", 42241 => x"0000000300000003",
        42242 => x"0000000300000003", 42243 => x"0000000300000003",
        42244 => x"0000000300000003", 42245 => x"0000000300000003",
        42246 => x"0000000300000003", 42247 => x"0000000300000003",

        -- CASO E ( regresion, stride_en=0 explicito -- mismo caso que
        -- CASO K de tb_cnn_top_hardcore.vhd ). Residual = 10 ( addr
        -- 0x56000, word 44032 ), bias = 104 ( addr 0x56800, word 44288 ).
        44032 => x"0A0A0A0A0A0A0A0A", 44033 => x"0A0A0A0A0A0A0A0A",
        44034 => x"0A0A0A0A0A0A0A0A", 44035 => x"0A0A0A0A0A0A0A0A",
        44036 => x"0A0A0A0A0A0A0A0A", 44037 => x"0A0A0A0A0A0A0A0A",
        44038 => x"0A0A0A0A0A0A0A0A", 44039 => x"0A0A0A0A0A0A0A0A",
        44288 => x"0000006800000068", 44289 => x"0000006800000068",
        44290 => x"0000006800000068", 44291 => x"0000006800000068",
        44292 => x"0000006800000068", 44293 => x"0000006800000068",
        44294 => x"0000006800000068", 44295 => x"0000006800000068",

        others => x"0101010101010101" );

    type rd_state_type is ( RD_S_IDLE, RD_S_BURST );
    signal rd_slave_state : rd_state_type := RD_S_IDLE;

    type wr_state_type is ( WR_S_IDLE, WR_S_DATA, WR_S_RESP );
    signal wr_slave_state : wr_state_type := WR_S_IDLE;
    signal wr_word_idx    : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.cnn_top
        port map(
            clk             => clk,
            reset           => reset,
            axi_awaddr     => axi_awaddr,
            axi_awvalid    => axi_awvalid,
            axi_awready    => axi_awready,
            axi_wdata      => axi_wdata,
            axi_wstrb      => axi_wstrb,
            axi_wvalid     => axi_wvalid,
            axi_wready     => axi_wready,
            axi_bresp      => axi_bresp,
            axi_bvalid     => axi_bvalid,
            axi_bready     => axi_bready,
            axi_araddr     => axi_araddr,
            axi_arvalid    => axi_arvalid,
            axi_arready    => axi_arready,
            axi_rdata      => axi_rdata,
            axi_rresp      => axi_rresp,
            axi_rvalid     => axi_rvalid,
            axi_rready     => axi_rready,
            s_axi_awaddr   => s_axi_awaddr,
            s_axi_awvalid  => s_axi_awvalid,
            s_axi_awready  => s_axi_awready,
            s_axi_wdata    => s_axi_wdata,
            s_axi_wstrb    => s_axi_wstrb,
            s_axi_wvalid   => s_axi_wvalid,
            s_axi_wready   => s_axi_wready,
            s_axi_bresp    => s_axi_bresp,
            s_axi_bvalid   => s_axi_bvalid,
            s_axi_bready   => s_axi_bready,
            s_axi_araddr   => s_axi_araddr,
            s_axi_arvalid  => s_axi_arvalid,
            s_axi_arready  => s_axi_arready,
            s_axi_rdata    => s_axi_rdata,
            s_axi_rresp    => s_axi_rresp,
            s_axi_rvalid   => s_axi_rvalid,
            s_axi_rready   => s_axi_rready,
            m_axi_r_arid    => m_axi_r_arid,
            m_axi_r_araddr  => m_axi_r_araddr,
            m_axi_r_arlen   => m_axi_r_arlen,
            m_axi_r_arsize  => m_axi_r_arsize,
            m_axi_r_arburst => m_axi_r_arburst,
            m_axi_r_arvalid => m_axi_r_arvalid,
            m_axi_r_arready => m_axi_r_arready,
            m_axi_r_rid     => m_axi_r_rid,
            m_axi_r_rdata   => m_axi_r_rdata,
            m_axi_r_rresp   => m_axi_r_rresp,
            m_axi_r_rlast   => m_axi_r_rlast,
            m_axi_r_rvalid  => m_axi_r_rvalid,
            m_axi_r_rready  => m_axi_r_rready,
            m_axi_w_awid    => m_axi_w_awid,
            m_axi_w_awaddr  => m_axi_w_awaddr,
            m_axi_w_awlen   => m_axi_w_awlen,
            m_axi_w_awsize  => m_axi_w_awsize,
            m_axi_w_awburst => m_axi_w_awburst,
            m_axi_w_awvalid => m_axi_w_awvalid,
            m_axi_w_awready => m_axi_w_awready,
            m_axi_w_wdata   => m_axi_w_wdata,
            m_axi_w_wstrb   => m_axi_w_wstrb,
            m_axi_w_wlast   => m_axi_w_wlast,
            m_axi_w_wvalid  => m_axi_w_wvalid,
            m_axi_w_wready  => m_axi_w_wready,
            m_axi_w_bid     => m_axi_w_bid,
            m_axi_w_bresp   => m_axi_w_bresp,
            m_axi_w_bvalid  => m_axi_w_bvalid,
            m_axi_w_bready  => m_axi_w_bready,
            dma_done        => dma_done
        );

    -- DDR, canal de lectura.
    process( clk )
        variable v_word_idx   : integer := 0;
        variable v_beats_left : integer := 0;
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                m_axi_r_arready <= '0';
                m_axi_r_rvalid  <= '0';
                rd_slave_state  <= RD_S_IDLE;
                v_word_idx      := 0;
                v_beats_left    := 0;

            else
                case rd_slave_state is
                    when RD_S_IDLE =>
                        m_axi_r_arready <= '0';
                        m_axi_r_rvalid  <= '0';
                        if( m_axi_r_arvalid = '1' ) then
                            m_axi_r_arready <= '1';
                            v_word_idx      := to_integer( unsigned( m_axi_r_araddr ) ) / 8;
                            v_beats_left    := to_integer( unsigned( m_axi_r_arlen ) ) + 1;
                            rd_slave_state  <= RD_S_BURST;
                        end if;

                    when RD_S_BURST =>
                        m_axi_r_arready <= '0';

                        if( m_axi_r_rvalid = '0' ) then
                            m_axi_r_rvalid <= '1';
                            m_axi_r_rdata  <= ddr_mem( v_word_idx );
                            m_axi_r_rlast  <= '0' when v_beats_left /= 1 else '1';

                        elsif( m_axi_r_rready = '1' ) then
                            v_word_idx   := v_word_idx + 1;
                            v_beats_left := v_beats_left - 1;
                            if( v_beats_left = 0 ) then
                                m_axi_r_rvalid <= '0';
                                rd_slave_state <= RD_S_IDLE;
                            else
                                m_axi_r_rdata <= ddr_mem( v_word_idx );
                                m_axi_r_rlast <= '0' when v_beats_left /= 1 else '1';
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- DDR, canal de escritura.
    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                m_axi_w_awready <= '0';
                m_axi_w_wready  <= '0';
                m_axi_w_bvalid  <= '0';
                wr_slave_state  <= WR_S_IDLE;
                wr_word_idx     <= 0;

            else
                case wr_slave_state is
                    when WR_S_IDLE =>
                        m_axi_w_awready <= '0';
                        m_axi_w_wready  <= '0';
                        m_axi_w_bvalid  <= '0';
                        if( m_axi_w_awvalid = '1' ) then
                            m_axi_w_awready <= '1';
                            wr_word_idx     <= to_integer( unsigned( m_axi_w_awaddr ) ) / 8;
                            wr_slave_state  <= WR_S_DATA;
                        end if;

                    when WR_S_DATA =>
                        m_axi_w_awready <= '0';
                        m_axi_w_wready  <= '1';
                        if( m_axi_w_wvalid = '1' ) then
                            ddr_mem( wr_word_idx ) <= m_axi_w_wdata;
                            wr_word_idx             <= wr_word_idx + 1;
                            if( m_axi_w_wlast = '1' ) then
                                m_axi_w_wready <= '0';
                                wr_slave_state <= WR_S_RESP;
                            end if;
                        end if;

                    when WR_S_RESP =>
                        if( m_axi_w_bvalid = '0' ) then
                            m_axi_w_bvalid <= '1';
                            m_axi_w_bresp  <= "00";
                        elsif( m_axi_w_bready = '1' ) then
                            m_axi_w_bvalid <= '0';
                            wr_slave_state <= WR_S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Main process.
    process

        procedure axi_write_accel( addr : in integer; data : in std_logic_vector( 31 downto 0 ) ) is
        begin
            axi_awaddr  <= std_logic_vector( to_unsigned( addr, 7 ) );
            axi_wdata   <= data;
            axi_awvalid <= '1';
            axi_wvalid  <= '1';
            wait until rising_edge( clk );
            axi_awvalid <= '0';
            axi_wvalid  <= '0';
            wait until axi_bvalid = '1';
            axi_bready <= '1';
            wait until rising_edge( clk );
            axi_bready <= '0';
        end procedure;

        procedure axi_write_dma( addr : in integer; data : in std_logic_vector( 31 downto 0 ) ) is
        begin
            s_axi_awaddr  <= std_logic_vector( to_unsigned( addr, 7 ) );
            s_axi_wdata   <= data;
            s_axi_awvalid <= '1';
            s_axi_wvalid  <= '1';
            wait until rising_edge( clk );
            s_axi_awvalid <= '0';
            s_axi_wvalid  <= '0';
            wait until s_axi_bvalid = '1';
            s_axi_bready <= '1';
            wait until rising_edge( clk );
            s_axi_bready <= '0';
        end procedure;

        -- Standard Config for tile 2x2. relu6_val por defecto = 127 ( se
        -- puede sobreescribir despues con un axi_write_accel(52,...) extra ).
        procedure cfg_accel(
            mode         : in std_logic_vector( 1 downto 0 );
            max_inner_v  : in integer;
            max_x_v      : in integer;
            max_y_v      : in integer;
            has_res      : in integer;
            pool_en_v    : in integer;
            pool_type_v  : in integer;
            shift_v      : in integer;
            gap_shift_v  : in integer
        ) is
        begin
            axi_write_accel(  4, std_logic_vector( resize( unsigned( mode ), 32 ) ) );
            axi_write_accel(  8, x"00000010" ); -- CIN = 16.
            axi_write_accel( 12, std_logic_vector( to_unsigned( max_inner_v, 32 ) ) );
            axi_write_accel( 16, x"00000000" ); -- MAX_CO = 0 ( override despues si hace falta ).
            axi_write_accel( 20, std_logic_vector( to_unsigned( max_x_v, 32 ) ) );
            axi_write_accel( 24, std_logic_vector( to_unsigned( max_y_v, 32 ) ) );
            axi_write_accel( 28, x"00000000" ); -- MAX_TILE_X = 0 ( override despues si hace falta ).
            axi_write_accel( 32, x"00000000" ); -- MAX_TILE_Y = 0.
            axi_write_accel( 36, std_logic_vector( to_unsigned( has_res, 32 ) ) );
            axi_write_accel( 40, std_logic_vector( to_unsigned( pool_en_v, 32 ) ) );
            axi_write_accel( 44, std_logic_vector( to_unsigned( pool_type_v, 32 ) ) );
            axi_write_accel( 48, std_logic_vector( to_unsigned( shift_v, 32 ) ) );
            axi_write_accel( 52, x"0000007F" ); -- RELU6_VAL = 127 ( override despues si hace falta ).
            axi_write_accel( 56, std_logic_vector( to_unsigned( gap_shift_v, 32 ) ) );
            axi_write_accel( 60, x"0000FFFF" ); -- REG_MULT ~= 1.0 ( no-op ), este tb no prueba el multiplicador.
        end procedure;

        -- Standard config of DMA for tile NxN, CON bias. DMA_COUT queda en
        -- 16 por defecto ( override despues si hace falta ).
        procedure cfg_dma(
            tile_n       : in integer;
            has_res      : in integer;
            weight_words : in integer;
            addr_w_v     : in integer;
            addr_in_v    : in integer;
            addr_out_v   : in integer;
            addr_res_v   : in integer;
            pool_en_v    : in integer;
            pool_type_v  : in integer;
            bias_words_v : in integer;
            addr_bias_v  : in integer
        ) is
        begin
            axi_write_dma(  8, x"00000010" ); -- DMA_CIN = 16.
            axi_write_dma( 12, x"00000010" ); -- DMA_COUT = 16.
            axi_write_dma( 16, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_IMG_W.
            axi_write_dma( 20, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_IMG_H.
            axi_write_dma( 24, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_TILE_W.
            axi_write_dma( 28, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_TILE_H.
            axi_write_dma( 32, x"00000001" ); -- DMA_NUM_TILE_X = 1 ( override despues si hace falta ).
            axi_write_dma( 36, x"00000001" ); -- DMA_NUM_TILE_Y = 1.
            axi_write_dma( 40, std_logic_vector( to_unsigned( has_res, 32 ) ) );
            axi_write_dma( 44, std_logic_vector( to_unsigned( weight_words, 32 ) ) );
            axi_write_dma( 48, std_logic_vector( to_unsigned( addr_w_v, 32 ) ) );
            axi_write_dma( 52, std_logic_vector( to_unsigned( addr_in_v, 32 ) ) );
            axi_write_dma( 56, std_logic_vector( to_unsigned( addr_out_v, 32 ) ) );
            axi_write_dma( 60, std_logic_vector( to_unsigned( addr_res_v, 32 ) ) );
            axi_write_dma( 68, std_logic_vector( to_unsigned( pool_en_v, 32 ) ) );
            axi_write_dma( 72, std_logic_vector( to_unsigned( pool_type_v, 32 ) ) );
            axi_write_dma( 76, std_logic_vector( to_unsigned( bias_words_v, 32 ) ) ); -- DMA_BIAS_WORDS ( 0x4C ).
            axi_write_dma( 80, std_logic_vector( to_unsigned( addr_bias_v, 32 ) ) );  -- DMA_ADDR_BIAS ( 0x50 ).
        end procedure;

        procedure run_layer_and_ack is
        begin
            axi_write_dma( 0, x"00000001" ); -- DMA_START.
            wait until dma_done = '1';
            wait for 1 ns;
        end procedure;

        procedure ack_dma_done is
        begin
            axi_write_dma( 64, x"00000001" ); -- write-1-to-clear DMA_DONE.
        end procedure;

        variable errors : integer := 0;

        procedure check( actual : in std_logic_vector( 63 downto 0 ); expected : in std_logic_vector( 63 downto 0 ); label_v : in string ) is
        begin
            if( actual /= expected ) then
                report "FALLO " & label_v & " -- esperado " & to_hstring( expected ) & " obtenido " & to_hstring( actual ) severity error;
                errors := errors + 1;
            else
                report "OK " & label_v & " = " & to_hstring( actual );
            end if;
        end procedure;

    begin

        reset <= '0';
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        reset <= '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "=== INICIO tb_cnn_top_stride: red densa con stride real + regresion ===";

        -- CASO A: Conv3x3 + stride_en=1, tile 2x2, activacion varia por
        -- fila ( imgrow0=imgrow1=2, imgrow2=imgrow3=6 ). Formula real:
        -- row = 2*y_counter + sig_ky.
        --   y=0 ( row set {0,1,2}, row0=halo=0 ): filas validas = 2,2 -> 4.
        --     x=0 (2 cols validas): sum=16*4*2=128. x=1 (3 cols validas):
        --     sum=16*4*3=192.
        --   y=1 ( row set {2,3,4}, todas reales ): filas = 2,6,6 -> 14.
        --     x=0: sum=16*14*2=448. x=1: sum=16*14*3=672.
        -- ( Si la formula NO escalara por stride -- bug de "olvidar" el
        --   shift_left -- y=1 leeria filas {1,2,3}=2,2,6=10, dando sumas
        --   distintas (320/480) -- este caso las distingue. )
        -- shift=4 (division exacta): 128->8, 192->12, 448->28, 672->42.
        report "--- CASO A: Conv3x3 + stride_en=1, activacion varia por fila ---";
        cfg_accel( "00", 144, 1, 1, 0, 0, 0, 4, 0 );
        axi_write_accel( 68, x"00000001" ); -- REG_STRIDE_EN = 1.
        cfg_dma( 4, 0, 144, 16#40000#, 16#41000#, 16#42000#, 16#43000#, 0, 0, 4, 16#43800# );
        axi_write_dma( 84, x"00000001" ); -- DMA_STRIDE_EN = 1.
        run_layer_and_ack;

        check( ddr_mem( 33792 ), x"0808080808080808", "CasoA pixel(y=0,x=0) = 8" );
        check( ddr_mem( 33794 ), x"0C0C0C0C0C0C0C0C", "CasoA pixel(y=0,x=1) = 12" );
        check( ddr_mem( 33796 ), x"1C1C1C1C1C1C1C1C", "CasoA pixel(y=1,x=0) = 28" );
        check( ddr_mem( 33798 ), x"2A2A2A2A2A2A2A2A", "CasoA pixel(y=1,x=1) = 42" );
        ack_dma_done;
        report "=== CASO A OK (row = 2*y_counter + sig_ky verificado con datos que distinguen stride correcto de bug) ===";

        -- CASO B: DW3x3 + stride_en=1, mismo tile 2x2, activacion varia
        -- por COLUMNA ( imgcol0=imgcol1=3, imgcol2=imgcol3=9 ). Formula
        -- real: col = 2*x_counter + sig_kx. DW3x3 es de un solo canal por
        -- salida ( sin multiplicar por 16 ), asi que no hace falta shift.
        --   x=0 (col set {0,1,2}, col0=halo=0): cols validas 3,3 -> 6.
        --     y=0 (2 filas validas): 2*6=12. y=1 (3 filas validas): 3*6=18.
        --   x=1 (col set {2,3,4}, todas reales): 3,9,9 -> 21.
        --     y=0: 2*21=42. y=1: 3*21=63.
        report "--- CASO B: DW3x3 + stride_en=1, activacion varia por columna ---";
        cfg_accel( "01", 9, 1, 1, 0, 0, 0, 0, 0 );
        axi_write_accel( 68, x"00000001" ); -- REG_STRIDE_EN = 1.
        cfg_dma( 4, 0, 9, 16#44000#, 16#45000#, 16#46000#, 16#47000#, 0, 0, 4, 16#47800# );
        axi_write_dma( 84, x"00000001" ); -- DMA_STRIDE_EN = 1.
        run_layer_and_ack;

        check( ddr_mem( 35840 ), x"0C0C0C0C0C0C0C0C", "CasoB pixel(y=0,x=0) = 12" );
        check( ddr_mem( 35842 ), x"2A2A2A2A2A2A2A2A", "CasoB pixel(y=0,x=1) = 42" );
        check( ddr_mem( 35844 ), x"1212121212121212", "CasoB pixel(y=1,x=0) = 18" );
        check( ddr_mem( 35846 ), x"3F3F3F3F3F3F3F3F", "CasoB pixel(y=1,x=1) = 63" );
        ack_dma_done;
        report "=== CASO B OK (col = 2*x_counter + sig_kx verificado, DW3x3 + stride sin regresion) ===";

        -- CASO C: Conv3x3 + stride_en=1, DOS tiles horizontales. Activacion
        -- y pesos por defecto (=1) -- se verifica por CONTEO de taps
        -- validos, igual estilo que el resto de la suite. tile0 es borde
        -- izquierdo real (halo=0); tile1 NO es borde izquierdo -- su halo
        -- izquierdo es el pixel real vecino de tile0 (dato REAL, no cero) --
        -- eso es lo que hace que tile1(x=0) de un conteo distinto a
        -- tile0(x=0), confirmando que el DMA decodifico bien el limite
        -- entre tiles con stride.
        --   filas validas: y=0 -> 2, y=1 -> 3 (igual en ambos tiles).
        --   cols validas: tile0 x=0 -> 2, tile0 x=1 -> 3 (borde real).
        --                 tile1 x=0 -> 3, tile1 x=1 -> 3 (sin cero real).
        -- sum = 16 * filas * cols, shift=4 (division exacta).
        report "--- CASO C: Conv3x3 + stride_en=1, 2 tiles horizontales (TILE_WAIT) ---";
        cfg_accel( "00", 144, 1, 1, 0, 0, 0, 4, 0 );
        axi_write_accel( 28, x"00000001" ); -- MAX_TILE_X = 1 ( 2 tiles ).
        axi_write_accel( 68, x"00000001" ); -- REG_STRIDE_EN = 1.
        cfg_dma( 4, 0, 144, 16#48000#, 16#49000#, 16#4A000#, 16#4B000#, 0, 0, 4, 16#4B800# );
        axi_write_dma( 16, x"00000008" ); -- DMA_IMG_W = 8 ( 2 tiles x 4 core, override ).
        axi_write_dma( 32, x"00000002" ); -- DMA_NUM_TILE_X = 2 ( override ).
        axi_write_dma( 84, x"00000001" ); -- DMA_STRIDE_EN = 1.
        run_layer_and_ack;

        report "--- tile0 (borde izquierdo real -> halo=0) ---";
        check( ddr_mem( 37888 ), x"0404040404040404", "CasoC tile0(y=0,x=0) = 4" );
        check( ddr_mem( 37890 ), x"0606060606060606", "CasoC tile0(y=0,x=1) = 6" );
        check( ddr_mem( 37896 ), x"0606060606060606", "CasoC tile0(y=1,x=0) = 6" );
        check( ddr_mem( 37898 ), x"0909090909090909", "CasoC tile0(y=1,x=1) = 9" );

        report "--- tile1 (halo izquierdo = pixel real vecino, no cero) ---";
        check( ddr_mem( 37892 ), x"0606060606060606", "CasoC tile1(y=0,x=0) = 6 (real, no 4)" );
        check( ddr_mem( 37894 ), x"0606060606060606", "CasoC tile1(y=0,x=1) = 6" );
        check( ddr_mem( 37900 ), x"0909090909090909", "CasoC tile1(y=1,x=0) = 9 (real, no 6)" );
        check( ddr_mem( 37902 ), x"0909090909090909", "CasoC tile1(y=1,x=1) = 9" );
        ack_dma_done;
        report "=== CASO C OK (DMA_TILE_W desacoplado de MAX_X/MAX_Y verificado con 2 tiles reales) ===";

        -- CASO D: cadena real Conv3x3(stride=2) -> DW3x3(stride=1), igual
        -- patron que conv1 -> siguiente capa en MobileNetV2 real. Capa 1
        -- igual al Caso C con UN tile (mismos conteos de taps: 4,6,6,9).
        -- Capa 2 consume la salida REAL de Capa 1 como imagen 2x2 --
        -- con solo 2x2 pixeles y kernel 3x3, CUALQUIER posicion de salida
        -- termina sumando los 4 pixeles reales (caso degenerado, ver nota
        -- en el header del archivo) -> las 4 salidas dan el mismo valor:
        -- 4+6+6+9=25, +bias3=28, shift=0.
        report "--- CASO D: cadena Conv3x3(stride=2) -> DW3x3(stride=1), datos reales propagados ---";

        report "--- Capa 1 (Conv3x3, stride_en=1) ---";
        cfg_accel( "00", 144, 1, 1, 0, 0, 0, 4, 0 );
        axi_write_accel( 68, x"00000001" ); -- REG_STRIDE_EN = 1.
        cfg_dma( 4, 0, 144, 16#4C000#, 16#4D000#, 16#4E000#, 16#4F000#, 0, 0, 4, 16#4F800# );
        axi_write_dma( 84, x"00000001" ); -- DMA_STRIDE_EN = 1.
        run_layer_and_ack;

        check( ddr_mem( 39936 ), x"0404040404040404", "CasoD capa1(y=0,x=0) = 4" );
        check( ddr_mem( 39938 ), x"0606060606060606", "CasoD capa1(y=0,x=1) = 6" );
        check( ddr_mem( 39940 ), x"0606060606060606", "CasoD capa1(y=1,x=0) = 6" );
        check( ddr_mem( 39942 ), x"0909090909090909", "CasoD capa1(y=1,x=1) = 9" );
        ack_dma_done;

        report "--- Capa 2 (DW3x3, stride_en=0 -- IN = OUT real de capa 1) ---";
        cfg_accel( "01", 9, 1, 1, 0, 0, 0, 0, 0 );
        axi_write_accel( 68, x"00000000" ); -- REG_STRIDE_EN = 0 ( explicito ).
        cfg_dma( 2, 0, 9, 16#50000#, 16#4E000#, 16#51000#, 16#52000#, 0, 0, 4, 16#52800# );
        axi_write_dma( 84, x"00000000" ); -- DMA_STRIDE_EN = 0 ( explicito ).
        run_layer_and_ack;

        check( ddr_mem( 41472 ), x"1C1C1C1C1C1C1C1C", "CasoD capa2(y=0,x=0) = 28" );
        check( ddr_mem( 41474 ), x"1C1C1C1C1C1C1C1C", "CasoD capa2(y=0,x=1) = 28" );
        check( ddr_mem( 41476 ), x"1C1C1C1C1C1C1C1C", "CasoD capa2(y=1,x=0) = 28" );
        check( ddr_mem( 41478 ), x"1C1C1C1C1C1C1C1C", "CasoD capa2(y=1,x=1) = 28" );
        ack_dma_done;
        report "=== CASO D OK (capa con stride alimentando directamente a capa sin stride, datos reales) ===";

        -- CASO E: regresion. Mismo caso y matematica EXACTA que el CASO K
        -- de tb_cnn_top_hardcore.vhd (PW1x1 + Residual): sum=16,
        -- acc=16+bias104=120, shift=0 -> 120. clamp_int8(120)=120 (dentro
        -- de rango). ReLU6: 120<127 -> 120. Residual sobreescrito a 10:
        -- add_unit: 120+10=130 > 127 -> satura A SU PROPIO limite a 127.
        -- stride_en=0 escrito EXPLICITO en los dos lados -- confirma que
        -- toda la plomeria nueva (registros + wiring + "or stride_en" en
        -- ddr_addr_gen.vhd/dma_fsm.vhd) no cambio el resultado ya
        -- verificado antes de este cambio.
        report "--- CASO E: regresion (PW1x1 + Residual, stride_en=0 explicito) ---";
        cfg_accel( "10", 16, 1, 1, 1, 0, 0, 0, 0 );
        axi_write_accel( 68, x"00000000" ); -- REG_STRIDE_EN = 0 ( explicito ).
        cfg_dma( 2, 1, 16, 16#53000#, 16#54000#, 16#55000#, 16#56000#, 0, 0, 4, 16#56800# );
        axi_write_dma( 84, x"00000000" ); -- DMA_STRIDE_EN = 0 ( explicito ).
        run_layer_and_ack;

        check( ddr_mem( 43520 ), x"7F7F7F7F7F7F7F7F", "CasoE pixel(0,0) (120+10=130 -> satura a 127)" );
        check( ddr_mem( 43522 ), x"7F7F7F7F7F7F7F7F", "CasoE pixel(0,1)" );
        check( ddr_mem( 43524 ), x"7F7F7F7F7F7F7F7F", "CasoE pixel(1,0)" );
        check( ddr_mem( 43526 ), x"7F7F7F7F7F7F7F7F", "CasoE pixel(1,1)" );
        ack_dma_done;
        report "=== CASO E OK (regresion confirmada: stride_en=0 no cambio nada del datapath ya verificado) ===";

        report "=== RESUMEN: " & integer'image( errors ) & " fallo(s) ===" severity note;
        if( errors = 0 ) then
            report "=== TODOS LOS CASOS PASARON ===" severity note;
        else
            report "=== HAY CASOS CON FALLOS, revisar arriba ===" severity error;
        end if;

        wait;
    end process;

end Behavioral;
