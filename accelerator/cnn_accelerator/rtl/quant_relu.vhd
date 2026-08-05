library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity quant_relu is
    port(
        clk       : in  std_logic;
        reset     : in  std_logic;
        quant_en  : in  std_logic;
        relu_en   : in  std_logic;
        mult      : in  unsigned( 15 downto 0 );
        shift     : in  unsigned( 4 downto 0 );
        relu6_val : in  signed( 7 downto 0 );
        acc_in    : in  int32_array( 0 to NUM_MACS - 1 );
        data_out  : out int8_array(  0 to NUM_MACS - 1 );
        valid_out : out std_logic      
    );
end quant_relu;

architecture Behavioral of quant_relu is
    
    type product_array_t is array( 0 to NUM_MACS - 1 ) of signed( 48 downto 0 );
    
    signal product_reg  : product_array_t := ( others => ( others => '0' ) );
    signal quant_en_d1  : std_logic := '0'; 
    
    function clamp( x : signed( 31 downto 0 ) ) return signed is
    begin
        if( x > 127 ) then 
            return to_signed( 127, 8 );
        elsif( x < -128 ) then 
            return to_signed( -128, 8 );
        else
            return x( 7 downto 0 ); 
        end if;
    end function;

begin

    process( clk )
        variable mult_ext : signed( 16 downto 0 );
    begin
        if( rising_edge( clk ) ) then
            quant_en_d1 <= quant_en;
            if( reset = '1' ) then
                product_reg <= ( others => ( others => '0' ) );
            elsif( quant_en = '1' ) then
                for i in 0 to NUM_MACS - 1 loop
                    mult_ext        := signed( '0' & mult );
                    product_reg( i ) <= acc_in( i ) * mult_ext;
                end loop;
            end if;
        end if;
    end process;

    process( clk )
        variable total_sh : integer;
        variable shifted  : signed( 31 downto 0 );
        variable clamped  : signed( 7 downto 0 );
        variable rounded  : signed( 48 downto 0 );
    begin
        if( rising_edge( clk ) ) then
            if( reset = '1' ) then
                valid_out <= '0';
                data_out  <= ( others => ( others => '0' ) );
            elsif( quant_en_d1 = '1' ) then
                valid_out <= '1';
                for i in 0 to NUM_MACS - 1 loop
                    total_sh := to_integer( shift ) + 16;
                    rounded  := product_reg( i ) + shift_left( to_signed( 1, 49 ), total_sh - 1 );
                    shifted  := resize( shift_right( rounded, total_sh ), 32 );
                    -- Step 2 and 3 ( clamp + ReLU6 ).
                    clamped := clamp( shifted );
                    if( relu_en = '1' ) then
                        if( clamped < 0 ) then
                            data_out( i ) <= ( others => '0' );
                        elsif( clamped > relu6_val ) then
                            data_out( i ) <= relu6_val;
                        else
                            data_out( i ) <= clamped;
                        end if;
                    else
                        data_out( i ) <= clamped;
                    end if;
                end loop;
            else
                valid_out <= '0';
            end if;
        end if;
    end process;
    
end Behavioral;

