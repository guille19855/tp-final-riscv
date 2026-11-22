#!/usr/bin/env python3
"""Simulador de instrucciones (ISS) del TP Final: el "modelo de referencia".

Ejecuta un programa de a UNA instruccion por vez, sin pipeline, tal como dice
la especificacion de RISC-V. Es lo que el procesador segmentado tiene que
imitar: si el pipeline resuelve bien los riesgos (forwarding, stall, flush),
al terminar tiene que tener los mismos registros y la misma memoria.

Uso:
    python sw/iss.py programs/ejemplo.s      (o el .hex ya ensamblado)
        -> genera programs/ejemplo.exp, .trc y .sto y muestra los registros
           que cambiaron

El .exp lo lee el testbench cpu_top_tb.v con $readmemh, una palabra por linea:
    lineas    0..31     registros x0..x31 al terminar
    lineas   32..1055   memoria de datos, palabras 0..1023
    linea    1056       instrucciones ejecutadas (incluido el ebreak)
    linea    1057       ciclos que tiene que tardar el pipeline (ver abajo)

TRAZAS. Comparar solo el estado final no alcanza: un valor intermedio mal
calculado (por ejemplo un forwarding que falla) suele pisarse despues y el
error desaparece. Por eso tambien se anota CADA escritura, en orden:
    .trc  una linea por escritura de registro (rd != x0), en el orden en que
          llegan a WB:  rr vvvvvvvv   (rd en 2 digitos hex + valor)
    .sto  una linea por store, en el orden en que llegan a MEM:
          f aaaaaaaa dddddddd   (funct3 + direccion + rs2 completo)
El testbench verifica cada escritura en el ciclo en que ocurre.

Modelo de la maquina (igual que el hardware):
    - memoria de datos de 1024 palabras, inicializada con palabra i = i
      (coe/data_init.coe); se usa addr[11:2] como en mem_stage.v
    - accesos desalineados: no soportados (decision 1-A de MEM) -> error
    - el programa termina en ebreak

CICLOS ESPERADOS. El pipeline no cambia QUE se calcula, solo CUANDO. Con
saltos en EX y forwarding, los ciclos se pueden predecir exactamente:
    ciclos = N + 3 + stalls + 2 * saltos_tomados
    - N: instrucciones ejecutadas (con el ebreak). Sin riesgos, la
      instruccion k (desde 0) llega a MEM/WB en el flanco k + 4, asi que el
      ebreak (k = N - 1) llega en el flanco N + 3.
    - stalls: 1 por cada load seguido de una instruccion que lee su rd
      (load-use; con rd != x0).
    - saltos tomados (branch tomado, jal, jalr): 2 ciclos de flush cada uno.
El testbench compara contra este numero: asi tambien se verifica que el
pipeline no frena de mas ni de menos.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm  # noqa: E402

MASK = 0xFFFFFFFF
DMEM_WORDS = 1024
MAX_STEPS = 1_000_000
MAX_TRACE = 32768                         # tamano de los arreglos del testbench

# Opcodes (definidos aca y no importados de asm.py: el modelo de referencia
# tiene que ser independiente del ensamblador)
OP_R, OP_I, OP_LOAD, OP_STORE = 0b0110011, 0b0010011, 0b0000011, 0b0100011
OP_BRANCH, OP_JAL, OP_JALR, OP_LUI = 0b1100011, 0b1101111, 0b1100111, 0b0110111
EBREAK = 0x00100073


class IssError(Exception):
    pass


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def signed(v):
    return sext(v, 32)


# ---------------------------------------------------------------------------
# Decodificacion: campos e inmediatos de cada formato (lo mismo que imm_gen.v)
# ---------------------------------------------------------------------------
def imm_i(w):
    return sext(w >> 20, 12)


def imm_s(w):
    return sext(((w >> 25) << 5) | ((w >> 7) & 0x1F), 12)


def imm_b(w):
    return sext((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) |
                (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1), 13)


def imm_j(w):
    return sext((((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12) |
                (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1), 21)


def alu(op, a, b):
    """op = (funct3, bit30). Devuelve el resultado de 32 bits."""
    f3, b30 = op
    sh = b & 0x1F
    if f3 == 0:
        return (a - b if b30 else a + b) & MASK
    if f3 == 1:
        return (a << sh) & MASK
    if f3 == 2:
        return int(signed(a) < signed(b))
    if f3 == 3:
        return int(a < b)
    if f3 == 4:
        return a ^ b
    if f3 == 5:
        return (signed(a) >> sh) & MASK if b30 else a >> sh
    if f3 == 6:
        return a | b
    return a & b


class Machine:
    def __init__(self, words):
        self.imem = list(words)
        self.regs = [0] * 32
        self.dmem = list(range(DMEM_WORDS))   # coe: palabra i = i
        self.pc = 0
        self.instret = 0
        self.stalls = 0
        self.taken = 0
        self.prev_load_rd = 0                 # rd del load anterior (load-use)
        self.done = False
        self.reg_trace = []                   # (rd, valor) en orden
        self.store_trace = []                 # (funct3, direccion, rs2) en orden

    # --- memoria de datos, little-endian, addr[11:2] -------------------------
    def load(self, addr, f3):
        size = {0: 1, 4: 1, 1: 2, 5: 2, 2: 4}[f3]
        if addr % size:
            raise IssError(f"pc {self.pc:#x}: load desalineado en {addr:#x}")
        word = self.dmem[(addr >> 2) % DMEM_WORDS]
        val = (word >> (8 * (addr & 3))) & ((1 << (8 * size)) - 1)
        if f3 in (0, 1):                      # lb, lh: con signo
            val = sext(val, 8 * size) & MASK
        return val

    def store(self, addr, f3, val):
        size = {0: 1, 1: 2, 2: 4}[f3]
        if addr % size:
            raise IssError(f"pc {self.pc:#x}: store desalineado en {addr:#x}")
        i = (addr >> 2) % DMEM_WORDS
        sh = 8 * (addr & 3)
        m = ((1 << (8 * size)) - 1) << sh
        self.dmem[i] = (self.dmem[i] & ~m | (val << sh) & m) & MASK

    # --- una instruccion ----------------------------------------------------
    def step(self):
        if self.pc % 4 or not 0 <= self.pc // 4 < len(self.imem):
            raise IssError(f"PC {self.pc:#x} fuera del programa")
        w = self.imem[self.pc // 4]
        op = w & 0x7F
        rd = (w >> 7) & 0x1F
        f3 = (w >> 12) & 7
        rs1 = (w >> 15) & 0x1F
        rs2 = (w >> 20) & 0x1F
        b30 = (w >> 30) & 1
        x = self.regs
        a, b = x[rs1], x[rs2]
        next_pc = (self.pc + 4) & MASK
        result = None                         # valor para rd (None = no escribe)
        usa = ()                              # registros que lee (para load-use)
        load_rd = 0

        if op == OP_R:
            result = alu((f3, b30), a, b)
            usa = (rs1, rs2)
        elif op == OP_I:
            # el bit 30 solo cuenta en srai (en el resto es parte del inmediato)
            result = alu((f3, b30 if f3 == 5 else 0), a, imm_i(w) & MASK)
            usa = (rs1,)
        elif op == OP_LOAD:
            result = self.load((a + imm_i(w)) & MASK, f3)
            usa = (rs1,)
            load_rd = rd
        elif op == OP_STORE:
            self.store((a + imm_s(w)) & MASK, f3, b)
            self.store_trace.append((f3, (a + imm_s(w)) & MASK, b))
            usa = (rs1, rs2)
        elif op == OP_BRANCH:
            if f3 not in (0, 1):
                raise IssError(f"pc {self.pc:#x}: branch no soportado {w:08x}")
            usa = (rs1, rs2)
            if (a == b) == (f3 == 0):
                next_pc = (self.pc + imm_b(w)) & MASK
                self.taken += 1
        elif op == OP_JAL:
            result = next_pc
            next_pc = (self.pc + imm_j(w)) & MASK
            self.taken += 1
        elif op == OP_JALR:
            result = next_pc
            next_pc = (a + imm_i(w)) & MASK & ~1
            usa = (rs1,)
            self.taken += 1
        elif op == OP_LUI:
            result = (w & 0xFFFFF000)
        elif w == EBREAK:
            self.done = True
        else:
            raise IssError(f"pc {self.pc:#x}: instruccion no soportada {w:08x}")

        # load-use: el load anterior escribe un registro que esta lee
        if self.prev_load_rd and self.prev_load_rd in usa:
            self.stalls += 1
        self.prev_load_rd = load_rd

        if result is not None and rd != 0:
            x[rd] = result & MASK
            self.reg_trace.append((rd, x[rd]))
        self.pc = next_pc
        self.instret += 1

    def run(self, max_steps=MAX_STEPS):
        while not self.done:
            if self.instret >= max_steps:
                raise IssError(f"no termino en {max_steps} instrucciones (lazo infinito?)")
            self.step()
        return self

    @property
    def cycles(self):
        return self.instret + 3 + self.stalls + 2 * self.taken


def run_words(words):
    return Machine(words).run()


def read_program(path):
    """Acepta un .s (lo ensambla) o un .hex (una palabra por linea)."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if path.endswith(".hex"):
        return [int(t, 16) for t in text.split()]
    return [w for _, w, _, _ in asm.assemble(text)]


