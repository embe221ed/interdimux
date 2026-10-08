/*
 * benchrun.c -- the measuring half of bench.sh (interdimux A/B harness).
 *
 * One multi-call binary, compiled by bench.sh into its work dir:
 *
 *   benchrun run [-t COLSxROWS] [-p] [-i IN] [-o OUT] [-e ERR] [-s PID [-P]]
 *                [-g GRACE_MS] [-r RESULT] -- CMD ARGS...
 *       Runs CMD once and appends ONE line to RESULT (default stdout):
 *         wall_us cpu_us srv_us status start_rt_us orphans killed jobs
 *         jobs_killed jobs_us
 *       wall_us  fork -> the command's own exit (CLOCK_MONOTONIC)
 *       cpu_us   user+sys of the whole process tree: the command, every
 *                descendant it waited for, AND every orphan it left behind
 *                (this process is a child subreaper, so a backgrounded or
 *                disowned descendant is reparented here and reaped with its
 *                rusage instead of escaping the measurement)
 *       srv_us   CPU the tmux server (-s PID) spent meanwhile: its own, from
 *                /proc/PID/schedstat (ns resolution) -- the format expansion
 *                a `list-panes -F ...` costs happens there, not in the
 *                client -- PLUS jobs_us
 *       status   the command's wait status, decoded: exit code, or 128+signal
 *       start_rt_us  CLOCK_REALTIME at fork, for the fzf stub's arrival stamp
 *       orphans  descendants still alive when the command exited
 *       killed   of those, how many outlived GRACE_MS and were SIGKILLed
 *       jobs     the server's jobs (run-shell, if-shell, a hook's run-shell,
 *                #()) still running when the command and its orphans were
 *                done: waited for, like the orphans, up to GRACE_MS.  With
 *                -P, every process the server started meanwhile counts as
 *                one, a popup's too (it has a pty, so it is no job
 *                otherwise): a key whose binding opens a popup is measured
 *                to the popup's end
 *       jobs_killed  of those, how many outlived it and were SIGKILLed
 *       jobs_us  what the server's jobs cost meanwhile: the growth of its
 *                cutime+cstime (/proc/PID/stat), which a job's CPU joins when
 *                the server reaps it.  The kernel reports those in clock
 *                ticks (10 ms), so one run's figure is a multiple of 10 ms,
 *                right on average over many runs.  A job's own orphans
 *                (reparented to init, not the server) escape it.
 *     -P is for a command that presses a key: the processes the server
 *     already had (its panes) are left out, and every one it starts is
 *     waited for and its CPU counted -- in whole clock ticks, as jobs_us.
 *     At least one is waited for (up to GRACE_MS): the binding runs after
 *     the client that sent the key is gone, so its popup may come later.
 *     -t gives the command a fresh pty of that size as its CONTROLLING
 *     terminal (a popup has one, and `stty size </dev/tty` reads it); -p also
 *     makes the pty its stdin/stdout/stderr, like a display-popup command, and
 *     drains it into OUT.  The command runs in a new session either way.
 *
 *   benchrun hogs MS PCT [EXCLUDE_SID...]
 *       Samples every process twice, MS apart, and prints "pid pct comm" for
 *       each that used more than PCT% of one CPU in between.
 *
 *   fzf (argv[0] basename "fzf", via a symlink) -- the stub fzf:
 *       --version anywhere in argv: prints $BENCH_FZF_VERSION, exits 0.
 *       BENCH_FZF_MODE=first: stamps CLOCK_REALTIME when the FIRST complete
 *         line arrives on stdin, drains the rest, writes
 *         "$BENCH_FZF_OUT.t" = "first_us last_us bytes lines accept_us" and
 *         the rows to "$BENCH_FZF_OUT.rows", exits 130 (what Esc makes fzf
 *         return).  Every mode that writes .t writes those five fields, and
 *         accept_us is 0 unless accept took a row.
 *       BENCH_FZF_MODE=accept: as first, then Enter on the row whose last
 *         tab-separated field (the spec the navigator reads) is
 *         $BENCH_FZF_ACCEPT, printed as fzf prints a selection: the query
 *         line first under --print-query (empty: nothing was typed), then
 *         the row with its ANSI codes stripped (--ansi); exits 0.  The
 *         CLOCK_REALTIME of that moment is .t's accept_us.  No such row:
 *         exits 130, accept_us 0.
 *       BENCH_FZF_MODE=hold: writes its argv (NUL-separated) to .args, its
 *         environment to .env, drains stdin to .rows, then .ready, and waits
 *         until "$BENCH_FZF_OUT.release" exists (or $BENCH_PID is gone), then
 *         exits 130.  This keeps a navigator alive with its state files, so
 *         callbacks can run with exactly the environment fzf would give them.
 *       anything else: drains stdin, exits 130.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int64_t now_us(clockid_t c) {
  struct timespec ts;
  clock_gettime(c, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static int64_t tv_us(struct timeval tv) { return (int64_t)tv.tv_sec * 1000000 + tv.tv_usec; }

/* sum_exec_runtime of every thread of PID, in ns; -1 when unreadable */
static int64_t schedstat_ns(pid_t pid) {
  char path[64];
  if (pid <= 0) return -1;
  snprintf(path, sizeof path, "/proc/%d/task", (int)pid);
  DIR *d = opendir(path);
  if (!d) return -1;
  int64_t total = 0;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!isdigit((unsigned char)e->d_name[0])) continue;
    char p[320];
    snprintf(p, sizeof p, "/proc/%d/task/%s/schedstat", (int)pid, e->d_name);
    FILE *f = fopen(p, "r");
    if (!f) continue;
    long long v = 0;
    if (fscanf(f, "%lld", &v) == 1) total += v;
    fclose(f);
  }
  closedir(d);
  return total;
}

