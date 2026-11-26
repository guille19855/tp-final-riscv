# TP Final — Procesador RISC-V segmentado (Arquitectura de Computadoras 2026, UNC FCEFyN)

Este archivo es el contexto del proyecto para Claude Code: se carga solo al abrir
esta carpeta. Lo armó Guillermo el 12/11/2026, al pasarle el proyecto a Nicolás
hasta la etapa ID, y se actualizó el 23/11/2026 con el estado final.

**Estado:** el procesador, la Debug Unit y la interfaz están terminados. Están
verificados en simulación y en la placa a 85 MHz. Falta cerrar el informe (capturas y
portada) y preparar la defensa.

## Cómo trabajar (reglas del equipo)

- **Responder en español** y explicar cada pieza paso a paso: qué hace, por qué y
  qué alternativas hubo. La nota sale de una **defensa oral**, así que hay que
  entender todo; no tirar código grande sin explicarlo.
- **Seguir la teoría de la cátedra** (`TEORICO/`, ver abajo). Cuando nos apartamos,
  está anotado en "Decisiones" con el motivo.
- **Cada módulo tiene su testbench autoverificable.** Si se cambia algo, correr la
  regresión completa (ver "Verificar") antes de dar el cambio por bueno.
- **Preguntar antes de decisiones de diseño grandes.** Primero se propone (tabla o
  esquema) y se aprueba; después se escribe el código.
- **No tocar** los archivos del TP1 que están en la raíz (`README_TP1.md`,
  `TP_1_ALU.*`) ni `legacy/`. El `README.md` es el del TP Final (23/11). Tampoco commitear `TP_1_ALU.srcs/.../uart_top.dcp`: Vivado lo
  modifica solo.
- **Informe Word** (`docs/informe/Informe_TP_Final.docx`): **nunca regenerarlo
  desde cero**, porque tiene capturas pegadas a mano. Solo se agregan secciones o
  se edita en el lugar, y antes se hace un backup. Lo edita una sola persona a la vez.
- **Git:** repo privado `guille19855/tp-final-riscv`, rama `main`. Commit y push solo
  cuando se pide. Los PDFs no se suben (`*.pdf` está en el `.gitignore`).

## Herramientas

- **Placa:** Basys3, `xc7a35tcpg236-1`, oscilador de 100 MHz. El diseño corre a
  **85 MHz** generados con el Clock Wizard.
- **Vivado 2022.2.** Hace falta *esta* versión, por los IP. El proyecto es
  `project_final/project_final.xpr`.
  - Las rutas son relativas (`$PPRDIR/../rtl/...`).
  - Los fuentes viven en `rtl/` y `tb/`. Se agregan con **Add Sources sin "Copy
    sources into project"**.
  - Top de síntesis: **`top`** (`rtl/top/top.v`). Constraints: solo
    `constraints/basys3_top.xdc` habilitado.
  - IP: `instr_mem`, `data_mem` (BRAM) y `clk_wiz_cpu` (85 MHz). `clk_wiz_50` es
    el viejo y ya no está en el proyecto.
- **Simular desde la terminal:** `scripts/sim.sh <nombre_tb> [--wave]`.
  - Compila todo `rtl/**/*.v`, los modelos de los IP y el TB con
    xvlog/xelab/xsim, y deja la salida en `sim_out/`.
  - Si Vivado no está en `/c/Xilinx/Vivado/2022.2`, exportar `VIVADO=<ruta>`.
  - `launch_simulation` en modo batch falla; por eso existe el script.
  - Para encontrar los modelos de los IP, antes hay que hacer *Generate Output
    Products* en Vivado.
- **Regresión de programas:** `scripts/run_programs.sh`, que usa `cpu_top_tb`, y
  `TB=top_core_tb scripts/run_programs.sh`, que pasa por UART y la Debug Unit y
  tarda unos 6 minutos.
- **En la GUI de Vivado:** el runtime por defecto es 1000 ns, así que usar `run all`.
  Si la simulación falla con "simulate.log está siendo utilizado por otro proceso",
  quedó un `vivado.exe` fantasma: terminarlo desde el Administrador de tareas.
- **Convención de TB:** entradas en el flanco de bajada y chequeos 1 ns después del
  flanco de subida. Imprime `OK ...` o `ERROR ...` por chequeo y al final
  `TEST PASSED: N checks, 0 errors`.
- **Timing:** `synth/measure.tcl` (Vivado batch, out of context, reloj de 10 ns)
  da la fmax post-síntesis y post-route. La fmax es 1 / (10 − WNS).
- **`scripts/svg_a_png.sh <pagina.html> <clase-svg> <salida.png>`:** renderiza un
  SVG de `docs/*.html` a PNG para el informe. Usa Edge headless.
