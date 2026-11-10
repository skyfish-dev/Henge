// Runs inside macOS on a Henge virtual Mac, as a LaunchAgent. It keeps the clipboard in step with the device,
// keeps the shared folder mounted, and keeps the shared folders of the computers set up in the app (Settings,
// Computers) mounted in ~/Henge Drives, so that apps on the Mac can save straight to them. It talks to host/share.c at 10.0.2.4, which only exists inside Henge.
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define HOST "10.0.2.4"

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

// One request on its own connection. A plain socket: the server is ours, and URLSession refuses plain HTTP.
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval timeout = {.tv_sec = 40};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(80)};
    inet_pton(AF_INET, HOST, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return nil;
    }
    NSString *head = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: " HOST "\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", method, path,
                                                (unsigned long)body.length];
    const char *text = head.UTF8String;
    if (send_all(fd, text, strlen(text)) != 0 || (body.length && send_all(fd, body.bytes, body.length) != 0)) {
        close(fd);
        return nil;
    }
    NSMutableData *all = [NSMutableData data];
    char piece[16384];
    for (;;) {
        ssize_t got = recv(fd, piece, sizeof piece, 0);
        if (got <= 0) break;
        [all appendBytes:piece length:(NSUInteger)got];
    }
    close(fd);
    NSRange end = [all rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, all.length)];
    if (end.location == NSNotFound) return nil;
    NSString *headers = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    if (sscanf(headers.UTF8String, "HTTP/1.1 %d", status) != 1) return nil;
    NSRange found = [headers rangeOfString:@"X-Henge-Seq: "];
    if (found.location != NSNotFound && seq) *seq = strtoul(headers.UTF8String + NSMaxRange(found), NULL, 10);
    NSUInteger start = NSMaxRange(end);
    return [all subdataWithRange:NSMakeRange(start, all.length - start)];
}

static NSInteger lastChange;

// The device's clipboard, as it changes. The server holds each request until there is something new.
static void followDevice(void) {
    unsigned long seq = 0;
    for (BOOL first = YES;; first = NO) {
        int status = 0;
        unsigned long now = seq;
        NSData *body = request(@"GET", [NSString stringWithFormat:@"/.henge/clipboard?since=%lu", first ? ULONG_MAX >> 1 : seq], nil, &status, &now);
        if (!body) {
            sleep(5);
            continue;
        }
        BOOL news = !first && status == 200 && now != seq;
        seq = now; // what the device had before this helper started isn't news
        if (!news) continue;
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!text) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            lastChange = board.changeCount;
        });
    }
}

// The Mac's clipboard goes to the device, unless the app that copied it marked it as secret.
static void checkClipboard(void) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (board.changeCount == lastChange) return;
    lastChange = board.changeCount;
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"]) return;
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"PUT", @"/.henge/clipboard", data, &status, NULL);
    });
}

static NSString *mountPoint(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Henge"]; }

// The shared folder, at ~/Henge. mount_webdav needs an empty folder it owns, and is a no-op failure if it is mounted.
static void keepMounted(void) {
    NSString *point = mountPoint();
    [NSFileManager.defaultManager createDirectoryAtPath:point withIntermediateDirectories:YES attributes:nil error:NULL];
    struct stat folder, parent;
    if (stat(point.fileSystemRepresentation, &folder) != 0 || stat(NSHomeDirectory().fileSystemRepresentation, &parent) != 0) return;
    if (folder.st_dev != parent.st_dev) return; // already something else's volume: mounted
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/mount_webdav"];
    task.arguments = @[ @"-S", @"-v", @"Henge", @"http://" HOST "/", point ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:NULL];
}

// ---- computers on the network ----

static NSString *drivesFolder(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Henge Drives"]; }

// Something else's volume is mounted on the folder.
static BOOL isMounted(NSString *point) {
    struct stat folder, parent;
    if (stat(point.fileSystemRepresentation, &folder) != 0) return NO;
    if (stat(point.stringByDeletingLastPathComponent.fileSystemRepresentation, &parent) != 0) return NO;
    return folder.st_dev != parent.st_dev;
}

// What a user name or password can hold in an smb:// URL.
static NSString *escaped(NSString *s) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

// A tool's exit status and the last thing it said, or -1 if it didn't finish in time (an address that doesn't answer).
static int runTool(NSString *path, NSArray<NSString *> *arguments, NSString **said) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = pipe;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *t) { (void)t; dispatch_semaphore_signal(done); };
    if (![task launchAndReturnError:NULL]) return -1;
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0) {
        [task terminate];
        if (said) *said = @"The computer didn't answer. Is it on, and on the same network?";
        return -1;
    }
    NSData *out = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    NSArray *lines = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"];
    if (said) *said = lines.lastObject ?: @"";
    return task.terminationStatus;
}

