library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: axi4_read_master
--
-- Como no hay DDR real en simulacion, este testbench incluye un modelo
-- simple de esclavo AXI4 ( "DDR falsa" ): un array de 512 palabras de 64
-- bits, precargado con mem(i) = i, que responde al protocolo AR/R igual
-- que lo haria un puerto S_AXI_HP real.
--
-- CASO 1: rafaga chica ( 4 palabras locales = 8 beats ), cabe en un solo
--   chunk interno del master ( limite es 64 palabras / 128 beats ).
-- CASO 2: rafaga grande ( 70 palabras = 140 beats ), obliga al master a
--   trocear en 2 chunks internos ( 64 + 6 ), verifica que la direccion DDR
--   y la direccion local avancen bien entre chunks.

entity tb_axi4_read_master is
end tb_axi4_read_master;

architecture Behavioral of tb_axi4_read_master is

    constant CLK_PERIOD : time := 10 ns;

    type mem_array is array( 0 to 511 ) of std_logic_vector( 63 downto 0 );

    function init_mem return mem_array is
        variable m : mem_array;
    begin
        for i in 0 to 511 loop
            m( i ) := std_logic_vector( to_unsigned( i, 64 ) );
        end loop;
        return m;
    end function;

    signal mock_mem : mem_array := init_mem;

    type slave_state_type is ( S_IDLE, S_BURST );
    signal slave_state     : slave_state_type := S_IDLE;

    -- Captura de lo que el master escribe en el buffer local ( direccion 13 bits ).
    type captured_array is array( 0 to 127 ) of std_logic_vector( 127 downto 0 );
    signal captured_mem : captured_array := ( others => ( others => '0' ) );

    signal clk   : std_logic := '0';
    signal reset : std_logic := '0'; -- activo.

    signal start         : std_logic := '0';
    signal ddr_addr      : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal burst_words   : std_logic_vector(  9 downto 0 ) := ( others => '0' );
    signal local_addr    : std_logic_vector( 12 downto 0 ) := ( others => '0' );
    signal done          : std_logic;

    signal m_axi_arid    : std_logic_vector(  3 downto 0 );
    signal m_axi_araddr  : std_logic_vector( 31 downto 0 );
    signal m_axi_arlen   : std_logic_vector(  7 downto 0 );
    signal m_axi_arsize  : std_logic_vector(  2 downto 0 );
    signal m_axi_arburst : std_logic_vector(  1 downto 0 );
    signal m_axi_arvalid : std_logic;
    signal m_axi_arready : std_logic := '0';
    signal m_axi_rid     : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal m_axi_rdata   : std_logic_vector( 63 downto 0 ) := ( others => '0' );
    signal m_axi_rresp   : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal m_axi_rlast   : std_logic := '0';
    signal m_axi_rvalid  : std_logic := '0';
    signal m_axi_rready  : std_logic;

    signal local_wr_en   : std_logic;
    signal local_wr_addr : std_logic_vector( 12 downto 0 );
    signal local_wr_data : std_logic_vector( 127 downto 0 );

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.axi4_read_master
        port map(
            clk           => clk,
            reset         => reset,
            start         => start,
            ddr_addr      => ddr_addr,
            burst_words   => burst_words,
            local_addr    => local_addr,
            done          => done,
            m_axi_arid    => m_axi_arid,
            m_axi_araddr  => m_axi_araddr,
            m_axi_arlen   => m_axi_arlen,
            m_axi_arsize  => m_axi_arsize,
            m_axi_arburst => m_axi_arburst,
            m_axi_arvalid => m_axi_arvalid,
            m_axi_arready => m_axi_arready,
            m_axi_rid     => m_axi_rid,
            m_axi_rdata   => m_axi_rdata,
            m_axi_rresp   => m_axi_rresp,
            m_axi_rlast   => m_axi_rlast,
            m_axi_rvalid  => m_axi_rvalid,
            m_axi_rready  => m_axi_rready,
            local_wr_en   => local_wr_en,
            local_wr_addr => local_wr_addr,
            local_wr_data => local_wr_data
        );

    -- Modelo de esclavo AXI4 ( "DDR falsa" ).
    --
    -- v_word_idx / v_beats_left son variables ( no señales ): el avance al
    -- siguiente beat y el dato que se pone en rdata para ESE mismo beat deben
    -- quedar sincronizados en el mismo flanco. Con señales ( que solo
    -- reflejan su valor nuevo un ciclo despues ) rdata queda desfasado del
    -- beat que realmente describe rlast, y el ultimo beat ( el que trae
    -- rlast='1' ) nunca llega a presentarse con rvalid='1' al mismo tiempo.
    process( clk )
        variable v_word_idx   : integer := 0;
        variable v_beats_left : integer := 0;
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                m_axi_arready <= '0';
                m_axi_rvalid  <= '0';
                slave_state   <= S_IDLE;
                v_word_idx    := 0;
                v_beats_left  := 0;

            else
                case slave_state is
                    when S_IDLE =>
                        m_axi_arready <= '0';
                        m_axi_rvalid  <= '0';
                        if( m_axi_arvalid = '1' ) then
                            m_axi_arready <= '1';
                            v_word_idx    := to_integer( unsigned( m_axi_araddr ) ) / 8;
                            v_beats_left  := to_integer( unsigned( m_axi_arlen ) ) + 1;
                            slave_state   <= S_BURST;
                        end if;

                    when S_BURST =>
                        m_axi_arready <= '0';

                        if( m_axi_rvalid = '0' ) then
                            -- Primer beat del burst ( recien salimos de S_IDLE ).
                            m_axi_rvalid <= '1';
                            m_axi_rdata  <= mock_mem( v_word_idx );
                            if( v_beats_left = 1 ) then
                                m_axi_rlast <= '1';
                            else
                                m_axi_rlast <= '0';
                            end if;

                        elsif( m_axi_rready = '1' ) then
                            -- El beat actual ya fue aceptado: avanzar o terminar.
                            v_word_idx   := v_word_idx + 1;
                            v_beats_left := v_beats_left - 1;
                            if( v_beats_left = 0 ) then
                                m_axi_rvalid <= '0';
                                slave_state  <= S_IDLE;
                            else
                                m_axi_rdata <= mock_mem( v_word_idx );
                                if( v_beats_left = 1 ) then
                                    m_axi_rlast <= '1';
                                else
                                    m_axi_rlast <= '0';
                                end if;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Captura de escrituras al buffer local.
    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( local_wr_en = '1' ) then
                captured_mem( to_integer( unsigned( local_wr_addr ) ) ) <= local_wr_data;
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

        report "=== INICIO TEST: axi4_read_master ===";

        -- CASO 1: rafaga chica, 4 palabras locales desde ddr_addr = 0.
        report "--- Caso 1: rafaga de 4 palabras (1 chunk) ---";
        ddr_addr    <= ( others => '0' );
        burst_words <= std_logic_vector( to_unsigned( 4, 10 ) );
        local_addr  <= ( others => '0' );
        start       <= '1';
        wait until rising_edge( clk );
        start <= '0';

        wait until done = '1';
        wait until rising_edge( clk );

        assert captured_mem( 0 ) = std_logic_vector( to_unsigned( 1, 64 ) ) & std_logic_vector( to_unsigned( 0, 64 ) )
            report "FALLO caso 1: captured_mem(0)" severity error;
        assert captured_mem( 1 ) = std_logic_vector( to_unsigned( 3, 64 ) ) & std_logic_vector( to_unsigned( 2, 64 ) )
            report "FALLO caso 1: captured_mem(1)" severity error;
        assert captured_mem( 2 ) = std_logic_vector( to_unsigned( 5, 64 ) ) & std_logic_vector( to_unsigned( 4, 64 ) )
            report "FALLO caso 1: captured_mem(2)" severity error;
        assert captured_mem( 3 ) = std_logic_vector( to_unsigned( 7, 64 ) ) & std_logic_vector( to_unsigned( 6, 64 ) )
            report "FALLO caso 1: captured_mem(3)" severity error;
        report "--- Caso 1 OK ---";

        -- CASO 2: rafaga grande, 70 palabras desde ddr_addr = 0 -> 2 chunks internos (64 + 6).
        report "--- Caso 2: rafaga de 70 palabras (2 chunks) ---";
        ddr_addr    <= ( others => '0' );
        burst_words <= std_logic_vector( to_unsigned( 70, 10 ) );
        local_addr  <= ( others => '0' );
        start       <= '1';
        wait until rising_edge( clk );
        start <= '0';

        wait until done = '1';
        wait until rising_edge( clk );

        -- Primer chunk: local_addr 0 y 63 ( primera y ultima palabra ).
        assert captured_mem( 0 ) = std_logic_vector( to_unsigned( 1, 64 ) ) & std_logic_vector( to_unsigned( 0, 64 ) )
            report "FALLO caso 2: captured_mem(0)" severity error;
        assert captured_mem( 63 ) = std_logic_vector( to_unsigned( 127, 64 ) ) & std_logic_vector( to_unsigned( 126, 64 ) )
            report "FALLO caso 2: captured_mem(63)" severity error;

        -- Segundo chunk: arranca en word_idx=128 ( ddr_addr avanzo 64*16=1024 bytes = 128 palabras de 8 bytes ).
        assert captured_mem( 64 ) = std_logic_vector( to_unsigned( 129, 64 ) ) & std_logic_vector( to_unsigned( 128, 64 ) )
            report "FALLO caso 2: captured_mem(64) - direccion DDR no avanzo bien entre chunks" severity error;
        assert captured_mem( 69 ) = std_logic_vector( to_unsigned( 139, 64 ) ) & std_logic_vector( to_unsigned( 138, 64 ) )
            report "FALLO caso 2: captured_mem(69)" severity error;

        report "--- Caso 2 OK ---";

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
