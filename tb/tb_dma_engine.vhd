library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: dma_engine ( integracion completa: reg_bank + ddr_addr_gen + dma_fsm +
-- axi4_read_master + axi4_write_master )
--
-- A diferencia de los testbenches aislados ( tb_reg_bank, tb_ddr_addr_gen,
-- tb_axi4_read_master, tb_axi4_write_master ), este testbench corre capas
-- completas de principio a fin: escribe la configuracion por AXI-Lite, dispara
-- DMA_START, y deja correr el flujo autonomo ( pesos -> IFM con halo -> residual
-- opcional -> handshake TILE_WAIT con un acelerador falso -> OFM/GAP -> DONE_LAYER )
-- contra una "DDR falsa" y un "acelerador falso".
--
-- Direcciones base usadas en todos los casos ( pequeñas a proposito para que la
-- "DDR falsa" quepa en un array chico ): ADDR_IN=0x000, ADDR_W=0x800, ADDR_RES=0x1000,
-- ADDR_OUT=0x1800. El lado de lectura de la DDR falsa no necesita array: entrega
-- mem( i ) = i calculado al vuelo ( igual patron que tb_axi4_read_master, sin limite de
-- direccion ). El lado de escritura si captura en un array ( ddr_mem ) para poder
-- verificar el contenido final.
--
-- Sincronizacion: en vez de tratar de adivinar tiempos fijos, dos contadores
-- ( local_wr_count, ddr_beat_count ), incrementados por los procesos mock, cuentan
-- TOTAL ACUMULADO de palabras escritas a buffers locales ( IFBuffer/WeightBuffer/
-- ResidualBuffer ) y beats aceptados por el canal W hacia la DDR de salida, a lo
-- largo de TODA la simulacion ( sin resetearse entre casos ). El proceso principal
-- espera con "wait until" a que esos contadores lleguen al total esperado de cada
-- caso, calculado a mano igual que en tb_ddr_addr_gen.

entity tb_dma_engine is
end tb_dma_engine;

