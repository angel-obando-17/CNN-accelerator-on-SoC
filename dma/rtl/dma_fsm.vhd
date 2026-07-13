library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dma_fsm is
    port(
        clk   : in std_logic;
        reset : in std_logic;

        -- Register from reg_bank.  
        dma_start    : in  std_logic;
        cin          : in  std_logic_vector(  6 downto 0 );
        cout         : in  std_logic_vector(  6 downto 0 );
        tile_h       : in  std_logic_vector(  3 downto 0 );
        num_tile_x   : in  std_logic_vector(  1 downto 0 );
        num_tile_y   : in  std_logic_vector(  5 downto 0 );
        has_residual : in  std_logic;
        pool_en      : in  std_logic;
        pool_type    : in  std_logic;
        addr_out     : in  std_logic_vector( 31 downto 0 );
        dma_done     : out std_logic;

        -- To ddr_addr_gen.
        transfer_type : out std_logic_vector(  1 downto 0 );
        gen_tile_x    : out std_logic_vector(  1 downto 0 );
        gen_tile_y    : out std_logic_vector(  5 downto 0 );
        gen_r_local   : out std_logic_vector(  3 downto 0 );

        -- From ddr_addr_gen.
        skip_ddr        : in std_logic;
        left_zero_en    : in std_logic;
        right_zero_en   : in std_logic;
        gen_burst_words : in std_logic_vector(  9 downto 0 );
        gen_local_addr  : in std_logic_vector( 12 downto 0 );
        gen_left_addr   : in std_logic_vector( 12 downto 0 );
        gen_right_addr  : in std_logic_vector( 12 downto 0 );

        -- To / From axi4_read_master.
        rd_start : out std_logic;
        rd_done  : in  std_logic;

        -- To / From axi4_write_master.
        wr_start         : out std_logic;
        wr_done          : in  std_logic;
        gap_flush_active : out std_logic;
        gap_ddr_addr     : out std_logic_vector( 31 downto 0 );
        gap_burst_words  : out std_logic_vector(  9 downto 0 );

        -- Fill zeros.
        zero_fill_active : out std_logic;
        zero_wr_en       : out std_logic;
        zero_wr_addr     : out std_logic_vector( 12 downto 0 );

        -- Destination / Origin Selector.
        target_sel : out std_logic_vector(  1 downto 0 );

        -- To accelerator.
        buf_sel     : out std_logic;
        accel_start : out std_logic;
        tile_ready  : out std_logic;
        tile_req    : in  std_logic;
        irq_out     : in  std_logic
    );
end dma_fsm;

architecture Behavioral of dma_fsm is
    type state_type is ( IDLE, 
                         LOAD_WEIGHTS, 
                         IFM_MAIN, 
                         IFM_READ, 
                         IFM_LEFT, 
                         IFM_RIGHT, 
                         ZERO_FILL, 
                         IFM_NEXT,
                         RES_READ, 
                         RES_NEXT, 
                         START_TILE,
                         START_TILE_HOLD,
                         WAIT_ACCEL,
                         CHECK_OFM, 
                         OFM_WRITE, 
                         OFM_NEXT, 
                         GAP_FLUSH,
                         NEXT_TILE, 
                         DONE_LAYER );

    -- Aux signals.
    signal current_state, next_state : state_type;
    signal zf_return_state           : state_type; -- Where backs when 'Fill Zeros' ends.

    -- Tile / Row Index.
    signal reg_tile_x  : unsigned(  1 downto 0 ) := ( others => '0' );
    signal reg_tile_y  : unsigned(  5 downto 0 ) := ( others => '0' );
    signal reg_r_local : unsigned(  3 downto 0 ) := ( others => '0' );

    -- Control Flags.
    signal reg_is_last_tile : std_logic := '0';
    signal reg_first_tile   : std_logic := '1';

    -- Fill Zeros counter.
    signal reg_zf_addr       : unsigned( 12 downto 0 ) := ( others => '0' );
    signal reg_zf_words_left : unsigned(  9 downto 0 ) := ( others => '0' );

