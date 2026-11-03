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
 * FilesArchiveErrorCode — codes in FilesArchiveErrorDomain. Every failure
 * (a name already taken, a full disk, …) is FilesArchiveErrorFailed, whose
 * localizedDescription is the tool's own message.
 */
typedef NS_ENUM(NSInteger, FilesArchiveErrorCode) {
    FilesArchiveErrorFailed = 1,
};

/*
 * FilesArchive — stateless class that creates archives with the system
 * tools /usr/bin/zip and /usr/bin/tar (bsdtar), and the tool window that
 * goes with them. Expanding an archive is not ours: a double-click hands
 * the file to its default application, as Finder does. All methods run on
 * the main thread; the tools run on a background queue. Passwords reach
 * zip through a pseudo-terminal, never on a command line where `ps` shows
 * them.
 */
@interface FilesArchive : NSObject

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

@end
