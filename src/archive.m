#import "archive.h"
#import "shared_ui.h"
#import "shared_tool_panel.h"
#import "util.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

NSString * const FilesArchiveErrorDomain = @"FilesArchiveErrorDomain";

static NSString * const zip_tool   = @"/usr/bin/zip";
static NSString * const unzip_tool = @"/usr/bin/unzip";
static NSString * const tar_tool   = @"/usr/bin/tar";

/* Most tool output kept for an error message, in bytes. */
#define TOOL_OUTPUT_LIMIT 65536
#define ERROR_TEXT_LIMIT  1000

/*
 * Names Files recognises as archives. The first entry of a format is the
 * extension it creates; later ones (.tgz) are only recognised.
 */
static const struct {
    const char         *suffix;
    FilesArchiveFormat  format;
} archive_suffixes[] = {
    { ".tar.gz", FilesArchiveFormatTarGz },
    { ".tgz",    FilesArchiveFormatTarGz },
    { ".tar",    FilesArchiveFormatTar   },
    { ".zip",    FilesArchiveFormatZip   },
};
#define ARCHIVE_SUFFIX_COUNT (sizeof archive_suffixes / sizeof archive_suffixes[0])

/*
 * archive_suffix_of — the archive extension a file name ends with.
 *
 * Inputs:
 *   name   — file name
 *   format — receives the extension's format; may be NULL
 *
 * Output: the matching suffix from archive_suffixes (e.g. ".tar.gz"), or
 * NULL if the name is not an archive's.
 */
static const char *
archive_suffix_of(NSString *name, FilesArchiveFormat *format)
{
    const char *s = name.UTF8String;
    size_t n      = strlen(s);
    for (size_t i = 0; i < ARCHIVE_SUFFIX_COUNT; i++) {
        size_t m = strlen(archive_suffixes[i].suffix);
        if (n >= m && strcasecmp(s + n - m, archive_suffixes[i].suffix) == 0) {
            if (format) *format = archive_suffixes[i].format;
            return archive_suffixes[i].suffix;
        }
    }
    return NULL;
}

/*
 * creation_suffix — the extension a format's archives get.
 *
 * Inputs:
 *   format — archive format
 *
 * Output: e.g. @".tar.gz".
 */
static NSString *
creation_suffix(FilesArchiveFormat format)
{
    for (size_t i = 0; i < ARCHIVE_SUFFIX_COUNT; i++) {
        if (archive_suffixes[i].format == format) {
            return @(archive_suffixes[i].suffix);
        }
    }
    return @"";
}

/*
 * archive_error — builds an error in FilesArchiveErrorDomain.
 *
 * Inputs:
 *   code — error code
 *   text — message for FilesArchiveErrorFailed; empty for a generic one
 *
 * Output: the error, with a user-facing localizedDescription.
 */
static NSError *
archive_error(FilesArchiveErrorCode code, NSString *text)
{
    NSString *desc;
    switch (code) {
    case FilesArchiveErrorPasswordRequired:  desc = @"The archive is password protected."; break;
    case FilesArchiveErrorPasswordIncorrect: desc = @"The password is incorrect.";        break;
    default: desc = text.length > 0 ? text : @"The archive tool failed.";                  break;
    }
    return [NSError errorWithDomain:FilesArchiveErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

/*
 * errno_error — an NSPOSIXErrorDomain error for the current errno.
 *
 * Output: the error.
 */
static NSError *
errno_error(void)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}

/*
 * run_outcome_t — how run_tool ended.
 */
typedef NS_ENUM(NSInteger, run_outcome_t) {
    run_exited,              /* the tool ran and exited; see its status */
    run_needs_password,      /* it asked for a password and none was given */
    run_password_rejected,   /* it asked again after being given one */
    run_not_started,         /* the terminal or the process could not be set up */
};

/*
 * free_argv — frees an argument vector made by run_tool.
 *
 * Inputs:
 *   argv — NULL-terminated array of malloc'd strings
 */
static void
free_argv(char **argv)
{
    for (char **p = argv; *p; p++) free(*p);
    free(argv);
}

/*
 * has_prompt — whether tool output holds a password prompt ("Enter
 * password: ", "[a.zip] x password: ", "password incorrect--reenter: ")
 * not yet answered.
 *
 * Inputs:
 *   out  — all output so far
 *   from — offset to look from (just past the last prompt answered)
 *   end  — receives the offset just past the prompt found
 *
 * Output: YES if a prompt was found.
 */
static BOOL
has_prompt(NSData *out, NSUInteger from, NSUInteger *end)
{
    static NSData *patterns[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        patterns[0] = [@"assword: " dataUsingEncoding:NSASCIIStringEncoding];
        patterns[1] = [@"reenter: " dataUsingEncoding:NSASCIIStringEncoding];
    });
    NSRange hit    = NSMakeRange(NSNotFound, 0);
    NSRange window = NSMakeRange(from, out.length - from);
    for (int i = 0; i < 2; i++) {
        NSRange r = [out rangeOfData:patterns[i] options:0 range:window];
        if (r.location != NSNotFound && (hit.location == NSNotFound || r.location < hit.location)) {
            hit = r;
        }
    }
    if (hit.location == NSNotFound) return NO;
    *end = hit.location + hit.length;
    return YES;
}