- **Python** (`pip install pyserial`):
  - `python sw/asm.py prog.s` → .hex, .bin y .lst.
  - `python sw/iss.py prog.s` → resultados esperados: .exp, .trc y .sto.
  - `python sw/debug_cli.py puertos | -p COMx cargar|correr|paso|volcado|reset|programa|verificar`.
  - `python sw/debug_gui.py` → interfaz gráfica.
  - Puerto **`SIM`** (GUI y CLI) → placa simulada, sin hardware (`sw/sim_board.py`,
    agregada el 26/11/2026). Es el pipeline ciclo a ciclo copiado del RTL. Si se
    cambia el RTL, hay que actualizarla también y correr `python sw/test_sim_board.py`.
  - `verificar` corre todos los programas en la placa contra el ISS. Supone la
    memoria de datos recién programada: hacer *Program Device* antes.

> **PDFs:** el enunciado y `TEORICO/` NO están en el repo. Pedírselos a Guillermo.

## Enunciado (resumen; está completo en `ENUNCIADO TRABAJO FINAL 2026.pdf`)

- **Pipeline:** RISC-V de 5 etapas (IF, ID, EX, MEM, WB) que resuelve los riesgos
  estructurales, de datos y de control.
- **Instrucciones:**
  - R: `add sub sll srl sra and or xor slt sltu`
  - I: `lb lh lw lbu lhu addi andi ori xori slti sltiu slli srli srai jalr`
  - S: `sb sh sw`
  - B: `beq bne`
  - U: `lui`
  - J: `jal`
  - más HALT.
- **Debug Unit por UART:**
  - envía los 32 registros, los latches intermedios, la memoria de datos usada y el PC;
  - carga el programa sin resintetizar;
  - tiene modo continuo y paso a paso;
  - al terminar, el pipeline tiene que quedar vacío.
- **Clock:** "no se debe intervenir el clock". Nada de clock gating: el paso a paso
  se hace con *clock enable* (`en`).
- **Timing:** análisis de timing (camino crítico, frecuencia máxima). Se sugiere el
  Clock Wizard.
- **PC:** ensamblador propio e interfaz en Python (el profesor aprobó Python).
- **Indicaciones del profesor:**
  - no hace falta borrar las memorias al reprogramar;
  - la memoria de datos se inicializa con 0..255 (`.coe`);
  - todos los FF resetean a 0;
  - la frecuencia máxima se saca de post-síntesis;
  - ojo con la lógica combinacional larga entre FF.

## Decisiones de diseño (ya tomadas, no rediscutir sin motivo)

1. **Saltos en EX** con *predict not-taken*: un salto tomado hace flush de IF/ID e
   ID/EX (2 ciclos). `beq`/`bne` usan un **comparador de igualdad propio** sobre los
   operandos forwardeados, no la ALU (Fase 10).
   - **Saltos en ID (Fase 11): evaluado y descartado.** Da −7,8 % de ciclos, pero
     suma stalls y alarga el camino crítico (informe 10.6, `docs/timing.html`).
2. **Banco de registros en FF con bypass interno.** La cátedra escribe en el flanco
   de bajada; el bypass no parte el período a la mitad.
3. **HALT = `ebreak`** (`0x00100073`). Se detecta en ID e IF deja de buscar. Cuando
   llega a WB (`program_done`), la Debug Unit baja `cpu_en` en ese mismo ciclo, así
   que el pipeline queda vacío.
4. **Memorias:** BRAM con el IP, True Dual Port, 1024×32, lectura sincrónica.
   - El puerto A es del CPU y el B de la Debug Unit.
   - La salida de `instr_mem` ES `IF/ID.instr`.
   - La salida de `data_mem` ES `MEM/WB.read_data`. Lleva escritura por byte y se
     inicializa con palabra i = i.
   - La memoria de datos **no se borra** entre programas.
5. **UART** del TP2 a 115200 baudios. `DVSR = 46` a 85 MHz (lo calcula `top.v`).
6. **Reset sincrónico** que lleva todo a 0, y `en = 0` congela todo.
   - Una **burbuja** solo pone en 0 el control con efecto y rs1/rs2/rd (Fase 10).
   - Excepción al reset a 0: el sincronizador de rx arranca en 1.
7. **jal/jalr:** PC+4 se elige en EX, así `ex_mem_result` es siempre lo que se
   escribe en rd y WB tiene un mux de 2 entradas.
8. **Debug Unit:**
   - comandos de 1 byte: L, R, C, S, D, I;
   - después de cada paso manda el volcado completo;
   - la memoria usada se lleva con un mapa de bits en hardware (`dmem_used.v`);
   - los latches se leen con un mux de 16 palabras en `cpu_top`.

## Estado (23/11/2026)

