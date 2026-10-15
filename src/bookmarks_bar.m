#import "bookmarks_bar.h"
#import "util.h"
#import <CoreServices/CoreServices.h>
#include <dirent.h>

static NSString * const bookmarks_defaults_key = @"files.bookmarks";
/* Set once iCloud Drive has been added to a saved bookmark list, so a user
 * who later removes it does not get it back. */
static NSString * const bookmarks_icloud_key   = @"files.bookmarks.icloud_added";
static const CGFloat btn_gap     = 4.0;
static const CGFloat btn_pad_left = 4.0;
/* How far the mouse moves with the button down before a press on a bookmark
 * becomes a drag that reorders it, and how long the others take to slide
 * out of its way. */
static const CGFloat reorder_threshold = 4.0;
static const double  reorder_slide_sec = 0.15;

NSString * const files_bookmarks_changed_note = @"FilesBookmarksChanged";

/* Posted (main queue) when the Trash goes from empty to full or back. */
static NSString * const trash_changed_note = @"FilesTrashChanged";

/* Whether the Trash has visible items, as last checked by the watcher. */
static BOOL trash_full;

/*
 * trash_has_items — whether a Trash folder holds anything but hidden (dot)
 * files, as Finder judges it. Stops at the first such entry.
 *
 * Inputs:
 *   path — a Trash folder
 *
 * Output: YES if it has a visible item.
 */
static BOOL
trash_has_items(const char *path)
{
    DIR *d = opendir(path);
    if (!d) return NO;
    BOOL found = NO;
    struct dirent *e;
    while (!found && (e = readdir(d)) != NULL) {
        found = e->d_name[0] != '.';
    }
    closedir(d);
    return found;
}

/*
 * check_trash — re-checks the Trash folders on a utility queue and, if it went
 * from empty to full or back, records it in trash_full and posts
 * trash_changed_note on the main queue.
 */
static void
check_trash(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("files.trash",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    NSArray<NSURL *> *trashes = files_trash_urls();
    dispatch_async(queue, ^{
        BOOL full = NO;
        for (NSURL *trash in trashes) {
            full = full || trash_has_items(trash.fileSystemRepresentation);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (full == trash_full) return;
            trash_full = full;
            [NSNotificationCenter.defaultCenter postNotificationName:trash_changed_note object:nil];
        });
    });
}

/*
 * trash_event_callback — FSEventStream callback for the Trash (main
 * queue): any change in it re-checks whether it is empty.
 */
static void
trash_event_callback(ConstFSEventStreamRef stream, void *info, size_t n, void *paths,
                     const FSEventStreamEventFlags *flags, const FSEventStreamEventId *ids)
{
    check_trash();
}

/*
 * watch_trash — starts the app's single Trash watcher (an FSEventStream on
 * the Trash folders, kept for the life of the process) and checks the Trash once.
 * Every bookmarks bar follows it through trash_changed_note, so the Trash
 * icon tracks Move to Trash, Empty Trash and changes made by other apps
 * without anything listing the Trash on navigation.
 */
static void
watch_trash(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *trash in files_trash_urls()) {
            [paths addObject:trash.URLByResolvingSymlinksInPath.path];
        }
        FSEventStreamContext ctx = {0};
        FSEventStreamRef stream = FSEventStreamCreate(kCFAllocatorDefault, trash_event_callback,
            &ctx, (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.5,
            kFSEventStreamCreateFlagNone);
        if (stream) {
            FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
            FSEventStreamStart(stream);
        }
        check_trash();
    });
}

/* Points a mouse wheel's one-line step moves the bookmarks. */
static const CGFloat wheel_line_w = 20.0;

/*
 * FilesBookmarksScrollView — the bar's horizontal-only scroll view. A
 * mouse wheel scrolls vertically, which a horizontal scroll view ignores,
 * so whichever axis an event mostly moves along scrolls the bookmarks
 * sideways: wheel down or a swipe left shows later bookmarks.
 */
