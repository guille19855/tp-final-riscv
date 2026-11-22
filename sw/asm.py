#!/usr/bin/env python3
"""Ensamblador RISC-V (subconjunto RV32I del TP Final).

Convierte un programa en assembly a las palabras de 32 bits que van a la
memoria de instrucciones.

Uso:
    python sw/asm.py programs/prueba.s            -> prueba.hex, prueba.bin, prueba.lst
    python sw/asm.py programs/prueba.s -o salida  -> salida.hex, salida.bin, salida.lst
    python sw/asm.py programs/prueba.s --coe      -> ademas prueba.coe

Salidas:
    .hex  una palabra por linea en hexadecimal (la lee $readmemh en simulacion)
    .bin  las palabras en little-endian (lo que se manda a la placa por UART)
    .lst  listado: direccion, palabra y linea original (para depurar)
    .coe  formato del IP Block Memory Generator (opcional)

Sintaxis (la estandar de RISC-V):
    # comentario
    etiqueta:  addi  x1, x0, 5       registros x0..x31 o nombres ABI (zero, ra, sp, t0...)
               lw    t0, 8(sp)       inmediatos en decimal, hexa (0x10) o negativos
               beq   x1, x2, fin     los saltos aceptan etiquetas (calcula el offset)
    fin:       halt                  halt = ebreak (0x00100073), la instruccion de parada

Pseudo-instrucciones: nop, mv, not, neg, j, ret, li, halt.
Si el programa no termina en halt, se agrega uno al final.

Tambien tiene un desensamblador (disasm), que usan los tests y la interfaz.
"""

import argparse
import re
import sys

# ---------------------------------------------------------------------------
# Constantes de la ISA (las mismas que rtl/cpu/riscv_defs.vh)
# ---------------------------------------------------------------------------
OP_R, OP_IMM, OP_LOAD, OP_STORE = 0b0110011, 0b0010011, 0b0000011, 0b0100011
OP_BRANCH, OP_JAL, OP_JALR, OP_LUI = 0b1100011, 0b1101111, 0b1100111, 0b0110111
OP_SYSTEM = 0b1110011
EBREAK = 0x00100073
MEM_WORDS = 1024                       # tamano de la memoria de instrucciones

# Tipo R: mnemonico -> (funct3, funct7)
R_OPS = {"add": (0, 0x00), "sub": (0, 0x20), "sll": (1, 0x00), "slt": (2, 0x00),
         "sltu": (3, 0x00), "xor": (4, 0x00), "srl": (5, 0x00), "sra": (5, 0x20),
         "or": (6, 0x00), "and": (7, 0x00)}
# Tipo I aritmetico: mnemonico -> funct3
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
# Shifts con inmediato: mnemonico -> (funct3, funct7)
SH_OPS = {"slli": (1, 0x00), "srli": (5, 0x00), "srai": (5, 0x20)}
LOAD_OPS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORE_OPS = {"sb": 0, "sh": 1, "sw": 2}
BRANCH_OPS = {"beq": 0, "bne": 1}

# Nombres de registros: x0..x31 y los nombres ABI
ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
       "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
       "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
       "t3", "t4", "t5", "t6"]
REGS = {f"x{i}": i for i in range(32)}
REGS.update({name: i for i, name in enumerate(ABI)})
REGS["fp"] = 8


class AsmError(Exception):
    """Error de ensamblado, con el numero de linea del archivo fuente."""

    def __init__(self, line, msg):
        super().__init__(f"linea {line}: {msg}")
        self.line, self.msg = line, msg


# ---------------------------------------------------------------------------
# Codificacion de los 6 formatos (la contracara de rtl/cpu/imm_gen.v)
# ---------------------------------------------------------------------------
def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(imm, rs2, rs1, f3, op):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | ((imm & 0x1F) << 7) | op


def enc_b(imm, rs2, rs1, f3, op):
    # offset de 13 bits con el bit 0 implicito: imm[12|10:5] rs2 rs1 f3 imm[4:1|11]
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) \
        | (rs1 << 15) | (f3 << 12) | (((imm >> 1) & 0xF) << 8) \
        | (((imm >> 11) & 1) << 7) | op


def enc_u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def enc_j(imm, rd, op):
    # offset de 21 bits con el bit 0 implicito: imm[20|10:1|11|19:12] rd
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) \
        | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | op


# ---------------------------------------------------------------------------
# Lectura de operandos
# ---------------------------------------------------------------------------
def parse_reg(tok, line):
    r = REGS.get(tok.strip().lower())
    if r is None:
        raise AsmError(line, f"registro invalido '{tok.strip()}'")
    return r


def parse_int(tok, line):
    tok = tok.strip()
    try:
        return int(tok, 0)
    except ValueError:
        raise AsmError(line, f"numero invalido '{tok}'") from None


