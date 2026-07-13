library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench de integracion completa de cnn_top: acelerador real + DMA real,
-- contra una "DDR falsa" bidireccional (un solo array sirve de lectura y
-- escritura, igual que memoria real). A diferencia de tb_dma_engine.vhd
-- (acelerador falso) y de tb_cnn_accelerator/tb_conv3x3/tb_dw3x3/tb_pool/
-- tb_add/tb_multilayer3, este es el primer testbench que ejercita el camino 
-- completo PS -> DMA -> acelerador -> DMA -> DDR para cada modo del acelerador.
--
-- Direcciones DDR: cada caso vive en su propio bloque de 0x4000 bytes
-- ( CASE_BASE = n * 0x4000 ), y dentro de cada bloque: ADDR_W = +0x0000,
-- ADDR_IN = +0x1000, ADDR_OUT = +0x2000, ADDR_RES = +0x3000. Margen amplio
-- ( el caso mas grande, Conv3x3, usa 144 palabras = 2304 bytes de pesos,
-- muy por debajo de los 4096 bytes de cada sub-bloque ).
--
-- La DDR falsa arranca con TODO en 0x01 repetido, cubre pesos y activaciones
-- de todos los casos que necesitan "todo en 1" sin tener que escribir direccion
-- por direccion.
--
-- Solo el Caso 7 ( TILE_WAIT ) sobreescribe una región puntual para dar un
-- valor distinto por tile ( 0x01 vs 0x02 ), y el Caso 8 encadena el OUT de
-- la capa 1 como IN de la capa 2 directamente ( mismo layout de memoria,
-- fila-mayor con canales contiguos por pixel, asi que no hace falta copiar
-- nada, la capa 2 lee exactamente lo que la capa 1 escribio ).
--
-- Direcciones de OFM resultantes: para un tile 2x2 sin pool, 
-- con wbase = ADDR_OUT / 8, los 4 pixeles caen en wbase + 0, wbase + 2, wbase + 4, 
-- wbase+6. Con pool_en = 1 tile_w_out / tile_h_out se
-- reducen a la mitad. GAP usa el camino aparte GAP_FLUSH ( una sola
-- rafaga en ADDR_OUT directo, sin offset de fila / pixel ).

entity tb_cnn_top is
end tb_cnn_top;

