library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dma_engine is
    port(
        clk   : in std_logic;
        reset : in std_logic; -- Low Active.

        -- AXI-Lite ( PS -> DMA Registers Bank ).
        s_axi_aw_addr  : in  std_logic_vector(  6 downto 0 );
        s_axi_aw_valid : in  std_logic;
        s_axi_aw_ready : out std_logic;
        s_axi_w_data   : in  std_logic_vector( 31 downto 0 );
        s_axi_w_strb   : in  std_logic_vector(  3 downto 0 );
        s_axi_w_valid  : in  std_logic;
        s_axi_w_ready  : out std_logic;
        s_axi_b_resp   : out std_logic_vector(  1 downto 0 );
        s_axi_b_valid  : out std_logic;
        s_axi_b_ready  : in  std_logic;
        s_axi_ar_addr  : in  std_logic_vector(  6 downto 0 );
        s_axi_ar_valid : in  std_logic;
        s_axi_ar_ready : out std_logic;
        s_axi_r_data   : out std_logic_vector( 31 downto 0 );
        s_axi_r_resp   : out std_logic_vector(  1 downto 0 );
        s_axi_r_valid  : out std_logic;
        s_axi_r_ready  : in  std_logic;

        -- AXI4 to DDR ( read ports: weights, IFM, residual ).
        m_axi_r_arid    : out std_logic_vector(  3 downto 0 );
        m_axi_r_araddr  : out std_logic_vector( 31 downto 0 );
        m_axi_r_arlen   : out std_logic_vector(  7 downto 0 );
        m_axi_r_arsize  : out std_logic_vector(  2 downto 0 );
        m_axi_r_arburst : out std_logic_vector(  1 downto 0 );
        m_axi_r_arvalid : out std_logic;
        m_axi_r_arready : in  std_logic;
        m_axi_r_rid     : in  std_logic_vector(  3 downto 0 );
        m_axi_r_rdata   : in  std_logic_vector( 63 downto 0 );
        m_axi_r_rresp   : in  std_logic_vector(  1 downto 0 );
        m_axi_r_rlast   : in  std_logic;
        m_axi_r_rvalid  : in  std_logic;
        m_axi_r_rready  : out std_logic;

        -- AXI4 to DDR ( write ports: OFM ).
        m_axi_w_awid    : out std_logic_vector(  3 downto 0 );
        m_axi_w_awaddr  : out std_logic_vector( 31 downto 0 );
        m_axi_w_awlen   : out std_logic_vector(  7 downto 0 );
        m_axi_w_awsize  : out std_logic_vector(  2 downto 0 );
        m_axi_w_awburst : out std_logic_vector(  1 downto 0 );
        m_axi_w_awvalid : out std_logic;
        m_axi_w_awready : in  std_logic;
        m_axi_w_wdata   : out std_logic_vector( 63 downto 0 );
        m_axi_w_wstrb   : out std_logic_vector(  7 downto 0 );
        m_axi_w_wlast   : out std_logic;
        m_axi_w_wvalid  : out std_logic;
        m_axi_w_wready  : in  std_logic;
        m_axi_w_bid     : in  std_logic_vector(  3 downto 0 );
        m_axi_w_bresp   : in  std_logic_vector(  1 downto 0 );
        m_axi_w_bvalid  : in  std_logic;
        m_axi_w_bready  : out std_logic;

        -- To accelerator.
        buf_sel        : out std_logic;
        dma_if_wr_en   : out std_logic;
        dma_if_wr_addr : out std_logic_vector( 12 downto 0 );
        dma_if_wr_data : out std_logic_vector( 127 downto 0 );
        dma_wb_wr_en   : out std_logic;
        dma_wb_wr_addr : out std_logic_vector(  7 downto 0 );
        dma_wb_wr_data : out std_logic_vector( 127 downto 0 );
        dma_rb_wr_en   : out std_logic;
        dma_rb_wr_addr : out std_logic_vector( 11 downto 0 );
        dma_rb_wr_data : out std_logic_vector( 127 downto 0 );
        dma_bb_wr_en   : out std_logic;
        dma_bb_wr_addr : out std_logic_vector(  3 downto 0 );
        dma_bb_wr_data : out std_logic_vector( 127 downto 0 );
        dma_ob_rd_en   : out std_logic;
        dma_ob_rd_addr : out std_logic_vector( 11 downto 0 );
        dma_ob_rd_data : in  std_logic_vector( 127 downto 0 );

        accel_start : out std_logic; -- To accelerator reg_start.
        tile_ready  : out std_logic;
        tile_req    : in  std_logic;
        irq_out     : in  std_logic;
        
        -- To PS.
        dma_done    : out std_logic
    );
