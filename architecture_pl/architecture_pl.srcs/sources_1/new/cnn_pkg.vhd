library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package cnn_pkg is
    constant NUM_MACS : integer := 16;

    type int8_array  is array ( natural range <> ) of signed(  7 downto 0 );
    type int32_array is array ( natural range <> ) of signed( 31 downto 0 );
end package cnn_pkg;