/*
 * wait_for_echo_off — waits until the tool has switched terminal echo off
 * to read a password. It prints its prompt first and only then clears
 * ECHO, discarding input typed in between; typing sooner loses the
 * password and leaves the tool waiting for it for good.
 *
 * Inputs:
 *   master — pseudo-terminal master descriptor
 */
static void
wait_for_echo_off(int master)
{
    for (int i = 0; i < 400; i++) {  /* 2 s at most; then type anyway */
        struct termios t;
        if (tcgetattr(master, &t) == 0 && !(t.c_lflag & ECHO)) return;
        usleep(5000);
    }
}

/*
 * run_tool — runs a command-line tool on a pseudo-terminal and waits for
 * it. zip and unzip read their password from the terminal, not a pipe, and
 * a command-line password would show in `ps`; so the tool gets a terminal
 * of its own as stdin, stdout, stderr and controlling terminal, and the
 * password is typed into it when a prompt appears. Output (stderr
 * included) is collected for error messages. Blocks until the tool exits;
 * call off the main thread.
 *
 * Inputs:
 *   tool      — absolute path of the executable
 *   args      — arguments after the tool name
 *   cwd       — working directory for the tool; nil = ours
 *   password  — typed at each prompt, up to max_sends times; nil = none
 *   max_sends — password prompts to answer before the next one means the
 *               password was refused (zip -e asks twice, unzip once)
 *   status    — receives the exit status (128 + signal if killed)
 *   text      — receives the output, tidied and without the password
 *
 * Output: run_exited, or why the tool was stopped early (it is killed at a
 * prompt it cannot answer).
 */
static run_outcome_t
run_tool(NSString *tool, NSArray<NSString *> *args, NSURL *cwd, NSString *password,
         int max_sends, int *status, NSString **text)
{
    /* Everything the child needs is prepared before fork: after it only
     * async-signal-safe calls are allowed, and ObjC is not among them. */
    char **argv = calloc(args.count + 2, sizeof(char *));
    argv[0]     = strdup(tool.fileSystemRepresentation);
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = strdup(args[i].fileSystemRepresentation);
    }
    char *dir = cwd ? strdup(cwd.fileSystemRepresentation) : NULL;
    const char *pw = password.length > 0 ? password.UTF8String : NULL;

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) {
        if (master >= 0) close(master);
        free_argv(argv);
        free(dir);
        return run_not_started;
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    char slave[128];
    strlcpy(slave, ptsname(master), sizeof slave);

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        free_argv(argv);
        free(dir);
        return run_not_started;
    }
    if (pid == 0) {
        /* Signal dispositions and the blocked set survive exec; this process
         * may have SIGTERM blocked or SIGPIPE ignored, which the tool must
         * not inherit (it could not be stopped at a prompt). */
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        setsid();
        if (dir && chdir(dir) != 0) _exit(126);
        int s = open(slave, O_RDWR);
        if (s < 0) _exit(126);
        ioctl(s, TIOCSCTTY, 0);
        dup2(s, 0);
        dup2(s, 1);
        dup2(s, 2);
        if (s > 2) close(s);
        execv(argv[0], argv);
        _exit(127);
    }

    NSMutableData *out = [NSMutableData data];
    NSUInteger scan_from = 0;
    int sends            = 0;
    run_outcome_t outcome = run_exited;
    char chunk[4096];
    for (;;) {
        ssize_t n = read(master, chunk, sizeof chunk);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;  /* EOF/EIO: every holder of the terminal has gone */
        if (out.length < TOOL_OUTPUT_LIMIT) [out appendBytes:chunk length:(NSUInteger)n];
        NSUInteger end;
        if (outcome != run_exited || !has_prompt(out, scan_from, &end)) continue;
        scan_from = end;
        if (pw && sends < max_sends) {
            wait_for_echo_off(master);
            write(master, pw, strlen(pw));
            write(master, "\n", 1);
            sends++;
        } else {
            outcome = pw ? run_password_rejected : run_needs_password;
            kill(pid, SIGTERM);
        }
    }
    close(master);
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    *status = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    free_argv(argv);
    free(dir);

    NSString *s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
                  ?: [[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    if (password.length > 0) s = [s stringByReplacingOccurrencesOfString:password withString:@""];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length > ERROR_TEXT_LIMIT) s = [s substringToIndex:ERROR_TEXT_LIMIT];
    *text = s;
    return outcome;
}

