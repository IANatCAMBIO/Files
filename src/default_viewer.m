#import "default_viewer.h"
#import "tool_panel.h"
#import "util.h"
#include <pwd.h>
#include <signal.h>
#include <unistd.h>

/* Files' own defaults key holding what the takeover replaced:
 * domain → key → wrapped original (@[value], or @[] if the key was absent),
 * the form files_sync_prefs reports and accepts. */
static NSString * const originals_key = @"files.default_viewer.originals";

static NSString * const finder_domain = @"com.apple.finder";
static NSString * const finder_path   = @"/System/Library/CoreServices/Finder.app";

/* Archive Utility's preferences (sandboxed: changing them needs Full Disk
 * Access). Its reveal-after keys make it open a Finder window on what it
 * creates or expands: off while Files is the default file viewer, on
 * (Archive Utility's own default) while Finder is. */
static NSString * const archive_utility_domain = @"com.apple.archiveutility";

/* Change logs written by files_default_viewer_choose, under ~/Library/Logs. */
static NSString * const log_folder = @"Logs/Files";

/* Titles of the logged steps both directions share. */
static NSString * const originals_title        = @"Files' saved copy of the original values "
                                                  "(saved when Files takes over, used and "
                                                  "removed when Finder is restored)";
static NSString * const quit_title             = @"Quit Finder, so it rereads its settings "
                                                  "when it next starts";
static NSString * const launch_title           = @"Start Finder again, so the desktop and "
                                                  "menus show its settings";
static NSString * const quit_command           = @"osascript -e 'quit app \"Finder\"'";
static NSString * const launch_command         = @"open -g -a Finder";

/* The zsh startup file that gets Files' `open` function, which sends
 * `open <folder>` in Terminal to Files. macOS gives no way to make Files
 * the default app for folders (LaunchServices rejects public.folder
 * handlers other than Finder), so this is how Terminal gets it. The
 * block between the marker lines is Files' own: added while Files is the
 * default file browser, removed when Finder is. */
static NSString * const zshrc_path   = @"~/.zshrc";
static NSString * const shell_begin  = @"# BEGIN Files: open folders in Files";
static NSString * const shell_end    = @"# END Files: open folders in Files";
static NSString * const shell_title  = @"Terminal: `open <folder>` in zsh opens Files (a shell "
                                        "function in ~/.zshrc; new Terminal windows pick it up)";
static NSString * const shell_verify = @"grep -A14 'BEGIN Files:' ~/.zshrc";

/*
 * FilesChangeLog — the record files_default_viewer_choose shows the user:
 * numbered steps, each with before/after values and the equivalent
 * Terminal command, plus one check per setting read back afterwards. Both
 * directions log the same steps and checks in the same order; a step a run
 * does not need is still listed, as "not needed this time" (skip:why:).
 * Every function that changes a setting takes one; nil (a silent sync)
 * makes every message a no-op.
 */
@interface FilesChangeLog : NSObject
@property (nonatomic, readonly) NSMutableString           *text;
@property (nonatomic, readonly) NSMutableArray<NSString *> *checks;
@property (nonatomic)           NSUInteger                 failures;
@property (nonatomic)           NSUInteger                 skipped;
@property (nonatomic)           NSUInteger                 steps;
@end

@implementation FilesChangeLog

/*
 * init — an empty log.
 *
 * Output: self or nil.
 */
- (instancetype)
init
{
    self = [super init];
    if (!self) return nil;
    _text   = [NSMutableString string];
    _checks = [NSMutableArray array];
    return self;
}

/*
 * step: — starts a numbered step.
 *
 * Inputs:
 *   title — what the step is about, in plain words
 */
- (void)
step:(NSString *)title
{
    self.steps++;
    [self.text appendFormat:@"\n[%lu] %@\n", (unsigned long)self.steps, title];
}

/*
 * note:text: — one labelled line of the current step; lines after the
 * first line of text are indented under it.
 *
 * Inputs:
 *   label — e.g. @"Before", @"Command"
 *   text  — value; may span lines
 */
- (void)
note:(NSString *)label text:(NSString *)text
{
    NSString *lead   = [[@"    " stringByAppendingString:[label stringByAppendingString:@":"]]
                        stringByPaddingToLength:14 withString:@" " startingAtIndex:0];
    NSString *indent = [@"" stringByPaddingToLength:lead.length withString:@" " startingAtIndex:0];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        [self.text appendFormat:@"%@%@\n", i == 0 ? lead : indent, lines[i]];
    }
}

