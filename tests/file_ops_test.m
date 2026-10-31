/*
 * file_ops_test — exercises the copy engine (FilesFileOps
 * run_copy_srcs:…) against real files in a scratch folder, plus a small
 * HFS+ disk image for moves and validation across volumes. Run with
 * `make test`; prints one line per check and exits non-zero on failure.
 */
#import <Cocoa/Cocoa.h>
#import "file_ops.h"
#include <sys/stat.h>
#include <unistd.h>

static int failures;

/*
 * check — records one test result and prints it.
 *
 * Inputs:
 *   ok   — whether the check passed
 *   what — description
 */
static void
check(BOOL ok, NSString *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

/*
 * transfer — runs the engine on the main thread's behalf and waits for it.
 *
 * Inputs:
 *   srcs     — source URLs
 *   dest     — destination folder
 *   is_cut   — YES = move
 *   hash     — YES = SHA-256 validation
 *   conflict — conflict answer for every clash
 *   log      — receives the transfer log lines; may be nil
 *
 * Output: the engine's error, nil on success.
 */
static NSError *
transfer(NSArray<NSURL *> *srcs, NSURL *dest, BOOL is_cut, BOOL hash,
         FilesConflictResolution conflict, NSMutableArray<NSString *> *log)
{
    __block BOOL done = NO;
    __block NSError *result = nil;
    NSLock *log_lock = [NSLock new];
    [FilesFileOps run_copy_srcs:srcs to:dest is_cut:is_cut hash_validate:hash
                       conflict:^FilesConflictResolution(NSURL *s, NSURL *d) { return conflict; }
                    cancel_flag:NULL progress:nil
                            log:^(NSString *line) {
                                [log_lock lock];
                                [log addObject:line];
                                [log_lock unlock];
                            }
                     completion:^(NSError *err) { result = err; done = YES; }];
    while (!done) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return result;
}

/*
 * write_file — creates a file with the given text.
 *
 * Inputs:
 *   url  — file to write
 *   text — contents
 */
static void
write_file(NSURL *url, NSString *text)
{
    [text writeToURL:url atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

/*
 * read_file — the file's text, or nil.
 *
 * Inputs:
 *   url — file to read
 */
static NSString *
read_file(NSURL *url)
{
    return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
}

/*
 * flags_of — the item's BSD flags (not following symbolic links), or 0.
 *
 * Inputs:
 *   url — item
 */
static u_int
flags_of(NSURL *url)
{
    struct stat st;
    return lstat(url.fileSystemRepresentation, &st) == 0 ? st.st_flags : 0;
}

/*
 * leftovers — names of hidden staging items (".*.files-*") in dir.
 *
 * Inputs:
 *   dir — folder to look in
 *
 * Output: matching names, empty if none.
 */
static NSArray<NSString *> *
leftovers(NSURL *dir)
{
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:nil];
    return [names filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"SELF CONTAINS '.files-'"]];
}

/*
 * log_has — YES if any log line contains text.
 *
 * Inputs:
 *   log  — collected lines
 *   text — text to look for
 */
static BOOL
log_has(NSArray<NSString *> *log, NSString *text)
{
    for (NSString *line in log) {
        if ([line containsString:text]) return YES;
    }
    return NO;
}

int
main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                       URLByAppendingPathComponent:
                           [@"files-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSURL *a = [root URLByAppendingPathComponent:@"a"];
        NSURL *b = [root URLByAppendingPathComponent:@"b"];
        [fm createDirectoryAtURL:a withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtURL:b withIntermediateDirectories:YES attributes:nil error:nil];

        /* Locked file: copied, still locked, nothing left behind. */
        NSURL *locked = [a URLByAppendingPathComponent:@"locked.txt"];
        write_file(locked, @"locked");
        chflags(locked.fileSystemRepresentation, UF_IMMUTABLE);
        NSError *err = transfer(@[locked], b, NO, NO, FilesConflictKeepBoth, nil);
        NSURL *locked_copy = [b URLByAppendingPathComponent:@"locked.txt"];
        check(err == nil, [NSString stringWithFormat:@"copy a locked file (%@)", err]);
        check([read_file(locked_copy) isEqualToString:@"locked"], @"locked copy has the data");
        check((flags_of(locked_copy) & UF_IMMUTABLE) != 0, @"locked copy is still locked");
        check(leftovers(b).count == 0, @"no staging items left after a locked copy");

        /* Locked folder with a locked file inside. */
        NSURL *dir = [a URLByAppendingPathComponent:@"dir"];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:NO attributes:nil error:nil];
        NSURL *inner = [dir URLByAppendingPathComponent:@"inner.txt"];
        write_file(inner, @"inner");
        chflags(inner.fileSystemRepresentation, UF_IMMUTABLE);
        chflags(dir.fileSystemRepresentation, UF_IMMUTABLE);
        err = transfer(@[dir], b, NO, NO, FilesConflictKeepBoth, nil);
        NSURL *dir_copy = [b URLByAppendingPathComponent:@"dir"];
        check(err == nil, [NSString stringWithFormat:@"copy a locked folder (%@)", err]);
        check((flags_of(dir_copy) & UF_IMMUTABLE) != 0, @"locked folder copy is still locked");
        check([read_file([dir_copy URLByAppendingPathComponent:@"inner.txt"])
                  isEqualToString:@"inner"], @"locked folder copy has its contents");
        check(leftovers(b).count == 0, @"no staging items left after a locked folder copy");

        /* Same-volume validation: a clone is hashed like any other copy. */
        NSURL *plain = [a URLByAppendingPathComponent:@"plain.txt"];
        write_file(plain, @"plain data");
        NSMutableArray *log = [NSMutableArray array];
        err = transfer(@[plain], b, NO, YES, FilesConflictKeepBoth, log);
        check(err == nil, @"validated copy on the same volume");
        check(log_has(log, @"SHA-256 match"), @"APFS clone is hashed");
        /* The five steps of one validated file, numbered, plus the job's
         * opening and closing lines and the file's success line. */
        check(log.count == 8, [NSString stringWithFormat:@"validated copy logs five steps (%lu lines)",
                               (unsigned long)log.count]);
        check(log_has(log, @"[1/5] Hashing source") && log_has(log, @"[2/5] Copying")
              && log_has(log, @"[3/5] Hashing the staged copy")
              && log_has(log, @"[4/5] Comparing the hashes")
              && log_has(log, @"[5/5] Hash check passed — renaming the staged file"),
              @"the five steps are logged in the order they run");
        check(log_has(log, @"✓ Copy of \"plain.txt\" successful"), @"the file reports success");

        /* Without validation a file is two steps: copy, then rename. */
        NSURL *quick = [a URLByAppendingPathComponent:@"quick.txt"];
        write_file(quick, @"quick data");
        log = [NSMutableArray array];
        err = transfer(@[quick], b, NO, NO, FilesConflictKeepBoth, log);
        check(err == nil, @"unvalidated copy on the same volume");
        check(log.count == 5, [NSString stringWithFormat:@"unvalidated copy logs two steps (%lu lines)",
                               (unsigned long)log.count]);
        check(log_has(log, @"[1/2] Copying") && log_has(log, @"[2/2] Renaming the staged copy"),
              @"the two steps are logged in the order they run");
        check(!log_has(log, @"SHA-256"), @"nothing is hashed without validation");

        /* Keep Both and duplicate in place. */
        err = transfer(@[plain], b, NO, NO, FilesConflictKeepBoth, nil);
        check(err == nil && [fm fileExistsAtPath:[b URLByAppendingPathComponent:@"plain copy.txt"].path],
              @"Keep Both saves \"plain copy.txt\"");
        err = transfer(@[plain], a, NO, NO, FilesConflictCancel, nil);
        check(err == nil && [fm fileExistsAtPath:[a URLByAppendingPathComponent:@"plain copy.txt"].path],
              @"paste into its own folder duplicates");

        /* Replace keeps nothing of the old item. */
        write_file(plain, @"new data");
        err = transfer(@[plain], b, NO, NO, FilesConflictOverwrite, nil);
        check(err == nil && [read_file([b URLByAppendingPathComponent:@"plain.txt"])
                                isEqualToString:@"new data"], @"Replace puts the new file in place");
        check(leftovers(b).count == 0, @"no items left behind after Replace");

        /* Copy into itself, spelled in another case. */
        NSURL *upper = [[a URLByAppendingPathComponent:@"DIR"] URLByAppendingPathComponent:@"sub"];
        chflags(dir.fileSystemRepresentation, 0);
        [fm createDirectoryAtURL:[dir URLByAppendingPathComponent:@"sub"]
     withIntermediateDirectories:NO attributes:nil error:nil];
        err = transfer(@[dir], upper, NO, NO, FilesConflictKeepBoth, nil);
        check(err != nil && [err.localizedDescription containsString:@"into itself"],
              @"copy a folder into its own subfolder (other case) is refused");

        /* Same-volume move: one rename. */
        NSURL *mv = [a URLByAppendingPathComponent:@"move.txt"];
        write_file(mv, @"move me");
        log = [NSMutableArray array];
        err = transfer(@[mv], b, YES, NO, FilesConflictKeepBoth, log);
        check(err == nil && ![fm fileExistsAtPath:mv.path]
              && [read_file([b URLByAppendingPathComponent:@"move.txt"]) isEqualToString:@"move me"],
              @"same-volume move");
        /* One rename, so the whole job is a single step: the job's own two
         * lines, that step and the file's success line, and nothing else. */
        check(log.count == 4, [NSString stringWithFormat:@"same-volume move is one step (%lu log lines)",
                               (unsigned long)log.count]);
        check([log.firstObject hasPrefix:@"Starting move job:"], @"the log opens with the job");
        check(log_has(log, @"no data copied"), @"same-volume move copies no data");
        check([log.lastObject isEqualToString:@"Move job completed successfully in 0.0 seconds"],
              [NSString stringWithFormat:@"the log closes with the job (%@)", log.lastObject]);

        /* Same-volume move onto an existing item with Replace. */
        write_file(mv, @"replacement");
        err = transfer(@[mv], b, YES, NO, FilesConflictOverwrite, nil);
        check(err == nil && [read_file([b URLByAppendingPathComponent:@"move.txt"])
                                isEqualToString:@"replacement"], @"same-volume move with Replace");
        check(leftovers(b).count == 0, @"no items left behind after a move with Replace");

        /* Another volume: data copy, hashed, then move. */
        NSURL *dmg = [root URLByAppendingPathComponent:@"vol.dmg"];
        NSURL *mnt = [root URLByAppendingPathComponent:@"mnt"];
        NSTask *mk = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/hdiutil"]
            arguments:@[@"create", @"-size", @"8m", @"-fs", @"HFS+", @"-volname", @"filestest",
                        @"-quiet", dmg.path] error:nil terminationHandler:nil];
        [mk waitUntilExit];
        NSTask *at = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/hdiutil"]
            arguments:@[@"attach", @"-quiet", @"-nobrowse", @"-mountpoint", mnt.path, dmg.path]
            error:nil terminationHandler:nil];
        [at waitUntilExit];
        if (at.terminationStatus == 0) {
            log = [NSMutableArray array];
            err = transfer(@[plain], mnt, NO, YES, FilesConflictKeepBoth, log);
            check(err == nil && log_has(log, @"SHA-256 match"), @"validated copy to another volume is hashed");
            NSURL *far = [a URLByAppendingPathComponent:@"far.txt"];
            write_file(far, @"far away");
            err = transfer(@[far], mnt, YES, NO, FilesConflictKeepBoth, nil);
            check(err == nil && ![fm fileExistsAtPath:far.path]
                  && [read_file([mnt URLByAppendingPathComponent:@"far.txt"]) isEqualToString:@"far away"],
                  @"move to another volume");
            NSTask *dt = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/hdiutil"]
                arguments:@[@"detach", @"-quiet", mnt.path] error:nil terminationHandler:nil];
            [dt waitUntilExit];
        } else {
            check(NO, @"attach the test disk image");
        }

        /* Folder size: nested files add up; symbolic links are not followed. */
        NSURL *sized = [root URLByAppendingPathComponent:@"sized"];
        NSURL *deep  = [sized URLByAppendingPathComponent:@"deep"];
        [fm createDirectoryAtURL:deep withIntermediateDirectories:YES attributes:nil error:nil];
        write_file([sized URLByAppendingPathComponent:@"ten"], @"0123456789");
        write_file([deep URLByAppendingPathComponent:@"five"], @"01234");
        [fm createSymbolicLinkAtURL:[sized URLByAppendingPathComponent:@"link"]
                 withDestinationURL:[NSURL fileURLWithPath:@"/System/Library/Kernels/kernel"]
                              error:nil];
        int64_t counted = 0;
        int64_t total   = files_folder_size(sized.fileSystemRepresentation, &counted, NULL);
        check(total == 15, [NSString stringWithFormat:@"folder size adds nested files, skips links (%lld)",
                            (long long)total]);
        check(counted == 2, [NSString stringWithFormat:@"folder size counts the files it added (%lld)",
                             (long long)counted]);
        check(files_folder_size([root URLByAppendingPathComponent:@"missing"].fileSystemRepresentation,
                                NULL, NULL) == -1, @"folder size of a missing folder is -1");

        /* Clean up: unlock everything first. */
        NSDirectoryEnumerator *e = [fm enumeratorAtURL:root includingPropertiesForKeys:nil
                                               options:0 errorHandler:nil];
        chflags(root.fileSystemRepresentation, 0);
        for (NSURL *u in e) lchflags(u.fileSystemRepresentation, 0);
        [fm removeItemAtURL:root error:nil];

        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
