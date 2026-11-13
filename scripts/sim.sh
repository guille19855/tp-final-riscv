#!/usr/bin/env bash
# Corre un testbench con el simulador de Vivado (xsim) desde la terminal,
# sin abrir la GUI. Compila todo rtl/, los modelos de simulacion de los IP
# (BRAM) y el testbench pedido.
#
# Uso:   scripts/sim.sh <nombre_del_tb>          ej: scripts/sim.sh if_stage_tb
#        scripts/sim.sh <nombre_del_tb> --wave   guarda formas de onda (.wdb)
#
# Es lo mismo que hace "Run Simulation" en Vivado (xvlog -> xelab -> xsim),
# pero mas rapido para iterar. La salida queda en sim_out/ (no versionar).
#
# Los IP tienen que estar generados en Vivado (Generate Output Products):
# se usan sus modelos de project_final.gen/sources_1/ip/<ip>/sim/ y el .mif
# con el contenido inicial de la memoria.

set -e
TB="$1"
[ -z "$TB" ] && { echo "uso: $0 <testbench> [--wave]"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIVADO="${VIVADO:-/c/Xilinx/Vivado/2022.2}"
BIN="$VIVADO/bin"
IP_GEN="$ROOT/project_final/project_final.gen/sources_1/ip"
OUT="$ROOT/sim_out/$TB"
mkdir -p "$OUT"
cd "$OUT"

TB_FILE="$(find "$ROOT/tb" -name "$TB.v" | head -1)"
[ -z "$TB_FILE" ] && { echo "no encuentro tb/**/$TB.v"; exit 1; }

RTL_FILES="$(find "$ROOT/rtl" -name '*.v')"
IP_FILES=""
if [ -d "$IP_GEN" ]; then
    IP_FILES="$(find "$IP_GEN" -path '*/sim/*.v')"
    cp -f $(find "$IP_GEN" -maxdepth 2 -name '*.mif') . 2>/dev/null || true
fi

"$BIN/xvlog.bat" -i "$ROOT/rtl/cpu" $RTL_FILES $IP_FILES "$VIVADO/data/verilog/src/glbl.v" "$TB_FILE" > xvlog.log 2>&1 \
    || { grep -E "ERROR|WARNING" xvlog.log; exit 1; }

LIBS="-L blk_mem_gen_v8_4_5 -L unisims_ver -L unimacro_ver -L secureip -L xpm"
if [ "$2" = "--wave" ]; then DEBUG=typical; else DEBUG=off; fi
"$BIN/xelab.bat" -debug $DEBUG $LIBS "$TB" glbl -s "${TB}_sim" > xelab.log 2>&1 \
    || { grep -E "ERROR" xelab.log; exit 1; }

if [ "$2" = "--wave" ]; then
    echo "log_wave -recursive *; run all; exit" > wave.tcl
    "$BIN/xsim.bat" "${TB}_sim" -tclbatch wave.tcl -wdb "$TB.wdb" | grep -vE "^\*\*\*\*|^INFO|^#|Time resolution"
    echo "formas de onda: $OUT/$TB.wdb"
else
    "$BIN/xsim.bat" "${TB}_sim" -R | grep -vE "^\*\*\*\*|^INFO|^#|Time resolution"
fi
