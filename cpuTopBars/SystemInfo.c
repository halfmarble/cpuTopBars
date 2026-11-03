// The MIT License (MIT)

// Copyright 2026 Halfmarble LLC

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#include "SystemInfo.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>

// taken once and kept, as CpuSampler.c keeps its port: each mach_host_self() adds a reference to the port
static mach_port_t HostPort(void)
{
  static mach_port_t host = MACH_PORT_NULL;
  if (host == MACH_PORT_NULL)
  {
    host = mach_host_self();
  }
  return host;
}

#pragma mark - CPU

#define CPU_RING_SIZE   (64)    // 6.3 s at the fastest refresh (0.1 s), enough for a 1 s window at every setting
#define CPU_WINDOW      (1.0)   // s
#define CPU_EACH_MAX    (64)    // logical CPUs whose own ticks a sample keeps; a Mac with more keeps none (eachCount 0)

struct CpuSample
{
  uint32_t ticks[CPU_STATE_MAX];        // the host's
  uint32_t cpuTicks[CPU_STATE_MAX];     // every CPU's, summed
  uint32_t kindTicks[2][CPU_STATE_MAX]; // [0] the E-cores', [1] the P-cores', each summed over its CPUs
  uint32_t eachTicks[CPU_EACH_MAX][CPU_STATE_MAX]; // each CPU's own, in host_processor_info's order
  natural_t eachCount;          // CPUs in eachTicks; 0: none kept
  bool     perCpu;              // cpuTicks were read
  bool     kinds;               // kindTicks were read
  double   time;                // s, CLOCK_MONOTONIC_RAW
}
typedef CpuSample;

static CpuSample cpuRing[CPU_RING_SIZE];
static int cpuCount = 0;        // samples stored, at most CPU_RING_SIZE
static int cpuNewest = -1;      // index of the newest sample

static char* cpuKinds = NULL;   // each logical CPU's kind, 'E' or 'P', in host_processor_info's order; NULL: none
static natural_t cpuKindsCount = 0;

void SystemInfoCpuSetKinds(natural_t count, const char* kinds)
{
  free(cpuKinds);
  cpuKinds = NULL;
  cpuKindsCount = 0;
  if ((kinds != NULL) && (count > 0))
  {
    cpuKinds = (char*)malloc(count);
    if (cpuKinds != NULL)
    {
      memcpy(cpuKinds, kinds, count);
      cpuKindsCount = count;
    }
  }
}

// every CPU's ticks, summed, into the sample's cpuTicks (perCpu: false when the CPUs cannot be read), and each kind's,
// summed over its CPUs, into its kindTicks (kinds: false also when there are no kinds or the CPUs' count is not the
// kinds'). The sums wrap in 32 bits as the kernel's counters do, so a difference of two of them is still right across
// a wrap. Each CPU's counters advance about 100 ticks a second, steadily, where the host's stall and catch up (over
// three 1 s windows on an M3, 798-803 summed over its 8 CPUs against the host's 794, 1,121 and 655). Each CPU's own
// ticks too, into eachTicks, up to CPU_EACH_MAX CPUs (eachCount: 0 when they cannot be read or there are more)
static void CpuEachTicks(CpuSample* sample)
{
  sample->perCpu = false;
  sample->kinds = false;
  sample->eachCount = 0;
  natural_t count = 0;
  processor_cpu_load_info_t load = NULL;
  mach_msg_type_number_t size = 0;
  if (host_processor_info(HostPort(), PROCESSOR_CPU_LOAD_INFO, &count, (processor_info_array_t*)&load, &size) != KERN_SUCCESS)
  {
    return;
  }
  bool kinds = (cpuKinds != NULL) && (count == cpuKindsCount);
  bool each = (count <= CPU_EACH_MAX);
  memset(sample->cpuTicks, 0, sizeof(sample->cpuTicks));
  memset(sample->kindTicks, 0, sizeof(sample->kindTicks));
  for (natural_t c=0; c<count; c++)
  {
    int kind = (kinds && (cpuKinds[c] == 'E')) ? 0 : 1;
    for (int i=0; i<CPU_STATE_MAX; i++)
    {
      sample->cpuTicks[i] += load[c].cpu_ticks[i];
      sample->kindTicks[kind][i] += load[c].cpu_ticks[i];
      if (each)
      {
        sample->eachTicks[c][i] = load[c].cpu_ticks[i];
      }
    }
  }
  sample->eachCount = each ? count : 0;
  sample->perCpu = true;
  sample->kinds = kinds;
  // size counts integers; vm_deallocate takes bytes
  vm_deallocate(mach_task_self(), (vm_address_t)load, (vm_size_t)size * sizeof(integer_t));
}

