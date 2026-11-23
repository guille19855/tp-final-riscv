"""Logica de la interfaz grafica (Fase 9), separada de la ventana.

Todo lo que se puede probar sin placa ni tkinter esta aca (test_gui_model.py):
  - leer un programa (.s lo ensambla con asm.py, .hex lo lee directo)
  - en que etapa esta cada instruccion del listado (IF / ID / EX)
  - texto de cada latch, con las burbujas detectadas
  - que registros y que posiciones de memoria cambiaron entre dos volcados
La ventana (debug_gui.py) solo dibuja lo que devuelven estas funciones.
"""

import os

import asm
from du_protocol import read_hex, WB_SEL

ALU_OP = {0: "ADD", 1: "SUB", 2: "R", 3: "I"}
FLAGS_IDEX = ("branch", "jal", "jalr", "mem_read", "mem_write", "reg_write", "halt")
FLAGS_EXMEM = ("mem_read", "mem_write", "reg_write", "halt")
FLAGS_MEMWB = ("mem_read", "reg_write", "halt")


# ---------------------------------------------------------------------------
# Programa
# ---------------------------------------------------------------------------
def load_program(path):
    """-> (palabras, listado) con listado = [(direccion, palabra, asm, fuente)].
    Un .s se ensambla (puede lanzar asm.AsmError); cualquier otra extension se
    lee como .hex (una palabra por linea)."""
    if os.path.splitext(path)[1].lower() == ".s":
        with open(path, encoding="utf-8") as f:
            prog = asm.assemble(f.read())
        words = [w for _, w, _, _ in prog]
        listing = [(a, w, asm.disasm(w), src) for a, w, _, src in prog]
    else:
        words = read_hex(path)
        listing = [(4 * i, w, asm.disasm(w), "") for i, w in enumerate(words)]
    return words, listing


# ---------------------------------------------------------------------------
# Burbujas y etapas
# ---------------------------------------------------------------------------
# Burbujas (Fase 10): el flush/stall solo pone en 0 los bits de control que
# tienen efecto; los datos del latch quedan con valores viejos que no importan.
# Toda instruccion real tiene al menos uno de esos bits en 1 (las que escriben
# registro, incluido el nop, tienen reg_write; sw mem_write; beq/bne branch;
# ebreak halt), asi que:
#   IF/ID : burbuja si valid = 0.
#   ID/EX : burbuja si branch/jal/jalr/mem_read/mem_write/reg_write/halt = 0.
#   EX/MEM, MEM/WB: "sin efecto" si no lee/escribe memoria, no escribe
#           registro y no es halt. Ahi caen las burbujas y tambien los
#           beq/bne, que ya hicieron todo su trabajo en EX.
def bubble_ifid(L):
    return not L["IF/ID"]["valid"]


def bubble_idex(L):
    return not any(L["ID/EX"][n] for n in FLAGS_IDEX)


def no_effect(L, latch):
    names = FLAGS_EXMEM if latch == "EX/MEM" else FLAGS_MEMWB
    return not any(L[latch][n] for n in names)


def stage_marks(d):
    """{direccion: etapa} de las instrucciones que se pueden ubicar:
    IF = el PC (la BRAM esta leyendo esa direccion), ID = IF/ID.pc,
    EX = ID/EX.pc. Si dos caen en la misma direccion (lazo de 1 instruccion)
    gana la mas adelantada."""
    L = d.latches
    marks = {}
    if not d.done:
        marks[d.pc] = "IF"
    if not bubble_ifid(L):
        marks[L["IF/ID"]["pc"]] = "ID"
    if not bubble_idex(L):
        marks[L["ID/EX"]["pc"]] = "EX"
    return marks


# ---------------------------------------------------------------------------
# Texto de los latches
# ---------------------------------------------------------------------------
def _flags(fields, names):
    on = [n for n in names if fields[n]]
    return " ".join(on) if on else "-"


def latch_lines(d):
    """-> [(nombre, texto, es_burbuja)] para los 4 latches."""
    L = d.latches
    out = []

    f = L["IF/ID"]
    if bubble_ifid(L):
        out.append(("IF/ID", "(burbuja)", True))
    else:
        out.append(("IF/ID", f"pc={f['pc']:08x}  instr={f['instr']:08x}  "
                             f"{asm.disasm(f['instr'])}", False))

    f = L["ID/EX"]
    if bubble_idex(L):
        out.append(("ID/EX", "(burbuja)", True))
    else:
        out.append(("ID/EX",
                    f"pc={f['pc']:08x}  rs1=x{f['rs1']}:{f['rs1_data']:08x}  "
                    f"rs2=x{f['rs2']}:{f['rs2_data']:08x}  imm={f['imm']:08x}  "
                    f"rd=x{f['rd']}  f3={f['funct3']} f7b5={f['funct7b5']}  "
                    f"srcA={'0' if f['alu_src_a'] else 'rs1'} "
                    f"srcB={'imm' if f['alu_src_b'] else 'rs2'}  "
                    f"aluop={ALU_OP[f['alu_op']]}  wb={WB_SEL[f['wb_sel']]}  "
                    f"[{_flags(f, FLAGS_IDEX)}]", False))

    # EX/MEM y MEM/WB sin efecto: se muestran los valores igual, en gris
    f = L["EX/MEM"]
    ne = no_effect(L, "EX/MEM")
    out.append(("EX/MEM", ("(sin efecto) " if ne else "") +
                f"result={f['result']:08x}  rs2_data={f['rs2_data']:08x}  "
                f"rd=x{f['rd']}  f3={f['funct3']}  wb={WB_SEL[f['wb_sel']]}  "
                f"[{_flags(f, FLAGS_EXMEM)}]", ne))

    f = L["MEM/WB"]
    ne = no_effect(L, "MEM/WB")
    out.append(("MEM/WB", ("(sin efecto) " if ne else "") +
                f"result={f['result']:08x}  read_data={f['read_data']:08x}  "
                f"rd=x{f['rd']}  f3={f['funct3']} addr_lo={f['addr_lo']}  "
                f"wb={WB_SEL[f['wb_sel']]}  [{_flags(f, FLAGS_MEMWB)}]", ne))
    return out


# ---------------------------------------------------------------------------
# Cambios entre volcados
# ---------------------------------------------------------------------------
def changed_regs(prev, cur):
    """Indices de los registros que cambiaron (vacio si no hay volcado previo)."""
    if prev is None:
        return set()
    return {i for i in range(32) if prev.regs[i] != cur.regs[i]}


def changed_mem(prev, cur):
    """Direcciones de memoria nuevas o con otro dato que en el volcado previo."""
    if prev is None:
        return set()
    old = dict(prev.mem)
    return {a for a, v in cur.mem if old.get(a) != v}


def fmt_value(v, mode):
    """mode 'hex' -> 0000002a ; 'dec' -> con signo."""
    if mode == "dec":
        return str(v - (1 << 32) if v & 0x80000000 else v)
    return f"{v:08x}"
