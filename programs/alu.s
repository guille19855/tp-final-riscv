# alu.s - todas las operaciones de la ALU (tipo R, tipo I y lui).
# Sin dependencias raras: prueba el camino de datos ID -> EX -> WB.
# Los valores esperados los calcula sw/iss.py; los comentarios son una ayuda.

        li    s0, 0x80000005    # negativo grande
        li    s1, 7
        li    s2, -3            # 0xFFFFFFFD
        li    s3, 0x0F0F00FF
        nop
        nop
        nop

# --- tipo R ---
        add   t0, s0, s1        # 0x8000000C
        sub   t1, s1, s0        # 7 - 0x80000005 = 0x80000002
        sll   t2, s1, s1        # 7 << 7 = 0x380
        slt   t3, s0, s1        # negativo < 7 -> 1 (con signo)
        sltu  t4, s0, s1        # 0x80000005 < 7 -> 0 (sin signo)
        xor   t5, s3, s2        # 0xF0F0FF02
        srl   t6, s0, s1        # logico: 0x01000000
        sra   a0, s0, s1        # aritmetico: 0xFF000000
        or    a1, s3, s1        # 0x0F0F00FF
        and   a2, s3, s2        # 0x0F0F00FD

# --- shift con rs2 > 31: solo cuentan los 5 bits bajos (b[4:0]) ---
        li    a3, 33
        nop
        nop
        nop
        sll   a4, s1, a3        # 7 << 1 = 14

# --- tipo I ---
        addi  a5, s1, -10       # imm negativo: bit 30 en 1, NO tiene que restar
        slti  a6, s2, -2        # -3 < -2 -> 1
        sltiu a7, s1, -1        # 7 < 0xFFFFFFFF -> 1
        xori  s4, s1, -1        # not 7 = 0xFFFFFFF8
        ori   s5, s1, 0x700     # 0x707
        andi  s6, s3, -16       # 0x0F0F00F0
        slli  s7, s1, 31        # 0x80000000
        srli  s8, s0, 4         # 0x08000000
        srai  s9, s0, 4         # 0xF8000000
        lui   s10, 0xABCDE      # 0xABCDE000
        addi  s11, zero, -2048  # el inmediato mas negativo

# --- x0 no se escribe nunca ---
        addi  zero, zero, 123
        add   ra, zero, zero    # ra = 0 (x0 sigue en 0)
        halt
