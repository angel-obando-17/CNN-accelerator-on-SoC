library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ddr_addr_gen is
    port(
        -- Registers from reg_bank.
        img_w        : in std_logic_vector(  8 downto 0 );
        tile_w       : in std_logic_vector(  7 downto 0 );
        tile_h       : in std_logic_vector(  3 downto 0 );
        num_tile_x   : in std_logic_vector(  1 downto 0 );
        num_tile_y   : in std_logic_vector(  5 downto 0 );
        cin          : in std_logic_vector(  6 downto 0 );
        cout         : in std_logic_vector(  6 downto 0 );
        pool_en      : in std_logic;
        addr_in      : in std_logic_vector( 31 downto 0 );
        addr_out     : in std_logic_vector( 31 downto 0 );
        addr_w       : in std_logic_vector( 31 downto 0 );
        addr_res     : in std_logic_vector( 31 downto 0 );
        addr_bias    : in std_logic_vector( 31 downto 0 );
        weight_words : in std_logic_vector(  7 downto 0 );
        bias_words   : in std_logic_vector(  7 downto 0 );

        -- Actual State from DMA_FSM.
        tile_x        : in std_logic_vector(  1 downto 0 );
        tile_y        : in std_logic_vector(  5 downto 0 );
        r_local       : in std_logic_vector(  3 downto 0 );
            -- 000 = IFM, 001 = OFM, 010 = Weights, 011 = Residual, 100 = Bias.
        transfer_type : in std_logic_vector(  2 downto 0 );

        -- Outputs.
        ddr_addr    : out std_logic_vector( 31 downto 0 );
        burst_words : out std_logic_vector(  9 downto 0 );
        local_addr  : out std_logic_vector( 12 downto 0 );
        skip_ddr    : out std_logic; 

        -- Aux ports.
        left_zero_en    : out std_logic;
        left_zero_addr  : out std_logic_vector( 12 downto 0 );
        right_zero_en   : out std_logic;
        right_zero_addr : out std_logic_vector( 12 downto 0 )
    );
end ddr_addr_gen;

