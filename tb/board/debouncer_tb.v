`timescale 1ns / 1ps

// Testbench autoverificable de debouncer.v (con STABLE_CYCLES = 4).
// Cuenta los pulsos generados: cada apriete limpio tiene que dar exactamente
// uno, y un rebote mas corto que STABLE_CYCLES no tiene que dar ninguno.

module debouncer_tb;

    reg  clk = 0, reset = 1, btn = 0;
    wire level, pulse;

    debouncer #(.STABLE_CYCLES(4)) dut (
        .clk(clk), .reset(reset), .btn(btn), .level(level), .pulse(pulse)
    );

    always #5 clk = ~clk;

    integer checks = 0, errors = 0, pulses = 0, pulse_len = 0, max_len = 0;
    always @(posedge clk) begin
        if (pulse) begin pulse_len = pulse_len + 1; end
        else begin
            if (pulse_len > 0) pulses = pulses + 1;
            if (pulse_len > max_len) max_len = pulse_len;
            pulse_len = 0;
        end
    end

    task expect(input integer got, input integer exp, input [8*48-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %0d, esperaba %0d", what, got, exp);
            end else
                $display("OK    %0s = %0d", what, got);
        end
    endtask

    task wait_cycles(input integer n); repeat (n) @(negedge clk); endtask

    initial begin
        wait_cycles(2); reset = 0;

        // 1. apriete limpio y largo: 1 pulso de 1 ciclo
        btn = 1; wait_cycles(3);
        expect(level, 0, "todavia no confirmado (3 ciclos)");
        wait_cycles(20);
        expect(level, 1, "apriete confirmado");
        expect(pulses, 1, "apriete largo: 1 solo pulso");
        expect(max_len, 1, "el pulso dura 1 ciclo");

        // 2. soltar
        btn = 0; wait_cycles(20);
        expect(level, 0, "soltado");
        expect(pulses, 1, "soltar no genera pulso");

        // 3. rebotes cortos (2 ciclos arriba, 1 abajo...) y despues estable
        btn = 1; wait_cycles(2); btn = 0; wait_cycles(1);
        btn = 1; wait_cycles(2); btn = 0; wait_cycles(2);
        btn = 1; wait_cycles(1); btn = 0; wait_cycles(10);
        expect(level, 0, "rebotes cortos: no cambia");
        expect(pulses, 1, "rebotes cortos: sin pulsos");

        btn = 1; wait_cycles(2); btn = 0; wait_cycles(1);   // rebota al apretar
        btn = 1; wait_cycles(20);                            // y se estabiliza
        expect(level, 1, "apriete con rebote: confirmado");
        expect(pulses, 2, "apriete con rebote: 1 pulso");

        // 4. rebote al soltar: no genera pulsos extra
        btn = 0; wait_cycles(1); btn = 1; wait_cycles(2); btn = 0; wait_cycles(20);
        expect(level, 0, "soltar con rebote");
        expect(pulses, 2, "soltar con rebote: sin pulso");

        // 5. tres aprietes: tres pulsos
        repeat (3) begin btn = 1; wait_cycles(10); btn = 0; wait_cycles(10); end
        expect(pulses, 5, "3 aprietes: 3 pulsos mas");

        // 6. reset en medio de un apriete
        btn = 1; wait_cycles(10); reset = 1; wait_cycles(1);
        expect(level, 0, "reset: level = 0");
        reset = 0; btn = 0; wait_cycles(10);

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
