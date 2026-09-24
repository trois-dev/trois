//
//  main.m
//  TroisInjector - Command-line injection tool
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import "UniversalInj.h"

// Installed next to this helper by Trois, so only root can replace it.
static const char *kLoaderPath = "/Library/PrivilegedHelperTools/TroisLoader.bundle/Contents/MacOS/TroisLoader";

// A pid can be reused between the app listing it and the admin prompt closing,
// so each target carries its start time and must still match it here.
static BOOL targetMatches(pid_t pid, long long startMicros) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) {
        fprintf(stderr, "pid %d is gone\n", pid);
        return NO;
    }
    struct timeval start = info.kp_proc.p_starttime;
    if ((long long)start.tv_sec * 1000000 + start.tv_usec != startMicros) {
        fprintf(stderr, "pid %d is a different process now\n", pid);
        return NO;
    }
    if (info.kp_eproc.e_ucred.cr_uid == 0) {
        fprintf(stderr, "pid %d runs as root, skipped\n", pid);
        return NO;
    }
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <pid>:<start microseconds>...\n", argv[0]);
            fprintf(stderr, "Injects TroisLoader into each listed process.\n");
            return 2;
        }

        struct stat st;
        if (stat(kLoaderPath, &st) != 0 || st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH))) {
            fprintf(stderr, "Loader missing or not owned by root: %s\n", kLoaderPath);
            return 2;
        }

        int failures = 0;
        for (int i = 1; i < argc; i++) {
            int pid = 0;
            long long startMicros = 0;
            char extra;
            if (sscanf(argv[i], "%d:%lld%c", &pid, &startMicros, &extra) != 2 || pid <= 0) {
                fprintf(stderr, "Invalid target: %s\n", argv[i]);
                failures++;
                continue;
            }
            if (!targetMatches(pid, startMicros) || inject_sync(pid, kLoaderPath) != KERN_SUCCESS) {
                failures++;
            }
        }
        return failures == 0 ? 0 : 1;
    }
}
