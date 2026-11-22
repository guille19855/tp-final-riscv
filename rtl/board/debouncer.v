// Antirrebote para un boton de la Basys3.
//
// Un boton mecanico "rebota": al apretarlo, durante unos milisegundos la
// senal salta varias veces entre 0 y 1. Si se usara directo, un solo apriete
// del boton de paso podria avanzar varios ciclos.
//
// Funcionamiento:
//   1. Sincronizador de 2 FF: el boton es asincronico respecto del clock; los
//      2 FF evitan la metaestabilidad (igual que en la UART del TP2).
//   2. Contador: la salida solo cambia cuando la entrada sincronizada se
//      mantuvo DISTINTA de la salida durante STABLE_CYCLES ciclos seguidos.
//      Si rebota antes, el contador vuelve a 0.
//   3. pulse: vale 1 durante UN solo ciclo cuando la salida pasa de 0 a 1
//      (flanco de subida). Es lo que se usa como "en" en el modo paso a paso.
//
// STABLE_CYCLES: con 50 MHz, 10 ms = 500_000 ciclos. En el testbench se usa
// un valor chico para no simular millones de ciclos.

`timescale 1ns / 1ps

module debouncer #(
    parameter integer STABLE_CYCLES = 500_000
) (
    input  wire clk,
    input  wire reset,
    input  wire btn,      // boton crudo (asincronico)
    output reg  level,    // boton limpio
    output wire pulse     // 1 ciclo al apretar
);

    localparam W = $clog2(STABLE_CYCLES + 1);

    reg sync0, sync1;
    always @(posedge clk) begin
        if (reset) {sync1, sync0} <= 2'b00;
        else       {sync1, sync0} <= {sync0, btn};
    end

    reg [W-1:0] count;
    reg         level_d;
    always @(posedge clk) begin
        if (reset) begin
            count   <= 0;
            level   <= 1'b0;
            level_d <= 1'b0;
        end else begin
            level_d <= level;
            if (sync1 == level)
                count <= 0;                       // estable: nada que hacer
            else if (count == STABLE_CYCLES - 1) begin
                count <= 0;
                level <= sync1;                   // cambio confirmado
            end else
                count <= count + 1'b1;
        end
    end

    assign pulse = level & ~level_d;

endmodule