/*
 * staging_url — a hidden, unique name in dir for work in progress, on the
 * same volume as its final place so rename(2) can finish the job.
 *
 * Inputs:
 *   dir  — folder the result will go in
 *   name — final name
 *   tag  — label embedded in the name ("extract" or "tmp")
 *
 * Output: URL that does not exist yet.
 */
static NSURL *
staging_url(NSURL *dir, NSString *name, NSString *tag)
{
    return [dir URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.files-%@-%@", name, tag, NSUUID.UUID.UUIDString]];
}

/*
 * remove_quietly — deletes a staging item left by a failed job; nothing to
 * report if that fails too.
 *
 * Inputs:
 *   url — item to delete
 */
static void
remove_quietly(NSURL *url)
{
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

/*
 * move_into_place — renames src to dir/name without replacing anything.
 *
 * Inputs:
 *   src      — staged item
 *   dir      — destination folder
 *   name     — wanted name
 *   suffixed — YES: if name is taken try "name 2", "name 3", …; NO: fail
 *              with EEXIST instead
 *   err      — receives the error on failure
 *
 * Output: the item's new URL, or nil.
 */
static NSURL *
move_into_place(NSURL *src, NSURL *dir, NSString *name, BOOL suffixed, NSError **err)
{
    for (int n = 1; ; n++) {
        NSString *candidate = n == 1 ? name : [NSString stringWithFormat:@"%@ %d", name, n];
        NSURL *dst = [dir URLByAppendingPathComponent:candidate];
        if (renamex_np(src.fileSystemRepresentation, dst.fileSystemRepresentation,
                       RENAME_EXCL) == 0) {
            return dst;
        }
        if (errno != EEXIST || !suffixed) {
            *err = errno_error();
            return nil;
        }
    }
}

/*
 * is_real_directory — whether url is a folder itself, not a link to one.
 *
 * Inputs:
 *   url — file URL
 *
 * Output: YES for a directory (lstat).
 */
static BOOL
is_real_directory(NSURL *url)
{
    struct stat st;
    return lstat(url.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

/*
 * extract_sync — does the work of +extract:password:completion:. Blocks;
 * call off the main thread.
 *
 * Inputs:
 *   archive  — archive file URL
 *   password — for an encrypted zip; may be nil
 *   err      — receives the error on failure
 *
 * Output: the folder holding the contents, or nil.
 */
static NSURL *
extract_sync(NSURL *archive, NSString *password, NSError **err)
{
    NSString *name = archive.lastPathComponent;
    FilesArchiveFormat format;
    const char *suffix = archive_suffix_of(name, &format);
    if (!suffix) {
        *err = archive_error(FilesArchiveErrorFailed, @"This is not a zip or tar archive.");
        return nil;
    }
    NSString *stem = [name substringToIndex:name.length - strlen(suffix)];
    if (stem.length == 0) stem = @"Extracted";

    NSURL *dir     = archive.URLByDeletingLastPathComponent;
    NSURL *staging = staging_url(dir, name, @"extract");
    NSError *mk_err = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:staging
                                withIntermediateDirectories:NO
                                                 attributes:nil
                                                      error:&mk_err]) {
        *err = mk_err;
        return nil;
    }

    BOOL zip = format == FilesArchiveFormatZip;
    NSArray<NSString *> *args = zip
        ? @[@"-q", @"-d", staging.path, archive.path, @"-x", @"__MACOSX/*"]
        : @[@"-xf", archive.path, @"-C", staging.path];
    int status = 0;
    NSString *text = nil;
    run_outcome_t outcome = run_tool(zip ? unzip_tool : tar_tool, args, nil,
                                     zip ? password : nil, 1, &status, &text);
    /* unzip exits 1 for warnings after extracting everything it could. */
    BOOL ok = outcome == run_exited && status <= (zip ? 1 : 0);
    if (!ok) {
        remove_quietly(staging);
        if (outcome == run_needs_password) {
            *err = archive_error(FilesArchiveErrorPasswordRequired, nil);
        } else if (outcome == run_password_rejected) {
            *err = archive_error(FilesArchiveErrorPasswordIncorrect, nil);
        } else if (outcome == run_not_started) {
            *err = archive_error(FilesArchiveErrorFailed, @"Could not start the extraction tool.");
        } else {
            *err = archive_error(FilesArchiveErrorFailed, text);
        }
        return nil;
    }

    NSArray<NSURL *> *top = [NSFileManager.defaultManager contentsOfDirectoryAtURL:staging
                                                        includingPropertiesForKeys:nil
                                                                           options:0
                                                                             error:nil];
    NSError *mv_err = nil;
    NSURL *result;
    if (top.count == 1 && is_real_directory(top.firstObject)) {
        result = move_into_place(top.firstObject, dir, top.firstObject.lastPathComponent,
                                 YES, &mv_err);
        remove_quietly(staging);
    } else {
        result = move_into_place(staging, dir, stem, YES, &mv_err);
        if (!result) remove_quietly(staging);
    }
    if (!result) *err = mv_err;
    return result;
}

/*
 * create_sync — does the work of +create_from:…. Blocks; call off the main
 * thread.
 *
 * Inputs:
 *   items    — items to archive, all in one folder
 *   name     — archive file name
 *   format   — archive format
 *   password — for zip; nil or empty for none
 *   err      — receives the error on failure
 *
 * Output: the archive's URL, or nil.
 */
static NSURL *
create_sync(NSArray<NSURL *> *items, NSString *name, FilesArchiveFormat format,
            NSString *password, NSError **err)
{
    if (items.count == 0) {
        *err = archive_error(FilesArchiveErrorFailed, @"Nothing to archive.");
        return nil;
    }
    BOOL zip = format == FilesArchiveFormatZip;
    if (password.length > 0 && !zip) {
        *err = archive_error(FilesArchiveErrorFailed,
                             @"Only zip archives can be password protected.");
        return nil;
    }
    NSURL *dir = items.firstObject.URLByDeletingLastPathComponent;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *item in items) {
        if (![item.URLByDeletingLastPathComponent.path isEqualToString:dir.path]) {
            *err = archive_error(FilesArchiveErrorFailed,
                                 @"The items to archive are not all in the same folder.");
            return nil;
        }
        [names addObject:item.lastPathComponent];
    }

    NSURL *staging = staging_url(dir, name, @"tmp");
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    if (zip) {
        [args addObjectsFromArray:@[@"-q", @"-r", @"-y"]];
        if (password.length > 0) [args addObject:@"-e"];
        [args addObject:staging.path];
    } else {
        [args addObjectsFromArray:@[format == FilesArchiveFormatTarGz ? @"-czf" : @"-cf",
                                    staging.path, @"--no-mac-metadata"]];
    }
    [args addObject:@"--"];
    [args addObjectsFromArray:names];

    int status = 0;
    NSString *text = nil;
    run_outcome_t outcome = run_tool(zip ? zip_tool : tar_tool, args, dir,
                                     password, 2, &status, &text);
    if (outcome != run_exited || status != 0) {
        remove_quietly(staging);
        *err = archive_error(FilesArchiveErrorFailed,
                             outcome == run_not_started ? @"Could not start the archive tool."
                                                        : text);
        return nil;
    }
    NSError *mv_err = nil;
    NSURL *result = move_into_place(staging, dir, name, NO, &mv_err);
    if (!result) {
        remove_quietly(staging);
        *err = mv_err.code == EEXIST
            ? archive_error(FilesArchiveErrorFailed,
                            [NSString stringWithFormat:@"\"%@\" already exists.", name])
            : mv_err;
    }
    return result;
}

/*
 * run_in_background — runs work on a user-initiated queue and delivers its
 * result on the main queue.
 *
 * Inputs:
 *   work       — produces the result URL, or nil with an error
 *   completion — called on the main queue
 */
static void
run_in_background(NSURL *(^work)(NSError **err),
                  void (^completion)(NSURL *url, NSError *err))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSURL *url   = work(&err);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(url, url ? nil : err);
        });
    });
}

