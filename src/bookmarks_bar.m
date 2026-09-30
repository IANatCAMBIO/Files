#import "bookmarks_bar.h"
#import "util.h"

static NSString * const bookmarks_defaults_key = @"files.bookmarks";
static const CGFloat btn_gap     = 4.0;
static const CGFloat btn_pad_left = 4.0;
static const CGFloat star_btn_w   = 26.0;
static const CGFloat star_btn_gap = 3.0;

@implementation FilesBookmarksBar {
    NSMutableArray<NSURL *> *_bookmarks;
    NSScrollView            *_scroll_view;
    NSView                  *_btn_container;
    NSButton                *_star_button;
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
    [self setup_star_button];
    [self setup_scroll_view];
    [self rebuild_buttons];

    return self;
}

/*
 * load_bookmarks — fills _bookmarks from NSUserDefaults, or initialises
 * defaults (Home, Desktop, Downloads, Documents, Applications, Trash).
 * Trash is always the last bookmark: the saved list is rewritten only in
 * the rare case where it is missing or not last, so a normal launch does
 * no extra work and writes nothing.
 */
- (void)
load_bookmarks
{
    NSURL *trash = files_directory_url(NSTrashDirectory);

    NSArray<NSString *> *saved =
        [NSUserDefaults.standardUserDefaults arrayForKey:bookmarks_defaults_key];
    if (saved.count == 0) {
        _bookmarks = [@[
            files_home_url(),
            files_directory_url(NSDesktopDirectory),
            files_directory_url(NSDownloadsDirectory),
            files_directory_url(NSDocumentDirectory),
            files_directory_url(NSApplicationDirectory),
            trash,
        ] mutableCopy];
        return;
    }

    _bookmarks = [NSMutableArray arrayWithCapacity:saved.count];
    for (NSString *path in saved) {
        [_bookmarks addObject:[NSURL fileURLWithPath:path]];
    }
    if (files_same_path(_bookmarks.lastObject, trash)) return;

    NSIndexSet *trash_rows = [_bookmarks indexesOfObjectsPassingTest:
        ^BOOL(NSURL *u, NSUInteger idx, BOOL *stop) { return files_same_path(u, trash); }];
    [_bookmarks removeObjectsAtIndexes:trash_rows];
    [_bookmarks addObject:trash];
    [self persist_bookmarks];
}

/*
 * persist_bookmarks — writes the current bookmark paths to NSUserDefaults.
 */
- (void)
persist_bookmarks
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in _bookmarks) {
        [paths addObject:url.path];
    }
    [NSUserDefaults.standardUserDefaults setObject:paths forKey:bookmarks_defaults_key];
}

/*
 * setup_star_button — creates the fixed ⭐️ button at the left of the bar
 * that adds the current folder to the bookmarks via the responder chain.
 */
- (void)
setup_star_button
{
    CGFloat bar_h = self.bounds.size.height;
    CGFloat btn_h = bar_h - 4.0;

    _star_button = [[NSButton alloc] init];
    _star_button.title      = @"⭐️";
    _star_button.bezelStyle = NSBezelStyleRecessed;
    [_star_button setButtonType:NSButtonTypeMomentaryPushIn];
    _star_button.font       = [NSFont systemFontOfSize:11.0];
    _star_button.target     = nil;   /* send up the responder chain */
    _star_button.action     = @selector(add_bookmark_action:);
    _star_button.toolTip    = @"Add Current Folder to Bookmarks";
    _star_button.frame      = NSMakeRect(btn_pad_left,
                                         (bar_h - btn_h) / 2.0,
                                         star_btn_w, btn_h);
    _star_button.autoresizingMask = NSViewMaxXMargin;
    [self addSubview:_star_button];
}

/*
 * setup_scroll_view — creates the NSScrollView that allows horizontal
 * scrolling when there are too many bookmarks to fit. Offset to the right
 * of the star button.
 */
- (void)
setup_scroll_view
{
    CGFloat offset = btn_pad_left + star_btn_w + star_btn_gap;
    CGFloat bar_w  = self.bounds.size.width;
    CGFloat bar_h  = self.bounds.size.height;

    _scroll_view = [[NSScrollView alloc] initWithFrame:
                       NSMakeRect(offset, 0, bar_w - offset, bar_h)];
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
        NSString *name;
        if (files_same_path(url, files_home_url())) {
            name = @"Home";
        } else if (is_trash) {
            name = @"Trash";
        } else {
            name = url.lastPathComponent;
        }

        NSImage *icon;
        if (is_trash) {
            icon = [NSImage imageNamed:NSImageNameTrashEmpty];
        } else {
            icon = [NSWorkspace.sharedWorkspace iconForFile:url.path]
                   ?: [NSImage imageNamed:NSImageNameFolder];
        }
        icon = [icon copy];
        icon.size = NSMakeSize(14, 14);

        NSButton *btn = [[NSButton alloc] init];
        btn.title         = name;
        btn.image         = icon;
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
    [self update_trash_icon];

    _btn_container.frame = NSMakeRect(0, 0,
        MAX(x, self.bounds.size.width), bar_h);
    _scroll_view.documentView = _btn_container;
    [self setNeedsDisplay:YES];
}

/*
 * update_trash_icon — checks ~/.Trash and sets the Trash bookmark button to
 * NSImageNameTrashFull or NSImageNameTrashEmpty to match the real state.
 *
 * Runs the filesystem check on a background queue to avoid blocking the UI,
 * then updates the button image on the main queue.
 */
- (void)
update_trash_icon
{
    if (!_trash_btn) return;
    NSURL *trash = files_directory_url(NSTrashDirectory);
    __weak NSButton *btn = _trash_btn;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        /* Ignore .DS_Store and other hidden files, as Finder does. */
        NSArray *items = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:trash includingPropertiesForKeys:nil
                             options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        BOOL has_items = items.count > 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSButton *b = btn;
            if (!b) return;
            NSImage *icon = [NSImage imageNamed:has_items
                ? NSImageNameTrashFull : NSImageNameTrashEmpty];
            icon = [icon copy];
            icon.size = NSMakeSize(14, 14);
            b.image = icon;
        });
    });
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
    if (idx >= _bookmarks.count) return;
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
 * drawRect: — draws a 1pt separator at the bottom of the bar.
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