| Fase | Qué | Estado |
|---|---|---|
| 0–2 | Preparación, IF, ID | ✅ |
| 3–5 | EX, MEM, WB | ✅ |
| 6 | Ensamblador + ISS + programas aleatorios | ✅ |
| 7 | Integración `cpu_top` | ✅ 28 programas |
| 8 | Debug Unit + `top` en la placa | ✅ 28/28 en la placa |
| 9 | Interfaz Python (CLI + GUI tkinter) | ✅ |
| 10 | Timing | ✅ fmax post-síntesis 64,9 → 90,5 MHz; placa a 85 MHz (WNS +0,59) |
| 11 | Saltos en ID | evaluada y descartada |
| **12** | **Informe y defensa** | **← falta: 22 capturas en los recuadros amarillos, portada, ensayo** |

**Páginas de referencia** (publicadas; pedir acceso a Guillermo si no abren):

| Página | Link | Archivo |
|---|---|---|
| Diagrama general | https://claude.ai/artifact/H2i71GegeujE758ojuauvS | `docs/pipeline_diagrama.html` |
| Plan de trabajo | https://claude.ai/artifact/ByEfhFGYdYCN64kAsE8jFR | `docs/plan_de_trabajo.html` |
| Tabla de control | https://claude.ai/artifact/AAPc4BgSib1JkagGoa1mwy | `docs/tabla_control.html` |
| Etapa IF | https://claude.ai/artifact/P9wfwUZrhmqCotAACqea7Q | `docs/etapa_if.html` |
| Etapa ID | https://claude.ai/artifact/CyWiMmMAzCLxCm4MQntavG | `docs/etapa_id.html` |
| Etapa EX | (sin publicar) | `docs/etapa_ex.html` |
| Etapa MEM | https://claude.ai/artifact/13TXxcVWpBKbMjvu2pdxwu | `docs/etapa_mem.html` |
| Etapa WB | https://claude.ai/artifact/67AmpLGntTA6G1L46oQ77y | `docs/etapa_wb.html` |
| Debug Unit | https://claude.ai/artifact/9b3TMJPdz5rmWFsL6V3zG3 | `docs/debug_unit.html` |
| Timing | https://claude.ai/artifact/5ysWcrpUvXZFGN9y63fX3c | `docs/timing.html` |

Cada página tiene su sección "Preguntas para la defensa".

## Estructura

```
rtl/cpu/      riscv_defs.vh, if/id/ex/mem/wb_stage.v (cada uno con su latch de salida),
              control_unit, imm_gen, reg_file, hazard_unit, alu, alu_control,
              forwarding_unit, dmem_used, cpu_top.v (integración + puertos de debug)
rtl/debug/    debug_unit.v (FSM del protocolo)
rtl/top/      top.v (Clock Wizard) · top_core.v (UART + Debug Unit + CPU + display)
rtl/board/    prueba temprana en la placa (sin Debug Unit), seven_seg, debouncer
rtl/uart/     UART del TP2 (rx, tx, baud_rate_gen)
tb/cpu, tb/top, tb/board, tb/uart   testbenches (<modulo>_tb.v)
programs/     programas de prueba (.s + .hex/.exp/.trc/.sto); random/ se regenera
sw/           asm.py, iss.py, gen_random.py, du_protocol.py, debug_cli.py,
              debug_gui.py, gui_model.py, test_*.py
coe/          contenido inicial de las BRAM
constraints/  basys3_top.xdc (el que va), basys3_board_test.xdc
synth/        measure.tcl + reportes del camino crítico (antes/después)
docs/         páginas HTML, informe/ (Word + img/)
scripts/      sim.sh, run_programs.sh, svg_a_png.sh
legacy/tp2/   TP2 viejo, no se usa (tiene un alu.v de 8 bits, NO confundir)
```

Para leer los PDFs de `TEORICO/` hay que extraer el texto con PyMuPDF.
- **"Apuntes de Arquitectura de Computadoras.pdf"**, Unidad 2 (pp. ~50-75): pipeline,
  en MIPS.
- **"3. Processor.pdf"**: datapath RISC-V, ALUOp, forwarding y load-use.

## Verificar (antes de dar por bueno cualquier cambio)

1. Testbench del módulo tocado: `scripts/sim.sh <modulo>_tb`.
2. `scripts/run_programs.sh` → "TODOS LOS PROGRAMAS PASARON".
3. Si se tocó la Debug Unit o el top: `TB=top_core_tb scripts/run_programs.sh`.
4. `python sw/test_asm.py`, `python sw/test_gui_model.py` y
   `python sw/test_sim_board.py` si se tocó `sw/` (el último también si se tocó `rtl/cpu`).
5. En la placa: Generate Bitstream → WNS ≥ 0 → Program Device →
   `python sw/debug_cli.py -p COMx verificar "programs/*.s" "programs/random/*.s"`.
