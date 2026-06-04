library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity add_unit is
    port(
        data_a   : in  int8_array( 0 to NUM_MACS - 1 );
        data_b   : in  int8_array( 0 to NUM_MACS - 1 );
        data_out : out int8_array( 0 to NUM_MACS - 1 )
    );
end add_unit;

architecture Behavioral of add_unit is
    type int9_array is array ( natural range <> ) of signed( 8 downto 0 );
    
    function clamp( x : signed( 8 downto 0 ) ) return signed is
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
    process( data_a, data_b )
        variable data_a_ext   : int9_array( 0 to NUM_MACS - 1 );
        variable data_b_ext   : int9_array( 0 to NUM_MACS - 1 );
        variable data_out_ext : int9_array( 0 to NUM_MACS - 1 );
    begin
        for i in 0 to NUM_MACS - 1 loop
            data_a_ext( i )   := resize( signed( data_a( i ) ), 9 );
            data_b_ext( i )   := resize( signed( data_b( i ) ), 9 );
            data_out_ext( i ) := data_a_ext( i ) + data_b_ext( i );
            data_out( i )     <= clamp( data_out_ext( i ) );
        end loop;
    end process;    
end Behavioral;