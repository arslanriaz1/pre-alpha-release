
module bp_accelerator_tile
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_cce_pkg::*;
 import bp_me_pkg::*;
 import bsg_cache_pkg::*;
   import bp_be_pkg::*;
   import bsg_noc_pkg::*;
   import bp_common_cfg_link_pkg::*;
   import bsg_wormhole_router_pkg::*;
  
 #(parameter bp_params_e bp_params_p = e_bp_inv_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_lce_cce_if_widths(cce_id_width_p, lce_id_width_p, paddr_width_p, lce_assoc_p, dword_width_p, cce_block_width_p)

   , localparam coh_noc_ral_link_width_lp = `bsg_ready_and_link_sif_width(coh_noc_flit_width_p)
   , localparam io_noc_ral_link_width_lp = `bsg_ready_and_link_sif_width(io_noc_flit_width_p)
   , parameter accelerator_type_p = 1 
   )
  (input                                    clk_i
   , input                                  reset_i

   , input [coh_noc_cord_width_p-1:0]       my_cord_i
   
   , input [coh_noc_ral_link_width_lp-1:0]  lce_req_link_i
   , output [coh_noc_ral_link_width_lp-1:0] lce_req_link_o

   , input [coh_noc_ral_link_width_lp-1:0]  lce_cmd_link_i
   , output [coh_noc_ral_link_width_lp-1:0] lce_cmd_link_o

   , input [coh_noc_ral_link_width_lp-1:0]  lce_resp_link_i
   , output [coh_noc_ral_link_width_lp-1:0] lce_resp_link_o

   );

  `declare_bp_me_if(paddr_width_p, cce_block_width_p, lce_id_width_p, lce_assoc_p);
  `declare_bp_lce_cce_if(cce_id_width_p, lce_id_width_p, paddr_width_p, lce_assoc_p, dword_width_p, cce_block_width_p);

  `declare_bsg_wormhole_concentrator_packet_s(coh_noc_cord_width_p, coh_noc_len_width_p, coh_noc_cid_width_p, lce_cce_req_width_lp, lce_req_packet_s);
  `declare_bsg_wormhole_concentrator_packet_s(coh_noc_cord_width_p, coh_noc_len_width_p, coh_noc_cid_width_p, lce_cmd_width_lp, lce_cmd_packet_s);
  `declare_bsg_wormhole_concentrator_packet_s(coh_noc_cord_width_p, coh_noc_len_width_p, coh_noc_cid_width_p, lce_cce_resp_width_lp, lce_resp_packet_s);
   
  `declare_bsg_ready_and_link_sif_s(coh_noc_flit_width_p, bp_coh_ready_and_link_s);
 
  //io-cce-side connections 
  bp_lce_cce_req_s  cce_lce_req_li;
  logic cce_lce_req_v_li, cce_lce_req_yumi_lo;
  bp_lce_cmd_s cce_lce_cmd_lo;
  logic cce_lce_cmd_v_lo, cce_lce_cmd_ready_li;
  
  bp_cce_mem_msg_s cce_io_cmd_lo;
  logic cce_io_cmd_v_lo, cce_io_cmd_ready_li;
  bp_cce_mem_msg_s cce_io_resp_li;
  logic cce_io_resp_v_li, cce_io_resp_yumi_lo;

  // accelerator-side connections network connections
  bp_lce_cce_req_s  lce_req_lo;
  logic             lce_req_v_lo, lce_req_ready_li;
  bp_lce_cce_resp_s lce_resp_lo;
  logic             lce_resp_v_lo, lce_resp_ready_li;
  bp_lce_cmd_s      lce_cmd_li;
  logic             lce_cmd_v_li, lce_cmd_yumi_lo;
  bp_lce_cmd_s      lce_cmd_lo;
  logic             lce_cmd_v_lo, lce_cmd_ready_li;
   

  logic [cce_id_width_p-1:0]  cce_id_li;
  logic [lce_id_width_p-1:0]  lce_id_li;
  bp_me_cord_to_id
   #(.bp_params_p(bp_params_p))
   id_map
    (.cord_i(my_cord_i)
     ,.core_id_o()
     ,.cce_id_o(cce_id_li)
     ,.lce_id0_o(lce_id_li)
     ,.lce_id1_o()
     );

  bp_io_cce
   #(.bp_params_p(bp_params_p))
   io_cce
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.cce_id_i(cce_id_li)

     ,.lce_req_i(cce_lce_req_li)
     ,.lce_req_v_i(cce_lce_req_v_li)
     ,.lce_req_yumi_o(cce_lce_req_yumi_lo)

     ,.lce_cmd_o(cce_lce_cmd_lo)
     ,.lce_cmd_v_o(cce_lce_cmd_v_lo)
     ,.lce_cmd_ready_i(cce_lce_cmd_ready_li)

     ,.io_cmd_o(cce_io_cmd_lo)
     ,.io_cmd_v_o(cce_io_cmd_v_lo)
     ,.io_cmd_ready_i(cce_io_cmd_ready_li)

     ,.io_resp_i(cce_io_resp_li)
     ,.io_resp_v_i(cce_io_resp_v_li)
     ,.io_resp_yumi_o(cce_io_resp_yumi_lo)
     );