@interface FilesBookmarksScrollView : NSScrollView
@end

@implementation FilesBookmarksScrollView

/*
 * scrollWheel: — scrolls the bookmarks horizontally by the event's larger
 * delta, in points for a trackpad or smooth-scrolling mouse and in lines
 * (wheel_line_w each) for a notched wheel, stopping at either end. Does
 * nothing while every bookmark is visible.
 *
 * Inputs:
 *   event — scroll-wheel event
 */
- (void)
scrollWheel:(NSEvent *)event
{
    CGFloat dx    = event.scrollingDeltaX, dy = event.scrollingDeltaY;
    CGFloat delta = fabs(dx) > fabs(dy) ? dx : dy;
    if (!event.hasPreciseScrollingDeltas) delta *= wheel_line_w;
    NSClipView *clip = self.contentView;
    NSRect bounds    = clip.bounds;
    if (delta == 0 || NSWidth(self.documentView.frame) <= NSWidth(bounds)) return;

    bounds.origin.x -= delta;
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [self reflectScrolledClipView:clip];
}

@end

@interface FilesBookmarksBar ()
- (BOOL)track_reorder_of:(NSButton *)btn from_event:(NSEvent *)event;
@end

/*
 * FilesBookmarkButton — a bookmark's button. A plain left press on a
 * movable one (every bookmark but Trash) is tracked by the bar, which
 * reorders the bookmark when the mouse drags it sideways and otherwise
 * treats the press as a click.
 */
@interface FilesBookmarkButton : NSButton
@property (nonatomic, weak)   FilesBookmarksBar *bar;
@property (nonatomic, assign) BOOL               movable;
@end

@implementation FilesBookmarkButton

/*
 * mouseDown: — hands a plain left press on a movable bookmark to the bar
 * (track_reorder_of:from_event:); a ^-click (context menu) or a press on
 * Trash gets NSButton's usual handling. A press the bar decides was a click
 * sends the button's action.
 *
 * Inputs:
 *   event — the mouse-down event
 */
- (void)
mouseDown:(NSEvent *)event
{
    if (!self.movable || (event.modifierFlags & NSEventModifierFlagControl)) {
        [super mouseDown:event];
        return;
    }
    if (![self.bar track_reorder_of:self from_event:event]) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

@end

@implementation FilesBookmarksBar {
    NSMutableArray<NSURL *> *_bookmarks;
    FilesBookmarksScrollView *_scroll_view;
    NSView                  *_btn_container;
    NSButton                *_trash_btn;   /* the Trash bookmark's button (in _btn_container); nil if none */
}

/*
 * init_with_frame: — loads bookmarks, sets up scroll view, builds buttons.
 *
 * Inputs:
 *   frame — initial frame; height should be 28
 *
 * Output: self or nil.
 */
- (instancetype)
init_with_frame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    [self load_bookmarks];
    [self setup_scroll_view];
    [self rebuild_buttons];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(update_trash_icon)
                                               name:trash_changed_note object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(bookmarks_changed:)
                                               name:files_bookmarks_changed_note object:nil];
    watch_trash();
    return self;
}

/*
 * dealloc — stops observing the shared Trash and bookmark notifications.
 */
- (void)
dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/*
 * bookmarks_changed: — another window's bar saved the bookmark list:
 * reload it, so no bar later saves an outdated copy over it.
 *
 * Inputs:
 *   note — files_bookmarks_changed_note; object is the bar that saved
 */
- (void)
bookmarks_changed:(NSNotification *)note
{
    if (note.object == self) return;
    [self load_bookmarks];
    [self rebuild_buttons];
}

