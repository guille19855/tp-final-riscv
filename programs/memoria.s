# memoria.s - todos los anchos de load y store en todos los offsets.
#
# La memoria arranca con palabra i = i. Little-endian: el byte de la
# direccion 4k+0 son los bits [7:0] de la palabra k.

# --- leer los valores iniciales ---
        lw    s0, 0(zero)       # palabra 0 = 0
        lw    s1, 1020(zero)    # palabra 255 = 255 (0xFF)
        li    t6, 0xFFC
        lw    s2, 0(t6)         # ultima palabra (1023) = 0x3FF

# --- armar una palabra conocida y leerla por partes ---
        li    t0, 0x8081F2F3    # bytes (de 0 a 3): F3 F2 81 80
        sw    t0, 256(zero)     # palabra 64
        lb    a0, 256(zero)     # F3 -> 0xFFFFFFF3 (con signo)
        lbu   a1, 256(zero)     # F3 -> 0x000000F3
        lb    a2, 257(zero)     # F2 -> 0xFFFFFFF2
        lbu   a3, 258(zero)     # 81 -> 0x00000081
        lb    a4, 259(zero)     # 80 -> 0xFFFFFF80
        lh    a5, 256(zero)     # F2F3 -> 0xFFFFF2F3
        lhu   a6, 256(zero)     # F2F3 -> 0x0000F2F3
        lh    a7, 258(zero)     # 8081 -> 0xFFFF8081
        lhu   s3, 258(zero)     # 8081 -> 0x00008081

# --- bytes positivos: lb y lbu dan lo mismo ---
        li    t1, 0x7F01
        sw    t1, 260(zero)
        lb    s4, 260(zero)     # 0x01
        lb    s5, 261(zero)     # 0x7F

# --- sb en cada offset: solo cambia ese byte ---
        li    t2, -1            # 0xFFFFFFFF
        sw    zero, 264(zero)   # palabra 66 = 0
        sb    t2, 264(zero)     # 0x000000FF
        lw    s6, 264(zero)
        sw    zero, 268(zero)
        sb    t2, 269(zero)     # 0x0000FF00
        sw    zero, 272(zero)
        sb    t2, 274(zero)     # 0x00FF0000
        sw    zero, 276(zero)
        sb    t2, 279(zero)     # 0xFF000000

# --- sh en las dos mitades, sobre los valores iniciales (i) ---
        li    t3, 0xABCD1234
        sh    t3, 280(zero)     # palabra 70 = 0x46 -> 0x00001234
        sh    t3, 286(zero)     # palabra 71 = 0x47 -> 0x12340047
        lw    s7, 280(zero)
        lw    s8, 284(zero)

# --- sb sobre un valor inicial: el resto de la palabra se conserva ---
        sb    t3, 293(zero)     # palabra 73 = 0x49 -> 0x00003449

# --- direccion calculada con base + desplazamiento negativo ---
        li    t4, 0x200
        sw    t3, -4(t4)        # palabra 127
        lw    s9, -4(t4)
        lhu   s10, -2(t4)       # 0xABCD

# --- store seguido inmediatamente de load de la misma direccion ---
        li    t5, 0x5A5A
        sw    t5, 512(zero)
        lw    s11, 512(zero)    # 0x5A5A (la BRAM ya lo tiene escrito)
        halt
