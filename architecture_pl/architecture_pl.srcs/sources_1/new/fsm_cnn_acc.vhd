library ieee;
use ieee.std_logic_1164.all;

entity fsm_cnn_accelerator is
    port(
        clk, reset       : in std_logic;
        -- Input signals.
        mac_valid        : in std_logic;
        reg_start        : in std_logic;
        reg_mode         : in std_logic_vector( 1 downto 0 );
        pixel_done       : in std_logic;
        reg_pool_en      : in std_logic;
        reg_pool_type    : in std_logic;
        post_done        : in std_logic;
        layer_done       : in std_logic;
        reg_has_residual : in std_logic;
        gap_done         : in std_logic;
        
        -- Output signals.
        acc_clear, addr_en, mac_en, mux_sel, acc_bank_enable : out std_logic;
        mac_clear, relu_en, quant_en, pool_act, pool_type_sel : out std_logic;
        add_en, addr_res, reg_done, irq_out: out std_logic
    );
end fsm_cnn_accelerator;

architecture Behavioral of fsm_cnn_accelerator is
    type state_type is ( IDLE, COMPUTE, LATCH, POST, FLUSH, DONE );

    -- Aux signals.
    signal current_state, next_state : state_type;
begin

    process( clk, reset )
    begin
        if( reset = '1' ) then
            -- Reset to the initial state.
            current_state <= IDLE;
        elsif( rising_edge( clk ) ) then
            -- Set current_state to next_state.
            current_state <= next_state;
        end if;
    end process;
    
    process( 
        current_state,
        mac_valid, 
        reg_start, 
        reg_mode, 
        pixel_done,
        reg_pool_en, 
        reg_pool_type, 
        post_done, 
        layer_done,
        reg_has_residual,
        gap_done 
    )
    begin
        -- Default values for signals.
        acc_clear       <= '0';
        addr_en         <= '0';
        mac_en          <= '0';
        mux_sel         <= '0';
        acc_bank_enable <= '0';
        mac_clear       <= '0';
        relu_en         <= '0';
        quant_en        <= '0';
        pool_act        <= '0';
        pool_type_sel   <= '0';
        add_en          <= '0';
        addr_res        <= '0';
        reg_done        <= '0';
        irq_out         <= '0';
        next_state      <= current_state;
        
        case current_state is
            when IDLE =>
                acc_clear  <= '1';
                if( reg_start = '1' ) then
                    next_state <= COMPUTE;
                else
                    next_state <= IDLE;
                end if;
            when COMPUTE =>
                addr_en <= '1';
                mac_en  <= mac_valid;
                if( reg_mode = "00" or reg_mode = "01" ) then
                    -- Set mux_sel = '0' to conv 3x3 and DW 3x3.
                    mux_sel <= '0';
                elsif( reg_mode = "10" ) then
                    -- Set mux_sel = '1' to PW 1x1.
                    mux_sel <= '1';
                end if;
                
                if( pixel_done = '1' ) then
                    next_state <= LATCH;
                else
                    next_state <= COMPUTE;
                end if;
            when LATCH => 
                acc_bank_enable <= '1';
                mac_clear <= '1';   
                next_state <= POST; 
            when POST =>
                relu_en  <= '1';
                quant_en <= '1';
                add_en   <= reg_has_residual;
                addr_res <= reg_has_residual;
                if( reg_pool_en = '1' ) then
                    -- Set pool_act = '1' and the mux who choose between maxpool and gap
                    -- is controlled by reg_pool_type.
                    pool_act <= '1';
                    pool_type_sel <= reg_pool_type;
                else
                    pool_act <= '0';
                    pool_type_sel <= '0';
                end if;
                
                if( post_done = '1' ) then
                    if( layer_done = '1' ) then
                        if( reg_pool_en = '1' and reg_pool_type = '1' ) then
                            next_state <= FLUSH;
                        else
                            next_state <= DONE;
                        end if;
                    else
                        next_state <= COMPUTE;
                    end if;
                else
                    next_state <= POST;
                end if;
            when FLUSH =>
                if( gap_done = '1' ) then
                    next_state <= DONE;
                else
                    next_state <= FLUSH;
                end if;
            when DONE =>
                reg_done <= '1';
                irq_out  <= '1';
                if( reg_start = '1' ) then
                    next_state <= IDLE;
                else
                    next_state <= DONE;
                end if;
        end case;
    end process;
end Behavioral;
