/*
 * dropexec: do one thing with an unprivileged user's rights, for the
 * module's root scripts.
 *
 *   dropexec run UID GID GROUPS PROG [ARG...]
 *       Run PROG (an absolute path) as UID:GID with the supplementary groups
 *       GROUPS (comma-separated gids, or "-" for none). PROG is opened before
 *       privileges are dropped, so it may live in a folder the user cannot
 *       enter (/data/adb is root-only).
 *
 *   dropexec read UID GID DIR NAME MAX
 *       Copy DIR/NAME to stdout with UID:GID's rights. DIR is opened as root,
 *       NAME inside it as the user. NAME must be a regular file of at most
 *       MAX bytes: symbolic links, folders, pipes and devices are refused, so
 *       a file the user may have replaced cannot make root read anything else.
 *
 * Exit status: 0 done, 125 file refused, 126 bad use or setup error,
 * 127 PROG could not be run.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

extern char **environ;

static void die(int code, const char *what)
{
    if (errno)
        fprintf(stderr, "dropexec: %s: %s\n", what, strerror(errno));
    else
        fprintf(stderr, "dropexec: %s\n", what);
    exit(code);
}

static void fail(int code, const char *what)
{
    errno = 0;
    die(code, what);
}

static unsigned long number(const char *s, unsigned long max)
{
    char *end;
    unsigned long v;

    if (*s < '0' || *s > '9')
        fail(126, "bad number");
    errno = 0;
    v = strtoul(s, &end, 10);
    if (errno || *end != '\0' || v > max)
        fail(126, "bad number");
    return v;
}

static unsigned long id(const char *s)
{
    unsigned long v = number(s, 2147483647UL);

    if (v == 0)
        fail(126, "refusing to keep root's user or group");
    return v;
}

/* Become UID:GID for good: no supplementary groups but GROUPS, no way
 * back to root, and no gaining privileges through exec. */
static void drop(const char *uid_s, const char *gid_s, const char *groups_s)
{
    uid_t uid = (uid_t)id(uid_s);
    gid_t gid = (gid_t)id(gid_s);
    gid_t groups[16];
    size_t n = 0;

    if (strcmp(groups_s, "-") != 0) {
        char buf[256], *tok, *save = NULL;

        if (strlen(groups_s) >= sizeof buf)
            fail(126, "group list too long");
        strcpy(buf, groups_s);
        for (tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            if (n == sizeof groups / sizeof groups[0])
                fail(126, "too many groups");
            groups[n++] = (gid_t)id(tok);
        }
    }
    if (setgroups(n, groups) != 0)
        die(126, "setgroups");
    if (setresgid(gid, gid, gid) != 0)
        die(126, "setresgid");
    if (setresuid(uid, uid, uid) != 0)
        die(126, "setresuid");
    if (setuid(0) == 0)
        fail(126, "could get root back");
    if (getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid)
        fail(126, "privileges not dropped");
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
        die(126, "no_new_privs");
}

static int do_run(char **a)    /* UID GID GROUPS PROG [ARG...] */
{
    int fd;

    if (a[3][0] != '/')
        fail(126, "PROG needs an absolute path");
    /* Not close-on-exec: a script's interpreter reads it as /dev/fd/N. */
    fd = open(a[3], O_RDONLY);
    if (fd < 0)
        die(127, a[3]);
    drop(a[0], a[1], a[2]);
    if (chdir("/") != 0)
        die(126, "chdir");
    syscall(SYS_execveat, fd, "", a + 3, environ, AT_EMPTY_PATH);
    die(127, a[3]);
    return 127;
}

static int do_read(char **a)   /* UID GID DIR NAME MAX */
{
    unsigned long max = number(a[4], 1UL << 30), total = 0;
    struct stat st;
    char buf[8192];
    ssize_t r;
    int dir, fd;

    if (a[3][0] == '\0' || strchr(a[3], '/') || !strcmp(a[3], ".") || !strcmp(a[3], ".."))
        fail(126, "NAME must be a plain file name");
    dir = open(a[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0)
        die(125, a[2]);
    drop(a[0], a[1], "-");
    fd = openat(dir, a[3], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (fd < 0)
        die(125, a[3]);
    if (fstat(fd, &st) != 0)
        die(125, a[3]);
    if (!S_ISREG(st.st_mode))
        fail(125, "not a regular file");
    if ((unsigned long long)st.st_size > max)
        fail(125, "file too large");
    while ((r = read(fd, buf, sizeof buf)) != 0) {
        ssize_t off = 0;

        if (r < 0) {
            if (errno == EINTR)
                continue;
            die(125, a[3]);
        }
        total += (unsigned long)r;
        if (total > max)
            fail(125, "file too large");
        while (off < r) {
            ssize_t w = write(STDOUT_FILENO, buf + off, (size_t)(r - off));

            if (w < 0) {
                if (errno == EINTR)
                    continue;
                die(126, "write");
            }
            off += w;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 6 && strcmp(argv[1], "run") == 0)
        return do_run(argv + 2);
    if (argc == 7 && strcmp(argv[1], "read") == 0)
        return do_read(argv + 2);
    fprintf(stderr,
            "usage: dropexec run UID GID GROUPS PROG [ARG...]\n"
            "       dropexec read UID GID DIR NAME MAX\n");
    return 126;
}
