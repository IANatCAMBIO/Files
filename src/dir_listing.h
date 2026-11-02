#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>

/*
 * files_item — everything the file list shows about one item, read once
 * with the listing. It replaces the resource values Foundation would
 * prefetch onto an NSURL: asking contentsOfDirectoryAtURL: for the twelve
 * keys the list needs costs ~420 ms for 10,000 items against ~10 ms for
 * the enumeration alone, because Foundation reads them item by item,
 * while getattrlistbulk returns the same attributes in batches as part of
 * the enumeration (~23 ms for the same 10,000, records and URLs
 * included). The values are a snapshot: nothing here re-reads the volume.
 */
@interface files_item : NSObject

@property (nonatomic, readonly) NSURL    *url;
@property (nonatomic, readonly) NSString *path;      /* url.path, kept once */
@property (nonatomic, readonly) NSString *name;
/* Size in bytes, or -1 for an item that has none (a directory), which the
 * Size column and the size sort treat as "ask the folder-size count". */
@property (nonatomic, readonly) long long size;
@property (nonatomic, readonly) NSDate   *modified;
@property (nonatomic, readonly) NSDate   *created;
/* st_mode as lstat(2) would report it: permission bits plus the format
 * bits, so strmode(3) prints the leading d, l or -. */
@property (nonatomic, readonly) mode_t    mode;
@property (nonatomic, readonly) BOOL      is_dir;
@property (nonatomic, readonly) BOOL      is_symlink;
@property (nonatomic, readonly) BOOL      is_package;
@property (nonatomic, readonly) BOOL      is_application;
/* Hidden as Finder counts it: a leading dot, the UF_HIDDEN file flag, or
 * the Finder "invisible" flag. */
@property (nonatomic, readonly) BOOL      is_hidden;
/* Carries an icon of its own (kHasCustomIcon), so the lists know to read
 * the item's icon rather than share its type's — free here, since the
 * Finder flags come with the enumeration. */
@property (nonatomic, readonly) BOOL      has_custom_icon;
/* The item's type and the kind string the Kind column shows ("Folder",
 * "Application", "Alias", "Rich Text Document"). Both come from Launch
 * Services, once per distinct kind of item in the folder rather than once
 * per item; nil only where Launch Services knows nothing. */
@property (nonatomic, readonly) UTType   *type;
@property (nonatomic, readonly) NSString *kind;

@end

/*
 * files_list_items — the contents of one folder, with every attribute the
 * file list needs, in batched getattrlistbulk calls. Reads the volume;
 * call on a background queue.
 *
 * Inputs:
 *   dir — folder to list
 *   err — receives the failure when nil is returned; may be NULL
 *
 * Output: one files_item per entry ("." and ".." excluded), in the order
 *         the file system gives them, or nil if the folder cannot be
 *         opened or read.
 */
NSArray<files_item *> *files_list_items(NSURL *dir, NSError **err);

/*
 * files_items_at_urls — the same attributes for items that did not come
 * from one folder listing, such as search results scattered over the
 * disk: one getattrlist each, which is still far cheaper than Foundation's
 * resource values. Reads the volume; call on a background queue.
 *
 * Inputs:
 *   urls — file URLs to read
 *
 * Output: one files_item per readable URL, in the order given; an item
 *         that cannot be read is left out, so the result may be shorter
 *         than urls.
 */
NSArray<files_item *> *files_items_at_urls(NSArray<NSURL *> *urls);

/*
 * files_item_at_url — the attributes of a single item, for the places
 * that hold a URL from outside the current listing (a symbolic link's
 * target, an item dropped from another window). Reads the volume.
 *
 * Inputs:
 *   url — file URL to read
 *
 * Output: the item, or nil if it cannot be read.
 */
files_item *files_item_at_url(NSURL *url);
