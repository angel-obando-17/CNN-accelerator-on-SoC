library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity inputf_buf_b is
    generic(
        DATA_WIDTH : integer := 128; -- Bits por palabra.
        ADDR_WIDTH : integer := 12   -- Bits de dirección ( 4096 posiciones ).
    );
    port(
        clk      : in  std_logic;
        r_enable : in  std_logic;
        w_enable : in  std_logic;
        wr_addr  : in  std_logic_vector( ADDR_WIDTH - 1 downto 0 );
        rd_addr  : in  std_logic_vector( ADDR_WIDTH - 1 downto 0 );
        data_in  : in  std_logic_vector( DATA_WIDTH - 1 downto 0 );
        data_out : out std_logic_vector( DATA_WIDTH - 1 downto 0 )
    );
end inputf_buf_b;

architecture Behavioral of inputf_buf_b is
    type buf_bram is array( 0 to ( 2 ** ADDR_WIDTH ) - 1 )of std_logic_vector( DATA_WIDTH - 1 downto 0 );
    signal buf_inputf_b : buf_bram;
begin

    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( w_enable = '1' ) then
                buf_inputf_b( to_integer( unsigned( wr_addr ) ) ) <= data_in;
            end if;
            
            
            if( r_enable = '1' ) then
                data_out <= buf_inputf_b( to_integer( unsigned( rd_addr ) ) );
            end if;
        end if;
    end process;

end Behavioral;