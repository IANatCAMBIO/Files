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

/* LaunchServices' per-user default-app choices: LSHandlers, an array of
 * { LSHandlerContentType or LSHandlerURLScheme, LSHandlerRole… = bundle ID }.
 * Too large (~0.5 MB) for `defaults write` arguments, so it is edited
 * through CFPreferences, which reaches this non-sandboxed domain. */
static CFStringRef const ls_domain    = CFSTR("com.apple.LaunchServices/com.apple.launchservices.secure");
static CFStringRef const ls_handlers  = CFSTR("LSHandlers");
static NSString * const folder_type   = @"public.folder";

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
 * quit_finder — asks Finder to quit (a clean quit, so launchd does not
 * restart it) and waits up to five seconds for it to exit. Blocks.
 *
 * Output: YES if Finder is no longer running.
 */
static BOOL
quit_finder(void)
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
    return gone;
}

/*
 * launch_finder — starts Finder in the background (it redraws the desktop
 * with whatever settings it now reads).
 */
static void
launch_finder(void)
{
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:finder_path]
                                        configuration:cfg
                                    completionHandler:nil];
}

/*
 * folder_handlers — reads LSHandlers, split into the entries that choose
 * the default app for folders and all the others.
 *
 * Inputs:
 *   others — if non-NULL, receives every non-folder entry, in order
 *
 * Output: the folder entries (possibly empty), or nil if LSHandlers is not
 *         an array.
 */
static NSArray<NSDictionary *> *
folder_handlers(NSMutableArray **others)
{
    id all = CFBridgingRelease(CFPreferencesCopyAppValue(ls_handlers, ls_domain));
    if (all && ![all isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *folder = [NSMutableArray array], *rest = [NSMutableArray array];
    for (id entry in all) {
        BOOL is_folder = [entry isKindOfClass:NSDictionary.class] &&
                         [entry[@"LSHandlerContentType"] isEqual:folder_type];
        [(is_folder ? folder : rest) addObject:entry];
    }
    if (others) *others = rest;
    return folder;
}

/*
 * set_folder_handlers — makes entries the only folder entries in
 * LSHandlers, leaving every other entry as it is. LaunchServices reads the
 * file at login, so the change takes effect after logging out and in.
 *
 * Inputs:
 *   entries — folder entries to install (empty: none, i.e. Finder)
 *
 * Output: YES if LSHandlers now holds exactly these folder entries.
 */
static BOOL
set_folder_handlers(NSArray<NSDictionary *> *entries)
{
    NSMutableArray *others = nil;
    NSArray *current = folder_handlers(&others);
    if (!current) return NO;
    if ([current isEqualToArray:entries]) return YES;

    [others addObjectsFromArray:entries];
    CFPreferencesSetAppValue(ls_handlers, (__bridge CFArrayRef)others, ls_domain);
    return CFPreferencesAppSynchronize(ls_domain);
}

/*
 * take_over_folders — makes Files the default app for folders in
 * LSHandlers (the approach ForkLift documents; the LaunchServices API
 * rejects public.folder). Before the first change it records the folder
 * entries it replaces, less any of Files' own (so a lost record is never
 * rebuilt from Files' entry).
 *
 * Output: YES if Files' entry is installed.
 */
static BOOL
take_over_folders(void)
{
    NSString *me       = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *mine = @{ @"LSHandlerContentType":       folder_type,
                            @"LSHandlerRoleAll":           me,
                            @"LSHandlerPreferredVersions": @{ @"LSHandlerRoleAll": @"-" } };
    NSArray *current = folder_handlers(NULL);
    if (!current) return NO;
    if ([current isEqualToArray:@[mine]]) return YES;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults arrayForKey:folder_originals_key]) {
        NSPredicate *not_mine = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *b) {
            return ![e[@"LSHandlerRoleAll"] isEqual:me] && ![e[@"LSHandlerRoleViewer"] isEqual:me];
        }];
        [defaults setObject:[current filteredArrayUsingPredicate:not_mine]
                     forKey:folder_originals_key];
    }
    return set_folder_handlers(@[mine]);
}

/*
 * give_back_folders — puts back the folder entries take_over_folders
 * recorded, then forgets the record (kept if the write failed).
 *
 * Output: YES if nothing was recorded or the originals are back.
 */
