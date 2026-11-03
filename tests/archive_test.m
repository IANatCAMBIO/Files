/*
 * archive_test — exercises FilesArchive (creating zip, tar.gz and tar,
 * passwords, name clashes, bad input) against real files in a scratch
 * folder. Files does not expand archives — a double-click hands them to
 * their default application — so what it creates is checked by unpacking it
 * with the system tool. Run with `make test`; prints one line per check and
 * exits non-zero on failure.
 */
#import <Cocoa/Cocoa.h>
#import "archive.h"
#include <sys/stat.h>
#include <sys/xattr.h>
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
 * spin_until — runs the main run loop until *done is set.
 *
 * Inputs:
 *   done — flag the completion block sets
 */
static void
spin_until(BOOL *done)
{
    while (!*done) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

/*
 * make_archive — creates an archive and waits for it.
 *
 * Inputs:
 *   items    — items to archive
 *   name     — archive file name
 *   format   — archive format
 *   password — password, or nil
 *   err      — receives the error on failure
 *
 * Output: the archive URL, or nil.
 */
static NSURL *
make_archive(NSArray<NSURL *> *items, NSString *name, FilesArchiveFormat format,
             NSString *password, NSError **err)
{
    __block BOOL done = NO;
    __block NSURL *result = nil;
    __block NSError *error = nil;
    [FilesArchive create_from:items name:name format:format password:password
                   completion:^(NSURL *archive, NSError *e) {
        result = archive;
        error  = e;
        done   = YES;
    }];
    spin_until(&done);
    if (err) *err = error;
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
 * archive_listing — entry names in an archive, as the system tool lists
 * them, one per line.
 *
 * Inputs:
 *   archive — archive file URL
 *   format  — its format
 *
 * Output: the listing, or nil if the tool could not be run.
 */
static NSString *
archive_listing(NSURL *archive, FilesArchiveFormat format)
{
    BOOL zip = format == FilesArchiveFormatZip;
    NSPipe *out = [NSPipe pipe];
    NSTask *t   = [[NSTask alloc] init];
    t.executableURL  = [NSURL fileURLWithPath:zip ? @"/usr/bin/unzip" : @"/usr/bin/tar"];
    t.arguments      = zip ? @[@"-Z1", archive.path] : @[@"-tf", archive.path];
    t.standardOutput = out;
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/*
 * expand_with_tool — unpacks an archive with /usr/bin/unzip or /usr/bin/tar.
 * Files itself never expands one, so this is how a test checks that what it
 * created is a sound archive. stdin is /dev/null, so a tool that asks for a
 * password fails instead of waiting.
 *
 * Inputs:
 *   archive  — archive file URL
 *   format   — its format
 *   dest     — an existing folder to unpack into
 *   password — for an encrypted zip; nil for none
 *
 * Output: YES if the tool exited 0.
 */
static BOOL
expand_with_tool(NSURL *archive, FilesArchiveFormat format, NSURL *dest, NSString *password)
{
    BOOL zip = format == FilesArchiveFormatZip;
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    if (zip) {
        [args addObject:@"-q"];
        if (password.length > 0) [args addObjectsFromArray:@[@"-P", password]];
        [args addObjectsFromArray:@[archive.path, @"-d", dest.path]];
    } else {
        [args addObjectsFromArray:@[@"-xf", archive.path, @"-C", dest.path]];
    }

    NSTask *t = [[NSTask alloc] init];
    t.executableURL  = [NSURL fileURLWithPath:zip ? @"/usr/bin/unzip" : @"/usr/bin/tar"];
    t.arguments      = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput  = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return NO;
    [t waitUntilExit];
    return t.terminationStatus == 0;
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
 * make_dir — creates a folder (and parents).
 *
 * Inputs:
 *   url — folder to create
 *
 * Output: url.
 */
static NSURL *
make_dir(NSURL *url)
{
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    return url;
}

/*
 * link_target — where a symbolic link points.
 *
 * Inputs:
 *   url — the link
 *
 * Output: its target text, or nil if url is not a link.
 */
static NSString *
link_target(NSURL *url)
{
    return [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:url.path error:nil];
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:
             [NSString stringWithFormat:@"archive_test_%d", getpid()]]];
        root = [NSURL fileURLWithPath:root.path.stringByResolvingSymlinksInPath];
        make_dir(root);

        /* A source tree with a folder, a symbolic link, a space and a dash-led name. */
        NSURL *src  = make_dir([root URLByAppendingPathComponent:@"src"]);
        NSURL *proj = make_dir([src URLByAppendingPathComponent:@"proj"]);
        write_file([proj URLByAppendingPathComponent:@"inner.txt"], @"inner");
        [fm createSymbolicLinkAtPath:[proj URLByAppendingPathComponent:@"link"].path
                 withDestinationPath:@"inner.txt" error:nil];
        write_file([src URLByAppendingPathComponent:@"-dash file.txt"], @"dash");
        write_file([src URLByAppendingPathComponent:@"top.txt"], @"top");
        NSArray<NSURL *> *both = @[proj, [src URLByAppendingPathComponent:@"-dash file.txt"]];

        struct { NSString *name; FilesArchiveFormat format; } formats[] = {
            { @"set.zip",    FilesArchiveFormatZip },
            { @"set.tar.gz", FilesArchiveFormatTarGz },
            { @"set.tar",    FilesArchiveFormatTar },
        };
        for (int i = 0; i < 3; i++) {
            NSString *name = formats[i].name;
            NSError *err = nil;
            NSURL *archive = make_archive(both, name, formats[i].format, nil, &err);
            check(archive && !err && [fm fileExistsAtPath:archive.path],
                  [NSString stringWithFormat:@"%@: create", name]);

            NSURL *out = make_dir([root URLByAppendingPathComponent:
                                   [NSString stringWithFormat:@"out%d", i]]);
            check(expand_with_tool(archive, formats[i].format, out, nil),
                  [NSString stringWithFormat:@"%@: the system tool unpacks it", name]);
            check([read_file([out URLByAppendingPathComponent:@"proj/inner.txt"]) isEqualToString:@"inner"]
                  && [read_file([out URLByAppendingPathComponent:@"-dash file.txt"]) isEqualToString:@"dash"],
                  [NSString stringWithFormat:@"%@: files round-trip", name]);
            check([link_target([out URLByAppendingPathComponent:@"proj/link"])
                   isEqualToString:@"inner.txt"],
                  [NSString stringWithFormat:@"%@: symbolic link kept as a link", name]);
            check(leftovers(src).count == 0,
                  [NSString stringWithFormat:@"%@: no staging items left", name]);
        }

        /* A tar has no ._ entries for extended attributes. */
        NSURL *xa = [src URLByAppendingPathComponent:@"top.txt"];
        setxattr(xa.fileSystemRepresentation, "user.test", "v", 1, 0, 0);
        NSURL *xtar = make_archive(@[xa], @"xa.tar", FilesArchiveFormatTar, nil, NULL);
        check([archive_listing(xtar, FilesArchiveFormatTar) isEqualToString:@"top.txt\n"],
              @"tar holds no ._ metadata entries");

        NSError *err = nil;
        /* Passwords. */
        NSString *pw = @"p@ss \"word\" 1!";
        NSURL *enc = make_archive(both, @"secret.zip", FilesArchiveFormatZip, pw, &err);
        check(enc != nil, @"encrypted zip: create");
        NSURL *enc_dir = make_dir([root URLByAppendingPathComponent:@"enc"]);
        check(!expand_with_tool(enc, FilesArchiveFormatZip, enc_dir, nil),
              @"encrypted zip: no password does not open it");
        check(!expand_with_tool(enc, FilesArchiveFormatZip, enc_dir, @"wrong"),
              @"encrypted zip: the wrong password does not open it");
        NSURL *enc_ok = make_dir([root URLByAppendingPathComponent:@"enc_ok"]);
        check(expand_with_tool(enc, FilesArchiveFormatZip, enc_ok, pw)
              && [read_file([enc_ok URLByAppendingPathComponent:@"-dash file.txt"])
                  isEqualToString:@"dash"],
              @"encrypted zip: the right password opens it");

        /* Refusals. */
        NSURL *bad = make_archive(both, @"bad.tar.gz", FilesArchiveFormatTarGz, @"x", &err);
        check(!bad && err.code == FilesArchiveErrorFailed
              && ![fm fileExistsAtPath:[src URLByAppendingPathComponent:@"bad.tar.gz"].path],
              @"tar.gz refuses a password");
        NSURL *clash = [src URLByAppendingPathComponent:@"clash.zip"];
        write_file(clash, @"precious");
        NSURL *over = make_archive(@[xa], @"clash.zip", FilesArchiveFormatZip, nil, &err);
        check(!over && [read_file(clash) isEqualToString:@"precious"],
              @"create never overwrites an existing file");
        NSURL *elsewhere = make_dir([root URLByAppendingPathComponent:@"elsewhere"]);
        write_file([elsewhere URLByAppendingPathComponent:@"e.txt"], @"e");
        NSURL *mixed = make_archive(@[xa, [elsewhere URLByAppendingPathComponent:@"e.txt"]],
                                    @"mixed.zip", FilesArchiveFormatZip, nil, &err);
        check(!mixed, @"items from different folders are refused");
        check(leftovers(src).count == 0 && leftovers(elsewhere).count == 0,
              @"refusals leave no staging items");

        /* Awkward archive names. */
        NSURL *odd = make_dir([root URLByAppendingPathComponent:@"odd"]);
        write_file([odd URLByAppendingPathComponent:@"o.txt"], @"o");
        NSURL *odd_zip = make_archive(@[[odd URLByAppendingPathComponent:@"o.txt"]],
                                      @"a[1] café *.zip", FilesArchiveFormatZip, nil, &err);
        NSURL *odd_out = make_dir([root URLByAppendingPathComponent:@"odd_out"]);
        check(odd_zip && expand_with_tool(odd_zip, FilesArchiveFormatZip, odd_out, nil)
              && [read_file([odd_out URLByAppendingPathComponent:@"o.txt"]) isEqualToString:@"o"],
              @"archive names with brackets, accents and * work");

        [fm removeItemAtURL:root error:nil];
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
