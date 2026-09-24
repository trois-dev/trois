//
//  MachInjector.h
//  Trois Mach Injector
//

#ifndef MachInjector_h
#define MachInjector_h

#include <sys/types.h>

// Inject a bundle into a running process
// Returns 0 on success, -1 on failure
// Requires SIP disabled and root privileges
int trois_inject(pid_t pid, const char *bundle_path);

#endif /* MachInjector_h */
