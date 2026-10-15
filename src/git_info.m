#import "git_info.h"
#import "util.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString * const git_tool = @"/usr/bin/git";

/*
 * git_available — whether /usr/bin/git can run. It is a shim for the git
 * in Xcode or the Command Line Tools; without either, every run would
 * make macOS offer to install the tools. Checked once per process:
 * `xcode-select -p` names the developer folder, which must hold git.
 *
 * Output: YES if git is installed.
 */
static BOOL
git_available(void)
{
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = nil;
        if (!files_run_tool(@"/usr/bin/xcode-select", @[@"-p"], FILES_TOOL_TIMEOUT, &data)) return;
        NSString *dev = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                            stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSString *git = [dev stringByAppendingPathComponent:@"usr/bin/git"];
        available = dev.length > 0 && access(git.fileSystemRepresentation, X_OK) == 0;
    });
    return available;
}

/*
 * files_is_git_repo — directory, not a package, with a .git entry.
 * Inputs/output are documented in git_info.h.
 */
BOOL
files_is_git_repo(NSURL *url)
{
    NSNumber *is_dir = nil, *is_pkg = nil;
    [url getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
    if (!is_dir.boolValue) return NO;
    [url getResourceValue:&is_pkg forKey:NSURLIsPackageKey error:nil];
    if (is_pkg.boolValue) return NO;
    NSString *dot_git = [url.path stringByAppendingPathComponent:@".git"];
    return access(dot_git.fileSystemRepresentation, F_OK) == 0;
}

/*
 * files_git_work_tree — walk up from dir to the first folder with .git;
 * nil when git is not installed. Inputs/output are documented in git_info.h.
 */
NSURL *
files_git_work_tree(NSURL *dir)
{
    if (!git_available()) return nil;
    NSString *path = dir.URLByStandardizingPath.path;
    /* The repository's own .git folder is not part of the working tree. */
    if ([path.pathComponents containsObject:@".git"]) return nil;
    while (path.length > 0) {
        NSString *dot_git = [path stringByAppendingPathComponent:@".git"];
        if (access(dot_git.fileSystemRepresentation, F_OK) == 0) {
            return [NSURL fileURLWithPath:path isDirectory:YES];
        }
        if ([path isEqualToString:@"/"]) break;
        path = path.stringByDeletingLastPathComponent;
    }
    return nil;
}

/*
 * files_git_tracked_names — first path component of every `git ls-files`
 * entry under dir. Inputs/output are documented in git_info.h.
 */
NSSet<NSString *> *
files_git_tracked_names(NSURL *dir)
{
    NSData *data = nil;
    if (!git_available() ||
        !files_run_tool(git_tool, @[@"-C", dir.path, @"ls-files", @"-z"],
                        FILES_TOOL_TIMEOUT, &data)) return nil;

    /* NUL-separated paths relative to dir; keep the part before the first
     * '/', which is the name of the child of dir the file lives under.
     * ls-files output is sorted, so all of a folder's files are adjacent:
     * only the first entry of each run makes a string, and a repository's
     * root costs one string per child rather than one per tracked file. */
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    const char *p    = data.bytes;
    const char *end  = p + data.length;
    const char *prev = NULL;    /* first component of the previous entry */
    size_t prev_len  = 0;
    while (p < end) {
        const char *entry_end = memchr(p, '\0', (size_t)(end - p));
        if (!entry_end) entry_end = end;
        const char *slash    = memchr(p, '/', (size_t)(entry_end - p));
        const char *name_end = slash ? slash : entry_end;
        size_t len = (size_t)(name_end - p);
        if (len > 0 && !(prev && len == prev_len && memcmp(p, prev, len) == 0)) {
            NSString *name = [[NSString alloc] initWithBytes:p length:len
                                                    encoding:NSUTF8StringEncoding];
            if (name) [names addObject:name];
            prev     = p;
            prev_len = len;
        }
        p = entry_end + 1;
    }
    return names;
}

/*
 * files_git_index_path — <resolved work tree>/.git/index when .git is a folder.
 * Inputs/output are documented in git_info.h.
 */
NSString *
files_git_index_path(NSURL *work_tree)
{
    NSString *dot_git = [work_tree.URLByResolvingSymlinksInPath.path
                            stringByAppendingPathComponent:@".git"];
    BOOL is_dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dot_git isDirectory:&is_dir] || !is_dir) {
        return nil;
    }
    return [dot_git stringByAppendingPathComponent:@"index"];
}

/* Git badge edge: at most git_badge_max points, and at most half the
 * icon's width. */
static const CGFloat git_badge_max = 32.0;

