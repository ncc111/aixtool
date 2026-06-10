#include <stdio.h>
#include <sys/time.h>

int is_prime(int n) {
    if (n <= 1) return 0;
    for (int i = 2; i * i <= n; i++) {
        if (n % i == 0) return 0;
    }
    return 1;
}

int main() {
    int max_num = 30000000; // 30 Million
    int count = 0;
    struct timeval start, end;
    
    printf("Starting CPU benchmark: Calculating primes up to %d...\n", max_num);
    
    gettimeofday(&start, NULL);
    
    for (int i = 2; i <= max_num; i++) {
        if (is_prime(i)) {
            count++;
        }
    }
    
    gettimeofday(&end, NULL);
    
    double time_taken = (end.tv_sec - start.tv_sec) + 
                        (end.tv_usec - start.tv_usec) / 1000000.0;
    
    printf("Found %d primes.\n", count);
    printf("Time taken: %.4f seconds.\n", time_taken);
    
    return 0;
}
