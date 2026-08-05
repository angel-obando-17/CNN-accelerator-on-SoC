library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench "hardcore": stress combinado del acelerador completo (acelerador
-- + DMA reales contra DDR falsa bidireccional, mismo patron que
-- tb_cnn_top.vhd / tb_cnn_top_bias.vhd), buscando romper el datapath con
-- combinaciones que NINGUN testbench anterior probo juntas:
--
--   CASO F: PW1x1 + MaxPool + 2 GRUPOS de co ( Cout=32 ) + bias DISTINTO
--           por grupo -- primera vez que se ejercita bias_buf.rd_addr
--           variando ( antes siempre fue "00" fijo, Cout<=16 ).
--   CASO G: PW1x1, 2 tiles horizontales ( TILE_WAIT ) con MISMO bias --
--           confirma que LOAD_BIAS carga una sola vez por capa y el bias
--           no se corrompe/recarga entre tiles de la misma capa.
--   CASO H: PW1x1 + MaxPool, bias muy NEGATIVO -- fuerza el acumulador a
--           negativo, confirma que ReLU6 lo satura a 0 ( no wrap-around ).
--   CASO I: PW1x1 + GAP, bias muy POSITIVO + relu6_val chico -- fuerza la
--           cadena COMPLETA de saturacion: clamp a int8 (127) primero, LUEGO
--           tope de ReLU6, con GAP encima.
--   CASO J: cadena real de 3 capas ( Conv3x3 -> DW3x3 -> PW1x1+GAP ) donde
--           cada capa consume la salida REAL de la anterior (no datos por
--           defecto) y cada una tiene su propio bias -- la prueba mas
--           parecida a un "modelo de verdad" de todo este bloque.
--   CASO K: PW1x1 + Residual, bias alto que deja el valor cerca del techo
--           y un residual que lo empuja a superar 127 -- ejercita el clamp
--           PROPIO de add_unit.vhd (independiente del de quant_relu.vhd),
--           nunca antes forzado a saturar en ningun testbench previo.
--   CASO L: PW1x1 + GAP + 2 GRUPOS de co ( Cout=32 ) + bias distinto por
--           grupo -- confirma que el fix de co_counter_reg (ver mas abajo)
--           tambien corrige gap_unit.vhd, mismo patron de bug que max_pool.
--
-- FIX APLICADO (2026-07-30, ver seccion de memoria del proyecto para el
-- diagnostico completo): los Casos F y L fallaban originalmente porque
-- max_pool.vhd/gap_unit.vhd indexaban su estado interno con co_counter EN
-- VIVO, que ya habia avanzado al siguiente grupo para cuando el dato del
-- grupo actual llegaba. Fix: nueva senal co_counter_reg en
-- cnn_accelerator.vhd (capturada en el mismo punto que ofbuf_wr_addr_reg),
-- alimentando inst_pool_unit.co_counter en vez de ag_co_counter en vivo.
-- Ademas se encontro y corrigio un segundo bug relacionado: max_pool.vhd no
-- tenia ningun mecanismo de limpieza entre capas ( a diferencia de
-- gap_unit.vhd, que ya limpia gap_acc via acc_clear ) -- una capa MaxPool
-- podia leer basura que dejo la capa MaxPool anterior. Fix: puerto
-- acc_clear nuevo en max_pool.vhd ( igual patron que gap_unit.vhd ),
-- conectado desde pool_unit.vhd ( que ya recibia acc_clear pero solo se lo
-- pasaba a gap_unit ).
--
-- Todos los valores se escogieron para division EXACTA por 2**shift
-- (evita ambiguedad de redondeo en la verificacion manual). Direcciones:
-- mismo esquema de bloques de 0x4000 bytes que tb_cnn_top_bias.vhd
-- ( +0x0000=W, +0x1000=IN, +0x2000=OUT, +0x3000=RES, +0x3800=BIAS ).
--
-- HALLAZGO DE DISENO (no es bug de esta sesion, descubierto al dimensionar
-- el Caso F): DMA_WEIGHT_WORDS es un registro de 8 bits (reg_bank.vhd,
-- offset 0x2C). Conv3x3 con Cin=16 y 2 grupos de Cout ya necesita
-- weight_words = 16*9*2 = 288, que DESBORDA el registro de 8 bits
-- (max 255) -- se trunca silenciosamente a 32. Por eso el Caso F usa
-- PW1x1 (weight_words=32, cabe) en vez de Conv3x3 para probar bias_buf
-- con 2 grupos -- probar bias no depende del modo de conv, asi que no se
-- pierde cobertura, pero el limite de Conv3x3 con Cout>16 (dado Cin=16)
-- queda documentado como hallazgo real para revisar aparte.

