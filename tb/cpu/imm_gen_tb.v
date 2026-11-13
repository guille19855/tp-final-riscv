// Testbench del generador de inmediatos.
//
// Parte 1 - casos dirigidos: instrucciones reales (palabras de 32 bits tal
//   cual las genera un ensamblador RISC-V) con el inmediato que deben dar.
//   Incluye positivos, negativos y los extremos de cada formato.
// Parte 2 - ida y vuelta aleatoria: se elige un inmediato al azar, se
//   "ensambla" en la instruccion con las funciones enc_* (escritas a partir
//   de la tabla de formatos del manual) y se verifica que el Imm Gen
//   devuelva exactamente el mismo valor. 200 casos por formato.
//
// Es combinacional: se cambia la entrada, se espera 1 ns y se compara.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module imm_gen_tb;

    reg  [31:0] instr;
    reg  [2:0]  imm_sel;
    wire [31:0] imm;

    imm_gen dut (.instr(instr), .imm_sel(imm_sel), .imm(imm));

    integer errors = 0, checks = 0;

    task check(input [31:0] word, input [2:0] sel, input [31:0] exp, input [8*20-1:0] name);
        begin
            instr = word; imm_sel = sel;
            #1;
            checks = checks + 1;
            if (imm !== exp) begin
                errors = errors + 1;
                $display("FAIL %-20s %h -> %h (%0d)  esperado %h (%0d)",
                         name, word, imm, $signed(imm), exp, $signed(exp));
            end else if (name != "")
                $display("OK   %-20s %h -> %h (%0d)", name, word, imm, $signed(imm));
        end
    endtask

    // --- "Ensamblador": pone el inmediato en los bits del formato ---
    // (registros/funct3 con valores cualquiera; al Imm Gen no le importan)
    function [31:0] enc_I(input [11:0] i); enc_I = {i, 5'd2, 3'b000, 5'd1, `OP_IMM};               endfunction
    function [31:0] enc_S(input [11:0] i); enc_S = {i[11:5], 5'd5, 5'd6, 3'b010, i[4:0], `OP_STORE};   endfunction
    function [31:0] enc_B(input [12:0] i); enc_B = {i[12], i[10:5], 5'd2, 5'd1, 3'b000, i[4:1], i[11], `OP_BRANCH}; endfunction
    function [31:0] enc_U(input [19:0] i); enc_U = {i, 5'd1, `OP_LUI};                              endfunction
    function [31:0] enc_J(input [20:0] i); enc_J = {i[20], i[10:1], i[11], i[19:12], 5'd1, `OP_JAL}; endfunction

    integer k;
    reg [31:0] r;

    initial begin
        // ---------------- Parte 1: casos dirigidos ----------------
        $display("--- I ---");
        check(32'h07852483, `IMM_I, 32'd120,        "lw x9,120(x10)");
        check(32'hFFF10093, `IMM_I, 32'hFFFFFFFF,   "addi x1,x2,-1");
        check(32'h7FF10093, `IMM_I, 32'd2047,       "addi max +2047");
        check(32'h80010093, `IMM_I, 32'hFFFFF800,   "addi min -2048");
        check(32'h40315093, `IMM_I, 32'h00000403,   "srai x1,x2,3");    // bit 30 queda en el imm
        check(32'h00008067, `IMM_I, 32'd0,          "jalr x0,0(x1)");

        $display("--- S ---");
        check(32'h00532423, `IMM_S, 32'd8,          "sw x5,8(x6)");
        check(32'hFE532E23, `IMM_S, 32'hFFFFFFFC,   "sw x5,-4(x6)");
        check(32'h7E532FA3, `IMM_S, 32'd2047,       "sw max +2047");
        check(32'h80532023, `IMM_S, 32'hFFFFF800,   "sw min -2048");

        $display("--- B ---");
        check(32'h00208863, `IMM_B, 32'd16,         "beq x1,x2,+16");
        check(32'hFE000EE3, `IMM_B, 32'hFFFFFFFC,   "beq x0,x0,-4");
        check(32'h7E209FE3, `IMM_B, 32'd4094,       "bne max +4094");
        check(32'h80209063, `IMM_B, 32'hFFFFF000,   "bne min -4096");

        $display("--- U ---");
        check(32'h123450B7, `IMM_U, 32'h12345000,   "lui x1,0x12345");
        check(32'hFFFFF2B7, `IMM_U, 32'hFFFFF000,   "lui x5,0xFFFFF");

        $display("--- J ---");
        check(32'h008000EF, `IMM_J, 32'd8,          "jal x1,+8");
        check(32'hFFDFF06F, `IMM_J, 32'hFFFFFFFC,   "jal x0,-4 (loop)");
        check(32'h7FFFF0EF, `IMM_J, 32'h000FFFFE,   "jal max +1048574");
        check(32'h800000EF, `IMM_J, 32'hFFF00000,   "jal min -1048576");

        $display("--- imm_sel invalido ---");
        check(32'hFFFFFFFF, 3'd7,   32'd0,          "imm_sel=7 -> 0");

        // ---------------- Parte 2: ida y vuelta aleatoria ----------------
        $display("--- 200 aleatorios por formato ---");
        for (k = 0; k < 200; k = k + 1) begin
            r = $random;
            check(enc_I(r[11:0]),  `IMM_I, {{20{r[11]}}, r[11:0]},       "");
            check(enc_S(r[11:0]),  `IMM_S, {{20{r[11]}}, r[11:0]},       "");
            check(enc_B({r[12:1], 1'b0}), `IMM_B, {{19{r[12]}}, r[12:1], 1'b0}, "");
            check(enc_U(r[31:12]), `IMM_U, {r[31:12], 12'b0},            "");
            check(enc_J({r[20:1], 1'b0}), `IMM_J, {{11{r[20]}}, r[20:1], 1'b0}, "");
        end

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