/*
 * bookmark_list — the bookmark list from NSUserDefaults, or the defaults
 * (Home, Desktop, Downloads, Documents, Applications, iCloud Drive when
 * set up, Trash) when none is saved. A saved list from before iCloud Drive
 * was a default gets it once, before Trash. Trash is always the last
 * bookmark.
 *
 * Inputs:
 *   repaired — set to YES when a saved list was changed by one of these
 *              repairs and should be saved again; may be NULL
 *
 * Output: the bookmarks, in bar order.
 */
static NSMutableArray<NSURL *> *
bookmark_list(BOOL *repaired)
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSURL *trash  = files_directory_url(NSTrashDirectory);
    NSURL *icloud = files_icloud_drive_url();
    if (repaired) *repaired = NO;

    NSArray<NSString *> *saved = [ud arrayForKey:bookmarks_defaults_key];
    if (saved.count == 0) {
        NSMutableArray<NSURL *> *list = [@[
            files_home_url(),
            files_directory_url(NSDesktopDirectory),
            files_directory_url(NSDownloadsDirectory),
            files_directory_url(NSDocumentDirectory),
            files_directory_url(NSApplicationDirectory),
        ] mutableCopy];
        if (icloud) [list addObject:icloud];
        [list addObject:trash];
        [ud setBool:YES forKey:bookmarks_icloud_key];
        return list;
    }

    NSMutableArray<NSURL *> *list = [NSMutableArray arrayWithCapacity:saved.count];
    for (NSString *path in saved) {
        [list addObject:[NSURL fileURLWithPath:path]];
    }

    BOOL changed = NO;
    if (!files_same_path(list.lastObject, trash)) {
        NSIndexSet *trash_rows = [list indexesOfObjectsPassingTest:
            ^BOOL(NSURL *u, NSUInteger idx, BOOL *stop) { return files_same_path(u, trash); }];
        [list removeObjectsAtIndexes:trash_rows];
        [list addObject:trash];
        changed = YES;
    }
    if (icloud && ![ud boolForKey:bookmarks_icloud_key]) {
        [ud setBool:YES forKey:bookmarks_icloud_key];
        NSUInteger have = [list indexOfObjectPassingTest:
            ^BOOL(NSURL *u, NSUInteger idx, BOOL *stop) { return files_same_path(u, icloud); }];
        if (have == NSNotFound) {
            [list insertObject:icloud atIndex:list.count - 1];
            changed = YES;
        }
    }
    if (repaired) *repaired = changed;
    return list;
}

/*
 * files_bookmark_urls — documented in bookmarks_bar.h.
 */
NSArray<NSURL *> *
files_bookmark_urls(void)
{
    return bookmark_list(NULL);
}

/*
 * files_is_bookmark — documented in bookmarks_bar.h.
 */
BOOL
files_is_bookmark(NSURL *url)
{
    for (NSURL *b in bookmark_list(NULL)) {
        if (files_same_path(b, url)) return YES;
    }
    return NO;
}

/*
 * files_bookmark_name — documented in bookmarks_bar.h.
 */
NSString *
files_bookmark_name(NSURL *url)
{
    if (files_same_path(url, files_home_url())) return @"Home";
    if (files_same_path(url, files_directory_url(NSTrashDirectory))) return @"Trash";
    /* The name Finder shows: "iCloud Drive", not com~apple~CloudDocs. */
    NSString *localized = nil;
    [url getResourceValue:&localized forKey:NSURLLocalizedNameKey error:nil];
    return localized ?: url.lastPathComponent;
}

/*
 * files_bookmark_icon — documented in bookmarks_bar.h.
 */
NSImage *
files_bookmark_icon(NSURL *url, CGFloat size)
{
    if (!files_same_path(url, files_directory_url(NSTrashDirectory))) {
        return files_icon_for_url(url, size, YES);
    }
    NSImage *icon = [[NSImage imageNamed:trash_full ? NSImageNameTrashFull
                                                    : NSImageNameTrashEmpty] copy];
    icon.size = NSMakeSize(size, size);
    return icon;
}

/*
 * load_bookmarks — fills _bookmarks from bookmark_list, saving the list
 * again only when a repair changed it, so a normal launch writes nothing.
 */
