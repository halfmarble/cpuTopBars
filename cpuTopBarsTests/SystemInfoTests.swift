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

import Testing
import Foundation

// A C string buffer up to its NUL, as String(cString:) on an array is deprecated
private func bufferString(_ buffer: [CChar]) -> String {
  String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// SystemInfo.c: the CPU window, memory, swap and uptime, and the battery and Wi-Fi helpers.
extension FreeTests {
  @Suite struct SystemInfoTests {
    @Test func noSamplesGiveNoReading() {
      // SystemInfoCpuReset forgets the samples (SystemInfo.c:131); with fewer than 2 the busy share is -1, the span 0
      // and both kinds' shares -1 (SystemInfo.c:162-177)
      SystemInfoCpuReset()
      var span = 1.0, efficiency = 0.0, performance = 0.0
      #expect(SystemInfoCpuBusy(&span, &efficiency, &performance) == -1)
      #expect(span == 0)
      #expect(efficiency == -1 && performance == -1)
      SystemInfoCpuTick()   // one sample is still fewer than 2
      #expect(SystemInfoCpuBusy(&span, nil, nil) == -1)
      #expect(span == 0)
    }

    @Test func memorySwapAndUptime() {
      // SystemInfoMemory: total is hw.memsize (SystemInfo.c:224, 242), used the counted pages, which cannot exceed it
      var used: UInt64 = 0, total: UInt64 = 0
      #expect(SystemInfoMemory(&used, &total))
      #expect(total == ProcessInfo.processInfo.physicalMemory)
      #expect(used > 0 && used <= total)
      // SystemInfoSwap reads vm.swapusage (SystemInfo.c:250)
      var swap: UInt64 = 0
      #expect(SystemInfoSwap(&swap))
      // SystemInfoUptimeSeconds counts from the boot time, sleep included (SystemInfo.c:269), so it is not below the
      // system uptime, which leaves sleep out; one second of slack for the two clocks' reads
      #expect(SystemInfoUptimeSeconds() >= Int(ProcessInfo.processInfo.systemUptime) - 1)
    }

    @Test func busyOverOneSecond() {
      // two ticks 1.1 s apart: the window is the 2 samples, whose span is their time difference, at least 1.1 s
      // (SystemInfo.c:185-200), and the busy share is used / total, between 0 and 1 (SystemInfo.c:126-128)
      SystemInfoCpuReset()
      SystemInfoCpuTick()
      let until = Date().addingTimeInterval(1.1)
      var spin = 0.0
      while Date() < until { spin += 1 }
      SystemInfoCpuTick()
      var span = 0.0
      let busy = SystemInfoCpuBusy(&span, nil, nil)
      #expect(busy >= 0 && busy <= 1, "busy \(busy) after \(spin) loops")
      #expect(span >= 1.0)
    }

    @Test func eachCpuOverTheSameWindow() {
      // SystemInfoCpuBusyEach gives what SystemInfoCpuBusy gives, over the same window, and each logical CPU's busy
      // share in it, one per CPU host_processor_info counts (hw.ncpu), each 0..1 or -1, nothing written past them
      SystemInfoCpuReset()
      SystemInfoCpuTick()
      let until = Date().addingTimeInterval(1.1)
      var spin = 0.0
      while Date() < until { spin += 1 }
      SystemInfoCpuTick()
      let cpus = ProcessInfo.processInfo.processorCount
      var each = [Double](repeating: -2, count: cpus + 1)
      var count: natural_t = 99
      var span = 0.0, spanEach = 0.0
      let busy = SystemInfoCpuBusy(&span, nil, nil)
      let busyEach = SystemInfoCpuBusyEach(&spanEach, nil, nil, &each, natural_t(each.count), &count)
      #expect(busyEach == busy && spanEach == span, "busy \(busy) after \(spin) loops")
      #expect(Int(count) == cpus)
      #expect(each.prefix(cpus).allSatisfy { ($0 >= 0 && $0 <= 1) || $0 == -1 }, "\(each)")
      #expect(each[cpus] == -2)
      // every CPU's counters advance about 100 ticks a second (SystemInfo.c, CpuEachTicks), so over 1.1 s each CPU has
      // ticks and a share, and the overall share, all CPUs' ticks summed, is close to the mean of theirs (within 0.0020
      // in 56 windows, measured on an M3): the E and P labels' titles over their lines
      let read = each.prefix(cpus).filter { $0 >= 0 }
      #expect(read.count == cpus, "\(each)")
      let mean = read.reduce(0, +) / Double(max(read.count, 1))
      #expect(abs(mean - busy) < 0.01, "mean \(mean), busy \(busy), each \(each)")
      // too small a capacity, or no buffer, writes none and counts 0; the busy share is still given
      var small = [Double](repeating: -2, count: max(cpus - 1, 1))
      #expect(SystemInfoCpuBusyEach(nil, nil, nil, &small, natural_t(cpus - 1), &count) == busy)
      #expect(count == 0)
      #expect(small.allSatisfy { $0 == -2 })
      count = 99
      #expect(SystemInfoCpuBusyEach(nil, nil, nil, nil, 0, &count) == busy)
      #expect(count == 0)
      // after a reset, no reading and none written
      SystemInfoCpuReset()
      count = 99
      #expect(SystemInfoCpuBusyEach(nil, nil, nil, &each, natural_t(each.count), &count) == -1)
      #expect(count == 0)
    }

    // the power source keys' literal values, from IOPSKeys.h
    private func powerSource(_ extra: [String: Any]) -> CFDictionary {
      var d: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 87, "Max Capacity": 100]
      for (k, v) in extra { d[k] = v }
      return d as NSDictionary as CFDictionary
    }

    private func batteryText(_ b: SystemInfoBattery) -> String {
      var text = [CChar](repeating: 0, count: 64)
      var b = b
      SystemInfoBatteryStateText(&b, &text, text.count)
      return bufferString(text)
    }

    private func parse(_ extra: [String: Any]) -> SystemInfoBattery? {
      var b = SystemInfoBattery()
      return SystemInfoBatteryFromDescription(powerSource(extra), &b) ? b : nil
    }

    @Test func batteryParserReadsTheInternalBattery() throws {
      let b = try #require(parse(["Is Charging": true, "Power Source State": "AC Power"]))
      #expect(abs(b.level - 0.87) < 1e-9)
      #expect(b.charging && !b.charged && b.onAC)
      #expect(batteryText(b) == "charging")
    }

    @Test func batteryParserRefusesOtherSourcesAndBadCapacity() {
      #expect(parse(["Type": "UPS"]) == nil)
      #expect(parse(["Is Present": false]) == nil)
      #expect(parse(["Max Capacity": 0]) == nil)
      #expect(SystemInfoBatteryFromDescription(nil, nil) == false)
    }

    @Test func batteryStateTexts() throws {
      let ac = try #require(parse(["Power Source State": "AC Power", "Is Charging": false, "Is Charged": false]))
      #expect(batteryText(ac) == "not charging")
      let full = try #require(parse(["Power Source State": "AC Power", "Is Charged": true]))
      #expect(batteryText(full) == "charged")
      let timed = try #require(parse(["Power Source State": "Battery Power", "Time to Empty": 192]))
      #expect(timed.minutesToEmpty == 192 && !timed.onAC)
      #expect(batteryText(timed) == "on battery, 3:12 left")
      let unknown = try #require(parse(["Power Source State": "Battery Power", "Time to Empty": -1]))
      #expect(unknown.minutesToEmpty == -1)
      #expect(batteryText(unknown) == "on battery")
    }

    @Test func wifiFill() {
      #expect(SystemInfoWifiFill(-90) == 0)
      #expect(SystemInfoWifiFill(-100) == 0)
      #expect(SystemInfoWifiFill(-60) == 0.5)
      #expect(SystemInfoWifiFill(-30) == 1)
      #expect(SystemInfoWifiFill(-20) == 1)
      #expect(SystemInfoWifiFill(0) == -1)
    }

    private func name(_ p: UnsafePointer<CChar>?) -> String? {
      p.map { String(cString: $0) }
    }

    @Test func wifiNames() {
      #expect(name(SystemInfoWifiSecurityName(4)) == "WPA2 Personal")
      #expect(name(SystemInfoWifiSecurityName(11)) == "WPA3 Personal")
      #expect(name(SystemInfoWifiSecurityName(0)) == "None")
      #expect(name(SystemInfoWifiSecurityName(99)) == nil)
      #expect(name(SystemInfoWifiPhyName(6)) == "802.11ax")
      #expect(name(SystemInfoWifiPhyName(7)) == "802.11be")
      #expect(name(SystemInfoWifiPhyName(99)) == nil)
    }

    @Test func wifiChannelText() {
      func text(_ n: Int, _ band: Int, _ width: Int) -> String {
        var t = [CChar](repeating: 0, count: 64)
        SystemInfoWifiChannelText(n, band, width, &t, t.count)
        return bufferString(t)
      }
      #expect(text(48, 2, 3) == "48 (5 GHz, 80 MHz)")
      #expect(text(6, 1, 1) == "6 (2.4 GHz, 20 MHz)")
      #expect(text(37, 3, 4) == "37 (6 GHz, 160 MHz)")
      #expect(text(11, 0, 0) == "11")
    }
  }
}
