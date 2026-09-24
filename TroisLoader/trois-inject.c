//
//  trois-inject.c
//  Command-line tool to inject TroisLoader into processes
//

#include <stdio.h>
#include <stdlib.h>
#include "MachInjector.h"

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <pid> <bundle_path>\n", argv[0]);
        fprintf(stderr, "Injects TroisLoader.bundle into a running process.\n");
        fprintf(stderr, "Requires SIP disabled and root privileges.\n");
        return 1;
    }

    pid_t pid = atoi(argv[1]);
    const char *bundle = argv[2];

    if (pid <= 0) {
        fprintf(stderr, "Invalid PID: %s\n", argv[1]);
        return 1;
    }

    printf("Injecting %s into pid %d...\n", bundle, pid);
    int result = trois_inject(pid, bundle);

    if (result == 0) {
        printf("Success!\n");
    } else {
        printf("Failed.\n");
    }

    return result == 0 ? 0 : 1;
}
