# TP Final — Procesador RISC-V segmentado con Debug Unit por UART

Arquitectura de Computadoras 2026 · FCEFyN, Universidad Nacional de Córdoba.

Procesador RISC-V (subconjunto RV32I) con un pipeline de 5 etapas, implementado en
Verilog sobre una Digilent **Basys3** (Artix-7 `xc7a35tcpg236-1`). Una **Debug
Unit** se comunica por UART con la PC, y una **interfaz en Python** permite cargar
programas, ejecutarlos en modo continuo o paso a paso y ver el estado interno del
procesador.

| | |
|---|---|
| Pipeline | IF · ID · EX · MEM · WB, con forwarding, stall load-use y flush de saltos |
| Instrucciones | `add sub sll srl sra and or xor slt sltu` · `addi andi ori xori slti sltiu slli srli srai` · `lb lh lw lbu lhu` · `sb sh sw` · `beq bne` · `jal jalr` · `lui` · HALT (`ebreak`) |
| Reloj | 85 MHz (Clock Wizard). Frecuencia máxima post-síntesis: 90,5 MHz |
| Verificación | Un testbench autoverificable por módulo, y 28 programas comparados contra un modelo de referencia en simulación y en la placa |
| Recursos | 2598 LUT (12,5 %) · 1683 FF (4 %) · 2 BRAM36 |

## Arquitectura

```
                ┌──────────────────────────── cpu_top ────────────────────────────┐
 instr_mem ──►  │  IF ─► IF/ID ─► ID ─► ID/EX ─► EX ─► EX/MEM ─► MEM ─► MEM/WB ─► WB │
 (BRAM)         │         ▲         │  banco de    │ ALU, forwarding,   data_mem      │
                │         │         │  registros   │ decisión de salto  (BRAM)        │
                │      flush/stall ◄┘  hazard unit  └─► branch_taken ─► PC             │
                └───────────────────────▲─────────────────────────────────────────────┘
                                        │ cpu_en · carga del programa · registros, latches, memoria
 PC (Python) ◄── USB-UART 115200 ──► debug_unit
```

- **Saltos:** se resuelven en EX con *predict not-taken*. Un salto tomado cuesta 2
  ciclos. `beq` y `bne` usan un comparador de igualdad propio.
- **Riesgos de datos:**
  - forwarding desde EX/MEM y MEM/WB;
  - bypass en el banco de registros;
  - un ciclo de stall para load-use.
- **Memorias:** BRAM True Dual Port de 1024 × 32. El puerto A es del procesador y el
  B de la Debug Unit, así que el programa se carga sin resintetizar.
- **HALT:** cuando el `ebreak` llega a WB, la Debug Unit baja el enable en el mismo
  ciclo y el pipeline queda vacío.
- **Sin tocar el reloj:** el paso a paso se hace con *clock enable*; no hay clock
  gating.

## Protocolo de la Debug Unit

| Comando | Efecto | Respuesta |
|---|---|---|
| `L` N (2 bytes) + N palabras | Carga el programa | `K` |
| `R` | Reset del procesador (la memoria de datos se conserva) | `K` |
| `C` | Ejecuta hasta HALT; cualquier byte lo pausa | volcado |
| `S` | Ejecuta un ciclo | volcado |
| `D` | Volcado sin ejecutar | volcado |
| `I` | Relee el programa cargado | `I` + N + palabras |

El **volcado** contiene, en palabras de 32 bits little-endian:
- PC, ciclos y estado;
- los 32 registros;
- los 4 latches (16 palabras);
- los pares (dirección, dato) de la memoria de datos escrita por el programa.

## Estructura

```
rtl/cpu/       etapas del pipeline (cada una con su latch), ALU, control, hazard,
               forwarding, banco de registros, cpu_top.v
rtl/debug/     debug_unit.v
rtl/top/       top.v (Clock Wizard) y top_core.v (UART + Debug Unit + CPU + display)
rtl/uart/      UART (reutilizada del TP2)
rtl/board/     prueba temprana en la placa, sin Debug Unit
tb/            testbenches autoverificables
sw/            ensamblador, modelo de referencia (ISS), generador de programas,
               CLI e interfaz gráfica
programs/      programas de prueba (.s) y sus resultados esperados
constraints/   basys3_top.xdc
coe/           contenido inicial de las memorias
synth/         medición de timing y reportes del camino crítico
docs/          una página por etapa, Debug Unit y timing; informe (Word)
scripts/       sim.sh, run_programs.sh, svg_a_png.sh
project_final/ proyecto de Vivado
```

`README_TP1.md`, `TP_1_ALU.*` y `legacy/` son de los trabajos prácticos anteriores.

