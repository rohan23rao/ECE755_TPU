`timescale 1ns / 1ps
import gemm_pkg::*;

module tpu_mnist_tb;

    // Memory arrays for testbench stimulus
    logic [ACT_WIDTH-1:0] mnist_activation_mem   [0:ARRAY_SIZE-1][0:ARRAY_SIZE * 98 - 1]; // 784 activations
    logic [ACT_WIDTH-1:0] layer_1_y_out_mem      [0:ARRAY_SIZE-1][0:ARRAY_SIZE * 32 - 1]; // 256 outputs
    logic [ACT_WIDTH-1:0] layer_2_y_out_mem      [0:ARRAY_SIZE-1][0:ARRAY_SIZE * 16 - 1]; // 128 outputs

    logic [WGT_WIDTH-1:0] layer_1_weight_mem     [0:ARRAY_SIZE * 98 - 1][0:ARRAY_SIZE * 32 - 1]; // 784 x 256 weights
    logic [WGT_WIDTH-1:0] layer_2_weight_mem     [0:ARRAY_SIZE * 32 - 1][0:ARRAY_SIZE * 16 - 1]; // 256 x 128 weights
    logic [WGT_WIDTH-1:0] layer_3_weight_mem     [0:ARRAY_SIZE * 16 - 1][0:10 - 1];              // 128 x 10 weights

    logic [ACC_WIDTH-1:0] layer_1_bias_mem       [0:ARRAY_SIZE * 32 - 1]; // 8 * 32 tiles
    logic [ACC_WIDTH-1:0] layer_2_bias_mem       [0:ARRAY_SIZE * 16 - 1]; // 8 * 16 tiles
    logic [ACC_WIDTH-1:0] layer_3_bias_mem       [0:10 - 1];              // 10 values  

    logic [ACC_WIDTH-1:0] layer_1_scale_mem      [0:ARRAY_SIZE * 32 - 1]; // 8 * 32 tiles
    logic [ACC_WIDTH-1:0] layer_2_scale_mem      [0:ARRAY_SIZE * 16 - 1]; // 8 * 16 tiles
    logic [ACC_WIDTH-1:0] layer_3_scale_mem      [0:10 - 1];              // 10 values

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

    // For visibility in waveform/debugging
    gemm_state_t state_output; 
    int number_of_tiles; 
    int set_of_y;

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
    task automatic send_aw_tile(input int a_dim, input int w_dim, input int k_dim, input int layer, input int set_y, input int i_tile);
        begin

            while (!DATA_RDY) @(posedge clk); // Wait for DUT to assert ready before next beat

            // When DATA_RDY = 1, send data_vld 1 cycle later, and keep it high until all data is sent.
            DATA_VLD = 1'b1; // send data_vld every cycle while sending tile data

            for (int k = 0; k < k_dim; k++) begin // 1 clk send k-element vectors for all ARRAY_SIZE rows/cols

                // Send activation & weight data for this k index depending on the layer
                if (layer == 2) begin 
                    for (int r = 0; r < a_dim; r++) begin // load activation column by column
                        A_DATA[r] <= layer_1_y_out_mem[r][k + i_tile * 8]; 
                    end

                    for (int c = 0; c < w_dim; c++) begin // load weight row by row
                        W_DATA[c] <= layer_2_weight_mem[k + i_tile * 8][c + set_y * 8];
                    end
                end

                else if (layer == 3) begin 
                    for (int r = 0; r < a_dim; r++) begin // load activation column by column
                        A_DATA[r] <= layer_2_y_out_mem[r][k + i_tile * 8]; 
                    end

                    for (int c = 0; c < w_dim; c++) begin // load weight row by row
                        W_DATA[c] <= layer_3_weight_mem[k + i_tile * 8][c + set_y * 8];
                    end
                end

                else begin // layer 1, load activations from activation_mem, weight from weight_mem 
                    for (int r = 0; r < a_dim; r++) begin // load activation column by column
                        A_DATA[r] <= mnist_activation_mem[r][k + i_tile * 8]; 
                    end
                
                    for (int c = 0; c < w_dim; c++) begin // load weight row by row
                        W_DATA[c] <= layer_1_weight_mem[k + i_tile * 8][c + set_y * 8];
                    end
                end

                @(posedge clk);
            end

            // After sending the whole tile, deassert data_vld and clear data signals
            DATA_VLD <= 1'b0;
            for (int i = 0; i < ARRAY_SIZE; i++) begin
                A_DATA[i] <= '0;
                W_DATA[i] <= '0;
            end
        end
    endtask

    // Task to send bias vector to PEs, 1 element per cycle during LOAD_FIFO state. 
    task automatic send_bias_vec(input int w_dim, input int layer, input int set_y);
        begin
            
            while (!BIAS_RDY) @(posedge clk);
            BIAS_VLD <= 1'b1; // send bias_vld every cycle while sending bias vector

            for (int c = 0; c < w_dim; c++) begin // send a bias per clk for the first w_dim columns

                if (layer == 1)
                    BIAS <= layer_1_bias_mem[c + set_y * 8];
                else if (layer == 2)
                    BIAS <= layer_2_bias_mem[c + set_y * 8];
                else
                    BIAS <= layer_3_bias_mem[c + set_y * 8];

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
    task automatic drain_outputs(input int w_dim, input int layer, input int set_y);
        begin
            for (int c = 0; c < w_dim; c++) begin
                SCALE_VLD = 1'b1; // tell DUT that the scale for this output column is valid
                Y_RDY     = 1'b1; // tell DUT that TB is ready to receive output data for this column

                if (layer == 1)
                    SCALE = layer_1_scale_mem[c + set_y * 8];
                else if (layer == 2)
                    SCALE = layer_2_scale_mem[c + set_y * 8];
                else
                    SCALE = layer_3_scale_mem[c + set_y * 8];

                @ (posedge clk); // send 1 scale per clk 
            end

            Y_RDY     <= 1'b0;
            SCALE_VLD <= 1'b0;
            SCALE     <= '0;
        end
    endtask

    // Write ouputs to memory arrays in testbench
    task automatic collect_outputs(input int w_dim, input int a_dim, input int layer, input int set_y);
        begin
            for (int c = 0; c < w_dim; c++) begin

                wait (Y_VLD); // wait until output for this column is valid
                @(negedge clk);

                for (int r = 0; r < a_dim; r++) begin
                    if (layer == 1)
                        layer_1_y_out_mem[r][c + set_y * 8] = Y_OUT[r];
                    else if (layer == 2) 
                        layer_2_y_out_mem[r][c + set_y * 8] = Y_OUT[r];
                end
            end
        end
    endtask
    

    task automatic display_outputs(input int w_dim, input int layer, input int set_y);
        begin
            for (int c = 0; c < w_dim; c++) begin
                wait (Y_VLD); // wait until output for this column is valid
                @(negedge clk);
                $display(" Output Y[%0d] = %0h", c + set_y * 8, Y_OUT[0]); 
            end
        end
    endtask

    //-----------------------------------------------------------------------
    // Task for multi tile
    //-----------------------------------------------------------------------
    task automatic multi_tile_test(input int a_dim, input int w_dim, input int k_dim, input int num_tiles, input int layer, input int set_y);
        begin
            //////////////
            // IDLE_STATE
            //////////////
            // Reset sequence
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);

            // for visibility in waveform/debugging
            number_of_tiles = 1; 
            set_of_y = set_y + 1;

            // send metadata for an 8x8 tile with bias and relu
            send_metadata(a_dim, w_dim, k_dim, 1'b0, 1'b1, 1'b1); // tile_last, bias_new, relu_en

            //////////////////
            // LOAD_FIFO state
            //////////////////
            // send tile data and bias vector in parallel
            fork
                send_aw_tile(a_dim, w_dim, k_dim, layer, set_y, 0);
                send_bias_vec(w_dim, layer, set_y);
            join

            /////////////////////
            // GEMM_COMPUTE state
            /////////////////////
            // wait for compute to finish
            wait_gemm_compute(a_dim, w_dim, k_dim, 1'b0); // not the last tile

            for (int i = 0; i < num_tiles - 2; i++) begin // repeat for num_tiles-2 times since we already did 1 tile above and 1 tile below
                
                // for visibility in waveform/debugging
                number_of_tiles = i + 2; 

                ///////////////////////////
                // IDLE_STATE between tiles
                ///////////////////////////
                // send metadata for an 8x8 tile with bias and relu
                send_metadata(a_dim, w_dim, k_dim, 1'b0, 1'b0, 1'b1); // not the last tile and no new bias 

                //////////////////
                // LOAD_FIFO state for 2nd tile
                //////////////////
                // send tile data (same as 1st tile) and no bias this time in parallel
                send_aw_tile(a_dim, w_dim, k_dim, layer, set_y, i+1);

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
            send_aw_tile(a_dim, w_dim, k_dim, layer, set_y, num_tiles-1);

            // for visibility in waveform/debugging
            number_of_tiles = num_tiles;

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
                collect_outputs(w_dim, a_dim, layer, set_y);
                drain_outputs(w_dim, layer, set_y);
                display_outputs(w_dim, layer, set_y);
            join
        end
    endtask

    // ----------------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------------


    initial begin
        // Load stimulus data from files
        $readmemh("mnist_activation_data.hex",   mnist_activation_mem);

        $readmemh("layer_1_weight_data.hex",     layer_1_weight_mem);
        $readmemh("layer_2_weight_data.hex",     layer_2_weight_mem);
        $readmemh("layer_3_weight_data.hex",     layer_3_weight_mem);

        $readmemh("layer_1_bias_data.hex",       layer_1_bias_mem);
        $readmemh("layer_2_bias_data.hex",       layer_2_bias_mem);
        $readmemh("layer_3_bias_data.hex",       layer_3_bias_mem);

        $readmemh("layer_1_scale_data.hex",      layer_1_scale_mem);
        $readmemh("layer_2_scale_data.hex",      layer_2_scale_mem);
        $readmemh("layer_3_scale_data.hex",      layer_3_scale_mem);

        init_inputs();

        //------------------------------------
        // First layer of MNIST (784 -- > 256)
        //------------------------------------
        $display("========= Start First layer of MNIST ! =========");

        // K = 784, J = 256, a set of y needs to be accumulated 98 times for a set of 8 Y_OUT, so 256 Y_OUT need 32 tiles  
        for (int set_y = 0; set_y < 32; set_y++) begin 
            // a_dim, w_dim, k_dim, num_tiles, layer, set_y
            multi_tile_test(1, 8, 8, 98, 1, set_y); 
        end

        @(posedge clk);
        $display("========= First layer of MNIST completed ! =========\n\n");
        repeat (5) @(posedge clk);

        //-------------------------------------
        // Second layer of MNIST (256 -- > 128)
        //-------------------------------------
        $display("========= Start Second layer of MNIST ! =========");

        // K = 256, J = 128, a set of y needs to be accumulated 32 times for a set of 8 Y_OUT, so 128 Y_OUT need 16 tiles
        for (int set_y = 0; set_y < 16; set_y++) begin 
            multi_tile_test(1, 8, 8, 32, 2, set_y);
        end
        
        @(posedge clk);
        $display("========= Second layer of MNIST completed ! =========\n\n");
        repeat (5) @(posedge clk);

        //-----------------------------------
        // Third layer of MNIST (128 -- > 10)
        //-----------------------------------
        $display("========= Start Third layer of MNIST ! =========");

        // K = 128, J = 10, a set of y needs to be accumulated 16 times for a set of 8 Y_OUT, so 10 Y_OUT need 2 tiles

        multi_tile_test(1, 8, 8, 16, 3, 0);
        multi_tile_test(1, 2, 8, 16, 3, 1); // the second tile for the last 2 Y_OUT
    
        @(posedge clk);
        $display("========= Third layer of MNIST completed ! =========\n\n");

        $stop;
    end
endmodule
