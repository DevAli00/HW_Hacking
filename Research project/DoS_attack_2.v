`timescale 1ns / 1ps

// ════════════════════════════════════════════════════════════════════════════
// AXI DoS ATTACK - READ CHANNEL FLOODING
// ════════════════════════════════════════════════════════════════════════════
// Attack demonstration:
// - Attacker floods read requests with incrementing IDs and addresses
// - Crossbar FIFO fills up to capacity
// - Victim requests get starved/delayed
// ════════════════════════════════════════════════════════════════════════════

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*; 
import design_1_axi_vip_1_0_pkg::*; 

module tb();
     
  bit clock;
  bit reset_n;
  
  // VIP Agents
  design_1_axi_vip_0_0_mst_t victim_agent;    // Legitimate user (victim)
  design_1_axi_vip_1_0_mst_t attacker_agent;  // Malicious user (attacker)
   
  // Memory map
  xil_axi_ulong BRAM_BASE = 32'h4000_0000;
  xil_axi_ulong ATTACKER_TARGET_ADDR = 32'h4000_1000;  // Attacker's target region
  xil_axi_ulong VICTIM_TARGET_ADDR = 32'h4000_0000;    // Victim's target region
  
  // Metrics
  int attacker_requests_sent = 0;
  int attacker_responses_received = 0;
  int victim_attempts = 0;
  int victim_success = 0;
  int victim_timeout = 0;
  
  realtime attack_start_time;
  realtime total_victim_latency = 0;
  realtime victim_latencies[$];  // Store individual latencies
  
  // Control flags
  bit attack_running = 0;
  
  // Design under test
  design_1 design_1_i(
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );
  
  // Clock: 100 MHz (10ns period)
  always #5ns clock <= ~clock;
  
  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER: Read request flooding
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction rd_trans;
    bit[31:0] read_data;
    xil_axi_resp_t resp;
    xil_axi_ulong current_addr;
    
    // Wait for attack enable
    wait(attack_running);
    
    attack_start_time = $realtime;
    $display("[ATTACKER] T=%0t: Initiating READ FLOOD attack...", $time);
    
    // Flood read requests as fast as possible
    forever begin
      if (!attack_running) break;
      
      // Calculate address with incrementing pattern
      current_addr = ATTACKER_TARGET_ADDR + ((attacker_requests_sent % 256) * 4);
      
      // Send read request - this creates real AXI traffic
      fork
        begin
          attacker_agent.AXI4LITE_READ_BURST(
            current_addr,
            0,  // prot
            read_data,
            resp
          );
          attacker_responses_received++;
        end
      join_none
      
      attacker_requests_sent++;
      
      // Progress indicator
      if (attacker_requests_sent <= 32 || attacker_requests_sent % 50 == 0) begin
        $display("[ATTACKER] T=%0t: Request #%0d → Addr: 0x%08h", 
                 $time, attacker_requests_sent, current_addr);
      end
      
      // Minimal delay between requests to maximize flooding
      @(posedge clock);
    end
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // VICTIM: Normal read operations
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    xil_axi_resp_t resp;
    bit[31:0] read_data;
    bit[31:0] write_data;
    realtime tx_start, tx_end;
    int timeout_flag;
    xil_axi_ulong victim_addr;
    
    // Initialize VIP agents
    victim_agent = new("Victim", design_1_i.axi_vip_0.inst.IF);
    attacker_agent = new("Attacker", design_1_i.axi_vip_1.inst.IF);
    
    // ═══════════════════════════════════════════════════════════════════════
    // Configure VIP for high throughput attack ("Machine Gun" mode)
    // ═══════════════════════════════════════════════════════════════════════
    
    // Increase transaction tracking depth
    attacker_agent.wr_driver.set_transaction_depth(1024);
    attacker_agent.rd_driver.set_transaction_depth(1024);
    
    // *** CRITICAL FIX: Allow sequencer to queue up to 1024 pending requests ***
    // Without this, the VIP crashes at 25 outstanding requests (default limit)
    attacker_agent.rd_driver.seq_item_port.set_max_item_cnt(1024);
    
    // Start the VIP master agents
    victim_agent.start_master();
    attacker_agent.start_master();
    
    // System reset
    reset_n = 0;
    #200ns;
    reset_n = 1;
    #300ns;
    
    $display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║      AXI READ CHANNEL DoS ATTACK - PROOF OF CONCEPT        ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ Attack Method:  Read request flooding (real AXI traffic)   ║");
    $display("║ Strategy:       Continuous ARVALID with incrementing IDs   ║");
    $display("║ Target:         Crossbar FIFO saturation                   ║");
    $display("║ Objective:      Starve victim of read channel access       ║");
    $display("╚════════════════════════════════════════════════════════════╝");
    $display("");
    
    // First, do a baseline write to have data to read back
    $display("[VICTIM] T=%0t: Writing test data to memory...", $time);
    for (int i = 1; i <= 10; i++) begin
      write_data = 32'hCAFE_0000 | i[15:0];
      victim_agent.AXI4LITE_WRITE_BURST(
        VICTIM_TARGET_ADDR + i * 4,
        0,
        write_data,
        resp
      );
    end
    $display("[VICTIM] T=%0t: Baseline data written successfully\n", $time);
    
    // Start the attack
    attack_running = 1;
    
    // Wait for attack to establish and fill crossbar FIFOs
    #2000ns;
    
    $display("[VICTIM] T=%0t: Attempting legitimate READ transactions...\n", $time);
    
    // Attempt legitimate read operations during the attack
    repeat(10) begin
      victim_attempts++;
      victim_addr = VICTIM_TARGET_ADDR + victim_attempts * 4;
      tx_start = $realtime;
      timeout_flag = 0;
      
      $display("[VICTIM] Transaction #%0d (T=%0t):", victim_attempts, $time);
      $display("         → Target: 0x%08h", victim_addr);
      
      fork : victim_transaction
        // Legitimate read attempt
        begin
          victim_agent.AXI4LITE_READ_BURST(
            victim_addr,
            0,
            read_data,
            resp
          );
          
          tx_end = $realtime;
          
          if (!timeout_flag) begin
            victim_success++;
            total_victim_latency += (tx_end - tx_start);
            victim_latencies.push_back(tx_end - tx_start);
            
            if (resp == XIL_AXI_RESP_OKAY) begin
              $display("         ✓ SUCCESS: Data=0x%08h (Latency: %.0f ns)", 
                       read_data, tx_end - tx_start);
            end else begin
              $display("         ⚠ COMPLETED with error response: %s", resp.name());
            end
          end
        end
        
        // Timeout detector
        begin
          #30000ns;  // 30µs timeout
          timeout_flag = 1;
          victim_timeout++;
          $display("         ✗ TIMEOUT after 30 µs - Request starved by attacker");
        end
      join_any
      disable victim_transaction;
      
      $display("");
      
      // Spacing between victim attempts
      #2000ns;
    end
    
    // Stop attack
    attack_running = 0;
    #1000ns;
    
    // Wait for outstanding attacker transactions to complete
    $display("[TEST] Waiting for outstanding attacker requests to complete...");
    #5000ns;
    
    // Print results
    print_results();
    
    #100ns;
    $finish;
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // Results reporting
  // ══════════════════════════════════════════════════════════════════════════
  task print_results();
    real attack_duration_us;
    real packet_loss_rate;
    real avg_latency_ns;
    real max_latency_ns;
    real min_latency_ns;
    real attacker_throughput;
    
    attack_duration_us = ($realtime - attack_start_time) / 1000.0;
    attacker_throughput = attacker_requests_sent / attack_duration_us;
    
    if (victim_attempts > 0) begin
      packet_loss_rate = 100.0 * victim_timeout / victim_attempts;
    end
    
    if (victim_success > 0) begin
      avg_latency_ns = total_victim_latency / victim_success;
      max_latency_ns = victim_latencies[0];
      min_latency_ns = victim_latencies[0];
      foreach (victim_latencies[i]) begin
        if (victim_latencies[i] > max_latency_ns) max_latency_ns = victim_latencies[i];
        if (victim_latencies[i] < min_latency_ns) min_latency_ns = victim_latencies[i];
      end
    end
    
    $display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║                  DoS ATTACK ANALYSIS                       ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║                                                            ║");
    $display("║ ATTACKER METRICS:                                          ║");
    $display("║   • Attack Duration:       %10.2f µs                   ║", attack_duration_us);
    $display("║   • Requests Sent:         %10d                        ║", attacker_requests_sent);
    $display("║   • Responses Received:    %10d                        ║", attacker_responses_received);
    $display("║   • Outstanding:           %10d                        ║", 
             attacker_requests_sent - attacker_responses_received);
    $display("║   • Throughput:            %10.1f req/µs               ║", attacker_throughput);
    $display("║                                                            ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║                                                            ║");
    $display("║ VICTIM METRICS:                                            ║");
    $display("║   • Total Attempts:        %10d                        ║", victim_attempts);
    $display("║   • Successful:            %10d                        ║", victim_success);
    $display("║   • Timed Out:             %10d                        ║", victim_timeout);
    
    if (victim_success > 0) begin
      $display("║   • Avg Latency:           %10.0f ns                   ║", avg_latency_ns);
      $display("║   • Min Latency:           %10.0f ns                   ║", min_latency_ns);
      $display("║   • Max Latency:           %10.0f ns                   ║", max_latency_ns);
    end
    
    $display("║   • Packet Loss Rate:      %9.1f %%                    ║", packet_loss_rate);
    $display("║                                                            ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    
    if (packet_loss_rate >= 50.0) begin
      $display("║                                                            ║");
      $display("║ ✓✓✓ DoS ATTACK HIGHLY EFFECTIVE ✓✓✓                       ║");
      $display("║                                                            ║");
      $display("║ Attacker successfully flooded the crossbar read channel,  ║");
      $display("║ causing %.0f%% of victim requests to timeout.              ║", packet_loss_rate);
    end else if (victim_success > 0 && avg_latency_ns > 500) begin
      $display("║                                                            ║");
      $display("║ ⚠ PARTIAL DoS SUCCESS - LATENCY DEGRADATION               ║");
      $display("║                                                            ║");
      $display("║ Victim requests completed but with %.1fx latency increase.║", avg_latency_ns / 100.0);
    end else begin
      $display("║                                                            ║");
      $display("║ ✗ DoS ATTACK INEFFECTIVE                                  ║");
      $display("║ Interconnect maintained fair arbitration.                 ║");
    end
    
    $display("║                                                            ║");
    $display("╚════════════════════════════════════════════════════════════╝");
    $display("");
  endtask
  
endmodule