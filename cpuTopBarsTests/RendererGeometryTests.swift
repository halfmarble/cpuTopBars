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
import CoreGraphics

// CpuRenderer.c's layout functions, all with tickWidth 4 and tickTotalWidth 6. Every expected value is worked out from
// the function named in the comment beside it.
extension FreeTests {
  @Suite struct RendererGeometryTests {
    @Test func readingsSlotAndWidth() {
      // _readings_slot: bar tickTotalWidth + tickWidth = 10, dot tickTotalWidth = 6
      #expect(CpuRenderReadingsSlot(true, 4, 6) == 10)
      #expect(CpuRenderReadingsSlot(false, 4, 6) == 6)
      // CpuRenderReadingsWidth, shown 0: 5 slots + (dot 1) + gap 4 + (split) split gap + extras
      #expect(CpuRenderReadingsWidth(true, 4, 6, 0, 0, 0, nil) == 54)   // 5*10 + 0 + 4
      #expect(CpuRenderReadingsWidth(false, 4, 6, 0, 0, 0, nil) == 35)  // 5*6 + 1 + 4
      #expect(CpuRenderReadingsWidth(true, 4, 6, 0, 2, 0, nil) == 58)   // 54 + _split_gap(bar) = 0 + 4
      #expect(CpuRenderReadingsWidth(false, 4, 6, 0, 2, 0, nil) == 40)  // 35 + _split_gap(dot) = 1 + 4
    }

    @Test func extraWidthGroupsAndNarrow() {
      // _extra_width: gap 4 + the slots + a group gap 4 per group start after the first + (dot 1)
      var extras = [CpuExtraReading](repeating: CpuExtraReading(), count: 2)
      #expect(extras.withUnsafeBufferPointer { CpuRenderExtraWidth(true, 4, 6, 2, $0.baseAddress) } == 24)  // 4 + 10 + 10
      extras[1].groupStart = true
      #expect(extras.withUnsafeBufferPointer { CpuRenderExtraWidth(true, 4, 6, 2, $0.baseAddress) } == 28)  // 24 + 4
      extras[1].groupStart = false
      extras[1].narrow = true
      #expect(extras.withUnsafeBufferPointer { CpuRenderExtraWidth(true, 4, 6, 2, $0.baseAddress) } == 20)  // 4 + 10 + 6
      #expect(CpuRenderExtraWidth(true, 4, 6, 0, nil) == 0)    // n > 0 is false
      #expect(CpuRenderExtraWidth(true, 4, 6, -3, nil) == 0)   // _extra_count turns -3 into 0
    }

    @Test func coreSlotThinsPast24() {
      // CpuRenderCoreSlot: up to 24 bars the full slot; past it max(1 + (6-4), min(6, floor(24*6/count)))
      #expect(CpuRenderCoreSlot(true, 4, 6, 24) == 6)
      #expect(CpuRenderCoreSlot(true, 4, 6, 30) == 4)    // floor(144/30) = 4
      #expect(CpuRenderCoreSlot(true, 4, 6, 48) == 3)    // floor(144/48) = 3
      #expect(CpuRenderCoreSlot(true, 4, 6, 100) == 3)   // floor(144/100) = 1, raised to the floor 1 + 2
      #expect(CpuRenderCoreSlot(false, 4, 6, 100) == 6)  // dots keep their slot
      // CpuRenderCoreWidth: tickWidth in a full slot, else the slot less the gap (6-4)
      #expect(CpuRenderCoreWidth(true, 4, 6, 10) == 4)
      #expect(CpuRenderCoreWidth(true, 4, 6, 30) == 2)   // 4 - 2
    }

    @Test func coreXAndBack() {
      // CpuRenderCoreX: start + index*slot + (index past the split) split gap + readings slot
      #expect(CpuRenderCoreX(true, 4, 6, 54, 0, 8, 3) == 72)   // 54 + 3*6
      #expect(CpuRenderCoreX(true, 4, 6, 44, 2, 8, 2) == 70)   // 44 + 2*6 + (0 + 4) + 10
      // CpuRenderCoreAtX: the rightmost bar starting at or left of x, if x is inside its slot
      #expect(CpuRenderCoreAtX(true, 4, 6, 54, 0, 8, 72) == 3)
      #expect(CpuRenderCoreAtX(true, 4, 6, 54, 0, 8, 53.9) == -1)               // left of bar 0 (x = 54)
      #expect(CpuRenderCoreAtX(true, 4, 6, 54, 0, 8, 54 + 48 + 100) == 7)       // the last bar has no right end
      #expect(CpuRenderCoreAtX(true, 4, 6, 44, 2, 8, 69.9) == -1)               // between bar 1's slot (50..56) and bar 2 (70)
      #expect(CpuRenderCoreAtX(true, 4, 6, 44, 2, 8, 70) == 2)
    }

