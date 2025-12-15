`timescale 1ns / 1ps

// ════════════════════════════════════════════════════════════════════════════
// AXI DoS ATTACK PROOF OF CONCEPT
// ════════════════════════════════════════════════════════════════════════════
// Demonstrates a Denial of Service attack on AXI interconnect by forcing
// AWVALID/WVALID signals HIGH, monopolizing bus arbitration and causing
// legitimate transactions to timeout (packet loss).
//
// Attack Strategy:
// - Continuously assert AWVALID/WVALID without waiting for READY
// - Request maximum burst length (256 beats)
// - Never assert WLAST to prevent transaction completion
// - Starve legitimate traffic of bus access
// ════════════════════════════════════════════════════════════════════════════

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*; 
import design_1_axi_vip_1_0_pkg::*; 

module tb();
     
  bit clock;
  bit reset_n;
  bit attack_enable = 0;  // Control flag for attack
  
  design_1_axi_vip_0_0_mst_t master_agent_victim;
  // Note: Don't create VIP agent for attacker - we'll use raw signals
   
  // Memory map
  xil_axi_ulong BRAM_BASE = 32'h4000_0000;
  xil_axi_ulong ATTACK_ADDR = 32'h4000_1000;
  
  // Metrics
  int victim_attempts = 0;
  int victim_success = 0;
  int victim_timeout = 0;
  int attacker_cycles = 0;
  realtime attack_start_time;
  realtime total_victim_latency = 0;
  
  // Design under test
  design_1 design_1_i(
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );
  
  // Clock: 100 MHz (10ns period)
  always #5ns clock <= ~clock;
  
  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER THREAD: Raw signal manipulation (NO VIP AGENT)
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    // Wait for attack enable signal from main thread
    wait(attack_enable);
    
    attack_start_time = $realtime;
    $display("[ATTACK] T=%0t: Initiating bus hijacking...", $time);
    
    // Continuously force AXI write channels to VALID state
    forever begin
      @(posedge clock);
      
      if (!attack_enable) begin
        // Release all forced signals when attack disabled
        release design_1_i.axi_vip_1.inst.IF.AWVALID;
        release design_1_i.axi_vip_1.inst.IF.AWADDR;
        release design_1_i.axi_vip_1.inst.IF.AWLEN;
        release design_1_i.axi_vip_1.inst.IF.AWSIZE;
        release design_1_i.axi_vip_1.inst.IF.AWBURST;
        release design_1_i.axi_vip_1.inst.IF.AWID;
        release design_1_i.axi_vip_1.inst.IF.WVALID;
        release design_1_i.axi_vip_1.inst.IF.WDATA;
        release design_1_i.axi_vip_1.inst.IF.WSTRB;
        release design_1_i.axi_vip_1.inst.IF.WLAST;
        release design_1_i.axi_vip_1.inst.IF.BREADY;
        break;
      end
      
      // ═══ Address Write Channel ═══
      force design_1_i.axi_vip_1.inst.IF.AWVALID = 1'b1;
      force design_1_i.axi_vip_1.inst.IF.AWADDR = ATTACK_ADDR;
      force design_1_i.axi_vip_1.inst.IF.AWLEN = 8'd255;
      force design_1_i.axi_vip_1.inst.IF.AWSIZE = 3'd2;
      force design_1_i.axi_vip_1.inst.IF.AWBURST = 2'd1;
      force design_1_i.axi_vip_1.inst.IF.AWID = 4'd0;
      
      // ═══ Write Data Channel ═══
      force design_1_i.axi_vip_1.inst.IF.WVALID = 1'b1;
      force design_1_i.axi_vip_1.inst.IF.WDATA = 32'hDEAD_BEEF;
      force design_1_i.axi_vip_1.inst.IF.WSTRB = 4'hF;
      force design_1_i.axi_vip_1.inst.IF.WLAST = 1'b0;  // Never complete!
      
      // ═══ Response Channel ═══
      force design_1_i.axi_vip_1.inst.IF.BREADY = 1'b1;
      
      // Also block the read channels to maximize DoS effect
      force design_1_i.axi_vip_1.inst.IF.ARVALID = 1'b1;
      force design_1_i.axi_vip_1.inst.IF.ARADDR = ATTACK_ADDR;
      force design_1_i.axi_vip_1.inst.IF.ARLEN = 8'd255;
      force design_1_i.axi_vip_1.inst.IF.RREADY = 1'b0;  // Never accept read data
      
      attacker_cycles++;
      
      if(attacker_cycles % 1000 == 0) begin
        $display("[ATTACK] T=%0t: Bus held for %0d cycles", $time, attacker_cycles);
      end
    end
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // MAIN CONTROL THREAD
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    xil_axi_resp_t resp;
    bit[31:0] data;
    realtime tx_start, tx_end;
    int timeout_flag;
    
    // Initialize ONLY the victim VIP agent
    master_agent_victim = new("LEGITIMATE_USER", design_1_i.axi_vip_0.inst.IF);
    master_agent_victim.start_master();
    
    // System reset
    reset_n = 0;
    #200ns;
    reset_n = 1;
    #500ns;
    
    $display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║         AXI INTERCONNECT DoS ATTACK - PROOF OF CONCEPT     ║");
    $display("╚════════════════════════════════════════════════════════════╝");
    $display("");
    
    // Enable attack BEFORE victim transactions
    attack_enable = 1;
    #1000ns;
    
    $display("[VICTIM] T=%0t: Attempting legitimate transactions...\n", $time);
    
    repeat(8) begin
      victim_attempts++;
      data = 32'hCAFE_0000 | victim_attempts[15:0];
      tx_start = $realtime;
      timeout_flag = 0;
      
      $display("[VICTIM] Transaction #%0d → Addr: 0x%08h", 
               victim_attempts, BRAM_BASE + victim_attempts * 4);
      
      fork : tx_block
        // Transaction attempt
        begin
          master_agent_victim.AXI4LITE_WRITE_BURST(
            BRAM_BASE + victim_attempts * 4,
            0,
            data,
            resp
          );
          tx_end = $realtime;
          if (!timeout_flag) begin
            victim_success++;
            total_victim_latency += (tx_end - tx_start);
            $display("         ✓ SUCCESS (%.0f ns)\n", tx_end - tx_start);
          end
        end
        
        // Timeout detector
        begin
          #20000ns;
          timeout_flag = 1;
          victim_timeout++;
          $display("         ✗ TIMEOUT - PACKET LOST\n");
        end
      join_any
      disable tx_block;
      
      #3000ns;
    end
    
    // Disable attack for clean shutdown
    attack_enable = 0;
    #1000ns;
    
    print_results();
    
    #100ns;
    $finish;
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // Results reporting task
  // ══════════════════════════════════════════════════════════════════════════
  task print_results();
    real attack_duration_us;
    real packet_loss_rate;
    real avg_latency_ns;
    
    attack_duration_us = ($realtime - attack_start_time) / 1000.0;
    
    if(victim_attempts > 0) begin
      packet_loss_rate = 100.0 * victim_timeout / victim_attempts;
    end
    
    if(victim_success > 0) begin
      avg_latency_ns = total_victim_latency / victim_success;
    end
    
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║                  DoS ATTACK ANALYSIS                       ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║                                                            ║");
    $display("║ ATTACKER METRICS:                                          ║");
    $display("║   • Attack Duration:       %10.2f µs                   ║", attack_duration_us);
    $display("║   • Bus Cycles Held:       %10d                        ║", attacker_cycles);
    $display("║   • Control Rate:          %10d cycles/µs              ║", 
             int(attacker_cycles / attack_duration_us));
    $display("║                                                            ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║                                                            ║");
    $display("║ VICTIM METRICS:                                            ║");
    $display("║   • Total Attempts:        %10d                        ║", victim_attempts);
    $display("║   • Successful:            %10d                        ║", victim_success);
    $display("║   • Timed Out (Lost):      %10d                        ║", victim_timeout);
    
    if(victim_success > 0) begin
      $display("║   • Avg Latency:           %10.0f ns                   ║", avg_latency_ns);
    end
    
    $display("║   • Packet Loss Rate:      %9.1f %%                    ║", packet_loss_rate);
    $display("║                                                            ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    
    if(packet_loss_rate >= 50.0) begin
      $display("║                                                            ║");
      $display("║ ✓✓✓ DoS ATTACK HIGHLY EFFECTIVE ✓✓✓                       ║");
      $display("║                                                            ║");
      $display("║ The attacker successfully monopolized the AXI bus,        ║");
      $display("║ causing %.0f%% of legitimate traffic to be dropped.        ║", packet_loss_rate);
      $display("║                                                            ║");
      $display("║ NEXT STEPS:                                                ║");
      $display("║ → Design security wrapper to detect/mitigate attack       ║");
      $display("║ → Implement traffic monitoring & rate limiting            ║");
      $display("║ → Add arbitration fairness mechanisms                     ║");
      $display("║                                                            ║");
    end else if(packet_loss_rate > 0) begin
      $display("║                                                            ║");
      $display("║ ⚠ PARTIAL DoS SUCCESS                                     ║");
      $display("║ Some packets lost but interconnect shows resilience       ║");
      $display("║                                                            ║");
    end else begin
      $display("║                                                            ║");
      $display("║ ✗ DoS ATTACK INEFFECTIVE                                  ║");
      $display("║ Interconnect successfully handled all traffic             ║");
      $display("║                                                            ║");
    end
    
    $display("╚════════════════════════════════════════════════════════════╝");
  endtask
  
endmodule