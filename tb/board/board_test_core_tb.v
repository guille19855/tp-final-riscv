`timescale 1ns / 1ps

// Testbench autoverificable de board_test_core.v (la prueba en la placa sin el
// Clock Wizard). Usa el programa ejemplo (suma 1..10: x10 = x11 = 55 = 0x37)
// y constantes chicas para el antirrebote y el display.
//
//   1. modo continuo: carga, corre hasta program_done y queda congelado;
//      el display muestra x10 = 0037 y el PC
//   2. modo paso a paso: sin apretar BTNR el PC no se mueve; cada apriete
//      (aunque se mantenga apretado) avanza exactamente 1 ciclo
//   3. pasar a continuo en medio del programa: termina con el mismo resultado

module board_test_core_tb;

    reg         clk = 0, reset_in = 1, btn_step = 0;
    reg  [15:0] sw = 0;
    wire [15:0] led;
    wire [3:0]  an;
    wire [6:0]  seg;

    localparam DEB = 4;

    board_test_core #(.PROG_FILE(""), .ROM_WORDS(256), .DEB_CYCLES(DEB), .REFRESH_BITS(4)) dut (
        .clk(clk), .reset_in(reset_in), .btn_step(btn_step), .sw(sw),
        .led(led), .an(an), .seg(seg)
    );

    always #10 clk = ~clk;   // 50 MHz, como en la placa

    integer checks = 0, errors = 0, fd, cycles;
    reg [8*128-1:0] fname;

    task expect(input [31:0] got, input [31:0] exp, input [8*48-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %h, esperaba %h", what, got, exp);
            end else
                $display("OK    %0s = %h", what, got);
        end
    endtask

    // reset y carga del programa (256 ciclos)
    task reset_and_load;
        begin
            reset_in = 1; repeat (4) @(negedge clk);
            reset_in = 0;
            cycles = 0;
            while (!led[14] && cycles < 1000) begin @(negedge clk); cycles = cycles + 1; end
        end
    endtask

    task press_step;   // apriete largo (mucho mas que el antirrebote)
        begin
            btn_step = 1; repeat (DEB * 5) @(negedge clk);
            btn_step = 0; repeat (DEB * 5) @(negedge clk);
        end
    endtask

    initial begin
        // El programa se carga en la ROM desde aca: la ruta depende de donde
        // corra el simulador (terminal: sim_out/<tb>, GUI: .../behav/xsim)
        fname = "../../programs/ejemplo.hex";
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            fname = "../../../../../programs/ejemplo.hex";
            fd = $fopen(fname, "r");
        end
        if (fd == 0) begin
            $display("ERROR no encuentro programs/ejemplo.hex");
            $display("TEST FAILED: 0 checks, 1 errors");
            $finish;
        end
        $fclose(fd);
        #1 $readmemh(fname, dut.rom);

        // ---------------- 1. modo continuo ----------------
        sw = 16'h8000 | (16'd10 << 8); // SW15 = continuo, SW12..8 = x10
        reset_and_load;
        expect(led[14], 1, "continuo: programa cargado");
        expect(cycles, 258, "continuo: carga = 2 (sincronizador) + 256 ciclos");
        cycles = 0;
        while (!led[15] && cycles < 1000) begin @(negedge clk); cycles = cycles + 1; end
        expect(led[15], 1, "continuo: program_done");
        expect(cycles, 56, "continuo: 56 ciclos (igual que cpu_top_tb)");
        repeat (50) @(negedge clk);
        expect(led[15], 1, "continuo: program_done se mantiene (en = 0)");
        expect(dut.en, 0, "continuo: en = 0 al terminar");
        expect(dut.shown, 16'h0037, "display: x10 = 0037 (55)");
        sw[12:8] = 11; #1;
        expect(dut.shown, 16'h0037, "display: x11 = 0037");
        sw[14] = 1; #1;
        expect(dut.shown, 16'h0000, "display: x11 mitad alta");
        sw[14] = 0; sw[13] = 1; #1;
        expect(dut.shown, 16'h0020, "display: PC congelado en 0x20 (halt)");
        expect(led[13], 1, "LED13: modo continuo");

        // ---------------- 2. paso a paso ----------------
        sw = 16'h2000;                   // SW15 = 0 (paso), SW13 = mostrar PC
        reset_and_load;
        repeat (100) @(negedge clk);
        expect(dut.pc, 0, "paso: sin apretar, el PC no avanza");
        expect(led[13], 0, "LED13: modo paso");
        press_step;
        expect(dut.pc, 4, "paso: 1 apriete = 1 ciclo (PC = 4)");
        press_step;
        expect(dut.pc, 8, "paso: 2 aprietes (PC = 8)");
        expect(dut.shown, 8, "display: muestra el PC");
        expect(led[7:0], 2, "LED7..0 = PC[9:2]");
        repeat (5) press_step;
        expect(led[15], 0, "paso: todavia no termino");

        // ---------------- 3. pasar a continuo y terminar ----------------
        sw = 16'h8000 | (16'd10 << 8);
        cycles = 0;
        while (!led[15] && cycles < 1000) begin @(negedge clk); cycles = cycles + 1; end
        expect(led[15], 1, "paso -> continuo: program_done");
        expect(dut.shown, 16'h0037, "paso -> continuo: x10 = 0037");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