- (void)
load_bookmarks
{
    BOOL repaired;
    _bookmarks = bookmark_list(&repaired);
    if (repaired) [self persist_bookmarks];
}

/*
 * persist_bookmarks — writes the current bookmark paths to NSUserDefaults
 * and tells the other windows' bars (files_bookmarks_changed_note).
 */
- (void)
persist_bookmarks
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in _bookmarks) {
        [paths addObject:url.path];
    }
    [NSUserDefaults.standardUserDefaults setObject:paths forKey:bookmarks_defaults_key];
    [NSNotificationCenter.defaultCenter postNotificationName:files_bookmarks_changed_note object:self];
}

/*
 * setup_scroll_view — creates the scroll view that scrolls the bookmarks
 * horizontally (mouse wheel or trackpad) when there are too many to fit.
 */
- (void)
setup_scroll_view
{
    _scroll_view = [[FilesBookmarksScrollView alloc] initWithFrame:self.bounds];
    _scroll_view.hasVerticalScroller   = NO;
    _scroll_view.hasHorizontalScroller = NO;
    _scroll_view.drawsBackground       = NO;
    _scroll_view.autoresizingMask      = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_scroll_view];
}

/*
 * rebuild_buttons — removes the old button container and recreates one
 * button per bookmark. Must be called on the main thread.
 */
- (void)
rebuild_buttons
{
    [_btn_container removeFromSuperview];

    CGFloat bar_h = self.bounds.size.height;
    _btn_container = [[NSView alloc] initWithFrame:
                         NSMakeRect(0, 0, self.bounds.size.width, bar_h)];

    _trash_btn = nil;
    CGFloat x = btn_pad_left;
    for (NSUInteger i = 0; i < _bookmarks.count; i++) {
        NSURL *url = _bookmarks[i];

        BOOL is_trash = files_same_path(url, files_directory_url(NSTrashDirectory));
        FilesBookmarkButton *btn = [[FilesBookmarkButton alloc] init];
        btn.bar           = self;
        btn.movable       = !is_trash;
        btn.title         = files_bookmark_name(url);
        btn.image         = files_bookmark_icon(url, 14);
        btn.imagePosition = NSImageLeft;
        btn.bezelStyle    = NSBezelStyleRecessed;
        [btn setButtonType:NSButtonTypeMomentaryPushIn];
        btn.font          = [NSFont systemFontOfSize:11.0];
        btn.tag           = (NSInteger)i;
        btn.target        = self;
        btn.action        = @selector(bookmark_clicked:);

        /* Trash is permanent (always last), so it has no Remove item. */
        if (!is_trash) {
            NSMenuItem *remove_item = [[NSMenuItem alloc]
                initWithTitle:@"Remove Bookmark"
                       action:@selector(remove_bookmark_clicked:)
                keyEquivalent:@""];
            remove_item.tag    = (NSInteger)i;
            remove_item.target = self;
            NSMenu *ctx = [[NSMenu alloc] initWithTitle:@""];
            [ctx addItem:remove_item];
            btn.menu = ctx;
        }

        [btn sizeToFit];

        NSRect r = btn.frame;
        r.size.height = MIN(r.size.height, bar_h - 4.0);
        r.origin      = NSMakePoint(x, (bar_h - r.size.height) / 2.0);
        btn.frame     = r;

        if (is_trash) _trash_btn = btn;
        [_btn_container addSubview:btn];
        x += r.size.width + btn_gap;
    }

    /* Exactly as wide as the buttons, so the bar scrolls only when the
     * window is too narrow for them, however it is resized later. */
    _btn_container.frame = NSMakeRect(0, 0, x, bar_h);
    _scroll_view.documentView = _btn_container;
}

/*
 * reorder_slots — the x position of each button when the bookmark buttons
 * stand in the given order, laid out as rebuild_buttons does.
 *
 * Inputs:
 *   order — the bookmark buttons, left to right
 *
 * Output: one x position per button, in the same order.
 */
