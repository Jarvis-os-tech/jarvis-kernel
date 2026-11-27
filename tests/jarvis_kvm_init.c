#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>

#include "uapi_jarvis.h"

static void read_small(const char *path, char *buf, size_t sz) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        snprintf(buf, sz, "<unavailable: %s>", strerror(errno));
        return;
    }
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n < 0) {
        snprintf(buf, sz, "<read error: %s>", strerror(errno));
        return;
    }
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
        buf[--n] = '\0';
}

static int load_ko(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        if (errno == ENOENT)
            return 1; /* optional module absent (e.g. DIBS built-in) */
        fprintf(stderr, "open(%s) failed: %s\n", path, strerror(errno));
        return -1;
    }
    int rc = (int)syscall(SYS_finit_module, fd, "", 0);
    int saved = errno;
    close(fd);
    if (rc != 0) {
        fprintf(stderr, "finit_module(%s) failed: %s\n", path, strerror(saved));
        return -1;
    }
    return 0;
}

static void poweroff_vm(int exit_code) {
    fflush(stdout);
    fflush(stderr);
    sync();
    if (getpid() == 1) {
        reboot(RB_POWER_OFF);
        for (;;)
            pause();
    }
    exit(exit_code);
}

static int test_fd;
static atomic_int stop_test, unsafe_allowed, checks_done, reset_errors, resets_done;
static void *reset_rules(void *unused) {
    (void)unused;
    while (!atomic_load(&stop_test)) {
        if (ioctl(test_fd, JARVIS_IOC_POLICY_RESET, 0))
            atomic_fetch_add(&reset_errors, 1);
        else
            atomic_fetch_add(&resets_done, 1);
    }
    return NULL;
}
static void *check_rules(void *unused) {
    (void)unused;
    while (!atomic_load(&stop_test)) {
        struct jarvis_policy_check c = {};
        strcpy((char *)c.server, "ShellMCP");
        strcpy((char *)c.tool, "run");
        strcpy((char *)c.path, "/etc/passwd");
        if (!ioctl(test_fd, JARVIS_IOC_POLICY_CHECK, &c)) {
            atomic_fetch_add(&checks_done, 1);
            if (c.allowed || c.tier != JARVIS_TIER_FORBIDDEN)
                atomic_fetch_add(&unsafe_allowed, 1);
        } else {
            atomic_fetch_add(&reset_errors, 1);
        }
    }
    return NULL;
}
static int regression_checks(int fd) {
    test_fd = fd;
    pthread_t resetter, checker;
    if (pthread_create(&resetter, NULL, reset_rules, NULL)) return 1;
    if (pthread_create(&checker, NULL, check_rules, NULL)) {
        atomic_store(&stop_test, 1);
        pthread_join(resetter, NULL);
        return 1;
    }
    sleep(3);
    atomic_store(&stop_test, 1);
    pthread_join(resetter, NULL);
    pthread_join(checker, NULL);
    printf("POLICY_RESET_RACE checks=%d forbidden_allowed=%d resets=%d errors=%d\n",
           atomic_load(&checks_done), atomic_load(&unsafe_allowed),
           atomic_load(&resets_done), atomic_load(&reset_errors));
    return atomic_load(&checks_done) == 0 || atomic_load(&resets_done) == 0 ||
           atomic_load(&unsafe_allowed) != 0 ||
           atomic_load(&reset_errors) != 0;
}

