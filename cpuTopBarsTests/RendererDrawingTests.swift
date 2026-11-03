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

    // the battery alone, in a 120-wide image: its bar at x = 0 to 8, a reading's width, drawn last from DASHED_BOTTOM 2 in
    // the dashed style and whole, without the dashes. Its body is outlined one device pixel wide and capped from height 15
    // to 16; its bolt, 4.25 x 5.7 pt, stands at x = 2.125 to 6.375 and heights 5.65 to 11.35 at any charge; columns 0, 1
    // and 7 never hold it
    private func batteryReadings(_ charge: Double, charging: Bool = false, onAC: Bool = false) -> CpuReadings {
      var r = readings(disk: -1)
      r.batteryShown = true
      r.battery = charge
      r.batteryCharging = charging
      r.batteryOnAC = onAC
      return r
    }

    // the battery at 100% in each power state: on battery, charging, and on the adapter and not charging
    private static let fullStates: [(name: String, charging: Bool, onAC: Bool)] =
      [("battery", false, false), ("charging", true, true), ("adapter", false, true)]

    // the bolt's colour in a power state, as 8-bit red, green and blue (_charging_color, _discharging_color): charging
    // systemGreen at 70% on a dark menu bar and systemRed at 70% on a light one, on battery systemRed at 70%, on the
    // adapter and not charging
    // black on a dark menu bar and white on a light one
    private func batteryBoltColour(charging: Bool, onAC: Bool, light: Bool) -> [Double] {
      if charging && !light { return [34, 146, 61] }
      if charging || !onAC { return light ? [178.5, 39, 42] : [178.5, 46, 48] }
      return light ? [255, 255, 255] : [0, 0, 0]
    }

    // the bolt's coverage of the pixel at x, y: the share of the way the channel has gone from the fill's to the bolt's own,
    // opaque. The fill is read at height 3, below the bolt, in the bar's column 1, inside the outline (the full fill is the
    // same on every row). The channel is the one where the two differ most (dark: the fill's 230 against charging green's
    // 146 leaves 84 on green, but 196 on red; light: the fill's 0 against red's green 39 leaves red's 178.5), at least 178.5
    private func batteryBoltCoverage(_ image: Bitmap, scale: Int, bolt: [Double], x: Int, y: Int) -> Double {
      let fill = image.pixel(x: scale, y: 3 * scale).map { Double($0) }
      let channel = (0..<3).max { abs(bolt[$0] - fill[$0]) < abs(bolt[$1] - fill[$1]) }!
      return (Double(image.pixel(x: x, y: y)[channel]) - fill[channel]) / (bolt[channel] - fill[channel])
    }

    // the bolt's area in points at scale: its coverage summed over the bar's columns from height 2 up to 14, the body's
    // top line at 1x (the cap is height 15), above the bolt's top, 11.35
    private func batteryBoltArea(_ image: Bitmap, scale: Int, columns: Int, bolt: [Double]) -> Double {
      var area = 0.0
      for y in (2 * scale)..<(14 * scale) {
        for x in 0..<(columns * scale) { area += batteryBoltCoverage(image, scale: scale, bolt: bolt, x: x, y: y) }
      }
      return area / Double(scale * scale)
    }

    @Test(arguments: [1, 2])
    func batteryFullBoltIsSolidInEveryState(scale: Int) {
      // at 100% the fill covers the inside of the outline, and the bolt is drawn over it solid, at full opacity, in the
      // state's colour: green charging on a dark menu bar and red on a light one, red on battery, black on the adapter on a
      // dark menu bar and white on a light one. Its box at x = 2.125 to 6.375 and heights 5.65 to 11.35 (the 16 - 5.7
      // centred snaps to 5, raised 0.5, then the icon's 0.125 and 0.15), so columns 0, 1 and 7 and the rows from 2 to 4 and
      // from 12 to 14 are the body alone, pixel for pixel: the outline and the full fill are one colour. The band across its
      // middle, x = 3 to 5, is all bolt: at 2x heights 8 to 8.5, opaque in the bolt's colour; at 1x its row 8. At 2x, heights
      // 10.5 to 11, the upper stroke, which leans right as the icon's does, holds x = 4.5 to 5 and not 3 to 3.5 (a bolt
      // mirrored across would hold the second). Its area by its coverage is 8.37 pt² by its corners (the shoelace formula).
      // Nothing stands below the bar or in the gap after it
      for light in [false, true] {
        for state in Self.fullStates {
          let bolt = batteryBoltColour(charging: state.charging, onAC: state.onAC, light: light)
          let image = render(bar: true, stripped: true, width: 120,
                             readings: batteryReadings(1.0, charging: state.charging, onAC: state.onAC), light: light, scale: scale)
          let label = "scale \(scale), light \(light), \(state.name)"
          let fill = image.pixel(x: scale, y: 3 * scale)
          for x in [0, 1, 7].flatMap({ ($0 * scale)..<(($0 + 1) * scale) }) {
            for y in (2 * scale)..<(15 * scale) { #expect(image.pixel(x: x, y: y) == fill, "\(label), column \(x), height \(y)") }
          }
          for y in Array((2 * scale)..<(5 * scale)) + Array((12 * scale)..<(15 * scale)) {
            for x in 0..<(8 * scale) { #expect(image.pixel(x: x, y: y) == fill, "\(label), pixel \(x), \(y)") }
          }
          if scale == 2 {
            for x in 6..<10 {
              let p = image.pixel(x: x, y: 16)
              #expect(p[3] == 255 && (0..<3).allSatisfy { abs(Double(p[$0]) - bolt[$0]) <= 1.5 }, "\(label), band pixel \(x): \(p)")
            }
            let right = batteryBoltCoverage(image, scale: 2, bolt: bolt, x: 9, y: 21)
            let left = batteryBoltCoverage(image, scale: 2, bolt: bolt, x: 6, y: 21)
            #expect(right > 0.875 && left < 0.125, "\(label), upper stroke: \(right) at x 9, \(left) at x 6")
          } else {
            for x in [3, 4] {
              let c = batteryBoltCoverage(image, scale: 1, bolt: bolt, x: x, y: 8)
              #expect(c > 0.9, "\(label), band pixel \(x): \(c)")
            }
          }
          let area = batteryBoltArea(image, scale: scale, columns: 8, bolt: bolt)
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

    @Test(arguments: [0.0, 0.3, 0.62], [1, 2])
    func batteryBoltShowsBelowFullInTheStatesColour(charge: Double, scale: Int) {
      // the bolt is drawn at any charge, not only at 100%, over the fill or over the bars' background above it (at 0 the fill
      // is no rows high, at 0.3 its top, 3 + 3.3 snapped to 6, is above the bolt's 5.65 foot, which then stands on the
      // outline's inside). At 2x the band's pixels, x = 6 to 9 at heights 8 to 8.5, are the bolt's opaque colour in each
      // state and on either menu bar, and the hue is the state's: green dominant charging on a dark bar, red dominant
      // charging on a light one and on battery (the 70% colours: green 146 over red 34 and blue 61, red 178.5 over 39 to 48)
      for light in [false, true] {
        for state in Self.fullStates {
          let bolt = batteryBoltColour(charging: state.charging, onAC: state.onAC, light: light)
          let image = render(bar: true, stripped: true, width: 120,
                             readings: batteryReadings(charge, charging: state.charging, onAC: state.onAC), light: light, scale: scale)
          let label = "charge \(charge), scale \(scale), light \(light), \(state.name)"
          let band = scale == 2 ? [(6, 16), (7, 16), (8, 16), (9, 16)] : [(3, 8), (4, 8)]
          for (x, y) in band {
            let p = image.pixel(x: x, y: y).map { Double($0) }
            guard scale == 2 else { continue }   // at 1x the band's pixels are blended, so only the outside check below reads
            #expect(p[3] == 255 && (0..<3).allSatisfy { abs(p[$0] - bolt[$0]) <= 1.5 }, "\(label), band pixel \(x): \(p)")
            if state.charging && !light { #expect(p[1] > p[0] + 80 && p[1] > p[2] + 80, "\(label), green dominant, pixel \(x): \(p)") }
            if (state.charging && light) || (!state.charging && !state.onAC) {
              #expect(p[0] > p[1] + 120 && p[0] > p[2] + 120, "\(label), red dominant, pixel \(x): \(p)")
            }
          }
          // no bolt left of its box, inside the outline (x = 1 pt, and at 2x 1.5 and 6.5): the fill where the charge reaches
          // height 9.5, else the background alone
          let expected = charge > 0.5 ? 230 : (light ? 31 : 77)
          let columns = scale == 2 ? [2, 3, 13] : [1]
          for x in columns {
            let a = Int(image.alpha(x: x, y: 9 * scale + scale / 2))
            #expect(abs(a - expected) <= 2, "\(label), column \(x): alpha \(a), expected \(expected)")
          }
        }
      }
    }

    @Test(arguments: [1, 2])
    func batteryCapIsOnePointSolidInTheMiddleHalfAboveTheBodysTopLine(scale: Int) {
      // every battery bar's cap is its top 1 pt, height 15 (CPU_RENDER_BATTERY_CAP): solid in the text colour at 0.9 (alpha
      // about 230) over the middle half of the width, each side cut a quarter of the width on a device pixel (the Thick 8-pt
      // bar's 2 pt, the Standard 6-pt's 1.5 (2 at 1x), the Thin 4-pt's 1), the cut columns clear there. Just under the cap
      // the body's top line, one device pixel, runs the whole width, cut columns included (alpha about 230). Under that
      // line the cut columns are the outline (the left and right lines, 230) or the inside (the background, under 127).
      // At every charge, full, 62, 20 and not read, in the solid and the dashed styles, in each power state, on either menu
      // bar
      for (tick, cut) in [(CGFloat(4), 2 * scale), (3, scale == 2 ? 3 : 2), (2, scale)] {
        let width = Int(2 * tick) * scale
        for charge in [1.0, 0.62, 0.2, -1] {
          for stripped in [false, true] {
            for light in [false, true] {
              for state in Self.fullStates {
                let image = render(bar: true, stripped: stripped, width: 120,
                                   readings: batteryReadings(charge, charging: state.charging, onAC: state.onAC),
                                   light: light, scale: scale, tickWidth: tick, tickTotalWidth: tick + 2)
                let label = "scale \(scale), width \(Int(2 * tick)), charge \(charge), stripped \(stripped), light \(light), \(state.name)"
                for x in 0..<width {
                  let corner = (x < cut) || (x >= width - cut)
                  for y in (15 * scale)..<(16 * scale) {
                    let a = Int(image.alpha(x: x, y: y))
                    #expect(corner ? (a == 0) : (abs(a - 230) <= 1), "\(label), cap pixel \(x), \(y): \(a)")
                  }
                  let line = Int(image.alpha(x: x, y: (15 * scale) - 1))
                  #expect(abs(line - 230) <= 1, "\(label), top line, column \(x): \(line)")
                  let under = Int(image.alpha(x: x, y: (15 * scale) - 2))
                  let outline = (x == 0) || (x == width - 1)
                  #expect(outline ? (abs(under - 230) <= 1) : (under > 0 && under < 127 || (charge > 0.99 && abs(under - 230) <= 1)),
                          "\(label), just under the top line, column \(x): \(under)")
                }
              }
            }
          }
        }
      }
    }

    @Test(arguments: [false, true], [1, 2])
    func batteryOutlineIsOneDevicePixelInTheTextColour(light: Bool, scale: Int) {
      // not read, so nothing inside but the bars' background: the body, x = 0 to 8 and heights 2 to 15 (its top line is at
      // 14.5 to 15 at 2x, 14 to 15 at 1x), is outlined one device pixel wide, 1 px at 1x and 0.5 pt (1 px) at
      // 2x, in the text colour at 0.9 (alpha about 230, white on a dark bar and black on a light one): the bottom row, the
      // top row and the left and right columns. The pixel inside each, next to it, is the background (alpha about 77, 31 on
      // a light bar) and not the outline, and the pixels outside the outline (under the bottom row, in the gap after the
      // bar) are clear. At 2x an outline of a whole point would be 2 px wide, the pixel inside it then the text colour
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(-1), light: light, scale: scale)
      let right = 8 * scale - 1
      let bottom = 2 * scale
      let top = 15 * scale - 1
      let background = light ? 31 : 77
      func isOutline(_ x: Int, _ y: Int) -> Bool {
        let a = Int(image.alpha(x: x, y: y))
        return abs(a - 230) <= 1 && Int(image.red(x: x, y: y)) == (light ? 0 : a)
      }
      func isBackground(_ x: Int, _ y: Int) -> Bool { abs(Int(image.alpha(x: x, y: y)) - background) <= 2 }
      for x in 0...right {
        #expect(isOutline(x, bottom), "bottom row, column \(x)")
        #expect(isOutline(x, top), "top row, column \(x)")
      }
      for y in bottom...top {
        #expect(isOutline(0, y), "left column, row \(y)")
        #expect(isOutline(right, y), "right column, row \(y)")
      }
      for x in 1..<right {
        #expect(isBackground(x, bottom + 1), "inside the bottom row, column \(x)")
        #expect(isBackground(x, top - 1), "inside the top row, column \(x)")
      }
      for y in (bottom + 1)..<top {
        #expect(isBackground(1, y), "inside the left column, row \(y)")
        #expect(isBackground(right - 1, y), "inside the right column, row \(y)")
      }
      for x in 0...right { #expect(image.alpha(x: x, y: bottom - 1) == 0, "under the outline, column \(x)") }
      for y in bottom...top { #expect(image.alpha(x: right + 1, y: y) == 0, "right of the outline, row \(y)") }
    }

    @Test func batteryBoltShrinksOnAThinBar() {
      // Thin: tickWidth 2, so the battery's bar is 4 pt wide, under the bolt's 4.25: the bolt drawn at 4 / 4.25 of its size,
      // its area 8.37 x 0.886 = 7.41 pt², over the outline's sides and inside the bar (the slot's gap after it, from 4, stays
      // clear), black on the adapter's white and red on the battery's
      for onAC in [true, false] {
        let bolt = batteryBoltColour(charging: false, onAC: onAC, light: false)
        let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, onAC: onAC), scale: 2,
                           tickWidth: 2, tickTotalWidth: 3)
        let area = batteryBoltArea(image, scale: 2, columns: 4, bolt: bolt)
        #expect(abs(area - 7.41) < 0.4, "adapter \(onAC), bolt area \(area)")
        for x in 8..<10 { #expect(image.column(x).allSatisfy { $0 == 0 }, "adapter \(onAC), the gap after the thin bar, column \(x)") }
      }
    }

    @Test(arguments: [false, true], [1, 2])
    func batteryFillIsTheTextColourAtNinetyPercentInsideTheOutline(light: Bool, scale: Int) {
      // 62% on the adapter, not charging: the inside of the outline is 11 pt tall at 1x (heights 3 to 14) and 12 pt at 2x
      // (2.5 to 14.5), its fill's top that share snapped to a device pixel: 7 rows at 1x (rows 3 to 9, top at height 10) and
      // 15 px at 2x (px 5 to 19, top at height 10). Under the top the text colour at 0.9 opacity alone (alpha about 230,
      // white on a dark bar and black on a light one), not over the bars' background, which made it brighter than the
      // system's icons; above it the background alone (the bars' grey, 0.8 at 0.3 on a dark bar, alpha about 77 and red
      // about 61, and 0.2 at 0.12 on a light one, about 31 and 6) up to the outline's top line. Read in the columns inside
      // the outline and clear of the bolt (x = 1 at 1x, 1 to 3 at 2x)
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.62, onAC: true), light: light, scale: scale)
      let top = 10 * scale   // the first row above the fill, in device pixels
      for x in 1..<(2 * scale) {
        for y in (3 * scale)..<top {
          let a = Int(image.alpha(x: x, y: y))
          #expect(abs(a - 230) <= 1 && Int(image.red(x: x, y: y)) == (light ? 0 : a), "light \(light), fill, column \(x), height \(y): alpha \(a)")
        }
        for y in top..<(15 * scale - 1) {
          let a = Int(image.alpha(x: x, y: y))
          let r = Int(image.red(x: x, y: y))
          #expect(abs(a - (light ? 31 : 77)) <= 2 && abs(r - (light ? 6 : 61)) <= 2, "light \(light), background, column \(x), height \(y): alpha \(a), red \(r)")
        }
      }
    }

    @Test(arguments: [false, true], [1, 2])
    func batteryChargingDrawsTheBodyAndFillAsOnBatteryOrTheAdapter(light: Bool, scale: Int) {
      // 50% in the three power states: the outline, the cap, the fill and the background above it are the same pixel for
      // pixel, charging or not (while charging, the fill was once lighter under the text colour above it, at alpha about
      // 199). Everything but the bolt's box, x = 2.125 to 6.375 and heights 5.65 to 11.35 (columns 2 to 6 and rows 5 to 11 at
      // 1x, whole pixels around it), is compared across the whole image; the bolt's own pixels differ by the state's colour
      let charging = render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.5, charging: true, onAC: true), light: light, scale: scale)
      let adapter = render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.5, onAC: true), light: light, scale: scale)
      let battery = render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.5), light: light, scale: scale)
      for (name, other) in [("adapter", adapter), ("battery", battery)] {
        for y in 0..<(16 * scale) {
          for x in 0..<(120 * scale) {
            if (2 * scale..<(7 * scale)).contains(x) && (5 * scale..<(12 * scale)).contains(y) { continue }
            #expect(charging.pixel(x: x, y: y) == other.pixel(x: x, y: y), "charging against \(name), pixel \(x), \(y)")
          }
        }
        // the bolt's band, at 1x row 8 and at 2x row 16, x = 3 to 4: charging colours it differently from the adapter's, and
        // from the battery's on a dark bar (on a light one both are the dark red)
        if name == "adapter" || !light { #expect(charging.pixel(x: 4 * scale - 1, y: 8 * scale) != other.pixel(x: 4 * scale - 1, y: 8 * scale), "bolt, charging against \(name)") }
      }
    }

    @Test(arguments: [false, true], [1, 2])
    func batteryFillAndWifiSegmentsSitOnWholePixels(light: Bool, scale: Int) {
      // at 1x and 2x every edge of the battery's outline and fill and of the Wi-Fi segments falls on a device pixel, so
      // no pixel of the battery's or Wi-Fi's bar outside the bolt's box is a blend: each alpha is one the bar can
      // produce, within 2: clear (the cap's cuts), Wi-Fi's background 77 and fill 230, the battery's outline and fill
      // 230 and its background 77 (31 on a light bar). A half-covered pixel would read between them. Charges 0.5 (the
      // fill's top at 3 + 5.5, snapped to 9 at 1x; at 2x 2.5 + 6, already on a device pixel), 0.62 and 0.2 (tops of 3 +
      // 6.82 and 3 + 2.2, snapped to device pixels; left unsnapped, their top rows would blend), in each power state.
      // Columns 0, 1 and 7 of the battery's bar (the bolt's box is x = 2.125 to 6.375) and Wi-Fi's bar, x = 10 to 18
      for charge in [0.5, 0.62, 0.2] {
        for state in Self.fullStates {
          let allowed = [0, 77, 230, 31]
          var r = batteryReadings(charge, charging: state.charging, onAC: state.onAC)
          r.wifiShown = true
          r.wifi = 0.5
          for stripped in [false, true] {
            let image = render(bar: true, stripped: stripped, width: 120, readings: r, light: light, scale: scale)
            let columns = Array(0..<(2 * scale)) + Array((7 * scale)..<(8 * scale)) + Array((10 * scale)..<(18 * scale))
            for x in columns {
              for y in 0..<(16 * scale) {
                let a = Int(image.alpha(x: x, y: y))
                #expect(allowed.contains { abs($0 - a) <= 2 }, "scale \(scale), light \(light), charge \(charge), \(state.name), stripped \(stripped), pixel \(x), \(y): \(a)")
              }
            }
          }
        }
      }
    }

    @Test func batteryNotReadDrawsOnlyTheOutlineCapAndBackground() {
      // not read, 1x, the dashed style: nothing under height 2; the outline's bottom row (height 2) and top row (height 14)
      // across the bar and its sides, x = 0 and 7, between them, in the text colour at 0.9 (alpha about 230); inside it the
      // bars' background alone (alpha about 77), heights 3 to 13, x = 1 to 6, with no fill and no bolt; and the cap, height
      // 15, solid (230) at x = 2 to 5 and clear at x = 0, 1, 6 and 7
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(-1))
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for y in [2, 14] { #expect(abs(Int(column[y]) - 230) <= 1, "outline row, column \(x), height \(y): \(column[y])") }
        for y in 3..<14 {
          let side = (x == 0) || (x == 7)
          #expect(side ? (abs(Int(column[y]) - 230) <= 1) : (abs(Int(column[y]) - 77) <= 2), "column \(x), height \(y): \(column[y])")
        }
        let corner = (x < 2) || (x >= 6)
        #expect(corner ? (column[15] == 0) : (abs(Int(column[15]) - 230) <= 1), "cap, column \(x): \(column[15])")
      }
      // no bolt: every pixel of the bar's columns 2 to 5 at height 8 is the background alone, alpha about 77
      for x in 2..<6 { #expect(abs(Int(image.alpha(x: x, y: 8)) - 77) <= 2, "no bolt, column \(x)") }
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
      // heights 0 to 4 from x + 1, read top row first, are its bitmap; N has its diagonal
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