    @Test func readingXAndGraphSpan() {
      // CpuRenderReadingX, shown 0, the five readings: index * slot
      #expect(CpuRenderReadingX(true, 4, 6, 0, 100, 0, 8, 0, nil, 2) == 20)
      // split after 2 bars: the E-cores' reading at _efficiency_x = 3*10 + 0 + 4
      #expect(CpuRenderReadingX(true, 4, 6, 0, 100, 2, 8, 0, nil, 3) == 34)
      // the P-cores' reading: 34 + slot 10 + 2 bars * 6 + split gap 4
      #expect(CpuRenderReadingX(true, 4, 6, 0, 100, 2, 8, 0, nil, 4) == 60)
      // extra readings: imageWidth - _extra_width + gap 4 + the slots before it; an index past the last gives the last one's
      let extras = [CpuExtraReading](repeating: CpuExtraReading(), count: 2)
      extras.withUnsafeBufferPointer { e in
        #expect(CpuRenderReadingX(true, 4, 6, 0, 200, 0, 8, 2, e.baseAddress, 5) == 180)  // 200 - 24 + 4
        #expect(CpuRenderReadingX(true, 4, 6, 0, 200, 0, 8, 2, e.baseAddress, 6) == 190)  // 180 + 10
        #expect(CpuRenderReadingX(true, 4, 6, 0, 200, 0, 8, 2, e.baseAddress, 9) == 190)  // clamped to the last
      }
      // CpuRenderGraphSpan
      var start: CGFloat = 0, end: CGFloat = 0
      CpuRenderGraphSpan(true, 4, 6, 100, true, 0, 0, 0, nil, &start, &end)
      #expect(start == 54 && end == 100)   // the readings' width, no extras
      CpuRenderGraphSpan(true, 4, 6, 100, true, 0, 2, 0, nil, &start, &end)
      #expect(start == 44)                 // _efficiency_x 34 + slot 10
      CpuRenderGraphSpan(true, 4, 6, 100, false, 0, 0, 0, nil, &start, &end)
      #expect(start == 0)                  // no readings: the graph starts at x = 0
    }

    @Test func neuralEngineWideSlot() {
      // shown = the GPU only: the Neural Engine's and the GPU's slots are both a reading's, 10 in bar style (CpuRenderReadingSlot,
      // CpuRenderer.c), 6 in Dot style
      let gpu = CPU_RENDER_SHOWN_GPU
      #expect(CpuRenderReadingSlot(true, 4, 6, gpu, 0, nil, 2) == 10)
      #expect(CpuRenderReadingSlot(true, 4, 6, gpu, 0, nil, 3) == 10)
      #expect(CpuRenderReadingSlot(false, 4, 6, gpu, 0, nil, 3) == 6)
      // the order: disk, memory, the Neural Engine, the GPU, CPU, then E and P; without the GPU's, CPU is third
      #expect(CpuRenderReadingIndex(gpu, CPU_RENDER_KIND_NEURAL_ENGINE) == 2)
      #expect(CpuRenderReadingIndex(gpu, CPU_RENDER_KIND_GPU) == 3)
      #expect(CpuRenderReadingIndex(gpu, CPU_RENDER_KIND_CPU) == 4)
      #expect(CpuRenderReadingIndex(0, CPU_RENDER_KIND_CPU) == 2)
      // CpuRenderReadingX: the slots before the index, and after memory the group gap 4 (_split_gap): disk 0, memory 10, the
      // Neural Engine 10 + 10 + 4 = 24, the GPU 34, CPU 44, E 54, P 64
      let xs: [CGFloat] = [0, 10, 24, 34, 44, 54, 64]
      for (index, x) in xs.enumerated() {
        #expect(CpuRenderReadingX(true, 4, 6, gpu, 200, 0, 8, 0, nil, Int32(index)) == x, "index \(index)")
      }
      // CpuRenderReadingsWidth: 7*10 + the gap after memory 4 + the readings' gap 4; dots 7*6 + 5 + 1 + 4
      #expect(CpuRenderReadingsWidth(true, 4, 6, gpu, 0, 0, nil) == 78)
      #expect(CpuRenderReadingsWidth(false, 4, 6, gpu, 0, 0, nil) == 52)
      // split after 2 bars: _efficiency_x = 5*10 + 4 + 0 + 4 = 58; the P-cores' reading
      // 58 + 10 + 2 bars * 6 + split gap 4 = 84; the graph from 58 + 10 = 68 (CpuRenderGraphSpan)
      #expect(CpuRenderReadingX(true, 4, 6, gpu, 200, 2, 8, 0, nil, 5) == 58)
      #expect(CpuRenderReadingX(true, 4, 6, gpu, 200, 2, 8, 0, nil, 6) == 84)
      var start: CGFloat = 0, end: CGFloat = 0
      CpuRenderGraphSpan(true, 4, 6, 200, true, gpu, 2, 0, nil, &start, &end)
      #expect(start == 68)
      CpuRenderGraphSpan(true, 4, 6, 200, true, gpu, 0, 0, nil, &start, &end)
      #expect(start == 78)
    }