static BOOL
give_back_folders(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *originals = [defaults arrayForKey:folder_originals_key];
    if (!originals) return YES;
    if (!set_folder_handlers(originals)) return NO;
    [defaults removeObjectForKey:folder_originals_key];
    return YES;
}

/*
 * take_over — makes every managed setting hold Files' value, recording the
 * value each one replaced unless a record already exists (the first
 * original wins, so re-applying after something reset a key keeps the
 * pre-Files value). Records are saved per domain as soon as it is written.
 * Also makes Files the default app for folders (take_over_folders).
 * Quits Finder if one of its settings changed, since Finder reads them
 * only at launch; it stays quit until something asks for it.
 *
 * Output: YES if every setting now holds Files' value.
 */
static BOOL
take_over(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *originals = [[defaults dictionaryForKey:originals_key] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
    NSDictionary *managed = managed_prefs();
    BOOL ok = YES, finder_changed = NO;

    for (NSString *domain in managed) {
        NSMutableDictionary *replaced = [NSMutableDictionary dictionary];
        ok = files_sync_prefs(domain, managed[domain], replaced) && ok;
        if (replaced.count == 0) continue;

        NSMutableDictionary *saved = [originals[domain] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
        for (NSString *key in replaced) {
            if (!saved[key]) saved[key] = replaced[key];
        }
        originals[domain] = saved;
        [defaults setObject:originals forKey:originals_key];
        if ([domain isEqualToString:finder_domain]) finder_changed = YES;
    }
    ok = take_over_folders() && ok;

    if (finder_changed) quit_finder();
    return ok;
}

/*
 * give_back — writes every recorded original back, including the folder
 * handlers (give_back_folders), then forgets the records (kept if a write
 * failed, so the next sync retries). Restarts
 * Finder if one of its settings changed, so the desktop and menus match.
 *
 * Output: YES if every recorded setting was restored.
 */
static BOOL
give_back(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *originals  = [defaults dictionaryForKey:originals_key];
    BOOL ok = YES, finder_changed = NO;

    for (NSString *domain in originals) {
        NSMutableDictionary *changed = [NSMutableDictionary dictionary];
        ok = files_sync_prefs(domain, originals[domain], changed) && ok;
        if (changed.count > 0 && [domain isEqualToString:finder_domain]) finder_changed = YES;
    }
    if (ok) [defaults removeObjectForKey:originals_key];
    ok = give_back_folders() && ok;

    if (finder_changed) {
        quit_finder();
        launch_finder();
    }
    return ok;
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
        BOOL ok = on ? take_over() : give_back();
        if (!ok) NSLog(@"[default_viewer] could not %@ every setting", on ? @"apply" : @"restore");
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    });
}

/*
 * files_default_viewer_choose — confirm, apply and report a default-viewer
 * choice. Inputs/output are documented in default_viewer.h.
 */
void
files_default_viewer_choose(BOOL files, NSWindow *window, void (^finished)(void))
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:files_pref_default_viewer] == files) {
        if (finished) finished();
        return;
    }

    void (^apply)(void) = ^{
        [defaults setBool:files forKey:files_pref_default_viewer];
        [defaults setBool:!files forKey:files_pref_archive_reveal];
        files_default_viewer_sync(^(BOOL ok) {
            NSAlert *done = files_new_alert();
            if (!ok) {
                done.messageText     = files ? @"Some settings could not be changed"
                                             : @"Some settings could not be restored";
                done.informativeText = @"Files will try again the next time it opens.";
            } else if (files) {
                done.messageText     = @"Files is the default file viewer";
                done.informativeText = @"\"Show in Finder\" requests from other apps now open "
                                        "in Files. Folders opened from other apps open in "
                                        "Files after you log out and back in.";
            } else {
                done.messageText     = @"Finder is the default file viewer again";
                done.informativeText = @"Every setting Files changed has been put back. "
                                        "You can now quit and uninstall Files; folders "
                                        "open in Finder again after you log out and back in.";
            }
            files_present_alert(done, window, nil);
            if (finished) finished();
        });
    };
    if (files) {
        apply();
        return;
    }

    NSAlert *alert = files_new_alert();
    alert.messageText     = @"Restore Finder as the default file viewer?";
    alert.informativeText = @"\"Show in Finder\" requests and opened folders will go to Finder "
                             "again, and the settings Files changed (desktop icons, Finder's "
                             "Quit menu item, Archive Utility revealing its results) go back "
                             "to what they were before Files. Do this before uninstalling "
                             "Files.";
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
