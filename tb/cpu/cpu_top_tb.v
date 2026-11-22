`timescale 1ns / 1ps
`include "riscv_defs.vh"

// Testbench de integracion del procesador completo (cpu_top.v).
//
// Corre un programa de programs/ y compara el estado final contra el modelo
// de referencia (sw/iss.py), que ejecuta lo mismo de a una instruccion por vez
// sin pipeline:
//   1. con reset = 1 carga programs/<PROG>.hex en la memoria de instrucciones
//      por el puerto B (como lo va a hacer la Debug Unit)
//   2. suelta el reset y corre hasta program_done (con timeout). Mientras
//      corre, verifica CADA escritura contra las trazas del modelo:
//        - cada registro que se escribe en WB, en orden   (<PROG>.trc)
//        - cada store que llega a MEM, en orden            (<PROG>.sto)
//      Asi tambien aparecen los valores intermedios mal calculados que despues
//      se pisan y no se verian en el estado final.
//   3. baja en y verifica que el pipeline quedo vacio
//   4. compara los ciclos, los 32 registros y las 1024 palabras de la memoria
//      de datos con programs/<PROG>.exp
//
// Plusargs:
//   PROG:<nombre>    programa a correr (sin extension). Por defecto: ejemplo
//   DIR:<ruta/>      carpeta de los programas. Por defecto la ruta relativa
//                    desde la carpeta de simulacion de la GUI de Vivado
//                    (project_final/project_final.sim/sim_1/behav/xsim)
//   TIMEOUT:<n>      ciclos maximos (por defecto 100000)
//   TRACE            muestra cada escritura de registro y store por ciclo
// Se usa ":" y no "=" porque xsim se lanza desde un .bat y cmd se come el "="
// (tambien se acepta "=" por si se llama a xsim directo).
// En la GUI: Settings -> Simulation -> Simulation -> More Options
//   (xsim.simulate.xsim.more_options) = -testplusarg PROG:forwarding
// Desde la terminal: scripts/run_programs.sh (ensambla, genera .exp/.trc/.sto
// y corre todos los programas)

