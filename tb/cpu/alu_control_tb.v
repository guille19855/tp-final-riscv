`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench autoverificable de alu_control.v.
//
// 1) Casos dirigidos, uno por instruccion del TP, con el funct3 y el bit 30
//    que tiene esa instruccion real. Incluye las trampas:
//      - addi/andi/... con inmediato negativo (bit 30 = 1) -> NO es SUB
//      - loads/stores/branches: funct3 y bit 30 no importan
// 2) Barrido de las 64 combinaciones (ALUOp x funct3 x bit30) contra la regla.

module alu_control_tb;

    reg  [1:0] alu_op;
    reg  [2:0] funct3;
    reg        funct7b5;
    wire [3:0] alu_ctrl;

    alu_control dut (.alu_op(alu_op), .funct3(funct3), .funct7b5(funct7b5),
                     .alu_ctrl(alu_ctrl));

    integer checks = 0, errors = 0;

    task check(input [1:0] op, input [2:0] f3, input b30,
               input [3:0] exp, input [8*26-1:0] what);
        begin
            alu_op = op; funct3 = f3; funct7b5 = b30;
            #1;
            checks = checks + 1;
            if (alu_ctrl !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: ALUOp=%b f3=%b b30=%b -> %b, esperaba %b",
                         what, op, f3, b30, alu_ctrl, exp);
            end else
                $display("OK    %0s -> %b", what, alu_ctrl);
        end
    endtask

    integer o, f, b;
    reg [3:0] exp;

    initial begin
        // ---- Tipo R (ALUOp = 10): {bit30, funct3} ----
        check(`ALUOP_R, 3'b000, 0, `ALU_ADD,  "add");
        check(`ALUOP_R, 3'b000, 1, `ALU_SUB,  "sub");
        check(`ALUOP_R, 3'b001, 0, `ALU_SLL,  "sll");
        check(`ALUOP_R, 3'b010, 0, `ALU_SLT,  "slt");
        check(`ALUOP_R, 3'b011, 0, `ALU_SLTU, "sltu");
        check(`ALUOP_R, 3'b100, 0, `ALU_XOR,  "xor");
        check(`ALUOP_R, 3'b101, 0, `ALU_SRL,  "srl");
        check(`ALUOP_R, 3'b101, 1, `ALU_SRA,  "sra");
        check(`ALUOP_R, 3'b110, 0, `ALU_OR,   "or");
        check(`ALUOP_R, 3'b111, 0, `ALU_AND,  "and");

        // ---- Tipo I aritmetico (ALUOp = 11) ----
        check(`ALUOP_I, 3'b000, 0, `ALU_ADD,  "addi imm positivo");
        check(`ALUOP_I, 3'b000, 1, `ALU_ADD,  "addi imm negativo (!SUB)");
        check(`ALUOP_I, 3'b010, 1, `ALU_SLT,  "slti imm negativo");
        check(`ALUOP_I, 3'b011, 1, `ALU_SLTU, "sltiu imm negativo");
        check(`ALUOP_I, 3'b100, 1, `ALU_XOR,  "xori -1 (not)");
        check(`ALUOP_I, 3'b110, 1, `ALU_OR,   "ori imm negativo");
        check(`ALUOP_I, 3'b111, 1, `ALU_AND,  "andi imm negativo");
        check(`ALUOP_I, 3'b001, 0, `ALU_SLL,  "slli");
        check(`ALUOP_I, 3'b101, 0, `ALU_SRL,  "srli");
        check(`ALUOP_I, 3'b101, 1, `ALU_SRA,  "srai");

        // ---- ALUOp = 00: siempre suma (funct3/bit30 no importan) ----
        check(`ALUOP_ADD, `F3_LW,  1, `ALU_ADD, "lw (imm negativo)");
        check(`ALUOP_ADD, `F3_LBU, 0, `ALU_ADD, "lbu");
        check(`ALUOP_ADD, `F3_LHU, 1, `ALU_ADD, "lhu");
        check(`ALUOP_ADD, `F3_SW,  1, `ALU_ADD, "sw (imm negativo)");
        check(`ALUOP_ADD, `F3_SB,  0, `ALU_ADD, "sb");
        check(`ALUOP_ADD, 3'b000,  1, `ALU_ADD, "jalr (imm negativo)");
        check(`ALUOP_ADD, 3'b101,  1, `ALU_ADD, "lui (bits de imm)");

        // ---- ALUOp = 01: branches, siempre resta ----
        check(`ALUOP_SUB, `F3_BEQ, 0, `ALU_SUB, "beq");
        check(`ALUOP_SUB, `F3_BNE, 1, `ALU_SUB, "bne (offset negativo)");

        // ---- Barrido completo contra la regla ----
        for (o = 0; o < 4; o = o + 1)
            for (f = 0; f < 8; f = f + 1)
                for (b = 0; b < 2; b = b + 1) begin
                    alu_op = o; funct3 = f; funct7b5 = b;
                    #1;
                    case (o)
                        0: exp = `ALU_ADD;
                        1: exp = `ALU_SUB;
                        2: exp = {b[0], f[2:0]};
                        3: exp = {(f == 5) && b[0], f[2:0]};
                    endcase
                    checks = checks + 1;
                    if (alu_ctrl !== exp) begin
                        errors = errors + 1;
                        $display("ERROR barrido: ALUOp=%0d f3=%0d b30=%0d -> %b, esperaba %b",
                                 o, f, b, alu_ctrl, exp);
                    end
                end
        $display("OK    barrido de las 64 combinaciones");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