// the busy share (0..1) of the ticks between then and now, or -1 with none; differenced in 32 bits, so a wrap is
// harmless
static double CpuTicksBusy(const uint32_t* now, const uint32_t* then)
{
  uint32_t user   = now[CPU_STATE_USER]   - then[CPU_STATE_USER];
  uint32_t system = now[CPU_STATE_SYSTEM] - then[CPU_STATE_SYSTEM];
  uint32_t nice   = now[CPU_STATE_NICE]   - then[CPU_STATE_NICE];
  uint32_t idle   = now[CPU_STATE_IDLE]   - then[CPU_STATE_IDLE];
  double used = (double)user + (double)system + (double)nice;
  double total = used + (double)idle;
  return (total == 0.0) ? -1.0 : used/total;
}

void SystemInfoCpuReset(void)
{
  cpuCount = 0;
  cpuNewest = -1;
}

void SystemInfoCpuTick(void)
{
  host_cpu_load_info_data_t load;
  mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
  if (host_statistics(HostPort(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) != KERN_SUCCESS)
  {
    // no reading: the ring keeps what it has
    return;
  }
  int index = (cpuNewest + 1) % CPU_RING_SIZE;
  for (int i=0; i<CPU_STATE_MAX; i++)
  {
    cpuRing[index].ticks[i] = load.cpu_ticks[i];
  }
  CpuEachTicks(&cpuRing[index]);
  cpuRing[index].time = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
  cpuNewest = index;
  if (cpuCount < CPU_RING_SIZE)
  {
    cpuCount++;
  }
}

double SystemInfoCpuBusy(double* span, double* efficiency, double* performance)
{
  return SystemInfoCpuBusyEach(span, efficiency, performance, NULL, 0, NULL);
}

double SystemInfoCpuBusyEach(double* span, double* efficiency, double* performance, double* each, natural_t capacity, natural_t* eachCount)
{
  if (eachCount != NULL)
  {
    *eachCount = 0;
  }
  if (span != NULL)
  {
    *span = 0.0;
  }
  if (efficiency != NULL)
  {
    *efficiency = -1.0;
  }
  if (performance != NULL)
  {
    *performance = -1.0;
  }
  if (cpuCount < 2)
  {
    return -1.0;
  }
  const CpuSample* now = &cpuRing[cpuNewest];
  // half a tick, from the newest two samples: a tick firing a little early must not push the window a whole tick past
  // CPU_WINDOW, as the readings' own threshold allows the same
  const double slack = 0.5 * (now->time - cpuRing[(cpuNewest - 1 + CPU_RING_SIZE) % CPU_RING_SIZE].time);
  // walk back from the newest to the first sample at least CPU_WINDOW older, less that half tick, and on while the
  // counters have not moved since it (the host's can stall for most of a second, then catch up); none that old: the
  // oldest stored. The CPUs' own summed counters when both samples have them, else the host's
  for (int back=1; back<cpuCount; back++)
  {
    const CpuSample* then = &cpuRing[(cpuNewest - back + CPU_RING_SIZE) % CPU_RING_SIZE];
    if (((now->time - then->time) < (CPU_WINDOW - slack)) && (back < (cpuCount - 1)))
    {
      continue;
    }
    bool perCpu = now->perCpu && then->perCpu;
    double busy = perCpu ? CpuTicksBusy(now->cpuTicks, then->cpuTicks) : CpuTicksBusy(now->ticks, then->ticks);
    if (busy < 0.0)
    {
      continue;
    }
    if (span != NULL)
    {
      *span = now->time - then->time;
    }
    if (now->kinds && then->kinds)
    {
      if (efficiency != NULL)
      {
        *efficiency = CpuTicksBusy(now->kindTicks[0], then->kindTicks[0]);
      }
      if (performance != NULL)
      {
        *performance = CpuTicksBusy(now->kindTicks[1], then->kindTicks[1]);
      }
    }
    if ((each != NULL) && (eachCount != NULL) && (now->eachCount > 0) && (now->eachCount == then->eachCount) &&
        (now->eachCount <= capacity))
    {
      for (natural_t c=0; c<now->eachCount; c++)
      {
        each[c] = CpuTicksBusy(now->eachTicks[c], then->eachTicks[c]);
      }
      *eachCount = now->eachCount;
    }
    return busy;
  }
  return -1.0;
}

#pragma mark - Memory

bool SystemInfoMemory(uint64_t* used, uint64_t* total)
{
  uint64_t memsize = 0;
  size_t size = sizeof(memsize);
  if ((sysctlbyname("hw.memsize", &memsize, &size, NULL, 0) != 0) || (memsize == 0))
  {
    return false;
  }

  vm_statistics64_data_t vm;
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  if (host_statistics64(HostPort(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
  {
    return false;
  }
  // app memory (anonymous pages that are not purgeable), wired and compressed
  uint64_t internal = vm.internal_page_count;
  uint64_t purgeable = vm.purgeable_count;
  uint64_t app = (internal > purgeable) ? (internal - purgeable) : 0;
  uint64_t pages = app + vm.wire_count + vm.compressor_page_count;

  *used = pages * (uint64_t)vm_kernel_page_size;
  *total = memsize;
  return true;
}

bool SystemInfoSwap(uint64_t* used)
{
  struct xsw_usage swap;
  size_t size = sizeof(swap);
  if ((sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) != 0) || (size != sizeof(swap)))
  {
    return false;
  }
  *used = swap.xsu_used;
  return true;
}

#pragma mark - Uptime

long SystemInfoUptimeSeconds(void)
{
  struct timeval boot = {0, 0};
  size_t size = sizeof(boot);
  int mib[2] = {CTL_KERN, KERN_BOOTTIME};
  if ((sysctl(mib, 2, &boot, &size, NULL, 0) != 0) || (size != sizeof(boot)) || (boot.tv_sec <= 0))
  {
    return -1;
  }
  long seconds = (long)(time(NULL) - boot.tv_sec);
  if (seconds < 0)
  {
    return -1;
  }
  if (seconds > 60)
  {
    seconds += 30;
  }
  return seconds;
}

#pragma mark - GPU and Neural Engine

#define IOKIT_RETRY     (60.0)  // s between lookups after one that found nothing
#define GPU_MAX         (8)     // IOAccelerator services kept; one per GPU

// seconds on mach_absolute_time's clock, for the lookups' retry
static double IOKitNow(void)
{
  static mach_timebase_info_data_t base = {0, 0};
  if (base.denom == 0)
  {
    mach_timebase_info(&base);
  }
  return ((double)mach_absolute_time() * base.numer / base.denom) / 1e9;
}

// whether a lookup may run now: the first time, and then at most once every IOKIT_RETRY s; *last is when the last ran
static bool IOKitMayLookUp(double* last)
{
  const double now = IOKitNow();
  if ((*last >= 0.0) && ((now - *last) < IOKIT_RETRY))
  {
    return false;
  }
  *last = now;
  return true;
}

// "Device Utilization %" of service, or -1 when it does not carry it
static long long GpuDevicePercent(io_service_t service)
{
  CFTypeRef stats = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
  if (stats == NULL)
  {
    return -1;
  }
  long long percent = -1;
  if (CFGetTypeID(stats) == CFDictionaryGetTypeID())
  {
    CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)stats, CFSTR("Device Utilization %"));
    if ((value == NULL) || (CFGetTypeID(value) != CFNumberGetTypeID()) || !CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &percent))
    {
      percent = -1;
    }
  }
  CFRelease(stats);
  return percent;
}

