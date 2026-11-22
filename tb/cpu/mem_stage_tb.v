`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench autoverificable de mem_stage.v (etapa MEM + latch MEM/WB) con la
// BRAM real (modelo de simulacion del IP data_mem).
//
// El TB hace de "etapa EX": en cada flanco de bajada carga el latch EX/MEM con
// una instruccion (tasks lw, sw, sb, ...). Un flanco de subida despues, la
// instruccion esta en MEM/WB y se chequea el resultado.
//
// Contenido inicial de la memoria (coe/data_init.coe): palabra i = i, o sea
// lw desde la direccion 4*i devuelve i.

module mem_stage_tb;

    reg clk = 0, reset = 1, en = 1;
    always #5 clk = ~clk;

    // ---- Latch EX/MEM (lo maneja el TB) ----
    reg [31:0] ex_mem_result, ex_mem_rs2_data;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_mem_read, ex_mem_mem_write, ex_mem_reg_write, ex_mem_halt;
    reg [1:0]  ex_mem_wb_sel;
    reg [9:0]  dbg_addr = 0;

    wire [31:0] dbg_rdata;
    wire [31:0] mem_wb_result, mem_wb_read_data, mem_wb_load_data;
    wire [4:0]  mem_wb_rd;
    wire [2:0]  mem_wb_funct3;
    wire [1:0]  mem_wb_addr_lo, mem_wb_wb_sel;
    wire        mem_wb_mem_read, mem_wb_reg_write, mem_wb_halt;

    mem_stage dut (
        .clk(clk), .reset(reset), .en(en),
        .ex_mem_result(ex_mem_result), .ex_mem_rs2_data(ex_mem_rs2_data),
        .ex_mem_rd(ex_mem_rd), .ex_mem_funct3(ex_mem_funct3),
        .ex_mem_mem_read(ex_mem_mem_read), .ex_mem_mem_write(ex_mem_mem_write),
        .ex_mem_reg_write(ex_mem_reg_write), .ex_mem_wb_sel(ex_mem_wb_sel),
        .ex_mem_halt(ex_mem_halt),
        .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata),
        .mem_wb_result(mem_wb_result), .mem_wb_read_data(mem_wb_read_data),
        .mem_wb_load_data(mem_wb_load_data), .mem_wb_rd(mem_wb_rd),
        .mem_wb_funct3(mem_wb_funct3), .mem_wb_addr_lo(mem_wb_addr_lo),
        .mem_wb_mem_read(mem_wb_mem_read), .mem_wb_reg_write(mem_wb_reg_write),
        .mem_wb_wb_sel(mem_wb_wb_sel), .mem_wb_halt(mem_wb_halt)
    );

    integer checks = 0, errors = 0;

    task expect(input [31:0] got, input [31:0] exp, input [8*44-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %h, esperaba %h  (t=%0t)", what, got, exp, $time);
            end else
                $display("OK    %0s = %h", what, got);
        end
    endtask

    // ---------------------------------------------------------------
    // "Etapa EX" de mentira: cargan EX/MEM como lo haria ex_stage
    // ---------------------------------------------------------------
    task nop;
        begin
            ex_mem_result = 0; ex_mem_rs2_data = 0; ex_mem_rd = 0; ex_mem_funct3 = 0;
            ex_mem_mem_read = 0; ex_mem_mem_write = 0; ex_mem_reg_write = 0;
            ex_mem_wb_sel = `WB_ALU; ex_mem_halt = 0;
        end
    endtask

    task load(input [2:0] f3, input [4:0] rd, input [31:0] addr);
        begin
            nop;
            ex_mem_result = addr; ex_mem_rd = rd; ex_mem_funct3 = f3;
            ex_mem_mem_read = 1; ex_mem_reg_write = 1; ex_mem_wb_sel = `WB_MEM;
        end
    endtask

    task store(input [2:0] f3, input [31:0] addr, input [31:0] data);
        begin
            nop;
            ex_mem_result = addr; ex_mem_rs2_data = data; ex_mem_funct3 = f3;
            ex_mem_mem_write = 1;
        end
    endtask

    // Instruccion de ALU (add x?, ...): no toca la memoria
    task alu(input [4:0] rd, input [31:0] res);
        begin
            nop;
            ex_mem_result = res; ex_mem_rd = rd; ex_mem_reg_write = 1;
            ex_mem_rs2_data = 32'hBAD0BAD0;   // basura: no se tiene que escribir
        end
    endtask

    // Pasa la instruccion de EX/MEM a MEM/WB
    task clock;
        begin @(posedge clk); #1; end
    endtask

    // Ejecuta un load y chequea lo que llega a WB
    task check_load(input [2:0] f3, input [31:0] addr, input [31:0] exp,
                    input [8*44-1:0] what);
        begin
            @(negedge clk); load(f3, 5, addr); clock;
            expect(mem_wb_load_data, exp, what);
        end
    endtask

    task do_store(input [2:0] f3, input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk); store(f3, addr, data); clock;
        end
    endtask

    // Lee una palabra por el puerto de debug (lectura sincronica)
    task check_dbg(input [9:0] word, input [31:0] exp, input [8*44-1:0] what);
        begin
            @(negedge clk); dbg_addr = word; clock;
            expect(dbg_rdata, exp, what);
        end
    endtask

    initial begin
        nop;

        // ---------------- 1. Reset ----------------
        @(negedge clk); @(negedge clk);
        reset = 0;
        expect(mem_wb_result,    0, "reset: result");
        expect(mem_wb_read_data, 0, "reset: read_data (enmascarado)");
        expect(mem_wb_load_data, 0, "reset: load_data");
        expect(mem_wb_reg_write, 0, "reset: reg_write");

        // ---------------- 2. Contenido inicial (palabra i = i) ----------------
        check_load(`F3_LW, 32'h000, 32'd0,    "lw 0x000 = palabra 0");
        check_load(`F3_LW, 32'h004, 32'd1,    "lw 0x004 = palabra 1");
        check_load(`F3_LW, 32'h028, 32'd10,   "lw 0x028 = palabra 10");
        check_load(`F3_LW, 32'hFFC, 32'd1023, "lw 0xFFC = palabra 1023");
        expect(mem_wb_rd,       5,        "lw: rd");
        expect(mem_wb_reg_write, 1,       "lw: reg_write");
        expect(mem_wb_wb_sel,   `WB_MEM,  "lw: wb_sel");
        expect(mem_wb_result,   32'hFFC,  "lw: result = direccion");

        // ---------------- 3. sw y lw ----------------
        do_store(`F3_SW, 32'h100, 32'hDEADBEEF);
        expect(mem_wb_read_data, 0, "sw: read_data = 0 (no es load)");
        check_load(`F3_LW, 32'h100, 32'hDEADBEEF, "lw despues de sw");

        // ---------------- 4. sb: escribe un solo byte ----------------
        // palabra 128 (0x200) vale 0x00000080
        do_store(`F3_SB, 32'h201, 32'h123456AB);           // solo el byte 1 = AB
        check_load(`F3_LW, 32'h200, 32'h0000AB80, "sb 0x201: solo el byte 1");
        do_store(`F3_SB, 32'h203, 32'h000000CD);
        check_load(`F3_LW, 32'h200, 32'hCD00AB80, "sb 0x203: byte 3 (little-endian)");
        do_store(`F3_SB, 32'h200, 32'h00000011);
        do_store(`F3_SB, 32'h202, 32'h00000022);
        check_load(`F3_LW, 32'h200, 32'hCD22AB11, "sb a los 4 bytes");

        // ---------------- 5. sh: media palabra ----------------
        // palabra 192 (0x300) vale 0x000000C0
        do_store(`F3_SH, 32'h302, 32'h1234BEEF);           // mitad alta = BEEF
        check_load(`F3_LW, 32'h300, 32'hBEEF00C0, "sh 0x302: mitad alta");
        do_store(`F3_SH, 32'h300, 32'h00005678);
        check_load(`F3_LW, 32'h300, 32'hBEEF5678, "sh 0x300: mitad baja");

        // ---------------- 6. Loads con y sin signo ----------------
        do_store(`F3_SW, 32'h400, 32'h80FF7F01);
        // bytes: [0x400]=01 [0x401]=7F [0x402]=FF [0x403]=80
        check_load(`F3_LB,  32'h400, 32'h00000001, "lb  0x400 = 01");
        check_load(`F3_LB,  32'h401, 32'h0000007F, "lb  0x401 = 7F (positivo)");
        check_load(`F3_LB,  32'h402, 32'hFFFFFFFF, "lb  0x402 = FF -> -1");
        check_load(`F3_LB,  32'h403, 32'hFFFFFF80, "lb  0x403 = 80 -> -128");
        check_load(`F3_LBU, 32'h402, 32'h000000FF, "lbu 0x402 = FF -> 255");
        check_load(`F3_LBU, 32'h403, 32'h00000080, "lbu 0x403 = 80 -> 128");
        check_load(`F3_LH,  32'h400, 32'h00007F01, "lh  0x400 = 7F01 (positivo)");
        check_load(`F3_LH,  32'h402, 32'hFFFF80FF, "lh  0x402 = 80FF (negativo)");
        check_load(`F3_LHU, 32'h402, 32'h000080FF, "lhu 0x402 = 80FF sin signo");
        check_load(`F3_LW,  32'h400, 32'h80FF7F01, "lw  0x400 completa");

        // ---------------- 7. Desalineados (decision 1-A) ----------------
        check_load(`F3_LW, 32'h402, 32'h80FF7F01, "lw 0x402: usa la palabra alineada");
        check_load(`F3_LH, 32'h403, 32'hFFFF80FF, "lh 0x403: usa addr[1]");

        // ---------------- 8. Instruccion de ALU: no toca memoria ----------------
        // add x7 con resultado 0x500 (parece direccion) y rs2 basura
        @(negedge clk); alu(7, 32'h500); clock;
        expect(mem_wb_result,    32'h500, "alu: result pasa a MEM/WB");
        expect(mem_wb_read_data, 0,       "alu: read_data = 0");
        expect(mem_wb_load_data, 0,       "alu: load_data = 0");
        expect(mem_wb_wb_sel,    `WB_ALU, "alu: wb_sel");
        check_load(`F3_LW, 32'h500, 32'd320, "alu no escribio (palabra 320)");

        // ---------------- 9. sw seguido de lw (ciclos consecutivos) ----------------
        @(negedge clk); store(`F3_SW, 32'h600, 32'hCAFE0006);
        @(negedge clk); load(`F3_LW, 9, 32'h600); clock;
        expect(mem_wb_load_data, 32'hCAFE0006, "sw y lw pegados: dato nuevo");

        // ---------------- 10. en = 0 congela ----------------
        @(negedge clk); load(`F3_LW, 10, 32'h004); clock;    // MEM/WB = 1
        @(negedge clk);
        en = 0;
        store(`F3_SW, 32'h004, 32'hFFFFFFFF);               // no se tiene que escribir
        clock; clock;
        expect(mem_wb_load_data, 32'd1, "en=0: dato del load se mantiene");
        expect(mem_wb_rd,        10,    "en=0: rd se mantiene");
        @(negedge clk);
        en = 1;
        nop;
        check_load(`F3_LW, 32'h004, 32'd1, "en=0: el sw no escribio");

        // ---------------- 11. Puerto de debug ----------------
        check_dbg(10'd256, 32'h80FF7F01, "debug: palabra 256 (0x400)");
        check_dbg(10'd128, 32'hCD22AB11, "debug: palabra 128 (los sb)");
        check_dbg(10'd1000, 32'd1000,    "debug: palabra 1000 (inicial)");

        // ---------------- 12. HALT viaja ----------------
        @(negedge clk); nop; ex_mem_halt = 1; clock;
        expect(mem_wb_halt, 1, "ebreak: halt pasa a MEM/WB");

        // ---------------- 13. Reset en el medio ----------------
        @(negedge clk); load(`F3_LW, 3, 32'h008); clock;
        @(negedge clk); reset = 1; nop; clock;
        expect(mem_wb_halt,      0, "reset: halt");
        expect(mem_wb_load_data, 0, "reset: load_data");
        expect(mem_wb_rd,        0, "reset: rd");
        reset = 0;

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
