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

// Top.c: the process sampler, run in the test runner (xctest), which is not sandboxed. Every test samples again, so each
// finds the runner's own process in the latest sample.
extension FreeTests {
  @Suite struct TopTests {
    // TopInit allocates its tables and takes the first sample (TopInit): once per process
    static let processCount = TopInit()

    private static func sample() -> Int32 {
      _ = processCount
      return TopSample()
    }

    @Test func findsItself() {
      #expect(TopTests.processCount > 0)
      // a second sample after some CPU use, so the runner has a baseline (_top_update_for_pid)
      let until = Date().addingTimeInterval(0.2)
      var spin = 0.0
      while Date() < until { spin += 1 }
      #expect(TopTests.sample() > 0, "after \(spin) loops")
      // own process: the full read works (_top_update_for_pid), so CPU and memory are known and the footprint is above 0
      let me = TopGetSample(getpid())
      #expect(me != nil)
      #expect(me?.pointee.cpu_known == 1)
      #expect(me?.pointee.mem_known == 1)
      #expect((me?.pointee.mem ?? 0) > 0)
    }

    @Test func memoryOrderIsNonIncreasing() {
      // _top_compare_mem_func: known memory first, then the larger footprint first
      _ = TopTests.sample()
      TopSetOrder(TopOrderMemory)
      defer { TopSetOrder(TopOrderCpu) }
      var last = UInt64.max, ordered = true, seen = 0
      while let s = TopIterate() {
        if s.pointee.mem_known == 1 {
          if s.pointee.mem > last { ordered = false }
          last = s.pointee.mem
        }
        seen += 1
      }
      #expect(ordered)
      #expect(seen > 0)
    }

    @Test func iterateResetStartsTheWalkAgain() {
      // TopIterateReset: after a walk that stopped part way, the next TopIterate starts at the first process
      _ = TopTests.sample()
      TopIterateReset()
      let first = TopIterate()?.pointee.pid
      #expect(first != nil)
      TopIterateReset()
      for _ in 0..<3 { _ = TopIterate() }
      TopIterateReset()
      #expect(TopIterate()?.pointee.pid == first)
      TopIterateReset()
    }

    @Test func arguments() {
      _ = TopTests.sample()
      // TopGetArgs reads KERN_PROCARGS2 of the runner's own process: argc is at least 1
      let args = TopGetArgs(getpid())
      #expect((args?.pointee.args_count ?? 0) >= 1)
    }

    // TopParseTopLine over three recordings of `top -l 2 -stats pid,cpu` (or pid,uid,cpu,command) on macOS 27 (in the
    // third, five process names were replaced by common app names), in Fixtures/ beside this file (read by #filePath: the runner is not sandboxed). Each sample is 12 lines that are not
    // process rows: 10 header lines (Processes, the date, Load Avg, CPU usage, SharedLibs, MemRegions, PhysMem, VM,
    // Networks, Disks), a blank line and the column heads "PID ...". Samples: 2, 3 and 2; lines: 84, 126 and 84.
    private static func fixtureLines(_ name: String) throws -> [String] {
      let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
      let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
      return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test(arguments: [("top-macos27-1.txt", 2, 60), ("top-macos27-2.txt", 3, 90), ("top-macos27-3.txt", 2, 60)])
    func parsesEveryProcessRow(file: String, samples: Int, rows: Int) throws {
      var lines = try TopTests.fixtureLines(file)
      if lines.last == "" { lines.removeLast() }   // the final newline
      let headerLines = 12 * samples
      #expect(lines.filter { $0.hasPrefix("Processes:") }.count == samples)
      #expect(lines.count - headerLines == rows, "lines that are not header lines")
      var parsed = 0, rejected: [String] = []
      for line in lines {
        var row = TopParsedRow()
        if TopParseTopLine(line, &row) == 1 {
          parsed += 1
          #expect(row.pid >= 0)   // kernel_task is pid 0
          #expect(row.cpu >= 0)
        } else {
          rejected.append(line)
        }
      }
      #expect(parsed == rows)
      #expect(rejected.count == headerLines)
      #expect(rejected.contains { $0.hasPrefix("PID") } && rejected.contains("") && rejected.contains { $0.hasPrefix("Disks:") })
    }

    @Test func parsesOneRowsFields() {
      var row = TopParsedRow()
      #expect(TopParseTopLine("99502  0.0 ", &row) == 1)
      #expect(row.pid == 99502)
      #expect(row.cpu == 0.0)
      #expect(row.has_uid == 0)
      #expect(TopParseTopLine("PID    %CPU", &row) == 0)
      #expect(TopParseTopLine("", &row) == 0)
    }

    // KillAllowed (Top.c): pid above 1, not self, and the process's uid equal to the user's
    @Test func killAllowedRefusesWhatItMust() {
      let me = getuid(), self_ = getpid()
      #expect(KillAllowed(0, me, self_, me) == 0, "pid 0")
      #expect(KillAllowed(1, me, self_, me) == 0, "pid 1 (launchd)")
      #expect(KillAllowed(-1, me, self_, me) == 0, "a negative pid")
      #expect(KillAllowed(self_, me, self_, me) == 0, "itself")
      #expect(KillAllowed(self_ + 1, me &+ 1, self_, me) == 0, "another user's process")
      #expect(KillAllowed(self_ + 1, 0, 1234, 501) == 0, "root's process, user 501")
    }

    @Test func killAllowedAllowsAnotherProcessOfTheSameUser() {
      let me = getuid(), self_ = getpid()
      #expect(KillAllowed(self_ + 1, me, self_, me) != 0)
      #expect(KillAllowed(2, 501, 1234, 501) != 0)
    }

    // Run as root, the test is skipped, not passed: root reads every process
    @Test(.disabled(if: getuid() == 0, "root reads every process")) func otherUsersProcessIsUnreadable() {
      // Process 1 (launchd) belongs to root. A user who is not root gets no task info for it (_top_update_for_pid), so its CPU
      // is unknown and it counts as unreadable (TopSort); the sample still lists it
      _ = TopTests.sample()
      let launchd = TopGetSample(1)
      #expect(launchd != nil)
      #expect(launchd?.pointee.cpu_known == 0)
      #expect(TopUnreadableCount() > 0)
    }
  }
}