/* A /proc/PID/stat line's fields after the command name: FIELD[0] is the
 * state (field 3 of proc(5)), FIELD[1] the ppid, and so on.  Returns how many
 * were read (at most MAX), 0 when the process is gone. */
static int stat_fields(pid_t pid, long long *field, int max, char *state) {
  char p[64], buf[1024];
  snprintf(p, sizeof p, "/proc/%d/stat", (int)pid);
  int fd = open(p, O_RDONLY);
  if (fd < 0) return 0;
  ssize_t r = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (r <= 0) return 0;
  buf[r] = 0;
  char *rp = strrchr(buf, ')');
  if (!rp || rp[1] != ' ') return 0;
  char *q = rp + 2;
  if (state) *state = *q;
  int n = 0;
  q = strchr(q, ' ');
  while (q && n < max) {
    char *e;
    long long v = strtoll(q + 1, &e, 10);
    if (e == q + 1) break;
    field[n++] = v;
    q = (*e == ' ') ? e : NULL;
  }
  return n;
}

/* what the server's reaped children cost, in us: cutime + cstime, fields 16
 * and 17 of proc(5) (in clock ticks); -1 when unreadable */
static int64_t children_us(pid_t pid) {
  long long f[16];
  if (pid <= 0 || stat_fields(pid, f, 16, NULL) < 15) return -1;
  /* f[0] = ppid (field 4) ... f[12] = cutime (16), f[13] = cstime (17) */
  long hz = sysconf(_SC_CLK_TCK);
  return (f[12] + f[13]) * 1000000 / (hz > 0 ? hz : 100);
}

/* The tmux server's jobs: its children without a controlling terminal.  A
 * pane's process has its pty, and a popup's too; run-shell, if-shell, #() and
 * the hooks' run-shell get a socketpair.  With ALL, every child: popups and
 * panes too.  Zombies count: their CPU joins the server's cutime only once it
 * reaps them. */
static int server_jobs(pid_t srv, pid_t *out, int max, int all) {
  DIR *d = opendir("/proc");
  if (!d) return 0;
  int n = 0;
  struct dirent *e;
  while ((e = readdir(d)) && n < max) {
    if (!isdigit((unsigned char)e->d_name[0])) continue;
    long long f[5];
    pid_t pid = (pid_t)atoi(e->d_name);
    /* f[0] ppid, f[1] pgrp, f[2] session, f[3] tty_nr */
    if (stat_fields(pid, f, 5, NULL) < 4) continue;
    if (f[0] == srv && (all || f[3] == 0)) out[n++] = pid;
  }
  closedir(d);
  return n;
}

