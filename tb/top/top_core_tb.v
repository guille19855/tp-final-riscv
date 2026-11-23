`timescale 1ns / 1ps

// Testbench autoverificable del sistema completo por UART (top_core.v):
// Debug Unit + UART + procesador. El TB hace de PC: tiene un MODELO DE UART
// que arma cada byte bit a bit en la linea rx (start, 8 datos LSB primero,
// stop) y otro que decodifica lo que sale por tx. No toca ninguna senal
// interna para manejar el sistema: todo pasa por los dos cables serie.
//
// Secuencia (con el programa PROG, por defecto ejemplo):
//   1. comando desconocido -> '?'
//   2. 'D' recien reseteado: PC = 0, ciclos = 0, sin memoria usada
//   3. 'L' + programa -> 'K';  'I' devuelve el mismo programa
//   4. 5 x 'S': un ciclo por paso; los 16 latches del volcado, decodificados
//      con la tabla de cpu_top.v, coinciden con las senales internas. Si el
//      programa dura <= 100 ciclos, se sigue en paso a paso HASTA EL FINAL
//      chequeando los latches en cada ciclo
//   5. 'C': corre hasta HALT (si ya termino en paso a paso, no ejecuta nada
//      y se chequea igual). Ciclos, 32 registros y memoria usada (pares
//      direccion/dato) contra el modelo de referencia (.exp y .sto de iss.py);
//      pipeline vacio
//   6. 'S' y 'C' despues de terminar: no ejecutan nada
//   7. 'R' -> 'K': PC y ciclos a 0; el bitmap de memoria usada se mantiene;
//      vuelve a correr hasta HALT
//   8. pausa: carga un lazo infinito (jal x0, 0), 'C', y un byte lo frena;
//      la carga borro el bitmap de memoria usada
//
// Plusargs (como cpu_top_tb): PROG:<nombre>  DIR:<carpeta/>
// Desde la terminal: scripts/sim.sh top_core_tb +DIR=../../programs/

module top_core_tb;

    localparam DVSR = 4;              // mas rapido que 27 (115200) para simular
    localparam BIT  = 16 * DVSR;      // ciclos de clock por bit

    reg         clk = 0, reset_in = 1, rx = 1;
    wire        tx;
    wire [15:0] led;
    wire [3:0]  an;
    wire [6:0]  seg;

    top_core #(.DVSR(DVSR), .REFRESH_BITS(4)) dut (
        .clk(clk), .reset_in(reset_in), .rx(rx), .tx(tx),
        .led(led), .an(an), .seg(seg)
    );

    always #10 clk = ~clk;            // 50 MHz, como en la placa

    // ------------------------------------------------------------------
    // Verificacion
    // ------------------------------------------------------------------
    integer checks = 0, errors = 0;
    reg [8*48-1:0] name;

    task check(input [31:0] got, input [31:0] exp, input [8*48-1:0] what, input quiet);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: %h, esperaba %h", what, got, exp);
            end else if (!quiet)
                $display("OK    %0s = %h", what, got);
        end
    endtask

    // ------------------------------------------------------------------
    // Modelo de UART: PC -> FPGA (linea rx)
    // ------------------------------------------------------------------
    task send_byte(input [7:0] b);
        integer k;
        begin
            rx = 1'b0;                                   // start
            repeat (BIT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin          // datos, LSB primero
                rx = b[k];
                repeat (BIT) @(posedge clk);
            end
            rx = 1'b1;                                   // stop
            repeat (BIT) @(posedge clk);
        end
    endtask

    task send_word(input [31:0] w);
        begin
            send_byte(w[7:0]);   send_byte(w[15:8]);
            send_byte(w[23:16]); send_byte(w[31:24]);
        end
    endtask

    // ------------------------------------------------------------------
    // Modelo de UART: FPGA -> PC (linea tx). Muestrea en el medio de cada
    // bit y guarda los bytes en una cola.
    // ------------------------------------------------------------------
    reg [7:0] rxq [0:65535];
    integer   wp = 0, rp = 0, framing_errors = 0;
    reg       monitor_on = 0;
    integer   fd_log;                // copia de lo recibido: uart_rx_log.hex
                                     // (la usa la prueba del decodificador Python)

    initial begin : uart_monitor
        reg [7:0] b;
        integer k;
        fd_log = $fopen("uart_rx_log.hex", "w");
        wait (monitor_on);
        forever begin
            @(negedge tx);                               // flanco del start
            repeat (BIT / 2) @(posedge clk);
            if (tx === 1'b0) begin
                for (k = 0; k < 8; k = k + 1) begin
                    repeat (BIT) @(posedge clk);
                    b[k] = tx;
                end
                repeat (BIT) @(posedge clk);
                if (tx !== 1'b1) framing_errors = framing_errors + 1;
                rxq[wp] = b;
                wp = wp + 1;
                $fdisplay(fd_log, "%h", b);
            end
        end
    end

    task recv_byte(output [7:0] b);
        integer t;
        begin
            t = 0;
            while (rp == wp && t < 400000) begin @(posedge clk); t = t + 1; end
            if (rp == wp) begin
                $display("ERROR timeout esperando un byte de la Debug Unit");
                errors = errors + 1;
                b = 8'hxx;
            end else begin
                b = rxq[rp];
                rp = rp + 1;
            end
        end
    endtask

    task recv_word(output [31:0] w);
        reg [7:0] b0, b1, b2, b3;
        begin
            recv_byte(b0); recv_byte(b1); recv_byte(b2); recv_byte(b3);
            w = {b3, b2, b1, b0};
        end
    endtask

    // ------------------------------------------------------------------
    // Volcado: 'D' + 51 palabras + pares (direccion, dato) + FFFFFFFF
    // ------------------------------------------------------------------
    reg  [31:0] fixw [0:50];
    reg  [31:0] used_addr [0:1023], used_data [0:1023];
    integer     n_used;

    task get_dump;
        reg [7:0]  h;
        reg [31:0] a, d;
        integer    k, done;
        begin
            recv_byte(h);
            check(h, "D", "volcado: cabecera 'D'", 1);
            for (k = 0; k < 51; k = k + 1) recv_word(fixw[k]);
            n_used = 0; done = 0;
            while (!done) begin
                recv_word(a);
                if (a === 32'hFFFF_FFFF || n_used == 1024 || a === 32'hxxxx_xxxx) done = 1;
                else begin
                    recv_word(d);
                    used_addr[n_used] = a; used_data[n_used] = d;
                    n_used = n_used + 1;
                end
            end
        end
    endtask

    task cmd(input [7:0] c);   // comando de 1 byte
        send_byte(c);
    endtask

    task expect_byte(input [7:0] exp, input [8*48-1:0] what);
        reg [7:0] b;
        begin
            recv_byte(b);
            check(b, exp, what, 0);
        end
    endtask

    // Los 16 latches del volcado, decodificados con la tabla de cpu_top.v,
    // contra las senales internas (el CPU esta congelado mientras manda)
    task check_latches(input [8*16-1:0] when);
        begin
            $sformat(name, "%0s IF/ID", when);
            check(fixw[35], dut.u_cpu.if_id_pc,    name, 1);
            check(fixw[36], dut.u_cpu.if_id_pc4,   name, 1);
            check(fixw[37], dut.u_cpu.if_id_instr, name, 1);
            check(fixw[38], {31'd0, dut.u_cpu.if_id_valid}, name, 1);
            $sformat(name, "%0s ID/EX", when);
            check(fixw[39], dut.u_cpu.id_ex_pc,       name, 1);
            check(fixw[40], dut.u_cpu.id_ex_pc4,      name, 1);
            check(fixw[41], dut.u_cpu.id_ex_rs1_data, name, 1);
            check(fixw[42], dut.u_cpu.id_ex_rs2_data, name, 1);
            check(fixw[43], dut.u_cpu.id_ex_imm,      name, 1);
            check(fixw[44][31:27], dut.u_cpu.id_ex_rs1,       name, 1);
            check(fixw[44][26:22], dut.u_cpu.id_ex_rs2,       name, 1);
            check(fixw[44][21:17], dut.u_cpu.id_ex_rd,        name, 1);
            check(fixw[44][16:14], dut.u_cpu.id_ex_funct3,    name, 1);
            check(fixw[44][13],    dut.u_cpu.id_ex_funct7b5,  name, 1);
            check(fixw[44][12],    dut.u_cpu.id_ex_alu_src_a, name, 1);
            check(fixw[44][11],    dut.u_cpu.id_ex_alu_src_b, name, 1);
            check(fixw[44][10:9],  dut.u_cpu.id_ex_alu_op,    name, 1);
            check(fixw[44][8:6],   {dut.u_cpu.id_ex_branch, dut.u_cpu.id_ex_jal,
                                    dut.u_cpu.id_ex_jalr},    name, 1);
            check(fixw[44][5:3],   {dut.u_cpu.id_ex_mem_read, dut.u_cpu.id_ex_mem_write,
                                    dut.u_cpu.id_ex_reg_write}, name, 1);
            check(fixw[44][2:0],   {dut.u_cpu.id_ex_wb_sel, dut.u_cpu.id_ex_halt}, name, 1);
            $sformat(name, "%0s EX/MEM", when);
            check(fixw[45], dut.u_cpu.ex_mem_result,   name, 1);
            check(fixw[46], dut.u_cpu.ex_mem_rs2_data, name, 1);
            check(fixw[47][31:14], 0,                     name, 1);
            check(fixw[47][13:9],  dut.u_cpu.ex_mem_rd,     name, 1);
            check(fixw[47][8:6],   dut.u_cpu.ex_mem_funct3, name, 1);
            check(fixw[47][5:0],   {dut.u_cpu.ex_mem_mem_read, dut.u_cpu.ex_mem_mem_write,
                                    dut.u_cpu.ex_mem_reg_write, dut.u_cpu.ex_mem_wb_sel,
                                    dut.u_cpu.ex_mem_halt}, name, 1);
            $sformat(name, "%0s MEM/WB", when);
            check(fixw[48], dut.u_cpu.mem_wb_result,    name, 1);
            check(fixw[49], dut.u_cpu.mem_wb_read_data, name, 1);
            check(fixw[50][31:15], 0,                      name, 1);
            check(fixw[50][14:10], dut.u_cpu.mem_wb_rd,      name, 1);
            check(fixw[50][9:7],   dut.u_cpu.mem_wb_funct3,  name, 1);
            check(fixw[50][6:5],   dut.u_cpu.mem_wb_addr_lo, name, 1);
            check(fixw[50][4:0],   {dut.u_cpu.mem_wb_mem_read, dut.u_cpu.mem_wb_reg_write,
                                    dut.u_cpu.mem_wb_wb_sel, dut.u_cpu.mem_wb_halt}, name, 1);
        end
    endtask

    // ------------------------------------------------------------------
    // Programa y resultado esperado (los mismos archivos que cpu_top_tb)
    // ------------------------------------------------------------------
    localparam EXP_INSTRET = 32 + 1024;
    localparam EXP_CYCLES  = 32 + 1024 + 1;
    localparam MAX_TRACE   = 32768;

    reg [31:0] program_img [0:1023];
    reg [31:0] expected    [0:EXP_CYCLES];
    reg [67:0] store_trace [0:MAX_TRACE-1];
    reg        exp_used    [0:1023];         // palabras que el modelo escribe
    reg [8*64-1:0]  prog;
    reg [8*256-1:0] dir, fname;

    integer i, k, n_words, n_exp_used, err0;
    reg [31:0] w, cycles_run1;
    reg [7:0]  b;

    // compara la lista de memoria usada del volcado contra el modelo
    task check_used_mem(input [8*16-1:0] when);
        begin
            err0 = errors;
            $sformat(name, "%0s: palabras de memoria usadas", when);
            check(n_used, n_exp_used, name, 0);
            k = 0;
            for (i = 0; i < 1024; i = i + 1)
                if (exp_used[i]) begin
                    if (k < n_used) begin
                        $sformat(name, "%0s: direccion usada %0d", when, k);
                        check(used_addr[k], i * 4, name, 1);
                        $sformat(name, "%0s: dato en %h", when, i * 4);
                        check(used_data[k], expected[32 + i], name, 1);
                    end
                    k = k + 1;
                end
            if (errors == err0)
                $display("OK    %0s: direcciones y datos de memoria usada iguales al modelo", when);
        end
    endtask

    initial begin
        if (!$value$plusargs("PROG=%s", prog) && !$value$plusargs("PROG:%s", prog))
            prog = "ejemplo";
        if (!$value$plusargs("DIR=%s", dir) && !$value$plusargs("DIR:%s", dir))
            dir = "../../../../../programs/";

        for (i = 0; i < 1024; i = i + 1) begin program_img[i] = 32'hx; exp_used[i] = 0; end
        for (i = 0; i <= EXP_CYCLES; i = i + 1) expected[i] = 32'hx;
        for (i = 0; i < MAX_TRACE; i = i + 1) store_trace[i] = 68'hx;
        $sformat(fname, "%0s%0s.hex", dir, prog); $readmemh(fname, program_img);
        $sformat(fname, "%0s%0s.exp", dir, prog); $readmemh(fname, expected);
        $sformat(fname, "%0s%0s.sto", dir, prog); $readmemh(fname, store_trace);
        if (program_img[0] === 32'hx || expected[EXP_CYCLES] === 32'hx) begin
            $display("ERROR no pude leer %0s%0s.hex / .exp (correr asm.py e iss.py)", dir, prog);
            $display("TEST FAILED: 0 checks, 1 errors");
            $finish;
        end
        n_words = 0;
        while (n_words < 1024 && program_img[n_words] !== 32'hx) n_words = n_words + 1;
        // memoria usada segun el modelo: cada palabra donde hubo un store
        n_exp_used = 0;
        for (i = 0; i < MAX_TRACE && store_trace[i] !== 68'hx; i = i + 1)
            if (!exp_used[store_trace[i][43:34]]) begin
                exp_used[store_trace[i][43:34]] = 1;
                n_exp_used = n_exp_used + 1;
            end
        $display("Programa: %0s (%0d palabras, %0d palabras de memoria escritas)",
                 prog, n_words, n_exp_used);

        repeat (5) @(posedge clk);
        reset_in = 0;
        monitor_on = 1;
        repeat (20) @(posedge clk);

        // ---------------- 1. comando desconocido ----------------
        cmd("Z");
        expect_byte("?", "comando desconocido -> '?'");

        // ---------------- 2. volcado recien reseteado ----------------
        cmd("D"); get_dump;
        check(fixw[0], 0, "reset: PC", 0);
        check(fixw[1], 0, "reset: ciclos", 0);
        check(fixw[2], 0, "reset: program_done", 0);
        check(n_used, 0,  "reset: memoria usada (ninguna)", 0);

        // ---------------- 3. carga y lectura del programa ----------------
        cmd("L"); send_byte(n_words[7:0]); send_byte(n_words[15:8]);
        for (i = 0; i < n_words; i = i + 1) send_word(program_img[i]);
        expect_byte("K", "carga -> 'K'");

        cmd("I");
        expect_byte("I", "'I' -> cabecera 'I'");
        recv_word(w);
        check(w, n_words, "'I': cantidad de palabras", 0);
        err0 = errors;
        for (i = 0; i < n_words; i = i + 1) begin
            recv_word(w);
            check(w, program_img[i], "'I': palabra del programa", 1);
        end
        if (errors == err0) $display("OK    'I': las %0d palabras coinciden con el .hex", n_words);

        // ---------------- 4. paso a paso ----------------
        for (k = 1; k <= 5; k = k + 1) begin
            cmd("S"); get_dump;
            $sformat(name, "paso %0d: ciclos", k);
            check(fixw[1], k, name, 0);
            $sformat(name, "paso %0d: PC", k);
            check(fixw[0], dut.u_cpu.pc, name, 1);
            $sformat(name, "paso %0d", k);
            err0 = errors;
            check_latches(name);
            if (errors == err0) $display("OK    paso %0d: PC y 16 latches decodificados = senales internas", k);
        end
        // programas cortos: TODO en paso a paso, latches chequeados en cada
        // ciclo (y el resultado tiene que ser el mismo que en continuo)
        if (expected[EXP_CYCLES] <= 100) begin
            err0 = errors;
            while (fixw[2] !== 1 && k <= 200) begin
                cmd("S"); get_dump;
                $sformat(name, "paso %0d: ciclos", k);
                check(fixw[1], k, name, 1);
                $sformat(name, "paso %0d", k);
                check_latches(name);
                k = k + 1;
            end
            if (errors == err0)
                $display("OK    paso a paso hasta HALT: %0d pasos, latches = senales internas en cada uno",
                         k - 1);
        end

        // ---------------- 5. continuo hasta HALT ----------------
        cmd("C"); get_dump;
        check(fixw[2], 1, "continuo: program_done", 0);
        check(fixw[1], expected[EXP_CYCLES], "continuo: ciclos (vs modelo)", 0);
        cycles_run1 = fixw[1];
        err0 = errors;
        for (i = 0; i < 32; i = i + 1) begin
            $sformat(name, "continuo: registro x%0d", i);
            check(fixw[3 + i], expected[i], name, 1);
        end
        if (errors == err0) $display("OK    continuo: 32 registros iguales al modelo");
        check_used_mem("continuo");
        check(fixw[38], 0, "vacio: IF/ID invalido", 0);
        // burbuja = bits de control con efecto en 0 (los datos quedan viejos):
        // ID/EX: branch jal jalr mem_read mem_write reg_write [8:3], halt [0]
        // EX/MEM: mem_read mem_write reg_write [5:3], halt [0]
        check(fixw[44] & 32'h1F9, 0, "vacio: ID/EX es burbuja", 0);
        check(fixw[47] & 32'h039, 0, "vacio: EX/MEM es burbuja", 0);
        check(fixw[50][0], 1, "vacio: el ebreak esta en MEM/WB", 0);
        check_latches("fin");
        $display("Ciclos: %0d  Instrucciones: %0d  CPI = %0.3f", fixw[1],
                 expected[EXP_INSTRET], fixw[1] * 1.0 / expected[EXP_INSTRET]);

        // ---------------- 6. despues de terminar ----------------
        cmd("S"); get_dump;
        check(fixw[1], cycles_run1, "'S' despues de HALT: no ejecuta", 0);
        cmd("C"); get_dump;
        check(fixw[1], cycles_run1, "'C' despues de HALT: no ejecuta", 0);

        // ---------------- 7. reset y volver a correr ----------------
        cmd("R");
        expect_byte("K", "'R' -> 'K'");
        cmd("D"); get_dump;
        check(fixw[0], 0, "'R': PC = 0", 0);
        check(fixw[1], 0, "'R': ciclos = 0", 0);
        check(fixw[2], 0, "'R': program_done = 0", 0);
        err0 = errors;
        for (i = 0; i < 32; i = i + 1) check(fixw[3 + i], 0, "'R': registros en 0", 1);
        if (errors == err0) $display("OK    'R': 32 registros en 0");
        check_used_mem("'R'");                   // la memoria no se borra
        // (la segunda corrida parte de la memoria que dejo la primera, asi
        //  que solo se exige que vuelva a terminar)
        cmd("C"); get_dump;
        check(fixw[2], 1, "'R' + 'C': vuelve a terminar", 0);

        // ---------------- 8. pausa de un programa que no termina ----------------
        cmd("L"); send_byte(1); send_byte(0);
        send_word(32'h0000_006F);                // jal x0, 0  (lazo infinito)
        expect_byte("K", "carga del lazo infinito -> 'K'");
        cmd("D"); get_dump;
        check(n_used, 0, "carga nueva: bitmap de memoria usada borrado", 0);
        cmd("C");
        repeat (3000) @(posedge clk);
        check(led[14], 1, "LED14: corriendo", 0);
        cmd("P");                                // cualquier byte lo pausa
        get_dump;
        check(fixw[2], 0, "pausa: no termino", 0);
        w = fixw[1];
        check(w > 3000, 1, "pausa: corrio mas de 3000 ciclos", 0);
        cmd("D"); get_dump;
        check(fixw[1], w, "pausa: queda congelado", 0);
        check(led[14], 0, "LED14: ya no corre", 0);
        cmd("I");
        expect_byte("I", "'I' tras la segunda carga");
        recv_word(w); check(w, 1, "'I': 1 palabra", 0);
        recv_word(w); check(w, 32'h0000_006F, "'I': jal x0, 0", 0);

        check(framing_errors, 0, "UART: sin errores de trama", 0);
        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
