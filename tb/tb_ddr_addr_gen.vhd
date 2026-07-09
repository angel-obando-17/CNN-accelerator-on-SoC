library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: ddr_addr_gen ( generador de direcciones DDR por tile/fila )
--
-- Modulo puramente combinacional, sin reloj necesario para su logica ( se usa
-- un reloj solo como referencia de tiempo para los "wait" del testbench ).
--
-- Configuracion fija para todos los casos: TILE_W = 4, TILE_H = 2, Cin = Cout = 16
-- ( cin_groups = cout_groups = 1 ), NUM_TILE_X = NUM_TILE_Y = 3 ( IMG_W = 12 ), para
-- poder probar los 3 casos de columna/fila ( borde, interior ) con un tile
-- intermedio ( tile 1 de 0..2 ) realmente interior.
--
-- Direcciones base: addr_in = 0x10000000, addr_out = 0x20000000, addr_w = 0x30000000,
-- addr_res = 0x40000000.

entity tb_ddr_addr_gen is
end tb_ddr_addr_gen;

architecture Behavioral of tb_ddr_addr_gen is

    constant CLK_PERIOD : time := 10 ns;

    signal clk : std_logic := '0';

    signal img_w           : std_logic_vector(  8 downto 0 ) := std_logic_vector( to_unsigned( 12, 9 ) );
    signal tile_w          : std_logic_vector(  7 downto 0 ) := std_logic_vector( to_unsigned( 4, 8 ) );
    signal tile_h          : std_logic_vector(  3 downto 0 ) := std_logic_vector( to_unsigned( 2, 4 ) );
    signal num_tile_x      : std_logic_vector(  1 downto 0 ) := std_logic_vector( to_unsigned( 3, 2 ) );
    signal num_tile_y      : std_logic_vector(  5 downto 0 ) := std_logic_vector( to_unsigned( 3, 6 ) );
    signal cin             : std_logic_vector(  6 downto 0 ) := std_logic_vector( to_unsigned( 16, 7 ) );
    signal cout            : std_logic_vector(  6 downto 0 ) := std_logic_vector( to_unsigned( 16, 7 ) );
    signal pool_en         : std_logic := '0';
    signal addr_in         : std_logic_vector( 31 downto 0 ) := x"10000000";
    signal addr_out        : std_logic_vector( 31 downto 0 ) := x"20000000";
    signal addr_w          : std_logic_vector( 31 downto 0 ) := x"30000000";
    signal addr_res        : std_logic_vector( 31 downto 0 ) := x"40000000";
    signal weight_words    : std_logic_vector(  7 downto 0 ) := std_logic_vector( to_unsigned( 100, 8 ) );

    signal tile_x          : std_logic_vector(  1 downto 0 ) := ( others => '0' );
    signal tile_y          : std_logic_vector(  5 downto 0 ) := ( others => '0' );
    signal r_local         : std_logic_vector(  3 downto 0 ) := ( others => '0' );
    signal transfer_type   : std_logic_vector(  1 downto 0 ) := ( others => '0' );

    signal ddr_addr        : std_logic_vector( 31 downto 0 );
    signal burst_words     : std_logic_vector(  9 downto 0 );
    signal local_addr      : std_logic_vector( 12 downto 0 );
    signal skip_ddr        : std_logic;
    signal left_zero_en    : std_logic;
    signal left_zero_addr  : std_logic_vector( 12 downto 0 );
    signal right_zero_en   : std_logic;
    signal right_zero_addr : std_logic_vector( 12 downto 0 );

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.ddr_addr_gen
        port map(
            img_w           => img_w,
            tile_w          => tile_w,
            tile_h          => tile_h,
            num_tile_x      => num_tile_x,
            num_tile_y      => num_tile_y,
            cin             => cin,
            cout            => cout,
            pool_en         => pool_en,
            addr_in         => addr_in,
            addr_out        => addr_out,
            addr_w          => addr_w,
            addr_res        => addr_res,
            weight_words    => weight_words,
            tile_x          => tile_x,
            tile_y          => tile_y,
            r_local         => r_local,
            transfer_type   => transfer_type,
            ddr_addr        => ddr_addr,
            burst_words     => burst_words,
            local_addr      => local_addr,
            skip_ddr        => skip_ddr,
            left_zero_en    => left_zero_en,
            left_zero_addr  => left_zero_addr,
            right_zero_en   => right_zero_en,
            right_zero_addr => right_zero_addr
        );

    process
    begin

        wait until rising_edge( clk );
        wait until rising_edge( clk );

        report "=== INICIO TEST: ddr_addr_gen ===";

        -- CASO 1: IFM, tile interior ( 1, 1 ), r_local = 0 ( fila de arriba, sin halo por ser interior ).
        -- row_words_padded = ( 4 + 2 ) * 1 =6. r_global = 1 * 2 + 0 - 1 = 1. col_ddr_start = 1 * 4 - 1 = 3.
        -- ddr_addr = addr_in + 1 * ( 12 * 16 ) + 3 * 16 = addr_in + 240.
        report "--- Caso 1: IFM tile interior (1,1), r_local=0 ---";
        transfer_type <= "00";
        tile_x <= std_logic_vector( to_unsigned( 1, 2 ) );
        tile_y <= std_logic_vector( to_unsigned( 1, 6 ) );
        r_local <= std_logic_vector( to_unsigned( 0, 4 ) );
        wait for 1 ns;
        assert skip_ddr = '0'                                           report "FALLO caso 1: skip_ddr"    severity error;
        assert ddr_addr = std_logic_vector( unsigned( addr_in ) + 240 ) report "FALLO caso 1: ddr_addr"    severity error;
        assert burst_words = std_logic_vector( to_unsigned( 6, 10 ) )   report "FALLO caso 1: burst_words" severity error;
        assert local_addr = std_logic_vector( to_unsigned( 0, 13 ) )    report "FALLO caso 1: local_addr"  severity error;
        assert left_zero_en = '0' and right_zero_en = '0'               report "FALLO caso 1: zero_en"     severity error;

        -- CASO 2: IFM, tile esquina superior-izquierda ( 0, 0 ), r_local = 0 -> toda la fila es halo, skip_ddr = 1.
        report "--- Caso 2: IFM tile (0,0), r_local=0 (skip top edge) ---";
        tile_x <= std_logic_vector( to_unsigned( 0, 2 ) );
        tile_y <= std_logic_vector( to_unsigned( 0, 6 ) );
        r_local <= std_logic_vector( to_unsigned( 0, 4 ) );
        wait for 1 ns;
        assert skip_ddr = '1'                                          report "FALLO caso 2: skip_ddr"    severity error;
        assert burst_words = std_logic_vector( to_unsigned( 6, 10 ) )  report "FALLO caso 2: burst_words" severity error;
        assert local_addr = std_logic_vector( to_unsigned( 0, 13 ) )   report "FALLO caso 2: local_addr"  severity error;

        -- CASO 3: IFM, tile ( 0, 0 ), r_local = 1 ( fila real, pero borde izquierdo recorta columna ).
        -- col_ddr_start = 0 * 4 = 0 ( -1 + 1 se cancela ). r_global = 0 * 2 + 1 - 1 = 0.
        -- ddr_addr = addr_in + 0 + 0 = addr_in. burst_words = 6 - 1 = 5. local_addr = 1 * 6 + 1 = 7.
        -- left_zero_en = 1, left_zero_addr = 1 * 6 = 6.
        report "--- Caso 3: IFM tile (0,0), r_local=1 (borde izquierdo) ---";
        r_local <= std_logic_vector( to_unsigned( 1, 4 ) );
        wait for 1 ns;
        assert skip_ddr = '0'                                            report "FALLO caso 3: skip_ddr"       severity error;
        assert ddr_addr = addr_in                                        report "FALLO caso 3: ddr_addr"       severity error;
        assert burst_words = std_logic_vector( to_unsigned( 5, 10 ) )    report "FALLO caso 3: burst_words"    severity error;
        assert local_addr = std_logic_vector( to_unsigned( 7, 13 ) )     report "FALLO caso 3: local_addr"     severity error;
        assert left_zero_en = '1'                                        report "FALLO caso 3: left_zero_en"   severity error;
        assert left_zero_addr = std_logic_vector( to_unsigned( 6, 13 ) ) report "FALLO caso 3: left_zero_addr" severity error;
        assert right_zero_en = '0'                                       report "FALLO caso 3: right_zero_en"  severity error;

        -- CASO 4: IFM, tile esquina inferior-derecha ( 2, 2 ), r_local = 3 ( = tile_h + 1 ) -> skip bottom edge.
        report "--- Caso 4: IFM tile (2,2), r_local=3 (skip bottom edge) ---";
        tile_x <= std_logic_vector( to_unsigned( 2, 2 ) );
        tile_y <= std_logic_vector( to_unsigned( 2, 6 ) );
        r_local <= std_logic_vector( to_unsigned( 3, 4 ) );
        wait for 1 ns;
        assert skip_ddr = '1'                                          report "FALLO caso 4: skip_ddr"    severity error;
        assert local_addr = std_logic_vector( to_unsigned( 18, 13 ) )  report "FALLO caso 4: local_addr"  severity error;

        -- CASO 5: IFM, tile ( 2, 2 ), r_local = 1 ( fila real, borde derecho recorta columna ).
        -- col_ddr_start = 2 * 4 - 1 = 7. r_global = 2 * 2 + 1 - 1 = 4.
        -- ddr_addr = addr_in + 4 * 192 + 7 * 16 = addr_in + 880. burst_words = 5. local_addr = 1 * 6 = 6.
        -- right_zero_en = 1, right_zero_addr = 6 + ( 4 + 1 ) * 1 = 11.
        report "--- Caso 5: IFM tile (2,2), r_local=1 (borde derecho) ---";
        r_local <= std_logic_vector( to_unsigned( 1, 4 ) );
        wait for 1 ns;
        assert skip_ddr = '0'                                              report "FALLO caso 5: skip_ddr"        severity error;
        assert ddr_addr = std_logic_vector( unsigned( addr_in ) + 880 )    report "FALLO caso 5: ddr_addr"        severity error;
        assert burst_words = std_logic_vector( to_unsigned( 5, 10 ) )      report "FALLO caso 5: burst_words"     severity error;
        assert local_addr = std_logic_vector( to_unsigned( 6, 13 ) )       report "FALLO caso 5: local_addr"      severity error;
        assert right_zero_en = '1'                                         report "FALLO caso 5: right_zero_en"   severity error;
        assert right_zero_addr = std_logic_vector( to_unsigned( 11, 13 ) ) report "FALLO caso 5: right_zero_addr" severity error;
        assert left_zero_en = '0'                                          report "FALLO caso 5: left_zero_en"    severity error;

        -- CASO 6: OFM, tile ( 1, 1 ), r_local = 0, sin pooling.
        -- row_words_out = 4 * 1 = 4. r_global_out = 1 * 2 + 0 = 2. ddr_addr = addr_out + 2 * 192 + 1 * 4 * 16 = addr_out + 448.
        report "--- Caso 6: OFM tile (1,1), r_local=0, pool_en=0 ---";
        transfer_type <= "01";
        tile_x <= std_logic_vector( to_unsigned( 1, 2 ) );
        tile_y <= std_logic_vector( to_unsigned( 1, 6 ) );
        r_local <= std_logic_vector( to_unsigned( 0, 4 ) );
        pool_en <= '0';
        wait for 1 ns;
        assert ddr_addr = std_logic_vector( unsigned( addr_out ) + 448 ) report "FALLO caso 6: ddr_addr"    severity error;
        assert burst_words = std_logic_vector( to_unsigned( 4, 10 ) )    report "FALLO caso 6: burst_words" severity error;
        assert local_addr = std_logic_vector( to_unsigned( 0, 13 ) )     report "FALLO caso 6: local_addr"  severity error;

        -- CASO 7: OFM, tile ( 1, 1 ), r_local = 0, CON pooling ( MaxPool 2x2 ).
        -- tile_w_out = 2, tile_h_out = 1, img_w_out = 6. row_words_out = 2. r_global_out = 1 * 1 + 0 = 1.
        -- ddr_addr = addr_out + 1 * 96 + 1 * 2 * 16 = addr_out + 128.
        report "--- Caso 7: OFM tile (1,1), r_local=0, pool_en=1 ---";
        pool_en <= '1';
        wait for 1 ns;
        assert ddr_addr = std_logic_vector( unsigned( addr_out ) + 128 ) report "FALLO caso 7: ddr_addr"    severity error;
        assert burst_words = std_logic_vector( to_unsigned( 2, 10 ) )    report "FALLO caso 7: burst_words" severity error;
        assert local_addr = std_logic_vector( to_unsigned( 0, 13 ) )     report "FALLO caso 7: local_addr"  severity error;
        pool_en <= '0';

        -- CASO 8: Residual, misma geometria que caso 6 pero con addr_res.
        report "--- Caso 8: Residual tile (1,1), r_local=0 ---";
        transfer_type <= "11";
        wait for 1 ns;
        assert ddr_addr = std_logic_vector( unsigned( addr_res ) + 448 ) report "FALLO caso 8: ddr_addr"    severity error;
        assert burst_words = std_logic_vector( to_unsigned( 4, 10 ) )    report "FALLO caso 8: burst_words" severity error;

        -- CASO 9: Pesos ( no depende de tile ni fila ).
        report "--- Caso 9: Pesos ---";
        transfer_type <= "10";
        wait for 1 ns;
        assert ddr_addr = addr_w                                         report "FALLO caso 9: ddr_addr"    severity error;
        assert burst_words = std_logic_vector( to_unsigned( 100, 10 ) )  report "FALLO caso 9: burst_words" severity error;
        assert local_addr = std_logic_vector( to_unsigned( 0, 13 ) )     report "FALLO caso 9: local_addr"  severity error;

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