/* Wait until the server has no job left but those in BASE (NBASE of them),
 * up to DEADLINE (CLOCK_MONOTONIC us).  With KILL, then SIGKILL what is left
 * and give the server a second to reap it.  Returns how many it killed;
 * *seen += every job it waited for.  ALL: every child counts (server_jobs).
 * NEED: one is waited for to appear too (until DEADLINE) before it is waited
 * for to end -- a key's binding runs only once the client that sent the key
 * has gone, so the popup it opens may not be there yet. */
#define MAXJOBS 1024
static int settle_jobs(pid_t srv, int64_t deadline, const pid_t *base, int nbase, int kill_left, int *seen,
                       int all, int need) {
  pid_t known[MAXJOBS];
  int nknown = 0, killed = 0;
  for (;;) {
    pid_t js[MAXJOBS];
    int nj = server_jobs(srv, js, MAXJOBS, all), left = 0;
    for (int k = 0; k < nj; k++) {
      int skip = 0;
      for (int m = 0; m < nbase; m++) if (base[m] == js[k]) skip = 1;
      if (skip) continue;
      js[left++] = js[k];
      for (int m = 0; m < nknown; m++) if (known[m] == js[k]) skip = 1;
      if (!skip && nknown < MAXJOBS) known[nknown++] = js[k];
    }
    if (left == 0 && (!need || nknown > 0 || now_us(CLOCK_MONOTONIC) >= deadline)) break;
    if (left > 0 && now_us(CLOCK_MONOTONIC) >= deadline) {
      if (!kill_left || killed) break;   /* killed once already: the second is up */
      for (int k = 0; k < left; k++) { kill(js[k], SIGKILL); killed++; }
      deadline = now_us(CLOCK_MONOTONIC) + 1000000;
      continue;
    }
    struct timespec ts = { 0, 2000000 };
    nanosleep(&ts, NULL);
  }
  if (seen) *seen += nknown;
  return killed;
}

static void write_all(int fd, const char *b, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, b, n);
    if (w < 0) { if (errno == EINTR) continue; return; }
    b += w; n -= (size_t)w;
  }
}

/* ------------------------------------------------------------------ run -- */

static volatile pid_t g_child = 0;
/* Kill the measured command's whole session, then die BY the signal: a child
 * that merely exits 130 tells bash it handled the Ctrl-C itself ("wait and
 * cooperative exit"), and bench.sh's INT trap would never run. */
static void on_term(int sig) {
  if (g_child > 0) kill(-g_child, SIGKILL);
  signal(sig, SIG_DFL);
  sigset_t s;
  sigemptyset(&s);
  sigaddset(&s, sig);
  sigprocmask(SIG_UNBLOCK, &s, NULL);
  raise(sig);
  _exit(128 + sig);
}

/* pids whose parent is us (reparented orphans included) */
static int our_children(pid_t *out, int max) {
  DIR *d = opendir("/proc");
  if (!d) return 0;
  pid_t me = getpid();
  int n = 0;
  struct dirent *e;
  while ((e = readdir(d)) && n < max) {
    if (!isdigit((unsigned char)e->d_name[0])) continue;
    char p[300], buf[512];
    snprintf(p, sizeof p, "/proc/%s/stat", e->d_name);
    int fd = open(p, O_RDONLY);
    if (fd < 0) continue;
    ssize_t r = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (r <= 0) continue;
    buf[r] = 0;
    char *rp = strrchr(buf, ')');
    if (!rp) continue;
    char st; int ppid;
    if (sscanf(rp + 2, "%c %d", &st, &ppid) != 2) continue;
    if (ppid == me) out[n++] = atoi(e->d_name);
  }
  closedir(d);
  return n;
}