/* ── Create Archive panel ────────────────────────────────────────────── */

static const CGFloat field_w = 260.0;
static const CGFloat field_h = 21.0;
static const CGFloat text_pt = 11.0;   /* every control, as in the other tool windows */

/*
 * FilesArchiveDialog — the Create Archive tool panel: its controls, their
 * actions, and the validation of what was entered.
 */
@interface FilesArchiveDialog : NSObject
@property (nonatomic, strong) SharedToolPanel   *panel;
@property (nonatomic, strong) NSPopUpButton     *format_popup;
@property (nonatomic, strong) NSTextField       *name_field;
@property (nonatomic, strong) NSButton          *password_check;
@property (nonatomic, strong) NSSecureTextField *password_field;
@property (nonatomic, strong) NSSecureTextField *verify_field;
@property (nonatomic, strong) NSTextField       *note;
@property (nonatomic, strong) NSURL             *folder;   /* where the archive will be made */
@property (nonatomic)         FilesArchiveFormat format;   /* the format the name field matches */
@end

@implementation FilesArchiveDialog

/*
 * make_label — a right-aligned caption for a grid row.
 *
 * Inputs:
 *   text — caption
 *
 * Output: label field.
 */
static NSTextField *
make_label(NSString *text)
{
    NSTextField *label = [NSTextField labelWithString:text];
    label.font      = [NSFont systemFontOfSize:text_pt];
    label.alignment = NSTextAlignmentRight;
    return label;
}

