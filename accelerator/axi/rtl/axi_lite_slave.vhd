library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_lite_slave is
    port(
        axi_clk      : in  std_logic;
        axi_reset    : in  std_logic;
        -- AW Channel - Write Address( Master -> Slave ).
        axi_aw_addr  : in  std_logic_vector( 6 downto 0 );
        axi_aw_valid : in  std_logic;
        axi_aw_ready : out std_logic;
        -- W Channel - Write Data ( Master -> Slave ).
        axi_w_data   : in  std_logic_vector( 31 downto 0 );
        axi_w_strb   : in  std_logic_vector( 3 downto 0 );
        axi_w_valid  : in  std_logic;
        axi_w_ready  : out std_logic;
        -- B Channel - Write Response ( Slave -> Master ).
        axi_b_resp   : out std_logic_vector( 1 downto 0 );
        axi_b_valid  : out std_logic;
        axi_b_ready  : in  std_logic;
        -- AR Channel - Read Address ( Master -> Slave ).
        axi_ar_addr  : in  std_logic_vector( 6 downto 0 );
        axi_ar_valid : in  std_logic;
        axi_ar_ready : out std_logic;
        -- R Channel - Read Data ( Slave -> Master ).
        axi_r_data   : out std_logic_vector( 31 downto 0 );
        axi_r_resp   : out std_logic_vector( 1 downto 0 );
        axi_r_valid  : out std_logic;
        axi_r_ready  : in  std_logic;
        
        -- In from CNN Accelerator.
        reg_done     : in  std_logic;
        -- Out to CNN Accelerator.
        reg_start        : out std_logic;
        reg_mode         : out std_logic_vector( 1 downto 0 );
        cin              : out std_logic_vector( 6 downto 0 );
        max_inner        : out std_logic_vector( 9 downto 0 );
        max_co           : out std_logic_vector( 1 downto 0 );
        max_x            : out std_logic_vector( 6 downto 0 );
        max_y            : out std_logic_vector( 2 downto 0 );
        max_tile_x       : out std_logic;
        max_tile_y       : out std_logic_vector( 4 downto 0 );
        reg_has_residual : out std_logic;
        reg_pool_en      : out std_logic;
        reg_pool_type    : out std_logic;
        shift            : out std_logic_vector( 4 downto 0 );
        relu6_val        : out std_logic_vector( 7 downto 0 );
        mult             : out std_logic_vector( 15 downto 0 );
        gap_shift        : out std_logic_vector( 4 downto 0 );
        stride_en        : out std_logic
    );
end axi_lite_slave;

architecture Behavioral of axi_lite_slave is

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
    signal r04_mode         : std_logic_vector( 1 downto 0 );
    signal r08_cin          : std_logic_vector( 6 downto 0 );
    signal r0c_max_inner    : std_logic_vector( 9 downto 0 );
    signal r10_max_co       : std_logic_vector( 1 downto 0 );
    signal r14_max_x        : std_logic_vector( 6 downto 0 );
    signal r18_max_y        : std_logic_vector( 2 downto 0 );
    signal r1c_max_tile_x   : std_logic;
    signal r20_max_tile_y   : std_logic_vector( 4 downto 0 );
    signal r24_has_residual : std_logic;
    signal r28_pool_en      : std_logic;
    signal r2c_pool_type    : std_logic;
    signal r30_shift        : std_logic_vector( 4 downto 0 );
    signal r34_relu6_val    : std_logic_vector( 7 downto 0 );
    signal r38_gap_shift    : std_logic_vector( 4 downto 0 );
    signal r3c_mult         : std_logic_vector( 15 downto 0 );  -- M0 en Q0.16, ver requantization_analysis.md.
    signal r44_stride_en    : std_logic;
    
