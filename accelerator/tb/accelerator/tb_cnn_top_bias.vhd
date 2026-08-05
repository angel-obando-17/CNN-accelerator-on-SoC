library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench de integracion completa de cnn_top CON SOPORTE DE BIAS: mismo
-- patron que tb_cnn_top.vhd (acelerador real + DMA real, DDR falsa
-- bidireccional), pero cada capa ahora carga bias via DMA (LOAD_BIAS) y el
-- valor esperado incluye la suma de bias antes del shift.
--
-- Direcciones DDR: cada bloque de capa vive en su propio rango de 0x4000
-- bytes ( CASE_BASE = n * 0x4000 ). Dentro de cada bloque:
--   ADDR_W    = +0x0000
--   ADDR_IN   = +0x1000
--   ADDR_OUT  = +0x2000
--   ADDR_RES  = +0x3000
--   ADDR_BIAS = +0x3800  ( nuevo -- 4 palabras locales de 128b = 16 canales
--                          int32, cabe holgado antes del siguiente bloque )
--
-- CASO A (PW1x1): bias DIFERENTE por grupo de 4 canales (0,1,2,3 en canales
-- 0-3/4-7/8-11/12-15) -- verifica que bias_buf indexa wr_addr/rd_addr bien,
-- no solo que "algun" bias se sume (un bias uniforme no distinguiria un bug
-- de indexado de un bias correcto).
-- CASOS B/C/D: bias uniforme por capa, verifica Conv3x3/DW3x3/Residual.
-- CASO E: cadena real de 2 capas (PW1x1 -> PW1x1+GAP, igual patron que el
-- Caso 8 de tb_cnn_top.vhd) con bias DISTINTO por capa -- confirma que
-- LOAD_BIAS recarga el buffer correctamente en cada DMA_START, no arrastra
-- el bias de la capa anterior.
--
-- Todos los valores esperados se escogieron para que la division por
-- 2**shift sea EXACTA (sin redondeo), evitando ambiguedad de shift
-- aritmetico en la verificacion manual.

entity tb_cnn_top_bias is
end tb_cnn_top_bias;

