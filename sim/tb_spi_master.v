// tb_spi_master -- mode-0 byte engine against a behavioural slave.
// The slave answers 5A first, then the complement of each byte it received, so
// a bit-order, edge or off-by-one error shows in both directions.  SCK must
// idle low and run at clk/4 (HALF = 2).
`timescale 1ns/1ps
module tb_spi_master;
    reg clk = 0;
    always #18.519 clk = ~clk;
    reg reset = 1;
    reg start = 0;
    reg [7:0] tx = 0;
    wire [7:0] rx;
    wire busy, done, sck, mosi, miso;
    reg cs_n = 1;

    spi_master #(.HALF(2)) dut (.clk(clk), .reset(reset), .start(start), .tx(tx),
        .rx(rx), .busy(busy), .done(done), .sck(sck), .mosi(mosi), .miso(miso));

    // slave
    reg [7:0] sh_rx = 0, sh_tx = 0, nextr = 0, got = 0;
    reg [2:0] bc = 0;
    reg fin = 0;
    reg [7:0] slave_got [0:3];
    integer ng = 0;
    assign miso = sh_tx[7];
    always @(negedge cs_n) begin sh_tx <= 8'h5A; bc <= 0; fin <= 0; end
    always @(posedge sck) if (!cs_n) begin
        sh_rx <= {sh_rx[6:0], mosi};
        if (bc == 3'd7) begin
            nextr <= ~{sh_rx[6:0], mosi}; fin <= 1; slave_got[ng] <= {sh_rx[6:0], mosi}; ng <= ng + 1;
        end else fin <= 0;
        bc <= bc + 3'd1;
    end
    always @(negedge sck) if (!cs_n) sh_tx <= fin ? nextr : {sh_tx[6:0], 1'b0};

    integer fails = 0;
    task check(input [255:0] what, input ok);
        if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end
    endtask

    reg [7:0] txs [0:3];
    reg [7:0] exp_rx [0:3];
    integer i, edges;
    real t_prev, t_now, period;
    initial begin
        txs[0] = 8'hA1; txs[1] = 8'h02; txs[2] = 8'hFF; txs[3] = 8'h80;
        exp_rx[0] = 8'h5A; exp_rx[1] = 8'h5E; exp_rx[2] = 8'hFD; exp_rx[3] = 8'h00;
        #100 reset = 0; #100;
        check("SCK idles low", sck === 1'b0);
        cs_n = 0; #50;
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk); tx = txs[i]; start = 1;
            @(posedge clk); start = 0;
            wait (done); @(posedge clk);
            check("rx byte", rx === exp_rx[i]);
            if (rx !== exp_rx[i]) $display("  byte %0d: got %02x want %02x", i, rx, exp_rx[i]);
        end
        #200; cs_n = 1;
        for (i = 0; i < 4; i = i + 1) begin
            check("slave got tx byte", slave_got[i] === txs[i]);
            if (slave_got[i] !== txs[i]) $display("  slave byte %0d: got %02x want %02x", i, slave_got[i], txs[i]);
        end
        // one more byte just to time SCK
        cs_n = 0; #50;
        @(posedge clk); tx = 8'h00; start = 1; @(posedge clk); start = 0;
        @(posedge sck); t_prev = $realtime; @(posedge sck); t_now = $realtime;
        period = t_now - t_prev;
        check("SCK is clk/4", period > 4*37.0 && period < 4*37.1);
        wait (done);
        if (fails == 0) $display("tb_spi_master: PASS");
        else            $display("tb_spi_master: FAIL (%0d)", fails);
        $finish;
    end
    initial begin #2000000; $display("tb_spi_master: FAIL (timeout)"); $finish; end
endmodule
