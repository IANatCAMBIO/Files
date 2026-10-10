/*
 * archive_test — exercises FilesArchive (create and extract zip, tar.gz and
 * tar, passwords, name clashes, bad input) against real files in a scratch
 * folder. Run with `make test`; prints one line per check and exits
 * non-zero on failure.
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
 * extract_archive — expands an archive and waits for it.
 *
 * Inputs:
 *   archive  — archive URL
 *   password — password, or nil
 *   err      — receives the error on failure
 *
 * Output: the new folder, or nil.
 */
static NSURL *
extract_archive(NSURL *archive, NSString *password, NSError **err)
{
    __block BOOL done = NO;
    __block NSURL *result = nil;
    __block NSError *error = nil;
    [FilesArchive extract:archive password:password completion:^(NSURL *folder, NSError *e) {
        result = folder;
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

        check([FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/a.zip"]]
              && [FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/a.tar"]]
              && [FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/a.tar.gz"]]
              && [FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/A.TGZ"]],
              @"zip, tar, tar.gz and tgz names are archives");
        check(![FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/a.gz"]]
              && ![FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/zip"]]
              && ![FilesArchive is_archive:[NSURL fileURLWithPath:@"/x/a.zip.txt"]],
              @"other names are not");

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
            NSURL *moved = [out URLByAppendingPathComponent:name];
            [fm moveItemAtURL:archive toURL:moved error:nil];
            NSURL *folder = extract_archive(moved, nil, &err);
            NSURL *base   = [out URLByAppendingPathComponent:@"set"];
            check(folder && [folder.path isEqualToString:base.path],
                  [NSString stringWithFormat:@"%@: extracts to a folder named after it", name]);
            check([read_file([base URLByAppendingPathComponent:@"proj/inner.txt"]) isEqualToString:@"inner"]
                  && [read_file([base URLByAppendingPathComponent:@"-dash file.txt"]) isEqualToString:@"dash"],
                  [NSString stringWithFormat:@"%@: files round-trip", name]);
            check([link_target([base URLByAppendingPathComponent:@"proj/link"])
                   isEqualToString:@"inner.txt"],
                  [NSString stringWithFormat:@"%@: symbolic link kept as a link", name]);
            check(leftovers(out).count == 0 && leftovers(src).count == 0,
                  [NSString stringWithFormat:@"%@: no staging items left", name]);

            NSURL *again = extract_archive(moved, nil, &err);
            check(again && [again.lastPathComponent isEqualToString:@"set 2"],
                  [NSString stringWithFormat:@"%@: a taken name gets \" 2\"", name]);
        }

        /* A tar has no ._ entries for extended attributes. */
        NSURL *xa = [src URLByAppendingPathComponent:@"top.txt"];
        setxattr(xa.fileSystemRepresentation, "user.test", "v", 1, 0, 0);
        NSURL *xtar = make_archive(@[xa], @"xa.tar", FilesArchiveFormatTar, nil, NULL);
        NSData *listing = nil;
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
        t.arguments     = @[@"-tf", xtar.path];
        NSPipe *p       = [NSPipe pipe];
        t.standardOutput = p;
        [t launchAndReturnError:nil];
        listing = [p.fileHandleForReading readDataToEndOfFile];
        [t waitUntilExit];
        NSString *names = [[NSString alloc] initWithData:listing encoding:NSUTF8StringEncoding];
        check([names isEqualToString:@"top.txt\n"], @"tar holds no ._ metadata entries");

        /* A single top-level folder is the result itself, not wrapped again. */
        NSError *err = nil;
        NSURL *one = make_archive(@[proj], @"whatever.zip", FilesArchiveFormatZip, nil, &err);
        NSURL *dest = make_dir([root URLByAppendingPathComponent:@"single"]);
        NSURL *one_moved = [dest URLByAppendingPathComponent:@"whatever.zip"];
        [fm moveItemAtURL:one toURL:one_moved error:nil];
        NSURL *unwrapped = extract_archive(one_moved, nil, &err);
        check(unwrapped && [unwrapped.lastPathComponent isEqualToString:@"proj"]
              && [read_file([unwrapped URLByAppendingPathComponent:@"inner.txt"]) isEqualToString:@"inner"],
              @"a lone top-level folder is not wrapped in another");
        struct stat st;
        stat(unwrapped.fileSystemRepresentation, &st);
        check((st.st_mode & 0700) == 0700 && (st.st_mode & 0055) != 0,
              @"extracted folder has ordinary permissions");

        /* A zip with a Finder-style __MACOSX folder drops it. */
        NSURL *mac = make_dir([root URLByAppendingPathComponent:@"mac"]);
        NSURL *mac_src = make_dir([mac URLByAppendingPathComponent:@"s"]);
        write_file([mac_src URLByAppendingPathComponent:@"f.txt"], @"f");
        make_dir([mac_src URLByAppendingPathComponent:@"__MACOSX"]);
        write_file([mac_src URLByAppendingPathComponent:@"__MACOSX/._f.txt"], @"meta");
        NSURL *mac_zip = make_archive(@[[mac_src URLByAppendingPathComponent:@"f.txt"],
                                        [mac_src URLByAppendingPathComponent:@"__MACOSX"]],
                                      @"mac.zip", FilesArchiveFormatZip, nil, &err);
        NSURL *mac_out = extract_archive(mac_zip, nil, &err);
        check(mac_out && [fm fileExistsAtPath:[mac_out URLByAppendingPathComponent:@"f.txt"].path]
              && ![fm fileExistsAtPath:[mac_out URLByAppendingPathComponent:@"__MACOSX"].path],
              @"__MACOSX metadata is not extracted");

        /* Passwords. */
        NSString *pw = @"p@ss \"word\" 1!";
        NSURL *enc = make_archive(both, @"secret.zip", FilesArchiveFormatZip, pw, &err);
        check(enc != nil, @"encrypted zip: create");
        NSURL *enc_dir = make_dir([root URLByAppendingPathComponent:@"enc"]);
        NSURL *enc_moved = [enc_dir URLByAppendingPathComponent:@"secret.zip"];
        [fm moveItemAtURL:enc toURL:enc_moved error:nil];

        NSURL *r = extract_archive(enc_moved, nil, &err);
        check(!r && [err.domain isEqualToString:FilesArchiveErrorDomain]
              && err.code == FilesArchiveErrorPasswordRequired,
              @"encrypted zip: no password is reported as required");
        r = extract_archive(enc_moved, @"wrong", &err);
        check(!r && err.code == FilesArchiveErrorPasswordIncorrect,
              @"encrypted zip: wrong password is reported as incorrect");
        check(leftovers(enc_dir).count == 0 &&
              [fm contentsOfDirectoryAtPath:enc_dir.path error:nil].count == 1,
              @"encrypted zip: failed attempts leave nothing behind");
        r = extract_archive(enc_moved, pw, &err);
        check(r && [read_file([r URLByAppendingPathComponent:@"-dash file.txt"]) isEqualToString:@"dash"],
              @"encrypted zip: right password extracts");
        NSURL *plain = make_archive(@[xa], @"plain.zip", FilesArchiveFormatZip, nil, &err);
        r = extract_archive(plain, @"unneeded", &err);
        check(r != nil, @"a password given for an unencrypted zip is ignored");

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

        /* Damaged and hostile archives. */
        NSURL *junk_dir = make_dir([root URLByAppendingPathComponent:@"junk"]);
        for (NSString *n in @[@"junk.zip", @"junk.tar.gz", @"junk.tar"]) {
            NSURL *junk = [junk_dir URLByAppendingPathComponent:n];
            write_file(junk, @"this is not an archive");
            NSURL *res = extract_archive(junk, nil, &err);
            check(!res && err.code == FilesArchiveErrorFailed && err.localizedDescription.length > 0,
                  [NSString stringWithFormat:@"%@: damaged archive is an error", n]);
        }
        check(leftovers(junk_dir).count == 0 && [fm contentsOfDirectoryAtPath:junk_dir.path error:nil].count == 3,
              @"damaged archives leave nothing behind");

        NSURL *trav = make_dir([root URLByAppendingPathComponent:@"trav"]);
        NSURL *trav_in = make_dir([trav URLByAppendingPathComponent:@"in"]);
        write_file([trav URLByAppendingPathComponent:@"evil.txt"], @"evil");
        NSTask *mk = [[NSTask alloc] init];
        mk.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
        mk.arguments = @[@"-cPf", [trav_in URLByAppendingPathComponent:@"evil.tar"].path,
                         @"-C", trav_in.path, @"../evil.txt"];
        [mk launchAndReturnError:nil];
        [mk waitUntilExit];
        [fm removeItemAtURL:[trav URLByAppendingPathComponent:@"evil.txt"] error:nil];
        extract_archive([trav_in URLByAppendingPathComponent:@"evil.tar"], nil, &err);
        check(![fm fileExistsAtPath:[trav URLByAppendingPathComponent:@"evil.txt"].path]
              && ![fm fileExistsAtPath:[trav_in URLByAppendingPathComponent:@"evil.txt"].path]
              && ![fm fileExistsAtPath:[trav URLByAppendingPathComponent:@"in/../evil.txt"].path],
              @"a tar entry named ../x is not written outside the extraction folder");

        /* Awkward archive names. */
        NSURL *odd = make_dir([root URLByAppendingPathComponent:@"odd"]);
        write_file([odd URLByAppendingPathComponent:@"o.txt"], @"o");
        NSURL *odd_zip = make_archive(@[[odd URLByAppendingPathComponent:@"o.txt"]],
                                      @"a[1] café *.zip", FilesArchiveFormatZip, nil, &err);
        NSURL *odd_out = odd_zip ? extract_archive(odd_zip, nil, &err) : nil;
        check(odd_out && [read_file([odd_out URLByAppendingPathComponent:@"o.txt"]) isEqualToString:@"o"],
              @"archive names with brackets, accents and * work");

        [fm removeItemAtURL:root error:nil];
        printf("%s\n", failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}
