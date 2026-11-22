// Top de la prueba temprana en la placa Basys3 (provisorio: en la Fase 8 se
// reemplaza por top.v con la Debug Unit).
//
// Clock: el oscilador de la placa es de 100 MHz, pero el procesador llega a
// ~68 MHz (analisis post-sintesis del 17/11). El Clock Wizard (IP clk_wiz_50,
// un MMCM) genera 50 MHz limpios a partir de los 100 MHz: no es clock gating,
// es otro reloj generado por hardware dedicado. Todo el diseno usa clk_50.
//
// locked = 1 cuando el MMCM se engancho y la salida es estable; mientras
// tanto todo queda en reset.

`timescale 1ns / 1ps

module board_test_top (
    input  wire        clk,      // 100 MHz (W5)
    input  wire        btnC,     // reset
    input  wire        btnR,     // paso
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [3:0]  an,
    output wire [6:0]  seg
);

    wire clk_50, locked;

    clk_wiz_50 u_clk (
        .clk_in1  (clk),
        .clk_out1 (clk_50),
        .locked   (locked)
    );

    board_test_core u_core (
        .clk(clk_50), .reset_in(btnC | ~locked), .btn_step(btnR),
        .sw(sw), .led(led), .an(an), .seg(seg)
    );

endmodule
