library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pool_unit is
    port(
        clk           : in  std_logic;
        pool_act      : in  std_logic;
        pool_type_sel : in  std_logic;
        valid_in      : in  std_logic;
        data_in       : in  std_logic_vector( 127 downto 0 );
        co_counter    : in  std_logic_vector( 1 downto 0 );
        max_co        : in  std_logic_vector( 1 downto 0 );
        x_counter     : in  std_logic_vector( 6 downto 0 );
        y_counter     : in  std_logic_vector( 2 downto 0 );
        max_x         : in  std_logic_vector( 6 downto 0 );
        layer_done    : in  std_logic;
        acc_clear     : in  std_logic;
        gap_shift     : in  std_logic_vector( 4 downto 0 );
        data_out      : out std_logic_vector( 127 downto 0 );
        wr_en         : out std_logic;
        wr_addr       : out std_logic_vector( 11 downto 0 );
        gap_done      : out std_logic
    );
end pool_unit;

architecture Behavioral of pool_unit is
    -- MaxPool Unit signals.
    signal mp_data_out  : std_logic_vector(127 downto 0);
    signal mp_wr_en     : std_logic;
    signal mp_wr_addr   : std_logic_vector(11 downto 0);
    -- GAP Unit signals.
    signal gap_data_out : std_logic_vector(127 downto 0);
    signal gap_wr_en    : std_logic;
    signal gap_wr_addr  : std_logic_vector(11 downto 0);
    
begin

    mp_inst : entity work.max_pool
        port map(
            clk        => clk,
            acc_clear  => acc_clear,
            pool_act   => pool_act,
            valid_in   => valid_in,
            data_in    => data_in,
            co_counter => co_counter,
            max_co     => max_co,
            x_counter  => x_counter,
            y_counter  => y_counter,
            max_x      => max_x,
            data_out   => mp_data_out,
            wr_en      => mp_wr_en,
            wr_addr    => mp_wr_addr         
        );
        
    gap_inst : entity work.gap_unit
        port map(
            clk           => clk,
            pool_type_sel => pool_type_sel,
            valid_in      => valid_in,
            data_in       => data_in,
            co_counter    => co_counter,
            max_co        => max_co,
            layer_done    => layer_done,
            acc_clear     => acc_clear,
            gap_shift     => gap_shift,
            data_out      => gap_data_out,
            wr_en         => gap_wr_en,
            wr_addr       => gap_wr_addr,
            gap_done      => gap_done 
        );

    data_out <= mp_data_out when pool_type_sel = '0' else gap_data_out;
    wr_en    <= mp_wr_en    when pool_type_sel = '0' else gap_wr_en;
    wr_addr  <= mp_wr_addr  when pool_type_sel = '0' else gap_wr_addr;
    
end Behavioral;