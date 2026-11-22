// Debug Unit (Fase 8): controla el procesador desde la PC por UART.
//
// Trabaja con BYTES: la UART (rx/tx del TP2) esta afuera, en top_core.v.
// Es una sola maquina de estados mas un "emisor" de palabras de 32 bits.
//
// ---------------------------------------------------------------------------
// PROTOCOLO (comandos de 1 byte desde la PC; palabras de 32 bits little-endian)
// ---------------------------------------------------------------------------
//  'L' N0 N1 + N palabras   carga N = N0 + 256*N1 palabras (N <= 1024) en la
//                           memoria de instrucciones, desde la direccion 0.
//                           Mientras carga, el CPU esta en reset. Ademas borra
//                           el bitmap de memoria usada.          Responde 'K'
//  'R'                      reset del CPU (vuelve a PC = 0, ciclos = 0). La
//                           memoria de datos NO se borra.        Responde 'K'
//  'C'                      continuo: en = 1 hasta program_done. Cualquier
//                           byte que llegue mientras corre lo PAUSA (para
//                           programas que no terminan); ese byte se descarta.
//                                                                Responde volcado
//  'S'                      un paso: en = 1 durante UN ciclo.    Responde volcado
//  'D'                      volcado sin ejecutar.                Responde volcado
//  'I'                      lee el programa cargado:   'I' N + N palabras
//  otro                     Responde '?'
//
//  Si el programa ya termino (program_done), 'C' y 'S' no ejecutan nada y
//  solo responden el volcado: el pipeline queda vacio y congelado.
//
// VOLCADO:  'D' + 51 palabras fijas + pares (direccion, dato) + 0xFFFFFFFF
//   palabra 0       PC (el de IF)
//   palabra 1       ciclos ejecutados desde el ultimo reset/carga
//   palabra 2       estado: bit 0 = program_done
//   palabras 3..34  registros x0..x31
//   palabras 35..50 latches (cpu_top.v, tabla "Latches para la Debug Unit")
//   despues, por cada palabra de la memoria de datos escrita por un store
//   (en orden de direccion): direccion en bytes, dato. Termina con FFFFFFFF
//   (no es una direccion valida: la memoria tiene 4 KB).
//
// Tiempos a 115200 baudios (~11,5 KB/s): volcado ~18 ms + 0,7 ms por
// palabra de memoria usada; cargar 1024 palabras ~0,36 s.
//
// ---------------------------------------------------------------------------
// CONTROL DEL PROCESADOR (sin tocar el clock)
// ---------------------------------------------------------------------------
//   cpu_en    = 1 solo en RUN (hasta program_done) o durante el ciclo de STEP
//   cpu_reset = reset general | cargando | pulso de 'R'
// cpu_en se baja en el MISMO ciclo en que aparece program_done (es
// combinacional), asi el ebreak queda en WB y el pipeline vacio.

