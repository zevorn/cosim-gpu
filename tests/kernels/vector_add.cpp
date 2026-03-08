// Vector addition: C[i] = A[i] + B[i]
// Basic sanity test for HIP compute on cosim.

#include "../common/test_utils.h"

__global__ void vector_add(const float* A, const float* B, float* C, int N) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < N)
        C[i] = A[i] + B[i];
}

int main() {
    const int N = 1 << 12;  // 4K elements
    const size_t bytes = N * sizeof(float);
    int failures = 0;
    Timer timer;

    float *h_A = (float*)malloc(bytes);
    float *h_B = (float*)malloc(bytes);
    float *h_C = (float*)malloc(bytes);
    float *h_ref = (float*)malloc(bytes);

    for (int i = 0; i < N; i++) {
        h_A[i] = (float)(i % 1000) * 0.01f;
        h_B[i] = (float)((i * 7) % 1000) * 0.01f;
        h_ref[i] = h_A[i] + h_B[i];
    }

    float *d_A, *d_B, *d_C;
    HIP_CHECK(hipMalloc(&d_A, bytes));
    HIP_CHECK(hipMalloc(&d_B, bytes));
    HIP_CHECK(hipMalloc(&d_C, bytes));

    HIP_CHECK(hipMemcpy(d_A, h_A, bytes, hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(d_B, h_B, bytes, hipMemcpyHostToDevice));

    timer.start();
    int threads = 256;
    int blocks = (N + threads - 1) / threads;
    hipLaunchKernelGGL(vector_add, dim3(blocks), dim3(threads), 0, 0,
                       d_A, d_B, d_C, N);
    HIP_CHECK(hipDeviceSynchronize());
    double ms = timer.elapsed_ms();

    HIP_CHECK(hipMemcpy(h_C, d_C, bytes, hipMemcpyDeviceToHost));

    int errs = check_float(h_ref, h_C, N);
    VERIFY("vector_add correctness", errs == 0);

    print_summary("vector_add", failures, ms);

    hipFree(d_A); hipFree(d_B); hipFree(d_C);
    free(h_A); free(h_B); free(h_C); free(h_ref);
    return failures;
}
