#import "dir_listing.h"
#import "util.h"
#include <sys/attr.h>
#include <sys/vnode.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

/* Finder flags, from Carbon's Finder.h, which this app does not link:
 * an icon of the item's own, an invisible item, the bundle bit that
 * makes a folder a package without a package extension, and the alias
 * bit, which makes Launch Services call an item an alias whatever its
 * extension says. */
static const uint16_t finder_flag_custom_icon = 0x0400;
static const uint16_t finder_flag_invisible   = 0x4000;
static const uint16_t finder_flag_bundle      = 0x2000;
static const uint16_t finder_flag_alias       = 0x8000;

/* The attributes one getattrlistbulk pass asks for. They come back in the
 * bit order of sys/attr.h, which is the order read_entry unpacks them in:
 * name, type, times, Finder info, mode, flags, a directory's mount
 * status, then the file size.
 *
 * ATTR_DIR_MOUNTSTATUS tells a plain folder from another volume mounted
 * on it. getattrlistbulk reports the covered folder underneath the mount,
 * not the volume's own root, so a mount point's attributes here are the
 * wrong ones and the entry has to be read again by path. */
#define LISTING_COMMON_ATTRS (ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE \
                            | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FNDRINFO    \
                            | ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS)
#define LISTING_DIR_ATTRS    (ATTR_DIR_MOUNTSTATUS)
#define LISTING_FILE_ATTRS   (ATTR_FILE_DATALENGTH)

/* What the file system told us about one entry, before Launch Services
 * is asked what kind of thing it is. */
typedef struct {
    char     name[NAME_MAX + 1];
    uint32_t obj_type;      /* VREG, VDIR, VLNK, … */
    uint16_t finder_flags;
    uint32_t access_mask;
    uint32_t file_flags;    /* st_flags: UF_HIDDEN, SF_FIRMLINK and friends */
    struct timespec created;
    struct timespec modified;
    off_t    size;
    BOOL     has_size;
    BOOL     is_mount_point;
} raw_entry_t;

/* The record is read-only to its users; the builder below fills it in. */
@interface files_item ()
@property (nonatomic, strong) NSURL    *url;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) long long size;
@property (nonatomic, strong) NSDate   *modified;
@property (nonatomic, strong) NSDate   *created;
@property (nonatomic, assign) mode_t    mode;
@property (nonatomic, assign) BOOL      is_dir;
@property (nonatomic, assign) BOOL      is_symlink;
@property (nonatomic, assign) BOOL      is_package;
@property (nonatomic, assign) BOOL      is_application;
@property (nonatomic, assign) BOOL      is_hidden;
@property (nonatomic, assign) BOOL      has_custom_icon;
@property (nonatomic, strong) UTType   *type;
@property (nonatomic, copy)   NSString *kind;
@end

@implementation files_item
@end

/*
 * listing_attrlist — the attribute list both the folder pass and the
 * single-item read use, so they ask for exactly the same things.
 *
 * Output: the attrlist, by value.
 */
static struct attrlist
listing_attrlist(void)
{
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr  = LISTING_COMMON_ATTRS;
    al.dirattr     = LISTING_DIR_ATTRS;
    al.fileattr    = LISTING_FILE_ATTRS;
    return al;
}

/*
 * read_entry — unpacks one attribute buffer entry into a raw_entry_t.
 * Fields are copied rather than dereferenced in place: the buffer packs
 * them to a 4-byte boundary, so an 8-byte size or time can land
 * unaligned.
 *
 * Inputs:
 *   field — first byte after the entry's length word
 *   out   — receives the entry; untouched fields are left zeroed
 *
 * Output: YES if the entry carried a name, NO if it is unusable.
 */