def check_range(val, lo, hi, what, line):
    if not lo <= val <= hi:
        raise AsmError(line, f"{what} {val} fuera de rango ({lo} .. {hi})")
    return val


def parse_mem(tok, line):
    """'8(sp)' -> (8, 2). El desplazamiento puede faltar: '(sp)' -> (0, 2)."""
    m = re.fullmatch(r"\s*([^()]*)\(\s*([\w]+)\s*\)\s*", tok)
    if not m:
        raise AsmError(line, f"se esperaba desplazamiento(registro), no '{tok.strip()}'")
    off = parse_int(m.group(1), line) if m.group(1).strip() else 0
    return check_range(off, -2048, 2047, "desplazamiento", line), parse_reg(m.group(2), line)


def li_parts(val):
    """Divide un valor de 32 bits en (parte alta para lui, parte baja para addi).
    addi extiende el signo, asi que si el bit 11 de la parte baja es 1 hay que
    sumar 1 a la parte alta para compensar."""
    val &= 0xFFFFFFFF
    hi = ((val + 0x800) >> 12) & 0xFFFFF
    lo = val - (hi << 12)
    lo = ((lo + 0x800) & 0xFFF) - 0x800          # llevar a -2048 .. 2047
    return hi, lo


# ---------------------------------------------------------------------------
# Ensamblador (dos pasadas)
# ---------------------------------------------------------------------------
LABEL_RE = re.compile(r"^\s*([A-Za-z_.][\w.]*)\s*:")


def split_operands(text):
    return [t.strip() for t in text.split(",")] if text.strip() else []


def instr_size(mn, ops, line):
    """Cantidad de palabras que ocupa una instruccion (para la 1ra pasada)."""
    if mn == "li":
        if len(ops) != 2:
            raise AsmError(line, "li espera 2 operandos: li rd, valor")
        val = parse_int(ops[1], line)
        check_range(val, -2**31, 2**32 - 1, "valor", line)
        if -2048 <= val <= 2047:
            return 1
        return 1 if li_parts(val)[1] == 0 else 2
    return 1


def assemble(source):
    """Ensambla el texto de un programa.
    Devuelve una lista de (direccion, palabra, linea, texto_original)."""
    # ---- 1ra pasada: etiquetas y direcciones ----
    items, labels, pc = [], {}, 0
    for n, raw in enumerate(source.splitlines(), start=1):
        text = raw.split("#")[0]
        while True:
            m = LABEL_RE.match(text)
            if not m:
                break
            name = m.group(1)
            if name in labels:
                raise AsmError(n, f"etiqueta '{name}' definida dos veces")
            labels[name] = pc
            text = text[m.end():]
        text = text.strip()
        if not text:
            continue
        parts = text.split(None, 1)
        mn = parts[0].lower()
        ops = split_operands(parts[1] if len(parts) > 1 else "")
        size = instr_size(mn, ops, n)
        items.append((pc, mn, ops, n, raw.strip()))
        pc += 4 * size

    # ---- 2da pasada: codificar ----
    out = []
    for pc, mn, ops, n, raw in items:
        for k, word in enumerate(encode(mn, ops, pc, labels, n)):
            out.append((pc + 4 * k, word, n, raw if k == 0 else ""))

    # ---- halt al final si falta ----
    if not out or out[-1][1] != EBREAK:
        addr = out[-1][0] + 4 if out else 0
        out.append((addr, EBREAK, 0, "halt   # agregado por el ensamblador"))

    if len(out) > MEM_WORDS:
        raise AsmError(0, f"el programa ocupa {len(out)} palabras; la memoria tiene {MEM_WORDS}")
    return out


def need(ops, k, mn, fmt, line):
    if len(ops) != k:
        raise AsmError(line, f"{mn} espera {k} operando(s): {mn} {fmt}")


def target(tok, pc, labels, line):
    """Destino de un salto: etiqueta (offset = destino - pc) o un offset numerico."""
    tok = tok.strip()
    if tok in labels:
        return labels[tok] - pc
    if re.fullmatch(r"[A-Za-z_.][\w.]*", tok):
        raise AsmError(line, f"etiqueta '{tok}' no definida")
    return parse_int(tok, line)