`timescale 1ns / 1ps

module debug_unit (
    input  wire        clk,
    input  wire        reset,

    // --- UART (de a bytes) ---
    input  wire [7:0]  rx_data,
    input  wire        rx_done,      // pulso de 1 ciclo: llego rx_data
    output reg         tx_start,     // pulso de 1 ciclo: mandar tx_data
    output reg  [7:0]  tx_data,
    input  wire        tx_done,      // pulso de 1 ciclo: termino el byte

    // --- Control del procesador ---
    output wire        cpu_reset,
    output wire        cpu_en,
    input  wire        program_done,
    input  wire [31:0] pc,

    // --- Puertos de debug de cpu_top ---
    output reg         imem_we,
    output reg  [9:0]  imem_addr,
    output reg  [31:0] imem_wdata,
    input  wire [31:0] imem_rdata,   // lectura sincronica (1 ciclo)
    output reg  [9:0]  dmem_addr,
    input  wire [31:0] dmem_rdata,   // lectura sincronica (1 ciclo)
    input  wire        dmem_used,    // asincronico
    output wire        used_clr,
    output wire [4:0]  reg_addr,
    input  wire [31:0] reg_data,
    output wire [3:0]  latch_sel,
    input  wire [31:0] latch_data,

    // --- Estado (LEDs) ---
    output wire        loading,
    output wire        running
);

    // ------------------------------------------------------------------
    // Estados
    // ------------------------------------------------------------------
    localparam [4:0]
        S_IDLE      = 5'd0,
        S_LD_N0     = 5'd1,    // carga: byte bajo de N
        S_LD_N1     = 5'd2,    //        byte alto de N
        S_LD_DATA   = 5'd3,    //        bytes de las palabras
        S_LD_WAIT   = 5'd4,    //        espera que termine el borrado del bitmap
        S_ACK       = 5'd5,    // manda 'K'
        S_ERR       = 5'd6,    // manda '?'
        S_RUN       = 5'd7,    // continuo
        S_STEP      = 5'd8,    // un ciclo
        S_DUMP_HDR  = 5'd9,    // volcado: 'D'
        S_DUMP_FIX  = 5'd10,   //          51 palabras fijas
        S_DUMP_SCAN = 5'd11,   //          busca la proxima palabra usada
        S_DUMP_RD   = 5'd12,   //          espera la lectura de la BRAM
        S_DUMP_ADDR = 5'd13,   //          manda la direccion
        S_DUMP_DATA = 5'd14,   //          manda el dato
        S_DUMP_END  = 5'd15,   //          manda FFFFFFFF
        S_I_HDR     = 5'd16,   // programa: 'I'
        S_I_LEN     = 5'd17,   //           N
        S_I_RD      = 5'd18,   //           espera la lectura de la BRAM
        S_I_DATA    = 5'd19;   //           manda la palabra

    localparam [5:0] N_FIX = 6'd51;

    reg [4:0]  state;
    reg [5:0]  item;          // palabra fija del volcado (0..50)
    reg [10:0] n_words;       // N recibido en la carga
    reg [10:0] prog_len;      // N del ultimo programa cargado (para 'I')
    reg [10:0] widx;          // palabra actual (carga y 'I')
    reg [1:0]  byte_idx;      // byte dentro de la palabra (carga)
    reg [23:0] word_acc;      // primeros 3 bytes de la palabra que llega
    reg [31:0] cycles;
    reg        r_pulse;       // reset de 1 ciclo por 'R'
    reg        clr_busy;      // borrando el bitmap de memoria usada

    // ------------------------------------------------------------------
    // Control del procesador
    // ------------------------------------------------------------------
    assign loading   = (state == S_LD_N0) || (state == S_LD_N1) ||
                       (state == S_LD_DATA) || (state == S_LD_WAIT);
    assign running   = (state == S_RUN);
    assign cpu_reset = reset | loading | r_pulse;
    assign cpu_en    = ~program_done & ((state == S_RUN) | (state == S_STEP));
    assign used_clr  = clr_busy;

    // ------------------------------------------------------------------
    // Palabras fijas del volcado
    // ------------------------------------------------------------------
    wire [5:0] item_reg   = item - 6'd3;      // 3..34  -> x0..x31
    wire [5:0] item_latch = item - 6'd35;     // 35..50 -> latch 0..15
    assign reg_addr  = item_reg[4:0];
    assign latch_sel = item_latch[3:0];

    reg [31:0] fix_word;
    always @(*) begin
        if      (item == 6'd0)  fix_word = pc;
        else if (item == 6'd1)  fix_word = cycles;
        else if (item == 6'd2)  fix_word = {31'd0, program_done};
        else if (item < 6'd35)  fix_word = reg_data;
        else                    fix_word = latch_data;
    end

    // ------------------------------------------------------------------
    // Emisor: manda snd_left bytes de snd_buf (el menos significativo
    // primero), esperando tx_done entre uno y otro. La FSM principal solo
    // le carga una palabra nueva cuando esta libre (snd_idle).
    // ------------------------------------------------------------------
    reg [31:0] snd_buf;
    reg [2:0]  snd_left;
    reg        snd_wait;
    wire       snd_idle = (snd_left == 3'd0) && !snd_wait;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state    <= S_IDLE;
            item     <= 6'd0;
            n_words  <= 11'd0;
            prog_len <= 11'd0;
            widx     <= 11'd0;
            byte_idx <= 2'd0;
            word_acc <= 24'd0;
            cycles   <= 32'd0;
            r_pulse  <= 1'b0;
            clr_busy <= 1'b0;
            imem_we  <= 1'b0;
            imem_addr  <= 10'd0;
            imem_wdata <= 32'd0;
            dmem_addr  <= 10'd0;
            snd_buf  <= 32'd0;
            snd_left <= 3'd0;
            snd_wait <= 1'b0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
        end else begin
            // --- valores por defecto (pulsos de 1 ciclo) ---
            tx_start <= 1'b0;
            imem_we  <= 1'b0;
            r_pulse  <= 1'b0;

            // --- contador de ciclos ---
            if (cpu_reset)   cycles <= 32'd0;
            else if (cpu_en) cycles <= cycles + 1'b1;

            // --- borrado del bitmap (en paralelo con la recepcion) ---
            if (clr_busy) begin
                if (dmem_addr == 10'd1023) clr_busy <= 1'b0;
                dmem_addr <= dmem_addr + 1'b1;
            end

            // --- emisor ---
            if (snd_wait) begin
                if (tx_done) snd_wait <= 1'b0;
            end else if (snd_left != 3'd0) begin
                tx_start <= 1'b1;
                tx_data  <= snd_buf[7:0];
                snd_buf  <= snd_buf >> 8;
                snd_left <= snd_left - 1'b1;
                snd_wait <= 1'b1;
            end

            // --- maquina principal ---
            case (state)
                S_IDLE:
                    if (rx_done) begin
                        case (rx_data)
                            "L": begin
                                state     <= S_LD_N0;
                                clr_busy  <= 1'b1;
                                dmem_addr <= 10'd0;
                            end
                            "R": begin r_pulse <= 1'b1; state <= S_ACK; end
                            "C": state <= program_done ? S_DUMP_HDR : S_RUN;
                            "S": state <= program_done ? S_DUMP_HDR : S_STEP;
                            "D": state <= S_DUMP_HDR;
                            "I": state <= S_I_HDR;
                            default: state <= S_ERR;
                        endcase
                    end

                // ---------------- carga del programa ----------------
                S_LD_N0:
                    if (rx_done) begin
                        n_words[7:0] <= rx_data;
                        state        <= S_LD_N1;
                    end
                S_LD_N1:
                    if (rx_done) begin
                        n_words[10:8] <= rx_data[2:0];
                        widx          <= 11'd0;
                        byte_idx      <= 2'd0;
                        state <= ({rx_data[2:0], n_words[7:0]} == 11'd0) ? S_LD_WAIT : S_LD_DATA;
                    end
                S_LD_DATA:
                    if (rx_done) begin
                        byte_idx <= byte_idx + 1'b1;
                        word_acc <= {rx_data, word_acc[23:8]};
                        if (byte_idx == 2'd3) begin            // palabra completa
                            imem_we    <= 1'b1;
                            imem_addr  <= widx[9:0];
                            imem_wdata <= {rx_data, word_acc};
                            widx       <= widx + 1'b1;
                            if (widx == n_words - 1'b1) state <= S_LD_WAIT;
                        end
                    end
                S_LD_WAIT:
                    if (!clr_busy) begin
                        prog_len <= n_words;
                        state    <= S_ACK;
                    end

                // ---------------- respuestas de 1 byte ----------------
                S_ACK:
                    if (snd_idle) begin
                        snd_buf <= "K"; snd_left <= 3'd1; state <= S_IDLE;
                    end
                S_ERR:
                    if (snd_idle) begin
                        snd_buf <= "?"; snd_left <= 3'd1; state <= S_IDLE;
                    end

                // ---------------- ejecucion ----------------
                S_RUN:                                   // cpu_en = 1
                    if (program_done || rx_done) state <= S_DUMP_HDR;
                S_STEP:                                  // cpu_en = 1 este ciclo
                    state <= S_DUMP_HDR;

                // ---------------- volcado ----------------
                S_DUMP_HDR:
                    if (snd_idle) begin
                        snd_buf <= "D"; snd_left <= 3'd1;
                        item    <= 6'd0;
                        state   <= S_DUMP_FIX;
                    end
                S_DUMP_FIX:
                    if (snd_idle) begin
                        snd_buf  <= fix_word; snd_left <= 3'd4;
                        item     <= item + 1'b1;
                        if (item == N_FIX - 1'b1) begin
                            dmem_addr <= 10'd0;
                            state     <= S_DUMP_SCAN;
                        end
                    end
                S_DUMP_SCAN:                             // 1 palabra por ciclo
                    if (dmem_used)                  state <= S_DUMP_RD;
                    else if (dmem_addr == 10'd1023) state <= S_DUMP_END;
                    else                            dmem_addr <= dmem_addr + 1'b1;
                S_DUMP_RD:                               // la BRAM lee dmem_addr
                    state <= S_DUMP_ADDR;
                S_DUMP_ADDR:
                    if (snd_idle) begin
                        snd_buf <= {20'd0, dmem_addr, 2'b00}; snd_left <= 3'd4;
                        state   <= S_DUMP_DATA;
                    end
                S_DUMP_DATA:
                    if (snd_idle) begin
                        snd_buf <= dmem_rdata; snd_left <= 3'd4;
                        if (dmem_addr == 10'd1023) state <= S_DUMP_END;
                        else begin
                            dmem_addr <= dmem_addr + 1'b1;
                            state     <= S_DUMP_SCAN;
                        end
                    end
                S_DUMP_END:
                    if (snd_idle) begin
                        snd_buf <= 32'hFFFF_FFFF; snd_left <= 3'd4;
                        state   <= S_IDLE;
                    end

                // ---------------- lectura del programa ('I') ----------------
                S_I_HDR:
                    if (snd_idle) begin
                        snd_buf <= "I"; snd_left <= 3'd1;
                        state   <= S_I_LEN;
                    end
                S_I_LEN:
                    if (snd_idle) begin
                        snd_buf   <= {21'd0, prog_len}; snd_left <= 3'd4;
                        widx      <= 11'd0;
                        imem_addr <= 10'd0;
                        state     <= (prog_len == 11'd0) ? S_IDLE : S_I_RD;
                    end
                S_I_RD:                                  // la BRAM lee imem_addr
                    state <= S_I_DATA;
                S_I_DATA:
                    if (snd_idle) begin
                        snd_buf <= imem_rdata; snd_left <= 3'd4;
                        widx    <= widx + 1'b1;
                        if (widx == prog_len - 1'b1) state <= S_IDLE;
                        else begin
                            imem_addr <= imem_addr + 1'b1;
                            state     <= S_I_RD;
                        end
                    end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