static io_service_t gpuServices[GPU_MAX];
static int gpuCount = 0;
static double gpuLookedUp = -1.0;

double SystemInfoGpuBusy(void)
{
  if ((gpuCount == 0) && IOKitMayLookUp(&gpuLookedUp))
  {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS)
    {
      for (io_service_t service; (service = IOIteratorNext(it)) != IO_OBJECT_NULL;)
      {
        if ((gpuCount < GPU_MAX) && (GpuDevicePercent(service) >= 0))
        {
          gpuServices[gpuCount++] = service;
        }
        else
        {
          IOObjectRelease(service);
        }
      }
      IOObjectRelease(it);
    }
  }
  long long best = -1;
  for (int i=0; i<gpuCount; i++)
  {
    const long long percent = GpuDevicePercent(gpuServices[i]);
    if (percent > best)
    {
      best = percent;
    }
  }
  if (best < 0)
  {
    return -1.0;
  }
  return (best > 100) ? 1.0 : ((double)best / 100.0);
}

static io_service_t neuralEngine = IO_OBJECT_NULL;
static double neuralEngineLookedUp = -1.0;

int SystemInfoNeuralEngine(void)
{
  if ((neuralEngine == IO_OBJECT_NULL) && IOKitMayLookUp(&neuralEngineLookedUp))
  {
    neuralEngine = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"));
  }
  if (neuralEngine == IO_OBJECT_NULL)
  {
    return -1;
  }
  CFTypeRef power = IORegistryEntryCreateCFProperty(neuralEngine, CFSTR("IOPowerManagement"), kCFAllocatorDefault, 0);
  if (power == NULL)
  {
    return -1;
  }
  int state = -1;
  if (CFGetTypeID(power) == CFDictionaryGetTypeID())
  {
    CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)power, CFSTR("CurrentPowerState"));
    if ((value == NULL) || (CFGetTypeID(value) != CFNumberGetTypeID()) || !CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &state))
    {
      state = -1;
    }
  }
  CFRelease(power);
  return (state < 0) ? -1 : ((state > 0) ? 1 : 0);
}