begin

    write_en     <=  axi_aw_valid and axi_w_valid and not( sig_b_valid );
    sig_aw_ready <= write_en;
    sig_w_ready  <= write_en;

    -- Write Path.
    process( axi_clk )
    begin
        if( rising_edge( axi_clk ) ) then
            if( axi_reset = '0' ) then
                r00_start        <= '0';
                r04_mode         <= ( others => '0' );
                r08_cin          <= ( others => '0' );
                r0c_max_inner    <= ( others => '0' );
                r10_max_co       <= ( others => '0' );
                r14_max_x        <= ( others => '0' );
                r18_max_y        <= ( others => '0' );
                r1c_max_tile_x   <= '0';
                r20_max_tile_y   <= ( others => '0' );
                r24_has_residual <= '0';
                r28_pool_en      <= '0';
                r2c_pool_type    <= '0';
                r30_shift        <= ( others => '0' );
                r34_relu6_val    <= ( others => '0' );
                r38_gap_shift    <= ( others => '0' );
                r3c_mult         <= ( others => '0' );
                r44_stride_en    <= '0';
                sig_b_valid      <= '0';

            else
                if( write_en = '1' ) then
                    aw_addr_lat <= axi_aw_addr;
                    w_data_lat  <= axi_w_data;
                    w_strb_lat  <= axi_w_strb;
                    sig_b_valid <= '1';

                    case axi_aw_addr is
                        when "0000000" => 
                            r00_start        <= axi_w_data( 0 );
                        when "0000100" => 
                            r04_mode         <= axi_w_data( 1 downto 0 );
                        when "0001000" =>
                            r08_cin          <= axi_w_data( 6 downto 0 );
                        when "0001100" => 
                            r0c_max_inner    <= axi_w_data( 9 downto 0 );
                        when "0010000" =>
                            r10_max_co       <= axi_w_data( 1 downto 0 );
                        when "0010100" =>
                            r14_max_x        <= axi_w_data( 6 downto 0 );
                        when "0011000" =>
                            r18_max_y        <= axi_w_data( 2 downto 0 );
                        when "0011100" =>
                            r1c_max_tile_x   <= axi_w_data( 0 );
                        when "0100000" =>
                            r20_max_tile_y   <= axi_w_data( 4 downto 0 );
                        when "0100100" =>
                            r24_has_residual <= axi_w_data( 0 );
                        when "0101000" =>
                            r28_pool_en      <= axi_w_data( 0 );
                        when "0101100" =>
                            r2c_pool_type    <= axi_w_data( 0 );
                        when "0110000" =>
                            r30_shift        <= axi_w_data( 4 downto 0 );
                        when "0110100" =>
                            r34_relu6_val    <= axi_w_data( 7 downto 0 );
                        when "0111000" =>
                            r38_gap_shift    <= axi_w_data( 4 downto 0 );
                        when "0111100" =>
                            r3c_mult         <= axi_w_data( 15 downto 0 );
                        when "1000100" =>
                            r44_stride_en    <= axi_w_data( 0 );                     
                        when others => null;
                    end case;
                end if;

                if( r00_start = '1' ) then 
                    r00_start <= '0'; 
                end if;

                if( sig_b_valid = '1' and axi_b_ready = '1' ) then
                    sig_b_valid <= '0';
                end if;

            end if;
        end if;
    end process;    

    -- Read Path.
    process( axi_clk )
    begin
        if( rising_edge( axi_clk ) ) then
            if( axi_reset = '0' ) then
                sig_ar_ready <= '0';
                sig_r_valid  <= '0';
                sig_r_data   <= ( others => '0' );

            else
                if( axi_ar_valid = '1' and sig_ar_ready = '0' and sig_r_valid = '0' ) then
                    sig_ar_ready <= '1';
                    sig_r_valid  <= '1';

                    case axi_ar_addr is
                        when "0000000" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & r00_start;
                        when "0000100" =>
                            sig_r_data <= ( 31 downto  2 => '0' ) & r04_mode;
                        when "0001000" =>
                            sig_r_data <= ( 31 downto  7 => '0' ) & r08_cin;
                        when "0001100" =>
                            sig_r_data <= ( 31 downto 10 => '0' ) & r0c_max_inner;
                        when "0010000" =>
                            sig_r_data <= ( 31 downto  2 => '0' ) & r10_max_co;
                        when "0010100" =>
                            sig_r_data <= ( 31 downto  7 => '0' ) & r14_max_x;
                        when "0011000" =>
                            sig_r_data <= ( 31 downto  3 => '0' ) & r18_max_y;
                        when "0011100" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & r1c_max_tile_x;
                        when "0100000" =>
                            sig_r_data <= ( 31 downto  5 => '0' ) & r20_max_tile_y;
                        when "0100100" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & r24_has_residual;
                        when "0101000" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & r28_pool_en;
                        when "0101100" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & r2c_pool_type;
                        when "0110000" =>
                            sig_r_data <= ( 31 downto  5 => '0' ) & r30_shift;
                        when "0110100" =>
                            sig_r_data <= ( 31 downto  8 => '0' ) & r34_relu6_val;
                        when "0111000" =>
                            sig_r_data <= ( 31 downto  5 => '0' ) & r38_gap_shift;
                        when "0111100" =>
                            sig_r_data <= ( 31 downto 16 => '0' ) & r3c_mult;
                        when "1000000" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & reg_done;
                        when "1000100" =>
                            sig_r_data <= ( 31 downto  1 => '0' ) & r44_stride_en;
                        when others =>
                            sig_r_data <= ( others => '0' );     
                    end case;
                else
                    sig_ar_ready <= '0';
                end if;

                if( sig_r_valid = '1' and axi_r_ready = '1' ) then
                    sig_r_valid <= '0';
                end if;

            end if;
        end if;
    end process;

    -- Connect inner signals to AXI ports.
    axi_aw_ready <= sig_aw_ready;
    axi_w_ready  <= sig_w_ready;
    axi_b_resp   <= "00";          -- Always OKAY.
    axi_b_valid  <= sig_b_valid;
    axi_ar_ready <= sig_ar_ready;
    axi_r_data   <= sig_r_data;
    axi_r_resp   <= "00";          -- Always OKAY.
    axi_r_valid  <= sig_r_valid;

    -- Connect register bank to CNN Accelerator ports.
    reg_start        <= r00_start;
    reg_mode         <= r04_mode;
    cin              <= r08_cin;
    max_inner        <= r0c_max_inner;
    max_co           <= r10_max_co;
    max_x            <= r14_max_x;
    max_y            <= r18_max_y;
    max_tile_x       <= r1c_max_tile_x;
    max_tile_y       <= r20_max_tile_y;
    reg_has_residual <= r24_has_residual;
    reg_pool_en      <= r28_pool_en;
    reg_pool_type    <= r2c_pool_type;
    shift            <= r30_shift;
    relu6_val        <= r34_relu6_val;
    mult             <= r3c_mult;
    gap_shift        <= r38_gap_shift;
    stride_en        <= r44_stride_en;
    
end Behavioral;