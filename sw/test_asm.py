#!/usr/bin/env python3
"""Tests del ensamblador (sw/asm.py).

Correr:  python sw/test_asm.py

1. Codificaciones conocidas: las mismas palabras que usan los testbenches de
   Verilog y codificaciones de referencia de RISC-V.
2. Ida y vuelta: miles de instrucciones con operandos aleatorios (incluidos
   los bordes de cada inmediato) se ensamblan, se desensamblan y se vuelven a
   ensamblar: tiene que dar la misma palabra.
3. Etiquetas, pseudo-instrucciones, halt automatico y archivos de salida.
4. Errores: cada programa invalido tiene que fallar con el mensaje correcto.
"""

import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm  # noqa: E402


def words(src):
    """Ensambla y devuelve solo las palabras (sin el halt agregado al final)."""
    prog = asm.assemble(src)
    if prog[-1][3].startswith("halt   # agregado"):
        prog = prog[:-1]
    return [w for _, w, _, _ in prog]


def one(src):
    w = words(src)
    assert len(w) == 1, w
    return w[0]


class Conocidas(unittest.TestCase):
    """Palabras verificadas a mano o tomadas de los testbenches de Verilog."""

    CASOS = [
        # instruccion                   palabra       de donde sale
        ("add  x3, x1, x2",            0x002081B3),  # id_stage_tb
        ("lw   x5, 8(x1)",             0x0080A283),  # id_stage_tb
        ("add  x6, x5, x2",            0x00228333),  # id_stage_tb
        ("sw   x2, -4(x1)",            0xFE20AE23),  # id_stage_tb
        ("addi x9, x7, 1",             0x00138493),  # id_stage_tb
        ("lui  x8, 0x12345",           0x12345437),  # id_stage_tb
        ("jal  x1, 8",                 0x008000EF),  # id_stage_tb
        ("halt",                       0x00100073),  # ebreak
        ("ebreak",                     0x00100073),
        ("nop",                        0x00000013),  # addi x0, x0, 0
        ("jal  x0, -4",                0xFFDFF06F),  # imm_gen_tb (J negativo)
        ("beq  x0, x0, -4",            0xFE000EE3),  # imm_gen_tb (B negativo)
        ("beq  x0, x0, 0",             0x00000063),
        ("ret",                        0x00008067),  # jalr x0, 0(ra)
        ("sub  x1, x2, x3",            0x403100B3),
        ("srai x1, x2, 3",             0x40315093),
        ("srli x1, x2, 3",             0x00315093),
        ("slli x1, x2, 31",            0x01F11093),
        ("lbu  x1, -1(x2)",            0xFFF14083),
        ("addi a0, zero, -1",          0xFFF00513),  # nombres ABI
        ("sltu t0, t1, t2",            0x007332B3),
        ("sb   a1, 3(sp)",             0x00B101A3),
        ("sh   a1, 2(sp)",             0x00B11123),
        ("bne  x1, x2, 16",            0x00209863),
        ("jalr ra, 0(t0)",             0x000280E7),
        ("jalr t0",                    0x000280E7),  # forma corta: rd = ra
    ]

    def test_conocidas(self):
        for src, esperada in self.CASOS:
            with self.subTest(src=src):
                self.assertEqual(one(src), esperada, f"{src}: {one(src):08x}")


class IdaYVuelta(unittest.TestCase):
    """asm -> disasm -> asm tiene que dar la misma palabra."""

    def test_aleatorio(self):
        rnd = random.Random(2026)
        r = lambda: rnd.randrange(32)
        imm12 = lambda: rnd.choice([-2048, -1, 0, 1, 2047, rnd.randint(-2048, 2047)])
        casos = []
        for _ in range(300):
            for mn in asm.R_OPS:
                casos.append(f"{mn} x{r()}, x{r()}, x{r()}")
            for mn in asm.I_OPS:
                casos.append(f"{mn} x{r()}, x{r()}, {imm12()}")
            for mn in asm.SH_OPS:
                casos.append(f"{mn} x{r()}, x{r()}, {rnd.choice([0, 31, rnd.randint(0, 31)])}")
            for mn in asm.LOAD_OPS:
                casos.append(f"{mn} x{r()}, {imm12()}(x{r()})")
            for mn in asm.STORE_OPS:
                casos.append(f"{mn} x{r()}, {imm12()}(x{r()})")
            for mn in asm.BRANCH_OPS:
                off = rnd.choice([-4096, -2, 0, 2, 4094, 2 * rnd.randint(-2048, 2047)])
                casos.append(f"{mn} x{r()}, x{r()}, {off}")
            off = rnd.choice([-2**20, -2, 0, 2, 2**20 - 2, 2 * rnd.randint(-2**19, 2**19 - 1)])
            casos.append(f"jal x{r()}, {off}")
            casos.append(f"jalr x{r()}, {imm12()}(x{r()})")
            casos.append(f"lui x{r()}, {rnd.choice([0, 0xFFFFF, rnd.randint(0, 0xFFFFF)])}")
        for src in casos:
            w = one(src)
            texto = asm.disasm(w)
            self.assertFalse(texto.startswith(".word"), f"{src} -> {texto}")
            self.assertEqual(one(texto), w, f"{src} -> {w:08x} -> {texto}")
        print(f"\n  ida y vuelta: {len(casos)} instrucciones")