entity tb_cnn_top_hardcore is
end tb_cnn_top_hardcore;

architecture Behavioral of tb_cnn_top_hardcore is

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

    constant DDR_WORDS : integer := 32768;
    type ddr_mem_array is array( 0 to DDR_WORDS - 1 ) of std_logic_vector( 63 downto 0 );

    signal ddr_mem : ddr_mem_array := (
        -- Caso F ( PW1x1 + MaxPool + 2 grupos ): bias grupo0=0, grupo1=5.
        1792 => x"0000000000000000", 1793 => x"0000000000000000",
        1794 => x"0000000000000000", 1795 => x"0000000000000000",
        1796 => x"0000000000000000", 1797 => x"0000000000000000",
        1798 => x"0000000000000000", 1799 => x"0000000000000000",
        1800 => x"0000000500000005", 1801 => x"0000000500000005",
        1802 => x"0000000500000005", 1803 => x"0000000500000005",
        1804 => x"0000000500000005", 1805 => x"0000000500000005",
        1806 => x"0000000500000005", 1807 => x"0000000500000005",
        -- Caso G ( 2 tiles, TILE_WAIT ): bias uniforme = 10 ( igual para
        -- ambos tiles, cargado UNA vez ). Activaciones distintas por tile
        -- ( offsets identicos a los usados en tb_cnn_top.vhd Caso 7,
        -- reubicados a la base de este caso ).
        2564 => x"0202020202020202", 2565 => x"0202020202020202",
        2566 => x"0202020202020202", 2567 => x"0202020202020202",
        2572 => x"0202020202020202", 2573 => x"0202020202020202",
        2574 => x"0202020202020202", 2575 => x"0202020202020202",
        3840 => x"0000000A0000000A", 3841 => x"0000000A0000000A",
        3842 => x"0000000A0000000A", 3843 => x"0000000A0000000A",
        3844 => x"0000000A0000000A", 3845 => x"0000000A0000000A",
        3846 => x"0000000A0000000A", 3847 => x"0000000A0000000A",
        -- Caso H ( PW1x1 + MaxPool ): bias = -50 ( 0xFFFFFFCE ).
        5888 => x"FFFFFFCEFFFFFFCE", 5889 => x"FFFFFFCEFFFFFFCE",
        5890 => x"FFFFFFCEFFFFFFCE", 5891 => x"FFFFFFCEFFFFFFCE",
        5892 => x"FFFFFFCEFFFFFFCE", 5893 => x"FFFFFFCEFFFFFFCE",
        5894 => x"FFFFFFCEFFFFFFCE", 5895 => x"FFFFFFCEFFFFFFCE",
        -- Caso I ( PW1x1 + GAP ): bias = 200 ( 0x000000C8 ).
        7936 => x"000000C8000000C8", 7937 => x"000000C8000000C8",
        7938 => x"000000C8000000C8", 7939 => x"000000C8000000C8",
        7940 => x"000000C8000000C8", 7941 => x"000000C8000000C8",
        7942 => x"000000C8000000C8", 7943 => x"000000C8000000C8",
        -- Caso J, Capa 1 ( Conv3x3 ): bias uniforme = 16.
        9984 => x"0000001000000010", 9985 => x"0000001000000010",
        9986 => x"0000001000000010", 9987 => x"0000001000000010",
        9988 => x"0000001000000010", 9989 => x"0000001000000010",
        9990 => x"0000001000000010", 9991 => x"0000001000000010",
        -- Caso J, Capa 2 ( DW3x3 ): bias uniforme = 12.
        12032 => x"0000000C0000000C", 12033 => x"0000000C0000000C",
        12034 => x"0000000C0000000C", 12035 => x"0000000C0000000C",
        12036 => x"0000000C0000000C", 12037 => x"0000000C0000000C",
        12038 => x"0000000C0000000C", 12039 => x"0000000C0000000C",
        -- Caso J, Capa 3 ( PW1x1 + GAP ): bias uniforme = 32.
        14080 => x"0000002000000020", 14081 => x"0000002000000020",
        14082 => x"0000002000000020", 14083 => x"0000002000000020",
        14084 => x"0000002000000020", 14085 => x"0000002000000020",
        14086 => x"0000002000000020", 14087 => x"0000002000000020",
        -- Caso K ( PW1x1 + Residual ): bias = 104 ( 0x00000068 ), y
        -- residual sobreescrito a 0x0A ( en vez del 0x01 por defecto ) para
        -- forzar la suma por encima de 127 y saturar en add_unit.
        15872 => x"0A0A0A0A0A0A0A0A", 15873 => x"0A0A0A0A0A0A0A0A",
        15874 => x"0A0A0A0A0A0A0A0A", 15875 => x"0A0A0A0A0A0A0A0A",
        15876 => x"0A0A0A0A0A0A0A0A", 15877 => x"0A0A0A0A0A0A0A0A",
        15878 => x"0A0A0A0A0A0A0A0A", 15879 => x"0A0A0A0A0A0A0A0A",
        16128 => x"0000006800000068", 16129 => x"0000006800000068",
        16130 => x"0000006800000068", 16131 => x"0000006800000068",
        16132 => x"0000006800000068", 16133 => x"0000006800000068",
        16134 => x"0000006800000068", 16135 => x"0000006800000068",
        -- Caso L ( PW1x1 + GAP + 2 grupos de co ): bias grupo0=0, grupo1=5
        -- ( base 0x23800/8=18176 ) -- confirma que el mismo fix de
        -- co_counter_reg tambien corrige gap_unit.vhd.
        18176 => x"0000000000000000", 18177 => x"0000000000000000",
        18178 => x"0000000000000000", 18179 => x"0000000000000000",
        18180 => x"0000000000000000", 18181 => x"0000000000000000",
        18182 => x"0000000000000000", 18183 => x"0000000000000000",
        18184 => x"0000000500000005", 18185 => x"0000000500000005",
        18186 => x"0000000500000005", 18187 => x"0000000500000005",
        18188 => x"0000000500000005", 18189 => x"0000000500000005",
        18190 => x"0000000500000005", 18191 => x"0000000500000005",
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
            axi_write_accel( 28, x"00000000" ); -- MAX_TILE_X = 0.
            axi_write_accel( 32, x"00000000" ); -- MAX_TILE_Y = 0.
            axi_write_accel( 36, std_logic_vector( to_unsigned( has_res, 32 ) ) );
            axi_write_accel( 40, std_logic_vector( to_unsigned( pool_en_v, 32 ) ) );
            axi_write_accel( 44, std_logic_vector( to_unsigned( pool_type_v, 32 ) ) );
            axi_write_accel( 48, std_logic_vector( to_unsigned( shift_v, 32 ) ) );
            axi_write_accel( 52, x"0000007F" ); -- RELU6_VAL = 127 ( override despues si hace falta ).
            axi_write_accel( 56, std_logic_vector( to_unsigned( gap_shift_v, 32 ) ) );
            -- REG_MULT (0x3C) no existia cuando se escribio este testbench.
            -- Se fija a ~1.0 (0xFFFF, M0~=0.99998 en Q0.16) para que el
            -- multiplicador nuevo sea esencialmente un no-op y no cambie
            -- ninguno de los valores esperados ya calculados abajo -- este
            -- testbench sigue siendo sobre bias/pool/etc, no sobre el
            -- multiplicador (ese se prueba aparte, con M0 no trivial).
            axi_write_accel( 60, x"0000FFFF" );
        end procedure;

        -- Standard config of DMA for tile NxN, CON bias. DMA_COUT queda en
        -- 16 por defecto ( override despues si hace falta, ej. Caso F ).
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

        report "=== INICIO tb_cnn_top_hardcore: stress combinado del datapath completo ===";

        -- CASO F ( CON FIX ): PW1x1 + MaxPool + 2 grupos de co ( Cout=32 ),
        -- bias distinto por grupo ( grupo0=0, grupo1=5 ). Esto FALLABA antes
        -- del fix de co_counter_reg -- ver HALLAZGO DE BUG al final del
        -- archivo para el detalle completo (diagnostico + fix real aplicado
        -- en cnn_accelerator.vhd/max_pool.vhd/pool_unit.vhd). sum=16 por
        -- canal, shift=0. grupo0: 16+0=16=0x10. grupo1: 16+5=21=0x15.
        -- MaxPool de pixeles identicos no cambia el valor.
        report "--- CASO F: PW1x1 + MaxPool + 2 grupos de co + bias por grupo ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 0, 0, 0 );
        axi_write_accel( 16, x"00000001" ); -- MAX_CO = 1 ( 2 grupos ).
        cfg_dma( 2, 0, 32, 16#00000#, 16#01000#, 16#02000#, 16#03000#, 1, 0, 8, 16#03800# );
        axi_write_dma( 12, x"00000020" ); -- DMA_COUT = 32.
        run_layer_and_ack;

        check( ddr_mem( 1024 ), x"1010101010101010", "CasoF grupo0 (co=0, canales 0-15) -- pooled" );
        check( ddr_mem( 1026 ), x"1515151515151515", "CasoF grupo1 (co=1, canales 16-31) -- pooled" );
        ack_dma_done;
        report "=== CASO F OK (fix de max_pool.vhd/co_counter_reg verificado con MaxPool real) ===";

        -- CASO G: PW1x1, 2 tiles horizontales ( TILE_WAIT ), MISMO bias=10
        -- para ambas ( LOAD_BIAS solo corre una vez, antes del loop de
        -- tiles ). tile0 act=1 -> 16+10=26=0x1A. tile1 act=2 -> 32+10=42=0x2A.
        report "--- CASO G: PW1x1, 2 tiles (TILE_WAIT), bias compartido entre tiles ---";
        cfg_accel( "10", 16, 1, 1, 0, 0, 0, 0, 0 );
        axi_write_accel( 28, x"00000001" ); -- MAX_TILE_X = 1 ( 2 tiles ).

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
        axi_write_dma( 48, x"00004000" ); -- DMA_ADDR_W.
        axi_write_dma( 52, x"00005000" ); -- DMA_ADDR_IN.
        axi_write_dma( 56, x"00006000" ); -- DMA_ADDR_OUT.
        axi_write_dma( 60, x"00007000" ); -- DMA_ADDR_RES.
        axi_write_dma( 68, x"00000000" ); -- DMA_POOL_EN = 0.
        axi_write_dma( 72, x"00000000" ); -- DMA_POOL_TYPE = 0.
        axi_write_dma( 76, x"00000004" ); -- DMA_BIAS_WORDS = 4.
        axi_write_dma( 80, x"00007800" ); -- DMA_ADDR_BIAS.

        run_layer_and_ack;

        report "--- tile0 (act=1, esperado 0x1A) ---";
        check( ddr_mem( 3072 ), x"1A1A1A1A1A1A1A1A", "CasoG tile0 pixel(0,0)" );
        check( ddr_mem( 3074 ), x"1A1A1A1A1A1A1A1A", "CasoG tile0 pixel(0,1)" );
        check( ddr_mem( 3080 ), x"1A1A1A1A1A1A1A1A", "CasoG tile0 pixel(1,0)" );
        check( ddr_mem( 3082 ), x"1A1A1A1A1A1A1A1A", "CasoG tile0 pixel(1,1)" );

        report "--- tile1 (act=2, esperado 0x2A -- mismo bias, activacion distinta) ---";
        check( ddr_mem( 3076 ), x"2A2A2A2A2A2A2A2A", "CasoG tile1 pixel(0,0)" );
        check( ddr_mem( 3078 ), x"2A2A2A2A2A2A2A2A", "CasoG tile1 pixel(0,1)" );
        check( ddr_mem( 3084 ), x"2A2A2A2A2A2A2A2A", "CasoG tile1 pixel(1,0)" );
        check( ddr_mem( 3086 ), x"2A2A2A2A2A2A2A2A", "CasoG tile1 pixel(1,1)" );
        ack_dma_done;
        report "=== CASO G OK (bias no se corrompe entre tiles de la misma capa) ===";

        -- CASO H: PW1x1 + MaxPool, bias = -50. sum=16, acc=16-50=-34.
        -- shift=0 -> -34. clamp_int8(-34)=-34 (dentro de rango). ReLU6:
        -- -34<0 -> 0. MaxPool de cuatro 0 = 0.
        report "--- CASO H: PW1x1 + MaxPool, bias muy negativo -> satura a 0 via ReLU6 ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 0, 0, 0 );
        cfg_dma( 2, 0, 16, 16#08000#, 16#09000#, 16#0A000#, 16#0B000#, 1, 0, 4, 16#0B800# );
        run_layer_and_ack;

        check( ddr_mem( 5120 ), x"0000000000000000", "CasoH pooled (bias=-50 -> 0x00, no wrap-around)" );
        ack_dma_done;
        report "=== CASO H OK ===";

        -- CASO I: PW1x1 + GAP, bias = 200, relu6_val = 6. sum=16,
        -- acc=16+200=216. shift=0 -> 216. clamp_int8(216)=127 (satura
        -- primero a int8). ReLU6: 127>relu6_val(6) -> 6. GAP: 4x6=24,
        -- gap_shift=1 -> 24>>1=12=0x0C.
        report "--- CASO I: PW1x1 + GAP, bias muy positivo + relu6_val chico -> cadena completa de clamp ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 1, 0, 1 );
        axi_write_accel( 52, x"00000006" ); -- RELU6_VAL = 6.
        cfg_dma( 2, 0, 16, 16#0C000#, 16#0D000#, 16#0E000#, 16#0F000#, 1, 1, 4, 16#0F800# );
        run_layer_and_ack;

        check( ddr_mem( 7168 ), x"0C0C0C0C0C0C0C0C", "CasoI GAP (clamp_int8=127 -> ReLU6 cap=6 -> GAP=12)" );
        ack_dma_done;
        report "=== CASO I OK ===";

        -- CASO J: cadena real de 3 capas, cada una consume la salida REAL
        -- de la anterior (no datos por defecto) y tiene su propio bias.
        report "--- CASO J: red de 3 capas con datos propagados (Conv3x3 -> DW3x3 -> PW1x1+GAP) ---";

        report "--- Capa 1 (Conv3x3): sum=64 (esquina, 4/9 taps) + bias16 = 80, shift4 -> 5 = 0x05 ---";
        cfg_accel( "00", 144, 1, 1, 0, 0, 0, 4, 0 );
        cfg_dma( 2, 0, 144, 16#10000#, 16#11000#, 16#12000#, 16#13000#, 0, 0, 4, 16#13800# );
        run_layer_and_ack;

        check( ddr_mem( 9216 ), x"0505050505050505", "CasoJ capa1 pixel(0,0)" );
        check( ddr_mem( 9218 ), x"0505050505050505", "CasoJ capa1 pixel(0,1)" );
        check( ddr_mem( 9220 ), x"0505050505050505", "CasoJ capa1 pixel(1,0)" );
        check( ddr_mem( 9222 ), x"0505050505050505", "CasoJ capa1 pixel(1,1)" );
        ack_dma_done;

        report "--- Capa 2 (DW3x3): IN=act 0x05 real de capa1. sum=4x(1x5)=20 + bias12 = 32, shift2 -> 8 = 0x08 ---";
        cfg_accel( "01", 9, 1, 1, 0, 0, 0, 2, 0 );
        cfg_dma( 2, 0, 9, 16#14000#, 16#12000#, 16#16000#, 16#17000#, 0, 0, 4, 16#17800# );
        run_layer_and_ack;

        check( ddr_mem( 11264 ), x"0808080808080808", "CasoJ capa2 pixel(0,0)" );
        check( ddr_mem( 11266 ), x"0808080808080808", "CasoJ capa2 pixel(0,1)" );
        check( ddr_mem( 11268 ), x"0808080808080808", "CasoJ capa2 pixel(1,0)" );
        check( ddr_mem( 11270 ), x"0808080808080808", "CasoJ capa2 pixel(1,1)" );
        ack_dma_done;

        report "--- Capa 3 (PW1x1+GAP): IN=act 0x08 real de capa2. sum=16x8=128 + bias32 = 160, shift4 -> 10; GAP 4x10=40, gap_shift2 -> 10 = 0x0A ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 1, 4, 2 );
        cfg_dma( 2, 0, 16, 16#18000#, 16#16000#, 16#1A000#, 16#1B000#, 1, 1, 4, 16#1B800# );
        run_layer_and_ack;

        check( ddr_mem( 13312 ), x"0A0A0A0A0A0A0A0A", "CasoJ capa3 GAP (fin de la cadena)" );
        ack_dma_done;
        report "=== CASO J OK (3 capas encadenadas con datos reales, bias correcto en cada una) ===";

        -- CASO K: PW1x1 + Residual, bias = 104. sum=16, acc=16+104=120.
        -- shift=0 -> 120. clamp_int8(120)=120 (bajo el limite). ReLU6:
        -- 120<127 -> 120 = 0x78 ( post quant_relu, PRE residual ).
        -- Residual sobreescrito a 0x0A ( en vez de 0x01 por defecto ):
        -- add_unit: 120+10=130 > 127 -> SU PROPIO clamp satura a 127=0x7F.
        report "--- CASO K: PW1x1 + Residual, bias alto + residual que fuerza saturacion en add_unit ---";
        cfg_accel( "10", 16, 1, 1, 1, 0, 0, 0, 0 );
        cfg_dma( 2, 1, 16, 16#1C000#, 16#1D000#, 16#1E000#, 16#1F000#, 0, 0, 4, 16#1F800# );
        run_layer_and_ack;

        check( ddr_mem( 15360 ), x"7F7F7F7F7F7F7F7F", "CasoK pixel(0,0) (120+10=130 -> satura a 127 en add_unit)" );
        check( ddr_mem( 15362 ), x"7F7F7F7F7F7F7F7F", "CasoK pixel(0,1)" );
        check( ddr_mem( 15364 ), x"7F7F7F7F7F7F7F7F", "CasoK pixel(1,0)" );
        check( ddr_mem( 15366 ), x"7F7F7F7F7F7F7F7F", "CasoK pixel(1,1)" );
        ack_dma_done;
        report "=== CASO K OK (saturacion propia de add_unit verificada con bias real) ===";

        -- CASO L: PW1x1 + GAP + 2 grupos de co ( Cout=32 ), bias distinto
        -- por grupo -- confirma que el fix de co_counter_reg TAMBIEN corrige
        -- gap_unit.vhd (mismo patron de codigo que max_pool.vhd,
        -- gap_acc(co_counter)). grupo0: quant=16 c/pixel, GAP 4x16=64,
        -- gap_shift2 -> 16=0x10. grupo1: quant=21 c/pixel, GAP 4x21=84,
        -- gap_shift2 -> 21=0x15.
        report "--- CASO L: PW1x1 + GAP + 2 grupos de co + bias por grupo ---";
        cfg_accel( "10", 16, 1, 1, 0, 1, 1, 0, 2 );
        axi_write_accel( 16, x"00000001" ); -- MAX_CO = 1 ( 2 grupos ).
        cfg_dma( 2, 0, 32, 16#20000#, 16#21000#, 16#22000#, 16#23000#, 1, 1, 8, 16#23800# );
        axi_write_dma( 12, x"00000020" ); -- DMA_COUT = 32.
        run_layer_and_ack;

        check( ddr_mem( 17408 ), x"1010101010101010", "CasoL grupo0 (co=0) -- GAP" );
        check( ddr_mem( 17410 ), x"1515151515151515", "CasoL grupo1 (co=1) -- GAP" );
        ack_dma_done;
        report "=== CASO L OK (fix de gap_unit.vhd/co_counter_reg verificado con GAP real) ===";

        report "=== RESUMEN: " & integer'image( errors ) & " fallo(s) ===" severity note;
        if( errors = 0 ) then
            report "=== TODOS LOS CASOS PASARON ===" severity note;
        else
            report "=== HAY CASOS CON FALLOS, revisar arriba ===" severity error;
        end if;

        wait;
    end process;

end Behavioral;
