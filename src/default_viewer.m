#import "default_viewer.h"
#import "util.h"
#include <signal.h>
#include <unistd.h>

/* Files' own defaults key holding what the takeover replaced:
 * domain → key → wrapped original (@[value], or @[] if the key was absent),
 * the form files_sync_prefs reports and accepts. */
static NSString * const originals_key = @"files.default_viewer.originals";

/* Files' own defaults key holding the LSHandlers entries for folders that
 * the takeover removed (an empty array if there were none). Present only
 * while Files' entry is installed. */
static NSString * const folder_originals_key = @"files.default_viewer.folder_handlers";

static NSString * const finder_domain = @"com.apple.finder";
static NSString * const finder_path   = @"/System/Library/CoreServices/Finder.app";

/* Archive Utility's preferences (sandboxed: changing them needs Full Disk
 * Access). Its reveal-after keys make it open a Finder window on what it
 * creates or expands: off while Files is the default file viewer, on
 * (Archive Utility's own default) while Finder is. */
static NSString * const archive_utility_domain = @"com.apple.archiveutility";

/* LaunchServices' per-user default-app choices: LSHandlers, an array of
 * { LSHandlerContentType or LSHandlerURLScheme, LSHandlerRole… = bundle ID }.
 * Too large (~0.5 MB) for `defaults write` arguments, so it is edited
 * through CFPreferences, which reaches this non-sandboxed domain. */
static NSString * const ls_domain     = @"com.apple.LaunchServices/com.apple.launchservices.secure";
static NSString * const ls_plist_path = @"~/Library/Preferences/com.apple.LaunchServices/"
                                         "com.apple.launchservices.secure.plist";
static CFStringRef const ls_handlers  = CFSTR("LSHandlers");
static NSString * const folder_type   = @"public.folder";

/* Change logs written by files_default_viewer_choose, under ~/Library/Logs. */
static NSString * const log_folder = @"Logs/Files";

/* Titles of the logged steps both directions share. */
static NSString * const folder_title           = @"Folders opened from other apps — `open "
                                                  "~/Downloads`, Dock folders, Spotlight "
                                                  "(LaunchServices folder handler; takes effect "
                                                  "after you log out and back in)";
static NSString * const originals_title        = @"Files' saved copy of the original values "
                                                  "(saved when Files takes over, used and "
                                                  "removed when Finder is restored)";
static NSString * const folder_originals_title = @"Files' saved copy of the original folder "
                                                  "handler (saved when Files takes over, used "
                                                  "and removed when Finder is restored)";
static NSString * const quit_title             = @"Quit Finder, so it rereads its settings "
                                                  "when it next starts";
static NSString * const launch_title           = @"Start Finder again, so the desktop and "
                                                  "menus show its settings";
static NSString * const quit_command           = @"osascript -e 'quit app \"Finder\"'";
static NSString * const launch_command         = @"open -g -a Finder";

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
 * folder_handlers — reads LSHandlers, split into the entries that choose
 * the default app for folders and all the others.
 *
 * Inputs:
 *   others — if non-NULL, receives every non-folder entry, in order
 *   where  — if non-NULL, receives the folder entries' indexes in LSHandlers
 *
 * Output: the folder entries (possibly empty), or nil if LSHandlers is not
 *         an array.
 */
