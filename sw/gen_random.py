#!/usr/bin/env python3
"""Generador de programas aleatorios para estresar el pipeline.

Uso:
    python sw/gen_random.py [--cant 20] [--largo 200] [--semilla 1] [--dir programs/random]
        -> programs/random/random_00.s ... random_19.s

La idea: muchas instrucciones al azar que usan POCOS registros (9), asi casi
todas dependen de alguna de las 1-3 anteriores. Eso genera todas las
combinaciones de riesgos que un programa escrito a mano no cubre:
forwarding desde EX/MEM y MEM/WB por rs1 y rs2, load-use, dato de store
forwardeado, saltos que dependen de resultados recien calculados, PC+4 de
jal/jalr forwardeado, saltos seguidos, etc.

Despues cada programa se corre en el modelo de referencia (sw/iss.py) y en
el pipeline (cpu_top_tb.v), y tienen que terminar igual.

Reglas para que el programa siempre termine y sea valido:
    - solo saltos HACIA ADELANTE (no hay lazos): siempre llega al halt
    - gp (x3) apunta a 0x400 y nunca se escribe: base de loads/stores, con
      desplazamientos alineados al ancho del acceso (no hay desalineados)
    - jalr con un patron fijo:  jal rX, L  /  L: jalr rY, 8 o 9(rX)
      (salta a L + 8, saltea la instruccion de abajo; con 9 prueba el &~1)
Las semillas son fijas: el mismo comando genera siempre los mismos programas.
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm  # noqa: E402

POOL = [1, 2, 4, 5, 6, 7, 8, 9, 10]      # registros que se usan (no x3 = gp)
GP_BASE = 0x400


def gen_program(rnd, largo):
    reg = lambda: f"x{rnd.choice(POOL)}"
    src = lambda: f"x{rnd.choice(POOL + [0])}"           # a veces x0
    dst = lambda: "x0" if rnd.random() < 0.04 else reg()  # a veces escribe x0

    lines = [f"# programa aleatorio (sw/gen_random.py)", f"        li    x3, {GP_BASE:#x}"]
    for r in POOL:
        v = rnd.choice([rnd.randint(-2**31, 2**31 - 1), rnd.randint(-16, 16),
                        rnd.randint(0, 255), 0x80000000, -1])
        lines.append(f"        li    x{r}, {v}")

    body = []          # (texto, cantidad de elementos que hay que garantizar despues)
    targets = []       # (indice del elemento destino, nombre de etiqueta)
    own = set()        # etiquetas de los patrones jal/jalr
    n_lab = 0

    def label_at(k):
        nonlocal n_lab
        name = f"L{n_lab}"
        n_lab += 1
        targets.append((k, name))
        return name

    while len(body) < largo:
        i = len(body)
        p = rnd.random()
        if p < 0.25:
            mn = rnd.choice(list(asm.R_OPS))
            body.append(f"{mn:5} {dst()}, {src()}, {src()}")
        elif p < 0.42:
            mn = rnd.choice(list(asm.I_OPS))
            imm = rnd.choice([rnd.randint(-2048, 2047), rnd.randint(-8, 8)])
            body.append(f"{mn:5} {dst()}, {src()}, {imm}")
        elif p < 0.50:
            mn = rnd.choice(list(asm.SH_OPS))
            body.append(f"{mn:5} {dst()}, {src()}, {rnd.randint(0, 31)}")
        elif p < 0.53:
            body.append(f"lui   {dst()}, {rnd.randint(0, 0xFFFFF):#x}")
        elif p < 0.65:
            mn = rnd.choice(list(asm.LOAD_OPS))
            size = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}[mn]
            if rnd.random() < 0.7:
                off = size * rnd.randint(-256 // size, 252 // size)
                body.append(f"{mn:5} {dst()}, {off}(x3)")
            else:
                off = size * rnd.randint(0, 2044 // size)
                body.append(f"{mn:5} {dst()}, {off}(x0)")
            if rnd.random() < 0.5:   # forzar un load-use
                rd = body[-1].split()[1].rstrip(",")
                body.append(f"add   {dst()}, {rd}, {src()}")
        elif p < 0.75:
            mn = rnd.choice(list(asm.STORE_OPS))
            size = {"sb": 1, "sh": 2, "sw": 4}[mn]
            off = size * rnd.randint(-256 // size, 252 // size)
            body.append(f"{mn:5} {src()}, {off}(x3)")
        elif p < 0.88:
            mn = rnd.choice(list(asm.BRANCH_OPS))
            a, b = src(), src()
            if rnd.random() < 0.2:
                b = a                                    # beq tomado / bne no tomado
            body.append(f"{mn:5} {a}, {b}, {label_at(i + 1 + rnd.randint(0, 3))}")
        elif p < 0.91:
            body.append(f"jal   {dst()}, {label_at(i + 1 + rnd.randint(0, 3))}")
        elif p < 0.95:
            # prioridad del forwarding: el mismo registro en EX/MEM y en MEM/WB
            # con valores distintos; tiene que ganar el mas nuevo (EX/MEM)
            r = reg()
            body.append(f"addi  {r}, {src()}, {rnd.randint(-2048, 2047)}")
            body.append(f"addi  {r}, {src()}, {rnd.randint(-2048, 2047)}")
            body.append(f"{rnd.choice(list(asm.R_OPS)):5} {dst()}, " +
                        (f"{r}, {src()}" if rnd.random() < 0.5 else f"{src()}, {r}"))
        elif i < largo - 4:
            rx = reg()
            name = label_at(i + 1)
            own.add(name)
            body.append(f"jal   {rx}, {name}")
            body.append(f"jalr  {dst()}, {rnd.choice([8, 9])}({rx})")
            body.append(f"addi  x{rnd.choice(POOL)}, x0, 0x7AD   # salteada por el jalr")

    by_index = {}
    for k, name in targets:
        k = min(k, len(body))
        # un salto que cae sobre el jalr del patron lo ejecutaria sin el jal
        # de antes (rX tendria cualquier valor): se corre a la siguiente
        if k < len(body) and body[k].startswith("jalr") and not name == f"L{n_lab - 1}" \
                and not body[k - 1].endswith(name):
            k += 1
        by_index.setdefault(k, []).append(name)
    for k, text in enumerate(body + ["halt"]):
        labs = "".join(f"{n}:\n" for n in by_index.get(k, []))
        lines.append(f"{labs}        {text}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Genera programas aleatorios para el pipeline")
    ap.add_argument("--cant", type=int, default=20)
    ap.add_argument("--largo", type=int, default=200)
    ap.add_argument("--semilla", type=int, default=1)
    ap.add_argument("--dir", default=os.path.join("programs", "random"))
    args = ap.parse_args(argv)
    os.makedirs(args.dir, exist_ok=True)
    for n in range(args.cant):
        rnd = random.Random(args.semilla * 1000 + n)
        path = os.path.join(args.dir, f"random_{n:02d}.s")
        with open(path, "w") as f:
            f.write(gen_program(rnd, args.largo))
    print(f"{args.cant} programas de {args.largo} instrucciones en {args.dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