static BOOL
read_entry(const char *field, raw_entry_t *out)
{
    memset(out, 0, sizeof *out);

    attribute_set_t returned;
    memcpy(&returned, field, sizeof returned);
    field += sizeof returned;

    if (!(returned.commonattr & ATTR_CMN_NAME)) {
        return NO;
    }
    attrreference_t ref;
    memcpy(&ref, field, sizeof ref);
    strlcpy(out->name, field + ref.attr_dataoffset, sizeof out->name);
    field += sizeof ref;

    if (returned.commonattr & ATTR_CMN_OBJTYPE) {
        fsobj_type_t t;
        memcpy(&t, field, sizeof t);
        out->obj_type = (uint32_t)t;
        field += sizeof t;
    }
    if (returned.commonattr & ATTR_CMN_CRTIME) {
        memcpy(&out->created, field, sizeof out->created);
        field += sizeof out->created;
    }
    if (returned.commonattr & ATTR_CMN_MODTIME) {
        memcpy(&out->modified, field, sizeof out->modified);
        field += sizeof out->modified;
    }
    if (returned.commonattr & ATTR_CMN_FNDRINFO) {
        uint8_t info[32];
        memcpy(info, field, sizeof info);
        out->finder_flags = (uint16_t)((info[8] << 8) | info[9]);
        field += sizeof info;
    }
    if (returned.commonattr & ATTR_CMN_ACCESSMASK) {
        memcpy(&out->access_mask, field, sizeof out->access_mask);
        field += sizeof out->access_mask;
    }
    if (returned.commonattr & ATTR_CMN_FLAGS) {
        memcpy(&out->file_flags, field, sizeof out->file_flags);
        field += sizeof out->file_flags;
    }
    /* Directory attributes sit between the common ones and the file ones,
     * and come back only for a directory. */
    if (returned.dirattr & ATTR_DIR_MOUNTSTATUS) {
        uint32_t status;
        memcpy(&status, field, sizeof status);
        out->is_mount_point = (status & DIR_MNTSTATUS_MNTPOINT) != 0;
        field += sizeof status;
    }
    if (returned.fileattr & ATTR_FILE_DATALENGTH) {
        memcpy(&out->size, field, sizeof out->size);
        out->has_size = YES;
    }
    return YES;
}

/*
 * mode_from — st_mode as lstat(2) reports it: the permission bits the
 * file system gave, with the format bits worked out from the object type
 * rather than taken from the access mask, which carries only the
 * permissions on some file systems.
 *
 * Inputs:
 *   e — the entry
 *
 * Output: st_mode, or 0 if the type is unknown and no permissions came
 *         back (the Permissions column then shows "—").
 */
static mode_t
mode_from(const raw_entry_t *e)
{
    mode_t fmt;
    switch (e->obj_type) {
    case VREG:  fmt = S_IFREG;  break;
    case VDIR:  fmt = S_IFDIR;  break;
    case VLNK:  fmt = S_IFLNK;  break;
    case VBLK:  fmt = S_IFBLK;  break;
    case VCHR:  fmt = S_IFCHR;  break;
    case VFIFO: fmt = S_IFIFO;  break;
    case VSOCK: fmt = S_IFSOCK; break;
    default:    fmt = 0;        break;
    }
    mode_t perms = (mode_t)(e->access_mask & ALLPERMS);
    return (fmt == 0 && perms == 0) ? 0 : (mode_t)(fmt | perms);
}

/*
 * type_group_key — what two items must share for Launch Services to give
 * them the same answer: the object type, the filename extension (case
 * does not matter to Launch Services) and the bundle bit, which alone can
 * make one folder a package while its neighbour is not.
 *
 * Sharing one answer is only sound when the extension decides the type.
 * Three kinds of item it does not decide, which therefore each get a key
 * of their own — a Launch Services read apiece — rather than inheriting
 * whichever neighbour happened to be read first:
 *
 *   - No extension at all. Launch Services then looks past the name, so
 *     a Makefile (public.make-source), a LICENSE (public.plain-text) and
 *     a binary blob (public.data) are three different types sharing an
 *     empty extension. Grouping them reported one type for all three and
 *     drew one icon for all three.
 *   - The Finder alias bit, which makes an item an alias
 *     (com.apple.alias-file, kind "Alias") whatever its extension says.
 *   - A mount point, which is a volume (public.volume, kind "Volume")
 *     rather than the folder it is mounted on.
 *
 * Those three still share everything that follows from the type once it
 * is known — see group_for, which falls back to grouping them by the type
 * each one resolves to.
 *
 * Inputs:
 *   e    — the entry
 *   name — its name, as an NSString
 *
 * Output: the key, or nil if the name does not decide this item's type.
 */
static NSString *
type_group_key(const raw_entry_t *e, NSString *name)
{
    NSString *ext = name.pathExtension.lowercaseString;
    if (ext.length == 0 || e->is_mount_point ||
        (e->finder_flags & finder_flag_alias) != 0) {
        return nil;
    }
    BOOL bundle = (e->finder_flags & finder_flag_bundle) != 0;
    return [NSString stringWithFormat:@"%u/%d/%@", e->obj_type, bundle, ext];
}