static NSArray<NSNumber *> *
reorder_slots(NSArray<NSButton *> *order)
{
    NSMutableArray<NSNumber *> *xs = [NSMutableArray arrayWithCapacity:order.count];
    CGFloat x = btn_pad_left;
    for (NSButton *b in order) {
        [xs addObject:@(x)];
        x += NSWidth(b.frame) + btn_gap;
    }
    return xs;
}

/*
 * track_reorder_of:from_event: — follows a left press on bookmark button btn
 * until the mouse is released. If the mouse moves reorder_threshold points
 * the press becomes a drag: btn follows the mouse along the bar and the
 * other bookmarks slide aside to show where it will land (never after
 * Trash, which stays last). On release btn settles into that slot and the
 * new order is saved and shown in every window.
 *
 * Inputs:
 *   btn   — the pressed bookmark button (tag = its bookmark index)
 *   event — the mouse-down event
 *
 * Output: YES if the press became a drag, NO if it was a click (the
 *         caller sends the button's action).
 */
- (BOOL)
track_reorder_of:(NSButton *)btn from_event:(NSEvent *)event
{
    NSPoint start = [_btn_container convertPoint:event.locationInWindow fromView:nil];
    btn.highlighted = YES;

    /* The other buttons in bookmark order; Trash, when present, is last. */
    NSMutableArray<NSButton *> *others = [NSMutableArray array];
    for (NSView *v in _btn_container.subviews) {
        if (v != btn && [v isKindOfClass:NSButton.class]) [others addObject:(NSButton *)v];
    }
    [others sortUsingComparator:^NSComparisonResult(NSButton *a, NSButton *b) {
        return a.tag < b.tag ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSUInteger last_slot = others.count - (_trash_btn && _trash_btn != btn ? 1 : 0);
    NSUInteger from      = (NSUInteger)btn.tag;
    NSUInteger target    = from;
    CGFloat    grab      = start.x - NSMinX(btn.frame);
    BOOL       dragging  = NO;

    for (;;) {
        NSEvent *e = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged |
                                                        NSEventMaskLeftMouseUp];
        if (e.type == NSEventTypeLeftMouseUp) break;
        NSPoint p = [_btn_container convertPoint:e.locationInWindow fromView:nil];
        if (!dragging) {
            if (hypot(p.x - start.x, p.y - start.y) < reorder_threshold) continue;
            dragging = YES;
            btn.highlighted = NO;
            btn.alphaValue  = 0.8;
            [_btn_container addSubview:btn positioned:NSWindowAbove relativeTo:nil];
        }
        [_btn_container autoscroll:e];

        NSRect f = btn.frame;
        f.origin.x = MAX(0.0, MIN(p.x - grab, NSWidth(_btn_container.bounds) - NSWidth(f)));
        btn.frame  = f;

        /* The slot is the number of movable bookmarks whose shown centre
         * is left of the dragged one's. */
        NSMutableArray<NSButton *> *order = [others mutableCopy];
        [order insertObject:btn atIndex:target];
        NSArray<NSNumber *> *xs = reorder_slots(order);
        NSUInteger slot = 0;
        for (NSUInteger i = 0; i < order.count; i++) {
            NSButton *b = order[i];
            if (b == btn || b == _trash_btn) continue;
            if (xs[i].doubleValue + NSWidth(b.frame) / 2.0 < NSMidX(f)) slot++;
        }
        slot = MIN(slot, last_slot);
        if (slot == target) continue;
        target = slot;

        order = [others mutableCopy];
        [order insertObject:btn atIndex:target];
        xs = reorder_slots(order);
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = reorder_slide_sec;
            for (NSUInteger i = 0; i < order.count; i++) {
                if (order[i] == btn) continue;
                NSRect r = order[i].frame;
                r.origin.x = xs[i].doubleValue;
                order[i].animator.frame = r;
            }
        }];
    }

    btn.highlighted = NO;
    if (!dragging) return NO;

    NSMutableArray<NSButton *> *order = [others mutableCopy];
    [order insertObject:btn atIndex:target];
    NSRect home = btn.frame;
    home.origin.x = reorder_slots(order)[target].doubleValue;
    __weak FilesBookmarksBar *ws = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = reorder_slide_sec;
        btn.animator.frame      = home;
        btn.animator.alphaValue = 1.0;
    } completionHandler:^{
        FilesBookmarksBar *s = ws;
        if (!s) return;
        if (target != from) {
            NSURL *url = s->_bookmarks[from];
            [s->_bookmarks removeObjectAtIndex:from];
            [s->_bookmarks insertObject:url atIndex:target];
            [s persist_bookmarks];
        }
        [s rebuild_buttons];
    }];
    return YES;
}

