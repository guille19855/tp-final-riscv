// Etapa EX (Execute) + latch EX/MEM.
//
// Recibe la instruccion del latch ID/EX y:
//   1. elige los operandos correctos  (forwarding_unit + muxes de forwarding)
//   2. calcula                        (alu_control + alu)
//   3. decide si salta y adonde       (sumador PC+imm, zero de la ALU)
//   4. guarda todo en EX/MEM para la etapa MEM del ciclo siguiente
//
// Orden de los muxes (importa):
//
//   rs1_data --[ForwardA]--> a_fwd --[ALUSrcA: a_fwd | 0  ]--> ALU.a
//   rs2_data --[ForwardB]--> b_fwd --[ALUSrcB: b_fwd | imm]--> ALU.b
//                              |
//                              +--> dato a escribir de sw/sh/sb (EX/MEM)
//
// El forwarding va ANTES de ALUSrcB: en "sw x5, 0(x2)" la ALU usa el
// inmediato, pero el dato a guardar (x5) tambien puede venir de una
// instruccion de adelante y tiene que salir forwardeado.
//
// SALTOS (se resuelven aca, decision v1; predict not-taken):
//   beq/bne: la ALU resta (ALUOp = SUB) y zero dice si rs1 == rs2.
//   branch_taken = (branch & condicion) | jal | jalr
//   destino:  beq/bne/jal -> PC + imm   (sumador propio, el "Add" del datapath)
//             jalr        -> (rs1 + imm) & ~1   (lo calcula la ALU; RISC-V
//                            pide poner el bit 0 en 0)
// branch_taken va a IF (carga el PC y vacia IF/ID) y a ID (vacia ID/EX).
// La instruccion que salta es la que esta aca, asi que sigue su camino normal.
//
// RESULTADO (decision 1-A): jal/jalr escriben PC+4 en rd, no el resultado de
// la ALU. Ese mux se hace ACA: ex_mem_result ya es "lo que se va a escribir en
// rd" (salvo en los loads, donde es la direccion). Asi el forwarding desde
// EX/MEM siempre toma ex_mem_result, sin casos especiales, y EX/MEM no
// necesita llevar PC+4.
//
// en = 0 congela el latch (modo paso a paso de la Debug Unit).

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module ex_stage (
    input  wire        clk,
    input  wire        reset,
    input  wire        en,

    // --- Desde el latch ID/EX: datos ---
    input  wire [31:0] id_ex_pc,
    input  wire [31:0] id_ex_pc4,
    input  wire [31:0] id_ex_rs1_data,
    input  wire [31:0] id_ex_rs2_data,
    input  wire [31:0] id_ex_imm,
    input  wire [4:0]  id_ex_rs1,
    input  wire [4:0]  id_ex_rs2,
    input  wire [4:0]  id_ex_rd,
    input  wire [2:0]  id_ex_funct3,
    input  wire        id_ex_funct7b5,

    // --- Desde el latch ID/EX: control ---
    input  wire        id_ex_alu_src_a,
    input  wire        id_ex_alu_src_b,
    input  wire [1:0]  id_ex_alu_op,
    input  wire        id_ex_branch,
    input  wire        id_ex_jal,
    input  wire        id_ex_jalr,
    input  wire        id_ex_mem_read,
    input  wire        id_ex_mem_write,
    input  wire        id_ex_reg_write,
    input  wire [1:0]  id_ex_wb_sel,
    input  wire        id_ex_halt,

    // --- Forwarding desde WB (latch MEM/WB y el valor que se escribe) ---
    input  wire [4:0]  mem_wb_rd,
    input  wire        mem_wb_reg_write,
    input  wire [31:0] wb_data,

    // --- Salto: hacia IF e ID ---
    output wire        branch_taken,
    output wire [31:0] branch_target,

    // --- Latch EX/MEM ---
    output reg  [31:0] ex_mem_result,    // resultado ALU, direccion, o PC+4 (jal/jalr)
    output reg  [31:0] ex_mem_rs2_data,  // dato a escribir en memoria (ya forwardeado)
    output reg  [4:0]  ex_mem_rd,
    output reg  [2:0]  ex_mem_funct3,    // ancho y signo de load/store
    output reg         ex_mem_mem_read,
    output reg         ex_mem_mem_write,
    output reg         ex_mem_reg_write,
    output reg  [1:0]  ex_mem_wb_sel,
    output reg         ex_mem_halt
);

    // ------------------------------------------------------------------
    // 1. Forwarding
    // ------------------------------------------------------------------
    wire [1:0] forward_a, forward_b;

    forwarding_unit fwd (
        .id_ex_rs1        (id_ex_rs1),
        .id_ex_rs2        (id_ex_rs2),
        .ex_mem_rd        (ex_mem_rd),
        .ex_mem_reg_write (ex_mem_reg_write),
        .mem_wb_rd        (mem_wb_rd),
        .mem_wb_reg_write (mem_wb_reg_write),
        .forward_a        (forward_a),
        .forward_b        (forward_b)
    );

    reg [31:0] a_fwd, b_fwd;

    always @(*) begin
        case (forward_a)
            `FWD_EX_MEM: a_fwd = ex_mem_result;
            `FWD_MEM_WB: a_fwd = wb_data;
            default:     a_fwd = id_ex_rs1_data;
        endcase
        case (forward_b)
            `FWD_EX_MEM: b_fwd = ex_mem_result;
            `FWD_MEM_WB: b_fwd = wb_data;
            default:     b_fwd = id_ex_rs2_data;
        endcase
    end

    // ------------------------------------------------------------------
    // 2. ALU
    // ------------------------------------------------------------------
    wire [31:0] alu_a = id_ex_alu_src_a ? 32'd0     : a_fwd;   // lui: 0 + imm
    wire [31:0] alu_b = id_ex_alu_src_b ? id_ex_imm : b_fwd;

    wire [3:0]  alu_ctrl;
    wire [31:0] alu_result;
    wire        alu_zero;

    alu_control actrl (
        .alu_op   (id_ex_alu_op),
        .funct3   (id_ex_funct3),
        .funct7b5 (id_ex_funct7b5),
        .alu_ctrl (alu_ctrl)
    );

    alu alu0 (
        .a      (alu_a),
        .b      (alu_b),
        .op     (alu_ctrl),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // ------------------------------------------------------------------
    // 3. Saltos
    // ------------------------------------------------------------------
    wire [31:0] pc_imm = id_ex_pc + id_ex_imm;           // sumador "Add"

    // beq (funct3 = 000) salta si son iguales, bne (001) si son distintos
    wire branch_cond = (id_ex_funct3 == `F3_BNE) ? ~alu_zero : alu_zero;

    assign branch_taken  = (id_ex_branch & branch_cond) | id_ex_jal | id_ex_jalr;
    assign branch_target = id_ex_jalr ? (alu_result & ~32'd1) : pc_imm;

    // ------------------------------------------------------------------
    // 4. Resultado y latch EX/MEM
    // ------------------------------------------------------------------
    wire [31:0] ex_result = (id_ex_jal | id_ex_jalr) ? id_ex_pc4 : alu_result;

    always @(posedge clk) begin
        if (reset) begin
            ex_mem_result    <= 32'd0;
            ex_mem_rs2_data  <= 32'd0;
            ex_mem_rd        <= 5'd0;
            ex_mem_funct3    <= 3'd0;
            ex_mem_mem_read  <= 1'b0;
            ex_mem_mem_write <= 1'b0;
            ex_mem_reg_write <= 1'b0;
            ex_mem_wb_sel    <= `WB_ALU;
            ex_mem_halt      <= 1'b0;
        end else if (en) begin
            ex_mem_result    <= ex_result;
            ex_mem_rs2_data  <= b_fwd;          // forwardeado, no id_ex_rs2_data
            ex_mem_rd        <= id_ex_rd;
            ex_mem_funct3    <= id_ex_funct3;
            ex_mem_mem_read  <= id_ex_mem_read;
            ex_mem_mem_write <= id_ex_mem_write;
            ex_mem_reg_write <= id_ex_reg_write;
            ex_mem_wb_sel    <= id_ex_wb_sel;
            ex_mem_halt      <= id_ex_halt;
        end
    end

endmodule