#pragma mark - Battery

// one number of a power source's description, or -1 when the key is missing or not a number
static int BatteryNumber(CFDictionaryRef description, CFStringRef key)
{
  CFTypeRef value = CFDictionaryGetValue(description, key);
  int number = -1;
  if ((value == NULL) || (CFGetTypeID(value) != CFNumberGetTypeID()) || !CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number))
  {
    return -1;
  }
  return number;
}

static bool BatteryFlag(CFDictionaryRef description, CFStringRef key)
{
  CFTypeRef value = CFDictionaryGetValue(description, key);
  return (value != NULL) && (CFGetTypeID(value) == CFBooleanGetTypeID()) && CFBooleanGetValue((CFBooleanRef)value);
}

static bool BatteryString(CFDictionaryRef description, CFStringRef key, const char* expected)
{
  CFTypeRef value = CFDictionaryGetValue(description, key);
  if ((value == NULL) || (CFGetTypeID(value) != CFStringGetTypeID()))
  {
    return false;
  }
  CFStringRef wanted = CFStringCreateWithCString(kCFAllocatorDefault, expected, kCFStringEncodingUTF8);
  if (wanted == NULL)
  {
    return false;
  }
  bool same = (CFStringCompare((CFStringRef)value, wanted, 0) == kCFCompareEqualTo);
  CFRelease(wanted);
  return same;
}

bool SystemInfoBatteryFromDescription(CFDictionaryRef description, SystemInfoBattery* battery)
{
  if ((description == NULL) || (battery == NULL))
  {
    return false;
  }
  if (!BatteryString(description, CFSTR(kIOPSTypeKey), kIOPSInternalBatteryType) || !BatteryFlag(description, CFSTR(kIOPSIsPresentKey)))
  {
    return false;
  }
  int current = BatteryNumber(description, CFSTR(kIOPSCurrentCapacityKey));
  int max = BatteryNumber(description, CFSTR(kIOPSMaxCapacityKey));
  if ((current < 0) || (max <= 0))
  {
    return false;
  }
  double level = (double)current / (double)max;
  battery->level = (level > 1.0) ? 1.0 : level;
  battery->charging = BatteryFlag(description, CFSTR(kIOPSIsChargingKey));
  battery->charged = BatteryFlag(description, CFSTR(kIOPSIsChargedKey));
  battery->onAC = BatteryString(description, CFSTR(kIOPSPowerSourceStateKey), kIOPSACPowerValue);
  int toEmpty = BatteryNumber(description, CFSTR(kIOPSTimeToEmptyKey));
  int toFull = BatteryNumber(description, CFSTR(kIOPSTimeToFullChargeKey));
  battery->minutesToEmpty = (toEmpty > 0) ? toEmpty : -1;
  battery->minutesToFull = (toFull > 0) ? toFull : -1;
  return true;
}

