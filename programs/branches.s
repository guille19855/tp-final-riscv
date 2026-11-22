# branches.s - riesgos de control con beq/bne (saltos resueltos en EX).
#
# Predict not-taken: el pipeline sigue buscando las instrucciones de abajo.
# Si el salto se toma, las 2 que entraron detras (en IF e ID) son del camino
# equivocado y se descartan (flush). Para verificarlo, despues de cada salto
# tomado hay instrucciones "trampa" que escriben 0xBAD: si alguna se ejecuta,
# el registro t6 no coincide con el modelo y el test falla.

        li    s0, 5
        li    s1, 5
        li    s2, 9
        li    t6, 0             # se queda en 0 si ninguna trampa se ejecuta

# --- beq tomado ---
        beq   s0, s1, b1
        addi  t6, t6, 0x1       # trampa (estaba en ID)
        addi  t6, t6, 0x2       # trampa (estaba en IF)
        addi  t6, t6, 0x4       # trampa
b1:     addi  a0, zero, 1

# --- beq no tomado: las siguientes SI se ejecutan ---
        beq   s0, s2, mal
        addi  a1, zero, 2
        addi  a2, zero, 3

# --- bne tomado ---
        bne   s0, s2, b2
        addi  t6, t6, 0x10      # trampa
        addi  t6, t6, 0x20      # trampa
b2:     addi  a3, zero, 4

# --- bne no tomado ---
        bne   s0, s1, mal
        addi  a4, zero, 5

# --- branch que depende del resultado de la instruccion anterior ---
#     (los operandos del branch vienen por forwarding desde EX/MEM)
        addi  s3, zero, 9
        beq   s3, s2, b3        # 9 == 9: salta
        addi  t6, t6, 0x40      # trampa
b3:     addi  a5, zero, 6

# --- salto a la instruccion siguiente (offset 4): tomado igual cuesta 2 ---
        beq   zero, zero, b4
b4:     addi  a6, zero, 7

# --- dos saltos tomados seguidos ---
        beq   zero, zero, b5
        addi  t6, t6, 0x80      # trampa
b5:     bne   s0, s2, b6
        addi  t6, t6, 0x100     # trampa
b6:     addi  a7, zero, 8

# --- lazo hacia atras: suma 1..5 en s4 ---
        li    s4, 0
        li    s5, 5
lazo:   add   s4, s4, s5
        addi  s5, s5, -1
        bne   s5, zero, lazo    # tomado 4 veces, no tomado la ultima
        addi  s6, zero, 15      # s4 tiene que ser 15

# --- ebreak en el camino equivocado: NO tiene que terminar el programa ---
        beq   zero, zero, b7
        halt                    # trampa: si para aca, s7 queda en 0
        addi  t6, t6, 0x200     # trampa
b7:     addi  s7, zero, 0x77
        halt

mal:    addi  t6, t6, 0x400     # solo si un branch no tomado salto
        halt
