library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: Residual Add | PW1x1 | Cin=16, Cout=16 | tile 2x2
--
-- Todas las activaciones y pesos = 0x01.  Residual buffer = 0x01.
-- PW1x1: 16 acumulaciones de (1*1) = 16 = 0x10. Shift=0.
-- Add unit: sat8(0x10 + 0x01) = sat8(17) = 17 = 0x11. Sin saturacion (17 < 127).
-- OFBuffer[0..3] esperado: 0x11...11.
--
-- Direcciones IFBuffer (addr_in = (y-1 mod 16)*2 + (x-1 mod 256), cin_groups=1):
--   pixel(0,0)=285  pixel(0,1)=30  pixel(1,0)=255  pixel(1,1)=0
-- Direcciones WeightBuffer: [0, 15] (co=0, ci=0..15)
-- Direcciones ResidualBuffer: [0, 3] (addr_out = y*tile_w*num_co + x*num_co + co = 2y+x)

entity tb_add is
end tb_add;

architecture Behavioral of tb_add is

    constant CLK_PERIOD   : time := 10 ns;
    constant ALL_ONES_128 : std_logic_vector( 127 downto 0 ) := x"01010101010101010101010101010101";
    constant EXPECTED_OUT : std_logic_vector( 127 downto 0 ) := x"11111111111111111111111111111111";

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
    signal dma_if_wr_addr   : std_logic_vector( 11 downto 0 ) := ( others => '0' );
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

        report "=== INICIO TEST: Residual Add, PW1x1 2x2 all-ones ===";

        -- Cargar WeightBuffer: 16 palabras (addr 0..15), todas 0x01.
        -- addr_w PW1x1 = co*Cin + ci, con co=0, ci=0..15.
        dma_wb_wr_data <= ALL_ONES_128;
        for ci in 0 to 15 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( ci, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco A (buf_sel='1'): 4 direcciones, todas 0x01.
        -- addr_in PW1x1 = (y-1 mod 16)*tile_w + (x-1 mod 256), tile_w=2, cin_groups=1.
        buf_sel        <= '1';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= ALL_ONES_128;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 285, 12 ) ); -- pixel(0,0): row=15, col=255
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 30,  12 ) ); -- pixel(0,1): row=15, col=0
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 255, 12 ) ); -- pixel(1,0): row=0,  col=255
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 0,   12 ) ); -- pixel(1,1): row=0,  col=0
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar ResidualBuffer: 4 palabras (addr 0..3), todas 0x01.
        -- addr = ag_addr_out en POST = y*tile_w*num_co + x*num_co + co = 2y + x.
        dma_rb_wr_data <= ALL_ONES_128;
        for addr in 0 to 3 loop
            dma_rb_wr_en   <= '1';
            dma_rb_wr_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
        end loop;
        dma_rb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Configurar registros.
        buf_sel          <= '0';
        reg_mode         <= "10";         -- PW1x1
        cin              <= "0010000";    -- Cin = 16
        max_inner        <= "0000010000"; -- 16 MACs validos (Cin=16)
        max_co           <= "00";         -- 0  (1 co_group: Cout=16)
        max_x            <= "0000001";    -- 1  (2 columnas)
        max_y            <= "001";        -- 1  (2 filas)
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '1';          -- RESIDUAL ACTIVO
        reg_pool_en      <= '0';
        reg_pool_type    <= '0';
        reg_shift        <= "00000";      -- shift=0 (16 >> 0 = 0x10)
        reg_relu6_val    <= x"7F";        -- 127, no recorta la salida de 16
        reg_gap_shift    <= "00000";
        wait until rising_edge( clk );

        -- 2 ciclos de warmup para registros de pipeline.
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- Pulso de start (1 ciclo).
        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';

        wait until irq_out = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- Verificar OFBuffer[0..3] = 0x11...11
        -- quant_relu: 0x10. Residual: 0x01. Add: sat8(16+1) = 17 = 0x11.
        report "--- Verificando OFBuffer (Residual Add) ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_OUT
                report "FALLO Residual Add en OFBuffer[" & integer'image( addr ) & "]"
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

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
