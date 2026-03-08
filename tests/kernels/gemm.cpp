// Tiled matrix multiplication using shared memory (LDS).
// C = A * B, where A is MxK, B is KxN, C is MxN.

#include "../common/test_utils.h"

#define TILE 16

__global__ void gemm_tiled(const float* A, const float* B, float* C,
                           int M, int N, int K) {
    __shared__ float sA[TILE][TILE];
    __shared__ float sB[TILE][TILE];

    int row = blockIdx.y * TILE + threadIdx.y;
    int col = blockIdx.x * TILE + threadIdx.x;
    float sum = 0.0f;

    for (int t = 0; t < (K + TILE - 1) / TILE; t++) {
        int aCol = t * TILE + threadIdx.x;
        int bRow = t * TILE + threadIdx.y;

        sA[threadIdx.y][threadIdx.x] =
            (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;
        sB[threadIdx.y][threadIdx.x] =
            (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;

        __syncthreads();

        for (int i = 0; i < TILE; i++)
            sum += sA[threadIdx.y][i] * sB[i][threadIdx.x];

        __syncthreads();
    }

    if (row < M && col < N)
        C[row * N + col] = sum;
}

// CPU reference
static void gemm_cpu(const float* A, const float* B, float* C,
                     int M, int N, int K) {
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            float sum = 0.0f;
            for (int k = 0; k < K; k++)
                sum += A[i * K + k] * B[k * N + j];
            C[i * N + j] = sum;
        }
}

int main() {
    const int M = 128, N = 128, K = 128;
    const size_t sA = M * K * sizeof(float);
    const size_t sB = K * N * sizeof(float);
    const size_t sC = M * N * sizeof(float);
    int failures = 0;
    Timer timer;

    float *h_A = (float*)malloc(sA);
    float *h_B = (float*)malloc(sB);
    float *h_C = (float*)malloc(sC);
    float *h_ref = (float*)malloc(sC);

    for (int i = 0; i < M * K; i++) h_A[i] = (float)(i % 50) * 0.02f;
    for (int i = 0; i < K * N; i++) h_B[i] = (float)(i % 37) * 0.03f;

    gemm_cpu(h_A, h_B, h_ref, M, N, K);

    float *d_A, *d_B, *d_C;
    HIP_CHECK(hipMalloc(&d_A, sA));
    HIP_CHECK(hipMalloc(&d_B, sB));
    HIP_CHECK(hipMalloc(&d_C, sC));

    HIP_CHECK(hipMemcpy(d_A, h_A, sA, hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(d_B, h_B, sB, hipMemcpyHostToDevice));

    dim3 threads(TILE, TILE);
    dim3 blocks((N + TILE - 1) / TILE, (M + TILE - 1) / TILE);

    timer.start();
    hipLaunchKernelGGL(gemm_tiled, blocks, threads, 0, 0,
                       d_A, d_B, d_C, M, N, K);
    HIP_CHECK(hipDeviceSynchronize());
    double ms = timer.elapsed_ms();

    HIP_CHECK(hipMemcpy(h_C, d_C, sC, hipMemcpyDeviceToHost));

    int errs = check_float(h_ref, h_C, M * N);
    VERIFY("gemm_tiled correctness", errs == 0);

    print_summary("gemm_tiled", failures, ms);

    (void)hipFree(d_A); (void)hipFree(d_B); (void)hipFree(d_C);
    free(h_A); free(h_B); free(h_C); free(h_ref);
    return failures;
}
