#import "ZMFDeviceInfo.h"

#include <mach/mach.h>
#include <os/proc.h>
#include <unistd.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

BOOL ZMFProcessHasDebuggerJIT(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) != 0) return NO;
    return (flags & CS_DEBUGGED) != 0;
}

uint64_t ZMFMemoryFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

uint64_t ZMFAvailableMemory(void) {
    return os_proc_available_memory();
}
