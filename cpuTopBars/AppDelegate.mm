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

#import <ServiceManagement/ServiceManagement.h>
#import <Security/Authorization.h>
#import <sys/sysctl.h>
#import <libproc.h>
#import <pwd.h>
#import <sys/types.h>
#import <unistd.h>
#import <getopt.h>
#import <stdlib.h>
#import <vector>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreWLAN/CoreWLAN.h>

#import "AppDelegate.h"

#import "CpuSampler.h"
#import "CpuRenderer.h"
#import "Top.h"
#import "SystemInfo.h"
#import "IOReportReader.h"
#import "MenuRows.h"
#import "Sandbox.h"

#pragma mark Constants

#define TOP_COUNT                   (15)    // the process rows the menu holds, the most Settings offers
#define TOP_REFRESH_RATE            (2.5)   // s between process samples, whatever the Refresh setting

//   32 space bar  3.333984
// 8201 thin space 1.669922
// 8202 hair space 0.837891
#define SPACE_THIN                  (8202)
#define NAME_STR_SPACE_TARGET       (201.6) // pt: 28 cells of the menu font, 7.2 pt each
#define CPU_STR_SPACE_TARGET        (50.0)

#define MENU_ICON_SIZE              (14.0)
#define TOP_ICON_SIZE               (48.0)
#define INSPECTOR_MARGIN            (20.0)  // pt: the icon's own left margin
#define INSPECTOR_GAP               (8.0)   // pt between two of the header's views
#define INSPECTOR_LINE              (16.0)  // pt: one line of the header's text
#define SETTINGS_WIDTH              (485.0) // pt: the Settings window's content width
#define SETTINGS_INSET_X            (20.0)  // pt from the window's left and right edges to the groups
#define SETTINGS_INSET_Y            (14.0)  // pt above the first heading and below the build number
#define SETTINGS_GROUP_WIDTH        (SETTINGS_WIDTH - 2.0*SETTINGS_INSET_X)
#define SETTINGS_GROUP_RADIUS       (10.0)  // pt: a group's rounded corners
#define SETTINGS_ROW_HEIGHT         (36.0)  // pt: one row of a group
#define SETTINGS_ROW_INSET          (MENU_ROWS_SETTINGS_INSET)  // pt from a group's edges to a row's title and control, and to the lines between rows
#define SETTINGS_TITLE_GAP          (8.0)   // pt kept between a row's title and its control
#define SETTINGS_SECTION_GAP        (14.0)  // pt from one section to the next
#define SETTINGS_HEADING_GAP        (6.0)   // pt from a heading to its group
#define SETTINGS_HEADING_INSET      (4.0)   // pt from a group's left edge to its heading
#define SETTINGS_BUTTONS_GAP        (8.0)   // pt from a group to the buttons below it, and between two of them
#define SETTINGS_BUILD_GAP          (10.0)  // pt from the last group to the build number
#define SETTINGS_DEMO_HEIGHT        (72.0)  // pt: the Demo card
#define SETTINGS_DEMO_CAPTION_GAP   (6.0)   // pt from a preview to its caption
#define SETTINGS_DEMO_MIN_GAP       (8.0)   // pt kept before, between and after the Demo previews, as a 24-CPU Mac has them: wider ones are narrowed
#define MENU_FONT_NAME              @"IBMPlexMono" // IBM Plex Mono Regular, in the app's Resources, registered at launch
#define MENU_FONT(points)           ([NSFont fontWithName:MENU_FONT_NAME size:(points)] ?: [NSFont monospacedSystemFontOfSize:(points) weight:NSFontWeightRegular])
#define MENU_TITLE_FONT_NAME        @"Verdana"
#define MENU_TITLE_FONT             ([NSFont fontWithName:MENU_TITLE_FONT_NAME size:MENU_ICON_SIZE-3]) // the status menu's title, and a build's panel headings
#define MENU_TITLE_COLOR            ([NSColor systemRedColor])
// the title's colour as the menu draws it: the title row has no action, and the menu draws a disabled row in systemRedColor about half way to white (matched for this red only)
#define MENU_HEADING_COLOR          ([MENU_TITLE_COLOR blendedColorWithFraction:0.5 ofColor:[NSColor whiteColor]])
#define MENU_PAD_FONT_NAME          @"Helvetica" // the rows' column padding: its hair space is 0.84 pt, IBM Plex Mono's 7.2

#define SYSTEM_ICONS_RSRC           "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"
#define APP_DEFAULT_ICON_NAME       "GenericApplicationIcon.icns"
#define PROCESS_DEFAULT_ICON_NAME   "ExecutableBinaryIcon.icns"

static NSString* GranularityKey = @"GranularityKey";
static NSString* RefreshKey = @"RefreshKey";
static NSString* StyleKey = @"StyleKey";
static NSString* TickLineKey = @"TickLineKey";
static NSString* TickWidthKey = @"TickWidthKey";
static NSString* AppearanceKey = @"AppearanceKey";
static NSString* ThemeKey = @"ThemeKey";
static NSString* ShowBarsKey = @"ShowBarsKey";
static NSString* ShowGpuNeuralEngineKey = @"ShowGpuNeuralEngine";
static NSString* ShowBatteryWifiKey = @"ShowBatteryWifi";
static NSString* ShowBarLettersKey = @"ShowBarLetters";
static NSString* TopRowsKey = @"TopRowsKey";

#pragma mark - C APIs

static void stringFree(CFAllocatorRef allocator, const void *value)
{
  NSString* string = (__bridge NSString*)value;
  CFBridgingRelease((__bridge CFTypeRef _Nullable)(string));
}

static const void* stringRetain(CFAllocatorRef allocator, const void *value)
{
  NSString* string = (__bridge NSString*)value;
  return CFBridgingRetain(string);
}

static Boolean stringEqual(const void *value1, const void *value2)
{
  NSString* string1 = (__bridge NSString*)value1;
  NSString* string2 = (__bridge NSString*)value2;
  return [string1 isEqualToString:string2];
}

// macOS 27 hides menu item images unless an item asks for them
static void ShowMenuItemImage(NSMenuItem* item)
{
  item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
}

// With Reduce Transparency on, the status menu's glass can be drawn as an opaque near-black, and
// the generic process icons disappear into it. Paint the menu's content in the menu bar's own Dark
// Mode grey instead. Menus have no public background setting, so this looks for the open menu's
// glass view; when it is not there, the menu stays as the system draws it.

// sRGB, the menu bar's grey in Dark Mode with Reduce Transparency
static const CGFloat MENU_DARK_GREY = 32.0/255.0;

// the first glass view in the window, breadth-first from its frame view
static NSGlassEffectView* FindGlassEffectView(NSWindow* window)
{
  NSView* root = window.contentView.superview ?: window.contentView;
  if (root == nil)
  {
    return nil;
  }
  NSMutableArray<NSView*>* queue = [NSMutableArray arrayWithObject:root];
  while (queue.count > 0)
  {
    NSView* view = queue[0];
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:[NSGlassEffectView class]])
    {
      return (NSGlassEffectView*)view;
    }
    [queue addObjectsFromArray:view.subviews];
  }
  return nil;
}

// the app's name as its bundle gives it, so a build with another product name reads right in its own menus and windows
static NSString* AppName(void)
{
  NSString* name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
  return (name.length > 0) ? name : [[NSProcessInfo processInfo] processName];
}

// Reduce Transparency on and Increase Contrast off: a menu in Dark Mode is then painted MENU_DARK_GREY
static bool PaintsMenusGrey(void)
{
  NSWorkspace* workspace = [NSWorkspace sharedWorkspace];
  return workspace.accessibilityDisplayShouldReduceTransparency && !workspace.accessibilityDisplayShouldIncreaseContrast;
}

static bool IsDarkAqua(NSAppearance* appearance)
{
  NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
  return [name isEqualToString:NSAppearanceNameDarkAqua];
}

static void PaintGlassGrey(NSGlassEffectView* glass)
{
  NSView* content = glass.contentView;
  content.wantsLayer = YES;
  content.layer.backgroundColor = [NSColor colorWithSRGBRed:MENU_DARK_GREY green:MENU_DARK_GREY blue:MENU_DARK_GREY alpha:1.0].CGColor;
  content.layer.cornerRadius = glass.cornerRadius;
  content.layer.masksToBounds = YES;
}

static void PaintOpenMenuBackground(void)
{
  if (!PaintsMenusGrey())
  {
    return;
  }

  static bool loggedNoWindow = false;
  static bool loggedNoGlass = false;
  bool found = false;
  for (NSWindow* window in [NSApp windows])
  {
    if (!window.isVisible || ![NSStringFromClass([window class]) containsString:@"Menu"])
    {
      continue;
    }
    found = true;

    if (!IsDarkAqua(window.effectiveAppearance))
    {
      continue;
    }

    NSGlassEffectView* glass = FindGlassEffectView(window);
    if (glass == nil)
    {
      if (!loggedNoGlass)
      {
        loggedNoGlass = true;
        NSLog(@"menu window %@ has no glass view: the menu keeps the system's background", NSStringFromClass([window class]));
      }
      continue;
    }

    PaintGlassGrey(glass);
  }

  if (!found && !loggedNoWindow)
  {
    loggedNoWindow = true;
    NSLog(@"no visible menu window: the menu keeps the system's background");
  }
}

#pragma mark - Row tooltips while frozen

// A process row's helper text shows only while the menu is frozen (otherwise the row has moved before
// the text can be read), in a box of its own left of the menu and level with the row, so that it never
// covers the rows. AppKit places a menu item's toolTip itself, so the rows carry the text in
// representedObject instead, and the box is a panel of our own.

#define ROW_TIP_DELAY               (0.4)   // s on a row before its text shows
#define ROW_TIP_GAP                 (6.0)   // pt between the box and the menu
#define ROW_TIP_MAX_WIDTH           (400.0)
#define BAR_TIP_DELAY               (1.0)   // s on a menu-bar reading before its label shows
#define BAR_TIP_WATCH               (0.25)  // s between looks at the pointer while a label is armed or shown
#define BAR_TIP_GAP                 (4.0)   // pt between the menu bar and the label
#define BAR_TIP_CORES               (1000)  // the core graph's index for the labels, past any reading's
#define BAR_TIP_CORES_E             (1001)  // split (barTipSplit above 0): the E-cores' reading's and bars'
#define BAR_TIP_CORES_P             (1002)  // the P-cores' reading's and bars'
#define BAR_TIP_GAP_REACH           (1.0)   // pt of clear space right of a bar's slot that still hovers it: with the slot's own 1-pt gap, 2 pt past the drawn bar

// the item's row on screen, NSZeroRect when the window's row views do not match the menu: top first,
// they are the menu's shown items in order, separators included
static NSRect MenuRowScreenRect(NSWindow* window, NSMenu* menu, NSMenuItem* item)
{
  NSView* root = window.contentView.superview ?: window.contentView;
  if (root == nil)
  {
    return NSZeroRect;
  }
  NSMutableArray<NSView*>* rows = [NSMutableArray array];
  NSMutableArray<NSView*>* stack = [NSMutableArray arrayWithObject:root];
  while (stack.count > 0)
  {
    NSView* view = [stack lastObject];
    [stack removeLastObject];
    if ([NSStringFromClass([view class]) hasSuffix:@"MenuItemView"])
    {
      [rows addObject:view];
      continue;
    }
    [stack addObjectsFromArray:view.subviews];
  }
  [rows sortUsingComparator:^NSComparisonResult(NSView* a, NSView* b) {
    CGFloat ya = NSMaxY([a convertRect:a.bounds toView:nil]);
    CGFloat yb = NSMaxY([b convertRect:b.bounds toView:nil]);
    return (ya > yb) ? NSOrderedAscending : ((ya < yb) ? NSOrderedDescending : NSOrderedSame);
  }];

  NSMutableArray<NSMenuItem*>* shown = [NSMutableArray array];
  for (NSMenuItem* each in menu.itemArray)
  {
    if (!each.hidden)
    {
      [shown addObject:each];
    }
  }
  NSUInteger index = [shown indexOfObjectIdenticalTo:item];
  if ((rows.count != shown.count) || (index == NSNotFound))
  {
    return NSZeroRect;
  }
  NSView* row = rows[index];
  return [window convertRectToScreen:[row convertRect:row.bounds toView:nil]];
}

// the open menu's window, recognised by the item's row (MenuRowScreenRect), which goes to *row when row is not NULL;
// nil when the menu is not on screen or its rows do not match it
static NSWindow* OpenMenuWindow(NSMenu* menu, NSMenuItem* item, NSRect* row)
{
  for (NSWindow* each in [NSApp windows])
  {
    if (each.isVisible && [NSStringFromClass([each class]) containsString:@"Menu"])
    {
      NSRect rect = MenuRowScreenRect(each, menu, item);
      if (!NSIsEmptyRect(rect))
      {
        if (row != NULL)
        {
          *row = rect;
        }
        return each;
      }
    }
  }
  return nil;
}

#pragma mark - The readings panel beside the menu

// While the status menu is open, a panel beside it shows uptime, then how full the startup volume is, memory and
// overall CPU, all read on this Mac. It is placed left of the menu, level with its top, or right of it when there is no
// room on the left; it updates every second, frozen too, and closes with the menu. The disk row is read when the menu
// opens and then every 10 s: each read asks another process for the volume's purgeable space. With the menu closed
// and the menu bar's bars on, the graph's timer reads it every 60 s instead.

#define INFO_REFRESH                (1.0)   // s between updates
#define DISK_REFRESH                (10.0)  // s between disk reads while the menu stays open
#define MENUBAR_DISK_REFRESH        (60.0)  // s between disk reads for the menu bar's disk bar
#define READINGS_TICKS              (2.0)   // Refresh intervals between reads of overall CPU and memory, for the bars and the panel
#define BATTERY_WIFI_REFRESH        (5.0)   // s between reads of the battery and Wi-Fi, for their bars and the panel
#define INFO_RETRY_DELAY            (0.1)   // s before a second look for the menu's window
#define INFO_ROW_HEIGHT             (22.0)  // pt, 2 pt shorter than a native row (a menu grows 24 pt with one, measured)
#define INFO_INSET                  (14.0)  // pt left and right, as a title-only row
#define INFO_COLUMN_GAP             (24.0)  // pt at least between a label and its value
#define INFO_EXTRA_WIDTH            (50.0)  // pt added to the widest row's need
#define INFO_VERTICAL_INSET         (5.0)
#define INFO_CORNER_RADIUS          (8.0)
#define INFO_SEPARATOR_HEIGHT       (11.0)  // pt, as a native menu separator (a menu grows 11 pt with one, measured)

// one decimal, none when the rounded value is whole, with the locale's separator: "9.8", "16", "9,8"
static NSString* OneDecimal(double value, NSLocale* locale)
{
  double rounded = round(value * 10.0) / 10.0;
  if (rounded == floor(rounded))
  {
    return [[NSString alloc] initWithFormat:@"%.0f" locale:locale, rounded];
  }
  return [[NSString alloc] initWithFormat:@"%.1f" locale:locale, rounded];
}

// memory, 1024-based as Activity Monitor shows it: "9.8 GB", "16 GB"
static NSString* GiBText(uint64_t bytes, NSLocale* locale)
{
  return [NSString stringWithFormat:@"%@ GB", OneDecimal((double)bytes / 1073741824.0, locale)];
}

// disk, 1000-based as Finder shows it: whole GB below 1000 GB ("412 GB"), else TB ("1.2 TB", "2 TB")
static NSString* GBText(uint64_t bytes, NSLocale* locale)
{
  double gb = round((double)bytes / 1e9);
  if (gb < 1000.0)
  {
    return [[NSString alloc] initWithFormat:@"%.0f GB" locale:locale, gb];
  }
  return [NSString stringWithFormat:@"%@ TB", OneDecimal((double)bytes / 1e12, locale)];
}

// "57%": part of whole as a whole percentage, 0% to 100%; "—" when whole is 0
static NSString* PercentText(uint64_t part, uint64_t whole, NSLocale* locale)
{
  if (whole == 0)
  {
    return @"—";
  }
  long percent = MIN(MAX(lround(100.0 * (double)part / (double)whole), 0L), 100L);
  return [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, percent];
}

// "0.51 GB", "1.23 GB": a process's memory, always in GB, in units of 1024, two decimals
static NSString* MemoryText(uint64_t bytes)
{
  return [NSString stringWithFormat:@"%.2f GB", (double)bytes / 1073741824.0];
}

// a hover label's lines, one value to a line: each row is @[name, value], the name padded with spaces to the longest
// name's length and three, so that the values start in one column in the label's monospace font, as Wi-Fi's label
// does (WifiTipText); the lines joined by "\n"; a label of one line, its name and one space ("CPU: 21%", as before).
// Defined here, before the labels that use it; Wi-Fi's keeps its own.
static NSString* TipLines(NSArray<NSArray<NSString*>*>* rows)
{
  NSUInteger gap = (rows.count == 1) ? 1 : 3;
  NSUInteger width = 0;
  for (NSArray<NSString*>* row in rows)
  {
    width = MAX(width, row[0].length + gap);
  }
  NSMutableArray<NSString*>* lines = [NSMutableArray arrayWithCapacity:rows.count];
  for (NSArray<NSString*>* row in rows)
  {
    [lines addObject:[[row[0] stringByPaddingToLength:width withString:@" " startingAtIndex:0] stringByAppendingString:row[1]]];
  }
  return [lines componentsJoinedByString:@"\n"];
}

// "16GB Memory usage:": a row's title led by its whole, written without a space ("16 GB" -> "16GB")
static NSString* TotalTitle(NSString* wholeText, NSString* name)
{
  return [NSString stringWithFormat:@"%@ %@", [wholeText stringByReplacingOccurrencesOfString:@" " withString:@""], name];
}

// the startup volume's row from its size and free space: title ("995GB Disk usage:"), text ("72% (free 279 GB, used 716 GB)")
// and tipText, the hover label's lines (TipLines): "Disk usage:   72%", "Free:         279 GB", "Used:         716 GB" and
// "Total:        995 GB", every value starting in one column; "Disk usage: —" when the volume has no size (readDisk)
static void DiskTexts(uint64_t wholeBytes, uint64_t freeBytes, NSLocale* locale, NSString* __strong * title, NSString* __strong * text, NSString* __strong * tipText)
{
  *title = TotalTitle(GBText(wholeBytes, locale), @"Disk usage:");
  uint64_t usedBytes = (wholeBytes > freeBytes) ? (wholeBytes - freeBytes) : 0;
  *text = PercentText(usedBytes, wholeBytes, locale);
  *tipText = [@"Disk usage: " stringByAppendingString:*text];
  if (wholeBytes > 0)
  {
    NSString* freeText = GBText(wholeBytes - usedBytes, locale);
    NSString* usedText = GBText(usedBytes, locale);
    *tipText = TipLines(@[@[@"Disk usage:", *text], @[@"Free:", freeText], @[@"Used:", usedText], @[@"Total:", GBText(wholeBytes, locale)]]);
    *text = [NSString stringWithFormat:@"%@ (free %@, used %@)", *text, freeText, usedText];
  }
}

// "3d 4h 27m"; under a day "4h 27m", under an hour "27m"
static NSString* UptimeText(long seconds)
{
  if (seconds < 0)
  {
    return @"unknown";
  }
  long days = seconds / 86400;
  long hours = (seconds % 86400) / 3600;
  long minutes = (seconds % 3600) / 60;
  if (days > 0)
  {
    return [NSString stringWithFormat:@"%ldd %ldh %ldm", days, hours, minutes];
  }
  if (hours > 0)
  {
    return [NSString stringWithFormat:@"%ldh %ldm", hours, minutes];
  }
  return [NSString stringWithFormat:@"%ldm", minutes];
}

#pragma mark - Rows that leave the menu open (Freeze)

// A click on a native menu item closes the menu; a click on an item's view does not, and sends no action. So
// these rows are views drawn like the native rows of 24 pt: with an image, the image at x 15 and the title at
// x 36; without one, the title at x 14, as Quit's; the title 4 pt up, and when highlighted the system's selection
// material, inset 5 pt with a corner radius of 7, under the title and image in the selected text colour. A title
// too wide for the row is drawn in smaller type. The item keeps its title, image and action: the action is what
// enables it, and so lets it highlight. Return on it does nothing (mouse only). After a click AppKit removes the
// highlight until the pointer moves. A disabled row is drawn grey, as a native one, with no selection, and a click on
// it does nothing.

#define STAY_OPEN_ROW_HEIGHT        (24.0)

static bool IsLight(NSAppearance* appearance);
static double RefreshInterval(void);
static double TopInterval(void);

@interface StayOpenMenuItem : NSMenuItem
{
  bool loggedNoTarget;  // a missing target is logged once per row
}
- (BOOL)actInPlace;
@end

@implementation StayOpenMenuItem

// a click on the row, or VoiceOver's press: the item's action, with the menu left open
- (BOOL)actInPlace
{
  if (!self.isEnabled)
  {
    return NO;
  }
  BOOL sent = [NSApp sendAction:self.action to:self.target from:self];
  if (!sent && !loggedNoTarget)
  {
    loggedNoTarget = true;
    // the action, not the title: a row's title can be private
    NSLog(@"the row's action %@ found no target", NSStringFromSelector(self.action));
  }
  return sent;
}

// a press on a menu item with a view would close the menu and send nothing
- (BOOL)accessibilityPerformPress
{
  return [self actInPlace];
}

// a native item reports its enabled state to accessibility; an item with a view reports enabled even when disabled
- (BOOL)isAccessibilityEnabled
{
  return self.isEnabled;
}

@end

@interface StayOpenRowView : NSView
{
  NSVisualEffectView* selection;
  NSImageView* icon;                  // nil for an item without an image
  NSTextField* label;
  NSAttributedString* fittedTitle;    // the title the label last showed, and the room it was fitted to
  CGFloat fittedRoom;
}
- (instancetype)initWithItem:(NSMenuItem*)item;
@end

@implementation StayOpenRowView

- (instancetype)initWithItem:(NSMenuItem*)item
{
  // the menu widens the view to its own width
  self = [super initWithFrame:NSMakeRect(0, 0, 100.0, STAY_OPEN_ROW_HEIGHT)];
  if (self != nil)
  {
    self.autoresizingMask = NSViewWidthSizable;

    selection = [[NSVisualEffectView alloc] initWithFrame:NSInsetRect(self.bounds, 5.0, 0.0)];
    selection.material = NSVisualEffectMaterialSelection;
    selection.state = NSVisualEffectStateActive;
    selection.emphasized = YES;
    selection.wantsLayer = YES;
    selection.layer.cornerRadius = 7.0;
    selection.layer.masksToBounds = YES;
    selection.autoresizingMask = NSViewWidthSizable;
    selection.hidden = YES;
    [self addSubview:selection];

    CGFloat x = 14.0;
    if (item.image != nil)
    {
      icon = [NSImageView imageViewWithImage:item.image];
      icon.frame = NSMakeRect(15.0, 4.0, 16.0, 16.0);
      // the check mark at its own size, centred, as the native row draws it
      icon.imageScaling = NSImageScaleNone;
      [self addSubview:icon];
      x = 36.0;
    }

    label = [NSTextField labelWithAttributedString:item.attributedTitle];
    label.frame = NSMakeRect(x, 4.0, NSWidth(self.bounds) - x - 6.0, 16.0);
    label.autoresizingMask = NSViewWidthSizable;
    [self addSubview:label];

    // VoiceOver reads the item itself (its title, and StayOpenMenuItem's press), as for a native item; the item's
    // accessibility children would otherwise be these cells
    icon.cell.accessibilityElement = NO;
    label.cell.accessibilityElement = NO;
  }
  return self;
}

// the item's title in the label, in smaller type when it is wider than the row's room
- (void)fitTitle:(NSMenuItem*)item
{
  NSAttributedString* title = item.attributedTitle;
  CGFloat room = NSWidth(label.frame);
  if ((title == nil) || (title.length == 0) || ([title isEqualToAttributedString:fittedTitle] && (room == fittedRoom)))
  {
    return;
  }
  fittedTitle = [title copy];
  fittedRoom = room;
  label.attributedStringValue = title;
  NSFont* font = [title attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
  CGFloat width = [label sizeThatFits:NSMakeSize(CGFLOAT_MAX, NSHeight(label.frame))].width;
  if ((font == nil) || (width <= room) || (width <= 0.0))
  {
    return;
  }
  // from the size that would fit if the width scaled with it, down in tenths of a point until it fits
  CGFloat size = floor(font.pointSize * room / width * 10.0) / 10.0;
  for (; size >= 6.0; size -= 0.1)
  {
    NSFont* smallerFont = [NSFont fontWithDescriptor:font.fontDescriptor size:size];
    if (smallerFont == nil)
    {
      return;
    }
    NSMutableAttributedString* smaller = [title mutableCopy];
    [smaller addAttribute:NSFontAttributeName value:smallerFont range:NSMakeRange(0, smaller.length)];
    label.attributedStringValue = smaller;
    if ([label sizeThatFits:NSMakeSize(CGFLOAT_MAX, NSHeight(label.frame))].width <= room)
    {
      return;
    }
  }
}

- (void)viewWillDraw
{
  NSMenuItem* item = self.enclosingMenuItem;
  bool enabled = item.isEnabled;
  bool highlighted = enabled && item.isHighlighted;
  selection.hidden = !highlighted;
  [self fitTitle:item];
  // disabled: the grey AppKit gives a native disabled row's title, secondary in Dark and tertiary in Light
  NSColor* disabledColor = IsLight(self.effectiveAppearance) ? [NSColor tertiaryLabelColor] : [NSColor secondaryLabelColor];
  NSColor* color = !enabled ? disabledColor : (highlighted ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor]);
  label.textColor = color;
  if (icon != nil)
  {
    icon.contentTintColor = color;
    // as high as the image and centred in the row, as the native row's image view is: the blank 16 x 16 at y 4, the
    // check 16 x 11 at y 6.5
    NSImage* image = item.image;
    CGFloat height = MIN(image.size.height, 16.0);
    icon.frame = NSMakeRect(15.0, (STAY_OPEN_ROW_HEIGHT - height)/2.0, 16.0, height);
    icon.image = image;
  }
  [super viewWillDraw];
}

// taken here, so that the menu does not act on it
- (void)mouseDown:(NSEvent*)event
{
}

- (void)mouseUp:(NSEvent*)event
{
  // a press that ends on another row has moved the highlight there
  NSMenuItem* item = self.enclosingMenuItem;
  if (item.isHighlighted && [item isKindOfClass:[StayOpenMenuItem class]])
  {
    [(StayOpenMenuItem*)item actInPlace];
  }
}

@end

#pragma mark - Rows a build adds

// made on the first call, not by an initializer: a class registers from +load, which runs before this file's static initializers
static NSMutableArray<Class>* menuRowsClasses = nil;

// one instance of each registered class, made in setupMenus; a menu item's target is weak, so this keeps them alive
static NSMutableArray<id<MenuRows>>* menuRows = nil;
// the views the rows add to the inspector's header, made on its first showing; empty unless a build adds rows
static NSMutableArray<NSView*>* inspectorRowViews = nil;

void MenuRowsRegister(Class<MenuRows> rowsClass)
{
  if (menuRowsClasses == nil)
  {
    menuRowsClasses = [[NSMutableArray alloc] init];
  }
  [menuRowsClasses addObject:rowsClass];
}

NSMenuItem* MenuRowsStayOpenItem(NSString* title, SEL action, id target, NSDictionary<NSAttributedStringKey, id>* attributes)
{
  NSMenuItem* item = [[StayOpenMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  [item setTarget:target];
  [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributes]];
  // a view, so that a click leaves the menu open
  [item setView:[[StayOpenRowView alloc] initWithItem:item]];
  return item;
}

NSSwitch* MenuRowsSettingsSwitch(BOOL on, SEL action, id target)
{
  NSSwitch* control = [[NSSwitch alloc] init];
  control.controlSize = NSControlSizeMini;
  control.state = on ? NSControlStateValueOn : NSControlStateValueOff;
  control.target = target;
  control.action = action;
  [control sizeToFit];
  return control;
}

NSSegmentedControl* MenuRowsSettingsChoice(NSArray<NSString*>* labels, CGFloat segmentWidth, NSInteger selected, SEL action, id target)
{
  NSSegmentedControl* control = [NSSegmentedControl segmentedControlWithLabels:labels trackingMode:NSSegmentSwitchTrackingSelectOne target:target action:action];
  control.controlSize = NSControlSizeRegular;
  control.segmentDistribution = NSSegmentDistributionFillEqually;
  for (NSInteger n=0; n<control.segmentCount; n++)
  {
    [control setWidth:segmentWidth forSegment:n];
  }
  control.selectedSegment = ((selected >= 0) && (selected < control.segmentCount)) ? selected : -1;
  [control sizeToFit];
  return control;
}

#pragma mark - Settings window

// a group of the Settings window: a rounded card, with a 1-pt line between its rows, each SETTINGS_ROW_HEIGHT tall, or,
// with rowViews, at the top of each row view after the first
@interface SettingsGroupView : NSView
@property (nonatomic, assign) NSInteger rowCount;
@property (nonatomic, copy) NSArray<NSView*>* rowViews;
@end

@implementation SettingsGroupView

- (BOOL)isFlipped
{
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
  static NSColor* fill = nil;
  if (fill == nil)
  {
    fill = [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* appearance) {
      return [NSColor colorWithWhite:1.0 alpha:IsLight(appearance) ? 0.6 : 0.05];
    }];
  }
  NSBezierPath* card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:SETTINGS_GROUP_RADIUS yRadius:SETTINGS_GROUP_RADIUS];
  [fill setFill];
  [card fill];
  [[NSColor separatorColor] setStroke];
  [card setLineWidth:1.0];
  [card stroke];
  [[NSColor separatorColor] setFill];
  NSMutableArray<NSNumber*>* tops = [[NSMutableArray alloc] init];
  if (self.rowViews != nil)
  {
    for (NSView* row in self.rowViews)
    {
      if (!row.hidden)
      {
        [tops addObject:@(NSMinY([self convertRect:row.bounds fromView:row]))];
      }
    }
  }
  else
  {
    for (NSInteger n=0; n<self.rowCount; n++)
    {
      [tops addObject:@(n*SETTINGS_ROW_HEIGHT)];
    }
  }
  for (NSUInteger n=1; n<tops.count; n++)
  {
    NSRect line = NSMakeRect(SETTINGS_ROW_INSET, tops[n].doubleValue - 0.5, NSWidth(self.bounds) - 2.0*SETTINGS_ROW_INSET, 1.0);
    NSRectFillUsingOperation(line, NSCompositingOperationSourceOver);
  }
}

// the rows' heights may change with their content: the lines are drawn again where they now are
- (void)layout
{
  [super layout];
  if (self.rowViews != nil)
  {
    [self setNeedsDisplay:YES];
  }
}

@end

// a label of the Settings window, laid out by constraints
static NSTextField* SettingsLabel(NSString* text, NSFont* font, NSColor* color)
{
  NSTextField* label = [NSTextField labelWithString:text];
  label.font = font;
  label.textColor = color;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  return label;
}

NSTextField* MenuRowsSettingsHeading(NSString* title)
{
  return SettingsLabel(title, [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold], [NSColor labelColor]);
}