static int cmd_run(int argc, char **argv) {
  const char *tty = NULL, *in = NULL, *out = NULL, *err = NULL, *result = NULL;
  int popup = 0, grace_ms = 3000, allkids = 0;
  pid_t srv = 0;
  int i = 0;
  for (; i < argc; i++) {
    if (!strcmp(argv[i], "--")) { i++; break; }
    if (i + 1 >= argc && strcmp(argv[i], "-p") && strcmp(argv[i], "-P")) { fprintf(stderr, "benchrun: %s needs a value\n", argv[i]); return 2; }
    if (!strcmp(argv[i], "-t")) tty = argv[++i];
    else if (!strcmp(argv[i], "-p")) popup = 1;
    else if (!strcmp(argv[i], "-P")) allkids = 1;
    else if (!strcmp(argv[i], "-i")) in = argv[++i];
    else if (!strcmp(argv[i], "-o")) out = argv[++i];
    else if (!strcmp(argv[i], "-e")) err = argv[++i];
    else if (!strcmp(argv[i], "-s")) srv = (pid_t)atoi(argv[++i]);
    else if (!strcmp(argv[i], "-g")) grace_ms = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-r")) result = argv[++i];
    else { fprintf(stderr, "benchrun: unknown option %s\n", argv[i]); return 2; }
  }
  if (i >= argc) { fprintf(stderr, "benchrun run: no command\n"); return 2; }
  char **cmd = argv + i;

  int master = -1;
  char slave[128] = "";
  if (tty) {
    int cols = 0, rows = 0;
    if (sscanf(tty, "%dx%d", &cols, &rows) != 2 || cols <= 0 || rows <= 0) {
      fprintf(stderr, "benchrun: bad -t %s\n", tty); return 2;
    }
    master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0 || grantpt(master) || unlockpt(master) || ptsname_r(master, slave, sizeof slave)) {
      perror("benchrun: pty"); return 2;
    }
    struct winsize ws = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols };
    ioctl(master, TIOCSWINSZ, &ws);
  }
  int outfd = -1;
  if (out) {
    outfd = open(out, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (outfd < 0) { perror(out); return 2; }
  }

  prctl(PR_SET_CHILD_SUBREAPER, 1);
  sigset_t mask, old;
  sigemptyset(&mask);
  sigaddset(&mask, SIGCHLD);
  sigprocmask(SIG_BLOCK, &mask, &old);
  int sfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
  struct sigaction sa = { 0 };
  sa.sa_handler = on_term;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);

  /* A job from before this run (a holder's, say) is given a second to end,
   * so its CPU does not land in this run's figures; one that lives on is
   * neither waited for nor killed below.  With -P, neither are the panes. */
  pid_t base[MAXJOBS];
  int nbase = 0;
  if (srv > 0) {
    settle_jobs(srv, now_us(CLOCK_MONOTONIC) + 1000000, NULL, 0, 0, NULL, 0, 0);
    nbase = server_jobs(srv, base, MAXJOBS, allkids);
  }
  int64_t srv0 = schedstat_ns(srv), job0 = children_us(srv);
  int64_t rt0 = now_us(CLOCK_REALTIME);
  int64_t t0 = now_us(CLOCK_MONOTONIC);
  pid_t pid = fork();
  if (pid < 0) { perror("fork"); return 2; }
  if (pid == 0) {
    sigprocmask(SIG_SETMASK, &old, NULL);
    signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    setsid();
    int ttyfd = -1;
    if (tty) {
      ttyfd = open(slave, O_RDWR);          /* a session leader's first tty: the ctty */
      if (ttyfd < 0) _exit(126);
      ioctl(ttyfd, TIOCSCTTY, 0);
    }
    int fd0 = -1, fd1 = -1, fd2 = -1;
    if (popup) { fd0 = fd1 = fd2 = ttyfd; }
    else {
      fd0 = open(in ? in : "/dev/null", O_RDONLY);
      fd1 = outfd >= 0 ? outfd : open("/dev/null", O_WRONLY);
      fd2 = err ? open(err, O_WRONLY | O_CREAT | O_TRUNC, 0600) : open("/dev/null", O_WRONLY);
    }
    if (fd0 < 0 || fd1 < 0 || fd2 < 0) _exit(126);
    dup2(fd0, 0); dup2(fd1, 1); dup2(fd2, 2);
    if (ttyfd > 2) close(ttyfd);
    execvp(cmd[0], cmd);
    _exit(127);
  }
  g_child = pid;

  int64_t cpu = 0, t1 = -1;
  int status = 0, done = 0, orphans = -1, killed = 0;
  int64_t deadline = 0;
  char buf[65536];
  for (;;) {
    struct pollfd pf[2];
    int n = 0;
    pf[n].fd = sfd; pf[n].events = POLLIN; n++;
    int mi = -1;
    if (popup && master >= 0) { mi = n; pf[n].fd = master; pf[n].events = POLLIN; n++; }
    int timeout = -1;
    if (done) {
      int64_t left = (deadline - now_us(CLOCK_MONOTONIC)) / 1000;
      timeout = left > 0 ? (int)left : 0;
    }
    int pr = poll(pf, n, timeout);
    if (pr < 0 && errno != EINTR) break;
    if (mi >= 0 && (pf[mi].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t r = read(master, buf, sizeof buf);
      if (r > 0) { if (outfd >= 0) write_all(outfd, buf, (size_t)r); }
      else if (r <= 0 && (pf[mi].revents & (POLLHUP | POLLERR)) && !(pf[mi].revents & POLLIN)) {
        /* no slave open right now: stop polling it until something reopens it */
        if (done) { close(master); master = -1; }
        else { struct timespec ts = { 0, 1000000 }; nanosleep(&ts, NULL); }
      }
    }
    struct signalfd_siginfo si;
    while (read(sfd, &si, sizeof si) == sizeof si) { /* drain */ }
    for (;;) {
      struct rusage ru;
      int st;
      pid_t w = wait4(-1, &st, WNOHANG, &ru);
      if (w <= 0) break;
      cpu += tv_us(ru.ru_utime) + tv_us(ru.ru_stime);
      if (w == pid) {
        t1 = now_us(CLOCK_MONOTONIC);
        status = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
        done = 1;
        deadline = t1 + (int64_t)grace_ms * 1000;
      }
    }
    if (done) {
      pid_t kids[4096];
      int nk = our_children(kids, 4096);
      if (orphans < 0) orphans = nk;
      if (nk == 0) break;
      if (now_us(CLOCK_MONOTONIC) >= deadline) {
        for (int k = 0; k < nk; k++) { kill(kids[k], SIGKILL); killed++; }
        /* reap what we just killed */
        for (int tries = 0; tries < 200; tries++) {
          struct rusage ru; int st;
          pid_t w = wait4(-1, &st, WNOHANG, &ru);
          if (w > 0) { cpu += tv_us(ru.ru_utime) + tv_us(ru.ru_stime); continue; }
          if (w < 0) break;
          struct timespec ts = { 0, 5000000 }; nanosleep(&ts, NULL);
        }
        break;
      }
      if (timeout != 0) { struct timespec ts = { 0, 2000000 }; nanosleep(&ts, NULL); }
    }
  }
  /* the server's jobs the command started and did not wait for (run-shell
   * -b, a hook's run-shell; with -P, a popup): the same grace as the orphans */
  int jobs = 0, jobs_killed = 0;
  if (srv > 0)
    jobs_killed = settle_jobs(srv, now_us(CLOCK_MONOTONIC) + (int64_t)grace_ms * 1000, base, nbase, 1, &jobs,
                              allkids, allkids);
  int64_t srv1 = schedstat_ns(srv), job1 = children_us(srv);
  int64_t srv_us = (srv0 >= 0 && srv1 >= 0) ? (srv1 - srv0) / 1000 : 0;
  int64_t jobs_us = (job0 >= 0 && job1 >= job0) ? job1 - job0 : 0;
  srv_us += jobs_us;
  if (orphans < 0) orphans = 0;
  if (t1 < 0) t1 = now_us(CLOCK_MONOTONIC);

  char line[256];
  int len = snprintf(line, sizeof line, "%lld %lld %lld %d %lld %d %d %d %d %lld\n",
                     (long long)(t1 - t0), (long long)cpu, (long long)srv_us, status,
                     (long long)rt0, orphans, killed, jobs, jobs_killed, (long long)jobs_us);
  if (result) {
    int rf = open(result, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (rf < 0) { perror(result); return 2; }
    write_all(rf, line, (size_t)len);
    close(rf);
  } else {
    write_all(1, line, (size_t)len);
  }
  return 0;
}

/* ----------------------------------------------------------------- hogs -- */

struct ps { int pid; long long ticks; int sid; char comm[64]; };

static int snap(struct ps *v, int max) {
  DIR *d = opendir("/proc");
  if (!d) return 0;
  int n = 0;
  struct dirent *e;
  while ((e = readdir(d)) && n < max) {
    if (!isdigit((unsigned char)e->d_name[0])) continue;
    char p[300], buf[1024];
    snprintf(p, sizeof p, "/proc/%s/stat", e->d_name);
    int fd = open(p, O_RDONLY);
    if (fd < 0) continue;
    ssize_t r = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (r <= 0) continue;
    buf[r] = 0;
    char *lp = strchr(buf, '('), *rp = strrchr(buf, ')');
    if (!lp || !rp) continue;
    size_t cl = (size_t)(rp - lp - 1);
    if (cl >= sizeof v[n].comm) cl = sizeof v[n].comm - 1;
    memcpy(v[n].comm, lp + 1, cl);
    v[n].comm[cl] = 0;
    /* fields after ')': state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime */
    char st; int ppid, pgrp, sid, ttynr, tpgid; unsigned flags;
    unsigned long minf, cminf, majf, cmajf, ut, stt;
    if (sscanf(rp + 2, "%c %d %d %d %d %d %u %lu %lu %lu %lu %lu %lu", &st, &ppid, &pgrp, &sid, &ttynr,
               &tpgid, &flags, &minf, &cminf, &majf, &cmajf, &ut, &stt) != 13) continue;
    v[n].pid = atoi(e->d_name);
    v[n].ticks = (long long)ut + (long long)stt;
    v[n].sid = sid;
    n++;
  }
  closedir(d);
  return n;
}

static int cmd_hogs(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "benchrun hogs MS PCT [SID...]\n"); return 2; }
  int ms = atoi(argv[0]);
  double pct = atof(argv[1]);
  static struct ps a[32768], b[32768];
  int na = snap(a, 32768);
  int64_t t0 = now_us(CLOCK_MONOTONIC);
  struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000 };
  nanosleep(&ts, NULL);
  int nb = snap(b, 32768);
  double secs = (double)(now_us(CLOCK_MONOTONIC) - t0) / 1e6;
  long hz = sysconf(_SC_CLK_TCK);
  for (int j = 0; j < nb; j++) {
    int skip = 0;
    for (int k = 2; k < argc; k++) if (b[j].sid == atoi(argv[k])) skip = 1;
    if (skip) continue;
    for (int i = 0; i < na; i++) {
      if (a[i].pid != b[j].pid) continue;
      double used = (double)(b[j].ticks - a[i].ticks) / (double)hz / secs * 100.0;
      if (used > pct) printf("%d %.0f %s\n", b[j].pid, used, b[j].comm);
      break;
    }
  }
  return 0;
}

