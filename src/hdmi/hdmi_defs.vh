// ============================================================================
//  hdmi_defs.vh -- shared constants: TMDS period codes and the video mode
//
//  The single definition of both.  RTL module parameters default to the VM_
//  values, src/top.v uses those defaults, and scripts/build.ps1 takes the
//  timing target from VM_PIXEL_HZ.
// ============================================================================
`ifndef HDMI_DEFS_VH
`define HDMI_DEFS_VH

// hdmi_tmds_encoder `mode` input: which symbol set a pixel is encoded with.
`define TMDS_CTRL   3'd0    // control period: C0..C3 control characters
`define TMDS_VIDEO  3'd1    // video data period: 8b/10b DC-balanced
`define TMDS_VGB    3'd2    // video guard band (Table 5-5)
`define TMDS_TERC4  3'd3    // data island body: TERC4
`define TMDS_DGB    3'd4    // data island guard band (Table 5-6)

// Video mode: CEA-861-D 720x480p59.94, VIC 2, 4:3.  27.000 MHz is exactly the
// Tang Nano 20K oscillator.  Sync polarity is the wire level during the
// pulse (both negative for this mode).
`define VM_PIXEL_HZ   27000000
`define VM_H_TOTAL    858
`define VM_H_ACTIVE   720
`define VM_H_FRONT    16
`define VM_H_SYNC_W   62
`define VM_V_TOTAL    525
`define VM_V_ACTIVE   480
`define VM_V_FRONT    9
`define VM_V_SYNC_W   6
`define VM_HSYNC_POL  1'b0
`define VM_VSYNC_POL  1'b0
`define VM_VIC        8'd2
`define VM_ASPECT     2'b01     // AVI M1M0: 01 = 4:3, 10 = 16:9

// Audio: 48 kHz L-PCM.  ACR N / CTS from HDMI 1.3 Table 7-3 for 27 MHz.
`define VM_AUDIO_HZ   48000
`define VM_ACR_N      20'd6144
`define VM_ACR_CTS    20'd27000

`endif
