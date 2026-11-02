`timescale 1ns/1ps
module tb_video_levels;
reg clk=0, rst=1, frame_tick=0;
always #5 clk=~clk;
reg [23:0] rgb;
reg [9:0] gain;
reg signed [10:0] offset;
wire [23:0] out;
reg [1:0] brightness_sel=2'd3;
reg [2:0] contrast_sel=3'd3;
reg idle_dim=0;
wire [9:0] ramp_gain;
wire signed [10:0] ramp_offset;
reg is_sun=1;
reg [10:0] circle_dx=0, circle_dy=0;
wire circle_disc;
wire [7:0] circle_glow;

video_levels dut(
 .rgb_in(rgb), .image_gain(gain), .contrast_offset(offset), .rgb_out(out)
);
video_level_ramp ramp(
 .clk(clk), .rst(rst), .frame_tick(frame_tick),
 .brightness_sel(brightness_sel), .contrast_sel(contrast_sel), .idle_dim(idle_dim),
 .image_gain(ramp_gain), .contrast_offset(ramp_offset)
);
celestial_circle circle(
 .dx(circle_dx), .dy(circle_dy), .is_sun(is_sun),
 .disc(circle_disc), .glow(circle_glow)
);

task check;
 input [23:0] pixel;
 input [9:0] coeff;
 input signed [10:0] bias;
 input [23:0] expected;
 begin
  rgb=pixel; gain=coeff; offset=bias; #1;
  if(out!==expected)
   $fatal(1,"levels mismatch rgb=%h gain=%0d offset=%0d out=%h expected=%h",
          pixel,coeff,bias,out,expected);
 end
endtask

task frame;
 begin
  @(negedge clk); frame_tick=1'b1;
  @(posedge clk); #1;
  @(negedge clk); frame_tick=1'b0;
 end
endtask

initial begin
 check(24'h4080c0,10'd128, 11'sd64,24'h6080a0);
 check(24'h4080c0,10'd192, 11'sd32,24'h5080b0);
 check(24'h4080c0,10'd232, 11'sd12,24'h4680ba);
 check(24'h4080c0,10'd256, 11'sd0, 24'h4080c0);
 check(24'h4080c0,10'd280,-11'sd12,24'h3a80c6);
 check(24'h4080c0,10'd320,-11'sd32,24'h3080d0);
 check(24'h4080c0,10'd384,-11'sd64,24'h2080e0);
 check(24'h000000,10'd384,-11'sd64,24'h000000);
 check(24'hffffff,10'd384,-11'sd64,24'hffffff);

 repeat(2) @(posedge clk); rst=0;
 contrast_sel=3'd6;
 frame;
 if(ramp_gain!==10'd256 || ramp_offset!==11'sd0)
  $fatal(1,"Contrast changed without ramp");
 frame;
 if(ramp_gain!==10'd260 || ramp_offset!==-11'sd2)
  $fatal(1,"Contrast first ramp step wrong: gain=%0d offset=%0d",ramp_gain,ramp_offset);
 repeat(31) frame;
 if(ramp_gain!==10'd384 || ramp_offset!==-11'sd64)
  $fatal(1,"Contrast ramp did not reach 150%%");

 brightness_sel=2'd0;
 frame;
 if(ramp_gain!==10'd384) $fatal(1,"Brightness changed without ramp");
 frame;
 if(ramp_gain!==10'd378) $fatal(1,"Brightness first ramp step wrong: %0d",ramp_gain);
 repeat(47) frame;
 if(ramp_gain!==10'd96) $fatal(1,"Brightness ramp did not reach 25%%: %0d",ramp_gain);

 is_sun=1'b1; circle_dx=11'd24; circle_dy=11'd0; #1;
 if(!circle_disc) $fatal(1,"Sun horizontal radius missing");
 circle_dx=11'd24; circle_dy=11'd1; #1;
 if(circle_disc) $fatal(1,"Sun edge is not circular");
 circle_dx=11'd16; circle_dy=11'd17; #1;
 if(!circle_disc) $fatal(1,"Sun diagonal interior missing");
 circle_dx=11'd17; circle_dy=11'd17; #1;
 if(circle_disc) $fatal(1,"Sun diagonal exterior included");
 is_sun=1'b0; circle_dx=11'd22; circle_dy=11'd1; #1;
 if(circle_disc) $fatal(1,"Moon edge is not circular");
 circle_dx=11'd61; circle_dy=11'd0; #1;
 if(circle_glow!==0) $fatal(1,"Moon glow exceeded circular radius");

 $display("VIDEO_LEVELS_TEST_OK: smooth brightness/contrast ramps; saturated affine levels; round sun/moon");
 $finish;
end
endmodule
