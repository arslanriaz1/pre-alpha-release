/**
 *
 * Name:
 *   bp_be_director.v
 * 
 * Description:
 *   Directs the PC for the FE and the calculator. Keeps track of the next PC
 *     and sends redirect signals to the FE when a misprediction is detected.
 *
 * Parameters:
 *   vaddr_width_p               - FE-BE structure sizing parameter
 *   paddr_width_p               - ''
 *   asid_width_p                - ''
 *   branch_metadata_fwd_width_p - ''
 * 
 * Inputs:
 *   clk_i                       -
 *   reset_i                     -
 *
 *   calc_status_i               - Instruction dependency information from the calculator
 *   expected_npc_o              - The expected npc (PC after the instruction in ex1) based on 
 *                                   branching information
 *   
 * Outputs:
 *   fe_cmd_o                    - FE cmd, handling pc redirection and attaboys, 
 *                                   among other things.
 *   fe_cmd_v_o                  - "ready-then-valid"
 *   fe_cmd_ready_i              -
 *  
 *   chk_flush_fe_o              - Command to flush the fe_queue (on mispredict)
 *   chk_dequeue_fe_o            - Increments the fe_queue checkpoint when an instruction commits
 *   chk_roll_fe_o               - Command to rollback the fe_queue to the last checkpoint
 *   
 *
 * Keywords:
 * 
 * Notes:
 *   We don't need the entirety of the calc_status structure here, but for simplicity 
 *     we pass it all. If the compiler doesn't flatten and optimize, we can do it ourselves.
 *   Branch_metadata should come from the target instruction, not the branch instruction,
 *     eliminating the need to store this in the BE
 *   We don't currently support MTVAL or EPC, so error muxes are disconnected
 *   FE cmd adapter could be split into a separate module
 */

module bp_be_director 
 import bp_common_pkg::*;
 import bp_be_rv64_pkg::*;
 import bp_be_pkg::*;
 #(parameter vaddr_width_p                 = "inv"
   , parameter paddr_width_p               = "inv"
   , parameter asid_width_p                = "inv"
   , parameter branch_metadata_fwd_width_p = "inv"

   // Generated parameters
   , localparam calc_status_width_lp = `bp_be_calc_status_width(vaddr_width_p, branch_metadata_fwd_width_p)
   , localparam fe_cmd_width_lp      = `bp_fe_cmd_width(vaddr_width_p
                                                        , paddr_width_p
                                                        , asid_width_p
                                                        , branch_metadata_fwd_width_p
                                                        )
   // From BE specifications
   , localparam pc_entry_point_lp = bp_pc_entry_point_gp
   // From RISC-V specifications
   , localparam reg_data_width_lp = rv64_reg_data_width_gp
   , localparam reg_addr_width_lp = rv64_reg_addr_width_gp
   , localparam eaddr_width_lp    = rv64_eaddr_width_gp
      // VM parameters
   , localparam vtag_width_lp     = (vaddr_width_p-bp_page_offset_width_gp)
   , localparam ptag_width_lp     = (paddr_width_p-bp_page_offset_width_gp)
   , localparam tlb_entry_width_lp = `bp_be_tlb_entry_width(ptag_width_lp)
   )
  (input                               clk_i
   , input                             reset_i

   // Dependency information
   , input [calc_status_width_lp-1:0]  calc_status_i
   , output [eaddr_width_lp-1:0]       expected_npc_o

   // FE-BE interface
   , output [fe_cmd_width_lp-1:0]      fe_cmd_o
   , output                            fe_cmd_v_o
   , input                             fe_cmd_ready_i

   // FE cmd queue control signals
   , output                            chk_flush_fe_o
   , output                            chk_dequeue_fe_o
   , output                            chk_roll_fe_o

   // CSR interface
   , input [reg_data_width_lp-1:0]    mtvec_i
   , input [reg_data_width_lp-1:0]    mepc_i
   
   //iTLB fill interface
   , input                           itlb_fill_v_i
   , input [vtag_width_lp-1:0]       itlb_fill_vtag_i
   , input [tlb_entry_width_lp-1:0]  itlb_fill_entry_i
  );

// Declare parameterized structures
`declare_bp_fe_be_if(vaddr_width_p
                                    , paddr_width_p
                                    , asid_width_p
                                    , branch_metadata_fwd_width_p
                                    );
