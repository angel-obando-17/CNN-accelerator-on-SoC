library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cnn_pkg.all;

entity cnn_accelerator is
    port(
        clk                : in std_logic;
        reset              : in std_logic;
        -- AXI-Lite Registers.
        reg_start          : in std_logic;
        reg_mode           : in std_logic_vector( 1 downto 0 );
        cin                : in std_logic_vector( 6 downto 0 );
        max_inner          : in std_logic_vector( 9 downto 0 );
        max_co             : in std_logic_vector( 1 downto 0 );
        max_x              : in std_logic_vector( 6 downto 0 );
        max_y              : in std_logic_vector( 2 downto 0 );
        max_tile_x         : in std_logic;
        max_tile_y         : in std_logic_vector( 4 downto 0 );
        reg_has_residual   : in std_logic;
        reg_pool_en        : in std_logic;
        reg_pool_type      : in std_logic;
        shift              : in std_logic_vector( 4 downto 0 ); -- To quant_relu
        relu6_val          : in std_logic_vector( 7 downto 0 ); -- To quant_relu
        gap_shift          : in std_logic_vector( 4 downto 0 ); -- To gap_unit
        -- DMA - IFBuffer.
        buf_sel            : in std_logic;
        dma_if_wr_en       : in std_logic;
        dma_if_wr_addr     : in std_logic_vector( 11 downto 0 ); 
        dma_if_wr_data     : in std_logic_vector( 127 downto 0 );
        -- DMA - WeightBuffer.
        dma_wb_wr_en       : in std_logic;
        dma_wb_wr_addr     : in std_logic_vector( 7 downto 0 );
        dma_wb_wr_data     : in std_logic_vector( 127 downto 0 );
        -- DMA - ResidualBuffer.
        dma_rb_wr_en       : in std_logic;
        dma_rb_wr_addr     : in std_logic_vector( 11 downto 0 );
        dma_rb_wr_data     : in std_logic_vector( 127 downto 0 );
        -- DMA - OFBuffer.
        dma_ob_rd_en       : in std_logic;
        dma_ob_rd_addr     : in std_logic_vector( 11 downto 0 );
        dma_ob_rd_data     : out std_logic_vector( 127 downto 0 );
        -- Outputs.
        reg_done           : out std_logic;
        irq_out            : out std_logic
    );
end cnn_accelerator;

architecture Behavioral of cnn_accelerator is
    -- FSM outputs
    signal sig_acc_clear      : std_logic;
    signal sig_addr_en        : std_logic;
    signal sig_mac_en         : std_logic;
    signal sig_acc_bank_en    : std_logic;
    signal sig_mac_clear      : std_logic;
    signal sig_relu_en        : std_logic;
    signal sig_quant_en       : std_logic;
    signal sig_pool_act       : std_logic;
    signal sig_pool_type_sel  : std_logic;
    signal sig_add_en         : std_logic;
    signal sig_addr_res       : std_logic;
    
    -- addr_generator outputs.
    signal ag_mac_valid       : std_logic;
    signal ag_addr_in         : std_logic_vector( 12 downto 0 );
    signal ag_addr_w          : std_logic_vector( 11 downto 0 );
    signal ag_addr_out        : std_logic_vector( 11 downto 0 );
    signal ag_byte_sel        : std_logic_vector( 3 downto 0 );
    signal ag_pixel_done      : std_logic;
    signal ag_layer_done      : std_logic;
    signal ag_co_counter      : std_logic_vector( 1 downto 0 );
    signal ag_x_counter       : std_logic_vector( 6 downto 0 );
    signal ag_y_counter       : std_logic_vector( 2 downto 0 );
    
    -- IFBuffer - InputMux.
    signal ifbuf_data_out     : std_logic_vector( 127 downto 0 );
    signal mux_act_out        : int8_array( 0 to NUM_MACS - 1 );
    
    -- WeightBuffer.
    signal wbuf_data_out      : std_logic_vector( 127 downto 0 );
    signal weight_arr         : int8_array( 0 to NUM_MACS - 1 );
    signal weight_reg         : int8_array( 0 to NUM_MACS - 1 ) := ( others => ( others => '0' ) );
    signal act_reg            : int8_array( 0 to NUM_MACS - 1 ) := ( others => ( others => '0' ) );
    -- MacArray.
    signal mac_acc_out        : int32_array( 0 to NUM_MACS - 1 );
    
    -- AccumulatorBank.
    signal acc_bank_in        : reg_array( 0 to NUM_MACS - 1 );
    signal acc_bank_out       : reg_array( 0 to NUM_MACS - 1 );
    signal acc_int32          : int32_array( 0 to NUM_MACS - 1 );
    
    -- QuantReLU6.
    signal quant_data_out     : int8_array( 0 to NUM_MACS - 1 );
    signal quant_valid        : std_logic;
    signal quant_packed       : std_logic_vector( 127 downto 0 );
    
    -- ResidualBuffer.
    signal res_data_out       : std_logic_vector( 127 downto 0 );
    signal res_arr            : int8_array( 0 to NUM_MACS - 1 );
    
    -- ADDUnit.
    signal add_data_out       : int8_array( 0 to NUM_MACS - 1 );
    signal add_packed         : std_logic_vector( 127 downto 0 );
    
    -- PoolUnit
    signal pool_data_out      : std_logic_vector( 127 downto 0 );
    signal pool_wr_en         : std_logic;
    signal pool_wr_addr       : std_logic_vector( 11 downto 0 );
    signal pool_gap_done      : std_logic;
    
    
    -- OFBuffer.
    signal ofbuf_wr_en        : std_logic;
    signal ofbuf_wr_addr      : std_logic_vector( 11 downto 0 );
    signal ofbuf_data_in      : std_logic_vector( 127 downto 0 );
    signal ofbuf_wr_addr_reg  : std_logic_vector( 11 downto 0 );
    signal quant_valid_prev   : std_logic;
        