bool SystemInfoBatteryRead(SystemInfoBattery* battery)
{
  CFTypeRef info = IOPSCopyPowerSourcesInfo();
  if (info == NULL)
  {
    return false;
  }
  bool found = false;
  CFArrayRef list = IOPSCopyPowerSourcesList(info);
  if (list != NULL)
  {
    for (CFIndex i=0; (i<CFArrayGetCount(list)) && !found; i++)
    {
      // the description is not ours to release (the Get rule)
      CFDictionaryRef description = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
      found = SystemInfoBatteryFromDescription(description, battery);
    }
    CFRelease(list);
  }
  CFRelease(info);
  return found;
}

void SystemInfoBatteryStateText(const SystemInfoBattery* battery, char* text, size_t size)
{
  if ((text == NULL) || (size == 0))
  {
    return;
  }
  if (battery == NULL)
  {
    text[0] = 0;
  }
  else if (battery->charged)
  {
    snprintf(text, size, "charged");
  }
  else if (battery->charging)
  {
    snprintf(text, size, "charging");
  }
  else if (battery->onAC)
  {
    snprintf(text, size, "not charging");
  }
  else if (battery->minutesToEmpty > 0)
  {
    snprintf(text, size, "on battery, %d:%02d left", battery->minutesToEmpty / 60, battery->minutesToEmpty % 60);
  }
  else
  {
    snprintf(text, size, "on battery");
  }
}

#pragma mark - Wi-Fi

double SystemInfoWifiFill(int rssi)
{
  if (rssi >= 0)
  {
    return -1;
  }
  double fill = (rssi + 90) / 60.0;
  return (fill < 0.0) ? 0.0 : ((fill > 1.0) ? 1.0 : fill);
}

// CoreWLAN's CWSecurity values (CoreWLANTypes.h); the unknown value, NSIntegerMax, and any other is NULL
const char* SystemInfoWifiSecurityName(long security)
{
  switch (security)
  {
    case 0:  return "None";
    case 1:  return "WEP";
    case 2:  return "WPA Personal";
    case 3:  return "WPA/WPA2 Personal";
    case 4:  return "WPA2 Personal";
    case 5:  return "Personal";
    case 6:  return "Dynamic WEP";
    case 7:  return "WPA Enterprise";
    case 8:  return "WPA/WPA2 Enterprise";
    case 9:  return "WPA2 Enterprise";
    case 10: return "Enterprise";
    case 11: return "WPA3 Personal";
    case 12: return "WPA3 Enterprise";
    case 13: return "WPA2/WPA3 Personal";
    case 14: return "OWE";
    case 15: return "OWE Transition";
    default: return NULL;
  }
}

// CoreWLAN's CWPHYMode values; 0, none, and any other is NULL
const char* SystemInfoWifiPhyName(long phy)
{
  switch (phy)
  {
    case 1:  return "802.11a";
    case 2:  return "802.11b";
    case 3:  return "802.11g";
    case 4:  return "802.11n";
    case 5:  return "802.11ac";
    case 6:  return "802.11ax";
    case 7:  return "802.11be";
    default: return NULL;
  }
}

void SystemInfoWifiChannelText(long number, long band, long width, char* text, size_t size)
{
  if ((text == NULL) || (size == 0))
  {
    return;
  }
  static const char* const bands[] = {NULL, "2.4 GHz", "5 GHz", "6 GHz"};
  static const char* const widths[] = {NULL, "20 MHz", "40 MHz", "80 MHz", "160 MHz"};
  const char* bandName = ((band > 0) && (band < 4)) ? bands[band] : NULL;
  const char* widthName = ((width > 0) && (width < 5)) ? widths[width] : NULL;
  if ((bandName != NULL) && (widthName != NULL))
  {
    snprintf(text, size, "%ld (%s, %s)", number, bandName, widthName);
  }
  else if ((bandName != NULL) || (widthName != NULL))
  {
    snprintf(text, size, "%ld (%s)", number, (bandName != NULL) ? bandName : widthName);
  }
  else
  {
    snprintf(text, size, "%ld", number);
  }
}