end dma_engine;

architecture Behavioral of dma_engine is

    -- reg_bank -> DMA.
    signal rb_start        : std_logic;
    signal rb_mode         : std_logic_vector(  1 downto 0 );
    signal rb_cin          : std_logic_vector(  6 downto 0 );
    signal rb_cout         : std_logic_vector(  6 downto 0 );
    signal rb_img_w        : std_logic_vector(  8 downto 0 );
    signal rb_img_h        : std_logic_vector(  8 downto 0 );
    signal rb_tile_w       : std_logic_vector(  7 downto 0 );
    signal rb_tile_h       : std_logic_vector(  3 downto 0 );
    signal rb_num_tile_x   : std_logic_vector(  1 downto 0 );
    signal rb_num_tile_y   : std_logic_vector(  5 downto 0 );
    signal rb_has_residual : std_logic;
    signal rb_weight_words : std_logic_vector(  9 downto 0 );
    signal rb_addr_w       : std_logic_vector( 31 downto 0 );
    signal rb_addr_in      : std_logic_vector( 31 downto 0 );
    signal rb_addr_out     : std_logic_vector( 31 downto 0 );
    signal rb_addr_res     : std_logic_vector( 31 downto 0 );
    signal rb_pool_en      : std_logic;
    signal rb_pool_type    : std_logic;
    signal rb_bias_words   : std_logic_vector(  7 downto 0 );
    signal rb_addr_bias    : std_logic_vector( 31 downto 0 );
    signal rb_done         : std_logic;
    signal rb_stride_en    : std_logic;

    -- dma_fsm <-> ddr_addr_gen.
    signal fsm_transfer_type   : std_logic_vector(  2 downto 0 );
    signal fsm_tile_x          : std_logic_vector(  1 downto 0 );
    signal fsm_tile_y          : std_logic_vector(  5 downto 0 );
    signal fsm_r_local         : std_logic_vector(  3 downto 0 );

    signal gen_ddr_addr        : std_logic_vector( 31 downto 0 );
    signal gen_burst_words     : std_logic_vector(  9 downto 0 );
    signal gen_local_addr      : std_logic_vector( 12 downto 0 );
    signal gen_skip_ddr        : std_logic;
    signal gen_left_zero_en    : std_logic;
    signal gen_left_zero_addr  : std_logic_vector( 12 downto 0 );
    signal gen_right_zero_en   : std_logic;
    signal gen_right_zero_addr : std_logic_vector( 12 downto 0 );

    -- dma_fsm <-> axi4_read_master.
    signal fsm_rd_start     : std_logic;
    signal rd_done          : std_logic;
    signal rd_local_wr_en   : std_logic;
    signal rd_local_wr_addr : std_logic_vector( 12 downto 0 );
    signal rd_local_wr_data : std_logic_vector( 127 downto 0 );

    -- dma_fsm <-> axi4_write_master.
    signal fsm_wr_start         : std_logic;
    signal wr_done              : std_logic;
    signal fsm_gap_flush_active : std_logic;
    signal fsm_gap_ddr_addr     : std_logic_vector( 31 downto 0 );
    signal fsm_gap_burst_words  : std_logic_vector(  9 downto 0 );
    signal wr_local_rd_en   : std_logic;
    signal wr_local_rd_addr : std_logic_vector( 11 downto 0 );

    -- dma_fsm: Fill Zeros and Mux Selector.
    signal fsm_zero_fill_active : std_logic;
    signal fsm_zero_wr_en       : std_logic;
    signal fsm_zero_wr_addr     : std_logic_vector( 12 downto 0 );
    signal fsm_target_sel       : std_logic_vector(  2 downto 0 );

    -- Combined local write bus.
    signal comb_wr_en   : std_logic;
    signal comb_wr_addr : std_logic_vector( 12 downto 0 );
    signal comb_wr_data : std_logic_vector( 127 downto 0 );

    -- Final Address to Write Master ( normal o GAP_FLUSH ).
    signal wr_ddr_addr    : std_logic_vector( 31 downto 0 );
    signal wr_burst_words : std_logic_vector(  9 downto 0 );

