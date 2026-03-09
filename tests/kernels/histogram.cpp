// Histogram using atomicAdd.
// Tests atomic operations on both shared and global memory.

#include "../common/test_utils.h"

#define NUM_BINS 256
#define BLOCK_SIZE 256

__global__ void histogram(const int* input, int* bins, int N) {
    __shared__ int local_bins[NUM_BINS];

    int tid = threadIdx.x;

    // Initialize local bins
    if (tid < NUM_BINS)
        local_bins[tid] = 0;
    __syncthreads();

    // Count into shared memory bins
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N)
        atomicAdd(&local_bins[input[i] % NUM_BINS], 1);
    __syncthreads();

    // Merge local bins into global bins
    if (tid < NUM_BINS)
        atomicAdd(&bins[tid], local_bins[tid]);
}

int main() {
    const int N = BLOCK_SIZE;
    const size_t input_bytes = N * sizeof(int);
    const size_t bin_bytes = NUM_BINS * sizeof(int);
    int failures = 0;
    Timer timer;

    int *h_input = (int*)malloc(input_bytes);
    int *h_bins = (int*)calloc(NUM_BINS, sizeof(int));
    int *h_ref = (int*)calloc(NUM_BINS, sizeof(int));

    // Generate input data with known distribution
    for (int i = 0; i < N; i++) {
        h_input[i] = (i * 7 + 13) % NUM_BINS;
        h_ref[h_input[i]]++;
    }

    int *d_input, *d_bins;
    HIP_CHECK(hipMalloc(&d_input, input_bytes));
    HIP_CHECK(hipMalloc(&d_bins, bin_bytes));
    HIP_CHECK(hipMemset(d_bins, 0, bin_bytes));

    HIP_CHECK(hipMemcpy(d_input, h_input, input_bytes, hipMemcpyHostToDevice));

    int blocks = (N + BLOCK_SIZE - 1) / BLOCK_SIZE;

    timer.start();
    hipLaunchKernelGGL(histogram, dim3(blocks), dim3(BLOCK_SIZE), 0, 0,
                       d_input, d_bins, N);
    HIP_CHECK(hipDeviceSynchronize());
    double ms = timer.elapsed_ms();

    HIP_CHECK(hipMemcpy(h_bins, d_bins, bin_bytes, hipMemcpyDeviceToHost));

    int errs = check_int(h_ref, h_bins, NUM_BINS);
    VERIFY("histogram correctness", errs == 0);

    // Verify total count
    int total = 0;
    for (int i = 0; i < NUM_BINS; i++) total += h_bins[i];
    VERIFY("histogram total count == N", total == N);

    print_summary("histogram", failures, ms);

    (void)hipFree(d_input); (void)hipFree(d_bins);
    free(h_input); free(h_bins); free(h_ref);
    return failures;
}
