library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: MaxPool 2x2 y GAP | PW1x1 | Cin=16, Cout=16
--
-- TEST 1 - MaxPool 2x2 | tile 4x4 all-ones
--   Cada pixel: 16 acumulaciones de (1*1) = 16 = 0x10. Shift=0.
--   MaxPool 2x2 de tile 4x4 -> salida 2x2. Todos los valores iguales.
--   OFBuffer[0..3] esperado: 0x10...10.
--
--   Direcciones IFBuffer (addr_in = (y+ky)*tile_w_pad + (x+kx), tile_w_pad=TILE_W+2=6,
--   cin_groups=1; PW1x1 fija ky=kx=1, ver ky_kx_reset_val en addr_generator.vhd
--   -- fix del 2026-07-11 para saltar el halo):
--     y=0: 7,8,9,10  y=1: 13,14,15,16  y=2: 19,20,21,22  y=3: 25,26,27,28
--   Direcciones WeightBuffer: [0, 15] (co=0, ci=0..15)
--
-- TEST 2 - GAP | tile 2x2 all-ones, gap_shift=2
--   Cada pixel: 0x10. 4 pixeles por canal: 4*16=64. gap_shift=2: 64>>2=16=0x10.
--   OFBuffer[0] esperado: 0x10...10.
--
--   Direcciones IFBuffer (tile_w_pad=4, cin_groups=1, ky=kx=1): 5, 6, 9, 10
--   Direcciones WeightBuffer: [0, 15]

entity tb_pool is
end tb_pool;

architecture Behavioral of tb_pool is

    constant CLK_PERIOD   : time := 10 ns;
    constant ALL_ONES_128 : std_logic_vector( 127 downto 0 ) := x"01010101010101010101010101010101";
    constant EXPECTED_10  : std_logic_vector( 127 downto 0 ) := x"10101010101010101010101010101010";

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    signal reg_start        : std_logic := '0';
    signal reg_mode         : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal cin              : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal max_inner        : std_logic_vector(  9 downto 0 ) := ( others => '0' );
    signal max_co           : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal max_x            : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal max_y            : std_logic_vector(  2 downto 0 ) := ( others => '0' );
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

        -- ===================================================================
        -- TEST 1: MaxPool 2x2 | PW1x1 | tile 4x4 all-ones
        -- ===================================================================
        report "=== INICIO TEST 1: MaxPool 2x2, PW1x1 4x4 all-ones ===";

        -- Cargar WeightBuffer: 16 palabras (addr 0..15), todas 0x01.
        -- addr_w PW1x1 = co*Cin + ci, con co=0, ci=0..15.
        dma_wb_wr_data <= ALL_ONES_128;
        for addr in 0 to 15 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( addr, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco A (buf_sel='1'): 16 direcciones, todas 0x01.
        -- addr_in = (y+1)*tile_w_pad + (x+1), tile_w_pad=6 (TILE_W=4+2), cin_groups=1.
        buf_sel        <= '1';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= ALL_ONES_128;
        wait until rising_edge( clk );

        -- Fila y=0: addr 7, 8, 9, 10.
        for addr in 7 to 10 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 13 ) );
            wait until rising_edge( clk );
        end loop;

        -- Fila y=1: addr 13, 14, 15, 16.
        for addr in 13 to 16 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 13 ) );
            wait until rising_edge( clk );
        end loop;

        -- Fila y=2: addr 19, 20, 21, 22.
        for addr in 19 to 22 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 13 ) );
            wait until rising_edge( clk );
        end loop;

        -- Fila y=3: addr 25, 26, 27, 28.
        for addr in 25 to 28 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 13 ) );
            wait until rising_edge( clk );
        end loop;

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- Configurar registros: PW1x1, tile 4x4, MaxPool 2x2.
        buf_sel          <= '0';
        reg_mode         <= "10";         -- PW1x1
        cin              <= "0010000";    -- Cin = 16
        max_inner        <= "0000010000"; -- 16 MACs validos (Cin=16)
        max_co           <= "00";         -- 0  (1 co_group: Cout=16)
        max_x            <= "0000011";    -- 3  (4 columnas)
        max_y            <= "011";        -- 3  (4 filas)
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '1';
        reg_pool_type    <= '0';          -- MaxPool 2x2
        reg_shift        <= "00000";      -- shift=0 (16 >> 0 = 0x10)
        reg_relu6_val    <= x"7F";        -- 127, no recorta la salida de 16
        reg_gap_shift    <= "00000";
        wait until rising_edge( clk );

        wait until rising_edge( clk );
        wait until rising_edge( clk );

        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';

        wait until irq_out = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- Verificar OFBuffer[0..3]: MaxPool 2x2 de tile 4x4 all-0x10 = 0x10.
        report "--- Verificando OFBuffer (MaxPool 2x2) ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_10
                report "FALLO MaxPool en OFBuffer[" & integer'image( addr ) & "]"
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

        report "=== TEST 1 FINALIZADO ===";

        -- ===================================================================
        -- TEST 2: GAP | PW1x1 | tile 2x2 all-ones, gap_shift=2
        -- ===================================================================
        report "=== INICIO TEST 2: GAP, PW1x1 2x2 all-ones ===";

        -- Cargar IFBuffer banco A: direcciones para tile 2x2 (tile_w_pad=4, cin_groups=1, ky=kx=1).
        -- pixel(0,0)=5  pixel(0,1)=6  pixel(1,0)=9  pixel(1,1)=10
        buf_sel        <= '1';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= ALL_ONES_128;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 5, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 6, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 9, 13 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 10, 13 ) );
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- Configurar registros: PW1x1, tile 2x2, GAP.
        -- gap_shift=2: 4 pixeles * 0x10 = 64, 64 >> 2 = 16 = 0x10.
        buf_sel          <= '0';
        reg_mode         <= "10";         -- PW1x1
        cin              <= "0010000";    -- Cin = 16
        max_inner        <= "0000010000"; -- 16 MACs validos
        max_co           <= "00";         -- 0
        max_x            <= "0000001";    -- 1  (2 columnas)
        max_y            <= "001";        -- 1  (2 filas)
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '1';
        reg_pool_type    <= '1';          -- GAP
        reg_shift        <= "00000";      -- shift=0 (16 >> 0 = 0x10)
        reg_relu6_val    <= x"7F";
        reg_gap_shift    <= "00010";      -- gap_shift=2 (64 >> 2 = 0x10)
        wait until rising_edge( clk );

        wait until rising_edge( clk );
        wait until rising_edge( clk );

        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';

        wait until irq_out = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- Verificar OFBuffer[0]: GAP de 4 pixeles all-0x10 con shift=2 = 0x10.
        report "--- Verificando OFBuffer (GAP) ---";
        dma_ob_rd_en   <= '1';
        dma_ob_rd_addr <= std_logic_vector( to_unsigned( 0, 12 ) );
        wait until rising_edge( clk );
        wait for 1 ns;
        report "OFBuffer[0] = " &
               integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
        assert dma_ob_rd_data = EXPECTED_10
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

        report "=== TEST 2 FINALIZADO ===";
        report "=== TODOS LOS TESTS DE POOL FINALIZADOS ===" severity note;
        wait;
    end process;

end Behavioral;
