library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: Conv3x3 | Cin=16, Cout=16 | tile 2x2
--
-- Todas las activaciones y pesos = 0x01.
-- Cada MAC acumula 16*9=144 productos de (1*1)=144. Con shift=4: 144 >> 4 = 9 = 0x09.
--
-- Direcciones IFBuffer ( 14 palabras unicas ):
--   addr: 0, 1, 2, 3, 4, 5, 6, 30, 31, 32, 255, 257, 259, 285
--   Incluyen los bordes con wrapping circular ( y - 1 y x - 1  cuando el pixel es ( 0, 0 ) )
--
-- Direcciones WeightBuffer: [ 0, 143 ] (co*Cin*9 + ci*9 + ky*3 + kx)
--
-- Salida esperada: 0x09 en cada byte de OFBuffer [ 0, 3 ]-

entity tb_conv3x3 is
end tb_conv3x3;

architecture Behavioral of tb_conv3x3 is

    constant CLK_PERIOD   : time := 10 ns;
    constant ALL_ONES_128 : std_logic_vector( 127 downto 0 ) := x"01010101010101010101010101010101";
    constant EXPECTED_OUT : std_logic_vector( 127 downto 0 ) := x"09090909090909090909090909090909";

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

        report "=== INICIO TEST: Conv3x3 2x2 all-ones ===";

        -- Cargar WeightBuffer: 144 palabras (addr [ 0, 143 ] ), todas 0x01
        -- addr_w = co*Cin*9 + ci*9 + ky*3 + kx, con co=0, ci = [ 0, 15 ], ky/kx=0..2
        dma_wb_wr_data <= ALL_ONES_128;
        for addr in 0 to 143 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( addr, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco A: 14 direcciones unicas, todas 0x01
        -- Incluyen bordes con wrapping: addr 255/257/259/285 son los pixeles de
        -- la vecindad de (y=0,x=0) que caen fuera del tile (y-1, x-1)
        buf_sel        <= '1';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= ALL_ONES_128;
        wait until rising_edge( clk );

        -- Grupo [ 0, 6 ] (vecindad de pixeles (y=1,x=0) y (y=1,x=1) en el tile)
        for addr in 0 to 6 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
        end loop;

        -- Grupo [ 30, 32 ] (vecindad del borde superior: row=15 del IFBuffer).
        for addr in 30 to 32 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
        end loop;

        -- Direcciones de borde izquierdo ( col=255, wrapping de x-1 cuando x=0 )
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 255, 12 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 257, 12 ) );
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 259, 12 ) );
        wait until rising_edge( clk );

        -- Esquina superior-izquierda ( row=15, col=255 ): solo pixel (y=0, x=0) la usa.
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 285, 12 ) );
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- Configura registros de la capa.
        buf_sel          <= '0';
        reg_mode         <= "00";         -- Conv3x3
        cin              <= "0010000";    -- Cin = 16
        max_inner        <= "0010010000"; -- 143 (16x9 - 1)
        max_co           <= "00";         -- 0  (1 co_group: Cout = 16)
        max_x            <= "0000001";    -- 1  (2 columnas)
        max_y            <= "001";        -- 1  (2 filas)
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '0';
        reg_pool_type    <= '0';
        reg_shift        <= "00100";      -- shift = 4 (144 >> 4 = 9 = 0x09)
        reg_relu6_val    <= x"7F";        -- 127, no recorta la salida de 9
        reg_gap_shift    <= "00000";
        wait until rising_edge( clk );

        -- 2 ciclos de warmup para que weight_reg y act_reg esten estables
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- Pulso de start (1 ciclo)
        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';

        wait until irq_out = '1';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        -- Leer y verificar OFBuffer (latencia BRAM = 1 ciclo)
        report "--- Verificando OFBuffer ---";

        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );

            assert dma_ob_rd_data = EXPECTED_OUT
                report "FALLO en OFBuffer[" & integer'image( addr ) & "]"
                severity error;
        end loop;
        dma_ob_rd_en <= '0';
        wait until rising_edge( clk );

        -- Volver FSM a IDLE
        reg_start <= '1';
        wait until rising_edge( clk );
        reg_start <= '0';
        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
