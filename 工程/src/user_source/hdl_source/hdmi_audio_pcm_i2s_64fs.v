module hdmi_audio_pcm_i2s_64fs(
    input wire I_mclk,
    input wire I_rst,
    input wire signed [15:0] I_sample,
    output reg O_sample_tick,
    output reg O_i2s_BCLK,
    output reg O_i2s_LRCK,
    output reg O_i2s_DOUT
);
    reg [5:0] bit_cnt;
    reg [63:0] shift_reg;
    reg [23:0] sample_word;

    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) begin
            O_i2s_BCLK <= 1'b0;
            O_i2s_LRCK <= 1'b0;
            O_i2s_DOUT <= 1'b0;
            O_sample_tick <= 1'b0;
            bit_cnt <= 6'd0;
            shift_reg <= 64'd0;
            sample_word <= 24'd0;
        end else begin
            O_sample_tick <= 1'b0;
            O_i2s_BCLK <= ~O_i2s_BCLK;
            if (O_i2s_BCLK) begin
                O_i2s_DOUT <= shift_reg[63];
                shift_reg <= {shift_reg[62:0], 1'b0};
                if (bit_cnt == 6'd63) begin
                    bit_cnt <= 6'd0;
                    if (!O_i2s_LRCK) begin
                        O_i2s_LRCK <= 1'b1;
                        shift_reg <= {sample_word, 40'd0};
                    end else begin
                        O_i2s_LRCK <= 1'b0;
                        sample_word <= {I_sample, 8'd0};
                        shift_reg <= {I_sample, 48'd0};
                        O_sample_tick <= 1'b1;
                    end
                end else
                    bit_cnt <= bit_cnt + 6'd1;
            end
        end
    end
endmodule