/*
 * style_field — gives a text field or popup the tool windows' small size and
 * a fixed width and height (without a fixed height the grid squeezes the
 * text out of its box).
 *
 * Inputs:
 *   control — field or popup button
 */
static void
style_field(NSControl *control)
{
    control.font        = [NSFont systemFontOfSize:text_pt];
    control.controlSize = NSControlSizeSmall;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control.widthAnchor constraintEqualToConstant:field_w].active  = YES;
    [control.heightAnchor constraintEqualToConstant:field_h].active = YES;
}

/*
 * init_for:handler: — builds the panel and its controls.
 *
 * Inputs:
 *   items   — items to be archived (non-empty, all in one folder)
 *   handler — as for +prompt_create_for:window:handler:
 *
 * Output: the dialog, set to zip with a default name.
 */
- (instancetype)
init_for:(NSArray<NSURL *> *)items
 handler:(void (^)(NSString *, FilesArchiveFormat, NSString *))handler
{
    self = [super init];
    if (!self) return nil;
    self.folder = items.firstObject.URLByDeletingLastPathComponent;
    self.format = FilesArchiveFormatZip;

    self.format_popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSArray<NSString *> *titles = @[@"Zip (.zip)", @"Tar, gzip compressed (.tar.gz)",
                                    @"Tar, uncompressed (.tar)"];
    FilesArchiveFormat formats[] = { FilesArchiveFormatZip, FilesArchiveFormatTarGz,
                                     FilesArchiveFormatTar };
    for (NSUInteger i = 0; i < titles.count; i++) {
        [self.format_popup addItemWithTitle:titles[i]];
        self.format_popup.lastItem.tag = formats[i];
    }
    self.format_popup.target = self;
    self.format_popup.action = @selector(format_changed:);

    self.name_field = [NSTextField textFieldWithString:
                       [FilesArchive default_name_for:items format:self.format]];
    self.password_field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.verify_field   = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    for (NSControl *c in @[self.format_popup, self.name_field,
                           self.password_field, self.verify_field]) {
        style_field(c);
    }

    self.password_check = [NSButton checkboxWithTitle:@"Password protect"
                                               target:self
                                               action:@selector(controls_changed:)];
    self.password_check.font        = [NSFont systemFontOfSize:text_pt];
    self.password_check.controlSize = NSControlSizeSmall;
    self.note = [NSTextField wrappingLabelWithString:@""];
    self.note.font                    = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1];
    self.note.textColor               = NSColor.secondaryLabelColor;
    self.note.preferredMaxLayoutWidth = field_w;

    NSView *none = NSGridCell.emptyContentView;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[make_label(@"Format:"),   self.format_popup],
        @[make_label(@"Name:"),     self.name_field],
        @[none,                     self.password_check],
        @[make_label(@"Password:"), self.password_field],
        @[make_label(@"Verify:"),   self.verify_field],
        @[none,                     self.note],
    ]];
    grid.columnSpacing = 8;
    grid.rowSpacing    = 8;
    grid.rowAlignment  = NSGridRowAlignmentNone;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    for (NSUInteger r = 0; r < 5; r++) [grid rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;

    NSString *what = items.count == 1
        ? [NSString stringWithFormat:@"\"%@\"", items.firstObject.lastPathComponent]
        : [NSString stringWithFormat:@"%lu items", (unsigned long)items.count];
    self.panel = [SharedToolPanel
        panel_with_title:@"Create Archive"
                headline:[NSString stringWithFormat:@"Archive %@", what]
                subtitle:[NSString stringWithFormat:@"In \"%@\"", self.folder.lastPathComponent]
                  symbol:@"archivebox"
                 content:grid
                 buttons:@[@"Create", @"Cancel"]
             destructive:-1
                 handler:^NSString *(NSInteger index) {
        if (index != 0) return nil;
        NSString *problem = [self validation_error];
        if (problem) return problem;
        handler([self final_name], self.format,
                self.password_field.enabled ? self.password_field.stringValue : nil);
        return nil;
    }];
    self.panel.window.initialFirstResponder = self.name_field;

    [self controls_changed:nil];
    return self;
}

