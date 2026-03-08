// Inclusive prefix sum (scan) using Hillis-Steele algorithm.
// Tests shared memory, multi-step synchronization, and data dependencies.

#include "../common/test_utils.h"

#define BLOCK_SIZE 256

// Hillis-Steele inclusive scan within a block
__global__ void inclusive_scan(const int* input, int* output,
                               int* block_sums, int N) {
    __shared__ int temp[2][BLOCK_SIZE];

    int tid = threadIdx.x;
    int gid = blockIdx.x * blockDim.x + threadIdx.x;

    int parity = 0;
    temp[0][tid] = (gid < N) ? input[gid] : 0;
    __syncthreads();

    for (int offset = 1; offset < BLOCK_SIZE; offset <<= 1) {
        temp[1 - parity][tid] = temp[parity][tid];
        if (tid >= offset)
            temp[1 - parity][tid] += temp[parity][tid - offset];
        parity = 1 - parity;
        __syncthreads();
    }

    if (gid < N)
        output[gid] = temp[parity][tid];

    // Store last element as block sum for multi-block scan
    if (tid == BLOCK_SIZE - 1 && block_sums != nullptr)
        block_sums[blockIdx.x] = temp[parity][tid];
}

// Add block offsets to produce final scan result
__global__ void add_block_offset(int* data, const int* offsets, int N) {
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid < N && blockIdx.x > 0)
        data[gid] += offsets[blockIdx.x - 1];
}

int main() {
    const int N = 1 << 12;  // 4K elements (keep small for cosim)
    const size_t bytes = N * sizeof(int);
    int failures = 0;
    Timer timer;

    int *h_input = (int*)malloc(bytes);
    int *h_output = (int*)malloc(bytes);
    int *h_ref = (int*)malloc(bytes);

    for (int i = 0; i < N; i++)
        h_input[i] = (i % 10) + 1;

    // CPU reference: inclusive prefix sum
    h_ref[0] = h_input[0];
    for (int i = 1; i < N; i++)
        h_ref[i] = h_ref[i - 1] + h_input[i];

    int *d_input, *d_output, *d_block_sums, *d_scanned_sums;
    int num_blocks = (N + BLOCK_SIZE - 1) / BLOCK_SIZE;
    HIP_CHECK(hipMalloc(&d_input, bytes));
    HIP_CHECK(hipMalloc(&d_output, bytes));
    HIP_CHECK(hipMalloc(&d_block_sums, num_blocks * sizeof(int)));
    HIP_CHECK(hipMalloc(&d_scanned_sums, num_blocks * sizeof(int)));

    HIP_CHECK(hipMemcpy(d_input, h_input, bytes, hipMemcpyHostToDevice));

    timer.start();

    // Step 1: scan within each block
    hipLaunchKernelGGL(inclusive_scan, dim3(num_blocks), dim3(BLOCK_SIZE),
                       0, 0, d_input, d_output, d_block_sums, N);

    // Step 2: scan the block sums (fits in one block for small N)
    if (num_blocks > 1) {
        hipLaunchKernelGGL(inclusive_scan, dim3(1), dim3(BLOCK_SIZE),
                           0, 0, d_block_sums, d_scanned_sums, nullptr,
                           num_blocks);

        // Step 3: add block offsets
        hipLaunchKernelGGL(add_block_offset, dim3(num_blocks),
                           dim3(BLOCK_SIZE), 0, 0,
                           d_output, d_scanned_sums, N);
    }

    HIP_CHECK(hipDeviceSynchronize());
    double ms = timer.elapsed_ms();

    HIP_CHECK(hipMemcpy(h_output, d_output, bytes, hipMemcpyDeviceToHost));

    int errs = check_int(h_ref, h_output, N);
    VERIFY("prefix_scan correctness", errs == 0);

    // Spot-check last element
    printf("  last element: ref=%d gpu=%d\n", h_ref[N - 1], h_output[N - 1]);

    print_summary("prefix_scan", failures, ms);

    (void)hipFree(d_input); (void)hipFree(d_output);
    (void)hipFree(d_block_sums); (void)hipFree(d_scanned_sums);
    free(h_input); free(h_output); free(h_ref);
    return failures;
}
