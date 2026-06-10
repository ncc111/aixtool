#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <string.h>

#define ALIGNMENT 4096 // 4KB memory alignment often required for direct I/O

// Helper function to calculate time differences
double get_time_diff(struct timeval start, struct timeval end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_usec - start.tv_usec) / 1000000.0;
}

int main(int argc, char *argv[]) {
    if (argc != 5) {
        printf("Usage: %s <filepath> <block_size_KB> <total_size_MB> <read|write>\n", argv[0]);
        printf("Example: %s /testfs/testfile.dat 64 1024 write\n", argv[0]);
        printf("Please ensure no IO cache and WRITE operation CORRUPT the file or device. \n");
        return 1;
    }

    const char *filepath = argv[1];
    size_t block_size = (size_t)atoi(argv[2]) * 1024;
    size_t total_size = (size_t)atoi(argv[3]) * 1024 * 1024;
    const char *operation = argv[4];

    int is_write = (strcmp(operation, "write") == 0);
    int is_read = (strcmp(operation, "read") == 0);

    if (!is_write && !is_read) {
        fprintf(stderr, "Error: Operation must be 'read' or 'write'.\n");
        return 1;
    }

    // O_SYNC ensures writes are flushed to physical storage before returning
    int flags = is_write ? (O_WRONLY | O_CREAT | O_SYNC) : (O_RDONLY);
    int fd = open(filepath, flags, 0644);
    if (fd < 0) {
        perror("Error opening file");
        return 1;
    }

    // Allocate aligned memory to support unbuffered I/O limits
    void *buffer;
    if (posix_memalign(&buffer, ALIGNMENT, block_size) != 0) {
        fprintf(stderr, "Error: Failed to allocate aligned memory.\n");
        close(fd);
        return 1;
    }

    // Fill buffer with dummy data for writes
    if (is_write) {
        memset(buffer, 'A', block_size);
    }

    size_t bytes_processed = 0;
    struct timeval start_time, end_time;

    printf("Starting %s test on %s...\n", operation, filepath);
    printf("Block Size: %zu Bytes | Total Size: %zu Bytes\n", block_size, total_size);

    gettimeofday(&start_time, NULL);

    while (bytes_processed < total_size) {
        ssize_t result = is_write ? write(fd, buffer, block_size) : read(fd, buffer, block_size);
        
        if (result <= 0) {
            perror("I/O Error during operation");
            break;
        }
        bytes_processed += result;
    }

    // Ensure data is synced to disk for writes before stopping the clock
    if (is_write) {
        fsync(fd);
    }

    gettimeofday(&end_time, NULL);

    double elapsed_time = get_time_diff(start_time, end_time);
    double throughput_mb = (bytes_processed / (1024.0 * 1024.0)) / elapsed_time;

    printf("\n--- Results ---\n");
    printf("Time Elapsed: %.4f seconds\n", elapsed_time);
    printf("Data Processed: %.2f MB\n", bytes_processed / (1024.0 * 1024.0));
    printf("Throughput: %.2f MB/s\n", throughput_mb);

    free(buffer);
    close(fd);
    
    // Clean up test file after write tests if you don't want it lingering
    // if (is_write) unlink(filepath); 

    return 0;
}
