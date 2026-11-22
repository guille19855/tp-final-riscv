// Procesador RISC-V segmentado completo (Fase 7: integracion).
//
// Instancia las 5 etapas y cierra los lazos hacia atras. Cada etapa ya tiene
// su latch de salida adentro (IF -> IF/ID, ID -> ID/EX, EX -> EX/MEM,
// MEM -> MEM/WB), asi que aca solo hay cables, no logica.
//
// Lazos hacia atras:
//   EX  -> IF   branch_taken, branch_target   cargar el PC con el destino y
//                                             descartar IF/ID (flush)
//   EX  -> ID   branch_taken                  burbuja en ID/EX (flush) y anular
//                                             un ebreak del camino equivocado
//   ID  -> IF   stall                         load-use: congelar PC e IF/ID
//   ID  -> IF   halt                          ebreak en ID: dejar de buscar
//   WB  -> ID   wb_reg_write, wb_rd, wb_data  escritura del banco de registros
//                                             (y bypass interno)
//   WB  -> EX   las mismas tres               forwarding desde MEM/WB (01)
// El forwarding desde EX/MEM (10) no aparece: el latch EX/MEM esta dentro de
// ex_stage y se usa ahi mismo.
//
// Puertos de debug (los usa la Debug Unit, Fase 8):
//   - escribir/leer la memoria de instrucciones (cargar el programa), puerto B
//   - leer la memoria de datos, puerto B, y si cada palabra fue escrita por
//     un store (bitmap dmem_used, que la Debug Unit borra al cargar)
//   - leer cualquier registro del banco
//   - leer los latches intermedios: dbg_latch_sel elige una de 16 palabras
//     de 32 bits (tabla abajo, "Latches para la Debug Unit"). Con un mux en
//     vez de sacar los ~500 bits como puertos.
//   - PC y program_done
//
// en = 0 congela TODO el procesador (PC, latches, banco, memorias): es el
// clock enable del modo paso a paso, el clock nunca se toca.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module cpu_top (
    input  wire        clk,
    input  wire        reset,
    input  wire        en,

    // --- Debug: memoria de instrucciones (cargar programa) ---
    input  wire        dbg_imem_we,
    input  wire [9:0]  dbg_imem_addr,
    input  wire [31:0] dbg_imem_wdata,
    output wire [31:0] dbg_imem_rdata,

    // --- Debug: memoria de datos (solo lectura) + bitmap de usadas ---
    input  wire [9:0]  dbg_dmem_addr,
    output wire [31:0] dbg_dmem_rdata,
    output wire        dbg_dmem_used,    // la palabra dbg_dmem_addr fue escrita
    input  wire        dbg_used_clr,     // borrar el bit de dbg_dmem_addr

    // --- Debug: banco de registros (solo lectura) ---
    input  wire [4:0]  dbg_reg_addr,
    output wire [31:0] dbg_reg_data,

    // --- Debug: latches intermedios (solo lectura) ---
    input  wire [3:0]  dbg_latch_sel,
    output reg  [31:0] dbg_latch_data,

    // --- Estado ---
    output wire [31:0] pc,
    output wire        program_done
);

    // ------------------------------------------------------------------
    // Cables entre etapas
    // ------------------------------------------------------------------
    // Lazos hacia atras
    wire        branch_taken;
    wire [31:0] branch_target;
    wire        stall, halt;
    wire        wb_reg_write;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    // IF/ID
    wire [31:0] if_id_pc, if_id_pc4, if_id_instr;
    wire        if_id_valid;

    // ID/EX
    wire [31:0] id_ex_pc, id_ex_pc4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    wire [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    wire [2:0]  id_ex_funct3;
    wire        id_ex_funct7b5, id_ex_alu_src_a, id_ex_alu_src_b;
    wire [1:0]  id_ex_alu_op, id_ex_wb_sel;
    wire        id_ex_branch, id_ex_jal, id_ex_jalr;
    wire        id_ex_mem_read, id_ex_mem_write, id_ex_reg_write, id_ex_halt;

    // EX/MEM
    wire [31:0] ex_mem_result, ex_mem_rs2_data;
    wire [4:0]  ex_mem_rd;
    wire [2:0]  ex_mem_funct3;
    wire        ex_mem_mem_read, ex_mem_mem_write, ex_mem_reg_write, ex_mem_halt;
    wire [1:0]  ex_mem_wb_sel;

    // MEM/WB
    wire [31:0] mem_wb_result, mem_wb_read_data, mem_wb_load_data;
    wire [4:0]  mem_wb_rd;
    wire [2:0]  mem_wb_funct3;
    wire [1:0]  mem_wb_addr_lo, mem_wb_wb_sel;
    wire        mem_wb_mem_read, mem_wb_reg_write, mem_wb_halt;

    // ------------------------------------------------------------------
    // IF
    // ------------------------------------------------------------------
    if_stage u_if (
        .clk(clk), .reset(reset), .en(en),
        .stall(stall), .halt(halt),
        .branch_taken(branch_taken), .branch_target(branch_target),
        .dbg_we(dbg_imem_we), .dbg_addr(dbg_imem_addr),
        .dbg_wdata(dbg_imem_wdata), .dbg_rdata(dbg_imem_rdata),
        .if_id_pc(if_id_pc), .if_id_pc4(if_id_pc4),
        .if_id_instr(if_id_instr), .if_id_valid(if_id_valid),
        .pc(pc)
    );

    // ------------------------------------------------------------------
    // ID
    // ------------------------------------------------------------------
    id_stage u_id (
        .clk(clk), .reset(reset), .en(en),
        .if_id_pc(if_id_pc), .if_id_pc4(if_id_pc4),
        .if_id_instr(if_id_instr), .if_id_valid(if_id_valid),
        .wb_reg_write(wb_reg_write), .wb_rd(wb_rd), .wb_data(wb_data),
        .branch_taken(branch_taken),
        .stall(stall), .halt(halt),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
        .id_ex_pc(id_ex_pc), .id_ex_pc4(id_ex_pc4),
        .id_ex_rs1_data(id_ex_rs1_data), .id_ex_rs2_data(id_ex_rs2_data),
        .id_ex_imm(id_ex_imm),
        .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2), .id_ex_rd(id_ex_rd),
        .id_ex_funct3(id_ex_funct3), .id_ex_funct7b5(id_ex_funct7b5),
        .id_ex_alu_src_a(id_ex_alu_src_a), .id_ex_alu_src_b(id_ex_alu_src_b),
        .id_ex_alu_op(id_ex_alu_op),
        .id_ex_branch(id_ex_branch), .id_ex_jal(id_ex_jal), .id_ex_jalr(id_ex_jalr),
        .id_ex_mem_read(id_ex_mem_read), .id_ex_mem_write(id_ex_mem_write),
        .id_ex_reg_write(id_ex_reg_write), .id_ex_wb_sel(id_ex_wb_sel),
        .id_ex_halt(id_ex_halt)
    );

    // ------------------------------------------------------------------
    // EX
    // ------------------------------------------------------------------
    ex_stage u_ex (
        .clk(clk), .reset(reset), .en(en),
        .id_ex_pc(id_ex_pc), .id_ex_pc4(id_ex_pc4),
        .id_ex_rs1_data(id_ex_rs1_data), .id_ex_rs2_data(id_ex_rs2_data),
        .id_ex_imm(id_ex_imm),
        .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2), .id_ex_rd(id_ex_rd),
        .id_ex_funct3(id_ex_funct3), .id_ex_funct7b5(id_ex_funct7b5),
        .id_ex_alu_src_a(id_ex_alu_src_a), .id_ex_alu_src_b(id_ex_alu_src_b),
        .id_ex_alu_op(id_ex_alu_op),
        .id_ex_branch(id_ex_branch), .id_ex_jal(id_ex_jal), .id_ex_jalr(id_ex_jalr),
        .id_ex_mem_read(id_ex_mem_read), .id_ex_mem_write(id_ex_mem_write),
        .id_ex_reg_write(id_ex_reg_write), .id_ex_wb_sel(id_ex_wb_sel),
        .id_ex_halt(id_ex_halt),
        .mem_wb_rd(wb_rd), .mem_wb_reg_write(wb_reg_write), .wb_data(wb_data),
        .branch_taken(branch_taken), .branch_target(branch_target),
        .ex_mem_result(ex_mem_result), .ex_mem_rs2_data(ex_mem_rs2_data),
        .ex_mem_rd(ex_mem_rd), .ex_mem_funct3(ex_mem_funct3),
        .ex_mem_mem_read(ex_mem_mem_read), .ex_mem_mem_write(ex_mem_mem_write),
        .ex_mem_reg_write(ex_mem_reg_write), .ex_mem_wb_sel(ex_mem_wb_sel),
        .ex_mem_halt(ex_mem_halt)
    );

    // ------------------------------------------------------------------
    // MEM
    // ------------------------------------------------------------------
    mem_stage u_mem (
        .clk(clk), .reset(reset), .en(en),
        .ex_mem_result(ex_mem_result), .ex_mem_rs2_data(ex_mem_rs2_data),
        .ex_mem_rd(ex_mem_rd), .ex_mem_funct3(ex_mem_funct3),
        .ex_mem_mem_read(ex_mem_mem_read), .ex_mem_mem_write(ex_mem_mem_write),
        .ex_mem_reg_write(ex_mem_reg_write), .ex_mem_wb_sel(ex_mem_wb_sel),
        .ex_mem_halt(ex_mem_halt),
        .dbg_addr(dbg_dmem_addr), .dbg_rdata(dbg_dmem_rdata),
        .mem_wb_result(mem_wb_result), .mem_wb_read_data(mem_wb_read_data),
        .mem_wb_load_data(mem_wb_load_data),
        .mem_wb_rd(mem_wb_rd), .mem_wb_funct3(mem_wb_funct3),
        .mem_wb_addr_lo(mem_wb_addr_lo), .mem_wb_mem_read(mem_wb_mem_read),
        .mem_wb_reg_write(mem_wb_reg_write), .mem_wb_wb_sel(mem_wb_wb_sel),
        .mem_wb_halt(mem_wb_halt)
    );

    // ------------------------------------------------------------------
    // WB
    // ------------------------------------------------------------------
    wb_stage u_wb (
        .mem_wb_result(mem_wb_result), .mem_wb_load_data(mem_wb_load_data),
        .mem_wb_rd(mem_wb_rd), .mem_wb_reg_write(mem_wb_reg_write),
        .mem_wb_wb_sel(mem_wb_wb_sel), .mem_wb_halt(mem_wb_halt),
        .wb_reg_write(wb_reg_write), .wb_rd(wb_rd), .wb_data(wb_data),
        .program_done(program_done)
    );

    // ------------------------------------------------------------------
    // Memoria de datos usada (bitmap): se marca con cada store que se ejecuta
    // ------------------------------------------------------------------
    dmem_used u_used (
        .clk(clk),
        .set(en & ex_mem_mem_write), .set_addr(ex_mem_result[11:2]),
        .clr(dbg_used_clr), .dbg_addr(dbg_dmem_addr), .used(dbg_dmem_used)
    );

    // ------------------------------------------------------------------
    // Latches para la Debug Unit: 16 palabras de 32 bits
    // ------------------------------------------------------------------
    //  sel  latch    contenido
    //   0   IF/ID    pc
    //   1   IF/ID    pc4
    //   2   IF/ID    instr
    //   3   IF/ID    {31'b0, valid}
    //   4   ID/EX    pc
    //   5   ID/EX    pc4
    //   6   ID/EX    rs1_data
    //   7   ID/EX    rs2_data
    //   8   ID/EX    imm
    //   9   ID/EX    control (32 bits justos, ver abajo)
    //  10   EX/MEM   result
    //  11   EX/MEM   rs2_data
    //  12   EX/MEM   control
    //  13   MEM/WB   result
    //  14   MEM/WB   read_data
    //  15   MEM/WB   control
    //
    // Palabras de control (bit mas alto primero):
    //  ID/EX : rs1[31:27] rs2[26:22] rd[21:17] funct3[16:14] funct7b5[13]
    //          alu_src_a[12] alu_src_b[11] alu_op[10:9] branch[8] jal[7]
    //          jalr[6] mem_read[5] mem_write[4] reg_write[3] wb_sel[2:1] halt[0]
    //  EX/MEM: rd[13:9] funct3[8:6] mem_read[5] mem_write[4] reg_write[3]
    //          wb_sel[2:1] halt[0]
    //  MEM/WB: rd[14:10] funct3[9:7] addr_lo[6:5] mem_read[4] reg_write[3]
    //          wb_sel[2:1] halt[0]
    // La interfaz Python (sw/) decodifica con esta misma tabla.
    always @(*) begin
        case (dbg_latch_sel)
            4'd0:  dbg_latch_data = if_id_pc;
            4'd1:  dbg_latch_data = if_id_pc4;
            4'd2:  dbg_latch_data = if_id_instr;
            4'd3:  dbg_latch_data = {31'd0, if_id_valid};
            4'd4:  dbg_latch_data = id_ex_pc;
            4'd5:  dbg_latch_data = id_ex_pc4;
            4'd6:  dbg_latch_data = id_ex_rs1_data;
            4'd7:  dbg_latch_data = id_ex_rs2_data;
            4'd8:  dbg_latch_data = id_ex_imm;
            4'd9:  dbg_latch_data = {id_ex_rs1, id_ex_rs2, id_ex_rd, id_ex_funct3,
                                     id_ex_funct7b5, id_ex_alu_src_a, id_ex_alu_src_b,
                                     id_ex_alu_op, id_ex_branch, id_ex_jal, id_ex_jalr,
                                     id_ex_mem_read, id_ex_mem_write, id_ex_reg_write,
                                     id_ex_wb_sel, id_ex_halt};
            4'd10: dbg_latch_data = ex_mem_result;
            4'd11: dbg_latch_data = ex_mem_rs2_data;
            4'd12: dbg_latch_data = {18'd0, ex_mem_rd, ex_mem_funct3, ex_mem_mem_read,
                                     ex_mem_mem_write, ex_mem_reg_write, ex_mem_wb_sel,
                                     ex_mem_halt};
            4'd13: dbg_latch_data = mem_wb_result;
            4'd14: dbg_latch_data = mem_wb_read_data;
            default: dbg_latch_data = {17'd0, mem_wb_rd, mem_wb_funct3, mem_wb_addr_lo,
                                       mem_wb_mem_read, mem_wb_reg_write, mem_wb_wb_sel,
                                       mem_wb_halt};
        endcase
    end

endmodule
