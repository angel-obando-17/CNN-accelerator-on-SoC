library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: Bottleneck multilayer | PW1x1 -> DW3x3 -> PW1x1 + Residual.
--
-- Valida: reutilizacion del acelerador entre capas, ping-pong del IFBuffer,
-- reset del addr_gen entre capas, y transferencia OFBuffer -> IFBuffer.
-- Tile 2x2, Cin=Cout=16 en las 3 capas. Todas las entradas y pesos = 0x01.
--
-- CAPA 1 | PW1x1 | acts=0x01, W=0x01, shift=0
--   16*(1*1) = 16 = 0x10. OFBuffer[ 0 - 3 ] esperado: 0x10...10.
--   IFBuffer banco A: buf_sel = '1' escribe A, buf_sel = '0' lee A.
--   Direcciones (tile_w_pad=4, PW1x1 fija ky=kx=1, ver ky_kx_reset_val en
--   addr_generator.vhd -- fix del 2026-07-11): pixel(0,0)=5, pixel(0,1)=6,
--   pixel(1,0)=9, pixel(1,1)=10.
--   WeightBuffer [ 0 - 15 ]: addr_w = co*Cin + ci, co = 0, ci = 0..15.
--
-- CAPA 2 | DW3x3 | acts=0x10, W=0x01, shift=4
--   9*(16*1) = 144 >> 4 = 9 = 0x09. OFBuffer[ 0 - 3 ] esperado: 0x09...09.
--   IFBuffer banco B: buf_sel = '0' escribe B, buf_sel = '1' lee B.
--   Direcciones ( 16 palabras, addr 0 a 15 ): tile 2x2 con kernel 3x3 cubre
--   toda la region con padding 4x4 (row_buf=y+ky, col_buf=x+kx, tile_w_pad=4).
--   WeightBuffer [ 0 - 8 ]: addr_w = co*9 + ky*3 + kx, co = 0.
--
-- CAPA 3 | PW1x1 + Residual | acts=0x09, W=0x01, shift=4, res=0x01
--   PW1x1: 16*(9*1) = 144 >> 4 = 9 = 0x09. Add: sat8( 9 + 1 ) = 10 = 0x0A.
--   OFBuffer[ 0 - 3 ] esperado: 0x0A...0A.
--   IFBuffer banco A: buf_sel = '1' escribe A, buf_sel = '0' lee A.
--   Direcciones: identicas a Capa 1 (misma formula PW1x1 tile 2x2).
--   ResidualBuffer [ 0 - 3 ]: addr = 2*y + x (pre-cargado al inicio, addr_out sin cambios).

entity tb_multilayer is
end tb_multilayer;

