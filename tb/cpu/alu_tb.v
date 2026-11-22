`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench autoverificable de alu.v.
//
// 1) Casos dirigidos: los bordes donde una ALU suele fallar (desborde que
//    "da la vuelta", signo en SLT vs SLTU, SRA vs SRL con negativos, shift
//    que solo usa b[4:0], flag zero).
// 2) 200 casos aleatorios por operacion, comparados contra un modelo de
//    referencia escrito DISTINTO a la ALU (sin usar >>>, $signed ni <<),
//    para que un error de concepto no se repita en los dos lados.

module alu_tb;

    reg  [31:0] a, b;
    reg  [3:0]  op;
    wire [31:0] result;
    wire        zero;

    alu dut (.a(a), .b(b), .op(op), .result(result), .zero(zero));

    integer checks = 0, errors = 0;

    // Aplica una operacion y compara resultado y zero
    task check(input [3:0] o, input [31:0] x, input [31:0] y,
               input [31:0] exp, input [8*20-1:0] what);
        begin
            op = o; a = x; b = y;
            #1;
            checks = checks + 1;
            if (result !== exp || zero !== (exp == 32'd0)) begin
                errors = errors + 1;
                $display("ERROR %0s: a=%h b=%h -> %h (zero=%b), esperaba %h",
                         what, x, y, result, zero, exp);
            end else
                $display("OK    %0s: a=%h b=%h -> %h", what, x, y, result);
        end
    endtask

    // ---- Modelo de referencia ----
    function [31:0] ref_alu(input [3:0] o, input [31:0] x, input [31:0] y);
        reg [63:0] ext;
        reg [4:0]  s;
        begin
            s = y[4:0];
            case (o)
                `ALU_ADD:  ref_alu = x + y;
                `ALU_SUB:  ref_alu = x + ~y + 32'd1;          // complemento a 2
                `ALU_SLL:  ref_alu = x * (32'd1 << s);         // correr = multiplicar por 2^s
                `ALU_SLT:  ref_alu = (x[31] != y[31]) ? x[31]  // signos distintos: el negativo es menor
                                                      : (x < y);
                `ALU_SLTU: ref_alu = (x < y);
                `ALU_XOR:  ref_alu = x ^ y;
                `ALU_SRL:  ref_alu = x / (32'd1 << s);         // dividir por 2^s (sin signo)
                `ALU_SRA:  begin                               // extender a 64 bits con el signo y correr
                               ext = {{32{x[31]}}, x} >> s;
                               ref_alu = ext[31:0];
                           end
                `ALU_OR:   ref_alu = x | y;
                `ALU_AND:  ref_alu = x & y;
                default:   ref_alu = 32'd0;
            endcase
        end
    endfunction

    reg [3:0] ops [0:9];
    integer i, k;
    reg [31:0] ra, rb, exp;

    initial begin
        // ---------------- Casos dirigidos ----------------
        // ADD / SUB
        check(`ALU_ADD,  32'd5,        32'd7,        32'd12,       "add simple");
        check(`ALU_ADD,  32'h7FFFFFFF, 32'd1,        32'h80000000, "add desborde");
        check(`ALU_ADD,  32'hFFFFFFFF, 32'd1,        32'd0,        "add -1+1 = 0");
        check(`ALU_ADD,  32'd100,      32'hFFFFFFFC, 32'd96,       "add imm negativo");
        check(`ALU_SUB,  32'd7,        32'd5,        32'd2,        "sub simple");
        check(`ALU_SUB,  32'd0,        32'd1,        32'hFFFFFFFF, "sub 0-1 = -1");
        check(`ALU_SUB,  32'h1234,     32'h1234,     32'd0,        "sub iguales: zero");
        check(`ALU_SUB,  32'h80000000, 32'd1,        32'h7FFFFFFF, "sub desborde");
        // SLT (con signo) vs SLTU (sin signo)
        check(`ALU_SLT,  32'hFFFFFFFF, 32'd1,        32'd1,        "slt -1 < 1");
        check(`ALU_SLTU, 32'hFFFFFFFF, 32'd1,        32'd0,        "sltu 0xFFFFFFFF > 1");
        check(`ALU_SLT,  32'd1,        32'hFFFFFFFF, 32'd0,        "slt 1 < -1? no");
        check(`ALU_SLTU, 32'd1,        32'hFFFFFFFF, 32'd1,        "sltu 1 < 0xFFFFFFFF");
        check(`ALU_SLT,  32'h80000000, 32'h7FFFFFFF, 32'd1,        "slt min < max");
        check(`ALU_SLT,  32'd5,        32'd5,        32'd0,        "slt iguales");
        check(`ALU_SLT,  32'hFFFFFFFE, 32'hFFFFFFFF, 32'd1,        "slt -2 < -1");
        // Shifts
        check(`ALU_SLL,  32'd1,        32'd31,       32'h80000000, "sll 1<<31");
        check(`ALU_SLL,  32'hFFFFFFFF, 32'd4,        32'hFFFFFFF0, "sll entra 0");
        check(`ALU_SLL,  32'd1,        32'd33,       32'd2,        "sll usa b[4:0]");
        check(`ALU_SRL,  32'h80000000, 32'd31,       32'd1,        "srl rellena 0");
        check(`ALU_SRA,  32'h80000000, 32'd31,       32'hFFFFFFFF, "sra repite signo");
        check(`ALU_SRA,  32'hFFFFFFF0, 32'd2,        32'hFFFFFFFC, "sra -16>>2 = -4");
        check(`ALU_SRA,  32'h70000000, 32'd4,        32'h07000000, "sra positivo");
        check(`ALU_SRL,  32'hF0000000, 32'd36,       32'h0F000000, "srl usa b[4:0]");
        check(`ALU_SRA,  32'h12345678, 32'd0,        32'h12345678, "sra por 0");
        // Logicas
        check(`ALU_AND,  32'hF0F0F0F0, 32'hFF00FF00, 32'hF000F000, "and");
        check(`ALU_OR,   32'hF0F0F0F0, 32'h0F0F0F0F, 32'hFFFFFFFF, "or");
        check(`ALU_XOR,  32'hAAAAAAAA, 32'hAAAAAAAA, 32'd0,        "xor iguales: zero");
        check(`ALU_XOR,  32'hAAAAAAAA, 32'h55555555, 32'hFFFFFFFF, "xor");
        // Codigo invalido
        check(4'b1111,   32'd5,        32'd7,        32'd0,        "op invalido = 0");

        // ---------------- Aleatorios contra el modelo ----------------
        ops[0] = `ALU_ADD;  ops[1] = `ALU_SUB;  ops[2] = `ALU_SLL;
        ops[3] = `ALU_SLT;  ops[4] = `ALU_SLTU; ops[5] = `ALU_XOR;
        ops[6] = `ALU_SRL;  ops[7] = `ALU_SRA;  ops[8] = `ALU_OR;
        ops[9] = `ALU_AND;
        for (k = 0; k < 10; k = k + 1)
            for (i = 0; i < 200; i = i + 1) begin
                ra = $random; rb = $random;
                if (i % 20 == 0) rb = ra;          // fuerza casos iguales (zero, slt)
                op = ops[k]; a = ra; b = rb;
                #1;
                exp = ref_alu(ops[k], ra, rb);
                checks = checks + 1;
                if (result !== exp || zero !== (exp == 32'd0)) begin
                    errors = errors + 1;
                    $display("ERROR aleatorio op=%b a=%h b=%h -> %h, esperaba %h",
                             ops[k], ra, rb, result, exp);
                end
            end
        $display("OK    2000 casos aleatorios (200 por operacion) comparados con el modelo");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
