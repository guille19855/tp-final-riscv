`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench autoverificable de forwarding_unit.v.
//
// 1) Casos dirigidos con secuencias de instrucciones reales (comentadas):
//    sin dependencia, desde EX/MEM, desde MEM/WB, prioridad, rd = x0,
//    reg_write = 0, burbuja, los dos operandos a la vez.
// 2) 2000 combinaciones aleatorias contra un modelo de referencia. Los
//    numeros de registro se eligen entre pocos valores (0..3) para que las
//    coincidencias sean frecuentes.

module forwarding_unit_tb;

    reg  [4:0] id_ex_rs1, id_ex_rs2, ex_mem_rd, mem_wb_rd;
    reg        ex_mem_reg_write, mem_wb_reg_write;
    wire [1:0] forward_a, forward_b;

    forwarding_unit dut (
        .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2),
        .ex_mem_rd(ex_mem_rd), .ex_mem_reg_write(ex_mem_reg_write),
        .mem_wb_rd(mem_wb_rd), .mem_wb_reg_write(mem_wb_reg_write),
        .forward_a(forward_a), .forward_b(forward_b));

    integer checks = 0, errors = 0;

    // rs1 rs2 | EX/MEM: rd we | MEM/WB: rd we | esperado A B
    task check(input [4:0] rs1, input [4:0] rs2,
               input [4:0] em_rd, input em_we, input [4:0] mw_rd, input mw_we,
               input [1:0] exp_a, input [1:0] exp_b, input [8*40-1:0] what);
        begin
            id_ex_rs1 = rs1; id_ex_rs2 = rs2;
            ex_mem_rd = em_rd; ex_mem_reg_write = em_we;
            mem_wb_rd = mw_rd; mem_wb_reg_write = mw_we;
            #1;
            checks = checks + 1;
            if (forward_a !== exp_a || forward_b !== exp_b) begin
                errors = errors + 1;
                $display("ERROR %0s: A=%b B=%b, esperaba A=%b B=%b",
                         what, forward_a, forward_b, exp_a, exp_b);
            end else
                $display("OK    %0s: A=%b B=%b", what, forward_a, forward_b);
        end
    endtask

    function [1:0] ref_fwd(input [4:0] rs, input [4:0] em_rd, input em_we,
                           input [4:0] mw_rd, input mw_we);
        begin
            if (em_we && em_rd != 0 && em_rd == rs)      ref_fwd = 2'b10;
            else if (mw_we && mw_rd != 0 && mw_rd == rs) ref_fwd = 2'b01;
            else                                         ref_fwd = 2'b00;
        end
    endfunction

    integer i;
    reg [4:0] r1, r2, er, mr;
    reg ew, mw;

    initial begin
        // Notacion: la instruccion en EX es la ultima de cada secuencia.

        // add x3,x1,x2 sin nada escribiendo x1/x2 adelante
        check(1, 2,  5, 1,  6, 1,  `FWD_REG,    `FWD_REG,    "sin dependencia");
        // add x1,..  ->  sub x4,x1,x5
        check(1, 5,  1, 1,  0, 0,  `FWD_EX_MEM, `FWD_REG,    "A desde EX/MEM");
        // add x5,..  ->  sub x4,x1,x5
        check(1, 5,  5, 1,  0, 0,  `FWD_REG,    `FWD_EX_MEM, "B desde EX/MEM");
        // add x1,.. -> nop -> or x6,x1,x7
        check(1, 7,  0, 0,  1, 1,  `FWD_MEM_WB, `FWD_REG,    "A desde MEM/WB");
        check(7, 1,  0, 0,  1, 1,  `FWD_REG,    `FWD_MEM_WB, "B desde MEM/WB");
        // lw x1,.. -> (burbuja) -> add x3,x1,x2 : el dato del load sale de MEM/WB
        check(1, 2,  0, 0,  1, 1,  `FWD_MEM_WB, `FWD_REG,    "load-use tras stall: MEM/WB");
        // add x1,.. -> sub x1,.. -> or x6,x1,x7 : gana el sub (mas nuevo)
        check(1, 7,  1, 1,  1, 1,  `FWD_EX_MEM, `FWD_REG,    "prioridad EX/MEM > MEM/WB");
        // add x1,.. -> add x2,.. -> add x3,x1,x2 : cada operando de un lado
        check(1, 2,  2, 1,  1, 1,  `FWD_MEM_WB, `FWD_EX_MEM, "A de MEM/WB, B de EX/MEM");
        // add x1,.. -> add x1,x1,x1 : los dos operandos del mismo
        check(1, 1,  1, 1,  0, 0,  `FWD_EX_MEM, `FWD_EX_MEM, "A y B mismo registro");
        // EX/MEM escribe x1 pero con reg_write=0 (ej: sw): no forwardear
        check(1, 2,  1, 0,  0, 0,  `FWD_REG,    `FWD_REG,    "EX/MEM sin reg_write");
        check(1, 2,  0, 0,  1, 0,  `FWD_REG,    `FWD_REG,    "MEM/WB sin reg_write");
        // EX/MEM no escribe x1 pero MEM/WB si: tiene que caer a MEM/WB
        check(1, 2,  1, 0,  1, 1,  `FWD_MEM_WB, `FWD_REG,    "EX/MEM we=0 -> usa MEM/WB");
        // x0: addi x0,.. -> add x3,x0,x0  nunca se forwardea
        check(0, 0,  0, 1,  0, 1,  `FWD_REG,    `FWD_REG,    "x0 nunca se forwardea");
        // Burbuja en EX/MEM y MEM/WB (todo 0) y una instruccion que no usa
        // rs (lui: rs1=rs2=0 guardados limpios en ID)
        check(0, 0,  0, 0,  0, 0,  `FWD_REG,    `FWD_REG,    "burbujas / lui");
        // jal x1 en EX/MEM (escribe x1 = PC+4) -> add x3,x1,x2
        check(1, 2,  1, 1,  0, 0,  `FWD_EX_MEM, `FWD_REG,    "despues de jal x1");

        // ---- Aleatorios contra el modelo ----
        for (i = 0; i < 2000; i = i + 1) begin
            r1 = $random & 3; r2 = $random & 3;
            er = $random & 3; mr = $random & 3;
            ew = $random;     mw = $random;
            id_ex_rs1 = r1; id_ex_rs2 = r2;
            ex_mem_rd = er; ex_mem_reg_write = ew;
            mem_wb_rd = mr; mem_wb_reg_write = mw;
            #1;
            checks = checks + 1;
            if (forward_a !== ref_fwd(r1, er, ew, mr, mw) ||
                forward_b !== ref_fwd(r2, er, ew, mr, mw)) begin
                errors = errors + 1;
                $display("ERROR aleatorio rs1=%0d rs2=%0d em=%0d/%b mw=%0d/%b -> A=%b B=%b",
                         r1, r2, er, ew, mr, mw, forward_a, forward_b);
            end
        end
        $display("OK    2000 casos aleatorios comparados con el modelo");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
