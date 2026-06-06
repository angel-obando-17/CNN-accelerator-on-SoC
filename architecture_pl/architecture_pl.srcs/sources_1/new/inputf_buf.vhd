library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity inputf_buf is
    generic(
        DATA_WIDTH : integer := 128; -- Bits por palabra.
        ADDR_WIDTH : integer := 12   -- Bits de dirección ( 4096 posiciones ).
    );
    port(
        clk         : in  std_logic;
        buf_sel     : in  std_logic;
        dma_wr_en   : in  std_logic;
        dma_wr_addr : in  std_logic_vector( ADDR_WIDTH - 1 downto 0 );
        dma_wr_data : in  std_logic_vector( DATA_WIDTH - 1 downto 0 );
        rd_en       : in  std_logic;
        rd_addr     : in  std_logic_vector( ADDR_WIDTH - 1 downto 0 );
        data_out    : out std_logic_vector( DATA_WIDTH - 1 downto 0 )
    );
end inputf_buf;

architecture Behavioral of inputf_buf is
    signal buf_a_en   : std_logic;
    signal buf_b_en   : std_logic;
    signal data_out_a : std_logic_vector( DATA_WIDTH - 1 downto 0 );
    signal data_out_b : std_logic_vector( DATA_WIDTH - 1 downto 0 );
begin
    
    buf_a_en <= '1' when ( dma_wr_en = '1' ) and ( buf_sel = '1' ) else '0';
    buf_b_en <= '1' when ( dma_wr_en = '1' ) and ( buf_sel = '0' ) else '0';
     
    buf_a : entity work.inputf_buf_a
        port map(
            clk      => clk,
            r_enable => rd_en,
            w_enable => buf_a_en,
            wr_addr  => dma_wr_addr,
            rd_addr  => rd_addr,
            data_in  => dma_wr_data,
            data_out => data_out_a
        );
    
    buf_b : entity work.inputf_buf_b
        port map(
            clk      => clk,
            r_enable => rd_en,
            w_enable => buf_b_en,
            wr_addr  => dma_wr_addr,
            rd_addr  => rd_addr,
            data_in  => dma_wr_data,
            data_out => data_out_b
        );
    
    data_out <= data_out_a when buf_sel = '0' else data_out_b;
    
end Behavioral;