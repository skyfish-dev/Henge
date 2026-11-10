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
        if (isMounted(point)) {
            [report appendFormat:@"%@\tok\n", name];
            continue;
        }
        // Several addresses (home, then Tailscale): the first whose file sharing answers.
        NSString *host = nil;
        for (NSString *h in [f[1] componentsSeparatedByString:@","]) {
            NSString *t = [h stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length && answers(t)) { host = t; break; }
        }
        if (!host) {
            [report appendFormat:@"%@\t%@\n", name, @"The computer didn't answer. Is it on and awake, and on this network or Tailscale?"];
            continue;
        }
        NSString *user = f[3].length ? escaped(f[3]) : @"guest";
        NSString *share = [f[2] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: f[2];
        NSString *url = [NSString stringWithFormat:@"//%@:%@@%@/%@", user, escaped(f[4]), host, share];
        NSString *said = nil;
        int rc = runTool(@"/sbin/mount_smbfs", @[ @"-N", url, point ], &said);
        if (rc == 0 || isMounted(point)) [report appendFormat:@"%@\tok\n", name];
        else [report appendFormat:@"%@\t%@\n", name, [plainError(said) stringByReplacingOccurrencesOfString:@"\t" withString:@" "]];
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
