"""Interfaz grafica de la Debug Unit (Fase 9).

    python sw/debug_gui.py              (tkinter: viene con Python)

Paneles: programa desensamblado (marca IF/ID/EX), registros, memoria de datos
usada, latches del pipeline y log. Botones: Cargar, Paso, Paso xN, Correr,
Pausa, Reset, Volcado.

Estructura:
  - du_protocol.py habla con la placa (el mismo que usa debug_cli.py).
  - gui_model.py tiene la logica (etapas, burbujas, cambios, formato).
  - Este archivo solo dibuja. Las operaciones con la placa corren en un hilo
    aparte (Worker) para que la ventana no se congele mientras el CPU corre;
    el hilo devuelve los resultados por una cola que la ventana lee cada 50 ms
    (tkinter no se puede tocar desde otro hilo).
"""

import os
import queue
import sys
import threading
import tkinter as tk
from tkinter import ttk, filedialog

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm  # noqa: E402
import gui_model as gm  # noqa: E402
from du_protocol import DebugUnit, DebugUnitError, ABI  # noqa: E402

FONT = ("Consolas", 10)
STAGE_COLOR = {"IF": "#cfe8ff", "ID": "#d8f5d0", "EX": "#ffe9b8"}
CHANGED = "#ffd6d6"
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class App:
    def __init__(self, root):
        self.root = root
        self.du = None                    # DebugUnit conectada
        self.words = None                 # programa abierto
        self.listing = []
        self.prog_name = ""
        self.dump = None                  # ultimo volcado
        self.prev = None                  # el anterior (para marcar cambios)
        self.busy = False
        self.pause_flag = threading.Event()
        self.results = queue.Queue()

        root.title("Debug Unit RISC-V")
        root.geometry("1280x820")
        self._build()
        self._refresh_ports()
        self._set_buttons()
        root.after(50, self._poll)

    # ------------------------------------------------------------------ UI
    def _build(self):
        top = ttk.Frame(self.root, padding=4)
        top.pack(fill="x")
        ttk.Label(top, text="Puerto").pack(side="left")
        self.port = ttk.Combobox(top, width=8, state="readonly")
        self.port.pack(side="left", padx=2)
        ttk.Button(top, text="↻", width=2, command=self._refresh_ports).pack(side="left")
        self.b_conn = ttk.Button(top, text="Conectar", command=self._toggle_conn)
        self.b_conn.pack(side="left", padx=(2, 12))

        self.b_open = ttk.Button(top, text="Abrir .s/.hex", command=self._open)
        self.b_load = ttk.Button(top, text="Cargar", command=self._load)
        self.b_step = ttk.Button(top, text="Paso", command=lambda: self._steps(1))
        self.b_stepn = ttk.Button(top, text="Paso ×N", command=self._stepn)
        self.n_steps = tk.StringVar(value="10")
        self.e_n = ttk.Spinbox(top, from_=1, to=10000, width=6, textvariable=self.n_steps)
        self.b_run = ttk.Button(top, text="Correr", command=self._run)
        self.b_pause = ttk.Button(top, text="Pausa", command=self.pause_flag.set)
        self.b_reset = ttk.Button(top, text="Reset", command=self._reset)
        self.b_dump = ttk.Button(top, text="Volcado", command=self._dump)
        for w in (self.b_open, self.b_load, self.b_step, self.b_stepn, self.e_n,
                  self.b_run, self.b_pause, self.b_reset, self.b_dump):
            w.pack(side="left", padx=2)

        self.status = ttk.Label(top, text="", font=("Consolas", 11, "bold"))
        self.status.pack(side="right", padx=6)

        # --- fila del medio: programa | registros | memoria
        mid = ttk.PanedWindow(self.root, orient="horizontal")
        mid.pack(fill="both", expand=True, padx=4)

        f = ttk.LabelFrame(mid, text="Programa")
        self.t_prog = self._tree(f, ("et", "addr", "word", "asm", "src"),
                                 ("", "dir", "palabra", "instrucción", "fuente"),
                                 (36, 50, 80, 210, 220))
        for st, col in STAGE_COLOR.items():
            self.t_prog.tag_configure(st, background=col)
        mid.add(f, weight=3)

        f = ttk.LabelFrame(mid, text="Registros")
        bar = ttk.Frame(f)
        bar.pack(fill="x")
        self.fmt = tk.StringVar(value="hex")
        for v, txt in (("hex", "hex"), ("dec", "decimal")):
            ttk.Radiobutton(bar, text=txt, value=v, variable=self.fmt,
                            command=self._redraw).pack(side="left")
        self.t_regs = self._tree(f, ("r", "abi", "val"), ("reg", "abi", "valor"),
                                 (40, 45, 100), height=32)
        self.t_regs.tag_configure("chg", background=CHANGED)
        mid.add(f, weight=1)

        f = ttk.LabelFrame(mid, text="Memoria de datos usada")
        self.t_mem = self._tree(f, ("addr", "hex", "dec"), ("dir", "hex", "decimal"),
                                (60, 90, 100))
        self.t_mem.tag_configure("chg", background=CHANGED)
        mid.add(f, weight=1)

        # --- latches
        f = ttk.LabelFrame(self.root, text="Pipeline (latches)")
        f.pack(fill="x", padx=4, pady=2)
        self.t_latch = tk.Text(f, height=4, font=FONT, wrap="none")
        self.t_latch.pack(fill="x")
        self.t_latch.tag_configure("name", font=("Consolas", 10, "bold"))
        self.t_latch.tag_configure("bubble", foreground="#999999")

        # --- log
        f = ttk.LabelFrame(self.root, text="Log")
        f.pack(fill="x", padx=4, pady=(0, 4))
        self.t_log = tk.Text(f, height=6, font=FONT, wrap="word")
        self.t_log.pack(fill="x")

    def _tree(self, parent, cols, heads, widths, height=None):
        frame = ttk.Frame(parent)
        frame.pack(fill="both", expand=True)
        t = ttk.Treeview(frame, columns=cols, show="headings", height=height or 20)
        for c, h, w in zip(cols, heads, widths):
            t.heading(c, text=h, anchor="w")
            t.column(c, width=w, anchor="w", stretch=(c in ("asm", "src")))
        sb = ttk.Scrollbar(frame, orient="vertical", command=t.yview)
        t.configure(yscrollcommand=sb.set)
        t.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        t.configure(style="Mono.Treeview")
        ttk.Style().configure("Mono.Treeview", font=FONT, rowheight=18)
        return t

    def log(self, msg):
        self.t_log.insert("end", msg + "\n")
        self.t_log.see("end")

    def _set_buttons(self):
        conn = self.du is not None
        idle = conn and not self.busy
        for b in (self.b_step, self.b_stepn, self.b_run, self.b_reset, self.b_dump):
            b.state(["!disabled"] if idle else ["disabled"])
        self.b_load.state(["!disabled"] if idle and self.words else ["disabled"])
        self.b_pause.state(["!disabled"] if self.busy else ["disabled"])
        self.b_open.state(["disabled"] if self.busy else ["!disabled"])
        self.b_conn.state(["disabled"] if self.busy else ["!disabled"])
        self.b_conn.config(text="Desconectar" if conn else "Conectar")

    # ------------------------------------------------------- conexion/archivo
    def _refresh_ports(self):
        try:
            from serial.tools import list_ports
            ports = [p.device for p in list_ports.comports()]
        except ImportError:
            ports = []
            self.log("Falta pyserial: pip install pyserial")
        self.port["values"] = ports
        if ports and self.port.get() not in ports:
            self.port.set(ports[0])

    def _toggle_conn(self):
        if self.du:
            self.du.close()
            self.du = None
            self.log("Desconectado.")
            self._set_buttons()
            return
        try:
            self.du = DebugUnit(self.port.get())
        except Exception as e:           # SerialException, puerto ocupado, etc.
            self.log(f"No se pudo abrir {self.port.get()}: {e}")
            return
        self.log(f"Conectado a {self.port.get()}.")
        self._dump()

    def _open(self):
        path = filedialog.askopenfilename(
            initialdir=os.path.join(ROOT_DIR, "programs"),
            filetypes=[("Programas", "*.s *.hex"), ("Todos", "*.*")])
        if not path:
            return
        try:
            words, listing = gm.load_program(path)
        except asm.AsmError as e:
            self.log(f"Error de ensamblado en {os.path.basename(path)}: {e}")
            return
        except (OSError, ValueError) as e:
            self.log(f"No se pudo leer {path}: {e}")
            return
        if not 0 < len(words) <= 1024:
            self.log(f"El programa tiene {len(words)} palabras (tiene que ser 1..1024).")
            return
        self.words, self.listing = words, listing
        self.prog_name = os.path.basename(path)
        self.log(f"Abierto {self.prog_name}: {len(words)} palabras. Falta 'Cargar'.")
        self._draw_program()
        self._set_buttons()

    # ------------------------------------------------ operaciones (en hilo)
    def _start(self, desc, fn):
        """Corre fn() en un hilo; su resultado vuelve por la cola."""
        self.busy = True
        self.pause_flag.clear()
        self._set_buttons()
        self.status.config(text=desc + "…")

        def work():
            try:
                self.results.put(("ok", desc, fn()))
            except (DebugUnitError, OSError) as e:
                self.results.put(("err", desc, e))
        threading.Thread(target=work, daemon=True).start()

    def _poll(self):
        try:
            while True:
                kind, desc, val = self.results.get_nowait()
                self.busy = False
                if kind == "err":
                    self.log(f"ERROR en {desc}: {val}")
                    self.status.config(text="error")
                else:
                    msg, dump = val
                    if msg:
                        self.log(msg)
                    if dump is not None:
                        self._show(dump)
                self._set_buttons()
        except queue.Empty:
            pass
        self.root.after(50, self._poll)

    def _load(self):
        du, words, name = self.du, self.words, self.prog_name

        def fn():
            du.load(words)
            back = du.read_program()
            ok = "verificado con 'I'" if back == words else "¡NO coincide al releer con 'I'!"
            return f"Cargado {name} ({len(words)} palabras), {ok}. PC = 0.", du.dump()
        self.dump = None                  # programa nuevo: no comparar cambios
        self._start("Cargando", fn)

    def _steps(self, n):
        du = self.du

        def fn():
            d = None
            for _ in range(n):
                d = du.step()
                if d.done:
                    break
            return (f"Paso ×{n}" if n > 1 else "Paso") + f": ciclo {d.cycles}", d
        self._start("Paso", fn)

    def _stepn(self):
        try:
            n = int(self.n_steps.get())
        except ValueError:
            self.log("N tiene que ser un número.")
            return
        if n > 0:
            self._steps(n)

    def _run(self):
        du = self.du

        def fn():
            d = du.run_until(self.pause_flag.is_set)
            if d.done:
                return f"Terminado (HALT) en {d.cycles} ciclos.", d
            return f"En pausa en el ciclo {d.cycles}, PC = {d.pc:08x}.", d
        self._start("Corriendo", fn)

    def _reset(self):
        du = self.du

        def fn():
            du.reset()
            return "Reset del CPU (PC = 0, ciclos = 0; la memoria de datos se conserva).", du.dump()
        self._start("Reset", fn)

    def _dump(self):
        du = self.du
        self._start("Volcado", lambda: ("", du.dump()))

    # -------------------------------------------------------------- dibujo
    def _show(self, d):
        self.prev, self.dump = self.dump, d
        self._redraw()

    def _redraw(self):
        d = self.dump
        if d is None:
            return
        prev = self.prev
        mode = self.fmt.get()

        self.status.config(text=f"PC {d.pc:08x}   ciclos {d.cycles}   "
                                + ("● HALT" if d.done else ""))
        self._draw_program(gm.stage_marks(d))

        chg = gm.changed_regs(prev, d)
        self.t_regs.delete(*self.t_regs.get_children())
        for i in range(32):
            self.t_regs.insert("", "end", values=(f"x{i}", ABI[i], gm.fmt_value(d.regs[i], mode)),
                               tags=("chg",) if i in chg else ())

        chg = gm.changed_mem(prev, d)
        self.t_mem.delete(*self.t_mem.get_children())
        for a, v in d.mem:
            self.t_mem.insert("", "end", values=(f"{a:03x}", f"{v:08x}", gm.fmt_value(v, "dec")),
                              tags=("chg",) if a in chg else ())

        self.t_latch.delete("1.0", "end")
        for name, text, bubble in gm.latch_lines(d):
            self.t_latch.insert("end", f"{name:7}", "name")
            self.t_latch.insert("end", text + "\n", "bubble" if bubble else ())

    def _draw_program(self, marks=None):
        marks = marks or {}
        self.t_prog.delete(*self.t_prog.get_children())
        first = None
        for a, w, dis, src in self.listing:
            st = marks.get(a, "")
            iid = self.t_prog.insert("", "end", values=(st, f"{a:03x}", f"{w:08x}", dis, src),
                                     tags=(st,) if st else ())
            if st and first is None:
                first = iid
        if first:
            self.t_prog.see(first)


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
