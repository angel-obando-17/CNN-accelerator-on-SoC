library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity addr_generator is
    port(
        clk, reset     : in  std_logic;
        -- Input signals.
        cin            : in  std_logic_vector( 6 downto 0 );
        tile_ready     : in  std_logic;
        ---- From accelerator FSM.
        addr_en        : in  std_logic;
        reg_mode       : in  std_logic_vector( 1 downto 0 );
        ---- FSM configuration inputs.
        max_inner      : in  std_logic_vector( 9 downto 0 );
        max_co         : in  std_logic_vector( 1 downto 0 );
        max_x          : in  std_logic_vector( 6 downto 0 );
        max_y          : in  std_logic_vector( 2 downto 0 );
        max_tile_x     : in  std_logic;
        max_tile_y     : in  std_logic_vector( 4 downto 0 );
        -- Output signals.
        mac_valid      : out std_logic;
        addr_in        : out std_logic_vector( 12 downto 0 );
        addr_w         : out std_logic_vector( 11 downto 0 );
        addr_out       : out std_logic_vector( 11 downto 0 );
        byte_sel       : out std_logic_vector( 3 downto 0 );
        tile_boundary  : out std_logic;
        ---- To accelerator FSM.
        pixel_done     : out std_logic;
        layer_done     : out std_logic;
        ---- Inner sub-counters.
        ci_out         : out std_logic_vector( 6 downto 0 );
        ky_out         : out std_logic_vector( 1 downto 0 );
        kx_out         : out std_logic_vector( 1 downto 0 );
        ---- Outer counters from FSM.
        co_counter     : out std_logic_vector( 1 downto 0 );
        x_counter      : out std_logic_vector( 6 downto 0 );
        y_counter      : out std_logic_vector( 2 downto 0 );
        tile_x_counter : out std_logic;
        tile_y_counter : out std_logic_vector( 4 downto 0 )
    );
end addr_generator;

architecture Behavioral of addr_generator is
    
    -- Aux signals.
    ---- Internal signals from FSM.
    signal sig_mac_valid     : std_logic;
    signal sig_pixel_done    : std_logic;
    signal sig_layer_done    : std_logic;
    signal sig_counter_reset : std_logic;
    signal sig_tile_boundary : std_logic;
    ---- Inner sub-counters.
    signal sig_ci          : unsigned( 6 downto 0 ) := ( others => '0' );
    signal sig_ky          : unsigned( 1 downto 0 ) := ( others => '0' );
    signal sig_kx          : unsigned( 1 downto 0 ) := ( others => '0' );
    signal ky_kx_reset_val : unsigned( 1 downto 0 );
    ---- Active when FSM is in ACCUM state.
    signal accum_active : std_logic;
