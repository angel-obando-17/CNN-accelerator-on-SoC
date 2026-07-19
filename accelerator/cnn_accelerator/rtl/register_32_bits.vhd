library ieee;
use ieee.std_logic_1164.all;

entity register_32_bits is
    port( 
        clk      : in  std_logic;
        reset    : in  std_logic;
        enable   : in  std_logic;
        data_in  : in  std_logic_vector ( 31 downto 0 );
        data_out : out std_logic_vector ( 31 downto 0 )
    );
end register_32_bits;

architecture Behavioral of register_32_bits is
begin
    process( clk, reset )
    begin
        if reset = '1' then
            data_out <= ( others => '0' );
        elsif rising_edge( clk ) then
            if enable = '1' then
                data_out <= data_in;
            end if;
        end if;    
    end process;

end Behavioral;
