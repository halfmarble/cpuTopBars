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

#import <AppKit/AppKit.h>

#include "CpuRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// Rows that a build adds to the status menu, above Quit, and to the readings panel beside it, after the readings. A
// class that adopts MenuRows registers itself with MenuRowsRegister from its +load; the app makes one instance of
// each when it builds the menu and adds its rows, then a separator, and its panel rows, any of them a heading, as a
// section of their own. It may also add views to the process inspector's header, bars to the menu bar, at the right of
// the core graph, with a mark, a tint, an alert, a group and a width per bar, and a group of rows to the Settings
// window and a section to the help window.
// Everything here runs on the main thread, +load aside.
@protocol MenuRows <NSObject>
// the rows, their titles set in attributes, the menu's own text attributes
- (NSArray<NSMenuItem*>*)menuItemsWithAttributes:(NSDictionary<NSAttributedStringKey, id>*)attributes;
@optional
// as the menu opens, frozen or not
- (void)menuWillOpen;
// while the menu is open, each time the process sampler runs (its timer, the menu opening, unfreezing, resuming
// after a pause), frozen or not; while frozen it takes no sample
- (void)menuTick;
- (void)menuDidClose;
// the panel's rows, each a title and its value (@[@"Title:", @"value"]); read whenever the panel's values are set: as
// the menu opens and then every second while it is open, frozen or not. The number may change from one read to the
// next, none included; the panel's height follows
- (NSArray<NSArray<NSString*>*>*)panelRows;
// each panel row's heading, in the same order as panelRows: an entry whose boolValue is YES draws that row's title as
// the menu's own title is drawn, in its font and colour, centred across the panel, and no value; NO, an entry that is
// not a number or a missing entry: a plain row. Read with panelRows
- (NSArray<NSNumber*>*)panelHeadings;
// views for the process inspector's header, made once, the first time the inspector shows a process: laid out left to
// right in this order on a line of their own below the header's text, each centred on that line, which is as tall as
// the tallest; the last view, and the text above, end 20 pt short of the header's right edge, the margin the icon keeps
// at its left. A view taller than about 35 pt reaches the tabs below
- (NSArray<NSView*>*)inspectorViews;
// each time the inspector shows a process, before its views are laid out: its pid and name, exited when its process has
// exited or its pid now belongs to another process, since the last sample or, for a frozen row, since the freeze. A view
// may change its width here
- (void)inspectorShowsPid:(pid_t)pid name:(NSString*)name exited:(BOOL)exited;
// bars for the menu bar, drawn right of the core graph in the CPU bar's style, each 0..1 (below 0: not read, only its
// background in bar style, nothing in Dot style); read at each tick of the graph, menu open or not, the app's own bars
// shown or not. All classes' bars together, with no limit; the status item widens with each bar, and macOS hides a
// status item that does not fit the menu bar. It widens or narrows when their number changes
- (NSArray<NSNumber*>*)barReadings;
// each bar's text, in the same order, shown below it while the pointer rests on it ("Title: value"); read when the
// label shows and every 0.25 s while it is shown. A missing or empty text shows no label
- (NSArray<NSString*>*)barLabels;
// the class's group in the Settings window, asked once, right after the app has made the menus, before the window is
// first shown: its heading, its rows and the buttons below it. The groups follow the app's "Menu bar" group, in the
// order the classes registered, each under its heading (none when settingsTitle is missing or empty). Each entry of
// settingsRows is one row, @[title, control]: the title (an NSString) on the left in the app's label font, cut at the
// control when too long, the control (an NSView) at the right, centred on the row. The class owns each control: its
// target, action, state and its own defaults key; the app only places it, and is not told of a click. The app names the
// control by its title for VoiceOver unless the control has an accessibilityLabel of its own, and draws the title dimmed
// while an NSControl is disabled (its enabled, set by the class, is followed as it changes). Make on/off
// controls with MenuRowsSettingsSwitch and choices with MenuRowsSettingsChoice, so that they look like the app's own.
// An entry that is not such a pair is skipped; with no row, there is no group and no buttons. settingsButtons are laid
// out left to right below the group, the last at its right edge. A control that hides its class's bars makes
// barReadings (and barLabels) return none while it is off, and the status item follows at the next tick of the graph
- (NSString*)settingsTitle;
- (NSArray<NSArray*>*)settingsRows;
- (NSArray<NSButton*>*)settingsButtons;
// the class's section in the help window, asked once, when the window is first made: its heading and its paragraphs.
// The section follows the app's "Menu bar" section, in the order the classes registered, under its heading. Each entry
// of helpRows is one paragraph, a row of a card, wrapped to the window's width: a non-empty NSString, or a pair, an
// NSArray of the text and an NSArray of NSViews, drawings that the window lays out under the text, in order, left to
// right and wrapping (make one with MenuRowsHelpExample; an entry of the array that is not an NSView is skipped, and an
// empty array is text only). An entry that is neither is skipped; with no title (missing or empty) or no such entry,
// there is no section
- (NSString*)helpTitle;
- (NSArray*)helpRows;
// each bar's mark, in the same order as barReadings: a share of the bar's height, 0..1 (above 1 at the top row; near 0
// on its lowest row), shown by a 1-pt line across the bar at that height, drawn over the dashes, white on a dark menu
// bar and black on a light one; 0 or below, an entry that is not a number, a missing entry or a bar not read: none.
// Nothing in Dot style. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barMarks;
// each bar's alert, in the same order as barReadings: an entry whose boolValue is YES draws a dashed bar whole, without
// the dashes, in its own colour (its tint's when it has one; a solid bar is not redrawn, and a dot does not change);
// with colour, a bar with no pace (barPaces) and no colour of its own (barColors) is painted all in its ramp's hottest
// colour instead, dashed or solid; NO, an entry that is not a number, a missing entry or a bar not read: none. Read with
// barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barAlerts;
// each bar's tint, in the same order as barReadings: above 0, the load 0..1 (above 1 as 1) whose colour the bar is
// painted in, its fill opaque with colour and at that load's opacity without, its height still its reading; 0 or
// below, an entry that is not a number, a missing entry or a bar not read: painted by its reading. Nothing in Dot
// style. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barTints;
// each bar's colour, in the same order as barReadings: an NSColor paints the bar in that colour in place of its ramp
// colour, tint and pace, and of an alert's hottest colour: its fill opaque, its background, drawn also while the bar is not read,
// in that colour at a dim opacity (0.25 on a light menu bar, 0.35 on a dark one); in Dot style a read bar's dot in that
// colour. Nothing changes without colour; an entry that is not an NSColor or a missing entry: none. Read with
// barReadings, at each tick of the graph
- (NSArray<NSColor*>*)barColors;
// each bar's pace, in the same order as barReadings: above 0, how much of the bar's period has passed, a share of its
// height 0..1 (above 1 as 1); a bar above it is painted up to it in its ramp's coolest colour and above it in its
// ramp's hottest colour, a bar below it gets the stretch up to it painted dim; 0 or below, an entry that is not a
// number, a missing entry or a bar not read: none. Nothing in Dot style or without colour. Read with barReadings, at
// each tick of the graph
- (NSArray<NSNumber*>*)barPaces;
// each bar's group, in the same order as barReadings: an entry whose boolValue is YES starts a new group, drawn after a
// clear gap; a class's first bar starts one whenever bars of another class come before it. NO, an entry that is not a
// number or a missing entry: the bar continues the group before it. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barGroupStarts;
// each bar's width, in the same order as barReadings: an entry whose boolValue is YES draws the bar as wide as a core bar,
// in a core bar's slot, at their full width when core bars are thinner (past CPU_RENDER_THIN_FROM cores; Dot style does
// not change); NO, an entry that is not a number or a missing entry: twice as wide,
// as the app's own readings. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barNarrows;
// each bar's letter, in the same order as barReadings: an NSString of one character, one of B W D M N G C E P 5 7, drawn
// under a wide bar (not barNarrows) in the band of the app's own letters, while Settings' "Show letters under the bars"
// is on and the app's own bars are shown; any other entry, a missing entry or a narrow bar: none. Read with barReadings,
// at each tick of the graph
- (NSArray<NSString*>*)barLetters;
@end

