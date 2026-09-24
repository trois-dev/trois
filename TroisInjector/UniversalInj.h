//
//  UniversalInj.h
//  UniversalInj
//
//  Created by Jeremy on 12/1/20.
//

#ifndef UniversalInj_h
#define UniversalInj_h

#include <stdio.h>
#include <sys/types.h>
#include <mach/mach.h>

// Loads the library at lib into the process. Needs root and SIP debugging restrictions off.
kern_return_t inject_sync(pid_t pid, const char *lib);

#endif /* UniversalInj_h */
