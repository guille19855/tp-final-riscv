"""Protocolo de la Debug Unit (Fase 8) del lado de la PC.

Es la contraparte de rtl/debug/debug_unit.v: misma tabla de comandos y mismo
formato de volcado. La CLI (debug_cli.py) y la interfaz grafica (Fase 9) usan
este modulo; ninguna de las dos habla con el puerto serie directamente.

Comandos (1 byte) y respuestas:
    'L' N0 N1 + N palabras  -> 'K'      cargar programa (CPU en reset mientras)
    'R'                     -> 'K'      reset del CPU
    'C'                     -> volcado  continuo hasta HALT (un byte lo pausa)
    'S'                     -> volcado  un ciclo
    'D'                     -> volcado  sin ejecutar
    'I'                     -> 'I' N + N palabras   programa cargado
    otro                    -> '?'
Palabras de 32 bits little-endian.

Volcado: 'D' + 51 palabras + pares (direccion, dato) + 0xFFFFFFFF
    0 PC   1 ciclos   2 estado (bit 0 = program_done)
    3..34 registros x0..x31   35..50 latches (tabla de rtl/cpu/cpu_top.v)
"""

import struct

BAUD = 115200
N_FIX = 51
END_MARK = 0xFFFFFFFF

ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
       "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5",
       "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]

WB_SEL = {0: "ALU", 1: "MEM", 2: "PC4", 3: "?"}


class DebugUnitError(Exception):
    pass