architecture Behavioral of ddr_addr_gen is
begin

    process(
        img_w, 
        tile_w,
        tile_h, 
        num_tile_x, 
        num_tile_y, 
        cin, 
        cout,
        pool_en,
        addr_in,
        addr_out,
        addr_w,
        addr_res,
        addr_bias,
        weight_words,
        bias_words,
        tile_x,
        tile_y, 
        r_local, 
        transfer_type
    )
        variable cin_groups  : unsigned( 15 downto 0 );
        variable cout_groups : unsigned( 15 downto 0 );

        variable v_tile_w, v_tile_h, v_img_w           : unsigned( 15 downto 0 );
        variable v_tile_x, v_tile_y                    : unsigned( 15 downto 0 );
        variable v_num_tile_x, v_num_tile_y, v_r_local : unsigned( 15 downto 0 );
        variable tile_w_out, tile_h_out, img_w_out     : unsigned( 15 downto 0 );

        variable is_top_edge, is_bottom_edge : std_logic;
        variable is_left_edge, is_right_edge : std_logic;

        -- IFM.
        variable row_words_padded : unsigned( 15 downto 0 ); -- ( tile_w + 2 ) * cin_groups.
        variable r_global         : unsigned( 15 downto 0 );
        variable col_ddr_start    : unsigned( 15 downto 0 );
        variable row_stride_in    : unsigned( 15 downto 0 ); -- img_w * cin.

        -- OFM / Residual.
        variable row_words_out  : unsigned( 15 downto 0 ); -- tile_w_out * cout_groups.
        variable r_global_out   : unsigned( 15 downto 0 );
        variable row_stride_out : unsigned( 15 downto 0 ); -- img_w_out * cout.

        -- DDR terms.
        variable term1 : unsigned( 31 downto 0 );
        variable term2 : unsigned( 31 downto 0 );

    begin
        -- Default Values.
        ddr_addr        <= ( others => '0' );
        burst_words     <= ( others => '0' );
        local_addr      <= ( others => '0' );
        skip_ddr        <= '0';
        left_zero_en    <= '0';
        left_zero_addr  <= ( others => '0' );
        right_zero_en   <= '0';
        right_zero_addr <= ( others => '0' );

        -- Resize.
        v_tile_w     := resize( unsigned( tile_w ), 16 );
        v_tile_h     := resize( unsigned( tile_h ), 16 );
        v_img_w      := resize( unsigned( img_w ), 16 );
        v_tile_x     := resize( unsigned( tile_x ), 16 );
        v_tile_y     := resize( unsigned( tile_y ), 16 );
        v_num_tile_x := resize( unsigned( num_tile_x ), 16 );
        v_num_tile_y := resize( unsigned( num_tile_y ), 16 );
        v_r_local    := resize( unsigned( r_local ), 16 );
        cin_groups   := resize( unsigned( cin( 6 downto 4 ) ), 16 );
        cout_groups  := resize( unsigned( cout( 6 downto 4 ) ), 16 );

        -- Edge conditions.
        if( v_tile_y = 0 ) then
            is_top_edge := '1';
        else
            is_top_edge := '0';
        end if;

        if( v_tile_y = v_num_tile_y - 1 ) then
            is_bottom_edge := '1';
        else
            is_bottom_edge := '0';
        end if;

        if( v_tile_x = 0 ) then
            is_left_edge := '1';
        else
            is_left_edge := '0';
        end if;

        if( v_tile_x = v_num_tile_x - 1 ) then
            is_right_edge := '1';
        else
            is_right_edge := '0';
        end if;

        -- Output Dimensions.
        if( pool_en = '1' ) then
            tile_w_out := shift_right( v_tile_w, 1 );
            tile_h_out := shift_right( v_tile_h, 1 );
            img_w_out  := shift_right( v_img_w, 1 );
        else
            tile_w_out := v_tile_w;
            tile_h_out := v_tile_h;
            img_w_out  := v_img_w;
        end if;

        case transfer_type is
            --IFB.
            when "000" =>
                row_words_padded := resize( ( v_tile_w + 2 ) * cin_groups, 16 );

                if( ( v_r_local = 0 and is_top_edge = '1' ) or
                    ( v_r_local = v_tile_h + 1 and is_bottom_edge = '1' ) ) then
                    skip_ddr    <= '1';
                    burst_words <= std_logic_vector( resize( row_words_padded, 10 ) );
                    local_addr  <= std_logic_vector( resize( v_r_local * row_words_padded, 13 ) );

                else
                    r_global := resize( v_tile_y * v_tile_h, 16 ) + v_r_local - 1;

                    if( is_left_edge = '1' and is_right_edge = '1' ) then
                        col_ddr_start   := resize( v_tile_x * v_tile_w, 16 );
                        burst_words     <= std_logic_vector( resize( row_words_padded - cin_groups * to_unsigned( 2, 16 ), 10 ) );
                        local_addr      <= std_logic_vector( resize( v_r_local * row_words_padded + cin_groups, 13 ) );
                        left_zero_en    <= '1';
                        left_zero_addr  <= std_logic_vector( resize( v_r_local * row_words_padded, 13 ) );
                        right_zero_en   <= '1';
                        right_zero_addr <= std_logic_vector( resize( v_r_local * row_words_padded + ( v_tile_w + 1 ) * cin_groups, 13 ) );

                    elsif( is_left_edge = '1' ) then
                        col_ddr_start  := resize( v_tile_x * v_tile_w, 16 );
                        burst_words    <= std_logic_vector( resize( row_words_padded - cin_groups, 10 ) );
                        local_addr     <= std_logic_vector( resize( v_r_local * row_words_padded + cin_groups, 13 ) );
                        left_zero_en   <= '1';
                        left_zero_addr <= std_logic_vector( resize( v_r_local * row_words_padded, 13 ) );

                    elsif( is_right_edge = '1' ) then
                        col_ddr_start   := resize( v_tile_x * v_tile_w, 16 ) - 1;
                        burst_words     <= std_logic_vector( resize( row_words_padded - cin_groups, 10 ) );
                        local_addr      <= std_logic_vector( resize( v_r_local * row_words_padded, 13 ) );
                        right_zero_en   <= '1';
                        right_zero_addr <= std_logic_vector( resize( v_r_local * row_words_padded + ( v_tile_w + 1 ) * cin_groups, 13 ) );

                    else
                        col_ddr_start := resize( v_tile_x * v_tile_w, 16 ) - 1;
                        burst_words   <= std_logic_vector( resize( row_words_padded, 10 ) );
                        local_addr    <= std_logic_vector( resize( v_r_local * row_words_padded, 13 ) );
                    end if;

                    row_stride_in := resize( v_img_w * unsigned( cin ), 16 );
                    term1 := resize( r_global * row_stride_in, 32 );
                    term2 := resize( col_ddr_start * unsigned( cin ), 32 );
                    ddr_addr <= std_logic_vector( unsigned( addr_in ) + term1 + term2 );
                end if;

            -- OFM / Residual.
            when "001" | "011" =>
                row_words_out  := resize( tile_w_out * cout_groups, 16 );
                r_global_out   := resize( v_tile_y * tile_h_out, 16 ) + v_r_local;
                row_stride_out := resize( img_w_out * unsigned( cout ), 16 );
                term1 := resize( r_global_out * row_stride_out, 32 );
                term2 := resize( resize( v_tile_x * tile_w_out, 16 ) * unsigned( cout ), 32 );

                if( transfer_type = "001" ) then
                    ddr_addr <= std_logic_vector( unsigned( addr_out ) + term1 + term2 );
                else
                    ddr_addr <= std_logic_vector( unsigned( addr_res ) + term1 + term2 );
                end if;

                burst_words <= std_logic_vector( resize( row_words_out, 10 ) );
                local_addr  <= std_logic_vector( resize( v_r_local * row_words_out, 13 ) );

            -- Bias.
            when "100" =>
                ddr_addr    <= addr_bias;
                burst_words <= "00" & bias_words;
                local_addr  <= ( others => '0' );

            -- Weights.
            when others =>
                ddr_addr    <= addr_w;
                burst_words <= "00" & weight_words;
                local_addr  <= ( others => '0' );

        end case;

    end process;
                    
end Behavioral;
