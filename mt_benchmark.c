#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/time.h>
#include <unistd.h>

#define LIMIT 50000000 // 50 Million total range

typedef struct {
    int thread_id;
    int start;
    int end;
    int prime_count;
} ThreadData;

// Prime checking function
int is_prime(int n) {
    if (n <= 1) return 0;
    for (int i = 2; i * i <= n; i++) {
        if (n % i == 0) return 0;
    }
    return 1;
}

// Worker thread routine
void* benchmark_worker(void* arg) {
    ThreadData* data = (ThreadData*)arg;
    data->prime_count = 0;
    
    for (int i = data->start; i <= data->end; i++) {
        if (is_prime(i)) {
            data->prime_count++;
        }
    }
    pthread_exit(NULL);
}

int main() {
    // 1. Detect available online CPU cores on AIX
    long num_cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (num_cores < 1) num_cores = 1;
    
    printf("AIX System Detected: %ld Online Logical Processors.\n", num_cores);
    printf("Spawning %ld threads to benchmark multi-threaded capacity...\n", num_cores);
    printf("Calculating primes up to %d...\n", LIMIT);
    printf("--------------------------------------------------\n");

    pthread_t threads[num_cores];
    ThreadData thread_data[num_cores];
    struct timeval start_time, end_time;
    
    // 2. Divide work evenly among threads
    int range_per_thread = LIMIT / num_cores;
    
    gettimeofday(&start_time, NULL);
    
    // 3. Launch threads
    for (int i = 0; i < num_cores; i++) {
        thread_data[i].thread_id = i;
        thread_data[i].start = (i * range_per_thread) + 1;
        // Ensure the last thread covers any remainder
        thread_data[i].end = (i == num_cores - 1) ? LIMIT : (i + 1) * range_per_thread;
        
        if (pthread_create(&threads[i], NULL, benchmark_worker, (void*)&thread_data[i]) != 0) {
            perror("Failed to create thread");
            return 1;
        }
    }
    
    // 4. Wait for all threads to finish (Join)
    int total_primes = 0;
    for (int i = 0; i < num_cores; i++) {
        pthread_join(threads[i], NULL);
        total_primes += thread_data[i].prime_count;
    }
    
    gettimeofday(&end_time, NULL);
    
    double elapsed_time = (end_time.tv_sec - start_time.tv_sec) + 
                          (end_time.tv_usec - start_time.tv_usec) / 1000000.0;
    
    // 5. Output results
    printf("Benchmark Completed successfully.\n");
    printf("Total Primes Found: %d\n", total_primes);
    printf("Total Time Taken  : %.4f seconds\n", elapsed_time);
    printf("Processing Rate   : %.2f operations/sec (scaled)\n", (double)LIMIT / elapsed_time);
    
    return 0;
}