/* The artwork's bounding box includes the folder's tab, so its center sits
 * above the middle of the folder's front; the badge is lowered by this
 * share of the icon's height (4 pt on Get Info's 64 pt icon). */
static const CGFloat git_badge_drop = 1.0 / 16.0;

/* Resolution of the alpha scan that finds an icon's artwork. */
static const int art_scan_px = 64;

/*
 * artwork_center — the center of icon's opaque artwork, as fractions of the
 * canvas. Icons do not fill their canvas (a folder leaves ~13% empty below
 * it), so the badge is centered on the artwork rather than the canvas.
 * Renders icon once at art_scan_px square.
 *
 * Inputs:
 *   icon — the icon to measure
 *
 * Output: center, x from the left and y from the bottom, each 0…1;
 *         (0.5, 0.5) if the icon is fully transparent.
 */
static NSPoint
artwork_center(NSImage *icon)
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:art_scan_px pixelsHigh:art_scan_px
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [icon drawInRect:NSMakeRect(0, 0, art_scan_px, art_scan_px)];
    [NSGraphicsContext restoreGraphicsState];

    /* Rows run top to bottom; alpha is the fourth byte of each pixel. */
    const unsigned char *px = rep.bitmapData;
    NSInteger bpr   = rep.bytesPerRow;
    int min_x = art_scan_px, max_x = -1, min_row = -1, max_row = -1;
    for (int row = 0; row < art_scan_px; row++) {
        for (int x = 0; x < art_scan_px; x++) {
            if (px[row * bpr + x * 4 + 3] < 128) continue;
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (min_row < 0) min_row = row;
            max_row = row;
        }
    }
    if (max_x < 0) return NSMakePoint(0.5, 0.5);
    return NSMakePoint((min_x + max_x + 1) / (2.0 * art_scan_px),
                       1.0 - (min_row + max_row + 1) / (2.0 * art_scan_px));
}

/*
 * files_git_badged_icon — icon with the git logo centered on its artwork.
 * Inputs/output are documented in git_info.h.
 */
NSImage *
files_git_badged_icon(NSImage *icon)
{
    static NSImage *badge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"git96" ofType:@"png"];
        badge = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    });
    if (!badge) return icon;

    /* The handler runs whenever the image is rendered, under the appearance
     * of the view drawing it, so the icon underneath stays light/dark
     * correct. */
    NSPoint center = artwork_center(icon);
    return [NSImage imageWithSize:icon.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [icon drawInRect:rect];
        CGFloat edge = MIN(git_badge_max, floor(NSWidth(rect) / 2.0));
        CGFloat x    = NSMinX(rect) + NSWidth(rect) * center.x - edge / 2.0;
        CGFloat y    = NSMinY(rect) + NSHeight(rect) * (center.y - git_badge_drop) - edge / 2.0;
        [badge drawInRect:NSMakeRect(x, y, edge, edge)];
        return YES;
    }];
}

/*
 * run_git — runs git with args in repo and returns its trimmed stdout.
 *
 * Inputs:
 *   repo — working-tree root (passed as -C)
 *   args — git arguments after -C <repo>
 *
 * Output: stdout without surrounding newlines, or nil if git failed.
 */
