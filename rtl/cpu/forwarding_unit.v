`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Unidad de forwarding (cortocircuito), etapa EX.
//
// Problema: una instruccion lee sus registros en ID, pero las 2 instrucciones
// de adelante todavia no los escribieron (lo hacen recien en WB).
//
//   add x1, x2, x3     IF ID EX ME WB          <- x1 recien se escribe aca
//   sub x4, x1, x5        IF ID EX ME WB       <- necesita x1 en EX
//   or  x6, x1, x7           IF ID EX ME WB    <- tambien
//
// Pero el valor nuevo de x1 YA EXISTE: esta en el latch EX/MEM (el add acaba
// de calcularlo) o en MEM/WB un ciclo despues. Esta unidad compara numeros
// de registro y le dice al mux de cada operando de donde tomar el dato.
//
// Ecuaciones de la catedra (operando A con rs1; B igual con rs2):
//   si EX/MEM.RegWrite y EX/MEM.rd != 0 y EX/MEM.rd == ID/EX.rs1  -> 10
//   si no, si MEM/WB.RegWrite y MEM/WB.rd != 0 y MEM/WB.rd == ID/EX.rs1 -> 01
//   si no -> 00 (valor leido del banco)
//
// - EX/MEM tiene prioridad: si las dos instrucciones de adelante escriben el
//   mismo registro, la mas nueva (EX/MEM) es la que vale.
// - rd != 0: x0 siempre vale 0, nunca se forwardea "lo que se quiso escribir".
// - La distancia 3 (la instruccion esta en WB mientras la otra lee en ID) no
//   pasa por aca: la resuelve el bypass interno del banco de registros.
// - Un load en EX/MEM nunca necesita forwarding desde ahi (su dato todavia no
//   existe): ese caso lo evita el stall load-use de la unidad de riesgos.
// - En ID se guarda rs1/rs2 = 0 si la instruccion no los usa y rd = 0 si no
//   escribe, asi esta unidad nunca ve dependencias falsas (lui, jal, sw...).

module forwarding_unit (
    input  wire [4:0] id_ex_rs1,
    input  wire [4:0] id_ex_rs2,
    input  wire [4:0] ex_mem_rd,
    input  wire       ex_mem_reg_write,
    input  wire [4:0] mem_wb_rd,
    input  wire       mem_wb_reg_write,
    output wire [1:0] forward_a,
    output wire [1:0] forward_b
);

    wire ex_mem_ok = ex_mem_reg_write && (ex_mem_rd != 5'd0);
    wire mem_wb_ok = mem_wb_reg_write && (mem_wb_rd != 5'd0);

    assign forward_a = (ex_mem_ok && ex_mem_rd == id_ex_rs1) ? `FWD_EX_MEM :
                       (mem_wb_ok && mem_wb_rd == id_ex_rs1) ? `FWD_MEM_WB :
                                                               `FWD_REG;

    assign forward_b = (ex_mem_ok && ex_mem_rd == id_ex_rs2) ? `FWD_EX_MEM :
                       (mem_wb_ok && mem_wb_rd == id_ex_rs2) ? `FWD_MEM_WB :
                                                               `FWD_REG;

endmodule