/*
 * check:what:verify: — records whether a setting was confirmed by reading
 * it back, as the current step's result and as a line of the summary.
 *
 * Inputs:
 *   ok     — YES if the setting reads back as wanted
 *   what   — the setting and its wanted state
 *   verify — Terminal command that shows the setting; may be nil
 */
- (void)
check:(BOOL)ok what:(NSString *)what verify:(NSString *)verify
{
    if (!ok) self.failures++;
    [self note:@"Result" text:ok ? @"✓ confirmed by reading it back"
                                 : @"✗ FAILED — the setting does not read back as wanted"];
    NSString *line = [NSString stringWithFormat:@"  %@ %@", ok ? @"✓" : @"✗", what];
    if (verify) line = [line stringByAppendingFormat:@"\n      check: %@", verify];
    [self.checks addObject:line];
}

/*
 * skip:why: — records that a check's step was not needed this run, as the
 * current step's result and as a line of the summary.
 *
 * Inputs:
 *   what — what the step would have done or checked
 *   why  — why it was not needed
 */
- (void)
skip:(NSString *)what why:(NSString *)why
{
    self.skipped++;
    [self note:@"Result" text:[@"– not needed this time: " stringByAppendingString:why]];
    [self.checks addObject:[NSString stringWithFormat:@"  – %@ (not needed this time)", what]];
}

@end

/*
 * shell_quote — a word as it would be typed in a shell: unchanged if it is
 * made only of characters the shell treats literally, else single-quoted.
 *
 * Inputs:
 *   word — the word
 *
 * Output: shell-safe text.
 */