NSView* MenuRowsSettingsCard(NSArray<NSView*>* rows)
{
  SettingsGroupView* card = [[SettingsGroupView alloc] init];
  card.translatesAutoresizingMaskIntoConstraints = NO;
  card.rowViews = rows;
  // a stack, so that a hidden row takes no room (and gets no line)
  NSStackView* stack = [NSStackView stackViewWithViews:rows];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 0.0;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [card addSubview:stack];
  NSMutableArray<NSLayoutConstraint*>* constraints = [[NSMutableArray alloc] init];
  [constraints addObjectsFromArray:@[
    [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
  ]];
  for (NSView* row in rows)
  {
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [constraints addObject:[row.widthAnchor constraintEqualToAnchor:stack.widthAnchor]];
  }
  [NSLayoutConstraint activateConstraints:constraints];
  return card;
}

// the entries of rows that are a pair @[NSString title, NSView control], in their order
static NSArray<NSArray*>* SettingsValidRows(id rows)
{
  NSMutableArray<NSArray*>* valid = [[NSMutableArray alloc] init];
  if (![rows isKindOfClass:[NSArray class]])
  {
    return valid;
  }
  for (id row in (NSArray*)rows)
  {
    if ([row isKindOfClass:[NSArray class]] && ([(NSArray*)row count] == 2) &&
        [((NSArray*)row)[0] isKindOfClass:[NSString class]] && [((NSArray*)row)[1] isKindOfClass:[NSView class]])
    {
      [valid addObject:row];
    }
  }
  return valid;
}

// a row's title follows its control: drawn in the label colour while the control is enabled, the tertiary label colour
// while it is not. Kept in settingsTitleWatchers for the app's life, as the window and its controls are
@interface SettingsTitleWatcher : NSObject
@property (nonatomic, weak) NSTextField* title;
@end

@implementation SettingsTitleWatcher

- (void)follow:(NSControl*)control
{
  self.title.textColor = control.enabled ? [NSColor labelColor] : [NSColor tertiaryLabelColor];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
  (void)keyPath; (void)change; (void)context;
  [self follow:(NSControl*)object];
}

@end

static NSMutableArray<SettingsTitleWatcher*>* settingsTitleWatchers = nil;

// a group of rows, each @[title, control], SETTINGS_ROW_HEIGHT tall: the title at the left, cut at the control when
// too long, the control at the right, both centred on the row. The control is named by its title for VoiceOver (unless
// it has a label of its own), and an NSControl's title dims while it is disabled. A control with no size of its own
// keeps its frame's
static SettingsGroupView* SettingsGroup(NSArray<NSArray*>* rows)
{
  SettingsGroupView* group = [[SettingsGroupView alloc] init];
  group.translatesAutoresizingMaskIntoConstraints = NO;
  group.rowCount = (NSInteger)rows.count;
  NSMutableArray<NSLayoutConstraint*>* constraints = [[NSMutableArray alloc] init];
  [constraints addObject:[group.widthAnchor constraintEqualToConstant:SETTINGS_GROUP_WIDTH]];
  [constraints addObject:[group.heightAnchor constraintEqualToConstant:rows.count*SETTINGS_ROW_HEIGHT]];
  for (NSUInteger n=0; n<rows.count; n++)
  {
    NSTextField* title = SettingsLabel(rows[n][0], [NSFont systemFontOfSize:13.0], [NSColor labelColor]);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView* control = rows[n][1];
    NSSize size = control.frame.size;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    if (control.intrinsicContentSize.width == NSViewNoIntrinsicMetric)
    {
      [constraints addObject:[control.widthAnchor constraintEqualToConstant:size.width]];
    }
    if (control.intrinsicContentSize.height == NSViewNoIntrinsicMetric)
    {
      [constraints addObject:[control.heightAnchor constraintEqualToConstant:size.height]];
    }
    [group addSubview:title];
    [group addSubview:control];
    if (control.accessibilityLabel.length == 0)
    {
      control.accessibilityLabel = rows[n][0];
    }
    if ([control isKindOfClass:[NSControl class]])
    {
      if (settingsTitleWatchers == nil)
      {
        settingsTitleWatchers = [[NSMutableArray alloc] init];
      }
      SettingsTitleWatcher* watcher = [[SettingsTitleWatcher alloc] init];
      watcher.title = title;
      [watcher follow:(NSControl*)control];
      [control addObserver:watcher forKeyPath:@"enabled" options:0 context:NULL];
      [settingsTitleWatchers addObject:watcher];
    }
    CGFloat centre = n*SETTINGS_ROW_HEIGHT + SETTINGS_ROW_HEIGHT/2.0;
    [constraints addObjectsFromArray:@[
      [title.leadingAnchor constraintEqualToAnchor:group.leadingAnchor constant:SETTINGS_ROW_INSET],
      [title.centerYAnchor constraintEqualToAnchor:group.topAnchor constant:centre],
      [title.trailingAnchor constraintLessThanOrEqualToAnchor:control.leadingAnchor constant:-SETTINGS_TITLE_GAP],
      [control.trailingAnchor constraintEqualToAnchor:group.trailingAnchor constant:-SETTINGS_ROW_INSET],
      [control.centerYAnchor constraintEqualToAnchor:group.topAnchor constant:centre],
    ]];
  }
  [NSLayoutConstraint activateConstraints:constraints];
  return group;
}

// the Demo card's captions' horizontal centres, which placeDemoPreviews moves with their previews
static NSLayoutConstraint* demoCaptionCentres[3] = {nil, nil, nil};

#pragma mark - /usr/bin/top reader

#if !CPUTOPBARS_SANDBOXED
#define TOP_TOOL_ROWS               (2*TOP_COUNT) // headroom: 2x the rows shown

// One /usr/bin/top run per menu opening. Its lines are parsed on the file handle's background queue;
// only complete blocks of (pid, cpu) rows reach the main thread.
@interface TopToolSession : NSObject
{
@public
  NSUInteger generation;
  NSTask* task;
  NSMutableData* pending;       // bytes after the last newline
  int blocks;                   // "PID" header lines seen; block 1 is all zeros and is dropped
  bool inBlock;
  int rows;
  pid_t pids[TOP_TOOL_ROWS];
  double cpus[TOP_TOOL_ROWS];
  bool loggedExit;
  bool loggedEmpty;
  bool drawn;                   // this run's first block with rows has come (applyTopTool:)
}
@end

@implementation TopToolSession
@end

// feeds one line to the parser; calls block() for every complete block after the first
static void TopToolParseLine(TopToolSession* session, const char* line, void (^block)(NSData* pids, NSData* cpus), void (^empty)(void))
{
  TopParsedRow_t row;
  if (strncmp(line, "PID", 3) == 0)
  {
    session->blocks++;
    session->inBlock = true;
    session->rows = 0;
  }
  else if (strncmp(line, "Processes:", 10) == 0)
  {
    if (session->inBlock && (session->blocks > 1))
    {
      if (session->rows > 0)
      {
        block([NSData dataWithBytes:session->pids length:session->rows * sizeof(pid_t)], [NSData dataWithBytes:session->cpus length:session->rows * sizeof(double)]);
      }
      else
      {
        empty();
      }
    }
    session->inBlock = false;
  }
  else if (session->inBlock && TopParseTopLine(line, &row) && !row.has_uid)
  {
    session->pids[session->rows] = row.pid;
    session->cpus[session->rows] = row.cpu;
    session->rows++;
    if (session->rows == TOP_TOOL_ROWS)
    {
      if (session->blocks > 1)
      {
        block([NSData dataWithBytes:session->pids length:session->rows * sizeof(pid_t)], [NSData dataWithBytes:session->cpus length:session->rows * sizeof(double)]);
      }
      session->inBlock = false;
    }
  }
}

static void TopToolConsume(TopToolSession* session, NSData* data, void (^block)(NSData* pids, NSData* cpus), void (^empty)(void))
{
  [session->pending appendData:data];
  const char* bytes = (const char*)[session->pending bytes];
  NSUInteger length = [session->pending length];
  NSUInteger start = 0;
  for (NSUInteger i=0; i<length; i++)
  {
    if (bytes[i] == '\n')
    {
      char line[256];
      NSUInteger n = MIN(i - start, sizeof(line) - 1);
      memcpy(line, &bytes[start], n);
      line[n] = '\0';
      TopToolParseLine(session, line, block, empty);
      start = i + 1;
    }
  }
  [session->pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}
#endif

#pragma mark - Process icons

typedef NS_ENUM(NSInteger, ProcessIconRule)
{
  ProcessIconRuleOwn,       // its own app, or a nested bundle that declares an icon
  ProcessIconRuleAncestor,  // the nearest ancestor with its own icon (launchd skipped)
  ProcessIconRuleBundle,    // the app bundle it runs inside
  ProcessIconRuleGeneric,   // the generic executable icon
};

// One decision per pid: the menu row, its tooltip and the inspector all come from it.
@interface ProcessIconDecision : NSObject
@property (nonatomic, copy) NSString* path;         // executable path, nil when proc_pidpath fails
@property (nonatomic, strong) NSImage* image;       // full size
@property (nonatomic, strong) NSImage* menuImage;   // MENU_ICON_SIZE copy
@property (nonatomic, assign) ProcessIconRule rule;
@property (nonatomic, assign) BOOL helper;          // shown with ↳
@property (nonatomic, copy) NSString* tooltip;      // nil unless helper
@property (nonatomic, copy) NSString* helperLine;   // the inspector's "Helper of:" line, nil unless helper
@end

@implementation ProcessIconDecision
@end

static NSString* ProcessPath(pid_t pid)
{
  char buffer[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, buffer, sizeof(buffer)) <= 0)
  {
    return nil;
  }
  return [NSString stringWithUTF8String:buffer];
}

// the start time of the process now running as pid, in microseconds; 0 when the pid has exited or is a
// zombie. sysctl(KERN_PROC_PID) gives it for every user's processes (proc_pidinfo only for the user's own)
static uint64_t ProcessStartTime(pid_t pid)
{
  struct kinfo_proc kinfo;
  size_t length = sizeof(kinfo);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  // for a pid that has already exited, sysctl succeeds but returns no data (length 0)
  if ((sysctl(mib, 4, &kinfo, &length, NULL, 0) != 0) || (length != sizeof(kinfo)) || (kinfo.kp_proc.p_stat == SZOMB))
  {
    return 0;
  }
  return ((uint64_t)kinfo.kp_proc.p_starttime.tv_sec * USEC_PER_SEC) + (uint64_t)kinfo.kp_proc.p_starttime.tv_usec;
}

// the outermost .app in the path, nil when there is none
static NSString* OuterApp(NSString* path)
{
  NSRange range = [path rangeOfString:@".app/"];
  if (range.location == NSNotFound)
  {
    return nil;
  }
  return [path substringToIndex:range.location + 4];
}

// the bundle whose icon is the process's own icon, nil when it has none
static NSString* OwnIconBundle(NSString* path)
{
  if (path == nil)
  {
    return nil;
  }
  NSString* bundle = nil;
  NSRange range = [path rangeOfString:@"/Contents/MacOS/" options:NSBackwardsSearch];
  if (range.location != NSNotFound)
  {
    bundle = [path substringToIndex:range.location];
  }
  else
  {
    // an executable directly in a .app directory (no Contents/MacOS)
    NSString* dir = [path stringByDeletingLastPathComponent];
    if ([dir hasSuffix:@".app"])
    {
      bundle = dir;
    }
  }
  if (bundle == nil)
  {
    return nil;
  }
  NSString* outer = OuterApp(path);
  if ([bundle hasSuffix:@".app"] && (outer != nil))
  {
    if ([bundle isEqualToString:outer])
    {
      // a top-level app: its icon is whatever LaunchServices shows
      return bundle;
    }
    if ([bundle isEqualToString:[[outer stringByAppendingPathComponent:@"Wrapper"] stringByAppendingPathComponent:[bundle lastPathComponent]]])
    {
      // an iOS app, <outer>.app/Wrapper/<inner>.app: the outer app's icon
      return outer;
    }
  }
  NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"]];
  if ((info[@"CFBundleIconFile"] != nil) || (info[@"CFBundleIconName"] != nil))
  {
    // a nested bundle that declares an icon
    return bundle;
  }
  return nil;
}

// decodes text from the kernel as UTF-8, and never fails: the kernel cuts names at a byte limit, so
// a name can end in part of a UTF-8 character, which is dropped; text that Foundation still refuses
// as UTF-8 is decoded as Mac OS Roman, which maps every byte (some invalid bytes Foundation accepts,
// showing U+FFFD)
static NSString* SampleText(const char* name)
{
  if (name == NULL)
  {
    return @"";
  }
  const unsigned char* bytes = (const unsigned char*)name;
  NSUInteger length = strlen(name);
  NSString* text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
  if (text != nil)
  {
    return text;
  }
  // the last character's first byte: back over up to 3 continuation bytes (10xxxxxx) to a byte that
  // can start a UTF-8 character (0xC2-0xF4)
  NSUInteger first = length;
  while ((first > 0) && (length - first < 3) && ((bytes[first-1] & 0xC0) == 0x80))
  {
    first--;
  }
  if ((first > 0) && (bytes[first-1] >= 0xC2) && (bytes[first-1] <= 0xF4))
  {
    first--;
    NSUInteger needed = (bytes[first] >= 0xF0) ? 4 : ((bytes[first] >= 0xE0) ? 3 : 2);
    if (length - first < needed)
    {
      text = [[NSString alloc] initWithBytes:bytes length:first encoding:NSUTF8StringEncoding];
    }
  }
  if (text == nil)
  {
    text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSMacOSRomanStringEncoding];
  }
  return (text != nil) ? text : @"";
}

static NSString* SampleName(pid_t pid)
{
  TopProcessSample_t* sample = TopGetSample(pid);
  return (sample != NULL) ? SampleText(sample->name) : nil;
}

static ProcessIconDecision* DecideProcessIcon(pid_t pid, NSString* path)
{
  ProcessIconDecision* decision = [[ProcessIconDecision alloc] init];
  decision.path = path;
  TopProcessSample_t* sample = TopGetSample(pid);
  pid_t ppid = (sample != NULL) ? sample->ppid : 0;
  NSString* name = (sample != NULL) ? SampleText(sample->name) : @"?";

  // the spawn chain from the topmost ancestor below launchd down to the process, and the nearest
  // ancestor with its own icon
  NSMutableArray<NSString*>* chain = [NSMutableArray arrayWithObject:name];
  NSString* ancestorBundle = nil;
  NSString* ancestorName = nil;
  pid_t p = ppid;
  for (int depth=0; (p > 1) && (depth < 64); depth++)
  {
    TopProcessSample_t* ancestor = TopGetSample(p);
    if (ancestor == NULL)
    {
      break;
    }
    NSString* ancestorSampleName = SampleText(ancestor->name);
    [chain insertObject:ancestorSampleName atIndex:0];
    if (ancestorBundle == nil)
    {
      ancestorBundle = OwnIconBundle(ProcessPath(p));
      if (ancestorBundle != nil)
      {
        ancestorName = ancestorSampleName;
      }
    }
    p = ancestor->ppid;
  }

  NSString* iconFile = OwnIconBundle(path);
  NSString* app = nil;
  if (iconFile != nil)
  {
    decision.rule = ProcessIconRuleOwn;
  }
  else if (ancestorBundle != nil)
  {
    decision.rule = ProcessIconRuleAncestor;
    iconFile = ancestorBundle;
  }
  else if ((path != nil) && ((app = OuterApp(path)) != nil))
  {
    decision.rule = ProcessIconRuleBundle;
    iconFile = app;
  }
  else
  {
    decision.rule = ProcessIconRuleGeneric;
  }

  NSImage* image = nil;
  if (iconFile != nil)
  {
    image = [[NSWorkspace sharedWorkspace] iconForFile:iconFile];
  }
  else
  {
    static NSImage* genericIcon = nil;
    if (genericIcon == nil)
    {
      genericIcon = [[NSWorkspace sharedWorkspace] iconForContentType:UTTypeUnixExecutable];
    }
    image = genericIcon;
  }
  decision.image = [image copy];
  decision.menuImage = [image copy];
  [decision.menuImage setSize:NSMakeSize(MENU_ICON_SIZE, MENU_ICON_SIZE)];

  // ↳: an ancestor other than launchd and kernel_task, or the icon of the app bundle it runs inside
  bool spawned = (pid > 1) && (ppid > 1);
  bool inside = (pid > 1) && (decision.rule == ProcessIconRuleBundle);
  decision.helper = spawned || inside;
  if (spawned)
  {
    NSString* of = (ancestorName != nil) ? ancestorName : SampleName(ppid);
    NSString* chainText = [chain componentsJoinedByString:@" → "];
    decision.tooltip = [NSString stringWithFormat:@"Helper of %@\n%@", (of != nil) ? of : @"?", chainText];
    decision.helperLine = [NSString stringWithFormat:@"Helper of: %@", chainText];
  }
  else if (inside)
  {
    NSString* appName = [[app lastPathComponent] stringByDeletingPathExtension];
    decision.tooltip = [NSString stringWithFormat:@"Helper of %@\n%@ runs inside %@", appName, name, [app lastPathComponent]];
    decision.helperLine = [NSString stringWithFormat:@"Helper of: %@ (runs inside %@)", appName, app];
  }
  return decision;
}

#pragma mark -

#pragma mark - Help window

#define HELP_MAX_HEIGHT             (640.0) // pt: the help window's tallest content; a longer text scrolls
#define HELP_ROW_PADDING            (8.0)   // pt above and below a paragraph in its card

// the help window, made on its first open and kept
static NSWindow* helpWindow = nil;

#define HELP_EXAMPLE_ZOOM           (2.0)   // an example is drawn this many times its size, so that a 1-pt line and the dashes show
#define HELP_EXAMPLE_PADDING        (3.0)   // pt of strip around the drawing
#define HELP_EXAMPLE_RADIUS         (4.0)   // pt, the strip's corners
#define HELP_EXAMPLE_GAP            (12.0)  // pt between examples, left to right
#define HELP_EXAMPLE_LINE_GAP       (8.0)   // pt between lines of examples
#define HELP_EXAMPLE_TEXT_GAP       (6.0)   // pt between a paragraph and its examples
#define HELP_EXAMPLE_TEXT_WIDTH     (SETTINGS_GROUP_WIDTH - 2.0*SETTINGS_ROW_INSET) // pt: a paragraph's, and an example row's
#define HELP_EXAMPLE_BELOW_GAP      (4.0)   // pt between the strip, the label box and the caption

static bool IsLight(NSAppearance* appearance);

// the hover labels' box, as the status item's labels are made (NewTipPanel, SetTipText), and the texts the examples show
// in it, worded by the code that words the real labels (defined with them)
static NSPanel* NewTipPanel(NSTextField* __strong * label);
static void SetTipText(NSPanel* panel, NSTextField* label, NSString* text, CGFloat wrap);
static void HelpCoreReadings(const double* coreLoads, int coreLoadCount, CpuReadings* readings);
static NSString* HelpDiskLabel(const CpuReadings* readings);
static NSString* HelpGpuLabel(const CpuReadings* readings);
static SystemInfoWifi HelpWifiSample(void);
static NSString* HelpBatteryLabel(const CpuReadings* readings);
static NSString* HelpWifiLabel(void);
static NSArray<NSView*>* HelpCoresExamples(const CpuReadings* readings, const double* coreLoads, int coreLoadCount);
static NSString* HelpReadingsCaption(const CpuReadings* readings);

// the menu bar's drawing settings at the moment an example is made, from the statics that updateMenuIcon draws with
typedef struct HelpExampleStyle
{
  int granularity;
  bool bar, stripped, colored;
  CGFloat drawWidth, tickTotalWidth, graphWidth, tickHeight;
  int theme;
  natural_t countLogical;
  int coreSplit;
} HelpExampleStyle;

// the help window's document view: flipped, so its content starts at its top and scrolls from there, and sized by its
// frame; pinned to the clip view instead, the content drifted from the scroll position at the next layout
@interface HelpDocumentView : NSView
@end

@implementation HelpDocumentView

- (BOOL)isFlipped
{
  return YES;
}

@end

// a drawing of the menu bar's image (MenuRowsHelpExample), rendered offscreen: CpuRender starts by clearing its rect,
// which would punch a hole in the window, so it draws into a bitmap that the view then crops and shows on a strip
@interface HelpExampleView : NSView
- (instancetype)initWithStyle:(HelpExampleStyle)style readings:(const CpuReadings*)readings coreLoads:(const double*)coreLoads
                coreLoadCount:(int)coreLoadCount part:(MenuRowsExamplePart)part label:(NSString*)label
                 labelReading:(int)labelReading caption:(NSString*)caption;
@end

@implementation HelpExampleView
{
  HelpExampleStyle _style;
  bool _hasReadings;
  CpuReadings _readings;      // extra points at _extra, a copy
  CpuExtraReading* _extra;
  CpuSummaryInfo _info;       // the real core count, each core's load from coreLoads; now is freed in dealloc
  CGFloat _imageWidth;        // the whole image's width, in pt
  CGFloat _cropX, _cropWidth; // the part shown, in pt of the image
  CGFloat _zoom;
  NSString* _label;
  NSString* _caption;
  NSView* _labelView;         // the real hover label's box (NewTipPanel, SetTipText) in a shadow's container; nil: no label
  NSFont* _captionFont;
  NSImage* _image;            // the render, at the view's backing scale
  NSRect _strip, _labelBox;
  NSPoint _captionOrigin;
  NSSize _size;
}

- (instancetype)initWithStyle:(HelpExampleStyle)style readings:(const CpuReadings*)readings coreLoads:(const double*)coreLoads
                coreLoadCount:(int)coreLoadCount part:(MenuRowsExamplePart)part label:(NSString*)label
                 labelReading:(int)labelReading caption:(NSString*)caption
{
  self = [super initWithFrame:NSZeroRect];
  if (self == nil)
  {
    return nil;
  }
  _style = style;
  _label = [label copy];
  _caption = [caption copy];
  _hasReadings = (readings != NULL);
  if (_hasReadings)
  {
    _readings = *readings;
    HelpCoreReadings(coreLoads, coreLoadCount, &_readings);
    int count = MAX(_readings.extraCount, 0);
    _readings.extraCount = count;
    _extra = NULL;
    if ((count > 0) && (_readings.extra != NULL))
    {
      _extra = (CpuExtraReading*)malloc(count * sizeof(CpuExtraReading));
      memcpy(_extra, _readings.extra, count * sizeof(CpuExtraReading));
    }
    else
    {
      _readings.extraCount = 0;
    }
    _readings.extra = _extra;
  }
  _info.countLogical = style.countLogical;
  _info.now = (Ticks*)calloc(MAX(style.countLogical, 1), sizeof(Ticks));
  for (natural_t i=0; i<style.countLogical; i++)
  {
    _info.now[i].load = ((coreLoads != NULL) && (coreLoadCount > 0)) ? coreLoads[i % coreLoadCount] : 0.0;
  }

  // the five readings are drawn, the E-cores' and the P-cores' heading their own bars, as in the menu bar
  bool five = _hasReadings && !_readings.extraOnly;
  if (_hasReadings)
  {
    _readings.efficiencyBars = five ? style.coreSplit : 0;
  }
  // the optional readings (the battery's, Wi-Fi's, the Neural Engine's and the GPU's) go with the five readings
  unsigned shown = _hasReadings ? CpuRenderReadingsShown(&_readings) : 0;
  int extraCount = _hasReadings ? _readings.extraCount : 0;
  _imageWidth = style.graphWidth;
  if (five)
  {
    _imageWidth += CpuRenderReadingsWidth(style.bar, style.drawWidth, style.tickTotalWidth, shown, _readings.efficiencyBars, extraCount, _extra);
  }
  else if (_hasReadings)
  {
    _imageWidth += CpuRenderExtraWidth(style.bar, style.drawWidth, style.tickTotalWidth, extraCount, _extra);
  }
  int split = _hasReadings ? _readings.efficiencyBars : 0;
  _cropX = 0.0;
  _cropWidth = _imageWidth;
  if ((part == MenuRowsExampleReadings) && five)
  {
    // up to the last reading before the core graph: when the graph splits, the one before the E-cores', which heads
    // their bars
    int last = ((split > 0) ? CpuRenderReadingEfficiency(shown) : CpuRenderReadingsCount(shown)) - 1;
    _cropWidth = CpuRenderReadingX(style.bar, style.drawWidth, style.tickTotalWidth, shown, _imageWidth, split, CpuSamplerGetCount(style.granularity), extraCount, _extra, last) +
      CpuRenderReadingSlot(style.bar, style.drawWidth, style.tickTotalWidth, shown, extraCount, _extra, last);
  }
  else if ((part == MenuRowsExampleExtra) && (extraCount > 0))
  {
    _cropX = CpuRenderReadingX(style.bar, style.drawWidth, style.tickTotalWidth, shown, _imageWidth, split, CpuSamplerGetCount(style.granularity), extraCount, _extra, CpuRenderReadingsCount(shown));
    _cropWidth = _imageWidth - _cropX;
  }
  _cropWidth = MAX(_cropWidth, 1.0);
  // zoom 2, less when the strip would pass the text's width
  _zoom = HELP_EXAMPLE_ZOOM;
  if (_cropWidth*_zoom > HELP_EXAMPLE_TEXT_WIDTH - 2.0*HELP_EXAMPLE_PADDING)
  {
    _zoom = (HELP_EXAMPLE_TEXT_WIDTH - 2.0*HELP_EXAMPLE_PADDING) / _cropWidth;
  }

  // the layout, top down: the strip, the hover label's box, the caption
  NSSize stripSize = NSMakeSize(ceil(_cropWidth*_zoom + 2.0*HELP_EXAMPLE_PADDING), ceil(style.tickHeight*_zoom + 2.0*HELP_EXAMPLE_PADDING));
  CGFloat width = stripSize.width;
  CGFloat bottom = stripSize.height;
  NSSize boxSize = NSZeroSize;
  if (_label.length > 0)
  {
    // the box the status item's labels are: made and sized by NewTipPanel and SetTipText, unwrapped as a reading's and a
    // label with line breaks are, its view then taken out of the panel; the panel's window shadow is a layer shadow
    // on a container, since the effect view masks to its bounds
    NSTextField* tipText = nil;
    NSPanel* panel = NewTipPanel(&tipText);
    SetTipText(panel, tipText, _label, CGFLOAT_MAX);
    boxSize = panel.frame.size;
    NSView* effect = panel.contentView;
    panel.contentView = [[NSView alloc] init];
    effect.frame = NSMakeRect(0.0, 0.0, boxSize.width, boxSize.height);
    if ([effect isKindOfClass:[NSVisualEffectView class]])
    {
      ((NSVisualEffectView*)effect).blendingMode = NSVisualEffectBlendingModeWithinWindow;
    }
    _labelView = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, boxSize.width, boxSize.height)];
    _labelView.wantsLayer = YES;
    _labelView.layer.shadowColor = [NSColor blackColor].CGColor;
    _labelView.layer.shadowOpacity = 0.3;
    _labelView.layer.shadowRadius = 5.0;
    _labelView.layer.shadowOffset = CGSizeMake(0.0, -2.0);
    CGPathRef shadowPath = CGPathCreateWithRoundedRect(CGRectMake(0.0, 0.0, boxSize.width, boxSize.height), 5.0, 5.0, NULL);
    _labelView.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);
    [_labelView addSubview:effect];
    [_labelView setAccessibilityElement:NO];
    [self addSubview:_labelView];
    width = MAX(width, boxSize.width);
  }
  NSSize captionSize = NSZeroSize;
  if (_caption.length > 0)
  {
    _captionFont = [NSFont systemFontOfSize:11.0];
    captionSize = [_caption sizeWithAttributes:@{NSFontAttributeName: _captionFont}];
    captionSize = NSMakeSize(ceil(captionSize.width), ceil(captionSize.height));
    width = MAX(width, captionSize.width);
  }
  // with a label the strip stays at the left, under which the box is centred on its reading, kept inside the view
  _strip = NSMakeRect((_label.length > 0) ? 0.0 : floor((width - stripSize.width) / 2.0), 0.0, stripSize.width, stripSize.height);
  CGFloat centreX = NSMidX(_strip);
  if (_label.length > 0)
  {
    CGFloat readingMid;
    if (labelReading < 0)
    {
      CGFloat start = 0.0;
      CGFloat end = 0.0;
      CpuRenderGraphSpan(style.bar, style.drawWidth, style.tickTotalWidth, _imageWidth, five, shown, split, extraCount, _extra, &start, &end);
      readingMid = (start + end) / 2.0;
    }
    else
    {
      readingMid = CpuRenderReadingX(style.bar, style.drawWidth, style.tickTotalWidth, shown, _imageWidth, split, CpuSamplerGetCount(style.granularity), extraCount, _extra, labelReading) +
        CpuRenderReadingSlot(style.bar, style.drawWidth, style.tickTotalWidth, shown, extraCount, _extra, labelReading) / 2.0;
    }
    CGFloat x = NSMinX(_strip) + HELP_EXAMPLE_PADDING + (readingMid - _cropX)*_zoom - boxSize.width/2.0;
    x = MIN(MAX(x, 0.0), width - boxSize.width);
    _labelBox = NSMakeRect(floor(x), bottom + HELP_EXAMPLE_BELOW_GAP, boxSize.width, boxSize.height);
    _labelView.frame = _labelBox;
    bottom = NSMaxY(_labelBox);
    centreX = NSMidX(_labelBox);
  }
  if (_caption.length > 0)
  {
    CGFloat x = MIN(MAX(centreX - captionSize.width/2.0, 0.0), width - captionSize.width);
    _captionOrigin = NSMakePoint(floor(x), bottom + HELP_EXAMPLE_BELOW_GAP);
    bottom = _captionOrigin.y + captionSize.height;
  }
  _size = NSMakeSize(width, bottom);
  self.frame = NSMakeRect(0.0, 0.0, _size.width, _size.height);
  return self;
}

- (void)dealloc
{
  free(_extra);
  free(_info.now);
}

- (BOOL)isFlipped
{
  return YES;
}

- (NSSize)intrinsicContentSize
{
  return _size;
}

// renders the whole image into a bitmap, in the menu bar's colour for this view's appearance, at its backing scale
- (void)render
{
  CGFloat scale = self.window.backingScaleFactor;
  if (scale <= 0.0)
  {
    scale = NSScreen.mainScreen.backingScaleFactor;
  }
  if (scale <= 0.0)
  {
    scale = 2.0;
  }
  NSInteger pixelsWide = MAX((NSInteger)ceil(_imageWidth*_zoom*scale), 1);
  NSInteger pixelsHigh = MAX((NSInteger)ceil(_style.tickHeight*_zoom*scale), 1);
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                  pixelsWide:pixelsWide
                                                                  pixelsHigh:pixelsHigh
                                                               bitsPerSample:8
                                                             samplesPerPixel:4
                                                                    hasAlpha:YES
                                                                    isPlanar:NO
                                                              colorSpaceName:NSCalibratedRGBColorSpace
                                                                 bytesPerRow:0
                                                                bitsPerPixel:32];
  if (rep == nil)
  {
    return;
  }
  NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:context];
  CGContextRef ctx = context.CGContext;
  CGContextScaleCTM(ctx, (CGFloat)pixelsWide / _imageWidth, (CGFloat)pixelsHigh / _style.tickHeight);
  CpuRender(&_info, ctx, IsLight(self.effectiveAppearance), _style.granularity, _style.bar, _style.stripped, _style.colored,
            _style.drawWidth, _style.tickTotalWidth, _imageWidth, _style.theme, _hasReadings ? &_readings : NULL);
  [NSGraphicsContext restoreGraphicsState];
  rep.size = NSMakeSize(_imageWidth*_zoom, _style.tickHeight*_zoom);
  _image = [[NSImage alloc] initWithSize:rep.size];
  [_image addRepresentation:rep];
  [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance
{
  [super viewDidChangeEffectiveAppearance];
  [self render];
}

- (void)viewDidChangeBackingProperties
{
  [super viewDidChangeBackingProperties];
  [self render];
}

- (void)drawRect:(NSRect)dirtyRect
{
  if (_image == nil)
  {
    [self render];
  }
  bool light = IsLight(self.effectiveAppearance);
  [[NSColor colorWithWhite:light ? 0.92 : 0.16 alpha:1.0] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:_strip xRadius:HELP_EXAMPLE_RADIUS yRadius:HELP_EXAMPLE_RADIUS] fill];
  NSGraphicsContext* context = [NSGraphicsContext currentContext];
  context.imageInterpolation = NSImageInterpolationNone;
  NSRect target = NSMakeRect(NSMinX(_strip) + HELP_EXAMPLE_PADDING, NSMinY(_strip) + HELP_EXAMPLE_PADDING, _cropWidth*_zoom, _style.tickHeight*_zoom);
  NSRect source = NSMakeRect(_cropX*_zoom, 0.0, _cropWidth*_zoom, _style.tickHeight*_zoom);
  [_image drawInRect:target fromRect:source operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationNone)}];

  if (_caption.length > 0)
  {
    [_caption drawAtPoint:_captionOrigin withAttributes:@{NSFontAttributeName: _captionFont, NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}];
  }
}

- (BOOL)isAccessibilityElement
{
  return YES;
}

- (NSAccessibilityRole)accessibilityRole
{
  return NSAccessibilityImageRole;
}

- (NSString*)accessibilityLabel
{
  NSString* label = (_caption.length > 0) ? _caption : @"Example";
  if (_label.length > 0)
  {
    label = [NSString stringWithFormat:@"%@: %@", label, [_label stringByReplacingOccurrencesOfString:@"\n" withString:@", "]];
  }
  return label;
}

@end

