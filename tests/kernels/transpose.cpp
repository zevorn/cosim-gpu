// Matrix transpose using shared memory to avoid uncoalesced writes.
// Keep it single-dispatch because current cosim is unstable across
// dependent kernel launches in the same process.

#include "../common/test_utils.h"

#define TILE 16

// Shared memory transpose with +1 padding to avoid bank conflicts
__global__ void transpose_smem(const float* in, float* out, int W, int H) {
    __shared__ float tile[TILE][TILE + 1];  // +1 padding avoids bank conflicts

    int xIdx = blockIdx.x * TILE + threadIdx.x;
    int yIdx = blockIdx.y * TILE + threadIdx.y;

    // Read tile from input (coalesced)
    if (xIdx < W && yIdx < H)
        tile[threadIdx.y][threadIdx.x] = in[yIdx * W + xIdx];
    __syncthreads();

    // Write tile to output (coalesced after transpose)
    int oxIdx = blockIdx.y * TILE + threadIdx.x;
    int oyIdx = blockIdx.x * TILE + threadIdx.y;
    if (oxIdx < H && oyIdx < W)
        out[oyIdx * H + oxIdx] = tile[threadIdx.x][threadIdx.y];
}

int main() {
    const int W = 64, H = 64;
    const size_t bytes = W * H * sizeof(float);
    int failures = 0;
    Timer timer;

    float *h_in = (float*)malloc(bytes);
    float *h_out_smem = (float*)malloc(bytes);
    float *h_ref = (float*)malloc(bytes);

    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            h_in[y * W + x] = (float)(y * W + x) * 0.001f;
            h_ref[x * H + y] = h_in[y * W + x];  // CPU transpose
        }

    float *d_in, *d_out;
    HIP_CHECK(hipMalloc(&d_in, bytes));
    HIP_CHECK(hipMalloc(&d_out, bytes));
    HIP_CHECK(hipMemcpy(d_in, h_in, bytes, hipMemcpyHostToDevice));

    dim3 threads(TILE, TILE);
    dim3 blocks((W + TILE - 1) / TILE, (H + TILE - 1) / TILE);

    HIP_CHECK(hipMemset(d_out, 0, bytes));
    timer.start();
    hipLaunchKernelGGL(transpose_smem, blocks, threads, 0, 0,
                       d_in, d_out, W, H);
    HIP_CHECK(hipDeviceSynchronize());
    double ms_smem = timer.elapsed_ms();
    HIP_CHECK(hipMemcpy(h_out_smem, d_out, bytes, hipMemcpyDeviceToHost));

    int errs = check_float(h_ref, h_out_smem, W * H);
    VERIFY("transpose_smem correctness", errs == 0);

    print_summary("transpose", failures, ms_smem);

    (void)hipFree(d_in); (void)hipFree(d_out);
    free(h_in); free(h_out_smem); free(h_ref);
    return failures;
}