// Whether a computer's file sharing (TCP 445) takes a connection within a couple of seconds.
static BOOL answers(NSString *host) {
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *found = NULL;
    if (getaddrinfo(host.UTF8String, "445", &hints, &found) != 0 || !found) return NO;
    BOOL ok = NO;
    int s = socket(found->ai_family, SOCK_STREAM, 0);
    if (s >= 0) {
        fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
        if (connect(s, found->ai_addr, found->ai_addrlen) == 0) ok = YES;
        else if (errno == EINPROGRESS) {
            struct pollfd p = { .fd = s, .events = POLLOUT };
            int err = 0;
            socklen_t len = sizeof err;
            ok = poll(&p, 1, 2500) == 1 && getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0;
        }
        close(s);
    }
    freeaddrinfo(found);
    return ok;
}

// mount_smbfs says what went wrong in its own words; these are the ones people meet.
static NSString *plainError(NSString *said) {
    NSString *s = said.lowercaseString;
    if ([s containsString:@"authentication"] || [s containsString:@"permission denied"]) return @"The user name or password was refused.";
    if ([s containsString:@"no route"] || [s containsString:@"unreachable"] || [s containsString:@"timed out"]) return @"The computer couldn't be reached.";
    if ([s containsString:@"not found"] || [s containsString:@"no such file"]) return @"No shared folder by that name on that computer.";
    if ([s containsString:@"resolve"] || [s containsString:@"unknown host"]) return @"No computer by that name: try its IP address.";
    return said.length ? said : @"It couldn't be connected.";
}

