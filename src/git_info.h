#import <Cocoa/Cocoa.h>

/*
 * git_info — recognising git working trees and describing their state:
 * the git badge on their icon, which items in them git tracks (the file
 * list's Git column), and the current branch and whether it has been
 * pushed, as shown in Get Info.
 */

/*
 * files_is_git_repo — whether url is the top folder of a git working tree:
 * a directory (not a package such as an .app) that contains a .git entry.
 * .git may be a folder or, for worktrees and submodules, a file. One stat;
 * safe on any thread.
 *
 * Inputs:
 *   url — file URL of the item
 *
 * Output: YES if url is a git working-tree root.
 */
BOOL files_is_git_repo(NSURL *url);

/*
 * files_git_work_tree — the git working tree dir is in: the nearest of dir
 * and its ancestors that contains a .git entry. A folder inside .git is in
 * no working tree, and nothing is while git is not installed (Xcode or the
 * Command Line Tools). A few stats (the first call also asks xcode-select
 * where git is); safe on any thread, but call off the main thread.
 *
 * Inputs:
 *   dir — folder URL
 *
 * Output: working-tree root URL, or nil if dir is not inside one.
 */
NSURL *files_git_work_tree(NSURL *dir);

/*
 * files_git_tracked_names — names of the items directly in dir that git
 * tracks: files in the index (so newly added ones count) and folders that
 * contain at least one such file (or are submodules). Untracked and ignored
 * items are never included. Runs git; blocks, so call off the main thread.
 *
 * Inputs:
 *   dir — folder inside a git working tree (files_git_work_tree(dir) != nil)
 *
 * Output: set of names (possibly empty), or nil if git could not list dir.
 */
NSSet<NSString *> *files_git_tracked_names(NSURL *dir);

/*
 * files_git_index_path — the resolved path of work_tree's index file
 * (.git/index), which git rewrites whenever what it tracks changes (add,
 * rm, commit, checkout). Safe on any thread.
 *
 * Inputs:
 *   work_tree — working-tree root
 *
 * Output: path, or nil when .git is a file (worktrees and submodules keep
 *         their index elsewhere).
 */
NSString *files_git_index_path(NSURL *work_tree);

/*
 * files_git_badged_icon — a new image that draws icon with the git logo
 * (git96.png in the app bundle) centered on its artwork (found by scanning
 * the icon's opaque pixels, so it is centered on the folder itself, not
 * the empty margin around it), lowered slightly onto the folder's front. The badge is 16 points square, but at most
 * half the icon's width so it stays a badge on small list icons. Drawing
 * is deferred, so icon still follows the light/dark appearance. Set the
 * wanted size on icon before calling; the result has the same size.
 *
 * Inputs:
 *   icon — the item's own icon
 *
 * Output: new NSImage, or icon itself if git96.png is missing.
 */
NSImage *files_git_badged_icon(NSImage *icon);

/*
 * files_git_describe — the current branch of a git working tree, whether
 * its commits have been pushed, and the remote URL, as display strings.
 * "Pushed" compares the branch with its upstream as of the last fetch;
 * nothing is fetched. Runs git; blocks, so call off the main thread.
 *
 * Inputs:
 *   repo       — working-tree root (files_is_git_repo(repo) is YES)
 *   branch     — receives the branch name, or "Detached at <commit>"
 *   pushed     — receives "Yes …" or "No …" with the reason, e.g.
 *                "No — 2 ahead of origin/main" (counts are commits)
 *   remote_url — receives the URL of the branch's upstream remote, else of
 *                "origin", else of the first remote; "None" if there are
 *                no remotes
 *
 * Output: YES if git could read the repository; NO (outputs untouched) if
 *         git is missing or refused (e.g. a repo owned by another user).
 */
BOOL files_git_describe(NSURL *repo, NSString **branch, NSString **pushed,
                        NSString **remote_url);

/*
 * files_git_show — fills three value fields with files_git_describe's
 * results for repo: shows "Checking…" at once, runs git on a background
 * queue, then sets the text (and full-text tooltips, since values may be
 * truncated) on the main queue. Shared by Get Info and the info sidebar.
 * Call on the main thread.
 *
 * Inputs:
 *   repo       — working-tree root (files_is_git_repo(repo) is YES)
 *   branch     — field for the branch name
 *   pushed     — field for the push state
 *   remote_url — field for the remote URL
 *   is_current — called on the main queue before filling; return NO when
 *                the view has moved on to another item, to drop the result
 */
void files_git_show(NSURL *repo, NSTextField *branch, NSTextField *pushed,
                    NSTextField *remote_url, BOOL (^is_current)(void));
