library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi4_write_master is
    port(
        clk         : in std_logic;
        reset       : in std_logic;

        -- Control Signals from and to DMA_FSM.
        start       : in  std_logic;
        ddr_addr    : in  std_logic_vector( 31 downto 0 );
        burst_words : in  std_logic_vector(  9 downto 0 );
        local_addr  : in  std_logic_vector( 11 downto 0 );
        done        : out std_logic;

        -- AXI4 Write.
        m_axi_awid    : out std_logic_vector(  3 downto 0 );
        m_axi_awaddr  : out std_logic_vector( 31 downto 0 );
        m_axi_awlen   : out std_logic_vector(  7 downto 0 );
        m_axi_awsize  : out std_logic_vector(  2 downto 0 );
        m_axi_awburst : out std_logic_vector(  1 downto 0 );
        m_axi_awvalid : out std_logic;
        m_axi_awready : in  std_logic;
        m_axi_wdata   : out std_logic_vector( 63 downto 0 );
        m_axi_wstrb   : out std_logic_vector(  7 downto 0 );
        m_axi_wlast   : out std_logic;
        m_axi_wvalid  : out std_logic;
        m_axi_wready  : in  std_logic;
        m_axi_bid     : in  std_logic_vector(  3 downto 0 );
        m_axi_bresp   : in  std_logic_vector(  1 downto 0 );
        m_axi_bvalid  : in  std_logic;
        m_axi_bready  : out std_logic;

        -- AXI4 Read.
        local_rd_en   : out std_logic;
        local_rd_addr : out std_logic_vector( 11 downto 0 );
        local_rd_data : in  std_logic_vector( 127 downto 0 )
    );
end axi4_write_master;

architecture Behavioral of axi4_write_master is
    type state_type is ( IDLE, AW_ADDR, RD_LOCAL, W_LOW, W_HIGH, B_RESP, CHECK_MORE );

    constant CHUNK_WORDS : unsigned( 9 downto 0 ) := to_unsigned( 64, 10 );

    -- Aux signals.
    signal current_state, next_state : state_type;

    -- Transffer progress.
    signal sig_ddr_addr    : unsigned( 31 downto 0 ) := ( others => '0' );
    signal sig_local_addr  : unsigned( 11 downto 0 ) := ( others => '0' );
    signal sig_words_left  : unsigned(  9 downto 0 ) := ( others => '0' );
    signal sig_chunk_words : unsigned(  9 downto 0 ) := ( others => '0' );
    signal sig_chunk_left  : unsigned(  9 downto 0 ) := ( others => '0' );
    signal sig_awlen       : std_logic_vector(  7 downto 0 ) := ( others => '0' );

    signal sig_wvalid : std_logic;
begin

    process( clk, reset )
    begin
        if( reset = '0' ) then
            current_state   <= IDLE;
            sig_ddr_addr    <= ( others => '0' );
            sig_local_addr  <= ( others => '0' );
            sig_words_left  <= ( others => '0' );
            sig_chunk_left  <= ( others => '0' );

        elsif( rising_edge( clk ) ) then
            current_state <= next_state;

            case current_state is
                when IDLE =>
                    if( start = '1' ) then
                        sig_ddr_addr   <= unsigned( ddr_addr );
                        sig_local_addr <= unsigned( local_addr );
                        sig_words_left <= unsigned( burst_words );
                    end if;

                when AW_ADDR =>
                    sig_chunk_left <= sig_chunk_words;

                when W_HIGH =>
                    if( sig_wvalid = '1' and m_axi_wready = '1' ) then
                        sig_local_addr <= sig_local_addr + 1;
                        sig_chunk_left <= sig_chunk_left - 1;
                    end if;

                when B_RESP =>
                    if( m_axi_bvalid = '1' ) then
                        sig_ddr_addr   <= sig_ddr_addr + resize( sig_chunk_words * to_unsigned( 16, 10 ), 32 );
                        sig_words_left <= sig_words_left - sig_chunk_words;
                    end if;

                when others =>
                    null;

            end case;
        end if;
    end process;

    process(
        current_state,
        start,
        sig_words_left,
        m_axi_awready,
        m_axi_wready,
        m_axi_bvalid,
        sig_chunk_left,
        local_rd_data
    )
    begin
        done          <= '0';
        m_axi_awvalid <= '0';
        sig_wvalid    <= '0';
        m_axi_wlast   <= '0';
        m_axi_wdata   <= ( others => '0' );
        m_axi_bready  <= '0';
        local_rd_en   <= '0';
        next_state    <= current_state;

        case current_state is
            when IDLE =>
                if( start = '1' ) then
                    next_state <= AW_ADDR;
                else
                    next_state <= IDLE;
                end if;

            when AW_ADDR =>
                m_axi_awvalid <= '1';
                if( m_axi_awready = '1' ) then
                    next_state <= RD_LOCAL;
                else
                    next_state <= AW_ADDR;
                end if;

            when RD_LOCAL =>
                local_rd_en <= '1';
                next_state  <= W_LOW;

            when W_LOW =>
                sig_wvalid  <= '1';
                m_axi_wdata <= local_rd_data( 63 downto 0 );
                if( m_axi_wready = '1' ) then
                    next_state <= W_HIGH;
                else
                    next_state <= W_LOW;
                end if;

            when W_HIGH =>
                sig_wvalid  <= '1';
                m_axi_wdata <= local_rd_data( 127 downto 64 );
                if( sig_chunk_left = 1 ) then
                    m_axi_wlast <= '1';
                end if;
                if( m_axi_wready = '1' ) then
                    if( sig_chunk_left = 1 ) then
                        next_state <= B_RESP;
                    else
                        next_state <= RD_LOCAL;
                    end if;
                else
                    next_state <= W_HIGH;
                end if;

            when B_RESP =>
                m_axi_bready <= '1';
                if( m_axi_bvalid = '1' ) then
                    next_state <= CHECK_MORE;
                else
                    next_state <= B_RESP;
                end if;

            when CHECK_MORE =>
                if( sig_words_left = 0 ) then
                    done       <= '1';
                    next_state <= IDLE;
                else
                    next_state <= AW_ADDR;
                end if;

        end case;
    end process;

    -- AW Channel ( Write Address ).
    m_axi_awid    <= "0000";
    m_axi_awaddr  <= std_logic_vector( sig_ddr_addr );
    sig_chunk_words <= CHUNK_WORDS when ( sig_words_left > CHUNK_WORDS ) else sig_words_left;
    sig_awlen <= std_logic_vector( to_unsigned( 127, 8 ) ) when ( sig_words_left > CHUNK_WORDS ) else
                 std_logic_vector( resize( shift_left( sig_words_left, 1 ) - 1, 8 ) );
    m_axi_awlen   <= sig_awlen;
    m_axi_awsize  <= "011";
    m_axi_awburst <= "01";

    -- W Channel.
    m_axi_wvalid <= sig_wvalid;
    m_axi_wstrb  <= "11111111";

    -- Local Read.
    local_rd_addr <= std_logic_vector( sig_local_addr );

end Behavioral;
