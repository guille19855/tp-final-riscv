#!/usr/bin/env bash
# Regresion del procesador completo: para cada programa
#   1. lo ensambla           (sw/asm.py   -> .hex)
#   2. corre el modelo        (sw/iss.py   -> .exp)
#   3. lo simula en el pipeline y compara (tb/cpu/cpu_top_tb.v)
#
# Uso:  scripts/run_programs.sh                 dirigidos + 20 aleatorios
#       scripts/run_programs.sh forwarding      solo ese programa (de programs/)
#       RANDOM_CANT=50 scripts/run_programs.sh  mas aleatorios
#       TB=top_core_tb scripts/run_programs.sh  por UART, con la Debug Unit
#                                               (tb/top/top_core_tb.v)
#
# Al final imprime una tabla con ciclos, instrucciones, CPI y resultado.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -n "$1" ]; then
    PROGS="programs/$1.s"
else
    python sw/gen_random.py --cant "${RANDOM_CANT:-20}" > /dev/null || exit 1
    PROGS="$(ls programs/*.s) $(ls programs/random/*.s)"
fi

TB="${TB:-cpu_top_tb}"
COMPILE=""
FAILS=0
printf "%-28s %7s %7s %6s  %s\n" "programa" "ciclos" "instr" "CPI" "resultado"
for s in $PROGS; do
    name="$(basename "$s" .s)"
    dir="$(dirname "$s")"
    python sw/asm.py "$s" > /dev/null || { echo "$name: error al ensamblar"; FAILS=$((FAILS+1)); continue; }
    python sw/iss.py "$s" > /dev/null || { echo "$name: error en el modelo";  FAILS=$((FAILS+1)); continue; }
    # sim.sh corre en sim_out/<tb>: la carpeta del programa es relativa a esa
    out="$(scripts/sim.sh $TB $COMPILE +PROG="$name" +DIR="../../$dir/" 2>&1)"
    COMPILE="--no-compile"                     # compila solo la primera vez
    stats="$(echo "$out" | grep '^Ciclos:' | awk '{print $2, $4, $7}')"
    result="$(echo "$out" | grep -E '^TEST (PASSED|FAILED)')"
    [ -z "$result" ] && result="SIN RESULTADO"
    printf "%-28s %7s %7s %6s  %s\n" "$name" $stats "$result"
    if ! echo "$result" | grep -q PASSED; then
        FAILS=$((FAILS+1))
        echo "$out" | grep -E '^ERROR' | head -10
    fi
done

echo
if [ $FAILS -eq 0 ]; then echo "TODOS LOS PROGRAMAS PASARON"; else echo "$FAILS PROGRAMA(S) FALLARON"; exit 1; fi
