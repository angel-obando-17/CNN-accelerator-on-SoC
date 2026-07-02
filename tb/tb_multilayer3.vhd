library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: Multilayer con TILE_WAIT y GAP | PW1x1 (2 tiles) -> PW1x1 + GAP
--
-- Ejercita dos cosas que ningun testbench anterior cubre:
--   1. El protocolo TILE_WAIT / TILE_HOLD (sincronizacion FSM <-> DMA entre
--      tiles de una misma capa), usando max_tile_x = '1' (2 tiles).
--   2. La GAP unit dentro de una cadena multilayer real (tb_pool.vhd la
--      prueba aislada, nunca despues de una capa previa via el patron de
--      volcado OFBuffer -> IFBuffer).
--
--
-- CAPA 1 | PW1x1 | tile 2x2 | Cin=Cout=16 | max_tile_x='1' (2 tiles) | shift=0
--   Tile 0: acts = 0x01, W = 0x01 -> 16*(1*1) = 16 = 0x10. OFBuffer[ 0 - 3 ] = 0x10.
--   Tile 1: acts = 0x02, W = 0x01 -> 16*(2*1) = 32 = 0x20. OFBuffer[ 0 - 3 ] = 0x20.
--   Los dos tiles usan las MISMAS direcciones de IFBuffer/OFBuffer (el
--   Address Generator no desplaza addr_in/addr_out por tile_x/tile_y), por
--   lo que el valor distinto entre tile 0 y tile 1 prueba que el recargo del
--   IFBuffer durante TILE_WAIT realmente tomo efecto y no quedo dato viejo.
--   IFBuffer banco A: buf_sel='1' escribe A, buf_sel='0' lee A.
--     pixel( 0, 0 ) = 0  pixel( 0, 1 ) = 1  pixel( 1, 0 ) = 4  pixel( 1, 1 ) = 5
--     (tile_w_pad=4, PW1x1 mantiene ky=kx=0 fijo, sin padding real).
--   WeightBuffer [ 0 - 15 ]: addr_w = co*Cin + ci, co = 0 (mismo peso, no se
--   recarga entre tiles: los pesos son por capa, no por tile).
--
-- CAPA 2 | PW1x1 + GAP | tile 2x2 | Cin = Cout = 16 | max_tile_x = '0' (1 tile)
--   acts = 0x10 (representa el resultado de la Capa 1, tile 0), W = 0x01, shift = 4
--   Por pixel: 16*(0x10*1) = 256 >> 4 = 16 = 0x10 (post quant_relu, por pixel).
--   GAP acumula 4 pixeles: 4*16 = 64. gap_shift=2: 64 >> 2 = 16 = 0x10.
--   OFBuffer[ 0 ] esperado: 0x10.
--   IFBuffer banco B: buf_sel='0' escribe B, buf_sel='1' lee B.
--     mismas direcciones PW1x1 2x2: 0, 1, 4, 5.
--   WeightBuffer [ 0 - 15 ]: addr_w = co*Cin + ci, co = 0, recargado para esta capa.

entity tb_multilayer3 is
end tb_multilayer3;