// one paragraph of a card of the help window: a wrapping, selectable label, SETTINGS_ROW_INSET in from the card's edges,
// then its examples (HelpExampleView or any NSView) under it, left to right with HELP_EXAMPLE_GAP between them, wrapping
// to a new line when the next would pass the text's width. Laid out once, from each example's size: the geometry of the
// menu bar does not change while the app runs
static NSView* HelpRow(NSString* text, NSArray<NSView*>* examples)
{
  NSView* row = [[NSView alloc] init];
  NSTextField* label = [NSTextField wrappingLabelWithString:text];
  label.font = [NSFont systemFontOfSize:13.0];
  label.textColor = [NSColor labelColor];
  label.selectable = YES;
  label.preferredMaxLayoutWidth = SETTINGS_GROUP_WIDTH - 2.0*SETTINGS_ROW_INSET;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
    [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:HELP_ROW_PADDING],
    [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:SETTINGS_ROW_INSET],
    [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-SETTINGS_ROW_INSET],
  ]];
  if (examples.count == 0)
  {
    [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-HELP_ROW_PADDING].active = YES;
    return row;
  }

  // the examples' flow, in a view of its own: frames from the top left, each line as tall as its tallest example
  NSView* flow = [[NSView alloc] init];
  flow.translatesAutoresizingMaskIntoConstraints = NO;
  std::vector<NSRect> frames;
  CGFloat x = 0.0;
  CGFloat y = 0.0;
  CGFloat line = 0.0;
  for (NSView* example in examples)
  {
    NSSize size = example.fittingSize;
    if ((size.width <= 0.0) || (size.height <= 0.0))
    {
      size = example.frame.size;
    }
    if ((x > 0.0) && (x + size.width > HELP_EXAMPLE_TEXT_WIDTH))
    {
      x = 0.0;
      y += line + HELP_EXAMPLE_LINE_GAP;
      line = 0.0;
    }
    frames.push_back(NSMakeRect(x, y, size.width, size.height));
    x += size.width + HELP_EXAMPLE_GAP;
    line = MAX(line, size.height);
  }
  CGFloat height = y + line;
  for (NSUInteger i=0; i<examples.count; i++)
  {
    // the flow is not flipped: a frame's y counts from its bottom
    NSRect frame = frames[i];
    examples[i].frame = NSMakeRect(frame.origin.x, height - frame.origin.y - frame.size.height, frame.size.width, frame.size.height);
    [flow addSubview:examples[i]];
  }
  [row addSubview:flow];
  [NSLayoutConstraint activateConstraints:@[
    [flow.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:HELP_EXAMPLE_TEXT_GAP],
    [flow.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
    [flow.widthAnchor constraintEqualToConstant:HELP_EXAMPLE_TEXT_WIDTH],
    [flow.heightAnchor constraintEqualToConstant:height],
    [flow.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-HELP_ROW_PADDING],
  ]];
  return row;
}

// the entries of rows that are a non-empty NSString, or a pair of one and an NSArray (its NSViews kept, the rest
// skipped), as pairs of the text and its examples, in their order
static NSArray<NSArray*>* HelpValidRows(id rows)
{
  NSMutableArray<NSArray*>* valid = [[NSMutableArray alloc] init];
  if (![rows isKindOfClass:[NSArray class]])
  {
    return valid;
  }
  for (id row in (NSArray*)rows)
  {
    id text = row;
    NSMutableArray<NSView*>* examples = [[NSMutableArray alloc] init];
    if ([row isKindOfClass:[NSArray class]])
    {
      NSArray* pair = (NSArray*)row;
      if ((pair.count != 2) || ![pair[1] isKindOfClass:[NSArray class]])
      {
        continue;
      }
      text = pair[0];
      for (id example in (NSArray*)pair[1])
      {
        if ([example isKindOfClass:[NSView class]])
        {
          [examples addObject:example];
        }
      }
    }
    if ([text isKindOfClass:[NSString class]] && ([(NSString*)text length] > 0))
    {
      [valid addObject:@[text, examples]];
    }
  }
  return valid;
}

// an example of extra readings alone, wide bars of these values and nothing else set
static NSView* HelpExtraExample(const double* values, int count, NSString* caption)
{
  std::vector<CpuExtraReading> extra(count);
  for (int i=0; i<count; i++)
  {
    extra[i] = CpuExtraReading();
    extra[i].value = values[i];
  }
  CpuReadings readings = {};
  readings.extraCount = count;
  readings.extra = extra.data();
  readings.extraOnly = true;
  return MenuRowsHelpExample(&readings, NULL, 0, MenuRowsExampleExtra, nil, -1, caption);
}

// the help's sentences on the Neural Engine's bar, as this variant draws it
#if CPUTOPBARS_SANDBOXED
static NSString* const NeuralEngineHelp = @" The bar right before the GPU bar is the Neural Engine's: solid while it is powered on, empty while it is off. It turns on when an app gives it work and goes off a few seconds after the work ends, and may come on again for a few seconds about ten seconds later while that app stays open, so it shows that the Neural Engine was powered recently, not how hard it works.";
#else
static NSString* const NeuralEngineHelp = @" The bar right before the GPU bar is the Neural Engine's: like the GPU bar it fills, in the same colours, to the share of time it was busy, read from the Mac's own counters of the Neural Engine's memory traffic. On a Mac whose counters cannot be read it shows instead whether the Neural Engine is powered: solid while it is on, empty while it is off.";
#endif

// the help window: the "Menu bar" section, then each MenuRows class's section in registration order, under its
// heading (none for a class with no title or no valid row), each a card of paragraphs, in a scroll view as tall as the
// content up to HELP_MAX_HEIGHT. Asked of the classes once, here
static NSWindow* MakeHelpWindow(void)
{
  NSView* help = [[NSView alloc] init];
  help.translatesAutoresizingMaskIntoConstraints = NO;
  NSMutableArray<NSLayoutConstraint*>* constraints = [[NSMutableArray alloc] init];
  [constraints addObject:[help.widthAnchor constraintEqualToConstant:SETTINGS_WIDTH]];
  __block NSLayoutYAxisAnchor* below = help.topAnchor;
  __block CGFloat gap = SETTINGS_INSET_Y;
  void (^section)(NSString*, NSArray<NSArray*>*) = ^(NSString* title, NSArray<NSArray*>* paragraphs) {
    NSMutableArray<NSView*>* rows = [[NSMutableArray alloc] init];
    for (NSArray* paragraph in paragraphs)
    {
      [rows addObject:HelpRow(paragraph[0], paragraph[1])];
    }
    NSTextField* heading = MenuRowsSettingsHeading(title);
    NSView* card = MenuRowsSettingsCard(rows);
    for (NSView* view in @[heading, card])
    {
      [help addSubview:view];
      [constraints addObject:[view.topAnchor constraintEqualToAnchor:below constant:gap]];
      [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:help.leadingAnchor
                                                                constant:SETTINGS_INSET_X + ((view == heading) ? SETTINGS_HEADING_INSET : 0.0)]];
      below = view.bottomAnchor;
      gap = (view == heading) ? SETTINGS_HEADING_GAP : SETTINGS_SECTION_GAP;
    }
    [constraints addObject:[card.widthAnchor constraintEqualToConstant:SETTINGS_GROUP_WIDTH]];
  };

  // the examples' values: this Mac's cores take the loads in turn (on EEEEPPPP, the E cores low and the P cores higher),
  // and the CPU, E and P readings are read from them (HelpCoreReadings)
  static const double loads[] = {0.15, 0.30, 0.10, 0.25, 0.65, 0.40, 0.85, 0.50};
  const int loadCount = sizeof(loads) / sizeof(loads[0]);
  CpuReadings shared = {};
  shared.memory = 0.48;
  shared.disk = 0.62;
  // the battery's bar and Wi-Fi's, as the menu bar draws them by default on a Mac that has them: on battery at 87%, and
  // the Wi-Fi sample's signal
  const SystemInfoWifi wifiSample = HelpWifiSample();
  shared.batteryShown = true;
  shared.battery = 0.87;
  shared.wifiShown = true;
  shared.wifi = SystemInfoWifiFill(wifiSample.rssi);
  CpuReadings barsOff = shared;
  barsOff.extraOnly = true;
  // the same with the GPU's bar and the Neural Engine's, as the menu bar draws them by default, the Neural Engine on:
  // the readings example, which shows it
  CpuReadings withGpu = shared;
  withGpu.gpuShown = true;
  withGpu.gpu = 0.35;
  withGpu.neuralEngine = 1;
#if !CPUTOPBARS_SANDBOXED
  // the unsandboxed variant draws it by its share of time busy, as the menu bar does where IOReport can be read
  withGpu.neuralEngineByShare = true;
  withGpu.neuralEngineBusy = 0.40;
#endif
  // and with the Neural Engine off: every other whole menu bar shown below but "bars off"
  CpuReadings engineOff = withGpu;
  engineOff.neuralEngine = 0;
  engineOff.neuralEngineBusy = 0.0;
  // the battery's paragraph: charging, plugged in and not charging, and on battery with Wi-Fi off
  CpuReadings charging = withGpu;
  charging.batteryCharging = true;
  charging.batteryOnAC = true;
  CpuReadings pluggedIn = withGpu;
  pluggedIn.batteryOnAC = true;
  CpuReadings wifiOff = withGpu;
  wifiOff.wifi = -1.0;
  const double fills[] = {0.0, 0.20, 0.50, 0.70, 1.00};
  const double colours[] = {0.10, 0.30, 0.50, 0.75, 1.00};

  // the hover labels, worded as the real ones are (HelpDiskLabel, HelpCoresExamples), each under its own reading
  const unsigned engineOffShown = CpuRenderReadingsShown(&engineOff);
  NSMutableArray<NSView*>* hoverExamples = [NSMutableArray arrayWithObject:
    MenuRowsHelpExample(&engineOff, loads, loadCount, MenuRowsExampleWhole, HelpDiskLabel(&engineOff), CpuRenderReadingIndex(engineOffShown, CPU_RENDER_KIND_DISK), @"a bar")];
  [hoverExamples addObject:MenuRowsHelpExample(&engineOff, loads, loadCount, MenuRowsExampleWhole, HelpBatteryLabel(&engineOff), CpuRenderReadingIndex(engineOffShown, CPU_RENDER_KIND_BATTERY), @"the battery bar")];
  [hoverExamples addObject:MenuRowsHelpExample(&engineOff, loads, loadCount, MenuRowsExampleWhole, HelpWifiLabel(), CpuRenderReadingIndex(engineOffShown, CPU_RENDER_KIND_WIFI), @"the Wi-Fi bar")];
  [hoverExamples addObject:MenuRowsHelpExample(&engineOff, loads, loadCount, MenuRowsExampleWhole, HelpGpuLabel(&engineOff), CpuRenderReadingIndex(engineOffShown, CPU_RENDER_KIND_GPU), @"the GPU bar")];
  [hoverExamples addObjectsFromArray:HelpCoresExamples(&engineOff, loads, loadCount)];

  section(@"Menu bar", @[
    @[
      [@"Wide bars show the battery's charge, the Wi-Fi signal, the startup volume's used space (disk), the memory in use, the GPU's load, and the CPU's, overall and for the efficiency cores (E) and the performance cores (P). Battery, Wi-Fi, disk, memory, Neural Engine, GPU and CPU come first, on the left, in that order; the E and P bars are shown with the cores, below." stringByAppendingString:NeuralEngineHelp],
      @[MenuRowsHelpExample(&withGpu, loads, loadCount, MenuRowsExampleReadings, nil, -1, HelpReadingsCaption(&withGpu))],
    ],
    @[
      @"On a Mac with a battery, the first bar is the battery, drawn as one: an outline in white (black on a light menu bar) with a solid cap at its top, filled inside to its charge in the same white over the faint background, with a lightning bolt over it: red on battery, green while it charges (red on a light menu bar), and black (white on a light menu bar) while it is plugged in and not charging. Next is Wi-Fi: its five segments light from the bottom with the signal, one at -78 dBm or weaker, one more for each 12 dB stronger, and all five from -41 dBm; with Wi-Fi off or not connected only its faint segments show. A small gap then sets battery, Wi-Fi, disk and memory apart from the Neural Engine, GPU and CPU. The network's name is not shown, so the app asks for no Location Services permission.",
      @[
        MenuRowsHelpExample(&charging, loads, loadCount, MenuRowsExampleReadings, nil, -1, @"charging"),
        MenuRowsHelpExample(&pluggedIn, loads, loadCount, MenuRowsExampleReadings, nil, -1, @"plugged in, not charging"),
        MenuRowsHelpExample(&wifiOff, loads, loadCount, MenuRowsExampleReadings, nil, -1, @"on battery, Wi-Fi off"),
      ],
    ],
    @[
      @"Each narrow bar is one CPU core. When the Mac lists its efficiency cores first, the E bar stands at the head of the efficiency cores' bars and the P bar at the head of the performance cores' bars, each group after a small gap; otherwise the E and P bars follow the CPU bar.",
      @[MenuRowsHelpExample(&engineOff, loads, loadCount, MenuRowsExampleWhole, nil, -1, @"this Mac's cores")],
    ],
    @[
      @"A bar fills from the bottom: empty is 0%, full is 100%. The faint column behind it is its full height, and each of its five dashes is a fifth; the top dash can be partly filled.",
      @[HelpExtraExample(fills, 5, @"0%, 20%, 50%, 70%, 100%")],
    ],
    @[
      @"The colour shows the same value: blue when idle, then green and yellow, to red at full load, and the more is in use, the more solid the colour.",
      @[HelpExtraExample(colours, 5, @"idle to full load")],
    ],
    @[
      @"Rest the pointer on a bar for a second to see its value below the menu bar. On the core bars it lists each core's load; when the cores are grouped, each group's label starts with its kind's reading.",
      hoverExamples,
    ],
    @[
      @"In Settings, \"Show Disk, RAM, CPU, E-core, P-core bars\" turns the wide bars off and leaves the core bars, \"Show battery and Wi-Fi bars\" turns those two off, \"Show GPU and Neural Engine bars\" those two, \"Show letters under the bars\" the letter under each wide bar (B battery, W Wi-Fi, D disk, M memory, N Neural Engine, G GPU, C CPU, E and P the efficiency and performance cores), and \"Refresh\" sets how often the bars move.",
      @[
        MenuRowsHelpExample(&engineOff, loads, loadCount, MenuRowsExampleWhole, nil, -1, @"bars on"),
        MenuRowsHelpExample(&barsOff, loads, loadCount, MenuRowsExampleWhole, nil, -1, @"bars off"),
      ],
    ],
  ]);

  // each class's section, with a title and at least one valid row
  for (id<MenuRows> rows in menuRows)
  {
    if (![rows respondsToSelector:@selector(helpTitle)] || ![rows respondsToSelector:@selector(helpRows)])
    {
      continue;
    }
    id title = [rows helpTitle];
    NSArray<NSArray*>* valid = HelpValidRows([rows helpRows]);
    if ([title isKindOfClass:[NSString class]] && ([(NSString*)title length] > 0) && (valid.count > 0))
    {
      section(title, valid);
    }
  }
  [constraints addObject:[below constraintEqualToAnchor:help.bottomAnchor constant:-SETTINGS_INSET_Y]];
  [NSLayoutConstraint activateConstraints:constraints];

  NSSize size = help.fittingSize;
  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, SETTINGS_WIDTH, MIN(size.height, HELP_MAX_HEIGHT))];
  scroll.drawsBackground = NO;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.autohidesScrollers = YES;
  // the content hangs from the document view's top left
  HelpDocumentView* document = [[HelpDocumentView alloc] initWithFrame:NSMakeRect(0.0, 0.0, size.width, size.height)];
  [document addSubview:help];
  [NSLayoutConstraint activateConstraints:@[
    [help.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
    [help.topAnchor constraintEqualToAnchor:document.topAnchor],
  ]];
  scroll.documentView = document;

  NSWindow* window = [[NSWindow alloc] initWithContentRect:scroll.frame
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.title = @"How to Read the Menu Bar";
  window.releasedWhenClosed = NO;
  window.contentView = scroll;
  return window;
}

@implementation AppDelegate

static CpuSummaryInfo cpu_info;
static char* cpuKinds = NULL;     // each logical CPU's kind, 'P' or 'E' (CpuSamplerGetKinds); NULL when not read
static CpuSummaryInfo cpu_sine_demo_info;
static CpuSummaryInfo cpu_flat_demo_info;

static NSMenu* menu = nil;

static NSTimer* timerCPU = nil;

static NSTimer* timerTop = nil;
static TopProcessSample_t topProcceses[TOP_COUNT];
static NSMenuItem* topMenus[TOP_COUNT];
static NSMutableDictionary<NSString*, NSString*>* topNameCache = nil; // padded names, by display text
static NSMutableDictionary<NSString*, NSString*>* topMemCache = nil;  // padded memory texts, by text
static CFMutableDictionaryRef topCpuHashTable;
static NSMutableDictionary<NSNumber*, ProcessIconDecision*>* topIconCache = nil; // by pid

static bool refreshTop = false;
static bool menuIsOpen = false;            // from menuWillOpen: to menuDidClose:
// the last sample is the baseline taken at the unfreeze, whose CPU% averages over the freeze: the rows wait for the
// next one (updateMenuTop)
static bool baselineOnly = false;
static bool topListValid = false;
static int topCount = 0;
static int topShown = TOP_COUNT;         // the process rows shown, from Settings (TopRows)
static TopOrder topOrder;                 // the order of the rows; TopOrderCpu (0) until set
static int topOthersCount = 0;            // other users' processes at the last sample, whose CPU cannot be read
static NSMenuItem* othersItem = nil;      // the row below the process rows that counts them
#if !CPUTOPBARS_SANDBOXED
// while the menu is open, /usr/bin/top gives the CPU of the other users' processes too (startTopTool)
static NSMutableDictionary<NSNumber*, NSNumber*>* topFigures = nil; // % of one core, by pid; nil until a block has come
static TopToolSession* topToolSession = nil;
static NSUInteger topToolGeneration = 0;
#endif
static NSTimeInterval lastTopSample = 0.0;
#define TOP_MIN_INTERVAL (0.25)

// The graph and the process samples pause while nothing can be seen: the displays asleep, the Mac going to sleep,
// or another user's session in front. Each has its own flag; the timers run again once all are clear (updatePause).
static bool screensAsleep = false;
static bool systemAsleep = false;
static bool sessionInactive = false;
static bool paused = false;

// Freeze (an item in the status menu whose check mark is its image): while frozen the rows keep what they
// showed, nothing is sampled for them; the menu-bar CPU graph keeps moving.
// frozenStarts holds each row's process start time, read when Freeze was chosen (0 = already gone).
static bool frozen = false;
static NSMutableDictionary<NSNumber*, NSNumber*>* frozenStarts = nil; // by pid
static NSImage* freezeOffImage = nil;       // Freeze's image when not frozen: blank, the size of the menu icons
static NSImage* freezeOnImage = nil;        // and while frozen: a check mark
static NSMenuItem* freezeItem = nil;        // always shown, so the readings panel finds the open menu by it

static NSPanel* rowTip = nil;               // the helper text box, left of the menu (frozen only)
static NSTextField* rowTipText = nil;
static NSMenuItem* rowTipItem = nil;        // the row whose text shows, or is about to
static NSRect rowTipRow;                    // that row on screen, and the menu's window, while its text shows
static NSWindow* rowTipMenuWindow = nil;

static NSPanel* infoPanel = nil;            // the readings beside the menu (see "The readings panel beside the menu")
static NSGlassEffectView* infoGlass = nil;  // its background
static NSArray<NSTextField*>* infoLabels = nil;
static NSArray<NSTextField*>* infoValues = nil;
static NSArray<NSBox*>* infoSeparators = nil; // menu-style lines, one above each row of infoSeparatorRows
static NSIndexSet* infoSeparatorRows = nil; // the first row of each section after Uptime, the first row (the readings: 1)
static NSTimer* infoTimer = nil;            // while the menu is open
static bool infoPlaced = false;             // the panel was placed in this opening
static bool infoRetried = false;            // the menu's window was looked for a second time in this opening
static bool infoSideDecided = false;        // its side is decided once per opening,
static bool infoOnLeft = true;
static CGFloat infoWidth = 0.0;             // and it only widens within one
static NSWindow* infoMenuWindow = nil;      // the menu's window it is placed beside
static NSUInteger infoGeneration = 0;       // bumped when the menu closes: a disk read for an earlier opening is not shown
static bool diskReadInFlight = false;
static NSTimeInterval lastDiskRead = 0.0;   // when the last disk read started, system uptime
static NSTimeInterval lastDiskAttempt = 0.0; // when the last disk read started, never reset: a failing read is retried once a minute
static double diskFraction = -1.0;          // how full the volume was at the last reading, 0..1, -1 before the first
static NSString* diskText = nil;            // the last reading of the startup volume ("72% (free 279 GB, used 716 GB)"), nil before the first
static NSString* diskTipText = nil;         // the hover label's lines, "Disk usage:", "Free:", "Used:" and "Total:", one value to a line
static NSString* diskTitle = nil;           // its title, with the volume's size ("995GB Disk usage:")
static NSTimeInterval lastReadings = 0.0;   // when overall CPU and memory were last read, system uptime; 0: read soon
static double readingsCpu = -1.0;           // overall CPU over the 1 s before it (after a reset, one tick), 0..1, -1 before the first
static double readingsCpuEfficiency = -1.0; // the E-cores' and the P-cores' over the same window, read with it; -1: not read
static double readingsCpuPerformance = -1.0;
static std::vector<double> readingsCpuEach; // each logical CPU's over the same window, read with it, in CpuSampler's order (-1: no ticks); empty: not read
static double readingsGpu = -1.0;           // the GPU's busy share, 0..1, read with them while the GPU's bar is shown; -1: not read
static int readingsNeuralEngine = -1;       // the Neural Engine's power: 1 on, 0 off, -1 not read
static double readingsNeuralEngineBusy = -1.0; // its share of time busy, 0..1, from IOReport, read with them; -1: not read
                                               // (always in the sandboxed variant), and ON/OFF is shown instead
static double readingsGpuWatts = -1.0;      // the GPU's power in W, from IOReport, read with them; -1: not read
static bool readingsMemory = false;         // memory could be read, as these two bytes
static uint64_t readingsMemoryUsed = 0;
static uint64_t readingsMemoryTotal = 0;
static bool readingsSwap = false;           // swap could be read, as these bytes, read with memory
static uint64_t readingsSwapUsed = 0;
// the battery and Wi-Fi, read every BATTERY_WIFI_REFRESH s while their bars are shown (readBatteryWifi:), dropped while not
static NSTimeInterval lastBatteryWifi = 0.0; // when they were last read, system uptime; 0: read at the next tick
static bool readingsBattery = false;        // this Mac's internal battery was read, as readingsBatteryState
static SystemInfoBattery readingsBatteryState = {};
static SystemInfoWifi readingsWifi = {};    // Wi-Fi as last read (WifiRead); present false: no Wi-Fi interface, or not read
// while Wi-Fi's hover label is up and Wi-Fi connected: the interface's IPv4 and MAC addresses and its router, read in full
// reads only (readWifi:); empty: not read. Shown in that label, never logged
static char readingsWifiIp[64] = "";
static char readingsWifiMac[64] = "";
static char readingsWifiRouter[64] = "";

#define BAR_WIDTH_EXTRA             (1.0)   // pt each bar is drawn wider than its width setting

static CGFloat tickHeight = 16.0;
static CGFloat tickWidth = 3.0;      // the width setting: 1 Thin, 2 Standard, 3 Thick; a bar is drawn BAR_WIDTH_EXTRA wider
static CGFloat tickSpaceWidth = 1.0;
static CGFloat tickTotalWidth = 0.0;
static CGFloat imageWidth = 0.0;
static CGFloat graphWidth = 0.0;     // the core graph alone, as the sine and flat previews draw it: imageWidth without the bars
static CGFloat drawWidth = 3.0;      // the width each bar or dot is drawn: the width setting plus BAR_WIDTH_EXTRA, 4 for the one package bar, 3 for dots; core bars past CPU_RENDER_THIN_FROM are thinner (CpuRenderCoreWidth)

static int granularity = 0;
static int coreSplit = 0;            // the core graph's E-cores' bars, which the E-cores' bar heads, the P-cores' bar after them (CpuRenderEfficiencyBars); 0: the five bars in one block

static bool bar = true;

static bool stripped = true;

static bool colored = false;
static int theme = THEME_YELLOW;

static bool showBars = true;         // the disk, memory, CPU, E-cores' and P-cores' bars left of the graph
static bool showGpuNeuralEngine = true; // with them, the GPU's bar and the Neural Engine's
static bool showBatteryWifi = true;  // with them, the battery's bar and Wi-Fi's
static bool showBarLetters = true;   // with them, the block's letters under its bars, in the menu bar only
// whether the GPU's bar and the Neural Engine's are drawn, read and listed: only with the bars they belong to
static bool GpuShown(void)
{
  return showBars && showGpuNeuralEngine;
}
// whether the battery and Wi-Fi are read, and their bars drawn and rows listed on a Mac that has them: the same
static bool BatteryWifiShown(void)
{
  return showBars && showBatteryWifi;
}
// the optional readings drawn (CPU_RENDER_SHOWN_*): the GPU's and the Neural Engine's with GpuShown, the battery's and
// Wi-Fi's with BatteryWifiShown, each only while this Mac has it as last read (no internal battery, no Wi-Fi interface:
// no slot). One mask for the image's width, the readings drawn, the hover labels and the panel
static unsigned ReadingsShown(void)
{
  unsigned shown = GpuShown() ? CPU_RENDER_SHOWN_GPU : 0;
  if (BatteryWifiShown())
  {
    shown |= readingsWifi.present ? CPU_RENDER_SHOWN_WIFI : 0;
    shown |= readingsBattery ? CPU_RENDER_SHOWN_BATTERY : 0;
  }
  return shown;
}
// the bars MenuRows classes add right of the graph, read each tick (collectExtraBars): cleared and filled again at each
// one, so a pointer into extraBars is good only until the next; each one's value, mark, tint, alert and group
static std::vector<CpuExtraReading> extraBars;
static std::vector<NSUInteger> extraBarOwner; // each one's class, as its index in menuRows,
static std::vector<NSUInteger> extraBarItem;  // and its index in that class's barReadings and barLabels

static float speed = 1.0f;

// the app's own Settings controls, made by setupSettings
static NSSegmentedControl* refreshChoice = nil;  // Refresh: 10, 5 or 2 times a second
static NSSegmentedControl* topRowsChoice = nil;  // Top processes: its segments' counts are topRowsChoices
static NSSwitch* showBarsSwitch = nil;           // Show Disk, RAM, CPU, E-core, P-core bars
static NSSwitch* showGpuSwitch = nil;            // Show GPU and Neural Engine bars
static NSSwitch* showBatteryWifiSwitch = nil;    // Show battery and Wi-Fi bars
static NSSwitch* showBarLettersSwitch = nil;     // Show letters under the bars
static NSSwitch* loginSwitch = nil;              // Launch at login
static const int topRowsChoices[] = {3, 5, 10, TOP_COUNT};
#define TOP_ROWS_CHOICES (sizeof(topRowsChoices)/sizeof(topRowsChoices[0]))

// the Refresh segment of the current speed (ten times the interval): 0.1, 0.2 or 0.5 s
static NSInteger RefreshChoiceIndex(void)
{
  return (speed == 1.0f) ? 0 : ((speed == 2.0f) ? 1 : 2);
}

// the Top processes segment of the rows shown, -1 for none
static NSInteger TopRowsChoiceIndex(void)
{
  for (NSUInteger n=0; n<TOP_ROWS_CHOICES; n++)
  {
    if (topRowsChoices[n] == topShown)
    {
      return (NSInteger)n;
    }
  }
  return -1;
}

static NSDictionary* attributesStandard = nil;
static NSDictionary* attributesPad = nil;      // the hair spaces that pad a process row's columns
static NSDictionary* attributesGrey = nil;
static NSDictionary* attributesWhite = nil;

static double spaceWidth = 0.0;
static CGFloat memTarget = 0.0;           // the width of the memory column

static NSNumber *current_process_pid = nil;
#if !CPUTOPBARS_SANDBOXED
// the inspector's lsof, nm and sample tabs; each *Job holds the inspectGeneration it runs for, 0 when it has finished
static NSString *current_process_path = nil;
static NSUInteger lsofJob = 0;
static NSUInteger nmJob = 0;
static NSUInteger threadsJob = 0;
static NSUInteger threadsRun = 0;
static NSTextView* procLsofTextView = nil;
static NSTextView* procNmTextView = nil;
static NSTextView* procThreadsTextView = nil;
#endif

// The inspector's man page tool runs on a background queue. Every selection bumps
// inspectGeneration, and a result that belongs to an older selection is dropped. Main thread only.
static NSUInteger inspectGeneration = 0;
static NSMutableSet<NSTask*>* runningTasks = nil;
#define TOOL_OUTPUT_MAX (1024*1024) // characters shown; laying out tens of MB blocks the main thread for seconds

- (void)runTool:(NSString*)tool arguments:(NSArray<NSString*>*)arguments withStderr:(BOOL)withStderr done:(void (^)(NSString* output))done
{
  NSUInteger generation = inspectGeneration;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSTask *task = [[NSTask alloc] init];
    [task setExecutableURL:[NSURL fileURLWithPath:tool]];
    [task setArguments:arguments];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:(withStderr ? pipe : [NSFileHandle fileHandleWithNullDevice])];

    NSString *output = nil;
    if ([task launchAndReturnError:nil])
    {
      @synchronized (runningTasks)
      {
        [runningTasks addObject:task];
      }
      // read everything BEFORE waiting: a tool whose output fills the pipe never exits while nobody reads
      NSData *data = [[pipe fileHandleForReading] readDataToEndOfFileAndReturnError:nil];
      [task waitUntilExit];
      if (data == nil)
      {
        data = [NSData data];
      }
      @synchronized (runningTasks)
      {
        [runningTasks removeObject:task];
      }
      output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (output == nil)
      {
        output = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
      }
      if ([output length] > TOOL_OUTPUT_MAX)
      {
        NSRange cut = [output rangeOfComposedCharacterSequenceAtIndex:TOOL_OUTPUT_MAX];
        output = [[output substringToIndex:cut.location] stringByAppendingFormat:@"\n\n... (truncated: %lu characters in total)\n", (unsigned long)[output length]];
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation == inspectGeneration)
      {
        done(output);
      }
    });
  });
}

- (void)stopInspectorTools
{
  @synchronized (runningTasks)
  {
    for (NSTask *task in runningTasks)
    {
      if ([task isRunning])
      {
        [task terminate];
      }
    }
  }
}

- (void)launchAppAt:(NSString*)path with:(NSArray<NSString *> *)arguments
{
  NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
  [configuration setArguments:arguments];
  [configuration setPromptsUserIfNeeded:YES];
  [configuration setAddsToRecentItems:NO];
  [configuration setActivates:YES];
  [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:path] configuration:configuration completionHandler:^(NSRunningApplication* app, NSError* error)
  {
    if (error)
    {
      NSLog(@"launchAppAt error: %@", error.localizedDescription);
    }
  }];
}

- (void)updateRendererParameters
{
  double tickSpace = tickWidth + BAR_WIDTH_EXTRA;
  natural_t count = CpuSamplerGetCount(granularity);
  if (bar == NO)
  {
    tickSpace = 7.0;
  }
  else if (count == 1)
  {
    tickSpace = 4.0;
  }
  tickTotalWidth = tickSpace + tickSpaceWidth;
  drawWidth = !bar ? 3.0 : ((count == 1) ? 4.0 : (tickWidth + BAR_WIDTH_EXTRA));
  imageWidth = count * CpuRenderCoreSlot(bar, drawWidth, tickTotalWidth, count);
  if (bar == NO)
  {
    imageWidth += 1.0;
  }
  graphWidth = imageWidth;
  coreSplit = CpuRenderEfficiencyBars(granularity, cpu_info.countLogical, cpuKinds);
  if (showBars)
  {
    imageWidth += CpuRenderReadingsWidth(bar, drawWidth, tickTotalWidth, ReadingsShown(), coreSplit, (int)extraBars.size(), extraBars.data());
  }
  else
  {
    // the five readings are off; the extra bars, if any, still follow the core graph (0 with none)
    imageWidth += CpuRenderExtraWidth(bar, drawWidth, tickTotalWidth, (int)extraBars.size(), extraBars.data());
  }
}