/* What Launch Services says about one group of items. Read from the
 * first item of the group and reused for the rest: it is the answer
 * Foundation would give for every one of them, at one read instead of
 * thousands. */
@interface type_group : NSObject
@property (nonatomic, strong) UTType   *type;
@property (nonatomic, copy)   NSString *kind;
@property (nonatomic, assign) BOOL      is_package;
@property (nonatomic, assign) BOOL      is_application;
@end

@implementation type_group
@end

/*
 * read_group — everything Launch Services has to say about one item. The
 * type identifier and kind string cannot be worked out from the extension
 * alone (a ".rtfd" directory is com.apple.rtfd but its extension alone
 * yields a dynamic type; the kind of a plain folder is "Folder", not the
 * type's own "folder"), so they are read from Foundation.
 *
 * Inputs:
 *   url — the item to read
 *
 * Output: the group (never nil).
 */
static type_group *
read_group(NSURL *url)
{
    NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:@[
        NSURLTypeIdentifierKey, NSURLLocalizedTypeDescriptionKey,
        NSURLIsPackageKey, NSURLIsApplicationKey] error:nil];

    type_group *group    = [[type_group alloc] init];
    group.type           = values[NSURLTypeIdentifierKey]
                             ? [UTType typeWithIdentifier:values[NSURLTypeIdentifierKey]] : nil;
    group.kind           = values[NSURLLocalizedTypeDescriptionKey];
    group.is_package     = [values[NSURLIsPackageKey] boolValue];
    group.is_application = [values[NSURLIsApplicationKey] boolValue];
    return group;
}

/*
 * group_for — the Launch Services answers for an item, read once per kind
 * of item in the folder rather than once per item.
 *
 * Items whose name settles their type (the common case: a filename
 * extension) are grouped by that name, so one read serves a folder of ten
 * thousand photographs. For the rest — no extension, an alias, a mount
 * point — the name says nothing, so each one's own type is resolved first
 * and the group is keyed on that type instead. The kind string and the
 * package and application flags all follow from the type, so a folder of
 * extensionless files still costs one full read per distinct type rather
 * than per file: the per-item part is the single content-type lookup.
 *
 * Inputs:
 *   url    — the item
 *   e      — its entry, for the object type and the bundle and mount bits
 *   name   — its name, as an NSString
 *   groups — the cache for this listing
 *
 * Output: the group (never nil).
 */
static type_group *
group_for(NSURL *url, const raw_entry_t *e, NSString *name,
          NSMutableDictionary<NSString *, type_group *> *groups)
{
    NSString *key = type_group_key(e, name);
    if (!key) {
        /* The name does not settle it: ask for this item's own type, then
         * group on that. The bundle bit stays in the key because it, not
         * the type, is what makes an extensionless folder a package. */
        UTType *type = nil;
        [url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
        BOOL bundle  = (e->finder_flags & finder_flag_bundle) != 0;
        key = [NSString stringWithFormat:@"=%u/%d/%@", e->obj_type, bundle,
                                         type.identifier ?: @"?"];
    }

    type_group *group = groups[key];
    if (!group) {
        group      = read_group(url);
        groups[key] = group;
    }
    return group;
}

/*
 * item_from — builds the record for one entry, asking the group cache
 * what kind of thing it is.
 *
 * Inputs:
 *   e      — the entry as the file system gave it
 *   dir    — the folder it is in
 *   groups — the type-group cache for this listing
 *
 * Output: the item (never nil).
 */
static files_item *
item_from(const raw_entry_t *e, NSString *dir,
          NSMutableDictionary<NSString *, type_group *> *groups)
{
    /* A name the volume did not store as UTF-8 (SMB, NFS and FUSE shares
     * deliver them; APFS rejects them with EILSEQ). Boxing a char * is
     * itself stringWithUTF8String:, so it is no use as a fallback — it
     * returns nil for exactly the same bytes, and nil reached
     * stringByAppendingPathComponent:, which raises. The file manager's
     * conversion handles most of them; MacOS Roman is the last resort,
     * being a single-byte encoding that cannot fail, so the row appears
     * with a mangled name rather than taking the listing down. */
    NSString *name = [NSString stringWithUTF8String:e->name];
    if (!name) {
        name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:e->name
                                                                         length:strlen(e->name)];
    }
    if (!name) {
        name = [[NSString alloc] initWithBytes:e->name
                                        length:strlen(e->name)
                                      encoding:NSMacOSRomanStringEncoding];
    }
    NSString *path  = [dir stringByAppendingPathComponent:name];
    BOOL      is_dir = (e->obj_type == VDIR);

    files_item *item  = [[files_item alloc] init];
    item.name         = name;
    item.path         = path;
    item.url          = [NSURL fileURLWithPath:path isDirectory:is_dir];
    item.is_dir       = is_dir;
    item.is_symlink   = (e->obj_type == VLNK);
    item.mode         = mode_from(e);
    /* A directory has no file size: the Size column shows the folder-size
     * count there instead, and the size sort falls back to it. */
    item.size         = (e->has_size && !is_dir) ? (long long)e->size : -1;
    item.created      = [NSDate dateWithTimeIntervalSince1970:
                            (NSTimeInterval)e->created.tv_sec];
    item.modified     = [NSDate dateWithTimeIntervalSince1970:
                            (NSTimeInterval)e->modified.tv_sec];
    item.is_hidden    = [name hasPrefix:@"."]
                      || (e->file_flags & UF_HIDDEN) != 0
                      || (e->finder_flags & finder_flag_invisible) != 0;
    item.has_custom_icon = (e->finder_flags & finder_flag_custom_icon) != 0;

    type_group *group    = group_for(item.url, e, name, groups);
    item.type            = group.type;
    item.kind            = group.kind;
    /* The bundle bit is part of the group key, so the group's answer
     * already accounts for it. */
    item.is_package      = group.is_package;
    item.is_application  = group.is_application;
    return item;
}

