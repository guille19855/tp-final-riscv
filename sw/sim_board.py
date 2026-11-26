"""Placa simulada: el procesador y la Debug Unit en Python, ciclo a ciclo.

Sirve para usar la interfaz sin la placa (practicar, mostrar en la defensa si
la placa falla, probar programas en casa):

    python sw/debug_gui.py                         -> elegir el puerto "SIM"
    python sw/debug_cli.py -p SIM cargar programs/jumps.hex
    python sw/debug_cli.py -p SIM verificar "programs/*.s"

NO es el ISS. El ISS (iss.py) ejecuta una instruccion por vez, sin pipeline.
Esto copia el HARDWARE: los mismos registros que el Verilog (PC, latches
IF/ID, ID/EX, EX/MEM, MEM/WB, flag halted, salidas de las BRAM) y, en cada
ciclo, la misma logica combinacional (forwarding, load-use, flush, HALT).
Por eso da los mismos ciclos y los mismos latches que la placa. Cada bloque
dice de que archivo de rtl/ sale.

SimBoard tiene los mismos metodos que du_protocol.DebugUnit (load, reset,
step, dump, run, run_until, read_program, close) y devuelve el mismo Dump:
la GUI y la CLI no notan la diferencia.

Lo verifica sw/test_sim_board.py: los 28 programas tienen que dar los mismos
ciclos, registros, memoria y ORDEN de escrituras que el ISS (igual que
cpu_top_tb.v con el hardware).
"""

import os
import time

from du_protocol import Dump, DebugUnitError

MASK = 0xFFFFFFFF
WORDS = 1024                       # instr_mem y data_mem: 1024 x 32
NOP = 0x00000013                   # addi x0, x0, 0
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Opcodes (riscv_defs.vh)
OP_R, OP_IMM, OP_LOAD, OP_STORE = 0b0110011, 0b0010011, 0b0000011, 0b0100011
OP_BRANCH, OP_JAL, OP_JALR, OP_LUI = 0b1100011, 0b1101111, 0b1100111, 0b0110111
OP_SYSTEM = 0b1110011

IMM_I, IMM_S, IMM_B, IMM_U, IMM_J = range(5)
ALUOP_ADD, ALUOP_SUB, ALUOP_R, ALUOP_I = range(4)
WB_ALU, WB_MEM, WB_PC4 = range(3)


