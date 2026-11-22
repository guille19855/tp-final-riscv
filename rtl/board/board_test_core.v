// Prueba temprana en la placa (antes de la Debug Unit): toda la logica.
//
// Esta separado de board_test_top.v (que solo agrega el Clock Wizard) para
// poder simularlo con un clock comun, sin el modelo del MMCM.
//
// Que hace:
//   1. CARGA: al salir del reset copia el programa de una ROM interna
//      (inicializada con $readmemh) a la memoria de instrucciones por el
//      puerto B, una palabra por ciclo. Es el mismo camino que va a usar la
//      Debug Unit con el programa que llegue por UART. Mientras carga, el
//      procesador esta en reset.
//   2. EJECUCION, dos modos segun SW15 (con el clock siempre corriendo):
//        SW15 = 1  continuo:     en = 1 hasta program_done
//        SW15 = 0  paso a paso:  en = 1 durante UN ciclo por cada apriete
//                                de BTNR (antirrebote + pulso)
//      Al llegar a program_done se baja en (como lo va a hacer la Debug
//      Unit): el pipeline queda congelado y vacio, y program_done queda en 1.
//   3. VISUALIZACION:
//        display  SW13 = 1: PC[15:0]
//                 SW13 = 0: registro SW12..8, mitad alta (SW14 = 1) o baja
//        LED15 program_done   LED14 programa cargado   LED13 modo continuo
//        LED12..8 SW12..8 (registro elegido)   LED7..0 PC[9:2] (n. de instruccion)
//
// Reset: BTNC o el Clock Wizard sin enganchar (locked = 0). Se sincroniza con
// 2 FF. Todos los FF resetean a 0.

`timescale 1ns / 1ps

module board_test_core #(
    parameter         PROG_FILE    = "board_prog.mem",  // programa (.hex de asm.py)
    parameter integer ROM_WORDS    = 256,
    parameter integer DEB_CYCLES   = 500_000,            // 10 ms a 50 MHz
    parameter integer REFRESH_BITS = 18
) (
    input  wire        clk,
    input  wire        reset_in,     // BTNC | ~locked (asincronico)
    input  wire        btn_step,     // BTNR
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [3:0]  an,
    output wire [6:0]  seg
);

    // ------------------------------------------------------------------
    // Reset sincronizado
    // ------------------------------------------------------------------
    reg rst_meta, rst;
    always @(posedge clk) {rst, rst_meta} <= {rst_meta, reset_in};

    // ------------------------------------------------------------------
    // ROM con el programa + cargador
    // ------------------------------------------------------------------
    localparam AW = $clog2(ROM_WORDS);

    reg [31:0] rom [0:ROM_WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < ROM_WORDS; k = k + 1) rom[k] = 32'd0;
        if (PROG_FILE != "") $readmemh(PROG_FILE, rom);   // en simulacion lo carga el TB
    end

    reg [AW-1:0] load_addr;
    reg          loaded;             // 0 = cargando
    always @(posedge clk) begin
        if (rst) begin
            load_addr <= 0;
            loaded    <= 1'b0;
        end else if (!loaded) begin
            load_addr <= load_addr + 1'b1;
            if (load_addr == ROM_WORDS - 1) loaded <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Paso a paso
    // ------------------------------------------------------------------
    wire step_pulse;
    debouncer #(.STABLE_CYCLES(DEB_CYCLES)) u_deb (
        .clk(clk), .reset(rst), .btn(btn_step), .level(), .pulse(step_pulse)
    );

    wire continuo = sw[15];

    // Registro a mostrar: SW12..8. (Se usaba SW4..0, pero en nuestra placa
    // SW3 no hace contacto: lo vimos con el eco en LED11.)
    wire [4:0] reg_sel = sw[12:8];

    // ------------------------------------------------------------------
    // Procesador
    // ------------------------------------------------------------------
    wire        program_done;
    wire [31:0] pc, reg_data;
    wire        en = loaded & ~program_done & (continuo | step_pulse);

    cpu_top u_cpu (
        .clk(clk), .reset(rst | ~loaded), .en(en),
        .dbg_imem_we(~loaded), .dbg_imem_addr({{(10-AW){1'b0}}, load_addr}),
        .dbg_imem_wdata(rom[load_addr]), .dbg_imem_rdata(),
        .dbg_dmem_addr(10'd0), .dbg_dmem_rdata(), .dbg_dmem_used(), .dbg_used_clr(1'b0),
        .dbg_latch_sel(4'd0), .dbg_latch_data(),
        .dbg_reg_addr(reg_sel), .dbg_reg_data(reg_data),
        .pc(pc), .program_done(program_done)
    );

    // ------------------------------------------------------------------
    // Display y LEDs
    // ------------------------------------------------------------------
    wire [15:0] shown = sw[13] ? pc[15:0] :
                        sw[14] ? reg_data[31:16] : reg_data[15:0];

    seven_seg #(.REFRESH_BITS(REFRESH_BITS)) u_seg (
        .clk(clk), .reset(rst), .value(shown), .an(an), .seg(seg)
    );

    // LED12..8 repiten SW12..8: muestran que registro esta leyendo el FPGA
    assign led = {program_done, loaded, continuo, reg_sel, pc[9:2]};

endmodule