begin

    inst_reg_bank : entity work.reg_bank
        port map(
            dma_clk          => clk,
            dma_reset        => reset,
            dma_aw_addr      => s_axi_aw_addr,
            dma_aw_valid     => s_axi_aw_valid,
            dma_aw_ready     => s_axi_aw_ready,
            dma_w_data       => s_axi_w_data,
            dma_w_strb       => s_axi_w_strb,
            dma_w_valid      => s_axi_w_valid,
            dma_w_ready      => s_axi_w_ready,
            dma_b_resp       => s_axi_b_resp,
            dma_b_valid      => s_axi_b_valid,
            dma_b_ready      => s_axi_b_ready,
            dma_ar_addr      => s_axi_ar_addr,
            dma_ar_valid     => s_axi_ar_valid,
            dma_ar_ready     => s_axi_ar_ready,
            dma_r_data       => s_axi_r_data,
            dma_r_resp       => s_axi_r_resp,
            dma_r_valid      => s_axi_r_valid,
            dma_r_ready      => s_axi_r_ready,
            dma_done         => rb_done,
            dma_start        => rb_start,
            dma_mode         => rb_mode,
            dma_cin          => rb_cin,
            dma_cout         => rb_cout,
            dma_img_w        => rb_img_w,
            dma_img_h        => rb_img_h,
            dma_tile_w       => rb_tile_w,
            dma_tile_h       => rb_tile_h,
            dma_num_tile_x   => rb_num_tile_x,
            dma_num_tile_y   => rb_num_tile_y,
            dma_has_residual => rb_has_residual,
            dma_weight_words => rb_weight_words,
            dma_addr_w       => rb_addr_w,
            dma_addr_in      => rb_addr_in,
            dma_addr_out     => rb_addr_out,
            dma_addr_res     => rb_addr_res,
            dma_pool_en      => rb_pool_en,
            dma_pool_type    => rb_pool_type,
            dma_bias_words   => rb_bias_words,
            dma_addr_bias    => rb_addr_bias,
            dma_irq          => dma_done,
            dma_stride_en    => rb_stride_en
        );

    inst_ddr_addr_gen : entity work.ddr_addr_gen
        port map(
            img_w           => rb_img_w,
            tile_w          => rb_tile_w,
            tile_h          => rb_tile_h,
            num_tile_x      => rb_num_tile_x,
            num_tile_y      => rb_num_tile_y,
            cin             => rb_cin,
            cout            => rb_cout,
            pool_en         => rb_pool_en,
            addr_in         => rb_addr_in,
            addr_out        => rb_addr_out,
            addr_w          => rb_addr_w,
            addr_res        => rb_addr_res,
            addr_bias       => rb_addr_bias,
            weight_words    => rb_weight_words,
            bias_words      => rb_bias_words,
            stride_en       => rb_stride_en,
            tile_x          => fsm_tile_x,
            tile_y          => fsm_tile_y,
            r_local         => fsm_r_local,
            transfer_type   => fsm_transfer_type,
            ddr_addr        => gen_ddr_addr,
            burst_words     => gen_burst_words,
            local_addr      => gen_local_addr,
            skip_ddr        => gen_skip_ddr,
            left_zero_en    => gen_left_zero_en,
            left_zero_addr  => gen_left_zero_addr,
            right_zero_en   => gen_right_zero_en,
            right_zero_addr => gen_right_zero_addr
        );

    inst_dma_fsm : entity work.dma_fsm
        port map(
            clk              => clk,
            reset            => reset,
            dma_start        => rb_start,
            cin              => rb_cin,
            cout             => rb_cout,
            tile_h           => rb_tile_h,
            num_tile_x       => rb_num_tile_x,
            num_tile_y       => rb_num_tile_y,
            has_residual     => rb_has_residual,
            pool_en          => rb_pool_en,
            pool_type        => rb_pool_type,
            addr_out         => rb_addr_out,
            dma_done         => rb_done,
            stride_en        => rb_stride_en,
            transfer_type    => fsm_transfer_type,
            gen_tile_x       => fsm_tile_x,
            gen_tile_y       => fsm_tile_y,
            gen_r_local      => fsm_r_local,
            skip_ddr         => gen_skip_ddr,
            left_zero_en     => gen_left_zero_en,
            right_zero_en    => gen_right_zero_en,
            gen_burst_words  => gen_burst_words,
            gen_local_addr   => gen_local_addr,
            gen_left_addr    => gen_left_zero_addr,
            gen_right_addr   => gen_right_zero_addr,
            rd_start         => fsm_rd_start,
            rd_done          => rd_done,
            wr_start         => fsm_wr_start,
            wr_done          => wr_done,
            gap_flush_active => fsm_gap_flush_active,
            gap_ddr_addr     => fsm_gap_ddr_addr,
            gap_burst_words  => fsm_gap_burst_words,
            zero_fill_active => fsm_zero_fill_active,
            zero_wr_en       => fsm_zero_wr_en,
            zero_wr_addr     => fsm_zero_wr_addr,
            target_sel       => fsm_target_sel,
            buf_sel          => buf_sel,
            accel_start      => accel_start,
            tile_ready       => tile_ready,
            tile_req         => tile_req,
            irq_out          => irq_out
        );

    inst_axi4_read_master : entity work.axi4_read_master
        port map(
            clk           => clk,
            reset         => reset,
            start         => fsm_rd_start,
            ddr_addr      => gen_ddr_addr,
            burst_words   => gen_burst_words,
            local_addr    => gen_local_addr,
            done          => rd_done,
            m_axi_arid    => m_axi_r_arid,
            m_axi_araddr  => m_axi_r_araddr,
            m_axi_arlen   => m_axi_r_arlen,
            m_axi_arsize  => m_axi_r_arsize,
            m_axi_arburst => m_axi_r_arburst,
            m_axi_arvalid => m_axi_r_arvalid,
            m_axi_arready => m_axi_r_arready,
            m_axi_rid     => m_axi_r_rid,
            m_axi_rdata   => m_axi_r_rdata,
            m_axi_rresp   => m_axi_r_rresp,
            m_axi_rlast   => m_axi_r_rlast,
            m_axi_rvalid  => m_axi_r_rvalid,
            m_axi_rready  => m_axi_r_rready,
            local_wr_en   => rd_local_wr_en,
            local_wr_addr => rd_local_wr_addr,
            local_wr_data => rd_local_wr_data
        );

    -- Address to Write Master.
    wr_ddr_addr    <= fsm_gap_ddr_addr    when fsm_gap_flush_active = '1' else gen_ddr_addr;
    wr_burst_words <= fsm_gap_burst_words when fsm_gap_flush_active = '1' else gen_burst_words;

    inst_axi4_write_master : entity work.axi4_write_master
        port map(
            clk           => clk,
            reset         => reset,
            start         => fsm_wr_start,
            ddr_addr      => wr_ddr_addr,
            burst_words   => wr_burst_words,
            local_addr    => gen_local_addr( 11 downto 0 ),
            done          => wr_done,
            m_axi_awid    => m_axi_w_awid,
            m_axi_awaddr  => m_axi_w_awaddr,
            m_axi_awlen   => m_axi_w_awlen,
            m_axi_awsize  => m_axi_w_awsize,
            m_axi_awburst => m_axi_w_awburst,
            m_axi_awvalid => m_axi_w_awvalid,
            m_axi_awready => m_axi_w_awready,
            m_axi_wdata   => m_axi_w_wdata,
            m_axi_wstrb   => m_axi_w_wstrb,
            m_axi_wlast   => m_axi_w_wlast,
            m_axi_wvalid  => m_axi_w_wvalid,
            m_axi_wready  => m_axi_w_wready,
            m_axi_bid     => m_axi_w_bid,
            m_axi_bresp   => m_axi_w_bresp,
            m_axi_bvalid  => m_axi_w_bvalid,
            m_axi_bready  => m_axi_w_bready,
            local_rd_en   => wr_local_rd_en,
            local_rd_addr => wr_local_rd_addr,
            local_rd_data => dma_ob_rd_data
        );

    -- OFBuffer.
    dma_ob_rd_en   <= wr_local_rd_en;
    dma_ob_rd_addr <= wr_local_rd_addr;

    -- Combined local write bus.
    comb_wr_en   <= fsm_zero_wr_en    when fsm_zero_fill_active = '1' else rd_local_wr_en;
    comb_wr_addr <= fsm_zero_wr_addr  when fsm_zero_fill_active = '1' else rd_local_wr_addr;
    comb_wr_data <= ( others => '0' ) when fsm_zero_fill_active = '1' else rd_local_wr_data;

    -- Routing of the combined bus to the destination buffer.
    dma_if_wr_en   <= comb_wr_en when fsm_target_sel = "000" else '0';
    dma_if_wr_addr <= comb_wr_addr;
    dma_if_wr_data <= comb_wr_data;

    dma_wb_wr_en   <= comb_wr_en when fsm_target_sel = "001" else '0';
    dma_wb_wr_addr <= comb_wr_addr( 7 downto 0 );
    dma_wb_wr_data <= comb_wr_data;

    dma_rb_wr_en   <= comb_wr_en when fsm_target_sel = "010" else '0';
    dma_rb_wr_addr <= comb_wr_addr( 11 downto 0 );
    dma_rb_wr_data <= comb_wr_data;

    dma_bb_wr_en   <= comb_wr_en when fsm_target_sel = "100" else '0';
    dma_bb_wr_addr <= comb_wr_addr( 3 downto 0 );
    dma_bb_wr_data <= comb_wr_data;

end Behavioral;