- (void)updateUI
{
  [self.packageButton setState:NSControlStateValueOff];
  [self.coreButton setState:NSControlStateValueOff];
  [self.logicalButton setState:NSControlStateValueOff];
  
  [self.barButton setState:NSControlStateValueOff];
  [self.dotButton setState:NSControlStateValueOff];
  
  [self.solidButton setState:NSControlStateValueOff];
  [self.strippedButton setState:NSControlStateValueOff];
  
  [self.thinButton setState:NSControlStateValueOff];
  [self.standardButton setState:NSControlStateValueOff];
  [self.thickButton setState:NSControlStateValueOff];
  
  [self.greyButton setState:NSControlStateValueOff];
  [self.colorButton setState:NSControlStateValueOff];
  
  [self.yellowButton setState:NSControlStateValueOff];
  [self.greenButton setState:NSControlStateValueOff];
  [self.blueButton setState:NSControlStateValueOff];

  showBarsSwitch.state = showBars ? NSControlStateValueOn : NSControlStateValueOff;
  showGpuSwitch.state = showGpuNeuralEngine ? NSControlStateValueOn : NSControlStateValueOff;
  showGpuSwitch.enabled = showBars;
  showBatteryWifiSwitch.state = showBatteryWifi ? NSControlStateValueOn : NSControlStateValueOff;
  showBatteryWifiSwitch.enabled = showBars;
  showBarLettersSwitch.state = showBarLetters ? NSControlStateValueOn : NSControlStateValueOff;
  showBarLettersSwitch.enabled = showBars;
  topRowsChoice.selectedSegment = TopRowsChoiceIndex();
    
  if (granularity == 0)
  {
    [self.packageButton setState:NSControlStateValueOn];

    [self.thinButton setEnabled:NO];
    [self.standardButton setEnabled:NO];
    [self.thickButton setEnabled:NO];
  }
  else if (granularity == 1)
  {
    [self.coreButton setState:NSControlStateValueOn];
    
    if (bar)
    {
      [self.thinButton setEnabled:YES];
      [self.standardButton setEnabled:YES];
      [self.thickButton setEnabled:YES];
    }
  }
  else
  {
    [self.logicalButton setState:NSControlStateValueOn];

    [self.thinButton setEnabled:YES];
    [self.standardButton setEnabled:YES];
    [self.thickButton setEnabled:YES];
  }
  
  if (bar)
  {
    [self.barButton setState:NSControlStateValueOn];
    [self.dotButton setState:NSControlStateValueOff];

    [self.solidButton setEnabled:YES];
    [self.strippedButton setEnabled:YES];
    if (granularity != 0)
    {
      [self.thinButton setEnabled:YES];
      [self.standardButton setEnabled:YES];
      [self.thickButton setEnabled:YES];
    }
    
    [self.greyButton setEnabled:YES];
  }
  else
  {
    colored = true;
    
    [self.barButton setState:NSControlStateValueOff];
    [self.dotButton setState:NSControlStateValueOn];

    [self.solidButton setEnabled:NO];
    [self.strippedButton setEnabled:NO];
    [self.thinButton setEnabled:NO];
    [self.standardButton setEnabled:NO];
    [self.thickButton setEnabled:NO];

    [self.greyButton setEnabled:NO];
  }
  
  if (!stripped)
  {
    [self.solidButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.strippedButton setState:NSControlStateValueOn];
  }
  
  if (tickWidth == 1.0)
  {
    [self.thinButton setState:NSControlStateValueOn];
  }
  else if (tickWidth == 2.0)
  {
    [self.standardButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.thickButton setState:NSControlStateValueOn];
  }
  
  refreshChoice.selectedSegment = RefreshChoiceIndex();
  
  if (!colored)
  {
    [self.greyButton setState:NSControlStateValueOn];

    [self.yellowButton setEnabled:NO];
    [self.greenButton setEnabled:NO];
    [self.blueButton setEnabled:NO];
  }
  else
  {
    [self.colorButton setState:NSControlStateValueOn];

    [self.yellowButton setEnabled:YES];
    [self.greenButton setEnabled:YES];
    [self.blueButton setEnabled:YES];
  }
  
  if (theme == THEME_GREEN)
  {
    [self.greenButton setState:NSControlStateValueOn];
  }
  else if (theme == THEME_BLUE)
  {
    [self.blueButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.yellowButton setState:NSControlStateValueOn];
  }
}

- (int)getSpacesCountFor:(NSMutableString*)string width:(CGFloat)target
{
  CGFloat test_width = [string sizeWithAttributes:attributesGrey].width;
  CGFloat room = target - test_width;
  int count = (int)round(room / spaceWidth);
  //printf("  spaces %d\n", spaces);

  CGFloat actualLeft = test_width + ((count-1) * spaceWidth);
  CGFloat diffLeft = fabs(target-actualLeft);
  //printf("  diffLeft %f %f\n", diffLeft, actualLeft);
  CGFloat actual = test_width + (count * spaceWidth);
  CGFloat diff = fabs(target-actual);
  //printf("  diff %f %f\n", diff, actual);
  CGFloat actualRight = test_width + ((count+1) * spaceWidth);
  CGFloat diffRight = fabs(target-actualRight);
  //printf("  diffRight %f %f\n", diffRight, actualRight);
  
  if (diffLeft < diffRight)
  {
    if (diffLeft < diff)
    {
      count--;
    }
  }
  else
  {
    if (diffRight < diff)
    {
      count++;
    }
  }
  return count;
}

#define SIZE_SPACES 4096
static unichar spaces[SIZE_SPACES];
static BOOL spaces_init = NO;

- (NSString*)getStringForCpu:(double)cpu width:(CGFloat)target
{
  if (cpu > 999.0)
  {
    cpu = 999.0;
  }
  
  NSMutableString* string = nil;
  const void* key = NULL;
  int integer = round(cpu * 10.0);
  if (cpu <= 10.0)
  {
    key = (const void *)(uintptr_t)integer;
    if (key == NULL)
    {
      key = (const void*)0xffffffff;
    }
  }
  if ((key==NULL) || !CFDictionaryContainsKey(topCpuHashTable, key))
  {
    string = [NSMutableString stringWithFormat:@"%6.1f%%", ((double)integer/10.0)];
    // none when the text is wider than the column: in the menu font its seven cells are 50.4 pt
    int count = MAX([self getSpacesCountFor:string width:target], 0);
    [string insertString:[NSString stringWithCharacters:&spaces[0] length:count] atIndex:0];
    
    if (key != NULL)
    {
      CFDictionarySetValue(topCpuHashTable, key, (__bridge const void *)(string));
    }
  }
  if (key != NULL)
  {
    return (NSString*)CFDictionaryGetValue(topCpuHashTable, key);
  }
  else
  {
    return string;
  }
  //return [NSString stringWithFormat:@"%--s %*c %6.1f%%", name, spaces, SPACE_THIN, cpu];
}

- (NSString*)getStringForMem:(uint64_t)mem known:(int)known width:(CGFloat)target
{
  NSString* text = (known != 0) ? MemoryText(mem) : @"—";
  NSString* padded = topMemCache[text];
  if (padded == nil)
  {
    NSMutableString* string = [NSMutableString stringWithString:text];
    int count = MAX([self getSpacesCountFor:string width:target], 0);
    [string insertString:[NSString stringWithCharacters:&spaces[0] length:count] atIndex:0];
    padded = [string copy];
    topMemCache[text] = padded;
  }
  return padded;
}

- (NSString*)getStringForName:(NSString*)name width:(CGFloat)target
{
  // keyed by the text shown, so a process that exec'd shows its new name
  NSString* padded = topNameCache[name];
  if (padded == nil)
  {
    NSMutableString* string = [NSMutableString stringWithString:name];
    int count = [self getSpacesCountFor:string width:target];
    if (count < 0)
    {
      // whole characters go (an emoji is two UTF-16 units, and an accent can be a unit of its own) until the rest and
      // one ellipsis, a single cell of the menu font, fit; a name that fits exactly fills the column's last cell
      while ((count < 0) && ([string length] > 0))
      {
        [string deleteCharactersInRange:[string rangeOfComposedCharacterSequenceAtIndex:[string length]-1]];
        count = [self getSpacesCountFor:[NSMutableString stringWithFormat:@"%@%C", string, (unichar)0x2026] width:target];
      }
      [string appendFormat:@"%C", (unichar)0x2026];
      if (count < 0)
      {
        // only when the ellipsis alone is wider than the target
        count = 0;
      }
    }

    size_t length = [string length];
    if (length > SIZE_SPACES)
    {
      length = SIZE_SPACES;
    }
    [string insertString:[NSString stringWithCharacters:&spaces[0] length:count] atIndex:length];

    padded = string;
    topNameCache[name] = padded;
  }
  return padded;
  //return [NSString stringWithFormat:@"%--s %*c %6.1f%%", name, spaces, SPACE_THIN, cpu];
}

// Decided once per pid, and again when the pid runs another executable. Not redone when the process
// is reparented (to launchd, when its parent exits) or when a reused pid runs the same executable.
- (ProcessIconDecision*)decisionForPid:(pid_t)pid
{
  NSNumber* key = [NSNumber numberWithInt:pid];
  NSString* path = ProcessPath(pid);
  ProcessIconDecision* decision = topIconCache[key];
  if ((decision == nil) || !((decision.path == path) || [decision.path isEqualToString:path]))
  {
    decision = DecideProcessIcon(pid, path);
    topIconCache[key] = decision;
  }
  return decision;
}

// drops the decisions of pids that are gone; call after every TopSample
- (void)pruneIconCache
{
  for (NSNumber* key in [topIconCache allKeys])
  {
    if (TopGetSample([key intValue]) == NULL)
    {
      [topIconCache removeObjectForKey:key];
    }
  }
}

// the hair spaces that pad a row's columns, in the padding font: in the monospaced menu font each is a whole cell wide,
// too coarse to line the columns up
static void SetPaddingFont(NSMutableAttributedString* title)
{
  NSString* string = title.string;
  NSFont* font = attributesPad[NSFontAttributeName];
  NSUInteger length = string.length;
  NSUInteger i = 0;
  while (i < length)
  {
    if ([string characterAtIndex:i] != SPACE_THIN)
    {
      i++;
      continue;
    }
    NSUInteger start = i;
    while ((i < length) && ([string characterAtIndex:i] == SPACE_THIN))
    {
      i++;
    }
    [title addAttribute:NSFontAttributeName value:font range:NSMakeRange(start, i - start)];
  }
}

- (void)updateMenuTopFor:(NSMenuItem*)item name:(char*)name pid:(pid_t)pid cpu:(double)cpu mem:(uint64_t)mem memKnown:(int)memKnown width:(CGFloat)target
{
  ProcessIconDecision* decision = [self decisionForPid:pid];
  NSString* shownName = [NSString stringWithFormat:@"%@%@", (decision.helper ? @"↳ " : @""), SampleText(name)];
  NSString* stringName = [self getStringForName:shownName width:target];
  NSString* stringCpu = [self getStringForCpu:cpu width:CPU_STR_SPACE_TARGET];
  NSString* stringMem = [self getStringForMem:mem known:memKnown width:memTarget];
  [item setTitle: [NSString stringWithFormat:@"%@ %@ %@", stringName, stringCpu, stringMem]];
  
  NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:[item title] attributes:attributesGrey];
  [title setAttributes:attributesWhite range:NSMakeRange([stringName length], [stringCpu length]+1+[stringMem length]+1)];
  SetPaddingFont(title);

  
  [item setAttributedTitle:title];
  [item setImage:decision.menuImage];
  // shown by showRowTip while frozen, never as the item's toolTip
  [item setRepresentedObject:decision.tooltip];
  
  //NSSize size = [[item title] sizeWithAttributes:attributesGrey];
  //return size.width;
}

// the text of the row that counts other users' processes; "" when there are none
static NSString* OthersRowText(int count)
{
  if (count <= 0)
  {
    return @"";
  }
  return (count == 1) ? @"1 other user's process: CPU and memory not readable" : [NSString stringWithFormat:@"%d other users' processes: CPU and memory not readable", count];
}

// the row's title: grey, and in smaller type when its text at four digits would be wider than a process row, so that
// a count gaining a digit never resizes the menu
- (NSAttributedString*)othersTitle:(int)count
{
  NSString* text = OthersRowText(count);
  CGFloat room = NAME_STR_SPACE_TARGET + spaceWidth + CPU_STR_SPACE_TARGET + spaceWidth + memTarget;
  CGFloat widest = [OthersRowText(MAX(count, 1000)) sizeWithAttributes:attributesStandard].width;
  if (widest <= room)
  {
    return [[NSAttributedString alloc] initWithString:text attributes:attributesStandard];
  }
  static bool logged = false;
  if (!logged)
  {
    logged = true;
    NSLog(@"the row counting other users' processes is %.1f pt wide at four digits, wider than a process row's %.1f pt: it is set in smaller type", widest, room);
  }
  NSFont* font = attributesStandard[NSFontAttributeName];
  CGFloat size = floor(font.pointSize * room / widest * 10.0) / 10.0;
  NSMutableDictionary* smaller = [attributesStandard mutableCopy];
  while (size > 1.0)
  {
    smaller[NSFontAttributeName] = [NSFont fontWithDescriptor:font.fontDescriptor size:size];
    if ([OthersRowText(MAX(count, 1000)) sizeWithAttributes:smaller].width <= room)
    {
      break;
    }
    size -= 0.1;
  }
  return [[NSAttributedString alloc] initWithString:text attributes:smaller];
}

- (void)updateMenuTop
{
  if (baselineOnly)
  {
    return;
  }
  for (int i=0; i<TOP_COUNT; i++)
  {
    //NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    //NSString *fullPath = [ws fullPathForApplication:[path lastPathComponent]];
    //NSImage *appIcon = [ws iconForFileType:NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
    
    if (i >= MIN(topCount, topShown))
    {
      [topMenus[i] setHidden:YES];
      continue;
    }
    TopProcessSample_t* sample = &topProcceses[i];
    [self updateMenuTopFor:topMenus[i] name:sample->name pid:sample->pid cpu:sample->cpu mem:sample->mem memKnown:sample->mem_known width:NAME_STR_SPACE_TARGET];
    [topMenus[i] setTag:sample->pid];
    [topMenus[i] setHidden:NO];
  }

  [othersItem setAttributedTitle:[self othersTitle:topOthersCount]];
  [othersItem setHidden:(topOthersCount <= 0)];
  
  [menu update];
}

