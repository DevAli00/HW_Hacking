`timescale 1ns / 1ps

// ════════════════════════════════════════════════════════════════════════════
// AXI DoS ATTACK 1: OUTSTANDING READ FLOOD (SAFE VERSION)
// ════════════════════════════════════════════════════════════════════════════

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*;
import design_1_axi_vip_1_0_pkg::*;
import design_1_axi_vip_2_0_pkg::*;
import design_1_axi_vip_3_0_pkg::*;

module tb_attack_read();

  // ══════════════════════════════════════════════════════════════════════════
  // CONFIGURATION
  // ══════════════════════════════════════════════════════════════════════════
  localparam bit [31:0] SHARED_ADDR = 32'h4000_0000;
  localparam int BURST_LEN = 255;       // 256 beats
  localparam int OUTSTANDING_DEPTH = 16;
  localparam int INJECTION_DELAY = 10;  // Aggressive

  // ══════════════════════════════════════════════════════════════════════════
  // SIGNALS & AGENTS
  // ══════════════════════════════════════════════════════════════════════════
  bit clock;
  bit reset_n;

  // Déclaration des agents (doivent être construits avant usage)
  design_1_axi_vip_0_0_mst_t victim_agent;
  design_1_axi_vip_1_0_mst_t attacker1_agent;
  design_1_axi_vip_2_0_mst_t attacker2_agent;
  design_1_axi_vip_3_0_mst_t attacker3_agent;

  // Control
  bit attack_enable = 0;
  bit test_done = 0;

  design_1 design_1_i (
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );

  always #5ns clock <= ~clock;

  // ══════════════════════════════════════════════════════════════════════════
  // MAIN TEST SEQUENCE (Tout fusionné ici pour éviter le Null Object Error)
  // ══════════════════════════════════════════════════════════════════════════
  initial begin
    // Variables locales
    bit [31:0] write_data, read_data;
    xil_axi_resp_t resp;
    realtime t_start, t_end, latency;
    real avg_baseline, avg_attack;
    int victim_attempts = 0;
    int victim_success = 0;
    int victim_timeout = 0;
    realtime attack_latencies[$];

    // 1. CONSTRUCTION DES AGENTS (L'étape qui manquait avant le start)
    victim_agent    = new("Victim", design_1_i.axi_vip_0.inst.IF);
    attacker1_agent = new("Attacker1", design_1_i.axi_vip_1.inst.IF);
    attacker2_agent = new("Attacker2", design_1_i.axi_vip_2.inst.IF);
    attacker3_agent = new("Attacker3", design_1_i.axi_vip_3.inst.IF);

    // 2. CONFIGURATION DES LIMITES (Pour éviter le crash FIFO overflow)
    attacker1_agent.rd_driver.set_transaction_depth(4096);
    attacker1_agent.rd_driver.seq_item_port.set_max_item_cnt(10000);
    
    attacker2_agent.rd_driver.set_transaction_depth(4096);
    attacker2_agent.rd_driver.seq_item_port.set_max_item_cnt(10000);
    
    attacker3_agent.rd_driver.set_transaction_depth(4096);
    attacker3_agent.rd_driver.seq_item_port.set_max_item_cnt(10000);

    // 3. DEMARRAGE DES AGENTS
    victim_agent.start_master();
    attacker1_agent.start_master();
    attacker2_agent.start_master();
    attacker3_agent.start_master();

    // 4. LANCEMENT DES ATTAQUANTS EN PARALLELE (Threads)
    // On utilise fork/join_none pour que ces boucles tournent en fond
    fork
        // --- Thread Attaquant 1 ---
        begin
            axi_transaction trans_queue[$]; axi_transaction trans; bit [31:0] addr; int op_count = 0;
            forever begin 
                wait(attack_enable); 
                while (attack_enable && !test_done) begin
                    addr = SHARED_ADDR + ((op_count % 256) * 4);
                    trans = attacker1_agent.rd_driver.create_transaction("atk1_rd");
                    trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, BURST_LEN, XIL_AXI_SIZE_4BYTE);
                    trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN);
                    attacker1_agent.rd_driver.send(trans);
                    trans_queue.push_back(trans);
                    if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
                        trans = trans_queue.pop_front();
                        attacker1_agent.rd_driver.wait_rsp(trans);
                    end
                    op_count++; #(INJECTION_DELAY * 1ns);
                end 
                while(trans_queue.size() > 0) begin trans=trans_queue.pop_front(); attacker1_agent.rd_driver.wait_rsp(trans); end
                @(posedge clock);
            end
        end

        // --- Thread Attaquant 2 ---
        begin
            axi_transaction trans_queue[$]; axi_transaction trans; bit [31:0] addr; int op_count = 0;
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
                    op_count++; #(INJECTION_DELAY * 1ns);
                end 
                while(trans_queue.size() > 0) begin trans=trans_queue.pop_front(); attacker2_agent.rd_driver.wait_rsp(trans); end
                @(posedge clock);
            end
        end

        // --- Thread Attaquant 3 ---
        begin
            axi_transaction trans_queue[$]; axi_transaction trans; bit [31:0] addr; int op_count = 0;
            forever begin 
                wait(attack_enable); 
                while (attack_enable && !test_done) begin
                    addr = SHARED_ADDR + ((op_count % 256) * 4) + 2048;
                    trans = attacker3_agent.rd_driver.create_transaction("atk3_rd");
                    trans.set_read_cmd(addr, XIL_AXI_BURST_TYPE_INCR, 0, BURST_LEN, XIL_AXI_SIZE_4BYTE);
                    trans.set_driver_return_item_policy(XIL_AXI_NO_RETURN);
                    attacker3_agent.rd_driver.send(trans);
                    trans_queue.push_back(trans);
                    if (trans_queue.size() >= OUTSTANDING_DEPTH) begin
                        trans = trans_queue.pop_front();
                        attacker3_agent.rd_driver.wait_rsp(trans);
                    end
                    op_count++; #(INJECTION_DELAY * 1ns);
                end 
                while(trans_queue.size() > 0) begin trans=trans_queue.pop_front(); attacker3_agent.rd_driver.wait_rsp(trans); end
                @(posedge clock);
            end
        end
    join_none

    // 5. SEQUENCE DE TEST VICTIME
    reset_n = 0; #200ns; reset_n = 1; #500ns;

    // --- BASELINE ---
    $display("╔══════════════════════════════════════════════════════════════════╗");
    $display("║  ATTACK 1: OUTSTANDING READ FLOOD                                ║");
    $display("╚══════════════════════════════════════════════════════════════════╝\n");
    
    // Ecriture données initiales
    for (int i = 0; i < 256; i++) begin
      write_data = 32'hCAFE_0000 | i;
      victim_agent.AXI4LITE_WRITE_BURST(SHARED_ADDR + i*4, 0, write_data, resp);
    end

    avg_baseline = 0;
    for (int i = 0; i < 10; i++) begin
      t_start = $realtime;
      victim_agent.AXI4LITE_READ_BURST(SHARED_ADDR + i*4, 0, read_data, resp);
      t_end = $realtime;
      avg_baseline += (t_end - t_start);
    end
    avg_baseline /= 10.0;
    $display("[BASELINE] Average Latency: %.0f ns\n", avg_baseline);

    #2000ns;

    // --- ATTAQUE ---
    $display("Starting Attack...");
    attack_enable = 1;
    #20000ns; // Warmup

    avg_attack = 0;
    for (int v = 0; v < 10; v++) begin
      bit tx_done = 0;
      victim_attempts++;
      t_start = $realtime;

      fork
        begin
          victim_agent.AXI4LITE_READ_BURST(SHARED_ADDR + v*4, 0, read_data, resp);
          t_end = $realtime;
          latency = t_end - t_start;
          tx_done = 1;
        end
        begin
          #200000ns; // Timeout
        end
      join_any

      if (tx_done) begin
        victim_success++;
        avg_attack += latency;
        $display("[VICTIM] #%02d: Latency %.0f ns (%.1fx)", v+1, latency, latency/avg_baseline);
      end else begin
        victim_timeout++;
        $display("[VICTIM] #%02d: ✗ TIMEOUT", v+1);
        wait(tx_done); // On attend quand même pour ne pas désynchroniser le bus
      end
      #800ns;
    end

    attack_enable = 0;
    test_done = 1;
    #2000ns;

    if (victim_success > 0) avg_attack /= victim_success;
    $display("\n[RESULT] Final Avg Latency: %.0f ns (%.1fx slowdown)", avg_attack, avg_attack/avg_baseline);
    
    $finish;
  end

endmodule