static NSArray<NSDictionary *> *
folder_handlers(NSMutableArray **others, NSIndexSet **where)
{
    id all = CFBridgingRelease(CFPreferencesCopyAppValue(ls_handlers, (__bridge CFStringRef)ls_domain));
    if (all && ![all isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *folder = [NSMutableArray array], *rest = [NSMutableArray array];
    NSMutableIndexSet *at  = [NSMutableIndexSet indexSet];
    NSUInteger i = 0;
    for (id entry in all) {
        BOOL is_folder = [entry isKindOfClass:NSDictionary.class] &&
                         [entry[@"LSHandlerContentType"] isEqual:folder_type];
        if (is_folder) [at addIndex:i];
        [(is_folder ? folder : rest) addObject:entry];
        i++;
    }
    if (others) *others = rest;
    if (where)  *where  = at;
    return folder;
}

/*
 * names_files — whether a LaunchServices handler entry sends its type to
 * Files.
 *
 * Inputs:
 *   entry — LSHandlers entry
 *
 * Output: YES if LSHandlerRoleAll or LSHandlerRoleViewer names Files.
 */
static BOOL
names_files(NSDictionary *entry)
{
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    return [entry[@"LSHandlerRoleAll"] isEqual:me] || [entry[@"LSHandlerRoleViewer"] isEqual:me];
}

/*
 * handlers_text — folder entries for the log.
 *
 * Inputs:
 *   entries — folder entries; nil = could not be read
 *
 * Output: one line per entry naming the app, or what an empty list means.
 */
static NSString *
handlers_text(NSArray<NSDictionary *> *entries)
{
    if (!entries)            return @"(could not be read)";
    if (entries.count == 0)  return @"(no entry — macOS uses Finder)";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *e in entries) {
        NSString *app = e[@"LSHandlerRoleAll"] ?: e[@"LSHandlerRoleViewer"] ?: @"?";
        [lines addObject:[NSString stringWithFormat:@"public.folder → %@", app]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

/*
 * folder_setting_text — the folder handler setting's name, for the log.
 *
 * Output: domain, key and which entries.
 */
static NSString *
folder_setting_text(void)
{
    return [ls_domain stringByAppendingString:@" LSHandlers (public.folder entries)"];
}

/*
 * folder_read_command — the Terminal command that shows the folder
 * handler entries.
 *
 * Output: the command line.
 */
static NSString *
folder_read_command(void)
{
    return [NSString stringWithFormat:@"defaults read %@ LSHandlers | grep -B1 -A4 public.folder",
            ls_domain];
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
 * set_folder_handlers — makes entries the only folder entries in
 * LSHandlers, leaving every other entry as it is. LaunchServices reads the
 * file at login, so the change takes effect after logging out and in.
 *
 * Inputs:
 *   entries — folder entries to install (empty: none, i.e. Finder)
 *   log     — change log; may be nil
 *
 * Output: YES if LSHandlers now holds exactly these folder entries.
 */
static BOOL
set_folder_handlers(NSArray<NSDictionary *> *entries, FilesChangeLog *log)
{
    NSMutableArray *others = nil;
    NSIndexSet *where      = nil;
    NSArray *current = folder_handlers(&others, &where);
    BOOL needed = current && ![current isEqualToArray:entries];
    if (needed) {
        [others addObjectsFromArray:entries];
        CFPreferencesSetAppValue(ls_handlers, (__bridge CFArrayRef)others,
                                 (__bridge CFStringRef)ls_domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)ls_domain);
    }
    NSArray *after = folder_handlers(NULL, NULL);
    BOOL ok = [after isEqualToArray:entries];
    if (!log) return ok;

    /* The same edit by hand: PlistBuddy removes array items (defaults
     * cannot), then cfprefsd is restarted so it rereads the file before
     * defaults appends the new entries. */
    NSMutableArray<NSString *> *cmds = [NSMutableArray array];
    [where enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger i, BOOL *stop) {
        [cmds addObject:[NSString stringWithFormat:@"/usr/libexec/PlistBuddy -c 'Delete :LSHandlers:%lu' %@",
                         (unsigned long)i, ls_plist_path]];
    }];
    if (cmds.count > 0) [cmds addObject:@"killall cfprefsd"];
    for (NSDictionary *e in entries) {
        [cmds addObject:[NSString stringWithFormat:@"defaults write %@ LSHandlers -array-add %@",
                         ls_domain, shell_quote(plist_text(e))]];
    }
    if (cmds.count == 0) [cmds addObject:@"(none)"];

    BOOL to_files = entries.count > 0;
    [log step:folder_title];
    [log note:@"Setting" text:folder_setting_text()];
    [log note:@"Before" text:handlers_text(current)];
    [log note:@"After" text:handlers_text(after)];
    NSString *cmd_text = [cmds componentsJoinedByString:@"\n"];
    [log note:@"Command" text:needed ? cmd_text : @"(none run: already set)"];
    [log check:ok
          what:to_files ? @"Folders open in Files (after you log out and back in)"
                        : @"No folder handler entry left from Files (folders open in Finder "
                           "after you log out and back in)"
        verify:folder_read_command()];
    return ok;
}

/*
 * take_over_folders — makes Files the default app for folders in
 * LSHandlers (the approach ForkLift documents; the LaunchServices API
 * rejects public.folder). On the first change it records the folder
 * entries it replaced, less any of Files' own (so a lost record is never
 * rebuilt from Files' entry).
 *
 * Inputs:
 *   log — change log; may be nil
 *
 * Output: YES if Files' entry is installed.
 */
static BOOL
take_over_folders(FilesChangeLog *log)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *me       = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *mine = @{ @"LSHandlerContentType":       folder_type,
                            @"LSHandlerRoleAll":           me,
                            @"LSHandlerPreferredVersions": @{ @"LSHandlerRoleAll": @"-" } };
    NSArray *current   = folder_handlers(NULL, NULL);
    BOOL recorded      = [defaults arrayForKey:folder_originals_key] != nil;
    BOOL record        = current && ![current isEqualToArray:@[mine]] && !recorded;

    BOOL ok = set_folder_handlers(@[mine], log);
    if (!record) {
        skip_step(folder_originals_title, defaults_command(me, folder_originals_key, @[@[]]),
                  @"Original folder handler saved in Files' preferences",
                  recorded ? @"it was saved earlier, and is kept until Finder is restored"
                  : current ? @"Files already handles folders, so there is nothing to save"
                            : @"LaunchServices' settings could not be read", log);
        return ok;
    }

    NSArray *saved = [current filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *b) {
        return !names_files(e);
    }]];
    [defaults setObject:saved forKey:folder_originals_key];
    [log step:folder_originals_title];
    [log note:@"Saved" text:handlers_text(saved)];
    [log note:@"Command" text:defaults_command(me, folder_originals_key, @[saved])];
    [log check:[[defaults arrayForKey:folder_originals_key] isEqualToArray:saved]
          what:@"Original folder handler saved in Files' preferences"
        verify:read_command(me, folder_originals_key)];
    return ok;
}

