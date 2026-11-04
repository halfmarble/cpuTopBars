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

#include "IOReportReader.h"
#include "Sandbox.h"

#include <stddef.h>

double IOReportAneBusyFromResidencies(const int64_t* residencies, int count)
{
  if ((residencies == NULL) || (count < 1))
  {
    return -1.0;
  }
  double total = 0.0;
  double loaded = 0.0;
  for (int i = 0; i < count; i++)
  {
    total += (double)residencies[i];
    if (i > 0)
    {
      loaded += (double)residencies[i];
    }
  }
  if (total <= 0.0)
  {
    return 0.0;
  }
  return 100.0 * loaded / total;
}

double IOReportGpuWattsFromEnergy(double nanojoules, double seconds)
{
  if ((seconds <= 0.0) || (nanojoules < 0.0))
  {
    return -1.0;
  }
  return nanojoules / 1e9 / seconds;
}

#if CPUTOPBARS_SANDBOXED

void IOReportSample(void)
{
}

double IOReportAneBusy(void)
{
  return -1.0;
}

double IOReportGpuWatts(void)
{
  return -1.0;
}

bool IOReportUnreadable(void)
{
  return false;
}

#else

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>

#define IOREPORT_RETRY  (60.0)  // s between setups after one that failed
#define IOREPORT_GAP    (10.0)  // s between requests after which the window starts again

typedef struct IOReportSubscription* IOReportSubscriptionRef;

