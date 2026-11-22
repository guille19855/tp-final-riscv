// Top de la placa (Fase 8): Clock Wizard + sistema completo (top_core.v).
//
// El oscilador de la Basys3 (100 MHz) entra al Clock Wizard (MMCM), que
// genera 50 MHz para todo el diseno. No es clock gating: el MMCM sintetiza
// otra frecuencia y la reparte por la red global (BUFG). El paso a paso
// sigue siendo con clock enable (en) dentro de la Debug Unit.
//
// Por que 50 MHz: la frecuencia maxima post-implementacion del procesador
// es ~56 MHz (Fase 7, camino critico dmem -> forwarding -> branch -> PC).
// Se revisa en la Fase 10.
//
// Mientras el MMCM no engancha (locked = 0), todo queda en reset.

`timescale 1ns / 1ps

module top (
    input  wire        clk,      // 100 MHz, pin W5
    input  wire        btnC,     // reset
    input  wire        RsRx,     // UART desde la PC (USB-UART de la placa)
    output wire        RsTx,     // UART hacia la PC
    output wire [15:0] led,
    output wire [3:0]  an,
    output wire [6:0]  seg
);

    wire clk_50, locked;

    clk_wiz_50 u_clk (
        .clk_in1(clk), .clk_out1(clk_50), .locked(locked)
    );

    top_core u_core (
        .clk(clk_50), .reset_in(btnC | ~locked),
        .rx(RsRx), .tx(RsTx),
        .led(led), .an(an), .seg(seg)
    );

endmodule