def encode(mn, ops, pc, labels, line):
    """Codifica una instruccion (o pseudo-instruccion). Devuelve una lista de palabras."""
    # ---- pseudo-instrucciones: se traducen a instrucciones reales ----
    if mn in ("nop",):
        need(ops, 0, mn, "", line)
        return [enc_i(0, 0, 0, 0, OP_IMM)]                         # addi x0, x0, 0
    if mn in ("halt", "ebreak"):
        need(ops, 0, mn, "", line)
        return [EBREAK]
    if mn == "mv":
        need(ops, 2, mn, "rd, rs", line)
        return encode("addi", [ops[0], ops[1], "0"], pc, labels, line)
    if mn == "not":
        need(ops, 2, mn, "rd, rs", line)
        return encode("xori", [ops[0], ops[1], "-1"], pc, labels, line)
    if mn == "neg":
        need(ops, 2, mn, "rd, rs", line)
        return encode("sub", [ops[0], "x0", ops[1]], pc, labels, line)
    if mn == "j":
        need(ops, 1, mn, "etiqueta", line)
        return encode("jal", ["x0", ops[0]], pc, labels, line)
    if mn == "ret":
        need(ops, 0, mn, "", line)
        return encode("jalr", ["x0", "0(ra)"], pc, labels, line)
    if mn == "li":
        rd = parse_reg(ops[0], line)
        val = parse_int(ops[1], line)
        if -2048 <= val <= 2047:
            return [enc_i(val, 0, 0, rd, OP_IMM)]                  # addi rd, x0, val
        hi, lo = li_parts(val)
        words = [enc_u(hi, rd, OP_LUI)]                            # lui  rd, hi
        if lo:
            words.append(enc_i(lo, rd, 0, rd, OP_IMM))             # addi rd, rd, lo
        return words

    # ---- instrucciones reales ----
    if mn in R_OPS:
        need(ops, 3, mn, "rd, rs1, rs2", line)
        f3, f7 = R_OPS[mn]
        return [enc_r(f7, parse_reg(ops[2], line), parse_reg(ops[1], line), f3,
                      parse_reg(ops[0], line), OP_R)]
    if mn in I_OPS:
        need(ops, 3, mn, "rd, rs1, imm", line)
        imm = check_range(parse_int(ops[2], line), -2048, 2047, "inmediato", line)
        return [enc_i(imm, parse_reg(ops[1], line), I_OPS[mn], parse_reg(ops[0], line), OP_IMM)]
    if mn in SH_OPS:
        need(ops, 3, mn, "rd, rs1, shamt", line)
        f3, f7 = SH_OPS[mn]
        sh = check_range(parse_int(ops[2], line), 0, 31, "desplazamiento", line)
        return [enc_i((f7 << 5) | sh, parse_reg(ops[1], line), f3, parse_reg(ops[0], line), OP_IMM)]
    if mn in LOAD_OPS:
        need(ops, 2, mn, "rd, imm(rs1)", line)
        off, rs1 = parse_mem(ops[1], line)
        return [enc_i(off, rs1, LOAD_OPS[mn], parse_reg(ops[0], line), OP_LOAD)]
    if mn in STORE_OPS:
        need(ops, 2, mn, "rs2, imm(rs1)", line)
        off, rs1 = parse_mem(ops[1], line)
        return [enc_s(off, parse_reg(ops[0], line), rs1, STORE_OPS[mn], OP_STORE)]
    if mn in BRANCH_OPS:
        need(ops, 3, mn, "rs1, rs2, etiqueta", line)
        off = target(ops[2], pc, labels, line)
        if off % 2:
            raise AsmError(line, f"offset de salto impar ({off})")
        check_range(off, -4096, 4094, "offset de salto", line)
        return [enc_b(off, parse_reg(ops[1], line), parse_reg(ops[0], line), BRANCH_OPS[mn], OP_BRANCH)]
    if mn == "jal":
        if len(ops) == 1:                                          # jal etiqueta -> rd = ra
            ops = ["ra", ops[0]]
        need(ops, 2, mn, "rd, etiqueta", line)
        off = target(ops[1], pc, labels, line)
        if off % 2:
            raise AsmError(line, f"offset de salto impar ({off})")
        check_range(off, -2**20, 2**20 - 2, "offset de salto", line)
        return [enc_j(off, parse_reg(ops[0], line), OP_JAL)]
    if mn == "jalr":
        # formas: jalr rs1 | jalr rd, imm(rs1) | jalr rd, rs1, imm
        if len(ops) == 1:
            rd, off, rs1 = 1, 0, parse_reg(ops[0], line)
        elif len(ops) == 2:
            rd = parse_reg(ops[0], line)
            off, rs1 = parse_mem(ops[1], line)
        else:
            need(ops, 3, mn, "rd, rs1, imm", line)
            rd, rs1 = parse_reg(ops[0], line), parse_reg(ops[1], line)
            off = check_range(parse_int(ops[2], line), -2048, 2047, "inmediato", line)
        return [enc_i(off, rs1, 0, rd, OP_JALR)]
    if mn == "lui":
        need(ops, 2, mn, "rd, imm20", line)
        imm = check_range(parse_int(ops[1], line), -2**19, 2**20 - 1, "inmediato", line)
        return [enc_u(imm, parse_reg(ops[0], line), OP_LUI)]

    raise AsmError(line, f"instruccion no soportada '{mn}'")


