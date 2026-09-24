//
//  MachInjector.c
//  Injects TroisLoader into running processes
//  Based on MacForge injection technique
//

#include "MachInjector.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>

#if defined(__x86_64__)
#include <mach/thread_status.h>
#elif defined(__arm64__)
#include <mach/arm/thread_status.h>
#include <mach/arm/_structs.h>
#include <ptrauth.h>
#endif

#define ADDR_TO_PTR(a) ((void*) (unsigned long) (a))
#define STACK_SIZE 0x8000
#define CODE_SIZE 512

// Function pointer for thread_convert_thread_state
kern_return_t (*_thread_convert_thread_state)(thread_act_t thread, int direction, thread_state_flavor_t flavor, thread_state_t in_state, mach_msg_type_number_t in_stateCnt, thread_state_t out_state, mach_msg_type_number_t *out_stateCnt);

static char shellCode[] =
#if defined(__x86_64__)
// x86_64 shellcode
"\x55"                            // push rbp
"\x48\x89\xe5"                    // mov rbp, rsp
"\x48\x83\xec\x10"                // sub rsp, 0x10
"\x48\xb8"                        // movabs rax, _pthread_set_self
"PTHRDSS_"
"\xff\xd0"                        // call rax
"\x48\x8d\x7d\xf8"                // lea rdi, [rbp-0x8]
"\x31\xc0"                        // xor eax, eax
"\x89\xc1"                        // mov ecx, eax
"\x48\x8d\x15\x30\x00\x00\x00"    // lea rdx, [rip+0x40]
"\x48\x89\xce"                    // mov rsi, rcx
"\x48\xb8"                        // movabs rax, pthread_create_from_mach_thread
"PTHRDCRT"
"\xff\xd0"                        // call rax
"\x48\xb8"                        // movabs rax, mach_thread_self
"THRDSELF"
"\xff\xd0"                        // call rax
"\x48\x89\xc7"                    // mov rdi, rax
"\x48\xb8"                        // movabs rax, thread_terminate
"THRDTERM"
"\xff\xd0"                        // call rax
"\x48\x83\xc4\x10"                // add rsp, 0x10
"\x5d"                            // pop rbp
"\xc3"                            // ret
// dlopen thread function
"\x55"                            // push rbp
"\x48\x89\xE5"                    // mov rbp, rsp
"\x48\x83\xEC\x10"                // sub rsp, 0x10
"\xBE\x01\x00\x00\x00"            // mov esi, 0x1 (RTLD_LAZY)
"\x48\x89\x7D\xF8"                // mov [rbp-8], rdi
"\x48\x8D\x3D\x1D\x00\x00\x00"    // lea rdi, [rip + libpath]
"\x48\xB8"                        // movabs rax, dlopen
"DLOPEN__"
"\xFF\xD0"                        // call rax
"\x31\xF6"                        // xor esi, esi
"\x89\xF7"                        // mov edi, esi
"\x48\x89\x45\xF0"                // mov [rbp-0x10], rax
"\x48\x89\xF8"                    // mov rax, rdi
"\x48\x83\xC4\x10"                // add rsp, 0x10
"\x5D"                            // pop rbp
"\xC3"                            // ret
#elif defined(__arm64__)
// arm64 shellcode with PAC support
"\xFF\xC3\x00\xD1"                // sub sp, sp, #0x30
"\xFD\x7B\x02\xA9"                // stp x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                // add x29, sp, #0x20
"\x09\x03\x00\x10"                // adr x9, pthread_set_self ptr
"\x29\x01\x40\xF9"                // ldr x9, [x9]
"\x20\x01\x3F\xD6"                // blr x9
"\xA0\xC3\x1F\xB8"                // stur w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                // str x1, [sp, #0x10]
"\xE0\x23\x00\x91"                // add x0, sp, #0x8
"\x08\x00\x80\xD2"                // mov x8, #0
"\xE8\x07\x00\xF9"                // str x8, [sp, #0x8]
"\xE1\x03\x08\xAA"                // mov x1, x8
"\xe2\x02\x00\x10"                // adr x2, dlopen_thread
"\xE2\x23\xC1\xDA"                // paciza x2
"\xE3\x03\x08\xAA"                // mov x3, x8
"\xc9\x01\x00\x10"                // adr x9, pthread_create ptr
"\x29\x01\x40\xF9"                // ldr x9, [x9]
"\x20\x01\x3F\xD6"                // blr x9
"\xa9\x01\x00\x10"                // adr x9, thread_self ptr
"\x29\x01\x40\xF9"                // ldr x9, [x9]
"\x20\x01\x3F\xD6"                // blr x9
"\x89\x01\x00\x10"                // adr x9, thread_terminate ptr
"\x29\x01\x40\xF9"                // ldr x9, [x9]
"\x20\x01\x3F\xD6"                // blr x9
"\xFD\x7B\x42\xA9"                // ldp x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                // add sp, sp, #0x30
"\xC0\x03\x5F\xD6"                // ret
"PTHRDSS_"
"PTHRDCRT"
"THRDSELF"
"THRDTERM"
// dlopen thread
"\x7F\x23\x03\xD5"                // pacibsp
"\xFF\xC3\x00\xD1"                // sub sp, sp, #0x30
"\xFD\x7B\x02\xA9"                // stp x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                // add x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                // stur w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                // str x1, [sp, #0x10]
"\x21\x00\x80\xD2"                // mov x1, #1 (RTLD_LAZY)
"\x60\x01\x00\x10"                // adr x0, libpath
"\x09\x01\x00\x10"                // adr x9, dlopen ptr
"\x29\x01\x40\xF9"                // ldr x9, [x9]
"\x20\x01\x3F\xD6"                // blr x9
"\x09\x00\x80\x52"                // mov w9, #0
"\xE0\x03\x09\xAA"                // mov x0, x9
"\xFD\x7B\x42\xA9"                // ldp x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                // add sp, sp, #0x30
"\xFF\x0F\x5F\xD6"                // retab
"DLOPEN__"
#endif
// Library path placeholder
"LIBLIBLIB\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

