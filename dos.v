`timescale 1ns / 1ps

// ════════════════════════════════════════════════════════════════════════════
// AXI DoS ATTACK - ADVANCED STRATEGIES
// ════════════════════════════════════════════════════════════════════════════
// Previous attack showed round-robin protects the victim well.
// New strategies:
//   1. SAME ADDRESS ATTACK - Create BRAM port contention
//   2. MIXED R/W ATTACK - Saturate both channels
//   3. BURST PRE-FILL - Fill interconnect FIFOs before victim
//   4. WRITE FLOOD - Target write channel specifically
// ════════════════════════════════════════════════════════════════════════════

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*; 
import design_1_axi_vip_1_0_pkg::*; 

module tb();
     
  // ══════════════════════════════════════════════════════════════════════════
  // SIGNALS & PARAMETERS
  // ══════════════════════════════════════════════════════════════════════════
  bit clock;
  bit reset_n;
  
  design_1_axi_vip_0_0_mst_t victim_agent;
  design_1_axi_vip_1_0_mst_t attacker_agent;
   
  // CRITICAL: Attack SAME addresses as victim to create BRAM contention
  localparam bit [31:0] SHARED_ADDR = 32'h4000_0000;  // Same as victim!
  
  // Attack configuration
  typedef enum {
    ATTACK_NONE,
    ATTACK_SAME_ADDR_READ,    // Read same addresses as victim
    ATTACK_SAME_ADDR_WRITE,   // Write same addresses as victim  
    ATTACK_MIXED_RW,          // Alternating read/write
    ATTACK_WRITE_FLOOD,       // Pure write flood
    ATTACK_PREFILL_BURST      // Pre-fill FIFOs then victim tries
  } attack_mode_t;
  
  attack_mode_t current_attack = ATTACK_NONE;
  
  // Metrics
  int attacker_reads = 0;
  int attacker_writes = 0;
  int victim_attempts = 0;
  int victim_success = 0;
  int victim_timeout = 0;
  int victim_errors = 0;
  
  realtime baseline_latency;
  realtime attack_latencies[$];
  
  // Control
  bit attack_enable = 0;
  bit test_done = 0;
  bit victim_data_corrupted = 0;
  
  // AXI Signal monitoring
  wire s00_arvalid, s00_arready, s00_awvalid, s00_awready;
  wire s01_arvalid, s01_arready, s01_awvalid, s01_awready;
  wire s00_rvalid, s00_rready, s00_bvalid, s00_bready;
  wire s01_rvalid, s01_rready, s01_bvalid, s01_bready;
  
  int s00_ar_stalls = 0;
  int s00_aw_stalls = 0;
  int s01_ar_stalls = 0;
  int s01_aw_stalls = 0;
  
  // ══════════════════════════════════════════════════════════════════════════
  // DESIGN INSTANTIATION
  // ══════════════════════════════════════════════════════════════════════════
  design_1 design_1_i (
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );
  
  always #5ns clock <= ~clock;
  
  // ══════════════════════════════════════════════════════════════════════════
  // SIGNAL PROBES
  // ══════════════════════════════════════════════════════════════════════════
  // Victim (VIP0) signals
  assign s00_arvalid = design_1_i.axi_vip_0.inst.IF.ARVALID;
  assign s00_arready = design_1_i.axi_vip_0.inst.IF.ARREADY;
  assign s00_awvalid = design_1_i.axi_vip_0.inst.IF.AWVALID;
  assign s00_awready = design_1_i.axi_vip_0.inst.IF.AWREADY;
  assign s00_rvalid  = design_1_i.axi_vip_0.inst.IF.RVALID;
  assign s00_rready  = design_1_i.axi_vip_0.inst.IF.RREADY;
  assign s00_bvalid  = design_1_i.axi_vip_0.inst.IF.BVALID;
  assign s00_bready  = design_1_i.axi_vip_0.inst.IF.BREADY;
  
  // Attacker (VIP1) signals
  assign s01_arvalid = design_1_i.axi_vip_1.inst.IF.ARVALID;
  assign s01_arready = design_1_i.axi_vip_1.inst.IF.ARREADY;
  assign s01_awvalid = design_1_i.axi_vip_1.inst.IF.AWVALID;
  assign s01_awready = design_1_i.axi_vip_1.inst.IF.AWREADY;
  assign s01_rvalid  = design_1_i.axi_vip_1.inst.IF.RVALID;
  assign s01_rready  = design_1_i.axi_vip_1.inst.IF.RREADY;
  assign s01_bvalid  = design_1_i.axi_vip_1.inst.IF.BVALID;
  assign s01_bready  = design_1_i.axi_vip_1.inst.IF.BREADY;
  
  // Stall counter
  always @(posedge clock) begin
    if (reset_n && attack_enable) begin
      if (s00_arvalid && !s00_arready) s00_ar_stalls++;
      if (s00_awvalid && !s00_awready) s00_aw_stalls++;
      if (s01_arvalid && !s01_arready) s01_ar_stalls++;
      if (s01_awvalid && !s01_awready) s01_aw_stalls++;
    end
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER PROCESS - Multiple attack modes
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    bit [31:0] data;
    xil_axi_resp_t resp;
    bit [31:0] addr;
    int rw_toggle = 0;
    
    forever begin
      wait(attack_enable);
      
      while (attack_enable && !test_done) begin
        // Calculate address - ATTACK SAME REGION AS VICTIM
        addr = SHARED_ADDR + ((attacker_reads + attacker_writes) % 64) * 4;
        
        case (current_attack)
          
          ATTACK_SAME_ADDR_READ: begin
            // Flood reads to SAME addresses victim uses
            attacker_agent.AXI4LITE_READ_BURST(addr, 0, data, resp);
            attacker_reads++;
          end
          
          ATTACK_SAME_ADDR_WRITE: begin
            // Flood writes to SAME addresses - may corrupt victim data!
            data = 32'hDEAD_0000 | (attacker_writes & 16'hFFFF);
            attacker_agent.AXI4LITE_WRITE_BURST(addr, 0, data, resp);
            attacker_writes++;
          end
          
          ATTACK_MIXED_RW: begin
            // Alternate read/write to saturate both channels
            if (rw_toggle) begin
              attacker_agent.AXI4LITE_READ_BURST(addr, 0, data, resp);
              attacker_reads++;
            end else begin
              data = 32'hBAD0_0000 | (attacker_writes & 16'hFFFF);
              attacker_agent.AXI4LITE_WRITE_BURST(addr, 0, data, resp);
              attacker_writes++;
            end
            rw_toggle = ~rw_toggle;
          end
          
          ATTACK_WRITE_FLOOD: begin
            // Pure write flood - different arbitration path
            data = 32'hAAAA_0000 | (attacker_writes & 16'hFFFF);
            attacker_agent.AXI4LITE_WRITE_BURST(addr, 0, data, resp);
            attacker_writes++;
          end
          
          default: begin
            @(posedge clock);
          end
          
        endcase
        
        // Progress display
        if ((attacker_reads + attacker_writes) % 100 == 0 && (attacker_reads + attacker_writes) > 0) begin
          $display("[ATTACKER] R=%0d W=%0d Addr=0x%08h", 
                   attacker_reads, attacker_writes, addr);
        end
      end
      
      // Wait for next attack
      @(posedge clock);
    end
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // SECOND ATTACKER THREAD - Parallel pressure
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    bit [31:0] data;
    xil_axi_resp_t resp;
    bit [31:0] addr;
    
    forever begin
      wait(attack_enable);
      
      while (attack_enable && !test_done) begin
        // Different address pattern - interleaved
        addr = SHARED_ADDR + 32'h80 + (($urandom() % 32) * 4);
        
        case (current_attack)
          ATTACK_SAME_ADDR_READ,
          ATTACK_MIXED_RW: begin
            attacker_agent.AXI4LITE_READ_BURST(addr, 0, data, resp);
            attacker_reads++;
          end
          
          ATTACK_SAME_ADDR_WRITE,
          ATTACK_WRITE_FLOOD: begin
            data = $urandom();
            attacker_agent.AXI4LITE_WRITE_BURST(addr, 0, data, resp);
            attacker_writes++;
          end
          
          default: @(posedge clock);
        endcase
      end
      
      @(posedge clock);
    end
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // MAIN TEST - Run all attack modes
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    bit [31:0] write_data, read_data, expected_data;
    xil_axi_resp_t resp;
    realtime t_start, t_end, latency;
    real avg_baseline, avg_attack;
    real results_latency[5];
    real results_impact[5];
    int results_timeout[5];
    int results_corrupt[5];
    string attack_names[5];
    
    attack_names[0] = "SAME_ADDR_READ";
    attack_names[1] = "SAME_ADDR_WRITE";
    attack_names[2] = "MIXED_RW";
    attack_names[3] = "WRITE_FLOOD";
    attack_names[4] = "PREFILL_BURST";
    
    // ════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ════════════════════════════════════════════════════════════════════════
    $display("\n");
    $display("╔══════════════════════════════════════════════════════════════════╗");
    $display("║       AXI DoS ATTACK - ADVANCED MULTI-STRATEGY TEST              ║");
    $display("╠══════════════════════════════════════════════════════════════════╣");
    $display("║  Goal: Find attack that bypasses round-robin arbitration         ║");
    $display("║  Key Insight: Attack SAME addresses to create resource conflict  ║");
    $display("╚══════════════════════════════════════════════════════════════════╝\n");
    
    victim_agent = new("Victim", design_1_i.axi_vip_0.inst.IF);
    attacker_agent = new("Attacker", design_1_i.axi_vip_1.inst.IF);
    
    victim_agent.start_master();
    attacker_agent.start_master();
    
    reset_n = 0;
    #200ns;
    reset_n = 1;
    #300ns;
    
    // ════════════════════════════════════════════════════════════════════════
    // BASELINE MEASUREMENT
    // ════════════════════════════════════════════════════════════════════════
    $display("╔══════════════════════════════════════════════════════════════════╗");
    $display("║  BASELINE MEASUREMENT (No Attack)                                ║");
    $display("╚══════════════════════════════════════════════════════════════════╝\n");
    
    // Write known test pattern
    $display("[SETUP] Writing test data with known pattern...");
    for (int i = 0; i < 64; i++) begin
      write_data = 32'hCAFE_0000 | i;
      victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
    end
    
    // Measure baseline
    avg_baseline = 0;
    for (int i = 0; i < 10; i++) begin
      t_start = $realtime;
      victim_agent.AXI4LITE_READ_BURST(SHARED_ADDR + i*4, 0, read_data, resp);
      t_end = $realtime;
      avg_baseline += (t_end - t_start);
      $display("[BASELINE] Read #%0d: Data=0x%08h Latency=%.0f ns", i+1, read_data, t_end-t_start);
    end
    avg_baseline /= 10.0;
    baseline_latency = avg_baseline;
    $display("\n[BASELINE] Average: %.0f ns\n", avg_baseline);
    
    #1000ns;
    
    // ════════════════════════════════════════════════════════════════════════
    // TEST EACH ATTACK MODE
    // ════════════════════════════════════════════════════════════════════════
    for (int mode = 0; mode < 4; mode++) begin
      // Reset metrics
      attacker_reads = 0;
      attacker_writes = 0;
      victim_attempts = 0;
      victim_success = 0;
      victim_timeout = 0;
      victim_errors = 0;
      victim_data_corrupted = 0;
      s00_ar_stalls = 0;
      s00_aw_stalls = 0;
      s01_ar_stalls = 0;
      s01_aw_stalls = 0;
      attack_latencies.delete();
      
      // Re-write test data (in case previous attack corrupted it)
      for (int i = 0; i < 64; i++) begin
        write_data = 32'hCAFE_0000 | i;
        victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
      end
      
      // Set attack mode
      case (mode)
        0: current_attack = ATTACK_SAME_ADDR_READ;
        1: current_attack = ATTACK_SAME_ADDR_WRITE;
        2: current_attack = ATTACK_MIXED_RW;
        3: current_attack = ATTACK_WRITE_FLOOD;
      endcase
      
      $display("╔══════════════════════════════════════════════════════════════════╗");
      $display("║  ATTACK MODE %0d: %-45s     ║", mode+1, attack_names[mode]);
      $display("╚══════════════════════════════════════════════════════════════════╝\n");
      
      // Start attack
      attack_enable = 1;
      #5000ns;  // Let attack saturate
      
      // Victim attempts during attack
      avg_attack = 0;
      
      for (int v = 0; v < 15; v++) begin
        victim_attempts++;
        expected_data = 32'hCAFE_0000 | v;
        t_start = $realtime;
        
        fork : victim_tx
          begin
            victim_agent.AXI4LITE_READ_BURST(SHARED_ADDR + v*4, 0, read_data, resp);
            t_end = $realtime;
            latency = t_end - t_start;
            
            victim_success++;
            avg_attack += latency;
            attack_latencies.push_back(latency);
            
            // Check for data corruption
            if (read_data != expected_data && 
                current_attack inside {ATTACK_SAME_ADDR_WRITE, ATTACK_MIXED_RW, ATTACK_WRITE_FLOOD}) begin
              victim_data_corrupted = 1;
              victim_errors++;
              $display("[VICTIM] #%0d: ✗ DATA CORRUPTED! Expected=0x%08h Got=0x%08h (%.0fns)",
                       v+1, expected_data, read_data, latency);
            end else if (latency > baseline_latency * 2.0) begin
              $display("[VICTIM] #%0d: ⚠ DEGRADED Latency=%.0f ns (%.1fx)", 
                       v+1, latency, latency/baseline_latency);
            end else begin
              $display("[VICTIM] #%0d: ✓ OK Data=0x%08h Latency=%.0f ns", 
                       v+1, read_data, latency);
            end
          end
          
          begin
            #30000ns;
            victim_timeout++;
            $display("[VICTIM] #%0d: ✗ TIMEOUT", v+1);
          end
        join_any
        disable victim_tx;
        
        #300ns;
      end
      
      // Stop attack
      attack_enable = 0;
      current_attack = ATTACK_NONE;
      #2000ns;
      
      // Store results
      if (victim_success > 0) begin
        avg_attack /= victim_success;
      end
      results_latency[mode] = avg_attack;
      results_timeout[mode] = victim_timeout;
      results_corrupt[mode] = victim_errors;
      results_impact[mode] = 100.0 * (victim_timeout + victim_errors) / victim_attempts;
      
      $display("\n[RESULT] Mode=%s: AvgLat=%.0fns (%.1fx), Timeout=%0d, Corrupt=%0d, Stalls(V)=%0d/%0d\n",
               attack_names[mode], avg_attack, avg_attack/baseline_latency,
               victim_timeout, victim_errors, s00_ar_stalls, s00_aw_stalls);
      
      #1000ns;
    end
    
    test_done = 1;
    
    // ════════════════════════════════════════════════════════════════════════
    // FINAL COMPARISON
    // ════════════════════════════════════════════════════════════════════════
    print_comparison(attack_names, results_latency, results_timeout, results_corrupt, results_impact, avg_baseline);
    
    #100ns;
    $finish;
  end
  
  // ══════════════════════════════════════════════════════════════════════════
  // RESULTS COMPARISON
  // ══════════════════════════════════════════════════════════════════════════
  task print_comparison(
    input string names[5],
    input real latencies[5],
    input int timeouts[5],
    input int corrupts[5],
    input real impacts[5],
    input real baseline
  );
    int best_mode = 0;
    real best_impact = 0;
    
    $display("\n");
    $display("╔══════════════════════════════════════════════════════════════════════════╗");
    $display("║                    ATTACK STRATEGY COMPARISON                            ║");
    $display("╠══════════════════════════════════════════════════════════════════════════╣");
    $display("║                                                                          ║");
    $display("║  Baseline Latency: %.0f ns                                               ║", baseline);
    $display("║                                                                          ║");
    $display("║  Mode              Latency    Increase  Timeout  Corrupt  Impact        ║");
    $display("║  ────────────────  ─────────  ────────  ───────  ───────  ──────        ║");
    
    for (int i = 0; i < 4; i++) begin
      string marker = "";
      if (impacts[i] > best_impact) begin
        best_impact = impacts[i];
        best_mode = i;
      end
      if (impacts[i] > 0 || latencies[i] > baseline * 1.5) marker = "⚠";
      if (impacts[i] >= 30) marker = "✓✓";
      
      $display("║  %-16s  %7.0f ns  %6.1fx    %5d    %5d    %5.1f%% %s  ║",
               names[i], latencies[i], latencies[i]/baseline,
               timeouts[i], corrupts[i], impacts[i], marker);
    end
    
    $display("║                                                                          ║");
    $display("╠══════════════════════════════════════════════════════════════════════════╣");
    $display("║                                                                          ║");
    
    if (best_impact >= 20.0) begin
      $display("║  ⚠⚠⚠ VULNERABILITY FOUND! ⚠⚠⚠                                           ║");
      $display("║                                                                          ║");
      $display("║  Attack '%s' achieved %.1f%% impact!                      ║", names[best_mode], best_impact);
      $display("║                                                                          ║");
      $display("║  EVIDENCE FOR PROTECTION REQUIREMENT:                                    ║");
      if (corrupts[best_mode] > 0) begin
        $display("║    • Data corruption detected - attacker modified victim's data         ║");
      end
      if (timeouts[best_mode] > 0) begin
        $display("║    • Denial of service - victim requests timed out                      ║");
      end
      if (latencies[best_mode] > baseline * 2) begin
        $display("║    • Significant latency degradation (%.1fx increase)                   ║", latencies[best_mode]/baseline);
      end
      $display("║                                                                          ║");
      $display("║  RECOMMENDED PROTECTIONS:                                                ║");
      $display("║    1. AXI Firewall - Restrict address ranges per master                  ║");
      $display("║    2. Rate Limiter - Cap transactions per master                         ║");
      $display("║    3. QoS Manager - Priority-based arbitration                           ║");
      $display("║    4. Address Isolation - Separate memory regions                        ║");
    end else begin
      $display("║  System showed resilience to tested attacks.                             ║");
      $display("║                                                                          ║");
      $display("║  However, the %.1fx latency increase under load demonstrates:            ║", latencies[best_mode]/baseline);
      $display("║    • Resource contention is possible                                     ║");
      $display("║    • More sophisticated attacks may succeed                              ║");
      $display("║    • Protection is still recommended for critical systems                ║");
    end
    
    $display("║                                                                          ║");
    $display("╚══════════════════════════════════════════════════════════════════════════╝");
    $display("");
  endtask

endmodule
