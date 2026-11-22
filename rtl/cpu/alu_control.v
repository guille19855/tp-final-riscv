`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Control de la ALU: segundo nivel del control (cátedra, "3. Processor",
// diapositivas 10-11).
//
// La unidad de control principal (ID) solo mira el opcode y manda un ALUOp de
// 2 bits que dice "de que familia" es la instruccion. Aca, en EX, se combina
// con funct3 y el bit 30 de la instruccion para elegir la operacion exacta:
//
//   ALUOp | instrucciones           | operacion
//   ------+-------------------------+--------------------------------------
//    00   | loads, stores, jalr,lui | ADD (direccion o rs1+imm, 0+imm)
//    01   | beq, bne                | SUB (zero = 1 si rs1 == rs2)
//    10   | tipo R                  | {bit30, funct3}
//    11   | tipo I aritmetico       | {bit30 solo si es shift, funct3}
//
// TRAMPA del tipo I: en addi/andi/... el bit 30 es parte del INMEDIATO.
// Ej: addi x1, x1, -1 tiene imm = 0xFFF -> bit 30 = 1. Si se usara como en
// tipo R, el addi se convertiria en SUB. Solo en srli/srai el bit 30 es
// parte de la instruccion (funct7 = 0000000 o 0100000), por eso solo se usa
// cuando funct3 = 101.

module alu_control (
    input  wire [1:0] alu_op,
    input  wire [2:0] funct3,
    input  wire       funct7b5,   // bit 30 de la instruccion
    output reg  [3:0] alu_ctrl
);

    always @(*) begin
        case (alu_op)
            `ALUOP_ADD: alu_ctrl = `ALU_ADD;
            `ALUOP_SUB: alu_ctrl = `ALU_SUB;
            `ALUOP_R:   alu_ctrl = {funct7b5, funct3};
            `ALUOP_I:   alu_ctrl = {(funct3 == `F3_SRL_SRA) & funct7b5, funct3};
            default:    alu_ctrl = `ALU_ADD;
        endcase
    end

endmodule