module cpu_top_tb;

    reg         clk = 0, reset = 1, en = 0;
    reg         dbg_imem_we = 0;
    reg  [9:0]  dbg_imem_addr = 0, dbg_dmem_addr = 0;
    reg  [31:0] dbg_imem_wdata = 0;
    reg  [4:0]  dbg_reg_addr = 0;
    wire [31:0] dbg_imem_rdata, dbg_dmem_rdata, dbg_reg_data, pc;
    wire        program_done;

    cpu_top dut (
        .clk(clk), .reset(reset), .en(en),
        .dbg_imem_we(dbg_imem_we), .dbg_imem_addr(dbg_imem_addr),
        .dbg_imem_wdata(dbg_imem_wdata), .dbg_imem_rdata(dbg_imem_rdata),
        .dbg_dmem_addr(dbg_dmem_addr), .dbg_dmem_rdata(dbg_dmem_rdata),
        .dbg_dmem_used(), .dbg_used_clr(1'b0),
        .dbg_latch_sel(4'd0), .dbg_latch_data(),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
        .pc(pc), .program_done(program_done)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ------------------------------------------------------------------
    localparam EXP_INSTRET = 32 + 1024;     // posiciones dentro del .exp
    localparam EXP_CYCLES  = 32 + 1024 + 1;
    localparam MAX_TRACE   = 32768;         // igual que en sw/iss.py

    reg [31:0] program_img [0:1023];
    reg [31:0] expected    [0:EXP_CYCLES];
    reg [39:0] reg_trace   [0:MAX_TRACE-1]; // {rd (8 bits), valor}
    reg [67:0] store_trace [0:MAX_TRACE-1]; // {funct3 (4 bits), direccion, dato}
    integer    n_reg = 0, n_store = 0;      // escrituras verificadas
    integer    trace_errors = 0;
    reg [8*64-1:0]  prog;
    reg [8*256-1:0] dir, fname;
    reg [8*40-1:0]  name;
    integer timeout, trace;

    integer checks = 0, errors = 0;
    integer i, n_words, cycles, mem_errors;

    task check(input [31:0] got, input [31:0] exp, input [8*40-1:0] what, input quiet);
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
    // Verificacion de las trazas, en cada flanco con en = 1. Se lee el valor
    // que se escribe EN ESTE flanco (antes de que se actualicen los latches).
    // ------------------------------------------------------------------
    always @(posedge clk)
        if (en && !reset) begin
            // escritura de registro en WB
            if (dut.wb_reg_write && dut.wb_rd != 0) begin
                if (trace) $display("  [ciclo %0d] x%0d <= %h", cycles, dut.wb_rd, dut.wb_data);
                if ({3'b0, dut.wb_rd, dut.wb_data} !== reg_trace[n_reg]) begin
                    trace_errors = trace_errors + 1;
                    if (trace_errors <= 10)
                        $display("ERROR ciclo %0d, escritura %0d: x%0d <= %h, esperaba x%0d <= %h",
                                 cycles, n_reg, dut.wb_rd, dut.wb_data,
                                 reg_trace[n_reg][39:32], reg_trace[n_reg][31:0]);
                end
                n_reg = n_reg + 1;
            end
            // store en MEM
            if (dut.ex_mem_mem_write) begin
                if (trace) $display("  [ciclo %0d] store f3=%0d en %h <= %h", cycles,
                                    dut.ex_mem_funct3, dut.ex_mem_result, dut.ex_mem_rs2_data);
                if ({1'b0, dut.ex_mem_funct3, dut.ex_mem_result, dut.ex_mem_rs2_data}
                        !== store_trace[n_store]) begin
                    trace_errors = trace_errors + 1;
                    if (trace_errors <= 10)
                        $display("ERROR ciclo %0d, store %0d: f3=%0d %h <= %h, esperaba f3=%0d %h <= %h",
                                 cycles, n_store, dut.ex_mem_funct3, dut.ex_mem_result,
                                 dut.ex_mem_rs2_data, store_trace[n_store][66:64],
                                 store_trace[n_store][63:32], store_trace[n_store][31:0]);
                end
                n_store = n_store + 1;
            end
        end

    initial begin
        // --- parametros ---------------------------------------------------
        // (desde la terminal llegan como PROG:x, ver scripts/sim.sh)
        if (!$value$plusargs("PROG=%s", prog) && !$value$plusargs("PROG:%s", prog))
            prog = "ejemplo";
        if (!$value$plusargs("DIR=%s", dir) && !$value$plusargs("DIR:%s", dir))
            dir = "../../../../../programs/";
        if (!$value$plusargs("TIMEOUT=%d", timeout) && !$value$plusargs("TIMEOUT:%d", timeout))
            timeout = 100000;
        trace = $test$plusargs("TRACE");
        cycles = 0;

        for (i = 0; i < 1024; i = i + 1) program_img[i] = 32'hx;
        for (i = 0; i <= EXP_CYCLES; i = i + 1) expected[i] = 32'hx;
        $sformat(fname, "%0s%0s.hex", dir, prog);
        $readmemh(fname, program_img);
        $sformat(fname, "%0s%0s.exp", dir, prog);
        $readmemh(fname, expected);
        for (i = 0; i < MAX_TRACE; i = i + 1) begin
            reg_trace[i] = 40'hx; store_trace[i] = 68'hx;
        end
        $sformat(fname, "%0s%0s.trc", dir, prog);
        $readmemh(fname, reg_trace);
        $sformat(fname, "%0s%0s.sto", dir, prog);
        $readmemh(fname, store_trace);
        if (program_img[0] === 32'hx || expected[EXP_CYCLES] === 32'hx) begin
            $display("ERROR no pude leer %0s%0s.hex / .exp (correr asm.py e iss.py)", dir, prog);
            $display("TEST FAILED: 0 checks, 1 errors");
            $finish;
        end
        $display("Programa: %0s", prog);

        // --- 1. carga del programa por el puerto B (con reset = 1) -----------
        @(negedge clk);
        n_words = 0;
        while (n_words < 1024 && program_img[n_words] !== 32'hx) begin
            dbg_imem_we = 1; dbg_imem_addr = n_words; dbg_imem_wdata = program_img[n_words];
            @(negedge clk);
            n_words = n_words + 1;
        end
        dbg_imem_we = 0;
        $display("Cargadas %0d palabras", n_words);

        // --- 2. correr hasta program_done -----------------------------------
        reset = 0; en = 1;
        while (!program_done && cycles < timeout) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
        end
        @(negedge clk);
        en = 0;                                   // como la Debug Unit
        if (!program_done) begin
            $display("ERROR timeout: no llego a program_done en %0d ciclos (pc = %h)", timeout, pc);
            errors = errors + 1;
        end

        // --- trazas: cada escritura ya se comparo; faltan las que no ocurrieron
        checks = checks + n_reg + n_store;
        errors = errors + trace_errors;
        if (reg_trace[n_reg] !== 40'hx) begin
            errors = errors + 1;
            $display("ERROR faltan escrituras de registro: hubo %0d, el modelo hace mas", n_reg);
        end
        if (store_trace[n_store] !== 68'hx) begin
            errors = errors + 1;
            $display("ERROR faltan stores: hubo %0d, el modelo hace mas", n_store);
        end
        if (trace_errors == 0)
            $display("OK    trazas: %0d escrituras de registro y %0d stores iguales al modelo",
                     n_reg, n_store);

        // --- 3. pipeline vacio -------------------------------------------------
        check(dut.u_if.if_id_valid, 0,  "vacio: IF/ID invalido", 0);
        check(dut.halt, 1,              "vacio: IF dejo de buscar (halt)", 0);
        check({dut.id_ex_reg_write, dut.id_ex_mem_read, dut.id_ex_mem_write,
               dut.id_ex_branch, dut.id_ex_jal, dut.id_ex_jalr, dut.id_ex_halt}, 0,
              "vacio: ID/EX es burbuja", 0);
        check({dut.ex_mem_reg_write, dut.ex_mem_mem_read, dut.ex_mem_mem_write,
               dut.ex_mem_halt}, 0, "vacio: EX/MEM es burbuja", 0);

        // --- 4. ciclos, registros y memoria ---------------------------------
        check(cycles, expected[EXP_CYCLES], "ciclos (vs modelo)", 0);

        for (i = 0; i < 32; i = i + 1) begin
            dbg_reg_addr = i; #1;
            $sformat(name, "registro x%0d", i);
            check(dbg_reg_data, expected[i], name, 0);
        end

        // memoria de datos: lectura sincronica por el puerto B (el clock
        // sigue andando; en = 0 solo congela el puerto A del procesador)
        mem_errors = errors;
        for (i = 0; i < 1024; i = i + 1) begin
            @(negedge clk) dbg_dmem_addr = i;
            @(posedge clk); #1;
            check(dbg_dmem_rdata, expected[32 + i], "memoria de datos", 1);
        end
        if (errors == mem_errors) $display("OK    memoria de datos: 1024 palabras iguales al modelo");

        $display("Ciclos: %0d  Instrucciones: %0d  CPI = %0.3f", cycles,
                 expected[EXP_INSTRET], cycles * 1.0 / expected[EXP_INSTRET]);
        if (errors == 0) $display("TEST PASSED: %0d checks, 0 errors", checks);
        else             $display("TEST FAILED: %0d checks, %0d errors", checks, errors);
        $finish;
    end

endmodule
