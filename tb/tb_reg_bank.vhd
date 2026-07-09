library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Testbench: reg_bank ( banco de registros AXI-Lite del DMA )
--
-- Escribe cada registro via AXI-Lite, lee cada uno de vuelta y verifica que
-- coincida ( tanto por el canal R como por las salidas directas del banco ).
-- Tambien verifica el auto-clear de DMA_START y que DMA_DONE sea de solo
-- lectura, reflejando la entrada externa dma_done.

entity tb_reg_bank is
end tb_reg_bank;

architecture Behavioral of tb_reg_bank is

    constant CLK_PERIOD : time := 10 ns;

    signal dma_clk   : std_logic := '0';
    signal dma_reset : std_logic := '0'; -- activo.

    signal dma_aw_addr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal dma_aw_valid : std_logic := '0';
    signal dma_aw_ready : std_logic;
    signal dma_w_data   : std_logic_vector( 31 downto 0 ) := ( others => '0' );
    signal dma_w_strb   : std_logic_vector(  3 downto 0 ) := ( others => '1' );
    signal dma_w_valid  : std_logic := '0';
    signal dma_w_ready  : std_logic;
    signal dma_b_resp   : std_logic_vector(  1 downto 0 );
    signal dma_b_valid  : std_logic;
    signal dma_b_ready  : std_logic := '0';
    signal dma_ar_addr  : std_logic_vector(  6 downto 0 ) := ( others => '0' );
    signal dma_ar_valid : std_logic := '0';
    signal dma_ar_ready : std_logic;
    signal dma_r_data   : std_logic_vector( 31 downto 0 );
    signal dma_r_resp   : std_logic_vector(  1 downto 0 );
    signal dma_r_valid  : std_logic;
    signal dma_r_ready  : std_logic := '0';

    signal dma_done : std_logic := '0';

    signal dma_start          : std_logic;
    signal dma_mode           : std_logic_vector(  1 downto 0 );
    signal dma_cin            : std_logic_vector(  6 downto 0 );
    signal dma_cout           : std_logic_vector(  6 downto 0 );
    signal dma_img_w          : std_logic_vector(  8 downto 0 );
    signal dma_img_h          : std_logic_vector(  8 downto 0 );
    signal dma_tile_w         : std_logic_vector(  7 downto 0 );
    signal dma_tile_h         : std_logic_vector(  3 downto 0 );
    signal dma_num_tile_x     : std_logic_vector(  1 downto 0 );
    signal dma_num_tile_y     : std_logic_vector(  5 downto 0 );
    signal dma_has_residual   : std_logic;
    signal dma_weight_words   : std_logic_vector(  7 downto 0 );
    signal dma_addr_w         : std_logic_vector( 31 downto 0 );
    signal dma_addr_in        : std_logic_vector( 31 downto 0 );
    signal dma_addr_out       : std_logic_vector( 31 downto 0 );
    signal dma_addr_res       : std_logic_vector( 31 downto 0 );
    signal dma_pool_en        : std_logic;
    signal dma_pool_type      : std_logic;

