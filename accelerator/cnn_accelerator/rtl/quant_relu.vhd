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
        shift     : in  unsigned( 4 downto 0 );
        relu6_val : in  signed( 7 downto 0 );
        acc_in    : in  int32_array( 0 to NUM_MACS - 1 );
        data_out  : out int8_array(  0 to NUM_MACS - 1 );
        valid_out : out std_logic      
    );
end quant_relu;

architecture Behavioral of quant_relu is

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
        variable shifted : signed( 31 downto 0 );
        variable clamped : signed( 7 downto 0 );
    begin
        if( rising_Edge( clk ) ) then
            if( reset = '1' ) then
                valid_out <= '0';
                data_out  <= ( others => ( others => '0' ) );
            elsif( quant_en = '1' ) then
                valid_out <= '1';
                for i in 0 to NUM_MACS - 1 loop
                    -- Step 1: shift_right to reduce the bits of the register.
                    shifted := shift_right( acc_in( i ), to_integer( shift ) );
                    -- Step 2: saturate to int8.
                    clamped := clamp( shifted );
                    -- Step 3: ReLU6 function.
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