begin

    gen_acc_in: for i in 0 to NUM_MACS - 1 generate
        acc_bank_in( i ) <= std_logic_vector( mac_acc_out( i ) );
    end generate;

    gen_acc_out: for i in 0 to NUM_MACS-1 generate
        acc_int32( i ) <= signed( acc_bank_out( i ) );
    end generate;
    
    gen_weight: for i in 0 to NUM_MACS - 1 generate
        weight_arr( i ) <= signed( wbuf_data_out( ( i * 8 ) + 7 downto ( i * 8 ) ) );
    end generate;

    gen_qpack: for i in 0 to NUM_MACS - 1 generate
        quant_packed( ( i * 8 ) + 7 downto ( i * 8 ) ) <= std_logic_vector( ( quant_data_out( i ) ) );
    end generate;
    
    gen_res: for i in 0 to NUM_MACS - 1 generate
        res_arr( i ) <= signed( res_data_out( ( i * 8 ) + 7 downto ( i * 8 ) ) );
    end generate;
    
    gen_apack: for i in 0 to NUM_MACS - 1 generate
        add_packed( ( i * 8 ) + 7 downto ( i * 8 ) ) <= std_logic_vector( add_data_out( i ) );
    end generate;
    
    -- Los datos llegan del buffer 1 ciclo despues de que addr_en los pide (latencia BRAM).
    -- mac_en se activa 1 ciclo despues de addr_en, asi que los registros alinean la
    -- llegada del dato con el ciclo en que el MAC lo consume. Sin esto el MAC acumula
    -- el dato del ciclo anterior. Lo mismo aplica para ofbuf_wr_addr: la direccion se
    -- captura en LATCH y se usa en POST, cuando ag_addr_out ya avanzo al siguiente pixel.
    -- quant_valid_prev convierte quant_valid (nivel) en un pulso de 1 ciclo para la
    -- escritura al OFBuffer y evitar escrituras duplicadas.
    process( clk )
    begin
        if rising_edge( clk ) then
            if( reset = '1' ) then
                weight_reg <= ( others => ( others => '0' ) );
                act_reg    <= ( others => ( others => '0' ) );
            elsif( sig_addr_en = '1' ) then
                weight_reg <= weight_arr;
                act_reg    <= mux_act_out;
            end if;
            quant_valid_prev  <= quant_valid;
            if( sig_acc_bank_en = '1' ) then
                ofbuf_wr_addr_reg <= ag_addr_out;
            end if;
        end if;
    end process;
        
    ofbuf_wr_en   <= pool_wr_en   when reg_pool_en = '1' else ( quant_valid and ( not quant_valid_prev ) );
    
    ofbuf_wr_addr <= pool_wr_addr when reg_pool_en = '1' else ofbuf_wr_addr_reg;
    
    ofbuf_data_in <= pool_data_out when reg_pool_en = '1' else
                     add_packed    when sig_add_en  = '1' else
                     quant_packed;

    main_fsm : entity work.fsm_cnn_accelerator
        port map(
            clk              => clk,
            reset            => reset,
            mac_valid        => ag_mac_valid,
            reg_start        => reg_start,
            reg_mode         => reg_mode,
            pixel_done       => ag_pixel_done,
            reg_pool_en      => reg_pool_en,
            reg_pool_type    => reg_pool_type,
            post_done        => quant_valid,
            layer_done       => ag_layer_done,
            reg_has_residual => reg_has_residual,
            gap_done         => pool_gap_done,
            acc_clear        => sig_acc_clear,
            addr_en          => sig_addr_en,
            mac_en           => sig_mac_en,
            mux_sel          => open,
            acc_bank_enable  => sig_acc_bank_en,
            mac_clear        => sig_mac_clear,
            relu_en          => sig_relu_en,
            quant_en         => sig_quant_en,
            pool_act         => sig_pool_act,
            pool_type_sel    => sig_pool_type_sel,
            add_en           => sig_add_en,
            addr_res         => sig_addr_res,
            reg_done         => reg_done,
            irq_out          => irq_out
        );
        
    inst_addr_generator : entity work.addr_generator
        port map(
            clk             => clk,
            reset           => reset,
            cin             => cin,
            addr_en         => sig_addr_en,
            reg_mode        => reg_mode,
            max_inner       => max_inner,
            max_co          => max_co,
            max_x           => max_x,
            max_y           => max_y,
            max_tile_x      => max_tile_x,
            max_tile_y      => max_tile_y,
            mac_valid       => ag_mac_valid,
            addr_in         => ag_addr_in,
            addr_w          => ag_addr_w,
            addr_out        => ag_addr_out,
            byte_sel        => ag_byte_sel,
            pixel_done      => ag_pixel_done,
            layer_done      => ag_layer_done,
            co_counter      => ag_co_counter,
            x_counter       => ag_x_counter,
            y_counter       => ag_y_counter,
            tile_x_counter  => open,
            tile_y_counter  => open,
            ci_out          => open,
            ky_out          => open,
            kx_out          => open
        );        
    
    inst_if_buf : entity work.inputf_buf
        port map(
            clk             => clk,
            buf_sel         => buf_sel,
            dma_wr_en       => dma_if_wr_en,
            dma_wr_addr     => dma_if_wr_addr,
            dma_wr_data     => dma_if_wr_data,
            rd_en           => sig_addr_en,
            rd_addr         => ag_addr_in( 11 downto 0 ),
            data_out        => ifbuf_data_out
        );

    inst_input_mux : entity work.input_mux
        port map(
            data_in         => ifbuf_data_out,
            byte_sel        => ag_byte_sel,
            reg_mode        => reg_mode,
            data_out        => mux_act_out
        );
        
    inst_weight_buf : entity work.weight_buf
        port map(
            clk             => clk,
            r_enable        => sig_addr_en,
            w_enable        => dma_wb_wr_en,
            rd_addr         => ag_addr_w( 7 downto 0 ),
            wr_addr         => dma_wb_wr_addr,
            data_in         => dma_wb_wr_data,
            data_out        => wbuf_data_out
        );
        
    inst_mac_array : entity work.mac_array
        port map(
            clk             => clk,
            reset           => reset,
            enable          => sig_mac_en,
            clear           => sig_mac_clear,
            weight          => weight_reg,
            act             => act_reg,
            acc_out         => mac_acc_out
        );    
    
    inst_acc_bank : entity work.accumulator_bank
        port map(
            clk             => clk,
            reset           => reset,
            enable          => sig_acc_bank_en,
            data_in         => acc_bank_in,
            data_out        => acc_bank_out
        );
        
    inst_quant_relu : entity work.quant_relu
        port map(
            clk             => clk,
            reset           => reset,
            quant_en        => sig_quant_en,
            relu_en         => sig_relu_en,
            shift           => unsigned( shift ),
            relu6_val       => signed( relu6_val ),
            acc_in          => acc_int32,
            data_out        => quant_data_out,
            valid_out       => quant_valid
        );    
        
    inst_res_buf : entity work.residual_buf
        port map(
            clk             => clk,
            r_enable        => sig_addr_res,
            w_enable        => dma_rb_wr_en,
            rd_addr         => ag_addr_out,
            wr_addr         => dma_rb_wr_addr,
            data_in         => dma_rb_wr_data,
            data_out        => res_data_out
        );        
    
    inst_add_unit : entity work.add_unit
        port map(
            data_a          => quant_data_out,
            data_b          => res_arr,
            data_out        => add_data_out
        );
    
    inst_pool_unit : entity work.pool_unit
        port map(
            clk             => clk,
            pool_act        => sig_pool_act,
            pool_type_sel   => sig_pool_type_sel,
            valid_in        => quant_valid,
            data_in         => quant_packed,
            co_counter      => ag_co_counter,
            max_co          => max_co,
            x_counter       => ag_x_counter,
            y_counter       => ag_y_counter,
            max_x           => max_x,
            layer_done      => ag_layer_done,
            acc_clear       => sig_acc_clear,
            gap_shift       => gap_shift,
            data_out        => pool_data_out,
            wr_en           => pool_wr_en,
            wr_addr         => pool_wr_addr,
            gap_done        => pool_gap_done
        );
    
    inst_of_buf : entity work.outputf_buf
        port map(
            clk             => clk,
            w_enable        => ofbuf_wr_en,
            wr_addr         => ofbuf_wr_addr,
            data_in         => ofbuf_data_in,
            r_enable        => dma_ob_rd_en,
            rd_addr         => dma_ob_rd_addr,
            data_out        => dma_ob_rd_data
        );
        
end Behavioral;
