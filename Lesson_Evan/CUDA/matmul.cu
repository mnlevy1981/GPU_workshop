#include <cuda_runtime.h>
#include <cuda.h>
#include "pch.h"

__global__ void SharedMatmul(const float *a, const float *b, float *c, const int m, const int p, const int q) {
  // Compute each thread's global row and column index
  int row = blockIdx.y * blockDim.y + threadIdx.y;
  int col = blockIdx.x * blockDim.x + threadIdx.x;

  // Statically allocate a tile of shared memory. Tile size should equal block size.
  __shared__ float s_a[SHMEM_SIZE];
  __shared__ float s_b[SHMEM_SIZE];

  // Declare a temporary variable to accumulate calculated elements
  // for the C matrix
  float tmp = 0.0;

  // Sweep tiles of size blockDim.x across matrices A and B
  // For matrix A, keep the row invariant and iterate through columns.
  // For matrix B, keep the column invariant and iterate through rows.
  for (int i = 0; i < p; i += blockDim.x) {
    // Load in elements from A and B into shared memory for this tile.
    int shared_index = threadIdx.y * blockDim.x + threadIdx.x;
    s_a[shared_index] = a[row * p + i + threadIdx.x];
    s_b[shared_index] = b[i * q + threadIdx.y * q + col];

    // Wait for tiles to be loaded in before doing computation
    __syncthreads();

    // Do matrix multiplication on the small matrix in the current tile.
    for (int j = 0; j < blockDim.x; j++) {
      tmp +=
          s_a[threadIdx.y * blockDim.x + j] * s_b[j * blockDim.x + threadIdx.x];
    }

    // Wait for all threads to finish using current tiles before loading in new
    // ones
    __syncthreads();
  }

  // Write resulting calculation as an element of the C matrix
  c[row * q + col] = tmp;
}

__host__ void gpuMatmul(const float *h_A, const float *h_B, float *h_C, const int m, const int p, const int q)
{
  float *d_A, *d_B, *d_C;

  // Allocate device matrices
  cudaMalloc(&d_A, m*p*sizeof(float));
  cudaMalloc(&d_B, p*q*sizeof(float));
  cudaMalloc(&d_C, m*q*sizeof(float));
  cudaCheckErrors("cudaMalloc failure");
  // Copy host matrices A and B to the device
  cudaMemcpy(d_A, h_A, m*p*sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_B, h_B, p*q*sizeof(float), cudaMemcpyHostToDevice);
  cudaCheckErrors("cudaMemcpy H2D failture");

  // Set threads per CUDA block dimension
  int thread_dim = BLOCK_SIZE;
  // Set blocks per grid dimension (assume thread_dim divides M and N evenly)
  int blocks_x = q / thread_dim;
  int blocks_y = m / thread_dim;
  // Use dim3 structs for block and grid dimensions
  dim3 threads(thread_dim, thread_dim);
  dim3 blocks(blocks_x, blocks_y);

  // Calcuate AxB=C on the device
  SharedMatmul<<<blocks, threads>>>(d_A, d_B, d_C, m, p, q);
  cudaCheckErrors("kernel launch failure");
  // Synchronize the device, then copy device C matrix to the host
  cudaDeviceSynchronize();
  cudaMemcpy(h_C, d_C, m*q*sizeof(float), cudaMemcpyDeviceToHost);
  cudaCheckErrors("Kernel execution failure or cudaMemcpy H2D failure");

  // Free the device matrices
  cudaFree(d_A);
  cudaFree(d_B);
  cudaFree(d_C);
  cudaCheckErrors("cudaFree failure");
}