`declare_bp_be_internal_if_structs(vaddr_width_p
                                   , paddr_width_p
                                   , asid_width_p
                                   , branch_metadata_fwd_width_p
                                   ); 

// Cast input and output ports 
bp_be_calc_status_s              calc_status;
bp_fe_cmd_s                      fe_cmd;
logic                            fe_cmd_v;
bp_fe_cmd_pc_redirect_operands_s fe_cmd_pc_redirect_operands;
bp_fe_cmd_reset_operands_s       fe_cmd_reset_operands;
bp_fe_cmd_attaboy_s              fe_cmd_attaboy;

assign calc_status = calc_status_i;
assign fe_cmd_o    = fe_cmd;
assign fe_cmd_v_o  = fe_cmd_v;

// Declare intermediate signals
logic [eaddr_width_lp-1:0]              npc_plus4;
logic [eaddr_width_lp-1:0]              npc_n, npc_r;
logic                                   npc_mismatch_v;
logic [branch_metadata_fwd_width_p-1:0] branch_metadata_fwd_r;
logic [reg_data_width_lp-1:0]           mepc_mux_lo;

// Logic for handling coming out of reset
enum bit [1:0] {e_reset, e_boot, e_run} state_n, state_r;

// Control signals
logic npc_w_v, btaken_v, redirect_pending, attaboy_pending;

logic [eaddr_width_lp-1:0] br_mux_o, roll_mux_o, ret_mux_o;

// Module instantiations
// Update the NPC on a valid instruction in ex1 or a cache miss or a tlb miss
assign npc_w_v = (calc_status.ex1_instr_v & ~npc_mismatch_v) 
                 | (calc_status.mem3_cache_miss_v)
                 | (calc_status.mem3_tlb_miss_v)
                 | (calc_status.mem3_exception_v)
                 | (calc_status.mem3_ret_v);
bsg_dff_reset_en 
 #(.width_p(eaddr_width_lp)
   ,.reset_val_p(pc_entry_point_lp)     
   ) 
 npc
  (.clk_i(clk_i)
   ,.reset_i(reset_i)
   ,.en_i(npc_w_v)
  
   ,.data_i(npc_n)
   ,.data_o(npc_r)
   );

// NPC calculation
bsg_mux 
 #(.width_p(eaddr_width_lp)
   ,.els_p(2)   
   )
 exception_mux
  (.data_i({ret_mux_o, roll_mux_o})
   ,.sel_i(calc_status.mem3_exception_v | calc_status.mem3_ret_v)
   ,.data_o(npc_n)
   );

bsg_mux 
 #(.width_p(eaddr_width_lp)
   ,.els_p(2)
   )
 roll_mux
  (.data_i({calc_status.mem3_pc, br_mux_o})
   ,.sel_i(calc_status.mem3_cache_miss_v | calc_status.mem3_tlb_miss_v)
   ,.data_o(roll_mux_o)
   );

assign npc_plus4 = npc_r + eaddr_width_lp'(4);
assign btaken_v  = calc_status.int1_v & calc_status.int1_btaken;
bsg_mux 
 #(.width_p(eaddr_width_lp)
   ,.els_p(2)
   )
 br_mux
  (.data_i({calc_status.int1_br_tgt, npc_plus4})
   ,.sel_i(btaken_v)
   ,.data_o(br_mux_o)
   );

bsg_mux 
 #(.width_p(eaddr_width_lp)
   ,.els_p(2)
   )
 ret_mux
  /* TODO: MTVEC is not actually the 64 bit address, it's a subset of them where the
   *         last few bits are the vectorization mode 
   */
  (.data_i({mepc_i, mtvec_i})
   ,.sel_i(calc_status.mem3_ret_v)
   ,.data_o(ret_mux_o)
   );

// A redirect is pending until the correct instruction has been fetched. Otherwise, we'll 
//   keep on sending redirects...
assign npc_mismatch_v = (expected_npc_o != calc_status.ex1_pc);
bsg_dff_reset_en
 #(.width_p(1))
 redirect_pending_reg
  (.clk_i(clk_i)
   ,.reset_i(reset_i)
   ,.en_i(calc_status.ex1_instr_v)

   ,.data_i(npc_mismatch_v)
   ,.data_o(redirect_pending)
   );

// Last operation was branch. Was it successful? Let's find out
bsg_dff_reset_en
 #(.width_p(1))
 attaboy_pending_reg
  (.clk_i(clk_i)
   ,.reset_i(reset_i)
   ,.en_i(calc_status.ex1_instr_v)

   ,.data_i(calc_status.int1_br_or_jmp)
   ,.data_o(attaboy_pending)
   );

// Generate control signals
assign expected_npc_o = npc_r;
// Increment the checkpoint if there's a committing instruction
assign chk_dequeue_fe_o = ~calc_status.mem3_cache_miss_v & ~calc_status.mem3_tlb_miss_v & calc_status.instr_cmt_v;
// Flush the FE queue if there's a pc redirect
assign chk_flush_fe_o = fe_cmd_v & (fe_cmd.opcode == e_op_pc_redirection);
// Rollback the FE queue on a cache miss
assign chk_roll_fe_o  = calc_status.mem3_cache_miss_v | calc_status.mem3_tlb_miss_v;

// Boot logic 
always_comb
  begin
    unique casez (state_r)
      e_reset : state_n = e_boot;
      e_boot  : state_n = fe_cmd_v ? e_run : e_boot;
      e_run   : state_n = e_run;
      default : state_n = e_reset;
    endcase
  end

always_ff @(posedge clk_i) 
  begin
    if (reset_i)
        state_r <= e_reset;
    else
      begin
        state_r <= state_n;
      end
  end

always_comb 
  begin : fe_cmd_adapter
    fe_cmd = 'b0;
    fe_cmd_v = 1'b0;
    fe_cmd_pc_redirect_operands = '0;

    // Send one reset cmd on boot
    if (state_r == e_boot) 
      begin : fe_reset
        fe_cmd.opcode = e_op_state_reset;
        fe_cmd_reset_operands.pc = npc_r;

        fe_cmd.operands.reset_operands = fe_cmd_reset_operands;
        fe_cmd_v = fe_cmd_ready_i;
      end
    // Redirect the pc if there's an NPC mismatch
    else if(calc_status.ex1_instr_v & npc_mismatch_v) 
      begin : pc_redirect
        fe_cmd.opcode                                   = e_op_pc_redirection;
        fe_cmd_pc_redirect_operands.pc                  = expected_npc_o;
        fe_cmd_pc_redirect_operands.subopcode           = e_subop_branch_mispredict;
        fe_cmd_pc_redirect_operands.branch_metadata_fwd =  calc_status.int1_branch_metadata_fwd;

        fe_cmd_pc_redirect_operands.misprediction_reason = calc_status.int1_br_or_jmp 
                                                           ? e_incorrect_prediction 
                                                           : e_not_a_branch;

        fe_cmd.operands.pc_redirect_operands = fe_cmd_pc_redirect_operands;

        fe_cmd_v = fe_cmd_ready_i & ~chk_roll_fe_o & ~redirect_pending;
      end 
    // Send an attaboy if there's a correct prediction
    else if(calc_status.ex1_instr_v & ~npc_mismatch_v & attaboy_pending) 
      begin : attaboy
        fe_cmd.opcode                      = e_op_attaboy;
        fe_cmd_attaboy.pc                  = calc_status.ex1_pc;
        fe_cmd_attaboy.branch_metadata_fwd = calc_status.int1_branch_metadata_fwd;

        fe_cmd.operands.attaboy = fe_cmd_attaboy;

        fe_cmd_v = fe_cmd_ready_i & ~chk_roll_fe_o & ~redirect_pending;
      end
    else if(itlb_fill_v_i)
      begin
        fe_cmd.opcode = e_op_itlb_fill_response;
        fe_cmd.operands.itlb_fill_response.vaddr = {itlb_fill_vtag_i, bp_page_offset_width_gp'(0)};
        fe_cmd.operands.itlb_fill_response.pte_entry_leaf = itlb_fill_entry_i;
      
        fe_cmd_v = fe_cmd_ready_i & ~chk_roll_fe_o;
      end
  end
endmodule : bp_be_director

