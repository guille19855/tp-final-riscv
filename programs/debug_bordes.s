# debug_bordes.s - casos borde para la Debug Unit (Fase 8).
#
# - store en la PRIMERA (0x000) y en la ULTIMA (0xFFC) palabra de la memoria
#   de datos: el volcado tiene que recorrer el bitmap de punta a punta y
#   mandar la palabra 1023
# - jal y jalr al principio: se ven en el latch ID/EX en paso a paso
# - sb y sh: marcan la palabra como usada aunque escriban solo una parte
#
# Resultado: memoria usada = 0x000, 0x008, 0x00C y 0xFFC

        jal   ra, sigue         # ra = 4; salta la trampa
        addi  t6, zero, 1       # trampa (no se ejecuta)
sigue:  li    t0, -4            # 0xFFFFFFFC: [11:2] = 1023, la ultima palabra
        li    t1, 0x55
        sw    t1, 0(zero)       # primera palabra
        sw    t1, 0(t0)         # ultima palabra
        sb    t1, 9(zero)       # un byte de la palabra 2
        sh    t1, 14(zero)      # media palabra de la palabra 3
        jalr  sp, 40(zero)      # sp = 0x24; salta a fin (0x28)
        addi  t6, zero, 2       # trampa (no se ejecuta)
fin:    halt