def _sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def read_coe(path):
    """Lee un .coe (radix 16) y lo completa con ceros hasta 1024 palabras."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    vec = text.split("memory_initialization_vector")[1].split("=", 1)[1]
    words = [int(t, 16) for t in vec.replace(";", "").replace(",", " ").split()]
    return (words + [0] * WORDS)[:WORDS]


# ---------------------------------------------------------------------------
# control_unit.v: solo mira el opcode. Valores por defecto = NOP.
#   (imm_sel, usa_rs1, usa_rs2, halt, alu_src_a, alu_src_b, alu_op,
#    branch, jal, jalr, mem_read, mem_write, reg_write, wb_sel)
# ---------------------------------------------------------------------------
_DEFAULT = (IMM_I, 0, 0, 0, 0, 0, ALUOP_ADD, 0, 0, 0, 0, 0, 0, WB_ALU)
_CONTROL = {
    OP_R:      (IMM_I, 1, 1, 0, 0, 0, ALUOP_R,   0, 0, 0, 0, 0, 1, WB_ALU),
    OP_IMM:    (IMM_I, 1, 0, 0, 0, 1, ALUOP_I,   0, 0, 0, 0, 0, 1, WB_ALU),
    OP_LOAD:   (IMM_I, 1, 0, 0, 0, 1, ALUOP_ADD, 0, 0, 0, 1, 0, 1, WB_MEM),
    OP_STORE:  (IMM_S, 1, 1, 0, 0, 1, ALUOP_ADD, 0, 0, 0, 0, 1, 0, WB_ALU),
    OP_BRANCH: (IMM_B, 1, 1, 0, 0, 0, ALUOP_SUB, 1, 0, 0, 0, 0, 0, WB_ALU),
    OP_JAL:    (IMM_J, 0, 0, 0, 0, 0, ALUOP_ADD, 0, 1, 0, 0, 0, 1, WB_PC4),
    OP_JALR:   (IMM_I, 1, 0, 0, 0, 1, ALUOP_ADD, 0, 0, 1, 0, 0, 1, WB_PC4),
    OP_LUI:    (IMM_U, 0, 0, 0, 1, 1, ALUOP_ADD, 0, 0, 0, 0, 0, 1, WB_ALU),
    OP_SYSTEM: (IMM_I, 0, 0, 1, 0, 0, ALUOP_ADD, 0, 0, 0, 0, 0, 0, WB_ALU),
}


def imm_gen(w, sel):
    """imm_gen.v: el signo siempre es instr[31]."""
    if sel == IMM_I:
        v = _sext(w >> 20, 12)
    elif sel == IMM_S:
        v = _sext(((w >> 25) << 5) | ((w >> 7) & 0x1F), 12)
    elif sel == IMM_B:
        v = _sext((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) |
                  (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1), 13)
    elif sel == IMM_U:
        v = w & 0xFFFFF000
    elif sel == IMM_J:
        v = _sext((((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12) |
                  (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1), 21)
    else:
        v = 0
    return v & MASK


def alu_control(alu_op, funct3, funct7b5):
    """alu_control.v: codigo de 4 bits = {bit30, funct3}."""
    if alu_op == ALUOP_ADD:
        return 0b0000
    if alu_op == ALUOP_SUB:
        return 0b1000
    if alu_op == ALUOP_R:
        return (funct7b5 << 3) | funct3
    return ((funct3 == 0b101 and funct7b5) << 3) | funct3      # ALUOP_I


def alu(op, a, b):
    """alu.v (un codigo invalido da 0, como el default del case)."""
    sh = b & 0x1F
    if op == 0b0000:
        return (a + b) & MASK
    if op == 0b1000:
        return (a - b) & MASK
    if op == 0b0001:
        return (a << sh) & MASK
    if op == 0b0010:
        return int(_sext(a, 32) < _sext(b, 32))
    if op == 0b0011:
        return int(a < b)
    if op == 0b0100:
        return a ^ b
    if op == 0b0101:
        return a >> sh
    if op == 0b1101:
        return (_sext(a, 32) >> sh) & MASK
    if op == 0b0110:
        return a | b
    if op == 0b0111:
        return a & b
    return 0


# ---------------------------------------------------------------------------
# El procesador: cpu_top.v
# ---------------------------------------------------------------------------
class Cpu:
    """Un atributo por cada registro del hardware. tick() es un flanco de
    subida con en = 1: primero calcula toda la logica combinacional con los
    valores ACTUALES y despues actualiza todos los registros juntos (como los
    '<=' de Verilog)."""

    def __init__(self, imem, dmem):
        self.imem = imem                  # contenido de las BRAM (no tienen reset)
        self.dmem = dmem
        self.used = [False] * WORDS       # dmem_used.v (LUTRAM, sin reset)
        self.imem_dout = 0                # registro de salida de instr_mem = IF/ID.instr
        self.dmem_dout = 0                # registro de salida de data_mem = MEM/WB.read_data
        self.reg_trace = []               # (rd, valor) en el orden en que se escriben
        self.store_trace = []             # (funct3, direccion, dato) en el orden de MEM
        self.reset()

    def reset(self):
        """Reset sincronico: todos los FF a 0 (las BRAM y el bitmap no)."""
        # if_stage.v
        self.pc = 0
        self.if_id_pc = self.if_id_pc4 = 0
        self.if_id_valid = 0
        # id_stage.v / reg_file.v
        self.regs = [0] * 32
        self.halted = 0
        self.id_ex_pc = self.id_ex_pc4 = 0
        self.id_ex_rs1_data = self.id_ex_rs2_data = self.id_ex_imm = 0
        self.id_ex_rs1 = self.id_ex_rs2 = self.id_ex_rd = 0
        self.id_ex_funct3 = self.id_ex_funct7b5 = 0
        self.id_ex_alu_src_a = self.id_ex_alu_src_b = 0
        self.id_ex_alu_op = ALUOP_ADD
        self.id_ex_branch = self.id_ex_jal = self.id_ex_jalr = 0
        self.id_ex_mem_read = self.id_ex_mem_write = self.id_ex_reg_write = 0
        self.id_ex_wb_sel = WB_ALU
        self.id_ex_halt = 0
        # ex_stage.v
        self.ex_mem_result = self.ex_mem_rs2_data = 0
        self.ex_mem_rd = self.ex_mem_funct3 = 0
        self.ex_mem_mem_read = self.ex_mem_mem_write = self.ex_mem_reg_write = 0
        self.ex_mem_wb_sel = WB_ALU
        self.ex_mem_halt = 0
        # mem_stage.v
        self.mem_wb_result = 0
        self.mem_wb_rd = self.mem_wb_funct3 = self.mem_wb_addr_lo = 0
        self.mem_wb_mem_read = self.mem_wb_reg_write = 0
        self.mem_wb_wb_sel = WB_ALU
        self.mem_wb_halt = 0

    # --- salidas combinacionales que se ven desde afuera --------------------
    @property
    def program_done(self):               # wb_stage.v
        return self.mem_wb_halt

    @property
    def if_id_instr(self):                # if_stage.v: NOP si IF/ID no es valido
        return self.imem_dout if self.if_id_valid else NOP

    @property
    def mem_wb_read_data(self):           # mem_stage.v, decision 3-A
        return self.dmem_dout if self.mem_wb_mem_read else 0

    def _wb(self):
        """mem_stage.v (extraccion del load) + wb_stage.v -> (we, rd, dato)."""
        rdata = self.mem_wb_read_data
        lo, f3 = self.mem_wb_addr_lo, self.mem_wb_funct3
        byte = (rdata >> (8 * lo)) & 0xFF
        half = (rdata >> 16) if lo & 2 else rdata & 0xFFFF
        if f3 == 0b000:
            load = _sext(byte, 8) & MASK          # lb
        elif f3 == 0b001:
            load = _sext(half, 16) & MASK         # lh
        elif f3 == 0b100:
            load = byte                           # lbu
        elif f3 == 0b101:
            load = half                           # lhu
        else:
            load = rdata                          # lw
        data = load if self.mem_wb_wb_sel == WB_MEM else self.mem_wb_result
        return self.mem_wb_reg_write, self.mem_wb_rd, data

    # --- un ciclo ------------------------------------------------------------
    def tick(self):
        # ============ logica combinacional (con los valores actuales) ========
        # ---- WB
        wb_we, wb_rd, wb_data = self._wb()

        # ---- EX: forwarding_unit.v (EX/MEM tiene prioridad sobre MEM/WB)
        ex_mem_ok = self.ex_mem_reg_write and self.ex_mem_rd != 0
        mem_wb_ok = wb_we and wb_rd != 0

        def fwd(rs, reg_value):
            if ex_mem_ok and self.ex_mem_rd == rs:
                return self.ex_mem_result         # 10
            if mem_wb_ok and wb_rd == rs:
                return wb_data                    # 01
            return reg_value                      # 00

        a_fwd = fwd(self.id_ex_rs1, self.id_ex_rs1_data)
        b_fwd = fwd(self.id_ex_rs2, self.id_ex_rs2_data)

        # ---- EX: ALU, saltos y resultado (ex_stage.v)
        alu_a = 0 if self.id_ex_alu_src_a else a_fwd
        alu_b = self.id_ex_imm if self.id_ex_alu_src_b else b_fwd
        alu_result = alu(alu_control(self.id_ex_alu_op, self.id_ex_funct3,
                                     self.id_ex_funct7b5), alu_a, alu_b)
        operands_eq = a_fwd == b_fwd                       # comparador propio
        branch_cond = (not operands_eq) if self.id_ex_funct3 == 0b001 else operands_eq
        branch_taken = bool((self.id_ex_branch and branch_cond)
                            or self.id_ex_jal or self.id_ex_jalr)
        pc_imm = (self.id_ex_pc + self.id_ex_imm) & MASK
        branch_target = (alu_result & ~1) & MASK if self.id_ex_jalr else pc_imm
        ex_result = self.id_ex_pc4 if (self.id_ex_jal or self.id_ex_jalr) else alu_result

        # ---- ID: decodificacion (id_stage.v)
        valid = self.if_id_valid
        instr = self.if_id_instr
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        (imm_sel, usa_rs1, usa_rs2, c_halt, c_src_a, c_src_b, c_alu_op, c_branch,
         c_jal, c_jalr, c_mem_read, c_mem_write, c_reg_write, c_wb_sel) = \
            _CONTROL.get(opcode, _DEFAULT)
        imm = imm_gen(instr, imm_sel)

        # reg_file.v: lectura con bypass (WB escribe el registro que ID lee)
        def read_reg(r):
            if r == 0:
                return 0
            if wb_we and wb_rd == r:
                return wb_data
            return self.regs[r]

        rs1_data, rs2_data = read_reg(rs1), read_reg(rs2)

        # hazard_unit.v: load-use y flush
        load_use = bool(self.id_ex_mem_read and self.id_ex_rd != 0 and
                        ((usa_rs1 and valid and self.id_ex_rd == rs1) or
                         (usa_rs2 and valid and self.id_ex_rd == rs2)))
        stall = load_use and not branch_taken
        flush_id_ex = load_use or branch_taken

        # HALT: ebreak valido en ID y no del camino equivocado
        halt_en_id = bool(valid and c_halt and not branch_taken)
        halt = bool(self.halted) or halt_en_id
        bubble = flush_id_ex or not valid

        # ============ flanco: se actualizan todos los registros ==============
        # ---- banco de registros (puerto de escritura de WB)
        if wb_we and wb_rd != 0:
            self.regs[wb_rd] = wb_data
            self.reg_trace.append((wb_rd, wb_data))

        # ---- MEM: data_mem puerto A (store por byte, WRITE_FIRST) + bitmap
        idx = (self.ex_mem_result >> 2) & (WORDS - 1)
        if self.ex_mem_mem_write:
            off = self.ex_mem_result & 3
            f3 = self.ex_mem_funct3 & 3
            if f3 == 0b00:                                 # sb
                be, data = 1 << off, (self.ex_mem_rs2_data & 0xFF) * 0x01010101
            elif f3 == 0b01:                               # sh
                be, data = (0b1100 if off & 2 else 0b0011), \
                    (self.ex_mem_rs2_data & 0xFFFF) * 0x00010001
            else:                                          # sw
                be, data = 0b1111, self.ex_mem_rs2_data
            mask = sum(0xFF << (8 * i) for i in range(4) if be >> i & 1)
            self.dmem[idx] = (self.dmem[idx] & ~mask | data & mask) & MASK
            self.used[idx] = True
            self.store_trace.append((self.ex_mem_funct3, self.ex_mem_result,
                                     self.ex_mem_rs2_data))
        self.dmem_dout = self.dmem[idx]

        # ---- latch MEM/WB
        self.mem_wb_result = self.ex_mem_result
        self.mem_wb_rd = self.ex_mem_rd
        self.mem_wb_funct3 = self.ex_mem_funct3
        self.mem_wb_addr_lo = self.ex_mem_result & 3
        self.mem_wb_mem_read = self.ex_mem_mem_read
        self.mem_wb_reg_write = self.ex_mem_reg_write
        self.mem_wb_wb_sel = self.ex_mem_wb_sel
        self.mem_wb_halt = self.ex_mem_halt

        # ---- latch EX/MEM
        self.ex_mem_result = ex_result
        self.ex_mem_rs2_data = b_fwd                       # forwardeado
        self.ex_mem_rd = self.id_ex_rd
        self.ex_mem_funct3 = self.id_ex_funct3
        self.ex_mem_mem_read = self.id_ex_mem_read
        self.ex_mem_mem_write = self.id_ex_mem_write
        self.ex_mem_reg_write = self.id_ex_reg_write
        self.ex_mem_wb_sel = self.id_ex_wb_sel
        self.ex_mem_halt = self.id_ex_halt

        # ---- latch ID/EX (Fase 10: la burbuja solo limpia lo que tiene efecto)
        if bubble:
            self.id_ex_rs1 = self.id_ex_rs2 = self.id_ex_rd = 0
            self.id_ex_branch = self.id_ex_jal = self.id_ex_jalr = 0
            self.id_ex_mem_read = self.id_ex_mem_write = self.id_ex_reg_write = 0
            self.id_ex_halt = 0
        else:
            self.id_ex_rs1 = rs1 if usa_rs1 else 0
            self.id_ex_rs2 = rs2 if usa_rs2 else 0
            self.id_ex_rd = rd if c_reg_write else 0
            self.id_ex_branch, self.id_ex_jal, self.id_ex_jalr = c_branch, c_jal, c_jalr
            self.id_ex_mem_read, self.id_ex_mem_write = c_mem_read, c_mem_write
            self.id_ex_reg_write, self.id_ex_halt = c_reg_write, c_halt
        self.id_ex_pc, self.id_ex_pc4 = self.if_id_pc, self.if_id_pc4
        self.id_ex_rs1_data, self.id_ex_rs2_data = rs1_data, rs2_data
        self.id_ex_imm = imm
        self.id_ex_funct3 = funct3
        self.id_ex_funct7b5 = (instr >> 30) & 1
        self.id_ex_alu_src_a, self.id_ex_alu_src_b = c_src_a, c_src_b
        self.id_ex_alu_op, self.id_ex_wb_sel = c_alu_op, c_wb_sel

        if halt_en_id:
            self.halted = 1

        # ---- IF (if_stage.v): misma prioridad que el Verilog
        pc = self.pc
        if branch_taken or not stall:                      # bram_en
            self.imem_dout = self.imem[(pc >> 2) & (WORDS - 1)]
        if branch_taken:
            self.pc = branch_target
            self.if_id_valid = 0                           # flush
        elif stall:
            pass                                           # todo congelado
        elif halt:
            self.if_id_valid = 0                           # PC quieto, entran NOPs
        else:
            self.pc = (pc + 4) & MASK
            self.if_id_pc = pc
            self.if_id_pc4 = (pc + 4) & MASK
            self.if_id_valid = 1

    # --- puertos de debug ---------------------------------------------------
    def latch_words(self):
        """Las 16 palabras del mux de latches (tabla de cpu_top.v)."""
        c_idex = (self.id_ex_rs1 << 27 | self.id_ex_rs2 << 22 | self.id_ex_rd << 17 |
                  self.id_ex_funct3 << 14 | self.id_ex_funct7b5 << 13 |
                  self.id_ex_alu_src_a << 12 | self.id_ex_alu_src_b << 11 |
                  self.id_ex_alu_op << 9 | self.id_ex_branch << 8 | self.id_ex_jal << 7 |
                  self.id_ex_jalr << 6 | self.id_ex_mem_read << 5 |
                  self.id_ex_mem_write << 4 | self.id_ex_reg_write << 3 |
                  self.id_ex_wb_sel << 1 | self.id_ex_halt)
        c_exmem = (self.ex_mem_rd << 9 | self.ex_mem_funct3 << 6 |
                   self.ex_mem_mem_read << 5 | self.ex_mem_mem_write << 4 |
                   self.ex_mem_reg_write << 3 | self.ex_mem_wb_sel << 1 | self.ex_mem_halt)
        c_memwb = (self.mem_wb_rd << 10 | self.mem_wb_funct3 << 7 |
                   self.mem_wb_addr_lo << 5 | self.mem_wb_mem_read << 4 |
                   self.mem_wb_reg_write << 3 | self.mem_wb_wb_sel << 1 | self.mem_wb_halt)
        return [self.if_id_pc, self.if_id_pc4, self.if_id_instr, self.if_id_valid,
                self.id_ex_pc, self.id_ex_pc4, self.id_ex_rs1_data, self.id_ex_rs2_data,
                self.id_ex_imm, c_idex,
                self.ex_mem_result, self.ex_mem_rs2_data, c_exmem,
                self.mem_wb_result, self.mem_wb_read_data, c_memwb]


# ---------------------------------------------------------------------------
# La Debug Unit: debug_unit.v, con la interfaz de du_protocol.DebugUnit
# ---------------------------------------------------------------------------
class SimBoard:
    """Arranca como la placa recien programada (Program Device + reset):
    instr_mem y data_mem con el contenido de los .coe, bitmap en 0, CPU en
    reset y ningun programa cargado."""

    name = "SIM"

    def __init__(self):
        try:
            imem = read_coe(os.path.join(ROOT_DIR, "coe", "instr_test.coe"))
        except (OSError, IndexError, ValueError):
            imem = [0] * WORDS
        try:
            dmem = read_coe(os.path.join(ROOT_DIR, "coe", "data_init.coe"))
        except (OSError, IndexError, ValueError):
            dmem = list(range(WORDS))
        self.cpu = Cpu(imem, dmem)
        self.cycles = 0                   # contador de la Debug Unit
        self.prog_len = 0                 # N del ultimo 'L' (para 'I')

    def close(self):
        pass

    def _clock(self):
        """Un ciclo con cpu_en = 1 (cpu_en = ~program_done & (RUN | STEP))."""
        self.cpu.tick()
        self.cycles = (self.cycles + 1) & MASK

    # --- comandos -------------------------------------------------------------
    def load(self, words):                                         # 'L'
        if not 0 < len(words) <= WORDS:
            raise DebugUnitError("el programa tiene que tener entre 1 y 1024 palabras")
        for i, w in enumerate(words):
            self.cpu.imem[i] = w & MASK
        self.cpu.used = [False] * WORDS   # borra el bitmap de memoria usada
        self.cpu.reset()                  # el CPU queda en reset mientras carga
        self.cycles = 0
        self.prog_len = len(words)

    def reset(self):                                               # 'R'
        self.cpu.reset()                  # la memoria de datos NO se borra
        self.cycles = 0

    def step(self):                                                # 'S'
        if not self.cpu.program_done:
            self._clock()
        return self.dump()

    def dump(self):                                                # 'D'
        c = self.cpu
        words = [c.pc, self.cycles, int(bool(c.program_done))]
        words += [0] + c.regs[1:]         # puerto de debug del banco: x0 = 0
        words += c.latch_words()
        mem = [(i * 4, c.dmem[i]) for i in range(WORDS) if c.used[i]]
        return Dump(words, mem)

    def run(self, max_seconds=10.0):                               # 'C'
        t_end = time.monotonic() + max_seconds
        return self.run_until(lambda: time.monotonic() > t_end)

    def run_until(self, pause_requested, poll=0.1):                # 'C' + pausa
        """Corre hasta HALT o hasta que pause_requested() devuelva True (en la
        placa, el byte de pausa). Se consulta cada 2000 ciclos."""
        c = self.cpu
        while not c.program_done:
            for _ in range(2000):
                if c.program_done:
                    break
                self._clock()
            if pause_requested():
                break
        return self.dump()

    def read_program(self):                                        # 'I'
        return self.cpu.imem[:self.prog_len]


def open_board(port):
    """'SIM' -> placa simulada; cualquier otro nombre -> la placa por UART."""
    if port.upper() == "SIM":
        return SimBoard()
    from du_protocol import DebugUnit
    return DebugUnit(port)
