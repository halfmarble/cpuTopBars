// The MIT License (MIT)

// Copyright 2022 HalfMarble LLC

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

#include "CpuSampler.h"

#include <stdlib.h>
#include <math.h>
#include <sys/sysctl.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

static host_basic_info_t _CpuSamplerGetCounts(void)
{
  static boolean_t initialized = FALSE;
  static host_basic_info_data_t basic_info;
  mach_msg_type_number_t msg_count = HOST_BASIC_INFO_COUNT;
  if (!initialized)
  {
    initialized = TRUE;
    
    kern_return_t error = host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&basic_info, &msg_count);
    if (error != KERN_SUCCESS)
    {
      mach_error("host_info error:", error);
      memset(&basic_info, 0x0, sizeof(host_basic_info_data_t));
    }
  }
  return &basic_info;
}

// Copies the tick counters of at most capacity CPUs into ticks (when not NULL), and returns the number of CPUs the
// kernel reported, 0 when it could not be read (ticks are then left as they were). Failures are logged once: this
// runs on every frame.
static natural_t _CpuSamplerGet(mach_port_t port, Ticks* ticks, natural_t capacity)
{
  natural_t cpu_count = 0;
  processor_cpu_load_info_t cpu_load = NULL;
  mach_msg_type_number_t msg_count = PROCESSOR_CPU_LOAD_INFO_COUNT;
  kern_return_t error = host_processor_info(port, PROCESSOR_CPU_LOAD_INFO, &cpu_count, (processor_info_array_t *)&cpu_load, &msg_count);
  if (error != KERN_SUCCESS)
  {
    static boolean_t logged = FALSE;
    if (!logged)
    {
      logged = TRUE;
      mach_error("host_processor_info error:", error);
    }
    return 0;
  }
  if (ticks != NULL)
  {
    natural_t count = (cpu_count < capacity) ? cpu_count : capacity;
    for (natural_t i=0; i<count; i++)
    {
      ticks[i].systemTicks = cpu_load[i].cpu_ticks[CPU_STATE_SYSTEM];
      ticks[i].userTicks   = cpu_load[i].cpu_ticks[CPU_STATE_USER];
      ticks[i].niceTicks   = cpu_load[i].cpu_ticks[CPU_STATE_NICE];
      ticks[i].idleTicks   = cpu_load[i].cpu_ticks[CPU_STATE_IDLE];
    }
  }
  // msg_count counts integers; vm_deallocate takes bytes
  error = vm_deallocate(mach_task_self(), (vm_address_t)cpu_load, (vm_size_t)msg_count * sizeof(integer_t));
  if (error != KERN_SUCCESS)
  {
    static boolean_t logged = FALSE;
    if (!logged)
    {
      logged = TRUE;
      mach_error("vm_deallocate error:", error);
    }
  }

  return cpu_count;
}

// at least 1: a failed host_info leaves the counts 0
natural_t CpuSamplerGetCount(int granularity)
{
  host_basic_info_t info = _CpuSamplerGetCounts();
  natural_t count = 1;
  switch(granularity)
  {
    case 1: count = info->physical_cpu; break;
    case 2: count = info->logical_cpu; break;
    default: count = 1; break;
  }
  return (count > 0) ? count : 1;
}

void CpuSamplerInit(CpuSummaryInfo* cpu_info)
{
  memset(cpu_info, 0x00, sizeof(CpuSummaryInfo));
  
  cpu_info->port = mach_host_self();
  cpu_info->countLogical = _CpuSamplerGet(cpu_info->port, NULL, 0);
  host_basic_info_t info = _CpuSamplerGetCounts();
  cpu_info->countCores = info->physical_cpu;

  size_t size = cpu_info->countLogical*sizeof(Ticks);
  cpu_info->last = (Ticks*)malloc(size);
  memset(cpu_info->last, 0x00, size);
  cpu_info->now = (Ticks*)malloc(size);
  memset(cpu_info->now, 0x00, size);
  
  _CpuSamplerGet(cpu_info->port, cpu_info->last, cpu_info->countLogical);
  CpuSamplerUpdate(cpu_info);
}

