`timescale 1ns/1ps
module tb_realtime_zoom;
reg clk = 1'b0;
reg rst = 1'b1;
reg req = 1'b0;
wire ack;
wire app_rd_en;
wire [20:0] app_rd_addr;
integer sample_count = 0;
integer out_x;
integer out_y;
integer expected_addr;

always #5 clk = ~clk;

frame_fifo_read #(.BURST_SIZE(8)) dut (
    .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1),
    .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0), .Sdr_rd_en(1'b0),
    .App_wr_busy(1'b0), .App_rd_en(app_rd_en), .App_rd_addr(app_rd_addr),
    .read_req(req), .read_req_ack(ack), .read_addr_0(21'd1000),
    .read_addr_1(21'd0), .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_4(21'd0), .read_use_addr4(1'b0), .zoom_2x(1'b1),
    .read_addr_index(2'd0), .read_len(21'd1280), .wrusedw(10'd0)
);

always @(posedge clk) begin
    if (!rst && app_rd_en) begin
        out_x = sample_count % 640;
        out_y = sample_count / 640;
        expected_addr = 1000 + 76960 + (out_y / 2) * 640 + (out_x / 2);
        if (app_rd_addr !== expected_addr[20:0])
            $fatal(1, "Zoom address mismatch sample=%0d x=%0d y=%0d got=%0d expected=%0d",
                   sample_count, out_x, out_y, app_rd_addr, expected_addr);
        sample_count = sample_count + 1;
    end
end

initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    req = 1'b1;
    wait (ack === 1'b1);
    @(negedge clk);
    req = 1'b0;
    wait (sample_count == 1280);
    $display("REALTIME_ZOOM_TEST_OK: center crop uses x/2,y/2 for every output pixel");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "Real-time zoom simulation watchdog");
end
endmodule
