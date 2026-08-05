library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity bias_add is
    port(
        data_a   : in  int32_array( 0 to NUM_MACS - 1 );
        data_b   : in  int32_array( 0 to NUM_MACS - 1 );
        data_out : out int32_array( 0 to NUM_MACS - 1 )
    );
end bias_add;

architecture Behavioral of bias_add is

begin

    process( data_a, data_b )
    begin
        for i in 0 to NUM_MACS - 1 loop
            data_out( i ) <= data_a( i ) + data_b( i );
        end loop;
    end process;

end Behavioral;