// the Settings window, built once, after setupMenus, which makes menuRows. Top to bottom: the Demo card with the three
// previews, the "Menu bar" group, then each MenuRows class's group in registration order, under its heading and above
// its buttons, then "Launch at login" and the build number. A class owns its controls (target, action, state, defaults
// key); the app only places them and is never told of a click. The window then takes the content's fitting size
- (void)setupSettings
{
  self.window.title = [NSString stringWithFormat:@"%@ Settings", AppName()];
  NSView* content = self.window.contentView;
  NSView* settings = [[NSView alloc] init];
  settings.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:settings];
  NSMutableArray<NSLayoutConstraint*>* constraints = [[NSMutableArray alloc] init];
  [constraints addObject:[settings.widthAnchor constraintEqualToConstant:SETTINGS_WIDTH]];

  // each view goes under the one before it, gap below it, indent in from the groups' left edge
  __block NSLayoutYAxisAnchor* below = settings.topAnchor;
  __block CGFloat gap = SETTINGS_INSET_Y;
  void (^place)(NSView*, CGFloat, CGFloat) = ^(NSView* view, CGFloat indent, CGFloat gapAfter) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [settings addSubview:view];
    [constraints addObject:[view.topAnchor constraintEqualToAnchor:below constant:gap]];
    [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:settings.leadingAnchor constant:SETTINGS_INSET_X + indent]];
    below = view.bottomAnchor;
    gap = gapAfter;
  };
  void (^heading)(NSString*) = ^(NSString* title) {
    place(MenuRowsSettingsHeading(title), SETTINGS_HEADING_INSET, SETTINGS_HEADING_GAP);
  };

  // Demo: the previews from the window's nib side by side, as far apart from each other as from the card's edges,
  // each with its caption under it, the previews and captions together centred on the card's height; placeDemoPreviews
  // spaces them again whenever a render changes a preview's width
  heading(@"Demo");
  SettingsGroupView* demo = [[SettingsGroupView alloc] init];
  [constraints addObject:[demo.widthAnchor constraintEqualToConstant:SETTINGS_GROUP_WIDTH]];
  [constraints addObject:[demo.heightAnchor constraintEqualToConstant:SETTINGS_DEMO_HEIGHT]];
  place(demo, 0.0, SETTINGS_SECTION_GAP);
  NSArray<NSImageView*>* previews = @[self.realDemoView, self.sineDemoView, self.flatDemoView];
  NSArray<NSString*>* captions = @[@"real-time CPU", @"sine wave", @"flat wave"];
  for (int n=0; n<3; n++)
  {
    NSImageView* preview = previews[n];
    // added without a removeFromSuperview first: the outlets are weak, and the card takes the view from the window
    [demo addSubview:preview];
    preview.translatesAutoresizingMaskIntoConstraints = YES;
    preview.autoresizingMask = NSViewNotSizable;
    // a preview placeDemoPreviews narrows keeps its full height: its image is squeezed across, never shrunk whole
    preview.imageScaling = NSImageScaleAxesIndependently;
    // no nib placeholder stretched across the preview before its first render
    preview.image = nil;
    NSTextField* caption = SettingsLabel(captions[n], [NSFont systemFontOfSize:11.0], [NSColor secondaryLabelColor]);
    [demo addSubview:caption];
    CGFloat top = floor((SETTINGS_DEMO_HEIGHT - (tickHeight + SETTINGS_DEMO_CAPTION_GAP + caption.fittingSize.height))/2.0);
    [preview setFrameOrigin:NSMakePoint(NSMinX(preview.frame), top)];
    demoCaptionCentres[n] = [caption.centerXAnchor constraintEqualToAnchor:demo.leadingAnchor constant:0.0];
    [constraints addObject:demoCaptionCentres[n]];
    [constraints addObject:[caption.topAnchor constraintEqualToAnchor:demo.topAnchor constant:top + tickHeight + SETTINGS_DEMO_CAPTION_GAP]];
  }
  [self placeDemoPreviews];

  // Menu bar
  heading(@"Menu bar");
  refreshChoice = MenuRowsSettingsChoice(@[@"10 a sec", @"5 a sec", @"2 a sec"], 66.0, RefreshChoiceIndex(), @selector(refreshChoiceChanged:), self);
  NSMutableArray<NSString*>* topLabels = [[NSMutableArray alloc] init];
  for (NSUInteger n=0; n<TOP_ROWS_CHOICES; n++)
  {
    [topLabels addObject:[NSString stringWithFormat:@"%d", topRowsChoices[n]]];
  }
  topRowsChoice = MenuRowsSettingsChoice(topLabels, 44.0, TopRowsChoiceIndex(), @selector(topRowsChoiceChanged:), self);
  showBarsSwitch = MenuRowsSettingsSwitch(showBars, @selector(showBarsButtonClicked:), self);
  showGpuSwitch = MenuRowsSettingsSwitch(showGpuNeuralEngine, @selector(showGpuButtonClicked:), self);
  showGpuSwitch.enabled = showBars;
  showBatteryWifiSwitch = MenuRowsSettingsSwitch(showBatteryWifi, @selector(showBatteryWifiButtonClicked:), self);
  showBatteryWifiSwitch.enabled = showBars;
  showBarLettersSwitch = MenuRowsSettingsSwitch(showBarLetters, @selector(showBarLettersButtonClicked:), self);
  showBarLettersSwitch.enabled = showBars;
  place(SettingsGroup(@[@[@"Refresh", refreshChoice],
                        @[@"Top processes", topRowsChoice],
                        @[@"Show Disk, RAM, CPU, E-core, P-core bars", showBarsSwitch],
                        @[@"Show battery and Wi-Fi bars", showBatteryWifiSwitch],
                        @[@"Show GPU and Neural Engine bars", showGpuSwitch],
                        @[@"Show letters under the bars", showBarLettersSwitch]]), 0.0, SETTINGS_SECTION_GAP);

  // each class's group, with at least one valid row
  for (id<MenuRows> rows in menuRows)
  {
    if (![rows respondsToSelector:@selector(settingsRows)])
    {
      continue;
    }
    NSArray<NSArray*>* valid = SettingsValidRows([rows settingsRows]);
    if (valid.count == 0)
    {
      continue;
    }
    id title = [rows respondsToSelector:@selector(settingsTitle)] ? [rows settingsTitle] : nil;
    if ([title isKindOfClass:[NSString class]] && ([(NSString*)title length] > 0))
    {
      heading(title);
    }
    SettingsGroupView* group = SettingsGroup(valid);
    place(group, 0.0, SETTINGS_SECTION_GAP);
    NSMutableArray<NSButton*>* buttons = [[NSMutableArray alloc] init];
    if ([rows respondsToSelector:@selector(settingsButtons)])
    {
      for (id button in [rows settingsButtons])
      {
        if ([button isKindOfClass:[NSButton class]])
        {
          [buttons addObject:button];
        }
      }
    }
    if (buttons.count > 0)
    {
      // left to right, the last at the group's right edge
      NSStackView* row = [NSStackView stackViewWithViews:buttons];
      row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      row.alignment = NSLayoutAttributeCenterY;
      row.spacing = SETTINGS_BUTTONS_GAP;
      [row setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
      row.translatesAutoresizingMaskIntoConstraints = NO;
      [settings addSubview:row];
      [constraints addObjectsFromArray:@[
        [row.topAnchor constraintEqualToAnchor:group.bottomAnchor constant:SETTINGS_BUTTONS_GAP],
        [row.trailingAnchor constraintEqualToAnchor:group.trailingAnchor],
        [row.leadingAnchor constraintGreaterThanOrEqualToAnchor:group.leadingAnchor],
      ]];
      below = row.bottomAnchor;
    }
  }

  // Launch at login
  loginSwitch = MenuRowsSettingsSwitch([SMAppService mainAppService].status == SMAppServiceStatusEnabled, @selector(loginButtonClicked:), self);
  place(SettingsGroup(@[@[@"Launch at login", loginSwitch]]), 0.0, SETTINGS_BUILD_GAP);

  // the build number, raised on every build by scripts/raise-build-number.sh, centred under the last group
  NSString* build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
  NSTextField* buildLabel = SettingsLabel([NSString stringWithFormat:@"b%@", build], [NSFont systemFontOfSize:11.0], [NSColor secondaryLabelColor]);
  [settings addSubview:buildLabel];
  [constraints addObjectsFromArray:@[
    [buildLabel.topAnchor constraintEqualToAnchor:below constant:gap],
    [buildLabel.centerXAnchor constraintEqualToAnchor:settings.centerXAnchor],
    [buildLabel.bottomAnchor constraintEqualToAnchor:settings.bottomAnchor constant:-SETTINGS_INSET_Y],
  ]];
  [NSLayoutConstraint activateConstraints:constraints];

  // the window fits the content, which then fills it
  [self.window setContentSize:settings.fittingSize];
  [NSLayoutConstraint activateConstraints:@[
    [settings.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [settings.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [settings.topAnchor constraintEqualToAnchor:content.topAnchor],
    [settings.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
  ]];

  // the Demo card has its width only now: space the previews in it before the window is first shown
  [content layoutSubtreeIfNeeded];
  [self placeDemoPreviews];
}

- (void)setupMenus
{
  if (!spaces_init)
  {
    spaces_init = YES;
    for (int i=0; i<SIZE_SPACES; i++)
    {
      spaces[i] = SPACE_THIN;
    }
  }
  
  attributesStandard = @{
    NSFontAttributeName: MENU_FONT(MENU_ICON_SIZE-2),
  };
  
  attributesGrey = @{
    NSFontAttributeName: MENU_FONT(MENU_ICON_SIZE-2),
    NSForegroundColorAttributeName: [NSColor controlTextColor]
  };
  
  attributesWhite = @{
    NSFontAttributeName: MENU_FONT(MENU_ICON_SIZE-2),
    NSForegroundColorAttributeName: [NSColor controlTextColor],
  };
  
  attributesPad = @{
    NSFontAttributeName: [NSFont fontWithName:MENU_PAD_FONT_NAME size:MENU_ICON_SIZE-2],
  };

  unichar unicodeSpace[1] = {SPACE_THIN};
  spaceWidth = [[NSString stringWithCharacters:unicodeSpace length:1] sizeWithAttributes:attributesPad].width;
  
  memTarget = 0.0;
  for (NSString* sample in @[@"999.99 GB", @"—"])
  {
    memTarget = MAX(memTarget, [sample sizeWithAttributes:attributesGrey].width);
  }
  
  NSDictionary* attributesThin = @{
    NSFontAttributeName: MENU_FONT(1.0),
  };
  
  NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
  paragraphStyle.alignment = NSTextAlignmentCenter;
  NSDictionary* attributesStandardCenter = @{
    NSFontAttributeName: MENU_TITLE_FONT,
    NSParagraphStyleAttributeName: paragraphStyle,
    NSForegroundColorAttributeName: MENU_TITLE_COLOR
  };
  
  menu = [[NSMenu alloc] init];
  [menu setDelegate:self];
  
  {
    NSMenuItem* item = [menu addItemWithTitle:@" " action:nil keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesThin]];
    // the unsandboxed variant ranks other users' processes too while /usr/bin/top runs (menu open, sorted by CPU); the
    // sandboxed one ranks only the user's own
#if !CPUTOPBARS_SANDBOXED
    item = [menu addItemWithTitle:@"TOP PROCESSES BY CPU" action:nil keyEquivalent:@""];
#else
    item = [menu addItemWithTitle:@"YOUR TOP PROCESSES BY CPU" action:nil keyEquivalent:@""];
#endif
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandardCenter]];
    for (int i=0; i<TOP_COUNT; i++)
    {
      topMenus[i] = [menu addItemWithTitle:@"" action:@selector(selectPid:) keyEquivalent:@""];
      ShowMenuItemImage(topMenus[i]);
    }
    // below the rows: how many other users' processes have no CPU figure (updateMenuTop)
    othersItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    [othersItem setEnabled:NO];
    [othersItem setHidden:YES];
  }
  
  [menu addItem:[NSMenuItem separatorItem]];

//  {
//    NSMenuItem* item = [menu addItemWithTitle:@"Process Explorer" action:@selector(processExplorer:) keyEquivalent:@""];
//    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
//    //NSImage* appIcon = [NSImage imageNamed:@"NSRevealFreestandingTemplate"];
//    //NSImage* appIcon = [NSImage imageNamed:@"NSQuickLookTemplate"];
//    //NSLog(@"appIcon: %@", appIcon);
//    //[appIcon setSize:NSMakeSize(MENU_ICON_SIZE-2.0, MENU_ICON_SIZE-2.0)];
//    //[item setImage:appIcon];
//  }
//
//  [menu addItem:[NSMenuItem separatorItem]];

  {
    NSMenuItem* item = [menu addItemWithTitle:@"Launch \"Activity Monitor\"" action:@selector(launchActivityMonitor:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    NSImage* appIcon = [[NSWorkspace sharedWorkspace] iconForFile:[NSString stringWithFormat:@"/System/Applications/Utilities/Activity Monitor.app"]];
    [appIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:appIcon];
    ShowMenuItemImage(item);
  }

  [menu addItem:[NSMenuItem separatorItem]];

  {
    // the check mark shows in the icon column while frozen (toggleFreeze:), a blank image there otherwise, so
    // "Freeze" lines up with the other titles and nothing moves when it is toggled (the item's state would add a
    // check column and shift every row); off at every launch
    CGFloat side = MENU_ICON_SIZE+2.0;
    freezeOffImage = [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rect) { return YES; }];
    // configured as AppKit draws it in a native row, which StayOpenRowView copies: 13 pt, small scale
    freezeOnImage = [[NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:@"Frozen"]
                     imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightSemibold
                                                                                                    scale:NSImageSymbolScaleSmall]];
    NSMenuItem* item = [[StayOpenMenuItem alloc] initWithTitle:@"Freeze" action:@selector(toggleFreeze:) keyEquivalent:@""];
    [menu addItem:item];
    freezeItem = item;
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    [item setImage:freezeOffImage];
    ShowMenuItemImage(item);
    // a view, so that a click leaves the menu open
    [item setView:[[StayOpenRowView alloc] initWithItem:item]];
  }

  {
    NSMenuItem* item = [menu addItemWithTitle:[NSString stringWithFormat:@"Open %@ Settings...", AppName()] action:@selector(openPreferences:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    //NSImage* appIcon = [NSImage imageNamed:@"AppIcon"];
    NSImage* appIcon = [NSImage imageNamed:@"NSPreferencesGeneral"];
    [appIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:appIcon];
    ShowMenuItemImage(item);
  }

  {
    NSMenuItem* item = [menu addItemWithTitle:@"How to Read the Menu Bar..." action:@selector(openHelp:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    NSImage* helpIcon = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
    [helpIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:helpIcon];
    ShowMenuItemImage(item);
  }

#ifndef CPUTOPBARS_NO_FUNDRAISER
  {
    // a build that defines CPUTOPBARS_NO_FUNDRAISER leaves this row out
    NSMenuItem* item = [menu addItemWithTitle:@"Support Team Fox..." action:@selector(openFundraiser:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    NSImage* heartIcon = [NSImage imageWithSystemSymbolName:@"heart" accessibilityDescription:nil];
    [heartIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:heartIcon];
    ShowMenuItemImage(item);
  }
#endif

  {
    NSMenuItem* item = [menu addItemWithTitle:[NSString stringWithFormat:@"About %@", AppName()] action:@selector(openAbout:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    // a copy, so the shared application icon keeps its own size for the About panel
    NSImage* appIcon = [[NSImage imageNamed:NSImageNameApplicationIcon] copy];
    [appIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:appIcon];
    ShowMenuItemImage(item);
  }

  [menu addItem:[NSMenuItem separatorItem]];

  menuRows = [[NSMutableArray alloc] init];
  for (Class rowsClass in menuRowsClasses)
  {
    id<MenuRows> rows = [[rowsClass alloc] init];
    [menuRows addObject:rows];
    NSArray<NSMenuItem*>* items = [rows menuItemsWithAttributes:attributesStandard];
    for (NSMenuItem* item in items)
    {
      [menu addItem:item];
    }
    if ([items count] > 0)
    {
      [menu addItem:[NSMenuItem separatorItem]];
    }
  }

  {
    // the build number, raised on every build by scripts/raise-build-number.sh
    NSString* build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSString* title = [NSString stringWithFormat:@"Quit (b%@)", build];
    NSMenuItem* item = [menu addItemWithTitle:title action:@selector(terminate:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
  }
  
  self.statusItem.menu = menu;
}

// light or dark as an appearance resolves to Aqua or Dark Aqua, whatever its variant (vibrant, high contrast)
static bool IsLight(NSAppearance* appearance)
{
  NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
  return ![name isEqualToString:NSAppearanceNameDarkAqua];
}

// a drawing of the menu bar's image for the help window (MenuRows.h), with the settings the status item draws with now
NSView* MenuRowsHelpExample(const CpuReadings* readings, const double* coreLoads, int coreLoadCount, MenuRowsExamplePart part,
                            NSString* label, int labelReading, NSString* caption)
{
  HelpExampleStyle style = {granularity, bar, stripped, colored, drawWidth, tickTotalWidth, graphWidth, tickHeight, theme,
                            cpu_info.countLogical, coreSplit};
  return [[HelpExampleView alloc] initWithStyle:style readings:readings coreLoads:coreLoads coreLoadCount:coreLoadCount
                                           part:part label:label labelReading:labelReading caption:caption];
}

- (void)renderMenubarWithLight:(BOOL)light readings:(const CpuReadings*)readings
{
  CpuSamplerUpdate(&cpu_info);
  // the menu bar's image has the block's letters under its bars, and the extra bars' own (barLetters) under theirs, while
  // Settings' "Show letters under the bars" is on, and is then taller (CpuRenderImageHeight); not at the Thin width, whose
  // 5-pt slots leave no room between the 5-pt letters; the Settings previews and the help's examples draw without them
  CpuReadings lettered = {};
  if (readings != NULL)
  {
    lettered = *readings;
    lettered.letters = showBarLetters && (tickWidth != 1.0);
  }
  const CpuReadings* drawn = (readings != NULL) ? &lettered : NULL;
  const CGFloat imageHeight = CpuRenderImageHeight(bar, stripped, drawn);
  static NSImage* image = nil;
  {
    image = self.statusItem.button.image;
    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, imageHeight)];
    }
    else
    {
      if (([image size].width != imageWidth) || ([image size].height != imageHeight))
      {
        image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, imageHeight)];
      }
    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, imageWidth, theme, drawn);
    }
    [image unlockFocus];
  }
  self.statusItem.button.image = image;
  [self updateBarTips:readings];
}

// a tooltip-style label under each reading's bar (or dot) in the status item: disk, memory, CPU, the battery and the GPU
// with its power, one value to a line ("Disk usage:", "Free:", "Used:", "Total:"; TipLines), the E-cores' and the P-cores' as "Efficiency cores: 22%"
// and "Performance cores: 13%", and each extra bar's,
// worded by its class (barLabels); and one under the core graph, with or without the readings: each CPU's load by kind,
// one value to a line, the bar under the pointer marked (CoresTipText); when the graph splits, one under the E-cores'
// reading and bars, the reading's line and then their CPUs alone, and one under the P-cores' with theirs; the mark follows the pointer along
// the graph, or along one kind's bars,
// without hiding the label. On macOS 27 no tooltip showed on the status item when tried (a tooltip rect was never asked
// for its text), but the pointer reaches the button, so the label is the app's own panel. updateBarTips: records where
// the readings are after each render; the pointer's entry and moves start a watch timer that follows the pointer while
// it is on the item, since no exit was delivered either, and a reading under it arms the label (BAR_TIP_DELAY)
static NSRect barTipLayout = {{-1.0, -1.0}, {-1.0, -1.0}}; // x: the image's left in the button, width: the readings' slot; none: -1
static bool barTipThree = false;            // the five readings (disk, memory, CPU, E-cores, P-cores) are drawn
static unsigned barTipMask = 0;             // with them, the optional readings drawn (CpuRenderReadingsShown: battery, Wi-Fi, GPU and Neural Engine)
static int barTipSplit = 0;                 // with them, the core graph's split as drawn (CpuReadings efficiencyBars); 0: none
static std::vector<CpuExtraReading> barTipBars; // the extra bars drawn right of the core graph, as drawn (a copy: extraBars is refilled each tick)
static NSInteger barTipIndex = -1;          // the reading under the pointer, armed or shown: a reading's index with barTipMask
                                            // (CpuRenderReadingIndex; 0 disk, 1 memory, 2 CPU, 3 E-cores, 4 P-cores with none of
                                            // the optional ones), the extra bars' from CpuRenderReadingsCount(barTipMask) on,
                                            // BAR_TIP_CORES the core graph (split: BAR_TIP_CORES_E or BAR_TIP_CORES_P, the bars of
                                            // one kind), -1 none
static NSPanel* barTip = nil;
static NSTextField* barTipText = nil;
static NSString* barTipShown = nil;         // the whole text last laid out in barTip: barTipText holds only its first part
static NSTimer* barTipWatch = nil;

// whether a label index is the core graph's, whole or one kind's bars
static bool BarTipIsCores(NSInteger index)
{
  return (index == BAR_TIP_CORES) || (index == BAR_TIP_CORES_E) || (index == BAR_TIP_CORES_P);
}

// readings: what the last render drew, NULL when nothing but the core graph
- (void)updateBarTips:(const CpuReadings*)readings
{
  NSStatusBarButton* button = self.statusItem.button;
  static NSTrackingArea* tracking = nil;
  if (tracking == nil)
  {
    tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect) owner:self userInfo:nil];
    [button addTrackingArea:tracking];
  }
  bool three = (readings != NULL) && !readings->extraOnly;
  unsigned mask = CpuRenderReadingsShown(readings);
  int split = (three && (readings->efficiencyBars > 0)) ? readings->efficiencyBars : 0;
  std::vector<CpuExtraReading> bars;
  if ((readings != NULL) && (readings->extra != NULL) && (readings->extraCount > 0))
  {
    bars.assign(readings->extra, readings->extra + readings->extraCount);
  }
  // a count, or a bar that starts a group or is narrow, that differs from what was drawn before moves the slots
  bool sameBars = (bars.size() == barTipBars.size());
  for (size_t i=0; sameBars && (i<bars.size()); i++)
  {
    sameBars = (bars[i].groupStart == barTipBars[i].groupStart) && (bars[i].narrow == barTipBars[i].narrow);
  }
  NSRect bounds = button.bounds;
  NSRect layout = NSMakeRect(round(NSMidX(bounds) - imageWidth/2.0), NSMinY(bounds), CpuRenderReadingsSlot(bar, drawWidth, tickTotalWidth), NSHeight(bounds));
  if (!NSEqualRects(layout, barTipLayout) || (three != barTipThree) || (mask != barTipMask) || (split != barTipSplit) || !sameBars)
  {
    barTipLayout = layout;
    barTipThree = three;
    barTipMask = mask;
    barTipSplit = split;
    barTipBars = bars;
    [self hideBarTip];
  }
}

// where the core graph starts and ends in the image, as the renderer drew it (barTipThree, barTipBars: what it drew
// besides the graph)
- (void)graphTipStart:(CGFloat*)start end:(CGFloat*)end
{
  CpuRenderGraphSpan(bar, drawWidth, tickTotalWidth, imageWidth, barTipThree, barTipMask, barTipSplit, (int)barTipBars.size(), barTipBars.data(), start, end);
}

// the reading at x, measured from the image's left: a reading's index with barTipMask (barTipIndex), the extra bars'
// after them, BAR_TIP_CORES on the core graph (split: BAR_TIP_CORES_E on the E-cores' reading and bars, BAR_TIP_CORES_P
// on the P-cores', in place of their indices); in bar style, in the first BAR_TIP_GAP_REACH pt of clear
// space right of a block, the image's right edge included, the reading or graph left of it; -1 on none of them (the
// rest of a gap, or past that)
- (NSInteger)barTipIndexAtX:(CGFloat)x
{
  NSInteger index = [self barTipSlotIndexAtX:x];
  if ((index == -1) && bar)
  {
    // the slots lie edge to edge within a block, so the first BAR_TIP_GAP_REACH pt right of one are those that put
    // x - BAR_TIP_GAP_REACH on its last slot; dots are not bars, so Dot style keeps the hit test of the slots alone
    index = [self barTipSlotIndexAtX:(x - BAR_TIP_GAP_REACH)];
  }
  return index;
}

// as barTipIndexAtX, but on the slots and the graph alone, no gap
- (NSInteger)barTipSlotIndexAtX:(CGFloat)x
{
  // a reading's slot starts where the renderer draws it, the extra bars' after the core graph; a gap is on none of them,
  // the split's gap inside the graph included (the P-cores' reading beside it is found first, by its slot)
  // split, the E-cores' and the P-cores' readings head their own bars, and each reading and its bars hover as one
  const NSInteger readingsCount = CpuRenderReadingsCount(barTipMask);
  for (NSInteger index=(barTipThree ? 0 : readingsCount); index<(readingsCount + (NSInteger)barTipBars.size()); index++)
  {
    CGFloat start = CpuRenderReadingX(bar, drawWidth, tickTotalWidth, barTipMask, imageWidth, barTipSplit, CpuSamplerGetCount(granularity), (int)barTipBars.size(), barTipBars.data(), (int)index);
    if ((x >= start) && (x < (start + CpuRenderReadingSlot(bar, drawWidth, tickTotalWidth, barTipMask, (int)barTipBars.size(), barTipBars.data(), (int)index))))
    {
      if ((barTipSplit > 0) && (index == CpuRenderReadingEfficiency(barTipMask)))
      {
        return BAR_TIP_CORES_E;
      }
      if ((barTipSplit > 0) && (index == CpuRenderReadingPerformance(barTipMask)))
      {
        return BAR_TIP_CORES_P;
      }
      return index;
    }
  }
  CGFloat graphStart = 0.0;
  CGFloat graphEnd = 0.0;
  [self graphTipStart:&graphStart end:&graphEnd];
  if ((x >= graphStart) && (x < graphEnd))
  {
    int core = CpuRenderCoreAtX(bar, drawWidth, tickTotalWidth, graphStart, barTipSplit, (int)CpuSamplerGetCount(granularity), x);
    if (core < 0)
    {
      return -1;
    }
    return (barTipSplit <= 0) ? BAR_TIP_CORES : ((core < barTipSplit) ? BAR_TIP_CORES_E : BAR_TIP_CORES_P);
  }
  return -1;
}

// whether readings a and b are both extra bars of one group (no group starts after the lower one, up to the higher one)
- (BOOL)barTipSameGroup:(NSInteger)a and:(NSInteger)b
{
  NSInteger low = MIN(a, b) - CpuRenderReadingsCount(barTipMask);
  NSInteger high = MAX(a, b) - CpuRenderReadingsCount(barTipMask);
  if ((low < 0) || (high >= (NSInteger)barTipBars.size()))
  {
    return NO;
  }
  for (NSInteger k=low+1; k<=high; k++)
  {
    if (barTipBars[k].groupStart)
    {
      return NO;
    }
  }
  return YES;
}

// where reading index (or BAR_TIP_CORES, BAR_TIP_CORES_E, BAR_TIP_CORES_P) sits in the image, in image coordinates: one
// kind's from its reading to the end of its last bar's slot, the P-cores' to the graph's end
- (NSRect)barTipSlotFor:(NSInteger)index
{
  if (BarTipIsCores(index))
  {
    CGFloat graphStart = 0.0;
    CGFloat graphEnd = 0.0;
    [self graphTipStart:&graphStart end:&graphEnd];
    if ((index == BAR_TIP_CORES_E) && (barTipSplit > 0))
    {
      const natural_t cores = CpuSamplerGetCount(granularity);
      graphEnd = CpuRenderCoreX(bar, drawWidth, tickTotalWidth, graphStart, barTipSplit, (int)cores, barTipSplit - 1) + CpuRenderCoreSlot(bar, drawWidth, tickTotalWidth, cores);
      graphStart = CpuRenderReadingX(bar, drawWidth, tickTotalWidth, barTipMask, imageWidth, barTipSplit, CpuSamplerGetCount(granularity), (int)barTipBars.size(), barTipBars.data(), CpuRenderReadingEfficiency(barTipMask));
    }
    else if ((index == BAR_TIP_CORES_P) && (barTipSplit > 0))
    {
      graphStart = CpuRenderReadingX(bar, drawWidth, tickTotalWidth, barTipMask, imageWidth, barTipSplit, CpuSamplerGetCount(granularity), (int)barTipBars.size(), barTipBars.data(), CpuRenderReadingPerformance(barTipMask));
    }
    return NSMakeRect(graphStart, barTipLayout.origin.y, graphEnd - graphStart, barTipLayout.size.height);
  }
  return NSMakeRect(CpuRenderReadingX(bar, drawWidth, tickTotalWidth, barTipMask, imageWidth, barTipSplit, CpuSamplerGetCount(granularity), (int)barTipBars.size(), barTipBars.data(), (int)index), barTipLayout.origin.y, CpuRenderReadingSlot(bar, drawWidth, tickTotalWidth, barTipMask, (int)barTipBars.size(), barTipBars.data(), (int)index), barTipLayout.size.height);
}

// the pointer's x, measured from the image's left; NO off the item, or nothing rendered yet
- (BOOL)barTipPointerX:(CGFloat*)x
{
  NSStatusBarButton* button = self.statusItem.button;
  if ((barTipLayout.size.width <= 0.0) || (button.window == nil))
  {
    return NO;
  }
  NSPoint p = [button convertPoint:[button.window convertPointFromScreen:[NSEvent mouseLocation]] fromView:nil];
  if (!NSPointInRect(p, button.bounds))
  {
    return NO;
  }
  *x = p.x - barTipLayout.origin.x;
  return YES;
}

// the reading under the pointer, from where it is now: 0 disk, 1 memory, 2 CPU, 3 E-cores, 4 P-cores, 5 on the extra
// bars, BAR_TIP_CORES on the core graph (split: BAR_TIP_CORES_E, BAR_TIP_CORES_P); -1 on the item but on none of them;
// -2 off the item, or nothing rendered yet
- (NSInteger)barTipIndexNow
{
  CGFloat x = 0.0;
  return [self barTipPointerX:&x] ? [self barTipIndexAtX:x] : -2;
}

// the core graph's bar under the pointer, from 0; -1 when the pointer is on none, or the graph has one bar (Package)
- (NSInteger)barTipCoreNow
{
  CGFloat x = 0.0;
  natural_t count = CpuSamplerGetCount(granularity);
  if ((count < 2) || (tickTotalWidth <= 0.0) || ![self barTipPointerX:&x])
  {
    return -1;
  }
  CGFloat graphStart = 0.0;
  CGFloat graphEnd = 0.0;
  [self graphTipStart:&graphStart end:&graphEnd];
  if ((x < graphStart) || !BarTipIsCores([self barTipIndexAtX:x]))
  {
    return -1;
  }
  // the bar as CpuRender places it (the P-cores' after the split's gap and their reading); Dot style's last dot overhangs
  // its slot by 1 pt, and the clear space right of the graph hovers it: that is still the last bar. In bar style the
  // first BAR_TIP_GAP_REACH pt of the split's gap hover the cores (barTipIndexAtX): those are the last E-core bar's
  NSInteger core = CpuRenderCoreAtX(bar, drawWidth, tickTotalWidth, graphStart, barTipSplit, (int)count, x);
  if ((core < 0) && bar)
  {
    core = CpuRenderCoreAtX(bar, drawWidth, tickTotalWidth, graphStart, barTipSplit, (int)count, x - BAR_TIP_GAP_REACH);
  }
  return core;
}

// a kind of core's reading, "22%" ("—" when busy is below 0, not read): the value of its reading's label and of the
// title line of a split core graph's label (CoresTipText)
static NSString* CoreKindReadingValue(double busy, NSLocale* locale)
{
  return (busy < 0.0) ? @"—" : [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(busy * 100.0)];
}

// the core graph's label from loads, each logical CPU's (0..1; below 0, not read: "—"), laid out as Wi-Fi's: a section per kind of
// core, E first, each its title, "Efficiency cores:" or "Performance cores:", at the left edge, then a line per CPU of
// that kind, by logical id, named by its kind and its number within the kind, with its load, "  E0:   18%"; a blank line
// before each section after the first, which SetTipText draws as a menu-style line; when the kinds were not read, one
// section, "Cores:", "C0:", "C1:" ... Each CPU's line starts with two cells, "› " for a CPU of the bar hovered (bar b
// averages CPUs b x perBar to b x perBar + perBar - 1, as CpuRender groups them; -1: none), two spaces for the others,
// and every load starts in one column, 3 cells after the longest of those names, so that TipPercents leaves the loads
// unpadded: "› E1:   42%", "  E2:   9%". only 'E' or 'P': that kind's section alone (0: every
// section), and with titleValue (nil: none) its title a line of that column too, its value the kind's reading
// ("Efficiency cores:   22%" over "  E0:               18%"); empty with no CPU
static NSString* CoresTipText(const std::vector<double>& loads, const char* kinds, natural_t perBar, NSInteger hovered, char only, NSString* titleValue, NSLocale* locale)
{
  const char letters[3] = {'E', 'P', 'C'};
  NSString* titles[3] = {@"Efficiency cores:", @"Performance cores:", @"Cores:"};
  std::vector<natural_t> sections[3];
  NSUInteger width = 0;     // the column the values start in: the longest name with its two lead cells, and three
  for (int section=0; section<3; section++)
  {
    if ((only != 0) && (letters[section] != only))
    {
      continue;
    }
    for (natural_t i=0; i<loads.size(); i++)
    {
      char kind = (kinds == NULL) ? 'C' : ((kinds[i] == 'E') ? 'E' : 'P');
      if (kind == letters[section])
      {
        sections[section].push_back(i);
      }
    }
    if (!sections[section].empty())
    {
      NSUInteger last = [NSString stringWithFormat:@"  %c%lu:", letters[section], (unsigned long)(sections[section].size() - 1)].length;
      width = MAX(width, last + 3);
      if ((only != 0) && (titleValue != nil))
      {
        width = MAX(width, titles[section].length + 3);
      }
    }
  }
  NSMutableArray<NSString*>* lines = [NSMutableArray array];
  for (int section=0; section<3; section++)
  {
    const std::vector<natural_t>& cpus = sections[section];
    if (cpus.empty())
    {
      continue;
    }
    if (lines.count > 0)
    {
      [lines addObject:@""];
    }
    if ((only != 0) && (titleValue != nil))
    {
      [lines addObject:[[titles[section] stringByPaddingToLength:width withString:@" " startingAtIndex:0] stringByAppendingString:titleValue]];
    }
    else
    {
      [lines addObject:titles[section]];
    }
    for (size_t k=0; k<cpus.size(); k++)
    {
      bool marked = (hovered >= 0) && (perBar > 0) && ((NSInteger)(cpus[k] / perBar) == hovered);
      NSString* name = [NSString stringWithFormat:@"%@%c%lu:", marked ? @"› " : @"  ", letters[section], (unsigned long)k];
      NSString* load = (loads[cpus[k]] < 0.0) ? @"—" : [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(100.0 * loads[cpus[k]])];
      [lines addObject:[[name stringByPaddingToLength:width withString:@" " startingAtIndex:0] stringByAppendingString:load]];
    }
  }
  return [lines componentsJoinedByString:@"\n"];
}

// the core graph's label, the bar under the pointer marked (CoresTipText): BAR_TIP_CORES at the graph's latest tick, as
// its bars show it; BAR_TIP_CORES_E or BAR_TIP_CORES_P that kind's section alone, its title line with that kind's
// reading (CoreKindReadingValue) and each CPU over the same window, read with it (readingsCpuEach), so that the title
// is close to the mean of its lines (equal to it where every CPU counts as many ticks), where at the latest tick a
// title of 7% stood over four 0%; while those are not read, the latest tick
- (NSString*)coresTipText:(NSInteger)index
{
  char only = (index == BAR_TIP_CORES_E) ? 'E' : ((index == BAR_TIP_CORES_P) ? 'P' : 0);
  bool windowed = (only != 0) && (cpu_info.countLogical > 0) && (readingsCpuEach.size() == cpu_info.countLogical);
  static bool windowLogged = false;
  if ((only != 0) && !windowed && !windowLogged)
  {
    windowLogged = true;
    NSLog(@"the %c-cores' label shows the latest tick: each CPU's share over the readings' window is not read (%lu of %u)", only, (unsigned long)readingsCpuEach.size(), cpu_info.countLogical);
  }
  std::vector<double> loads;
  for (natural_t i=0; i<cpu_info.countLogical; i++)
  {
    loads.push_back(windowed ? fmin(readingsCpuEach[i], 1.0) : fmin(fmax(cpu_info.now[i].load, 0.0), 1.0));
  }
  NSString* titleValue = nil;
  if (only != 0)
  {
    titleValue = CoreKindReadingValue((only == 'E') ? readingsCpuEfficiency : readingsCpuPerformance, [NSLocale currentLocale]);
  }
  return CoresTipText(loads, cpuKinds, cpu_info.countLogical / CpuSamplerGetCount(granularity), [self barTipCoreNow], only, titleValue, [NSLocale currentLocale]);
}

// a label's whole percentages three characters wide, "  1%", " 10%", "100%", so that a label in the monospaced font
// keeps its width as its values change; one after "~", an estimate, keeps its own width, and so does one whose
// digits follow a figure space (U+2007): a label that pads its own numbers with figure spaces keeps them; and so does
// one after three spaces, a value that starts its line's value column (TipLines), so that every value of a label laid
// out one value to a line starts in one column, as Wi-Fi's do ("Disk usage:   74%" over "Free:         257 GB")
static NSString* TipPercents(NSString* text)
{
  static NSRegularExpression* percent = nil;
  if (percent == nil)
  {
    percent = [NSRegularExpression regularExpressionWithPattern:@"(?<![0-9.,~\\x{2007}])(?<!   )([0-9]{1,3})%" options:0 error:NULL];
  }
  NSMutableString* padded = [text mutableCopy];
  NSArray<NSTextCheckingResult*>* matches = [percent matchesInString:text options:0 range:NSMakeRange(0, text.length)];
  for (NSTextCheckingResult* match in matches.reverseObjectEnumerator)
  {
    NSRange digits = [match rangeAtIndex:1];
    [padded replaceCharactersInRange:digits withString:[NSString stringWithFormat:@"%3d", [[text substringWithRange:digits] intValue]]];
  }
  return padded;
}

// the reading's label of a kind of core, "Efficiency cores: 22%" or "Performance cores: 13%" (CoreKindReadingValue)
static NSString* CoreKindReadingText(bool efficiency, double busy, NSLocale* locale)
{
  return [NSString stringWithFormat:@"%@ %@", efficiency ? @"Efficiency cores:" : @"Performance cores:", CoreKindReadingValue(busy, locale)];
}

// a help example's CPU, E and P readings from its core loads, coreLoads[i % coreLoadCount] for logical CPU i, as the app
// reads them from the CPUs (SystemInfo): CPU the mean over all of them, E and P the mean over that kind's (cpuKinds),
// -1 (not read) for a kind with no CPU or with the kinds not read. With no loads (count 0) the readings are left as given
static void HelpCoreReadings(const double* coreLoads, int coreLoadCount, CpuReadings* readings)
{
  if ((coreLoads == NULL) || (coreLoadCount <= 0) || (cpu_info.countLogical == 0))
  {
    return;
  }
  double sum = 0.0;
  double kindSum[2] = {0.0, 0.0};
  int kindCount[2] = {0, 0};
  for (natural_t i=0; i<cpu_info.countLogical; i++)
  {
    double load = fmin(fmax(coreLoads[i % coreLoadCount], 0.0), 1.0);
    sum += load;
    if ((cpuKinds != NULL) && ((cpuKinds[i] == 'E') || (cpuKinds[i] == 'P')))
    {
      int kind = (cpuKinds[i] == 'E') ? 0 : 1;
      kindSum[kind] += load;
      kindCount[kind]++;
    }
  }
  readings->cpu = sum / (double)cpu_info.countLogical;
  readings->efficiency = (kindCount[0] > 0) ? (kindSum[0] / kindCount[0]) : -1.0;
  readings->performance = (kindCount[1] > 0) ? (kindSum[1] / kindCount[1]) : -1.0;
}

// the GPU's hover label, "GPU: 12%", and with its power read (watts 0 or more: IOReport, the unsandboxed variant) one
// value to a line (TipLines), "GPU:     12%" over "Power:   0.08 W"; the Neural Engine's, "Neural Engine: ON", or with
// its share of time busy read (busy 0..1), "Neural Engine: 37%"; unpadded, as barTipTextAt: pads them
static NSString* GpuTipText(double gpu, double watts)
{
  if (gpu < 0.0)
  {
    return @"GPU: cannot be read on this Mac";
  }
  NSLocale* locale = [NSLocale currentLocale];
  NSMutableArray<NSArray<NSString*>*>* rows = [NSMutableArray arrayWithObject:
    @[@"GPU:", [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(fmin(gpu, 1.0) * 100.0)]]];
  if (watts >= 0.0)
  {
    [rows addObject:@[@"Power:", [[NSString alloc] initWithFormat:@"%.2f W" locale:locale, watts]]];
  }
  return TipLines(rows);
}

static NSString* NeuralEngineTipText(int state, double busy)
{
  if (busy >= 0.0)
  {
    return [[NSString alloc] initWithFormat:@"Neural Engine: %ld%%" locale:[NSLocale currentLocale], lround(fmin(busy, 1.0) * 100.0)];
  }
  if (state < 0)
  {
    return @"Neural Engine: cannot be read on this Mac";
  }
  return (state > 0) ? @"Neural Engine: ON" : @"Neural Engine: OFF";
}

// the battery's value, as its panel row and its hover label show it: its charge and its state, "87% (charging)"
// (SystemInfoBatteryStateText); "—" when it was not read
static NSString* BatteryValueText(bool read, const SystemInfoBattery* battery)
{
  if (!read)
  {
    return @"—";
  }
  char state[64];
  SystemInfoBatteryStateText(battery, state, sizeof(state));
  return [[NSString alloc] initWithFormat:@"%ld%% (%@)" locale:[NSLocale currentLocale], lround(fmin(fmax(battery->level, 0.0), 1.0) * 100.0), @(state)];
}

// the battery's hover label, one value to a line (TipLines): "Battery:" and the charge, "State:" ("charged", "charging",
// "not charging" or "on battery", tested in the order SystemInfoBatteryStateText tests them) and, on battery with its time
// to empty read, "Time left:" ("3:12"); "Battery: —" when it was not read; unpadded, as barTipTextAt: pads it
static NSString* BatteryTipText(bool read, const SystemInfoBattery* battery)
{
  if (!read)
  {
    return @"Battery: —";
  }
  NSString* charge = [[NSString alloc] initWithFormat:@"%ld%%" locale:[NSLocale currentLocale], lround(fmin(fmax(battery->level, 0.0), 1.0) * 100.0)];
  NSString* state = @"on battery";
  if (battery->charged)
  {
    state = @"charged";
  }
  else if (battery->charging)
  {
    state = @"charging";
  }
  else if (battery->onAC)
  {
    state = @"not charging";
  }
  NSMutableArray<NSArray<NSString*>*>* rows = [NSMutableArray arrayWithObjects:@[@"Battery:", charge], @[@"State:", state], nil];
  if (!battery->charged && !battery->charging && !battery->onAC && (battery->minutesToEmpty > 0))
  {
    [rows addObject:@[@"Time left:", [NSString stringWithFormat:@"%d:%02d", battery->minutesToEmpty / 60, battery->minutesToEmpty % 60]]];
  }
  return TipLines(rows);
}

// Wi-Fi's state in words, its panel row's value: "connected", "on, not connected" or "off"; "—" with no interface read
static NSString* WifiStateText(const SystemInfoWifi* wifi)
{
  if (!wifi->present)
  {
    return @"—";
  }
  if (!wifi->powerOn)
  {
    return @"off";
  }
  return wifi->connected ? @"connected" : @"on, not connected";
}

// "48 (5 GHz, 80 MHz)" (SystemInfoWifiChannelText)
static NSString* WifiChannelText(const SystemInfoWifi* wifi)
{
  char text[64];
  SystemInfoWifiChannelText(wifi->channel, wifi->band, wifi->width, text, sizeof(text));
  return @(text);
}

// Wi-Fi's hover label: connected, "Wi-Fi:" and the signal (-50 dBm), then a line each for the details the macOS Wi-Fi
// menu lists with Option held, in its order, but those that need Location Services (the network's name, its BSSID, the
// country code), the MCS index and NSS, which CoreWLAN does not give, and the RSSI, which is the first line: "IP
// Address:", "Router:", "MAC Address:", "Security:", "Channel:", "Noise:", "Tx Rate:" and "PHY Mode:"; a detail that was
// not read (ip, router and mac empty), or that has no name, has no line. Each name, "Wi-Fi:" included, is padded with
// spaces to 15 characters ("MAC Address:", the longest, and three), so the values start in one column in the label's
// monospace font ("Wi-Fi:         -50 dBm"). Else "Wi-Fi: off" or "Wi-Fi: not connected"
static NSString* WifiTipText(const SystemInfoWifi* wifi, const char* ip, const char* router, const char* mac)
{
  if (!wifi->present)
  {
    return @"Wi-Fi: cannot be read on this Mac";
  }
  if (!wifi->powerOn)
  {
    return @"Wi-Fi: off";
  }
  if (!wifi->connected)
  {
    return @"Wi-Fi: not connected";
  }
  NSMutableString* text = [NSMutableString stringWithFormat:@"%-15s%d dBm", "Wi-Fi:", wifi->rssi];
  if (ip[0] != 0)
  {
    [text appendFormat:@"\n%-15s%s", "IP Address:", ip];
  }
  if (router[0] != 0)
  {
    [text appendFormat:@"\n%-15s%s", "Router:", router];
  }
  if (mac[0] != 0)
  {
    [text appendFormat:@"\n%-15s%s", "MAC Address:", mac];
  }
  const char* security = SystemInfoWifiSecurityName(wifi->security);
  if (security != NULL)
  {
    [text appendFormat:@"\n%-15s%s", "Security:", security];
  }
  [text appendFormat:@"\n%-15s%@\n%-15s%d dBm\n%-15s%.0f Mbps", "Channel:", WifiChannelText(wifi), "Noise:", wifi->noise,
                     "Tx Rate:", wifi->txRate];
  const char* phy = SystemInfoWifiPhyName(wifi->phy);
  if (phy != NULL)
  {
    [text appendFormat:@"\n%-15s%s", "PHY Mode:", phy];
  }
  return text;
}

// Wi-Fi's panel row: "Wi-Fi:" and the signal while connected ("-55 dBm"), else its state; the details are in its hover
// label (WifiTipText)
static NSArray<NSArray<NSString*>*>* WifiRows(const SystemInfoWifi* wifi)
{
  if (wifi->connected)
  {
    return @[@[@"Wi-Fi:", [NSString stringWithFormat:@"%d dBm", wifi->rssi]]];
  }
  return @[@[@"Wi-Fi:", WifiStateText(wifi)]];
}

// the GPU hover label of the help window's example, as the real one reads, the percentage padded (TipPercents); in the
// unsandboxed variant, which reads the GPU's power, with 0.08 W of it
static NSString* HelpGpuLabel(const CpuReadings* readings)
{
#if CPUTOPBARS_SANDBOXED
  return TipPercents(GpuTipText(readings->gpu, -1.0));
#else
  return TipPercents(GpuTipText(readings->gpu, 0.08));
#endif
}

// the help window's Wi-Fi example, a connection as this app reads one: -50 dBm, WPA2 Personal, 802.11ax, channel 48
// (5 GHz, 80 MHz); its addresses are HelpWifiLabel's
static SystemInfoWifi HelpWifiSample(void)
{
  SystemInfoWifi wifi = {};
  wifi.present = true;
  wifi.powerOn = true;
  wifi.connected = true;
  wifi.rssi = -50;
  wifi.noise = -94;
  wifi.txRate = 720.0;
  wifi.security = 4;
  wifi.phy = 6;
  wifi.channel = 48;
  wifi.band = 2;
  wifi.width = 3;
  return wifi;
}

// the battery and Wi-Fi hover labels of the help window's examples, as the real ones read: the battery at the example's
// charge, charging or not charging on the adapter as the example draws it, or on battery with 3:12 left; Wi-Fi the sample's
static NSString* HelpBatteryLabel(const CpuReadings* readings)
{
  bool charging = readings->batteryCharging;
  bool onAC = charging || readings->batteryOnAC;
  SystemInfoBattery battery = {readings->battery, charging, false, onAC, onAC ? -1 : 192, -1};
  return TipPercents(BatteryTipText(true, &battery));
}

static NSString* HelpWifiLabel(void)
{
  SystemInfoWifi wifi = HelpWifiSample();
  return WifiTipText(&wifi, "192.168.1.23", "192.168.1.1", "a6:3c:12:9e:5b:70");
}

// the disk hover label of the help window's example, as the real one reads: 1 TB, readings->disk of it used, its
// lines (DiskTexts), the percentages padded (TipPercents)
static NSString* HelpDiskLabel(const CpuReadings* readings)
{
  uint64_t whole = 1000000000000ULL;
  uint64_t used = (uint64_t)llround(fmin(fmax(readings->disk, 0.0), 1.0) * (double)whole);
  NSString* title = nil;
  NSString* text = nil;
  NSString* tipText = nil;
  DiskTexts(whole, whole - used, [NSLocale currentLocale], &title, &text, &tipText);
  return TipPercents(tipText);
}

// the readings example's caption, naming what it shows: the readings before the core graph, without the E-cores' and
// the P-cores' when the graph splits (coreSplit), as they head their own bars
static NSString* HelpReadingsCaption(const CpuReadings* readings)
{
  NSMutableArray<NSString*>* names = [NSMutableArray array];
  if (readings->batteryShown)
  {
    [names addObject:@"battery"];
  }
  if (readings->wifiShown)
  {
    [names addObject:@"Wi-Fi"];
  }
  [names addObjectsFromArray:@[@"disk", @"memory"]];
  if (readings->gpuShown)
  {
    [names addObjectsFromArray:@[@"Neural Engine", @"GPU"]];
  }
  [names addObject:@"CPU"];
  if (coreSplit <= 0)
  {
    [names addObjectsFromArray:@[@"E", @"P"]];
  }
  return [names componentsJoinedByString:@", "];
}

// the help window's core graph hover labels, from the example's loads cycled over this Mac's CPUs, as barTipTextAt:
// words them: when the graph splits (coreSplit), two images, one with the E-cores' label under the E reading and one
// with the P-cores', each its section's title with its reading (CoresTipText's titleValue); else one, the whole
// label, under the core graph
static NSArray<NSView*>* HelpCoresExamples(const CpuReadings* readings, const double* coreLoads, int coreLoadCount)
{
  std::vector<double> loads;
  for (natural_t i=0; i<cpu_info.countLogical; i++)
  {
    double load = ((coreLoads != NULL) && (coreLoadCount > 0)) ? coreLoads[i % coreLoadCount] : 0.0;
    loads.push_back(fmin(fmax(load, 0.0), 1.0));
  }
  natural_t perBar = cpu_info.countLogical / CpuSamplerGetCount(granularity);
  NSLocale* locale = [NSLocale currentLocale];
  // the kinds' readings as the example draws them (HelpCoreReadings)
  CpuReadings read = *readings;
  HelpCoreReadings(coreLoads, coreLoadCount, &read);
  if (coreSplit <= 0)
  {
    NSString* text = TipPercents(CoresTipText(loads, cpuKinds, perBar, -1, 0, nil, locale));
    return @[MenuRowsHelpExample(readings, coreLoads, coreLoadCount, MenuRowsExampleWhole, text, -1, @"the cores")];
  }
  NSMutableArray<NSView*>* examples = [NSMutableArray array];
  for (int kind=0; kind<2; kind++)
  {
    bool efficiency = (kind == 0);
    NSString* cores = CoresTipText(loads, cpuKinds, perBar, -1, efficiency ? 'E' : 'P',
                                   CoreKindReadingValue(efficiency ? read.efficiency : read.performance, locale), locale);
    [examples addObject:MenuRowsHelpExample(readings, coreLoads, coreLoadCount, MenuRowsExampleWhole, TipPercents(cores),
                                            efficiency ? CpuRenderReadingEfficiency(CpuRenderReadingsShown(readings)) : CpuRenderReadingPerformance(CpuRenderReadingsShown(readings)),
                                            efficiency ? @"efficiency cores" : @"performance cores")];
  }
  return examples;
}

// a label's text, its percentages three characters wide (TipPercents), but for a value that starts its line's value
// column ("Disk usage:   72%", the next lines "Free:" and so on)
- (NSString*)barTipTextAt:(NSInteger)index
{
  return TipPercents([self barTipTextUnpaddedAt:index]);
}

// a reading's text, one value to a line (TipLines): "Disk usage:   72%", "Free:         279 GB", "Used:         716 GB",
// "Total:        995 GB" (diskTipText); memory's, CPU's, the battery's and the GPU's the same way; an extra bar's, its class's barLabels entry; the core graph's, coresTipText, one kind's (split) with
// that kind's reading on its title's line, "Efficiency cores:   22%"; empty when there is none
- (NSString*)barTipTextUnpaddedAt:(NSInteger)index
{
  if (BarTipIsCores(index))
  {
    return [self coresTipText:index];
  }
  const NSInteger readingsCount = CpuRenderReadingsCount(barTipMask);
  if (index >= readingsCount)
  {
    NSInteger extra = index - readingsCount;
    if ((extra < 0) || (extra >= (NSInteger)extraBarOwner.size()) || (extra >= (NSInteger)extraBarItem.size()) || (extraBarOwner[extra] >= menuRows.count))
    {
      return @"";
    }
    id<MenuRows> rows = menuRows[extraBarOwner[extra]];
    NSArray<NSString*>* labels = [rows respondsToSelector:@selector(barLabels)] ? [rows barLabels] : nil;
    NSString* label = (extraBarItem[extra] < labels.count) ? labels[extraBarItem[extra]] : nil;
    return [label isKindOfClass:[NSString class]] ? label : @"";
  }
  switch (CpuRenderReadingKind(barTipMask, (int)index))
  {
    case CPU_RENDER_KIND_BATTERY:
      return BatteryTipText(readingsBattery, &readingsBatteryState);
    case CPU_RENDER_KIND_WIFI:
      return WifiTipText(&readingsWifi, readingsWifiIp, readingsWifiRouter, readingsWifiMac);
    case CPU_RENDER_KIND_NEURAL_ENGINE:
      return NeuralEngineTipText(readingsNeuralEngine, readingsNeuralEngineBusy);
    case CPU_RENDER_KIND_GPU:
      return GpuTipText(readingsGpu, readingsGpuWatts);
    case CPU_RENDER_KIND_EFFICIENCY:
    case CPU_RENDER_KIND_PERFORMANCE:
    {
      bool efficiency = (index == CpuRenderReadingEfficiency(barTipMask));
      return CoreKindReadingText(efficiency, efficiency ? readingsCpuEfficiency : readingsCpuPerformance, [NSLocale currentLocale]);
    }
    // disk's, memory's and CPU's, one value to a line
    case CPU_RENDER_KIND_DISK:
      return diskTipText ?: @"Disk usage: —";
    case CPU_RENDER_KIND_MEMORY:
      return [self memoryTipText];
    case CPU_RENDER_KIND_CPU:
      return [self cpuTipText];
    default:
      return @"";
  }
}

// follows the pointer: off the item (or the menu open), everything stops; on it, the watch runs; another reading, or
// none, hides the label and arms the new one, except that a shown label moves at once, with no wait, to another extra
// bar of the same group; the same one keeps the label, laid out again only when its text changed
- (void)trackBarTip
{
  NSInteger index = menuIsOpen ? -2 : [self barTipIndexNow];
  if (index == -2)
  {
    [self hideBarTip];
    return;
  }
  if (barTipWatch == nil)
  {
    barTipWatch = [NSTimer timerWithTimeInterval:BAR_TIP_WATCH target:self selector:@selector(watchBarTip:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:barTipWatch forMode:NSRunLoopCommonModes];
  }
  if ((index != barTipIndex) && (index >= CpuRenderReadingsCount(barTipMask)) && (barTipIndex >= CpuRenderReadingsCount(barTipMask)) && barTip.isVisible && [self barTipSameGroup:barTipIndex and:index])
  {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showBarTip) object:nil];
    barTipIndex = index;
    [self showBarTip];
  }
  else if (index != barTipIndex)
  {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showBarTip) object:nil];
    [barTip orderOut:nil];
    barTipIndex = index;
    if (index >= 0)
    {
      [self performSelector:@selector(showBarTip) withObject:nil afterDelay:BAR_TIP_DELAY inModes:@[NSRunLoopCommonModes]];
    }
  }
  else if ((index >= 0) && barTip.isVisible && ![[self barTipTextAt:index] isEqualToString:barTipShown])
  {
    [self showBarTip];
  }
}

