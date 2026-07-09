library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi4_read_master is
    port(
        clk         : in std_logic;
        reset       : in std_logic;

        -- Control Signals from and to DMA_FSM.
        start       : in  std_logic;
        ddr_addr    : in  std_logic_vector( 31 downto 0 );
        burst_words : in  std_logic_vector(  9 downto 0 );
        local_addr  : in  std_logic_vector( 12 downto 0 );
        done        : out std_logic;

        -- AXI4 Read.
        m_axi_arid    : out std_logic_vector(  3 downto 0 );
        m_axi_araddr  : out std_logic_vector( 31 downto 0 );
        m_axi_arlen   : out std_logic_vector(  7 downto 0 );
        m_axi_arsize  : out std_logic_vector(  2 downto 0 );
        m_axi_arburst : out std_logic_vector(  1 downto 0 );
        m_axi_arvalid : out std_logic;
        m_axi_arready : in  std_logic;
        m_axi_rid     : in  std_logic_vector(  3 downto 0 );
        m_axi_rdata   : in  std_logic_vector( 63 downto 0 );
        m_axi_rresp   : in  std_logic_vector(  1 downto 0 );
        m_axi_rlast   : in  std_logic;
        m_axi_rvalid  : in  std_logic;
        m_axi_rready  : out std_logic;

        -- AXI4 Write.
        local_wr_en   : out std_logic;
        local_wr_addr : out std_logic_vector( 12 downto 0 );
        local_wr_data : out std_logic_vector( 127 downto 0 )
    );
end axi4_read_master;

architecture Behavioral of axi4_read_master is
    type state_type is ( IDLE, AR_ADDR, R_DATA, CHECK_MORE );

    constant CHUNK_WORDS : unsigned( 9 downto 0 ) := to_unsigned( 64, 10 );

    -- Aux signals.
    signal current_state, next_state : state_type;

    -- Transffer progress.
    signal sig_ddr_addr    : unsigned( 31 downto 0 ) := ( others => '0' );
    signal sig_local_addr  : unsigned( 12 downto 0 ) := ( others => '0' );
    signal sig_words_left  : unsigned(  9 downto 0 ) := ( others => '0' );
    signal sig_chunk_words : unsigned(  9 downto 0 ) := ( others => '0' );
    signal sig_arlen       : std_logic_vector(  7 downto 0 ) := ( others => '0' );

    signal sig_low_beat : std_logic_vector( 63 downto 0 ) := ( others => '0' );
    signal sig_have_low : std_logic := '0';

    signal sig_rready : std_logic;
begin

    process( clk, reset )
    begin
        if( reset = '0' ) then
            current_state   <= IDLE;
            sig_ddr_addr    <= ( others => '0' );
            sig_local_addr  <= ( others => '0' );
            sig_words_left  <= ( others => '0' );
            sig_chunk_words <= ( others => '0' );
            sig_arlen       <= ( others => '0' );
            sig_low_beat    <= ( others => '0' );
            sig_have_low    <= '0';

        elsif( rising_edge( clk ) ) then
            current_state <= next_state;

            case current_state is
                when IDLE =>
                    if( start = '1' ) then
                        sig_ddr_addr   <= unsigned( ddr_addr );
                        sig_local_addr <= unsigned( local_addr );
                        sig_words_left <= unsigned( burst_words );
                    end if;
                    sig_have_low <= '0';

                when AR_ADDR =>
                    if( sig_words_left > CHUNK_WORDS ) then
                        sig_chunk_words <= CHUNK_WORDS;
                        sig_arlen       <= std_logic_vector( to_unsigned( 127, 8 ) );
                    else
                        sig_chunk_words <= sig_words_left;
                        sig_arlen       <= std_logic_vector( resize( shift_left( sig_words_left, 1 ) - 1, 8 ) );
                    end if;
                    sig_have_low <= '0';

                when R_DATA =>
                    if( m_axi_rvalid = '1' and sig_rready = '1' ) then
                        if( sig_have_low = '0' ) then
                            sig_low_beat <= m_axi_rdata;
                            sig_have_low <= '1';
                        else
                            sig_have_low   <= '0';
                            sig_local_addr <= sig_local_addr + 1;
                        end if;

                        if( m_axi_rlast = '1' ) then
                            sig_ddr_addr   <= sig_ddr_addr + resize( sig_chunk_words * to_unsigned( 16, 10 ), 32 );
                            sig_words_left <= sig_words_left - sig_chunk_words;
                        end if;
                    end if;

                when CHECK_MORE =>
                    null;

            end case;
        end if;
    end process;

    process(
        current_state,
        start,
        sig_words_left,
        m_axi_arready,
        m_axi_rvalid,
        m_axi_rlast,
        sig_have_low
    )
    begin
        done          <= '0';
        m_axi_arvalid <= '0';
        sig_rready    <= '0';
        next_state    <= current_state;

        case current_state is
            when IDLE =>
                if( start = '1' ) then
                    next_state <= AR_ADDR;
                else
                    next_state <= IDLE;
                end if;

            when AR_ADDR =>
                m_axi_arvalid <= '1';
                if( m_axi_arready = '1' ) then
                    next_state <= R_DATA;
                else
                    next_state <= AR_ADDR;
                end if;

            when R_DATA =>
                sig_rready <= '1';
                if( m_axi_rvalid = '1' and m_axi_rlast = '1' ) then
                    next_state <= CHECK_MORE;
                else
                    next_state <= R_DATA;
                end if;

            when CHECK_MORE =>
                if( sig_words_left = 0 ) then
                    done       <= '1';
                    next_state <= IDLE;
                else
                    next_state <= AR_ADDR;
                end if;

        end case;
    end process;

    -- AR Channel ( Read Address ).
    m_axi_arid    <= "0000";
    m_axi_araddr  <= std_logic_vector( sig_ddr_addr );
    m_axi_arlen   <= sig_arlen;
    m_axi_arsize  <= "011";
    m_axi_arburst <= "01";  

    m_axi_rready <= sig_rready;

    -- Write to Local Buffer.
    local_wr_en   <= '1' when ( m_axi_rvalid = '1' and sig_rready = '1' and sig_have_low = '1' ) else '0';
    local_wr_addr <= std_logic_vector( sig_local_addr );
    local_wr_data <= m_axi_rdata & sig_low_beat;

end Behavioral;
