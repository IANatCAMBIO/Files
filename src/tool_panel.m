#import "tool_panel.h"

static const CGFloat panel_min_w  = 340.0;
static const CGFloat hero_h       = 43.0;
static const CGFloat hero_h_pad   = 16.0;   /* horizontal inset in the hero */
static const CGFloat hero_v_pad   = 3.0;    /* hero title to subtitle */
static const CGFloat hero_icon_sz = 22.0;
static const CGFloat content_pad  = 16.0;   /* around the caller's controls */
static const CGFloat btn_bar_h    = 40.0;
static const CGFloat btn_h        = 25.0;
static const CGFloat btn_w        = 83.0;
static const CGFloat btn_gap      = 8.0;
static const CGFloat btn_margin   = 12.0;
static const CGFloat btn_pad      = 24.0;   /* label to button edge, for long titles */
static const CGFloat msg_w        = 388.0;  /* wrapped message text width */
static const CGFloat msg_max_h    = 240.0;  /* taller messages scroll */
static const CGFloat text_size    = 11.0;   /* every label and button title */

/* Panels on screen: each keeps itself alive until its window closes. */
static NSMutableSet<id> *live_panels;

/*
 * FilesToolHeroView — solid accent-blue background behind the hero labels.
 */
@interface FilesToolHeroView : NSView
@end

@implementation FilesToolHeroView

/*
 * isOpaque — the hero fills its whole frame.
 *
 * Output: YES.
 */
- (BOOL)
isOpaque
{
    return YES;
}

/*
 * drawRect: — fills the hero with the same blue as the Tasks reminders.
 *
 * Inputs:
 *   dirtyRect — area to redraw (unused: the whole view is filled)
 */
- (void)
drawRect:(NSRect)dirtyRect
{
    [[NSColor colorWithSRGBRed:0.0 green:0.447 blue:0.776 alpha:1.0] setFill];
    NSRectFill(self.bounds);
}

@end

@interface FilesToolPanel () <NSWindowDelegate>
@property (nonatomic, strong) NSPanel     *panel;
@property (nonatomic, strong) NSTextField *subtitle_label;
@property (nonatomic, copy)   NSString    *subtitle;
@property (nonatomic, copy)   NSString *(^button_handler)(NSInteger index);
@property (nonatomic, copy)   void (^dismissed_handler)(void);
@property (nonatomic)         BOOL          chosen;
@end

@implementation FilesToolPanel

/*
 * build_with_title:… — the panel behind every public constructor: lays out
 * the hero strip, content and one button per entry of button_titles.
 *
 * Inputs:
 *   window_title   — title bar text
 *   hero_title     — bold line in the hero strip
 *   subtitle       — second line in the hero strip; empty = title only
 *   symbol         — SF Symbols name for the hero icon; may be nil
 *   content        — the controls, sized by their own fittingSize
 *   button_titles  — button labels, at least one: [0] is the default button
 *                    at the far right, the rest follow to its left; the last
 *                    of several answers Escape
 *   button_handler — called with the index of the clicked button; returns
 *                    nil to close the panel or a one-line problem to show in
 *                    the hero strip (it stays open)
 *
 * Output: the panel, not yet shown.
 */
