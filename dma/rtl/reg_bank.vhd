library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reg_bank is
    port(
        dma_clk      : in  std_logic;
        dma_reset    : in  std_logic;
        -- AW Channel - Write Address( Master -> Slave ).
        dma_aw_addr  : in  std_logic_vector(  6 downto 0 );
        dma_aw_valid : in  std_logic;
        dma_aw_ready : out std_logic;
        -- W Channel - Write Data ( Master -> Slave ).
        dma_w_data   : in  std_logic_vector( 31 downto 0 );
        dma_w_strb   : in  std_logic_vector(  3 downto 0 );
        dma_w_valid  : in  std_logic;
        dma_w_ready  : out std_logic;
        -- B Channel - Write Response ( Slave -> Master ).
        dma_b_resp   : out std_logic_vector(  1 downto 0 );
        dma_b_valid  : out std_logic;
        dma_b_ready  : in  std_logic;
        -- AR Channel - Read Address ( Master -> Slave ).
        dma_ar_addr  : in  std_logic_vector(  6 downto 0 );
        dma_ar_valid : in  std_logic;
        dma_ar_ready : out std_logic;
        -- R Channel - Read Data ( Slave -> Master ).
        dma_r_data   : out std_logic_vector( 31 downto 0 );
        dma_r_resp   : out std_logic_vector(  1 downto 0 );
        dma_r_valid  : out std_logic;
        dma_r_ready  : in  std_logic;
        
        -- In from Main FSM.
        dma_done     : in  std_logic;

        dma_start         : out std_logic;
        dma_mode          : out std_logic_vector(  1 downto 0 );
        dma_cin           : out std_logic_vector(  6 downto 0 );
        dma_cout          : out std_logic_vector(  6 downto 0 );
        dma_img_w         : out std_logic_vector(  8 downto 0 );
        dma_img_h         : out std_logic_vector(  8 downto 0 );
        dma_tile_w        : out std_logic_vector(  7 downto 0 );
        dma_tile_h        : out std_logic_vector(  3 downto 0 );
        dma_num_tile_x    : out std_logic_vector(  1 downto 0 );
        dma_num_tile_y    : out std_logic_vector(  5 downto 0 );
        dma_has_residual  : out std_logic;
        dma_weight_words  : out std_logic_vector(  7 downto 0 );
        dma_addr_w        : out std_logic_vector( 31 downto 0 );
        dma_addr_in       : out std_logic_vector( 31 downto 0 );
        dma_addr_out      : out std_logic_vector( 31 downto 0 );
        dma_addr_res      : out std_logic_vector( 31 downto 0 );
        dma_pool_en       : out std_logic;
        dma_pool_type     : out std_logic
    );
end reg_bank;

architecture Behavioral of reg_bank is

    -- Write path.
    signal aw_addr_lat : std_logic_vector(  6 downto 0 ); -- Latched Address
    signal w_data_lat  : std_logic_vector( 31 downto 0 ); -- Latched Data.
    signal w_strb_lat  : std_logic_vector(  3 downto 0 ); -- Byte enables Latched.
    signal write_en    : std_logic;                       -- Pulse: Write Register.

    -- Handshake outputs ( Inner signals before assign to the ports ).
    signal sig_aw_ready : std_logic;
    signal sig_w_ready  : std_logic;
    signal sig_b_valid  : std_logic;
    signal sig_ar_ready : std_logic;
    signal sig_r_valid  : std_logic;
    signal sig_r_data   : std_logic_vector( 31 downto 0 );

    -- Registers Bank ( One per offset ).
    signal r00_start        : std_logic;
    signal r04_mode         : std_logic_vector(  1 downto 0 );
    signal r08_cin          : std_logic_vector(  6 downto 0 );
    signal r0c_cout         : std_logic_vector(  6 downto 0 );
    signal r10_img_w        : std_logic_vector(  8 downto 0 );
    signal r14_img_h        : std_logic_vector(  8 downto 0 );
    signal r18_tile_w       : std_logic_vector(  7 downto 0 );
    signal r1c_tile_h       : std_logic_vector(  3 downto 0 );
    signal r20_num_tile_x   : std_logic_vector(  1 downto 0 );
    signal r24_num_tile_y   : std_logic_vector(  5 downto 0 );
    signal r28_has_residual : std_logic;
    signal r2c_weight_words : std_logic_vector(  7 downto 0 );
    signal r30_addr_w       : std_logic_vector( 31 downto 0 );
    signal r34_addr_in      : std_logic_vector( 31 downto 0 );
    signal r38_addr_out     : std_logic_vector( 31 downto 0 );
    signal r3c_addr_res     : std_logic_vector( 31 downto 0 );
    signal r44_pool_en      : std_logic;
    signal r48_pool_type    : std_logic;

