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

#ifndef CpuRenderer_h
#define CpuRenderer_h

#include <stdio.h>
#include <CoreGraphics/CoreGraphics.h>

#include "CpuSampler.h"

__BEGIN_DECLS

enum Theme
{
  THEME_YELLOW = 0,
  THEME_GREEN,
  THEME_BLUE,
};

// the readings block at the left of the image, bars drawn as the core graph's but twice as wide (in Dot style dots as the
// graph's), then a clear gap before the core graph. The block's readings, from the left: the battery (CPU_RENDER_SHOWN_BATTERY:
// a bar with its charge written over it), Wi-Fi's signal (CPU_RENDER_SHOWN_WIFI), disk, memory, then a clear gap, then the Neural
// Engine's and the GPU's bar (CPU_RENDER_SHOWN_GPU, both), CPU, the E-cores' CPU and the P-cores' CPU. Which of the optional
// ones are drawn is a mask, shown, of CPU_RENDER_SHOWN_* bits, and each reading has a kind, CPU_RENDER_KIND_*; its index is
// the number of shown readings of earlier kinds (CpuRenderReadingIndex, CpuRenderReadingKind), each index one slot. The gap
// after memory is a group gap, 4 pt
// (5 in Dot style, after the last dot's overhang), and is there only when shown is not 0, so with none of the optional
// readings the block is as it was before them. When the graph splits into the E-cores' bars and then the P-cores' (efficiencyBars
// above 0, the count of the graph's bars that are E-cores', CpuRenderEfficiencyBars), the E-cores' and the P-cores' readings
// each head their own cores instead: the readings before them, the gap, the E-cores' reading and their bars, a group gap, the
// P-cores' reading and their bars; the image is a group gap wider (in Dot style 1 pt more, the last E-core dot's overhang). Any
// number of extra readings that a build adds are drawn in the same way at the right of the
// image, after the core graph and a gap as wide. The block's readings may be left out (extraOnly): the core graph then starts at x = 0, with the extra readings, when
// there are any, at the right as before. The extra readings fall into groups: a reading that starts a group is drawn
// after a further clear gap, CPU_RENDER_GROUP_GAP wide, and the first reading is always the first of its group. An
// extra reading may also carry a mark, a 1-pt line across its bar at that height, an alert, which draws its bar whole,
// without the dashes, a pace, how much of the bar's period has passed, and a tint, which paints its bar as a bar at
// another load would be, its fill opaque with colour, its height unchanged; with colour, the part of a bar above its
// pace, and all of an alert bar with no pace, is painted in its ramp's hottest colour. With none of the optional readings
// the block holds five (CPU_RENDER_READINGS_COUNT): disk, memory, CPU, the E-cores' and the P-cores' readings, at indices 0 to 4;
// with all of them nine (CPU_RENDER_READINGS_MAX)
#define CPU_RENDER_READINGS_COUNT (5) // the readings with none of the optional ones, and the first extra reading's index then
#define CPU_RENDER_READINGS_MAX (9) // with all of them
#define CPU_RENDER_READING_EFFICIENCY (3) // the E-cores' CPU's index among the readings, with none of the optional ones
#define CPU_RENDER_READING_PERFORMANCE (4) // the P-cores' CPU's, with none of the optional ones
// the optional readings, as bits of the mask shown: the Neural Engine's bar and the GPU's together, Wi-Fi's, the battery's
#define CPU_RENDER_SHOWN_GPU (1u)
#define CPU_RENDER_SHOWN_WIFI (2u)
#define CPU_RENDER_SHOWN_BATTERY (4u)
// a reading's kind, in the order the readings are drawn
#define CPU_RENDER_KIND_BATTERY (0)
#define CPU_RENDER_KIND_WIFI (1)
#define CPU_RENDER_KIND_DISK (2)
#define CPU_RENDER_KIND_MEMORY (3)
#define CPU_RENDER_KIND_NEURAL_ENGINE (4)
#define CPU_RENDER_KIND_GPU (5)
#define CPU_RENDER_KIND_CPU (6)
#define CPU_RENDER_KIND_EFFICIENCY (7)
#define CPU_RENDER_KIND_PERFORMANCE (8)
// the font the battery's number is drawn in, by its PostScript name: Micro 5 (SIL Open Font License 1.1), a pixel font made
// for tiny sizes, whose digits are 5 pixels tall. The app registers it from its Resources at launch; without it the number
// is not drawn. At CPU_RENDER_BATTERY_FONT_SIZE a font pixel is 1 pt (1650 units per em, 150 per pixel, measured with
// CoreText), so the digits are 5 pt tall and 3 pt wide ("1" 2 pt)
#define CPU_RENDER_BATTERY_FONT "Micro5-Regular"
#define CPU_RENDER_BATTERY_FONT_SIZE (11.0)
// the battery bar's styles (CpuReadings batteryStyle), each over the bar's whole height in bar style, its fill on a device
// pixel; an unknown style draws as CPU_RENDER_BATTERY_LIGHT_TINT, the default, which a zeroed struct draws.
// LIGHT_TINT: the fill's colour mixed 55% toward white, opaque (on the adapter the bars' grey at 0.55 opacity); the digits
// cut out, so the menu bar shows through them, except on a light menu bar with a coloured fill (charging or on battery),
// where they are black at 0.9 opacity.
// GREY and LIGHT_GREY: the bars' grey at 0.60 and 0.75 opacity; the digits cut out.
// TINT: the fill's colour at 0.38 opacity (0.3 on the adapter); the digits cut out of the fill, and above it in the fill's
// colour mixed 60% toward white (45% toward black on a light menu bar), on the adapter the text colour at 0.9 opacity
#define CPU_RENDER_BATTERY_LIGHT_TINT (0)
#define CPU_RENDER_BATTERY_GREY (1)
#define CPU_RENDER_BATTERY_LIGHT_GREY (2)
#define CPU_RENDER_BATTERY_TINT (3)
// the band under the bars that holds the block's letters (CpuReadings letters): the letters, 5 x 5-pt pixel bitmaps in
// the style of CPU_RENDER_BATTERY_FONT, and a 3-pt gap above them, up to the bars' foot (in the dashed style the bars' clear 2-pt foot
// is taken off, so the gap stays 3 pt); the image is then taller (CpuRenderImageHeight) by the band and by
// CPU_RENDER_LETTERS_TOP, clear above the bars, which balances the gap's second and third points so that the status item,
// which centres the image, draws the bars where a 1-pt gap had them and the letters 2 pt lower
#define CPU_RENDER_LETTERS_HEIGHT (8.0)
#define CPU_RENDER_LETTERS_TOP (2.0)
// the Wi-Fi bar's segments, each 2 pt tall
#define CPU_RENDER_WIFI_SEGMENTS (5)
#define CPU_RENDER_READINGS_GAP (4.0)
#define CPU_RENDER_EXTRA_GAP CPU_RENDER_READINGS_GAP
#define CPU_RENDER_GROUP_GAP CPU_RENDER_EXTRA_GAP
#define CPU_RENDER_THIN_FROM (24) // core bars past this many are drawn thinner, so the core graph keeps about this many slots' width

