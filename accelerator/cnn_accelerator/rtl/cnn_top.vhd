library ieee;
use ieee.std_logic_1164.all;

entity cnn_top is
    port(
        clk, reset      : in std_logic;
        
        -------------------------------------------------------------
        -- AXI-Lite Slave ( Accelerator ).
        -------------------------------------------------------------
            -- AW Channel - Write Address( Master -> Slave ).
        axi_awaddr     : in  std_logic_vector( 6 downto 0 );
        axi_awvalid    : in  std_logic;
        axi_awready    : out std_logic;
            -- W Channel - Write Data ( Master -> Slave ).
        axi_wdata      : in  std_logic_vector( 31 downto 0 );
        axi_wstrb      : in  std_logic_vector( 3 downto 0 );
        axi_wvalid     : in  std_logic;
        axi_wready     : out std_logic;
            -- B Channel - Write Response ( Slave -> Master ).
        axi_bresp      : out std_logic_vector( 1 downto 0 );
        axi_bvalid     : out std_logic;
        axi_bready     : in  std_logic;
            -- AR Channel - Read Address ( Master -> Slave ).
        axi_araddr     : in  std_logic_vector( 6 downto 0 );
        axi_arvalid    : in  std_logic;
        axi_arready    : out std_logic;
            -- R Channel - Read Data ( Slave -> Master ).
        axi_rdata      : out std_logic_vector( 31 downto 0 );
        axi_rresp      : out std_logic_vector( 1 downto 0 );
        axi_rvalid     : out std_logic;
        axi_rready     : in  std_logic;
        
        -------------------------------------------------------------
        -- DMA
        -------------------------------------------------------------
        
            -- AXI-Lite ( PS -> DMA Registers Bank ).
        s_axi_awaddr   : in  std_logic_vector(  6 downto 0 );
        s_axi_awvalid  : in  std_logic;
        s_axi_awready  : out std_logic;
        s_axi_wdata    : in  std_logic_vector( 31 downto 0 );
        s_axi_wstrb    : in  std_logic_vector(  3 downto 0 );
        s_axi_wvalid   : in  std_logic;
        s_axi_wready   : out std_logic;
        s_axi_bresp    : out std_logic_vector(  1 downto 0 );
        s_axi_bvalid   : out std_logic;
        s_axi_bready   : in  std_logic;
        s_axi_araddr   : in  std_logic_vector(  6 downto 0 );
        s_axi_arvalid  : in  std_logic;
        s_axi_arready  : out std_logic;
        s_axi_rdata    : out std_logic_vector( 31 downto 0 );
        s_axi_rresp    : out std_logic_vector(  1 downto 0 );
        s_axi_rvalid   : out std_logic;
        s_axi_rready   : in  std_logic;

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
        
            -- To PS.
        dma_done        : out std_logic
    );
end cnn_top;

architecture Behavioral of cnn_top is
    
    signal reset_n : std_logic;
    
    -- Start signal to CNN Accelerator.
    signal start_dma_to_cnn      : std_logic;
    
    -- Axi Slave to CNN Accelerator.
    signal reg_mode_axi_to_cnn   : std_logic_vector( 1 downto 0 );
    signal cin_axi_to_cnn        : std_logic_vector( 6 downto 0 );
    signal max_inner_axi_to_cnn  : std_logic_vector( 9 downto 0 );
    signal max_co_axi_to_cnn     : std_logic_vector( 1 downto 0 );
    signal max_x_axi_to_cnn      : std_logic_vector( 6 downto 0 );
    signal max_y_axi_to_cnn      : std_logic_vector( 2 downto 0 );
    signal max_tile_x_axi_to_cnn : std_logic;
    signal max_tile_y_axi_to_cnn : std_logic_vector( 4 downto 0 );
    signal residual_axi_to_cnn   : std_logic;
    signal pool_en_axi_to_cnn    : std_logic;
    signal pool_type_axi_to_cnn  : std_logic;
    signal shift_axi_to_cnn      : std_logic_vector( 4 downto 0 );
    signal relu6_axi_to_cnn      : std_logic_vector( 7 downto 0 );
    signal gap_shift_axi_to_cnn  : std_logic_vector( 4 downto 0 );
    
    -- CNN Accelerator to Axi Slave.
    signal done_cnn_to_axi       : std_logic;
    
    -- DMA to CNN Accelerator.
    signal tile_ready_dma_to_cnn : std_logic;
    signal buf_sel_dma_to_cnn    : std_logic;
    signal if_wr_en_dma_to_cnn   : std_logic;
    signal if_wr_addr_dma_to_cnn : std_logic_vector(  12 downto 0 );
    signal if_wr_data_dma_to_cnn : std_logic_vector( 127 downto 0 );
    signal wb_wr_en_dma_to_cnn   : std_logic;
    signal wb_wr_addr_dma_to_cnn : std_logic_vector(   7 downto 0 );
    signal wb_wr_data_dma_to_cnn : std_logic_vector( 127 downto 0 );
    signal rb_wr_en_dma_to_cnn   : std_logic;
    signal rb_wr_addr_dma_to_cnn : std_logic_vector(  11 downto 0 );
    signal rb_wr_data_dma_to_cnn : std_logic_vector( 127 downto 0 );
    signal ob_rd_en_dma_to_cnn   : std_logic;
    signal ob_rd_addr_dma_to_cnn : std_logic_vector(  11 downto 0 );
    signal ob_rd_data_dma_to_cnn : std_logic_vector( 127 downto 0 ); 
    
    -- CNN Accelerator to DMA.
    signal tile_req_cnn_to_dma   : std_logic;
    signal irq_out_cnn_to_dma    : std_logic;
    