- (void)watchBarTip:(NSTimer*)timer
{
  [self trackBarTip];
}

- (void)mouseEntered:(NSEvent*)event
{
  [self trackBarTip];
}

- (void)mouseMoved:(NSEvent*)event
{
  [self trackBarTip];
}

- (void)mouseExited:(NSEvent*)event
{
  [self hideBarTip];
}

// the reading armed or shown is Wi-Fi's
static bool BarTipIsWifi(void)
{
  return (barTipIndex >= 0) && (barTipIndex < CpuRenderReadingsCount(barTipMask)) && (CpuRenderReadingKind(barTipMask, (int)barTipIndex) == CPU_RENDER_KIND_WIFI);
}

// the label below the menu bar, centred under its reading, kept on screen; not when the pointer has left that reading
// since it was armed (the watch hides and re-arms at its next look). Wi-Fi's, as it comes up, first reads Wi-Fi in full,
// for the details only it shows (readWifi:)
- (void)showBarTip
{
  NSStatusBarButton* button = self.statusItem.button;
  if (menuIsOpen || (barTipIndex < 0) || (button.window == nil) || ([self barTipIndexNow] != barTipIndex))
  {
    return;
  }
  if (BarTipIsWifi() && !barTip.isVisible && BatteryWifiShown())
  {
    [self readWifi:true];
  }
  NSString* text = [self barTipTextAt:barTipIndex];
  if (text.length == 0)
  {
    [barTip orderOut:nil];
    return;
  }
  if (barTip == nil)
  {
    barTip = NewTipPanel(&barTipText);
  }
  // a label with line breaks is laid out by whoever wrote it, so its lines are not wrapped; nor is a reading's, one
  // line as its panel row
  bool unwrapped = (barTipIndex < CpuRenderReadingsCount(barTipMask)) || ([text rangeOfString:@"\n"].location != NSNotFound);
  SetTipText(barTip, barTipText, text, unwrapped ? CGFLOAT_MAX : ROW_TIP_MAX_WIDTH);
  barTipShown = text;
  NSRect slot = [self barTipSlotFor:barTipIndex];
  slot.origin.x += barTipLayout.origin.x;
  NSRect onScreen = [button.window convertRectToScreen:[button convertRect:slot toView:nil]];
  NSRect item = button.window.frame;
  NSRect frame = barTip.frame;
  NSRect visible = (button.window.screen ?: [NSScreen mainScreen]).frame;
  frame.origin.x = round(NSMidX(onScreen) - NSWidth(frame)/2.0);
  frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)), NSMaxX(visible) - NSWidth(frame));
  frame.origin.y = NSMinY(item) - BAR_TIP_GAP - NSHeight(frame);
  [barTip setFrame:frame display:YES];
  [barTip orderFrontRegardless];
}

- (void)hideBarTip
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showBarTip) object:nil];
  [barTipWatch invalidate];
  barTipWatch = nil;
  barTipIndex = -1;
  [barTip orderOut:nil];
}

// the Demo card's three previews side by side, with equal room before, between and after them, each caption centred
// under its preview; their heights and tops do not change. Previews too wide to keep SETTINGS_DEMO_MIN_GAP around
// them (many CPUs, or a build's extra bars) are all made narrower by one factor, and each view squeezes its image
// across to fit (setupSettings sets their scaling)
- (void)placeDemoPreviews
{
  NSArray<NSImageView*>* previews = @[self.realDemoView, self.sineDemoView, self.flatDemoView];
  // the widths the renders draw at, read here rather than from the frames, which a shrink has made narrower
  const CGFloat natural[3] = {imageWidth, graphWidth, graphWidth};
  CGFloat cardWidth = NSWidth(self.realDemoView.superview.bounds);
  CGFloat widths = natural[0] + natural[1] + natural[2];
  CGFloat room = cardWidth - 4.0*SETTINGS_DEMO_MIN_GAP;
  CGFloat scale = ((room > 0.0) && (widths > room)) ? room/widths : 1.0;
  CGFloat gap = MAX(0.0, (cardWidth - scale*widths)/4.0);
  CGFloat x = gap;
  for (int n=0; n<3; n++)
  {
    NSImageView* preview = previews[n];
    NSSize size = NSMakeSize(scale*natural[n], NSHeight(preview.frame));
    [preview setFrame:NSMakeRect((int)x, NSMinY(preview.frame), size.width, size.height)];
    [preview setBoundsSize:size];
    demoCaptionCentres[n].constant = (int)x + size.width/2.0;
    x += size.width + gap;
  }
}

- (void)renderPrefsRealWithLight:(BOOL)light readings:(const CpuReadings*)readings
{
  [self.realDemoView setBoundsSize:NSMakeSize(imageWidth, tickHeight)];
  [self.realDemoView setFrameSize:NSMakeSize(imageWidth, tickHeight)];
  [self placeDemoPreviews];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, tickHeight)];
    }
//    else
//    {
//      image = self.realDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, imageWidth, theme, readings);
    }
    [image unlockFocus];
  }
  self.realDemoView.image = image;
}

- (void)renderPrefsSinWithLight:(BOOL)light
{
  CpuSamplerSineDemoUpdate(&cpu_sine_demo_info, speed);

  [self.sineDemoView setBoundsSize:NSMakeSize(graphWidth, tickHeight)];
  [self.sineDemoView setFrameSize:NSMakeSize(graphWidth, tickHeight)];
  [self placeDemoPreviews];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, tickHeight)];
    }
//    else
//    {
//      image = self.sineDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_sine_demo_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, graphWidth, theme, NULL);
    }
    [image unlockFocus];
  }
  self.sineDemoView.image = image;
}

- (void)renderPrefsFlatWithLight:(BOOL)light
{
  CpuSamplerFlatDemoUpdate(&cpu_flat_demo_info, speed);
  
  [self.flatDemoView setBoundsSize:NSMakeSize(graphWidth, tickHeight)];
  [self.flatDemoView setFrameSize:NSMakeSize(graphWidth, tickHeight)];
  [self placeDemoPreviews];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, tickHeight)];
    }
//    else
//    {
//      image = self.flatDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_flat_demo_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, graphWidth, theme, NULL);
    }
    [image unlockFocus];
  }
  self.flatDemoView.image = image;
}

// the bars the MenuRows classes add right of the core graph, in their order, with no limit, whether the app's own bars
// are shown or not. A value that is not a number is not read (-1). A class's first bar starts a group when bars of
// another class come before it, and so does any bar its class's barGroupStarts marks
- (void)collectExtraBars
{
  extraBars.clear();
  extraBarOwner.clear();
  extraBarItem.clear();
  for (NSUInteger owner=0; owner<menuRows.count; owner++)
  {
    id<MenuRows> rows = menuRows[owner];
    NSArray<NSNumber*>* values = [rows respondsToSelector:@selector(barReadings)] ? [rows barReadings] : nil;
    NSArray<NSNumber*>* marks = [rows respondsToSelector:@selector(barMarks)] ? [rows barMarks] : nil;
    NSArray<NSNumber*>* tints = [rows respondsToSelector:@selector(barTints)] ? [rows barTints] : nil;
    NSArray<NSColor*>* colors = [rows respondsToSelector:@selector(barColors)] ? [rows barColors] : nil;
    NSArray<NSNumber*>* alerts = [rows respondsToSelector:@selector(barAlerts)] ? [rows barAlerts] : nil;
    NSArray<NSNumber*>* paces = [rows respondsToSelector:@selector(barPaces)] ? [rows barPaces] : nil;
    NSArray<NSNumber*>* starts = [rows respondsToSelector:@selector(barGroupStarts)] ? [rows barGroupStarts] : nil;
    NSArray<NSNumber*>* narrows = [rows respondsToSelector:@selector(barNarrows)] ? [rows barNarrows] : nil;
    NSArray<NSString*>* letters = [rows respondsToSelector:@selector(barLetters)] ? [rows barLetters] : nil;
    for (NSUInteger item=0; item<values.count; item++)
    {
      NSNumber* value = values[item];
      NSNumber* mark = (item < marks.count) ? marks[item] : nil;
      NSNumber* tint = (item < tints.count) ? tints[item] : nil;
      NSColor* color = (item < colors.count) ? colors[item] : nil;
      NSNumber* alert = (item < alerts.count) ? alerts[item] : nil;
      NSNumber* pace = (item < paces.count) ? paces[item] : nil;
      NSNumber* start = (item < starts.count) ? starts[item] : nil;
      NSNumber* narrow = (item < narrows.count) ? narrows[item] : nil;
      NSString* letter = (item < letters.count) ? letters[item] : nil;
      CpuExtraReading reading = {};
      reading.value = [value isKindOfClass:[NSNumber class]] ? value.doubleValue : -1.0;
      reading.mark = [mark isKindOfClass:[NSNumber class]] ? mark.doubleValue : 0.0;
      reading.tint = [tint isKindOfClass:[NSNumber class]] ? tint.doubleValue : 0.0;
      NSColor* rgb = [color isKindOfClass:[NSColor class]] ? [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] : nil;
      if (rgb)
      {
        reading.hasColor = true;
        reading.colorRed = rgb.redComponent;
        reading.colorGreen = rgb.greenComponent;
        reading.colorBlue = rgb.blueComponent;
      }
      reading.alert = [alert isKindOfClass:[NSNumber class]] ? alert.boolValue : false;
      reading.pace = [pace isKindOfClass:[NSNumber class]] ? pace.doubleValue : 0.0;
      reading.groupStart = [start isKindOfClass:[NSNumber class]] ? start.boolValue : false;
      reading.narrow = [narrow isKindOfClass:[NSNumber class]] ? narrow.boolValue : false;
      // one ASCII character, which the renderer draws when it has its bitmap; anything else is none
      const bool oneCharacter = [letter isKindOfClass:[NSString class]] && (letter.length == 1) && ([letter characterAtIndex:0] < 0x80);
      reading.letter = oneCharacter ? (char)[letter characterAtIndex:0] : 0;
      if ((item == 0) && !extraBars.empty())
      {
        reading.groupStart = true; // bars of another class come before it
      }
      extraBars.push_back(reading);
      extraBarOwner.push_back(owner);
      extraBarItem.push_back(item);
    }
  }
}

// Wi-Fi from CoreWLAN into *wifi: whether this Mac has a Wi-Fi interface, its power, whether it is connected (on, with a
// channel and a signal below 0 dBm), and then its signal, noise, transmit rate and channel; with full also its security
// and PHY mode, which its hover label alone shows. rssiValue and security cost 2 to 3.3 ms a call, the others under 0.3 ms
// (measured on an M3 MacBook Pro, in and out of the sandbox), so a read that is not full leaves security out. Never the
// network's name, its BSSID or the country code, which need Location Services: this app asks for no permission. The
// interface is asked for again while there is none
static void WifiRead(SystemInfoWifi* wifi, bool full)
{
  static CWInterface* interface = nil;
  if (interface == nil)
  {
    interface = [CWWiFiClient sharedWiFiClient].interface;
  }
  long security = wifi->security;
  long phy = wifi->phy;
  *wifi = SystemInfoWifi();
  if (interface == nil)
  {
    return;
  }
  wifi->present = true;
  snprintf(wifi->ifname, sizeof(wifi->ifname), "%s", interface.interfaceName.UTF8String ?: "");
  wifi->powerOn = interface.powerOn;
  if (!wifi->powerOn)
  {
    return;
  }
  CWChannel* channel = interface.wlanChannel;
  wifi->rssi = (int)interface.rssiValue;
  wifi->connected = (channel != nil) && (wifi->rssi < 0);
  if (!wifi->connected)
  {
    return;
  }
  wifi->noise = (int)interface.noiseMeasurement;
  wifi->txRate = interface.transmitRate;
  wifi->channel = channel.channelNumber;
  wifi->band = channel.channelBand;
  wifi->width = channel.channelWidth;
  // a read that is not full keeps the last full read's security and PHY mode, which only the hover label shows (it reads
  // in full as it comes up and while it is up)
  wifi->security = full ? (long)interface.security : security;
  wifi->phy = full ? (long)interface.activePHYMode : phy;
}

// Wi-Fi into readingsWifi (WifiRead); in full also, while connected, the interface's addresses and router, which a read
// that is not full keeps
- (void)readWifi:(bool)full
{
  WifiRead(&readingsWifi, full);
  if (full)
  {
    readingsWifiIp[0] = readingsWifiMac[0] = readingsWifiRouter[0] = 0;
    if (readingsWifi.connected)
    {
      SystemInfoInterfaceAddresses(readingsWifi.ifname, readingsWifiIp, sizeof(readingsWifiIp), readingsWifiMac, sizeof(readingsWifiMac));
      SystemInfoDefaultRouter(readingsWifi.ifname, readingsWifiRouter, sizeof(readingsWifiRouter));
    }
  }
}

// the battery and Wi-Fi, for their bars, hover labels and panel rows: every BATTERY_WIFI_REFRESH s (half a tick early,
// as the other readings), or now; Wi-Fi in full while its hover label is up (readWifi:). While their bars are not shown
// nothing is read and the old values are dropped, so a Mac's slots follow what the last read found
- (void)readBatteryWifi:(bool)now
{
  if (!BatteryWifiShown())
  {
    lastBatteryWifi = 0.0;
    readingsBattery = false;
    readingsWifi = SystemInfoWifi();
    readingsWifiIp[0] = readingsWifiMac[0] = readingsWifiRouter[0] = 0;
    return;
  }
  NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
  if (!now && (lastBatteryWifi > 0.0) && ((uptime - lastBatteryWifi) < (BATTERY_WIFI_REFRESH - 0.5*RefreshInterval())))
  {
    return;
  }
  lastBatteryWifi = uptime;
  readingsBattery = SystemInfoBatteryRead(&readingsBatteryState);
  [self readWifi:(barTip.isVisible && BarTipIsWifi())];
  static bool batteryLogged = false;
  if (!readingsBattery && !batteryLogged)
  {
    batteryLogged = true;
    NSLog(@"no internal battery was found: the battery bar and row are left out");
  }
  static bool wifiLogged = false;
  if (!readingsWifi.present && !wifiLogged)
  {
    wifiLogged = true;
    NSLog(@"no Wi-Fi interface was found: the Wi-Fi bar and rows are left out");
  }
}

- (void)updateCPU:(id)sender
{
  // overall CPU, menu open or not, so that its window is full the moment the menu opens
  SystemInfoCpuTick();
  // overall CPU and memory, for the bars and the panel, every READINGS_TICKS ticks, half a tick early, so that a tick
  // firing a little late does not put the read off by a whole tick; while CPU cannot be read yet (fewer than two
  // samples, after a reset) both keep their last reading and are tried again on the next tick
  if (([[NSProcessInfo processInfo] systemUptime] - lastReadings) >= ((READINGS_TICKS - 0.5)*RefreshInterval()))
  {
    double efficiency = -1.0;
    double performance = -1.0;
    std::vector<double> each(cpu_info.countLogical);
    natural_t eachCount = 0;
    double cpu = SystemInfoCpuBusyEach(NULL, &efficiency, &performance, each.data(), (natural_t)each.size(), &eachCount);
    if (cpu >= 0.0)
    {
      readingsCpu = cpu;
      readingsCpuEfficiency = efficiency;
      readingsCpuPerformance = performance;
      each.resize(eachCount);
      readingsCpuEach = each;
      static bool kindsLogged = false;
      if ((cpuKinds != NULL) && ((efficiency < 0.0) || (performance < 0.0)) && !kindsLogged)
      {
        kindsLogged = true;
        NSLog(@"CPU by kind could not be read (efficiency %.3f, performance %.3f): the CPU row leaves it out", efficiency, performance);
      }
      readingsMemory = SystemInfoMemory(&readingsMemoryUsed, &readingsMemoryTotal);
      readingsSwap = SystemInfoSwap(&readingsSwapUsed);
      static bool swapLogged = false;
      if (!readingsSwap && !swapLogged)
      {
        swapLogged = true;
        NSLog(@"swap could not be read: the memory row leaves it out");
      }
      // the GPU's busy share and whether the Neural Engine is powered, only while their bars are shown; with
      // either switch off nothing is read, and the old values are dropped
      if (GpuShown())
      {
        readingsGpu = SystemInfoGpuBusy();
        readingsNeuralEngine = SystemInfoNeuralEngine();
        // the next sample is queued first, so that after a pause of more than 10 s the old readings are dropped before
        // they are read (they read -1, shown as ON/OFF and no watts, until a sample finishes); the readings are those the
        // last finished sample published, a reading behind (IOReportReader.h); -1 each in the sandboxed variant
        IOReportSample();
        const double aneBusy = IOReportAneBusy();
        readingsNeuralEngineBusy = (aneBusy < 0.0) ? -1.0 : fmin(aneBusy / 100.0, 1.0);
        readingsGpuWatts = IOReportGpuWatts();
#if !CPUTOPBARS_SANDBOXED
        static bool ioReportLogged = false;
        if (IOReportUnreadable() && !ioReportLogged)
        {
          ioReportLogged = true;
          NSLog(@"IOReport could not be read: the Neural Engine may show ON and OFF, and the GPU row may leave out its watts");
        }
#endif
        static bool gpuLogged = false;
        static bool neuralEngineLogged = false;
        if ((readingsGpu < 0.0) && !gpuLogged)
        {
          gpuLogged = true;
          NSLog(@"GPU busy share could not be read: the GPU bar and row leave it out");
        }
        if ((readingsNeuralEngine < 0) && !neuralEngineLogged)
        {
          neuralEngineLogged = true;
          NSLog(@"Neural Engine power could not be read: its bar and row leave it out");
        }
      }
      else
      {
        readingsGpu = -1.0;
        readingsNeuralEngine = -1;
        readingsNeuralEngineBusy = -1.0;
        readingsGpuWatts = -1.0;
      }
      lastReadings = [[NSProcessInfo processInfo] systemUptime];
    }
  }

  // before the image's width is worked out, which follows whether this Mac has a battery and Wi-Fi
  [self readBatteryWifi:false];
  [self collectExtraBars];
  [self updateRendererParameters];

  // one set of readings per tick, for the menu bar and the real-time preview; CPU or memory that cannot be read is -1,
  // and its bar shows only its background (no dot in Dot style); the disk keeps its last reading, -1 before the first
  CpuReadings readings = {-1.0, -1.0, diskFraction, -1.0, -1.0};
  // the pointer is used only by the renders below, within this call; the next tick refills extraBars
  readings.extraCount = (int)extraBars.size();
  readings.extra = extraBars.data();
  readings.extraOnly = !showBars;
  readings.efficiencyBars = coreSplit;
  // one mask (ReadingsShown) for the width worked out above and what is drawn
  const unsigned mask = ReadingsShown();
  readings.gpuShown = ((mask & CPU_RENDER_SHOWN_GPU) != 0);
  readings.batteryShown = ((mask & CPU_RENDER_SHOWN_BATTERY) != 0);
  readings.wifiShown = ((mask & CPU_RENDER_SHOWN_WIFI) != 0);
  readings.battery = -1.0;
  readings.wifi = -1.0;
  if (showBars)
  {
    if (readingsBattery)
    {
      readings.battery = readingsBatteryState.level;
      readings.batteryCharging = readingsBatteryState.charging;
      readings.batteryOnAC = readingsBatteryState.onAC;
    }
    readings.wifi = readingsWifi.connected ? SystemInfoWifiFill(readingsWifi.rssi) : -1.0;
    readings.gpu = readingsGpu;
    readings.neuralEngine = readingsNeuralEngine;
    readings.neuralEngineByShare = (readingsNeuralEngineBusy >= 0.0);
    readings.neuralEngineBusy = readingsNeuralEngineBusy;
    readings.cpu = readingsCpu;
    readings.efficiency = readingsCpuEfficiency;
    readings.performance = readingsCpuPerformance;
    if (readingsMemory && (readingsMemoryTotal > 0))
    {
      readings.memory = MIN((double)readingsMemoryUsed / (double)readingsMemoryTotal, 1.0);
    }
    // half a tick early, so that a tick firing a little late does not put the read off by a whole tick
    if (([[NSProcessInfo processInfo] systemUptime] - lastDiskAttempt) >= (MENUBAR_DISK_REFRESH - 0.5*RefreshInterval()))
    {
      [self readDisk];
    }
  }
  const CpuReadings* shown = (showBars || !extraBars.empty()) ? &readings : NULL;
  
  // the menu bar's appearance need not be the app's: the graph takes the status item's, the previews their window's
  [self renderMenubarWithLight:IsLight(self.statusItem.button.effectiveAppearance) readings:shown];
  if ([self.window isVisible])
  {
    bool light = IsLight(self.window.effectiveAppearance);
    [self renderPrefsRealWithLight:light readings:shown];
    [self renderPrefsSinWithLight:light];
    [self renderPrefsFlatWithLight:light];
  }
}

//static int _task_extmod_info_for_pid(pid_t pid, struct task_extmod_info *info)
//{
//  task_name_t task;
//  kern_return_t kr = task_name_for_pid(mach_task_self(), pid, &task);
//  if (kr != KERN_SUCCESS)
//  {
//    return kr;
//  }
//  else
//  {
//    memset(info, 0, sizeof(struct task_extmod_info));
//    mach_msg_type_number_t count = TASK_EXTMOD_INFO_COUNT;
//    kr = task_info(task, TASK_EXTMOD_INFO, (task_info_t)info, &count);
//    mach_port_deallocate(mach_task_self(), task);
//    if (kr != KERN_SUCCESS)
//    {
//      return kr;
//    }
//  }
//  return 0;
//}

// Samples on every tick, with the menu closed too (about 1-2 ms), so that the CPU% always covers the
// last interval and the list is current the moment the menu opens. Nothing is sampled while frozen.
- (void)updateTop:(id)sender
{
  // the rows a build adds run under Freeze too
  if (menuIsOpen)
  {
    for (id<MenuRows> rows in menuRows)
    {
      if ([rows respondsToSelector:@selector(menuTick)])
      {
        [rows menuTick];
      }
    }
  }

  if (frozen)
  {
    return;
  }

  TopSample();
  lastTopSample = [[NSProcessInfo processInfo] systemUptime];
  topListValid = true;
  baselineOnly = false;
  [self pruneIconCache];

  [self collectTopList];

  if (refreshTop)
  {
    [self updateMenuTop];
  }
}

- (void)collectTopList
{
  // the walk starts at the busiest process, wherever the last walk stopped (the first block of top and stopTopTool
  // collect again between samples)
  TopIterateReset();
  int counter = 0;
#if !CPUTOPBARS_SANDBOXED
  if ((topFigures != nil) && (topOrder == TopOrderCpu))
  {
    // other users' processes take the CPU top read for them, and are ranked with the rest: the whole sample is walked,
    // keeping the TOP_COUNT busiest
    const TopProcessSample_t *each = TopIterate();
    while (each != NULL)
    {
      TopProcessSample_t candidate = *each;
      if (candidate.cpu_known == 0)
      {
        NSNumber* figure = topFigures[[NSNumber numberWithInt:candidate.pid]];
        if (figure != nil)
        {
          candidate.cpu = [figure doubleValue];
          candidate.cpu_known = 1;
        }
      }
      if (candidate.cpu_known != 0)
      {
        int at = counter;
        while ((at > 0) && (topProcceses[at - 1].cpu < candidate.cpu))
        {
          at--;
        }
        if (at < TOP_COUNT)
        {
          int last = MIN(counter, TOP_COUNT - 1);
          for (int j=last; j>at; j--)
          {
            topProcceses[j] = topProcceses[j - 1];
          }
          topProcceses[at] = candidate;
          counter = MIN(counter + 1, TOP_COUNT);
        }
      }
      each = TopIterate();
    }
    topCount = counter;
    // the row that counts them stays hidden while top's figures are in
    topOthersCount = 0;
    return;
  }
#endif
  const TopProcessSample_t *psample = TopIterate();
  while ((psample != NULL) && (counter < TOP_COUNT))
  {
    // other users' processes have no CPU or memory figure in the sandbox and are not ranked; in memory order a
    // process whose memory could not be read is not ranked either
    if (((topOrder == TopOrderMemory) ? psample->mem_known : psample->cpu_known) != 0)
    {
      topProcceses[counter++] = *psample;
    }
    psample = TopIterate();
  }
  topCount = counter;
  topOthersCount = TopUnreadableCount();
}

#if !CPUTOPBARS_SANDBOXED
#pragma mark - /usr/bin/top while the menu is open

- (void)startTopTool
{
  [self stopTopTool];

  TopToolSession* session = [[TopToolSession alloc] init];
  session->generation = ++topToolGeneration;
  session->pending = [NSMutableData data];

  NSTask* task = [[NSTask alloc] init];
  [task setExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/top"]];
  // a sample every 2 s, whatever the Refresh setting: top takes whole seconds, and 2 s costs it about half the CPU of 1 s
  [task setArguments:@[@"-l", @"0", @"-s", @"2", @"-o", @"cpu", @"-stats", @"pid,cpu", @"-n", [NSString stringWithFormat:@"%d", TOP_TOOL_ROWS]]];
  // the decimal separator is '.' whatever the user's locale
  NSMutableDictionary* environment = [NSMutableDictionary dictionaryWithObject:@"C" forKey:@"LC_ALL"];
  NSString* path = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
  if (path != nil)
  {
    environment[@"PATH"] = path;
  }
  [task setEnvironment:environment];
  NSPipe* pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

  NSUInteger generation = session->generation;
  [task setTerminationHandler:^(NSTask* t) {
    int status = [t terminationStatus];
    long reason = (long)[t terminationReason];
    dispatch_async(dispatch_get_main_queue(), ^{
      if ((topToolSession != nil) && (topToolSession->generation == generation) && !topToolSession->loggedExit)
      {
        topToolSession->loggedExit = true;
        NSLog(@"/usr/bin/top exited while the menu was open: status %d, reason %ld", status, reason);
      }
    });
  }];

  NSError* error = nil;
  if (![task launchAndReturnError:&error])
  {
    NSLog(@"could not launch /usr/bin/top: %@", error);
    return;
  }
  session->task = task;
  topToolSession = session;

  __weak AppDelegate* weakSelf = self;
  [[pipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle* handle) {
    NSData* data = [handle availableData];
    if ([data length] == 0)
    {
      // end of file: a handler left set would be called again and again
      [handle setReadabilityHandler:nil];
      return;
    }
    TopToolConsume(session, data, ^(NSData* pids, NSData* cpus) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf applyTopTool:session pids:pids cpus:cpus];
      });
    }, ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        if ((topToolSession == session) && !session->loggedEmpty)
        {
          session->loggedEmpty = true;
          NSLog(@"/usr/bin/top printed a sample with no readable rows");
        }
      });
    });
  }];
}

- (void)applyTopTool:(TopToolSession*)session pids:(NSData*)pids cpus:(NSData*)cpus
{
  if ((topToolSession != session) || (session->generation != topToolGeneration))
  {
    return;
  }
  const pid_t* pidList = (const pid_t*)[pids bytes];
  const double* cpuList = (const double*)[cpus bytes];
  NSUInteger count = [pids length] / sizeof(pid_t);
  NSMutableDictionary<NSNumber*, NSNumber*>* figures = [NSMutableDictionary dictionaryWithCapacity:count];
  for (NSUInteger i=0; i<count; i++)
  {
    figures[[NSNumber numberWithInt:pidList[i]]] = [NSNumber numberWithDouble:cpuList[i]];
  }
  topFigures = figures;
  // the rows redraw at each process sample (updateTop:), which picks up top's latest block. At the run's first block
  // they redraw now, so that other users' processes join with it and the rows change once
  if (refreshTop && !session->drawn)
  {
    session->drawn = true;
    [self collectTopList];
    [self updateMenuTop];
  }
}

- (void)stopTopTool
{
  topToolGeneration++;
  TopToolSession* session = topToolSession;
  topToolSession = nil;
  if (session != nil)
  {
    NSTask* task = session->task;
    [[[task standardOutput] fileHandleForReading] setReadabilityHandler:nil];
    [task setTerminationHandler:nil];
    // terminate on a task that never launched throws
    if ([task isRunning])
    {
      [task terminate];
    }
  }
  bool had = (topFigures != nil);
  topFigures = nil;
  if (had && !frozen)
  {
    [self collectTopList];
  }
}
#endif

- (void)setupStatusItem
{
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  [self updateCPU:nil];
}

- (void)removeUserDefaults
{
    NSUserDefaults * userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary * dict = [userDefaults dictionaryRepresentation];
    for (id key in dict) {
        [userDefaults removeObjectForKey:key];
    }
    [userDefaults synchronize];
}

// the refresh interval Settings offers: 0.1, 0.2 or 0.5 s; any other stored value counts as 0.2, the default
static double RefreshInterval(void)
{
  double interval = [[NSUserDefaults standardUserDefaults] doubleForKey:RefreshKey];
  return ((interval == 0.1) || (interval == 0.5)) ? interval : 0.2;
}

// the process rows Settings offers: 3, 5, 10 or 15; any other stored value counts as 5, the default
static int TopRows(void)
{
  NSInteger rows = [[NSUserDefaults standardUserDefaults] integerForKey:TopRowsKey];
  return ((rows == 3) || (rows == 10) || (rows == TOP_COUNT)) ? (int)rows : 5;
}

// the process sample's interval: 2.5 s, whatever the Refresh setting, with the menu open or closed
static double TopInterval(void)
{
  return TOP_REFRESH_RATE;
}

