// Bitmap de "memoria de datos usada" (Fase 8, decision 1-A).
//
// Un bit por palabra de la memoria de datos (1024 bits). Se pone en 1 cuando
// el procesador hace un store en esa palabra. La Debug Unit lo recorre al
// mandar el volcado y solo envia las palabras marcadas: eso es lo que pide el
// enunciado ("la memoria de datos usada").
//
// Se implementa como memoria distribuida (LUTRAM, 1024 x 1), no como 1024 FF:
//   - 1024 FF necesitarian un decodificador de 10 bits por FF (~1000 LUT) y un
//     mux 1024:1 para leer; la LUTRAM ya trae las dos cosas adentro
//   - la contra: una LUTRAM no tiene reset, asi que no se borra de golpe. La
//     borra la Debug Unit al recibir un programa nuevo, escribiendo 0 en las
//     1024 posiciones (1024 ciclos, ~20 us a 50 MHz, mientras llegan los bytes)
//   - al configurar el FPGA arranca en 0 (initial)
//
// Un puerto de escritura (store del CPU, o borrado de la Debug Unit) y uno de
// lectura asincronica (Debug Unit).

`timescale 1ns / 1ps

module dmem_used (
    input  wire       clk,
    // marcar: store del procesador que se ejecuta en este ciclo
    input  wire       set,
    input  wire [9:0] set_addr,
    // borrar (Debug Unit), tiene prioridad (no ocurre a la vez: el CPU esta
    // en reset mientras se carga un programa)
    input  wire       clr,
    // direccion de la Debug Unit: se usa para borrar y para leer
    input  wire [9:0] dbg_addr,
    output wire       used
);

    reg used_mem [0:1023];
    integer i;
    initial for (i = 0; i < 1024; i = i + 1) used_mem[i] = 1'b0;

    always @(posedge clk) begin
        if (clr)      used_mem[dbg_addr] <= 1'b0;
        else if (set) used_mem[set_addr] <= 1'b1;
    end

    assign used = used_mem[dbg_addr];

endmodule