static char *libPathField = NULL;
static int initialized = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void patch_shellcode(void) {
    if (initialized) return;

    uint64_t addrOfPthreadCreate = (uint64_t)dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread");
    uint64_t addrOfPthreadSetSelf = (uint64_t)dlsym(RTLD_DEFAULT, "_pthread_set_self");
    uint64_t addrOfThreadSelf = (uint64_t)mach_thread_self;
    uint64_t addrOfThreadTerminate = (uint64_t)thread_terminate;
    uint64_t addrOfDlopen = (uint64_t)dlopen;

#if defined(__arm64__)
    addrOfPthreadCreate = (uint64_t)ptrauth_strip(ADDR_TO_PTR(addrOfPthreadCreate), ptrauth_key_function_pointer);
    addrOfPthreadSetSelf = (uint64_t)ptrauth_strip(ADDR_TO_PTR(addrOfPthreadSetSelf), ptrauth_key_function_pointer);
    addrOfThreadSelf = (uint64_t)ptrauth_strip(ADDR_TO_PTR(addrOfThreadSelf), ptrauth_key_function_pointer);
    addrOfThreadTerminate = (uint64_t)ptrauth_strip(ADDR_TO_PTR(addrOfThreadTerminate), ptrauth_key_function_pointer);
    addrOfDlopen = (uint64_t)ptrauth_strip(ADDR_TO_PTR(addrOfDlopen), ptrauth_key_function_pointer);
#endif

    char *p = shellCode;
    for (size_t i = 0; i < sizeof(shellCode); i++, p++) {
        if (memcmp(p, "PTHRDCRT", 8) == 0) {
            memcpy(p, &addrOfPthreadCreate, 8);
        } else if (memcmp(p, "PTHRDSS_", 8) == 0) {
            memcpy(p, &addrOfPthreadSetSelf, 8);
        } else if (memcmp(p, "THRDSELF", 8) == 0) {
            memcpy(p, &addrOfThreadSelf, 8);
        } else if (memcmp(p, "THRDTERM", 8) == 0) {
            memcpy(p, &addrOfThreadTerminate, 8);
        } else if (memcmp(p, "DLOPEN__", 8) == 0) {
            memcpy(p, &addrOfDlopen, 8);
        } else if (memcmp(p, "LIBLIBLIB", 9) == 0) {
            libPathField = p;
        }
    }

    // Load thread_convert_thread_state
    void *module = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (module) {
        _thread_convert_thread_state = dlsym(module, "thread_convert_thread_state");
        dlclose(module);
    }

    initialized = 1;
}

