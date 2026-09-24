//
//  main.m
//  TroisInjector - Command-line injection tool
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import "UniversalInj.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        fprintf(stderr, "TroisInjector: Starting\n");
        fflush(stderr);

        if (argc != 3) {
            fprintf(stderr, "Usage: %s <pid> <bundle_path>\n", argv[0]);
            fprintf(stderr, "Injects TroisLoader into the specified process.\n");
            return 1;
        }

        pid_t pid = atoi(argv[1]);
        const char *bundlePath = argv[2];

        if (pid <= 0) {
            fprintf(stderr, "Invalid PID: %s\n", argv[1]);
            return 1;
        }

        fprintf(stderr, "TroisInjector: About to get task for pid %d\n", pid);
        fflush(stderr);

        // Test task_for_pid first
        task_t task;
        kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
        fprintf(stderr, "TroisInjector: task_for_pid returned %d (%s)\n", kr, mach_error_string(kr));
        fflush(stderr);

        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "TroisInjector: Failed to get task port\n");
            return 1;
        }

        fprintf(stderr, "TroisInjector: Calling inject_sync\n");
        fflush(stderr);

        inject_sync(pid, bundlePath);

        fprintf(stderr, "TroisInjector: Injection complete\n");
        fflush(stderr);

        return 0;
    }
}
