// Testbench de la unidad de hazard.
//
// Casos con secuencias de instrucciones reales (la de EX y la de ID):
//   - load-use por rs1 y por rs2                          -> stall
//   - load seguido de una instruccion que NO usa ese reg   -> no stall
//   - el registro coincide pero la instruccion no lo usa   -> no stall
//     (lui, jal, ebreak: los campos rs1/rs2 tienen otros bits)
//   - load a x0                                            -> no stall
//   - instruccion en EX que no es load (add)               -> no stall (forwarding)
//   - store despues de load usando el dato (rs2)           -> stall
//   - salto tomado                                         -> flush, sin stall
//   - salto tomado + load-use al mismo tiempo              -> gana el salto
//
// Combinacional: se cambia la entrada, se espera 1 ns y se compara.

`timescale 1ns / 1ps

module hazard_unit_tb;

    reg  [4:0] id_rs1, id_rs2, ex_rd;
    reg        id_usa_rs1, id_usa_rs2, ex_mem_read, branch_taken;
    wire       load_use, stall, flush_id_ex;

    hazard_unit dut (
        .id_rs1(id_rs1), .id_rs2(id_rs2),
        .id_usa_rs1(id_usa_rs1), .id_usa_rs2(id_usa_rs2),
        .ex_mem_read(ex_mem_read), .ex_rd(ex_rd),
        .branch_taken(branch_taken),
        .load_use(load_use), .stall(stall), .flush_id_ex(flush_id_ex)
    );

    integer errors = 0, checks = 0;

    // ex: (es load, rd)   id: (rs1, usa_rs1, rs2, usa_rs2)   salto
    // esperado: {load_use, stall, flush_id_ex}
    task check(input ex_ld, input [4:0] rd,
               input [4:0] r1, input u1, input [4:0] r2, input u2,
               input br, input [2:0] exp, input [8*44-1:0] what);
        begin
            ex_mem_read = ex_ld; ex_rd = rd;
            id_rs1 = r1; id_usa_rs1 = u1; id_rs2 = r2; id_usa_rs2 = u2;
            branch_taken = br;
            #1;
            checks = checks + 1;
            if ({load_use, stall, flush_id_ex} === exp)
                $display("OK   %-44s lu=%b stall=%b flush=%b", what, load_use, stall, flush_id_ex);
            else begin
                errors = errors + 1;
                $display("FAIL %-44s lu=%b stall=%b flush=%b  esperado %b",
                         what, load_use, stall, flush_id_ex, exp);
            end
        end
    endtask

    initial begin
        //     ex_ld rd    rs1 u1  rs2 u2  br  {lu,st,fl}
        // --- load-use: hay que frenar ---
        check(1, 5'd5,  5'd5, 1, 5'd2, 1, 0, 3'b111, "lw x5 | add x6,x5,x2   (rs1)");
        check(1, 5'd5,  5'd2, 1, 5'd5, 1, 0, 3'b111, "lw x5 | add x6,x2,x5   (rs2)");
        check(1, 5'd5,  5'd5, 1, 5'd5, 1, 0, 3'b111, "lw x5 | add x6,x5,x5   (ambos)");
        check(1, 5'd5,  5'd5, 1, 5'd0, 0, 0, 3'b111, "lw x5 | addi x6,x5,1");
        check(1, 5'd5,  5'd5, 1, 5'd0, 0, 0, 3'b111, "lw x5 | lw x6,0(x5)    (direccion)");
        check(1, 5'd5,  5'd1, 1, 5'd5, 1, 0, 3'b111, "lw x5 | sw x5,0(x1)    (dato)");
        check(1, 5'd5,  5'd5, 1, 5'd0, 1, 0, 3'b111, "lw x5 | beq x5,x0,L");
        check(1, 5'd5,  5'd5, 1, 5'd0, 0, 0, 3'b111, "lw x5 | jalr x1,0(x5)");

        // --- no hay que frenar ---
        check(1, 5'd5,  5'd1, 1, 5'd2, 1, 0, 3'b000, "lw x5 | add x6,x1,x2   (otro reg)");
        check(0, 5'd5,  5'd5, 1, 5'd2, 1, 0, 3'b000, "add x5| add x6,x5,x2   (forwarding)");
        check(1, 5'd0,  5'd0, 1, 5'd0, 1, 0, 3'b000, "lw x0 | add x6,x0,x0   (x0)");
        // campos que coinciden pero no son registros leidos:
        check(1, 5'd5,  5'd5, 0, 5'd0, 0, 0, 3'b000, "lw x5 | lui x6,...  (bits=x5, no lee)");
        check(1, 5'd5,  5'd5, 0, 5'd5, 0, 0, 3'b000, "lw x5 | jal x6,...  (bits=x5, no lee)");
        check(1, 5'd1,  5'd0, 0, 5'd1, 0, 0, 3'b000, "lw x1 | ebreak      (rs2 bits=x1)");
        check(1, 5'd5,  5'd1, 1, 5'd5, 0, 0, 3'b000, "lw x5 | addi (imm bits=x5, no lee)");

        // --- saltos ---
        check(0, 5'd0,  5'd1, 1, 5'd2, 1, 1, 3'b001, "beq tomado en EX      -> flush");
        check(1, 5'd5,  5'd5, 1, 5'd2, 1, 1, 3'b101, "salto+load-use (proteccion) -> sin stall");

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