# ---------------------------------------------------------------------------
# Desensamblador (lo usan los tests y la interfaz para mostrar los latches)
# ---------------------------------------------------------------------------
def _sext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def disasm(word):
    """Palabra de 32 bits -> texto en assembly (con registros xN)."""
    op, rd, f3 = word & 0x7F, (word >> 7) & 0x1F, (word >> 12) & 7
    rs1, rs2, f7 = (word >> 15) & 0x1F, (word >> 20) & 0x1F, word >> 25
    imm_i = _sext(word >> 20, 12)
    imm_s = _sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
    imm_b = _sext((((word >> 31) & 1) << 12) | (((word >> 7) & 1) << 11)
                  | (((word >> 25) & 0x3F) << 5) | (((word >> 8) & 0xF) << 1), 13)
    imm_j = _sext((((word >> 31) & 1) << 20) | (((word >> 12) & 0xFF) << 12)
                  | (((word >> 20) & 1) << 11) | (((word >> 21) & 0x3FF) << 1), 21)

    def find(table, key):
        for k, v in table.items():
            if v == key:
                return k
        return None

    if word == EBREAK:
        return "halt"
    if op == OP_R:
        mn = find(R_OPS, (f3, f7))
        if mn:
            return f"{mn} x{rd}, x{rs1}, x{rs2}"
    elif op == OP_IMM:
        if f3 in (1, 5):
            mn = find(SH_OPS, (f3, f7))
            if mn:
                return f"{mn} x{rd}, x{rs1}, {rs2}"
        else:
            return f"{find(I_OPS, f3)} x{rd}, x{rs1}, {imm_i}"
    elif op == OP_LOAD and find(LOAD_OPS, f3):
        return f"{find(LOAD_OPS, f3)} x{rd}, {imm_i}(x{rs1})"
    elif op == OP_STORE and find(STORE_OPS, f3):
        return f"{find(STORE_OPS, f3)} x{rs2}, {imm_s}(x{rs1})"
    elif op == OP_BRANCH and find(BRANCH_OPS, f3):
        return f"{find(BRANCH_OPS, f3)} x{rs1}, x{rs2}, {imm_b}"
    elif op == OP_JAL:
        return f"jal x{rd}, {imm_j}"
    elif op == OP_JALR and f3 == 0:
        return f"jalr x{rd}, {imm_i}(x{rs1})"
    elif op == OP_LUI:
        return f"lui x{rd}, 0x{word >> 12:05x}"
    return f".word 0x{word:08x}"


# ---------------------------------------------------------------------------
# Archivos de salida
# ---------------------------------------------------------------------------
def write_outputs(prog, base, coe=False):
    words = [w for _, w, _, _ in prog]
    with open(base + ".hex", "w") as f:
        f.write("".join(f"{w:08x}\n" for w in words))
    with open(base + ".bin", "wb") as f:
        f.write(b"".join(w.to_bytes(4, "little") for w in words))
    with open(base + ".lst", "w", encoding="utf-8") as f:
        f.write(f"{'direc.':8}  {'palabra':8}  {'linea':>5}  {'fuente':32}  instruccion real\n")
        for addr, w, n, src in prog:
            code = src.split("#")[0].strip() if n else "(halt agregado)"
            f.write(f"{addr:08x}  {w:08x}  {n if n else '':>5}  {code:32}  {disasm(w)}\n")
    if coe:
        with open(base + ".coe", "w") as f:
            f.write("memory_initialization_radix=16;\nmemory_initialization_vector=\n")
            f.write(",\n".join(f"{w:08X}" for w in words) + ";\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Ensamblador RISC-V del TP Final")
    ap.add_argument("fuente", help="programa en assembly (.s)")
    ap.add_argument("-o", "--salida", help="nombre base de las salidas (sin extension)")
    ap.add_argument("--coe", action="store_true", help="generar tambien el .coe")
    args = ap.parse_args(argv)

    base = args.salida or re.sub(r"\.[^./\\]*$", "", args.fuente)
    try:
        with open(args.fuente, encoding="utf-8") as f:
            prog = assemble(f.read())
    except AsmError as e:
        print(f"{args.fuente}:{e.line}: error: {e.msg}", file=sys.stderr)
        return 1
    write_outputs(prog, base, args.coe)
    print(f"{args.fuente}: {len(prog)} instrucciones ({4 * len(prog)} bytes) -> "
          f"{base}.hex .bin .lst" + (" .coe" if args.coe else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