int trois_inject(pid_t pid, const char *bundle_path) {
    patch_shellcode();

    if (!libPathField) {
        fprintf(stderr, "TroisInjector: Failed to find library path field\n");
        return -1;
    }

    // Get task port for target process
    task_t remoteTask;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &remoteTask);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: task_for_pid failed: %s\n", mach_error_string(kr));
        return -1;
    }

    // Allocate stack in remote process
    mach_vm_address_t remoteStack64 = 0;
    kr = mach_vm_allocate(remoteTask, &remoteStack64, STACK_SIZE, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to allocate stack: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), remoteTask);
        return -1;
    }

    // Allocate code in remote process
    mach_vm_address_t remoteCode64 = 0;
    kr = mach_vm_allocate(remoteTask, &remoteCode64, sizeof(shellCode), VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to allocate code: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), remoteTask);
        return -1;
    }

    // Copy bundle path into shellcode
    pthread_mutex_lock(&lock);
    strncpy(libPathField, bundle_path, 255);

    // Write shellcode to remote process
    kr = mach_vm_write(remoteTask, remoteCode64, (vm_address_t)shellCode, sizeof(shellCode));
    pthread_mutex_unlock(&lock);

    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to write code: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), remoteTask);
        return -1;
    }

    // Set memory protections
    kr = vm_protect(remoteTask, (vm_address_t)remoteCode64, sizeof(shellCode), FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    kr = vm_protect(remoteTask, (vm_address_t)remoteStack64, STACK_SIZE, TRUE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to set memory protection: %s\n", mach_error_string(kr));
    }

    // Set up thread state
#if defined(__x86_64__)
    x86_thread_state64_t threadState;
    x86_thread_state64_t machineThreadState;
    thread_state_flavor_t flavor = x86_THREAD_STATE64;
    mach_msg_type_number_t stateCnt = x86_THREAD_STATE64_COUNT;
    mach_msg_type_number_t machineStateCnt = x86_THREAD_STATE64_COUNT;
#elif defined(__arm64__)
    struct arm_unified_thread_state threadState;
    struct arm_unified_thread_state machineThreadState;
    thread_state_flavor_t flavor = ARM_UNIFIED_THREAD_STATE;
    mach_msg_type_number_t stateCnt = ARM_UNIFIED_THREAD_STATE_COUNT;
    mach_msg_type_number_t machineStateCnt = ARM_UNIFIED_THREAD_STATE_COUNT;
#endif

    thread_act_t remoteThread = 0;
    memset(&threadState, 0, sizeof(threadState));
    memset(&machineThreadState, 0, sizeof(machineThreadState));

    remoteStack64 += (STACK_SIZE / 2);

#if defined(__x86_64__)
    threadState.__rdi = (uint64_t)(remoteStack64);
    threadState.__rip = (uint64_t)remoteCode64;
    threadState.__rsp = (uint64_t)((remoteStack64 + (STACK_SIZE/2)) - 8);
#elif defined(__arm64__)
    threadState.ash.flavor = ARM_THREAD_STATE64;
    threadState.ash.count = ARM_THREAD_STATE64_COUNT;
    threadState.ts_64.__x[0] = (uint64_t)(remoteStack64);
    __darwin_arm_thread_state64_set_pc_fptr(threadState.ts_64,
        ptrauth_sign_unauthenticated(ADDR_TO_PTR(remoteCode64), ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(threadState.ts_64,
        (unsigned long)((remoteStack64 + (STACK_SIZE/2))));
#endif

    // Create thread
    kr = thread_create(remoteTask, &remoteThread);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to create thread: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), remoteTask);
        return -1;
    }

    // Convert thread state if needed
    if (_thread_convert_thread_state) {
        kr = _thread_convert_thread_state(remoteThread, 2, flavor,
            (thread_state_t)&threadState, stateCnt,
            (thread_state_t)&machineThreadState, &machineStateCnt);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "TroisInjector: Failed to convert thread state: %s\n", mach_error_string(kr));
        }
    } else {
        machineThreadState = threadState;
    }

    // Set thread state
    kr = thread_set_state(remoteThread, flavor, (thread_state_t)&machineThreadState, machineStateCnt);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to set thread state: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), remoteThread);
        mach_port_deallocate(mach_task_self(), remoteTask);
        return -1;
    }

    // Resume thread
    kr = thread_resume(remoteThread);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "TroisInjector: Failed to resume thread: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), remoteThread);
        mach_port_deallocate(mach_task_self(), remoteTask);
        return -1;
    }

    printf("TroisInjector: Successfully injected into pid %d\n", pid);

    mach_port_deallocate(mach_task_self(), remoteThread);
    mach_port_deallocate(mach_task_self(), remoteTask);

    return 0;
}
