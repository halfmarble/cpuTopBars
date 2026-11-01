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
import CoreText
import Foundation

// CpuRender into a bitmap, dark menu bar, no colour, tickWidth 4 and tickTotalWidth 6. Granularity 0 is one core bar on
// any Mac (CpuSampler.c:130), so the readings block starts the image: the disk bar is at x = 0 to 8 (CpuRenderer.c:295,
// 2 * tickWidth wide). The bitmap's first memory row is the image's top, so the row at height y is memory row 15 - y.
private struct Bitmap {
  let width: Int
  var height = 16
  let bytes: [UInt8]

  func alpha(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4 + 3] }
  func red(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4] }
  func green(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4 + 1] }
  func pixel(x: Int, y: Int) -> [UInt8] { Array(bytes[(height - 1 - y) * width * 4 + x * 4 ..< (height - 1 - y) * width * 4 + x * 4 + 4]) }
  func column(_ x: Int) -> [UInt8] { (0..<height).map { alpha(x: x, y: $0) } }   // index 0 is height 0, the bottom
}

// scale 2 draws as for a Retina display: a bitmap twice the size, its transform scaled by 2, so a point is 2 pixels;
// height is the image's in points (26 with the block's letters, CpuRenderImageHeight)
private func render(bar: Bool, stripped: Bool, width: Int, readings: CpuReadings,
                    extra: [CpuExtraReading] = [], light: Bool = false, scale: Int = 1, height: Int = 16,
                    tickWidth: CGFloat = 4, tickTotalWidth: CGFloat = 6, colored: Bool = false) -> Bitmap {
  let h = height * scale
  let ctx = CGContext(data: nil, width: width * scale, height: h, bitsPerComponent: 8, bytesPerRow: width * scale * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  var ticks = Ticks()
  var readings = readings
  withUnsafeMutablePointer(to: &ticks) { t in
    var info = CpuSummaryInfo()
    info.countLogical = 1
    info.countCores = 1
    info.now = t
    info.last = t
    extra.withUnsafeBufferPointer { e in
      readings.extraCount = Int32(extra.count)
      readings.extra = extra.isEmpty ? nil : e.baseAddress
      CpuRender(&info, ctx, light, 0, bar, stripped, colored, tickWidth, tickTotalWidth, CGFloat(width), 0, &readings)
    }
  }
  let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
  return Bitmap(width: width * scale, height: h, bytes: Array(UnsafeBufferPointer(start: data, count: width * scale * h * 4)))
}

private func readings(disk: Double) -> CpuReadings {
  var r = CpuReadings()
  r.disk = disk; r.memory = -1; r.cpu = -1; r.efficiency = -1; r.performance = -1
  return r
}

extension FreeTests {
  @Suite struct RendererDrawingTests {
    @Test(arguments: [(0.0, 0), (0.25, 4), (0.5, 8), (1.0, 16)])
    func barHeight(load: Double, rows: Int) {
      // _render_group (CpuRenderer.c:395): a background over the whole 16 pt, then a fill load*16 pt high from the bottom.
      // On a dark bar the background has alpha 0.3 (about 76) and the fill over it at least 0.606 (about 154) at load 0.25,
      // so "above 127" counts the filled rows only
      let column = render(bar: true, stripped: false, width: 60, readings: readings(disk: load)).column(1)
      #expect(column.filter { $0 > 127 }.count == rows)
      #expect(column.allSatisfy { $0 > 0 })                  // the background, whole height
      #expect(column.prefix(rows).allSatisfy { $0 > 127 })   // filled from the bottom
    }

    @Test func dashes() {
      // stripped: the bar starts at DASHED_BOTTOM 2 (CpuRenderer.c:545), so heights 0 and 1 are clear, and heights 4, 7,
      // 10 and 13 are cleared again (CpuRenderer.c:637), leaving five 2-pt dashes
      let column = render(bar: true, stripped: true, width: 60, readings: readings(disk: 1.0)).column(1)
      for y in [0, 1, 4, 7, 10, 13] { #expect(column[y] == 0, "height \(y)") }
      for y in [2, 3, 5, 6, 8, 9, 11, 12, 14, 15] { #expect(column[y] > 127, "height \(y)") }
    }

    @Test func cpuDrawnAfterGpu() {
      // gpuShown: CPU at full load is drawn at index 4 (CpuRenderReadingIndex), x = 44 to 52, filled the whole 16 pt; index
      // 2, the Neural Engine's (off: its background only), and index 3, the GPU's (not read), stay below the fill's alpha.
      // The gap after memory, x = 20 to 24 (memory's bar ends at 18, its slot at 20), stays clear
      var r = readings(disk: -1)
      r.gpuShown = true
      r.gpu = -1
      r.neuralEngine = 0
      r.cpu = 1.0
      let image = render(bar: true, stripped: false, width: 100, readings: r)
      for x in 44..<52 { #expect(image.column(x).allSatisfy { $0 > 127 }, "CPU column \(x)") }
      for x in 24..<42 { #expect(image.column(x).allSatisfy { $0 <= 127 }, "column \(x)") }
      for x in 20..<24 { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
    }

    @Test func unreadReadingsDrawNothingInDotStyle() {
      // Dot style, every reading below 0: the branch for a reading not read draws only in bar style (CpuRenderer.c:600),
      // so the disk slot, x = 0 to 6 (the dot slot is tickTotalWidth), stays transparent. The one core dot starts at
      // x = 35 (CpuRenderReadingsWidth, dot), clear of that slot
      let image = render(bar: false, stripped: false, width: 60, readings: readings(disk: -1))
      for x in 0..<6 { #expect(image.column(x).allSatisfy { $0 == 0 }, "column \(x)") }
    }

    @Test(arguments: [(Int32(1), true), (Int32(0), false)])
    func neuralEngineWideSolidBar(state: Int32, on: Bool) {
      // gpuShown, dashed: the memory bar (not read: its background only) at x = 10 to 18, the gap after memory (x = 18 to 24),
      // the Neural Engine's bar at x = 24 to 32 (index 2), the GPU's (its background only) at 34 to 42, 2 * tickWidth wide (CpuRenderReadingX, CpuRenderer.c), drawn last from DASHED_BOTTOM 2 and
      // whole, without the dashes (_render_neural_engine, CpuRenderer.c:498): on, white at 0.9 opacity (alpha about 230,
      // and red equal to alpha, as premultiplied white); off, the background alone, alpha 0.3 (about 76). The 2-pt gaps
      // before it (x = 18 to 23) and after it (x = 32, 33) stay clear
      var r = readings(disk: -1)
      r.gpuShown = true
      r.gpu = -1
      r.neuralEngine = state
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 24..<32 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0, "below DASHED_BOTTOM, column \(x)")
        for y in 2..<16 {
          if on {
            #expect(abs(Int(column[y]) - 230) <= 1, "0.9 opacity, column \(x), height \(y)")
            #expect(image.red(x: x, y: y) == column[y], "white, column \(x), height \(y)")
          } else {
            #expect(column[y] > 0 && column[y] < 127, "column \(x), height \(y)")
          }
        }
      }
      for x in [18, 19, 20, 21, 22, 23, 32, 33] { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
      #expect(image.column(17)[2] > 0)   // the memory bar's background ends at x = 18
      #expect(image.column(34)[2] > 0)   // the GPU's background starts at x = 34
    }

    @Test(arguments: [-1.0, 0.0, 0.37, 1.0], [true, false])
    func neuralEngineBarByShare(share: Double, dashed: Bool) {
      // the same layout as above, with neuralEngineByShare: the Neural Engine's reading is drawn as the GPU's bar is (a block
      // value through _render_group), so its columns, x = 24 to 32, are pixel for pixel the GPU's, x = 34 to 42, in all four
      // channels, whatever the share (below 0 not read: the background alone) and in either style, without colour and in
      // the ramp's colours. neuralEngine is ignored
      var r = readings(disk: -1)
      r.gpuShown = true
      r.neuralEngine = 0   // ignored by share
      r.neuralEngineByShare = true
      r.neuralEngineBusy = share
      r.gpu = share
      for colored in [false, true] {
        let image = render(bar: true, stripped: dashed, width: 100, readings: r, colored: colored)
        for dx in 0..<8 {
          for y in 0..<16 {
            #expect(image.pixel(x: 24 + dx, y: y) == image.pixel(x: 34 + dx, y: y), "share \(share), dashed \(dashed), colored \(colored), column \(24 + dx), height \(y)")
          }
        }
        if colored && share > 0 {
          // in colour the fill is the ramp's (theme 0, yellow: red and green over blue), not grey
          let p = image.pixel(x: 24, y: 2)
          #expect(p[0] != p[2], "share \(share), dashed \(dashed): the ramp's colour, \(p)")
        }
      }
      let image = render(bar: true, stripped: dashed, width: 100, readings: r)
      for x in [18, 19, 20, 21, 22, 23, 32, 33] { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
      if share > 0 {
        // the fill over the background is at least about 154 (barHeight), so above the background's 77 and the 127 of barHeight
        #expect(image.column(24)[2] > 127, "filled from the bottom of the bar")   // height 2 is a dash's row
      }
      if dashed && share >= 0 {
        // the dashes of the dashed style: heights 0, 1 (below DASHED_BOTTOM) and 4, 7, 10 and 13 cleared, not drawn whole
        for x in 24..<32 { for y in [0, 1, 4, 7, 10, 13] { #expect(image.alpha(x: x, y: y) == 0, "dash row, column \(x), height \(y)") } }
      }
    }

    // the battery number's font, registered once from the app's sources: the hostless bundle has no app Resources
    private static let batteryFont: Bool = {
      let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("cpuTopBars/Micro5-Regular.ttf")
      return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    // the battery alone, in a 120-wide image: its bar at x = 0 to 8, a reading's width, drawn last from DASHED_BOTTOM 2 in
    // the dashed style and whole, without the dashes. Its digits, Micro 5 at 1 pt a pixel, 5 pt tall and 3 wide ("1" 2),
    // are centred across it on whole points, x = 2 to 5 ("1" 3 to 5), and stacked from the top 1 pt apart, 1 pt above the
    // centre: two digits are 11 pt, from height 4 ("87": the 7 at 4 to 9, the 8 at 10 to 15). Columns 0, 1, 6 and 7 never
    // hold a digit
    private func batteryReadings(_ charge: Double, charging: Bool = false, onAC: Bool = false, style: Int32 = 0) -> CpuReadings {
      var r = readings(disk: -1)
      r.batteryShown = true
      r.battery = charge
      r.batteryCharging = charging
      r.batteryOnAC = onAC
      r.batteryStyle = style
      return r
    }

    // the battery at 100% in each power state: on battery, charging, and on the adapter and not charging
    private static let fullStates: [(name: String, charging: Bool, onAC: Bool)] =
      [("battery", false, false), ("charging", true, true), ("adapter", false, true)]

    // the bolt's coverage of the pixel at x, y: the share of the way its green has gone from the fill's, read at height 3,
    // below the bolt (the full fill is the same on every row), to the bolt's own, 255 white or 0 black, opaque. The fill's
    // green is 189 or more from either in every state and style (measured, dark: 238 to 245 on the adapter by style, 209
    // charging, 66 on battery; light: 0 to 4, 199, 56)
    private func batteryBoltCoverage(_ image: Bitmap, scale: Int, white: Bool, x: Int, y: Int) -> Double {
      let fill = Double(image.green(x: 0, y: 3 * scale))
      return (Double(image.green(x: x, y: y)) - fill) / ((white ? 255.0 : 0.0) - fill)
    }

    // the bolt's area in points at scale: its coverage summed over the bar's columns from height 2 up to the cap's row, 15
    private func batteryBoltArea(_ image: Bitmap, scale: Int, columns: Int, white: Bool) -> Double {
      var area = 0.0
      for y in (2 * scale)..<(15 * scale) {
        for x in 0..<(columns * scale) { area += batteryBoltCoverage(image, scale: scale, white: white, x: x, y: y) }
      }
      return area / Double(scale * scale)
    }

    @Test(arguments: [Int32(0), 1, 2, 3], [1, 2])
    func batteryFullBoltIsSolidInEveryStateAndStyle(style: Int32, scale: Int) {
      // at 100% the fill covers the bar in every style, and the bolt is drawn over it solid, at full opacity, in every power
      // state: white on battery's red and on the light menu bar's black adapter fill, black on charging's green and on the
      // dark menu bar's white one. Its box at x = 2.125 to 6.375 and heights 6.15 to 11.85 (the 16 - 5.7 centred snaps to 5,
      // raised 1, then the icon's 0.125 and 0.15), so columns 0, 1 and 7 and the rows from 2 to 5 and from 12 to 14 are the
      // fill alone, pixel for pixel. The band across its middle, heights 8.5 to 9 and x = 3 to 5, is all bolt at 2x: opaque
      // in the bolt's colour; at 1x its row 8 is mostly bolt at x = 3 and 4. At 2x, heights 11 to 11.5, the upper stroke,
      // which leans right as the icon's does, holds x = 4.5 to 5 and not 3 to 3.5 (a bolt mirrored across would hold the
      // second). Its area by its coverage is 8.37 pt² by its corners (the shoelace formula). Nothing stands below the bar or
      // in the gap after it
      for light in [false, true] {
        for state in Self.fullStates {
          let white = !state.charging && (!state.onAC || light)
          let image = render(bar: true, stripped: true, width: 120,
                             readings: batteryReadings(1.0, charging: state.charging, onAC: state.onAC, style: style), light: light, scale: scale)
          let label = "style \(style), scale \(scale), light \(light), \(state.name)"
          let fill = image.pixel(x: 0, y: 3 * scale)
          for x in [0, 1, 7].flatMap({ ($0 * scale)..<(($0 + 1) * scale) }) {
            for y in (2 * scale)..<(15 * scale) { #expect(image.pixel(x: x, y: y) == fill, "\(label), column \(x), height \(y)") }
          }
          for y in Array((2 * scale)..<(6 * scale)) + Array((12 * scale)..<(15 * scale)) {
            for x in 0..<(8 * scale) { #expect(image.pixel(x: x, y: y) == fill, "\(label), pixel \(x), \(y)") }
          }
          if scale == 2 {
            let bolt: UInt8 = white ? 255 : 0
            for x in 6..<10 {
              let p = image.pixel(x: x, y: 17)
              #expect(p == [bolt, bolt, bolt, 255], "\(label), band pixel \(x): \(p)")
            }
            let right = batteryBoltCoverage(image, scale: 2, white: white, x: 9, y: 22)
            let left = batteryBoltCoverage(image, scale: 2, white: white, x: 6, y: 22)
            #expect(right > 0.875 && left < 0.125, "\(label), upper stroke: \(right) at x 9, \(left) at x 6")
          } else {
            for x in [3, 4] {
              let c = batteryBoltCoverage(image, scale: 1, white: white, x: x, y: 8)
              #expect(c > 0.5, "\(label), band pixel \(x): \(c)")
            }
          }
          let area = batteryBoltArea(image, scale: scale, columns: 8, white: white)
          #expect(abs(area - 8.37) < 0.4, "\(label), bolt area \(area)")
          for x in 0..<(8 * scale) {
            for y in 0..<(2 * scale) { #expect(image.alpha(x: x, y: y) == 0, "\(label), below the bar, \(x), \(y)") }
          }
          // the readings' gap after the bar: the slot ends at 10, where disk's background starts
          for x in (8 * scale)..<(10 * scale) { #expect(image.column(x).allSatisfy { $0 == 0 }, "\(label), gap column \(x)") }
          #expect(image.column(10 * scale)[2 * scale] > 0)
        }
      }
    }

    @Test(arguments: [Int32(0), 1, 2, 3], [1, 2])
    func batteryCapCutsTheTopCorners(style: Int32, scale: Int) {
      // every battery bar's top 1 pt, height 15 to 16, is cleared but for its middle half, each cut a quarter of the width
      // on a device pixel: the Thick 8-pt bar's 2 pt, the Standard 6-pt's 1.5 (2 at 1x), the Thin 4-pt's 1. At every charge,
      // full (the bolt), 62 and 20 (the digits) and not read (the background alone), in the solid and the dashed styles, in
      // each power state, on either menu bar. Without digits the cut columns are drawn at height 14: the cap is 1 pt tall
      for (tick, cut) in [(CGFloat(4), 2 * scale), (3, scale == 2 ? 3 : 2), (2, scale)] {
        let width = Int(2 * tick) * scale
        for charge in [1.0, 0.62, 0.2, -1] {
          for stripped in [false, true] {
            for light in [false, true] {
              for state in Self.fullStates {
                let image = render(bar: true, stripped: stripped, width: 120,
                                   readings: batteryReadings(charge, charging: state.charging, onAC: state.onAC, style: style),
                                   light: light, scale: scale, tickWidth: tick, tickTotalWidth: tick + 2)
                let label = "style \(style), scale \(scale), width \(Int(2 * tick)), charge \(charge), stripped \(stripped), light \(light), \(state.name)"
                for x in 0..<width {
                  let corner = (x < cut) || (x >= width - cut)
                  for y in (15 * scale)..<(16 * scale) {
                    let a = image.alpha(x: x, y: y)
                    #expect(corner ? (a == 0) : (a > 0), "\(label), pixel \(x), \(y): \(a)")
                  }
                  if corner && (charge == 1.0 || charge < 0) {
                    #expect(image.alpha(x: x, y: (15 * scale) - 1) > 0, "\(label), below the cap, column \(x)")
                  }
                }
              }
            }
          }
        }
      }
    }

    @Test func batteryFullBoltShrinksOnAThinBar() {
      // Thin: tickWidth 2, so the battery's bar is 4 pt wide, under the bolt's 4.25: the bolt drawn at 4 / 4.25 of its size,
      // its area 8.37 x 0.886 = 7.41 pt², inside the bar (the slot's gap after it, from 4, stays clear), black on the
      // adapter's white and white on the battery's red
      for (onAC, white) in [(true, false), (false, true)] {
        let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, onAC: onAC, style: 1), scale: 2,
                           tickWidth: 2, tickTotalWidth: 3)
        let area = batteryBoltArea(image, scale: 2, columns: 4, white: white)
        #expect(abs(area - 7.41) < 0.4, "white \(white), bolt area \(area)")
        for x in 8..<10 { #expect(image.column(x).allSatisfy { $0 == 0 }, "white \(white), the gap after the thin bar, column \(x)") }
      }
    }

    // the device rows of a two-digit number at scale: the lower digit's, the upper digit's, and the rows beside them that
    // hold no digit (the row below the stack, the gap, the row above it). At 1x the centred 2.5 snaps to 3 and the raise
    // adds 1: the stack is 4 to 15, rows 4 to 8, the gap row 9, rows 10 to 14. At 2x _snap keeps 2.5: 3.5 to 14.5 pt,
    // rows 7 to 16, the gap rows 17 and 18, rows 19 to 28. Before the 1-pt raise and gap the digits were at rows 3 to 7
    // and 9 to 13 at 1x, and at 2x, where the stack's 2.75 snapped to 3, at rows 6 to 15 and 17 to 26, the gap row 16
    private func batteryDigitRows(scale: Int) -> (lower: Range<Int>, upper: Range<Int>, clear: [Int]) {
      scale == 1 ? (4..<9, 10..<15, [3, 9, 15]) : (7..<17, 19..<29, [6, 17, 18, 29])
    }

    @Test(arguments: [Int32(0), 1, 2, 3], [1, 2])
    func batteryNumberIsCutOutOfTheFill(style: Int32, scale: Int) {
      #expect(Self.batteryFont)
      // 87% on the adapter, on a dark bar: the fill to 2 + 0.87 * 14 = 14.18, its top snapped to a device pixel, so the 7 and
      // all but the 8's top row stand in it and are cut out of it, in every style (the tint style cuts them out of the fill
      // and draws them over the rest). Below the fill's top, which crosses row 14 at 1x and 28 at 2x, each digit row holds a cut-out
      // pixel in the digits' columns, 2 to 4, and each clear row none; and those digit rows hold at least 12 cut-out
      // points, 12 pixels at 1x and 48 at 2x
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.87, onAC: true, style: style), scale: scale)
      let rows = batteryDigitRows(scale: scale)
      let top = 14 * scale
      let columns = (2 * scale)..<(5 * scale)
      var cut = 0
      for y in Array(rows.lower) + Array(rows.upper) where y < top {
        #expect(columns.contains { image.alpha(x: $0, y: y) == 0 }, "style \(style), scale \(scale), digit row \(y)")
        cut += columns.filter { image.alpha(x: $0, y: y) == 0 }.count
      }
      #expect(cut >= 12 * scale * scale, "scale \(scale), cut-out pixels: \(cut)")
      for y in rows.clear where y < top {
        #expect(columns.allSatisfy { image.alpha(x: $0, y: y) > 200 }, "scale \(scale), clear row \(y)")
      }
      for x in [0, 1, 6, 7].flatMap({ ($0 * scale)..<(($0 + 1) * scale) }) {
        for y in (2 * scale)..<top { #expect(image.alpha(x: x, y: y) > 200, "scale \(scale), column \(x), height \(y)") }
      }
      for x in 0..<(8 * scale) {
        for y in 0..<(2 * scale) { #expect(image.alpha(x: x, y: y) == 0, "below the bar, scale \(scale), \(x), \(y)") }
      }
    }

    @Test(arguments: [Int32(0), 1, 2, 3])
    func batteryFillColourFollowsThePowerState(style: Int32) {
      #expect(Self.batteryFont)
      for light in [false, true] {
        let battery = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, style: style), light: light)
        let charging = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, charging: true, onAC: true, style: style), light: light)
        let adapter = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, onAC: true, style: style), light: light)
        // on battery systemRed and charging systemGreen, both at full opacity; on the adapter the text colour at 0.9
        #expect(battery.alpha(x: 0, y: 8) == 255 && battery.red(x: 0, y: 8) > battery.green(x: 0, y: 8), "light \(light)")
        #expect(charging.alpha(x: 0, y: 8) == 255 && charging.green(x: 0, y: 8) > charging.red(x: 0, y: 8), "light \(light)")
        #expect(adapter.alpha(x: 0, y: 8) < 255 && adapter.red(x: 0, y: 8) == adapter.green(x: 0, y: 8), "style \(style), light \(light)")
        #expect((adapter.red(x: 0, y: 8) > 200) == !light, "white on a dark menu bar, black on a light one")
      }
    }

    @Test(arguments: [false, true], [1, 2])
    func batteryTintNumberOverTheEmptyBarIsAShadeOfTheFill(light: Bool, scale: Int) {
      #expect(Self.batteryFont)
      // the tint style, 20% on battery in the solid style: the fill to height 3.2, snapped to 3 (6 at 2x), below the stack,
      // so "20" stands over the background alone (red at 0.38 opacity, alpha 97). Each digit row holds a digit pixel (alpha
      // 255) in the digits' columns, 2 to 4, in systemRed mixed 60% toward white on a dark bar (red 255, green about 179:
      // 66 + 189 x 0.6; the white or black of the text colour, or the plain fill (green 66 dark, 56 light), would fail) and 45%
      // toward black on a light one (red about 140, green about 31), and each clear row none: the background alone, alpha
      // 97, row 3 at 1x and 6 at 2x
      let image = render(bar: true, stripped: false, width: 120, readings: batteryReadings(0.2, style: 3), light: light, scale: scale)
      let rows = batteryDigitRows(scale: scale)
      let columns = (2 * scale)..<(5 * scale)
      for y in Array(rows.lower) + Array(rows.upper) {
        let digit = columns.filter { image.alpha(x: $0, y: y) > 200 }
        #expect(!digit.isEmpty, "scale \(scale), digit row \(y)")
        for x in digit {
          let (red, green) = (Int(image.red(x: x, y: y)), Int(image.green(x: x, y: y)))
          #expect(light ? (abs(red - 140) <= 3 && abs(green - 31) <= 3) : (red == 255 && abs(green - 179) <= 3),
                  "scale \(scale), column \(x), height \(y): red \(red), green \(green)")
        }
      }
      for y in rows.clear {
        #expect(columns.allSatisfy { image.alpha(x: $0, y: y) <= 200 }, "scale \(scale), clear row \(y)")
      }
      for x in [0, 1, 6, 7].flatMap({ ($0 * scale)..<(($0 + 1) * scale) }) {
        for y in (4 * scale)..<(15 * scale) {   // height 15 is the cap's (batteryCapCutsTheTopCorners)
          #expect(abs(Int(image.alpha(x: x, y: y)) - 97) <= 2, "scale \(scale), column \(x), height \(y)")
        }
      }
    }

    @Test(arguments: [Int32(0), 1, 2, 3], [1, 2])
    func batteryDigitsAndWifiSegmentsSitOnWholePixels(style: Int32, scale: Int) {
      #expect(Self.batteryFont)
      // at 1x and 2x every edge of the digits, of the battery's fill and of the Wi-Fi segments falls on a device pixel, so
      // no pixel of the battery's or Wi-Fi's bar is a blend: each alpha is one the style can produce, within 2: clear (the
      // cut-out digits), Wi-Fi's background 77 and fill 230, the battery's background (light tint 255, grey 153, light grey
      // 191, tint 97), its fill 255 and its digits 255 (the light tint's, the tint style's above the fill). A half-covered
      // pixel would read between them. Dark bar, battery, charges 0.5 (the fill's top on a whole point in both styles: 8,
      // and 2 + 7 = 9), 0.62 and 0.2 (tops of 9.92 and 3.2 solid, 2 + 8.68 and 2 + 2.8 dashed, snapped to device pixels; left
      // unsnapped, their top rows would blend); the other alphas are 0 and 255 at the edges the cut-outs touch
      let background = [Int32(255), 153, 191, 97][Int(style)]
      let allowed = [0, 77, 230, 255, Int(background)]
      for charge in [0.5, 0.62, 0.2] {
        var r = batteryReadings(charge, style: style)
        r.wifiShown = true
        r.wifi = 0.5
        for stripped in [false, true] {
          let image = render(bar: true, stripped: stripped, width: 120, readings: r, scale: scale)
          for x in 0..<(18 * scale) {
            for y in 0..<(16 * scale) {
              let a = Int(image.alpha(x: x, y: y))
              #expect(allowed.contains { abs($0 - a) <= 2 }, "style \(style), scale \(scale), charge \(charge), stripped \(stripped), pixel \(x), \(y): \(a)")
            }
          }
        }
      }
    }

    @Test(arguments: [Int32(0), 1, 2, 3])
    func batteryNotReadDrawsOnlyTheBarBackground(style: Int32) {
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(-1, style: style))
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for y in 2..<15 { #expect(column[y] > 0 && column[y] < 127, "column \(x), height \(y): \(column[y])") }
        // the cap: height 15 cleared at the corners, x = 0, 1, 6 and 7
        let corner = (x < 2) || (x >= 6)
        #expect(corner ? (column[15] == 0) : (column[15] > 0 && column[15] < 127), "column \(x), height 15: \(column[15])")
      }
    }

    // the battery at 62% on battery, in the dashed style, 1x: the fill's height 0.62 * 14 = 8.68, snapped to 9, so rows 2 to 10;
    // the digits "62": the 2 at rows 4 to 8 and the 6 at rows 10 to 14, both with a pixel at x = 3 on rows 4, 6, 8, 12 and 14
    // (the 6's row 10 is in the fill, rows 11 to 14 above it). So (3, 4), (3, 6) and (3, 8) are digit pixels on the fill, (3, 12)
    // and (3, 14) digit pixels above it, and x = 0 is the bar with no digit: the fill at y = 6, the background at y = 12
    private func batteryDigits(style: Int32, light: Bool, charging: Bool = false, onAC: Bool = false) -> Bitmap {
      render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.62, charging: charging, onAC: onAC, style: style), light: light)
    }

    @Test func batteryLightTintOnADarkBarIsOpaqueAndPinkerThanTheFill() {
      #expect(Self.batteryFont)
      // systemRed on a dark bar is (255, 66, ...); the background is that mixed 55% toward white: green about 170, alpha 255
      // (measured: the fill 255/255/66 as alpha/red/green, the background 255/255/170). The digits are cut out: alpha 0, on
      // the fill and above it
      let image = batteryDigits(style: 0, light: false)
      #expect(image.alpha(x: 0, y: 12) == 255 && image.alpha(x: 0, y: 6) == 255)
      #expect(image.green(x: 0, y: 12) > image.green(x: 0, y: 6) + 60, "background \(image.green(x: 0, y: 12)), fill \(image.green(x: 0, y: 6))")
      #expect(abs(Int(image.green(x: 0, y: 12)) - 170) <= 2 && abs(Int(image.green(x: 0, y: 6)) - 66) <= 2)
      for y in [4, 6, 8] { #expect(image.alpha(x: 3, y: y) == 0, "digit on the fill, height \(y)") }
      for y in [12, 14] { #expect(image.alpha(x: 3, y: y) == 0, "digit above the fill, height \(y)") }
    }

    @Test(arguments: [false, true])
    func batteryLightTintOnALightBarHasBlackDigitsWhenColoured(charging: Bool) {
      #expect(Self.batteryFont)
      // light menu bar, on battery or charging: the digits are black at 0.9 opacity over the fill and over the tint, none cut
      // out: alpha 255, red and green under 40 (measured: 25 and 5 to 16 on battery, 5 to 23 charging)
      let image = batteryDigits(style: 0, light: true, charging: charging, onAC: charging)
      for (x, y) in [(3, 4), (3, 6), (3, 8), (3, 12), (3, 14)] {
        #expect(image.alpha(x: x, y: y) == 255, "charging \(charging), pixel \(x), \(y)")
        #expect(image.red(x: x, y: y) < 40 && image.green(x: x, y: y) < 40, "charging \(charging), pixel \(x), \(y)")
      }
      // the background: the fill mixed 55% toward white, opaque. On battery systemRed (255, 56, ...) gives green
      // about 166 (0.22 + 0.78 x 0.55); charging systemGreen (52, 199, ...) gives red about 164 and green about 230
      let (alpha, red, green) = (Int(image.alpha(x: 0, y: 12)), Int(image.red(x: 0, y: 12)), Int(image.green(x: 0, y: 12)))
      #expect(alpha == 255, "charging \(charging): background alpha \(alpha)")
      #expect(charging ? (abs(red - 164) <= 3 && abs(green - 230) <= 3) : (red == 255 && abs(green - 166) <= 3),
              "charging \(charging): background red \(red), green \(green)")
    }

    @Test func batteryLightTintOnALightBarOnTheAdapterCutsTheDigitsOut() {
      #expect(Self.batteryFont)
      // neutral (on the adapter, not charging): the tint is the bars' grey at 0.55 and the fill the text colour, so the digits
      // are cut out as on a dark bar
      let image = batteryDigits(style: 0, light: true, onAC: true)
      for (x, y) in [(3, 4), (3, 6), (3, 8), (3, 12), (3, 14)] { #expect(image.alpha(x: x, y: y) == 0, "pixel \(x), \(y)") }
      #expect(image.alpha(x: 0, y: 12) > 0 && image.alpha(x: 0, y: 6) > 0)
    }

    @Test(arguments: [(Int32(1), 153), (Int32(2), 191)])
    func batteryGreyStylesHaveTheirBackgroundOpacityAndCutOutDigits(style: Int32, alpha: Int) {
      #expect(Self.batteryFont)
      // the bars' grey at 0.60 (alpha 153) and 0.75 (191) over the whole bar, above the fill; the digits cut out everywhere
      let image = batteryDigits(style: style, light: false)
      for y in [11, 12, 13, 14] { #expect(abs(Int(image.alpha(x: 0, y: y)) - alpha) <= 2, "style \(style), height \(y): \(image.alpha(x: 0, y: y))") }
      #expect(image.alpha(x: 0, y: 6) == 255, "the fill")
      for y in [4, 6, 8, 12, 14] { #expect(image.alpha(x: 3, y: y) == 0, "style \(style), digit at height \(y)") }
    }

    @Test(arguments: [Int32(99), -1, 4])
    func batteryStyleZeroedOrUnknownDrawsTheLightTint(style: Int32) {
      #expect(Self.batteryFont)
      for light in [false, true] {
        for (charging, onAC) in [(false, false), (true, true), (false, true)] {
          let tint = batteryDigits(style: 0, light: light, charging: charging, onAC: onAC)
          let other = batteryDigits(style: style, light: light, charging: charging, onAC: onAC)
          #expect(tint.bytes == other.bytes, "style \(style), light \(light), charging \(charging), adapter \(onAC)")
        }
      }
      // a zeroed struct is style 0 as well: batteryReadings sets the style, so build one that does not
      var r = readings(disk: -1)
      r.batteryShown = true
      r.battery = 0.62
      #expect(r.batteryStyle == 0)
      let zeroed = render(bar: true, stripped: true, width: 120, readings: r)
      #expect(zeroed.bytes == batteryDigits(style: 0, light: false).bytes)
    }

    @Test(arguments: [(1.0, 5), (0.5, 3), (0.4, 2), (0.0, 1), (-1.0, 0)])
    func wifiSegmentsLightWithTheSignal(fill: Double, lit: Int) {
      // Wi-Fi alone: its bar is the first reading, x = 0 to 8. In the dashed style, from DASHED_BOTTOM 2: five segments 2 pt
      // tall, 1 pt apart, at heights 2, 5, 8, 11 and 14; ceil(fill * 5) lit from the bottom, at least one from fill 0, white
      // at 0.9 opacity alone (alpha about 230, as the Neural Engine's bar), not over the background, which would make it
      // 238 and brighter than the system's icons; the rest the background alone; the gaps and the rows below 2 clear
      var r = readings(disk: -1)
      r.wifiShown = true
      r.wifi = fill
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for segment in 0..<5 {
          let y = 2 + (segment * 3)
          for row in [y, y + 1] {
            if segment < lit {
              #expect(abs(Int(column[row]) - 230) <= 1, "lit, 0.9 opacity, column \(x), height \(row): \(column[row])")
              #expect(image.red(x: x, y: row) == column[row], "white, column \(x), height \(row)")
            } else {
              #expect(column[row] > 0 && column[row] < 127, "background, column \(x), height \(row): \(column[row])")
            }
          }
          if segment < 4 { #expect(column[y + 2] == 0, "gap, column \(x), height \(y + 2)") }
        }
      }
    }


    @Test func wifiSegmentsInTheSolidStyle() {
      // the full 16 pt: segments at heights 0, 3.5, 7, 10.5 and 14, 1.5 pt apart, each foot on a device pixel: in this 1x
      // bitmap at 0, 4, 7, 11 and 14, so rows 2, 3, 6, 9, 10 and 13 are gaps
      var r = readings(disk: -1)
      r.wifiShown = true
      r.wifi = 1.0
      let image = render(bar: true, stripped: false, width: 100, readings: r)
      for x in 0..<8 {
        let column = image.column(x)
        for y in [0, 1, 4, 5, 7, 8, 11, 12, 14, 15] { #expect(column[y] > 200, "column \(x), height \(y): \(column[y])") }
        for y in [2, 3, 6, 9, 10, 13] { #expect(column[y] == 0, "gap, column \(x), height \(y): \(column[y])") }
      }
    }

    @Test func extraReadingMarkDrawsOneRow() {
      // one extra reading, value 0.5 and mark 0.5, in a 100-wide image: its x is 100 - _extra_width (4 + 10) + 4 = 90
      // (CpuRenderer.c:317), its bar 2 * tickWidth = 8 wide. The mark is a 1-pt white line at
      // floor(bottom + 0.5 * 16) = 8 (CpuRenderer.c:676), drawn last so it is opaque
      var extra = CpuExtraReading()
      extra.value = 0.5
      extra.mark = 0.5
      let image = render(bar: true, stripped: false, width: 100, readings: readings(disk: -1), extra: [extra])
      for x in 90..<98 {
        #expect(image.alpha(x: x, y: 8) == 255, "mark row, column \(x)")
        #expect(image.alpha(x: x, y: 7) < 255, "below the mark, column \(x)")   // the fill over the background, about 188
        #expect(image.alpha(x: x, y: 9) < 255, "above the mark, column \(x)")   // the background alone, about 76
      }
      #expect(image.alpha(x: 89, y: 8) < 255)   // the mark stops at the bar's left edge
      #expect(image.alpha(x: 98, y: 8) < 255)   // and at its right edge
    }

    @Test func imageHeightWithTheLetters() {
      // taller only with the letters asked for, in bar style, with the block drawn: 26 pt solid, 24 dashed (the dashed
      // bars' clear 2-pt foot taken off); else the 16-pt image as before
      var r = readings(disk: 1.0)
      #expect(CpuRenderImageHeight(true, false, &r) == 16)
      #expect(CpuRenderImageHeight(true, true, &r) == 16)
      r.letters = true
      #expect(CpuRenderImageHeight(true, false, &r) == 26)
      #expect(CpuRenderImageHeight(true, true, &r) == 24)
      #expect(CpuRenderImageHeight(false, true, &r) == 16)
      r.extraOnly = true
      #expect(CpuRenderImageHeight(true, true, &r) == 16)
      #expect(CpuRenderImageHeight(true, true, nil) == 16)
    }

    @Test(arguments: [false, true])
    func lettersSitThreePointsUnderTheDashedBars(light: Bool) {
      // the dashed style the app draws: a 24-pt image, the bars lifted 6 pt, so the disk bar's dashes (from DASHED_BOTTOM 2
      // on its 16-pt scale) stand at heights 8, 9, 11, 12, 14, 15, 17, 18, 20 and 21, with the cleared rows 10, 13, 16 and 19
      // between them; heights 5 to 7 are the 3-pt gap, heights 22 and 23 the clear top; D at heights 0 to 4, x = 1 to 5, in the
      // text colour (black on a light menu bar, white on a dark one)
      var r = readings(disk: 1.0)
      r.letters = true
      let image = render(bar: true, stripped: true, width: 60, readings: r, light: light, height: 24)
      for x in 0..<8 {
        let column = image.column(x)
        for y in [8, 9, 11, 12, 14, 15, 17, 18, 20, 21] { #expect(column[y] > 200, "dash, column \(x), height \(y): \(column[y])") }
        for y in [5, 6, 7, 10, 13, 16, 19, 22, 23] { #expect(column[y] == 0, "clear, column \(x), height \(y)") }
        let lit = (0..<5).filter { image.alpha(x: x, y: $0) > 200 }
        #expect(lit.isEmpty == !(1..<6).contains(x), "D's columns, column \(x): \(lit)")
        for y in lit { #expect((image.red(x: x, y: y) > 200) == !light, "text colour, column \(x), height \(y)") }
      }
    }

    @Test func lettersUnderTheBlockBars() {
      // the five readings, D R C E P, at x = 0, 10, 20, 30 and 40, each 8 wide; every bar full, so each fills heights 8 to
      // 23 above the band, and heights 24 and 25, the top, are clear. The letters, white at 0.9 opacity, stand at heights 0 to 4,
      // centred on whole points in this 1x bitmap: each 5 pt wide at x + 1 to x + 5 ("x + 1.5" rounded down); heights 5
      // to 7, the gap, are clear, and so is the band under the core bar
      var r = readings(disk: 1.0)
      r.memory = 1.0; r.cpu = 1.0; r.efficiency = 1.0; r.performance = 1.0
      r.letters = true
      let image = render(bar: true, stripped: false, width: 60, readings: r, height: 26)
      let core = Int(CpuRenderReadingsWidth(true, 4, 6, 0, 0, 0, nil))
      for (i, letter) in ["D", "M", "C", "E", "P"].enumerated() {
        let x = 10 * i
        let (from, to) = (x + 1, x + 6)
        for bx in x..<(x + 8) {
          for y in 8..<24 { #expect(image.alpha(x: bx, y: y) > 200, "\(letter) bar, column \(bx), height \(y)") }
          #expect((5..<8).allSatisfy { image.alpha(x: bx, y: $0) == 0 }, "gap, column \(bx)")
          #expect(image.alpha(x: bx, y: 24) == 0 && image.alpha(x: bx, y: 25) == 0, "top, column \(bx)")
          let lit = (0..<5).filter { image.alpha(x: bx, y: $0) > 200 }
          if bx < from || bx >= to {
            #expect(lit.isEmpty, "\(letter): nothing in column \(bx)")
          } else {
            #expect(!lit.isEmpty, "\(letter): column \(bx)")
            for y in lit { #expect(image.red(x: bx, y: y) == image.alpha(x: bx, y: y), "white, column \(bx), height \(y)") }
          }
        }
      }
      // the letters differ: D's pixels are not M's
      let d: [Bool] = (1..<6).flatMap { x -> [Bool] in (0..<5).map { y in image.alpha(x: x, y: y) > 200 } }
      let m: [Bool] = (11..<16).flatMap { x -> [Bool] in (0..<5).map { y in image.alpha(x: x, y: y) > 200 } }
      #expect(d != m)
      for x in core..<60 {
        for y in 0..<8 { #expect(image.alpha(x: x, y: y) == 0, "under the core bar, column \(x), height \(y)") }
      }
    }

    @Test func lettersFitAStandardBarAtTwoX() {
      // Standard: tickWidth 3 and tickTotalWidth 4, so each reading's bar is 6 pt wide in a 7-pt slot: the battery's (not
      // read: its background, and its B) at 0 to 6 pt, Wi-Fi's at 7 to 13, disk's at 14 to 20. On a Retina display each
      // 5-pt letter is centred exactly, 0.5 pt inside its bar: B at 0.5 to 5.5, device pixels 1 to 10; W at 7.5 to 12.5,
      // pixels 15 to 24; D at 14.5 to 19.5, pixels 29 to 38. So pixels 0, 11 to 14 and 25 to 28 hold no letter, and the
      // gap, heights 5 to 8 pt (rows 10 to 15), none at all. (The app asks for no letters at the Thin width.)
      var r = readings(disk: -1)
      r.batteryShown = true
      r.battery = -1
      r.wifiShown = true
      r.wifi = 1.0
      r.letters = true
      let image = render(bar: true, stripped: false, width: 60, readings: r, scale: 2, height: 26,
                         tickWidth: 3, tickTotalWidth: 4)
      let lit = { (x: Int) in (0..<10).contains { image.alpha(x: x, y: $0) > 200 } }
      for x in [1, 10, 15, 24, 29, 38] { #expect(lit(x), "device column \(x)") }
      for x in [0, 11, 14, 25, 28, 39] { #expect(!lit(x), "device column \(x)") }
      for x in 0..<40 { #expect((10..<16).allSatisfy { image.alpha(x: x, y: $0) == 0 }, "gap, device column \(x)") }
    }

    @Test func everyLetterIsItsFiveByFiveBitmap() {
      // all nine readings shown, each bar 8 pt wide (tickWidth 4, tickTotalWidth 6) at 1x: each letter's 5 x 5 pixels at
      // heights 0 to 4 from x + 1, read top row first, are its bitmap; N has its diagonal, unlike Micro 5's 3-wide N
      let letters: [(String, [String])] = [
        ("B", ["####.", "#...#", "####.", "#...#", "####."]),
        ("W", ["#.#.#", "#.#.#", "#.#.#", "#.#.#", ".#.#."]),
        ("D", ["####.", "#...#", "#...#", "#...#", "####."]),
        ("M", ["#...#", "##.##", "#.#.#", "#...#", "#...#"]),
        ("N", ["#...#", "##..#", "#.#.#", "#..##", "#...#"]),
        ("G", [".####", "#....", "#..##", "#...#", ".###."]),
        ("C", [".####", "#....", "#....", "#....", ".####"]),
        ("E", ["#####", "#....", "####.", "#....", "#####"]),
        ("P", ["####.", "#...#", "####.", "#....", "#...."]),
      ]
      var r = readings(disk: 1.0)
      r.memory = 1.0; r.cpu = 1.0; r.efficiency = 1.0; r.performance = 1.0
      r.batteryShown = true; r.battery = 1.0
      r.wifiShown = true; r.wifi = 1.0
      r.gpuShown = true; r.gpu = 1.0; r.neuralEngine = 1
      r.letters = true
      let image = render(bar: true, stripped: false, width: 140, readings: r, height: 26)
      let shown = CpuRenderReadingsShown(&r)
      for i in 0..<9 {
        let kind = Int(CpuRenderReadingKind(shown, Int32(i)))
        let (name, rows) = letters[kind]
        let x = Int(CpuRenderReadingX(true, 4, 6, shown, 140, 0, 0, 0, nil, Int32(i))) + 1
        let drawn = (0..<5).map { row in
          String((0..<5).map { column in image.alpha(x: x + column, y: 4 - row) > 200 ? "#" : "." })
        }
        #expect(drawn == rows, "\(name) at x \(x): \(drawn)")
        for y in 0..<5 {
          #expect(image.alpha(x: x - 1, y: y) == 0 && image.alpha(x: x + 5, y: y) == 0, "\(name): clear beside it, height \(y)")
        }
      }
    }

    @Test func extraReadingsTakeTheirOwnLetters() {
      // five extra readings at the image's right edge, after the block and the core bar: a wide one lettered 5, a wide one
      // lettered 7 and not read (its letter drawn all the same, as the battery's B is), a wide one with no letter, a wide one
      // lettered X, which has no bitmap, and a narrow one lettered 5, whose slot is too tight. 5 and 7 are drawn as their 5 x 5
      // bitmaps at x + 1 (1x, 8-pt bars), white; the other three draw nothing in the band
      func extra(_ value: Double, _ letter: Character?, narrow: Bool = false) -> CpuExtraReading {
        var e = CpuExtraReading()
        e.value = value
        e.narrow = narrow
        e.letter = letter.map { CChar(bitPattern: $0.asciiValue!) } ?? 0
        return e
      }
      let extras = [extra(1.0, "5"), extra(-1.0, "7"), extra(1.0, nil), extra(1.0, "X"), extra(1.0, "5", narrow: true)]
      var r = readings(disk: 1.0)
      r.letters = true
      let width = 140
      let image = render(bar: true, stripped: false, width: width, readings: r, extra: extras, height: 26)
      let shown = CpuRenderReadingsShown(&r)
      let base = Int(CpuRenderReadingsCount(shown))
      let xs: [Int] = extras.withUnsafeBufferPointer { e in
        (0..<extras.count).map { i in
          Int(CpuRenderReadingX(true, 4, 6, shown, CGFloat(width), 0, 1, Int32(extras.count), e.baseAddress, Int32(base + i)))
        }
      }
      let digits: [(String, [String])] = [
        ("5", ["#####", "#....", "####.", "....#", "####."]),
        ("7", ["#####", "....#", "...#.", "..#..", "..#.."]),
      ]
      for (i, (name, rows)) in digits.enumerated() {
        let x = xs[i] + 1
        let drawn = (0..<5).map { row in
          String((0..<5).map { column in image.alpha(x: x + column, y: 4 - row) > 200 ? "#" : "." })
        }
        #expect(drawn == rows, "\(name) at x \(x): \(drawn)")
        for y in 0..<5 {
          #expect(image.alpha(x: x - 1, y: y) == 0 && image.alpha(x: x + 5, y: y) == 0, "\(name): clear beside it, height \(y)")
          for column in x..<(x + 5) where image.alpha(x: column, y: y) > 200 {
            #expect(image.red(x: column, y: y) == image.alpha(x: column, y: y), "\(name): white, column \(column), height \(y)")
          }
        }
      }
      // no letter, X and the narrow one: the band under them, from the third extra's bar to the image's right edge, is clear
      for x in xs[2]..<width {
        #expect((0..<5).allSatisfy { image.alpha(x: x, y: $0) == 0 }, "no letter, column \(x)")
      }
    }

    @Test func extraLettersOnlyWithTheBlockLetters() {
      // an extra reading's letter is one of the block's letters: none without them (letters false) and none when the block
      // is not drawn (extraOnly), where the image stays 16 pt and the bar, not read, is its background alone (alpha about
      // 76), so no pixel of its column reaches a letter's 0.9 opacity
      var e = CpuExtraReading()
      e.value = -1.0
      e.letter = CChar(bitPattern: Character("5").asciiValue!)
      let width = 60
      for extraOnly in [false, true] {
        var r = readings(disk: 1.0)
        r.letters = extraOnly   // without the block, asked for and still not drawn
        r.extraOnly = extraOnly
        #expect(CpuRenderImageHeight(true, false, &r) == 16)
        let image = render(bar: true, stripped: false, width: width, readings: r, extra: [e])
        let shown = CpuRenderReadingsShown(&r)
        let x = [e].withUnsafeBufferPointer { p in
          Int(CpuRenderReadingX(true, 4, 6, shown, CGFloat(width), 0, 1, 1, p.baseAddress, CpuRenderReadingsCount(shown)))
        }
        for column in x..<(x + 8) {
          #expect((0..<16).allSatisfy { image.alpha(x: column, y: $0) < 200 }, "extraOnly \(extraOnly), column \(column)")
        }
      }
    }
  }
}