begin

    write_en     <= dma_aw_valid and dma_w_valid and not( sig_b_valid );
    sig_aw_ready <= write_en;
    sig_w_ready  <= write_en;

    -- Write Path.
    process( dma_clk )
    begin
        if( rising_edge( dma_clk ) ) then
            if( dma_reset = '0' ) then
                r00_start        <= '0';
                r04_mode         <= ( others => '0' );
                r08_cin          <= ( others => '0' );
                r0c_cout         <= ( others => '0' );
                r10_img_w        <= ( others => '0' );
                r14_img_h        <= ( others => '0' );
                r18_tile_w       <= ( others => '0' );
                r1c_tile_h       <= ( others => '0' );
                r20_num_tile_x   <= ( others => '0' );
                r24_num_tile_y   <= ( others => '0' );
                r28_has_residual <= '0';
                r2c_weight_words <= ( others => '0' );
                r30_addr_w       <= ( others => '0' );
                r34_addr_in      <= ( others => '0' );
                r38_addr_out     <= ( others => '0' );
                r3c_addr_res     <= ( others => '0' );
                r44_pool_en      <= '0';
                r48_pool_type    <= '0';
                sig_b_valid      <= '0';

            else
                if( write_en = '1' ) then
                    aw_addr_lat <= dma_aw_addr;
                    w_data_lat  <= dma_w_data;
                    w_strb_lat  <= dma_w_strb;
                    sig_b_valid <= '1';

                    case dma_aw_addr is
                        when "0000000" => 
                            r00_start        <= dma_w_data( 0 );
                        when "0000100" => 
                            r04_mode         <= dma_w_data( 1 downto 0 );
                        when "0001000" =>
                            r08_cin          <= dma_w_data( 6 downto 0 );
                        when "0001100" => 
                            r0c_cout         <= dma_w_data( 6 downto 0 );
                        when "0010000" =>
                            r10_img_w        <= dma_w_data( 8 downto 0 );
                        when "0010100" =>
                            r14_img_h        <= dma_w_data( 8 downto 0 );
                        when "0011000" =>
                            r18_tile_w       <= dma_w_data( 7 downto 0 );
                        when "0011100" =>
                            r1c_tile_h       <= dma_w_data( 3 downto 0 );
                        when "0100000" =>
                            r20_num_tile_x   <= dma_w_data( 1 downto 0 );
                        when "0100100" =>
                            r24_num_tile_y   <= dma_w_data( 5 downto 0 );
                        when "0101000" =>
                            r28_has_residual <= dma_w_data( 0 );
                        when "0101100" =>
                            r2c_weight_words <= dma_w_data( 7 downto 0 );
                        when "0110000" =>
                            r30_addr_w       <= dma_w_data;
                        when "0110100" =>
                            r34_addr_in      <= dma_w_data;
                        when "0111000" =>
                            r38_addr_out     <= dma_w_data;
                        when "0111100" =>
                            r3c_addr_res     <= dma_w_data;
                        when "1000100" =>
                            r44_pool_en      <= dma_w_data( 0 );
                        when "1001000" =>
                            r48_pool_type    <= dma_w_data( 0 );
                        when others => null;
                    end case;
                end if;

                if( r00_start = '1' ) then 
                    r00_start <= '0'; 
                end if;

                if( sig_b_valid = '1' and dma_b_ready = '1' ) then
                    sig_b_valid <= '0';
                end if;

            end if;
        end if;
    end process;

