`timescale 1ns / 1ps

// ════════════════════════════════════════════════════════════════════════════
// AXI DoS ATTACK 3: MIXED OUTSTANDING READ/WRITE
// ════════════════════════════════════════════════════════════════════════════
// This attack combines outstanding read and write transactions from multiple
// attackers, creating maximum bus contention and chaos on both channels.
// ════════════════════════════════════════════════════════════════════════════

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*;
import design_1_axi_vip_1_0_pkg::*;
import design_1_axi_vip_2_0_pkg::*;
import design_1_axi_vip_3_0_pkg::*;

module tb_mixed_outstanding_attack();

  // ══════════════════════════════════════════════════════════════════════════
  // SIMULATION CONTROL
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    #2000000ns; // 2ms max runtime
    $display("\n[WARNING] Simulation reached maximum runtime limit!");
    $finish;
  end

  // ══════════════════════════════════════════════════════════════════════════
  // CONFIGURATION
  // ══════════════════════════════════════════════════════════════════════════
  localparam bit [31:0] SHARED_ADDR = 32'h4000_0000;
  
  // Burst configuration
  localparam int BURST_LEN = 127;   // 128 beats (medium)
  
  // Outstanding transactions depth
  localparam int OUTSTANDING_DEPTH = 16;
  
  // Injection rate
  localparam int INJECTION_DELAY = 10;  // Aggressive

  // ══════════════════════════════════════════════════════════════════════════
  // SIGNALS
  // ══════════════════════════════════════════════════════════════════════════
  bit clock;
  bit reset_n;

  design_1_axi_vip_0_0_mst_t victim_agent;
  design_1_axi_vip_1_0_mst_t attacker1_agent;
  design_1_axi_vip_2_0_mst_t attacker2_agent;
  design_1_axi_vip_3_0_mst_t attacker3_agent;

  // Metrics
  int victim_attempts = 0;
  int victim_success = 0;
  int victim_timeout = 0;
  int victim_errors = 0;

  realtime baseline_latency;
  realtime attack_latencies[$];

  // Control
  bit attack_enable = 0;
  bit test_done = 0;

  design_1 design_1_i (
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );

  always #5ns clock <= ~clock;

  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER 1 - Outstanding Write Flood
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction trans_queue[$];
    axi_transaction trans;
    xil_axi_uint beat;
    bit [31:0] addr;
    int op_count = 0;

    forever begin
      wait(attack_enable);
      while (attack_enable && !test_done) begin
        addr = SHARED_ADDR + ((op_count % 256) * 4);

        trans = attacker1_agent.wr_driver.create_transaction("atk1_wr");
        trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, BURST_LEN, XIL_AXI_SIZE_4BYTE);
        trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN);
        trans.size_wr_beats();
        for (beat = 0; beat < trans.get_len() + 1; beat++)
          trans.set_data_beat(beat, 32'hA111_0000 | op_count);
        
        attacker1_agent.wr_driver.send(trans);
        trans_queue.push_back(trans);
        
        if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
          trans = trans_queue.pop_front();
          attacker1_agent.wr_driver.wait_rsp(trans);
        end

        op_count++;
        #(INJECTION_DELAY * 1ns);
      end
      
      while (trans_queue.size() > 0) begin
        trans = trans_queue.pop_front();
        attacker1_agent.wr_driver.wait_rsp(trans);
      end
      
      @(posedge clock);
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER 2 - Outstanding Read Flood (opposite of attacker 1)
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction trans_queue[$];
    axi_transaction trans;
    bit [31:0] addr;
    int op_count = 0;

    forever begin
      wait(attack_enable);
      while (attack_enable && !test_done) begin
        addr = SHARED_ADDR + ((op_count % 256) * 4) + 1024;

        trans = attacker2_agent.rd_driver.create_transaction("atk2_rd");
        trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, BURST_LEN, XIL_AXI_SIZE_4BYTE);
        trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN);
        
        attacker2_agent.rd_driver.send(trans);
        trans_queue.push_back(trans);
        
        if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
          trans = trans_queue.pop_front();
          attacker2_agent.rd_driver.wait_rsp(trans);
        end

        op_count++;
        #(INJECTION_DELAY * 1ns);
      end
      
      while (trans_queue.size() > 0) begin
        trans = trans_queue.pop_front();
        attacker2_agent.rd_driver.wait_rsp(trans);
      end
      
      @(posedge clock);
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER 3 - Alternating Read/Write (maximum chaos)
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction trans_queue[$];
    axi_transaction trans;
    xil_axi_uint beat;
    bit [31:0] addr;
    int op_count = 0;

    forever begin
      wait(attack_enable);
      while (attack_enable && !test_done) begin
        addr = SHARED_ADDR + ((op_count % 256) * 4) + 2048;

        // Alternate between read and write
        if (op_count % 2 == 0) begin
          trans = attacker3_agent.wr_driver.create_transaction("atk3_wr");
          trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, BURST_LEN, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN);
          trans.size_wr_beats();
          for (beat = 0; beat < trans.get_len() + 1; beat++)
            trans.set_data_beat(beat, 32'hA333_0000 | op_count);
          attacker3_agent.wr_driver.send(trans);
        end else begin
          trans = attacker3_agent.rd_driver.create_transaction("atk3_rd");
          trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, BURST_LEN, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN);
          attacker3_agent.rd_driver.send(trans);
        end
        
        trans_queue.push_back(trans);
        
        // Don't wait for response to maximize chaos
        if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
          trans = trans_queue.pop_front();
          // Intentionally not waiting to keep transactions outstanding
        end

        op_count++;
        #(INJECTION_DELAY * 1ns);
      end
      
      trans_queue.delete();
      @(posedge clock);
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // MAIN TEST SEQUENCE
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    bit [31:0] write_data, read_data, expected_data;
    xil_axi_resp_t resp;
    realtime t_start, t_end, latency;
    real avg_baseline, avg_attack;

    // INIT
    victim_agent    = new("Victim", design_1_i.axi_vip_0.inst.IF);
    attacker1_agent = new("Attacker1", design_1_i.axi_vip_1.inst.IF);
    attacker2_agent = new("Attacker2", design_1_i.axi_vip_2.inst.IF);
    attacker3_agent = new("Attacker3", design_1_i.axi_vip_3.inst.IF);

    // Configure transaction depths
    attacker1_agent.wr_driver.set_transaction_depth(4096);
    attacker1_agent.rd_driver.set_transaction_depth(4096);
    attacker2_agent.wr_driver.set_transaction_depth(4096);
    attacker2_agent.rd_driver.set_transaction_depth(4096);
    attacker3_agent.wr_driver.set_transaction_depth(4096);
    attacker3_agent.rd_driver.set_transaction_depth(4096);
    
    attacker1_agent.wr_driver.seq_item_port.set_max_item_cnt(10000);
    attacker1_agent.rd_driver.seq_item_port.set_max_item_cnt(10000);
    attacker2_agent.wr_driver.seq_item_port.set_max_item_cnt(10000);
    attacker2_agent.rd_driver.seq_item_port.set_max_item_cnt(10000);
    attacker3_agent.wr_driver.seq_item_port.set_max_item_cnt(10000);
    attacker3_agent.rd_driver.seq_item_port.set_max_item_cnt(10000);

    victim_agent.start_master();
    attacker1_agent.start_master();
    attacker2_agent.start_master();
    attacker3_agent.start_master();

    reset_n = 0; #200ns; reset_n = 1; #500ns;

    // BASELINE MEASUREMENT
    $display("╔══════════════════════════════════════════════════════════════════╗");
    $display("║  ATTACK 3: MIXED OUTSTANDING READ/WRITE                          ║");
    $display("╚══════════════════════════════════════════════════════════════════╝\n");
    
    $display("[INFO] Measuring baseline latency...\n");

    // Initialize memory
    for (int i = 0; i < 256; i++) begin
      write_data = 32'hCAFE_0000 | i;
      victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
    end

    // Measure baseline
    avg_baseline = 0;
    for (int i = 0; i < 20; i++) begin
      t_start = $realtime;
      victim_agent.AXI4LITE_READ_BURST(SHARED_ADDR + i*4, 0, read_data, resp);
      t_end = $realtime;
      avg_baseline += (t_end - t_start);
    end
    avg_baseline /= 20.0;
    baseline_latency = avg_baseline;
    $display("[BASELINE] Average Latency: %.0f ns\n", avg_baseline);

    #2000ns;

    // Re-initialize memory before attack
    for (int i = 0; i < 256; i++) begin
      write_data = 32'hCAFE_0000 | i;
      victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
    end

    // START ATTACK
    $display("╔══════════════════════════════════════════════════════════════════╗");
    $display("║  Starting Mixed Outstanding R/W Attack                           ║");
    $display("║  Attacker 1: Writes only                                         ║");
    $display("║  Attacker 2: Reads only                                          ║");
    $display("║  Attacker 3: Alternating R/W (chaos mode)                        ║");
    $display("║  Injection: %3dns | Burst: %3d beats | Outstanding: %0d          ║",
             INJECTION_DELAY, BURST_LEN+1, OUTSTANDING_DEPTH);
    $display("╚══════════════════════════════════════════════════════════════════╝\n");

    attack_enable = 1;
    #20000ns;

    // MEASURE VICTIM LATENCY UNDER ATTACK
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

          if (read_data != expected_data) begin
            victim_errors++;
            $display("[VICTIM] #%02d: ✗ CORRUPTED! Expected: 0x%08X Got: 0x%08X Latency: %.0f ns (%.1fx)",
                     v+1, expected_data, read_data, latency, latency/baseline_latency);
          end else if (latency > baseline_latency * 10.0) begin
            $display("[VICTIM] #%02d: 🔥 CRITICAL LAG %.0f ns (%.1fx)",
                     v+1, latency, latency/baseline_latency);
          end else if (latency > baseline_latency * 4.0) begin
            $display("[VICTIM] #%02d: ⚠ HIGH LAG %.0f ns (%.1fx)",
                     v+1, latency, latency/baseline_latency);
          end else begin
            $display("[VICTIM] #%02d: ✓ OK %.0f ns", v+1, latency);
          end
        end
        begin
          #200000ns; // 200us timeout
          victim_timeout++;
          $display("[VICTIM] #%02d: ✗ TIMEOUT (Bus saturated by mixed traffic)", v+1);
        end
      join_any
      disable victim_tx;
      #800ns;
    end

    attack_enable = 0;
    test_done = 1;
    
    #10000ns;

    // FINAL REPORT
    if (victim_success > 0) avg_attack /= victim_success;
    
    $display("\n╔══════════════════════════════════════════════════════════════════╗");
    $display("║  MIXED OUTSTANDING R/W - RESULTS                                 ║");
    $display("╠══════════════════════════════════════════════════════════════════╣");
    $display("║  Baseline Latency:    %.0f ns                                   ║", avg_baseline);
    $display("║  Attack Latency:      %.0f ns                                   ║", avg_attack);
    $display("║  Slowdown Factor:     %.1fx                                     ║", avg_attack/avg_baseline);
    $display("║  Timeouts:            %0d / %0d                                   ║", victim_timeout, victim_attempts);
    $display("║  Data Corruptions:    %0d / %0d                                   ║", victim_errors, victim_success);
    $display("╠══════════════════════════════════════════════════════════════════╣");
    if (avg_attack/avg_baseline >= 4.0 || victim_errors > 0)
      $display("║  ✓ SUCCESS: Attack effective (slowdown or corruption)!          ║");
    else
      $display("║  ⚠ Below target effectiveness                                   ║");
    $display("╚══════════════════════════════════════════════════════════════════╝\n");
    
    #1000ns;
    $finish;
  end

endmodule
