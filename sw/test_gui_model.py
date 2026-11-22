"""Tests de gui_model.py (logica de la interfaz, sin placa ni ventana).

    python sw/test_gui_model.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gui_model as gm  # noqa: E402
from du_protocol import Dump, read_hex  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
checks = errors = 0


def check(cond, msg):
    global checks, errors
    checks += 1
    if cond:
        print("OK   ", msg)
    else:
        errors += 1
        print("ERROR", msg)


def mk_dump(pc=0, cycles=0, done=False, regs=None, latches=None, mem=()):
    regs = regs or [0] * 32
    lw = latches or [0] * 16
    return Dump([pc, cycles, int(done)] + regs + lw, list(mem))


# --- load_program: .s ensamblado == .hex del ensamblador --------------------
for name in ("ejemplo", "jumps", "memoria"):
    base = os.path.join(ROOT, "programs", name)
    ws, ls = gm.load_program(base + ".s")
    wh, lh = gm.load_program(base + ".hex")
    check(ws == wh == read_hex(base + ".hex"), f"{name}: .s y .hex dan las mismas palabras")
    check([a for a, *_ in ls] == [4 * i for i in range(len(ws))], f"{name}: direcciones 0,4,8...")
    check(all(d1 == d2 for (_, _, d1, _), (_, _, d2, _) in zip(ls, lh)),
          f"{name}: mismo desensamblado")
check(gm.load_program(os.path.join(ROOT, "programs", "ejemplo.s"))[1][0][3] != "",
      "el listado de un .s trae la linea fuente")

# --- burbujas y etapas ------------------------------------------------------
d = mk_dump(pc=0)                                    # recien reseteado
check(gm.stage_marks(d) == {0: "IF"}, "reset: solo IF en 0 (latches en burbuja)")
check([b for *_, b in gm.latch_lines(d)] == [True] * 4, "reset: 4 latches en burbuja")

lw = [0] * 16
lw[0], lw[1], lw[2], lw[3] = 8, 12, 0x002081B3, 1    # IF/ID: add en 8, valida
lw[4], lw[5] = 0, 4                                  # ID/EX: instruccion real en 0
lw[9] = (5 << 17) | (3 << 9) | (1 << 11) | (1 << 3)  # rd=5, aluop=I, srcB=imm, reg_write
d = mk_dump(pc=12, latches=lw)
check(gm.stage_marks(d) == {12: "IF", 8: "ID", 0: "EX"}, "IF=PC, ID=IF/ID.pc, EX=ID/EX.pc (en 0)")
lines = gm.latch_lines(d)
check(not lines[0][2] and "add" in lines[0][1], "IF/ID desensambla la instruccion")
check(not lines[1][2] and "rd=x5" in lines[1][1] and "aluop=I" in lines[1][1]
      and "srcB=imm" in lines[1][1] and "[reg_write]" in lines[1][1], "ID/EX decodificado")
check(lines[2][2] and lines[3][2], "EX/MEM y MEM/WB en 0 -> burbuja")

lw2 = list(lw)
lw2[3] = 0                                           # IF/ID invalido (flush)
lw2[4], lw2[5] = 0, 0                                # ID/EX burbuja (pc4 = 0)
lw2[10], lw2[12] = 0, 1 << 4                         # EX/MEM: sw con resultado 0
check(gm.stage_marks(mk_dump(pc=12, latches=lw2)) == {12: "IF"},
      "IF/ID invalido y ID/EX con pc4=0 no se marcan")
check(not gm.latch_lines(mk_dump(latches=lw2))[2][2],
      "EX/MEM con result=0 pero mem_write NO es burbuja")
check(gm.stage_marks(mk_dump(pc=8, done=True, latches=lw)) == {8: "ID", 0: "EX"},
      "con HALT no se marca IF")
lw3 = list(lw)
lw3[0], lw3[1] = 0, 4                                # lazo: IF/ID y ID/EX en 0
check(gm.stage_marks(mk_dump(pc=0, latches=lw3)) == {0: "EX"},
      "misma direccion en varias etapas: gana la mas adelantada")

# --- cambios entre volcados -------------------------------------------------
r1, r2 = [0] * 32, [0] * 32
r2[5], r2[10] = 7, 0xFFFFFFFF
a = mk_dump(regs=r1, mem=[(0, 1), (8, 2)])
b = mk_dump(regs=r2, mem=[(0, 1), (8, 3), (0xFFC, 4)])
check(gm.changed_regs(None, b) == set(), "sin volcado previo no marca cambios")
check(gm.changed_regs(a, b) == {5, 10}, "registros cambiados")
check(gm.changed_mem(a, b) == {8, 0xFFC}, "memoria: dato distinto y direccion nueva")
check(gm.fmt_value(0xFFFFFFFF, "dec") == "-1" and gm.fmt_value(42, "hex") == "0000002a",
      "formato hex / decimal con signo")

print()
print(f"TEST {'PASSED' if errors == 0 else 'FAILED'}: {checks} checks, {errors} errors")
sys.exit(1 if errors else 0)
