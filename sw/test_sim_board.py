"""Tests de sim_board.py (la placa simulada), sin placa.

    python sw/test_sim_board.py

1. Los programas de programs/ y programs/random/: el modelo del pipeline tiene
   que dar exactamente lo mismo que el ISS (iss.py), igual que el hardware en
   cpu_top_tb.v: ciclos, registros, memoria usada y el ORDEN de cada escritura
   de registro y de cada store.
2. Comportamientos del pipeline que se ven en la interfaz: stall load-use,
   flush de un salto, HALT con el pipeline vacio, paso a paso, reset, carga.
"""

import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gui_model as gm  # noqa: E402
import iss  # noqa: E402
from sim_board import SimBoard, NOP  # noqa: E402

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


def words_of(name):
    return iss.read_program(os.path.join(ROOT, "programs", name + ".s"))


# --- 1. los programas contra el ISS ---------------------------------------
progs = sorted(glob.glob(os.path.join(ROOT, "programs", "*.s")) +
               glob.glob(os.path.join(ROOT, "programs", "random", "*.s")))
for path in progs:
    name = os.path.relpath(path, os.path.join(ROOT, "programs"))
    words = iss.read_program(path)
    m = iss.Machine(words).run()
    b = SimBoard()
    b.load(words)
    d = b.run(max_seconds=30)
    exp_mem = sorted({(ad >> 2) & 0x3FF for _, ad, _ in m.store_trace})
    ok = (d.done and d.cycles == m.cycles and list(d.regs) == m.regs
          and d.mem == [(i * 4, m.dmem[i]) for i in exp_mem]
          and b.cpu.reg_trace == m.reg_trace and b.cpu.store_trace == m.store_trace
          and b.read_program() == words)
    check(ok, f"{name:22} {d.cycles:6} ciclos (ISS {m.cycles}), registros, memoria y trazas")

# --- 2a. estado inicial: como la placa recien programada --------------------
b = SimBoard()
d = b.dump()
check(d.pc == 0 and d.cycles == 0 and not d.done and d.regs == [0] * 32 and d.mem == [],
      "inicio: PC 0, ciclos 0, registros en 0, sin memoria usada")
check(d.latch_words[3] == 0 and d.latch_words[2] == NOP, "inicio: IF/ID invalido (ID ve un NOP)")
check(b.cpu.imem[0] == 0xC0DE0000 and b.cpu.dmem[10] == 10,
      "inicio: memorias con el contenido de los .coe")
check(b.read_program() == [], "inicio: 'I' sin programa cargado devuelve 0 palabras")

# --- 2b. paso a paso == continuo -------------------------------------------
w = words_of("forwarding")
b1, b2 = SimBoard(), SimBoard()
b1.load(w)
b2.load(w)
d1 = b1.run()
n = 0
while not b2.dump().done:
    d2 = b2.step()
    n += 1
check(n == d1.cycles and d2.raw == d1.raw and d2.mem == d1.mem,
      f"forwarding: {n} pasos dan el mismo volcado que correr")
d3 = b2.step()
check(d3.cycles == d2.cycles and d3.raw == d2.raw, "terminado: 'S' no ejecuta nada")

# --- 2c. HALT: pipeline vacio ----------------------------------------------
lw = d1.latch_words
check(lw[3] == 0, "HALT: IF/ID invalido")
check(lw[9] & 0x1F9 == 0, "HALT: ID/EX sin bits de efecto (burbuja)")
check(lw[12] & 0x039 == 0, "HALT: EX/MEM sin bits de efecto")
check(d1.latches["MEM/WB"]["halt"] == 1, "HALT: el ebreak esta en MEM/WB (program_done)")

# --- 2d. stall load-use: el PC se repite un paso ---------------------------
b = SimBoard()
b.load([0x02802283,            # lw   x5, 40(x0)
        0x00128313,            # addi x6, x5, 1   <- usa x5: load-use
        0x00100073])           # ebreak
pcs = [b.step().pc for _ in range(4)]
check(pcs == [4, 8, 8, 12], f"load-use: PC {pcs} (se queda en 8 un ciclo)")
d = b.run()
check(d.regs[5] == 10 and d.regs[6] == 11, "load-use: x5 = 10 (palabra 10), x6 = 11")
check(d.cycles == 3 + 3 + 1, f"load-use: {d.cycles} ciclos = 3 instr + 3 + 1 stall")

# --- 2e. flush de un salto tomado ------------------------------------------
b = SimBoard()
b.load([0x0080006F,            # 0x0: jal  x0, 8   -> salta a 0x8
        0x00100093,            # 0x4: addi x1, x0, 1   (camino equivocado)
        0x00200113,            # 0x8: addi x2, x0, 2
        0x00100073])           # 0xc: ebreak
b.step()                                       # jal en IF/ID
b.step()                                       # jal en ID/EX, addi x1 en IF/ID
d = b.step()                                   # jal en EX: salta y descarta
check(d.pc == 8 and d.latch_words[3] == 0, "salto: PC = destino e IF/ID descartado")
check(d.latch_words[9] & 0x1F9 == 0, "salto: ID/EX en burbuja (flush)")
d = b.run()
check(d.regs[1] == 0 and d.regs[2] == 2, "salto: addi x1 no se ejecuto, addi x2 si")
check(d.cycles == 3 + 3 + 2, f"salto: {d.cycles} ciclos = 3 instr + 3 + 2 de flush")

# --- 2f. reset y carga: que se borra y que no -------------------------------
b = SimBoard()
b.load(words_of("memoria"))
d = b.run()
used = d.mem
b.reset()
d = b.dump()
check(d.pc == 0 and d.cycles == 0 and d.regs == [0] * 32, "'R': PC, ciclos y registros a 0")
check(d.mem == used and used, "'R': la memoria de datos y el bitmap se conservan")
b.load([0x00100073])
d = b.dump()
check(d.mem == [] and b.cpu.dmem[used[0][0] // 4] == used[0][1],
      "'L': borra el bitmap pero NO la memoria de datos")
d = b.run()
check(d.done and d.cycles == 4, "un programa de solo ebreak tarda 4 ciclos")

# --- 2g. la GUI entiende el volcado ----------------------------------------
b = SimBoard()
b.load(words_of("jumps"))
for _ in range(3):
    d = b.step()
check(gm.stage_marks(d) == {12: "IF", 8: "ID", 4: "EX"}, "GUI: marca IF/ID/EX en 12/8/4")

# --- 2h. pausa de un programa que no termina --------------------------------
b = SimBoard()
b.load([0x0000006F])           # jal x0, 0: lazo infinito
d = b.run_until(lambda: True)
check(not d.done and d.cycles > 0, f"lazo infinito: Pausa lo frena (ciclo {d.cycles})")

print()
print(f"TEST {'PASSED' if errors == 0 else 'FAILED'}: {checks} checks, {errors} errors")
sys.exit(1 if errors else 0)
