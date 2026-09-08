library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: cruce de frontera de 4 KB en axi4_read_master / axi4_write_master.
--
-- AXI4 (seccion A3.4.1 de la spec) prohibe que una rafaga INCR cruce un
-- limite de direccion de 4 KB. Los dos masters trocean en chunks de
-- CHUNK_WORDS = 64 palabras de 16 bytes = 1024 bytes, arrancando en una
-- direccion arbitraria ( addr_in + r_global*row_stride + col*cin_groups*16 ),
-- asi que nada garantiza que el chunk quepa en la pagina.
--
-- Este testbench agrega lo que ningun otro tiene: un CHEQUEADOR DE PROTOCOLO
-- que mira cada handshake AR/AW y calcula si esa rafaga cruza la frontera.
-- La "DDR falsa" de los otros testbenches sirve cualquier direccion sin
-- quejarse -- por eso el bug es invisible en simulacion hasta que alguien
-- lo chequea explicitamente.
--
--   CASO 1 (lectura): el caso REAL de irb1_dw con tile_x=1 -- base de pagina
--     + 2016 bytes de offset, 132 palabras de fila. Termina en 8224 con la
--     frontera en 8192.
--   CASO 2 (lectura): arranque 16 bytes antes de una frontera, rafaga larga
--     -- el caso mas agresivo posible.
--   CASO 3 (lectura): regresion, base alineada + 70 palabras ( el "Caso 2"
--     del tb_axi4_read_master original ). No debe cruzar ni antes ni despues.
--   CASO 4 (escritura): mismo escenario que el Caso 1, del lado del
--     axi4_write_master.
--   CASO 5 (los dos): burst_words = 0. Sin la guarda de AR_ADDR / AW_ADDR,
--     arlen sale shift_left( 0, 1 ) - 1 = 255 en aritmetica unsigned, o sea
--     una rafaga fantasma de 256 beats ( 2 KB ) que nadie pidio: en lectura
--     pisa 128 palabras del buffer destino, en escritura mete 2 KB de basura
--     en DDR. El caso tambien confirma que igual sale 'done' -- si el master
--     simplemente no arrancara, dma_fsm quedaria colgada esperandolo.
--
-- Ademas de no cruzar, se verifica que los datos leidos sigan siendo los
-- correctos: un fix que parta la rafaga pero pierda el hilo de la direccion
-- seria peor que el bug.

entity tb_axi4_4kb is
end tb_axi4_4kb;

