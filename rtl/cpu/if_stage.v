`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Etapa IF (Instruction Fetch) + latch IF/ID.
//
// El latch IF/ID esta "repartido": pc, pc4 y valid son registros de este
// modulo, y la instruccion es el registro de salida interno de la BRAM
// (lectura sincronica, latencia 1). En cada flanco pasan tres cosas a la vez:
//     IF/ID.pc   <= PC
//     BRAM lee la direccion PC  ->  IF/ID.instr = mem[PC]
//     PC         <= PC + 4  (o el destino del salto)
// por eso el par (if_id_pc, if_id_instr) siempre corresponde a la misma
// instruccion, igual que en el pipeline clasico del libro.
//
// Prioridad de las senales de control (de mayor a menor):
//   reset        -> PC = 0, IF/ID vacio (valid = 0)
//   en = 0       -> nada cambia (pausa / modo paso a paso, sin tocar el clock)
//   branch_taken -> PC = destino y flush de IF/ID (lo que se estaba buscando
//                   era del camino equivocado). Gana sobre stall y halt porque
//                   viene de una instruccion mas vieja (EX).
//   stall        -> PC e IF/ID congelados, BRAM con enable en 0 (load-use)
//   halt         -> PC congelado e IF/ID vacio: se deja de buscar
//                   instrucciones y el pipeline se vacia solo
//   (ninguna)    -> avance normal
//
// Reset sincronico: es lo que recomienda Xilinx para FPGA y entra en el
// analisis de timing como cualquier otra senal.

module if_stage (
    input  wire        clk,
    input  wire        reset,
    input  wire        en,             // cpu_en de la Debug Unit
    input  wire        stall,          // unidad de hazard (ID)
    input  wire        halt,           // detector de HALT (ID)
    input  wire        branch_taken,   // decision de salto (EX)
    input  wire [31:0] branch_target,  // destino del salto (EX)

    // Puerto B de la memoria de programa (Debug Unit)
    input  wire        dbg_we,
    input  wire [9:0]  dbg_addr,       // indice de palabra (0..1023)
    input  wire [31:0] dbg_wdata,
    output wire [31:0] dbg_rdata,

    // Latch IF/ID
    output reg  [31:0] if_id_pc,
    output reg  [31:0] if_id_pc4,
    output wire [31:0] if_id_instr,    // NOP si if_id_valid = 0
    output reg         if_id_valid,

    output reg  [31:0] pc              // para la Debug Unit
);

    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] next_pc  = branch_taken ? branch_target : pc_plus4;

    // La BRAM se congela solo en un stall: asi su salida (IF/ID.instr) no cambia.
    // Durante un salto si lee: lo que traiga se descarta con valid = 0.
    wire        bram_en  = en & (branch_taken | ~stall);
    wire [31:0] bram_dout;

    // PC: PC[11:2] es el indice de palabra (bytes / 4, 1024 palabras = 10 bits).
    // Port A del procesador: solo lee. Port B: Debug Unit.
    instr_mem imem (
        .clka  (clk),
        .ena   (bram_en),
        .wea   (1'b0),
        .addra (pc[11:2]),
        .dina  (32'd0),
        .douta (bram_dout),
        .clkb  (clk),
        .web   (dbg_we),
        .addrb (dbg_addr),
        .dinb  (dbg_wdata),
        .doutb (dbg_rdata)
    );

    // Si la instruccion no es valida (reset, flush, halt) ID ve un NOP, asi
    // las etapas siguientes no tienen que saber nada de "valid".
    assign if_id_instr = if_id_valid ? bram_dout : `INSTR_NOP;

    always @(posedge clk) begin
        if (reset) begin
            pc          <= 32'd0;
            if_id_pc    <= 32'd0;
            if_id_pc4   <= 32'd0;
            if_id_valid <= 1'b0;
        end else if (en) begin
            if (branch_taken) begin
                pc          <= next_pc;
                if_id_valid <= 1'b0;          // flush
            end else if (stall) begin
                // todo congelado (la BRAM tambien, con bram_en = 0)
            end else if (halt) begin
                if_id_valid <= 1'b0;          // PC queda quieto, entran NOPs
            end else begin
                pc          <= next_pc;
                if_id_pc    <= pc;
                if_id_pc4   <= pc_plus4;
                if_id_valid <= 1'b1;
            end
        end
    end

endmodule