- (void)setupPreferences
{
#if 0
  [self removeUserDefaults];
#endif
  
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{RefreshKey:@0.2}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ShowBarsKey:@YES}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ShowGpuNeuralEngineKey:@YES}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ShowBatteryWifiKey:@YES}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ShowBarLettersKey:@YES}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{TopRowsKey:@5}];

  // Settings no longer offers granularity, style, line, width, appearance or theme: each takes its old default,
  // whatever an earlier version (1.0 included) stored under its key, which is left in place
  granularity = 2;
  speed = 10.0 * RefreshInterval();
  bar = true;
  stripped = true;
  tickWidth = 3.0;
  colored = true;
  theme = THEME_BLUE;
  showBars = [[NSUserDefaults standardUserDefaults] boolForKey:ShowBarsKey];
  showGpuNeuralEngine = [[NSUserDefaults standardUserDefaults] boolForKey:ShowGpuNeuralEngineKey];
  showBatteryWifi = [[NSUserDefaults standardUserDefaults] boolForKey:ShowBatteryWifiKey];
  showBarLetters = [[NSUserDefaults standardUserDefaults] boolForKey:ShowBarLettersKey];
  topShown = TopRows();

  [self updateRendererParameters];
  [self updateUI];
  [self updateLoginButton];
}

// both timers, at launch and after a pause; none while paused (nothing can be seen: updatePause starts them again)
- (void)setupTimers
{
  // the overall CPU's window starts again, so that it never spans a pause, and CPU and memory are read again soon
  SystemInfoCpuReset();
  lastReadings = 0.0;
  [self startGraphTimer];
  [self startTopTimer:TopInterval()];
}

// (re)starts the graph's timer at the Refresh interval, none while paused; a Refresh change restarts only this one, so
// that the process sample, the overall CPU's window and the readings carry on at their own rates
- (void)startGraphTimer
{
  [timerCPU invalidate];
  timerCPU = nil;
  if (paused)
  {
    return;
  }

  // common modes: they fire while the menu is open (event tracking) and under a modal panel too. A tolerance of a
  // tenth of the interval lets macOS group their wakeups with others'.
  double interval = RefreshInterval();
  timerCPU = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(updateCPU:) userInfo:nil repeats:YES];
  timerCPU.tolerance = 0.1 * interval;
  [[NSRunLoop mainRunLoop] addTimer:timerCPU forMode:NSRunLoopCommonModes];
}

// (re)starts the process sample's timer at its interval (TopInterval), its next sample in delay s
- (void)startTopTimer:(NSTimeInterval)delay
{
  [timerTop invalidate];
  timerTop = nil;
  if (paused)
  {
    return;
  }
  double interval = TopInterval();
  timerTop = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(updateTop:) userInfo:nil repeats:YES];
  timerTop.tolerance = 0.1 * interval;
  [timerTop setFireDate:[NSDate dateWithTimeIntervalSinceNow:delay]];
  [[NSRunLoop mainRunLoop] addTimer:timerTop forMode:NSRunLoopCommonModes];
}

// the delay to the next process sample: one interval after the last sample (now if that is past), or the timer's own
// next sample when that comes sooner (the soon one after a pause or an unfreeze)
static NSTimeInterval TopDelay(void)
{
  NSTimeInterval delay = MAX(0.0, lastTopSample + TopInterval() - [[NSProcessInfo processInfo] systemUptime]);
  if (timerTop != nil)
  {
    delay = MIN(delay, MAX(0.0, [[timerTop fireDate] timeIntervalSinceNow]));
  }
  return delay;
}

- (void)workspaceChanged:(NSNotification*)notification
{
  NSString* name = notification.name;
  if ([name isEqualToString:NSWorkspaceScreensDidSleepNotification])
  {
    screensAsleep = true;
  }
  else if ([name isEqualToString:NSWorkspaceScreensDidWakeNotification])
  {
    // the displays are on, so the Mac is awake too
    screensAsleep = false;
    systemAsleep = false;
  }
  else if ([name isEqualToString:NSWorkspaceWillSleepNotification])
  {
    systemAsleep = true;
  }
  else if ([name isEqualToString:NSWorkspaceDidWakeNotification])
  {
    systemAsleep = false;
  }
  else if ([name isEqualToString:NSWorkspaceSessionDidResignActiveNotification])
  {
    sessionInactive = true;
  }
  else if ([name isEqualToString:NSWorkspaceSessionDidBecomeActiveNotification])
  {
    // this session is in front, so its displays are on and the Mac is awake: a wake missed while it was not in
    // front cannot keep the graph paused
    screensAsleep = false;
    systemAsleep = false;
    sessionInactive = false;
  }
  [self updatePause];
}

// stops the timers when nothing can be seen, and starts them again when something can
- (void)updatePause
{
  bool pause = screensAsleep || systemAsleep || sessionInactive;
  if (pause == paused)
  {
    return;
  }
  paused = pause; // first: setupTimers makes no timers while paused
  if (paused)
  {
    [timerCPU invalidate];
    timerCPU = nil;
    [timerTop invalidate];
    timerTop = nil;
    NSLog(@"paused: nothing can be seen (screens asleep %d, system asleep %d, session inactive %d)", screensAsleep, systemAsleep, sessionInactive);
  }
  else
  {
    // the first readings after the pause would average over all of it: take them now as the new baselines
    CpuSamplerUpdate(&cpu_info);
    [self updateTop:nil];
    [self setupTimers];
    // and the next process sample soon, so that an open menu does not show the pause's average for a whole interval
    [self startTopTimer:MIN(TOP_MIN_INTERVAL, TopInterval())];
    NSLog(@"running again");
  }
}

- (void)fillDescForProcess:(NSString*)name tab:(NSTabViewItem*)descriptionTab
{
  // "--": a process name starting with '-' must not be read as an option
  [self runTool:@"/usr/bin/man" arguments:@[@"-P", @"col -bx", @"--", name] withStderr:NO done:^(NSString* output) {
    if ([output length] > 0)
    {
      // the tab stays where selectPid put it: removing the selected tab would select the args tab
      [self.procDescTextView setString:[NSString stringWithFormat:@"\n%@", output]];
    }
    else
    {
      [self.procAppView removeTabViewItem:descriptionTab];
    }
  }];
}

- (BOOL)fillArgsEnvForProcess:(TopProcessInfo_t*) info
{
  BOOL found = NO;

  if (info->args_count > 0)
  {
    NSString *output = [NSString stringWithFormat:@"\nCOMMAND:\n\n%@\n\n\nARGUMENTS: (%d)\n\n%@\n\nENVIRONMENT: (%d)\n\n%@\n",
                        SampleText(info->command), info->args_count, SampleText(info->args_info), info->envs_count, SampleText(info->envs_info)];
    [self.procArgsEnvTextView setString:output];
    found = YES;
  }
  else
  {
    NSString *output = [NSString stringWithFormat:@"\nCOMMAND:\n%s\n\n\nARGUMENTS: (%d)\n\n%s\n\nENVIRONMENT: (%d)\n\n%s\n",
                        "", 0, "", 0, ""];
    [self.procArgsEnvTextView setString:output];
  }
  
  return found;
}

#if !CPUTOPBARS_SANDBOXED
#pragma mark - Inspector tabs: lsof, nm, sample

// a tab that holds one read-only text, laid out and set in the type of the "args & env" tab
- (NSTabViewItem*)inspectorTabLabeled:(NSString*)label identifier:(NSString*)identifier textView:(NSTextView* __strong *)textView
{
  NSScrollView* argsScroll = self.procArgsEnvScrollView;
  NSView* container = [[NSView alloc] initWithFrame:[[argsScroll superview] bounds]];
  [container setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:[argsScroll frame]];
  [scroll setAutoresizingMask:[argsScroll autoresizingMask]];
  [scroll setBorderType:NSNoBorder];
  [scroll setHasVerticalScroller:YES];
  [scroll setHasHorizontalScroller:NO];
  [scroll setDrawsBackground:NO];

  NSSize size = [scroll contentSize];
  NSTextView* text = [[NSTextView alloc] initWithFrame:NSMakeRect(0.0, 0.0, size.width, size.height)];
  [text setEditable:NO];
  [text setRichText:NO];
  [text setImportsGraphics:NO];
  [text setUsesFindBar:YES];
  [text setIncrementalSearchingEnabled:YES];
  [text setFont:[self.procArgsEnvTextView font]];
  [text setMinSize:NSMakeSize(0.0, size.height)];
  [text setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
  [text setVerticallyResizable:YES];
  [text setHorizontallyResizable:NO];
  [text setAutoresizingMask:NSViewWidthSizable];
  [[text textContainer] setContainerSize:NSMakeSize(size.width, FLT_MAX)];
  [[text textContainer] setWidthTracksTextView:YES];
  [scroll setDocumentView:text];
  [container addSubview:scroll];

  NSTabViewItem* item = [[NSTabViewItem alloc] initWithIdentifier:identifier];
  [item setLabel:label];
  [item setView:container];
  *textView = text;
  return item;
}

// after "args & env", where the xib's tabs end; the tab view's delegate runs a tab's tool when it is selected
- (void)setupInspectorTabs
{
  [self.procAppView addTabViewItem:[self inspectorTabLabeled:@"lsof" identifier:@"3" textView:&procLsofTextView]];
  [self.procAppView addTabViewItem:[self inspectorTabLabeled:@"nm" identifier:@"4" textView:&procNmTextView]];
  [self.procAppView addTabViewItem:[self inspectorTabLabeled:@"sample" identifier:@"5" textView:&procThreadsTextView]];
  [self.procAppView setDelegate:self];
}

- (void)fillLsofForProcess:(NSNumber*)pid_number
{
  if ((pid_number == nil) || (lsofJob == inspectGeneration))
  {
    return;
  }
  NSUInteger generation = inspectGeneration;
  lsofJob = generation;

  [self runTool:@"/usr/sbin/lsof" arguments:@[@"-p", [pid_number stringValue]] withStderr:YES done:^(NSString* output) {
    if (lsofJob == generation)
    {
      lsofJob = 0;
    }
    [procLsofTextView setString:(output != nil) ? output : @"N/A (error)"];
  }];
}

- (void)fillNmForProcess:(NSString*)path
{
  if ([path length] == 0)
  {
    // no executable path (kernel_task): nothing to run nm on
    [procNmTextView setString:@"N/A"];
    return;
  }
  if (nmJob == inspectGeneration)
  {
    return;
  }
  NSUInteger generation = inspectGeneration;
  nmJob = generation;

  // "--": a path starting with '-' must not be read as an option
  [self runTool:@"/usr/bin/nm" arguments:@[@"--", path] withStderr:YES done:^(NSString* output) {
    if (nmJob == generation)
    {
      nmJob = 0;
    }
    [procNmTextView setString:(output != nil) ? output : @"N/A (error)"];
  }];
}

- (void)fillThreadsForProcess:(NSNumber*)pid_number
{
  if ((pid_number == nil) || (threadsJob == inspectGeneration))
  {
    return;
  }
  NSUInteger generation = inspectGeneration;
  threadsJob = generation;
  NSUInteger run = ++threadsRun;

  // sample runs for 10 seconds by default: count down until its report arrives
  for (int i=0; i<=10; i++)
  {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if ((threadsRun == run) && (threadsJob == generation) && (inspectGeneration == generation))
      {
        [procThreadsTextView setString:[NSString stringWithFormat:@"\nsampling ends in %d seconds ...", (10-i)]];
      }
    });
  }

  [self runTool:@"/usr/bin/sample" arguments:@[[pid_number stringValue]] withStderr:YES done:^(NSString* output) {
    if (threadsJob == generation)
    {
      threadsJob = 0;
    }
    [procThreadsTextView setString:(output != nil) ? output : @"N/A (error)"];
  }];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
  if (current_process_pid == nil)
  {
    // no selection yet, or a row whose process has exited: no tool runs
    return;
  }

  switch ([[tabViewItem identifier] intValue])
  {
    case 3:
      [self fillLsofForProcess:current_process_pid];
      break;
    case 4:
      [self fillNmForProcess:current_process_path];
      break;
    case 5:
      [self fillThreadsForProcess:current_process_pid];
      break;
    default:
      break;
  }
}
#endif

#pragma mark - Public APIs

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
  srandom((int)time(NULL)^getpid());

  runningTasks = [NSMutableSet set];

  {
    {
      CFDictionaryValueCallBacks tableCallbacks = { 0, stringRetain, stringFree, NULL, stringEqual };
      topCpuHashTable = CFDictionaryCreateMutable(NULL, 0, NULL, &tableCallbacks);
    }
    topNameCache = [NSMutableDictionary dictionary];
    topMemCache = [NSMutableDictionary dictionary];
    topIconCache = [NSMutableDictionary dictionary];
    frozenStarts = [NSMutableDictionary dictionary];

    // the menu's font, from the app's Resources, for this process only; when it does not load, MENU_FONT falls back
    // to the system's monospaced font
    NSURL* fontURL = [[NSBundle mainBundle] URLForResource:@"IBMPlexMono-Regular" withExtension:@"otf"];
    CFErrorRef fontError = NULL;
    if ((fontURL == nil) || !CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess, &fontError))
    {
      NSLog(@"the menu font did not load (%@); the system's monospaced font stands in", (fontError != NULL) ? (__bridge_transfer NSError*)fontError : @"not in the app");
    }

    CpuRenderInit();
    CpuSamplerInit(&cpu_info);
    cpuKinds = (char*)calloc(cpu_info.countLogical, 1);
    if (CpuSamplerGetKinds(cpu_info.countLogical, cpuKinds) == 0)
    {
      NSLog(@"cores: kinds not read from the device tree; the cores' label lists every CPU under \"Cores:\", then their mean");
      free(cpuKinds);
      cpuKinds = NULL;
    }
    SystemInfoCpuSetKinds(cpu_info.countLogical, cpuKinds);
    CpuSamplerSineDemoInit(&cpu_sine_demo_info);
    CpuSamplerFlatDemoInit(&cpu_flat_demo_info);
    TopInit(); // takes the first sample: the CPU baseline
    lastTopSample = [[NSProcessInfo processInfo] systemUptime];

    [self setupPreferences];
    [self setupStatusItem];
    [self setupMenus];
    [self setupSettings];

    // the app menu's four items name the app: found by action in the main menu only, as the status menu's Quit sends terminate: too
    NSDictionary<NSString*, NSString*>* appMenuTitles = @{
      NSStringFromSelector(@selector(orderFrontStandardAboutPanel:)): @"About %@",
      NSStringFromSelector(@selector(hide:)): @"Hide %@",
      NSStringFromSelector(@selector(terminate:)): @"Quit %@",
      NSStringFromSelector(@selector(showHelp:)): @"%@ Help",
    };
    for (NSMenuItem* top in [NSApp mainMenu].itemArray)
    {
      for (NSMenuItem* entry in top.submenu.itemArray)
      {
        NSString* format = appMenuTitles[NSStringFromSelector(entry.action)];
        if (format != nil)
        {
          entry.title = [NSString stringWithFormat:format, AppName()];
        }
      }
    }

    // pause while nothing can be seen (updatePause)
    NSNotificationCenter* workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (NSNotificationName name in @[NSWorkspaceScreensDidSleepNotification, NSWorkspaceScreensDidWakeNotification,
                                      NSWorkspaceWillSleepNotification, NSWorkspaceDidWakeNotification,
                                      NSWorkspaceSessionDidResignActiveNotification, NSWorkspaceSessionDidBecomeActiveNotification])
    {
      [workspaceCenter addObserver:self selector:@selector(workspaceChanged:) name:name object:nil];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesBecameKey:)
                                                 name:NSWindowDidBecomeKeyNotification object:self.window];
    [self setupTimers];

    // the readings panel's disk row has a value the first time the menu opens
    [self readDisk];

    // room for the inspector's "Helper of:" line
    [self.procAppName setUsesSingleLineMode:NO];
    [self.procAppName setMaximumNumberOfLines:2];
#if !CPUTOPBARS_SANDBOXED
  [self setupInspectorTabs];
#endif
  }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
#if !CPUTOPBARS_SANDBOXED
  [self stopTopTool];
#endif
  //[[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)openPreferences:(id)sender
{
  [NSApp activateIgnoringOtherApps:YES];
  
  [self updateLoginButton];
  [self.window center];
  [self.window orderFrontRegardless];
  [self.window makeKeyWindow];
}

- (IBAction)openHelp:(id)sender
{
  [NSApp activateIgnoringOtherApps:YES];

  if (helpWindow == nil)
  {
    helpWindow = MakeHelpWindow();
    [helpWindow center];
  }
  [helpWindow makeKeyAndOrderFront:sender];
}

- (IBAction)openAbout:(id)sender
{
  [NSApp activateIgnoringOtherApps:YES];

  [NSApp orderFrontStandardAboutPanel:sender];
}

#ifndef CPUTOPBARS_NO_FUNDRAISER
- (IBAction)openFundraiser:(id)sender
{
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://give.michaeljfox.org/halfmarble"]];
}
#endif

- (void)processExplorer:(id)sender
{
  NSLog(@"processExplorer");
}

// the views the rows add to the inspector's header, on a line of their own below its text, at its right; with none,
// nothing here changes the header
- (void)showInspectorRowsForPid:(pid_t)pid name:(NSString*)name exited:(bool)exited
{
  NSView* header = [self.procAppName superview];
  if (inspectorRowViews == nil)
  {
    inspectorRowViews = [[NSMutableArray alloc] init];
    for (id<MenuRows> rows in menuRows)
    {
      if ([rows respondsToSelector:@selector(inspectorViews)])
      {
        for (NSView* view in [rows inspectorViews])
        {
          // they stay at the right as the window is resized
          [view setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
          [header addSubview:view];
          [inspectorRowViews addObject:view];
        }
      }
    }
  }
  for (id<MenuRows> rows in menuRows)
  {
    if ([rows respondsToSelector:@selector(inspectorShowsPid:name:exited:)])
    {
      [rows inspectorShowsPid:pid name:name exited:exited];
    }
  }
  if ([inspectorRowViews count] == 0)
  {
    return;
  }
  // the views' line, as tall as the tallest view, each view centred on it, right to left from the header's right edge,
  // the margin the icon keeps at the left; one line of text and the views' line are centred on the icon. The text sits
  // on the views' line and ends where the views do, a helper's second line under its first, so two lines reach 16 pt
  // higher; the views' line stays put
  CGFloat tallest = 0.0;
  for (NSView* view in inspectorRowViews)
  {
    tallest = MAX(tallest, NSHeight([view frame]));
  }
  NSRect iconFrame = [self.procAppIcon frame];
  CGFloat viewsTop = round(NSMidY(iconFrame) + ((INSPECTOR_LINE + tallest) / 2.0)) - INSPECTOR_LINE;
  CGFloat midY = viewsTop - (tallest / 2.0);
  CGFloat right = NSWidth([header bounds]) - INSPECTOR_MARGIN;
  NSRect nameFrame = [self.procAppName frame];
  nameFrame.origin.y = viewsTop;
  nameFrame.size.width = MAX(0.0, right - NSMinX(nameFrame));
  [self.procAppName setFrame:nameFrame];
  CGFloat x = right;
  for (NSView* view in [inspectorRowViews reverseObjectEnumerator])
  {
    NSRect frame = [view frame];
    x -= NSWidth(frame);
    frame.origin = NSMakePoint(x, round(midY - (NSHeight(frame) / 2.0)));
    [view setFrame:frame];
    x -= INSPECTOR_GAP;
  }
}

- (void)selectPid:(id)sender
{
  static NSTabViewItem* descriptionTab = nil;
  if (descriptionTab == nil)
  {
    descriptionTab = [self.procAppView tabViewItemAtIndex:0];
  }
    
  NSMenuItem* menu = sender;

  pid_t pid = (pid_t)[menu tag];
  TopProcessSample_t* sample = TopGetSample(pid);
  if (sample == NULL)
  {
    // the process exited after the menu was filled
    return;
  }

  // a row whose process has exited, or whose pid now belongs to another process (its start time differs from the
  // last sample's, or, while frozen, from the one read at the freeze): show what the row recorded and run no tool
  // on the pid
  uint64_t start = ProcessStartTime(pid);
  uint64_t frozenStart = [frozenStarts[[NSNumber numberWithInt:pid]] unsignedLongLongValue];
  bool exited = (start == 0) || ((sample->start_us != 0) && (start != sample->start_us)) ||
                (frozen && (start != frozenStart));

  inspectGeneration++;
  [self stopInspectorTools];
  current_process_pid = exited ? nil : [NSNumber numberWithInt:pid];
#if !CPUTOPBARS_SANDBOXED
  // KERN_PROCARGS2 (info->command) fails for other users' processes; proc_pidpath fails only for kernel_task
  current_process_path = exited ? nil : ProcessPath(pid);
#endif

  ProcessIconDecision* decision = exited ? topIconCache[[NSNumber numberWithInt:pid]] : [self decisionForPid:pid];
  NSImage *icon = [decision.image copy];
  [icon setSize:NSMakeSize(TOP_ICON_SIZE, TOP_ICON_SIZE)];
  [self.procAppIcon setImage:icon];

  TopProcessInfo_t* info = exited ? NULL : TopGetArgs(pid);
  NSString* name = exited ? SampleText(sample->name) : SampleText(info->name);
  
  char bits_str[40] = "00000000 00000000 00000000 00000000";
  uint32_t flags = sample->flags;
  for (int i=0; i<8; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[34-i] = '1';
    }
  }
  for (int i=8; i<16; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[33-i] = '1';
    }
  }
  for (int i=16; i<24; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[32-i] = '1';
    }
  }
  for (int i=24; i<32; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[31-i] = '1';
    }
  }
  bits_str[36] = '\0';
  
  char const *status_str = NULL;
  switch(sample->status)
  {
    case SIDL: status_str = "SIDL"; break;
    case SRUN: status_str = "SRUN"; break;
    case SSLEEP: status_str = "SSLEEP"; break;
    case SSTOP: status_str = "SSTOP"; break;
    case SZOMB: status_str = "SZOMB"; break;
    default: status_str = "?"; break;
  }

  NSString* line = [NSString stringWithFormat:@"%@%@, pid:%d, ppid:%d, prio:%d, stat:%d (%s), flags:%d (%s)",
                    SampleText(sample->name), (exited ? @" (exited)" : @""), sample->pid, sample->ppid, sample->tprio, sample->status, status_str, sample->flags, bits_str];
  if (decision.helper)
  {
    line = [line stringByAppendingFormat:@"\n%@", decision.helperLine];
  }
  [self.procAppName setStringValue:line];
  // the window is resizable: keep the field's current x, width and vertical center
  NSRect frame = [self.procAppName frame];
  CGFloat midY = NSMidY(frame);
  frame.size.height = decision.helper ? 32.0 : 16.0;
  frame.origin.y = midY - (frame.size.height / 2.0);
  [self.procAppName setFrame:frame];
  [self showInspectorRowsForPid:pid name:SampleText(sample->name) exited:exited];
#if !CPUTOPBARS_SANDBOXED
  [self updateKillButton:sample exited:exited];
#endif

  NSString* live = exited ? @"\nN/A (exited)" : @"\npreparing...";
  [self.procDescTextView setString:@"\npreparing..."];
  [self.procArgsEnvTextView setString:live];
#if !CPUTOPBARS_SANDBOXED
  [procLsofTextView setString:live];
  [procNmTextView setString:live];
  [procThreadsTextView setString:live];
#endif

  //if ([self.top isVisible] == NO)
  {
    [NSApp activateIgnoringOtherApps:YES];
    [self.top center];
    [self.top orderFrontRegardless];
    [self.top makeKeyWindow];
  }
  
  // open on the man page: put its tab back first if the last process had none, and fillDescForProcess removes it
  // again if this one has none
  if ([self.procAppView indexOfTabViewItem:descriptionTab] == NSNotFound)
  {
    [self.procAppView insertTabViewItem:descriptionTab atIndex:0];
  }
  [self.procAppView selectTabViewItem:descriptionTab];

  if (!exited)
  {
    [self fillArgsEnvForProcess:info];
  }
  [self fillDescForProcess:name tab:descriptionTab];
}

// Freeze keeps the rows as they were when it was chosen, so that they can be examined
- (void)toggleFreeze:(NSMenuItem*)sender
{
  [self hideRowTip];
  frozen = !frozen;
  [sender setImage:(frozen ? freezeOnImage : freezeOffImage)];
  // the row is a view (StayOpenRowView), which draws the item's image
  [sender.view setNeedsDisplay:YES];
  [frozenStarts removeAllObjects];
  if (frozen)
  {
    // the menu stays open, and its rows keep what they show
    refreshTop = false;
#if !CPUTOPBARS_SANDBOXED
    [self stopTopTool];
#endif
    for (int i=0; i<TOP_COUNT; i++)
    {
      if (![topMenus[i] isHidden])
      {
        pid_t pid = (pid_t)[topMenus[i] tag];
        frozenStarts[[NSNumber numberWithInt:pid]] = [NSNumber numberWithUnsignedLongLong:ProcessStartTime(pid)];
      }
    }
  }
  else
  {
    // the next sample would average the CPU% over the whole freeze: take one now as the new baseline. It is never
    // shown: refreshTop is false while frozen, and baselineOnly holds the rows until the next sample
    [self updateTop:nil];
    baselineOnly = true;
    if (menuIsOpen)
    {
      // as at an opening: the rows refresh from the next sample, taken soon
      refreshTop = true;
#if !CPUTOPBARS_SANDBOXED
      [self startTopTool];
#endif
      [self startTopTimer:MIN(TOP_MIN_INTERVAL, TopInterval())];
    }
    else
    {
      [self startTopTimer:TopInterval()];
    }
  }
}

- (void)launchActivityMonitor:(id)sender
{
  NSString *appPath = @"/System/Applications/Utilities/Activity Monitor.app";
  [self launchAppAt:appPath with:@[]];
}

- (IBAction)packageButtonClicked:(id)sender
{
  granularity = 0;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  [[NSUserDefaults standardUserDefaults] setDouble:granularity forKey:GranularityKey];

  [self updateUI];
}

- (IBAction)coreButtonClicked:(id)sender
{
  granularity = 1;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  [[NSUserDefaults standardUserDefaults] setDouble:granularity forKey:GranularityKey];

  [self updateUI];
}

- (IBAction)logicalButtonClicked:(id)sender
{
  granularity = 2;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  [[NSUserDefaults standardUserDefaults] setDouble:granularity forKey:GranularityKey];
  
  [self updateUI];
}

- (IBAction)fastButtonClicked:(id)sender
{
  speed = 1.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.1 forKey:RefreshKey];

  [self updateUI];
  [self startGraphTimer];
}

- (IBAction)normalButtonClicked:(id)sender
{
  speed = 2.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.2 forKey:RefreshKey];

  [self updateUI];
  [self startGraphTimer];
}

- (IBAction)slowButtonClicked:(id)sender
{
  speed = 5.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.5 forKey:RefreshKey];

  [self updateUI];
  [self startGraphTimer];
}

- (IBAction)barButtonClicked:(id)sender
{
  bar = true;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  colored = [[NSUserDefaults standardUserDefaults] boolForKey:AppearanceKey];
  [[NSUserDefaults standardUserDefaults] setBool:bar forKey:StyleKey];

  [self updateUI];
}

- (IBAction)dotButtonClicked:(id)sender
{
  bar = false;
  colored = false;
  [[NSUserDefaults standardUserDefaults] setBool:bar forKey:StyleKey];

  [self updateUI];
}

- (IBAction)solidButtonClicked:(id)sender
{
  stripped = false;
  [[NSUserDefaults standardUserDefaults] setBool:stripped forKey:TickLineKey];
  
  [self updateUI];
}

- (IBAction)strippedButtonClicked:(id)sender
{
  stripped = true;
  [[NSUserDefaults standardUserDefaults] setBool:stripped forKey:TickLineKey];
  
  [self updateUI];
}

- (IBAction)thinButtonClicked:(id)sender
{
  tickWidth = 1.0;
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];
  
  [self updateUI];
}

- (IBAction)standardButtonClicked:(id)sender
{
  tickWidth = 2.0;
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];
  
  [self updateUI];
}

- (IBAction)thickButtonClicked:(id)sender
{
  tickWidth = 3.0;
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];
  
  [self updateUI];
}

- (IBAction)greyButtonClicked:(id)sender
{
  colored = false;
  [[NSUserDefaults standardUserDefaults] setBool:colored forKey:AppearanceKey];
  
  [self updateUI];
}

- (IBAction)colorButtonClicked:(id)sender
{
  colored = true;
  [[NSUserDefaults standardUserDefaults] setBool:colored forKey:AppearanceKey];
  
  [self updateUI];
}

- (IBAction)yellow:(id)sender
{
  theme = THEME_YELLOW;

  [self.yellowButton setState:NSControlStateValueOn];
  [self.greenButton setState:NSControlStateValueOff];
  [self.blueButton setState:NSControlStateValueOff];

  [[NSUserDefaults standardUserDefaults] setDouble:theme forKey:ThemeKey];
}

- (IBAction)green:(id)sender
{
  theme = THEME_GREEN;
  
  [self.yellowButton setState:NSControlStateValueOff];
  [self.greenButton setState:NSControlStateValueOn];
  [self.blueButton setState:NSControlStateValueOff];

  [[NSUserDefaults standardUserDefaults] setDouble:theme forKey:ThemeKey];
}

- (IBAction)blue:(id)sender
{
  theme = THEME_BLUE;
  
  [self.yellowButton setState:NSControlStateValueOff];
  [self.greenButton setState:NSControlStateValueOff];
  [self.blueButton setState:NSControlStateValueOn];

  [[NSUserDefaults standardUserDefaults] setDouble:theme forKey:ThemeKey];
}

- (IBAction)showBarsButtonClicked:(id)sender
{
  showBars = (showBarsSwitch.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:showBars forKey:ShowBarsKey];
  [self updateRendererParameters];
  [self updateUI];
}

- (IBAction)showGpuButtonClicked:(id)sender
{
  showGpuNeuralEngine = (showGpuSwitch.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:showGpuNeuralEngine forKey:ShowGpuNeuralEngineKey];
  [self updateRendererParameters];
  [self updateUI];
}

- (IBAction)showBatteryWifiButtonClicked:(id)sender
{
  showBatteryWifi = (showBatteryWifiSwitch.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:showBatteryWifi forKey:ShowBatteryWifiKey];
  // on: read at once, so the slots are there at the next render; off: the values are dropped
  [self readBatteryWifi:true];
  [self updateRendererParameters];
  [self updateUI];
}

- (IBAction)showBarLettersButtonClicked:(id)sender
{
  showBarLetters = (showBarLettersSwitch.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:showBarLetters forKey:ShowBarLettersKey];
  [self updateRendererParameters];
  [self updateUI];
}

// Refresh: 10, 5 or 2 times a second, by the segment chosen
- (IBAction)refreshChoiceChanged:(id)sender
{
  switch (refreshChoice.selectedSegment)
  {
    case 0:
      [self fastButtonClicked:sender];
      break;
    case 1:
      [self normalButtonClicked:sender];
      break;
    case 2:
      [self slowButtonClicked:sender];
      break;
    default:
      break;
  }
}

// Top processes: 3, 5, 10 or 15 rows, by the segment chosen. The menu is closed while Settings is used, and its next
// opening redraws the rows (updateMenuTop); while frozen they keep what they showed until the unfreeze
- (IBAction)topRowsChoiceChanged:(id)sender
{
  NSInteger index = topRowsChoice.selectedSegment;
  if ((index < 0) || (index >= (NSInteger)TOP_ROWS_CHOICES))
  {
    return;
  }
  [[NSUserDefaults standardUserDefaults] setInteger:topRowsChoices[index] forKey:TopRowsKey];
  topShown = TopRows();
  [self updateUI];
}