architecture Behavioral of tb_cnn_top_bias is

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

    -- DDR falsa BIDIRECCIONAL. Arranca con TODO en 0x01 repetido ( pesos y
    -- activaciones de todos los casos ), con overrides puntuales para las
    -- regiones de bias ( 0x01010101 como int32 NO sirve como bias pequeno,
    -- asi que cada region de bias se sobreescribe explicitamente ).
    constant DDR_WORDS : integer := 32768;
    type ddr_mem_array is array( 0 to DDR_WORDS - 1 ) of std_logic_vector( 63 downto 0 );

    signal ddr_mem : ddr_mem_array := (
        -- Caso A ( PW1x1 ): bias por grupo de 4 canales -- 0,1,2,3.
        1792 => x"0000000000000000", 1793 => x"0000000000000000",
        1794 => x"0000000100000001", 1795 => x"0000000100000001",
        1796 => x"0000000200000002", 1797 => x"0000000200000002",
        1798 => x"0000000300000003", 1799 => x"0000000300000003",
        -- Caso B ( Conv3x3 ): bias uniforme = 16 ( multiplo limpio de 2**shift=16 ).
        3840 => x"0000001000000010", 3841 => x"0000001000000010",
        3842 => x"0000001000000010", 3843 => x"0000001000000010",
        3844 => x"0000001000000010", 3845 => x"0000001000000010",
        3846 => x"0000001000000010", 3847 => x"0000001000000010",
        -- Caso C ( DW3x3 ): bias uniforme = 1.
        5888 => x"0000000100000001", 5889 => x"0000000100000001",
        5890 => x"0000000100000001", 5891 => x"0000000100000001",
        5892 => x"0000000100000001", 5893 => x"0000000100000001",
        5894 => x"0000000100000001", 5895 => x"0000000100000001",
        -- Caso D ( PW1x1 + Residual ): bias uniforme = 3.
        7936 => x"0000000300000003", 7937 => x"0000000300000003",
        7938 => x"0000000300000003", 7939 => x"0000000300000003",
        7940 => x"0000000300000003", 7941 => x"0000000300000003",
        7942 => x"0000000300000003", 7943 => x"0000000300000003",
        -- Caso E, Capa 1 ( PW1x1 ): bias uniforme = 5.
        9984 => x"0000000500000005", 9985 => x"0000000500000005",
        9986 => x"0000000500000005", 9987 => x"0000000500000005",
        9988 => x"0000000500000005", 9989 => x"0000000500000005",
        9990 => x"0000000500000005", 9991 => x"0000000500000005",
        -- Caso E, Capa 2 ( PW1x1 + GAP ): bias uniforme = 16.
        12032 => x"0000001000000010", 12033 => x"0000001000000010",
        12034 => x"0000001000000010", 12035 => x"0000001000000010",
        12036 => x"0000001000000010", 12037 => x"0000001000000010",
        12038 => x"0000001000000010", 12039 => x"0000001000000010",
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

        -- Standard config of DMA for tile NxN, CON bias ( bias_words_v /
        -- addr_bias_v -- offsets 0x4C / 0x50 nuevos de reg_bank.vhd ).
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

        report "=== INICIO tb_cnn_top_bias: soporte de bias en el datapath ===";

        -- CASO A: PW1x1, bias DIFERENTE por grupo de 4 canales.
        -- sum = Cin(16) x act(1) x w(1) = 16. shift = 0.
        --   ch0-3   bias=0 -> 16 = 0x10
        --   ch4-7   bias=1 -> 17 = 0x11
        --   ch8-11  bias=2 -> 18 = 0x12
        --   ch12-15 bias=3 -> 19 = 0x13
        -- Palabra baja  ( canales 7..0 )  = 0x1111111110101010.
        -- Palabra alta  ( canales 15..8 ) = 0x1313131312121212.
        report "--- CASO A: PW1x1 + bias por grupo de canales ---";
        cfg_accel( "10", 16, 1, 1, 0, 0, 0, 0, 0 );
        cfg_dma( 2, 0, 16, 16#00000#, 16#01000#, 16#02000#, 16#03000#, 0, 0, 4, 16#03800# );
        run_layer_and_ack;

        check( ddr_mem( 1024 ), x"1111111110101010", "CasoA pixel(0,0) canales 0-7" );
        check( ddr_mem( 1025 ), x"1313131312121212", "CasoA pixel(0,0) canales 8-15" );
        check( ddr_mem( 1026 ), x"1111111110101010", "CasoA pixel(0,1) canales 0-7" );
        check( ddr_mem( 1027 ), x"1313131312121212", "CasoA pixel(0,1) canales 8-15" );
        check( ddr_mem( 1028 ), x"1111111110101010", "CasoA pixel(1,0) canales 0-7" );
        check( ddr_mem( 1029 ), x"1313131312121212", "CasoA pixel(1,0) canales 8-15" );
        check( ddr_mem( 1030 ), x"1111111110101010", "CasoA pixel(1,1) canales 0-7" );
        check( ddr_mem( 1031 ), x"1313131312121212", "CasoA pixel(1,1) canales 8-15" );
        ack_dma_done;
        report "=== CASO A OK ===";

        -- CASO B: Conv3x3, bias uniforme = 16 antes del shift.
        -- sum (tile esquina, 4/9 taps validos) = 64. + bias 16 = 80.
        -- shift = 4 -> 80 >> 4 = 5 = 0x05 ( division exacta ).
        report "--- CASO B: Conv3x3 + bias uniforme (verifica orden bias-antes-de-shift) ---";
        cfg_accel( "00", 144, 1, 1, 0, 0, 0, 4, 0 );
        cfg_dma( 2, 0, 144, 16#04000#, 16#05000#, 16#06000#, 16#07000#, 0, 0, 4, 16#07800# );
        run_layer_and_ack;

        check( ddr_mem( 3072 ), x"0505050505050505", "CasoB pixel(0,0)" );
        check( ddr_mem( 3074 ), x"0505050505050505", "CasoB pixel(0,1)" );
        check( ddr_mem( 3076 ), x"0505050505050505", "CasoB pixel(1,0)" );
        check( ddr_mem( 3078 ), x"0505050505050505", "CasoB pixel(1,1)" );
        ack_dma_done;
        report "=== CASO B OK ===";

        -- CASO C: DW3x3, bias uniforme = 1.
        -- sum (tile esquina, 4/9 taps validos, sin loop de Cin) = 4. + bias 1 = 5.
        -- shift = 0 -> 5 = 0x05.
        report "--- CASO C: DW3x3 + bias uniforme ---";
        cfg_accel( "01", 9, 1, 1, 0, 0, 0, 0, 0 );
        cfg_dma( 2, 0, 9, 16#08000#, 16#09000#, 16#0A000#, 16#0B000#, 0, 0, 4, 16#0B800# );
        run_layer_and_ack;

        check( ddr_mem( 5120 ), x"0505050505050505", "CasoC pixel(0,0)" );
        check( ddr_mem( 5122 ), x"0505050505050505", "CasoC pixel(0,1)" );
        check( ddr_mem( 5124 ), x"0505050505050505", "CasoC pixel(1,0)" );
        check( ddr_mem( 5126 ), x"0505050505050505", "CasoC pixel(1,1)" );
        ack_dma_done;
        report "=== CASO C OK ===";

        -- CASO D: PW1x1 + Residual, bias uniforme = 3.
        -- sum = 16. + bias 3 = 19 = 0x13 ( post quant_relu, PRE residual ).
        -- + residual ( datos por defecto = 0x01 ) = 0x14.
        report "--- CASO D: PW1x1 + Residual + bias (bias antes de la suma residual) ---";
        cfg_accel( "10", 16, 1, 1, 1, 0, 0, 0, 0 );
        cfg_dma( 2, 1, 16, 16#0C000#, 16#0D000#, 16#0E000#, 16#0F000#, 0, 0, 4, 16#0F800# );
        run_layer_and_ack;

        check( ddr_mem( 7168 ), x"1414141414141414", "CasoD pixel(0,0)" );
        check( ddr_mem( 7170 ), x"1414141414141414", "CasoD pixel(0,1)" );
        check( ddr_mem( 7172 ), x"1414141414141414", "CasoD pixel(1,0)" );
        check( ddr_mem( 7174 ), x"1414141414141414", "CasoD pixel(1,1)" );
        ack_dma_done;
        report "=== CASO D OK ===";

        -- CASO E: red de 2 capas encadenadas ( Capa2.IN = Capa1.OUT ), cada
        -- una con bias DISTINTO -- confirma que LOAD_BIAS recarga el buffer
        -- en cada DMA_START y no arrastra el bias de la capa anterior.
        report "--- CASO E: red de 2 capas (PW1x1 -> PW1x1+GAP), bias distinto por capa ---";

        report "--- Capa 1: PW1x1, bias = 5 -> sum 16 + 5 = 21 = 0x15 ---";
        cfg_accel( "10", 16, 1, 1, 0, 0, 0, 0, 0 );
        cfg_dma( 2, 0, 16, 16#10000#, 16#11000#, 16#12000#, 16#13000#, 0, 0, 4, 16#13800# );
        run_layer_and_ack;

        check( ddr_mem( 9216 ), x"1515151515151515", "CasoE capa1 pixel(0,0)" );
        check( ddr_mem( 9218 ), x"1515151515151515", "CasoE capa1 pixel(0,1)" );
        check( ddr_mem( 9220 ), x"1515151515151515", "CasoE capa1 pixel(1,0)" );
        check( ddr_mem( 9222 ), x"1515151515151515", "CasoE capa1 pixel(1,1)" );

        ack_dma_done;

        report "--- Capa 2: PW1x1 + GAP, IN = OUT de capa1 (act=21), bias = 16 ---";
        -- sum = Cin(16) x act(21) x w(1) = 336. + bias 16 = 352.
        -- shift = 4 -> 352 >> 4 = 22 = 0x16 ( division exacta ) por pixel.
        -- GAP: suma 4 pixeles x 22 = 88. gap_shift = 2 -> 88 >> 2 = 22 = 0x16.
        cfg_accel( "10", 16, 1, 1, 0, 1, 1, 4, 2 );
        cfg_dma( 2, 0, 16, 16#14000#, 16#12000#, 16#16000#, 16#17000#, 1, 1, 4, 16#17800# );
        run_layer_and_ack;

        check( ddr_mem( 11264 ), x"1616161616161616", "CasoE capa2 GAP" );
        ack_dma_done;
        report "=== CASO E OK (red de 2 capas + recarga de bias entre capas verificada) ===";

        report "=== RESUMEN: " & integer'image( errors ) & " fallo(s) ===" severity note;
        if( errors = 0 ) then
            report "=== TODOS LOS CASOS PASARON ===" severity note;
        else
            report "=== HAY CASOS CON FALLOS, revisar arriba ===" severity error;
        end if;

        wait;
    end process;

end Behavioral;