bool SystemInfoInterfaceAddresses(const char* ifname, char* ip, size_t ipSize, char* mac, size_t macSize)
{
  if (ifname == NULL)
  {
    return false;
  }
  struct ifaddrs* list = NULL;
  if (getifaddrs(&list) != 0)
  {
    return false;
  }
  bool haveIp = false;
  if ((ip != NULL) && (ipSize > 0))
  {
    ip[0] = 0;
  }
  if ((mac != NULL) && (macSize > 0))
  {
    mac[0] = 0;
  }
  for (struct ifaddrs* a=list; a!=NULL; a=a->ifa_next)
  {
    if ((a->ifa_name == NULL) || (a->ifa_addr == NULL) || (strcmp(a->ifa_name, ifname) != 0))
    {
      continue;
    }
    if ((a->ifa_addr->sa_family == AF_INET) && !haveIp)
    {
      const struct sockaddr_in* in = (const struct sockaddr_in*)(const void*)a->ifa_addr;
      if ((ip == NULL) || (ipSize == 0))
      {
        haveIp = true;
      }
      else if (inet_ntop(AF_INET, &in->sin_addr, ip, (socklen_t)ipSize) != NULL)
      {
        haveIp = true;
      }
    }
    else if ((a->ifa_addr->sa_family == AF_LINK) && (mac != NULL) && (macSize > 0))
    {
      const struct sockaddr_dl* link = (const struct sockaddr_dl*)(const void*)a->ifa_addr;
      if (link->sdl_alen == 6)
      {
        const unsigned char* b = (const unsigned char*)LLADDR(link);
        snprintf(mac, macSize, "%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]);
      }
    }
  }
  freeifaddrs(list);
  return haveIp;
}

// a routing message's socket addresses are packed after its header, each padded to 4 bytes
#define ROUTE_ALIGN(len)  (((len) > 0) ? (1 + (((len) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))

bool SystemInfoDefaultRouter(const char* ifname, char* text, size_t size)
{
  if ((ifname == NULL) || (text == NULL) || (size == 0))
  {
    return false;
  }
  unsigned index = if_nametoindex(ifname);
  if (index == 0)
  {
    return false;
  }
  int mib[6] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY};
  size_t length = 0;
  if ((sysctl(mib, 6, NULL, &length, NULL, 0) != 0) || (length == 0))
  {
    return false;
  }
  char* table = (char*)malloc(length);
  if (table == NULL)
  {
    return false;
  }
  bool found = false;
  if (sysctl(mib, 6, table, &length, NULL, 0) == 0)
  {
    for (char* p=table; !found && ((size_t)(p - table) + sizeof(struct rt_msghdr) <= length); )
    {
      const struct rt_msghdr* message = (const struct rt_msghdr*)(const void*)p;
      if (message->rtm_msglen == 0)
      {
        break;
      }
      const char* end = p + message->rtm_msglen;
      if ((message->rtm_index == index) && ((message->rtm_addrs & (RTA_DST | RTA_GATEWAY)) == (RTA_DST | RTA_GATEWAY)))
      {
        // RTA_DST is the first address, RTA_GATEWAY the second
        const char* address = p + sizeof(struct rt_msghdr);
        const struct sockaddr* destination = (const struct sockaddr*)(const void*)address;
        if ((address + sizeof(struct sockaddr) <= end) && (destination->sa_family == AF_INET))
        {
          const struct sockaddr_in* dst = (const struct sockaddr_in*)(const void*)destination;
          const char* next = address + ROUTE_ALIGN(destination->sa_len);
          if ((dst->sin_addr.s_addr == 0) && (next + sizeof(struct sockaddr_in) <= end))
          {
            const struct sockaddr_in* gateway = (const struct sockaddr_in*)(const void*)next;
            if ((gateway->sin_family == AF_INET) && (inet_ntop(AF_INET, &gateway->sin_addr, text, (socklen_t)size) != NULL))
            {
              found = true;
            }
          }
        }
      }
      p = (char*)end;
    }
  }
  free(table);
  return found;
}
