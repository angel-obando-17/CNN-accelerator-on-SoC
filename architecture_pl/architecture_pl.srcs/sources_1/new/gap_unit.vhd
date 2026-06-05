library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity gap_unit is
    port(
        clk           : in  std_logic;
        acc_clear     : in  std_logic;
        pool_type_sel : in  std_logic;
        valid_in      : in  std_logic;
        data_in       : in  std_logic_vector( 127 downto 0 );
        co_counter    : in  std_logic_vector( 1 downto 0 );
        max_co        : in  std_logic_vector( 1 downto 0 );
        layer_done    : in  std_logic;
        gap_shift     : in  std_logic_vector( 4 downto 0 );
        data_out      : out std_logic_vector( 127 downto 0 );
        wr_en         : out std_logic;
        wr_addr       : out std_logic_vector( 11 downto 0 );
        gap_done      : out std_logic
    );
end gap_unit;

architecture Behavioral of gap_unit is

    type gap_row_t is array( 0 to NUM_MACS - 1 ) of signed( 31 downto 0 );
    type gap_acc_t is array( 0 to 3 ) of gap_row_t;
    
    signal gap_acc       : gap_acc_t;
    signal gap_writing   : std_logic;
    signal gap_write_cnt : unsigned( 1 downto 0 );
    
    function clamp( x : signed( 31 downto 0 ) ) return signed is
    begin
        if( x > 127 ) then 
            return to_signed( 127, 8 );
        elsif( x < -128 ) then 
            return to_signed( -128, 8 );
        else
            return x( 7 downto 0 ); 
        end if;
    end function;
    
    function gap_avg_word(
        a     : gap_row_t;
        shift : std_logic_vector( 4 downto 0 ) 
    ) return std_logic_vector is
        variable shifted : signed( 31 downto 0 );
        variable result  : std_logic_vector( 127 downto 0 );
    begin
        for i in 0 to NUM_MACS - 1 loop
            shifted := shift_right( a( i ), to_integer( unsigned( shift ) ) );
            result( ( ( 8 * i ) + 7 ) downto ( 8 * i ) ) := std_logic_vector( clamp( shifted ) );
        end loop;
        return result;
    end function;
    
begin

    process( clk )
    begin
        if( rising_edge( clk ) ) then
            wr_en    <= '0';
            gap_done <= '0';
            if( acc_clear = '1' ) then
                gap_writing   <= '0';
                gap_write_cnt <= "00";
                gap_acc <= ( others => ( others => ( others => '0' ) ) );
            else
                if( pool_type_sel = '1' and valid_in = '1' and gap_writing = '0' ) then
                    for i in 0 to NUM_MACS - 1 loop
                        gap_acc( to_integer( unsigned( co_counter ) ) )( i ) <= gap_acc( to_integer( unsigned( co_counter ) ) )( i ) + signed( data_in( ( 8 * i ) + 7 downto ( 8 * i ) ) );
                    end loop;
                    if( layer_done = '1' ) then
                        gap_writing   <= '1';
                        gap_write_cnt <= "00";
                    end if;
                end if;
                if( gap_writing = '1' ) then
                    data_out <= gap_avg_word( gap_acc( to_integer( unsigned( gap_write_cnt ) ) ), gap_shift );
                    wr_en    <= '1';
                    wr_addr  <= std_logic_vector( resize( gap_write_cnt, 12 ) );
                    if( gap_write_cnt = unsigned( max_co ) ) then
                        gap_done    <= '1';
                        gap_writing <= '0';
                    else
                        gap_write_cnt <= gap_write_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;