architecture Behavioral of tb_dma_engine is

    constant CLK_PERIOD : time := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '0'; -- Low active.

    -- AXI-Lite ( PS -> DMA ).
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

    -- AXI4 to DDR, read ( weights / IFM / residual ).
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

    -- AXI4 to DDR, write ( OFM / GAP ).
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

    -- To accelerator ( fake local buffers ).
    signal buf_sel        : std_logic;
    signal dma_if_wr_en   : std_logic;
    signal dma_if_wr_addr : std_logic_vector( 12 downto 0 );
    signal dma_if_wr_data : std_logic_vector( 127 downto 0 );
    signal dma_wb_wr_en   : std_logic;
    signal dma_wb_wr_addr : std_logic_vector(  7 downto 0 );
    signal dma_wb_wr_data : std_logic_vector( 127 downto 0 );
    signal dma_rb_wr_en   : std_logic;
    signal dma_rb_wr_addr : std_logic_vector( 11 downto 0 );
    signal dma_rb_wr_data : std_logic_vector( 127 downto 0 );
    signal dma_ob_rd_en   : std_logic;
    signal dma_ob_rd_addr : std_logic_vector( 11 downto 0 );
    signal dma_ob_rd_data : std_logic_vector( 127 downto 0 );

    signal accel_start : std_logic;
    signal tile_ready  : std_logic;
    signal tile_req    : std_logic := '0';
    signal irq_out     : std_logic := '0';

    -- Fake DDR of writting ( to OFM/GAP ).
    type ddr_mem_array is array( 0 to 1023 ) of std_logic_vector( 63 downto 0 );
    signal ddr_mem : ddr_mem_array := ( others => ( others => '0' ) );

    type rd_state_type is ( RD_S_IDLE, RD_S_BURST );
    signal rd_slave_state : rd_state_type := RD_S_IDLE;

    type wr_state_type is ( WR_S_IDLE, WR_S_DATA, WR_S_RESP );
    signal wr_slave_state : wr_state_type := WR_S_IDLE;
    signal wr_word_idx    : integer := 0;

    -- Catch accelerator local buffers.
    type captured_if_array is array( 0 to 31 ) of std_logic_vector( 127 downto 0 );
    type captured_wb_array is array( 0 to 15 ) of std_logic_vector( 127 downto 0 );
    type captured_rb_array is array( 0 to 15 ) of std_logic_vector( 127 downto 0 );

    signal captured_if : captured_if_array := ( others => ( others => '0' ) );
    signal captured_wb : captured_wb_array := ( others => ( others => '0' ) );
    signal captured_rb : captured_rb_array := ( others => ( others => '0' ) );

    -- Accumulated counters.
    signal local_wr_count : integer := 0;
    signal ddr_beat_count : integer := 0;

    signal mock_total_tiles : integer := 1;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.dma_engine
        port map(
            clk             => clk,
            reset           => reset,
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
            buf_sel         => buf_sel,
            dma_if_wr_en    => dma_if_wr_en,
            dma_if_wr_addr  => dma_if_wr_addr,
            dma_if_wr_data  => dma_if_wr_data,
            dma_wb_wr_en    => dma_wb_wr_en,
            dma_wb_wr_addr  => dma_wb_wr_addr,
            dma_wb_wr_data  => dma_wb_wr_data,
            dma_rb_wr_en    => dma_rb_wr_en,
            dma_rb_wr_addr  => dma_rb_wr_addr,
            dma_rb_wr_data  => dma_rb_wr_data,
            dma_ob_rd_en    => dma_ob_rd_en,
            dma_ob_rd_addr  => dma_ob_rd_addr,
            dma_ob_rd_data  => dma_ob_rd_data,
            accel_start     => accel_start,
            tile_ready      => tile_ready,
            tile_req        => tile_req,
            irq_out         => irq_out
        );

    dma_ob_rd_data <= std_logic_vector( to_unsigned( 2 * to_integer( unsigned( dma_ob_rd_addr ) ) + 1, 64 ) ) &
                      std_logic_vector( to_unsigned( 2 * to_integer( unsigned( dma_ob_rd_addr ) ), 64 ) );

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
                            m_axi_r_rdata  <= std_logic_vector( to_unsigned( v_word_idx, 64 ) );
                            if( v_beats_left = 1 ) then
                                m_axi_r_rlast <= '1';
                            else
                                m_axi_r_rlast <= '0';
                            end if;

                        elsif( m_axi_r_rready = '1' ) then
                            v_word_idx   := v_word_idx + 1;
                            v_beats_left := v_beats_left - 1;
                            if( v_beats_left = 0 ) then
                                m_axi_r_rvalid <= '0';
                                rd_slave_state <= RD_S_IDLE;
                            else
                                m_axi_r_rdata <= std_logic_vector( to_unsigned( v_word_idx, 64 ) );
                                if( v_beats_left = 1 ) then
                                    m_axi_r_rlast <= '1';
                                else
                                    m_axi_r_rlast <= '0';
                                end if;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                m_axi_w_awready <= '0';
                m_axi_w_wready  <= '0';
                m_axi_w_bvalid  <= '0';
                wr_slave_state  <= WR_S_IDLE;
                wr_word_idx     <= 0;
                ddr_beat_count  <= 0;

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
                            ddr_beat_count         <= ddr_beat_count + 1;
                            wr_word_idx            <= wr_word_idx + 1;
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

    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                local_wr_count <= 0;

            elsif( dma_if_wr_en = '1' ) then
                captured_if( to_integer( unsigned( dma_if_wr_addr ) ) ) <= dma_if_wr_data;
                local_wr_count <= local_wr_count + 1;

            elsif( dma_wb_wr_en = '1' ) then
                captured_wb( to_integer( unsigned( dma_wb_wr_addr ) ) ) <= dma_wb_wr_data;
                local_wr_count <= local_wr_count + 1;

            elsif( dma_rb_wr_en = '1' ) then
                captured_rb( to_integer( unsigned( dma_rb_wr_addr ) ) ) <= dma_rb_wr_data;
                local_wr_count <= local_wr_count + 1;
            end if;
        end if;
    end process;

    process( clk )
        variable v_tiles_left : integer := 0;
        variable v_wait_cnt   : integer := 0;
        variable v_waiting    : boolean := false;
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                tile_req  <= '0';
                irq_out   <= '0';
                v_waiting := false;

            else
                tile_req <= '0';
                irq_out  <= '0';

                if( v_waiting ) then
                    if( v_wait_cnt = 0 ) then
                        if( v_tiles_left = 0 ) then
                            irq_out <= '1';
                        else
                            tile_req     <= '1';
                            v_tiles_left := v_tiles_left - 1;
                        end if;
                        v_waiting := false;
                    else
                        v_wait_cnt := v_wait_cnt - 1;
                    end if;

                elsif( accel_start = '1' ) then
                    v_tiles_left := mock_total_tiles - 1;
                    v_waiting    := true;
                    v_wait_cnt   := 4;

                elsif( tile_ready = '1' ) then
                    v_waiting  := true;
                    v_wait_cnt := 4;
                end if;
            end if;
        end if;
    end process;

    -- Main process.
    process

        procedure axi_write( addr : in integer; data : in std_logic_vector( 31 downto 0 ) ) is
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

        -- Margen de seguridad entre casos: dma_fsm tarda unos pocos ciclos en
        -- pasar DONE_LAYER -> IDLE tras el ultimo wr_done. Si un DMA_START
        -- siguiente llega mientras la FSM todavia esta en DONE_LAYER, r00_start
        -- ( reg_bank.vhd ) se autolimpia un ciclo despues sin que dma_fsm
        -- alcance a verlo en IDLE ( carrera confirmada con vsim: el Caso 4
        -- se colgaba porque solo tenia UNA escritura de registro antes del
        -- DMA_START, insuficiente margen ). 10 ciclos cubre esa transicion
        -- con sobra.
        procedure wait_dma_settle is
        begin
            for i in 1 to 10 loop
                wait until rising_edge( clk );
            end loop;
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

        report "=== INICIO TEST: dma_engine ( integracion completa ) ===";

        -- CASE 1.
        report "--- CASO 1: capa de 1 tile, todos los bordes, sin residual, sin pool ---";

        axi_write(  4, x"00000000" ); -- DMA_MODE.
        axi_write(  8, x"00000010" ); -- DMA_CIN = 16.
        axi_write( 12, x"00000010" ); -- DMA_COUT = 16.
        axi_write( 16, x"00000004" ); -- DMA_IMG_W = 4.
        axi_write( 20, x"00000002" ); -- DMA_IMG_H = 2.
        axi_write( 24, x"00000004" ); -- DMA_TILE_W = 4.
        axi_write( 28, x"00000002" ); -- DMA_TILE_H = 2.
        axi_write( 32, x"00000001" ); -- DMA_NUM_TILE_X = 1.
        axi_write( 36, x"00000001" ); -- DMA_NUM_TILE_Y = 1.
        axi_write( 40, x"00000000" ); -- DMA_HAS_RESIDUAL = 0.
        axi_write( 44, x"00000009" ); -- DMA_WEIGHT_WORDS = 9.
        axi_write( 48, x"00000800" ); -- DMA_ADDR_W.
        axi_write( 52, x"00000000" ); -- DMA_ADDR_IN.
        axi_write( 56, x"00001800" ); -- DMA_ADDR_OUT.
        axi_write( 60, x"00001000" ); -- DMA_ADDR_RES.
        axi_write( 68, x"00000000" ); -- DMA_POOL_EN = 0.
        axi_write( 72, x"00000000" ); -- DMA_POOL_TYPE = 0.

        mock_total_tiles <= 1;
        axi_write( 0, x"00000001" ); -- DMA_START.

        wait until local_wr_count = 33 and ddr_beat_count = 16;
        wait for 1 ns;

        report "--- Verificando pesos ( LOAD_WEIGHTS ) ---";
        assert captured_wb( 0 ) = std_logic_vector( to_unsigned( 257, 64 ) ) & std_logic_vector( to_unsigned( 256, 64 ) )
            report "FALLO caso 1: captured_wb(0)" severity error;
        assert captured_wb( 8 ) = std_logic_vector( to_unsigned( 273, 64 ) ) & std_logic_vector( to_unsigned( 272, 64 ) )
            report "FALLO caso 1: captured_wb(8)" severity error;

        report "--- Verificando IFM: fila r_local=0 ( skip top, todo cero ) ---";
        assert captured_if( 0 ) = ( captured_if( 0 )'range => '0' ) report "FALLO caso 1: captured_if(0) deberia ser 0" severity error;
        assert captured_if( 5 ) = ( captured_if( 5 )'range => '0' ) report "FALLO caso 1: captured_if(5) deberia ser 0" severity error;

        report "--- Verificando IFM: fila r_local=1 ( real, ambos bordes izq/der ) ---";
        assert captured_if( 6 )  = ( captured_if( 6 )'range => '0' )                                                   report "FALLO caso 1: captured_if(6) left zero"   severity error;
        assert captured_if( 7 )  = std_logic_vector( to_unsigned( 1, 64 ) ) & std_logic_vector( to_unsigned( 0, 64 ) ) report "FALLO caso 1: captured_if(7)"             severity error;
        assert captured_if( 10 ) = std_logic_vector( to_unsigned( 7, 64 ) ) & std_logic_vector( to_unsigned( 6, 64 ) ) report "FALLO caso 1: captured_if(10)"            severity error;
        assert captured_if( 11 ) = ( captured_if( 11 )'range => '0' )                                                  report "FALLO caso 1: captured_if(11) right zero" severity error;

        report "--- Verificando IFM: fila r_local=3 ( skip bottom, todo cero ) ---";
        assert captured_if( 18 ) = ( captured_if( 18 )'range => '0' ) report "FALLO caso 1: captured_if(18) deberia ser 0" severity error;
        assert captured_if( 23 ) = ( captured_if( 23 )'range => '0' ) report "FALLO caso 1: captured_if(23) deberia ser 0" severity error;

        report "--- Verificando OFM ( DDR de salida, addr_out = 0x1800, word_idx base 768 ) ---";
        assert ddr_mem( 768 ) = std_logic_vector( to_unsigned( 0, 64 ) )  report "FALLO caso 1: ddr_mem(768)" severity error;
        assert ddr_mem( 775 ) = std_logic_vector( to_unsigned( 7, 64 ) )  report "FALLO caso 1: ddr_mem(775)" severity error;
        assert ddr_mem( 776 ) = std_logic_vector( to_unsigned( 8, 64 ) )  report "FALLO caso 1: ddr_mem(776)" severity error;
        assert ddr_mem( 783 ) = std_logic_vector( to_unsigned( 15, 64 ) ) report "FALLO caso 1: ddr_mem(783)" severity error;

        report "--- CASO 1 OK ---";
        wait_dma_settle;

        -- CASE 2:
        report "--- CASO 2: capa de 2 tiles horizontales, con residual, sin pool ---";

        axi_write( 16, x"00000008" ); -- DMA_IMG_W = 8 ( 2 tiles of width = 4 ).
        axi_write( 32, x"00000002" ); -- DMA_NUM_TILE_X = 2.
        axi_write( 40, x"00000001" ); -- DMA_HAS_RESIDUAL = 1.

        mock_total_tiles <= 2;
        axi_write( 0, x"00000001" ); -- DMA_START.

        wait until local_wr_count = 33 + 9 + 24 + 8;
        wait for 1 ns;

        report "--- Verificando IFM tile0 ( borde izquierdo unicamente, r_local=1 ) ---";
        assert captured_if( 6 )  = ( captured_if( 6 )'range => '0' )                                                   report "FALLO caso 2 tile0: captured_if(6) left zero"                      severity error;
        assert captured_if( 7 )  = std_logic_vector( to_unsigned( 1, 64 ) ) & std_logic_vector( to_unsigned( 0, 64 ) ) report "FALLO caso 2 tile0: captured_if(7)"                                severity error;
        assert captured_if( 11 ) = std_logic_vector( to_unsigned( 9, 64 ) ) & std_logic_vector( to_unsigned( 8, 64 ) ) report "FALLO caso 2 tile0: captured_if(11) ( real, no hay zero derecho )" severity error;

        report "--- Verificando Residual tile0 ---";
        assert captured_rb( 0 ) = std_logic_vector( to_unsigned( 513, 64 ) ) & std_logic_vector( to_unsigned( 512, 64 ) )
            report "FALLO caso 2 tile0: captured_rb(0)" severity error;
        assert captured_rb( 3 ) = std_logic_vector( to_unsigned( 519, 64 ) ) & std_logic_vector( to_unsigned( 518, 64 ) )
            report "FALLO caso 2 tile0: captured_rb(3)" severity error;

        report "--- Tile0 OK, esperando tile1 ( NEXT_TILE via tile_req ) ---";

        wait until local_wr_count = 33 + 9 + 24 + 8 + 24 + 8 and ddr_beat_count = 16 + 16 + 16;
        wait for 1 ns;

        report "--- Verificando IFM tile1 ( borde derecho unicamente, r_local=1 ) ---";
        assert captured_if( 6 )  = std_logic_vector( to_unsigned( 7, 64 ) ) & std_logic_vector( to_unsigned( 6, 64 ) )  report "FALLO caso 2 tile1: captured_if(6) ( real, no hay zero izquierdo )" severity error;
        assert captured_if( 11 ) = ( captured_if( 11 )'range => '0' )                                                   report "FALLO caso 2 tile1: captured_if(11) right zero"                     severity error;

        report "--- Verificando Residual tile1 ---";
        assert captured_rb( 0 ) = std_logic_vector( to_unsigned( 521, 64 ) ) & std_logic_vector( to_unsigned( 520, 64 ) )
            report "FALLO caso 2 tile1: captured_rb(0)" severity error;
        assert captured_rb( 7 ) = std_logic_vector( to_unsigned( 543, 64 ) ) & std_logic_vector( to_unsigned( 542, 64 ) )
            report "FALLO caso 2 tile1: captured_rb(7)" severity error;

        report "--- CASO 2 OK ( NEXT_TILE + RES_READ/RES_NEXT verificados ) ---";
        wait_dma_settle;

        -- CASE 3:
        report "--- CASO 3: capa de 1 tile, sin residual, pool GAP ---";

        axi_write( 16, x"00000004" ); -- DMA_IMG_W = 4 ( back to tile 1 ).
        axi_write( 32, x"00000001" ); -- DMA_NUM_TILE_X = 1.
        axi_write( 40, x"00000000" ); -- DMA_HAS_RESIDUAL = 0.
        axi_write( 68, x"00000001" ); -- DMA_POOL_EN = 1.
        axi_write( 72, x"00000001" ); -- DMA_POOL_TYPE = 1 ( GAP ).

        mock_total_tiles <= 1;
        axi_write( 0, x"00000001" ); -- DMA_START.

        wait until local_wr_count = 106 + 9 + 24 and ddr_beat_count = 48 + 2;
        wait for 1 ns;

        report "--- Verificando GAP_FLUSH ( burst = cout_groups = 1 palabra = 2 beats ) ---";
        assert ddr_mem( 768 ) = std_logic_vector( to_unsigned( 0, 64 ) ) report "FALLO caso 3: ddr_mem(768) ( GAP )" severity error;
        assert ddr_mem( 769 ) = std_logic_vector( to_unsigned( 1, 64 ) ) report "FALLO caso 3: ddr_mem(769) ( GAP )" severity error;

        report "--- CASO 3 OK ( CHECK_OFM -> GAP_FLUSH sin pasar por OFM_WRITE ) ---";
        wait_dma_settle;

        -- CASE 4:
        report "--- CASO 4: capa de 1 tile, sin residual, pool MaxPool ---";

        axi_write( 72, x"00000000" ); -- DMA_POOL_TYPE = 0 ( MaxPool ).

        mock_total_tiles <= 1;
        axi_write( 0, x"00000001" ); -- DMA_START.

        wait until local_wr_count = 139 + 9 + 24 and ddr_beat_count = 50 + 4;
        wait for 1 ns;

        report "--- Verificando OFM con MaxPool ( 1 sola fila de salida, 2 palabras ) ---";
        assert ddr_mem( 768 ) = std_logic_vector( to_unsigned( 0, 64 ) ) report "FALLO caso 4: ddr_mem(768)" severity error;
        assert ddr_mem( 769 ) = std_logic_vector( to_unsigned( 1, 64 ) ) report "FALLO caso 4: ddr_mem(769)" severity error;
        assert ddr_mem( 770 ) = std_logic_vector( to_unsigned( 2, 64 ) ) report "FALLO caso 4: ddr_mem(770)" severity error;
        assert ddr_mem( 771 ) = std_logic_vector( to_unsigned( 3, 64 ) ) report "FALLO caso 4: ddr_mem(771)" severity error;

        report "--- CASO 4 OK ( OFM_NEXT con pool_en=1 confirmado: mitad de filas/columnas ) ---";

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