# ---------------------------------------------------------------------------
# Decodificacion de los latches (misma tabla que rtl/cpu/cpu_top.v)
# ---------------------------------------------------------------------------
def _bits(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def decode_latches(w):
    """w: las 16 palabras de latches -> dict {latch: {campo: valor}}"""
    c_idex, c_exmem, c_memwb = w[9], w[12], w[15]
    return {
        "IF/ID": {
            "pc": w[0], "pc4": w[1], "instr": w[2], "valid": w[3] & 1,
        },
        "ID/EX": {
            "pc": w[4], "pc4": w[5], "rs1_data": w[6], "rs2_data": w[7], "imm": w[8],
            "rs1": _bits(c_idex, 31, 27), "rs2": _bits(c_idex, 26, 22),
            "rd": _bits(c_idex, 21, 17), "funct3": _bits(c_idex, 16, 14),
            "funct7b5": _bits(c_idex, 13, 13),
            "alu_src_a": _bits(c_idex, 12, 12), "alu_src_b": _bits(c_idex, 11, 11),
            "alu_op": _bits(c_idex, 10, 9),
            "branch": _bits(c_idex, 8, 8), "jal": _bits(c_idex, 7, 7),
            "jalr": _bits(c_idex, 6, 6),
            "mem_read": _bits(c_idex, 5, 5), "mem_write": _bits(c_idex, 4, 4),
            "reg_write": _bits(c_idex, 3, 3), "wb_sel": _bits(c_idex, 2, 1),
            "halt": _bits(c_idex, 0, 0),
        },
        "EX/MEM": {
            "result": w[10], "rs2_data": w[11],
            "rd": _bits(c_exmem, 13, 9), "funct3": _bits(c_exmem, 8, 6),
            "mem_read": _bits(c_exmem, 5, 5), "mem_write": _bits(c_exmem, 4, 4),
            "reg_write": _bits(c_exmem, 3, 3), "wb_sel": _bits(c_exmem, 2, 1),
            "halt": _bits(c_exmem, 0, 0),
        },
        "MEM/WB": {
            "result": w[13], "read_data": w[14],
            "rd": _bits(c_memwb, 14, 10), "funct3": _bits(c_memwb, 9, 7),
            "addr_lo": _bits(c_memwb, 6, 5),
            "mem_read": _bits(c_memwb, 4, 4), "reg_write": _bits(c_memwb, 3, 3),
            "wb_sel": _bits(c_memwb, 2, 1), "halt": _bits(c_memwb, 0, 0),
        },
    }


class Dump:
    """Un volcado de la Debug Unit, ya decodificado."""

    def __init__(self, words, mem):
        self.raw = words
        self.pc = words[0]
        self.cycles = words[1]
        self.done = bool(words[2] & 1)
        self.regs = words[3:35]
        self.latch_words = words[35:51]
        self.latches = decode_latches(self.latch_words)
        self.mem = mem                    # [(direccion en bytes, dato)]

    def __str__(self):
        out = [f"PC = 0x{self.pc:08x}   ciclos = {self.cycles}   "
               f"{'TERMINADO (HALT)' if self.done else 'corriendo / en pausa'}",
               "", "Registros:"]
        for r in range(0, 32, 4):
            out.append("  " + "   ".join(
                f"x{i:<2} {ABI[i]:>4} = {self.regs[i]:08x}" for i in range(r, r + 4)))
        out.append("")
        out.append("Latches:")
        for latch, fields in self.latches.items():
            parts = []
            for k, v in fields.items():
                if k == "wb_sel":
                    parts.append(f"{k}={WB_SEL[v]}")
                elif v > 0xFFFF or k in ("pc", "pc4", "instr", "result", "rs1_data",
                                         "rs2_data", "imm", "read_data"):
                    parts.append(f"{k}={v:08x}")
                else:
                    parts.append(f"{k}={v}")
            out.append(f"  {latch:7} " + " ".join(parts))
        out.append("")
        if self.mem:
            out.append(f"Memoria de datos usada ({len(self.mem)} palabras):")
            for a, d in self.mem:
                out.append(f"  [0x{a:03x}] = {d:08x}  ({d if d < 0x80000000 else d - (1 << 32)})")
        else:
            out.append("Memoria de datos usada: ninguna")
        return "\n".join(out)


# ---------------------------------------------------------------------------
# Lectura de respuestas (funciona con cualquier objeto con .read(n))
# ---------------------------------------------------------------------------
def _read_exact(port, n):
    data = port.read(n)
    if len(data) != n:
        raise DebugUnitError(f"timeout: esperaba {n} bytes, llegaron {len(data)}")
    return data


def _read_word(port):
    return struct.unpack("<I", _read_exact(port, 4))[0]


def read_dump_body(port):
    """Lee lo que sigue a la cabecera 'D'."""
    words = list(struct.unpack(f"<{N_FIX}I", _read_exact(port, 4 * N_FIX)))
    mem = []
    while True:
        a = _read_word(port)
        if a == END_MARK:
            break
        if len(mem) >= 1024:
            raise DebugUnitError("volcado: mas de 1024 palabras de memoria")
        mem.append((a, _read_word(port)))
    return Dump(words, mem)


def read_response(port):
    """Lee UNA respuesta completa, segun su byte de cabecera.
    Devuelve ('K', None) / ('?', None) / ('D', Dump) / ('I', [palabras])."""
    h = _read_exact(port, 1)
    if h == b"K":
        return "K", None
    if h == b"?":
        return "?", None
    if h == b"D":
        return "D", read_dump_body(port)
    if h == b"I":
        n = _read_word(port)
        return "I", [_read_word(port) for _ in range(n)]
    raise DebugUnitError(f"cabecera desconocida: {h!r}")


# ---------------------------------------------------------------------------
# Conexion con la placa
# ---------------------------------------------------------------------------
class DebugUnit:
    def __init__(self, port_name, baud=BAUD, timeout=3.0):
        import serial                     # pyserial (pip install pyserial)
        self.ser = serial.Serial(port_name, baud, timeout=timeout)
        self.ser.reset_input_buffer()

    def close(self):
        self.ser.close()

    def _expect(self, kind):
        k, v = read_response(self.ser)
        if k != kind:
            raise DebugUnitError(f"esperaba respuesta '{kind}', llego '{k}'")
        return v

    def load(self, words):
        if not 0 < len(words) <= 1024:
            raise DebugUnitError("el programa tiene que tener entre 1 y 1024 palabras")
        n = len(words)
        self.ser.write(b"L" + struct.pack("<H", n) + struct.pack(f"<{n}I", *words))
        self._expect("K")

    def reset(self):
        self.ser.write(b"R")
        self._expect("K")

    def step(self):
        self.ser.write(b"S")
        return self._expect("D")

    def dump(self):
        self.ser.write(b"D")
        return self._expect("D")

    def run(self, max_seconds=10.0):
        """Continuo hasta HALT. Si no termina en max_seconds, lo pausa."""
        old = self.ser.timeout
        self.ser.timeout = max_seconds
        self.ser.write(b"C")
        h = self.ser.read(1)
        self.ser.timeout = old
        if h == b"":                       # no termino: pausar con un byte
            self.ser.write(b"P")
            h = _read_exact(self.ser, 1)
        if h != b"D":
            raise DebugUnitError(f"esperaba volcado, llego {h!r}")
        return read_dump_body(self.ser)

    def run_until(self, pause_requested, poll=0.1):
        """Continuo hasta HALT o hasta que pause_requested() devuelva True
        (la GUI lo llama desde otro hilo: boton Pausa). Devuelve el volcado."""
        old = self.ser.timeout
        self.ser.timeout = poll
        try:
            self.ser.write(b"C")
            paused = False
            while True:
                h = self.ser.read(1)
                if h:
                    break
                if not paused and pause_requested():
                    self.ser.write(b"P")       # cualquier byte pausa el continuo
                    paused = True
        finally:
            self.ser.timeout = old
        if h != b"D":
            raise DebugUnitError(f"esperaba volcado, llego {h!r}")
        d = read_dump_body(self.ser)
        if paused:
            # Carrera: si el programa llego a HALT justo antes de que llegara la
            # 'P', la Debug Unit ya estaba en IDLE y la tomo como comando
            # invalido -> responde '?'. Se descarta para no ensuciar la proxima.
            self.ser.timeout = 0.05
            self.ser.read(1)
            self.ser.timeout = old
        return d

    def read_program(self):
        self.ser.write(b"I")
        return self._expect("I")


# ---------------------------------------------------------------------------
# Archivos de programs/ (los genera asm.py e iss.py)
# ---------------------------------------------------------------------------
def read_hex(path):
    with open(path) as f:
        return [int(line, 16) for line in f if line.strip()]


def read_exp(path):
    """-> (regs[32], mem[1024], instret, cycles)"""
    v = read_hex(path)
    return v[0:32], v[32:1056], v[1056], v[1057]


def read_sto(path):
    """-> conjunto de indices de palabra escritos por stores"""
    used = set()
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    used.add((int(line[1:9], 16) >> 2) & 0x3FF)
    except FileNotFoundError:
        pass
    return used
