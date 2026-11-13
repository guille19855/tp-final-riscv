// Banco de registros (Register File) - etapa ID.
//
// 32 registros de 32 bits (x0..x31) implementados con flip-flops.
//  - 2 puertos de lectura combinacionales (rs1, rs2) para la etapa ID.
//  - 1 puerto de escritura sincronico (rd) que usa la etapa WB.
//  - 1 puerto de lectura extra para la Debug Unit (mandar los 32 registros
//    por UART), independiente de los otros: no molesta al procesador.
//
// x0 vale siempre 0: nunca se escribe y se lee como 0.
//
// BYPASS INTERNO (decision del TP, ver docs/pipeline_diagrama.html):
// en el mismo ciclo en que WB escribe un registro, ID puede estar leyendo
// ese mismo registro. Como la escritura recien ocurre en el flanco, ID leeria
// el valor viejo. La catedra lo resuelve escribiendo en el flanco de bajada;
// aca lo resolvemos con un mux: si se esta escribiendo el registro que se lee,
// la salida es directamente el dato que se escribe (wdata).
//
// Reset sincronico: todos los registros a 0 (pedido del profesor).

`timescale 1ns / 1ps

module reg_file (
    input  wire        clk,
    input  wire        reset,

    // Lectura (etapa ID)
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data,

    // Escritura (etapa WB)
    input  wire        we,         // RegWrite que llega de MEM/WB
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,

    // Lectura para la Debug Unit
    input  wire [4:0]  dbg_addr,
    output wire [31:0] dbg_data
);

    reg [31:0] regs [0:31];
    integer i;

    // Escritura: en el flanco de subida, nunca sobre x0
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'd0;
        end else if (we && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

    // Hay bypass cuando WB escribe justo el registro que ID esta leyendo
    wire bypass1 = we && (rd_addr != 5'd0) && (rd_addr == rs1_addr);
    wire bypass2 = we && (rd_addr != 5'd0) && (rd_addr == rs2_addr);

    // Lectura combinacional: x0 -> 0, bypass -> dato nuevo, si no -> registro
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 :
                      bypass1            ? rd_data : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 :
                      bypass2            ? rd_data : regs[rs2_addr];

    // Puerto de debug: lee el valor guardado (sin bypass, es solo para mirar)
    assign dbg_data = (dbg_addr == 5'd0) ? 32'd0 : regs[dbg_addr];

endmodule