def write_exp(m, base):
    """Escribe base.exp (estado final), base.trc y base.sto (trazas)."""
    if max(len(m.reg_trace), len(m.store_trace)) > MAX_TRACE:
        raise IssError(f"traza de mas de {MAX_TRACE} escrituras: programa muy largo")
    lines = [f"{v:08x}" for v in m.regs + m.dmem + [m.instret, m.cycles]]
    with open(base + ".exp", "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(base + ".trc", "w") as f:
        f.write("".join(f"{rd:02x}{v:08x}\n" for rd, v in m.reg_trace))
    with open(base + ".sto", "w") as f:
        f.write("".join(f"{f3:x}{ad:08x}{v:08x}\n" for f3, ad, v in m.store_trace))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("uso: python sw/iss.py <programa.s | programa.hex>", file=sys.stderr)
        return 2
    src = argv[0]
    try:
        m = run_words(read_program(src))
    except (IssError, asm.AsmError) as e:
        print(f"{src}: error: {e}", file=sys.stderr)
        return 1
    base = os.path.splitext(src)[0]
    try:
        write_exp(m, base)
    except IssError as e:
        print(f"{src}: error: {e}", file=sys.stderr)
        return 1
    print(f"{src}: {m.instret} instrucciones, {m.stalls} stalls, "
          f"{m.taken} saltos tomados -> {m.cycles} ciclos esperados -> {base}.exp/.trc/.sto")
    for i, v in enumerate(m.regs):
        if v:
            print(f"  x{i:<2} ({asm.ABI[i]:>4}) = {v:08x}  ({signed(v)})")
    changed = [i for i, v in enumerate(m.dmem) if v != i]
    if changed:
        print(f"  memoria: {len(changed)} palabras distintas del valor inicial: " +
              ", ".join(f"[{i}]={m.dmem[i]:08x}" for i in changed[:8]) +
              (" ..." if len(changed) > 8 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