static NSString *
run_git(NSURL *repo, NSArray<NSString *> *args)
{
    NSData *data = nil;
    NSArray *full = [@[@"-C", repo.path] arrayByAddingObjectsFromArray:args];
    if (!git_available() || !files_run_tool(git_tool, full, FILES_TOOL_TIMEOUT, &data)) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    /* Newlines only: a tab can be a meaningful (empty) leading field. */
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

/*
 * describe_upstream — the "pushed" text for a branch from its upstream name
 * and git's tracking summary (%(upstream:track,nobracket): "", "ahead N",
 * "behind N", "ahead N, behind M" or "gone").
 *
 * Inputs:
 *   upstream — upstream short name, e.g. "origin/main"; empty if none
 *   track    — tracking summary as above
 *
 * Output: "Yes — …" or "No — …".
 */
static NSString *
describe_upstream(NSString *upstream, NSString *track)
{
    if (upstream.length == 0) return @"No — no upstream branch";
    if ([track isEqualToString:@"gone"]) {
        return [NSString stringWithFormat:@"No — %@ was deleted", upstream];
    }

    const char *t = track.UTF8String;
    const char *a = strstr(t, "ahead ");
    const char *b = strstr(t, "behind ");
    int ahead  = a ? atoi(a + strlen("ahead ")) : 0;
    int behind = b ? atoi(b + strlen("behind ")) : 0;

    if (ahead > 0 && behind > 0) {
        return [NSString stringWithFormat:@"No — %d ahead, %d behind %@",
                ahead, behind, upstream];
    }
    if (ahead > 0) {
        return [NSString stringWithFormat:@"No — %d ahead of %@", ahead, upstream];
    }
    if (behind > 0) {
        return [NSString stringWithFormat:@"Yes — %d behind %@", behind, upstream];
    }
    return [NSString stringWithFormat:@"Yes — up to date with %@", upstream];
}

/*
 * describe_remote_url — the URL of the remote a branch pushes to: its
 * upstream's remote, else "origin", else the first remote configured.
 *
 * Inputs:
 *   repo     — working-tree root
 *   upstream — name of the upstream's remote (e.g. "origin"); nil or empty
 *              if the branch has none
 *
 * Output: the URL (insteadOf rewrites applied), or "None" if the
 *         repository has no remotes.
 */
static NSString *
describe_remote_url(NSURL *repo, NSString *upstream)
{
    NSString *name = upstream;
    if (name.length == 0) {
        NSArray<NSString *> *remotes =
            [run_git(repo, @[@"remote"]) componentsSeparatedByString:@"\n"];
        name = [remotes containsObject:@"origin"] ? @"origin" : remotes.firstObject;
    }
    NSString *url = name.length ? run_git(repo, @[@"remote", @"get-url", name]) : nil;
    return url.length ? url : @"None";
}

/*
 * files_git_describe — branch via symbolic-ref, push state via
 * for-each-ref, remote URL via git remote. Inputs/output are documented in
 * git_info.h.
 */
BOOL
files_git_describe(NSURL *repo, NSString **branch, NSString **pushed, NSString **remote_url)
{
    NSString *ref = run_git(repo, @[@"symbolic-ref", @"--quiet", @"HEAD"]);
    if (!ref) {
        /* Detached HEAD (or not readable at all): name the commit, and call
         * it pushed if any remote-tracking branch contains it. */
        NSString *sha = run_git(repo, @[@"rev-parse", @"--short", @"HEAD"]);
        if (sha.length == 0) return NO;
        NSString *remote = run_git(repo, @[@"for-each-ref", @"--contains", @"HEAD",
                                           @"--count=1", @"--format=%(refname:short)",
                                           @"refs/remotes"]);
        *branch = [NSString stringWithFormat:@"Detached at %@", sha];
        *pushed = remote.length ? [NSString stringWithFormat:@"Yes — on %@", remote]
                                : @"No — not on any remote branch";
        *remote_url = describe_remote_url(repo, nil);
        return YES;
    }

    NSString *format = @"--format=%(upstream:short)%09%(upstream:track,nobracket)"
                       @"%09%(upstream:remotename)";
    NSString *line   = run_git(repo, @[@"for-each-ref", format, ref]);
    if (!line) return NO;

    NSString *prefix = @"refs/heads/";
    *branch = [ref hasPrefix:prefix] ? [ref substringFromIndex:prefix.length] : ref;
    if (line.length == 0) {
        /* The branch ref does not exist yet: a new repository. */
        *pushed     = @"No — no commits yet";
        *remote_url = describe_remote_url(repo, nil);
        return YES;
    }
    NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
    *pushed     = describe_upstream(fields[0], fields.count > 1 ? fields[1] : @"");
    *remote_url = describe_remote_url(repo, fields.count > 2 ? fields[2] : nil);
    return YES;
}

/*
 * files_git_show — runs files_git_describe off the main thread and fills
 * the fields. Inputs/output are documented in git_info.h.
 */
void
files_git_show(NSURL *repo, NSTextField *branch, NSTextField *pushed,
               NSTextField *remote_url, BOOL (^is_current)(void))
{
    for (NSTextField *f in @[branch, pushed, remote_url]) {
        f.stringValue = @"Checking…";
        f.toolTip     = nil;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *b = nil, *p = nil, *r = nil;
        BOOL ok = files_git_describe(repo, &b, &p, &r);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!is_current()) return;
            if (!ok) {
                branch.stringValue     = @"Unavailable (git could not read it)";
                branch.toolTip         = branch.stringValue;
                pushed.stringValue     = @"—";
                remote_url.stringValue = @"—";
                return;
            }
            branch.stringValue     = b;
            branch.toolTip         = b;
            pushed.stringValue     = p;
            pushed.toolTip         = [p stringByAppendingString:
                @"\nCompared with the upstream branch as of the last fetch."];
            remote_url.stringValue = r;
            remote_url.toolTip     = r;
        });
    });
}
