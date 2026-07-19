library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity input_mux is
    port(
        data_in  : in  std_logic_vector( 127 downto 0 );
        byte_sel : in  std_logic_vector( 3 downto 0 );
        reg_mode : in  std_logic_vector( 1 downto 0 );
        data_out : out int8_array( 0 to NUM_MACS - 1 )
    );
end input_mux;

architecture Behavioral of input_mux is

begin

    process( data_in, byte_sel, reg_mode )
        variable byte_idx : integer;
        variable sel_byte : std_logic_vector( 7 downto 0 );
    begin
        byte_idx := to_integer( unsigned( byte_sel ) );
        sel_byte := data_in( ( ( byte_idx * 8 ) + 7 ) downto ( byte_idx * 8 ) );
        
        for i in 0 to NUM_MACS - 1 loop
            -- DW 3x3.
            if( reg_mode = "01" ) then
                data_out( i ) <= signed( data_in( ( ( i * 8 ) + 7 ) downto ( i * 8 ) ) );
            -- PW 1x1 y Conv 3x3.
            else
                data_out( i ) <= signed( sel_byte );
            end if;
        end loop;
    end process;

end Behavioral;