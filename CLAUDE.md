# TP Final — Procesador RISC-V segmentado (Arquitectura de Computadoras 2026, UNC FCEFyN)

Este archivo es el contexto del proyecto para Claude Code: se carga solo al abrir
esta carpeta. Lo armó Guillermo, al pasarle el proyecto a Nicolás (12/11/2026),
con todo lo que se decidió y construyó hasta la etapa ID. **Nicolás sigue con la
etapa EX (Fase 3).**

## Cómo trabajar (reglas del equipo)

- **Responder en español** y explicar cada pieza paso a paso: qué hace, por qué y
  qué alternativas hubo. La nota sale de una **defensa oral**, así que hay que
  entender todo; no tirar código grande sin explicarlo.
- **Seguir la teoría de la cátedra** (`TEORICO/`, ver abajo). Cuando nos apartamos,
  está anotado en "Decisiones" con el motivo.
- **Etapa por etapa**: cada módulo tiene su testbench autoverificable antes de
  integrar. Las entradas que vienen de otras etapas se manejan a mano en el TB.
- **Preguntar antes de decisiones de diseño grandes.** Primero se propone (tabla o
  esquema) y se aprueba; después se escribe el código.
- **No tocar** los archivos del TP1 que están en la raíz (`README.md`, `TP_1_ALU.*`)
  ni `legacy/`.
- **Informe Word** (`docs/informe/Informe_TP_Final.docx`): **nunca regenerarlo
  desde cero**, porque tiene capturas pegadas a mano. Solo se agregan secciones o
  se edita en el lugar. Lo edita una sola persona a la vez (coordinar con
  Guillermo). Lo más simple: escribir la sección 6.3 (EX) aparte y pasársela.
- **Git:** todavía no hay repo. Si se crea uno para trabajar de a dos, hacerlo de
  común acuerdo (no hacer push sin preguntar).

## Herramientas

- **Placa:** Basys3, `xc7a35tcpg236-1`, clock 100 MHz.
- **Vivado 2022.2.** Hace falta *esta* versión, por el IP de la BRAM. El proyecto
  es `project_final/project_final.xpr`.
  - Las rutas son relativas (`$PPRDIR/../rtl/...`).
  - Los fuentes viven en `rtl/` y `tb/`. Se agregan con **Add Sources sin "Copy
    sources into project"**: diseño desde `rtl/`, testbenches como *simulation
    sources* desde `tb/`.
- **Simular desde la terminal:** `scripts/sim.sh <nombre_tb> [--wave]`.
  - Compila todo `rtl/**/*.v`, los modelos del IP y el TB con xvlog/xelab/xsim, y
    deja la salida en `sim_out/`.
  - Si Vivado no está en `/c/Xilinx/Vivado/2022.2`, exportar `VIVADO=<ruta>`.
  - `launch_simulation` en modo batch falla; por eso existe el script.
  - Para que encuentre los modelos del IP, primero hay que hacer *Generate Output
    Products* del IP `instr_mem` en Vivado.
- **En la GUI de Vivado**, el runtime por defecto es 1000 ns: usar `run all` o
  poner `xsim.simulate.runtime` en `-all`.
- **Si la simulación de la GUI falla con "simulate.log está siendo utilizado por
  otro proceso"**, quedó un `vivado.exe` fantasma en segundo plano. Hay que
  terminarlo desde el Administrador de tareas → Detalles.
- **Convención de TB:** entradas en el flanco de bajada y chequeos 1 ns después del
  flanco de subida. Imprime `OK ...` o `ERROR ...` por chequeo y al final
  `TEST PASSED: N checks, 0 errors`.
- **`scripts/svg_a_png.sh <pagina.html> <clase-svg> <salida.png>`:** renderiza un
  SVG de las páginas `docs/*.html` a PNG para el informe. Usa Edge headless.

> **PDFs:** el enunciado y `TEORICO/` NO están en el repo (`*.pdf` está en el
> `.gitignore`). Pedírselos a Guillermo y copiarlos en la raíz y en `TEORICO/`.

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
- **Debug Unit por UART:** envía los 32 registros, los latches intermedios, la
  memoria de datos usada y el PC.
  - Carga el programa por UART, sin resintetizar.
  - Modo continuo (hasta HALT) y modo paso a paso.
  - Al terminar, el pipeline tiene que quedar vacío.
- **Clock:** "no se debe intervenir el clock". Nada de clock gating: el modo paso
  a paso se hace con *clock enable* (`en`).
