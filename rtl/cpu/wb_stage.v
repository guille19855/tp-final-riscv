// Etapa WB (Write Back).
//
// Ultima etapa: elige el valor que se escribe en el registro destino y lo
// manda a tres lugares:
//   - al banco de registros (puerto de escritura, en ID)
//   - al forwarding de EX (fuente MEM/WB, codigo 01)
//   - al bypass del banco (WB escribe y ID lee el mismo registro)
//
// Es combinacional y no tiene latch propio: despues de WB no hay otra etapa.
// La escritura en si ocurre en el flanco, dentro del banco de registros.
//
// El mux es de solo 2 entradas gracias a decisiones anteriores:
//   - jal/jalr: el PC+4 ya viene en mem_wb_result (decision 1-A de EX), asi
//     que WB_PC4 se trata igual que WB_ALU
//   - loads: el byte/media palabra ya viene extendido desde MEM (decision 2-A)
//
// HALT: cuando el ebreak llega aca, todas las instrucciones anteriores ya
// escribieron sus resultados y las etapas de atras solo tienen burbujas: el
// pipeline esta vacio y el programa termino (program_done). La Debug Unit
// usa esta senal para bajar en; con en = 0 el latch MEM/WB se congela y
// program_done queda en 1.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module wb_stage (
    // --- Desde el latch MEM/WB ---
    input  wire [31:0] mem_wb_result,     // ALU, direccion o PC+4
    input  wire [31:0] mem_wb_load_data,  // dato del load ya extendido
    input  wire [4:0]  mem_wb_rd,
    input  wire        mem_wb_reg_write,
    input  wire [1:0]  mem_wb_wb_sel,
    input  wire        mem_wb_halt,

    // --- Hacia el banco de registros y el forwarding ---
    output wire        wb_reg_write,
    output wire [4:0]  wb_rd,
    output wire [31:0] wb_data,

    // --- Hacia la Debug Unit ---
    output wire        program_done
);

    assign wb_data      = (mem_wb_wb_sel == `WB_MEM) ? mem_wb_load_data : mem_wb_result;
    assign wb_reg_write = mem_wb_reg_write;
    assign wb_rd        = mem_wb_rd;
    assign program_done = mem_wb_halt;

endmodule
