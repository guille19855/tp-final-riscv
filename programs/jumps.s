# jumps.s - jal y jalr: saltos incondicionales y llamadas a funcion.
#
# jal  rd, etiqueta   ->  rd = PC+4 ; PC = PC + imm
# jalr rd, imm(rs1)   ->  rd = PC+4 ; PC = (rs1 + imm) & ~1
# Siempre se toman: 2 ciclos de flush cada uno. Trampas como en branches.s.

        li    t6, 0             # se queda en 0 si ninguna trampa se ejecuta
        li    s0, 0

# --- jal hacia adelante, guardando el PC+4 ---
        jal   s1, j1            # s1 = direccion de la trampa de abajo
        addi  t6, t6, 1         # trampa
        addi  t6, t6, 2         # trampa
j1:     addi  s0, s0, 1

# --- jal con rd = x0 (j): no escribe nada ---
        j     j2
        addi  t6, t6, 4         # trampa
j2:     addi  s0, s0, 1

# --- llamada a funcion y vuelta con ret (jalr x0, 0(ra)) ---
        li    a0, 6
        jal   ra, doble         # a0 = 12
        addi  s2, a0, 0         # s2 = 12 (se ejecuta al volver)
        jal   ra, doble         # a0 = 24
        addi  s3, a0, 0         # s3 = 24

# --- funcion anidada: guarda ra en memoria (pila simple) ---
        li    sp, 0x400         # "pila" al final de la memoria usada
        li    a0, 3
        jal   ra, cuadruple     # a0 = 12
        addi  s4, a0, 0

# --- jalr con desplazamiento y con el bit 0 en 1 (se tiene que limpiar) ---
        jal   t0, base          # t0 = direccion de "base"
base:   jalr  t1, 9(t0)         # destino = (base + 9) & ~1 = base + 8
        addi  t6, t6, 8         # trampa (base + 4)
        addi  s5, zero, 0x55    # base + 8: aca cae

# --- jalr cuyo rs1 viene del load de la instruccion anterior (load-use) ---
        jal   t3, aca
aca:    addi  t3, t3, 20        # t3 = aca + 20 = direccion de "fin"
        sw    t3, 0(zero)
        lw    t4, 0(zero)
        jalr  zero, 0(t4)       # stall + forwarding MEM/WB al jalr
        addi  t6, t6, 16        # trampa
fin:    addi  s6, zero, 0x66
        halt

# ------------------------------------------------------------------
doble:  add   a0, a0, a0
        ret

cuadruple:
        addi  sp, sp, -4
        sw    ra, 0(sp)         # guardar la direccion de vuelta
        jal   ra, doble
        jal   ra, doble
        lw    ra, 0(sp)         # recuperarla
        addi  sp, sp, 4
        ret
