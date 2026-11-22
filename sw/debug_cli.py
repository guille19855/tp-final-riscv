"""CLI minima para la Debug Unit (Fase 8): probar la placa sin la interfaz
grafica (esa es la Fase 9).

Uso (el puerto lo muestra "puertos"; en Windows es COMx):
    python sw/debug_cli.py puertos
    python sw/debug_cli.py -p COM5 cargar programs/ejemplo.hex
    python sw/debug_cli.py -p COM5 correr
    python sw/debug_cli.py -p COM5 paso [n]
    python sw/debug_cli.py -p COM5 volcado
    python sw/debug_cli.py -p COM5 reset
    python sw/debug_cli.py -p COM5 programa
    python sw/debug_cli.py -p COM5 verificar programs/ejemplo programs/alu ...

"verificar" es la prueba automatica en la placa: por cada programa (tiene que
existir el .hex) lo carga, relee el programa con 'I', lo corre en continuo y
compara ciclos, los 32 registros y la memoria usada contra el ISS (sw/iss.py).
Es lo mismo que hace tb/top/top_core_tb.v en simulacion, pero en el hardware
real. Como la memoria de datos no se borra entre programas, el ISS arranca de
la memoria recien programada y la va encadenando: correrlo despues de hacer
Program Device.
"""

import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from du_protocol import DebugUnit, DebugUnitError, read_hex, ABI  # noqa: E402
import iss  # noqa: E402


def cmd_puertos(_args):
    from serial.tools import list_ports
    ports = list(list_ports.comports())
    if not ports:
        print("No hay puertos serie. Esta conectada la placa?")
    for p in ports:
        print(f"{p.device:8} {p.description}")


def verificar(du, base, dmem):
    """Carga, corre y compara un programa. Devuelve (ok, texto, errores).

    La memoria de datos de la placa NO se reinicia entre programas (indicacion
    del profesor: no hace falta borrarla al reprogramar), asi que el .exp (que
    supone la memoria recien inicializada en 0..N) no sirve a partir del segundo
    programa. El valor esperado lo calcula el ISS partiendo de 'dmem', el modelo
    de lo que hay en la memoria de la placa, que se actualiza al final."""
    words = read_hex(base + ".hex")
    m = iss.Machine(words)
    m.dmem = list(dmem)
    m.run()
    regs, mem, instret, cycles = m.regs, m.dmem, m.instret, m.cycles
    used = {(ad >> 2) & 0x3FF for _, ad, _ in m.store_trace}
    dmem[:] = m.dmem                      # asi queda la memoria de la placa
    errs = []

    du.load(words)
    if du.read_program() != words:
        errs.append("el programa releido con 'I' no coincide")
    d = du.run()
    if not d.done:
        errs.append(f"no termino (PC = {d.pc:08x})")
    if d.cycles != cycles:
        errs.append(f"ciclos {d.cycles}, esperaba {cycles}")
    for i in range(32):
        if d.regs[i] != regs[i]:
            errs.append(f"x{i} ({ABI[i]}) = {d.regs[i]:08x}, esperaba {regs[i]:08x}")
    exp_mem = [(i * 4, mem[i]) for i in sorted(used)]
    if d.mem != exp_mem:
        errs.append(f"memoria usada: {len(d.mem)} palabras, esperaba {len(exp_mem)}"
                    + ("" if len(d.mem) != len(exp_mem) else " (distintos datos)"))
    info = f"{d.cycles:6} ciclos {instret:6} instr  CPI {d.cycles / instret:5.3f}"
    return (not errs), info, errs


def main():
    ap = argparse.ArgumentParser(description="CLI de la Debug Unit (TP Final RISC-V)")
    ap.add_argument("-p", "--port", help="puerto serie (ej. COM5)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("puertos")
    c = sub.add_parser("cargar");    c.add_argument("hex")
    sub.add_parser("correr")
    c = sub.add_parser("paso");      c.add_argument("n", nargs="?", type=int, default=1)
    sub.add_parser("volcado")
    sub.add_parser("reset")
    sub.add_parser("programa")
    c = sub.add_parser("verificar"); c.add_argument("programas", nargs="+")
    args = ap.parse_args()

    if args.cmd == "puertos":
        return cmd_puertos(args)
    if not args.port:
        ap.error("falta -p PUERTO (ver: python sw/debug_cli.py puertos)")

    du = DebugUnit(args.port)
    try:
        if args.cmd == "cargar":
            w = read_hex(args.hex)
            du.load(w)
            print(f"Cargadas {len(w)} palabras. CPU en PC = 0, listo para 'correr' o 'paso'.")
        elif args.cmd == "correr":
            print(du.run())
        elif args.cmd == "paso":
            for _ in range(args.n):
                d = du.step()
            print(d)
        elif args.cmd == "volcado":
            print(du.dump())
        elif args.cmd == "reset":
            du.reset()
            print("CPU reseteado (PC = 0, ciclos = 0).")
        elif args.cmd == "programa":
            for i, w in enumerate(du.read_program()):
                print(f"{i * 4:08x}  {w:08x}")
        elif args.cmd == "verificar":
            progs = []
            for p in args.programas:            # acepta comodines: programs/random/*
                progs += sorted(glob.glob(p)) if any(ch in p for ch in "*?") else [p]
            bases = sorted({os.path.splitext(p)[0] for p in progs})
            print("Supone la memoria de datos como recien programada la FPGA (0..N);")
            print("si ya corriste programas, volve a hacer Program Device antes.\n")
            dmem = list(range(iss.DMEM_WORDS))
            fails = 0
            for base in bases:
                ok, info, errs = verificar(du, base, dmem)
                print(f"{os.path.basename(base):24} {info}  {'OK' if ok else 'FALLO'}")
                for e in errs[:8]:
                    print("    " + e)
                fails += not ok
            print()
            print("TODOS LOS PROGRAMAS PASARON EN LA PLACA" if fails == 0
                  else f"{fails} PROGRAMA(S) FALLARON")
            return 1 if fails else 0
    except DebugUnitError as e:
        print("ERROR:", e)
        return 1
    finally:
        du.close()


if __name__ == "__main__":
    sys.exit(main() or 0)
