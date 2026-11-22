// Constantes del subconjunto RV32I que implementa el TP Final.
// Todos los modulos del procesador hacen `include "riscv_defs.vh" y usan
// estos nombres en vez de numeros sueltos: `OP_LOAD se lee mejor que 7'b0000011
// y si hay un error se corrige en un solo lugar.
//
// Fuente: RISC-V Unprivileged ISA, cap. "RV32I Base Integer Instruction Set".

`ifndef RISCV_DEFS_VH
`define RISCV_DEFS_VH

// ---------------------------------------------------------------------------
// Opcodes: bits [6:0] de la instruccion. Definen el formato (R, I, S, B, U, J)
// y la familia de instruccion.
// ---------------------------------------------------------------------------
`define OP_R       7'b0110011   // R: add sub sll srl sra and or xor slt sltu
`define OP_IMM     7'b0010011   // I: addi andi ori xori slti sltiu slli srli srai
`define OP_LOAD    7'b0000011   // I: lb lh lw lbu lhu
`define OP_STORE   7'b0100011   // S: sb sh sw
`define OP_BRANCH  7'b1100011   // B: beq bne
`define OP_JAL     7'b1101111   // J: jal
`define OP_JALR    7'b1100111   // I: jalr
`define OP_LUI     7'b0110111   // U: lui
`define OP_SYSTEM  7'b1110011   // I: ebreak (lo usamos como HALT)

// ---------------------------------------------------------------------------
// funct3: bits [14:12]. Dentro de un mismo opcode elige la operacion.
// ---------------------------------------------------------------------------
// OP_R / OP_IMM
`define F3_ADD_SUB 3'b000       // add/sub (R, se distinguen por funct7[5]) y addi
`define F3_SLL     3'b001
`define F3_SLT     3'b010
`define F3_SLTU    3'b011
`define F3_XOR     3'b100
`define F3_SRL_SRA 3'b101       // srl/sra y srli/srai (se distinguen por funct7[5])
`define F3_OR      3'b110
`define F3_AND     3'b111

// OP_LOAD
`define F3_LB      3'b000
`define F3_LH      3'b001
`define F3_LW      3'b010
`define F3_LBU     3'b100
`define F3_LHU     3'b101

// OP_STORE
`define F3_SB      3'b000
`define F3_SH      3'b001
`define F3_SW      3'b010

// OP_BRANCH
`define F3_BEQ     3'b000
`define F3_BNE     3'b001

// ---------------------------------------------------------------------------
// Instrucciones completas que el hardware necesita reconocer
// ---------------------------------------------------------------------------
`define INSTR_NOP    32'h00000013  // addi x0, x0, 0: no escribe nada (x0 es siempre 0)
`define INSTR_EBREAK 32'h00100073  // HALT del TP

// ---------------------------------------------------------------------------
// Codificacion de las senales de control (ver docs/tabla_control.html)
// ---------------------------------------------------------------------------
// ImmSel: que formato de inmediato arma el Imm Gen (3 bits)
`define IMM_I      3'd0         // addi..., loads, jalr: instr[31:20]
`define IMM_S      3'd1         // stores: instr[31:25] | instr[11:7]
`define IMM_B      3'd2         // branches: offset de 13 bits, bit 0 = 0
`define IMM_U      3'd3         // lui: instr[31:12] << 12
`define IMM_J      3'd4         // jal: offset de 21 bits, bit 0 = 0

// ALUOp: primer nivel del control de la ALU (2 bits)
`define ALUOP_ADD  2'b00        // loads, stores, jalr, lui: siempre suma
`define ALUOP_SUB  2'b01        // branches: resta para comparar
`define ALUOP_R    2'b10        // tipo R: decide funct3 + bit 30
`define ALUOP_I    2'b11        // tipo I aritmetico: funct3 (bit 30 solo en shifts)

// WBSel: que valor se escribe en rd (2 bits)
`define WB_ALU     2'b00        // resultado de la ALU
`define WB_MEM     2'b01        // dato leido de memoria
`define WB_PC4     2'b10        // PC + 4 (direccion de retorno de jal/jalr)

// ---------------------------------------------------------------------------
// Operacion de la ALU (4 bits) = {bit30, funct3}: es la misma codificacion
// que usa RISC-V en las instrucciones tipo R, asi el control de la ALU
// casi no tiene que traducir nada (ver alu_control.v).
// ---------------------------------------------------------------------------
`define ALU_ADD    4'b0000
`define ALU_SUB    4'b1000
`define ALU_SLL    4'b0001
`define ALU_SLT    4'b0010
`define ALU_SLTU   4'b0011
`define ALU_XOR    4'b0100
`define ALU_SRL    4'b0101
`define ALU_SRA    4'b1101
`define ALU_OR     4'b0110
`define ALU_AND    4'b0111

// ---------------------------------------------------------------------------
// Forwarding: de donde sale cada operando de la ALU (mismos codigos que las
// diapositivas de la catedra, ForwardA / ForwardB)
// ---------------------------------------------------------------------------
`define FWD_REG    2'b00        // valor leido del banco de registros (ID/EX)
`define FWD_MEM_WB 2'b01        // valor que se esta escribiendo en WB
`define FWD_EX_MEM 2'b10        // resultado de la instruccion de adelante (EX/MEM)

`endif
