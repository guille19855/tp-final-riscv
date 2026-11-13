// Testbench de la unidad de control.
//
// Le pasa las 32 instrucciones del enunciado + ebreak, codificadas de verdad
// (con registros e inmediatos), y compara TODAS las salidas contra la fila
// esperada de la tabla de control (docs/tabla_control.html).
// Tambien prueba opcodes invalidos: tienen que dar NOP.
//
// Como la unidad es combinacional no hace falta clock: se cambia la entrada,
// se espera 1 ns y se mira la salida.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module control_unit_tb;

    reg  [31:0] instr;
    wire [2:0]  imm_sel;
    wire        usa_rs1, usa_rs2, halt;
    wire        alu_src_a, alu_src_b, branch, jal, jalr;
    wire [1:0]  alu_op, wb_sel;
    wire        mem_read, mem_write, reg_write;

    control_unit dut (
        .opcode(instr[6:0]),
        .imm_sel(imm_sel), .usa_rs1(usa_rs1), .usa_rs2(usa_rs2), .halt(halt),
        .alu_src_a(alu_src_a), .alu_src_b(alu_src_b), .alu_op(alu_op),
        .branch(branch), .jal(jal), .jalr(jalr),
        .mem_read(mem_read), .mem_write(mem_write),
        .reg_write(reg_write), .wb_sel(wb_sel)
    );

    // Todas las salidas juntas en un vector de 18 bits, en el mismo orden que
    // las columnas de la tabla:
    //   ImmSel UsaRs1 UsaRs2 Halt | SrcA SrcB ALUOp Br Jal Jalr | MRd MWr | RegW WBSel
    wire [17:0] got = {imm_sel, usa_rs1, usa_rs2, halt,
                       alu_src_a, alu_src_b, alu_op, branch, jal, jalr,
                       mem_read, mem_write,
                       reg_write, wb_sel};

    // Filas esperadas de la tabla (una por familia)
    //                         ImmSel   rs1 rs2 H   A    B    ALUOp       Br   J    Jr   MR   MW   RW   WBSel
    localparam [17:0] ROW_R   = {`IMM_I, 3'b110, 1'b0,1'b0,`ALUOP_R,  3'b000, 2'b00, 1'b1,`WB_ALU};
    localparam [17:0] ROW_IMM = {`IMM_I, 3'b100, 1'b0,1'b1,`ALUOP_I,  3'b000, 2'b00, 1'b1,`WB_ALU};
    localparam [17:0] ROW_LD  = {`IMM_I, 3'b100, 1'b0,1'b1,`ALUOP_ADD,3'b000, 2'b10, 1'b1,`WB_MEM};
    localparam [17:0] ROW_ST  = {`IMM_S, 3'b110, 1'b0,1'b1,`ALUOP_ADD,3'b000, 2'b01, 1'b0,`WB_ALU};
    localparam [17:0] ROW_BR  = {`IMM_B, 3'b110, 1'b0,1'b0,`ALUOP_SUB,3'b100, 2'b00, 1'b0,`WB_ALU};
    localparam [17:0] ROW_JAL = {`IMM_J, 3'b000, 1'b0,1'b0,`ALUOP_ADD,3'b010, 2'b00, 1'b1,`WB_PC4};
    localparam [17:0] ROW_JR  = {`IMM_I, 3'b100, 1'b0,1'b1,`ALUOP_ADD,3'b001, 2'b00, 1'b1,`WB_PC4};
    localparam [17:0] ROW_LUI = {`IMM_U, 3'b000, 1'b1,1'b1,`ALUOP_ADD,3'b000, 2'b00, 1'b1,`WB_ALU};
    localparam [17:0] ROW_HLT = {`IMM_I, 3'b001, 1'b0,1'b0,`ALUOP_ADD,3'b000, 2'b00, 1'b0,`WB_ALU};
    localparam [17:0] ROW_NOP = {`IMM_I, 3'b000, 1'b0,1'b0,`ALUOP_ADD,3'b000, 2'b00, 1'b0,`WB_ALU};

    // --- Armado de instrucciones reales, campo por campo ---
    function [31:0] R(input [6:0] f7, input [4:0] rs2, rs1, input [2:0] f3, input [4:0] rd);
        R = {f7, rs2, rs1, f3, rd, `OP_R};
    endfunction
    function [31:0] I(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
        I = {imm, rs1, f3, rd, op};
    endfunction
    function [31:0] S(input [11:0] imm, input [4:0] rs2, rs1, input [2:0] f3);
        S = {imm[11:5], rs2, rs1, f3, imm[4:0], `OP_STORE};
    endfunction
    function [31:0] B(input [12:0] imm, input [4:0] rs2, rs1, input [2:0] f3);
        B = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], `OP_BRANCH};
    endfunction

    integer errors = 0, checks = 0;

    task check(input [31:0] word, input [17:0] exp, input [8*8-1:0] name);
        begin
            instr = word;
            #1;
            checks = checks + 1;
            if (got === exp)
                $display("OK   %-6s %h  -> %b", name, word, got);
            else begin
                errors = errors + 1;
                $display("FAIL %-6s %h  -> %b  (esperado %b)", name, word, got, exp);
            end
        end
    endtask

    initial begin
        $display("ImmSel rs1 rs2 H | A B ALUOp Br J Jr | MR MW | RW WB");

        // Tipo R (10)
        check(R(7'b0000000, 5'd2, 5'd1, `F3_ADD_SUB, 5'd3), ROW_R, "add");
        check(R(7'b0100000, 5'd2, 5'd1, `F3_ADD_SUB, 5'd3), ROW_R, "sub");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_SLL,     5'd3), ROW_R, "sll");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_SRL_SRA, 5'd3), ROW_R, "srl");
        check(R(7'b0100000, 5'd2, 5'd1, `F3_SRL_SRA, 5'd3), ROW_R, "sra");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_AND,     5'd3), ROW_R, "and");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_OR,      5'd3), ROW_R, "or");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_XOR,     5'd3), ROW_R, "xor");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_SLT,     5'd3), ROW_R, "slt");
        check(R(7'b0000000, 5'd2, 5'd1, `F3_SLTU,    5'd3), ROW_R, "sltu");

        // Tipo I aritmeticas (9). addi con -1: bit 30 = 1, igual es ROW_IMM
        check(I(12'hFFF,  5'd2, `F3_ADD_SUB, 5'd1, `OP_IMM), ROW_IMM, "addi");
        check(I(12'h0F0,  5'd2, `F3_AND,     5'd1, `OP_IMM), ROW_IMM, "andi");
        check(I(12'h0F0,  5'd2, `F3_OR,      5'd1, `OP_IMM), ROW_IMM, "ori");
        check(I(12'h0F0,  5'd2, `F3_XOR,     5'd1, `OP_IMM), ROW_IMM, "xori");
        check(I(12'd5,    5'd2, `F3_SLT,     5'd1, `OP_IMM), ROW_IMM, "slti");
        check(I(12'd5,    5'd2, `F3_SLTU,    5'd1, `OP_IMM), ROW_IMM, "sltiu");
        check(I(12'h003,  5'd2, `F3_SLL,     5'd1, `OP_IMM), ROW_IMM, "slli");
        check(I(12'h003,  5'd2, `F3_SRL_SRA, 5'd1, `OP_IMM), ROW_IMM, "srli");
        check(I(12'h403,  5'd2, `F3_SRL_SRA, 5'd1, `OP_IMM), ROW_IMM, "srai");

        // Loads (5): lw x9, 120(x10) es el ejemplo de la teoria
        check(I(12'd120, 5'd10, `F3_LB,  5'd9, `OP_LOAD), ROW_LD, "lb");
        check(I(12'd120, 5'd10, `F3_LH,  5'd9, `OP_LOAD), ROW_LD, "lh");
        check(I(12'd120, 5'd10, `F3_LW,  5'd9, `OP_LOAD), ROW_LD, "lw");
        check(I(12'd120, 5'd10, `F3_LBU, 5'd9, `OP_LOAD), ROW_LD, "lbu");
        check(I(12'd120, 5'd10, `F3_LHU, 5'd9, `OP_LOAD), ROW_LD, "lhu");

        // Stores (3)
        check(S(12'd8, 5'd5, 5'd6, `F3_SB), ROW_ST, "sb");
        check(S(12'd8, 5'd5, 5'd6, `F3_SH), ROW_ST, "sh");
        check(S(12'd8, 5'd5, 5'd6, `F3_SW), ROW_ST, "sw");

        // Branches (2)
        check(B(13'd16, 5'd2, 5'd1, `F3_BEQ), ROW_BR, "beq");
        check(B(13'd16, 5'd2, 5'd1, `F3_BNE), ROW_BR, "bne");

        // Saltos, lui y halt
        check(32'h008000EF,                          ROW_JAL, "jal");   // jal x1, 8
        check(I(12'd0, 5'd1, 3'b000, 5'd0, `OP_JALR), ROW_JR,  "jalr");  // jalr x0, 0(x1)
        check(32'h123450B7,                          ROW_LUI, "lui");   // lui x1, 0x12345
        check(`INSTR_EBREAK,                         ROW_HLT, "ebreak");

        // La NOP de verdad (addi x0,x0,0) es un addi: RegWrite = 1 pero rd = x0
        check(`INSTR_NOP,                            ROW_IMM, "nop");

        // Opcodes que no existen en el TP: todo en 0
        check(32'h00000000,                          ROW_NOP, "cero");
        check(32'hFFFFFFFF,                          ROW_NOP, "unos");
        check(32'h00000017,                          ROW_NOP, "auipc"); // RV32I, pero no esta en el TP

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