// Launch at login: macOS keeps the setting (System Settings, Login Items), so the switch shows what macOS
// reports.
- (void)updateLoginButton
{
  loginSwitch.state = ([SMAppService mainAppService].status == SMAppServiceStatusEnabled) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (IBAction)loginButtonClicked:(id)sender
{
  SMAppService* service = [SMAppService mainAppService];
  BOOL on = (loginSwitch.state == NSControlStateValueOn);
  NSError* error = nil;
  BOOL ok = on ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
  if (!ok)
  {
    NSLog(@"launch at login: %@ failed: %@ %ld, status %ld", on ? @"register" : @"unregister", error.domain, (long)error.code, (long)service.status);
  }
  if (on && (service.status == SMAppServiceStatusRequiresApproval))
  {
    // registered, but the user turned it off in System Settings: show them where to allow it
    [SMAppService openSystemSettingsLoginItems];
  }
  [self updateLoginButton];
}

- (void)preferencesBecameKey:(NSNotification*)notification
{
  // the setting may have changed in System Settings while the Settings window was open
  [self updateLoginButton];
}

#if !CPUTOPBARS_SANDBOXED
// the Kill button: shown, and enabled only for a process KillAllowed lets the app end
- (void)updateKillButton:(TopProcessSample_t*)sample exited:(bool)exited
{
  [self.killButton setHidden:NO];
  [self.killButton setEnabled:(!exited && KillAllowed(sample->pid, sample->uid, getpid(), getuid()))];
}

- (void)showKillProblem:(int)error name:(NSString*)name pid:(pid_t)pid
{
  NSAlert* alert = [[NSAlert alloc] init];
  if (error == ESRCH)
  {
    [alert setMessageText:[NSString stringWithFormat:@"%@ (pid %d) has already exited.", name, pid]];
  }
  else if (error == EPERM)
  {
    [alert setMessageText:[NSString stringWithFormat:@"%@ (pid %d) cannot be ended from here.", name, pid]];
    [alert setInformativeText:@"macOS does not let this app end it."];
  }
  else
  {
    [alert setMessageText:[NSString stringWithFormat:@"%@ (pid %d) could not be ended.", name, pid]];
    [alert setInformativeText:[NSString stringWithUTF8String:strerror(error)]];
  }
  [alert beginSheetModalForWindow:self.top completionHandler:nil];
}

// SIGTERM first; if the process is still there 3 s later, the user is offered SIGKILL
- (IBAction)killButtonClicked:(id)sender
{
  pid_t pid = [current_process_pid intValue];
  TopProcessSample_t* sample = (pid > 0) ? TopGetSample(pid) : NULL;
  if ((sample == NULL) || !KillAllowed(pid, sample->uid, getpid(), getuid()))
  {
    return;
  }
  NSString* name = SampleText(sample->name);
  // the start time tells the process from a later one that is given the same pid
  uint64_t start = ProcessStartTime(pid);
  if (start == 0)
  {
    [self showKillProblem:ESRCH name:name pid:pid];
    return;
  }

  NSAlert* alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:@"End %@ (pid %d)?", name, pid]];
  [alert setInformativeText:@"The process is asked to quit. Work it has not saved can be lost."];
  [[alert addButtonWithTitle:@"End Process"] setHasDestructiveAction:YES];
  [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:self.top completionHandler:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn)
    {
      return;
    }
    if (ProcessStartTime(pid) != start)
    {
      [self showKillProblem:ESRCH name:name pid:pid];
      return;
    }
    if (kill(pid, SIGTERM) != 0)
    {
      [self showKillProblem:errno name:name pid:pid];
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      // gone: the pid is free, or belongs to a later process
      if ((kill(pid, 0) != 0) || (ProcessStartTime(pid) != start))
      {
        return;
      }
      NSAlert* force = [[NSAlert alloc] init];
      [force setMessageText:[NSString stringWithFormat:@"%@ (pid %d) is still running.", name, pid]];
      [force setInformativeText:@"Force Quit ends it at once, without letting it save anything."];
      [[force addButtonWithTitle:@"Force Quit"] setHasDestructiveAction:YES];
      [force addButtonWithTitle:@"Leave It"];
      [force beginSheetModalForWindow:self.top completionHandler:^(NSModalResponse answer) {
        if (answer != NSAlertFirstButtonReturn)
        {
          return;
        }
        if (ProcessStartTime(pid) != start)
        {
          [self showKillProblem:ESRCH name:name pid:pid];
        }
        else if (kill(pid, SIGKILL) != 0)
        {
          [self showKillProblem:errno name:name pid:pid];
        }
      }];
    });
  }];
}
#else
// the Kill button stays hidden
- (IBAction)killButtonClicked:(id)sender
{
}
#endif

- (void)menuWillOpen:(NSMenu *)menu
{
  menuIsOpen = true;
  [self hideBarTip];
  if (paused)
  {
    // the menu is open, so something can be seen: a wake was missed
    NSLog(@"menu opened while paused (screens asleep %d, system asleep %d, session inactive %d): running again", screensAsleep, systemAsleep, sessionInactive);
    screensAsleep = false;
    systemAsleep = false;
    sessionInactive = false;
    [self updatePause];
  }

  // frozen too
  for (id<MenuRows> rows in menuRows)
  {
    if ([rows respondsToSelector:@selector(menuWillOpen)])
    {
      [rows menuWillOpen];
    }
  }

  // frozen: the rows keep what they showed, and no sample runs
  if (!frozen)
  {
    refreshTop = true;
#if !CPUTOPBARS_SANDBOXED
    [self startTopTool];
#endif

    // take a fresh sample, unless the timer has just taken one: a very short interval gives noisy CPU%
    if (!topListValid || (([[NSProcessInfo processInfo] systemUptime] - lastTopSample) >= TOP_MIN_INTERVAL))
    {
      [self updateTop:nil];
      // the next sample a whole interval after this one, so that its CPU% never covers a shorter window
      [self startTopTimer:TopInterval()];
    }
    else
    {
      [self updateMenuTop];
      // the next sample an interval after the last, or at the timer's own fire when that comes sooner (TopDelay)
      [self startTopTimer:TopDelay()];
    }
  }
  else
  {
    // frozen: no sample, but the rows a build adds tick at the process sample's interval
    [self startTopTimer:TopInterval()];
  }

  // the menu's window is new on every opening; paint it once it is on screen
  [self performSelector:@selector(paintMenuBackground) withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];

  // the readings panel, frozen too: placed once the menu's window is on screen, then updated every second
  infoPlaced = false;
  infoRetried = false;
  infoSideDecided = false;
  infoWidth = 0.0;
  [self performSelector:@selector(showInfoPanel) withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];
  [self readDisk];
  // the battery and Wi-Fi, for the panel's first values
  [self readBatteryWifi:true];
  [infoTimer invalidate];
  infoTimer = [NSTimer timerWithTimeInterval:INFO_REFRESH target:self selector:@selector(updateInfoPanel:) userInfo:nil repeats:YES];
  infoTimer.tolerance = 0.1 * INFO_REFRESH;
  [[NSRunLoop mainRunLoop] addTimer:infoTimer forMode:NSRunLoopCommonModes];
}

- (void)paintMenuBackground
{
  PaintOpenMenuBackground();
}

- (void)menuDidClose:(NSMenu *)menu
{
  // the menu can close before its deferred paint runs
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(paintMenuBackground) object:nil];

  menuIsOpen = false;
  refreshTop = false;
#if !CPUTOPBARS_SANDBOXED
  [self stopTopTool];
#endif
  // the next sample an interval after the last, or at the timer's own fire when that comes sooner (TopDelay)
  [self startTopTimer:TopDelay()];
  [self hideRowTip];
  [self hideInfoPanel];

  for (id<MenuRows> rows in menuRows)
  {
    if ([rows respondsToSelector:@selector(menuDidClose)])
    {
      [rows menuDidClose];
    }
  }
}

// while frozen, a row with helper text shows it after ROW_TIP_DELAY on the row
- (void)menu:(NSMenu*)aMenu willHighlightItem:(NSMenuItem*)item
{
  // the same row again: its text is showing, or about to
  if ((item != nil) && (item == rowTipItem))
  {
    return;
  }
  [self hideRowTip];
  if (frozen && [item.representedObject isKindOfClass:[NSString class]])
  {
    rowTipItem = item;
    [self performSelector:@selector(showRowTip) withObject:nil afterDelay:ROW_TIP_DELAY inModes:@[NSRunLoopCommonModes]];
  }
}

// a tooltip-style box: a borderless panel at help level in the tooltip material, its label in the menu font at the
// tooltip font's size
static NSPanel* NewTipPanel(NSTextField* __strong * label)
{
  NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 100, 20) styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel) backing:NSBackingStoreBuffered defer:YES];
  panel.level = CGWindowLevelForKey(kCGHelpWindowLevelKey);
  panel.ignoresMouseEvents = YES;
  panel.hidesOnDeactivate = NO;
  panel.hasShadow = YES;
  panel.opaque = NO;
  panel.backgroundColor = [NSColor clearColor];
  panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSVisualEffectView* background = [[NSVisualEffectView alloc] init];
  background.material = NSVisualEffectMaterialToolTip;
  background.state = NSVisualEffectStateActive;
  background.wantsLayer = YES;
  background.layer.cornerRadius = 5.0;
  background.layer.masksToBounds = YES;
  panel.contentView = background;
  *label = [NSTextField wrappingLabelWithString:@""];
  (*label).font = MENU_FONT([NSFont toolTipsFontOfSize:0].pointSize);
  [background addSubview:*label];
  return panel;
}

// the box's text, wrapped at wrap pt, the box sized to it at its present origin. A blank line in the text is a
// menu-style line, INFO_SEPARATOR_HEIGHT tall as in the readings panel, between the parts above and below it: label
// holds the first part, and the box's other labels and lines, made here, are kept for the next text
static void SetTipText(NSPanel* panel, NSTextField* label, NSString* text, CGFloat wrap)
{
  NSArray<NSString*>* parts = [(text ?: @"") componentsSeparatedByString:@"\n\n"];
  NSView* background = panel.contentView;
  NSMutableArray<NSTextField*>* labels = [NSMutableArray arrayWithObject:label];
  NSMutableArray<NSBox*>* lines = [NSMutableArray array];
  for (NSView* view in background.subviews)
  {
    if ([view isKindOfClass:[NSBox class]])
    {
      [lines addObject:(NSBox*)view];
    }
    else if ((view != label) && [view isKindOfClass:[NSTextField class]])
    {
      [labels addObject:(NSTextField*)view];
    }
  }
  while (labels.count > parts.count)
  {
    [labels.lastObject removeFromSuperview];
    [labels removeLastObject];
  }
  while (labels.count < parts.count)
  {
    NSTextField* more = [NSTextField wrappingLabelWithString:@""];
    more.font = label.font;
    [background addSubview:more];
    [labels addObject:more];
  }
  while (lines.count > parts.count - 1)
  {
    [lines.lastObject removeFromSuperview];
    [lines removeLastObject];
  }
  while (lines.count < parts.count - 1)
  {
    NSBox* line = [[NSBox alloc] init];
    line.boxType = NSBoxSeparator;
    [background addSubview:line];
    [lines addObject:line];
  }
  std::vector<NSSize> sizes;
  NSSize size = NSMakeSize(0.0, (CGFloat)lines.count * INFO_SEPARATOR_HEIGHT);
  for (NSUInteger i=0; i<parts.count; i++)
  {
    labels[i].stringValue = parts[i];
    NSSize part = [labels[i] sizeThatFits:NSMakeSize(wrap, CGFLOAT_MAX)];
    sizes.push_back(NSMakeSize(ceil(part.width), ceil(part.height)));
    size.width = MAX(size.width, sizes.back().width);
    size.height += sizes.back().height;
  }
  CGFloat top = 4.0 + size.height;
  for (NSUInteger i=0; i<parts.count; i++)
  {
    if (i > 0)
    {
      lines[i - 1].frame = NSMakeRect(6.0, floor(top - INFO_SEPARATOR_HEIGHT/2.0), size.width, 1.0);
      top -= INFO_SEPARATOR_HEIGHT;
    }
    labels[i].frame = NSMakeRect(6.0, top - sizes[i].height, size.width, sizes[i].height);
    top -= sizes[i].height;
  }
  NSRect frame = panel.frame;
  [panel setFrame:NSMakeRect(NSMinX(frame), NSMaxY(frame) - (size.height + 8.0), size.width + 12.0, size.height + 8.0) display:panel.isVisible];
}

- (void)showRowTip
{
  NSMenuItem* item = rowTipItem;
  if (!frozen || ![item.representedObject isKindOfClass:[NSString class]])
  {
    return;
  }

  NSRect row = NSZeroRect;
  NSWindow* window = OpenMenuWindow(menu, item, &row);
  if (window == nil)
  {
    static bool logged = false;
    if (!logged)
    {
      logged = true;
      NSLog(@"the open menu's rows were not found: no helper text shown");
    }
    return;
  }

  if (rowTip == nil)
  {
    rowTip = NewTipPanel(&rowTipText);
  }

  SetTipText(rowTip, rowTipText, item.representedObject, ROW_TIP_MAX_WIDTH);
  rowTipRow = row;
  rowTipMenuWindow = window;
  [self placeRowTip];
  [rowTip orderFrontRegardless];
}

// left of the menu, level with its row; where the readings panel is on that side and level with the box too, left of
// the panel instead; kept on screen, even when that means covering the menu or the panel
- (void)placeRowTip
{
  NSRect frame = rowTip.frame;
  NSScreen* screen = rowTipMenuWindow.screen ?: [NSScreen mainScreen];
  NSRect visible = screen.visibleFrame;
  frame.origin.y = NSMidY(rowTipRow) - NSHeight(frame)/2.0;
  frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)), NSMaxY(visible) - NSHeight(frame));
  frame.origin.x = NSMinX(rowTipMenuWindow.frame) - ROW_TIP_GAP - NSWidth(frame);
  if (infoPlaced && infoOnLeft && infoPanel.isVisible)
  {
    NSRect panel = infoPanel.frame;
    if ((NSMinY(frame) < NSMaxY(panel)) && (NSMaxY(frame) > NSMinY(panel)))
    {
      frame.origin.x = NSMinX(panel) - ROW_TIP_GAP - NSWidth(frame);
    }
  }
  frame.origin.x = MAX(frame.origin.x, NSMinX(visible));
  [rowTip setFrame:frame display:YES];
}

- (void)hideRowTip
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showRowTip) object:nil];
  rowTipItem = nil;
  rowTipMenuWindow = nil;
  [rowTip orderOut:nil];
}

#pragma mark - The readings panel beside the menu

- (void)makeInfoPanel
{
  infoPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel) backing:NSBackingStoreBuffered defer:YES];
  infoPanel.level = CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey);
  infoPanel.ignoresMouseEvents = YES;
  infoPanel.hidesOnDeactivate = NO;
  infoPanel.hasShadow = YES;
  infoPanel.opaque = NO;
  infoPanel.backgroundColor = [NSColor clearColor];
  infoPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorFullScreenAuxiliary;
  // glass as the menu's, shaped and painted like it at each opening (matchInfoPanelToMenu:)
  infoGlass = [[NSGlassEffectView alloc] init];
  infoGlass.cornerRadius = INFO_CORNER_RADIUS;
  NSView* background = [[NSView alloc] init];
  background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  background.accessibilityRole = NSAccessibilityGroupRole;
  background.accessibilityLabel = @"Readings";
  infoGlass.contentView = background;
  infoPanel.contentView = infoGlass;
  // the rows are made by applyInfoValues (makeInfoRows:starts:)
}

// a label and a value for each of count rows, and a separator for each section start: the ones there are kept, the
// missing ones added at the end, the extra ones removed from the end, so the panel follows a build's rows when their
// number changes (MenuRows' panelRows); applyInfoValues sets their text
- (void)makeInfoRows:(NSUInteger)count starts:(NSIndexSet*)starts
{
  NSView* background = infoGlass.contentView;
  NSFont* font = MENU_FONT(MENU_ICON_SIZE-2);
  NSMutableArray<NSTextField*>* labels = [NSMutableArray arrayWithArray:infoLabels ?: @[]];
  NSMutableArray<NSTextField*>* values = [NSMutableArray arrayWithArray:infoValues ?: @[]];
  while (labels.count > count)
  {
    [labels.lastObject removeFromSuperview];
    [labels removeLastObject];
    [values.lastObject removeFromSuperview];
    [values removeLastObject];
  }
  while (labels.count < count)
  {
    NSTextField* label = [NSTextField labelWithString:@""];
    label.font = font;
    label.textColor = [NSColor labelColor];
    [background addSubview:label];
    [labels addObject:label];
    NSTextField* value = [NSTextField labelWithString:@""];
    value.font = font;
    value.textColor = [NSColor labelColor];
    value.alignment = NSTextAlignmentRight;
    [background addSubview:value];
    [values addObject:value];
  }
  infoLabels = labels;
  infoValues = values;

  NSMutableArray<NSBox*>* separators = [NSMutableArray arrayWithArray:infoSeparators ?: @[]];
  while (separators.count > starts.count)
  {
    [separators.lastObject removeFromSuperview];
    [separators removeLastObject];
  }
  while (separators.count < starts.count)
  {
    NSBox* separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    [background addSubview:separator];
    [separators addObject:separator];
  }
  infoSeparators = separators;
  infoSeparatorRows = [starts copy];
}

// the menu's look, read at each opening since the settings can change in between: its appearance (the menu bar's,
// which need not be the app's), its glass's shape, style and tint, and the grey it is painted with Reduce
// Transparency in Dark Mode (PaintOpenMenuBackground)
- (void)matchInfoPanelToMenu:(NSWindow*)window
{
  infoPanel.appearance = window.effectiveAppearance;
  NSGlassEffectView* menuGlass = FindGlassEffectView(window);
  if (menuGlass != nil)
  {
    infoGlass.cornerRadius = menuGlass.cornerRadius;
    infoGlass.style = menuGlass.style;
    infoGlass.tintColor = menuGlass.tintColor;
  }
  if (PaintsMenusGrey() && IsDarkAqua(window.effectiveAppearance))
  {
    PaintGlassGrey(infoGlass);
  }
  else if (infoGlass.contentView.layer != nil)
  {
    infoGlass.contentView.layer.backgroundColor = NULL;
  }
}

- (void)showInfoPanel
{
  NSWindow* window = OpenMenuWindow(menu, freezeItem, NULL);
  if (window == nil)
  {
    if (!infoRetried)
    {
      infoRetried = true;
      [self performSelector:@selector(showInfoPanel) withObject:nil afterDelay:INFO_RETRY_DELAY inModes:@[NSRunLoopCommonModes]];
      return;
    }
    static bool logged = false;
    if (!logged)
    {
      logged = true;
      NSLog(@"the open menu's window was not found: no readings panel shown");
    }
    return;
  }

  if (infoPanel == nil)
  {
    [self makeInfoPanel];
  }
  [self matchInfoPanelToMenu:window];
  infoMenuWindow = window;
  infoPlaced = true;
  [self applyInfoValues];
  [infoPanel orderFrontRegardless];
}

- (void)updateInfoPanel:(id)sender
{
  if (!infoPlaced)
  {
    return;
  }
  // half a tick early, so that a tick firing a little late does not put the read off by a whole second
  if (([[NSProcessInfo processInfo] systemUptime] - lastDiskRead) >= (DISK_REFRESH - 0.5*INFO_REFRESH))
  {
    [self readDisk];
  }
  [self applyInfoValues];
}

// the readings after the menu bar's gap, as shown, each its title and value, in the bars' order: the Neural Engine and
// the GPU while their bars are shown (GpuShown), then CPU; each its last reading (updateCPU:)
- (NSArray<NSArray<NSString*>*>*)readingRowsAfterGap
{
  NSMutableArray<NSArray<NSString*>*>* rows = [NSMutableArray array];
  if (GpuShown())
  {
    [rows addObject:[self neuralEngineRow]];
    [rows addObject:[self gpuRow]];
  }
  [rows addObject:[self cpuRow]];
  return rows;
}

- (NSArray<NSString*>*)diskRow
{
  return @[diskTitle ?: @"Disk usage:", diskText ?: @"—"];
}

// the memory's hover label, one value to a line (TipLines): "Memory usage:" and its percentage, "Free:", "Used:",
// "Swapped:" (only while swap is read) and "Total:", every value starting in one column; "Memory usage: —" when it was
// not read
- (NSString*)memoryTipText
{
  if (!readingsMemory || (readingsMemoryTotal == 0))
  {
    return @"Memory usage: —";
  }
  NSLocale* locale = [NSLocale currentLocale];
  uint64_t used = MIN(readingsMemoryUsed, readingsMemoryTotal);
  NSMutableArray<NSArray<NSString*>*>* rows = [NSMutableArray arrayWithObjects:@[@"Memory usage:", PercentText(readingsMemoryUsed, readingsMemoryTotal, locale)],
                                               @[@"Free:", GiBText(readingsMemoryTotal - used, locale)],
                                               @[@"Used:", GiBText(used, locale)], nil];
  if (readingsSwap)
  {
    [rows addObject:@[@"Swapped:", GiBText(readingsSwapUsed, locale)]];
  }
  [rows addObject:@[@"Total:", GiBText(readingsMemoryTotal, locale)]];
  return TipLines(rows);
}

- (NSArray<NSString*>*)memoryRow
{
  NSLocale* locale = [NSLocale currentLocale];
  NSString* memoryTitle = @"Memory usage:";
  NSString* memoryUsed = @"—";
  if (readingsMemory)
  {
    memoryTitle = TotalTitle(GiBText(readingsMemoryTotal, locale), @"Memory usage:");
    memoryUsed = PercentText(readingsMemoryUsed, readingsMemoryTotal, locale);
    if (readingsMemoryTotal > 0)
    {
      uint64_t used = MIN(readingsMemoryUsed, readingsMemoryTotal);
      NSString* swapped = readingsSwap ? [NSString stringWithFormat:@", swapped %@", GiBText(readingsSwapUsed, locale)] : @"";
      memoryUsed = [NSString stringWithFormat:@"%@ (free %@, used %@%@)", memoryUsed, GiBText(readingsMemoryTotal - used, locale), GiBText(used, locale), swapped];
    }
  }
  return @[memoryTitle, memoryUsed];
}

- (NSArray<NSString*>*)cpuRow
{
  NSLocale* locale = [NSLocale currentLocale];
  double busy = readingsCpu;
  NSString* cpu = (busy < 0.0) ? @"—" : [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(busy * 100.0)];
  // each kind's share beside it, "21% (Efficiency cores: 30%, Performance cores: 12%)", when both were read
  if ((busy >= 0.0) && (readingsCpuEfficiency >= 0.0) && (readingsCpuPerformance >= 0.0))
  {
    cpu = [[NSString alloc] initWithFormat:@"%@ (Efficiency cores: %ld%%, Performance cores: %ld%%)" locale:locale, cpu, lround(readingsCpuEfficiency * 100.0), lround(readingsCpuPerformance * 100.0)];
  }
  return @[@"CPU:", cpu];
}

// the CPU's hover label, one value to a line (TipLines): "CPU:", and when both kinds were read, as in cpuRow,
// "Efficiency cores:" and "Performance cores:"; "CPU: —" when it was not read
- (NSString*)cpuTipText
{
  if (readingsCpu < 0.0)
  {
    return @"CPU: —";
  }
  NSLocale* locale = [NSLocale currentLocale];
  NSMutableArray<NSArray<NSString*>*>* rows = [NSMutableArray arrayWithObject:@[@"CPU:", [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(readingsCpu * 100.0)]]];
  if ((readingsCpuEfficiency >= 0.0) && (readingsCpuPerformance >= 0.0))
  {
    [rows addObject:@[@"Efficiency cores:", [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(readingsCpuEfficiency * 100.0)]]];
    [rows addObject:@[@"Performance cores:", [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(readingsCpuPerformance * 100.0)]]];
  }
  return TipLines(rows);
}

- (NSArray<NSString*>*)gpuRow
{
  NSLocale* locale = [NSLocale currentLocale];
  NSString* gpu = (readingsGpu < 0.0) ? @"—" : [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(fmin(readingsGpu, 1.0) * 100.0)];
  // its power beside it, "12%  0.08 W", when IOReport gives it (the unsandboxed variant)
  if ((readingsGpu >= 0.0) && (readingsGpuWatts >= 0.0))
  {
    gpu = [[NSString alloc] initWithFormat:@"%@  %.2f W" locale:locale, gpu, readingsGpuWatts];
  }
  return @[@"GPU:", gpu];
}

- (NSArray<NSString*>*)neuralEngineRow
{
  NSString* neuralEngine = (readingsNeuralEngine < 0) ? @"—" : ((readingsNeuralEngine > 0) ? @"ON" : @"OFF");
  if (readingsNeuralEngineBusy >= 0.0)
  {
    neuralEngine = [[NSString alloc] initWithFormat:@"%ld%%" locale:[NSLocale currentLocale], lround(readingsNeuralEngineBusy * 100.0)];
  }
  return @[@"Neural Engine:", neuralEngine];
}

// the panel's rows as shown: uptime, read now, then the readings in the bars' order in two sections, split where the
// menu bar's gap is: the battery's row, Wi-Fi's, disk and memory (the disk row the last reading of readDisk, memory the
// last of updateCPU:), then those after the gap (readingRowsAfterGap); then each MenuRows' panel rows as a section of
// their own; starts, when given, gets the first row of each section after uptime, and headings, when given, gets the
// rows a build marks as headings
- (NSArray<NSArray<NSString*>*>*)infoRowsWithStarts:(NSMutableIndexSet*)starts headings:(NSMutableIndexSet*)headings
{
  NSMutableArray<NSArray<NSString*>*>* rows = [NSMutableArray arrayWithObject:@[@"Uptime:", UptimeText(SystemInfoUptimeSeconds())]];
  const NSUInteger readingsFirst = rows.count;
  [starts addIndex:readingsFirst];
  const unsigned shown = ReadingsShown();
  if ((shown & CPU_RENDER_SHOWN_BATTERY) != 0)
  {
    [rows addObject:@[@"Battery:", BatteryValueText(readingsBattery, &readingsBatteryState)]];
  }
  if ((shown & CPU_RENDER_SHOWN_WIFI) != 0)
  {
    [rows addObjectsFromArray:WifiRows(&readingsWifi)];
  }
  [rows addObject:[self diskRow]];
  [rows addObject:[self memoryRow]];
  [starts addIndex:rows.count];
  [rows addObjectsFromArray:[self readingRowsAfterGap]];
  for (id<MenuRows> menuRow in menuRows)
  {
    NSArray<NSArray<NSString*>*>* section = [menuRow respondsToSelector:@selector(panelRows)] ? [menuRow panelRows] : nil;
    if (section.count > 0)
    {
      NSUInteger first = rows.count;
      [starts addIndex:first];
      [rows addObjectsFromArray:section];
      NSArray* marks = [menuRow respondsToSelector:@selector(panelHeadings)] ? [menuRow panelHeadings] : nil;
      for (NSUInteger k=0; k<MIN(section.count, marks.count); k++)
      {
        if ([marks[k] isKindOfClass:[NSNumber class]] && [marks[k] boolValue])
        {
          [headings addIndex:first + k];
        }
      }
    }
  }
  return rows;
}

// sets the values, then sizes and places the panel: left of the menu and level with its top, or right of it when the
// left has no room; kept on screen, even when that means covering the menu. The side is decided once per opening and
// the panel only widens within one, so a row tip placed left of it stays clear of it; its height follows the rows,
// whose number a build's panelRows may change.
- (void)applyInfoValues
{
  if (!infoPlaced || (infoPanel == nil))
  {
    return;
  }

  NSMutableIndexSet* starts = [NSMutableIndexSet indexSet];
  NSMutableIndexSet* headings = [NSMutableIndexSet indexSet];
  NSArray<NSArray<NSString*>*>* rows = [self infoRowsWithStarts:starts headings:headings];
  if ((rows.count != infoValues.count) || ![starts isEqualToIndexSet:infoSeparatorRows])
  {
    [self makeInfoRows:rows.count starts:starts];
  }
  NSUInteger count = rows.count;
  CGFloat valueWidth = 0.0;
  CGFloat rowWidth = 0.0;
  for (NSUInteger i=0; i<count; i++)
  {
    // labels are reused by index as rows come and go, so every row sets its font and colour every time
    bool heading = [headings containsIndex:i];
    NSString* shown = heading ? @"" : rows[i][1];
    infoLabels[i].font = heading ? MENU_TITLE_FONT : MENU_FONT(MENU_ICON_SIZE-2);
    infoLabels[i].textColor = heading ? MENU_HEADING_COLOR : [NSColor labelColor];
    infoLabels[i].stringValue = rows[i][0];
    infoValues[i].stringValue = shown;
    [infoValues[i] sizeToFit];
    [infoLabels[i] sizeToFit];
    valueWidth = MAX(valueWidth, NSWidth(infoValues[i].frame));
    // a row's own need: its title and value side by side, the gap only when it has both; an empty side needs nothing
    CGFloat title = (rows[i][0].length > 0) ? NSWidth(infoLabels[i].frame) : 0.0;
    CGFloat value = (shown.length > 0) ? NSWidth(infoValues[i].frame) : 0.0;
    rowWidth = MAX(rowWidth, title + (((title > 0.0) && (value > 0.0)) ? INFO_COLUMN_GAP : 0.0) + value);
  }
  CGFloat width = ceil(INFO_INSET + rowWidth + INFO_EXTRA_WIDTH + INFO_INSET);
  bool widened = (width > infoWidth);
  width = MAX(width, infoWidth);
  infoWidth = width;
  CGFloat height = (CGFloat)infoValues.count * INFO_ROW_HEIGHT + (CGFloat)infoSeparators.count * INFO_SEPARATOR_HEIGHT + 2.0 * INFO_VERTICAL_INSET;

  for (NSUInteger i=0; i<count; i++)
  {
    // below the separators of the sections that start at this row or above it
    CGFloat gaps = (CGFloat)[infoSeparatorRows countOfIndexesInRange:NSMakeRange(0, i + 1)];
    CGFloat y = height - INFO_VERTICAL_INSET - (CGFloat)(i + 1) * INFO_ROW_HEIGHT - gaps * INFO_SEPARATOR_HEIGHT;
    NSRect label = infoLabels[i].frame;
    CGFloat labelX = [headings containsIndex:i] ? floor((width - NSWidth(label))/2.0) : INFO_INSET;
    infoLabels[i].frame = NSMakeRect(labelX, y + floor((INFO_ROW_HEIGHT - NSHeight(label))/2.0), NSWidth(label), NSHeight(label));
    NSRect value = infoValues[i].frame;
    infoValues[i].frame = NSMakeRect(width - INFO_INSET - valueWidth, y + floor((INFO_ROW_HEIGHT - NSHeight(value))/2.0), valueWidth, NSHeight(value));
  }

  // each a line through the middle of the gap above its section's first row, inset as the rows' text
  __block NSUInteger separator = 0;
  [infoSeparatorRows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL* stop) {
    CGFloat line = height - INFO_VERTICAL_INSET - (CGFloat)row * INFO_ROW_HEIGHT - ((CGFloat)separator + 0.5) * INFO_SEPARATOR_HEIGHT;
    infoSeparators[separator].frame = NSMakeRect(INFO_INSET, floor(line), width - 2.0 * INFO_INSET, 1.0);
    separator++;
  }];

  NSRect menuFrame = infoMenuWindow.frame;
  NSScreen* screen = infoMenuWindow.screen ?: [NSScreen mainScreen];
  NSRect visible = screen.visibleFrame;
  if (!infoSideDecided)
  {
    infoSideDecided = true;
    bool leftFits = (NSMinX(menuFrame) - ROW_TIP_GAP - width) >= NSMinX(visible);
    bool rightFits = (NSMaxX(menuFrame) + ROW_TIP_GAP + width) <= NSMaxX(visible);
    // neither: left, clamped onto the screen below
    infoOnLeft = leftFits || !rightFits;
  }
  NSRect frame = NSMakeRect(0, 0, width, height);
  frame.origin.x = infoOnLeft ? (NSMinX(menuFrame) - ROW_TIP_GAP - width) : (NSMaxX(menuFrame) + ROW_TIP_GAP);
  frame.origin.y = NSMaxY(menuFrame) - height;
  frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)), NSMaxX(visible) - width);
  frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)), NSMaxY(visible) - height);
  bool resized = widened || (height != NSHeight(infoPanel.frame));
  [infoPanel setFrame:frame display:YES];
  infoGlass.contentView.frame = infoGlass.bounds;

  if (resized && (rowTipMenuWindow != nil) && rowTip.isVisible)
  {
    [self placeRowTip];
  }
}

- (void)hideInfoPanel
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showInfoPanel) object:nil];
  [infoTimer invalidate];
  infoTimer = nil;
  infoGeneration++;
  infoPlaced = false;
  infoMenuWindow = nil;
  [infoPanel orderOut:nil];
}

// how full the startup volume is, from its free space as Finder shows it (purgeable space included), read off the
// main thread: one read takes tens of milliseconds. One read at a time; a read for an earlier opening is kept but not
// shown.
- (void)readDisk
{
  if (diskReadInFlight)
  {
    return;
  }
  diskReadInFlight = true;
  lastDiskRead = [[NSProcessInfo processInfo] systemUptime];
  lastDiskAttempt = lastDiskRead;
  NSUInteger generation = infoGeneration;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // a new URL each time: an NSURL keeps the resource values it has read
    NSURL* root = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    NSDictionary<NSURLResourceKey, id>* volume = [root resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey] error:NULL];
    NSNumber* available = volume[NSURLVolumeAvailableCapacityForImportantUsageKey];
    NSNumber* total = volume[NSURLVolumeTotalCapacityKey];
    dispatch_async(dispatch_get_main_queue(), ^{
      diskReadInFlight = false;
      if ((available == nil) || (total == nil))
      {
        lastDiskRead = 0.0; // the next tick tries again
        static bool logged = false;
        if (!logged)
        {
          logged = true;
          NSLog(@"the startup volume's free space could not be read: the disk row keeps its last value");
        }
        return;
      }
      NSLocale* locale = [NSLocale currentLocale];
      uint64_t wholeBytes = total.unsignedLongLongValue;
      uint64_t freeBytes = available.unsignedLongLongValue;
      uint64_t usedBytes = (wholeBytes > freeBytes) ? (wholeBytes - freeBytes) : 0;
      DiskTexts(wholeBytes, freeBytes, locale, &diskTitle, &diskText, &diskTipText);
      diskFraction = (wholeBytes > 0) ? ((double)usedBytes / (double)wholeBytes) : -1.0;
      if (generation == infoGeneration)
      {
        [self applyInfoValues];
      }
    });
  });
}

@end
