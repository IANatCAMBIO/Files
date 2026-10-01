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
static const CGFloat star_btn_w   = 26.0;
static const CGFloat star_btn_gap = 3.0;

/* Posted (main queue) by a bar after it saves the bookmark list, so every
 * other window's bar shows the same list; object is the bar that saved. */
static NSString * const bookmarks_changed_note = @"FilesBookmarksChanged";

/* Posted (main queue) when the Trash goes from empty to full or back. */
static NSString * const trash_changed_note = @"FilesTrashChanged";

/* Whether the Trash has visible items, as last checked by the watcher. */
static BOOL trash_full;

/*
 * trash_has_items — whether the Trash holds anything but hidden (dot)
 * files, as Finder judges it. Stops at the first such entry.
 *
 * Inputs:
 *   path — the Trash folder
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
 * check_trash — re-checks the Trash on a utility queue and, if it went
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
    NSString *path = files_directory_url(NSTrashDirectory).path;
    dispatch_async(queue, ^{
        BOOL full = trash_has_items(path.fileSystemRepresentation);
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
 * ~/.Trash, kept for the life of the process) and checks the Trash once.
 * Every bookmarks bar follows it through trash_changed_note, so the Trash
 * icon tracks Move to Trash, Empty Trash and changes made by other apps
 * without anything listing the Trash on navigation.
 */
static void
watch_trash(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = files_directory_url(NSTrashDirectory).URLByResolvingSymlinksInPath.path;
        FSEventStreamContext ctx = {0};
        FSEventStreamRef stream = FSEventStreamCreate(kCFAllocatorDefault, trash_event_callback,
            &ctx, (__bridge CFArrayRef)@[path], kFSEventStreamEventIdSinceNow, 0.5,
            kFSEventStreamCreateFlagNone);
        if (stream) {
            FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
            FSEventStreamStart(stream);
        }
        check_trash();
    });
}

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

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(update_trash_icon)
                                               name:trash_changed_note object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(bookmarks_changed:)
                                               name:bookmarks_changed_note object:nil];
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
 *   note — bookmarks_changed_note; object is the bar that saved
 */
- (void)
bookmarks_changed:(NSNotification *)note
{
    if (note.object == self) return;
    [self load_bookmarks];
    [self rebuild_buttons];
}

/*
 * load_bookmarks — fills _bookmarks from NSUserDefaults, or initialises
 * defaults (Home, Desktop, Downloads, Documents, Applications, iCloud
 * Drive when set up, Trash). A saved list from before iCloud Drive was a
 * default gets it once, before Trash. Trash is always the last bookmark.
 * The saved list is rewritten only when one of these repairs changes it,
 * so a normal launch does no extra work and writes nothing.
 */
- (void)
load_bookmarks
{
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSURL *trash  = files_directory_url(NSTrashDirectory);
    NSURL *icloud = files_icloud_drive_url();

    NSArray<NSString *> *saved = [ud arrayForKey:bookmarks_defaults_key];
    if (saved.count == 0) {
        _bookmarks = [@[
            files_home_url(),
            files_directory_url(NSDesktopDirectory),
            files_directory_url(NSDownloadsDirectory),
            files_directory_url(NSDocumentDirectory),
            files_directory_url(NSApplicationDirectory),
        ] mutableCopy];
        if (icloud) [_bookmarks addObject:icloud];
        [_bookmarks addObject:trash];
        [ud setBool:YES forKey:bookmarks_icloud_key];
        return;
    }

    _bookmarks = [NSMutableArray arrayWithCapacity:saved.count];
    for (NSString *path in saved) {
        [_bookmarks addObject:[NSURL fileURLWithPath:path]];
    }

    BOOL changed = NO;
    if (!files_same_path(_bookmarks.lastObject, trash)) {
        NSIndexSet *trash_rows = [_bookmarks indexesOfObjectsPassingTest:
            ^BOOL(NSURL *u, NSUInteger idx, BOOL *stop) { return files_same_path(u, trash); }];
        [_bookmarks removeObjectsAtIndexes:trash_rows];
        [_bookmarks addObject:trash];
        changed = YES;
    }
    if (icloud && ![ud boolForKey:bookmarks_icloud_key]) {
        [ud setBool:YES forKey:bookmarks_icloud_key];
        NSUInteger have = [_bookmarks indexOfObjectPassingTest:
            ^BOOL(NSURL *u, NSUInteger idx, BOOL *stop) { return files_same_path(u, icloud); }];
        if (have == NSNotFound) {
            [_bookmarks insertObject:icloud atIndex:_bookmarks.count - 1];
            changed = YES;
        }
    }
    if (changed) [self persist_bookmarks];
}

/*
 * persist_bookmarks — writes the current bookmark paths to NSUserDefaults
 * and tells the other windows' bars (bookmarks_changed_note).
 */
- (void)
persist_bookmarks
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in _bookmarks) {
        [paths addObject:url.path];
    }
    [NSUserDefaults.standardUserDefaults setObject:paths forKey:bookmarks_defaults_key];
    [NSNotificationCenter.defaultCenter postNotificationName:bookmarks_changed_note object:self];
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
            /* The name Finder shows: "iCloud Drive", not com~apple~CloudDocs. */
            NSString *localized = nil;
            [url getResourceValue:&localized forKey:NSURLLocalizedNameKey error:nil];
            name = localized ?: url.lastPathComponent;
        }

        NSImage *icon;
        if (is_trash) {
            icon = [[NSImage imageNamed:NSImageNameTrashEmpty] copy];
            icon.size = NSMakeSize(14, 14);
        } else {
            icon = files_icon_for_url(url, 14, YES);
        }

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
 * update_trash_icon — shows the Trash bookmark as full or empty, from the
 * shared Trash watcher's last check (trash_full). Called on every
 * trash_changed_note and when the buttons are rebuilt.
 */
- (void)
update_trash_icon
{
    if (!_trash_btn) return;
    NSImage *icon = [[NSImage imageNamed:trash_full ? NSImageNameTrashFull
                                                    : NSImageNameTrashEmpty] copy];
    icon.size = NSMakeSize(14, 14);
    _trash_btn.image = icon;
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
