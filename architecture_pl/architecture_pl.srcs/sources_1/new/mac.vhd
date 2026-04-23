library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac is
    port(
       clk, reset : in std_logic;
       enable     : in std_logic;
       clear      : in std_logic;
       weight     : in signed( 7 downto 0 );
       act        : in signed( 7 downto 0 );
       acc_out    : out signed( 31 downto 0 )
    );
end mac;

architecture Behavioral of mac is
    signal accumulator : signed( 31 downto 0 );

    attribute use_dsp : string;
    attribute use_dsp of accumulator : signal is "yes";
begin
    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( reset = '1' or clear = '1' ) then
                accumulator <= ( others => '0' );
            elsif( enable = '1' ) then
                accumulator <= accumulator + ( weight * act );
            end if;
        end if;
    end process;

    acc_out <= accumulator;

end Behavioral;