// one extra reading, as the bars of the extra block are drawn from left to right
struct CpuExtraReading
{
  // 0..1; below 0, not read: only the bar's background is drawn, and in Dot style nothing
  double value;
  // a share of its bar's height (from where a dashed bar starts): a 1-pt line across the bar at that height, white on a
  // dark menu bar and black on a light one, over the dashes; none in Dot style, and drawn only above 0, so a zeroed
  // struct has none
  double mark;
  // a share of its bar's height, 0..1 (above 1 as 1), as mark: how much of its period has passed. Above 0, in bar style
  // with colour: a bar above it is painted in two, up to pace in its ramp's coolest colour and from pace up in its
  // ramp's hottest colour; a bar below it has the stretch from its top up to pace painted dim in its own colour.
  // Nothing in Dot style or without colour, and 0 or below (NaN too) is the default, so a zeroed struct has none
  double pace;
  // above 0: in bar style the bar is painted as a bar at that load (0..1, above 1 as 1) would be, in its ramp colour, its
  // fill opaque with colour and at that load's opacity without, its height still value's; 0 or below (NaN too) is the
  // default: painted by its value. Nothing changes in Dot style or for a bar not read, so a zeroed struct has none
  double tint;
  // true: this reading is painted in colorRed, colorGreen and colorBlue (sRGB, each 0..1) in place of its ramp colour,
  // tint and pace, and of an alert's hottest colour: in bar style its fill opaque and its background, drawn also while
  // it is not read, at the dim opacity of the pace's stretch (0.25 light, 0.35 dark); in Dot style a read reading's
  // dot. Only with colour; false is the default, so a zeroed struct has none
  bool hasColor;
  double colorRed, colorGreen, colorBlue;
  // true: this reading's dashed bar is drawn whole, without the dashes, in its own colour (its tint's when it has one);
  // in bar style with colour, a bar with no pace above 0 and no colour of its own (hasColor) is painted all in its
  // ramp's hottest colour instead, dashed or solid (with a pace, the pace paints it, and a bar at or below its pace keeps its
  // colour); nothing changes in Dot style; false is the default
  bool alert;
  // true: this reading starts a new group, after a clear gap; false is the default, and the first reading's flag is
  // ignored
  bool groupStart;
  // true: this reading is drawn as a core bar, as wide as the tickWidth given and in a core bar's slot (tickTotalWidth);
  // false is the default: twice as wide, in the readings' slot. Dot style does not change
  bool narrow;
  // the letter drawn under this reading's bar with the block's letters (CpuReadings letters), in the same 5 x 5 pixel
  // style: one of B W D M N G C E P 5 7. Only under a wide bar (not narrow); any other value, 0 the default, draws none,
  // so a zeroed struct has none
  char letter;
} typedef CpuExtraReading;

