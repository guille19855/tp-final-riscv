// Display de 7 segmentos de 4 digitos de la Basys3: muestra 16 bits en hex.
//
// Los 4 digitos comparten los mismos 7 pines de segmentos (seg); cada digito
// tiene su propio anodo (an). Solo se puede encender un digito a la vez, asi
// que se MULTIPLEXA: se enciende uno, despues el siguiente, etc., lo bastante
// rapido (~1 kHz por digito) para que el ojo los vea a los 4 encendidos.
//
// En la Basys3 todo es activo en BAJO (0 = encendido):
//   an[3:0]  anodos, an[0] = digito de la derecha
//   seg[6:0] = {g, f, e, d, c, b, a}
//
//        a
//      f   b
//        g
//      e   c
//        d
//
// REFRESH_BITS: el digito activo lo eligen los 2 bits altos de un contador
// libre de REFRESH_BITS bits. Con 50 MHz y 18 bits: 50e6 / 2^16 = 763 Hz por
// digito. En el testbench se usa un valor chico.

`timescale 1ns / 1ps

module seven_seg #(
    parameter integer REFRESH_BITS = 18
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] value,
    output reg  [3:0]  an,
    output reg  [6:0]  seg
);

    reg [REFRESH_BITS-1:0] refresh;
    always @(posedge clk) begin
        if (reset) refresh <= 0;
        else       refresh <= refresh + 1'b1;
    end

    wire [1:0] digit = refresh[REFRESH_BITS-1 -: 2];

    reg [3:0] nibble;
    always @(*) begin
        case (digit)
            2'd0: begin an = 4'b1110; nibble = value[3:0];   end
            2'd1: begin an = 4'b1101; nibble = value[7:4];   end
            2'd2: begin an = 4'b1011; nibble = value[11:8];  end
            default: begin an = 4'b0111; nibble = value[15:12]; end
        endcase
    end

    // Decodificador hex -> segmentos (activo en bajo)        gfedcba
    always @(*) begin
        case (nibble)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;   // b minuscula
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;   // d minuscula
            4'hE: seg = 7'b0000110;
            default: seg = 7'b0001110; // F
        endcase
    end

endmodule