begin

    process( clk, reset )
    begin
        if( reset = '0' ) then
            current_state     <= IDLE;
            reg_tile_x        <= ( others => '0' );
            reg_tile_y        <= ( others => '0' );
            reg_r_local       <= ( others => '0' );
            reg_is_last_tile  <= '0';
            reg_first_tile    <= '1';
            reg_zf_addr       <= ( others => '0' );
            reg_zf_words_left <= ( others => '0' );

        elsif( rising_edge( clk ) ) then
            current_state <= next_state;

            case current_state is
                when IDLE =>
                    if( dma_start = '1' ) then
                        reg_tile_x     <= ( others => '0' );
                        reg_tile_y     <= ( others => '0' );
                        reg_r_local    <= ( others => '0' );
                        reg_first_tile <= '1';
                    end if;

                when IFM_MAIN =>
                    if( skip_ddr = '1' ) then
                        reg_zf_addr       <= unsigned( gen_local_addr );
                        reg_zf_words_left <= unsigned( gen_burst_words );
                        zf_return_state   <= IFM_NEXT;
                    end if;

                when IFM_LEFT =>
                    if( left_zero_en = '1' ) then
                        reg_zf_addr       <= unsigned( gen_left_addr );
                        reg_zf_words_left <= resize( unsigned( cin( 6 downto 4 ) ), 10 );
                        zf_return_state   <= IFM_RIGHT;
                    end if;

                when IFM_RIGHT =>
                    if( right_zero_en = '1' ) then
                        reg_zf_addr       <= unsigned( gen_right_addr );
                        reg_zf_words_left <= resize( unsigned( cin( 6 downto 4 ) ), 10 );
                        zf_return_state   <= IFM_NEXT;
                    end if;

                when ZERO_FILL =>
                    if( reg_zf_words_left /= 0 ) then
                        reg_zf_addr       <= reg_zf_addr + 1;
                        reg_zf_words_left <= reg_zf_words_left - 1;
                    end if;

                when IFM_NEXT =>
                    if( reg_r_local < unsigned( tile_h ) + 1 ) then
                        reg_r_local <= reg_r_local + 1;
                    else
                        reg_r_local <= ( others => '0' );
                    end if;

                when RES_NEXT =>
                    if( pool_en = '1' ) then
                        if( reg_r_local < resize( shift_right( unsigned( tile_h ), 1 ), 4 ) - 1 ) then
                            reg_r_local <= reg_r_local + 1;
                        else
                            reg_r_local <= ( others => '0' );
                        end if;
                    else
                        if( reg_r_local < unsigned( tile_h ) - 1 ) then
                            reg_r_local <= reg_r_local + 1;
                        else
                            reg_r_local <= ( others => '0' );
                        end if;
                    end if;

                when WAIT_ACCEL =>
                    if( tile_req = '1' ) then
                        reg_is_last_tile <= '0';
                        reg_r_local      <= ( others => '0' );
                    elsif( irq_out = '1' ) then
                        reg_is_last_tile <= '1';
                        reg_r_local      <= ( others => '0' );
                    end if;

                when OFM_NEXT =>
                    if( pool_en = '1' ) then
                        if( reg_r_local < resize( shift_right( unsigned( tile_h ), 1 ), 4 ) - 1 ) then
                            reg_r_local <= reg_r_local + 1;
                        else
                            reg_r_local <= ( others => '0' );
                        end if;
                    else
                        if( reg_r_local < unsigned( tile_h ) - 1 ) then
                            reg_r_local <= reg_r_local + 1;
                        else
                            reg_r_local <= ( others => '0' );
                        end if;
                    end if;

                when START_TILE =>
                    reg_first_tile <= '0';

                when NEXT_TILE =>
                    if( reg_tile_x < unsigned( num_tile_x ) - 1 ) then
                        reg_tile_x <= reg_tile_x + 1;
                    else
                        reg_tile_x <= ( others => '0' );
                        reg_tile_y <= reg_tile_y + 1;
                    end if;
                    reg_r_local <= ( others => '0' );

                when others =>
                    null;

            end case;
        end if;
    end process;

    process(
        current_state, 
        dma_start, 
        rd_done, 
        wr_done, 
        tile_req, 
        irq_out,
        skip_ddr, 
        left_zero_en, 
        right_zero_en, 
        reg_zf_words_left, 
        reg_zf_addr,
        reg_tile_x, 
        reg_tile_y, 
        reg_r_local, 
        reg_is_last_tile, 
        reg_first_tile,
        tile_h, 
        num_tile_x, 
        pool_en, 
        pool_type, 
        has_residual,
        zf_return_state, 
        cout, 
        addr_out
    )
    begin
        -- Default Values..
        dma_done         <= '0';
        transfer_type    <= "00";
        rd_start         <= '0';
        wr_start         <= '0';
        gap_flush_active <= '0';
        gap_ddr_addr     <= ( others => '0' );
        gap_burst_words  <= ( others => '0' );
        zero_fill_active <= '0';
        zero_wr_en       <= '0';
        zero_wr_addr     <= std_logic_vector( reg_zf_addr );
        target_sel       <= "00";
        buf_sel          <= '0';
        accel_start      <= '0';
        tile_ready       <= '0';
        next_state       <= current_state;

        gen_tile_x  <= std_logic_vector( reg_tile_x );
        gen_tile_y  <= std_logic_vector( reg_tile_y );
        gen_r_local <= std_logic_vector( reg_r_local );

        case current_state is
            when IDLE =>
                if( dma_start = '1' ) then
                    next_state <= LOAD_WEIGHTS;
                else
                    next_state <= IDLE;
                end if;

            when LOAD_WEIGHTS =>
                transfer_type <= "10";
                target_sel    <= "01"; -- WeightBuffer.
                if( rd_done = '1' ) then
                    next_state <= IFM_MAIN;
                else
                    rd_start   <= '1';
                    next_state <= LOAD_WEIGHTS;
                end if;

            when IFM_MAIN =>
                transfer_type <= "00";
                target_sel    <= "00"; -- IFBuffer.
                buf_sel       <= '1';
                if( skip_ddr = '1' ) then
                    next_state <= ZERO_FILL;
                else
                    next_state <= IFM_READ;
                end if;

            when IFM_READ =>
                transfer_type <= "00";
                target_sel    <= "00";
                buf_sel       <= '1';
                if( rd_done = '1' ) then
                    next_state <= IFM_LEFT;
                else
                    rd_start   <= '1';
                    next_state <= IFM_READ;
                end if;

            when IFM_LEFT =>
                transfer_type <= "00";
                target_sel    <= "00";
                buf_sel       <= '1';
                if( left_zero_en = '1' ) then
                    next_state <= ZERO_FILL;
                else
                    next_state <= IFM_RIGHT;
                end if;

            when IFM_RIGHT =>
                transfer_type <= "00";
                target_sel    <= "00";
                buf_sel       <= '1';
                if( right_zero_en = '1' ) then
                    next_state <= ZERO_FILL;
                else
                    next_state <= IFM_NEXT;
                end if;

            when ZERO_FILL =>
                target_sel       <= "00"; -- IFBuffer.
                buf_sel          <= '1';
                zero_fill_active <= '1';
                if( reg_zf_words_left = 0 ) then
                    next_state <= zf_return_state;
                else
                    zero_wr_en <= '1';
                    next_state <= ZERO_FILL;
                end if;

            when IFM_NEXT =>
                target_sel <= "00";
                buf_sel    <= '1';
                if( reg_r_local < unsigned( tile_h ) + 1 ) then
                    next_state <= IFM_MAIN;
                elsif( has_residual = '1' ) then
                    next_state <= RES_READ;
                else
                    next_state <= START_TILE;
                end if;

            when RES_READ =>
                transfer_type <= "11";
                target_sel    <= "10"; -- ResidualBuffer.
                if( rd_done = '1' ) then
                    next_state <= RES_NEXT;
                else
                    rd_start   <= '1';
                    next_state <= RES_READ;
                end if;

            when RES_NEXT =>
                target_sel <= "10";
                if( ( pool_en = '1' and reg_r_local < resize( shift_right( unsigned( tile_h ), 1 ), 4 ) - 1 ) or
                    ( pool_en = '0' and reg_r_local < unsigned( tile_h ) - 1 ) ) then
                    next_state <= RES_READ;
                else
                    next_state <= START_TILE;
                end if;

            when START_TILE =>
                if( reg_first_tile = '1' ) then
                    accel_start <= '1';
                    next_state  <= START_TILE_HOLD;
                else
                    tile_ready <= '1';
                    next_state <= WAIT_ACCEL;
                end if;            
            
            when START_TILE_HOLD =>
                accel_start <= '1';
                next_state  <= WAIT_ACCEL;
            
            when WAIT_ACCEL =>
                if( tile_req = '1' or irq_out = '1' ) then
                    next_state <= CHECK_OFM;
                else
                    next_state <= WAIT_ACCEL;
                end if;

            when CHECK_OFM =>
                if( pool_en = '1' and pool_type = '1' ) then -- GAP.
                    if( reg_is_last_tile = '1' ) then
                        next_state <= GAP_FLUSH;
                    else
                        next_state <= NEXT_TILE;
                    end if;
                else
                    next_state <= OFM_WRITE;
                end if;

            when OFM_WRITE =>
                transfer_type <= "01";
                target_sel    <= "11"; -- OFBuffer.
                if( wr_done = '1' ) then
                    next_state <= OFM_NEXT;
                else
                    wr_start   <= '1';
                    next_state <= OFM_WRITE;
                end if;

            when OFM_NEXT =>
                target_sel <= "11";
                if( ( pool_en = '1' and reg_r_local < resize( shift_right( unsigned( tile_h ), 1 ), 4 ) - 1 ) or
                    ( pool_en = '0' and reg_r_local < unsigned( tile_h ) - 1 ) ) then
                    next_state <= OFM_WRITE;
                elsif( reg_is_last_tile = '1' ) then
                    next_state <= DONE_LAYER;
                else
                    next_state <= NEXT_TILE;
                end if;

            when GAP_FLUSH =>
                transfer_type    <= "01"; -- OFB.
                target_sel       <= "11";
                gap_flush_active <= '1';
                gap_ddr_addr     <= addr_out;
                gap_burst_words  <= std_logic_vector( resize( unsigned( cout( 6 downto 4 ) ), 10 ) );
                if( wr_done = '1' ) then
                    next_state <= DONE_LAYER;
                else
                    wr_start   <= '1';
                    next_state <= GAP_FLUSH;
                end if;

            when NEXT_TILE =>
                next_state <= IFM_MAIN;

            when DONE_LAYER =>
                dma_done   <= '1';
                next_state <= IDLE;

        end case;
    end process;

end Behavioral;