- **Timing:** análisis de timing (camino crítico, frecuencia máxima); se sugiere
  el Clock Wizard.
- **PC:** ensamblador propio e interfaz en Python (el profesor aprobó Python).
- **Indicaciones del profesor:**
  - No hace falta borrar las memorias al reprogramar.
  - La memoria de datos se inicializa con 0..255 (`.coe`).
  - Todos los FF resetean a 0.
  - La frecuencia máxima se saca de post-síntesis.
  - Ojo con la lógica combinacional larga entre FF.

## Decisiones de diseño (ya tomadas, no rediscutir sin motivo)

1. **Saltos:** se resuelven en **EX** con *predict not-taken*. Si se toma el salto,
   se hace flush de IF/ID e ID/EX (penalidad de 2 ciclos). Moverlos a ID (Opción II
   de la cátedra, 1 ciclo) es una mejora opcional para el final (Fase 11).
2. **Banco de registros:** en flip-flops, con **bypass interno** (si WB escribe el
   mismo registro que ID lee, sale el dato nuevo). La cátedra escribe en el flanco
   de bajada; elegimos el bypass porque no parte el período a la mitad y no limita
   la frecuencia.
3. **HALT = `ebreak`** (`0x00100073`). Se detecta en ID: IF deja de buscar y el
   `ebreak` viaja hasta WB. Cuando llega a WB, el pipeline está vacío y el programa
   terminó.
4. **Memorias:** BRAM con el IP *Block Memory Generator*, True Dual Port, 1024×32.
   - El puerto A es del CPU y el puerto B de la Debug Unit.
   - La lectura es sincrónica (latencia 1).
   - La memoria de instrucciones se direcciona con el registro PC, y su salida
     ES el `IF/ID.instr`.
   - La memoria de datos (**todavía no creada**, Fase 4) se va a direccionar
     desde EX/MEM, y su salida va a hacer de `MEM/WB.read_data`. Lleva escritura
     por byte para `sb`/`sh` y se inicializa con 0..255.
5. **UART:** 115200 baudios. Es la del TP2 (`rtl/uart/`), con DVSR parametrizado
   según el clock.
6. **Reset sincrónico** en todo, que lleva todo a 0. `en = 0` congela todo el
   procesador, incluida la escritura del banco de registros.

## Estado (12/11/2026)

| Fase | Qué | Estado |
|---|---|---|
| 0 | Preparación (carpetas, `riscv_defs.vh`, `sim.sh`) | ✅ |
| 1 | IF: `if_stage.v` + IP `instr_mem` | ✅ 26/26 |
| 2 | ID: `control_unit`, `imm_gen`, `reg_file`, `hazard_unit`, `id_stage` | ✅ 37 + 1021 + 300 + 17 + 70 |
| **3** | **EX: ALU, control de ALU, forwarding, decisión de salto, latch EX/MEM** | **← sigue (Nicolás)** |
| 4 | MEM: IP `data_mem` (escritura por byte, `.coe` 0..255), loads con extensión de signo | |
| 5 | WB: mux de escritura (ALU / MEM / PC+4) | |
| 6 | Ensamblador en Python (`sw/asm.py`) | |
| 7 | Integración `cpu_top.v` + programas de prueba en `programs/` | |
| 8 | Debug Unit + `top.v` en la placa | |
| 9 | Interfaz Python | |
| 10 | Timing / Clock Wizard | |
| 11 | Saltos en ID (opcional) | |
| 12 | Informe y defensa | |

**Páginas de referencia** (publicadas por Guillermo; pedirle acceso si no abren):
- Diagrama general del pipeline: https://claude.ai/artifact/H2i71GegeujE758ojuauvS
  (`docs/pipeline_diagrama.html`)
- Plan de trabajo: https://claude.ai/artifact/ByEfhFGYdYCN64kAsE8jFR
  (`docs/plan_de_trabajo.html`)
- Tabla de control: https://claude.ai/artifact/AAPc4BgSib1JkagGoa1mwy
  (`docs/tabla_control.html`)
- Etapa IF: https://claude.ai/artifact/P9wfwUZrhmqCotAACqea7Q (`docs/etapa_if.html`)
- Etapa ID: https://claude.ai/artifact/CyWiMmMAzCLxCm4MQntavG (`docs/etapa_id.html`)

Hay una página `docs/etapa_<x>.html` por cada etapa terminada, con el esquemático,
los fragmentos de Verilog, la síntesis y las preguntas para la defensa. Hacer
`docs/etapa_ex.html` igual cuando EX esté lista.

