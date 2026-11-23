// Testbench de la etapa ID completa (con el latch ID/EX).
//
// El testbench hace de "etapa IF" (pone instrucciones en if_id_*) y de
// "etapa WB" (escribe registros por wb_*), y mira lo que queda en ID/EX.
//
// Escenarios:
//   1. Reset: ID/EX en 0, halt = 0, stall = 0.
//   2. WB escribe x1 = 10, x2 = 20 y se leen por el puerto de debug.
//   3. add x3,x1,x2: lee 10 y 20, rd = 3, ALUOp = R, RegWrite.
//   4. lw x5,8(x1): imm = 8, MemRead, WBSel = MEM.
//   5. Load-use: con el lw en EX entra add x6,x5,x2 -> stall = 1 y burbuja.
//      Al ciclo siguiente (lw ya paso) el add entra normal.
//   6. sw x2,-4(x1): imm = -4, MemWrite, rd = 0 (no escribe registro).
//   7. Bypass: WB escribe x7 en el mismo ciclo que ID lo lee.
//   8. Salto tomado en EX -> burbuja.
//   9. IF/ID invalido -> burbuja.
//  10. en = 0: no cambia nada y WB no escribe.
//  11. ebreak: halt = 1 en el mismo ciclo, id_ex_halt = 1, halt queda
//      pegado aunque entren otras instrucciones. Reset lo limpia.
//  12. ebreak + salto tomado: es del camino equivocado, no hay halt.
//  13. lui x8,0x12345 y jal x1,+8: rs1/rs2 en ID/EX quedan en 0
//      (no los leen) y rd correcto.
//
// Convencion: entradas cambian en el flanco de bajada, se chequea 1 ns
// despues del flanco de subida.

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module id_stage_tb;

    reg         clk = 0, reset = 1, en = 1;
    reg  [31:0] if_id_pc = 0, if_id_pc4 = 0, if_id_instr = `INSTR_NOP;
    reg         if_id_valid = 0;
    reg         wb_reg_write = 0;
    reg  [4:0]  wb_rd = 0;
    reg  [31:0] wb_data = 0;
    reg         branch_taken = 0;
    reg  [4:0]  dbg_reg_addr = 0;

    wire        stall, halt;
    wire [31:0] dbg_reg_data;
    wire [31:0] id_ex_pc, id_ex_pc4, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    wire [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    wire [2:0]  id_ex_funct3;
    wire        id_ex_funct7b5, id_ex_alu_src_a, id_ex_alu_src_b;
    wire [1:0]  id_ex_alu_op, id_ex_wb_sel;
    wire        id_ex_branch, id_ex_jal, id_ex_jalr;
    wire        id_ex_mem_read, id_ex_mem_write, id_ex_reg_write, id_ex_halt;

    id_stage dut (
        .clk(clk), .reset(reset), .en(en),
        .if_id_pc(if_id_pc), .if_id_pc4(if_id_pc4),
        .if_id_instr(if_id_instr), .if_id_valid(if_id_valid),
        .wb_reg_write(wb_reg_write), .wb_rd(wb_rd), .wb_data(wb_data),
        .branch_taken(branch_taken),
        .stall(stall), .halt(halt),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
        .id_ex_pc(id_ex_pc), .id_ex_pc4(id_ex_pc4),
        .id_ex_rs1_data(id_ex_rs1_data), .id_ex_rs2_data(id_ex_rs2_data),
        .id_ex_imm(id_ex_imm), .id_ex_rs1(id_ex_rs1), .id_ex_rs2(id_ex_rs2),
        .id_ex_rd(id_ex_rd), .id_ex_funct3(id_ex_funct3), .id_ex_funct7b5(id_ex_funct7b5),
        .id_ex_alu_src_a(id_ex_alu_src_a), .id_ex_alu_src_b(id_ex_alu_src_b),
        .id_ex_alu_op(id_ex_alu_op), .id_ex_branch(id_ex_branch),
        .id_ex_jal(id_ex_jal), .id_ex_jalr(id_ex_jalr),
        .id_ex_mem_read(id_ex_mem_read), .id_ex_mem_write(id_ex_mem_write),
        .id_ex_reg_write(id_ex_reg_write), .id_ex_wb_sel(id_ex_wb_sel),
        .id_ex_halt(id_ex_halt)
    );

    always #5 clk = ~clk;

    integer errors = 0, checks = 0;

    // Todo el control de ID/EX en un vector para comparar de una vez:
    // SrcA SrcB ALUOp(2) Br Jal Jalr MRd MWr RegW WBSel(2) Halt  = 13 bits
    wire [12:0] ctrl = {id_ex_alu_src_a, id_ex_alu_src_b, id_ex_alu_op,
                        id_ex_branch, id_ex_jal, id_ex_jalr,
                        id_ex_mem_read, id_ex_mem_write,
                        id_ex_reg_write, id_ex_wb_sel, id_ex_halt};
    //                       A  B  ALUOp      Br J Jr MR MW RW WBSel   H
    localparam [12:0] C_NOP = {2'b00, `ALUOP_ADD, 3'b000, 2'b00, 1'b0, `WB_ALU, 1'b0};
    localparam [12:0] C_R   = {2'b00, `ALUOP_R,   3'b000, 2'b00, 1'b1, `WB_ALU, 1'b0};
    localparam [12:0] C_LD  = {2'b01, `ALUOP_ADD, 3'b000, 2'b10, 1'b1, `WB_MEM, 1'b0};
    localparam [12:0] C_ST  = {2'b01, `ALUOP_ADD, 3'b000, 2'b01, 1'b0, `WB_ALU, 1'b0};
    localparam [12:0] C_LUI = {2'b11, `ALUOP_ADD, 3'b000, 2'b00, 1'b1, `WB_ALU, 1'b0};
    localparam [12:0] C_JAL = {2'b00, `ALUOP_ADD, 3'b010, 2'b00, 1'b1, `WB_PC4, 1'b0};
    localparam [12:0] C_HLT = {2'b00, `ALUOP_ADD, 3'b000, 2'b00, 1'b0, `WB_ALU, 1'b1};

    task expect(input [31:0] got, input [31:0] exp, input [8*44-1:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %-44s got %h esperado %h", what, got, exp);
            end
        end
    endtask

    task tick; begin @(posedge clk); #1; end endtask

    // IF entrega una instruccion valida en la direccion pc
    task fetch(input [31:0] pc, input [31:0] instr);
        begin
            @(negedge clk);
            if_id_pc = pc; if_id_pc4 = pc + 4; if_id_instr = instr; if_id_valid = 1;
        end
    endtask

    // ID/EX quedo como burbuja. Fase 10: la burbuja solo pone en 0 lo que
    // tiene efecto (branch/jal/jalr, mem_read/mem_write, reg_write, halt) y
    // los numeros de registro; los datos (pc, operandos, imm, alu_op...) quedan
    // con valores viejos que no importan.
    wire [6:0] efectos = {id_ex_branch, id_ex_jal, id_ex_jalr, id_ex_mem_read,
                          id_ex_mem_write, id_ex_reg_write, id_ex_halt};
    task expect_bubble(input [8*44-1:0] what);
        begin
            expect(efectos, 0, what);
            expect(id_ex_rd, 0, what);
            expect(id_ex_rs1, 0, what);
            expect(id_ex_rs2, 0, what);
        end
    endtask

    // Instrucciones de prueba (codificacion real)
    localparam [31:0] ADD_X3_X1_X2  = 32'h002081B3;  // add  x3, x1, x2
    localparam [31:0] LW_X5_8_X1    = 32'h0080A283;  // lw   x5, 8(x1)
    localparam [31:0] ADD_X6_X5_X2  = 32'h00228333;  // add  x6, x5, x2
    localparam [31:0] SW_X2_M4_X1   = 32'hFE20AE23;  // sw   x2, -4(x1)
    localparam [31:0] ADDI_X9_X7_1  = 32'h00138493;  // addi x9, x7, 1
    localparam [31:0] LUI_X8        = 32'h12345437;  // lui  x8, 0x12345
    localparam [31:0] JAL_X1_8      = 32'h008000EF;  // jal  x1, +8

    initial begin
        // ---- 1. Reset ----
        tick; tick;
        expect_bubble("1. reset: ID/EX en 0");
        expect(halt,  0, "1. reset: halt = 0");
        expect(stall, 0, "1. reset: stall = 0");
        @(negedge clk) reset = 0;
        $display("1. reset                                (%0d errores)", errors);

        // ---- 2. WB escribe x1 = 10, x2 = 20 ----
        @(negedge clk) begin wb_reg_write = 1; wb_rd = 1; wb_data = 10; end
        @(negedge clk) begin wb_rd = 2; wb_data = 20; end
        @(negedge clk) wb_reg_write = 0;
        dbg_reg_addr = 1; #1 expect(dbg_reg_data, 10, "2. debug lee x1");
        dbg_reg_addr = 2; #1 expect(dbg_reg_data, 20, "2. debug lee x2");
        $display("2. WB escribe x1, x2 (debug los lee)    (%0d errores)", errors);

        // ---- 3. add x3, x1, x2 ----
        fetch(32'h100, ADD_X3_X1_X2);
        tick;
        expect(id_ex_pc,       32'h100, "3. add: pc");
        expect(id_ex_pc4,      32'h104, "3. add: pc+4");
        expect(id_ex_rs1_data, 10,      "3. add: rs1_data = x1");
        expect(id_ex_rs2_data, 20,      "3. add: rs2_data = x2");
        expect(id_ex_rs1, 1, "3. add: rs1"); expect(id_ex_rs2, 2, "3. add: rs2");
        expect(id_ex_rd,  3, "3. add: rd");
        expect(id_ex_funct3, `F3_ADD_SUB, "3. add: funct3");
        expect(id_ex_funct7b5, 0, "3. add: bit30");
        expect(ctrl, C_R, "3. add: control tipo R");
        $display("3. add x3,x1,x2                         (%0d errores)", errors);

        // ---- 4. lw x5, 8(x1) ----
        fetch(32'h104, LW_X5_8_X1);
        tick;
        expect(id_ex_imm, 8, "4. lw: imm");
        expect(id_ex_rs1_data, 10, "4. lw: base x1");
        expect(id_ex_rd, 5, "4. lw: rd");
        expect(id_ex_rs2, 0, "4. lw: rs2 no usado -> 0");
        expect(id_ex_funct3, `F3_LW, "4. lw: funct3");
        expect(ctrl, C_LD, "4. lw: control load");
        $display("4. lw x5,8(x1)                          (%0d errores)", errors);

        // ---- 5. Load-use: lw x5 en EX, add x6,x5,x2 en ID ----
        fetch(32'h108, ADD_X6_X5_X2);
        #1 expect(stall, 1, "5. load-use: stall = 1");
        tick;
        expect_bubble("5. load-use: burbuja en ID/EX");
        // el lw ya paso a MEM (ID/EX tiene la burbuja): el add puede seguir.
        // IF/ID no cambio (en el pipeline real IF lo retiene por el stall)
        #1 expect(stall, 0, "5. ciclo siguiente: stall = 0");
        tick;
        expect(id_ex_rd, 6, "5. add entra: rd = 6");
        expect(id_ex_rs1, 5, "5. add entra: rs1 = 5");
        expect(ctrl, C_R, "5. add entra: control R");
        $display("5. load-use: stall + burbuja            (%0d errores)", errors);

        // ---- 6. sw x2, -4(x1) ----
        fetch(32'h10C, SW_X2_M4_X1);
        tick;
        expect(id_ex_imm, 32'hFFFFFFFC, "6. sw: imm = -4");
        expect(id_ex_rs2_data, 20, "6. sw: dato = x2");
        expect(id_ex_rd, 0, "6. sw: rd = 0 (no escribe)");
        expect(ctrl, C_ST, "6. sw: control store");
        $display("6. sw x2,-4(x1)                         (%0d errores)", errors);

        // ---- 7. Bypass: WB escribe x7 mientras ID lee x7 ----
        fetch(32'h110, ADDI_X9_X7_1);
        wb_reg_write = 1; wb_rd = 7; wb_data = 32'hCAFE0007;
        tick;
        expect(id_ex_rs1_data, 32'hCAFE0007, "7. bypass: rs1_data = dato nuevo");
        @(negedge clk) wb_reg_write = 0;
        $display("7. bypass WB -> ID                      (%0d errores)", errors);

        // ---- 8. Salto tomado en EX -> burbuja ----
        fetch(32'h114, ADD_X3_X1_X2);
        branch_taken = 1;
        #1 expect(stall, 0, "8. salto: sin stall");
        tick;
        expect_bubble("8. salto tomado: burbuja");
        @(negedge clk) branch_taken = 0;
        $display("8. salto tomado -> flush                (%0d errores)", errors);

        // ---- 9. IF/ID invalido -> burbuja ----
        @(negedge clk) begin if_id_valid = 0; if_id_instr = `INSTR_NOP; end
        tick;
        expect_bubble("9. IF/ID invalido: burbuja");
        $display("9. IF/ID invalido -> burbuja            (%0d errores)", errors);

        // ---- 10. en = 0 congela ----
        fetch(32'h120, ADD_X3_X1_X2);
        tick;                                   // ID/EX = add (pc 0x120)
        @(negedge clk) begin
            en = 0;
            if_id_pc = 32'h124; if_id_instr = LW_X5_8_X1;
            wb_reg_write = 1; wb_rd = 1; wb_data = 32'hBAD;
        end
        tick; tick;
        expect(id_ex_pc, 32'h120, "10. en=0: ID/EX no cambia");
        expect(ctrl, C_R,         "10. en=0: control no cambia");
        dbg_reg_addr = 1; #1 expect(dbg_reg_data, 10, "10. en=0: WB no escribe x1");
        @(negedge clk) begin en = 1; wb_reg_write = 0; end
        $display("10. en = 0 congela todo                 (%0d errores)", errors);

        // ---- 11. ebreak ----
        fetch(32'h200, `INSTR_EBREAK);
        #1 expect(halt, 1, "11. ebreak en ID: halt = 1 ya");
        tick;
        expect(ctrl, C_HLT, "11. ebreak: id_ex_halt = 1");
        @(negedge clk) if_id_valid = 0;         // IF ya no entrega nada
        tick;
        expect(halt, 1, "11. halt queda pegado");
        expect_bubble("11. detras del ebreak: burbujas");
        fetch(32'h204, ADD_X3_X1_X2);           // aunque llegara algo
        #1 expect(halt, 1, "11. halt sigue con otra instr");
        @(negedge clk) reset = 1;
        tick;
        @(negedge clk) begin reset = 0; if_id_valid = 0; end
        #1 expect(halt, 0, "11. reset limpia halt");
        $display("11. ebreak -> halt                      (%0d errores)", errors);

        // ---- 12. ebreak del camino equivocado ----
        fetch(32'h300, `INSTR_EBREAK);
        branch_taken = 1;
        #1 expect(halt, 0, "12. ebreak + salto: halt = 0");
        tick;
        expect_bubble("12. ebreak descartado");
        @(negedge clk) begin branch_taken = 0; if_id_valid = 0; end
        #1 expect(halt, 0, "12. halt no quedo pegado");
        $display("12. ebreak + salto -> sin halt          (%0d errores)", errors);

        // ---- 13. lui y jal: no leen registros ----
        fetch(32'h400, LUI_X8);
        tick;
        expect(id_ex_imm, 32'h12345000, "13. lui: imm");
        expect(id_ex_rs1, 0, "13. lui: rs1 = 0"); expect(id_ex_rs2, 0, "13. lui: rs2 = 0");
        expect(id_ex_rd, 8, "13. lui: rd = 8");
        expect(ctrl, C_LUI, "13. lui: control");
        fetch(32'h404, JAL_X1_8);
        tick;
        expect(id_ex_imm, 8, "13. jal: imm = 8");
        expect(id_ex_rs1, 0, "13. jal: rs1 = 0"); expect(id_ex_rs2, 0, "13. jal: rs2 = 0");
        expect(id_ex_rd, 1, "13. jal: rd = 1");
        expect(id_ex_pc4, 32'h408, "13. jal: pc+4 (direccion de retorno)");
        expect(ctrl, C_JAL, "13. jal: control");
        $display("13. lui / jal                           (%0d errores)", errors);

        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