// each 0..1; below 0, not read: only the bar's background is drawn, and in Dot style nothing
struct CpuReadings
{
  double cpu;
  double memory;
  double disk;
  double efficiency; // the E-cores' CPU
  double performance; // the P-cores' CPU
  int extraCount; // 0 or more (below 0 counts as 0), the first extraCount of extra drawn
  // extraCount entries; NULL: every extra reading is not read, with no mark, no alert and one group
  const CpuExtraReading* extra;
  // true: the block's readings are not drawn, only the extra readings (false is the default)
  bool extraOnly;
  // above 0: the graph splits after this many bars, the E-cores', and the E-cores' and P-cores' readings head their own
  // bars (CpuRenderEfficiencyBars, for the granularity drawn); 0 is the default: the readings in one block. Ignored
  // when the block is not drawn
  int efficiencyBars;
  // the GPU's busy share, 0..1; below 0, not read, as the five. Drawn only with gpuShown
  double gpu;
  // the Neural Engine's power: 1 on, filled in the menu bar's text colour (white on a dark menu bar, black on a light
  // one) at 0.9 opacity; 0 off; below 0, not read: nothing in its slot. In bar style a wide bar drawn whole, without the
  // dashes: on, solid; off, only the bars' background. In Dot style a dot: on, filled; off, a 1-pt ring at the bars'
  // background opacity. Drawn only with gpuShown, never in the ramp's colours
  int neuralEngine;
  // true: neuralEngineBusy, not neuralEngine, sets the Neural Engine's reading, drawn as the GPU's is: a wide bar filled
  // to neuralEngineBusy (0..1; below 0, not read: only the bar's background, and in Dot style nothing), dashed in the
  // dashed style and in the ramp's colours with colour, or a dot. false is the default, so a zeroed struct draws
  // neuralEngine as before
  bool neuralEngineByShare;
  double neuralEngineBusy;
  // true: the Neural Engine's bar and the GPU's are drawn after the gap that follows memory, before CPU; false is the
  // default, so a zeroed struct draws the five as before. Ignored when the block is not drawn (extraOnly)
  bool gpuShown;
  // true: the battery's reading, a bar as wide as the readings' with its charge written over it, is drawn first, left of
  // everything; false is the default. Ignored when the block is not drawn
  bool batteryShown;
  // the battery's charge, 0..1 (above 1 as 1); below 0, not read: the bars' background only, no number, and in Dot style
  // nothing. In bar style a wide bar, whole, without the dashes: its background in batteryStyle and a fill of that share
  // of its height, its top on a device pixel, and over it the charge in whole percent in CPU_RENDER_BATTERY_FONT (at 100
  // a lightning bolt in its place, solid, black on a light fill and white on a dark one, in every style), its digits upright
  // and stacked from the top on device pixels, drawn as batteryStyle says; its top 1 pt cut away but for the middle half, a
  // battery's cap, read or not. In Dot style a dot filled while the charge is 0.005 or more, with no number. Drawn only with
  // batteryShown
  double battery;
  // the power state, which colours the fill, or in Dot style the dot: charging, systemGreen at full opacity; else on the
  // adapter (batteryOnAC: charged, or held below full, and not charging), the menu bar's text colour at 0.9 opacity, white
  // on a dark menu bar and black on a light one; else on battery, systemRed at full opacity, as a zeroed struct draws it.
  // Drawn only with batteryShown
  bool batteryCharging;
  bool batteryOnAC;
  // the battery bar's style in bar style, a CPU_RENDER_BATTERY_* value; Dot style does not change
  int batteryStyle;
  // true: Wi-Fi's reading, a bar as wide as the readings' (a dot in Dot style), is drawn after the battery's, before disk;
  // false is the default. Ignored when the block is not drawn
  bool wifiShown;
  // Wi-Fi's signal as a fill, 0..1 (above 1 as 1); below 0, Wi-Fi off, not connected or not readable. In bar style
  // CPU_RENDER_WIFI_SEGMENTS segments from the bar's bottom to its top, whole, without the dashes, evenly spaced with clear
  // gaps, each segment's foot on a device pixel: ceil(fill * CPU_RENDER_WIFI_SEGMENTS) of them lit from the bottom, at least one while the fill is 0 or more, in
  // the menu bar's text colour at 0.9 opacity alone (no background under them), never in the ramp's colours; the rest, and all of
  // them below 0, the background alone. In Dot style a dot filled while the fill is 0.005 or more, else a 1-pt ring at the
  // bars' background opacity. Drawn only with wifiShown
  double wifi;
  // true: in bar style, a letter under each of the block's wide bars, B the battery's, W Wi-Fi's, D disk, M memory, N the
  // Neural Engine's, G the GPU's, C CPU, E the E-cores' and P the P-cores', and under each wide extra reading its own
  // letter (CpuExtraReading letter), in the band at the image's bottom
  // (CPU_RENDER_LETTERS_HEIGHT), and everything else drawn above it, the bars 3 pt over the letters in either style; the
  // image must be CpuRenderImageHeight tall. false is the default, so a zeroed struct draws the 16-pt image as before.
  // Ignored when the block is not drawn and in Dot style
  bool letters;
} typedef CpuReadings;

