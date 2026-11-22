`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench autoverificable de ex_stage.v (etapa EX + latch EX/MEM).
//
// El TB hace de "etapa ID": cada ciclo carga a mano el latch ID/EX con una
// instruccion (con las mismas senales que pondria control_unit), y hace de
// "etapa WB" manejando mem_wb_rd / mem_wb_reg_write / wb_data.
//
// Convencion de tiempos (igual que los otros TB):
//   flanco de bajada -> se cargan las entradas
//   +1 ns            -> se chequean las salidas combinacionales (salto)
//   flanco de subida -> EX/MEM captura; +1 ns se chequea el latch
//
// Las instrucciones van en secuencia, asi el latch EX/MEM tiene la
// instruccion anterior y se puede probar el forwarding desde EX/MEM.
// Los valores "viejos" del banco se ponen en 0xDEAD.. para que si el
// forwarding falla se note enseguida.

module ex_stage_tb;

    reg clk = 0, reset = 1, en = 1;
    always #5 clk = ~clk;

    // ---- Latch ID/EX (lo maneja el TB) ----
    reg [31:0] id_ex_pc, id_ex_pc4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_funct7b5, id_ex_alu_src_a, id_ex_alu_src_b;
    reg [1:0]  id_ex_alu_op, id_ex_wb_sel;
    reg        id_ex_branch, id_ex_jal, id_ex_jalr;
    reg        id_ex_mem_read, id_ex_mem_write, id_ex_reg_write, id_ex_halt;

    // ---- WB (lo maneja el TB) ----
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_reg_write;
    reg [31:0] wb_data;

    wire        branch_taken;
    wire [31:0] branch_target;
    wire [31:0] ex_mem_result, ex_mem_rs2_data;
    wire [4:0]  ex_mem_rd;
    wire [2:0]  ex_mem_funct3;
    wire        ex_mem_mem_read, ex_mem_mem_write, ex_mem_reg_write, ex_mem_halt;
    wire [1:0]  ex_mem_wb_sel;

    ex_stage dut (
        .clk(clk), .reset(reset), .en(en),
        .id_ex_pc(id_ex_pc), .id_ex_pc4(id_ex_pc4),
        .id_ex_rs1_data(id_ex_rs1_data), .id_ex_rs2_data(id_ex_rs2_data),
        .id_ex_imm(id_ex_imm), .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2),
        .id_ex_rd(id_ex_rd), .id_ex_funct3(id_ex_funct3),
        .id_ex_funct7b5(id_ex_funct7b5),
        .id_ex_alu_src_a(id_ex_alu_src_a), .id_ex_alu_src_b(id_ex_alu_src_b),
        .id_ex_alu_op(id_ex_alu_op), .id_ex_branch(id_ex_branch),
        .id_ex_jal(id_ex_jal), .id_ex_jalr(id_ex_jalr),
        .id_ex_mem_read(id_ex_mem_read), .id_ex_mem_write(id_ex_mem_write),
        .id_ex_reg_write(id_ex_reg_write), .id_ex_wb_sel(id_ex_wb_sel),
        .id_ex_halt(id_ex_halt),
        .mem_wb_rd(mem_wb_rd), .mem_wb_reg_write(mem_wb_reg_write),
        .wb_data(wb_data),
        .branch_taken(branch_taken), .branch_target(branch_target),
        .ex_mem_result(ex_mem_result), .ex_mem_rs2_data(ex_mem_rs2_data),
        .ex_mem_rd(ex_mem_rd), .ex_mem_funct3(ex_mem_funct3),
        .ex_mem_mem_read(ex_mem_mem_read), .ex_mem_mem_write(ex_mem_mem_write),
        .ex_mem_reg_write(ex_mem_reg_write), .ex_mem_wb_sel(ex_mem_wb_sel),
        .ex_mem_halt(ex_mem_halt)
    );

    integer checks = 0, errors = 0;

    task expect(input [31:0] got, input [31:0] exp, input [8*44-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %h, esperaba %h  (t=%0t)", what, got, exp, $time);
            end else
                $display("OK    %0s = %h", what, got);
        end
    endtask

    // ---------------------------------------------------------------
    // "Etapa ID" de mentira: cada task carga ID/EX como lo haria
    // id_stage para esa familia de instrucciones (ver tabla_control).
    // ---------------------------------------------------------------
    task bubble;   // todo en 0 = burbuja
        begin
            id_ex_pc = 0; id_ex_pc4 = 0; id_ex_rs1_data = 0; id_ex_rs2_data = 0;
            id_ex_imm = 0; id_ex_rs1 = 0; id_ex_rs2 = 0; id_ex_rd = 0;
            id_ex_funct3 = 0; id_ex_funct7b5 = 0;
            id_ex_alu_src_a = 0; id_ex_alu_src_b = 0; id_ex_alu_op = `ALUOP_ADD;
            id_ex_branch = 0; id_ex_jal = 0; id_ex_jalr = 0;
            id_ex_mem_read = 0; id_ex_mem_write = 0; id_ex_reg_write = 0;
            id_ex_wb_sel = `WB_ALU; id_ex_halt = 0;
        end
    endtask

    task r_type(input [2:0] f3, input b30, input [4:0] rd, input [4:0] rs1,
                input [4:0] rs2, input [31:0] d1, input [31:0] d2);
        begin
            bubble;
            id_ex_rs1 = rs1; id_ex_rs2 = rs2; id_ex_rd = rd;
            id_ex_rs1_data = d1; id_ex_rs2_data = d2;
            id_ex_funct3 = f3; id_ex_funct7b5 = b30;
            id_ex_alu_op = `ALUOP_R; id_ex_reg_write = 1;
        end
    endtask

    task i_type(input [2:0] f3, input [4:0] rd, input [4:0] rs1,
                input [31:0] d1, input [31:0] imm);
        begin
            bubble;
            id_ex_rs1 = rs1; id_ex_rd = rd; id_ex_rs1_data = d1;
            id_ex_imm = imm; id_ex_funct3 = f3;
            id_ex_funct7b5 = imm[10];       // instr[30] = imm[10] en tipo I
            id_ex_alu_src_b = 1; id_ex_alu_op = `ALUOP_I; id_ex_reg_write = 1;
        end
    endtask

    task load(input [2:0] f3, input [4:0] rd, input [4:0] rs1,
              input [31:0] d1, input [31:0] imm);
        begin
            bubble;
            id_ex_rs1 = rs1; id_ex_rd = rd; id_ex_rs1_data = d1;
            id_ex_imm = imm; id_ex_funct3 = f3; id_ex_funct7b5 = imm[10];
            id_ex_alu_src_b = 1; id_ex_mem_read = 1; id_ex_reg_write = 1;
            id_ex_wb_sel = `WB_MEM;
        end
    endtask

    task store(input [2:0] f3, input [4:0] rs1, input [4:0] rs2,
               input [31:0] d1, input [31:0] d2, input [31:0] imm);
        begin
            bubble;
            id_ex_rs1 = rs1; id_ex_rs2 = rs2;     // rd = 0: no escribe
            id_ex_rs1_data = d1; id_ex_rs2_data = d2;
            id_ex_imm = imm; id_ex_funct3 = f3; id_ex_funct7b5 = imm[10];
            id_ex_alu_src_b = 1; id_ex_mem_write = 1;
        end
    endtask

    task branch(input [2:0] f3, input [4:0] rs1, input [4:0] rs2,
                input [31:0] d1, input [31:0] d2, input [31:0] pc, input [31:0] imm);
        begin
            bubble;
            id_ex_pc = pc; id_ex_pc4 = pc + 4;
            id_ex_rs1 = rs1; id_ex_rs2 = rs2;
            id_ex_rs1_data = d1; id_ex_rs2_data = d2;
            id_ex_imm = imm; id_ex_funct3 = f3; id_ex_funct7b5 = imm[10];
            id_ex_alu_op = `ALUOP_SUB; id_ex_branch = 1;
        end
    endtask

    task jal(input [4:0] rd, input [31:0] pc, input [31:0] imm);
        begin
            bubble;
            id_ex_pc = pc; id_ex_pc4 = pc + 4; id_ex_rd = rd;
            id_ex_rs1_data = 32'hDEAD0001;        // rs1 no se usa (rs1 = 0)
            id_ex_imm = imm; id_ex_jal = 1;
            id_ex_reg_write = 1; id_ex_wb_sel = `WB_PC4;
        end
    endtask

    task jalr(input [4:0] rd, input [4:0] rs1, input [31:0] d1,
              input [31:0] pc, input [31:0] imm);
        begin
            bubble;
            id_ex_pc = pc; id_ex_pc4 = pc + 4; id_ex_rd = rd;
            id_ex_rs1 = rs1; id_ex_rs1_data = d1;
            id_ex_imm = imm; id_ex_alu_src_b = 1; id_ex_jalr = 1;
            id_ex_reg_write = 1; id_ex_wb_sel = `WB_PC4;
        end
    endtask

    task lui(input [4:0] rd, input [31:0] imm);
        begin
            bubble;
            id_ex_rd = rd; id_ex_imm = imm;
            id_ex_rs1_data = 32'hDEAD0002;        // basura del campo rs1: no se usa
            id_ex_alu_src_a = 1; id_ex_alu_src_b = 1; id_ex_reg_write = 1;
        end
    endtask

    task wb_idle;
        begin mem_wb_rd = 0; mem_wb_reg_write = 0; wb_data = 32'hDEADBEEF; end
    endtask

    task wb_write(input [4:0] rd, input [31:0] d);
        begin mem_wb_rd = rd; mem_wb_reg_write = 1; wb_data = d; end
    endtask

    // Espera el flanco que captura EX/MEM y deja pasar 1 ns
    task clock;
        begin @(posedge clk); #1; end
    endtask

    // Chequea la decision de salto (combinacional, antes del flanco)
    task expect_jump(input taken, input [31:0] target, input [8*30-1:0] what);
        begin
            #1;
            expect(branch_taken, taken, {what, " taken"});
            if (taken) expect(branch_target, target, {what, " target"});
        end
    endtask

    initial begin
        bubble; wb_idle;

        // ---------------- 1. Reset ----------------
        @(negedge clk); @(negedge clk);
        reset = 0;
        expect(ex_mem_result,    0, "reset: result");
        expect(ex_mem_reg_write, 0, "reset: reg_write");
        expect(ex_mem_rd,        0, "reset: rd");

        // ---------------- 2. ALU basica ----------------
        // add x1, x2, x3   (5 + 7)
        r_type(`F3_ADD_SUB, 0, 1, 2, 3, 32'd5, 32'd7);
        expect_jump(0, 0, "add");
        clock;
        expect(ex_mem_result,    12, "add x1=5+7: result");
        expect(ex_mem_rd,         1, "add: rd");
        expect(ex_mem_reg_write,  1, "add: reg_write");
        expect(ex_mem_wb_sel, `WB_ALU, "add: wb_sel");

        // ---------------- 3. Forwarding desde EX/MEM ----------------
        // sub x4, x1, x5   x1 viene del add (EX/MEM = 12), en el banco esta viejo
        @(negedge clk);
        r_type(`F3_ADD_SUB, 1, 4, 1, 5, 32'hDEAD0000, 32'd2);
        clock;
        expect(ex_mem_result, 10, "sub x4=x1(fwd EX/MEM)-2");

        // ---------------- 4. Prioridad EX/MEM > MEM/WB ----------------
        // EX/MEM tiene x4 = 10 (sub); WB escribe x4 = 0x111 (instr. mas vieja)
        // or x6, x4, x4 -> tiene que usar 10 (el mas nuevo)
        @(negedge clk);
        r_type(`F3_OR, 0, 6, 4, 4, 32'hDEAD0000, 32'hDEAD0000);
        wb_write(4, 32'h111);
        clock;
        expect(ex_mem_result, 10, "or x6=x4|x4: prioridad EX/MEM");

        // ---------------- 5. Forwarding desde MEM/WB ----------------
        // and x7, x9, x8   x8 viene de WB (0x0000FFFF), en el banco esta viejo
        @(negedge clk);
        r_type(`F3_AND, 0, 7, 9, 8, 32'h00FF00FF, 32'hDEAD0000);
        wb_write(8, 32'h0000FFFF);
        clock;
        expect(ex_mem_result, 32'h000000FF, "and x7=x9&x8(fwd MEM/WB)");
        wb_idle;

        // ---------------- 6. Tipo I y la trampa del bit 30 ----------------
        // addi x10, x0, -256  -> imm = 0xFFFFFF00 (bit 30 = 1): NO es sub
        @(negedge clk);
        i_type(`F3_ADD_SUB, 10, 0, 32'd0, 32'hFFFFFF00);
        clock;
        expect(ex_mem_result, 32'hFFFFFF00, "addi x10=-256 (no sub)");

        // srai x11, x10, 4   (imm = 0x404, bit 30 = 1) x10 forwardeado
        @(negedge clk);
        i_type(`F3_SRL_SRA, 11, 10, 32'hDEAD0000, 32'h00000404);
        clock;
        expect(ex_mem_result, 32'hFFFFFFF0, "srai x11=x10>>>4 (fwd)");

        // srli x12, x13, 4   (imm = 4, bit 30 = 0)
        @(negedge clk);
        i_type(`F3_SRL_SRA, 12, 13, 32'hFFFFFF00, 32'h00000004);
        clock;
        expect(ex_mem_result, 32'h0FFFFFF0, "srli x12=0xFFFFFF00>>4");

        // ---------------- 7. lui ----------------
        // lui x13, 0x12345 -> 0 + 0x12345000 (ignora la basura de rs1_data)
        @(negedge clk);
        lui(13, 32'h12345000);
        clock;
        expect(ex_mem_result, 32'h12345000, "lui x13: result");

        // ---------------- 8. Store con dato forwardeado ----------------
        // sw x13, 8(x2): direccion = 0x100 + 8; dato x13 viene de EX/MEM (lui)
        @(negedge clk);
        store(`F3_SW, 2, 13, 32'h100, 32'hDEAD0000, 32'd8);
        clock;
        expect(ex_mem_result,    32'h108,      "sw: direccion 0x100+8");
        expect(ex_mem_rs2_data,  32'h12345000, "sw: dato x13 (fwd EX/MEM)");
        expect(ex_mem_mem_write, 1,            "sw: mem_write");
        expect(ex_mem_reg_write, 0,            "sw: reg_write");
        expect(ex_mem_rd,        0,            "sw: rd");

        // ---------------- 9. Load ----------------
        // lw x14, -4(x2): direccion = 0x100 - 4
        @(negedge clk);
        load(`F3_LW, 14, 2, 32'h100, 32'hFFFFFFFC);
        clock;
        expect(ex_mem_result,   32'hFC, "lw: direccion 0x100-4");
        expect(ex_mem_mem_read, 1,      "lw: mem_read");
        expect(ex_mem_funct3,   `F3_LW, "lw: funct3");
        expect(ex_mem_wb_sel,   `WB_MEM, "lw: wb_sel");

        // ---------------- 10. Branches ----------------
        // beq x3, x15, -16  en pc 0x40, 5 == 5 -> salta a 0x30
        @(negedge clk);
        branch(`F3_BEQ, 3, 15, 32'd5, 32'd5, 32'h40, 32'hFFFFFFF0);
        expect_jump(1, 32'h30, "beq 5==5");
        clock;
        expect(ex_mem_reg_write, 0, "beq: reg_write");
        expect(ex_mem_mem_write, 0, "beq: mem_write");

        // beq 5 == 6 -> no salta
        @(negedge clk);
        branch(`F3_BEQ, 3, 15, 32'd5, 32'd6, 32'h40, 32'hFFFFFFF0);
        expect_jump(0, 0, "beq 5==6");

        // bne x3, x15, +32 en pc 0x80, 5 != 6 -> salta a 0xA0
        @(negedge clk);
        branch(`F3_BNE, 3, 15, 32'd5, 32'd6, 32'h80, 32'h20);
        expect_jump(1, 32'hA0, "bne 5!=6");

        // bne 5 != 5 -> no salta
        @(negedge clk);
        branch(`F3_BNE, 3, 15, 32'd5, 32'd5, 32'h80, 32'h20);
        expect_jump(0, 0, "bne 5!=5");

        // bne x16, x17 con x16 forwardeado desde WB = 7 y x17 = 7: iguales
        // (en el banco x16 esta viejo: si no forwardea, saltaria mal)
        @(negedge clk);
        branch(`F3_BNE, 16, 17, 32'hDEAD0000, 32'd7, 32'h80, 32'h20);
        wb_write(16, 32'd7);
        expect_jump(0, 0, "bne x16(fwd)!=x17");
        clock;
        wb_idle;

        // ---------------- 11. jal ----------------
        // jal x1, +8 en pc 0x100 -> salta a 0x108, x1 = 0x104
        @(negedge clk);
        jal(1, 32'h100, 32'd8);
        expect_jump(1, 32'h108, "jal +8");
        clock;
        expect(ex_mem_result,    32'h104, "jal: result = PC+4");
        expect(ex_mem_rd,        1,       "jal: rd");
        expect(ex_mem_wb_sel,    `WB_PC4, "jal: wb_sel");

        // add x18, x1, x0 -> x1 forwardeado = PC+4 del jal (decision 1-A)
        @(negedge clk);
        r_type(`F3_ADD_SUB, 0, 18, 1, 0, 32'hDEAD0000, 32'd0);
        clock;
        expect(ex_mem_result, 32'h104, "add x18=x1 (fwd PC+4 del jal)");

        // jal hacia atras: pc 0x200, imm -0x100 -> 0x100
        @(negedge clk);
        jal(0, 32'h200, 32'hFFFFFF00);
        expect_jump(1, 32'h100, "jal -0x100");
        clock;
        expect(ex_mem_rd,        0, "jal x0 (j): rd");

        // ---------------- 12. jalr ----------------
        // jalr x5, 3(x6) en pc 0x300, x6 = 0x200 -> 0x203 & ~1 = 0x202
        @(negedge clk);
        jalr(5, 6, 32'h200, 32'h300, 32'd3);
        expect_jump(1, 32'h202, "jalr: (0x200+3)&~1");
        clock;
        expect(ex_mem_result, 32'h304, "jalr: result = PC+4");

        // jalr x0, 0(x5): x5 viene de EX/MEM (= 0x304, el jalr anterior)
        @(negedge clk);
        jalr(0, 5, 32'hDEAD0000, 32'h400, 32'd0);
        expect_jump(1, 32'h304, "jalr x5 (fwd EX/MEM)");
        clock;

        // ---------------- 13. Burbuja ----------------
        @(negedge clk);
        bubble;
        expect_jump(0, 0, "burbuja");
        clock;
        expect(ex_mem_reg_write, 0, "burbuja: reg_write");
        expect(ex_mem_mem_write, 0, "burbuja: mem_write");
        expect(ex_mem_mem_read,  0, "burbuja: mem_read");
        expect(ex_mem_rd,        0, "burbuja: rd");

        // ---------------- 14. en = 0 congela EX/MEM ----------------
        // add x20, x2, x3 (1 + 2) entra con en = 1 ...
        @(negedge clk);
        r_type(`F3_ADD_SUB, 0, 20, 2, 3, 32'd1, 32'd2);
        clock;
        expect(ex_mem_result, 3, "add x20=1+2");
        // ... y con en = 0 otra instruccion no entra
        @(negedge clk);
        en = 0;
        r_type(`F3_ADD_SUB, 0, 21, 2, 3, 32'd100, 32'd200);
        clock; clock;
        expect(ex_mem_result, 3,  "en=0: result congelado");
        expect(ex_mem_rd,     20, "en=0: rd congelado");
        @(negedge clk);
        en = 1;
        clock;
        expect(ex_mem_result, 300, "en=1 de nuevo: add x21");

        // ---------------- 15. HALT viaja ----------------
        @(negedge clk);
        bubble; id_ex_halt = 1;
        expect_jump(0, 0, "ebreak");
        clock;
        expect(ex_mem_halt, 1, "ebreak: halt pasa a EX/MEM");

        // ---------------- 16. Reset en el medio ----------------
        @(negedge clk);
        reset = 1;
        clock;
        expect(ex_mem_halt,   0, "reset: halt");
        expect(ex_mem_result, 0, "reset: result");
        reset = 0;

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
