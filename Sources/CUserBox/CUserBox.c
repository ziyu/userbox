#define _GNU_SOURCE
#include "CUserBox.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#ifdef __APPLE__
#include <libproc.h>
#include <Security/AuthSession.h>
#include <ApplicationServices/ApplicationServices.h>
#endif

static int address(const char *path, struct sockaddr_un *a) {
    if (!path || strlen(path) >= sizeof(a->sun_path)) { errno = ENAMETOOLONG; return -1; }
    memset(a, 0, sizeof(*a)); a->sun_family = AF_UNIX;
    memcpy(a->sun_path, path, strlen(path) + 1); return 0;
}
static int new_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0) {
        fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef __APPLE__
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        ub_set_timeout(fd, 30);
    }
    return fd;
}
int ub_listen(const char *path) {
    struct sockaddr_un a; if (address(path, &a)) return -1;
    // Never unlink an arbitrary existing path. A stale socket must belong to this UID.
    struct stat st;
    if (!lstat(path, &st)) {
        if (!S_ISSOCK(st.st_mode) || st.st_uid != getuid()) { errno = EPERM; return -1; }
        int probe = ub_connect(path);
        if (probe >= 0) { ub_close(probe); errno = EADDRINUSE; return -1; }
        if (errno != ECONNREFUSED && errno != ENOENT) return -1;
        if (unlink(path)) return -1;
    } else if (errno != ENOENT) return -1;
    int fd = new_socket(); if (fd < 0) return -1;
    mode_t old = umask(0117); // socket 0660, inside a provisioned 0750 private group directory
    int result = bind(fd, (struct sockaddr *)&a, sizeof(a)); umask(old);
    if (result || listen(fd, 8)) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}
int ub_connect(const char *path) {
    struct sockaddr_un a; if (address(path, &a)) return -1;
    int fd = new_socket(); if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof(a))) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}
int ub_accept(int fd) {
    int client;
    do { client = accept(fd, NULL, NULL); } while (client < 0 && errno == EINTR);
    if (client >= 0) {
        fcntl(client, F_SETFD, FD_CLOEXEC); ub_set_timeout(client, 30);
#ifdef __APPLE__
        int one = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    }
    return client;
}
int ub_peer_uid(int fd, uint32_t *uid) {
#ifdef __APPLE__
    uid_t u; gid_t g; if (getpeereid(fd, &u, &g)) return -1; *uid = u;
#else
    struct ucred c; socklen_t len = sizeof(c);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &c, &len)) return -1; *uid = c.uid;
#endif
    return 0;
}
int ub_read_exact(int fd, void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = read(fd, (char *)buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (!n) errno = ECONNRESET; return -1; }
        done += (size_t)n;
    }
    return 0;
}
int ub_write_exact(int fd, const void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
#ifdef __APPLE__
        ssize_t n = send(fd, (const char *)buffer + done, count - done, 0);
#else
        ssize_t n = send(fd, (const char *)buffer + done, count - done, MSG_NOSIGNAL);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}
void ub_close(int fd) { if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); } }
int ub_set_timeout(int fd, int seconds) {
    struct timeval t = {seconds, 0};
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof(t)) |
           setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof(t));
}
uint32_t ub_uid(void) { return getuid(); }
uint32_t ub_console_uid(void) {
    struct stat st; return stat("/dev/console", &st) ? UINT32_MAX : st.st_uid;
}
int ub_secure_config(const char *path) {
    struct stat st;
    if (lstat(path, &st)) return 0;
    return S_ISREG(st.st_mode) && st.st_uid == 0 && !(st.st_mode & 0022);
}
int ub_session(uint32_t *sid, uint32_t *uid, int *graphical, int *console, int *loggedIn) {
#ifdef __APPLE__
    SecuritySessionId session; SessionAttributeBits bits;
    if (SessionGetInfo(callerSecuritySession, &session, &bits) != errSessionSuccess) return -1;
    CFDictionaryRef dict = CGSessionCopyCurrentDictionary(); if (!dict) return -1;
    CFNumberRef user = CFDictionaryGetValue(dict, kCGSessionUserIDKey);
    CFBooleanRef onConsole = CFDictionaryGetValue(dict, kCGSessionOnConsoleKey);
    CFBooleanRef login = CFDictionaryGetValue(dict, kCGSessionLoginDoneKey);
    int64_t userValue = -1;
    int valid = user && CFGetTypeID(user) == CFNumberGetTypeID() &&
        CFNumberGetValue(user, kCFNumberSInt64Type, &userValue) && userValue >= 0 &&
        onConsole && CFGetTypeID(onConsole) == CFBooleanGetTypeID() &&
        login && CFGetTypeID(login) == CFBooleanGetTypeID();
    if (valid) {
        *sid = session; *uid = (uint32_t)userValue;
        *graphical = (bits & sessionHasGraphicAccess) != 0;
        *console = CFBooleanGetValue(onConsole); *loggedIn = CFBooleanGetValue(login);
    }
    CFRelease(dict); return valid ? 0 : -1;
#else
    (void)sid; (void)uid; (void)graphical; (void)console; (void)loggedIn;
    errno = ENOTSUP; return -1;
#endif
}

uint32_t ub_process_uid(int pid) {
#ifdef __APPLE__
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return UINT32_MAX;
    return info.pbi_uid;
#else
    (void)pid; return UINT32_MAX;
#endif
}
