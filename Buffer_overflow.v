`timescale 1ns / 1ps

import axi_vip_pkg::*;
import design_1_axi_vip_0_0_pkg::*; 
import design_1_axi_vip_1_0_pkg::*; 

module tb();
     
  bit clock;
  bit reset_n;
  
  design_1_axi_vip_0_0_mst_t master_agent_victim;
  design_1_axi_vip_1_0_mst_t master_agent_attacker;
   
  // Memory map
  xil_axi_ulong BRAM_BASE = 32'h4000_0000;
  xil_axi_ulong ATTACK_ADDR = 32'h4000_2000;
  
  // Metrics
  int attacker_outstanding = 0;
  int attacker_completed = 0;
  int victim_attempts = 0;
  int victim_success = 0;
  int victim_failures = 0;
  int victim_response_errors = 0;
  
  realtime attack_start_time;
  
  // Design under test
  design_1 design_1_i(
    .clk_100MHz(clock),
    .reset_rtl_0(reset_n)
  );
  
  // Clock: 100 MHz (10ns period)
  always #5ns clock <= ~clock;

  initial begin 

    axi_transaction wr_trans;
    xil_axi_resp_t resp;
    bit[31:0] attack_data;

    // Wait for reset release
    @(posedge reset_n);
    #500ns; // Small stabilization delay

    attack_start_time = $realtime;
    $display("[ATTACK] T=%0t: Launching buffer overflow attack...", $time);
    $display("[ATTACK] Strategy: Generate %0d outstanding transactions", 64);

for (int i = 0; i < 128; i++) begin
    attack_data = 32'hBAD00000 | i;

    fork 
        begin
            automatic int trans_id = i;
            master_agent_attacker.AXI4LITE_WRITE_BURST(
                ATTACK_BASE + (trans_id * 4),
                0,
                attack_data,
                resp
            );
            attacker_completed++;
        end
    join_none

    attacker_outstanding++;

    #10ns;
end

$display("[ATTACK] T=%0t: Launched %0d outstanding transactions", 
             $time, attacker_outstanding);

repeat(100) begin
    attack_data = 32'hDEAD0000;

    fork 
        begin
            master_agent_attacker.AXI4LITE_WRITE_BURST(
                ATTACK_BASE + ($urandom() % 256)*4,
                0,
                attack_data,
                resp
            );
        end
    join_none

    #100ns;
end
end


#victim

initial begin
    xil_axi_resp_t resp;
    bit[31:0] victim_data;
    realtime tx_start, tx_end;

    master_agent_victim = new("master_agent_victim", design_1_i.axi_vip_0.inst.IF);
    master_agent_attacker = new("master_agent_attacker", design_1_i.axi_vip_1.inst.IF);

    master_agent_victim.start_master();
    master_agent_attacker.start_master();

    reset_n = 0;
    #200ns;
    reset_n = 1;
    #1000ns;

$display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║        AXI BUFFER OVERFLOW ATTACK - PROOF OF CONCEPT       ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ Attack: Outstanding transaction flooding                   ║");
    $display("║ Target: Interconnect FIFO buffers                          ║");
    $display("╚════════════════════════════════════════════════════════════╝");
    $display("");
    
    // Wait for attack to fill buffers
    #2000ns;
    
    $display("[VICTIM] T=%0t: Attempting transactions during attack...\n", $time);
    
    // Try legitimate transactions
    repeat(15) begin
      victim_attempts++;
      victim_data = 32'hCAFE0000 | victim_attempts[15:0];
      tx_start = $realtime;
      
      $display("[VICTIM] Transaction #%0d:", victim_attempts);
      
      fork
        begin
          master_agent_victim.AXI4LITE_WRITE_BURST(
            BRAM_BASE + victim_attempts * 4,
            0,
            victim_data,
            resp
          );
          
          tx_end = $realtime;
          
          if(resp == XIL_AXI_RESP_OKAY) begin
            victim_success++;
            $display("         ✓ SUCCESS (%.0f ns)", tx_end - tx_start);
          end else begin
            victim_response_errors++;
            $display("         ✗ ERROR RESPONSE: %0d", resp);
          end
        end
        
        begin
          #15000ns; // 15us timeout
          victim_failures++;
          $display("         ✗ TIMEOUT - Buffer likely full");
        end
      join_any
      disable fork;
      
      #1000ns;
    end
    
    // Wait for attacker to complete
    #5000ns;
    
    print_results();
    #100ns;
    $finish;
  end
  
  task print_results();
    real attack_duration = ($realtime - attack_start) / 1000.0;
    real victim_success_rate = 0;
    real victim_error_rate = 0;
    
    if(victim_attempts > 0) begin
      victim_success_rate = 100.0 * victim_success / victim_attempts;
      victim_error_rate = 100.0 * (victim_failures + victim_response_errors) / victim_attempts;
    end
    
    $display("");
    $display("╔════════════════════════════════════════════════════════════╗");
    $display("║              BUFFER OVERFLOW ATTACK RESULTS                ║");
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ ATTACKER METRICS:                                          ║");
    $display("║   • Outstanding Transactions: %10d                    ║", attacker_outstanding);
    $display("║   • Completed Transactions:   %10d                    ║", attacker_completed);
    $display("║   • Attack Duration:          %10.2f µs               ║", attack_duration);
    $display("╠════════════════════════════════════════════════════════════╣");
    $display("║ VICTIM METRICS:                                            ║");
    $display("║   • Total Attempts:           %10d                    ║", victim_attempts);
    $display("║   • Successful:               %10d                    ║", victim_success);
    $display("║   • Timeouts:                 %10d                    ║", victim_failures);
    $display("║   • Error Responses:          %10d                    ║", victim_response_errors);
    $display("║   • Success Rate:             %9.1f %%                ║", victim_success_rate);
    $display("║   • Error Rate:               %9.1f %%                ║", victim_error_rate);
    $display("╠════════════════════════════════════════════════════════════╣");
    
    if(victim_error_rate >= 30.0) begin
      $display("║ ✓ BUFFER OVERFLOW ATTACK SUCCESSFUL                        ║");
      $display("║   Significant degradation/errors detected                  ║");
    end else if(victim_error_rate > 0) begin
      $display("║ ⚠ PARTIAL BUFFER OVERFLOW SUCCESS                         ║");
      $display("║   Some errors but system shows resilience                  ║");
    end else begin
      $display("║ ✗ ATTACK INEFFECTIVE                                      ║");
      $display("║   Interconnect handled all traffic successfully            ║");
    end
    
    $display("╚════════════════════════════════════════════════════════════╝");
  endtask
  
endmodule
