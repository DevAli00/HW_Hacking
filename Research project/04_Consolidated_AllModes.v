`timescale 1ns / 1ps

// ════════════════════════════════════════════════════════════════════════════
// OPTIMIZED AXI DoS ATTACK - "OUTSTANDING TRANSACTION FLOOD" (CORRECTED)
// ════════════════════════════════════════════════════════════════════════════

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*;
import design_1_axi_vip_1_0_pkg::*;
import design_1_axi_vip_2_0_pkg::*;
import design_1_axi_vip_3_0_pkg::*;

module tb();

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
 
  // Strategy 1: Longer bursts
  localparam int BURST_LEN_LONG = 255;   // 256 beats (max)
  localparam int BURST_LEN_MED = 127;    // 128 beats
  localparam int BURST_LEN_SHORT = 63;   // 64 beats
 
  // Strategy 2: Outstanding transactions
  localparam int OUTSTANDING_DEPTH = 16;  // Pushing limits
 
  // Strategy 3: Injection rate
  localparam int INJECTION_DELAY_AGGRESSIVE = 10;
  localparam int INJECTION_DELAY_MODERATE = 50;
 
  typedef enum {
    ATTACK_NONE,
    ATTACK_OUTSTANDING_READ,    
    ATTACK_OUTSTANDING_WRITE,    
    ATTACK_MIXED_OUTSTANDING,    
    ATTACK_VARIABLE_BURST        
  } attack_mode_t;

  attack_mode_t current_attack = ATTACK_NONE;
  int current_injection_delay = INJECTION_DELAY_MODERATE;
  int current_burst_len = BURST_LEN_LONG;

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
  // ATTACKER 1
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction trans_queue[$];
    axi_transaction trans;
    xil_axi_uint beat;
    bit [31:0] addr;
    int op_count = 0;
    int burst_len;

    forever begin
      wait(attack_enable);
      while (attack_enable && !test_done) begin
       
        if (current_attack == ATTACK_VARIABLE_BURST) begin
          case (op_count % 3)
            0: burst_len = BURST_LEN_LONG;
            1: burst_len = BURST_LEN_MED;
            2: burst_len = BURST_LEN_SHORT;
          endcase
        end else begin
          burst_len = current_burst_len;
        end
       
        addr = SHARED_ADDR + ((op_count % 256) * 4);

        if (current_attack inside {ATTACK_OUTSTANDING_WRITE, ATTACK_MIXED_OUTSTANDING}) begin
          trans = attacker1_agent.wr_driver.create_transaction("atk1_wr");
          trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX: Correct Enum
          trans.size_wr_beats();
          for (beat = 0; beat < trans.get_len() + 1; beat++)
            trans.set_data_beat(beat, 32'hA111_0000 | op_count); // FIX: Valid Hex
         
          attacker1_agent.wr_driver.send(trans);
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            attacker1_agent.wr_driver.wait_rsp(trans);
          end
        end
        else if (current_attack inside {ATTACK_OUTSTANDING_READ, ATTACK_VARIABLE_BURST}) begin
          trans = attacker1_agent.rd_driver.create_transaction("atk1_rd");
          trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
         
          attacker1_agent.rd_driver.send(trans);
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            attacker1_agent.rd_driver.wait_rsp(trans);
          end
        end

        op_count++;
        #(current_injection_delay * 1ns);
      end
     
      while (trans_queue.size() > 0) begin
        trans = trans_queue.pop_front();
        if (current_attack inside {ATTACK_OUTSTANDING_WRITE, ATTACK_MIXED_OUTSTANDING})
          attacker1_agent.wr_driver.wait_rsp(trans);
        else
          attacker1_agent.rd_driver.wait_rsp(trans);
      end
     
      @(posedge clock);
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER 2
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction trans_queue[$];
    axi_transaction trans;
    xil_axi_uint beat;
    bit [31:0] addr;
    int op_count = 0;
    int burst_len;

    forever begin
      wait(attack_enable);
      while (attack_enable && !test_done) begin
       
        if (current_attack == ATTACK_VARIABLE_BURST) burst_len = BURST_LEN_MED;
        else burst_len = current_burst_len;
       
        addr = SHARED_ADDR + ((op_count % 256) * 4) + 1024;

        if (current_attack inside {ATTACK_OUTSTANDING_WRITE, ATTACK_VARIABLE_BURST}) begin
          trans = attacker2_agent.wr_driver.create_transaction("atk2_wr");
          trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
          trans.size_wr_beats();
          for (beat = 0; beat < trans.get_len() + 1; beat++)
            trans.set_data_beat(beat, 32'hA222_0000 | op_count); // FIX
         
          attacker2_agent.wr_driver.send(trans);
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            attacker2_agent.wr_driver.wait_rsp(trans);
          end
        end
        else if (current_attack inside {ATTACK_OUTSTANDING_READ, ATTACK_MIXED_OUTSTANDING}) begin
          trans = attacker2_agent.rd_driver.create_transaction("atk2_rd");
          trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
         
          attacker2_agent.rd_driver.send(trans);
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            attacker2_agent.rd_driver.wait_rsp(trans);
          end
        end

        op_count++;
        #(current_injection_delay * 1ns);
      end
     
      while (trans_queue.size() > 0) begin
        trans = trans_queue.pop_front();
        if (current_attack inside {ATTACK_OUTSTANDING_WRITE, ATTACK_VARIABLE_BURST})
          attacker2_agent.wr_driver.wait_rsp(trans);
        else
          attacker2_agent.rd_driver.wait_rsp(trans);
      end
     
      @(posedge clock);
    end
  end

  // ══════════════════════════════════════════════════════════════════════════
  // ATTACKER 3
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    axi_transaction trans_queue[$];
    axi_transaction trans;
    xil_axi_uint beat;
    bit [31:0] addr;
    int op_count = 0;
    int burst_len;

    forever begin
      wait(attack_enable);
      while (attack_enable && !test_done) begin
       
        if (current_attack == ATTACK_VARIABLE_BURST) burst_len = BURST_LEN_SHORT;
        else burst_len = current_burst_len;
       
        addr = SHARED_ADDR + ((op_count % 256) * 4) + 2048;

        if (current_attack inside {ATTACK_MIXED_OUTSTANDING}) begin
          if (op_count % 2 == 0) begin
            trans = attacker3_agent.wr_driver.create_transaction("atk3_wr");
            trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
            trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
            trans.size_wr_beats();
            for (beat = 0; beat < trans.get_len() + 1; beat++)
              trans.set_data_beat(beat, 32'hA333_0000 | op_count); // FIX
            attacker3_agent.wr_driver.send(trans);
          end else begin
            trans = attacker3_agent.rd_driver.create_transaction("atk3_rd");
            trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
            trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
            attacker3_agent.rd_driver.send(trans);
          end
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            // Don't wait here for mixed to maximize chaos
          end
        end
        else if (current_attack inside {ATTACK_OUTSTANDING_WRITE, ATTACK_VARIABLE_BURST}) begin
          trans = attacker3_agent.wr_driver.create_transaction("atk3_wr");
          trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
          trans.size_wr_beats();
          for (beat = 0; beat < trans.get_len() + 1; beat++)
            trans.set_data_beat(beat, 32'hA333_0000 | op_count); // FIX
         
          attacker3_agent.wr_driver.send(trans);
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            attacker3_agent.wr_driver.wait_rsp(trans);
          end
        end
        else if (current_attack == ATTACK_OUTSTANDING_READ) begin
          trans = attacker3_agent.rd_driver.create_transaction("atk3_rd");
          trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, burst_len, XIL_AXI_SIZE_4BYTE);
          trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN); // FIX
         
          attacker3_agent.rd_driver.send(trans);
          trans_queue.push_back(trans);
         
          if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
            trans = trans_queue.pop_front();
            attacker3_agent.rd_driver.wait_rsp(trans);
          end
        end

        op_count++;
        #(current_injection_delay * 1ns);
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
    real results_latency[5];
    real results_impact[5];
    int results_timeout[5];
    int results_corrupt[5];
    string attack_names[5];

    attack_names[0] = "Outstanding Reads (Aggressive)";
    attack_names[1] = "Outstanding Writes (Aggressive)";
    attack_names[2] = "Outstanding Reads (Moderate)";
    attack_names[3] = "Mixed Outstanding R/W";
    attack_names[4] = "Variable Burst Sizes";

    // INIT
    victim_agent    = new("Victim", design_1_i.axi_vip_0.inst.IF);
    attacker1_agent = new("Attacker1", design_1_i.axi_vip_1.inst.IF);
    attacker2_agent = new("Attacker2", design_1_i.axi_vip_2.inst.IF);
    attacker3_agent = new("Attacker3", design_1_i.axi_vip_3.inst.IF);

    // Buffers & Limits - INCREASED FOR FLOODING
    attacker1_agent.wr_driver.set_transaction_depth(4096);
    attacker1_agent.rd_driver.set_transaction_depth(4096);
    attacker2_agent.wr_driver.set_transaction_depth(4096);
    attacker2_agent.rd_driver.set_transaction_depth(4096);
    attacker3_agent.wr_driver.set_transaction_depth(4096);
    attacker3_agent.rd_driver.set_transaction_depth(4096);
   
    // Safety against sequence overflow
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

    // BASELINE
    $display("╔══════════════════════════════════════════════════════════════════╗");
    $display("║  BASELINE MEASUREMENT (No Attack)                                ║");
    $display("╚══════════════════════════════════════════════════════════════════╝\n");

    for (int i = 0; i < 256; i++) begin
      write_data = 32'hCAFE_0000 | i;
      victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
    end

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

    // ATTACK LOOP
    $display("[INFO] Starting attack sequence...\n");
   
    for (int mode = 0; mode < 5; mode++) begin
      victim_attempts = 0;
      victim_success = 0;
      victim_timeout = 0;
      victim_errors = 0;
      attack_latencies.delete();

      // Reset Memory
      for (int i = 0; i < 256; i++) begin
        write_data = 32'hCAFE_0000 | i;
        victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
      end

      case (mode)
        0: begin // Aggressive outstanding reads
          current_attack = ATTACK_OUTSTANDING_READ;
          current_injection_delay = INJECTION_DELAY_AGGRESSIVE;
          current_burst_len = BURST_LEN_LONG;
        end
        1: begin // Aggressive outstanding writes
          current_attack = ATTACK_OUTSTANDING_WRITE;
          current_injection_delay = INJECTION_DELAY_AGGRESSIVE;
          current_burst_len = BURST_LEN_LONG;
        end
        2: begin // Moderate outstanding reads
          current_attack = ATTACK_OUTSTANDING_READ;
          current_injection_delay = INJECTION_DELAY_MODERATE;
          current_burst_len = BURST_LEN_LONG;
        end
        3: begin // Mixed R/W
          current_attack = ATTACK_MIXED_OUTSTANDING;
          current_injection_delay = INJECTION_DELAY_AGGRESSIVE;
          current_burst_len = BURST_LEN_MED;
        end
        4: begin // Variable bursts
          current_attack = ATTACK_VARIABLE_BURST;
          current_injection_delay = INJECTION_DELAY_AGGRESSIVE;
          current_burst_len = BURST_LEN_MED;
        end
      endcase

      $display("╔══════════════════════════════════════════════════════════════════╗");
      $display("║  ATTACK MODE %0d: %-47s║", mode+1, attack_names[mode]);
      $display("║  Injection: %3dns | Burst: %3d beats | Outstanding: %0d          ║",
               current_injection_delay, current_burst_len+1, OUTSTANDING_DEPTH);
      $display("╚══════════════════════════════════════════════════════════════════╝\n");

      attack_enable = 1;
      #20000ns;

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

            if (read_data != expected_data &&
                current_attack inside {ATTACK_OUTSTANDING_WRITE, ATTACK_MIXED_OUTSTANDING, ATTACK_VARIABLE_BURST}) begin
              victim_errors++;
              $display("[VICTIM] #%02d: ✗ CORRUPTED! Latency: %.0f ns (%.1fx)",
                       v+1, latency, latency/baseline_latency);
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
            $display("[VICTIM] #%02d: ✗ TIMEOUT (Bus saturated by outstanding txns)", v+1);
          end
        join_any
        disable victim_tx;
        #800ns;
      end

      attack_enable = 0;
      current_attack = ATTACK_NONE;
      $display("[INFO] Attack mode %0d completed. Waiting for bus to settle...\n", mode+1);
      #10000ns;

      if (victim_success > 0) avg_attack /= victim_success;
      results_latency[mode] = avg_attack;
      results_timeout[mode] = victim_timeout;
      results_corrupt[mode] = victim_errors;
      results_impact[mode] = 100.0 * (victim_timeout + victim_errors) / victim_attempts;
     
      #2000ns;
    end

    test_done = 1;
   
    print_comparison(attack_names, results_latency, results_timeout,
                     results_corrupt, results_impact, avg_baseline);
   
    #1000ns;
    $finish;
  end

  // ══════════════════════════════════════════════════════════════════════════
  // REPORT GENERATION (FIXED: Automatic)
  // ══════════════════════════════════════════════════════════════════════════
  task automatic print_comparison(
    input string names[5],
    input real latencies[5],
    input int timeouts[5],
    input int corrupts[5],
    input real impacts[5],
    input real baseline
  );
    int best_mode = 0;
    real best_latency = 0;
    real best_impact = 0;
   
    $display("\n╔═══════════════════════════════════════════════════════════════════════════════╗");
    $display("║          ATTACK EFFECTIVENESS REPORT (Outstanding Transactions)             ║");
    $display("╠═══════════════════════════════════════════════════════════════════════════════╣");
    $display("║  Baseline Latency: %.0f ns                                                 ║", baseline);
    $display("║  Target: 4x-5x latency increase                                               ║");
    $display("║  Outstanding Depth: %0d transactions per attacker                             ║", OUTSTANDING_DEPTH);
    $display("╠═══════════════════════════════════════════════════════════════════════════════╣");
    $display("║  Attack Mode                         Latency    Slowdown  Timeouts  Corrupted  ║");
    $display("╠═══════════════════════════════════════════════════════════════════════════════╣");
   
    for (int i = 0; i < 5; i++) begin
      string marker = "";
      real slowdown = (baseline > 0) ? latencies[i] / baseline : 0;
     
      if (slowdown > best_latency) begin
        best_latency = slowdown;
        best_mode = i;
      end
      if (impacts[i] > best_impact) best_impact = impacts[i];
     
      if (slowdown >= 5.0) marker = "🎯✓";
      else if (slowdown >= 4.0) marker = "✓";
      else if (slowdown >= 2.0) marker = "~";
     
      $display("║  %-33s  %7.0f ns   %6.1fx       %4d        %4d  %-3s ║",
               names[i], latencies[i], slowdown,
               timeouts[i], corrupts[i], marker);
    end
   
    $display("╠═══════════════════════════════════════════════════════════════════════════════╣");
    $display("║  🏆 Best Latency Attack: %-52s ║", names[best_mode]);
    $display("║     Achieved: %.1fx slowdown                                                 ║", best_latency);
    if (best_latency >= 4.0)
      $display("║     ✓ SUCCESS: Target 4x-5x achieved!                                        ║");
    else
      $display("║     ⚠ Below target - consider more aggressive parameters                     ║");
    $display("╚═══════════════════════════════════════════════════════════════════════════════╝\n");
  endtask

endmodule