begin
       
    reset_n <= not reset;
    
    inst_cnn_accelerator : entity work.cnn_accelerator
        port map(
            clk                => clk,
            reset              => reset_n,
            reg_start          => start_dma_to_cnn,
            reg_mode           => reg_mode_axi_to_cnn,
            cin                => cin_axi_to_cnn,
            max_inner          => max_inner_axi_to_cnn,
            max_co             => max_co_axi_to_cnn,
            max_x              => max_x_axi_to_cnn,
            max_y              => max_y_axi_to_cnn,
            max_tile_x         => max_tile_x_axi_to_cnn,
            max_tile_y         => max_tile_y_axi_to_cnn,
            reg_has_residual   => residual_axi_to_cnn,
            reg_pool_en        => pool_en_axi_to_cnn,
            reg_pool_type      => pool_type_axi_to_cnn,
            shift              => shift_axi_to_cnn,
            relu6_val          => relu6_axi_to_cnn,
            gap_shift          => gap_shift_axi_to_cnn,
            tile_ready         => tile_ready_dma_to_cnn,
            buf_sel            => buf_sel_dma_to_cnn,
            dma_if_wr_en       => if_wr_en_dma_to_cnn,
            dma_if_wr_addr     => if_wr_addr_dma_to_cnn, 
            dma_if_wr_data     => if_wr_data_dma_to_cnn,
            dma_wb_wr_en       => wb_wr_en_dma_to_cnn,
            dma_wb_wr_addr     => wb_wr_addr_dma_to_cnn,
            dma_wb_wr_data     => wb_wr_data_dma_to_cnn,
            dma_rb_wr_en       => rb_wr_en_dma_to_cnn,
            dma_rb_wr_addr     => rb_wr_addr_dma_to_cnn,
            dma_rb_wr_data     => rb_wr_data_dma_to_cnn,
            dma_ob_rd_en       => ob_rd_en_dma_to_cnn,
            dma_ob_rd_addr     => ob_rd_addr_dma_to_cnn,
            dma_ob_rd_data     => ob_rd_data_dma_to_cnn,
            tile_req           => tile_req_cnn_to_dma,
            reg_done           => done_cnn_to_axi,
            irq_out            => irq_out_cnn_to_dma
        );
    
    inst_axi_slave : entity work.axi_lite_slave
        port map(
            axi_clk          => clk,
            axi_reset        => reset,
            axi_aw_addr      => axi_awaddr,
            axi_aw_valid     => axi_awvalid,
            axi_aw_ready     => axi_awready,
            axi_w_data       => axi_wdata,
            axi_w_strb       => axi_wstrb,
            axi_w_valid      => axi_wvalid,
            axi_w_ready      => axi_wready,
            axi_b_resp       => axi_bresp,
            axi_b_valid      => axi_bvalid,
            axi_b_ready      => axi_bready,
            axi_ar_addr      => axi_araddr,
            axi_ar_valid     => axi_arvalid,
            axi_ar_ready     => axi_arready,
            axi_r_data       => axi_rdata,
            axi_r_resp       => axi_rresp,
            axi_r_valid      => axi_rvalid,
            axi_r_ready      => axi_rready,
            reg_done         => done_cnn_to_axi,
            reg_start        => open,
            reg_mode         => reg_mode_axi_to_cnn,
            cin              => cin_axi_to_cnn,
            max_inner        => max_inner_axi_to_cnn,
            max_co           => max_co_axi_to_cnn,
            max_x            => max_x_axi_to_cnn,
            max_y            => max_y_axi_to_cnn,
            max_tile_x       => max_tile_x_axi_to_cnn,
            max_tile_y       => max_tile_y_axi_to_cnn,
            reg_has_residual => residual_axi_to_cnn,
            reg_pool_en      => pool_en_axi_to_cnn,
            reg_pool_type    => pool_type_axi_to_cnn,
            shift            => shift_axi_to_cnn,
            relu6_val        => relu6_axi_to_cnn,
            gap_shift        => gap_shift_axi_to_cnn
        );
    
    inst_dma_engine : entity work.dma_engine
        port map(
            clk             => clk,
            reset           => reset,
            s_axi_aw_addr   => s_axi_awaddr,
            s_axi_aw_valid  => s_axi_awvalid,  
            s_axi_aw_ready  => s_axi_awready,
            s_axi_w_data    => s_axi_wdata,
            s_axi_w_strb    => s_axi_wstrb,   
            s_axi_w_valid   => s_axi_wvalid,   
            s_axi_w_ready   => s_axi_wready, 
            s_axi_b_resp    => s_axi_bresp,
            s_axi_b_valid   => s_axi_bvalid,
            s_axi_b_ready   => s_axi_bready,
            s_axi_ar_addr   => s_axi_araddr,
            s_axi_ar_valid  => s_axi_arvalid,
            s_axi_ar_ready  => s_axi_arready,
            s_axi_r_data    => s_axi_rdata,
            s_axi_r_resp    => s_axi_rresp,
            s_axi_r_valid   => s_axi_rvalid,
            s_axi_r_ready   => s_axi_rready,
            m_axi_r_arid    => m_axi_r_arid,
            m_axi_r_araddr  => m_axi_r_araddr,  
            m_axi_r_arlen   => m_axi_r_arlen,   
            m_axi_r_arsize  => m_axi_r_arsize,  
            m_axi_r_arburst => m_axi_r_arburst, 
            m_axi_r_arvalid => m_axi_r_arvalid, 
            m_axi_r_arready => m_axi_r_arready, 
            m_axi_r_rid     => m_axi_r_rid,     
            m_axi_r_rdata   => m_axi_r_rdata,   
            m_axi_r_rresp   => m_axi_r_rresp,   
            m_axi_r_rlast   => m_axi_r_rlast,   
            m_axi_r_rvalid  => m_axi_r_rvalid,  
            m_axi_r_rready  => m_axi_r_rready,  
            m_axi_w_awid    => m_axi_w_awid,
            m_axi_w_awaddr  => m_axi_w_awaddr,  
            m_axi_w_awlen   => m_axi_w_awlen,   
            m_axi_w_awsize  => m_axi_w_awsize,  
            m_axi_w_awburst => m_axi_w_awburst, 
            m_axi_w_awvalid => m_axi_w_awvalid, 
            m_axi_w_awready => m_axi_w_awready, 
            m_axi_w_wdata   => m_axi_w_wdata,   
            m_axi_w_wstrb   => m_axi_w_wstrb,    
            m_axi_w_wlast   => m_axi_w_wlast,   
            m_axi_w_wvalid  => m_axi_w_wvalid,  
            m_axi_w_wready  => m_axi_w_wready,  
            m_axi_w_bid     => m_axi_w_bid,     
            m_axi_w_bresp   => m_axi_w_bresp,   
            m_axi_w_bvalid  => m_axi_w_bvalid,  
            m_axi_w_bready  => m_axi_w_bready,
            buf_sel         => buf_sel_dma_to_cnn,
            dma_if_wr_en    => if_wr_en_dma_to_cnn,
            dma_if_wr_addr  => if_wr_addr_dma_to_cnn,
            dma_if_wr_data  => if_wr_data_dma_to_cnn,
            dma_wb_wr_en    => wb_wr_en_dma_to_cnn,
            dma_wb_wr_addr  => wb_wr_addr_dma_to_cnn,
            dma_wb_wr_data  => wb_wr_data_dma_to_cnn,
            dma_rb_wr_en    => rb_wr_en_dma_to_cnn,
            dma_rb_wr_addr  => rb_wr_addr_dma_to_cnn,
            dma_rb_wr_data  => rb_wr_data_dma_to_cnn,
            dma_ob_rd_en    => ob_rd_en_dma_to_cnn,
            dma_ob_rd_addr  => ob_rd_addr_dma_to_cnn,
            dma_ob_rd_data  => ob_rd_data_dma_to_cnn,
            accel_start     => start_dma_to_cnn,
            tile_ready      => tile_ready_dma_to_cnn,
            tile_req        => tile_req_cnn_to_dma,
            irq_out         => irq_out_cnn_to_dma,
            dma_done        => dma_done
        );
    
end Behavioral;