/*
 * entry_needs_reread — whether getattrlistbulk's answer for this entry
 * describes something other than the item the user sees, so the entry has
 * to be read again by path.
 *
 * Two cases, both of which the batched call reports as the directory that
 * is standing in the way rather than the one it stands for:
 *
 *   - A firmlink (SF_FIRMLINK), the mechanism that shows the Data
 *     volume's folders at the startup volume's root. Eight of the
 *     twenty-one entries at / are firmlinks (Library, Users,
 *     Applications, private, opt, Volumes, cores), and the batched call
 *     gives every one of them the synthetic root's own dates, so the
 *     startup disk showed one identical date down the whole window and
 *     sorting it by date meant nothing. Reading by path resolves the
 *     firmlink; the flag is set in the batched answer and clear in the
 *     path one, which is how the two can be told apart.
 *   - A mount point (/dev and friends): the batched call reports the
 *     covered folder beneath the mount, not the mounted volume's root.
 *
 * Inputs:
 *   e — the entry as the batched call gave it
 *
 * Output: YES if the entry must be read again by path.
 */
static BOOL
entry_needs_reread(const raw_entry_t *e)
{
    return (e->file_flags & SF_FIRMLINK) != 0 || e->is_mount_point;
}

/*
 * reread_by_path — the attributes of an item the batched call described
 * wrongly, read again through its path, which resolves firmlinks and
 * crosses into a mounted volume.
 *
 * The name, path and URL stay the listed ones. A path read of a mount
 * point answers with the mounted volume's own name ("Macintosh HD"),
 * not the name of the directory it is mounted on (/.nofollow), and the
 * folder has to show the name it actually holds. Hidden stays true if
 * either answer says so, since it follows from that listed name as well
 * as from the item's flags.
 *
 * Inputs:
 *   listed — the item as the batched call built it
 *
 * Output: the corrected item, or listed unchanged if the path read failed.
 */
static files_item *
reread_by_path(files_item *listed)
{
    files_item *resolved = files_item_at_url(listed.url);
    if (!resolved) {
        return listed;
    }
    resolved.name      = listed.name;
    resolved.path      = listed.path;
    resolved.url       = listed.url;
    resolved.is_hidden = resolved.is_hidden || listed.is_hidden;
    return resolved;
}

/*
 * list_one_by_one — the same listing without getattrlistbulk, for a file
 * system that does not implement it (some network and FUSE volumes, such
 * as a folder over SSH): the names, then one getattrlist each. Slower,
 * and the only way such a volume can be listed at all.
 *
 * Inputs:
 *   dir — folder to list
 *   err — receives the failure when nil is returned; may be NULL
 *
 * Output: the items, or nil if the folder cannot be read.
 */
