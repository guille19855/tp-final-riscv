// Etapa ID (Instruction Decode) + latch ID/EX.
//
// Recibe la instruccion del latch IF/ID y:
//   1. la decodifica           (control_unit: senales de control)
//   2. arma el inmediato       (imm_gen)
//   3. lee rs1 y rs2           (reg_file; WB escribe por el otro puerto)
//   4. detecta hazards         (hazard_unit: load-use y flush por salto)
//   5. detecta el HALT         (ebreak)
// y guarda todo en el latch ID/EX para que lo use la etapa EX el ciclo siguiente.
//
// BURBUJA: cuando hay que anular la instruccion de ID (stall por load-use,
// flush por salto tomado, o IF/ID invalido) el latch ID/EX se carga con todo
// en 0. Con todo el control en 0 la instruccion no escribe registros ni
// memoria ni salta: es una NOP.
//
// HALT: cuando el ebreak esta en ID se avisa a IF en ese mismo ciclo (halt)
// para que deje de buscar instrucciones. Despues queda "halted" = 1 hasta el
// reset, asi IF no vuelve a arrancar. El ebreak sigue viajando por el pipeline
// (id_ex_halt -> EX -> MEM -> WB): cuando llega a WB todas las instrucciones
// anteriores ya terminaron y el programa termino.
// Si en el mismo ciclo EX resuelve un salto tomado, el ebreak es del camino
// equivocado: se descarta y NO se activa el halt.
//
// en = 0 congela todo (latch ID/EX, flag halted y escritura del banco de
// registros). Lo usa la Debug Unit para el modo paso a paso.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module id_stage (
    input  wire        clk,
    input  wire        reset,
    input  wire        en,

    // --- Desde el latch IF/ID ---
    input  wire [31:0] if_id_pc,
    input  wire [31:0] if_id_pc4,
    input  wire [31:0] if_id_instr,
    input  wire        if_id_valid,

    // --- Escritura del banco de registros (desde WB) ---
    input  wire        wb_reg_write,
    input  wire [4:0]  wb_rd,
    input  wire [31:0] wb_data,

    // --- Salto resuelto en EX ---
    input  wire        branch_taken,

    // --- Hacia IF ---
    output wire        stall,          // load-use: congelar PC e IF/ID
    output wire        halt,           // dejar de buscar instrucciones

    // --- Debug Unit: lectura de registros ---
    input  wire [4:0]  dbg_reg_addr,
    output wire [31:0] dbg_reg_data,

    // --- Latch ID/EX: datos ---
    output reg  [31:0] id_ex_pc,
    output reg  [31:0] id_ex_pc4,
    output reg  [31:0] id_ex_rs1_data,
    output reg  [31:0] id_ex_rs2_data,
    output reg  [31:0] id_ex_imm,
    output reg  [4:0]  id_ex_rs1,      // numeros de registro: los usa el
    output reg  [4:0]  id_ex_rs2,      // forwarding en EX
    output reg  [4:0]  id_ex_rd,
    output reg  [2:0]  id_ex_funct3,   // EX (ALU, branch) y MEM (ancho load/store)
    output reg         id_ex_funct7b5, // instr[30]: sub/sra

    // --- Latch ID/EX: control ---
    output reg         id_ex_alu_src_a,
    output reg         id_ex_alu_src_b,
    output reg  [1:0]  id_ex_alu_op,
    output reg         id_ex_branch,
    output reg         id_ex_jal,
    output reg         id_ex_jalr,
    output reg         id_ex_mem_read,
    output reg         id_ex_mem_write,
    output reg         id_ex_reg_write,
    output reg  [1:0]  id_ex_wb_sel,
    output reg         id_ex_halt
);

    // ------------------------------------------------------------------
    // Campos de la instruccion
    // ------------------------------------------------------------------
    wire [6:0] opcode = if_id_instr[6:0];
    wire [4:0] rd     = if_id_instr[11:7];
    wire [2:0] funct3 = if_id_instr[14:12];
    wire [4:0] rs1    = if_id_instr[19:15];
    wire [4:0] rs2    = if_id_instr[24:20];

    // ------------------------------------------------------------------
    // Unidad de control
    // ------------------------------------------------------------------
    wire [2:0] imm_sel;
    wire       usa_rs1, usa_rs2, c_halt;
    wire       c_alu_src_a, c_alu_src_b, c_branch, c_jal, c_jalr;
    wire [1:0] c_alu_op, c_wb_sel;
    wire       c_mem_read, c_mem_write, c_reg_write;

    control_unit ctrl (
        .opcode(opcode),
        .imm_sel(imm_sel), .usa_rs1(usa_rs1), .usa_rs2(usa_rs2), .halt(c_halt),
        .alu_src_a(c_alu_src_a), .alu_src_b(c_alu_src_b), .alu_op(c_alu_op),
        .branch(c_branch), .jal(c_jal), .jalr(c_jalr),
        .mem_read(c_mem_read), .mem_write(c_mem_write),
        .reg_write(c_reg_write), .wb_sel(c_wb_sel)
    );

    // ------------------------------------------------------------------
    // Generador de inmediatos
    // ------------------------------------------------------------------
    wire [31:0] imm;
    imm_gen igen (.instr(if_id_instr), .imm_sel(imm_sel), .imm(imm));

    // ------------------------------------------------------------------
    // Banco de registros. WB solo escribe si el procesador esta habilitado.
    // ------------------------------------------------------------------
    wire [31:0] rs1_data, rs2_data;
    reg_file regs (
        .clk(clk), .reset(reset),
        .rs1_addr(rs1), .rs2_addr(rs2),
        .rs1_data(rs1_data), .rs2_data(rs2_data),
        .we(wb_reg_write & en), .rd_addr(wb_rd), .rd_data(wb_data),
        .dbg_addr(dbg_reg_addr), .dbg_data(dbg_reg_data)
    );

    // ------------------------------------------------------------------
    // Unidad de hazard. Si IF/ID no es valido no hay instruccion: no frena.
    // ------------------------------------------------------------------
    wire flush_id_ex;
    hazard_unit hz (
        .id_rs1(rs1), .id_rs2(rs2),
        .id_usa_rs1(usa_rs1 & if_id_valid), .id_usa_rs2(usa_rs2 & if_id_valid),
        .ex_mem_read(id_ex_mem_read), .ex_rd(id_ex_rd),
        .branch_taken(branch_taken),
        .load_use(), .stall(stall), .flush_id_ex(flush_id_ex)
    );

    // ------------------------------------------------------------------
    // HALT
    // ------------------------------------------------------------------
    // ebreak valido en ID y que no sea del camino equivocado
    wire halt_en_id = if_id_valid & c_halt & ~branch_taken;
    reg  halted;

    always @(posedge clk) begin
        if (reset)                halted <= 1'b0;
        else if (en & halt_en_id) halted <= 1'b1;
    end

    assign halt = halted | halt_en_id;

    // ------------------------------------------------------------------
    // Latch ID/EX
    // ------------------------------------------------------------------
    // Burbuja: la instruccion de ID no pasa a EX
    wire bubble = flush_id_ex | ~if_id_valid;

    always @(posedge clk) begin
        if (reset || (en && bubble)) begin
            id_ex_pc        <= 32'd0;
            id_ex_pc4       <= 32'd0;
            id_ex_rs1_data  <= 32'd0;
            id_ex_rs2_data  <= 32'd0;
            id_ex_imm       <= 32'd0;
            id_ex_rs1       <= 5'd0;
            id_ex_rs2       <= 5'd0;
            id_ex_rd        <= 5'd0;
            id_ex_funct3    <= 3'd0;
            id_ex_funct7b5  <= 1'b0;
            id_ex_alu_src_a <= 1'b0;
            id_ex_alu_src_b <= 1'b0;
            id_ex_alu_op    <= `ALUOP_ADD;
            id_ex_branch    <= 1'b0;
            id_ex_jal       <= 1'b0;
            id_ex_jalr      <= 1'b0;
            id_ex_mem_read  <= 1'b0;
            id_ex_mem_write <= 1'b0;
            id_ex_reg_write <= 1'b0;
            id_ex_wb_sel    <= `WB_ALU;
            id_ex_halt      <= 1'b0;
        end else if (en) begin
            id_ex_pc        <= if_id_pc;
            id_ex_pc4       <= if_id_pc4;
            id_ex_rs1_data  <= rs1_data;
            id_ex_rs2_data  <= rs2_data;
            id_ex_imm       <= imm;
            // Si la instruccion no lee rs1/rs2 se guarda 0 (x0): asi el
            // forwarding de EX no "ve" una dependencia que no existe.
            id_ex_rs1       <= usa_rs1 ? rs1 : 5'd0;
            id_ex_rs2       <= usa_rs2 ? rs2 : 5'd0;
            // Si no escribe registro, rd = 0: idem para el forwarding y el
            // hazard load-use del ciclo siguiente.
            id_ex_rd        <= c_reg_write ? rd : 5'd0;
            id_ex_funct3    <= funct3;
            id_ex_funct7b5  <= if_id_instr[30];
            id_ex_alu_src_a <= c_alu_src_a;
            id_ex_alu_src_b <= c_alu_src_b;
            id_ex_alu_op    <= c_alu_op;
            id_ex_branch    <= c_branch;
            id_ex_jal       <= c_jal;
            id_ex_jalr      <= c_jalr;
            id_ex_mem_read  <= c_mem_read;
            id_ex_mem_write <= c_mem_write;
            id_ex_reg_write <= c_reg_write;
            id_ex_wb_sel    <= c_wb_sel;
            id_ex_halt      <= c_halt;
        end
    end

endmodule
