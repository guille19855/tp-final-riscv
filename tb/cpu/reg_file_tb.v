// Testbench del banco de registros.
//
// Escenarios:
//  1. Despues del reset los 32 registros valen 0.
//  2. Escribir x1..x31 con valores distintos y leerlos por los 3 puertos.
//  3. x0 no se puede escribir: sigue leyendo 0.
//  4. we = 0 no escribe.
//  5. Bypass: escribir y leer el mismo registro en el mismo ciclo devuelve
//     el dato NUEVO (en rs1 y en rs2), y no hay bypass hacia x0.
//  6. Bypass solo cuando coincide la direccion: los otros puertos leen normal.
//  7. Reset en medio de la ejecucion vuelve todo a 0.
//
// Convencion (igual que en if_stage_tb): las entradas cambian en el flanco de
// bajada y se chequea 1 ns despues del flanco de subida.

`timescale 1ns / 1ps

module reg_file_tb;

    reg         clk = 0, reset = 1;
    reg  [4:0]  rs1_addr = 0, rs2_addr = 0, rd_addr = 0, dbg_addr = 0;
    reg         we = 0;
    reg  [31:0] rd_data = 0;
    wire [31:0] rs1_data, rs2_data, dbg_data;

    reg_file dut (
        .clk(clk), .reset(reset),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rs1_data(rs1_data), .rs2_data(rs2_data),
        .we(we), .rd_addr(rd_addr), .rd_data(rd_data),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data)
    );

    always #5 clk = ~clk;   // 100 MHz

    integer errors = 0, checks = 0, k;

    function [31:0] val(input [4:0] r);   // valor de prueba distinto por registro
        val = 32'hA5A50000 + r * 32'h00010001;
    endfunction

    task tick;                            // un ciclo: subida, +1 ns
        begin @(posedge clk); #1; end
    endtask

    task expect(input [31:0] got, input [31:0] exp, input [8*40-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %-40s got %h esperado %h", what, got, exp);
            end
        end
    endtask

    // lectura combinacional por los 3 puertos del registro r
    task read_all(input [4:0] r, input [31:0] exp, input [8*40-1:0] what);
        begin
            rs1_addr = r; rs2_addr = r; dbg_addr = r; #1;
            expect(rs1_data, exp, what);
            expect(rs2_data, exp, what);
            expect(dbg_data, exp, what);
        end
    endtask

    initial begin
        // ---- 1. Reset ----
        tick; tick;
        @(negedge clk) reset = 0;
        for (k = 0; k < 32; k = k + 1) read_all(k, 0, "1. reset: todo en 0");
        $display("1. reset: 32 registros en 0            (%0d errores)", errors);

        // ---- 2. Escribir x1..x31 y leer ----
        for (k = 1; k < 32; k = k + 1) begin
            @(negedge clk) begin we = 1; rd_addr = k; rd_data = val(k); end
        end
        @(negedge clk) we = 0;
        for (k = 1; k < 32; k = k + 1) read_all(k, val(k), "2. escribir/leer x1..x31");
        $display("2. escribir y leer x1..x31              (%0d errores)", errors);

        // ---- 3. x0 no se escribe ----
        @(negedge clk) begin we = 1; rd_addr = 0; rd_data = 32'hDEADBEEF; rs1_addr = 0; rs2_addr = 0; end
        #1 expect(rs1_data, 0, "3. x0 sin bypass (mismo ciclo)");
        tick;
        @(negedge clk) we = 0;
        read_all(0, 0, "3. x0 sigue en 0");
        $display("3. x0 no se puede escribir             (%0d errores)", errors);

        // ---- 4. we = 0 no escribe ----
        @(negedge clk) begin we = 0; rd_addr = 5; rd_data = 32'h12345678; end
        tick;
        read_all(5, val(5), "4. we=0 no escribe");
        $display("4. we = 0 no escribe                   (%0d errores)", errors);

        // ---- 5. Bypass: escribir x7 y leerlo en el MISMO ciclo ----
        @(negedge clk) begin
            we = 1; rd_addr = 7; rd_data = 32'hCAFE0007;
            rs1_addr = 7; rs2_addr = 7; dbg_addr = 7;
        end
        #1;
        expect(rs1_data, 32'hCAFE0007, "5. bypass rs1 (antes del flanco)");
        expect(rs2_data, 32'hCAFE0007, "5. bypass rs2 (antes del flanco)");
        expect(dbg_data, val(7),       "5. debug sin bypass: valor viejo");
        tick;                              // ahora si se guarda
        @(negedge clk) we = 0;
        read_all(7, 32'hCAFE0007, "5. x7 quedo guardado");
        $display("5. bypass escritura -> lectura         (%0d errores)", errors);

        // ---- 6. Bypass solo en el puerto que coincide ----
        @(negedge clk) begin
            we = 1; rd_addr = 9; rd_data = 32'hBEEF0009;
            rs1_addr = 9; rs2_addr = 10;
        end
        #1;
        expect(rs1_data, 32'hBEEF0009, "6. rs1=x9 con bypass");
        expect(rs2_data, val(10),      "6. rs2=x10 sin bypass");
        @(negedge clk) we = 0;
        $display("6. bypass solo donde coincide          (%0d errores)", errors);

        // ---- 7. Reset en medio ----
        @(negedge clk) reset = 1;
        tick;
        @(negedge clk) reset = 0;
        for (k = 0; k < 32; k = k + 1) read_all(k, 0, "7. reset en medio");
        $display("7. reset en medio de la ejecucion      (%0d errores)", errors);

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
