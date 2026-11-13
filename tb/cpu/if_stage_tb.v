`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench de la etapa IF (if_stage.v + BRAM instr_mem).
//
// La BRAM arranca con coe/instr_test.coe: la palabra i vale 0xC0DE0000 + i,
// asi que una instruccion "C0DE0005" tuvo que salir de PC = 20.
//
// Las senales que en el procesador real vienen de otras etapas (stall y
// halt de ID, branch_taken de EX, puerto B de la Debug Unit) aca se manejan
// a mano. Las entradas se cambian en el flanco de bajada y los chequeos se
// hacen 1 ns despues del flanco de subida, asi nunca hay carreras.

module if_stage_tb;

    localparam integer CLK_PERIOD = 10;

    reg         clk = 1'b0;
    reg         reset, en, stall, halt, branch_taken;
    reg  [31:0] branch_target;
    reg         dbg_we;
    reg  [9:0]  dbg_addr;
    reg  [31:0] dbg_wdata;
    wire [31:0] dbg_rdata;
    wire [31:0] if_id_pc, if_id_pc4, if_id_instr, pc;
    wire        if_id_valid;

    integer errors = 0;
    integer checks = 0;

    if_stage dut (
        .clk           (clk),
        .reset         (reset),
        .en            (en),
        .stall         (stall),
        .halt          (halt),
        .branch_taken  (branch_taken),
        .branch_target (branch_target),
        .dbg_we        (dbg_we),
        .dbg_addr      (dbg_addr),
        .dbg_wdata     (dbg_wdata),
        .dbg_rdata     (dbg_rdata),
        .if_id_pc      (if_id_pc),
        .if_id_pc4     (if_id_pc4),
        .if_id_instr   (if_id_instr),
        .if_id_valid   (if_id_valid),
        .pc            (pc)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Espera un flanco de subida y deja que las salidas se asienten
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Chequea el estado completo de IF: PC y el contenido de IF/ID
    task expect_state;
        input [31:0]   exp_pc;
        input [31:0]   exp_if_id_pc;
        input [31:0]   exp_instr;
        input          exp_valid;
        input [8*40:1] what;
        begin
            checks = checks + 1;
            if (pc === exp_pc && if_id_valid === exp_valid && if_id_instr === exp_instr &&
                (!exp_valid || (if_id_pc === exp_if_id_pc && if_id_pc4 === exp_if_id_pc + 4))) begin
                $display("OK   %0s: PC=%h  IF/ID={pc=%h instr=%h valid=%b}",
                         what, pc, if_id_pc, if_id_instr, if_id_valid);
            end else begin
                errors = errors + 1;
                $display("FAIL %0s: PC=%h (esperado %h)  IF/ID={pc=%h instr=%h valid=%b} (esperado pc=%h instr=%h valid=%b)",
                         what, pc, exp_pc, if_id_pc, if_id_instr, if_id_valid,
                         exp_if_id_pc, exp_instr, exp_valid);
            end
        end
    endtask

    function [31:0] word;   // contenido inicial de la palabra i
        input integer i;
        word = 32'hC0DE0000 + i;
    endfunction

    integer k;
    reg [31:0] s_pc, s_if_pc, s_instr;
    reg        s_valid;

    initial begin
        reset = 1; en = 1; stall = 0; halt = 0; branch_taken = 0; branch_target = 0;
        dbg_we = 0; dbg_addr = 0; dbg_wdata = 0;

        // ---- 1. Reset: PC = 0 y IF/ID vacio (ID ve un NOP) ----------------
        tick; tick;
        expect_state(32'h0, 32'h0, `INSTR_NOP, 1'b0, "reset");

        // ---- 2. Avance normal: PC de a 4, instr = mem[PC] -----------------
        @(negedge clk) reset = 0;
        for (k = 1; k <= 5; k = k + 1) begin
            tick;
            expect_state(4*k, 4*(k-1), word(k-1), 1'b1, "avance normal");
        end

        // ---- 3. Stall: PC e IF/ID congelados (BRAM con enable en 0) -------
        @(negedge clk) stall = 1;
        tick; expect_state(32'd20, 32'd16, word(4), 1'b1, "stall ciclo 1");
        tick; expect_state(32'd20, 32'd16, word(4), 1'b1, "stall ciclo 2");
        @(negedge clk) stall = 0;
        tick; expect_state(32'd24, 32'd20, word(5), 1'b1, "fin del stall");

        // ---- 4. Salto: PC = destino y flush de IF/ID ----------------------
        @(negedge clk) begin branch_taken = 1; branch_target = 32'h40; end
        tick; expect_state(32'h40, 32'h0, `INSTR_NOP, 1'b0, "salto a 0x40: flush");
        @(negedge clk) branch_taken = 0;
        tick; expect_state(32'h44, 32'h40, word(16), 1'b1, "primera instr del destino");

        // ---- 5. Salto y stall a la vez: gana el salto ---------------------
        @(negedge clk) begin branch_taken = 1; branch_target = 32'h10; stall = 1; end
        tick; expect_state(32'h10, 32'h0, `INSTR_NOP, 1'b0, "salto+stall: gana salto");
        @(negedge clk) begin branch_taken = 0; stall = 0; end
        tick; expect_state(32'h14, 32'h10, word(4), 1'b1, "despues de salto+stall");

        // ---- 6. Halt: PC quieto y entran NOPs -----------------------------
        @(negedge clk) halt = 1;
        tick; expect_state(32'h14, 32'h0, `INSTR_NOP, 1'b0, "halt ciclo 1");
        tick; expect_state(32'h14, 32'h0, `INSTR_NOP, 1'b0, "halt ciclo 2");
        @(negedge clk) halt = 0;
        tick; expect_state(32'h18, 32'h14, word(5), 1'b1, "sale del halt");

        // ---- 7. en = 0: nada cambia (modo paso a paso, clock intacto) -----
        s_pc = pc; s_if_pc = if_id_pc; s_instr = if_id_instr; s_valid = if_id_valid;
        @(negedge clk) en = 0;
        tick; expect_state(s_pc, s_if_pc, s_instr, s_valid, "en=0 ciclo 1");
        tick; expect_state(s_pc, s_if_pc, s_instr, s_valid, "en=0 ciclo 2");
        tick; expect_state(s_pc, s_if_pc, s_instr, s_valid, "en=0 ciclo 3");
        @(negedge clk) en = 1;
        tick; expect_state(32'h1C, 32'h18, word(6), 1'b1, "en=1: un paso");

        // ---- 8. Puerto B: la Debug Unit escribe y relee -------------------
        @(negedge clk) begin dbg_we = 1; dbg_addr = 10'd50; dbg_wdata = 32'h12345678; end
        tick;
        @(negedge clk) begin dbg_we = 0; dbg_addr = 10'd50; end
        tick;
        checks = checks + 1;
        if (dbg_rdata === 32'h12345678) $display("OK   puerto B: escribe y relee 12345678 en la palabra 50");
        else begin errors = errors + 1; $display("FAIL puerto B: relee %h", dbg_rdata); end
        @(negedge clk) dbg_addr = 10'd3;
        tick;
        checks = checks + 1;
        if (dbg_rdata === word(3)) $display("OK   puerto B: lee el contenido inicial %h", dbg_rdata);
        else begin errors = errors + 1; $display("FAIL puerto B: palabra 3 = %h", dbg_rdata); end

        // ... y el procesador la lee por el puerto A (PC = 50*4 = 200)
        @(negedge clk) begin branch_taken = 1; branch_target = 32'd200; end
        tick;
        @(negedge clk) branch_taken = 0;
        tick; expect_state(32'd204, 32'd200, 32'h12345678, 1'b1, "puerto A lee lo escrito por B");

        // ---- 9. Fin de memoria: PC = 0x1000 vuelve a la palabra 0 ---------
        @(negedge clk) begin branch_taken = 1; branch_target = 32'hFFC; end
        tick;
        @(negedge clk) branch_taken = 0;
        tick; expect_state(32'h1000, 32'hFFC, 32'h0, 1'b1, "ultima palabra (1023)");
        tick; expect_state(32'h1004, 32'h1000, word(0), 1'b1, "PC=0x1000 da la vuelta");

        // ---- 10. Reset en medio de la ejecucion ---------------------------
        @(negedge clk) reset = 1;
        tick; expect_state(32'h0, 32'h0, `INSTR_NOP, 1'b0, "reset en ejecucion");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