    @Test func kindAndIndexRoundTripForEveryMask() {
      for mask in UInt32(0)..<8 {
        let gpu = (mask & CPU_RENDER_SHOWN_GPU) != 0, wifi = (mask & CPU_RENDER_SHOWN_WIFI) != 0
        let battery = (mask & CPU_RENDER_SHOWN_BATTERY) != 0
        let count = 5 + (gpu ? 2 : 0) + (wifi ? 1 : 0) + (battery ? 1 : 0)
        #expect(CpuRenderReadingsCount(mask) == Int32(count), "mask \(mask)")
        #expect(count <= Int(CPU_RENDER_READINGS_MAX))
        var last: Int32 = -1
        for index in 0..<Int32(count) {
          let kind = CpuRenderReadingKind(mask, index)
          #expect(kind > last, "mask \(mask), index \(index)")   // the kinds are in drawing order
          #expect(CpuRenderReadingIndex(mask, kind) == index, "mask \(mask), kind \(kind)")
          last = kind
        }
        #expect(CpuRenderReadingKind(mask, Int32(count)) == -1)   // an extra reading
        #expect(CpuRenderReadingKind(mask, -1) == -1)
        #expect(CpuRenderReadingIndex(mask, CPU_RENDER_KIND_BATTERY) == (battery ? 0 : -1))
        #expect(CpuRenderReadingIndex(mask, CPU_RENDER_KIND_WIFI) == (wifi ? (battery ? 1 : 0) : -1))
        #expect(CpuRenderReadingIndex(mask, CPU_RENDER_KIND_GPU) == (gpu ? Int32(count) - 4 : -1))
        #expect(CpuRenderReadingIndex(mask, CPU_RENDER_KIND_PERFORMANCE) == Int32(count) - 1)
        #expect(CpuRenderReadingEfficiency(mask) == Int32(count) - 2 && CpuRenderReadingPerformance(mask) == Int32(count) - 1)
        #expect(CpuRenderReadingIndex(mask, 9) == -1 && CpuRenderReadingIndex(mask, -1) == -1)
      }
      // shown 0: the five of the readings before the optional ones, and their indices
      #expect(CpuRenderReadingEfficiency(0) == Int32(CPU_RENDER_READING_EFFICIENCY))
      #expect(CpuRenderReadingPerformance(0) == Int32(CPU_RENDER_READING_PERFORMANCE))
      #expect(CpuRenderReadingsCount(0) == Int32(CPU_RENDER_READINGS_COUNT))
    }