__BEGIN_DECLS

void MenuRowsRegister(Class<MenuRows> rowsClass);

// a row that a click leaves open: it sends action to target on mouse-up (and on VoiceOver's press), drawn as a
// native row; disabled, it is grey and a click does nothing
NSMenuItem* MenuRowsStayOpenItem(NSString* title, SEL action, id target, NSDictionary<NSAttributedStringKey, id>* attributes);

// a Settings row's on/off control, as the app's own: a mini switch, on or off, that sends action to target when it is
// clicked
NSSwitch* MenuRowsSettingsSwitch(BOOL on, SEL action, id target);

// a Settings row's choice, as the app's own: a segmented control with one segment per label, each segmentWidth pt
// wide, the segment at selected chosen (none when out of range), that sends action to target when a segment is chosen
NSSegmentedControl* MenuRowsSettingsChoice(NSArray<NSString*>* labels, CGFloat segmentWidth, NSInteger selected, SEL action, id target);

// pt from the sides of a Settings group to its rows' titles and controls, and to the lines between its rows
#define MENU_ROWS_SETTINGS_INSET    (12.0)

// a heading above a group, as the app's own in Settings: 13 pt semibold, in the label colour
NSTextField* MenuRowsSettingsHeading(NSString* title);

// a card drawn as the app's own Settings groups, for a window of the class's own: a rounded fill and border, the rows
// stacked top to bottom at its full width, and a 1-pt line between two rows, MENU_ROWS_SETTINGS_INSET in from its
// sides. Each row is the caller's view, laid out by constraints, as tall as its content makes it; the caller insets its
// content by MENU_ROWS_SETTINGS_INSET. A hidden row takes no room and gets no line, and the lines follow the rows as
// their heights change. The caller gives the card its width and its place; its height is the rows'
NSView* MenuRowsSettingsCard(NSArray<NSView*>* rows);

