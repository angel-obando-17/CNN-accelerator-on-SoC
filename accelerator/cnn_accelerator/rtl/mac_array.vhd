library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity mac_array is
    port(
        clk, reset : in  std_logic;
        enable     : in  std_logic;
        clear      : in  std_logic;
        weight     : in  int8_array  ( 0 to NUM_MACS - 1 );
        act        : in  int8_array  ( 0 to NUM_MACS - 1 );
        acc_out    : out int32_array ( 0 to NUM_MACS - 1 )
    );
end mac_array;

architecture Behavioral of mac_array is
begin
    gen_macs : for i in 0 to NUM_MACS - 1 generate
        mac_inst : entity work.mac
            port map(
                clk     => clk,
                reset   => reset,
                enable  => enable,
                clear   => clear,
                weight  => weight( i ),
                act     => act( i ),
                acc_out => acc_out( i )
            );
    end generate gen_macs;
end Behavioral;