static NSString *
shell_quote(NSString *word)
{
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:=@%+,"];
    if (word.length > 0 &&
        [word rangeOfCharacterFromSet:safe.invertedSet].location == NSNotFound) {
        return word;
    }
    return [NSString stringWithFormat:@"'%@'",
            [word stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

/*
 * plist_text — a value as one line of XML property list (no header), the
 * form `defaults write` accepts for any type.
 *
 * Inputs:
 *   value — property-list object
 *
 * Output: e.g. @"<dict><key>a</key><string>b</string></dict>".
 */
static NSString *
plist_text(id value)
{
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:value
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:nil];
    NSString *s = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : @"";
    NSRange open  = [s rangeOfString:@"<plist version=\"1.0\">"];
    NSRange close = [s rangeOfString:@"</plist>" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound) return s;
    NSUInteger from = NSMaxRange(open);
    s = [s substringWithRange:NSMakeRange(from, close.location - from)];

    NSMutableString *line = [NSMutableString string];
    for (NSString *part in [s componentsSeparatedByString:@"\n"]) {
        [line appendString:[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    }
    return line;
}

/*
 * is_bool — whether a property-list value is a boolean (CFBoolean), not a
 * number.
 *
 * Inputs:
 *   value — any object
 *
 * Output: YES for @YES / @NO.
 */
static BOOL
is_bool(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

/*
 * value_text — a wrapped preference value for the log.
 *
 * Inputs:
 *   wrapped — @[value] or @[] (absent); nil = could not be read
 *
 * Output: e.g. @"false", @"\"com.cambio.files\"", @"(not set)".
 */
static NSString *
value_text(NSArray *wrapped)
{
    if (!wrapped) return @"(could not be read)";
    id v = wrapped.firstObject;
    if (!v)                                 return @"(not set)";
    if (is_bool(v))                         return [v boolValue] ? @"true" : @"false";
    if ([v isKindOfClass:NSString.class])   return [NSString stringWithFormat:@"\"%@\"", v];
    if ([v isKindOfClass:NSNumber.class])   return [v stringValue];
    return plist_text(v);
}

/*
 * domain_arg — a preferences domain as the defaults tool takes it.
 *
 * Inputs:
 *   domain — domain name; @"NSGlobalDomain" for the global one
 *
 * Output: @"-g" or the quoted domain.
 */
static NSString *
domain_arg(NSString *domain)
{
    return [domain isEqualToString:@"NSGlobalDomain"] ? @"-g" : shell_quote(domain);
}

/*
 * defaults_command — the `defaults` command that gives a key a wrapped
 * value.
 *
 * Inputs:
 *   domain  — preferences domain
 *   key     — preference key
 *   wrapped — @[value] to write, @[] to delete
 *
 * Output: the command line.
 */
static NSString *
defaults_command(NSString *domain, NSString *key, NSArray *wrapped)
{
    NSString *target = [NSString stringWithFormat:@"%@ %@", domain_arg(domain), shell_quote(key)];
    id v = wrapped.firstObject;
    if (!v) return [NSString stringWithFormat:@"defaults delete %@", target];

    NSString *arg;
    if (is_bool(v)) {
        arg = [v boolValue] ? @"-bool true" : @"-bool false";
    } else if ([v isKindOfClass:NSString.class]) {
        arg = [@"-string " stringByAppendingString:shell_quote(v)];
    } else if ([v isKindOfClass:NSNumber.class]) {
        const char *t = [v objCType];
        arg = [NSString stringWithFormat:@"%@ %@",
               (t[0] == 'd' || t[0] == 'f') ? @"-float" : @"-int", [v stringValue]];
    } else {
        arg = shell_quote(plist_text(v));
    }
    return [NSString stringWithFormat:@"defaults write %@ %@", target, arg];
}

/*
 * read_command — the `defaults` command that shows a key.
 *
 * Inputs:
 *   domain — preferences domain
 *   key    — preference key
 *
 * Output: the command line.
 */
static NSString *
read_command(NSString *domain, NSString *key)
{
    return [NSString stringWithFormat:@"defaults read %@ %@", domain_arg(domain), shell_quote(key)];
}

/*
 * managed_prefs — the settings Files owns while it is the default viewer.
 *
 * Output: domain → key → wrapped value, for files_sync_prefs.
 */
static NSDictionary<NSString *, NSDictionary<NSString *, NSArray *> *> *
managed_prefs(void)
{
    return @{
        @"NSGlobalDomain": @{ @"NSFileViewer": @[NSBundle.mainBundle.bundleIdentifier] },
        finder_domain:     @{ @"CreateDesktop": @[@NO], @"QuitMenuItem": @[@YES] },
    };
}

/*
 * domain_title — what a managed domain's settings do, for the log.
 *
 * Inputs:
 *   domain — preferences domain
 *
 * Output: plain-words title.
 */
static NSString *
domain_title(NSString *domain)
{
    if ([domain isEqualToString:@"NSGlobalDomain"]) {
        return @"\"Show in Finder\" requests from other apps (NSFileViewer)";
    }
    if ([domain isEqualToString:finder_domain]) {
        return @"Finder: desktop icons (CreateDesktop) and its Quit menu item (QuitMenuItem)";
    }
    if ([domain isEqualToString:archive_utility_domain]) {
        return @"Archive Utility: open Finder on what it creates or expands";
    }
    return domain;
}

/*
 * sync_domain — files_sync_prefs, logged: reads each key before and after,
 * and logs both values, the equivalent `defaults` command and whether the
 * key now reads back as wanted.
 *
 * Inputs:
 *   domain   — preferences domain
 *   values   — key → wrapped wanted value
 *   previous — as for files_sync_prefs; may be nil
 *   log      — change log; nil = files_sync_prefs alone
 *
 * Output: files_sync_prefs' result.
 */
static BOOL
sync_domain(NSString *domain, NSDictionary<NSString *, NSArray *> *values,
            NSMutableDictionary<NSString *, NSArray *> *previous, FilesChangeLog *log)
{
    NSArray<NSString *> *keys = [values.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary *before = log ? files_read_prefs(domain, keys) : nil;
    BOOL ok = files_sync_prefs(domain, values, previous);
    if (!log) return ok;
    NSDictionary *after = files_read_prefs(domain, keys);

    [log step:domain_title(domain)];
    BOOL all_set = YES;
    for (NSString *key in keys) {
        NSArray *want = values[key];
        BOOL needed   = !before || ![before[key] isEqual:want];
        NSString *cmd = defaults_command(domain, key, want);
        [log note:@"Setting" text:[NSString stringWithFormat:@"%@ %@", domain, key]];
        [log note:@"Before" text:value_text(before[key])];
        [log note:@"After" text:value_text(after[key])];
        [log note:@"Command" text:needed ? cmd
                                         : [cmd stringByAppendingString:@"   (not run: already set)"]];
        [log check:[after[key] isEqual:want]
              what:[NSString stringWithFormat:@"%@ %@ = %@", domain, key, value_text(want)]
            verify:read_command(domain, key)];
        all_set = all_set && [after[key] isEqual:want];
    }
    if (!all_set && !files_has_full_disk_access()) {
        [log note:@"Note" text:@"Files does not have Full Disk Access, which changing another "
                                "app's settings needs: System Settings ▸ Privacy & Security ▸ "
                                "Full Disk Access ▸ Files. Then click the button again."];
    }
    return ok;
}

/*
 * own_pref — sets one of Files' own BOOL preferences, logged.
 *
 * Inputs:
 *   key   — files_pref_* key
 *   value — value to set
 *   title — what the preference means, for the log
 *   log   — change log; may be nil
 */
static void
own_pref(NSString *key, BOOL value, NSString *title, FilesChangeLog *log)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    BOOL was     = [defaults boolForKey:key];
    [defaults setBool:value forKey:key];

    [log step:title];
    [log note:@"Setting" text:[NSString stringWithFormat:@"%@ %@", me, key]];
    [log note:@"Before" text:was ? @"true" : @"false"];
    [log note:@"After" text:[defaults boolForKey:key] ? @"true" : @"false"];
    [log note:@"Command" text:defaults_command(me, key, @[@(value)])];
    [log check:[defaults boolForKey:key] == value
          what:[NSString stringWithFormat:@"%@ %@ = %@", me, key, value ? @"true" : @"false"]
        verify:read_command(me, key)];
}

/*
 * quit_finder — asks Finder to quit (a clean quit, so launchd does not
 * restart it) and waits up to five seconds for it to exit. Blocks.
 *
 * Inputs:
 *   log — change log; may be nil
 *
 * Output: YES if Finder is no longer running.
 */
static BOOL
quit_finder(FilesChangeLog *log)
{
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
    BOOL gone = YES;
    for (NSRunningApplication *app in apps) {
        pid_t pid = app.processIdentifier;
        [app terminate];
        /* NSRunningApplication.terminated only updates on the main run
         * loop; probing the pid works from this queue. */
        for (int i = 0; i < 50 && kill(pid, 0) == 0; i++) usleep(100000);
        gone = kill(pid, 0) != 0 && gone;
    }

    [log step:quit_title];
    [log note:@"Command" text:quit_command];
    [log check:gone what:@"Finder quit (macOS starts it again when something needs it)" verify:nil];
    return gone;
}

/*
 * launch_finder — starts Finder in the background (it redraws the desktop
 * with whatever settings it now reads) and waits up to ten seconds for it
 * to start. Blocks.
 *
 * Inputs:
 *   log — change log; may be nil
 *
 * Output: YES if Finder started.
 */
static BOOL
launch_finder(FilesChangeLog *log)
{
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = NO;
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:finder_path]
                                        configuration:cfg
                                    completionHandler:^(NSRunningApplication *app, NSError *err) {
        ok = app != nil;
        dispatch_semaphore_signal(started);
    }];
    dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    [log step:launch_title];
    [log note:@"Command" text:launch_command];
    [log check:ok what:@"Finder is running" verify:@"pgrep -x Finder"];
    return ok;
}

/*
 * skip_step — logs a step this run does not need, so every run lists the
 * same steps: its title, the command it would run, and why it was not
 * needed.
 *
 * Inputs:
 *   title   — step title
 *   command — Terminal command the step runs when needed
 *   what    — what the step does, for the summary
 *   why     — why it was not needed
 *   log     — change log; may be nil
 */
static void
skip_step(NSString *title, NSString *command, NSString *what, NSString *why, FilesChangeLog *log)
{
    [log step:title];
    [log note:@"Command" text:[command stringByAppendingString:@"   (not run)"]];
    [log skip:what why:why];
}

/*
 * shell_block — Files' block for ~/.zshrc: an `open` function that sends
 * one or more plain folders to Files and anything else (files, options,
 * packages such as .app bundles) to the real `open`, which it also falls
 * back to if Files cannot be opened.
 *
 * Output: the block, marker lines included, ending in a newline.
 */
static NSString *
shell_block(void)
{
    return [NSString stringWithFormat:
        @"%@\n"
         "# Added by Files while it is the default file browser; \"Set default file\n"
         "# browser to Finder\" in Files' Preferences removes it.\n"
         "open() {\n"
         "    local arg\n"
         "    (( $# )) || { command open; return; }\n"
         "    for arg in \"$@\"; do\n"
         "        [[ -d $arg && $(mdls -raw -name kMDItemContentTypeTree -- \"$arg\" 2>/dev/null) == *'\"public.folder\"'* ]] ||\n"
         "            { command open \"$@\"; return; }\n"
         "    done\n"
         "    command open -b %@ \"$@\" 2>/dev/null || command open \"$@\"\n"
         "}\n"
         "%@\n",
        shell_begin, NSBundle.mainBundle.bundleIdentifier, shell_end];
}

/*
 * without_shell_block — a zsh startup file's text with Files' block (and
 * the blank line Files put before it) taken out.
 *
 * Inputs:
 *   text — file contents
 *
 * Output: text unchanged if it has no complete block, else without it.
 */
static NSString *
without_shell_block(NSString *text)
{
    /* The nearest begin marker before the end marker, so a stray begin
     * line above the block never takes the user's lines with it. */
    NSRange end   = [text rangeOfString:shell_end];
    if (end.location == NSNotFound) return text;
    NSRange begin = [text rangeOfString:shell_begin options:NSBackwardsSearch
                                  range:NSMakeRange(0, end.location)];
    if (begin.location == NSNotFound) return text;

    NSUInteger from = begin.location, to = NSMaxRange(end);
    if (to < text.length && [text characterAtIndex:to] == '\n') to++;
    if (from >= 2 && [[text substringWithRange:NSMakeRange(from - 2, 2)] isEqualToString:@"\n\n"]) from--;
    return [text stringByReplacingCharactersInRange:NSMakeRange(from, to - from) withString:@""];
}

/*
 * shell_state_text — whether a zsh startup file holds Files' block, for
 * the log.
 *
 * Inputs:
 *   text — file contents; nil = could not be read
 *   want — Files' current block
 *
 * Output: plain-words state.
 */
static NSString *
shell_state_text(NSString *text, NSString *want)
{
    if (!text)                                return @"(could not be read)";
    if ([text containsString:want])           return @"Files' open function is in ~/.zshrc";
    if ([text containsString:shell_begin])    return @"an older or edited copy of Files' open function is in ~/.zshrc";
    return @"no open function from Files";
}

/*
 * login_shell — the user's login shell.
 *
 * Output: its path, e.g. @"/bin/zsh", or nil if unknown.
 */
static NSString *
login_shell(void)
{
    struct passwd *pw = getpwuid(getuid());
    return pw && pw->pw_shell ? @(pw->pw_shell) : nil;
}

/*
 * sync_shell_function — adds Files' `open` function to ~/.zshrc (install,
 * replacing an older copy) or takes it out, leaving the rest of the file as
 * it is, logged. The file is written in place, so a symlinked ~/.zshrc
 * keeps its link. Installing is skipped when the login shell is not zsh;
 * removing always runs.
 *
 * Inputs:
 *   install — YES: add the function; NO: remove it
 *   log     — change log; may be nil
 *
 * Output: YES if ~/.zshrc now holds (install) or lacks (remove) the block,
 *         or installing was not needed.
 */
static BOOL
sync_shell_function(BOOL install, FilesChangeLog *log)
{
    NSString *path  = zshrc_path.stringByExpandingTildeInPath.stringByResolvingSymlinksInPath;
    NSString *block = shell_block();
    NSString *shell = login_shell();
    NSString *add   = [NSString stringWithFormat:@"cat >> ~/.zshrc <<'EOF'\n\n%@EOF", block];
    NSString *drop  = [NSString stringWithFormat:@"sed -i '' '/^%@$/,/^%@$/d' ~/.zshrc",
                       shell_begin, shell_end];

    if (install && ![shell.lastPathComponent isEqualToString:@"zsh"]) {
        skip_step(shell_title, add, @"~/.zshrc has Files' open function",
                  [NSString stringWithFormat:@"your login shell is %@; Files only sets up zsh",
                   shell ?: @"unknown"], log);
        return YES;
    }

    BOOL exists      = [NSFileManager.defaultManager fileExistsAtPath:path];
    NSString *before = exists ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
                                                             error:nil]
                              : @"";
    NSString *want   = nil;
    if (before) {
        want = without_shell_block(before);
        if (install) {
            if (want.length > 0 && ![want hasSuffix:@"\n"]) want = [want stringByAppendingString:@"\n"];
            want = [want stringByAppendingFormat:@"%@%@", want.length > 0 ? @"\n" : @"", block];
        }
    }
    BOOL needed = before && ![want isEqualToString:before];
    if (needed) {
        [want writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *after = [NSFileManager.defaultManager fileExistsAtPath:path]
                      ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                      : @"";
    BOOL ok = after && (install ? [after containsString:block] : ![after containsString:shell_begin]);
    if (!log) return ok;

    [log step:shell_title];
    [log note:@"Setting" text:[NSString stringWithFormat:@"%@ (%@ … %@)", zshrc_path,
                               shell_begin, shell_end]];
    [log note:@"Before" text:shell_state_text(before, block)];
    [log note:@"After" text:shell_state_text(after, block)];
    NSString *cmd = install ? ([before containsString:shell_begin]
                               ? [NSString stringWithFormat:@"%@\n%@", drop, add] : add)
                            : drop;
    [log note:@"Command" text:needed ? cmd : [cmd stringByAppendingString:@"\n(not run: already set)"]];
    [log check:ok
          what:install ? @"~/.zshrc has Files' open function" : @"~/.zshrc has no open function from Files"
        verify:shell_verify];
    if (needed) {
        [log note:@"Note" text:@"Open a new Terminal window, or run `source ~/.zshrc`, for it to "
                                "take effect in a shell that is already open."];
    }
    return ok;
}

/*
 * sync_archive_reveal — makes Archive Utility reveal (or not) what it
 * creates or expands, logged.
 *
 * Inputs:
 *   reveal — YES: Archive Utility opens Finder on its results
 *   log    — change log; may be nil
 *
 * Output: YES if both reveal-after keys now hold reveal.
 */
static BOOL
sync_archive_reveal(BOOL reveal, FilesChangeLog *log)
{
    return sync_domain(archive_utility_domain,
                       @{ @"dearchive-reveal-after": @[@(reveal)],
                          @"archive-reveal-after":   @[@(reveal)] },
                       nil, log);
}

/*
 * take_over — makes every managed setting hold Files' value, recording the
 * value each one replaced unless a record already exists (the first
 * original wins, so re-applying after something reset a key keeps the
 * pre-Files value). Records are saved per domain as soon as it is written.
 * Also adds the `open` function to ~/.zshrc and stops Archive Utility
 * opening Finder on its results. Quits Finder if one of its settings
 * changed, since Finder reads them only at launch; it
 * stays quit until something asks for it.
 *
 * Inputs:
 *   log — change log; may be nil
 *
 * Output: YES if every setting now holds Files' value.
 */
static BOOL
take_over(FilesChangeLog *log)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    NSMutableDictionary *originals = [[defaults dictionaryForKey:originals_key] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
    NSDictionary *managed = managed_prefs();
    BOOL ok = YES, finder_changed = NO, saved_any = NO;

    for (NSString *domain in [managed.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableDictionary *replaced = [NSMutableDictionary dictionary];
        ok = sync_domain(domain, managed[domain], replaced, log) && ok;
        if (replaced.count == 0) continue;
        if ([domain isEqualToString:finder_domain]) finder_changed = YES;

        NSMutableDictionary *saved = [originals[domain] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
        for (NSString *key in replaced) {
            if (saved[key]) continue;
            saved[key] = replaced[key];
            saved_any  = YES;
        }
        originals[domain] = saved;
        [defaults setObject:originals forKey:originals_key];
    }

    NSString *save = defaults_command(me, originals_key, @[originals]);
    if (saved_any) {
        [log step:originals_title];
        [log note:@"Saved" text:plist_text(originals)];
        [log note:@"Command" text:save];
        [log check:[[defaults dictionaryForKey:originals_key] isEqual:originals]
              what:@"Original values saved in Files' preferences"
            verify:read_command(me, originals_key)];
    } else {
        skip_step(originals_title, save, @"Original values saved in Files' preferences",
                  originals.count > 0
                  ? @"they were saved earlier, and are kept until Finder is restored"
                  : @"Files changed no setting, so there is nothing to save", log);
    }

    ok = sync_shell_function(YES, log) && ok;
    ok = sync_archive_reveal(NO, log) && ok;

    if (finder_changed) {
        quit_finder(log);
    } else {
        skip_step(quit_title, quit_command, @"Finder quit",
                  @"Finder's settings did not change", log);
    }
    skip_step(launch_title, launch_command, @"Finder is running",
              @"while Files is the default, Finder stays quit until something needs it", log);
    return ok;
}

/*
 * give_back — writes every recorded original back, then forgets the records (kept if a write
 * failed, so the next sync retries), takes the `open` function out of
 * ~/.zshrc, and turns Archive Utility's
 * reveal-in-Finder back on. Restarts Finder if one of its settings
 * changed, so the desktop and menus match.
 *
 * Inputs:
 *   log — change log; may be nil
 *
 * Output: YES if every recorded setting was restored.
 */
static BOOL
give_back(FilesChangeLog *log)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *originals = [defaults dictionaryForKey:originals_key];
    NSDictionary *managed   = managed_prefs();
    BOOL ok = YES, finder_changed = NO;

    /* Every managed setting is listed; one with no saved original was
     * never changed by Files, so it is left as it is. */
    for (NSString *domain in [managed.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *values = originals[domain] ?: @{};
        NSMutableDictionary *changed = [NSMutableDictionary dictionary];
        ok = sync_domain(domain, values, changed, log) && ok;
        if (changed.count > 0 && [domain isEqualToString:finder_domain]) finder_changed = YES;
        for (NSString *key in [[managed[domain] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if (values[key]) continue;
            [log note:@"Setting" text:[NSString stringWithFormat:@"%@ %@", domain, key]];
            [log note:@"Command" text:@"(none run)"];
            [log skip:[NSString stringWithFormat:@"%@ %@ put back", domain, key]
                  why:@"Files has no saved value for it, so it did not change it"];
        }
    }

    NSString *forget = defaults_command(me, originals_key, @[]);
    if (!originals) {
        skip_step(originals_title, forget, @"Saved values removed from Files' preferences",
                  @"nothing was saved", log);
    } else if (!ok) {
        skip_step(originals_title, forget, @"Saved values removed from Files' preferences",
                  @"kept, because a setting above could not be put back; Files tries again "
                   "the next time it opens", log);
    } else {
        [defaults removeObjectForKey:originals_key];
        [log step:originals_title];
        [log note:@"Command" text:forget];
        [log check:[defaults objectForKey:originals_key] == nil
              what:@"Saved values removed from Files' preferences"
            verify:read_command(me, originals_key)];
    }

    ok = sync_shell_function(NO, log) && ok;
    ok = sync_archive_reveal(YES, log) && ok;

    if (finder_changed) {
        quit_finder(log);
        launch_finder(log);
    } else {
        NSString *why = @"Finder's settings did not change";
        skip_step(quit_title, quit_command, @"Finder quit", why, log);
        skip_step(launch_title, launch_command, @"Finder is running", why, log);
    }
    return ok;
}

/*
 * check_final — confirms, whatever was recorded, that "Show in Finder"
 * requests go to the chosen app: Files, or (for Finder) anything but
 * Files.
 *
 * Inputs:
 *   files — YES for Files, NO for Finder
 *   log   — change log
 */
static void
check_final(BOOL files, FilesChangeLog *log)
{
    NSString *me  = NSBundle.mainBundle.bundleIdentifier;
    NSString *who = files ? @"Files" : @"Finder";

    NSArray *viewer = files_read_prefs(@"NSGlobalDomain", @[@"NSFileViewer"])[@"NSFileViewer"];
    BOOL viewer_me  = [viewer.firstObject isEqual:me];
    [log step:[NSString stringWithFormat:@"Final check: \"Show in Finder\" goes to %@", who]];
    [log note:@"Value" text:value_text(viewer)];
    [log check:viewer && viewer_me == files
          what:files ? @"NSGlobalDomain NSFileViewer names Files"
                     : @"NSGlobalDomain NSFileViewer does not name Files"
        verify:read_command(@"NSGlobalDomain", @"NSFileViewer")];
}

/*
 * files_default_viewer_sync — take_over or give_back on
 * files_background_queue(). Inputs/output are documented in default_viewer.h.
 */
void
files_default_viewer_sync(void (^done)(BOOL ok))
{
    dispatch_async(files_background_queue(), ^{
        BOOL on = [NSUserDefaults.standardUserDefaults boolForKey:files_pref_default_viewer];
        BOOL ok = on ? take_over(nil) : give_back(nil);
        if (!ok) NSLog(@"[default_viewer] could not %@ every setting", on ? @"apply" : @"restore");
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    });
}

/*
 * apply_logged — the body of files_default_viewer_choose's change, run on
 * files_background_queue(): Files' preference, the managed settings
 * (Archive Utility included), then the final checks, all logged.
 *
 * Inputs:
 *   files — YES for Files, NO for Finder
 *   log   — change log to fill
 */
static void
apply_logged(BOOL files, FilesChangeLog *log)
{
    own_pref(files_pref_default_viewer, files,
             @"Files' own setting: default file browser (true = Files, false = Finder)", log);
    if (files) {
        take_over(log);
    } else {
        give_back(log);
    }
    check_final(files, log);
}

/*
 * write_log — writes the finished log to ~/Library/Logs/Files with a
 * header and a summary of every check.
 *
 * Inputs:
 *   files — YES for Files, NO for Finder
 *   log   — filled change log
 *   err   — receives the error if the file could not be written
 *
 * Output: the log file's URL, or nil.
 */
static NSURL *
write_log(BOOL files, FilesChangeLog *log, NSError **err)
{
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory
                                                       inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:log_folder isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES
                                                 attributes:nil error:err]) {
        return nil;
    }
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd-HHmmss";
    NSURL *url = [dir URLByAppendingPathComponent:
                  [NSString stringWithFormat:@"default-file-browser-%@.log", [fmt stringFromDate:now]]];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";

    NSString *who    = files ? @"Files" : @"Finder";
    NSUInteger total = log.checks.count;
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"Files — Set default file browser to %@\n", who];
    [out appendFormat:@"Date:  %@\n", [fmt stringFromDate:now]];
    [out appendFormat:@"App:   %@ (%@)\n", NSBundle.mainBundle.bundlePath,
                      NSBundle.mainBundle.bundleIdentifier];
    [out appendFormat:@"Log:   %@\n\n", url.path];
    [out appendString:@"Every setting Files looked at or changed is listed below, in order, with\n"
                       "its value before and after, the Terminal command that makes the same\n"
                       "change, and whether the new value was confirmed by reading it back.\n"
                       "Both buttons list the same steps and checks in the same order; a\n"
                       "step this change did not need says \"not needed this time\" and why,\n"
                       "and a command marked \"not run\" was not needed.\n"];
    [out appendString:log.text];
    [out appendString:@"\n────────────────────────────────────────────────────────────\n"];
    NSUInteger run = total - log.skipped;
    if (log.failures == 0) {
        [out appendFormat:@"RESULT: SUCCESS — %lu checks: %lu passed, %lu not needed this time.\n"
                           "%@ is the default file browser.\n",
                          (unsigned long)total, (unsigned long)run, (unsigned long)log.skipped, who];
    } else {
        [out appendFormat:@"RESULT: INCOMPLETE — %lu of %lu checks run failed (marked ✗).\n"
                           "Files will try again the next time it opens; you can also click the\n"
                           "button again.\n",
                          (unsigned long)log.failures, (unsigned long)run];
    }
    [out appendString:@"\nChecks (run the \"check\" commands in Terminal to see each value yourself):\n"];
    [out appendString:[log.checks componentsJoinedByString:@"\n"]];
    if (files) {
        [out appendString:@"\n\n\"Show in Finder\" and other reveal requests from other apps open in\n"
                           "Files now, and in zsh, `open <folder>` opens Files in new Terminal\n"
                           "windows. A folder that another app opens (rather than reveals) - a\n"
                           "Dock folder's \"Open in Finder\", a Spotlight result - still opens in\n"
                           "Finder: macOS lets no other app be the default for folders.\n"];
    } else {
        [out appendString:@"\n\n\"Show in Finder\" requests go to Finder now, and `open` in new\n"
                           "Terminal windows is the plain macOS command again. Files can now be\n"
                           "quit and uninstalled.\n"];
    }

    return [out writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:err] ? url : nil;
}

/*
 * files_default_viewer_choose — confirm, apply, log and show a
 * default-viewer choice. Inputs/output are documented in default_viewer.h.
 */
void
files_default_viewer_choose(BOOL files, NSWindow *window, void (^finished)(void))
{
    void (^apply)(void) = ^{
        dispatch_async(files_background_queue(), ^{
            FilesChangeLog *log = [[FilesChangeLog alloc] init];
            apply_logged(files, log);
            NSError *err = nil;
            NSURL *url   = write_log(files, log, &err);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (url) {
                    [NSWorkspace.sharedWorkspace openURL:url];
                } else {
                    files_show_error(@"Files could not write the change log", err, window);
                }
                if (log.failures > 0) {
                    [FilesToolPanel show_message:files ? @"Some settings could not be changed"
                                                       : @"Some settings could not be restored"
                                         message:@"The log lists which ones (marked ✗). Files will "
                                                  "try again the next time it opens."
                                          symbol:@"exclamationmark.triangle.fill"
                                         buttons:@[@"OK"]
                                            over:window
                                         handler:nil];
                }
                if (finished) finished();
            });
        });
    };
    if (files) {
        apply();
        return;
    }

    [FilesToolPanel show_message:@"Restore Finder as the default file browser?"
                         message:@"\"Show in Finder\" requests will go to Finder again, `open` in "
                                  "Terminal loses Files' shell function, and the settings Files "
                                  "changed (desktop icons, Finder's Quit menu item, Archive Utility "
                                  "revealing its results) go back "
                                  "to what they were before Files. Do this before uninstalling "
                                  "Files. A log of every change opens when it is done."
                          symbol:@"questionmark.circle"
                         buttons:@[@"Restore Finder", @"Cancel"]
                            over:window
                         handler:^(NSInteger resp) {
        if (resp == 0) {
            apply();
        } else if (finished) {
            finished();
        }
    }];
}