typedef NS_ENUM(NSInteger, MenuRowsExamplePart) {
  MenuRowsExampleWhole,     // the menu bar's image: the five readings and the optional ones readings shows (battery, Wi-Fi, Neural Engine, GPU; none with readings->extraOnly), cores, extras
  MenuRowsExampleReadings,  // only the readings before the core graph: the five and the optional ones shown, less
                            // the E-cores' and the P-cores' when the graph splits, as they head their own bars
  MenuRowsExampleExtra,     // only the extra readings, from the first to the last
};
// a drawing of the menu bar's image, as the app draws it now, for the help window: readings (NULL: none, the cores
// only) and the core bars' loads, coreLoads[i % coreLoadCount] for core bar i (count 0: all 0), from which the CPU, E
// and P readings are then read, as the app reads them from the cores (count 0: as given), drawn on a strip in
// the menu bar's colour for the view's appearance, redrawn when its appearance or backing scale changes; part crops
// it; label (nil: none) is drawn as a hover label in a box under reading labelReading (CpuRenderReadingX's index, in the
// visual order battery, Wi-Fi, disk, memory, Neural Engine, GPU, CPU, E, P of those shown: CpuRenderReadingIndex; -1:
// the core graph's middle); caption (nil: none) in small secondary text under it. The extras are copied
NSView* MenuRowsHelpExample(const CpuReadings* _Nullable readings, const double* _Nullable coreLoads,
                            int coreLoadCount, MenuRowsExamplePart part, NSString* _Nullable label,
                            int labelReading, NSString* _Nullable caption);

__END_DECLS

NS_ASSUME_NONNULL_END