class Etiquetas(unittest.TestCase):

    def test_adelante_y_atras(self):
        src = """
        inicio: addi x1, x0, 3      # 0x00
        loop:   addi x1, x1, -1     # 0x04
                bne  x1, x0, loop   # 0x08 -> offset -4
                beq  x0, x0, fin    # 0x0c -> offset +12
                nop                 # 0x10
                nop                 # 0x14
        fin:    jal  ra, inicio     # 0x18 -> offset -24
                j    fin            # 0x1c -> offset -4
        """
        w = words(src)
        self.assertEqual(asm.disasm(w[2]), "bne x1, x0, -4")
        self.assertEqual(asm.disasm(w[3]), "beq x0, x0, 12")
        self.assertEqual(asm.disasm(w[6]), "jal x1, -24")
        self.assertEqual(asm.disasm(w[7]), "jal x0, -4")

    def test_etiqueta_sola_en_su_linea(self):
        w = words("a:\nb:\n  j a\n")
        self.assertEqual(asm.disasm(w[0]), "jal x0, 0")

    def test_direcciones_con_li_de_dos_palabras(self):
        # li grande ocupa 2 palabras: la etiqueta de despues tiene que correrse
        w = words("li x1, 0x12345678\nfin: j fin\n")
        self.assertEqual(len(w), 3)
        self.assertEqual(asm.disasm(w[2]), "jal x0, 0")


class Pseudo(unittest.TestCase):

    def test_pseudo(self):
        self.assertEqual(asm.disasm(one("mv t0, t1")), "addi x5, x6, 0")
        self.assertEqual(asm.disasm(one("not x1, x2")), "xori x1, x2, -1")
        self.assertEqual(asm.disasm(one("neg x1, x2")), "sub x1, x0, x2")
        self.assertEqual(asm.disasm(one("li x1, -5")), "addi x1, x0, -5")

    def test_li_grande(self):
        self.assertEqual(words("li a0, 0x12345678"), [0x12345537, 0x67850513])
        # parte baja con el bit 11 en 1: la parte alta se corrige en +1
        w = words("li a0, 0x12345FFF")
        self.assertEqual([asm.disasm(x) for x in w], ["lui x10, 0x12346", "addi x10, x10, -1"])
        # parte baja = 0: un solo lui
        self.assertEqual(words("li a0, 0x10000"), [0x00010537])
        # todos los li tienen que dar el valor pedido (simulando lui + addi)
        rnd = random.Random(1)
        for v in [0, 2047, 2048, -2049, 0x7FFFFFFF, -2**31, 0xFFFFFFFF, 0x800, 0xFFFFF800] + \
                 [rnd.randint(-2**31, 2**32 - 1) for _ in range(2000)]:
            reg = 0
            for x in words(f"li x1, {v}"):
                t = asm.disasm(x)
                if t.startswith("lui"):
                    reg = int(t.split(",")[1], 16) << 12
                elif t.startswith("addi x1, x0"):
                    reg = int(t.split(",")[2])
                else:
                    reg = reg + int(t.split(",")[2])
            self.assertEqual(reg & 0xFFFFFFFF, v & 0xFFFFFFFF, f"li {v:#x}")


class Halt(unittest.TestCase):

    def test_halt_agregado(self):
        prog = asm.assemble("addi x1, x0, 1")
        self.assertEqual(len(prog), 2)
        self.assertEqual(prog[-1][1], asm.EBREAK)
        self.assertEqual(prog[-1][0], 4)

    def test_halt_no_duplicado(self):
        prog = asm.assemble("addi x1, x0, 1\nhalt")
        self.assertEqual(len(prog), 2)

    def test_programa_vacio(self):
        prog = asm.assemble("# solo comentarios\n\n")
        self.assertEqual([w for _, w, _, _ in prog], [asm.EBREAK])


class Errores(unittest.TestCase):

    CASOS = [
        ("addi x1, x0, 5000",      "fuera de rango"),
        ("addi x1, x0, -2049",     "fuera de rango"),
        ("add x1, x2, x32",        "registro invalido"),
        ("add x1, x2",             "espera 3 operando"),
        ("slli x1, x2, 32",        "fuera de rango"),
        ("lw x1, 4096(x2)",        "fuera de rango"),
        ("lw x1, x2",              "desplazamiento(registro)"),
        ("beq x1, x2, nada",       "no definida"),
        ("beq x1, x2, 3",          "impar"),
        ("beq x1, x2, 4096",       "fuera de rango"),
        ("mul x1, x2, x3",         "no soportada"),
        ("a: nop\na: nop",         "dos veces"),
        ("addi x1, x0, cinco",     "numero invalido"),
        ("lui x1, 0x100000",       "fuera de rango"),
    ]

    def test_errores(self):
        for src, msg in self.CASOS:
            with self.subTest(src=src):
                with self.assertRaises(asm.AsmError) as ctx:
                    asm.assemble(src)
                self.assertIn(msg, ctx.exception.msg)

    def test_numero_de_linea(self):
        with self.assertRaises(asm.AsmError) as ctx:
            asm.assemble("nop\nnop\nadd x1, x2, x99\n")
        self.assertEqual(ctx.exception.line, 3)

    def test_programa_demasiado_grande(self):
        with self.assertRaises(asm.AsmError):
            asm.assemble("nop\n" * 1025)


class Salidas(unittest.TestCase):

    def test_archivos(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "p.s")
            with open(src, "w") as f:
                f.write("addi x1, x0, 1\nsw x1, 0(x0)\n")
            self.assertEqual(asm.main([src, "--coe"]), 0)
            with open(os.path.join(d, "p.hex")) as f:
                self.assertEqual(f.read().split(), ["00100093", "00102023", "00100073"])
            with open(os.path.join(d, "p.bin"), "rb") as f:
                b = f.read()
            self.assertEqual(len(b), 12)
            self.assertEqual(b[:4], bytes([0x93, 0x00, 0x10, 0x00]))   # little-endian
            self.assertTrue(os.path.exists(os.path.join(d, "p.lst")))
            self.assertTrue(os.path.exists(os.path.join(d, "p.coe")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
