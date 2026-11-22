# Ejemplo: suma 1 + 2 + ... + 10 y guarda el resultado en memoria.
# Ensamblar:  python sw/asm.py programs/ejemplo.s
# Resultado esperado: x10 = 55 y la palabra 0 de la memoria de datos = 55.

        li    t0, 10          # contador
        li    a0, 0           # acumulador
loop:   add   a0, a0, t0      # a0 += t0
        addi  t0, t0, -1      # t0--
        bne   t0, zero, loop  # repetir mientras t0 != 0
        sw    a0, 0(zero)     # guardar 55 en la direccion 0
        lw    a1, 0(zero)     # leerlo de vuelta (a1 = 55)
        halt