/*
 * show_over: — shows the panel with the name's base selected, ready to type.
 *
 * Inputs:
 *   parent — window to centre over; may be nil
 */
- (void)
show_over:(NSWindow *)parent
{
    [self.panel show_over:parent];
    NSString *name = self.name_field.stringValue;
    const char *suffix = archive_suffix_of(name, NULL);
    [self.panel.window makeFirstResponder:self.name_field];
    [self.name_field.currentEditor setSelectedRange:
        NSMakeRange(0, name.length - (suffix ? strlen(suffix) : 0))];
}

/*
 * controls_changed: — enables the password controls only for zip with
 * "Password protect" ticked, and words the note under them.
 *
 * Inputs:
 *   sender — the control that changed (unused)
 */
- (void)
controls_changed:(id)sender
{
    BOOL zip = self.format_popup.selectedItem.tag == FilesArchiveFormatZip;
    self.password_check.enabled = zip;
    BOOL on = zip && self.password_check.state == NSControlStateValueOn;
    self.password_field.enabled = on;
    self.verify_field.enabled   = on;
    self.note.stringValue = zip
        ? @"Zip password protection uses the older ZipCrypto scheme, which is weak."
        : @"Only zip archives can be password protected.";
}

/*
 * format_changed: — swaps the name's extension to the new format's, if it
 * still has the old format's, then updates the password controls.
 *
 * Inputs:
 *   sender — the format popup
 */
- (void)
format_changed:(id)sender
{
    FilesArchiveFormat now = (FilesArchiveFormat)self.format_popup.selectedItem.tag;
    NSString *name   = self.name_field.stringValue;
    FilesArchiveFormat have;
    const char *suffix = archive_suffix_of(name, &have);
    if (suffix && have == self.format) {
        name = [[name substringToIndex:name.length - strlen(suffix)]
                stringByAppendingString:creation_suffix(now)];
        self.name_field.stringValue = name;
    }
    self.format = now;
    [self controls_changed:sender];
}

