library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity max_pool is
    port(
        clk        : in  std_logic;
        pool_act   : in  std_logic;
        valid_in   : in  std_logic;
        data_in    : in  std_logic_vector( 127 downto 0 );
        x_counter  : in  std_logic_vector( 6 downto 0 );
        y_counter  : in  std_logic_vector( 2 downto 0 );
        co_counter : in  std_logic_vector( 1 downto 0 );
        max_co     : in  std_logic_vector( 1 downto 0 );
        max_x      : in  std_logic_vector( 6 downto 0 );
        data_out   : out std_logic_vector( 127 downto 0 );
        wr_en      : out std_logic;
        wr_addr    : out std_logic_vector( 11 downto 0 )
    );
end max_pool;

architecture Behavioral of max_pool is

    type reg_bank_t is array( 0 to 3 )   of std_logic_vector( 127 downto 0 );
    type row_buf_t  is array( 0 to 255 ) of std_logic_vector( 127 downto 0 );
    
    signal x_even_reg   : reg_bank_t;
    signal row_buf_ram  : row_buf_t;
    signal rb_rd_data   : std_logic_vector( 127 downto 0 );
    signal h_max        : std_logic_vector( 127 downto 0 );
    signal h_max_reg    : std_logic_vector( 127 downto 0 );
    signal wr_en_pipe   : std_logic;
    signal wr_addr_pipe : std_logic_vector( 11 downto 0 );
    
    function max_word( 
        a : std_logic_vector( 127 downto 0 );
        b : std_logic_vector( 127 downto 0 ) 
    ) return std_logic_vector is
        variable a_sig  : signed( 7 downto 0 );
        variable b_sig  : signed( 7 downto 0 );
        variable result : std_logic_vector( 127 downto 0 );
    begin
        for i in 0 to NUM_MACS - 1 loop
            a_sig := signed( a( ( ( 8 * i ) + 7 ) downto ( 8 * i ) ) );
            b_sig := signed( b( ( ( 8 * i ) + 7 ) downto ( 8 * i ) ) );
            if( a_sig > b_sig ) then
                result( ( ( 8 * i ) + 7 ) downto ( 8 * i ) ) := std_logic_vector( a_sig );
            else
                result( ( ( 8 * i ) + 7 ) downto ( 8 * i ) ) := std_logic_vector( b_sig );
            end if;
        end loop;
        
        return result;
    end function;
    
begin
    
    h_max <= max_word( data_in, x_even_reg( to_integer( unsigned( co_counter ) ) ) );
    
    process( clk )
        variable rb_addr    : unsigned(  7 downto 0 );   -- dirección del row buffer.
        variable pool_addr  : unsigned( 11 downto 0 );   -- dirección de salida al OFBuffer.
        variable tile_w_h   : unsigned(  6 downto 0 );   -- TILE_W / 2.
        variable num_co_v   : unsigned(  2 downto 0 );   -- max_co + 1.
        variable y_out      : unsigned(  2 downto 0 );   -- y_counter >> 1.
        variable x_out      : unsigned(  5 downto 0 );   -- x_counter >> 1.
    begin
        if( rising_edge( clk ) ) then
            wr_en_pipe <= '0';
            num_co_v := resize( unsigned( max_co ), 3 ) + 1;
            tile_w_h := resize( unsigned( max_x( 6 downto 1 ) ), 7 ) + 1;
            x_out    := unsigned( x_counter( 6 downto 1 ) );
            y_out    := resize( unsigned( y_counter( 2 downto 1 ) ), 3 );
            
            rb_addr  := resize( x_out * resize( num_co_v, 6 ), 8 ) + resize( unsigned( co_counter ), 8 );
            pool_addr := resize( resize( y_out * tile_w_h, 10 ) * resize( num_co_v, 10 ), 12 ) + resize( x_out * resize( num_co_v, 6 ), 12 ) + resize( unsigned( co_counter ), 12 );
            if( pool_act = '1' and valid_in = '1' ) then 
                -- x par: guardar píxel en el banco de registros
                if( x_counter( 0 ) = '0' ) then
                x_even_reg( to_integer( unsigned( co_counter ) ) ) <= data_in;
                -- x impar: comparar con el par y actuar según y
                elsif( x_counter( 0 ) = '1' ) then
                    -- y par: escribir máximo horizontal al row buffer
                    if( y_counter( 0 ) = '0' ) then
                      row_buf_ram( to_integer( rb_addr ) ) <= h_max;
                    -- y impar: leer row buffer + cargar pipeline
                    else
                      rb_rd_data   <= row_buf_ram( to_integer( rb_addr ) );
                      h_max_reg    <= h_max;
                      wr_en_pipe   <= '1';
                      wr_addr_pipe <= std_logic_vector( pool_addr );
                    end if;
                end if;
            end if;
        end if;
    end process;
    
    wr_en    <= wr_en_pipe;
    wr_addr  <= wr_addr_pipe;
    data_out <= max_word( h_max_reg, rb_rd_data );
    
end Behavioral;