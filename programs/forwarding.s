# forwarding.s - riesgos de datos que se resuelven SIN frenar.
#
#   distancia 1: el dato esta en EX/MEM  -> forward 10
#   distancia 2: el dato esta en MEM/WB  -> forward 01
#   distancia 3: WB escribe y ID lee el mismo ciclo -> bypass del banco
#
# Cada bloque arranca con nops para que no se mezclen con el anterior.

# --- distancia 1, por rs1 y por rs2 ---
        addi  t0, zero, 5
        addi  t1, t0, 1         # rs1 <- EX/MEM: t1 = 6
        add   t2, zero, t1      # rs2 <- EX/MEM: t2 = 6
        nop
        nop
        nop

# --- distancia 2 ---
        addi  s0, zero, 10
        nop
        addi  s1, s0, 1         # rs1 <- MEM/WB: s1 = 11
        nop
        nop
        nop

# --- distancia 3 (bypass del banco de registros) ---
        addi  s2, zero, 20
        nop
        nop
        addi  s3, s2, 1         # s3 = 21
        nop
        nop
        nop

# --- los dos operandos forwardeados a la vez, de fuentes distintas ---
        addi  a0, zero, 100
        addi  a1, zero, 200
        sub   a2, a1, a0        # a1 <- EX/MEM, a0 <- MEM/WB: a2 = 100
        nop
        nop
        nop

# --- prioridad: el mismo registro en EX/MEM y en MEM/WB ---
#     tiene que ganar EX/MEM (el valor mas nuevo)
        addi  a3, zero, 1       # valor viejo (MEM/WB)
        addi  a3, zero, 2       # valor nuevo (EX/MEM)
        addi  a4, a3, 0         # a4 = 2, no 1
        nop
        nop
        nop

# --- cadena: cada instruccion usa la anterior ---
        addi  a5, zero, 1
        add   a5, a5, a5        # 2
        add   a5, a5, a5        # 4
        add   a5, a5, a5        # 8
        add   a5, a5, a5        # 16
        nop
        nop
        nop

# --- rd = x0: no se tiene que forwardear ---
        addi  zero, zero, 77    # escribe x0 (se descarta)
        add   a6, zero, zero    # si forwardeara 77, a6 = 154; tiene que ser 0
        nop
        nop
        nop

# --- dato del sw forwardeado (rs2), con la ALU usando el inmediato ---
        addi  a7, zero, 0x55
        sw    a7, 64(zero)      # dato <- EX/MEM
        addi  s4, zero, 0x66
        nop
        sw    s4, 68(zero)      # dato <- MEM/WB
        addi  s5, zero, 0x80    # base del sw tambien forwardeada
        sw    s4, 8(s5)         # direccion 0x88
        nop
        nop
        nop

# --- forward del PC+4 de un jal (decision 1-A de EX) ---
        jal   s6, sigue         # s6 = direccion del addi de abajo
sigue:  addi  s7, s6, 0         # s7 = s6 (si forwardeara el resultado de la ALU, mal)
        halt
