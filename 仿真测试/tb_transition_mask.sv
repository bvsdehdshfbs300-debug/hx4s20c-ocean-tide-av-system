`timescale 1ns/1ps
module tb_transition_mask;
    reg [10:0] x;
    reg [9:0] y;
    reg [2:0] mode;
    reg [7:0] alpha;
    wire visible;
    wire edge_on;
    integer m, a;
    reg seen;

    transition_mask dut (
        .x(x), .y(y), .mode(mode), .alpha(alpha),
        .visible(visible), .edge_on(edge_on)
    );

    initial begin
        for (m = 0; m <= 5; m = m + 1) begin
            mode = m;
            x = 11'd320;
            y = 10'd240;
            alpha = 8'd0;
            #1;
            if (m == 0) begin
                if (visible !== 1'b1) $fatal(1, "DEFAULT must stay visible at alpha zero");
            end else if (visible !== 1'b0) $fatal(1, "mode %0d must start fully covered", m);
            alpha = 8'd255;
            #1;
            if (visible !== 1'b1) $fatal(1, "mode %0d must end fully revealed", m);

            case (m)
                1: begin x = 11'd320; y = 10'd240; end
                2: begin x = 11'd320; y = 10'd240; end
                3: begin x = 11'd320; y = 10'd240; end
                4: begin x = 11'd100; y = 10'd100; end
                5: begin x = 11'd7; y = 10'd7; end
                default: begin x = 11'd320; y = 10'd240; end
            endcase
            seen = 1'b0;
            for (a = 0; a <= 255; a = a + 1) begin
                alpha = a;
                #1;
                if (visible) seen = 1'b1;
                if (seen && !visible) $fatal(1, "mode %0d is not monotonic at alpha %0d", m, a);
            end
            if (!seen) $fatal(1, "mode %0d never reveals the sample pixel", m);
            if (mode >= 2 && mode <= 4 && !edge_on)
                $display("MASK_NOTE: edge sample depends on selected coordinates for mode %0d", m);
        end
        $display("TRANSITION_MASK_TEST_OK: modes 0..5 cover, reveal, and progress monotonically");
        $finish;
    end
endmodule