begin

    dma_clk <= not dma_clk after CLK_PERIOD / 2;

    dut : entity work.reg_bank
        port map(
            dma_clk          => dma_clk,
            dma_reset        => dma_reset,
            dma_aw_addr      => dma_aw_addr,
            dma_aw_valid     => dma_aw_valid,
            dma_aw_ready     => dma_aw_ready,
            dma_w_data       => dma_w_data,
            dma_w_strb       => dma_w_strb,
            dma_w_valid      => dma_w_valid,
            dma_w_ready      => dma_w_ready,
            dma_b_resp       => dma_b_resp,
            dma_b_valid      => dma_b_valid,
            dma_b_ready      => dma_b_ready,
            dma_ar_addr      => dma_ar_addr,
            dma_ar_valid     => dma_ar_valid,
            dma_ar_ready     => dma_ar_ready,
            dma_r_data       => dma_r_data,
            dma_r_resp       => dma_r_resp,
            dma_r_valid      => dma_r_valid,
            dma_r_ready      => dma_r_ready,
            dma_done         => dma_done,
            dma_start        => dma_start,
            dma_mode         => dma_mode,
            dma_cin          => dma_cin,
            dma_cout         => dma_cout,
            dma_img_w        => dma_img_w,
            dma_img_h        => dma_img_h,
            dma_tile_w       => dma_tile_w,
            dma_tile_h       => dma_tile_h,
            dma_num_tile_x   => dma_num_tile_x,
            dma_num_tile_y   => dma_num_tile_y,
            dma_has_residual => dma_has_residual,
            dma_weight_words => dma_weight_words,
            dma_addr_w       => dma_addr_w,
            dma_addr_in      => dma_addr_in,
            dma_addr_out     => dma_addr_out,
            dma_addr_res     => dma_addr_res,
            dma_pool_en      => dma_pool_en,
            dma_pool_type    => dma_pool_type
        );

    process
    begin

        -- Reset: activo en bajo, 4 ciclos.
        dma_reset <= '0';
        wait until rising_edge( dma_clk );
        wait until rising_edge( dma_clk );
        wait until rising_edge( dma_clk );
        wait until rising_edge( dma_clk );
        dma_reset <= '1';
        wait until rising_edge( dma_clk );
        wait until rising_edge( dma_clk );

        report "=== INICIO TEST: reg_bank, escritura/lectura de todos los registros ===";

        -- DMA_MODE ( 0x04 ) = "10".
        dma_aw_addr <= "0000100"; dma_w_data <= x"00000002";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_CIN ( 0x08 ) = 64.
        dma_aw_addr <= "0001000"; dma_w_data <= x"00000040";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_COUT ( 0x0C ) = 63.
        dma_aw_addr <= "0001100"; dma_w_data <= x"0000003F";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_IMG_W ( 0x10 ) = 256.
        dma_aw_addr <= "0010000"; dma_w_data <= x"00000100";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_IMG_H ( 0x14 ) = 255.
        dma_aw_addr <= "0010100"; dma_w_data <= x"000000FF";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_TILE_W ( 0x18 ) = 128.
        dma_aw_addr <= "0011000"; dma_w_data <= x"00000080";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_TILE_H ( 0x1C ) = 8.
        dma_aw_addr <= "0011100"; dma_w_data <= x"00000008";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_NUM_TILE_X ( 0x20 ) = 2.
        dma_aw_addr <= "0100000"; dma_w_data <= x"00000002";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_NUM_TILE_Y ( 0x24 ) = 32.
        dma_aw_addr <= "0100100"; dma_w_data <= x"00000020";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_HAS_RESIDUAL ( 0x28 ) = 1.
        dma_aw_addr <= "0101000"; dma_w_data <= x"00000001";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_WEIGHT_WORDS ( 0x2C ) = 255.
        dma_aw_addr <= "0101100"; dma_w_data <= x"000000FF";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_ADDR_W ( 0x30 ) = 0x10000000.
        dma_aw_addr <= "0110000"; dma_w_data <= x"10000000";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_ADDR_IN ( 0x34 ) = 0x20000000.
        dma_aw_addr <= "0110100"; dma_w_data <= x"20000000";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_ADDR_OUT ( 0x38 ) = 0x30000000.
        dma_aw_addr <= "0111000"; dma_w_data <= x"30000000";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_ADDR_RES ( 0x3C ) = 0x40000000.
        dma_aw_addr <= "0111100"; dma_w_data <= x"40000000";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_POOL_EN ( 0x44 ) = 1.
        dma_aw_addr <= "1000100"; dma_w_data <= x"00000001";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- DMA_POOL_TYPE ( 0x48 ) = 1.
        dma_aw_addr <= "1001000"; dma_w_data <= x"00000001";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';
        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        wait until rising_edge( dma_clk );

        report "--- Verificando salidas directas del banco ---";
        assert dma_mode          = "10"                  report "FALLO dma_mode"          severity error;
        assert dma_cin           = "1000000"             report "FALLO dma_cin"           severity error;
        assert dma_cout          = "0111111"             report "FALLO dma_cout"          severity error;
        assert dma_img_w         = "100000000"           report "FALLO dma_img_w"         severity error;
        assert dma_img_h         = "011111111"           report "FALLO dma_img_h"         severity error;
        assert dma_tile_w        = "10000000"            report "FALLO dma_tile_w"        severity error;
        assert dma_tile_h        = "1000"                report "FALLO dma_tile_h"        severity error;
        assert dma_num_tile_x    = "10"                  report "FALLO dma_num_tile_x"    severity error;
        assert dma_num_tile_y    = "100000"              report "FALLO dma_num_tile_y"    severity error;
        assert dma_has_residual  = '1'                   report "FALLO dma_has_residual"  severity error;
        assert dma_weight_words  = "11111111"            report "FALLO dma_weight_words"  severity error;
        assert dma_addr_w        = x"10000000"           report "FALLO dma_addr_w"        severity error;
        assert dma_addr_in       = x"20000000"           report "FALLO dma_addr_in"       severity error;
        assert dma_addr_out      = x"30000000"           report "FALLO dma_addr_out"      severity error;
        assert dma_addr_res      = x"40000000"           report "FALLO dma_addr_res"      severity error;
        assert dma_pool_en       = '1'                   report "FALLO dma_pool_en"       severity error;
        assert dma_pool_type     = '1'                   report "FALLO dma_pool_type"     severity error;
        report "--- Salidas directas OK ---";

        report "--- Verificando lectura via AXI-Lite ---";

        -- Leer DMA_CIN ( 0x08 ), esperar 64.
        dma_ar_addr <= "0001000"; dma_ar_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_ar_valid <= '0';
        wait until dma_r_valid = '1';
        wait for 1 ns;
        report "R DMA_CIN = " & integer'image( to_integer( unsigned( dma_r_data ) ) );
        assert dma_r_data = x"00000040" report "FALLO lectura DMA_CIN" severity error;
        dma_r_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_r_ready <= '0';

        -- Leer DMA_ADDR_OUT ( 0x38 ), esperar 0x30000000.
        dma_ar_addr <= "0111000"; dma_ar_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_ar_valid <= '0';
        wait until dma_r_valid = '1';
        wait for 1 ns;
        report "R DMA_ADDR_OUT = " & integer'image( to_integer( unsigned( dma_r_data ) ) );
        assert dma_r_data = x"30000000" report "FALLO lectura DMA_ADDR_OUT" severity error;
        dma_r_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_r_ready <= '0';

        -- Leer DMA_POOL_TYPE ( 0x48 ), esperar 1.
        dma_ar_addr <= "1001000"; dma_ar_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_ar_valid <= '0';
        wait until dma_r_valid = '1';
        wait for 1 ns;
        report "R DMA_POOL_TYPE = " & integer'image( to_integer( unsigned( dma_r_data ) ) );
        assert dma_r_data = x"00000001" report "FALLO lectura DMA_POOL_TYPE" severity error;
        dma_r_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_r_ready <= '0';

        report "--- Lectura AXI-Lite OK ---";

        report "--- Verificando auto-clear de DMA_START ---";

        -- Escribir DMA_START ( 0x00 ) = 1.
        dma_aw_addr <= "0000000"; dma_w_data <= x"00000001";
        dma_aw_valid <= '1'; dma_w_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_aw_valid <= '0'; dma_w_valid <= '0';

        -- dma_start debe pulsar '1' este mismo ciclo ( justo tras la escritura ).
        -- Hay que verificarlo ANTES de consumir el handshake del canal B: ese
        -- handshake tarda exactamente 1 ciclo en cerrarse, que es el mismo ciclo
        -- en el que dma_start ya se autolimpio ( pulso de 1 ciclo de ancho ).
        wait for 1 ns;
        assert dma_start = '1' report "FALLO: dma_start no pulso tras escribir DMA_START" severity error;

        wait until dma_b_valid = '1';
        dma_b_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_b_ready <= '0';

        -- Un ciclo despues de la escritura, dma_start ya se debio autolimpiar.
        wait for 1 ns;
        assert dma_start = '0' report "FALLO: dma_start no se auto-limpio" severity error;

        -- Confirmar por AXI-Lite tambien: leer DMA_START debe dar 0 ya.
        dma_ar_addr <= "0000000"; dma_ar_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_ar_valid <= '0';
        wait until dma_r_valid = '1';
        wait for 1 ns;
        report "R DMA_START ( post auto-clear ) = " & integer'image( to_integer( unsigned( dma_r_data ) ) );
        assert dma_r_data = x"00000000" report "FALLO: lectura DMA_START deberia ser 0 tras auto-clear" severity error;
        dma_r_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_r_ready <= '0';

        report "--- Auto-clear DMA_START OK ---";

        report "--- Verificando DMA_DONE ( solo lectura, refleja entrada externa ) ---";

        dma_done <= '1';
        wait for 1 ns;

        dma_ar_addr <= "1000000"; dma_ar_valid <= '1';
        wait until rising_edge( dma_clk );
        dma_ar_valid <= '0';
        wait until dma_r_valid = '1';
        wait for 1 ns;
        report "R DMA_DONE = " & integer'image( to_integer( unsigned( dma_r_data ) ) );
        assert dma_r_data = x"00000001" report "FALLO lectura DMA_DONE" severity error;
        dma_r_ready <= '1';
        wait until rising_edge( dma_clk );
        dma_r_ready <= '0';

        dma_done <= '0';

        report "--- DMA_DONE OK ---";

        report "=== TEST FINALIZADO ===" severity note;
        wait;
    end process;

end Behavioral;
