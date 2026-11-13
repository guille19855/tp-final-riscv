// Unidad de control principal (etapa ID).
//
// Mira SOLO el opcode (instr[6:0]) y genera las senales de control de toda la
// instruccion. Es combinacional pura: no tiene clock ni registros. Las senales
// que usan EX, MEM y WB viajan despues por los latches ID/EX, EX/MEM y MEM/WB.
//
// Cada fila del "case" es una fila de la tabla de docs/tabla_control.html.
// Lo que distingue instrucciones dentro de una misma familia (add vs sub,
// lb vs lw) NO se decide aca: lo deciden funct3 y el bit 30, que viajan
// junto con la instruccion hasta la etapa que los necesita.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module control_unit (
    input  wire [6:0] opcode,

    // --- usadas en ID ---
    output reg  [2:0] imm_sel,     // formato del inmediato (`IMM_I ... `IMM_J)
    output reg        usa_rs1,     // la instruccion lee rs1 (para la unidad de hazard)
    output reg        usa_rs2,     // la instruccion lee rs2 (para la unidad de hazard)
    output reg        halt,        // ebreak: dejar de buscar instrucciones

    // --- usadas en EX ---
    output reg        alu_src_a,   // 0 = rs1, 1 = cero (lui)
    output reg        alu_src_b,   // 0 = rs2, 1 = inmediato
    output reg  [1:0] alu_op,      // primer nivel del control de la ALU
    output reg        branch,      // beq/bne: saltar si se cumple la condicion
    output reg        jal,         // salto incondicional a PC + imm
    output reg        jalr,        // salto incondicional a (rs1 + imm) & ~1

    // --- usadas en MEM ---
    output reg        mem_read,    // load
    output reg        mem_write,   // store

    // --- usadas en WB ---
    output reg        reg_write,   // escribir rd
    output reg  [1:0] wb_sel       // que se escribe en rd (`WB_ALU, `WB_MEM, `WB_PC4)
);

    always @(*) begin
        // Valores por defecto = NOP: nada escribe, nada salta.
        // Asi un opcode desconocido no corrompe registros ni memoria, y
        // ademas evita que la sintesis infiera latches (toda salida tiene
        // valor en todos los caminos).
        imm_sel   = `IMM_I;
        usa_rs1   = 1'b0;
        usa_rs2   = 1'b0;
        halt      = 1'b0;
        alu_src_a = 1'b0;
        alu_src_b = 1'b0;
        alu_op    = `ALUOP_ADD;
        branch    = 1'b0;
        jal       = 1'b0;
        jalr      = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        reg_write = 1'b0;
        wb_sel    = `WB_ALU;

        case (opcode)
            `OP_R: begin                       // add sub sll ... : rd = rs1 op rs2
                usa_rs1   = 1'b1;
                usa_rs2   = 1'b1;
                alu_op    = `ALUOP_R;
                reg_write = 1'b1;
            end

            `OP_IMM: begin                     // addi andi ... : rd = rs1 op imm
                imm_sel   = `IMM_I;
                usa_rs1   = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = `ALUOP_I;
                reg_write = 1'b1;
            end

            `OP_LOAD: begin                    // lb lh lw ... : rd = Mem[rs1 + imm]
                imm_sel   = `IMM_I;
                usa_rs1   = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = `ALUOP_ADD;
                mem_read  = 1'b1;
                reg_write = 1'b1;
                wb_sel    = `WB_MEM;
            end

            `OP_STORE: begin                   // sb sh sw : Mem[rs1 + imm] = rs2
                imm_sel   = `IMM_S;
                usa_rs1   = 1'b1;
                usa_rs2   = 1'b1;              // el dato a guardar sale de rs2
                alu_src_b = 1'b1;
                alu_op    = `ALUOP_ADD;
                mem_write = 1'b1;
            end

            `OP_BRANCH: begin                  // beq bne : si (rs1 ? rs2) PC = PC + imm
                imm_sel   = `IMM_B;
                usa_rs1   = 1'b1;
                usa_rs2   = 1'b1;
                alu_op    = `ALUOP_SUB;        // rs1 - rs2, se mira el flag zero
                branch    = 1'b1;
            end

            `OP_JAL: begin                     // jal : rd = PC + 4 ; PC = PC + imm
                imm_sel   = `IMM_J;
                jal       = 1'b1;
                reg_write = 1'b1;
                wb_sel    = `WB_PC4;
            end

            `OP_JALR: begin                    // jalr : rd = PC + 4 ; PC = (rs1 + imm) & ~1
                imm_sel   = `IMM_I;
                usa_rs1   = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = `ALUOP_ADD;
                jalr      = 1'b1;
                reg_write = 1'b1;
                wb_sel    = `WB_PC4;
            end

            `OP_LUI: begin                     // lui : rd = imm << 12  (= 0 + imm)
                imm_sel   = `IMM_U;
                alu_src_a = 1'b1;              // primer operando = 0
                alu_src_b = 1'b1;
                alu_op    = `ALUOP_ADD;
                reg_write = 1'b1;
            end

            `OP_SYSTEM: begin                  // ebreak : HALT
                halt      = 1'b1;
            end

            default: ;                         // opcode desconocido: queda NOP
        endcase
    end

endmodule