int main(void) {
    int failures = 0;

    mkdir("/proc", 0755);
    mkdir("/sys", 0755);
    mkdir("/dev", 0755);
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    printf("\n=== JARVIS OS KVM Kernel Smoke Test ===\n");

    struct utsname uts;
    if (uname(&uts) == 0) {
        printf("[KERN] release=%s machine=%s version=%s\n",
               uts.release, uts.machine, uts.version);
    }

    char buf[512];
    read_small("/proc/sys/kernel/sched_bore", buf, sizeof(buf));
    printf("[SCHED] sched_bore=%s\n", buf);

    read_small("/sys/block/vda/queue/scheduler", buf, sizeof(buf));
    printf("[IO]    vda_scheduler=%s\n", buf);
    if (!strstr(buf, "adios")) {
        fprintf(stderr, "[WARN] adios scheduler missing on vda\n");
    }

    read_small("/proc/sys/net/ipv4/tcp_available_congestion_control", buf, sizeof(buf));
    printf("[NET]   tcp_available=%s\n", buf);
    read_small("/proc/sys/net/ipv4/tcp_congestion_control", buf, sizeof(buf));
    printf("[NET]   tcp_active=%s\n", buf);

    read_small("/sys/module/module/parameters/sig_enforce", buf, sizeof(buf));
    printf("[MOD]   sig_enforce=%s\n", buf);

    /* Load dibs.ko if modular, then jarvis.ko */
    if (load_ko("/lib/modules/dibs.ko") < 0)
        failures++;
    if (load_ko("/lib/modules/jarvis.ko") != 0) {
        fprintf(stderr, "[FAIL] failed to load /lib/modules/jarvis.ko\n");
        failures++;
        printf("=== JARVIS_KVM_SMOKE_FAIL (%d) ===\n", failures);
        poweroff_vm(1);
    }
    printf("[MOD]   jarvis.ko loaded cleanly\n");

    int jfd = open("/dev/jarvis", O_RDWR);
    if (jfd < 0) {
        fprintf(stderr, "[FAIL] open(/dev/jarvis): %s\n", strerror(errno));
        failures++;
    } else {
        struct jarvis_status st;
        memset(&st, 0, sizeof(st));
        if (ioctl(jfd, JARVIS_IOC_STATUS, &st) != 0) {
            fprintf(stderr, "[FAIL] JARVIS_IOC_STATUS: %s\n", strerror(errno));
            failures++;
        } else {
            printf("[DEV]   status.state=%u pending=%u\n", st.state, st.pending_queries);
        }

        struct jarvis_sysmon sm;
        memset(&sm, 0, sizeof(sm));
        if (ioctl(jfd, JARVIS_IOC_SYSMON, &sm) != 0) {
            fprintf(stderr, "[FAIL] JARVIS_IOC_SYSMON: %s\n", strerror(errno));
            failures++;
        } else {
            printf("[SYSMON] cpus=%u mem_total_mb=%llu mem_avail_mb=%llu thermal_zones=%u\n",
                   sm.cpu_count,
                   (unsigned long long)sm.mem_total_mb,
                   (unsigned long long)sm.mem_avail_mb,
                   sm.thermal_count);
            if (sm.cpu_count == 0 || sm.mem_total_mb == 0)
                failures++;
        }

        struct jarvis_policy_check chk;
        memset(&chk, 0, sizeof(chk));
        snprintf((char *)chk.server, sizeof(chk.server), "FileSystemMCP");
        snprintf((char *)chk.tool, sizeof(chk.tool), "read_file");
        if (ioctl(jfd, JARVIS_IOC_POLICY_CHECK, &chk) != 0 ||
            chk.tier != JARVIS_TIER_SAFE || chk.allowed != 1) {
            fprintf(stderr, "[FAIL] policy check read_file failed (tier=%u allowed=%u)\n",
                    chk.tier, chk.allowed);
            failures++;
        } else {
            printf("[POLICY] FileSystemMCP:read_file -> tier=%u allowed=%u (SAFE)\n",
                   chk.tier, chk.allowed);
        }

        memset(&chk, 0, sizeof(chk));
        snprintf((char *)chk.server, sizeof(chk.server), "ShellMCP");
        snprintf((char *)chk.tool, sizeof(chk.tool), "run");
        snprintf((char *)chk.path, sizeof(chk.path), "/etc/passwd");
        if (ioctl(jfd, JARVIS_IOC_POLICY_CHECK, &chk) != 0 ||
            chk.tier != JARVIS_TIER_FORBIDDEN || chk.allowed != 0) {
            fprintf(stderr, "[FAIL] policy check /etc/passwd failed (tier=%u allowed=%u)\n",
                    chk.tier, chk.allowed);
            failures++;
        } else {
            printf("[POLICY] ShellMCP:run(/etc/passwd) -> tier=%u allowed=%u (FORBIDDEN)\n",
                   chk.tier, chk.allowed);
        }

        /* A newly published, path-scoped deny rule takes priority until removed. */
        struct jarvis_policy_entry entry = {
            .pattern = "EchoMCP:echo", .path_prefix = "/tmp/guest-test",
            .tier = JARVIS_TIER_FORBIDDEN,
        };
        struct jarvis_policy_check echo = {
            .server = "EchoMCP", .tool = "echo", .path = "/tmp/guest-test",
        };
        if (ioctl(jfd, JARVIS_IOC_POLICY_ADD, &entry) ||
            ioctl(jfd, JARVIS_IOC_POLICY_CHECK, &echo) ||
            echo.tier != JARVIS_TIER_FORBIDDEN || echo.allowed ||
            ioctl(jfd, JARVIS_IOC_POLICY_DEL, entry.pattern) ||
            ioctl(jfd, JARVIS_IOC_POLICY_CHECK, &echo) ||
            echo.tier != JARVIS_TIER_SAFE || echo.allowed != 1) {
            fprintf(stderr, "[FAIL] guest policy add/check/delete\n");
            failures++;
        } else {
            printf("[POLICY] scoped deny added, enforced and removed\n");
        }

        failures += regression_checks(jfd);
        close(jfd);
    }

    read_small("/sys/class/misc/jarvis/state", buf, sizeof(buf));
    printf("[SYSFS] state=%s\n", buf);
    read_small("/sys/class/misc/jarvis/sysmon/mem_total", buf, sizeof(buf));
    printf("[SYSFS] sysmon/mem_total=%s MiB\n", buf);

    if (failures == 0)
        printf("=== JARVIS_KVM_SMOKE_PASS ===\n");
    else
        printf("=== JARVIS_KVM_SMOKE_FAIL (%d) ===\n", failures);

    poweroff_vm(failures == 0 ? 0 : 1);
    return 0;
}
