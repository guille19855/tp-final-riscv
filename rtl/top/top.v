// Top de la placa (Fase 8): Clock Wizard + sistema completo (top_core.v).
//
// El oscilador de la Basys3 (100 MHz) entra al Clock Wizard (MMCM), que
// genera CLK_HZ para todo el diseno. No es clock gating: el MMCM sintetiza
// otra frecuencia y la reparte por la red global (BUFG). El paso a paso
// sigue siendo con clock enable (en) dentro de la Debug Unit.
//
// Frecuencia (Fase 10): 85 MHz.
//   - Fase 7/8: 50 MHz (fmax post-route ~56 MHz; camino critico
//     dmem -> forwarding -> resta de la ALU -> zero -> branch -> flush ID/EX).
//   - Fase 10: comparador de igualdad para beq/bne + burbuja solo de control
//     -> fmax post-sintesis 65 -> 90 MHz, post-route ~96 MHz. Se usa 85 MHz
//     para dejar margen al ruteo real y al jitter del MMCM.
// Si se cambia CLK_HZ hay que regenerar el IP clk_wiz_cpu con la misma
// frecuencia (CLKOUT1_REQUESTED_OUT_FREQ).
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

    localparam CLK_HZ = 85_000_000;
    localparam BAUD   = 115_200;
    // Divisor del generador de baudios (16 muestras por bit), redondeado:
    // 85e6 / (115200*16) = 46,1 -> 46  (error 0,24 %)
    localparam DVSR   = (CLK_HZ + 8 * BAUD) / (16 * BAUD);

    wire clk_cpu, locked;

    clk_wiz_cpu u_clk (
        .clk_in1(clk), .clk_out1(clk_cpu), .locked(locked)
    );

    top_core #(.DVSR(DVSR)) u_core (
        .clk(clk_cpu), .reset_in(btnC | ~locked),
        .rx(RsRx), .tx(RsTx),
        .led(led), .an(an), .seg(seg)
    );

endmodule
