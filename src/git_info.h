#import <Cocoa/Cocoa.h>

/*
 * git_info — recognising git working trees and describing their state:
 * the GitHub folder icon (light and dark variants) and the current branch
 * and whether it has been pushed, as shown in Get Info.
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
 * files_git_folder_icon — a new image of the git folder icon that draws the
 * light or dark variant (gh_folder_light/dark.icns in the app bundle) to
 * match the appearance it is drawn in, so it follows the system setting,
 * including when it changes while the image is on screen or cached. The
 * caller owns the image and may resize it.
 *
 * Output: new NSImage, or nil if the icns files are missing from the bundle.
 */
NSImage *files_git_folder_icon(void);

/*
 * files_git_describe — the current branch of a git working tree and whether
 * its commits have been pushed, as display strings. "Pushed" compares the
 * branch with its upstream as of the last fetch; nothing is fetched. Runs
 * git; blocks, so call off the main thread.
 *
 * Inputs:
 *   repo   — working-tree root (files_is_git_repo(repo) is YES)
 *   branch — receives the branch name, or "Detached at <commit>"
 *   pushed — receives "Yes …" or "No …" with the reason, e.g.
 *            "No — 2 ahead of origin/main" (counts are commits)
 *
 * Output: YES if git could read the repository; NO (outputs untouched) if
 *         git is missing or refused (e.g. a repo owned by another user).
 */
BOOL files_git_describe(NSURL *repo, NSString **branch, NSString **pushed);