## Estructura

```
rtl/cpu/riscv_defs.vh   opcodes, funct3 y codificación del control (`include en todo)
rtl/cpu/if_stage.v      PC + BRAM de instrucciones + latch IF/ID
rtl/cpu/control_unit.v  decodifica el opcode -> señales de control
rtl/cpu/imm_gen.v       inmediatos I/S/B/U/J extendidos en signo
rtl/cpu/reg_file.v      32x32 en FF, x0=0, bypass, puerto de debug
rtl/cpu/hazard_unit.v   load-use -> stall, flush_id_ex
rtl/cpu/id_stage.v      todo lo anterior + latch ID/EX
rtl/uart/               UART del TP2 (rx, tx, baud_rate_gen)
tb/cpu/, tb/uart/       testbenches (<modulo>_tb.v)
coe/instr_test.coe      contenido inicial de instr_mem (palabra i = C0DE0000+i)
constraints/            .xdc de la Basys3
docs/                   páginas HTML de cada etapa, plan, informe/
TEORICO/                PDFs de la cátedra
scripts/                sim.sh, svg_a_png.sh
programs/, sw/          (vacíos: assembler y programas de prueba)
legacy/tp2/             TP2 viejo, no se usa (tiene un alu.v de 8 bits, NO confundir)
```

Para leer los PDFs de `TEORICO/`, que son casi todos imágenes, hay que extraer el
texto con Python `fitz` (PyMuPDF).
- **"Apuntes de Arquitectura de Computadoras.pdf"** es lo más importante. La
  Unidad 2 (Segmentación, pp. ~50-75) cubre el pipeline. Está en MIPS: traducir rt
  como rs2/rd, sin RegDst, target = PC+imm.
- **"3. Processor.pdf"** son las diapositivas RISC-V: datapath, ALUOp, ecuaciones
  de forwarding (pp. 10-11 tienen el control de 2 niveles) y load-use.

## Lo que EX recibe de ID (ya implementado en `id_stage.v`)

**Latch ID/EX** (todos registros; 0 cuando hay burbuja o reset):

| Señal | Bits | Uso en EX |
|---|---|---|
| `id_ex_pc` | 32 | target de branch/jal = `pc + imm` |
| `id_ex_pc4` | 32 | valor que escriben `jal`/`jalr` en rd |
| `id_ex_rs1_data`, `id_ex_rs2_data` | 32 c/u | operandos del banco (antes del forwarding) |
| `id_ex_imm` | 32 | inmediato ya extendido |
| `id_ex_rs1`, `id_ex_rs2` | 5 c/u | para el forwarding. **Valen 0 si la instrucción no los usa** |
| `id_ex_rd` | 5 | **vale 0 si la instrucción no escribe registro** |
| `id_ex_funct3` | 3 | operación de la ALU, tipo de branch, ancho de load/store |
| `id_ex_funct7b5` | 1 | `instr[30]`: add/sub, srl/sra |
| `id_ex_alu_src_a` | 1 | 0 = rs1, 1 = **cero** (solo `lui`: 0 + imm) |
| `id_ex_alu_src_b` | 1 | 0 = rs2, 1 = imm |
| `id_ex_alu_op` | 2 | `ALUOP_ADD` 00 (ld/st/jalr/lui), `SUB` 01 (branch), `R` 10, `I` 11 |
| `id_ex_branch`, `id_ex_jal`, `id_ex_jalr` | 1 c/u | tipo de salto |
| `id_ex_mem_read`, `id_ex_mem_write` | 1 c/u | pasan a MEM |
| `id_ex_reg_write`, `id_ex_wb_sel` | 1 + 2 | pasan a WB (`WB_ALU` 00, `WB_MEM` 01, `WB_PC4` 10) |
| `id_ex_halt` | 1 | el `ebreak` viaja hasta WB |

**Señales que EX le tiene que dar a IF e ID:**
- `branch_taken` va a `if_stage.branch_taken` y a `id_stage.branch_taken`:
  - en IF hace flush de IF/ID y carga el PC;
  - en ID convierte el latch ID/EX en burbuja y anula un `ebreak` del camino
    equivocado.
- `branch_target[31:0]` va a `if_stage.branch_target`.

Ya está resuelto en ID: el stall por load-use, la burbuja y la detección de HALT.
EX no tiene que hacer flush de nada propio: la instrucción que salta es la que está
en EX y sigue su camino.

## Fase 3 — EX: lo que está pensado (a confirmar con el equipo)

Módulos sugeridos, cada uno con su TB: `rtl/cpu/alu.v`, `rtl/cpu/alu_control.v`,
`rtl/cpu/forwarding_unit.v` y `rtl/cpu/ex_stage.v` (este último incluye el latch
EX/MEM).

**Control de la ALU (segundo nivel, diapositivas 10-11 de "3. Processor").**
La operación interna es `{bit30, funct3}`:

| Op | Código | Op | Código |
|---|---|---|---|
| ADD | 0000 | SRL | 0101 |
| SUB | 1000 | SRA | 1101 |
| SLL | 0001 | OR | 0110 |
| SLT | 0010 | AND | 0111 |
| SLTU | 0011 | XOR | 0100 |

- ALUOp 00 → ADD; 01 → SUB.
- ALUOp 10 (R) → `{funct7b5, funct3}`.
- ALUOp 11 (I) → `{(funct3==101) ? funct7b5 : 0, funct3}`.

  **Trampa:** en tipo I, `instr[30]` es parte del inmediato. Un `addi` con
  inmediato negativo tiene el bit 30 en 1 y NO tiene que hacerse `sub`. El bit 30
  solo cuenta en `srli`/`srai`. Probarlo en el TB.

**ALU (32 bits, combinacional):**
- Los shifts usan `b[4:0]`.
- SLT compara con signo (`$signed`); SLTU, sin signo.
- `zero = (result == 0)` sirve para los branches, que usan SUB.

**Forwarding (ecuaciones de la cátedra):**
```
ForwardA = 10  si EX/MEM.reg_write && EX/MEM.rd != 0 && EX/MEM.rd == ID/EX.rs1
         = 01  si no, y MEM/WB.reg_write && MEM/WB.rd != 0 && MEM/WB.rd == ID/EX.rs1
         = 00  si no (dato del banco)
