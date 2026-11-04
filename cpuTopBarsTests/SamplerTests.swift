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

// CpuSampler.c: the counts, the two demo samplers and one real read.
extension FreeTests {
  @Suite struct SamplerTests {
    @Test func flatDemo() {
      var flat = CpuSummaryInfo()
      CpuSamplerFlatDemoInit(&flat)
      defer { free(flat.now) }
      let n = Int(flat.countLogical)
      #expect(n >= 1)
      // every CPU gets the same load
      let first = flat.now[0].load
      #expect((0..<n).allSatisfy { flat.now[$0].load == first })
      // each call stores the static load, then raises it by 0.04 * speed, back to 0 past 1: the
      // next call stores the raised value, or 0 after the wrap
      CpuSamplerFlatDemoUpdate(&flat, 1.0)
      let second = flat.now[0].load
      #expect(abs(second - (first + 0.04)) < 1e-12 || second == 0.0)
    }

    @Test func sineDemo() throws {
      // The demo's counter is static and shared, so the first CPU's phase depends on what ran before. What holds from
      // any starting phase: every load is in 0...1, and each CPU's phase is one step (3.5 * 0.025) past the one before,
      // so sin(a + d) = sin(a) cos(d) +- cos(a) sin(d), the sign of cos(a) being unknown from the load alone
      var sine = CpuSummaryInfo()
      CpuSamplerSineDemoInit(&sine)
      defer { free(sine.now) }
      try #require(sine.countLogical >= 2)
      let step = 3.5 * 0.025
      for i in 0..<Int(sine.countLogical) {
        #expect(sine.now[i].load >= 0.0 && sine.now[i].load <= 1.0)
      }
      for i in 0..<Int(sine.countLogical) - 1 {
        let s0 = (Double(sine.now[i].load) - 0.5) * 2.0
        let s1 = (Double(sine.now[i + 1].load) - 0.5) * 2.0
        let c0 = (max(0.0, 1.0 - s0 * s0)).squareRoot()
        let plus = s0 * cos(step) + c0 * sin(step)
        let minus = s0 * cos(step) - c0 * sin(step)
        #expect(abs(s1 - plus) < 1e-6 || abs(s1 - minus) < 1e-6)
      }
    }

    @Test func countsByGranularity() {
      // CpuSamplerGetCount: 1 for granularity 0, the physical count for 1 and the logical count for 2,
      // each at least 1, and a Mac has no fewer logical CPUs than physical ones
      #expect(CpuSamplerGetCount(0) == 1)
      #expect(CpuSamplerGetCount(1) >= 1)
      #expect(CpuSamplerGetCount(2) >= CpuSamplerGetCount(1))
    }

    @Test func realReadStaysInRange() {
      // CpuSamplerInit reads once and calls CpuSamplerUpdate, which stores used / total,
      // a share between 0 and 1
      var info = CpuSummaryInfo()
      CpuSamplerInit(&info)
      defer { free(info.last); free(info.now) }
      let n = Int(info.countLogical)
      #expect(n >= 1)
      #expect((0..<n).allSatisfy { (0.0...1.0).contains(info.now[$0].load) })
      CpuSamplerUpdate(&info)
      #expect((0..<n).allSatisfy { (0.0...1.0).contains(info.now[$0].load) })
    }
  }
}