static CFMutableDictionaryRef (*pCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
static void (*pMergeChannels)(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
static IOReportSubscriptionRef (*pCreateSubscription)(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
static CFDictionaryRef (*pCreateSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
static CFDictionaryRef (*pCreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
static CFStringRef (*pChannelGetGroup)(CFDictionaryRef);
static CFStringRef (*pChannelGetSubGroup)(CFDictionaryRef);
static CFStringRef (*pChannelGetChannelName)(CFDictionaryRef);
static CFStringRef (*pChannelGetUnitLabel)(CFDictionaryRef);
static int64_t (*pSimpleGetIntegerValue)(CFDictionaryRef, int32_t);
static int32_t (*pStateGetCount)(CFDictionaryRef);
static int64_t (*pStateGetResidency)(CFDictionaryRef, int32_t);

// the sampling queue's: set up and used only by IOReportTake, and the function pointers once IOReportLoad has set them
static IOReportSubscriptionRef subscription = NULL;
static CFMutableDictionaryRef subscribed = NULL;
static CFDictionaryRef previous = NULL;
static double previousAt = 0.0;
static double setupAt = -1.0;

// the main thread's
static dispatch_queue_t queue = NULL;
static bool queued = false;           // a sample is queued or running, and has not published yet
static double requestedAt = -1.0;     // the last request queued
static double aneBusy = -1.0;
static double gpuWatts = -1.0;
static bool unreadable = false;

// one sample's readings, from the sampling queue to the main thread
struct IOReportReadings
{
  double ane;
  double gpu;
  bool failed;  // the set-up or the sample failed
} typedef IOReportReadings_t;

// seconds on mach_absolute_time's clock
static double IOReportNow(void)
{
  static mach_timebase_info_data_t base = {0, 0};
  if (base.denom == 0)
  {
    mach_timebase_info(&base);
  }
  return ((double)mach_absolute_time() * base.numer / base.denom) / 1e9;
}

// the C string of s into buf, or "" with leading spaces dropped
static void IOReportString(CFStringRef s, char* buf, size_t size)
{
  buf[0] = 0;
  if ((s != NULL) && CFStringGetCString(s, buf, (CFIndex)size, kCFStringEncodingUTF8))
  {
    size_t skip = 0;
    while (buf[skip] == ' ')
    {
      skip++;
    }
    if (skip > 0)
    {
      memmove(buf, buf + skip, strlen(buf + skip) + 1);
    }
  }
}

static bool IOReportLoad(void)
{
  void* handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
  if (handle == NULL)
  {
    return false;
  }
  pCopyChannelsInGroup = dlsym(handle, "IOReportCopyChannelsInGroup");
  pMergeChannels = dlsym(handle, "IOReportMergeChannels");
  pCreateSubscription = dlsym(handle, "IOReportCreateSubscription");
  pCreateSamples = dlsym(handle, "IOReportCreateSamples");
  pCreateSamplesDelta = dlsym(handle, "IOReportCreateSamplesDelta");
  pChannelGetGroup = dlsym(handle, "IOReportChannelGetGroup");
  pChannelGetSubGroup = dlsym(handle, "IOReportChannelGetSubGroup");
  pChannelGetChannelName = dlsym(handle, "IOReportChannelGetChannelName");
  pChannelGetUnitLabel = dlsym(handle, "IOReportChannelGetUnitLabel");
  pSimpleGetIntegerValue = dlsym(handle, "IOReportSimpleGetIntegerValue");
  pStateGetCount = dlsym(handle, "IOReportStateGetCount");
  pStateGetResidency = dlsym(handle, "IOReportStateGetResidency");
  return (pCopyChannelsInGroup != NULL) && (pMergeChannels != NULL) && (pCreateSubscription != NULL) &&
         (pCreateSamples != NULL) && (pCreateSamplesDelta != NULL) && (pChannelGetGroup != NULL) &&
         (pChannelGetSubGroup != NULL) && (pChannelGetChannelName != NULL) && (pChannelGetUnitLabel != NULL) &&
         (pSimpleGetIntegerValue != NULL) && (pStateGetCount != NULL) && (pStateGetResidency != NULL);
}

// whether channel is one of the two read: "PMP | AF BW | ANE0 RD+WR" or "Energy Model | GPU Energy"
static bool IOReportWanted(CFDictionaryRef channel)
{
  char group[64], subgroup[64], name[64];
  IOReportString(pChannelGetGroup(channel), group, sizeof(group));
  IOReportString(pChannelGetSubGroup(channel), subgroup, sizeof(subgroup));
  IOReportString(pChannelGetChannelName(channel), name, sizeof(name));
  return ((strcmp(group, "PMP") == 0) && (strcmp(subgroup, "AF BW") == 0) && (strcmp(name, "ANE0 RD+WR") == 0)) ||
         ((strcmp(group, "Energy Model") == 0) && (strcmp(name, "GPU Energy") == 0));
}

// the request narrowed to the two channels read (a sample of all 192 costs about twice as much); NULL when it lacks one
static CFMutableDictionaryRef IOReportNarrow(CFMutableDictionaryRef request)
{
  CFArrayRef all = CFDictionaryGetValue(request, CFSTR("IOReportChannels"));
  if ((all == NULL) || (CFGetTypeID(all) != CFArrayGetTypeID()))
  {
    return NULL;
  }
  CFMutableArrayRef two = CFArrayCreateMutable(kCFAllocatorDefault, 2, &kCFTypeArrayCallBacks);
  const CFIndex count = CFArrayGetCount(all);
  for (CFIndex i = 0; i < count; i++)
  {
    CFDictionaryRef channel = CFArrayGetValueAtIndex(all, i);
    if (IOReportWanted(channel))
    {
      CFArrayAppendValue(two, channel);
    }
  }
  CFMutableDictionaryRef narrow = NULL;
  if (CFArrayGetCount(two) == 2)
  {
    narrow = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, request);
    CFDictionarySetValue(narrow, CFSTR("IOReportChannels"), two);
  }
  CFRelease(two);
  return narrow;
}

// subscribes once to "PMP" / "AF BW" and "Energy Model", narrowed to the two channels, and takes the first sample;
// false leaves nothing held
static bool IOReportSetUp(void)
{
  if (!IOReportLoad())
  {
    return false;
  }
  CFMutableDictionaryRef pmp = pCopyChannelsInGroup(CFSTR("PMP"), CFSTR("AF BW"), 0, 0, 0);
  CFMutableDictionaryRef energy = pCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
  if ((pmp == NULL) || (energy == NULL))
  {
    if (pmp != NULL)
    {
      CFRelease(pmp);
    }
    if (energy != NULL)
    {
      CFRelease(energy);
    }
    return false;
  }
  pMergeChannels(pmp, energy, NULL);
  CFRelease(energy);
  CFMutableDictionaryRef narrow = IOReportNarrow(pmp);
  CFRelease(pmp);
  if (narrow == NULL)
  {
    return false;
  }
  pmp = narrow;
  CFMutableDictionaryRef subbed = NULL;
  IOReportSubscriptionRef sub = pCreateSubscription(NULL, pmp, &subbed, 0, NULL);
  CFRelease(pmp);
  if ((sub == NULL) || (subbed == NULL))
  {
    if (subbed != NULL)
    {
      CFRelease(subbed);
    }
    if (sub != NULL)
    {
      CFRelease(sub);
    }
    return false;
  }
  CFDictionaryRef first = pCreateSamples(sub, subbed, NULL);
  if (first == NULL)
  {
    CFRelease(subbed);
    CFRelease(sub);
    return false;
  }
  subscription = sub;
  subscribed = subbed;
  previous = first;
  previousAt = IOReportNow();
  return true;
}

// reads the delta's two channels into *ane and *gpu (-1 when a channel is missing)
static void IOReportRead(CFDictionaryRef delta, double seconds, double* ane, double* gpu)
{
  *ane = -1.0;
  *gpu = -1.0;
  CFArrayRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
  if ((channels == NULL) || (CFGetTypeID(channels) != CFArrayGetTypeID()))
  {
    return;
  }
  const CFIndex count = CFArrayGetCount(channels);
  for (CFIndex i = 0; i < count; i++)
  {
    CFDictionaryRef channel = CFArrayGetValueAtIndex(channels, i);
    char group[64], subgroup[64], name[64];
    IOReportString(pChannelGetGroup(channel), group, sizeof(group));
    IOReportString(pChannelGetSubGroup(channel), subgroup, sizeof(subgroup));
    IOReportString(pChannelGetChannelName(channel), name, sizeof(name));
    if ((strcmp(group, "PMP") == 0) && (strcmp(subgroup, "AF BW") == 0) && (strcmp(name, "ANE0 RD+WR") == 0))
    {
      const int32_t states = pStateGetCount(channel);
      if ((states > 0) && (states <= 256))
      {
        int64_t residencies[256];
        for (int32_t s = 0; s < states; s++)
        {
          residencies[s] = pStateGetResidency(channel, s);
        }
        *ane = IOReportAneBusyFromResidencies(residencies, (int)states);
      }
    }
    else if ((strcmp(group, "Energy Model") == 0) && (strcmp(name, "GPU Energy") == 0))
    {
      char unit[32];
      IOReportString(pChannelGetUnitLabel(channel), unit, sizeof(unit));
      double nanojoules = (double)pSimpleGetIntegerValue(channel, 0);
      if (strcmp(unit, "nJ") == 0)
      {
      }
      else if (strcmp(unit, "uJ") == 0)
      {
        nanojoules *= 1e3;
      }
      else if (strcmp(unit, "mJ") == 0)
      {
        nanojoules *= 1e6;
      }
      else if (strcmp(unit, "J") == 0)
      {
        nanojoules *= 1e9;
      }
      else
      {
        continue;
      }
      *gpu = IOReportGpuWattsFromEnergy(nanojoules, seconds);
    }
  }
}

// on the sampling queue: the readings since the previous sample into r, -1 each while none can be read
static void IOReportTake(IOReportReadings_t* r)
{
  r->ane = -1.0;
  r->gpu = -1.0;
  r->failed = false;
  if (subscription == NULL)
  {
    if ((setupAt >= 0.0) && ((IOReportNow() - setupAt) < IOREPORT_RETRY))
    {
      r->failed = true;
      return;
    }
    setupAt = IOReportNow();
    r->failed = !IOReportSetUp();
    return;
  }
  CFDictionaryRef current = pCreateSamples(subscription, subscribed, NULL);
  const double now = IOReportNow();
  if (current == NULL)
  {
    r->failed = true;
    return;
  }
  // after a pause the window starts again: its readings would average the pause in
  if ((now - previousAt) <= IOREPORT_GAP)
  {
    CFDictionaryRef delta = pCreateSamplesDelta(previous, current, NULL);
    if (delta != NULL)
    {
      IOReportRead(delta, now - previousAt, &r->ane, &r->gpu);
      CFRelease(delta);
    }
    r->failed = (r->ane < 0.0) || (r->gpu < 0.0);
  }
  CFRelease(previous);
  previous = current;
  previousAt = now;
}

// on the main thread: the readings of the sample just taken
static void IOReportPublish(void* context)
{
  IOReportReadings_t* r = (IOReportReadings_t*)context;
  aneBusy = r->ane;
  gpuWatts = r->gpu;
  if (r->failed)
  {
    unreadable = true;
  }
  else if ((r->ane >= 0.0) && (r->gpu >= 0.0))
  {
    unreadable = false;
  }
  free(r);
  queued = false;
}

static void IOReportSampleOnQueue(void* context)
{
  IOReportTake((IOReportReadings_t*)context);
  dispatch_async_f(dispatch_get_main_queue(), context, IOReportPublish);
}

void IOReportSample(void)
{
  if (queued)
  {
    return;
  }
  const double now = IOReportNow();
  if ((requestedAt >= 0.0) && ((now - requestedAt) > IOREPORT_GAP))
  {
    aneBusy = -1.0;
    gpuWatts = -1.0;
  }
  if (queue == NULL)
  {
    queue = dispatch_queue_create("cputopbars.ioreport", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  }
  IOReportReadings_t* r = (IOReportReadings_t*)malloc(sizeof(IOReportReadings_t));
  if ((queue == NULL) || (r == NULL))
  {
    free(r);
    return;
  }
  queued = true;
  requestedAt = now;
  dispatch_async_f(queue, r, IOReportSampleOnQueue);
}

double IOReportAneBusy(void)
{
  return aneBusy;
}

double IOReportGpuWatts(void)
{
  return gpuWatts;
}

bool IOReportUnreadable(void)
{
  return unreadable;
}

#endif
