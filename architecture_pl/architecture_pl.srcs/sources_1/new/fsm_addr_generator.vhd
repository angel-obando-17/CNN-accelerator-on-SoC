library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fsm_addr_generator is
    port(
        clk, reset     : in std_logic;
        -- Input signals.
        addr_en        : in std_logic;
        max_inner      : in std_logic_vector( 9 downto 0 );
        max_co         : in std_logic_vector( 1 downto 0 );
        max_x          : in std_logic_vector( 6 downto 0 );
        max_y          : in std_logic_vector( 2 downto 0 );
        max_tile_x     : in std_logic;
        max_tile_y     : in std_logic_vector( 4 downto 0 );
        -- Output signals.
        counter_reset  : out std_logic;
        pixel_done     : out std_logic;
        layer_done     : out std_logic;
        inner_counter  : out std_logic_vector( 9 downto 0 );
        co_counter     : out std_logic_vector( 1 downto 0 );
        x_counter      : out std_logic_vector( 6 downto 0 );
        y_counter      : out std_logic_vector( 2 downto 0 );
        tile_x_counter : out std_logic;
        tile_y_counter : out std_logic_vector( 4 downto 0 );
        mac_valid      : out std_logic
    );
end fsm_addr_generator;

architecture Behavioral of fsm_addr_generator is
    type state_type is ( IDLE, ACCUM, PIXEL_END, LAYER_CHECK );

    -- Aux signals.
    signal current_state, next_state : state_type;
    signal sig_layer_done : std_logic;
    signal sig_inner_cnt  : std_logic_vector( 9 downto 0 ) := ( others => '0' );
    signal sig_co_cnt     : std_logic_vector( 1 downto 0 ) := ( others => '0' );
    signal sig_x_cnt      : std_logic_vector( 6 downto 0 ) := ( others => '0' );
    signal sig_y_cnt      : std_logic_vector( 2 downto 0 ) := ( others => '0' );
    signal sig_tile_x_cnt : std_logic := '0';
    signal sig_tile_y_cnt : std_logic_vector( 4 downto 0 ) := ( others => '0' );
begin

    layer_done     <= sig_layer_done;
    inner_counter  <= sig_inner_cnt;
    co_counter     <= sig_co_cnt;
    x_counter      <= sig_x_cnt;
    y_counter      <= sig_y_cnt;
    tile_x_counter <= sig_tile_x_cnt;
    tile_y_counter <= sig_tile_y_cnt;

    process( clk, reset )
    begin
        if( reset = '1' ) then
            current_state  <= IDLE;
            sig_inner_cnt  <= ( others => '0' );
            sig_co_cnt     <= ( others => '0' );
            sig_x_cnt      <= ( others => '0' );
            sig_y_cnt      <= ( others => '0' );
            sig_tile_x_cnt <= '0';
            sig_tile_y_cnt <= ( others => '0' );
            sig_layer_done <= '0';
        elsif( rising_edge( clk ) ) then
            current_state <= next_state;

            -- Increase the value of inner_counter.
            if( current_state = ACCUM ) then
                sig_inner_cnt <= std_logic_vector( unsigned( sig_inner_cnt ) + 1 );
            end if;
            
            if( current_state = PIXEL_END ) then
                sig_layer_done <= '1' when(
                    sig_co_cnt     = max_co     and
                    sig_x_cnt      = max_x      and
                    sig_y_cnt      = max_y      and
                    sig_tile_x_cnt = max_tile_x and
                    sig_tile_y_cnt = max_tile_y
                ) else '0';
            end if;
            
            -- Increase the outer counters in hierarchy order.
            if( current_state = LAYER_CHECK and sig_layer_done = '0' ) then
                sig_inner_cnt <= ( others => '0' );
                if( sig_co_cnt = max_co ) then
                    sig_co_cnt <= ( others => '0' );
                    if( sig_x_cnt = max_x ) then
                        sig_x_cnt <= ( others => '0' );
                        if( sig_y_cnt = max_y ) then
                            sig_y_cnt <= ( others => '0' );
                            if( sig_tile_x_cnt = max_tile_x ) then
                                sig_tile_x_cnt <= '0';
                                sig_tile_y_cnt <= std_logic_vector( unsigned( sig_tile_y_cnt ) + 1 );
                            else
                                sig_tile_x_cnt <= not sig_tile_x_cnt;
                            end if;
                        else
                            sig_y_cnt <= std_logic_vector( unsigned( sig_y_cnt ) + 1 );
                        end if;
                    else
                        sig_x_cnt <= std_logic_vector( unsigned( sig_x_cnt ) + 1 );
                    end if;
                else
                    sig_co_cnt <= std_logic_vector( unsigned( sig_co_cnt ) + 1 );
                end if;
            end if;
            
            -- Reset all when returning to IDLE state.
            if( next_state = IDLE ) then
                sig_inner_cnt  <= ( others => '0' );
                sig_co_cnt     <= ( others => '0' );
                sig_x_cnt      <= ( others => '0' );
                sig_y_cnt      <= ( others => '0' );
                sig_tile_x_cnt <= '0';
                sig_tile_y_cnt <= ( others => '0' );
            end if;

        end if;
    end process;

    process(
        current_state,
        addr_en,
        max_inner,
        sig_layer_done,
        sig_inner_cnt
    )

    begin
        counter_reset  <= '0';
        pixel_done     <= '0';
        mac_valid      <= '1';
        next_state     <= current_state;

        case current_state is
            when IDLE =>
                counter_reset <= '1';
                if( addr_en = '1' ) then
                    next_state <= ACCUM;
                else
                    next_state <= IDLE;
                end if;
            when ACCUM =>
                if( sig_inner_cnt = "0000000000" ) then
                    mac_valid <= '0';
                end if;
                if( max_inner = sig_inner_cnt ) then
                    next_state <= PIXEL_END;
                else
                    next_state <= ACCUM;
                end if;
            when PIXEL_END =>
                pixel_done <= '1';
                if( addr_en = '1' ) then
                    next_state <= LAYER_CHECK;
                else
                    next_state <= PIXEL_END;
                end if;
            when LAYER_CHECK =>
                pixel_done <= '1';
                if( sig_layer_done = '1' ) then
                    next_state <= IDLE;
                else
                    next_state <= ACCUM;
                end if;
        end case;
    end process;
end Behavioral;