void CpuSamplerUpdate(CpuSummaryInfo* cpu_info)
{
  if (_CpuSamplerGet(cpu_info->port, cpu_info->now, cpu_info->countLogical) == 0)
  {
    // no reading: the previous loads stay
    return;
  }
  
  for (natural_t i=0; i<cpu_info->countLogical; i++)
  {
    uint32_t systemTicks = cpu_info->now[i].systemTicks - cpu_info->last[i].systemTicks;
    uint32_t userTicks   = cpu_info->now[i].userTicks   - cpu_info->last[i].userTicks;
    uint32_t niceTicks   = cpu_info->now[i].niceTicks   - cpu_info->last[i].niceTicks;
    uint32_t idleTicks   = cpu_info->now[i].idleTicks   - cpu_info->last[i].idleTicks;
    {
      double used = (double)systemTicks + (double)userTicks + (double)niceTicks;
      double total = used + (double)idleTicks;
      if (total == 0.0)
      {
        total = 1.0;
      }
      cpu_info->now[i].load = used/total;
    }
    cpu_info->last[i] = cpu_info->now[i];
  }
}

int CpuSamplerGetKinds(natural_t count, char* kinds)
{
  memset(kinds, 0, count);
  io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus");
  if (cpus == MACH_PORT_NULL)
  {
    return 0;
  }
  io_iterator_t iterator = MACH_PORT_NULL;
  if (IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) != KERN_SUCCESS)
  {
    IOObjectRelease(cpus);
    return 0;
  }
  natural_t found = 0;
  io_registry_entry_t cpu;
  while ((cpu = IOIteratorNext(iterator)) != MACH_PORT_NULL)
  {
    CFTypeRef type = IORegistryEntryCreateCFProperty(cpu, CFSTR("cluster-type"), kCFAllocatorDefault, 0);
    CFTypeRef ident = IORegistryEntryCreateCFProperty(cpu, CFSTR("logical-cpu-id"), kCFAllocatorDefault, 0);
    char kind = 0;
    if ((type != NULL) && (CFGetTypeID(type) == CFDataGetTypeID()) && (CFDataGetLength((CFDataRef)type) >= 1))
    {
      kind = (char)CFDataGetBytePtr((CFDataRef)type)[0];
    }
    long long index = -1;
    if ((ident != NULL) && (CFGetTypeID(ident) == CFNumberGetTypeID()))
    {
      CFNumberGetValue((CFNumberRef)ident, kCFNumberLongLongType, &index);
    }
    if (((kind == 'P') || (kind == 'E')) && (index >= 0) && (index < (long long)count) && (kinds[index] == 0))
    {
      kinds[index] = kind;
      found++;
    }
    if (type != NULL)
    {
      CFRelease(type);
    }
    if (ident != NULL)
    {
      CFRelease(ident);
    }
    IOObjectRelease(cpu);
  }
  IOObjectRelease(iterator);
  IOObjectRelease(cpus);
  return (found == count) ? 1 : 0;
}

void CpuSamplerSineDemoInit(CpuSummaryInfo* cpu_info)
{
  cpu_info->port = mach_host_self();
  cpu_info->countLogical = _CpuSamplerGet(cpu_info->port, NULL, 0);
  host_basic_info_t info = _CpuSamplerGetCounts();
  cpu_info->countCores = info->physical_cpu;

  size_t size = cpu_info->countLogical*sizeof(Ticks);
  cpu_info->now = (Ticks*)malloc(size);
  memset(cpu_info->now, 0x00, size);
  
  CpuSamplerSineDemoUpdate(cpu_info, 1.0);
}

void CpuSamplerSineDemoUpdate(CpuSummaryInfo* cpu_info, float speed)
{
  static double counter = 0.0;
  for (natural_t i=0; i<cpu_info->countLogical; i++)
  {
    cpu_info->now[i].load = (sin(3.5*counter)/2.0) + 0.5;
    counter += (0.025*speed);
  }
}

void CpuSamplerFlatDemoInit(CpuSummaryInfo* cpu_info)
{
  cpu_info->port = mach_host_self();
  cpu_info->countLogical = _CpuSamplerGet(cpu_info->port, NULL, 0);
  host_basic_info_t info = _CpuSamplerGetCounts();
  cpu_info->countCores = info->physical_cpu;

  size_t size = cpu_info->countLogical*sizeof(Ticks);
  cpu_info->now = (Ticks*)malloc(size);
  memset(cpu_info->now, 0x00, size);
  
  CpuSamplerFlatDemoUpdate(cpu_info, 1.0);
}

void CpuSamplerFlatDemoUpdate(CpuSummaryInfo* cpu_info, float speed)
{
  static double load = 0.0;
  for (natural_t i=0; i<cpu_info->countLogical; i++)
  {
    cpu_info->now[i].load = load;
  }
  load += (0.04*speed);
  if (load > 1.0)
  {
    load = 0.0;
  }
}