static NSArray<files_item *> *
list_one_by_one(NSURL *dir, NSError **err)
{
    NSArray<NSString *> *names =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:err];
    if (!names) {
        return nil;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        [urls addObject:[dir URLByAppendingPathComponent:name]];
    }
    NSArray<files_item *> *items = files_items_at_urls(urls);
    /* files_items_at_urls drops an item whose getattrlist failed. On the
     * sort of volume this fallback exists for, the per-item call can be
     * unsupported too, and every one of them is then dropped: a folder
     * with names in it would come back empty and the window would show an
     * empty folder rather than saying it could not be read. */
    if (items.count == 0 && names.count > 0) {
        if (err) *err = files_posix_error(ENOTSUP, dir);
        return nil;
    }
    return items;
}

/*
 * files_list_items — one folder in batched getattrlistbulk calls.
 * Inputs/output are documented in dir_listing.h.
 */
NSArray<files_item *> *
files_list_items(NSURL *dir, NSError **err)
{
    int fd = open(dir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY);
    if (fd < 0) {
        if (err) *err = files_posix_error(errno, dir);
        return nil;
    }

    struct attrlist al = listing_attrlist();
    /* 128 KB holds a few hundred entries a call, so a folder of 10,000
     * costs tens of system calls rather than tens of thousands. */
    char buf[128 * 1024];
    NSString *path = dir.path;
    NSMutableArray<files_item *> *items = [NSMutableArray array];
    NSMutableDictionary<NSString *, type_group *> *groups = [NSMutableDictionary dictionary];

    BOOL first = YES;
    for (;;) {
        int count = getattrlistbulk(fd, &al, buf, sizeof buf, 0);
        if (count == 0) {
            break;      /* end of the directory */
        }
        if (count < 0) {
            int failed = errno;
            close(fd);
            /* A volume whose file system has no batched attributes says so
             * on the first call; everything else is a real failure. */
            if (first && (failed == ENOTSUP || failed == EINVAL)) {
                return list_one_by_one(dir, err);
            }
            if (err) *err = files_posix_error(failed, dir);
            return nil;
        }
        first = NO;
        const char *entry = buf;
        for (int i = 0; i < count; i++) {
            uint32_t length;
            memcpy(&length, entry, sizeof length);
            raw_entry_t e;
            if (read_entry(entry + sizeof length, &e)) {
                files_item *item = item_from(&e, path, groups);
                /* A firmlink or a mount point: what the batched call said
                 * describes the directory standing in the way, so read
                 * this one again by path. A handful of entries at a volume
                 * root at most, and none in an ordinary folder. */
                if (entry_needs_reread(&e)) {
                    item = reread_by_path(item);
                }
                [items addObject:item];
            }
            entry += length;
        }
    }
    close(fd);
    return items;
}

/*
 * files_items_at_urls — scattered items, one getattrlist each.
 * Inputs/output are documented in dir_listing.h.
 */
NSArray<files_item *> *
files_items_at_urls(NSArray<NSURL *> *urls)
{
    struct attrlist al = listing_attrlist();
    NSMutableArray<files_item *> *items = [NSMutableArray arrayWithCapacity:urls.count];
    NSMutableDictionary<NSString *, type_group *> *groups = [NSMutableDictionary dictionary];

    for (NSURL *url in urls) {
        /* One entry, in the same shape getattrlistbulk returns: the
         * length word, then the attributes. */
        char buf[sizeof(uint32_t) + sizeof(attribute_set_t) + NAME_MAX + 512];
        if (getattrlist(url.fileSystemRepresentation, &al, buf, sizeof buf,
                        FSOPT_NOFOLLOW | FSOPT_REPORT_FULLSIZE) != 0) {
            continue;
        }
        /* FSOPT_REPORT_FULLSIZE makes the length word the size the reply
         * needed, so a reply too big for the buffer can be told from one
         * that fits rather than read past its end. */
        uint32_t length;
        memcpy(&length, buf, sizeof length);
        raw_entry_t e;
        if (length > sizeof buf || !read_entry(buf + sizeof length, &e)) {
            continue;
        }
        [items addObject:item_from(&e, url.URLByDeletingLastPathComponent.path, groups)];
    }
    return items;
}

/*
 * files_item_at_url — one item.
 * Inputs/output are documented in dir_listing.h.
 */
files_item *
files_item_at_url(NSURL *url)
{
    return url ? files_items_at_urls(@[url]).firstObject : nil;
}
