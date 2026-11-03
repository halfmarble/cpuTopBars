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

#ifndef SystemInfo_h
#define SystemInfo_h

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_types.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

// The readings of the panel beside the status menu, all read on this Mac. Main thread only, as the other modules.

// Overall CPU: SystemInfoCpuTick stores the system-wide ticks on every graph tick, every CPU's summed and the host's;
// SystemInfoCpuBusy gives the busy share (0..1), from the CPUs' summed ticks when both samples have them, else from
// the host's, between the newest stored sample and the newest one at least 1 s older, less half a tick (an older one
// where the counters had not moved since), or -1 with fewer than two samples or no ticks in them; *span,
// when span is not NULL, gets the window's length in seconds (0 with -1). SystemInfoCpuReset forgets the samples
// (after a pause, so that a window never spans one).
// By kind: once SystemInfoCpuSetKinds has each logical CPU's kind, 'E' or 'P' (CpuSamplerGetKinds), every tick also
// stores each kind's ticks, summed over its CPUs, and *efficiency and *performance, when not NULL, get each kind's busy
// share over the same window, or -1 when it cannot be given (no kinds set, a sample without them, no CPU of that
// kind, no ticks in it). SystemInfoCpuSetKinds copies the kinds; NULL forgets them.
// Each CPU: every tick also stores each logical CPU's own ticks (up to 64 CPUs), and SystemInfoCpuBusyEach gives what
// SystemInfoCpuBusy gives and, in the caller's each (capacity entries), each CPU's busy share over the same window, in
// host_processor_info's order (CpuSampler's), -1 for a CPU with no ticks in it; *eachCount gets how many were written,
// 0 when none could be (each or eachCount NULL, no reading, a sample without them, the count changed between the two,
// or more CPUs than capacity).
void SystemInfoCpuSetKinds(natural_t count, const char* kinds);
void SystemInfoCpuReset(void);
void SystemInfoCpuTick(void);
double SystemInfoCpuBusy(double* span, double* efficiency, double* performance);
double SystemInfoCpuBusyEach(double* span, double* efficiency, double* performance, double* each, natural_t capacity,
                             natural_t* eachCount);

// memory used as Activity Monitor counts it (app memory, wired and compressed) and the physical memory, in bytes
bool SystemInfoMemory(uint64_t* used, uint64_t* total);

// swap in use, vm.swapusage's used, in bytes
bool SystemInfoSwap(uint64_t* used);

// seconds since the last boot, sleep included, past the first minute rounded to the nearest minute as uptime(1)
// does; -1 when the kernel cannot be read
long SystemInfoUptimeSeconds(void);

// the GPU's busy share, 0..1: IOAccelerator's "Device Utilization %" over 100, the highest among the services that carry
// it (one per GPU); -1 when it cannot be read. The services are looked up on the first call and kept; after a lookup
// that finds none, the next is tried at most once a minute
double SystemInfoGpuBusy(void);

// the Neural Engine's power: 1 when the H11ANEIn service's IOPowerManagement CurrentPowerState is above 0, 0 when it is
// 0, -1 when there is no such service or the state cannot be read. Its power, not its work: it turns on with work and
// off seconds after it. Looked up as SystemInfoGpuBusy's services are
int SystemInfoNeuralEngine(void);

// The internal battery, as IOPowerSources describes it: level is the charge, 0..1 (Current Capacity over Max Capacity);
// charging and charged as the power source says; onAC when the power source is the adapter; the minutes to empty
// (on battery) and to full (charging), -1 when unknown (the system is still estimating, or the source gives none).
struct SystemInfoBattery
{
  double level;
  bool   charging;
  bool   charged;
  bool   onAC;
  int    minutesToEmpty;
  int    minutesToFull;
}
typedef SystemInfoBattery;

// reads one power source's description into *battery: true only for the internal battery that is present, with a
// capacity to divide by; the other sources (a UPS, a Bluetooth device) and a Mac without a battery give false.
// *battery is left as it was when the result is false
bool SystemInfoBatteryFromDescription(CFDictionaryRef description, SystemInfoBattery* battery);

// the first power source that SystemInfoBatteryFromDescription accepts; false when this Mac has no internal battery
bool SystemInfoBatteryRead(SystemInfoBattery* battery);

// the state in words, into text of size: "charging", "charged", "not charging" (on the adapter, neither charging nor
// charged), "on battery, 3:12 left" or "on battery" (time unknown)
void SystemInfoBatteryStateText(const SystemInfoBattery* battery, char* text, size_t size);

// Wi-Fi. The readings come from CoreWLAN in AppDelegate.mm, which fills a SystemInfoWifi; the rest here is pure. Nothing
// here reads the network's name, its BSSID or its country, which need Location Services.
struct SystemInfoWifi
{
  bool   present;       // this Mac has a Wi-Fi interface
  bool   powerOn;
  bool   connected;
  int    rssi;          // dBm
  int    noise;         // dBm
  double txRate;        // Mbps
  long   security;      // CWSecurity
  long   phy;           // CWPHYMode
  long   channel;       // the channel's number
  long   band;          // CWChannelBand
  long   width;         // CWChannelWidth
  char   ifname[16];    // "en0"
}
typedef SystemInfoWifi;

// the Wi-Fi bar's fill, 0..1: (rssi + 90) / 60, empty at -90 dBm or weaker and full at -30 dBm or stronger; -1 for an
// rssi of 0 or above, which is no reading
double SystemInfoWifiFill(int rssi);

// CWSecurity's name ("WPA2 Personal"), CWPHYMode's ("802.11ax"); NULL for a value without one
const char* SystemInfoWifiSecurityName(long security);
const char* SystemInfoWifiPhyName(long phy);

// "48 (5 GHz, 80 MHz)" from CWChannelBand and CWChannelWidth; a band or width without a name is left out of the brackets
void SystemInfoWifiChannelText(long number, long band, long width, char* text, size_t size);

// the IPv4 address and the MAC address of an interface, as dotted and colon-separated text, as the interface has them
// now (the MAC is the private one a network sees); either buffer may be NULL; false when the interface has no IPv4
// address
bool SystemInfoInterfaceAddresses(const char* ifname, char* ip, size_t ipSize, char* mac, size_t macSize);

// the IPv4 default router through that interface, from the kernel's routing table; false when there is none
bool SystemInfoDefaultRouter(const char* ifname, char* text, size_t size);

__END_DECLS

#endif /* SystemInfo_h */