+ (instancetype)
build_with_title:(NSString *)window_title
      hero_title:(NSString *)hero_title
        subtitle:(NSString *)subtitle
          symbol:(NSString *)symbol
         content:(NSView *)content
   button_titles:(NSArray<NSString *> *)button_titles
  button_handler:(NSString *(^)(NSInteger index))button_handler
{
    FilesToolPanel *p = [[FilesToolPanel alloc] init];
    p.subtitle        = subtitle;
    p.button_handler  = button_handler;

    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    CGFloat buttons_w = 2 * btn_margin - btn_gap;
    for (NSUInteger i = 0; i < button_titles.count; i++) {
        NSButton *b = [NSButton buttonWithTitle:button_titles[i] target:p
                                         action:@selector(button_clicked:)];
        b.tag  = (NSInteger)i;
        b.font = [NSFont systemFontOfSize:text_size];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [buttons addObject:b];
        buttons_w += btn_gap + MAX(btn_w, b.fittingSize.width + btn_pad);
    }

    [content layoutSubtreeIfNeeded];
    NSSize cs  = content.fittingSize;
    CGFloat w  = MAX(MAX(panel_min_w, cs.width + 2 * content_pad), buttons_w);
    CGFloat h  = hero_h + content_pad + cs.height + content_pad + 1.0 + btn_bar_h;

    NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskUtilityWindow;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                                                styleMask:mask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title                = window_title;
    panel.floatingPanel        = YES;
    panel.hidesOnDeactivate    = NO;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.releasedWhenClosed   = NO;
    panel.delegate             = p;
    p.panel                    = panel;
    NSView *cv = panel.contentView;

    /* Hero strip */
    FilesToolHeroView *hero = [[FilesToolHeroView alloc] init];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:hero];

    NSImageView *icon = [[NSImageView alloc] init];
    NSImage *sym = symbol ? [NSImage imageWithSystemSymbolName:symbol
                                      accessibilityDescription:nil] : nil;
    if (sym) {
        icon.image = [sym imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:hero_icon_sz
                                                            weight:NSFontWeightMedium]];
    }
    icon.contentTintColor = NSColor.whiteColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:icon];

    NSTextField *title = [NSTextField labelWithString:hero_title];
    title.font          = [NSFont boldSystemFontOfSize:text_size];
    title.textColor     = NSColor.whiteColor;
    title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:title];

    NSTextField *sub = [NSTextField labelWithString:subtitle];
    sub.font          = [NSFont systemFontOfSize:text_size];
    sub.lineBreakMode = NSLineBreakByTruncatingTail;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:sub];
    p.subtitle_label = sub;
    sub.hidden = subtitle.length == 0;
    [p show_subtitle:subtitle problem:NO];

    [NSLayoutConstraint activateConstraints:@[
        [hero.topAnchor      constraintEqualToAnchor:cv.topAnchor],
        [hero.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor],
        [hero.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [hero.heightAnchor   constraintEqualToConstant:hero_h],

        [icon.leadingAnchor  constraintEqualToAnchor:hero.leadingAnchor constant:hero_h_pad],
        [icon.centerYAnchor  constraintEqualToAnchor:hero.centerYAnchor],
        [icon.widthAnchor    constraintEqualToConstant:hero_icon_sz],
        [icon.heightAnchor   constraintEqualToConstant:hero_icon_sz],

        [title.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:10.0],
        [title.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-hero_h_pad],
        [title.bottomAnchor   constraintEqualToAnchor:hero.centerYAnchor
                                             constant:subtitle.length ? -hero_v_pad / 2.0
                                                                      : text_size / 2.0],

        [sub.leadingAnchor  constraintEqualToAnchor:title.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [sub.topAnchor      constraintEqualToAnchor:hero.centerYAnchor
                                           constant:hero_v_pad / 2.0],
    ]];

    /* Button bar: right-aligned, the default button rightmost */
    buttons.firstObject.keyEquivalent = @"\r";
    if (buttons.count > 1) buttons.lastObject.keyEquivalent = @"\033";
    for (NSButton *b in buttons) [cv addSubview:b];

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:sep];

    content.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:content];

    NSButton *right = nil;
    for (NSButton *b in buttons) {
        [NSLayoutConstraint activateConstraints:@[
            [b.trailingAnchor constraintEqualToAnchor:right ? right.leadingAnchor
                                                            : cv.trailingAnchor
                                             constant:right ? -btn_gap : -btn_margin],
            [b.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor
                                             constant:-(btn_bar_h - btn_h) / 2.0],
            [b.widthAnchor    constraintEqualToConstant:MAX(btn_w, b.fittingSize.width + btn_pad)],
            [b.heightAnchor   constraintEqualToConstant:btn_h],
        ]];
        right = b;
    }

    [NSLayoutConstraint activateConstraints:@[
        [sep.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
        [sep.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor constant:-btn_bar_h],
        [sep.heightAnchor   constraintEqualToConstant:1.0],

        [content.topAnchor     constraintEqualToAnchor:hero.bottomAnchor constant:content_pad],
        [content.centerXAnchor constraintEqualToAnchor:cv.centerXAnchor],
    ]];
    return p;
}

/*
 * show_subtitle:problem: — sets the hero's second line.
 *
 * Inputs:
 *   text    — line to show
 *   problem — YES: highlighted as a problem; NO: the normal subtitle style
 */
- (void)
show_subtitle:(NSString *)text problem:(BOOL)problem
{
    self.subtitle_label.stringValue = text;
    self.subtitle_label.textColor = problem
        ? [NSColor colorWithSRGBRed:1.0 green:0.92 blue:0.55 alpha:1.0]
        : [NSColor colorWithWhite:0.88 alpha:1.0];
}