////////////////////////////////////////////////////////////////////
  lce_req_packet_s lce_req_packet_li, lce_req_packet_lo;
  bp_me_wormhole_packet_encode_lce_req
   #(.bp_params_p(bp_params_p))
   req_encode
    (.payload_i(lce_req_lo)
     ,.packet_o(lce_req_packet_lo)
     );

  bsg_wormhole_router_adapter
   #(.max_payload_width_p($bits(lce_req_packet_s)-coh_noc_cord_width_p-coh_noc_len_width_p)
     ,.len_width_p(coh_noc_len_width_p)
     ,.cord_width_p(coh_noc_cord_width_p)
     ,.flit_width_p(coh_noc_flit_width_p)
     )
   lce_req_adapter
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.packet_i(lce_req_packet_lo)
     ,.v_i(lce_req_v_lo)
     ,.ready_o(lce_req_ready_li)

     ,.link_i(lce_req_link_i)
     ,.link_o(lce_req_link_o)

     ,.packet_o(lce_req_packet_li)
     ,.v_o(cce_lce_req_v_li)
     ,.yumi_i(cce_lce_req_yumi_lo)
     );
   assign cce_lce_req_li = lce_req_packet_li.payload;

  lce_resp_packet_s lce_resp_packet_lo;
  bp_me_wormhole_packet_encode_lce_resp
    #(.bp_params_p(bp_params_p))
    resp_encode
      (.payload_i(lce_resp_lo)
       ,.packet_o(lce_resp_packet_lo)
       );

  bsg_wormhole_router_adapter_in
    #(.max_payload_width_p($bits(lce_resp_packet_s)-coh_noc_cord_width_p-coh_noc_len_width_p)
      ,.len_width_p(coh_noc_len_width_p)
      ,.cord_width_p(coh_noc_cord_width_p)
      ,.flit_width_p(coh_noc_flit_width_p)
      )
    lce_resp_adapter_in
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.packet_i(lce_resp_packet_lo)
     ,.v_i(lce_resp_v_lo)
     ,.ready_o(lce_resp_ready_li)

     ,.link_i(lce_resp_link_i)
     ,.link_o(lce_resp_link_o)
     );


    bp_coh_ready_and_link_s lce_cmd_link_li, lce_cmd_link_lo;
    bp_coh_ready_and_link_s cce_lce_cmd_link_li, cce_lce_cmd_link_lo;  
    lce_cmd_packet_s lce_cmd_packet_li, lce_cmd_packet_lo;
    bp_me_wormhole_packet_encode_lce_cmd
     #(.bp_params_p(bp_params_p))
     cmd_encode
      (.payload_i(lce_cmd_lo)
       ,.packet_o(lce_cmd_packet_lo)
       );

    bsg_wormhole_router_adapter
     #(.max_payload_width_p($bits(lce_cmd_packet_s)-coh_noc_cord_width_p-coh_noc_len_width_p)
       ,.len_width_p(coh_noc_len_width_p)
       ,.cord_width_p(coh_noc_cord_width_p)
       ,.flit_width_p(coh_noc_flit_width_p)
       )
     cmd_adapter
      (.clk_i(clk_i)
       ,.reset_i(reset_i)

       ,.packet_i(lce_cmd_packet_lo)
       ,.v_i(lce_cmd_v_lo)
       ,.ready_o(lce_cmd_ready_li)

       ,.link_i(lce_cmd_link_li)
       ,.link_o(lce_cmd_link_lo)

       ,.packet_o(lce_cmd_packet_li)
       ,.v_o(lce_cmd_v_li)
       ,.yumi_i(lce_cmd_yumi_lo)
       );
    assign lce_cmd_li = lce_cmd_packet_li.payload;


   
  lce_cmd_packet_s cce_lce_cmd_packet_lo;
  bp_me_wormhole_packet_encode_lce_cmd
   #(.bp_params_p(bp_params_p))
   cce_cmd_encode
    (.payload_i(cce_lce_cmd_lo)
     ,.packet_o(cce_lce_cmd_packet_lo)
     );
  bsg_wormhole_router_adapter_in
   #(.max_payload_width_p($bits(lce_cmd_packet_s)-coh_noc_cord_width_p-coh_noc_len_width_p)
     ,.len_width_p(coh_noc_len_width_p)
     ,.cord_width_p(coh_noc_cord_width_p)
     ,.flit_width_p(coh_noc_flit_width_p)
     )
    cce_lce_cmd_adapter_in
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.packet_i(cce_lce_cmd_packet_lo)
     ,.v_i(cce_lce_cmd_v_lo)
     ,.ready_o(cce_lce_cmd_ready_li)

     ,.link_i(cce_lce_cmd_link_li)
     ,.link_o(cce_lce_cmd_link_lo)
     );


  bp_coh_ready_and_link_s lce_cmd_link_cast_i, lce_cmd_link_cast_o;
  bp_coh_ready_and_link_s cmd_concentrated_link_li, cmd_concentrated_link_lo;
  
  assign lce_cmd_link_cast_i  = lce_cmd_link_i;
  assign lce_cmd_link_o  = lce_cmd_link_cast_o;
  assign cmd_concentrated_link_li = lce_cmd_link_cast_i;
  assign lce_cmd_link_cast_o = cmd_concentrated_link_lo;
    
  bsg_wormhole_concentrator
   #(.flit_width_p(coh_noc_flit_width_p)
     ,.len_width_p(coh_noc_len_width_p)
     ,.cid_width_p(coh_noc_cid_width_p)
     ,.num_in_p(2)
     ,.cord_width_p(coh_noc_cord_width_p)
     )
   cmd_concentrator
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.links_i({cce_lce_cmd_link_lo, lce_cmd_link_lo})
     ,.links_o({cce_lce_cmd_link_li, lce_cmd_link_li})

     ,.concentrated_link_i(cmd_concentrated_link_li)
     ,.concentrated_link_o(cmd_concentrated_link_lo)
     );