ForwardB: igual con rs2
```
- EX/MEM tiene prioridad porque es el dato más reciente.
- La distancia 3 (WB→ID) ya la cubre el bypass del banco.
- Como `rs1`/`rs2`/`rd` llegan "limpios" (0 si no se usan), no aparecen
  dependencias falsas.

**Detalles a tener en cuenta:**
- **El mux de forwarding va ANTES del mux ALUSrcB.** El dato de un `sw` (rs2) tiene
  que salir forwardeado aunque la ALU use el inmediato. A EX/MEM se pasa el rs2
  *forwardeado* como dato de escritura.
- **Valor forwardeado desde EX/MEM** si la instrucción de adelante es `jal`/`jalr`:
  lo que escribe en rd es PC+4, no el resultado de la ALU. Decidir una de dos:
  - guardar en EX/MEM un "resultado" ya multiplexado;
  - forwardear según `wb_sel`.
- **Un load en EX/MEM nunca se forwardea desde ahí**, porque el dato no existe
  todavía. Ese caso ya lo frena el stall load-use de ID.
- **Desde MEM/WB** se forwardea el valor final de WB, el mismo que va al banco.
- **Decisión de salto:**
  - `taken = (branch && (funct3==BEQ ? zero : ~zero)) || jal || jalr`.
  - Target: `pc + imm` para branch/jal, con un sumador propio ("Add" del
    datapath); `(rs1_fwd + imm) & ~1` para `jalr`.
- **Latch EX/MEM:**
  - Datos: `alu_result` (o resultado), `rs2` forwardeado, `rd`, `funct3`, `pc4`.
  - Control: `mem_read`, `mem_write`, `reg_write`, `wb_sel`, `halt`.
  - Mismo esquema que ID/EX: `reset` pone todo en 0, `en` copia y `en = 0`
    congela.
- **Timing:** el camino forwarding → ALU → decisión → mux del PC es candidato a
  camino crítico (lo advirtió el profesor). Medirlo en la Fase 10.
- **Para el TB de `ex_stage`:** manejar a mano las entradas ID/EX y las de
  forwarding (EX/MEM, MEM/WB). Casos mínimos:
  - las 10 operaciones;
  - `addi` con imm negativo;
  - `srai` vs `srli`;
  - `lui`;
  - forwarding A/B desde cada fuente y prioridad EX/MEM > MEM/WB;
  - forwarding con rd = x0;
  - `sw` con rs2 forwardeado;
  - `beq`/`bne` tomados y no tomados;
  - `jal`, y `jalr` con bit 0 en 1;
  - burbuja;
  - `en = 0`.