    @Test func batteryAndWifiGeometry() {
      // the battery's slot is a reading's, its number written over its bar
      #expect(CpuRenderReadingSlot(true, 4, 6, CPU_RENDER_SHOWN_BATTERY, 0, nil, 0) == 10)
      #expect(CpuRenderReadingSlot(false, 4, 6, CPU_RENDER_SHOWN_BATTERY, 0, nil, 0) == 6)
      #expect(CpuRenderReadingSlot(true, 4, 6, CPU_RENDER_SHOWN_BATTERY, 0, nil, 1) == 10)
      // all shown: battery 0, Wi-Fi 10, disk 20, memory 30, then the gap 4 and the Neural Engine at 44, the GPU 54,
      // CPU 64, E 74, P 84; the width is P's end 94 + the readings' gap 4
      let all = CPU_RENDER_SHOWN_GPU | CPU_RENDER_SHOWN_WIFI | CPU_RENDER_SHOWN_BATTERY
      let xs: [CGFloat] = [0, 10, 20, 30, 44, 54, 64, 74, 84]
      for (index, x) in xs.enumerated() {
        #expect(CpuRenderReadingX(true, 4, 6, all, 300, 0, 8, 0, nil, Int32(index)) == x, "index \(index)")
      }
      #expect(CpuRenderReadingsWidth(true, 4, 6, all, 0, 0, nil) == 98)
      var start: CGFloat = 0, end: CGFloat = 0
      CpuRenderGraphSpan(true, 4, 6, 300, true, all, 0, 0, nil, &start, &end)
      #expect(start == 98 && end == 300)   // width and the graph's start agree
      // split after 2 bars: E at 78 (= 70 of slots before it + 4 + 4), P at 78 + 10 + 12 + 4 = 104, the graph from 88,
      // the width 102
      #expect(CpuRenderReadingX(true, 4, 6, all, 300, 2, 8, 0, nil, 7) == 78)
      #expect(CpuRenderReadingX(true, 4, 6, all, 300, 2, 8, 0, nil, 8) == 104)
      CpuRenderGraphSpan(true, 4, 6, 300, true, all, 2, 0, nil, &start, &end)
      #expect(start == 88)
      #expect(CpuRenderReadingsWidth(true, 4, 6, all, 2, 0, nil) == 102)
      // the battery alone: disk 10, memory 20, then the gap: CPU 34, E 44, P 54, width 64 + 4
      #expect(CpuRenderReadingX(true, 4, 6, CPU_RENDER_SHOWN_BATTERY, 300, 0, 8, 0, nil, 1) == 10)
      #expect(CpuRenderReadingX(true, 4, 6, CPU_RENDER_SHOWN_BATTERY, 300, 0, 8, 0, nil, 3) == 34)
      #expect(CpuRenderReadingsWidth(true, 4, 6, CPU_RENDER_SHOWN_BATTERY, 0, 0, nil) == 68)
      // Wi-Fi alone: Wi-Fi 0, disk 10, memory 20, CPU 34, width 60 + 4 + 4
      #expect(CpuRenderReadingX(true, 4, 6, CPU_RENDER_SHOWN_WIFI, 300, 0, 8, 0, nil, 3) == 34)
      #expect(CpuRenderReadingsWidth(true, 4, 6, CPU_RENDER_SHOWN_WIFI, 0, 0, nil) == 68)
      // extra readings sit after the graph whatever the mask: an index at the block's count
      let extras = [CpuExtraReading](repeating: CpuExtraReading(), count: 1)
      extras.withUnsafeBufferPointer { e in
        #expect(CpuRenderReadingX(true, 4, 6, all, 200, 0, 8, 1, e.baseAddress, 9) == 190)   // 200 - (4 + 10) + 4
      }
    }

    @Test func dotStyleGap() {
      // Dot style, the GPU only: slot 6, the gap after memory 5 (the last dot's 1-pt overhang and 4): disk 0, memory 6, the
      // Neural Engine 17, the GPU 23, CPU 29, E 35, P 41; the width 7*6 + 5 + 1 + 4 = 52
      let gpu = CPU_RENDER_SHOWN_GPU
      let xs: [CGFloat] = [0, 6, 17, 23, 29, 35, 41]
      for (index, x) in xs.enumerated() {
        #expect(CpuRenderReadingX(false, 4, 6, gpu, 200, 0, 8, 0, nil, Int32(index)) == x, "index \(index)")
      }
      #expect(CpuRenderReadingsWidth(false, 4, 6, gpu, 0, 0, nil) == 52)
      // the split: _efficiency_x = 5*6 + 5 + 1 + 4 = 40; the P-cores' reading 40 + 6 + 2 bars * 6 + (1 + 4) = 63
      #expect(CpuRenderReadingX(false, 4, 6, gpu, 200, 2, 8, 0, nil, 5) == 40)
      #expect(CpuRenderReadingX(false, 4, 6, gpu, 200, 2, 8, 0, nil, 6) == 63)
      // the battery's slot in Dot style: a reading's, 6
      #expect(CpuRenderReadingX(false, 4, 6, CPU_RENDER_SHOWN_BATTERY, 200, 0, 8, 0, nil, 1) == 6)
    }

    @Test func efficiencyBars() {
      // CpuRenderEfficiencyBars; granularity 0 is one bar, under 2 gives 0
      #expect(CpuRenderEfficiencyBars(0, 8, "EEEEPPPP") == 0)
      let n = Int(CpuSamplerGetCount(2))
      #expect(n >= 2)
      // one bar per logical CPU: one E then P's gives efficiency 1 and group 1; P first gives efficiency 0
      let split = "E" + String(repeating: "P", count: n - 1)
      #expect(CpuRenderEfficiencyBars(2, natural_t(n), split) == 1)
      let flipped = "P" + String(repeating: "E", count: n - 1)
      #expect(CpuRenderEfficiencyBars(2, natural_t(n), flipped) == 0)
      #expect(CpuRenderEfficiencyBars(2, natural_t(n), nil) == 0)   // kinds NULL
    }
  }
}
