# load_use.s - el unico riesgo de datos que obliga a frenar (stall).
#
# El dato de un load recien existe al final de MEM; si la instruccion
# siguiente lo usa en EX, no llega: la unidad de hazard frena 1 ciclo y
# despues el forwarding MEM/WB lo resuelve.
#
# La memoria de datos arranca con palabra i = i (direccion 4*i).
# El modelo cuenta los stalls esperados (aca 6) y el TB compara los ciclos.

# --- load-use por rs1 ---                              stall 1
        lw    t0, 40(zero)      # t0 = 10 (palabra 10)
        addi  t1, t0, 1         # t1 = 11
        nop
        nop

# --- load-use por rs2 ---                              stall 2
        lw    t2, 80(zero)      # t2 = 20
        add   t3, zero, t2      # t3 = 20
        nop
        nop

# --- load-use por los dos operandos ---                stall 3
        lw    t4, 12(zero)      # t4 = 3
        add   t5, t4, t4        # t5 = 6
        nop
        nop

# --- load seguido de sw que guarda lo leido (dato = rs2) --- stall 4
        lw    t6, 400(zero)     # t6 = 100
        sw    t6, 0(zero)       # palabra 0 = 100
        nop
        nop

# --- load seguido de un load que usa el dato como direccion --- stall 5
        lw    a0, 32(zero)      # a0 = 8 (palabra 8)
        lw    a1, 4(a0)         # direccion 12 = palabra 3 -> a1 = 3
        nop
        nop

# --- distancia 2: NO frena (lo resuelve el forwarding) ---
        lw    a2, 20(zero)      # a2 = 5
        nop
        addi  a3, a2, 1         # a3 = 6, sin stall

# --- load a x0: no frena aunque la siguiente "use" x0 ---
        lw    zero, 8(zero)
        addi  a4, zero, 7       # a4 = 7, sin stall

# --- load que no se usa: no frena ---
        lw    a5, 24(zero)      # a5 = 6
        addi  a6, a4, 1         # usa a4, no a5: sin stall

# --- load-use con branch: el branch lee los dos registros ---  stall 6
        lw    a7, 28(zero)      # a7 = 7
        bne   a7, a4, mal       # 7 == 7: no salta
        addi  s0, zero, 1       # s0 = 1
        halt
mal:    addi  s0, zero, -1
        halt
