`timescale 1ns / 1ps

// Testbench autoverificable de seven_seg.v (con REFRESH_BITS = 4: cada digito
// queda encendido 4 ciclos).
//   1. los 16 valores hex en el digito de la derecha, contra una tabla de
//      segmentos escrita a mano
//   2. multiplexado: en cada ciclo hay UN solo anodo activo y muestra el
//      nibble que corresponde a ese digito
//
//  segmentos:   a          seg = {g,f,e,d,c,b,a}, activo en bajo
//             f   b
//               g
//             e   c
//               d

module seven_seg_tb;

    reg         clk = 0, reset = 1;
    reg  [15:0] value = 0;
    wire [3:0]  an;
    wire [6:0]  seg;

    seven_seg #(.REFRESH_BITS(4)) dut (
        .clk(clk), .reset(reset), .value(value), .an(an), .seg(seg)
    );

    always #5 clk = ~clk;

    // Segmentos ENCENDIDOS de cada digito (activo en alto, para leerla facil)
    //                       gfedcba
    reg [6:0] lit [0:15];
    initial begin
        lit[0]  = 7'b0111111;  // a b c d e f
        lit[1]  = 7'b0000110;  // b c
        lit[2]  = 7'b1011011;  // a b d e g
        lit[3]  = 7'b1001111;  // a b c d g
        lit[4]  = 7'b1100110;  // b c f g
        lit[5]  = 7'b1101101;  // a c d f g
        lit[6]  = 7'b1111101;  // a c d e f g
        lit[7]  = 7'b0000111;  // a b c
        lit[8]  = 7'b1111111;  // todos
        lit[9]  = 7'b1101111;  // a b c d f g
        lit[10] = 7'b1110111;  // A: a b c e f g
        lit[11] = 7'b1111100;  // b: c d e f g
        lit[12] = 7'b0111001;  // C: a d e f
        lit[13] = 7'b1011110;  // d: b c d e g
        lit[14] = 7'b1111001;  // E: a d e f g
        lit[15] = 7'b1110001;  // F: a e f g
    end

    integer checks = 0, errors = 0, i, d;

    task expect(input [31:0] got, input [31:0] exp, input [8*48-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %b, esperaba %b", what, got, exp);
            end else
                $display("OK    %0s = %b", what, got);
        end
    endtask

    reg [8*48-1:0] name;

    initial begin
        @(negedge clk); reset = 0;

        // 1. tabla completa en el digito 0 (los primeros 4 ciclos tras el reset)
        for (i = 0; i < 16; i = i + 1) begin
            reset = 1; value = {12'h000, i[3:0]};
            @(negedge clk); reset = 0; #1;
            $sformat(name, "digito 0 muestra %h (seg)", i[3:0]);
            expect({~seg}, lit[i], name);
            expect(an, 4'b1110, "an = digito 0");
        end

        // 2. multiplexado de 12AF durante 2 vueltas completas (32 ciclos)
        value = 16'h12AF; reset = 1; @(negedge clk); reset = 0;
        for (i = 0; i < 32; i = i + 1) begin
            d = i / 4 % 4;                       // digito que tiene que estar activo
            #1;
            $sformat(name, "ciclo %0d: anodo del digito %0d", i, d);
            expect(an, {~(4'b0001 << d)}, name);
            $sformat(name, "ciclo %0d: segmentos", i);
            expect({~seg}, lit[(value >> (4 * d)) & 4'hF], name);
            @(negedge clk);
        end

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
