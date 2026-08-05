library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bias_buf is
    generic(
        ADDR_WIDTH : integer := 4    -- Bits de dirección ( 16 posiciones ).
    );
    port(
        clk      : in  std_logic;
        r_enable : in  std_logic;
        w_enable : in  std_logic;
        wr_addr  : in  std_logic_vector(   3 downto 0 );
        rd_addr  : in  std_logic_vector(   1 downto 0 );
        data_in  : in  std_logic_vector( 127 downto 0 );
        data_out : out std_logic_vector( 511 downto 0 )
    );
end bias_buf;

architecture Behavioral of bias_buf is

    type buf_bram is array( 0 to ( 2 ** ADDR_WIDTH ) - 1 )of std_logic_vector( 127 downto 0 );
    signal buf_bias : buf_bram;
begin

    process( clk )
    begin
        if( rising_edge( clk ) ) then
            if( w_enable = '1' ) then
                buf_bias( to_integer( unsigned( wr_addr ) ) ) <= data_in;
            end if;
            
            if( r_enable = '1' ) then
                data_out( 127 downto   0 ) <= buf_bias( to_integer( unsigned( rd_addr ) ) * 4 );
                data_out( 255 downto 128 ) <= buf_bias( to_integer( unsigned( rd_addr ) ) * 4 + 1 );
                data_out( 383 downto 256 ) <= buf_bias( to_integer( unsigned( rd_addr ) ) * 4 + 2 );
                data_out( 511 downto 384 ) <= buf_bias( to_integer( unsigned( rd_addr ) ) * 4 + 3 );
            end if;
        end if;
    end process;
end Behavioral;
