#import "git_info.h"
#import "util.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
 * load_bundle_icns — loads name.icns from the app bundle (all sizes).
 *
 * Inputs:
 *   name — resource name without extension
 *
 * Output: image, or nil if the file is missing or unreadable.
 */
static NSImage *
load_bundle_icns(NSString *name)
{
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"icns"];
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}

/*
 * files_git_folder_icon — appearance-following git folder image.
 * Inputs/output are documented in git_info.h.
 */
NSImage *
files_git_folder_icon(void)
{
    static NSImage *light, *dark;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        light = load_bundle_icns(@"gh_folder_light");
        dark  = load_bundle_icns(@"gh_folder_dark");
    });
    if (!light || !dark) return nil;

    /* The handler runs whenever the image is rendered, under the appearance
     * of the view drawing it, so one image serves both modes. */
    return [NSImage imageWithSize:NSMakeSize(512, 512) flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
        NSAppearanceName match = [NSAppearance.currentDrawingAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,
                                                NSAppearanceNameDarkAqua]];
        NSImage *src = [match isEqualToString:NSAppearanceNameDarkAqua] ? dark : light;
        [src drawInRect:rect];
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
    if (!files_run_tool(@"/usr/bin/git", full, &data)) return nil;
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
 * files_git_describe — branch via symbolic-ref, push state via for-each-ref.
 * Inputs/output are documented in git_info.h.
 */
BOOL
files_git_describe(NSURL *repo, NSString **branch, NSString **pushed)
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
        return YES;
    }

    NSString *line = run_git(repo, @[@"for-each-ref",
                                     @"--format=%(upstream:short)%09%(upstream:track,nobracket)",
                                     ref]);
    if (!line) return NO;

    NSString *prefix = @"refs/heads/";
    *branch = [ref hasPrefix:prefix] ? [ref substringFromIndex:prefix.length] : ref;
    if (line.length == 0) {
        /* The branch ref does not exist yet: a new repository. */
        *pushed = @"No — no commits yet";
        return YES;
    }
    NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
    *pushed = describe_upstream(fields[0], fields.count > 1 ? fields[1] : @"");
    return YES;
}
