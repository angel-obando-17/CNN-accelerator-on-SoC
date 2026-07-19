library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity accumulator_bank is
    port( 
        clk      : in  std_logic;
        reset    : in  std_logic;
        enable   : in  std_logic;
        data_in  : in  reg_array( 0 to NUM_MACS - 1 );
        data_out : out reg_array( 0 to NUM_MACS - 1 )
    );
end accumulator_bank;

architecture Behavioral of accumulator_bank is
begin
    gen_registers : for i in 0 to NUM_MACS - 1 generate
        reg_inst : entity work.register_32_bits
            port map(
                clk      => clk,
                reset    => reset,
                enable   => enable,
                data_in  => data_in( i ),
                data_out => data_out( i )
            );
    end generate gen_registers;

end Behavioral;
