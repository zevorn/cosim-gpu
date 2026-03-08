// Parallel sum reduction using shared memory.
// Tests __syncthreads, LDS, and tree-based reduction pattern.

#include "../common/test_utils.h"

#define BLOCK_SIZE 256

__global__ void reduce_sum(const float* input, float* output, int N) {
    __shared__ float sdata[BLOCK_SIZE];

    int tid = threadIdx.x;
    int i = blockIdx.x * blockDim.x * 2 + threadIdx.x;

    // Load two elements per thread
    float val = 0.0f;
    if (i < N) val += input[i];
    if (i + blockDim.x < N) val += input[i + blockDim.x];
    sdata[tid] = val;
    __syncthreads();

    // Tree reduction in shared memory
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s)
            sdata[tid] += sdata[tid + s];
        __syncthreads();
    }

    if (tid == 0)
        output[blockIdx.x] = sdata[0];
}

int main() {
    const int N = 1 << 12;  // 4K elements
    const size_t bytes = N * sizeof(float);
    int failures = 0;
    Timer timer;

    float *h_input = (float*)malloc(bytes);
    float ref_sum = 0.0f;

    for (int i = 0; i < N; i++) {
        h_input[i] = (float)(i % 100) * 0.01f;
        ref_sum += h_input[i];
    }

    float *d_input, *d_partial;
    int num_blocks = (N + BLOCK_SIZE * 2 - 1) / (BLOCK_SIZE * 2);
    HIP_CHECK(hipMalloc(&d_input, bytes));
    HIP_CHECK(hipMalloc(&d_partial, num_blocks * sizeof(float)));

    HIP_CHECK(hipMemcpy(d_input, h_input, bytes, hipMemcpyHostToDevice));

    timer.start();

    // First pass: reduce to partial sums
    hipLaunchKernelGGL(reduce_sum, dim3(num_blocks), dim3(BLOCK_SIZE), 0, 0,
                       d_input, d_partial, N);

    // Second pass: reduce partial sums (small enough for one block)
    float *d_result;
    int num_blocks2 = (num_blocks + BLOCK_SIZE * 2 - 1) / (BLOCK_SIZE * 2);
    HIP_CHECK(hipMalloc(&d_result, num_blocks2 * sizeof(float)));
    hipLaunchKernelGGL(reduce_sum, dim3(num_blocks2), dim3(BLOCK_SIZE), 0, 0,
                       d_partial, d_result, num_blocks);
    HIP_CHECK(hipDeviceSynchronize());
    double ms = timer.elapsed_ms();

    // Collect remaining partial sums on CPU
    float *h_partial = (float*)malloc(num_blocks2 * sizeof(float));
    HIP_CHECK(hipMemcpy(h_partial, d_result, num_blocks2 * sizeof(float),
                        hipMemcpyDeviceToHost));
    float gpu_sum = 0.0f;
    for (int i = 0; i < num_blocks2; i++)
        gpu_sum += h_partial[i];

    float rel_err = fabsf(gpu_sum - ref_sum) / fabsf(ref_sum);
    VERIFY("reduction correctness (rel_err < 1e-3)", rel_err < 1e-3f);
    printf("  ref=%.2f gpu=%.2f rel_err=%.6f\n", ref_sum, gpu_sum, rel_err);

    print_summary("reduction", failures, ms);

    hipFree(d_input); hipFree(d_partial); hipFree(d_result);
    free(h_input); free(h_partial);
    return failures;
}