void CpuRenderInit(void);
// the mask of the optional readings that readings draws: 0 for NULL or extraOnly, else CPU_RENDER_SHOWN_GPU if gpuShown,
// CPU_RENDER_SHOWN_WIFI if wifiShown and CPU_RENDER_SHOWN_BATTERY if batteryShown
unsigned CpuRenderReadingsShown(const CpuReadings* readings);
// the image's height for what readings draws, in bar style or not, dashed (stripped) or solid: 16 pt; with the block's
// letters (CpuReadings letters) CPU_RENDER_LETTERS_HEIGHT and CPU_RENDER_LETTERS_TOP more, less the dashed style's clear
// 2-pt foot: 26 pt solid, 24 dashed
CGFloat CpuRenderImageHeight(bool bar, bool stripped, const CpuReadings* readings);
// the readings block's count with the optional readings shown (a CPU_RENDER_SHOWN_* mask, other bits ignored): 5, plus 2
// for the GPU's, 1 for Wi-Fi's and 1 for the battery's, at most CPU_RENDER_READINGS_MAX; the first extra reading's index is
// the count
int CpuRenderReadingsCount(unsigned shown);
// the index of the reading of kind (CPU_RENDER_KIND_*) among the readings with shown, the number of shown readings of
// earlier kinds; -1 when that reading is not shown or kind is not one
int CpuRenderReadingIndex(unsigned shown, int kind);
// the kind of the reading at index with shown, the inverse of CpuRenderReadingIndex; -1 for an extra reading or an index
// out of range
int CpuRenderReadingKind(unsigned shown, int index);
// the E-cores' and the P-cores' readings' indices, the block's last two: 3 and 4 with no optional reading shown
int CpuRenderReadingEfficiency(unsigned shown);
int CpuRenderReadingPerformance(unsigned shown);
// how many of the core graph's bars at granularity are the E-cores', when the graph splits into them and then the
// P-cores': kinds (countLogical of 'E' or 'P', CpuSamplerGetKinds) all E-cores' first and then all P-cores', both
// present, and each bar's CPUs of one kind; 0 when it does not split (one bar, kinds NULL, any other order)
int CpuRenderEfficiencyBars(int granularity, natural_t countLogical, const char* kinds);
// the width the readings block and its gap add to the image, and the extra readings' block with its gap, for the core
// graph's style, bar width and tick spacing, with the optional readings in the mask shown, the split after
// efficiencyBars bars (0: none), with extraCount extra readings, extra giving their groups (NULL: one group)
CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, int efficiencyBars, int extraCount, const CpuExtraReading* extra);
// the width the extra readings' block with its gap adds to the image, with extraCount extra readings and their groups;
// 0 with none
CGFloat CpuRenderExtraWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra);
// the slot width of reading index in an image with extraCount extra readings: the readings' slot for the block's
// readings (CpuRenderReadingsCount(shown) of them), an extra reading's own for the others, which is a full core bar's slot when it is
// narrow (extra NULL: none is)
CGFloat CpuRenderReadingSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, int extraCount, const CpuExtraReading* extra, int index);
// the x step from one of the block's readings, or one extra reading that is not narrow, to the next, a reading's slot
// (the readings are placed by CpuRenderReadingX: a group gap follows memory when any optional
// reading is shown; the extra readings, right of the core graph, the same step apart; a narrow extra reading's step is a
// full core bar's slot, a group's gap is added where a group starts)
CGFloat CpuRenderReadingsSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth);
// where reading index starts in an image imageWidth wide with extraCount extra readings and their groups: the block's
// readings (CpuRenderReadingsCount(shown)) the slots of the readings before index from the left, and the gap after memory
// for a reading after it, the first at 0 (split after efficiencyBars bars: the E-cores' before their bars, the P-cores'
// before theirs), the extra ones (index CpuRenderReadingsCount(shown) on) after the
// core graph and its gap, each group's gap added where a group starts; an index past the last extra reading gives the
// last one's x
CGFloat CpuRenderReadingX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, CGFloat imageWidth, int efficiencyBars, natural_t cores, int extraCount, const CpuExtraReading* extra, int index);
// where the core graph starts and ends in an image imageWidth wide: after the readings block and its gap when the five
// readings are drawn (readings; with the optional readings in the mask shown), else at x = 0; split after efficiencyBars bars, from
// the first E-core bar, past the P-cores' reading, to the last P-core bar; before the extra readings' block (extraCount
// and extra, read with or without the five)
void CpuRenderGraphSpan(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, bool readings, unsigned shown, int efficiencyBars, int extraCount, const CpuExtraReading* extra, CGFloat* start, CGFloat* end);
// a core bar's slot with count core bars: tickTotalWidth up to CPU_RENDER_THIN_FROM bars; past it, the largest whole
// number of points that keeps the graph within CPU_RENDER_THIN_FROM slots, but never less than a 1-pt bar and the full
// slot's gap (tickTotalWidth - tickWidth), so a graph of many cores grows past that width. Dots keep theirs
CGFloat CpuRenderCoreSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, natural_t count);
// the width a core bar is drawn with count core bars: tickWidth in a full slot, else its slot less the same gap (at
// least 1 pt). The readings keep tickWidth and tickTotalWidth whatever the count
CGFloat CpuRenderCoreWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, natural_t count);
// where the core graph's bar index of count is drawn, the graph starting at start (CpuRenderGraphSpan): a core bar's
// slot per bar, the P-cores' bars (index efficiencyBars on, when above 0) after the split's gap and the P-cores' reading
CGFloat CpuRenderCoreX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat start, int efficiencyBars, int count, int index);
// the core graph's bar whose slot (CpuRenderCoreX, a core bar's slot wide) holds x, of count bars; the last bar's
// reaches on past its slot (Dot style's overhang, the clear space right of the graph); -1 left of the first bar, and
// between the last E-core bar's slot and the first P-core bar (the split's gap and the P-cores' reading)
int CpuRenderCoreAtX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat start, int efficiencyBars, int count, CGFloat x);
// readings NULL: no block, the core graph starts at x = 0; else it starts after the block and the gap, unless
// readings->extraOnly leaves the five out
void CpuRender(CpuSummaryInfo* cpu_info, CGContextRef ctx, bool light, int granularity, bool bar, bool stripped, bool colored, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int theme, const CpuReadings* readings);
void CpuRenderDemo(CGContextRef ctx, CGFloat width, CGFloat height, int tint);

__END_DECLS

#endif /* CpuRenderer_h */