## Uso

### Requisitos

- **Vivado 2022.2.** Hace falta esta versión por los IP de memoria y de reloj.
- **Python 3** con `pip install pyserial`.

### Placa

1. Abrir `project_final/project_final.xpr`. El top es `top` y el único constraint
   habilitado es `constraints/basys3_top.xdc`.
2. *Generate Bitstream* → *Program Device* → apretar **BTNC** (reset).
3. Desde la PC:

```bash
python sw/debug_cli.py puertos                        # ver el puerto de la placa
python sw/debug_gui.py                                # interfaz gráfica
python sw/debug_cli.py -p COM3 cargar programs/ejemplo.hex
python sw/debug_cli.py -p COM3 paso 5                 # 5 ciclos
python sw/debug_cli.py -p COM3 correr                 # hasta HALT
python sw/debug_cli.py -p COM3 verificar "programs/*.s" "programs/random/*.s"
```

En la placa, el display muestra el PC. LED15 indica HALT, LED14 que está corriendo y
LED13 que está cargando.

### Sin la placa

El puerto **`SIM`** es una placa simulada (`sw/sim_board.py`). Es el pipeline
modelado ciclo a ciclo en Python, a partir del Verilog: tiene los mismos latches,
forwarding, stalls, flush y HALT. Da los mismos ciclos y volcados que el hardware.
`sw/test_sim_board.py` lo compara con el ISS en los 28 programas.

```bash
python sw/debug_gui.py                                  # elegir el puerto SIM
python sw/debug_cli.py -p SIM verificar "programs/*.s" "programs/random/*.s"
```

Con la CLI, la placa simulada arranca de cero en cada comando. Para el paso a paso,
usar la GUI.

### Programas

```bash
python sw/asm.py programs/mi_prog.s     # -> .hex, .bin, .lst
python sw/iss.py programs/mi_prog.s     # resultados esperados (.exp, .trc, .sto)
```

El ensamblador acepta nombres ABI (`zero`, `ra`, `sp`, `t0`…), etiquetas y las
pseudo-instrucciones `nop mv not neg j ret li halt`.

### Simulación (desde la terminal)

```bash
scripts/sim.sh ex_stage_tb                 # un testbench
scripts/run_programs.sh                    # los 28 programas en cpu_top_tb
TB=top_core_tb scripts/run_programs.sh     # los 28, por UART y la Debug Unit
```

Antes de la primera simulación hay que hacer *Generate Output Products* de los IP en
Vivado. Si Vivado no está en `/c/Xilinx/Vivado/2022.2`, exportar `VIVADO=<ruta>`.

## Verificación

- **Testbenches por módulo:** cada uno imprime `TEST PASSED: N checks, 0 errors`.
- **Modelo de referencia:** `sw/iss.py` ejecuta el programa de a una instrucción, sin
  pipeline. Para cada programa el procesador tiene que reproducir:
  - cada escritura de registro y cada store, en orden;
  - el estado final;
  - la cantidad exacta de ciclos.
- **Programas:** 8 escritos a mano (ALU, forwarding, load-use, saltos, memoria…) y 20
  aleatorios que combinan todos los riesgos.
- **Sistema completo:** `top_core_tb` maneja la placa desde afuera, con un modelo de
  UART. Se validó con pruebas de mutación: el testbench detecta las 7 fallas
  introducidas a propósito.
- **En la placa:** los 28 programas pasan a 85 MHz.

## Timing

| | Antes | Después |
|---|---|---|
| fmax post-síntesis | 64,9 MHz | 90,5 MHz |
| Reloj en la placa | 50 MHz | 85 MHz (WNS +0,59 ns) |

El camino crítico original era un load seguido de un salto que usa el dato: lectura
de memoria → forwarding → resta en la ALU → decisión de salto → flush de ID/EX. Se
acortó con dos cambios:
- un comparador de igualdad para los saltos;
- un flush que solo limpia los bits de control.

Resolver los saltos en ID se evaluó y se descartó: daba −7,8 % de ciclos, pero a
costa de un camino más largo. Detalle en `docs/timing.html` y en el capítulo 10 del
informe.

## Documentación

- `docs/informe/Informe_TP_Final.docx`: el informe completo.
- `docs/pipeline_diagrama.html` y `docs/tabla_control.html`: el diagrama general y
  la tabla de control.
- `docs/etapa_{if,id,ex,mem,wb}.html`, `docs/debug_unit.html` y `docs/timing.html`:
  una página por bloque, con su esquemático, el Verilog clave y las preguntas para
  la defensa.
- `docs/plan_de_trabajo.html`: el plan y el estado por fase.