// The app carries a helper; when it isn't this one (Henge was updated), this one is replaced by it and quits, and
// launchd starts the new one (KeepAlive). Installed by an older script, there's no record: the first look makes one.
static void updateSelf(void) {
    int status = 0;
    NSData *idData = request(@"GET", @"/.henge/agent-id", nil, &status, NULL);
    if (!idData || status != 200) return; // a Henge from before this
    NSString *served = [[[NSString alloc] initWithData:idData encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *me = NSProcessInfo.processInfo.arguments.firstObject;
    if (!served.length || !me.length) return;
    NSString *idPath = [me stringByAppendingString:@".id"];
    NSString *mine = [[NSString stringWithContentsOfFile:idPath encoding:NSUTF8StringEncoding error:NULL]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([served isEqualToString:mine]) return;
    NSData *gz = request(@"GET", @"/.henge/agent", nil, &status, NULL);
    if (!gz.length || status != 200) return;
    NSString *gzPath = [me stringByAppendingString:@".new.gz"], *newPath = [me stringByAppendingString:@".new"];
    if (![gz writeToFile:gzPath atomically:YES]) return;
    int rc = runTool(@"/bin/sh", @[ @"-c", @"/usr/bin/gunzip -c \"$0\" > \"$1\" && chmod 755 \"$1\"", gzPath, newPath ], NULL);
    unlink(gzPath.fileSystemRepresentation);
    if (rc != 0 || rename(newPath.fileSystemRepresentation, me.fileSystemRepresentation) != 0) {
        unlink(newPath.fileSystemRepresentation);
        return;
    }
    [served writeToFile:idPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"henge-agent: updated to %@, restarting", served);
    exit(0);
}

// MARK: Saving while the computer is away
//
// While a computer can't be reached, its folder in ~/Henge Drives is an ordinary folder on the Mac: what's saved there
// stays on the Mac. Before the computer's folder is mounted over it again, that moves to an outbox
// (~/Library/Application Support/Henge/Outbox/<name>), and from there goes to the computer. A file the computer already
// has with different contents is never overwritten without asking.

static NSString *outboxFolder(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Henge/Outbox"]
        stringByAppendingPathComponent:name];
}

static BOOL junk(NSString *file) { return [file isEqualToString:@".DS_Store"] || [file isEqualToString:@".localized"]; }

// What was saved in the not-mounted folder, into the outbox (merged with what's waiting there already).
static void stashOffline(NSString *point, NSString *name) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *outbox = outboxFolder(name);
    for (NSString *item in [files contentsOfDirectoryAtPath:point error:NULL] ?: @[]) {
        NSString *from = [point stringByAppendingPathComponent:item];
        if (junk(item)) { [files removeItemAtPath:from error:NULL]; continue; }
        [files createDirectoryAtPath:outbox withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *to = [outbox stringByAppendingPathComponent:item];
        if (runTool(@"/usr/bin/ditto", @[ from, to ], NULL) == 0) [files removeItemAtPath:from error:NULL];
    }
}

// Asks on the Mac's screen; the button's title, or nil if nobody answered (it gives up after 10 minutes).
static NSString *ask(NSString *message, NSArray<NSString *> *buttons) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    NSMutableArray *args = [@[ @"-e", @"on run argv",
        @"-e", @"set r to display dialog (item 1 of argv) with title \"Henge\" buttons (items 2 thru -1 of argv) "
               @"default button (count of argv) - 1 with icon caution giving up after 600",
        @"-e", @"return button returned of r", @"-e", @"end run", message ] mutableCopy];
    [args addObjectsFromArray:buttons];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return nil;
    NSData *out = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *answer = [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return answer.length ? answer : nil;
}

// "Report (from Mac).pdf", or "Report (from Mac 2).pdf" if that's taken too.
static NSString *besides(NSString *path) {
    NSString *folder = path.stringByDeletingLastPathComponent, *file = path.lastPathComponent;
    NSString *stem = file.stringByDeletingPathExtension, *ext = file.pathExtension;
    for (int n = 1;; n++) {
        NSString *tag = n == 1 ? @"from Mac" : [NSString stringWithFormat:@"from Mac %d", n];
        NSString *name = [NSString stringWithFormat:@"%@ (%@)", stem, tag];
        if (ext.length) name = [name stringByAppendingPathExtension:ext];
        NSString *candidate = [folder stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
}

// Copies to a temporary name first, then renames over: an interrupted copy never leaves half a file in its place.
static BOOL put(NSString *from, NSString *to) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *part = [to stringByAppendingString:@".henge-part"];
    [files removeItemAtPath:part error:NULL];
    if (![files copyItemAtPath:from toPath:part error:NULL]) return NO;
    if (rename(part.fileSystemRepresentation, to.fileSystemRepresentation) != 0) {
        [files removeItemAtPath:part error:NULL];
        return NO;
    }
    return YES;
}

// Sends what's waiting in the outbox to the mounted computer. Returns how many files still wait (a copy failed).
static NSUInteger sendOutbox(NSString *point, NSString *name) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *outbox = outboxFolder(name);
    BOOL isDir = NO;
    if (![files fileExistsAtPath:outbox isDirectory:&isDir] || !isDir) return 0;

    NSMutableArray<NSString *> *fresh = [NSMutableArray array], *clashing = [NSMutableArray array];
    NSDirectoryEnumerator *walk = [files enumeratorAtPath:outbox];
    for (NSString *rel in walk) {
        NSString *from = [outbox stringByAppendingPathComponent:rel];
        if (![files fileExistsAtPath:from isDirectory:&isDir] || isDir) continue;
        if (junk(rel.lastPathComponent)) { [files removeItemAtPath:from error:NULL]; continue; }
        NSString *to = [point stringByAppendingPathComponent:rel];
        if (![files fileExistsAtPath:to]) [fresh addObject:rel];
        else if ([files contentsEqualAtPath:from andPath:to]) [files removeItemAtPath:from error:NULL];
        else [clashing addObject:rel];
    }

    NSUInteger left = 0;
    for (NSString *rel in fresh) {
        NSString *from = [outbox stringByAppendingPathComponent:rel], *to = [point stringByAppendingPathComponent:rel];
        [files createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        if (put(from, to)) [files removeItemAtPath:from error:NULL]; else left++;
    }

    // Files the computer has too, with other contents: one question for all of them, never a silent overwrite.
    if (clashing.count) {
        NSString *message;
        if (clashing.count == 1) {
            message = [NSString stringWithFormat:@"“%@” was saved on this Mac while %@ was away, and %@ already has a "
                       @"different file with that name.\n\nKeep both: the Mac's copy is added as “%@”.",
                       clashing[0], name, name, besides([point stringByAppendingPathComponent:clashing[0]]).lastPathComponent];
        } else {
            NSArray *some = [clashing subarrayWithRange:NSMakeRange(0, MIN(clashing.count, 5))];
            message = [NSString stringWithFormat:@"%lu files saved on this Mac while %@ was away already exist there "
                       @"with different contents:\n\n%@%@\n\nKeep both: the Mac's copies are added with “(from Mac)” in "
                       @"their names.", (unsigned long)clashing.count, name, [some componentsJoinedByString:@"\n"],
                       clashing.count > some.count ? @"\n…" : @""];
        }
        NSString *keepPC = @"Keep the Computer's";
        NSString *replace = clashing.count == 1 ? @"Replace It" : @"Replace Them";
        NSString *answer = ask(message, @[ keepPC, replace, @"Keep Both" ]);
        for (NSString *rel in clashing) {
            NSString *from = [outbox stringByAppendingPathComponent:rel], *to = [point stringByAppendingPathComponent:rel];
            if ([answer isEqualToString:keepPC]) {
                // The Mac's copy goes to the Mac's Trash, not away for good.
                [files trashItemAtURL:[NSURL fileURLWithPath:from] resultingItemURL:NULL error:NULL];
            } else if ([answer isEqualToString:replace]) {
                if (put(from, to)) [files removeItemAtPath:from error:NULL]; else left++;
            } else {
                // Keep Both, and nobody answering: nothing is lost either way.
                if (put(from, besides(to))) [files removeItemAtPath:from error:NULL]; else left++;
            }
        }
    }
    // Folders the files came in, now empty.
    runTool(@"/usr/bin/find", @[ outbox, @"-mindepth", @"1", @"-type", @"d", @"-empty", @"-delete" ], NULL);
    rmdir(outbox.fileSystemRepresentation);
    return left;
}

// The app's list (host/share.c, /.henge/drives): name TAB host TAB share TAB user TAB password, a line each.
// Each is kept mounted on ~/Henge Drives/<name>; one taken off the list is unmounted. How it went goes back.
static void keepDrivesMounted(void) {
    int status = 0;
    NSData *body = request(@"GET", @"/.henge/drives", nil, &status, NULL);
    if (!body || status != 200) return;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
    NSString *folder = drivesFolder();
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableSet<NSString *> *wanted = [NSMutableSet set];
    NSMutableString *report = [NSMutableString string];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
        if (f.count < 5) continue;
        NSString *name = [[f[0] stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        if (!name.length || [name hasPrefix:@"."] || !f[1].length || !f[2].length) continue;
        [wanted addObject:name];
        NSString *point = [folder stringByAppendingPathComponent:name];
        [files createDirectoryAtPath:point withIntermediateDirectories:YES attributes:nil error:NULL];
        // Several addresses (home, then Tailscale): the first whose file sharing answers.
        NSString *host = nil;
        for (NSString *h in [f[1] componentsSeparatedByString:@","]) {
            NSString *t = [h stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length && answers(t)) { host = t; break; }
        }
        if (isMounted(point)) {
            if (host) {
                NSUInteger left = sendOutbox(point, name);
                if (left) [report appendFormat:@"%@\twaiting:%lu\n", name, (unsigned long)left];
                else [report appendFormat:@"%@\tok\n", name];
                continue;
            }
            // Gone (left home, asleep): let go of it, so the folder is the Mac's own again and saves keep working.
            runTool(@"/sbin/umount", @[ @"-f", point ], NULL);
            if (isMounted(point)) continue;
        }
        if (!host) {
            // "away": the app says saves wait on the Mac (an older app shows the word as it is).
            [report appendFormat:@"%@\taway\n", name];
            continue;
        }
        // Saved while it was away: out of the way of the mount, then sent.
        stashOffline(point, name);
        NSString *user = f[3].length ? escaped(f[3]) : @"guest";
        NSString *share = [f[2] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: f[2];
        NSString *url = [NSString stringWithFormat:@"//%@:%@@%@/%@", user, escaped(f[4]), host, share];
        NSString *said = nil;
        int rc = runTool(@"/sbin/mount_smbfs", @[ @"-N", url, point ], &said);
        if (rc == 0 || isMounted(point)) {
            NSUInteger left = sendOutbox(point, name);
            if (left) [report appendFormat:@"%@\twaiting:%lu\n", name, (unsigned long)left];
            else [report appendFormat:@"%@\tok\n", name];
        } else {
            // Not mounted after all: what was saved goes back where it was, in view, until the next try.
            NSString *outbox = outboxFolder(name);
            if ([files fileExistsAtPath:outbox] && runTool(@"/usr/bin/ditto", @[ outbox, point ], NULL) == 0)
                [files removeItemAtPath:outbox error:NULL];
            [report appendFormat:@"%@\t%@\n", name, [plainError(said) stringByReplacingOccurrencesOfString:@"\t" withString:@" "]];
        }
    }
    // Drives no longer on the list: let go of them, and of their empty folders.
    for (NSString *name in [files contentsOfDirectoryAtPath:folder error:NULL] ?: @[]) {
        if ([wanted containsObject:name] || [name hasPrefix:@"."]) continue;
        NSString *point = [folder stringByAppendingPathComponent:name];
        if (isMounted(point)) runTool(@"/sbin/umount", @[ point ], NULL);
        if (!isMounted(point)) rmdir(point.fileSystemRepresentation);
    }
    if (report.length) request(@"PUT", @"/.henge/drives-status", [report dataUsingEncoding:NSUTF8StringEncoding], &status, NULL);
}

int main(void) {
    @autoreleasepool {
        lastChange = NSPasteboard.generalPasteboard.changeCount;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followDevice(); });
        keepMounted();
        // One at a time, off the main thread: a computer that doesn't answer can hold a mount for a while.
        dispatch_queue_t drives = dispatch_queue_create("henge.drives", DISPATCH_QUEUE_SERIAL);
        // A newer helper in the app takes over: now, and every few minutes (Henge can be updated while macOS runs).
        dispatch_async(drives, ^{ updateSelf(); });
        [NSTimer scheduledTimerWithTimeInterval:300 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            dispatch_async(drives, ^{ updateSelf(); });
        }];
        dispatch_async(drives, ^{ keepDrivesMounted(); });
        [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            dispatch_async(drives, ^{ keepDrivesMounted(); });
        }];
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; checkClipboard(); }];
        [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) { (void)timer; keepMounted(); }];
        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
