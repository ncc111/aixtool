#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <stdint.h>

// Set test size: 1GB (Ensures it exceeds L3 Cache to test actual RAM speed)
#define TEST_SIZE_BYTES (1024LL * 1024LL * 1024LL) 

// Function to get current time in seconds (with microsecond precision)
double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

int main() {
    printf("=== Memory Bandwidth Test (AIX Environment) ===\n");
    printf("Preparing to allocate %.2f GB of memory...\n", (double)TEST_SIZE_BYTES / (1024 * 1024 * 1024));

    // 1. Allocate memory (Using a 64-bit integer array)
    size_t num_elements = TEST_SIZE_BYTES / sizeof(uint64_t);
    uint64_t *array = (uint64_t *)malloc(TEST_SIZE_BYTES);

    if (array == NULL) {
        printf("Memory allocation failed! Please check available system RAM.\n");
        return 1;
    }

    // 2. Warm-up - Bypassing OS Lazy Allocation (Page Faults)
    printf("Initializing memory (Triggering Page Faults)...\n");
    for (size_t i = 0; i < num_elements; i++) {
        array[i] = 1; // Forcing the OS to actually assign physical memory
    }
    printf("Initialization complete. Starting benchmark...\n\n");

    double start_time, end_time, time_spent, bandwidth;

    // ---------------------------------------------------
    // Test 1: Sequential Write
    // ---------------------------------------------------
    start_time = get_time();
    for (size_t i = 0; i < num_elements; i++) {
        array[i] = i; 
    }
    end_time = get_time();
    
    time_spent = end_time - start_time;
    bandwidth = ((double)TEST_SIZE_BYTES / (1024 * 1024 * 1024)) / time_spent;
    
    printf("[Sequential Write] Time elapsed: %.4f seconds\n", time_spent);
    printf("[Sequential Write] Bandwidth:    %.2f GB/s\n", bandwidth);

    // ---------------------------------------------------
    // Test 2: Sequential Read
    // ---------------------------------------------------
    // Using 'volatile' prevents the compiler from optimizing away the read loop
    volatile uint64_t dummy_sum = 0; 
    
    start_time = get_time();
    for (size_t i = 0; i < num_elements; i++) {
        dummy_sum += array[i];
    }
    end_time = get_time();

    time_spent = end_time - start_time;
    bandwidth = ((double)TEST_SIZE_BYTES / (1024 * 1024 * 1024)) / time_spent;

    printf("[Sequential Read]  Time elapsed: %.4f seconds\n", time_spent);
    printf("[Sequential Read]  Bandwidth:    %.2f GB/s\n", bandwidth);

    // Print the dummy_sum to ensure the compiler treats the operations as necessary
    printf("\n(Debug) Checksum: %llu\n", dummy_sum);

    // 3. Free memory
    free(array);
    printf("Test complete. Memory freed.\n");

    return 0;
}
