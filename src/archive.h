#import <Cocoa/Cocoa.h>

/*
 * FilesArchiveFormat — the archive formats Files creates. Zip is the only
 * one that can be password protected.
 */
typedef NS_ENUM(NSInteger, FilesArchiveFormat) {
    FilesArchiveFormatZip,
    FilesArchiveFormatTarGz,
    FilesArchiveFormatTar,
};

/* Error domain of the errors FilesArchive reports. */
extern NSString * const FilesArchiveErrorDomain;

/*
 * FilesArchiveErrorCode — codes in FilesArchiveErrorDomain. Anything else
 * (a damaged archive, a full disk, …) is FilesArchiveErrorFailed, whose
 * localizedDescription is the tool's own message.
 */
typedef NS_ENUM(NSInteger, FilesArchiveErrorCode) {
    FilesArchiveErrorFailed = 1,
    FilesArchiveErrorPasswordRequired,   /* extract: archive is encrypted, no password given */
    FilesArchiveErrorPasswordIncorrect,  /* extract: the password given does not open it */
};

/*
 * FilesArchive — stateless class that expands and creates archives with
 * the system tools /usr/bin/unzip, /usr/bin/zip and /usr/bin/tar (bsdtar),
 * and the tool windows that go with them. All methods run on the main thread;
 * the tools run on a background queue. Passwords reach zip and unzip
 * through a pseudo-terminal, never on a command line where `ps` shows them.
 */
@interface FilesArchive : NSObject

/*
 * is_archive: — whether Files expands url on double-click: a name ending
 * in .zip, .tar, .tar.gz or .tgz (any case).
 *
 * Inputs:
 *   url — file URL
 *
 * Output: YES if the name is one of those.
 */
+ (BOOL)is_archive:(NSURL *)url;

/*
 * extract:password:completion: — expands an archive into a new folder next
 * to it. The contents are first unpacked into a hidden staging folder and
 * moved into place only when complete, so a failure leaves nothing behind.
 * If the archive holds a single top-level folder that folder is the
 * result, otherwise the result is a folder named after the archive
 * ("notes.tar.gz" → "notes"). A name already taken gets " 2", " 3", …
 * appended. Entries are never written outside that folder (the tools drop
 * ".." and absolute paths), and a zip's __MACOSX metadata folder is left
 * out.
 *
 * Inputs:
 *   archive    — .zip, .tar, .tar.gz or .tgz file URL
 *   password   — for an encrypted zip; nil if none is known (ignored for
 *                tar)
 *   completion — called on the main queue with the new folder, or nil and
 *                an error (FilesArchiveErrorPasswordRequired /
 *                FilesArchiveErrorPasswordIncorrect for a zip whose
 *                password is missing or wrong)
 */
+ (void)extract:(NSURL *)archive
       password:(NSString *)password
     completion:(void (^)(NSURL *folder, NSError *err))completion;

/*
 * create_from:name:format:password:completion: — archives items into a new
 * file next to them, written under a hidden name and renamed into place
 * only when complete. Entries are stored relative to that folder (symbolic
 * links kept as links), without macOS extended-attribute (._) entries in a
 * tar.
 *
 * Inputs:
 *   items      — files and folders to archive; all in the same folder
 *   name       — file name of the archive, extension included; must not
 *                exist yet
 *   format     — archive format; should match the name's extension
 *   password   — encrypts the archive; nil or empty for none; only
 *                FilesArchiveFormatZip supports one
 *   completion — called on the main queue with the archive's URL, or nil
 *                and an error
 */
+ (void)create_from:(NSArray<NSURL *> *)items
               name:(NSString *)name
             format:(FilesArchiveFormat)format
           password:(NSString *)password
         completion:(void (^)(NSURL *archive, NSError *err))completion;

/*
 * default_name_for:format: — the archive name the Create Archive dialog
 * starts with: the item's own name for a single item, "Archive" for
 * several, plus the format's extension.
 *
 * Inputs:
 *   items  — items to be archived (non-empty)
 *   format — chosen format
 *
 * Output: file name.
 */
+ (NSString *)default_name_for:(NSArray<NSURL *> *)items format:(FilesArchiveFormat)format;

/*
 * prompt_create_for:window:handler: — shows the Create Archive tool window
 * (FilesToolPanel), centred over window: format (zip, tar.gz or tar), file name, and for zip an
 * optional password entered twice. Create is refused, with the reason in
 * the window, for an empty or invalid name, a name already in use, or a
 * password left empty or mismatched.
 *
 * Inputs:
 *   items   — items to be archived (non-empty, all in one folder)
 *   window  — window to centre over; nil = the screen
 *   handler — called only if the user chose Create, with the validated file
 *             name (extension added if missing), the format and the
 *             password (nil if none)
 */
+ (void)prompt_create_for:(NSArray<NSURL *> *)items
                   window:(NSWindow *)window
                  handler:(void (^)(NSString *name, FilesArchiveFormat format,
                                    NSString *password))handler;

/*
 * prompt_password_for:incorrect:window:handler: — asks for the password of
 * an encrypted archive in a tool window (FilesToolPanel).
 *
 * Inputs:
 *   archive   — the archive, named in the window
 *   incorrect — YES if a previous password was wrong (says so)
 *   window    — window to centre over; nil = the screen
 *   handler   — called only if the user chose Extract, with the password
 */
+ (void)prompt_password_for:(NSURL *)archive
                  incorrect:(BOOL)incorrect
                     window:(NSWindow *)window
                    handler:(void (^)(NSString *password))handler;

@end
