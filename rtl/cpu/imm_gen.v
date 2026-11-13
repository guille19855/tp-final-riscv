// Generador de inmediatos (Imm Gen) - etapa ID.
//
// Arma el inmediato de 32 bits a partir de los bits de la instruccion.
// RISC-V tiene 5 formatos de inmediato y en cada uno los bits estan en
// lugares distintos. La unidad de control dice cual usar (imm_sel).
//
// Dos reglas que valen para todos los formatos:
//  1) El bit de signo SIEMPRE es instr[31]. Por eso la extension de signo
//     se puede hacer igual en todos los formatos (y en paralelo con el
//     decodificado: no hace falta saber el formato para saber el signo).
//  2) B y J no guardan el bit 0 del offset: los saltos son a direcciones
//     pares, asi que el bit 0 se agrega como 0 y el rango se duplica.
//
// Es combinacional pura: no tiene clock.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module imm_gen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_sel,    // `IMM_I, `IMM_S, `IMM_B, `IMM_U, `IMM_J
    output reg  [31:0] imm
);

    wire s = instr[31];            // bit de signo, igual en los 5 formatos

    always @(*) begin
        case (imm_sel)
            // I: addi, loads, jalr.  imm[11:0] = instr[31:20]
            `IMM_I: imm = {{20{s}}, instr[31:20]};

            // S: stores.  imm[11:5] = instr[31:25], imm[4:0] = instr[11:7]
            // (rd no existe en un store: esos bits son la parte baja del imm)
            `IMM_S: imm = {{20{s}}, instr[31:25], instr[11:7]};

            // B: branches.  imm[12|10:5] = instr[31:25], imm[4:1|11] = instr[11:7]
            `IMM_B: imm = {{19{s}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

            // U: lui.  imm[31:12] = instr[31:12], parte baja en 0
            `IMM_U: imm = {instr[31:12], 12'b0};

            // J: jal.  imm[20|10:1|11|19:12] = instr[31:12]
            `IMM_J: imm = {{11{s}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

            default: imm = 32'd0;
        endcase
    end

endmodule