////////////////////////////////////////////////////////////////
  logic [io_noc_did_width_p-1:0]  dst_did_lo;
  logic [io_noc_cord_width_p-1:0] dst_cord_lo;

  bp_global_addr_s global_addr_lo;
  bp_local_addr_s  local_addr_lo;

  assign global_addr_lo = cce_io_cmd_lo.addr;
  assign local_addr_lo  = cce_io_cmd_lo.addr;

  wire is_host_addr  = (~local_addr_lo.nonlocal && (local_addr_lo.dev == host_dev_gp));
  assign dst_did_lo  = is_host_addr ? '1 : global_addr_lo.did;
  assign dst_cord_lo = dst_did_lo;

 
  bp_accelerator_example
   #(.bp_params_p(bp_params_p))
   accelerator_link
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.lce_id_i(lce_id_li)
     ,.my_cord_i(my_cord_i)
     ,.io_cmd_i(cce_io_cmd_lo)
     ,.io_cmd_v_i(cce_io_cmd_v_lo)
     ,.io_cmd_ready_o(cce_io_cmd_ready_li)

     ,.io_resp_o(cce_io_resp_li)
     ,.io_resp_v_o(cce_io_resp_v_li)
     ,.io_resp_yumi_i(cce_io_resp_yumi_lo)

     ,.lce_req_o(lce_req_lo)
     ,.lce_req_v_o(lce_req_v_lo)
     ,.lce_req_ready_i(lce_req_ready_li)

     ,.lce_cmd_o(lce_cmd_lo)
     ,.lce_cmd_v_o(lce_cmd_v_lo)
     ,.lce_cmd_ready_i(lce_cmd_ready_li)

     ,.lce_resp_o(lce_resp_lo)
     ,.lce_resp_v_o(lce_resp_v_lo)
     ,.lce_resp_ready_i(lce_resp_ready_li)

     ,.lce_cmd_i(lce_cmd_li)
     ,.lce_cmd_v_i(lce_cmd_v_li)
     ,.lce_cmd_yumi_o(lce_cmd_yumi_lo)

     );


endmodule

