#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

typedef struct {
    uint32_t key;
    uint8_t reserved[24];
    uint32_t size, type;
    uint8_t attr, pad[3], result, status, command, pad2;
    uint32_t data32;
    uint8_t bytes[32];
} SMCMessage;
_Static_assert(sizeof(SMCMessage)==80, "SMC ABI");
static uint32_t key32(const char *s) { return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|s[3]; }
static int call(io_connect_t c, SMCMessage *in, SMCMessage *out) {
    size_t size = sizeof(*out);
    memset(out, 0, sizeof(*out));
    return IOConnectCallStructMethod(c, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS && out->result == 0 && size == sizeof(*out);
}
double read_cpu_temperature(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NAN;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) return NAN;
    const char *keys[] = {"Tp01","Tp05","Tp09","Tp0D","Tp0H","Tp0L","Tp04","Tp08","Tp0C","Te05","Te09"};
    double sum = 0; int count = 0;
    for (unsigned i=0; i<sizeof(keys)/sizeof(keys[0]); i++) {
        SMCMessage in = {0}, out = {0}; in.key=key32(keys[i]); in.command=9;
        if (!call(connection, &in, &out) || out.size != 4 || out.type != key32("flt ")) continue;
        in.size=out.size; in.command=5;
        if (!call(connection, &in, &out)) continue;
        float value; memcpy(&value, out.bytes, sizeof(value));
        if (isfinite(value) && value > 10 && value < 125) { sum+=value; count++; }
    }
    IOServiceClose(connection);
    return count ? sum/count : NAN;
}