-- Read Path.
    process( dma_clk )
    begin
        if( rising_edge( dma_clk ) ) then
            if( dma_reset = '0' ) then
                sig_ar_ready <= '0';
                sig_r_valid  <= '0';
                sig_r_data   <= ( others => '0' );

            else
                if( dma_ar_valid = '1' and sig_ar_ready = '0' and sig_r_valid = '0' ) then
                    sig_ar_ready <= '1';
                    sig_r_valid  <= '1';

                    case dma_ar_addr is
                        when "0000000" =>
                            sig_r_data <= ( 31 downto 1 => '0' ) & r00_start;
                        when "0000100" =>
                            sig_r_data <= ( 31 downto 2 => '0' ) & r04_mode;
                        when "0001000" =>
                            sig_r_data <= ( 31 downto 7 => '0' ) & r08_cin;
                        when "0001100" =>
                            sig_r_data <= ( 31 downto 7 => '0' ) & r0c_cout;
                        when "0010000" =>
                            sig_r_data <= ( 31 downto 9 => '0' ) & r10_img_w;
                        when "0010100" =>
                            sig_r_data <= ( 31 downto 9 => '0' ) & r14_img_h;
                        when "0011000" =>
                            sig_r_data <= ( 31 downto 8 => '0' ) & r18_tile_w;
                        when "0011100" =>
                            sig_r_data <= ( 31 downto 4 => '0' ) & r1c_tile_h;
                        when "0100000" =>
                            sig_r_data <= ( 31 downto 2 => '0' ) & r20_num_tile_x;
                        when "0100100" =>
                            sig_r_data <= ( 31 downto 6 => '0' ) & r24_num_tile_y;
                        when "0101000" =>
                            sig_r_data <= ( 31 downto 1 => '0' ) & r28_has_residual;
                        when "0101100" =>
                            sig_r_data <= ( 31 downto 8 => '0' ) & r2c_weight_words;
                        when "0110000" =>
                            sig_r_data <= r30_addr_w;
                        when "0110100" =>
                            sig_r_data <= r34_addr_in;
                        when "0111000" =>
                            sig_r_data <= r38_addr_out;      
                        when "0111100" =>
                            sig_r_data <= r3c_addr_res;
                        when "1000000" =>
                            sig_r_data <= ( 31 downto 1 => '0' ) & dma_done;
                        when "1000100" =>
                            sig_r_data <= ( 31 downto 1 => '0' ) & r44_pool_en;
                        when "1001000" =>
                            sig_r_data <= ( 31 downto 1 => '0' ) & r48_pool_type;
                        when others =>
                            sig_r_data <= ( others => '0' );     
                    end case;
                else
                    sig_ar_ready <= '0';
                end if;

                if( sig_r_valid = '1' and dma_r_ready = '1' ) then
                    sig_r_valid <= '0';
                end if;

            end if;
        end if;
    end process;

    -- Connect inner signals to AXI ports.
    dma_aw_ready <= sig_aw_ready;
    dma_w_ready  <= sig_w_ready;
    dma_b_resp   <= "00";          -- Always OKAY.
    dma_b_valid  <= sig_b_valid;
    dma_ar_ready <= sig_ar_ready;
    dma_r_data   <= sig_r_data;
    dma_r_resp   <= "00";          -- Always OKAY.
    dma_r_valid  <= sig_r_valid;

    -- Connect register bank to DMA ports.
    dma_start        <= r00_start;
    dma_mode         <= r04_mode;
    dma_cin          <= r08_cin;
    dma_cout         <= r0c_cout;
    dma_img_w        <= r10_img_w;
    dma_img_h        <= r14_img_h;
    dma_tile_w       <= r18_tile_w;
    dma_tile_h       <= r1c_tile_h;
    dma_num_tile_x   <= r20_num_tile_x;
    dma_num_tile_y   <= r24_num_tile_y;
    dma_has_residual <= r28_has_residual;
    dma_weight_words <= r2c_weight_words;
    dma_addr_w       <= r30_addr_w;
    dma_addr_in      <= r34_addr_in;
    dma_addr_out     <= r38_addr_out;
    dma_addr_res     <= r3c_addr_res;
    dma_pool_en      <= r44_pool_en;
    dma_pool_type    <= r48_pool_type;

end Behavioral;