begin

    fsm_inst : entity work.fsm_addr_generator
        port map(
            clk            => clk,
            reset          => reset,
            addr_en        => addr_en,
            max_inner      => max_inner,
            max_co         => max_co,
            max_x          => max_x,
            max_y          => max_y,
            max_tile_x     => max_tile_x,
            max_tile_y     => max_tile_y,
            tile_ready     => tile_ready,
            counter_reset  => sig_counter_reset,
            pixel_done     => sig_pixel_done,
            layer_done     => sig_layer_done,
            tile_boundary  => sig_tile_boundary,
            inner_counter  => open,
            co_counter     => co_counter,
            x_counter      => x_counter,
            y_counter      => y_counter,
            tile_x_counter => tile_x_counter,
            tile_y_counter => tile_y_counter,
            mac_valid      => sig_mac_valid
        );

    pixel_done <= sig_pixel_done;
    layer_done <= sig_layer_done;
    mac_valid  <= sig_mac_valid;
    tile_boundary <= sig_tile_boundary;
    
    ci_out <= std_logic_vector( sig_ci );
    ky_out <= std_logic_vector( sig_ky );
    kx_out <= std_logic_vector( sig_kx );
    
    ky_kx_reset_val <= "01" when reg_mode = "10" else "00";
    -- Flag to know when the fsm is in ACCUM State.
    accum_active <= addr_en and ( not sig_counter_reset ) and ( not sig_pixel_done );

    -- Inner sub-counter process.
    process( clk, reset )
    begin
        if( reset = '1' ) then
            sig_ci <= ( others => '0' );
            sig_ky <= ky_kx_reset_val;
            sig_kx <= ky_kx_reset_val;
        elsif( rising_edge( clk ) ) then

            if( sig_counter_reset = '1' ) then
                sig_ci <= ( others => '0' );
                sig_ky <= ky_kx_reset_val;
                sig_kx <= ky_kx_reset_val;

            elsif( sig_pixel_done = '1' and addr_en = '1' ) then
                sig_ci <= ( others => '0' );
                sig_ky <= ky_kx_reset_val;
                sig_kx <= ky_kx_reset_val;

            elsif( accum_active = '1' ) then
                case reg_mode is
                    when "00" =>
                        -- Conv3x3: kx -> ky -> ci.
                        if( sig_kx = "10" ) then
                            sig_kx <= "00";
                            if( sig_ky = "10" ) then
                                sig_ky <= "00";
                                sig_ci <= sig_ci + 1;
                            else
                                sig_ky <= sig_ky + 1;
                            end if;
                        else
                            sig_kx <= sig_kx + 1;
                        end if;
                    when "01" =>
                        -- DW3x3: kx -> ky only, ci stays 0.
                        if( sig_kx = "10" ) then
                            sig_kx <= "00";
                            sig_ky <= sig_ky + 1;
                        else
                            sig_kx <= sig_kx + 1;
                        end if;
                    when "10" =>
                        -- PW1x1: only ci, kx and ky stay 1.
                        sig_ci <= sig_ci + 1;
                    when others => null;
                end case;

            end if;
        end if;
    end process;
        
    process(
        sig_ci, 
        sig_ky, 
        sig_kx,
        co_counter,
        x_counter,
        y_counter,
        cin, 
        max_x,
        max_co, 
        reg_mode
    )
    
    variable tile_w : unsigned( 7  downto 0 );  -- max 128.
    variable num_co : unsigned( 2  downto 0 );  
    -- To addr_in.
    variable row         : unsigned( 3 downto 0 );
    variable col         : unsigned( 7 downto 0 );
    variable cin_groups  : unsigned( 2 downto 0 );  -- Cin/16
    variable term1       : unsigned( 12 downto 0 ); -- row * TILE_W * cin_groups
    variable term2       : unsigned( 12 downto 0 ); -- col * cin_groups
    -- To addr_w.
        -- To Conv 3x3.
    variable term3  : unsigned( 11 downto 0 );  -- co * Cin * 9.
    variable term4  : unsigned( 10 downto 0 );  -- ci * 9.
    variable term5  : unsigned( 3  downto 0 );  -- ky * 3.
        -- To DW 3x3.
    variable term6  : unsigned( 5  downto 0 );  -- co * 9.
        -- To PW 1x1.
    variable term7  : unsigned( 8  downto 0 );  -- co * Cin.
    -- To addr_out.
    variable term8  : unsigned( 11 downto 0 );  -- y * TILE_W * num_co.
    variable term9  : unsigned( 9  downto 0 );  -- x * num_co.
    -- To Padding.
    variable tile_w_pad : unsigned( 7 downto 0 );
       
    begin
        tile_w     := resize( unsigned( max_x ), 8 ) + 1;
        tile_w_pad := tile_w + 2;
        num_co     := resize( unsigned( max_co ), 3 ) + 1;
        
        -- addr_in
        row        := resize( unsigned( y_counter ), 4 ) + resize( sig_ky, 4 );
        col        := resize( unsigned( x_counter ), 8 ) + resize( sig_kx, 8 );
        cin_groups := resize( unsigned( cin( 6 downto 4 ) ), 3 );  -- Cin / 16
                
        -- addr_w
        term3 := resize( unsigned( co_counter ) * unsigned( cin ) * to_unsigned( 9, 4 ), 12 );
        term4 := resize( sig_ci * to_unsigned( 9, 4 ), 11 );
        term5 := resize( sig_ky * to_unsigned( 3, 2 ), 4 );
        term6 := resize( unsigned( co_counter ) * to_unsigned( 9, 4 ), 6 );
        term7 := resize( unsigned( co_counter ) * unsigned( cin ), 9 );
            
        case reg_mode is
            when "01" =>
                -- DW3x3: word = base_pixel + co_counter (cada grupo de 16 canales)
                term1 := resize( row * tile_w_pad * cin_groups, 13 );
                term2 := resize( col * cin_groups, 13 );
                addr_in  <= std_logic_vector( term1 + term2 + resize( unsigned( co_counter ), 13 ) );
                byte_sel <= ( others => '0' );
            when others =>
                -- Conv3x3 y PW1x1: word = base_pixel + sig_ci/16, byte = sig_ci mod 16
                term1 := resize( row * tile_w_pad * cin_groups, 13 );
                term2 := resize( col * cin_groups, 13 );
                addr_in  <= std_logic_vector( term1 + term2 + resize( unsigned( sig_ci( 6 downto 4 ) ), 13 ) );
                byte_sel <= std_logic_vector( sig_ci( 3 downto 0 ) );
        end case;
        
        case reg_mode is
            when "00" =>
                addr_w <= std_logic_vector( term3 + resize( term4, 12 ) + resize( term5, 12 ) + resize( sig_kx, 12 ) );
            when "01" =>
                addr_w <= std_logic_vector( resize( term6, 12 ) + resize( term5, 12 ) + resize( sig_kx, 12 ) );
            when "10" =>
                addr_w <= std_logic_vector( resize( term7, 12 ) + resize( sig_ci, 12 ) );
            when others =>
                addr_w <= ( others => '0' );
        end case;
            
        -- addr_out.
        term8 := resize( unsigned( y_counter ) * ( tile_w * num_co ), 12 );
        term9 := resize( unsigned( x_counter ) * num_co, 10 );
        addr_out <= std_logic_vector( term8 + resize( term9, 12 ) + resize( unsigned( co_counter ), 12 ) );
       
    end process;    
end Behavioral;
