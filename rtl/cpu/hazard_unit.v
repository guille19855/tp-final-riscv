// Unidad de deteccion de hazards - etapa ID.
//
// Con forwarding (EX/MEM -> EX y MEM/WB -> EX) casi todos los hazards de datos
// se resuelven sin frenar. El UNICO que no se puede resolver es el load-use:
//
//     lw  x5, 0(x1)     <- en EX: el dato recien sale de memoria en MEM
//     add x6, x5, x2    <- en ID: lo necesita en EX el ciclo que viene
//
// El dato del lw esta listo al final de MEM, pero el add lo necesita al
// principio de EX, que es el mismo ciclo: no llega. Hay que frenar 1 ciclo
// (stall) y despues el forwarding MEM/WB -> EX lo resuelve.
//
// Un stall hace 3 cosas:
//   - PC no avanza         (se vuelve a buscar la misma instruccion)
//   - IF/ID no cambia      (el add se queda en ID)
//   - ID/EX recibe burbuja (se mete una NOP en EX: control en 0)
//
// Tambien maneja el hazard de control: cuando EX resuelve que un branch/jal/
// jalr salta (branch_taken), las 2 instrucciones que entraron detras (en IF e
// ID) son del camino equivocado y se descartan (flush). La de IF la descarta
// if_stage (pone IF/ID invalido); la de ID se descarta metiendo burbuja en
// ID/EX.
//
// Es combinacional pura.

`timescale 1ns / 1ps

module hazard_unit (
    // Instruccion en ID: que registros lee realmente
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    input  wire       id_usa_rs1,
    input  wire       id_usa_rs2,

    // Instruccion en EX (sale del latch ID/EX)
    input  wire       ex_mem_read,   // es un load
    input  wire [4:0] ex_rd,         // registro que va a escribir

    // Salto resuelto en EX
    input  wire       branch_taken,

    output wire       load_use,      // hay hazard load-use (para debug/ondas)
    output wire       stall,         // congelar PC e IF/ID
    output wire       flush_id_ex    // meter burbuja en ID/EX
);

    // Load-use: la instruccion en EX es un load que escribe un registro
    // (distinto de x0) que la instruccion en ID realmente lee.
    assign load_use = ex_mem_read && (ex_rd != 5'd0) &&
                      ((id_usa_rs1 && ex_rd == id_rs1) ||
                       (id_usa_rs2 && ex_rd == id_rs2));

    // Si al mismo tiempo hay un salto tomado, gana el salto: la instruccion
    // en ID es del camino equivocado, no tiene sentido esperarla.
    // (Con saltos en EX no puede pasar: la instruccion de EX no puede ser
    // load y salto a la vez. Se deja por seguridad y porque cuando movamos
    // los saltos a ID - Fase 11 - si puede ocurrir.)
    assign stall       = load_use & ~branch_taken;

    // Burbuja en ID/EX por stall (la instruccion de ID todavia no puede
    // avanzar) o por flush (la instruccion de ID es del camino equivocado).
    assign flush_id_ex = load_use | branch_taken;

endmodule