architecture Behavioral of tb_multilayer is

    constant CLK_PERIOD  : time := 10 ns;
    constant ALL_ONES    : std_logic_vector( 127 downto 0 ) := x"01010101010101010101010101010101";
    constant VAL_10      : std_logic_vector( 127 downto 0 ) := x"10101010101010101010101010101010";
    constant VAL_09      : std_logic_vector( 127 downto 0 ) := x"09090909090909090909090909090909";
    constant EXPECTED_L1 : std_logic_vector( 127 downto 0 ) := x"10101010101010101010101010101010";
    constant EXPECTED_L2 : std_logic_vector( 127 downto 0 ) := x"09090909090909090909090909090909";
    constant EXPECTED_L3 : std_logic_vector( 127 downto 0 ) := x"0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A";

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

        -- Pre-cargar ResidualBuffer [ 0 - 3 ] = 0x01.
        -- Simula la conexion de skip del bottleneck: el PS guarda el feature map
        -- original antes de iniciar las 3 capas. Se usa en Capa 3.
        -- addr_res = y*tile_w*num_co + x*num_co + co = 2*y + x.
        dma_rb_wr_data <= ALL_ONES;
        for addr in 0 to 3 loop
            dma_rb_wr_en   <= '1';
            dma_rb_wr_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
        end loop;
        dma_rb_wr_en <= '0';
        wait until rising_edge( clk );

        -- CAPA 1: PW1x1 | acts = 0x01, W = 0x01, shift = 0
        -- Resultado esperado: 16*(1*1) = 16 = 0x10. OFBuffer[ 0 - 3 ] = 0x10...10.
        -- Usa IFBuffer banco A (buf_sel = '1' escribe A, buf_sel = '0' lee A).
        report "=== INICIO CAPA 1: PW1x1 2x2 all-ones ===";

        -- Cargar WeightBuffer PW1x1 [ 0 - 15 ]: addr_w = co*Cin + ci, co = 0, ci = 0..15.
        dma_wb_wr_data <= ALL_ONES;
        for ci in 0 to 15 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( ci, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco A ( buf_sel = '1' ): 4 pixeles del tile 2x2.
        -- addr_in = (y+1)*tile_w_pad + (x+1), tile_w_pad = 4, cin_groups = 1.
        buf_sel        <= '1';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= ALL_ONES;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 5, 13 ) ); -- pixel(0,0)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 6, 13 ) ); -- pixel(0,1)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 9, 13 ) ); -- pixel(1,0)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 10, 13 ) ); -- pixel(1,1)
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- Configurar y arrancar Capa 1.
        buf_sel          <= '0';           -- lee banco A
        reg_mode         <= "10";          -- PW1x1
        cin              <= "0010000";     -- Cin = 16
        max_inner        <= "0000010000";  -- 16 MACs validos (Cin=16)
        max_co           <= "00";          -- 0 (1 co_group: Cout=16)
        max_x            <= "0000001";     -- 1 (2 columnas)
        max_y            <= "001";         -- 1 (2 filas)
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '0';
        reg_pool_type    <= '0';
        reg_shift        <= "00000";       -- shift=0: 16>>0=0x10
        reg_relu6_val    <= x"7F";
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

        -- Verificar OFBuffer Capa 1.
        report "--- Verificando OFBuffer Capa 1 ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "L1 OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_L1
                report "FALLO Capa 1 en OFBuffer[" & integer'image( addr ) & "]"
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

        report "=== CAPA 1 OK ===";

        -- INTER-CAPA 1 -> 2
        -- Simula al PS: recarga pesos DW3x3 y vuelca OFBuffer L1 -> IFBuffer B.
        -- buf_sel permanece '0' (escribe banco B automaticamente).
        report "--- Inter-capa 1->2: cargando pesos DW3x3 e IFBuffer B con 0x10 ---";

        -- Cargar WeightBuffer DW3x3 [ 0 - 8 ]: addr_w = co*9 + ky*3 + kx, co = 0.
        -- Cada palabra de 128b contiene los pesos de todos los canales en esa posicion (ky,kx).
        dma_wb_wr_data <= ALL_ONES;
        for addr in 0 to 8 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( addr, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco B ( buf_sel = '0' ): direcciones 0 a 15 con 0x10.
        -- ( toda la region con padding 4x4 que cubre el tile 2x2 + halo de 1px ).
        buf_sel        <= '0';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= VAL_10;
        wait until rising_edge( clk );

        for addr in 0 to 15 loop
            dma_if_wr_addr <= std_logic_vector( to_unsigned( addr, 13 ) );
            wait until rising_edge( clk );
        end loop;

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- CAPA 2: DW3x3 | acts = 0x10, W = 0x01, shift = 4
        -- Resultado esperado: 9*(16*1) = 144 >> 4 = 9 = 0x09. OFBuffer[ 0 - 3 ] = 0x09...09.
        -- Usa IFBuffer banco B ( buf_sel = '1' lee B).
        report "=== INICIO CAPA 2: DW3x3 2x2, acts=0x10 ===";

        buf_sel          <= '1';           -- lee banco B
        reg_mode         <= "01";          -- DW3x3
        cin              <= "0010000";     -- Cin = 16
        max_inner        <= "0000001001";  -- 9 (3x3, sin loop de Cin)
        max_co           <= "00";
        max_x            <= "0000001";
        max_y            <= "001";
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '0';
        reg_pool_en      <= '0';
        reg_pool_type    <= '0';
        reg_shift        <= "00100";       -- shift=4: 144>>4=9=0x09
        reg_relu6_val    <= x"7F";
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

        -- Verificar OFBuffer Capa 2.
        report "--- Verificando OFBuffer Capa 2 ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "L2 OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_L2
                report "FALLO Capa 2 en OFBuffer[" & integer'image( addr ) & "]"
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

        report "=== CAPA 2 OK ===";

        -- INTER-CAPA 2 -> 3
        -- Simula al PS: recarga pesos PW1x1 y vuelca OFBuffer L2 -> IFBuffer A.
        -- buf_sel = '1' escribe banco A.
        report "--- Inter-capa 2->3: cargando pesos PW1x1 e IFBuffer A con 0x09 ---";

        -- Cargar WeightBuffer PW1x1 [ 0 - 15 ]: co = 0, ci = 0..15.
        dma_wb_wr_data <= ALL_ONES;
        for ci in 0 to 15 loop
            dma_wb_wr_en   <= '1';
            dma_wb_wr_addr <= std_logic_vector( to_unsigned( ci, 8 ) );
            wait until rising_edge( clk );
        end loop;
        dma_wb_wr_en <= '0';
        wait until rising_edge( clk );

        -- Cargar IFBuffer banco A ( buf_sel = '1' ): 4 pixeles con 0x09.
        -- Sobreescribe banco A con el output de Capa 2.
        buf_sel        <= '1';
        dma_if_wr_en   <= '1';
        dma_if_wr_data <= VAL_09;
        wait until rising_edge( clk );

        dma_if_wr_addr <= std_logic_vector( to_unsigned( 5, 13 ) ); -- pixel(0,0)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 6, 13 ) ); -- pixel(0,1)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 9, 13 ) ); -- pixel(1,0)
        wait until rising_edge( clk );
        dma_if_wr_addr <= std_logic_vector( to_unsigned( 10, 13 ) ); -- pixel(1,1)
        wait until rising_edge( clk );

        dma_if_wr_en <= '0';
        wait until rising_edge( clk );

        -- CAPA 3: PW1x1 + Residual | acts = 0x09, W = 0x01, shift = 4, res = 0x01
        -- PW1x1: 16*(9*1) = 144 >> 4 = 9 = 0x09. Add: sat8( 9 + 1 ) = 10 = 0x0A.
        -- OFBuffer[ 0 - 3 ] esperado: 0x0A...0A.
        -- Usa IFBuffer banco A ( buf_sel = '0' lee A ).
        report "=== INICIO CAPA 3: PW1x1 + Residual, acts=0x09, res=0x01 ===";

        buf_sel          <= '0';           -- lee banco A
        reg_mode         <= "10";          -- PW1x1
        cin              <= "0010000";     -- Cin = 16
        max_inner        <= "0000010000";  -- 16 MACs validos
        max_co           <= "00";
        max_x            <= "0000001";
        max_y            <= "001";
        max_tile_x       <= '0';
        max_tile_y       <= "00000";
        reg_has_residual <= '1';           -- RESIDUAL ACTIVO
        reg_pool_en      <= '0';
        reg_pool_type    <= '0';
        reg_shift        <= "00100";       -- shift=4: 144>>4=9=0x09 antes de add
        reg_relu6_val    <= x"7F";
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

        -- Verificar OFBuffer Capa 3.
        report "--- Verificando OFBuffer Capa 3 (con Residual) ---";
        for addr in 0 to 3 loop
            dma_ob_rd_en   <= '1';
            dma_ob_rd_addr <= std_logic_vector( to_unsigned( addr, 12 ) );
            wait until rising_edge( clk );
            wait for 1 ns;
            report "L3 OFBuffer[" & integer'image( addr ) & "] = " &
                   integer'image( to_integer( unsigned( dma_ob_rd_data( 31 downto 0 ) ) ) );
            assert dma_ob_rd_data = EXPECTED_L3
                report "FALLO Capa 3 en OFBuffer[" & integer'image( addr ) & "]"
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

        report "=== CAPA 3 OK ===" severity note;
        report "=== TEST MULTILAYER COMPLETADO: PW1x1->DW3x3->PW1x1+Res VERIFICADO ===" severity note;
        wait;
    end process;

end Behavioral;
