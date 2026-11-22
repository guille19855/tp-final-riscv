// Etapa MEM (Memory Access) + latch MEM/WB.
//
// Recibe la instruccion del latch EX/MEM y:
//   - store (sb/sh/sw): escribe en la memoria de datos SOLO los bytes que
//     corresponden, usando el byte write enable de la BRAM
//   - load (lb/lh/lw/lbu/lhu): lee la palabra; el byte o media palabra se
//     elige y se extiende a la salida del latch MEM/WB (ver abajo)
//   - el resto: el resultado de EX pasa derecho a MEM/WB
//
// MEMORIA DE DATOS: IP data_mem (Block Memory Generator), True Dual Port,
// 1024 x 32, byte write enable, latencia 1, contenido inicial palabra i = i
// (coe/data_init.coe).
//   Puerto A: procesador (lee y escribe)
//   Puerto B: Debug Unit (solo lee, para mandar la memoria a la PC)
// Little-endian: el byte de la direccion 4*k + 0 son los bits [7:0] de la
// palabra k.
//
// LECTURA SINCRONICA: la BRAM entrega el dato en el flanco SIGUIENTE al que
// recibe la direccion. Por eso su salida ES el campo read_data del latch
// MEM/WB (igual que en IF la salida de instr_mem es IF/ID.instr). En ese mismo
// flanco el latch guarda funct3 y addr[1:0], que dicen que byte tomar.
//
// DECISIONES (Fase 4):
//   1-A Accesos desalineados no soportados: sw/lw usan la palabra alineada,
//       sh/lh solo miran addr[1], sb/lb usan addr[1:0].
//   2-A La extraccion y extension del load se hace aca, combinacional a la
//       salida de MEM/WB (mem_wb_load_data). WB solo elige.
//   3-A read_data se enmascara con mem_read: despues del reset, o si la
//       instruccion no es un load, vale 0 (la salida de la BRAM no tiene reset).
//
// en = 0 congela todo: la BRAM no lee ni escribe (ena = en) y el latch no cambia.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module mem_stage (
    input  wire        clk,
    input  wire        reset,
    input  wire        en,

    // --- Desde el latch EX/MEM ---
    input  wire [31:0] ex_mem_result,     // direccion (load/store) o resultado
    input  wire [31:0] ex_mem_rs2_data,   // dato a escribir (store)
    input  wire [4:0]  ex_mem_rd,
    input  wire [2:0]  ex_mem_funct3,
    input  wire        ex_mem_mem_read,
    input  wire        ex_mem_mem_write,
    input  wire        ex_mem_reg_write,
    input  wire [1:0]  ex_mem_wb_sel,
    input  wire        ex_mem_halt,

    // --- Puerto B de la memoria de datos (Debug Unit) ---
    input  wire [9:0]  dbg_addr,          // indice de palabra (0..1023)
    output wire [31:0] dbg_rdata,

    // --- Latch MEM/WB ---
    output reg  [31:0] mem_wb_result,
    output wire [31:0] mem_wb_read_data,  // palabra leida (0 si no es load)
    output wire [31:0] mem_wb_load_data,  // byte/media/palabra ya extendido
    output reg  [4:0]  mem_wb_rd,
    output reg  [2:0]  mem_wb_funct3,
    output reg  [1:0]  mem_wb_addr_lo,    // byte dentro de la palabra
    output reg         mem_wb_mem_read,
    output reg         mem_wb_reg_write,
    output reg  [1:0]  mem_wb_wb_sel,
    output reg         mem_wb_halt
);

    // ------------------------------------------------------------------
    // 1. Store: byte enables y dato repetido
    // ------------------------------------------------------------------
    // El dato se repite en todas las posiciones de la palabra y el byte
    // enable elige cual se escribe: no hace falta un desplazador.
    wire [1:0] off = ex_mem_result[1:0];
    reg  [3:0] byte_en;
    reg  [31:0] store_data;

    always @(*) begin
        case (ex_mem_funct3[1:0])
            2'b00: begin                                     // sb
                byte_en    = 4'b0001 << off;
                store_data = {4{ex_mem_rs2_data[7:0]}};
            end
            2'b01: begin                                     // sh
                byte_en    = off[1] ? 4'b1100 : 4'b0011;
                store_data = {2{ex_mem_rs2_data[15:0]}};
            end
            default: begin                                   // sw
                byte_en    = 4'b1111;
                store_data = ex_mem_rs2_data;
            end
        endcase
    end

    wire [3:0] wea = ex_mem_mem_write ? byte_en : 4'b0000;

    // ------------------------------------------------------------------
    // 2. Memoria de datos (BRAM)
    // ------------------------------------------------------------------
    wire [31:0] bram_dout;

    data_mem dmem (
        .clka  (clk),
        .ena   (en),                      // en = 0: no lee ni escribe (paso a paso)
        .wea   (wea),
        .addra (ex_mem_result[11:2]),     // indice de palabra
        .dina  (store_data),
        .douta (bram_dout),               // = MEM/WB.read_data (un ciclo despues)
        .clkb  (clk),
        .web   (4'b0000),                 // la Debug Unit solo lee
        .addrb (dbg_addr),
        .dinb  (32'd0),
        .doutb (dbg_rdata)
    );

    // ------------------------------------------------------------------
    // 3. Latch MEM/WB (el resto de los campos)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            mem_wb_result    <= 32'd0;
            mem_wb_rd        <= 5'd0;
            mem_wb_funct3    <= 3'd0;
            mem_wb_addr_lo   <= 2'd0;
            mem_wb_mem_read  <= 1'b0;
            mem_wb_reg_write <= 1'b0;
            mem_wb_wb_sel    <= `WB_ALU;
            mem_wb_halt      <= 1'b0;
        end else if (en) begin
            mem_wb_result    <= ex_mem_result;
            mem_wb_rd        <= ex_mem_rd;
            mem_wb_funct3    <= ex_mem_funct3;
            mem_wb_addr_lo   <= ex_mem_result[1:0];
            mem_wb_mem_read  <= ex_mem_mem_read;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_wb_sel    <= ex_mem_wb_sel;
            mem_wb_halt      <= ex_mem_halt;
        end
    end

    // Decision 3-A: la salida de la BRAM no tiene reset; se muestra solo si
    // la instruccion que esta en MEM/WB es un load.
    assign mem_wb_read_data = mem_wb_mem_read ? bram_dout : 32'd0;

    // ------------------------------------------------------------------
    // 4. Load: elegir el byte / media palabra y extender (decision 2-A)
    // ------------------------------------------------------------------
    wire [7:0]  ld_byte = mem_wb_read_data >> (8  * mem_wb_addr_lo);
    wire [15:0] ld_half = mem_wb_addr_lo[1] ? mem_wb_read_data[31:16]
                                            : mem_wb_read_data[15:0];
    reg  [31:0] load_ext;

    always @(*) begin
        case (mem_wb_funct3)
            `F3_LB:  load_ext = {{24{ld_byte[7]}},  ld_byte};   // con signo
            `F3_LH:  load_ext = {{16{ld_half[15]}}, ld_half};
            `F3_LBU: load_ext = {24'd0, ld_byte};               // con ceros
            `F3_LHU: load_ext = {16'd0, ld_half};
            default: load_ext = mem_wb_read_data;               // lw
        endcase
    end

    assign mem_wb_load_data = load_ext;

endmodule
