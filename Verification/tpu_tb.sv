`timescale 1ns / 1ps
import gemm_pkg::*;

module tpu_tb;

    // Memory arrays for testbench stimulus
    logic [ACT_WIDTH-1:0] activation_mem [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    logic [WGT_WIDTH-1:0] weight_mem     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    logic [ACC_WIDTH-1:0] bias_mem       [0:ARRAY_SIZE-1];
    logic [ACC_WIDTH-1:0] scale_mem      [0:ARRAY_SIZE-1];
    logic [ACC_WIDTH-1:0] expected_single_tile_mem   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    logic [ACC_WIDTH-1:0] expected_multi_tile_mem    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  

    // Clock and reset
    logic clk;
    logic rst_n;

    // Input Control signals
    logic TILE_START;
    logic TILE_LAST;
    logic BIAS_NEW;
    logic RELU_EN;
    logic [DIM_WIDTH-1:0] A_LEN;
    logic [DIM_WIDTH-1:0] W_LEN;
    logic [DIM_WIDTH-1:0] K_LEN;
    logic METADATA_VLD;
    logic DATA_VLD;
    logic BIAS_VLD;
    logic SCALE_VLD;
    logic Y_RDY;

    // Input Data signals
    logic [ACT_WIDTH-1:0] A_DATA [0:ARRAY_SIZE-1];
    logic [WGT_WIDTH-1:0] W_DATA [0:ARRAY_SIZE-1];
    logic [ACC_WIDTH-1:0] BIAS;
    logic [ACC_WIDTH-1:0] SCALE;

    // Output Control signals
    logic METADATA_RDY;
    logic DATA_RDY;
    logic BIAS_RDY;
    logic SCALE_RDY;
    logic Y_VLD;
    logic TILE_DONE;

    // Output Data signals
    logic [OUT_WIDTH-1:0] Y_OUT [0:ARRAY_SIZE-1];

    gemm_state_t state_output; // For visibility in waveform/debugging

    // Instantiate the GEMM Top Module
    gemm_top dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .TILE_START   (TILE_START),
        .TILE_LAST    (TILE_LAST),
        .BIAS_NEW     (BIAS_NEW),
        .RELU_EN      (RELU_EN),
        .A_LEN        (A_LEN),
        .W_LEN        (W_LEN),
        .K_LEN        (K_LEN),
        .METADATA_VLD (METADATA_VLD),
        .DATA_VLD     (DATA_VLD),
        .BIAS_VLD     (BIAS_VLD),
        .SCALE_VLD    (SCALE_VLD),
        .Y_RDY        (Y_RDY),
        .A_DATA       (A_DATA),
        .W_DATA       (W_DATA),
        .BIAS         (BIAS),
        .SCALE        (SCALE),
        .METADATA_RDY (METADATA_RDY),
        .DATA_RDY     (DATA_RDY),
        .BIAS_RDY     (BIAS_RDY),
        .SCALE_RDY    (SCALE_RDY),
        .Y_VLD        (Y_VLD),
        .TILE_DONE    (TILE_DONE),
        .Y_OUT        (Y_OUT),
        .state_output (state_output) // For visibility in waveform/debugging
    );

    // Clock generation
    initial clk = 1'b0;
    always #5 clk = ~clk;
     // Task to initialize inputs
    task automatic init_inputs();
        begin
            TILE_START   = 1'b0;
            TILE_LAST    = 1'b0;
            BIAS_NEW     = 1'b0;
            RELU_EN      = 1'b0;
            A_LEN        = '0;
            W_LEN        = '0;
            K_LEN        = '0;
            METADATA_VLD = 1'b0;
            DATA_VLD     = 1'b0;
            BIAS_VLD     = 1'b0;
            SCALE_VLD    = 1'b0;
            Y_RDY        = 1'b0;
            BIAS         = '0;
            SCALE        = '0;

            for (int i = 0; i < ARRAY_SIZE; i++) begin
                A_DATA[i] = '0;
                W_DATA[i] = '0;
            end
        end
    endtask

    // Task to send metadata to DUT at the beginning of each tile, during IDLE state
    task automatic send_metadata( input int a_dim, input int w_dim, input int k_dim, input logic tile_last_i, input logic bias_new_i, input logic relu_en_i);
        begin
            // Wait for DUT to be ready to receive metadata
            while (!METADATA_RDY) @(posedge clk);

            // next clk, present metadata
            A_LEN        <= a_dim;
            W_LEN        <= w_dim;
            K_LEN        <= k_dim;
            TILE_LAST    <= tile_last_i;
            BIAS_NEW     <= bias_new_i;
            RELU_EN      <= relu_en_i;
            TILE_START   <= 1'b1;
            METADATA_VLD <= 1'b1;

            // next next clk, deassert start and metadata valid
            @(posedge clk);
            TILE_START   <= 1'b0;
            METADATA_VLD <= 1'b0;
            A_LEN        <= '0;
            W_LEN        <= '0;
            K_LEN        <= '0;
            TILE_LAST    <= 1'b0;
            BIAS_NEW     <= 1'b0;
            RELU_EN      <= 1'b0;
        end
    endtask

    // Task to send tile data to FIFOs, 1 k-element vector per cycle for all rows/cols, during LOAD_FIFO state
    task automatic send_aw_tile(input int a_dim, input int w_dim, input int k_dim);
        begin

            while (!DATA_RDY) @(posedge clk); // Wait for DUT to assert ready before next beat

            // When DATA_RDY = 1, send data_vld 1 cycle later, and keep it high until all data is sent.
            DATA_VLD = 1'b1; // send data_vld every cycle while sending tile data

            for (int k = 0; k < k_dim; k++) begin // 1 clk send k-element vectors for all ARRAY_SIZE rows/cols
                for (int r = 0; r < ARRAY_SIZE; r++) begin // load activation column by column
                    A_DATA[r] <= activation_mem[r][k]; 
                end
                for (int c = 0; c < ARRAY_SIZE; c++) begin // load weight row by row
                    W_DATA[c] <= weight_mem[k][c];
                end
                @(posedge clk);
            end

            DATA_VLD <= 1'b0;
            for (int i = 0; i < ARRAY_SIZE; i++) begin
                A_DATA[i] <= '0;
                W_DATA[i] <= '0;
            end
        end
    endtask

    // Task to send bias vector to PEs, 1 element per cycle during LOAD_FIFO state. 
    task automatic send_bias_vec(input int w_dim);
        begin
            
            while (!BIAS_RDY) @(posedge clk);
            BIAS_VLD <= 1'b1; // send bias_vld every cycle while sending bias vector

            for (int c = 0; c < w_dim; c++) begin // send a bias per clk for the first w_dim columns
                BIAS <= bias_mem[c];
                @(posedge clk);
            end

            BIAS_VLD <= 1'b0;
            BIAS     <= '0;
        end
    endtask

    // Wait state = GEMM_COMPUTE, then wait a_dim+w_dim+k_dim-3 cycles 
    task automatic wait_gemm_compute(input int a_dim, input int w_dim, input int k_dim, input logic tile_last_i);
        begin
            int total_compute_cycles = a_dim + w_dim + k_dim - 3;
            wait (state_output == GEMM_COMPUTE); // wait until we enter the compute state
            repeat (total_compute_cycles) @(posedge clk);

            if (tile_last_i) begin
                wait (state_output == GEMM_FLUSH); // if this is the last tile, also wait until we enter the flush state
            end
            else begin
                wait (state_output == IDLE); // if not last tile, wait until we return to IDLE for next tile
            end
        end
    endtask

    // Task to drain output Y column by column, presenting corresponding scale for each column
    task automatic drain_outputs(input int w_dim);
        begin
            for (int c = 0; c < w_dim; c++) begin
                SCALE_VLD = 1'b1; // tell DUT that the scale for this output column is valid
                Y_RDY     = 1'b1; // tell DUT that TB is ready to receive output data for this column
                SCALE = scale_mem[c];
                @ (posedge clk); // send 1 scale per clk 
            end

            Y_RDY     <= 1'b0;
            SCALE_VLD <= 1'b0;
            SCALE     <= '0;
        end
    endtask

    task automatic result_compare (input int w_dim, input int a_dim, input logic tile);

            int error_cnt = 0;
            @ (posedge clk);

            for (int c = 0; c < w_dim; c++) begin

                $display("======= COLUMN %0d =======",c);

                @ (posedge clk);
                // Check output against golden reference
                for (int r = 0; r < a_dim; r++) begin
                    if (tile) begin // single tile test result comparison
                        if (Y_OUT[r] !== expected_single_tile_mem[c][r]) begin
                            $display("ERROR @ col=%0d row=%0d : got=%h expected=%h", c, r, Y_OUT[r], expected_single_tile_mem[c][r]);
                            error_cnt++;
                        end
                        else begin
                            $display("PASS @ col=%0d row=%0d : %h", c, r, Y_OUT[r]);
                        end
                    end
                    else begin // multi-tile test result comparison
                        if (Y_OUT[r] !== expected_multi_tile_mem[c][r]) begin
                            $display("ERROR @ col=%0d row=%0d : got=%h expected=%h", c, r, Y_OUT[r], expected_multi_tile_mem[c][r]);
                            error_cnt++;
                        end
                        else begin
                            $display("PASS @ col=%0d row=%0d : %h", c, r, Y_OUT[r]);
                        end
                    end
                end
            end

            if (error_cnt == 0)
                $display("===== ALL PASS =====");
            else
                $display("===== FAIL : %0d errors =====", error_cnt);
    endtask


    //--------------------------------------------------------------------------------
    // task for single tile
    //--------------------------------------------------------------------------------
    task automatic single_tile_test(input int a_dim, input int w_dim, input int k_dim);
        begin
            
            //////////////
            // IDLE_STATE
            //////////////
            // Reset sequence
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);

            // send metadata for an 8x8 tile with bias and relu
            send_metadata(a_dim, w_dim, k_dim, 1'b1, 1'b1, 1'b1); // this is the last tile, with new bias and relu

            //////////////////
            // LOAD_FIFO state
            //////////////////
            // send tile data and bias vector in parallel
            fork
                send_aw_tile(a_dim, w_dim, k_dim);
                send_bias_vec(w_dim);   
            join

            /////////////////////
            // GEMM_COMPUTE state
            /////////////////////
            // wait for compute to finish
            wait_gemm_compute(a_dim, w_dim, k_dim, 1'b1);

            ///////////////////
            // GEMM_FLUSH state
            ///////////////////
            // drain outputs and compare results
            fork
                drain_outputs(w_dim);
                result_compare(w_dim, a_dim, 1'b1);
            join
        end
    endtask

    //-----------------------------------------------------------------------
    // Task for multi tile
    //-----------------------------------------------------------------------
    task automatic multi_tile_test(input int a_dim, input int w_dim, input int k_dim, input int num_tiles);
        begin
            //////////////
            // IDLE_STATE
            //////////////
            // Reset sequence
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);

            // send metadata for an 8x8 tile with bias and relu
            send_metadata(a_dim, w_dim, k_dim, 1'b0, 1'b1, 1'b1);

            //////////////////
            // LOAD_FIFO state
            //////////////////
            // send tile data and bias vector in parallel
            fork
                send_aw_tile(a_dim, w_dim, k_dim);
                send_bias_vec(w_dim);   
            join

            /////////////////////
            // GEMM_COMPUTE state
            /////////////////////
            // wait for compute to finish
            wait_gemm_compute(a_dim, w_dim, k_dim, 1'b0); // not the last tile

            for (int i = 0; i < num_tiles-2; i++) begin // repeat for num_tiles-2 times since we already did 1 tile above and 1 tile below
                ///////////////////////////
                // IDLE_STATE between tiles
                ///////////////////////////
                // send metadata for an 8x8 tile with bias and relu
                send_metadata(a_dim, w_dim, k_dim, 1'b0, 1'b0, 1'b1); // not the last tile and no new bias 

                //////////////////
                // LOAD_FIFO state for 2nd tile
                //////////////////
                // send tile data (same as 1st tile) and no bias this time in parallel
                send_aw_tile(a_dim, w_dim, k_dim);

                ////////////////
                // GEMM_COMPUTE state for 2nd tile
                ////////////////
                // wait for compute to finish
                wait_gemm_compute(a_dim, w_dim, k_dim, 1'b0); // not the last tile
            end
            ///////////////////////////
            // IDLE_STATE between tiles
            ///////////////////////////
            // send metadata for an 8x8 tile with bias and relu
            send_metadata(a_dim, w_dim, k_dim, 1'b1, 1'b0, 1'b1); // this is the last tile, but still no new bias

            ///////////////////////////////
            // LOAD_FIFO state for 3rd tile
            ///////////////////////////////
            // send tile data (same as 1st tile) and no bias this time in parallel
            send_aw_tile(a_dim, w_dim, k_dim);

            //////////////////////////////////
            // GEMM_COMPUTE state for 3rd tile
            //////////////////////////////////
            // wait for compute to finish
            wait_gemm_compute(a_dim, w_dim, k_dim, 1'b1); // this is the last tile

            ///////////////////
            // GEMM_FLUSH state
            ///////////////////
            // drain outputs and compare results
            fork
                drain_outputs(w_dim);
                result_compare(w_dim, a_dim, 1'b0);
            join
        end
    endtask

    // ----------------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------------
    initial begin
        // Load stimulus data from files
        $readmemh("activation_data.hex", activation_mem);
        $readmemh("weight_data.hex",     weight_mem);
        $readmemh("bias_data.hex",       bias_mem);
        $readmemh("scale_data.hex",      scale_mem);
        $readmemh("expected_single_tile_data.hex",   expected_single_tile_mem);
        $readmemh("expected_multi_tile_data.hex",    expected_multi_tile_mem);

        init_inputs();

        //-------------------------------
        // Single tile test w/ PE masking
        //-------------------------------
        $display("========= Start Single-tile with PE masking Test ! =========");
        single_tile_test(4, 4, 4); 
        @(posedge clk);
        $display("========= Single-tile with PE masking Test completed ! =========\n");
        repeat (5) @(posedge clk);

        //---------------------
        // Single 8x8 tile test
        //---------------------
        $display("========= Start Single-tile Test ! =========");
        single_tile_test(8, 8, 8);
        @(posedge clk);
        $display("========= Single-tile Test completed ! =========\n");
        
        //--------------------------------
        // Single tile test w/ rectangular PE masking
        //--------------------------------
        $display("========= Start Single-tile with rectangular PE masking Test ! =========");
        single_tile_test(8, 4, 8);
        @(posedge clk);
        $display("========= Single-tile with rectangular PE masking Test completed ! =========\n");

        //---------------------
        // Multi-tile test
        //---------------------
        $display("\n========= Start Multi-tile Test ! =========");
        multi_tile_test(8, 8, 8, 10);
        @(posedge clk);
        $display("========= Multi-tile Test completed ! =========\n");
        repeat (5) @(posedge clk);

        //--------------------------------
        // Multi-tile test w/ PE masking
        //--------------------------------
        $display("========= Start Multi-tile with PE masking Test ! =========");
        multi_tile_test(4, 4, 8, 10);
        @(posedge clk);
        $display("========= Multi-tile with PE masking Test completed ! =========\n");

        //--------------------------------
        // Multi-tile test w/ rectangular PE masking
        //--------------------------------
        $display("========= Start Multi-tile with rectangular PE masking Test ! =========");
        multi_tile_test(4, 8, 8, 10);
        @(posedge clk);
        $display("========= Multi-tile with rectangular PE masking Test completed ! =========\n");

        $stop;
    end
endmodule