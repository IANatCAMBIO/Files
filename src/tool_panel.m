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
@property (nonatomic, copy)   NSString *(^primary_handler)(void);
@end

@implementation FilesToolPanel

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
    FilesToolPanel *p = [[FilesToolPanel alloc] init];
    p.subtitle        = subtitle;
    p.primary_handler = primary_handler;

    [content layoutSubtreeIfNeeded];
    NSSize cs  = content.fittingSize;
    CGFloat w  = MAX(panel_min_w, cs.width + 2 * content_pad);
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
                                             constant:-hero_v_pad / 2.0],

        [sub.leadingAnchor  constraintEqualToAnchor:title.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [sub.topAnchor      constraintEqualToAnchor:hero.centerYAnchor
                                           constant:hero_v_pad / 2.0],
    ]];

    /* Button bar: Cancel left of the primary button, both right-aligned */
    NSButton *primary = [NSButton buttonWithTitle:primary_title target:p
                                           action:@selector(primary_clicked:)];
    NSButton *cancel  = [NSButton buttonWithTitle:@"Cancel" target:p
                                           action:@selector(cancel_clicked:)];
    primary.keyEquivalent = @"\r";
    cancel.keyEquivalent  = @"\033";
    for (NSButton *b in @[primary, cancel]) {
        b.font = [NSFont systemFontOfSize:text_size];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:b];
    }

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:sep];

    content.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [primary.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-btn_margin],
        [primary.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor
                                               constant:-(btn_bar_h - btn_h) / 2.0],
        [primary.widthAnchor    constraintEqualToConstant:btn_w],
        [primary.heightAnchor   constraintEqualToConstant:btn_h],
        [cancel.trailingAnchor  constraintEqualToAnchor:primary.leadingAnchor constant:-btn_gap],
        [cancel.centerYAnchor   constraintEqualToAnchor:primary.centerYAnchor],
        [cancel.widthAnchor     constraintEqualToConstant:btn_w],
        [cancel.heightAnchor    constraintEqualToConstant:btn_h],

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
 * primary_clicked: — runs the primary handler: nil closes the panel, a
 * problem is shown in the hero strip and the panel stays.
 *
 * Inputs:
 *   sender — the primary button (unused)
 */
- (void)
primary_clicked:(id)sender
{
    [self show_subtitle:self.subtitle problem:NO];
    NSString *problem = self.primary_handler ? self.primary_handler() : nil;
    if (problem) {
        [self show_subtitle:problem problem:YES];
        NSBeep();
        return;
    }
    [self.panel close];
}

/*
 * cancel_clicked: — closes the panel without calling the handler.
 *
 * Inputs:
 *   sender — the Cancel button (unused)
 */
- (void)
cancel_clicked:(id)sender
{
    [self.panel close];
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
 * windowWillClose: — drops the handler (which may reference the caller's
 * objects) and the panel's self-retention.
 *
 * Inputs:
 *   note — close notification (unused)
 */
- (void)
windowWillClose:(NSNotification *)note
{
    self.primary_handler = nil;
    [live_panels removeObject:self];
}

@end
