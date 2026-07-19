library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: axi4_write_master
--
-- Dos modelos falsos, igual que en tb_axi4_read_master:
--   1) Buffer local de origen ( combinacional ): para la palabra local de
--      direccion "addr", entrega beat bajo = 2*addr, beat alto = 2*addr+1.
--      Asi el patron esperado en la "DDR falsa" queda simplemente
--      ddr_mem(i) = i, sin importar en que chunk ni en que posicion cae.
--   2) Esclavo AXI4 de escritura ( "DDR falsa" ): array de 512 palabras de
--      64 bits que captura cada beat segun AWADDR + orden de llegada.
--
-- CASO 1: rafaga chica ( 4 palabras locales = 8 beats ), un solo chunk.
-- CASO 2: rafaga grande ( 70 palabras = 140 beats ), obliga a trocear en
--   2 chunks internos ( 64 + 6 ); verifica que tanto la direccion DDR como
--   la direccion local avancen bien entre chunks.

entity tb_axi4_write_master is
end tb_axi4_write_master;

architecture Behavioral of tb_axi4_write_master is

    constant CLK_PERIOD : time := 10 ns;

    type ddr_mem_array is array( 0 to 511 ) of std_logic_vector( 63 downto 0 );
    signal ddr_mem : ddr_mem_array := ( others => ( others => '0' ) );

    type slave_state_type is ( S_IDLE, S_DATA, S_RESP );
    signal slave_state   : slave_state_type := S_IDLE;
    signal mock_word_idx : integer := 0;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '0'; -- activo en bajo.

    signal start       : std_logic := '0';
    signal ddr_addr    : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal burst_words : std_logic_vector(  9 downto 0 ) := ( others => '0' );
    signal local_addr  : std_logic_vector( 11 downto 0 ) := ( others => '0' );
    signal done        : std_logic;

    signal m_axi_awid    : std_logic_vector(  3 downto 0 );
    signal m_axi_awaddr  : std_logic_vector( 31 downto 0 );
    signal m_axi_awlen   : std_logic_vector(  7 downto 0 );
    signal m_axi_awsize  : std_logic_vector(  2 downto 0 );
    signal m_axi_awburst : std_logic_vector(  1 downto 0 );
    signal m_axi_awvalid : std_logic;
    signal m_axi_awready : std_logic := '0';
    signal m_axi_wdata   : std_logic_vector( 63 downto 0 );
    signal m_axi_wstrb   : std_logic_vector(  7 downto 0 );
    signal m_axi_wlast   : std_logic;
    signal m_axi_wvalid  : std_logic;
    signal m_axi_wready  : std_logic := '0';
    signal m_axi_bid     : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal m_axi_bresp   : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal m_axi_bvalid  : std_logic := '0';
    signal m_axi_bready  : std_logic;

    signal local_rd_en   : std_logic;
    signal local_rd_addr : std_logic_vector( 11 downto 0 );
    signal local_rd_data : std_logic_vector( 127 downto 0 );

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.axi4_write_master
        port map(
            clk           => clk,
            reset         => reset,
            start         => start,
            ddr_addr      => ddr_addr,
            burst_words   => burst_words,
            local_addr    => local_addr,
            done          => done,
            m_axi_awid    => m_axi_awid,
            m_axi_awaddr  => m_axi_awaddr,
            m_axi_awlen   => m_axi_awlen,
            m_axi_awsize  => m_axi_awsize,
            m_axi_awburst => m_axi_awburst,
            m_axi_awvalid => m_axi_awvalid,
            m_axi_awready => m_axi_awready,
            m_axi_wdata   => m_axi_wdata,
            m_axi_wstrb   => m_axi_wstrb,
            m_axi_wlast   => m_axi_wlast,
            m_axi_wvalid  => m_axi_wvalid,
            m_axi_wready  => m_axi_wready,
            m_axi_bid     => m_axi_bid,
            m_axi_bresp   => m_axi_bresp,
            m_axi_bvalid  => m_axi_bvalid,
            m_axi_bready  => m_axi_bready,
            local_rd_en   => local_rd_en,
            local_rd_addr => local_rd_addr,
            local_rd_data => local_rd_data
        );

    -- Modelo del buffer local de origen ( combinacional ).
    local_rd_data <= std_logic_vector( to_unsigned( 2 * to_integer( unsigned( local_rd_addr ) ) + 1, 64 ) ) &
                      std_logic_vector( to_unsigned( 2 * to_integer( unsigned( local_rd_addr ) ),     64 ) );

    -- Modelo de esclavo AXI4 ( "DDR falsa" ).
    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                m_axi_awready <= '0';
                m_axi_wready  <= '0';
                m_axi_bvalid  <= '0';
                slave_state   <= S_IDLE;

            else
                case slave_state is
                    when S_IDLE =>
                        m_axi_awready <= '0';
                        m_axi_wready  <= '0';
                        m_axi_bvalid  <= '0';
                        if( m_axi_awvalid = '1' ) then
                            m_axi_awready <= '1';
                            mock_word_idx <= to_integer( unsigned( m_axi_awaddr ) ) / 8;
                            slave_state   <= S_DATA;
                        end if;

                    when S_DATA =>
                        m_axi_awready <= '0';
                        m_axi_wready  <= '1';
                        if( m_axi_wvalid = '1' ) then
                            ddr_mem( mock_word_idx ) <= m_axi_wdata;
                            mock_word_idx <= mock_word_idx + 1;
                            if( m_axi_wlast = '1' ) then
                                m_axi_wready <= '0';
                                slave_state  <= S_RESP;
                            end if;
                        end if;

                    when S_RESP =>
                        -- m_axi_bready ya puede estar en '1' desde ANTES de entrar aqui
                        -- ( el master lo levanta apenas entra a B_RESP, mismo flanco en
                        -- que este mock entra a S_RESP ). Si se revisara bready en el
                        -- mismo ciclo que se presenta bvalid por primera vez, se pisaria
                        -- el bvalid<='1' con bvalid<='0' sin que el master llegue a verlo
                        -- nunca en alto.
                        if( m_axi_bvalid = '0' ) then
                            -- Primer ciclo en S_RESP: presentar bvalid.
                            m_axi_bvalid <= '1';
                            m_axi_bresp  <= "00";
                        elsif( m_axi_bready = '1' ) then
                            -- bvalid ya estaba en alto y el master lo acepto.
                            m_axi_bvalid <= '0';
                            slave_state  <= S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    process
    begin

        reset <= '0';
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        reset <= '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "=== INICIO TEST: axi4_write_master ===";

        -- CASO 1: rafaga chica, 4 palabras locales hacia ddr_addr=0.
        report "--- Caso 1: rafaga de 4 palabras (1 chunk) ---";
        ddr_addr    <= ( others => '0' );
        burst_words <= std_logic_vector( to_unsigned( 4, 10 ) );
        local_addr  <= ( others => '0' );
        start       <= '1';
        wait until rising_edge( clk );
        start <= '0';

        wait until done = '1';
        wait until rising_edge( clk );

        assert ddr_mem( 0 ) = std_logic_vector( to_unsigned( 0, 64 ) )
            report "FALLO caso 1: ddr_mem(0)" severity error;
        assert ddr_mem( 1 ) = std_logic_vector( to_unsigned( 1, 64 ) )
            report "FALLO caso 1: ddr_mem(1)" severity error;
        assert ddr_mem( 6 ) = std_logic_vector( to_unsigned( 6, 64 ) )
            report "FALLO caso 1: ddr_mem(6)" severity error;
        assert ddr_mem( 7 ) = std_logic_vector( to_unsigned( 7, 64 ) )
            report "FALLO caso 1: ddr_mem(7)" severity error;
        report "--- Caso 1 OK ---";

        -- CASO 2: rafaga grande, 70 palabras desde local_addr=0 hacia ddr_addr=0 -> 2 chunks internos (64 + 6).
        report "--- Caso 2: rafaga de 70 palabras (2 chunks) ---";
        ddr_addr    <= ( others => '0' );
        burst_words <= std_logic_vector( to_unsigned( 70, 10 ) );
        local_addr  <= ( others => '0' );
        start       <= '1';
        wait until rising_edge( clk );
        start <= '0';

        wait until done = '1';
        wait until rising_edge( clk );

        -- Primer chunk: ultima palabra ( beats 126,127 ).
        assert ddr_mem( 126 ) = std_logic_vector( to_unsigned( 126, 64 ) )
            report "FALLO caso 2: ddr_mem(126)" severity error;
        assert ddr_mem( 127 ) = std_logic_vector( to_unsigned( 127, 64 ) )
            report "FALLO caso 2: ddr_mem(127)" severity error;

        -- Segundo chunk: arranca en word_idx=128 ( ddr_addr avanzo 64*16=1024 bytes = 128 palabras de 8 bytes )
        -- y usa local_addr=64 en adelante ( 2*64=128 ), confirma que ambas direcciones avanzaron juntas.
        assert ddr_mem( 128 ) = std_logic_vector( to_unsigned( 128, 64 ) )
            report "FALLO caso 2: ddr_mem(128) - direccion DDR o local no avanzo bien entre chunks" severity error;
        assert ddr_mem( 139 ) = std_logic_vector( to_unsigned( 139, 64 ) )
            report "FALLO caso 2: ddr_mem(139)" severity error;

        report "--- Caso 2 OK ---";

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
