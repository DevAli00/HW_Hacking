`timescale 1ns / 1ps

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*; 
import design_1_axi_vip_1_0_pkg::*; 

module tb();
     
  bit clock;
  bit reset_n;
  
  // VIP Agents
  design_1_axi_vip_0_0_mst_t master_agent_victim;
  design_1_axi_vip_1_0_mst_t master_agent_attacker;
   
  // Memory addresses
  xil_axi_ulong BRAM_BASE = 32'h4000_0000;
  xil_axi_ulong ATTACK_BASE = 32'h4000_2000;
  
  // Attack and victim metrics
  int attacker_outstanding = 0;
  int attacker_completed = 0;
  int victim_attempts = 0;
  int victim_success = 0;
  int victim_failures = 0;
  int victim_response_errors = 0;
  
  realtime attack_start;
  realtime total_victim_latency = 0;
  
  // Design under test
  design_1 design_1_i(
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );
  
  // 100 MHz clock (10ns period)
  always #5ns clock <= ~clock;
  
  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER THREAD: Controlled flood attack
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction wr_trans;
    bit[31:0] attack_data;
    xil_axi_resp_t resp;
    
    // Wait for reset to complete
    @(posedge reset_n);
    #500ns;
    
    attack_start = $realtime;
    $display("[ATTACK] T=%0t: Launching BUFFER OVERFLOW attack...", $time);
    
    // Continuous flood: Send transactions as fast as the VIP allows
    // This creates sustained pressure on the interconnect
    forever begin
      attack_data = 32'hBAD00000 | (attacker_outstanding & 16'hFFFF);
      
      // Use blocking send to avoid VIP FIFO overflow
      // The backpressure will naturally occur at the AXI level
      master_agent_attacker.AXI4LITE_WRITE_BURST(
        ATTACK_BASE + ((attacker_outstanding % 256) * 4),
        0,  // prot
        attack_data,
        resp
      );
      
      attacker_outstanding++;
      attacker_completed++;
      
      // Progress indicator every 100 transactions
      if (attacker_outstanding % 100 == 0) begin
        $display("[ATTACK] T=%0t: %0d transactions completed", $time, attacker_outstanding);
      end
      
      // Minimal delay to allow victim thread to compete for bus access
      #10ns;
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // VICTIM THREAD: Legitimate traffic attempting to access the bus
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    xil_axi_resp_t resp;
    bit[31:0] victim_data;
    realtime tx_start, tx_end;
    int timeout_flag;
    
    // Initialize VIP agents
    master_agent_victim = new("VICTIM", design_1_i.axi_vip_0.inst.IF);
    master_agent_attacker = new("ATTACKER", design_1_i.axi_vip_1.inst.IF);
    
    // Increase the VIP FIFO depth to prevent testbench crash
    // This allows us to measure actual interconnect behavior
    master_agent_attacker.wr_driver.set_transaction_depth(100);
    
    // Start the VIP master agents
    master_agent_victim.start_master();
    master_agent_attacker.start_master();
    
    // Apply reset sequence
    reset_n = 0;
    #200ns;
    reset_n = 1;
    
    // Wait for attack to begin flooding the bus
    #3000ns; 
    
    $display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║        AXI BUFFER OVERFLOW ATTACK - TEST START             ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ Attack Method:  Transaction flooding via sustained writes  ║");
    $display("║ Target:         AXI Interconnect arbitration & FIFOs       ║");
    $display("║ Objective:      Starve victim of bus access                ║");
    $display("╚════════════════════════════════════════════════════════════╝");
    $display("");
    
    // Attempt legitimate transactions during the attack
    repeat(10) begin
      victim_attempts++;
      victim_data = 32'hCAFE0000 | victim_attempts[15:0];
      tx_start = $realtime;
      timeout_flag = 0;
      
      $display("[VICTIM] Transaction #%0d attempting access...", victim_attempts);
      
      fork : victim_transaction
        // Branch A: Attempt the write transaction
        begin
          master_agent_victim.AXI4LITE_WRITE_BURST(
            BRAM_BASE + victim_attempts * 4,
            0,  // prot
            victim_data,
            resp
          );
          
          tx_end = $realtime;
          
          if (!timeout_flag) begin
            if (resp == XIL_AXI_RESP_OKAY) begin
              victim_success++;
              total_victim_latency += (tx_end - tx_start);
              $display("         ✓ SUCCESS (Latency: %.0f ns)", tx_end - tx_start);
            end else begin
              victim_response_errors++;
              $display("         ✗ ERROR RESPONSE: %s", resp.name());
            end
          end
        end
        
        // Branch B: Timeout watchdog
        // If interconnect FIFOs are full, transaction may stall indefinitely
        begin
          #50000ns;  // 50us timeout
          timeout_flag = 1;
          victim_failures++;
          $display("         ✗ TIMEOUT - Bus saturated / Backpressure detected");
        end
      join_any
      disable victim_transaction;
      
      // Wait before next victim attempt
      #2000ns;
    end
    
    // Print final results
    print_results();
    #100ns;
    $finish;
  end

  // ══════════════════════════════════════════════════════════════════════════
  // RESULTS REPORTING
  // ══════════════════════════════════════════════════════════════════════════
  task print_results();
    real victim_error_rate;
    real avg_latency;
    real attack_duration_us;
    
    victim_error_rate = 0;
    avg_latency = 0;
    attack_duration_us = ($realtime - attack_start) / 1000.0;
    
    if (victim_attempts > 0)
      victim_error_rate = 100.0 * (victim_failures + victim_response_errors) / victim_attempts;
      
    if (victim_success > 0)
      avg_latency = total_victim_latency / victim_success;
      
    $display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║                    ATTACK RESULTS                          ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ ATTACKER STATISTICS:                                       ║");
    $display("║   • Attack Duration:      %8.2f µs                      ║", attack_duration_us);
    $display("║   • Transactions Sent:    %8d                          ║", attacker_completed);
    $display("║   • Throughput:           %8.1f trans/µs                ║", 
             attacker_completed / attack_duration_us);
    $display("║                                                            ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ VICTIM STATISTICS:                                         ║");
    $display("║   • Total Attempts:       %8d                          ║", victim_attempts);
    $display("║   • Successful:           %8d                          ║", victim_success);
    $display("║   • Timeouts:             %8d                          ║", victim_failures);
    $display("║   • Error Responses:      %8d                          ║", victim_response_errors);
    if (victim_success > 0) begin
    $display("║   • Avg Latency:          %8.0f ns                      ║", avg_latency);
    end
    $display("║   • Failure Rate:         %7.1f %%                       ║", victim_error_rate);
    $display("║                                                            ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    
    if (victim_error_rate >= 50.0) begin
      $display("║ ✓✓✓ BUFFER OVERFLOW ATTACK SUCCESSFUL ✓✓✓                  ║");
      $display("║                                                            ║");
      $display("║ The attacker successfully saturated the interconnect,     ║");
      $display("║ causing %.0f%% of legitimate traffic to fail.              ║", victim_error_rate);
    end else if (avg_latency > 1000) begin
      $display("║ ⚠ PARTIAL SUCCESS - SIGNIFICANT LATENCY IMPACT            ║");
      $display("║                                                            ║");
      $display("║ While transactions completed, latency increased by        ║");
      $display("║ %.1fx compared to normal operation.                        ║", avg_latency / 100.0);
    end else begin
      $display("║ ✗ ATTACK INEFFECTIVE                                       ║");
      $display("║                                                            ║");
      $display("║ The interconnect handled the flood without significant    ║");
      $display("║ impact on legitimate traffic.                             ║");
    end
    
    $display("╚════════════════════════════════════════════════════════════╝");
    $display("");
  endtask
  
endmodule