/*
 * button_clicked: — runs the button handler: nil closes the panel, a
 * problem is shown in the hero strip and the panel stays.
 *
 * Inputs:
 *   sender — the clicked button; its tag is the index in button_titles
 */
- (void)
button_clicked:(NSButton *)sender
{
    [self show_subtitle:self.subtitle problem:NO];
    NSString *problem = self.button_handler ? self.button_handler(sender.tag) : nil;
    if (problem) {
        [self show_subtitle:problem problem:YES];
        NSBeep();
        return;
    }
    self.chosen = YES;
    [self.panel close];
}

/*
 * panel_with_title:… — see tool_panel.h.
 */
+ (instancetype)
panel_with_title:(NSString *)window_title
      hero_title:(NSString *)hero_title
        subtitle:(NSString *)subtitle
          symbol:(NSString *)symbol
         content:(NSView *)content
   primary_title:(NSString *)primary_title
 primary_handler:(NSString *(^)(void))primary_handler
{
    return [self build_with_title:window_title hero_title:hero_title subtitle:subtitle
                           symbol:symbol content:content
                    button_titles:@[primary_title, @"Cancel"]
                   button_handler:^NSString *(NSInteger index) {
        return index == 0 && primary_handler ? primary_handler() : nil;
    }];
}

/*
 * message_content — the wrapped, selectable message text, in a fixed-size
 * view; messages taller than msg_max_h scroll.
 *
 * Inputs:
 *   message — text to show
 *
 * Output: view msg_w wide.
 */
static NSView *
message_content(NSString *message)
{
    NSTextField *label = [NSTextField wrappingLabelWithString:message];
    label.font         = [NSFont systemFontOfSize:text_size];
    label.selectable   = YES;
    label.preferredMaxLayoutWidth = msg_w;
    CGFloat h = ceil([label.cell cellSizeForBounds:NSMakeRect(0, 0, msg_w, CGFLOAT_MAX)].height);

    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, msg_w, MIN(h, msg_max_h))];
    if (h <= msg_max_h) {
        label.frame = box.bounds;
        [box addSubview:label];
    } else {
        label.frame = NSMakeRect(0, 0, msg_w, h);
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:box.bounds];
        scroll.hasVerticalScroller = YES;
        scroll.drawsBackground     = NO;
        scroll.documentView        = label;
        [box addSubview:scroll];
    }
    [NSLayoutConstraint activateConstraints:@[
        [box.widthAnchor  constraintEqualToConstant:msg_w],
        [box.heightAnchor constraintEqualToConstant:MIN(h, msg_max_h)],
    ]];
    return box;
}

/*
 * show_message:… — see tool_panel.h.
 */
+ (void)
show_message:(NSString *)title
     message:(NSString *)message
      symbol:(NSString *)symbol
     buttons:(NSArray<NSString *> *)buttons
        over:(NSWindow *)parent
     handler:(void (^)(NSInteger index))handler
{
    FilesToolPanel *p = [self build_with_title:@"Files" hero_title:title subtitle:@""
                                        symbol:symbol content:message_content(message)
                                 button_titles:buttons
                                button_handler:^NSString *(NSInteger index) {
        if (handler) handler(index);
        return nil;
    }];
    p.dismissed_handler = ^{ if (handler) handler(-1); };
    [p show_over:parent];
}

/*
 * show_over: — see tool_panel.h.
 */
- (void)
show_over:(NSWindow *)parent
{
    if (!live_panels) live_panels = [NSMutableSet set];
    [live_panels addObject:self];
    if (parent) {
        NSRect pf = parent.frame, f = self.panel.frame;
        [self.panel setFrameOrigin:NSMakePoint(NSMidX(pf) - f.size.width / 2.0,
                                               NSMidY(pf) - f.size.height / 2.0)];
    } else {
        [self.panel center];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
}

/*
 * window — see tool_panel.h.
 */
- (NSPanel *)
window
{
    return self.panel;
}

/*
 * windowWillClose: — drops the handlers (which may reference the caller's
 * objects) and the panel's self-retention, and reports a close without a
 * button click to the dismissed handler.
 *
 * Inputs:
 *   note — close notification (unused)
 */
- (void)
windowWillClose:(NSNotification *)note
{
    void (^dismissed)(void) = self.chosen ? nil : self.dismissed_handler;
    self.button_handler    = nil;
    self.dismissed_handler = nil;
    [live_panels removeObject:self];
    if (dismissed) dismissed();
}

@end