architecture Behavioral of tb_multilayer3 is

    constant CLK_PERIOD    : time := 10 ns;
    constant VAL_01        : std_logic_vector( 127 downto 0 ) := x"01010101010101010101010101010101";
    constant VAL_02        : std_logic_vector( 127 downto 0 ) := x"02020202020202020202020202020202";
    constant VAL_10        : std_logic_vector( 127 downto 0 ) := x"10101010101010101010101010101010";
    constant EXPECTED_T0   : std_logic_vector( 127 downto 0 ) := x"10101010101010101010101010101010";
    constant EXPECTED_T1   : std_logic_vector( 127 downto 0 ) := x"20202020202020202020202020202020";
    constant EXPECTED_GAP  : std_logic_vector( 127 downto 0 ) := x"10101010101010101010101010101010";

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    signal reg_start        : std_logic := '0';
    signal reg_mode         : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal cin              : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal max_inner        : std_logic_vector(  9 downto 0 ) := ( others => '0' );
    signal max_co           : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal max_x            : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal max_y             : std_logic_vector(  2 downto 0 ) := ( others => '0' );
    signal max_tile_x       : std_logic := '0';
    signal max_tile_y       : std_logic_vector(  4 downto 0 ) := ( others => '0' );
    signal reg_has_residual : std_logic := '0';
    signal reg_pool_en      : std_logic := '0';
    signal reg_pool_type    : std_logic := '0';
    signal reg_shift        : std_logic_vector(  4 downto 0 ) := ( others => '0' );
    signal reg_relu6_val    : std_logic_vector(  7 downto 0 ) := ( others => '0' );
    signal reg_gap_shift    : std_logic_vector(  4 downto 0 ) := ( others => '0' );

    signal buf_sel          : std_logic := '0';
    signal dma_if_wr_en     : std_logic := '0';
    signal dma_if_wr_addr   : std_logic_vector( 12 downto 0 ) := ( others => '0' );
    signal dma_if_wr_data   : std_logic_vector( 127 downto 0 ) := ( others => '0' );

    signal dma_wb_wr_en     : std_logic := '0';
    signal dma_wb_wr_addr   : std_logic_vector(  7 downto 0 ) := ( others => '0' );
    signal dma_wb_wr_data   : std_logic_vector( 127 downto 0 ) := ( others => '0' );

    signal dma_rb_wr_en     : std_logic := '0';
    signal dma_rb_wr_addr   : std_logic_vector( 11 downto 0 ) := ( others => '0' );
    signal dma_rb_wr_data   : std_logic_vector( 127 downto 0 ) := ( others => '0' );

    signal dma_ob_rd_en     : std_logic := '0';
    signal dma_ob_rd_addr   : std_logic_vector( 11 downto 0 ) := ( others => '0' );
    signal dma_ob_rd_data   : std_logic_vector( 127 downto 0 );

    signal tile_ready : std_logic := '0';
    signal tile_req   : std_logic;

    signal reg_done : std_logic;
    signal irq_out  : std_logic;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.cnn_accelerator
        port map(
            clk              => clk,
            reset            => reset,
            reg_start        => reg_start,
            reg_mode         => reg_mode,
            cin              => cin,
            max_inner        => max_inner,
            max_co           => max_co,
            max_x            => max_x,
            max_y            => max_y,
            max_tile_x       => max_tile_x,
            max_tile_y       => max_tile_y,
            reg_has_residual => reg_has_residual,
            reg_pool_en      => reg_pool_en,
            reg_pool_type    => reg_pool_type,
            shift            => reg_shift,
            relu6_val        => reg_relu6_val,
            gap_shift        => reg_gap_shift,
            buf_sel          => buf_sel,
            dma_if_wr_en     => dma_if_wr_en,
            dma_if_wr_addr   => dma_if_wr_addr,
            dma_if_wr_data   => dma_if_wr_data,
            dma_wb_wr_en     => dma_wb_wr_en,
            dma_wb_wr_addr   => dma_wb_wr_addr,
            dma_wb_wr_data   => dma_wb_wr_data,
            dma_rb_wr_en     => dma_rb_wr_en,
            dma_rb_wr_addr   => dma_rb_wr_addr,
            dma_rb_wr_data   => dma_rb_wr_data,
            dma_ob_rd_en     => dma_ob_rd_en,
            dma_ob_rd_addr   => dma_ob_rd_addr,
            dma_ob_rd_data   => dma_ob_rd_data,
            tile_ready       => tile_ready,
            tile_req         => tile_req,
            reg_done         => reg_done,
            irq_out          => irq_out
        );

    process
    begin

        -- Reset: 4 ciclos activo.
        reset <= '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        reset <= '0';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- CAPA 1: PW1x1, tile 2x2, 2 tiles horizontales (TILE_WAIT / TILE_HOLD)
        report "=== INICIO CAPA 1: PW1x1 2x2, 2 tiles (TILE_WAIT) ===";

        -- Cargar WeightBuffer [ 0 - 15 ]: addr_w = co*Cin + ci, co = 0. Se usa para
        -- ambos tiles, no se recarga entre tiles (los pesos son por capa).
        dma_wb_wr_data <= VAL_01;
        for addr in 0 to 15 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( addr, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco A con datos del tile 0 (0x01).
        buf_sel        <= '1';           -- escribe A
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= VAL_01;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 0, 13 ) ); -- pixel(0,0)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 1, 13 ) ); -- pixel(0,1)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 4, 13 ) ); -- pixel(1,0)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 5, 13 ) ); -- pixel(1,1)
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- Configurar y arrancar Capa 1 con max_tile_x = '1' (2 tiles).
        buf_sel          <= '0';           -- lee A
        reg_mode         <= "10";          -- PW1x1
        cin              <= "0010000";     -- Cin = 16
        max_inner        <= "0000010000";  -- 16 MACs validos (Cin=16)
        max_co           <= "00";          -- 1 co_group (Cout=16)
        max_x            <= "0000001";     -- 1 (2 columnas)
        max_y            <= "001";         -- 1 (2 filas)
        max_tile_x       <= '1';           -- 2 tiles horizontales
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '0';
        reg_pool_type    <= '0';
        reg_shift        <= "00000";       -- shift=0: 16>>0=16=0x10
        reg_relu6_val    <= x"7F";
        reg_gap_shift    <= "00000";
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';

        -- Esperar a que termine el tile 0: tile_req='1' en vez de irq_out,
        -- porque layer_done='0' todavia (queda el tile 1 por procesar).
        wait until tile_req = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "--- TILE_WAIT alcanzado: verificando OFBuffer del tile 0 ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "Tile0 OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_T0
                report "FALLO tile 0 en OFBuffer[" & integer'image( addr ) & "]"
                severity error;
        end loop;
        dma_ob_rd_en <= '0';
        wait until rising_edge( clk );

        -- El DMA recarga el IFBuffer (misma direccion fisica, banco A) con
        -- los datos del tile 1 (0x02) mientras el acelerador esta congelado
        -- en TILE_WAIT / TILE_HOLD. buf_sel debe volver a '0' antes de
        -- liberar tile_ready para que el acelerador siga leyendo el banco A.
        report "--- Recargando IFBuffer banco A con datos del tile 1 (0x02) ---";
        buf_sel        <= '1';           -- escribe A
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= VAL_02;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 0, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 1, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 4, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 5, 13 ) );
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        buf_sel      <= '0';             -- vuelve a leer A antes de liberar
        wait until rising_edge( clk );

        -- Liberar TILE_WAIT / TILE_HOLD: pulso de 1 ciclo en tile_ready.
        report "--- Liberando TILE_WAIT: pulso de tile_ready ---";
        tile_ready <= '1';
        wait until rising_edge( clk );
        tile_ready <= '0';

        -- Ahora si es el ultimo tile: layer_done='1' -> DONE -> irq_out.
        wait until irq_out = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "--- Capa 1 completa: verificando OFBuffer del tile 1 ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "Tile1 OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_T1
                report "FALLO tile 1 en OFBuffer[" & integer'image( addr ) & "]"
                severity error;
        end loop;
        dma_ob_rd_en <= '0';
        wait until rising_edge( clk );

        -- Volver a IDLE.
        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "=== CAPA 1 OK (TILE_WAIT / TILE_HOLD verificado) ===";

        -- CAPA 2: PW1x1 + GAP, tile 2x2, 1 tile
        -- INTER-CAPA 1 -> 2: PS recarga pesos y vuelca el resultado del
        -- tile 0 de la Capa 1 (0x10) al IFBuffer B como entrada representativa.
        report "--- Inter-capa 1->2: cargando pesos e IFBuffer B con 0x10 ---";

        dma_wb_wr_data <= VAL_01;
        for addr in 0 to 15 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( addr, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        buf_sel        <= '0';           -- escribe B
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= VAL_10;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 0, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 1, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 4, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 5, 13 ) );
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        report "=== INICIO CAPA 2: PW1x1 + GAP, acts=0x10 ===";

        buf_sel          <= '1';           -- lee B
        reg_mode         <= "10";          -- PW1x1
        cin              <= "0010000";     -- Cin = 16
        max_inner        <= "0000010000";  -- 16 MACs validos
        max_co           <= "00";
        max_x            <= "0000001";
        max_y            <= "001";
        max_tile_x       <= '0';           -- 1 tile
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '1';           -- pooling activo
        reg_pool_type    <= '1';           -- GAP
        reg_shift        <= "00100";       -- shift=4: 256>>4=16=0x10
        reg_relu6_val    <= x"7F";
        reg_gap_shift    <= "00010";       -- gap_shift=2: 64>>2=16=0x10
        wait until rising_edge( clk );
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';

        -- 1 solo tile: nunca pasa por TILE_WAIT, va directo a FLUSH (GAP) y DONE.
        wait until irq_out = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "--- Verificando OFBuffer Capa 2 (GAP) ---";
        dma_ob_rd_en   <= '1';
        dma_ob_rd_addr <= std_logic_vector( to_unsigned( 0, 12 ) );
        wait until rising_edge( clk );
        wait for 1 ns;
        report "GAP OFBuffer[0] = " &
               integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
        assert dma_ob_rd_data = EXPECTED_GAP
            report "FALLO GAP en OFBuffer[0]"
            severity error;
        dma_ob_rd_en <= '0';
        wait until rising_edge( clk );

        -- Volver a IDLE.
        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "=== CAPA 2 OK ===";
        report "=== TEST MULTILAYER3 COMPLETADO: TILE_WAIT + GAP en cadena VERIFICADO ===" severity note;
        wait;
    end process;

end Behavioral;
