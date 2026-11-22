`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench autoverificable de wb_stage.v.
// La etapa es combinacional: se cargan las entradas del latch MEM/WB y se
// chequea que valor se manda al banco de registros, una instruccion por caso.

module wb_stage_tb;

    reg  [31:0] mem_wb_result, mem_wb_load_data;
    reg  [4:0]  mem_wb_rd;
    reg         mem_wb_reg_write, mem_wb_halt;
    reg  [1:0]  mem_wb_wb_sel;
    wire        wb_reg_write, program_done;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    wb_stage dut (
        .mem_wb_result(mem_wb_result), .mem_wb_load_data(mem_wb_load_data),
        .mem_wb_rd(mem_wb_rd), .mem_wb_reg_write(mem_wb_reg_write),
        .mem_wb_wb_sel(mem_wb_wb_sel), .mem_wb_halt(mem_wb_halt),
        .wb_reg_write(wb_reg_write), .wb_rd(wb_rd), .wb_data(wb_data),
        .program_done(program_done)
    );

    integer checks = 0, errors = 0;

    task expect(input [31:0] got, input [31:0] exp, input [8*40-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %h, esperaba %h", what, got, exp);
            end else
                $display("OK    %0s = %h", what, got);
        end
    endtask

    // Carga MEM/WB: result, load_data, rd, reg_write, wb_sel, halt
    task set(input [31:0] res, input [31:0] ld, input [4:0] rd,
             input we, input [1:0] sel, input h);
        begin
            mem_wb_result = res; mem_wb_load_data = ld; mem_wb_rd = rd;
            mem_wb_reg_write = we; mem_wb_wb_sel = sel; mem_wb_halt = h;
            #1;
        end
    endtask

    initial begin
        // add x3, ... = 0x12 : escribe el resultado de la ALU
        set(32'h12, 32'hBAD, 3, 1, `WB_ALU, 0);
        expect(wb_data, 32'h12, "add: wb_data = result");
        expect(wb_rd, 3,        "add: rd");
        expect(wb_reg_write, 1, "add: reg_write");

        // lw x5 desde 0x100 = 0xDEADBEEF : escribe el dato leido, no la direccion
        set(32'h100, 32'hDEADBEEF, 5, 1, `WB_MEM, 0);
        expect(wb_data, 32'hDEADBEEF, "lw: wb_data = dato leido");

        // lb x6 = -128 (ya extendido en MEM)
        set(32'h403, 32'hFFFFFF80, 6, 1, `WB_MEM, 0);
        expect(wb_data, 32'hFFFFFF80, "lb: dato extendido");

        // jal x1 en pc 0x100 : result ya trae PC+4 (decision 1-A)
        set(32'h104, 32'hBAD, 1, 1, `WB_PC4, 0);
        expect(wb_data, 32'h104, "jal: wb_data = PC+4");
        expect(wb_rd, 1,         "jal: rd");

        // sw : no escribe registro
        set(32'h200, 32'h0, 0, 0, `WB_ALU, 0);
        expect(wb_reg_write, 0, "sw: reg_write = 0");

        // burbuja: todo en 0
        set(0, 0, 0, 0, `WB_ALU, 0);
        expect(wb_reg_write, 0, "burbuja: reg_write = 0");
        expect(wb_data, 0,      "burbuja: wb_data = 0");
        expect(program_done, 0, "burbuja: program_done = 0");

        // ebreak llega a WB: programa terminado, no escribe registro
        set(0, 0, 0, 0, `WB_ALU, 1);
        expect(program_done, 1, "ebreak: program_done");
        expect(wb_reg_write, 0, "ebreak: reg_write = 0");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