/* ------------------------------------------------------------------ fzf -- */

static void save(const char *base, const char *ext, const char *data, size_t n) {
  char p[4096], t[4200];
  snprintf(p, sizeof p, "%s%s", base, ext);
  snprintf(t, sizeof t, "%s.tmp", p);
  int fd = open(t, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return;
  write_all(fd, data, n);
  close(fd);
  rename(t, p);
}

static int stub_fzf(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--version")) {
      const char *v = getenv("BENCH_FZF_VERSION");
      printf("%s\n", v && *v ? v : "0.74.3 (bench)");
      return 0;
    }
  }
  const char *mode = getenv("BENCH_FZF_MODE");
  const char *out = getenv("BENCH_FZF_OUT");
  if (!mode || !out || !*out) mode = "drain";
  char p[4096];

  if (!strcmp(mode, "hold")) {
    /* argv and environment first: what the navigator handed fzf */
    size_t cap = 1 << 16, len = 0;
    char *b = malloc(cap);
    for (int i = 1; i < argc; i++) {
      size_t l = strlen(argv[i]) + 1;
      while (len + l > cap) { cap *= 2; b = realloc(b, cap); }
      memcpy(b + len, argv[i], l);
      len += l;
    }
    save(out, ".args", b, len);
    len = 0;
    for (char **e = environ; *e; e++) {
      size_t l = strlen(*e) + 1;
      while (len + l > cap) { cap *= 2; b = realloc(b, cap); }
      memcpy(b + len, *e, l);
      len += l;
    }
    save(out, ".env", b, len);
    free(b);
    char pid[32];
    int pl = snprintf(pid, sizeof pid, "%d\n", (int)getpid());
    save(out, ".pid", pid, (size_t)pl);
  }

  /* drain stdin, stamping the first complete line */
  size_t cap = 1 << 16, len = 0, lines = 0;
  char *rows = malloc(cap);
  int64_t first = -1, last = -1;
  for (;;) {
    if (len + 65536 > cap) { cap *= 2; rows = realloc(rows, cap); }
    ssize_t r = read(0, rows + len, 65536);
    if (r < 0) { if (errno == EINTR) continue; break; }
    if (r == 0) break;
    int64_t t = now_us(CLOCK_REALTIME);
    for (ssize_t k = 0; k < r; k++) {
      if (rows[len + k] == '\n') { lines++; if (first < 0) first = t; }
    }
    last = t;
    len += (size_t)r;
  }
  int rc = 130;
  int64_t acc = 0;
  if (!strcmp(mode, "accept")) {
    const char *want = getenv("BENCH_FZF_ACCEPT");
    size_t wl = want ? strlen(want) : 0;
    int pq = 0;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--print-query")) pq = 1;
    char *plain = malloc(len + 1);
    for (size_t s = 0; wl > 0 && s < len;) {
      char *nl = memchr(rows + s, '\n', len - s);
      size_t e = nl ? (size_t)(nl - rows) : len, pl = 0;
      for (size_t k = s; k < e; k++) {
        if (rows[k] == 0x1b && k + 1 < e && rows[k + 1] == '[') {   /* CSI ... final byte */
          for (k += 2; k < e && !(rows[k] >= 0x40 && rows[k] <= 0x7e); k++) {}
          continue;
        }
        plain[pl++] = rows[k];
      }
      char *tab = memrchr(plain, '\t', pl);
      size_t from = tab ? (size_t)(tab - plain) + 1 : 0;
      if (pl - from == wl && !memcmp(plain + from, want, wl)) {
        acc = now_us(CLOCK_REALTIME);
        if (pq) write_all(1, "\n", 1);
        plain[pl++] = '\n';
        write_all(1, plain, pl);
        rc = 0;
        break;
      }
      s = e + 1;
    }
    free(plain);
  }
  if (strcmp(mode, "drain")) {
    save(out, ".rows", rows, len);
    char t[160];
    int tl = snprintf(t, sizeof t, "%lld %lld %zu %zu %lld\n", (long long)first, (long long)last, len, lines,
                      (long long)acc);
    save(out, ".t", t, (size_t)tl);
  }
  free(rows);

  if (!strcmp(mode, "hold")) {
    save(out, ".ready", "1\n", 2);
    const char *bp = getenv("BENCH_PID");
    pid_t bench = bp ? (pid_t)atoi(bp) : 0;
    snprintf(p, sizeof p, "%s.release", out);
    for (;;) {
      if (access(p, F_OK) == 0) break;
      if (bench > 0 && kill(bench, 0) != 0 && errno == ESRCH) break;
      struct timespec ts = { 0, 200000000 };
      nanosleep(&ts, NULL);
    }
  }
  return rc;
}

int main(int argc, char **argv) {
  const char *base = strrchr(argv[0], '/');
  base = base ? base + 1 : argv[0];
  if (!strcmp(base, "fzf")) return stub_fzf(argc, argv);
  if (argc >= 2 && !strcmp(argv[1], "run")) return cmd_run(argc - 2, argv + 2);
  if (argc >= 2 && !strcmp(argv[1], "hogs")) return cmd_hogs(argc - 2, argv + 2);
  fprintf(stderr, "usage: benchrun run|hogs ...  (or invoked as fzf)\n");
  return 2;
}
