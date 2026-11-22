// Sistema completo sin el Clock Wizard (Fase 8): UART + Debug Unit + CPU.
//
// Esta separado de top.v (que solo agrega el Clock Wizard) para poder
// simularlo con un clock comun, sin el modelo del MMCM. Es lo que prueba
// tb/top/top_core_tb.v con un modelo de UART en el testbench.
//
//   rx (PC) -> sincronizador -> uart_rx --bytes--> debug_unit --en/reset--> cpu_top
//   tx (PC) <------------------ uart_tx <--bytes--/     \---- puertos dbg_* ---/
//
// La UART es la del TP2 sin cambios. DVSR = f_clk / (baudios * 16):
//   50 MHz, 115200 baudios -> 50e6 / 1_843_200 = 27,13 -> 27 (error 0,5 %)
//
// Placa (sin switches: SW3 de nuestra Basys3 no anda, ver prueba en placa):
//   display  PC[15:0]
//   LED15 program_done   LED14 corriendo (C)   LED13 cargando (L)
//   LED7..0 PC[9:2] (numero de instruccion)
//
// Reset: reset_in (BTNC o Clock Wizard sin enganchar) sincronizado con 2 FF.

`timescale 1ns / 1ps

module top_core #(
    parameter integer DVSR         = 27,   // 115200 baudios a 50 MHz
    parameter integer REFRESH_BITS = 18
) (
    input  wire        clk,
    input  wire        reset_in,     // asincronico
    input  wire        rx,           // linea serie desde la PC
    output wire        tx,           // linea serie hacia la PC
    output wire [15:0] led,
    output wire [3:0]  an,
    output wire [6:0]  seg
);

    // ------------------------------------------------------------------
    // Reset y rx sincronizados
    // ------------------------------------------------------------------
    reg rst_meta, rst;
    always @(posedge clk) {rst, rst_meta} <= {rst_meta, reset_in};

    // rx viene de afuera, sin relacion con nuestro clock: 2 FF para evitar
    // metaestabilidad. Sin reset A PROPOSITO: la linea en reposo vale 1 y un
    // reset a 0 la UART lo veria como un bit de start falso. Durante el reset
    // general la UART esta en reset igual, y estos FF ya copiaron la linea.
    reg rx_meta, rx_sync;
    always @(posedge clk) {rx_sync, rx_meta} <= {rx_meta, rx};

    // ------------------------------------------------------------------
    // UART (TP2)
    // ------------------------------------------------------------------
    wire       tick, rx_done, tx_done, tx_start;
    wire [7:0] rx_data, tx_data;

    baud_rate_gen #(.DVSR(DVSR)) u_baud (.clk(clk), .reset(rst), .tick(tick));

    uart_rx u_rx (
        .clk(clk), .reset(rst), .rx(rx_sync), .s_tick(tick),
        .rx_done(rx_done), .d_out(rx_data)
    );

    uart_tx u_tx (
        .clk(clk), .reset(rst), .tx_start(tx_start), .s_tick(tick),
        .d_in(tx_data), .tx_done(tx_done), .tx(tx)
    );

    // ------------------------------------------------------------------
    // Debug Unit
    // ------------------------------------------------------------------
    wire        cpu_reset, cpu_en, program_done;
    wire [31:0] pc;
    wire        imem_we;
    wire [9:0]  imem_addr, dmem_addr;
    wire [31:0] imem_wdata, imem_rdata, dmem_rdata, reg_data, latch_data;
    wire        dmem_used, used_clr;
    wire [4:0]  reg_addr;
    wire [3:0]  latch_sel;
    wire        loading, running;

    debug_unit u_du (
        .clk(clk), .reset(rst),
        .rx_data(rx_data), .rx_done(rx_done),
        .tx_start(tx_start), .tx_data(tx_data), .tx_done(tx_done),
        .cpu_reset(cpu_reset), .cpu_en(cpu_en),
        .program_done(program_done), .pc(pc),
        .imem_we(imem_we), .imem_addr(imem_addr),
        .imem_wdata(imem_wdata), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_rdata(dmem_rdata),
        .dmem_used(dmem_used), .used_clr(used_clr),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .latch_sel(latch_sel), .latch_data(latch_data),
        .loading(loading), .running(running)
    );

    // ------------------------------------------------------------------
    // Procesador
    // ------------------------------------------------------------------
    cpu_top u_cpu (
        .clk(clk), .reset(cpu_reset), .en(cpu_en),
        .dbg_imem_we(imem_we), .dbg_imem_addr(imem_addr),
        .dbg_imem_wdata(imem_wdata), .dbg_imem_rdata(imem_rdata),
        .dbg_dmem_addr(dmem_addr), .dbg_dmem_rdata(dmem_rdata),
        .dbg_dmem_used(dmem_used), .dbg_used_clr(used_clr),
        .dbg_reg_addr(reg_addr), .dbg_reg_data(reg_data),
        .dbg_latch_sel(latch_sel), .dbg_latch_data(latch_data),
        .pc(pc), .program_done(program_done)
    );

    // ------------------------------------------------------------------
    // Display y LEDs
    // ------------------------------------------------------------------
    seven_seg #(.REFRESH_BITS(REFRESH_BITS)) u_seg (
        .clk(clk), .reset(rst), .value(pc[15:0]), .an(an), .seg(seg)
    );

    assign led = {program_done, running, loading, 5'b0, pc[9:2]};

endmodule
