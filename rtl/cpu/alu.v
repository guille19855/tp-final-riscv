`timescale 1ns / 1ps
`include "riscv_defs.vh"

// ALU de 32 bits del procesador (etapa EX).
//
// Combinacional pura: el resultado aparece en el mismo ciclo, sin reloj.
// La operacion llega ya traducida por alu_control.v (codigos `ALU_* de
// riscv_defs.vh, que son {bit30, funct3} de RISC-V).
//
// Detalles de RISC-V que hay que respetar:
//   - Shifts: la cantidad es SOLO b[4:0] (0..31). Para un registro de 32 bits
//     no tiene sentido correr mas; los bits altos de b se ignoran.
//   - SRL rellena con 0, SRA repite el bit de signo (division por 2^n con signo).
//   - SLT compara con signo (-1 < 1), SLTU sin signo (0xFFFFFFFF es el mayor).
//     El resultado es 1 o 0 en el bit 0.
//   - No hay flags de carry ni overflow: RISC-V no los tiene (a diferencia
//     de la ALU del TP1). Para comparar se usa slt/sltu o los branches.
//
// zero = 1 cuando el resultado es 0. Lo usan beq/bne: el control manda SUB y
// rs1 == rs2  <=>  rs1 - rs2 == 0.

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] result,
    output wire        zero
);

    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (op)
            `ALU_ADD:  result = a + b;
            `ALU_SUB:  result = a - b;
            `ALU_SLL:  result = a << shamt;
            `ALU_SLT:  result = {31'd0, $signed(a) < $signed(b)};
            `ALU_SLTU: result = {31'd0, a < b};
            `ALU_XOR:  result = a ^ b;
            `ALU_SRL:  result = a >> shamt;
            `ALU_SRA:  result = $signed(a) >>> shamt;
            `ALU_OR:   result = a | b;
            `ALU_AND:  result = a & b;
            default:   result = 32'd0;   // codigo invalido: no deberia pasar
        endcase
    end

    assign zero = (result == 32'd0);

endmodule