/*
 * update_trash_icon — shows the Trash bookmark as full or empty, from the
 * shared Trash watcher's last check (trash_full). Called on every
 * trash_changed_note; rebuild_buttons sets it the same way.
 */
- (void)
update_trash_icon
{
    _trash_btn.image = files_bookmark_icon(files_directory_url(NSTrashDirectory), 14);
}

/*
 * bookmark_clicked: — dispatches to selection_handler.
 *
 * Inputs:
 *   sender — the NSButton that was clicked (tag = bookmark index)
 */
- (void)
bookmark_clicked:(NSButton *)sender
{
    NSUInteger idx = (NSUInteger)sender.tag;
    if (idx >= _bookmarks.count) return;
    if (self.selection_handler) {
        self.selection_handler(_bookmarks[idx]);
    }
}

/*
 * remove_bookmark_clicked: — removes the bookmark at the menu item's tag index.
 *
 * Inputs:
 *   sender — NSMenuItem whose tag is the bookmark index to remove
 */
- (void)
remove_bookmark_clicked:(NSMenuItem *)sender
{
    NSUInteger idx = (NSUInteger)sender.tag;
    if (idx < _bookmarks.count) [self remove_bookmark:_bookmarks[idx]];
}

/*
 * remove_bookmark: — removes url from the bar, then persists and rebuilds.
 * Ignored for Trash (always the last bookmark) or a URL not bookmarked.
 *
 * Inputs:
 *   url — directory URL to remove
 */
- (void)
remove_bookmark:(NSURL *)url
{
    if (files_same_path(url, files_directory_url(NSTrashDirectory))) return;
    NSUInteger idx = [_bookmarks indexOfObjectPassingTest:
        ^BOOL(NSURL *u, NSUInteger i, BOOL *stop) { return files_same_path(u, url); }];
    if (idx == NSNotFound) return;
    [_bookmarks removeObjectAtIndex:idx];
    [self persist_bookmarks];
    [self rebuild_buttons];
}

/*
 * add_bookmark: — inserts url just before the Trash bookmark (which stays
 * last) if not already present, then persists and rebuilds.
 *
 * Inputs:
 *   url — directory URL to add
 */
- (void)
add_bookmark:(NSURL *)url
{
    for (NSURL *existing in _bookmarks) {
        if (files_same_path(existing, url)) return;
    }
    [_bookmarks insertObject:url atIndex:_bookmarks.count - 1];
    [self persist_bookmarks];
    [self rebuild_buttons];
}

/*
 * drawRect: — draws a 1pt separator at the bottom of the bar: the divider
 * between the bar and the file list.
 *
 * Inputs:
 *   dirty — region to redraw
 */
- (void)
drawRect:(NSRect)dirty
{
    [NSColor.separatorColor setStroke];
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(0, 0.5)];
    [line lineToPoint:NSMakePoint(self.bounds.size.width, 0.5)];
    line.lineWidth = 1.0;
    [line stroke];
}

@end