/*
 * final_name — the typed name, trimmed, with the format's extension added
 * unless it already ends in one of that format's.
 *
 * Output: file name to create.
 */
- (NSString *)
final_name
{
    NSString *name = [self.name_field.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    FilesArchiveFormat have;
    if (name.length > 0 && !(archive_suffix_of(name, &have) && have == self.format)) {
        name = [name stringByAppendingString:creation_suffix(self.format)];
    }
    return name;
}

/*
 * validation_error — why Create cannot go ahead yet.
 *
 * Output: a sentence for the panel, or nil if the name and password are
 * acceptable.
 */
- (NSString *)
validation_error
{
    NSString *name = [self final_name];
    if (name.length == 0) return @"Enter a name for the archive.";
    if ([name containsString:@"/"]) return @"The name cannot contain \"/\".";
    struct stat st;
    NSURL *target = [self.folder URLByAppendingPathComponent:name];
    if (lstat(target.fileSystemRepresentation, &st) == 0) {
        return [NSString stringWithFormat:@"\"%@\" already exists in this folder.", name];
    }
    if (self.password_field.enabled) {
        if (self.password_field.stringValue.length == 0) return @"Enter a password.";
        if (![self.password_field.stringValue isEqualToString:self.verify_field.stringValue]) {
            return @"The passwords do not match.";
        }
    }
    return nil;
}

@end

@implementation FilesArchive

/*
 * is_archive: — see archive.h.
 */
+ (BOOL)
is_archive:(NSURL *)url
{
    return archive_suffix_of(url.lastPathComponent, NULL) != NULL;
}

/*
 * extract:password:completion: — see archive.h.
 */
+ (void)
extract:(NSURL *)archive
password:(NSString *)password
completion:(void (^)(NSURL *folder, NSError *err))completion
{
    run_in_background(^NSURL *(NSError **err) {
        return extract_sync(archive, password, err);
    }, completion);
}

/*
 * create_from:name:format:password:completion: — see archive.h.
 */
+ (void)
create_from:(NSArray<NSURL *> *)items
       name:(NSString *)name
     format:(FilesArchiveFormat)format
   password:(NSString *)password
 completion:(void (^)(NSURL *archive, NSError *err))completion
{
    run_in_background(^NSURL *(NSError **err) {
        return create_sync(items, name, format, password, err);
    }, completion);
}

/*
 * default_name_for:format: — see archive.h.
 */
+ (NSString *)
default_name_for:(NSArray<NSURL *> *)items format:(FilesArchiveFormat)format
{
    NSString *base = items.count == 1 ? items.firstObject.lastPathComponent : @"Archive";
    return [base stringByAppendingString:creation_suffix(format)];
}

/*
 * prompt_create_for:window:handler: — see archive.h.
 */
+ (void)
prompt_create_for:(NSArray<NSURL *> *)items
           window:(NSWindow *)window
          handler:(void (^)(NSString *, FilesArchiveFormat, NSString *))handler
{
    [[[FilesArchiveDialog alloc] init_for:items handler:handler] show_over:window];
}

/*
 * prompt_password_for:incorrect:window:handler: — see archive.h.
 */
+ (void)
prompt_password_for:(NSURL *)archive
          incorrect:(BOOL)incorrect
             window:(NSWindow *)window
            handler:(void (^)(NSString *password))handler
{
    NSTextField *label = [NSTextField labelWithString:@"Password:"];
    label.font         = [NSFont systemFontOfSize:text_pt];
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    style_field(field);
    NSStackView *row = [NSStackView stackViewWithViews:@[label, field]];
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;

    SharedToolPanel *panel = [SharedToolPanel
        panel_with_title:@"Password"
                headline:[NSString stringWithFormat:@"\"%@\" is password protected",
                          archive.lastPathComponent]
                subtitle:incorrect ? @"The password was incorrect. Try again."
                                   : @"Enter the password to extract it."
                  symbol:@"lock.fill"
                 content:row
                 buttons:@[@"Extract", @"Cancel"]
             destructive:-1
                 handler:^NSString *(NSInteger index) {
        if (index != 0) return nil;
        if (field.stringValue.length == 0) return @"Enter a password.";
        handler(field.stringValue);
        return nil;
    }];
    panel.window.initialFirstResponder = field;
    [panel show_over:window];
}

@end