architecture Behavioral of tb_axi4_4kb is

    constant CLK_PERIOD : time := 10 ns;

    -- 16 KB de DDR falsa = 4 paginas de 4 KB.
    constant MEM_WORDS : integer := 2048;
    type mem_array is array( 0 to MEM_WORDS - 1 ) of std_logic_vector( 63 downto 0 );

    function init_mem return mem_array is
        variable m : mem_array;
    begin
        for i in 0 to MEM_WORDS - 1 loop
            m( i ) := std_logic_vector( to_unsigned( i, 64 ) );
        end loop;
        return m;
    end function;

    signal mock_mem : mem_array := init_mem;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '0';

    -- Contadores separados: VHDL no deja manejar una senal desde dos
    -- procesos ( el chequeador de protocolo y el de datos ).
    signal crossings  : integer := 0;   -- violaciones de 4 KB.
    signal err_data   : integer := 0;   -- datos leidos incorrectos.
    signal phantom    : integer := 0;   -- rafagas emitidas con burst_words = 0.
    signal watch_zero : std_logic := '0';

    -- ---------------- lectura ----------------
    signal rd_start       : std_logic := '0';
    signal rd_ddr_addr    : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal rd_burst_words : std_logic_vector(  9 downto 0 ) := ( others => '0' );
    signal rd_local_addr  : std_logic_vector( 12 downto 0 ) := ( others => '0' );
    signal rd_done        : std_logic;

    signal arid    : std_logic_vector(  3 downto 0 );
    signal araddr  : std_logic_vector( 31 downto 0 );
    signal arlen   : std_logic_vector(  7 downto 0 );
    signal arsize  : std_logic_vector(  2 downto 0 );
    signal arburst : std_logic_vector(  1 downto 0 );
    signal arvalid : std_logic;
    signal arready : std_logic := '0';
    signal rid     : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal rdata   : std_logic_vector( 63 downto 0 ) := ( others => '0' );
    signal rresp   : std_logic_vector(  1 downto 0 ) := "00";
    signal rlast   : std_logic := '0';
    signal rvalid  : std_logic := '0';
    signal rready  : std_logic;

    signal loc_wr_en   : std_logic;
    signal loc_wr_addr : std_logic_vector( 12 downto 0 );
    signal loc_wr_data : std_logic_vector( 127 downto 0 );

    type captured_array is array( 0 to 255 ) of std_logic_vector( 127 downto 0 );
    signal captured_mem : captured_array := ( others => ( others => '0' ) );

    -- ---------------- escritura ----------------
    signal wr_start       : std_logic := '0';
    signal wr_ddr_addr    : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal wr_burst_words : std_logic_vector(  9 downto 0 ) := ( others => '0' );
    signal wr_local_addr  : std_logic_vector( 11 downto 0 ) := ( others => '0' );
    signal wr_done        : std_logic;

    signal awid    : std_logic_vector(  3 downto 0 );
    signal awaddr  : std_logic_vector( 31 downto 0 );
    signal awlen   : std_logic_vector(  7 downto 0 );
    signal awsize  : std_logic_vector(  2 downto 0 );
    signal awburst : std_logic_vector(  1 downto 0 );
    signal awvalid : std_logic;
    signal awready : std_logic := '0';
    signal wdata   : std_logic_vector( 63 downto 0 );
    signal wstrb   : std_logic_vector(  7 downto 0 );
    signal wlast   : std_logic;
    signal wvalid  : std_logic;
    signal wready  : std_logic := '0';
    signal bid     : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal bresp   : std_logic_vector(  1 downto 0 ) := "00";
    signal bvalid  : std_logic := '0';
    signal bready  : std_logic;

    signal loc_rd_en   : std_logic;
    signal loc_rd_addr : std_logic_vector( 11 downto 0 );
    signal loc_rd_data : std_logic_vector( 127 downto 0 ) := ( others => '0' );

    type slave_state_type is ( S_IDLE, S_BURST );
    signal rd_slave_state : slave_state_type := S_IDLE;

    type wslave_state_type is ( W_IDLE, W_DATA, W_RESP );
    signal wr_slave_state : wslave_state_type := W_IDLE;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut_rd : entity work.axi4_read_master
        port map(
            clk => clk, reset => reset,
            start => rd_start, ddr_addr => rd_ddr_addr,
            burst_words => rd_burst_words, local_addr => rd_local_addr,
            done => rd_done,
            m_axi_arid => arid, m_axi_araddr => araddr, m_axi_arlen => arlen,
            m_axi_arsize => arsize, m_axi_arburst => arburst,
            m_axi_arvalid => arvalid, m_axi_arready => arready,
            m_axi_rid => rid, m_axi_rdata => rdata, m_axi_rresp => rresp,
            m_axi_rlast => rlast, m_axi_rvalid => rvalid, m_axi_rready => rready,
            local_wr_en => loc_wr_en, local_wr_addr => loc_wr_addr,
            local_wr_data => loc_wr_data
        );

    dut_wr : entity work.axi4_write_master
        port map(
            clk => clk, reset => reset,
            start => wr_start, ddr_addr => wr_ddr_addr,
            burst_words => wr_burst_words, local_addr => wr_local_addr,
            done => wr_done,
            m_axi_awid => awid, m_axi_awaddr => awaddr, m_axi_awlen => awlen,
            m_axi_awsize => awsize, m_axi_awburst => awburst,
            m_axi_awvalid => awvalid, m_axi_awready => awready,
            m_axi_wdata => wdata, m_axi_wstrb => wstrb, m_axi_wlast => wlast,
            m_axi_wvalid => wvalid, m_axi_wready => wready,
            m_axi_bid => bid, m_axi_bresp => bresp, m_axi_bvalid => bvalid,
            m_axi_bready => bready,
            local_rd_en => loc_rd_en, local_rd_addr => loc_rd_addr,
            local_rd_data => loc_rd_data
        );

    -- El OFBuffer falso: devuelve la direccion local como dato, para poder
    -- rastrear que palabra fue a parar a que direccion de DDR.
    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( loc_rd_en = '1' ) then
                loc_rd_data <= std_logic_vector( resize( unsigned( loc_rd_addr ), 128 ) );
            end if;
        end if;
    end process;

    -- =====================================================================
    -- CHEQUEADOR DE PROTOCOLO: frontera de 4 KB.
    -- =====================================================================
    process( clk )
        variable v_addr   : integer;
        variable v_bytes  : integer;
        variable v_offset : integer;
    begin
        if( rising_edge( clk ) ) then
            if( arvalid = '1' and arready = '1' ) then
                v_addr   := to_integer( unsigned( araddr ) );
                v_bytes  := ( to_integer( unsigned( arlen ) ) + 1 ) * 8;
                v_offset := v_addr mod 4096;
                if( v_offset + v_bytes > 4096 ) then
                    report "VIOLACION 4KB (AR): addr=" & integer'image( v_addr ) &
                           " (offset " & integer'image( v_offset ) & " en su pagina)" &
                           " arlen=" & integer'image( to_integer( unsigned( arlen ) ) ) &
                           " -> " & integer'image( v_bytes ) & " bytes, se pasa " &
                           integer'image( v_offset + v_bytes - 4096 ) & " bytes de la frontera"
                        severity error;
                    crossings <= crossings + 1;
                end if;
            end if;

            -- Rafaga fantasma: cualquier handshake de direccion mientras el
            -- estimulo pidio burst_words = 0 es, por definicion, una rafaga
            -- que nadie pidio.
            if( watch_zero = '1' and
                ( ( arvalid = '1' and arready = '1' ) or ( awvalid = '1' and awready = '1' ) ) ) then
                report "RAFAGA FANTASMA: se emitio una rafaga con burst_words = 0" severity error;
                phantom <= phantom + 1;
            end if;

            if( awvalid = '1' and awready = '1' ) then
                v_addr   := to_integer( unsigned( awaddr ) );
                v_bytes  := ( to_integer( unsigned( awlen ) ) + 1 ) * 8;
                v_offset := v_addr mod 4096;
                if( v_offset + v_bytes > 4096 ) then
                    report "VIOLACION 4KB (AW): addr=" & integer'image( v_addr ) &
                           " (offset " & integer'image( v_offset ) & " en su pagina)" &
                           " awlen=" & integer'image( to_integer( unsigned( awlen ) ) ) &
                           " -> " & integer'image( v_bytes ) & " bytes, se pasa " &
                           integer'image( v_offset + v_bytes - 4096 ) & " bytes de la frontera"
                        severity error;
                    crossings <= crossings + 1;
                end if;
            end if;
        end if;
    end process;

    -- ---------------- esclavo AXI de lectura ----------------
    process( clk )
        variable v_word_idx   : integer := 0;
        variable v_beats_left : integer := 0;
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                arready <= '0'; rvalid <= '0'; rd_slave_state <= S_IDLE;
                v_word_idx := 0; v_beats_left := 0;
            else
                case rd_slave_state is
                    when S_IDLE =>
                        arready <= '0'; rvalid <= '0';
                        if( arvalid = '1' ) then
                            arready      <= '1';
                            v_word_idx   := to_integer( unsigned( araddr ) ) / 8;
                            v_beats_left := to_integer( unsigned( arlen ) ) + 1;
                            rd_slave_state <= S_BURST;
                        end if;

                    when S_BURST =>
                        arready <= '0';
                        if( rvalid = '0' ) then
                            rvalid <= '1';
                            rdata  <= mock_mem( v_word_idx mod MEM_WORDS );
                            if( v_beats_left = 1 ) then rlast <= '1'; else rlast <= '0'; end if;
                        elsif( rready = '1' ) then
                            v_word_idx   := v_word_idx + 1;
                            v_beats_left := v_beats_left - 1;
                            if( v_beats_left = 0 ) then
                                rvalid <= '0'; rd_slave_state <= S_IDLE;
                            else
                                rdata <= mock_mem( v_word_idx mod MEM_WORDS );
                                if( v_beats_left = 1 ) then rlast <= '1'; else rlast <= '0'; end if;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- ---------------- esclavo AXI de escritura ----------------
    process( clk )
        variable v_word_idx   : integer := 0;
        variable v_beats_left : integer := 0;
    begin
        if( rising_edge( clk ) ) then
            if( reset = '0' ) then
                awready <= '0'; wready <= '0'; bvalid <= '0'; wr_slave_state <= W_IDLE;
            else
                case wr_slave_state is
                    when W_IDLE =>
                        awready <= '0'; bvalid <= '0';
                        if( awvalid = '1' ) then
                            awready      <= '1';
                            v_word_idx   := to_integer( unsigned( awaddr ) ) / 8;
                            v_beats_left := to_integer( unsigned( awlen ) ) + 1;
                            wready       <= '1';
                            wr_slave_state <= W_DATA;
                        end if;

                    when W_DATA =>
                        awready <= '0';
                        if( wvalid = '1' and wready = '1' ) then
                            mock_mem( v_word_idx mod MEM_WORDS ) <= wdata;
                            v_word_idx   := v_word_idx + 1;
                            v_beats_left := v_beats_left - 1;
                            if( v_beats_left = 0 ) then
                                wready <= '0'; bvalid <= '1';
                                wr_slave_state <= W_RESP;
                            end if;
                        end if;

                    when W_RESP =>
                        if( bready = '1' ) then
                            bvalid <= '0'; wr_slave_state <= W_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( loc_wr_en = '1' ) then
                captured_mem( to_integer( unsigned( loc_wr_addr ) ) mod 256 ) <= loc_wr_data;
            end if;
        end if;
    end process;

    -- =====================================================================
    -- Estimulo.
    -- =====================================================================
    process
        variable v_base   : integer;
        variable v_expect : std_logic_vector( 127 downto 0 );

        procedure do_read( addr : integer; words : integer ) is
        begin
            rd_ddr_addr    <= std_logic_vector( to_unsigned( addr, 32 ) );
            rd_burst_words <= std_logic_vector( to_unsigned( words, 10 ) );
            rd_local_addr  <= ( others => '0' );
            wait until rising_edge( clk );
            rd_start <= '1';
            wait until rising_edge( clk );
            rd_start <= '0';
            wait until rd_done = '1';
            wait until rising_edge( clk );
        end procedure;

        procedure do_write( addr : integer; words : integer ) is
        begin
            wr_ddr_addr    <= std_logic_vector( to_unsigned( addr, 32 ) );
            wr_burst_words <= std_logic_vector( to_unsigned( words, 10 ) );
            wr_local_addr  <= ( others => '0' );
            wait until rising_edge( clk );
            wr_start <= '1';
            wait until rising_edge( clk );
            wr_start <= '0';
            wait until wr_done = '1';
            wait until rising_edge( clk );
        end procedure;

        -- Verifica que la palabra local n traiga los 2 words de 64 bits que
        -- le corresponden en la DDR falsa ( mem(i) = i ).
        procedure check_word( base_addr : integer; n : integer; tag : string ) is
            variable idx : integer;
            variable exp : std_logic_vector( 127 downto 0 );
        begin
            idx := ( base_addr / 8 ) + 2 * n;
            exp := std_logic_vector( to_unsigned( idx + 1, 64 ) ) &
                   std_logic_vector( to_unsigned( idx,     64 ) );
            if( captured_mem( n ) /= exp ) then
                report "FALLO " & tag & ": palabra local " & integer'image( n ) &
                       " trajo dato equivocado" severity error;
                err_data <= err_data + 1;
            end if;
        end procedure;

    begin
        reset <= '0';
        wait for 100 ns;
        wait until rising_edge( clk );
        reset <= '1';
        wait for 50 ns;

        report "=== INICIO tb_axi4_4kb: cruce de frontera de 4 KB ===";

        ------------------------------------------------------------------
        report "--- CASO 1 (lectura): irb1_dw real, tile_x=1 -- offset 2016, 132 palabras ---";
        -- Pagina 1 arranca en 4096. 4096 + 2016 = 6112. 132 palabras = 2112
        -- bytes -> termina en 8224, con la frontera de pagina en 8192.
        v_base := 4096 + 2016;
        do_read( v_base, 132 );
        check_word( v_base,   0, "Caso1" );
        check_word( v_base,  63, "Caso1" );
        check_word( v_base,  64, "Caso1" );
        check_word( v_base, 131, "Caso1" );
        wait for 100 ns;

        ------------------------------------------------------------------
        report "--- CASO 2 (lectura): arranque 16 bytes antes de la frontera, 80 palabras ---";
        v_base := 8192 - 16;
        do_read( v_base, 80 );
        check_word( v_base,  0, "Caso2" );
        check_word( v_base,  1, "Caso2" );
        check_word( v_base, 79, "Caso2" );
        wait for 100 ns;

        ------------------------------------------------------------------
        report "--- CASO 3 (lectura): regresion, base alineada + 70 palabras (2 chunks) ---";
        v_base := 4096;
        do_read( v_base, 70 );
        check_word( v_base,  0, "Caso3" );
        check_word( v_base, 63, "Caso3" );
        check_word( v_base, 64, "Caso3" );
        check_word( v_base, 69, "Caso3" );
        wait for 100 ns;

        ------------------------------------------------------------------
        report "--- CASO 4 (escritura): mismo escenario del Caso 1 ---";
        v_base := 4096 + 2016;
        do_write( v_base, 132 );
        wait for 100 ns;

        ------------------------------------------------------------------
        report "--- CASO 5: burst_words = 0 en los dos masters (rafaga fantasma) ---";
        watch_zero <= '1';
        wait until rising_edge( clk );
        do_read( 4096, 0 );
        do_write( 4096, 0 );
        watch_zero <= '0';
        wait for 100 ns;

        ------------------------------------------------------------------
        report "=== RESUMEN: " & integer'image( crossings ) & " cruce(s) de frontera, " &
               integer'image( err_data ) & " error(es) de dato, " &
               integer'image( phantom ) & " rafaga(s) fantasma ===" severity note;
        if( crossings = 0 and err_data = 0 and phantom = 0 ) then
            report "=== SIN VIOLACIONES DE 4KB Y DATOS CORRECTOS ===" severity note;
        else
            report "=== HAY VIOLACIONES, revisar arriba ===" severity error;
        end if;

        wait;
    end process;

end Behavioral;