architecture Behavioral of tb_cnn_top is

    constant CLK_PERIOD : time := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '0'; -- Low Active.

    -- AXI-Lite #1 ( acelerador ).
    signal axi_aw_addr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal axi_aw_valid : std_logic := '0';
    signal axi_aw_ready : std_logic;
    signal axi_w_data   : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal axi_w_strb   : std_logic_vector(  3 downto 0 ) := ( others => '1' );
    signal axi_w_valid  : std_logic := '0';
    signal axi_w_ready  : std_logic;
    signal axi_b_resp   : std_logic_vector(  1 downto 0 );
    signal axi_b_valid  : std_logic;
    signal axi_b_ready  : std_logic := '0';
    signal axi_ar_addr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal axi_ar_valid : std_logic := '0';
    signal axi_ar_ready : std_logic;
    signal axi_r_data   : std_logic_vector( 31 downto 0 );
    signal axi_r_resp   : std_logic_vector(  1 downto 0 );
    signal axi_r_valid  : std_logic;
    signal axi_r_ready  : std_logic := '0';

    -- AXI-Lite #2 ( DMA ).
    signal s_axi_aw_addr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal s_axi_aw_valid : std_logic := '0';
    signal s_axi_aw_ready : std_logic;
    signal s_axi_w_data   : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal s_axi_w_strb   : std_logic_vector(  3 downto 0 ) := ( others => '1' );
    signal s_axi_w_valid  : std_logic := '0';
    signal s_axi_w_ready  : std_logic;
    signal s_axi_b_resp   : std_logic_vector(  1 downto 0 );
    signal s_axi_b_valid  : std_logic;
    signal s_axi_b_ready  : std_logic := '0';
    signal s_axi_ar_addr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal s_axi_ar_valid : std_logic := '0';
    signal s_axi_ar_ready : std_logic;
    signal s_axi_r_data   : std_logic_vector( 31 downto 0 );
    signal s_axi_r_resp   : std_logic_vector(  1 downto 0 );
    signal s_axi_r_valid  : std_logic;
    signal s_axi_r_ready  : std_logic := '0';

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

    -- DDR falsa BIDIRECCIONAL: un solo array sirve de lectura y escritura,
    -- igual que memoria real. Arranca con TODO en 0x01 repetido, cubre
    -- pesos y activaciones de la mayoria de los casos sin overrides.
    constant DDR_WORDS : integer := 32768;
    type ddr_mem_array is array( 0 to DDR_WORDS - 1 ) of std_logic_vector( 63 downto 0 );

    signal ddr_mem : ddr_mem_array := (
        12804 => x"0202020202020202", 12805 => x"0202020202020202",
        12806 => x"0202020202020202", 12807 => x"0202020202020202",
        12812 => x"0202020202020202", 12813 => x"0202020202020202",
        12814 => x"0202020202020202", 12815 => x"0202020202020202",
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
            axi_aw_addr     => axi_aw_addr,
            axi_aw_valid    => axi_aw_valid,
            axi_aw_ready    => axi_aw_ready,
            axi_w_data      => axi_w_data,
            axi_w_strb      => axi_w_strb,
            axi_w_valid     => axi_w_valid,
            axi_w_ready     => axi_w_ready,
            axi_b_resp      => axi_b_resp,
            axi_b_valid     => axi_b_valid,
            axi_b_ready     => axi_b_ready,
            axi_ar_addr     => axi_ar_addr,
            axi_ar_valid    => axi_ar_valid,
            axi_ar_ready    => axi_ar_ready,
            axi_r_data      => axi_r_data,
            axi_r_resp      => axi_r_resp,
            axi_r_valid     => axi_r_valid,
            axi_r_ready     => axi_r_ready,
            s_axi_aw_addr   => s_axi_aw_addr,
            s_axi_aw_valid  => s_axi_aw_valid,
            s_axi_aw_ready  => s_axi_aw_ready,
            s_axi_w_data    => s_axi_w_data,
            s_axi_w_strb    => s_axi_w_strb,
            s_axi_w_valid   => s_axi_w_valid,
            s_axi_w_ready   => s_axi_w_ready,
            s_axi_b_resp    => s_axi_b_resp,
            s_axi_b_valid   => s_axi_b_valid,
            s_axi_b_ready   => s_axi_b_ready,
            s_axi_ar_addr   => s_axi_ar_addr,
            s_axi_ar_valid  => s_axi_ar_valid,
            s_axi_ar_ready  => s_axi_ar_ready,
            s_axi_r_data    => s_axi_r_data,
            s_axi_r_resp    => s_axi_r_resp,
            s_axi_r_valid   => s_axi_r_valid,
            s_axi_r_ready   => s_axi_r_ready,
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

    -- DDR.
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

    -- Mock DDR, Write Channel:
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
            axi_aw_addr  <= std_logic_vector( to_unsigned( addr, 7 ) );
            axi_w_data   <= data;
            axi_aw_valid <= '1';
            axi_w_valid  <= '1';
            wait until rising_edge( clk );
            axi_aw_valid <= '0';
            axi_w_valid  <= '0';
            wait until axi_b_valid = '1';
            axi_b_ready <= '1';
            wait until rising_edge( clk );
            axi_b_ready <= '0';
        end procedure;

        procedure axi_write_dma( addr : in integer; data : in std_logic_vector( 31 downto 0 ) ) is
        begin
            s_axi_aw_addr  <= std_logic_vector( to_unsigned( addr, 7 ) );
            s_axi_w_data   <= data;
            s_axi_aw_valid <= '1';
            s_axi_w_valid  <= '1';
            wait until rising_edge( clk );
            s_axi_aw_valid <= '0';
            s_axi_w_valid  <= '0';
            wait until s_axi_b_valid = '1';
            s_axi_b_ready <= '1';
            wait until rising_edge( clk );
            s_axi_b_ready <= '0';
        end procedure;

        -- Standard Config for tile 2x2.
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
            axi_write_accel( 16, x"00000000" ); -- MAX_CO = 0.
            axi_write_accel( 20, std_logic_vector( to_unsigned( max_x_v, 32 ) ) );
            axi_write_accel( 24, std_logic_vector( to_unsigned( max_y_v, 32 ) ) );
            axi_write_accel( 28, x"00000000" ); -- MAX_TILE_X = 0.
            axi_write_accel( 32, x"00000000" ); -- MAX_TILE_Y = 0.
            axi_write_accel( 36, std_logic_vector( to_unsigned( has_res, 32 ) ) );
            axi_write_accel( 40, std_logic_vector( to_unsigned( pool_en_v, 32 ) ) );
            axi_write_accel( 44, std_logic_vector( to_unsigned( pool_type_v, 32 ) ) );
            axi_write_accel( 48, std_logic_vector( to_unsigned( shift_v, 32 ) ) );
            axi_write_accel( 52, x"0000007F" ); -- RELU6_VAL = 127.
            axi_write_accel( 56, std_logic_vector( to_unsigned( gap_shift_v, 32 ) ) );
        end procedure;
    
        -- Standard config of DMA  for tile NxN.
        procedure cfg_dma(
            tile_n       : in integer;
            has_res      : in integer;
            weight_words : in integer;
            addr_w_v     : in integer;
            addr_in_v    : in integer;
            addr_out_v   : in integer;
            addr_res_v   : in integer;
            pool_en_v    : in integer;
            pool_type_v  : in integer
        ) is
        begin
            axi_write_dma(  8, x"00000010" ); -- DMA_CIN = 16.
            axi_write_dma( 12, x"00000010" ); -- DMA_COUT = 16.
            axi_write_dma( 16, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_IMG_W = tile_n ( 1 tile ).
            axi_write_dma( 20, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_IMG_H.
            axi_write_dma( 24, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_TILE_W.
            axi_write_dma( 28, std_logic_vector( to_unsigned( tile_n, 32 ) ) ); -- DMA_TILE_H.
            axi_write_dma( 32, x"00000001" ); -- DMA_NUM_TILE_X = 1.
            axi_write_dma( 36, x"00000001" ); -- DMA_NUM_TILE_Y = 1.
            axi_write_dma( 40, std_logic_vector( to_unsigned( has_res, 32 ) ) );
            axi_write_dma( 44, std_logic_vector( to_unsigned( weight_words, 32 ) ) );
            axi_write_dma( 48, std_logic_vector( to_unsigned( addr_w_v, 32 ) ) );
            axi_write_dma( 52, std_logic_vector( to_unsigned( addr_in_v, 32 ) ) );
            axi_write_dma( 56, std_logic_vector( to_unsigned( addr_out_v, 32 ) ) );
            axi_write_dma( 60, std_logic_vector( to_unsigned( addr_res_v, 32 ) ) );
            axi_write_dma( 68, std_logic_vector( to_unsigned( pool_en_v, 32 ) ) );
            axi_write_dma( 72, std_logic_vector( to_unsigned( pool_type_v, 32 ) ) );
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

        report "=== INICIO tb_cnn_top: suite agresiva de integracion ===";

        -- CASE 1.
        report "--- CASO 1: PW1x1 basico ---";
        cfg_accel( "10", 16, 1, 1, 0, 0, 0, 0, 0 );
        cfg_dma( 2, 0, 16, 16#00000#, 16#01000#, 16#02000#, 16#03000#, 0, 0 );
        run_layer_and_ack;

        check( ddr_mem( 1024 ), x"1010101010101010", "Caso1 pixel(0,0)" );
        check( ddr_mem( 1026 ), x"1010101010101010", "Caso1 pixel(0,1)" );
        check( ddr_mem( 1028 ), x"1010101010101010", "Caso1 pixel(1,0)" );
        check( ddr_mem( 1030 ), x"1010101010101010", "Caso1 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO 1 OK ===";

        -- CASE 2.
        report "--- CASO 2: Conv3x3 ---";
        cfg_accel( "00", 144, 1, 1, 0, 0, 0, 4, 0 );
        cfg_dma( 2, 0, 144, 16#04000#, 16#05000#, 16#06000#, 16#07000#, 0, 0 );
        run_layer_and_ack;

        check( ddr_mem( 3072 ), x"0404040404040404", "Caso2 pixel(0,0)" );
        check( ddr_mem( 3074 ), x"0404040404040404", "Caso2 pixel(0,1)" );
        check( ddr_mem( 3076 ), x"0404040404040404", "Caso2 pixel(1,0)" );
        check( ddr_mem( 3078 ), x"0404040404040404", "Caso2 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO 2 OK ===";

        -- CASE 3.
        report "--- CASO 3: DW3x3 ---";
        cfg_accel( "01", 9, 1, 1, 0, 0, 0, 0, 0 );
        cfg_dma( 2, 0, 9, 16#08000#, 16#09000#, 16#0A000#, 16#0B000#, 0, 0 );
        run_layer_and_ack;

        check( ddr_mem( 5120 ), x"0404040404040404", "Caso3 pixel(0,0)" );
        check( ddr_mem( 5122 ), x"0404040404040404", "Caso3 pixel(0,1)" );
        check( ddr_mem( 5124 ), x"0404040404040404", "Caso3 pixel(1,0)" );
        check( ddr_mem( 5126 ), x"0404040404040404", "Caso3 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO 3 OK ===";

        -- CASE 4.
        report "--- CASO 4: PW1x1 + Residual ---";
        cfg_accel( "10", 16, 1, 1, 1, 0, 0, 0, 0 );
        cfg_dma( 2, 1, 16, 16#0C000#, 16#0D000#, 16#0E000#, 16#0F000#, 0, 0 );
        run_layer_and_ack;

        check( ddr_mem( 7168 ), x"1111111111111111", "Caso4 pixel(0,0)" );
        check( ddr_mem( 7170 ), x"1111111111111111", "Caso4 pixel(0,1)" );
        check( ddr_mem( 7172 ), x"1111111111111111", "Caso4 pixel(1,0)" );
        check( ddr_mem( 7174 ), x"1111111111111111", "Caso4 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO 4 OK ===";

        -- CASE 5.
        report "--- CASO 5: PW1x1 + MaxPool ---";
        cfg_accel( "10", 16, 3, 3, 0, 1, 0, 0, 0 );
        cfg_dma( 4, 0, 16, 16#10000#, 16#11000#, 16#12000#, 16#13000#, 1, 0 );
        run_layer_and_ack;

        check( ddr_mem( 9216 ), x"1010101010101010", "Caso5 pixel(0,0)" );
        check( ddr_mem( 9218 ), x"1010101010101010", "Caso5 pixel(0,1)" );
        check( ddr_mem( 9220 ), x"1010101010101010", "Caso5 pixel(1,0)" );
        check( ddr_mem( 9222 ), x"1010101010101010", "Caso5 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO 5 OK ===";

        -- CASE 6.
        report "--- CASO 6: PW1x1 + GAP ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 1, 0, 2 );
        cfg_dma( 2, 0, 16, 16#14000#, 16#15000#, 16#16000#, 16#17000#, 1, 1 );
        run_layer_and_ack;

        check( ddr_mem( 11264 ), x"1010101010101010", "Caso6 GAP" );
        ack_dma_done;
        report "=== CASO 6 OK ===";

        -- CASE 7.
        report "--- CASO 7: PW1x1 2 tiles horizontales ( TILE_WAIT ) ---";

        cfg_accel( "10", 16, 1, 1, 0, 0, 0, 0, 0 );
        axi_write_accel( 28, x"00000001" ); -- MAX_TILE_X = 1..

        axi_write_dma(  8, x"00000010" ); -- DMA_CIN = 16.
        axi_write_dma( 12, x"00000010" ); -- DMA_COUT = 16.
        axi_write_dma( 16, x"00000004" ); -- DMA_IMG_W = 4.
        axi_write_dma( 20, x"00000002" ); -- DMA_IMG_H = 2.
        axi_write_dma( 24, x"00000002" ); -- DMA_TILE_W = 2.
        axi_write_dma( 28, x"00000002" ); -- DMA_TILE_H = 2.
        axi_write_dma( 32, x"00000002" ); -- DMA_NUM_TILE_X = 2.
        axi_write_dma( 36, x"00000001" ); -- DMA_NUM_TILE_Y = 1.
        axi_write_dma( 40, x"00000000" ); -- DMA_HAS_RESIDUAL = 0.
        axi_write_dma( 44, x"00000010" ); -- DMA_WEIGHT_WORDS = 16.
        axi_write_dma( 48, x"00018000" ); -- DMA_ADDR_W.
        axi_write_dma( 52, x"00019000" ); -- DMA_ADDR_IN.
        axi_write_dma( 56, x"0001A000" ); -- DMA_ADDR_OUT.
        axi_write_dma( 60, x"0001B000" ); -- DMA_ADDR_RES.
        axi_write_dma( 68, x"00000000" ); -- DMA_POOL_EN = 0.
        axi_write_dma( 72, x"00000000" ); -- DMA_POOL_TYPE = 0.

        run_layer_and_ack;

        report "--- Verificando tile0 ( esperado 0x10, datos=0x01 ) ---";
        check( ddr_mem( 13312 ), x"1010101010101010", "Caso7 tile0 pixel(0,0)" );
        check( ddr_mem( 13314 ), x"1010101010101010", "Caso7 tile0 pixel(0,1)" );
        check( ddr_mem( 13320 ), x"1010101010101010", "Caso7 tile0 pixel(1,0)" );
        check( ddr_mem( 13322 ), x"1010101010101010", "Caso7 tile0 pixel(1,1)" );

        report "--- Verificando tile1 ( esperado 0x20, datos=0x02 -- confirma recarga real de TILE_WAIT ) ---";
        check( ddr_mem( 13316 ), x"2020202020202020", "Caso7 tile1 pixel(0,0)" );
        check( ddr_mem( 13318 ), x"2020202020202020", "Caso7 tile1 pixel(0,1)" );
        check( ddr_mem( 13324 ), x"2020202020202020", "Caso7 tile1 pixel(1,0)" );
        check( ddr_mem( 13326 ), x"2020202020202020", "Caso7 tile1 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO 7 OK ( TILE_WAIT autonomo del DMA verificado ) ===";

        -- CASE 8.
        report "--- CASO 8: cadena de 2 capas, protocolo DMA_DONE real ---";

        report "--- Capa 1: PW1x1 basico ---";
        cfg_accel( "10", 16, 1, 1, 0, 0, 0, 0, 0 );
        cfg_dma( 2, 0, 16, 16#1C000#, 16#1D000#, 16#1E000#, 16#1F000#, 0, 0 );
        run_layer_and_ack;

        check( ddr_mem( 15360 ), x"1010101010101010", "Caso8 capa1 pixel(0,0)" );
        check( ddr_mem( 15362 ), x"1010101010101010", "Caso8 capa1 pixel(0,1)" );
        check( ddr_mem( 15364 ), x"1010101010101010", "Caso8 capa1 pixel(1,0)" );
        check( ddr_mem( 15366 ), x"1010101010101010", "Caso8 capa1 pixel(1,1)" );

        ack_dma_done;

        report "--- Capa 2: PW1x1 + GAP, IN = OUT de la capa 1 ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 1, 4, 2 );
        cfg_dma( 2, 0, 16, 16#1F000#, 16#1E000#, 16#20000#, 16#21000#, 1, 1 );
        run_layer_and_ack;

        check( ddr_mem( 16384 ), x"1010101010101010", "Caso8 capa2 GAP" );
        ack_dma_done;
        report "=== CASO 8 OK ( cadena de 2 capas + protocolo DMA_DONE real verificado ) ===";
        
        report "=== RESUMEN: " & integer'image( errors ) & " fallo(s) ===" severity note;
        if( errors = 0 ) then
            report "=== TODOS LOS CASOS PASARON ===" severity note;
        else
            report "=== HAY CASOS CON FALLOS, revisar arriba ===" severity error;
        end if;

        wait;
    end process;

end Behavioral;