/*
 * give_back_folders — puts back the folder entries take_over_folders
 * recorded, then forgets the record (kept if the write failed). With no
 * record, the folder handler is left as it is.
 *
 * Inputs:
 *   log — change log; may be nil
 *
 * Output: YES if nothing was recorded or the originals are back.
 */
static BOOL
give_back_folders(FilesChangeLog *log)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *me       = NSBundle.mainBundle.bundleIdentifier;
    NSArray *originals = [defaults arrayForKey:folder_originals_key];
    NSString *forget   = defaults_command(me, folder_originals_key, @[]);
    if (!originals) {
        [log step:folder_title];
        [log note:@"Setting" text:folder_setting_text()];
        [log note:@"Value" text:handlers_text(folder_handlers(NULL, NULL))];
        [log note:@"Command" text:@"(none run)"];
        [log skip:@"Original folder handler put back"
              why:@"Files has no saved folder handler, so it did not change it"];
        skip_step(folder_originals_title, forget,
                  @"Saved folder handler removed from Files' preferences",
                  @"nothing was saved", log);
        return YES;
    }

    BOOL ok = set_folder_handlers(originals, log);
    if (!ok) {
        skip_step(folder_originals_title, forget,
                  @"Saved folder handler removed from Files' preferences",
                  @"kept, because the folder handler could not be put back; Files tries "
                   "again the next time it opens", log);
        return NO;
    }
    [defaults removeObjectForKey:folder_originals_key];
    [log step:folder_originals_title];
    [log note:@"Command" text:forget];
    [log check:[defaults objectForKey:folder_originals_key] == nil
          what:@"Saved folder handler removed from Files' preferences"
        verify:read_command(me, folder_originals_key)];
    return YES;
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
 * Also makes Files the default app for folders (take_over_folders) and
 * stops Archive Utility opening Finder on its results. Quits Finder if one
 * of its settings changed, since Finder reads them only at launch; it
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

    ok = take_over_folders(log) && ok;
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
 * give_back — writes every recorded original back, including the folder
 * handlers (give_back_folders), then forgets the records (kept if a write
 * failed, so the next sync retries), and turns Archive Utility's
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

    ok = give_back_folders(log) && ok;
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
 * check_final — confirms, whatever was recorded, that both settings that
 * send files and folders to an app name the chosen one: Files, or (for
 * Finder) anything but Files.
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

    NSArray<NSDictionary *> *handlers = folder_handlers(NULL, NULL);
    BOOL handlers_me = NO;
    for (NSDictionary *e in handlers) handlers_me = handlers_me || names_files(e);
    [log step:[NSString stringWithFormat:@"Final check: folders go to %@ "
                                          "(after you log out and back in)", who]];
    [log note:@"Value" text:handlers_text(handlers)];
    [log check:handlers && handlers_me == files
          what:files ? @"A LaunchServices folder handler names Files"
                     : @"No LaunchServices folder handler names Files"
        verify:folder_read_command()];
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
    [out appendString:files
        ? @"\n\n\"Show in Finder\" requests from other apps open in Files now. Folders opened\n"
           "from other apps open in Files after you log out and back in.\n"
        : @"\n\n\"Show in Finder\" requests go to Finder now. Folders opened from other apps\n"
           "open in Finder after you log out and back in. Files can now be quit and\n"
           "uninstalled.\n"];

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
                    NSAlert *alert        = files_new_alert();
                    alert.messageText     = files ? @"Some settings could not be changed"
                                                  : @"Some settings could not be restored";
                    alert.informativeText = @"The log lists which ones (marked ✗). Files will "
                                             "try again the next time it opens.";
                    files_present_alert(alert, window, nil);
                }
                if (finished) finished();
            });
        });
    };
    if (files) {
        apply();
        return;
    }

    NSAlert *alert = files_new_alert();
    alert.messageText     = @"Restore Finder as the default file browser?";
    alert.informativeText = @"\"Show in Finder\" requests and opened folders will go to Finder "
                             "again, and the settings Files changed (desktop icons, Finder's "
                             "Quit menu item, Archive Utility revealing its results) go back "
                             "to what they were before Files. Do this before uninstalling "
                             "Files. A log of every change opens when it is done.";
    [alert addButtonWithTitle:@"Restore Finder"];
    [alert addButtonWithTitle:@"Cancel"];
    files_present_alert(alert, window, ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) {
            apply();
        } else if (finished) {
            finished();
        }
    });
}
