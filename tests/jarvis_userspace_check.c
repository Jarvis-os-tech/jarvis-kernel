#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "uapi_jarvis.h"

int main(void) {
    struct stat st_dev;
    if (stat("/dev/jarvis", &st_dev) != 0) {
        fprintf(stderr, "FAIL: /dev/jarvis missing: %s\n", strerror(errno));
        return 1;
    }
    printf("DEV_MODE=%04o GID=%u\n", st_dev.st_mode & 0777, (unsigned)st_dev.st_gid);

    int fd = open("/dev/jarvis", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "FAIL: open(/dev/jarvis): %s\n", strerror(errno));
        return 1;
    }

    struct jarvis_status jst;
    memset(&jst, 0, sizeof(jst));
    if (ioctl(fd, JARVIS_IOC_STATUS, &jst) != 0) {
        fprintf(stderr, "FAIL: JARVIS_IOC_STATUS: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    printf("JARVIS_STATUS state=%u pending=%u\n", jst.state, jst.pending_queries);

    struct jarvis_sysmon sm;
    memset(&sm, 0, sizeof(sm));
    if (ioctl(fd, JARVIS_IOC_SYSMON, &sm) != 0) {
        fprintf(stderr, "FAIL: JARVIS_IOC_SYSMON: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    printf("JARVIS_SYSMON cpus=%u mem_total_mb=%llu mem_avail_mb=%llu\n",
           sm.cpu_count,
           (unsigned long long)sm.mem_total_mb,
           (unsigned long long)sm.mem_avail_mb);

    struct jarvis_policy_check chk;
    memset(&chk, 0, sizeof(chk));
    snprintf((char *)chk.server, sizeof(chk.server), "FileSystemMCP");
    snprintf((char *)chk.tool, sizeof(chk.tool), "read_file");
    if (ioctl(fd, JARVIS_IOC_POLICY_CHECK, &chk) != 0 || chk.tier != JARVIS_TIER_SAFE || chk.allowed != 1) {
        fprintf(stderr, "FAIL: policy read_file tier=%u allowed=%u\n", chk.tier, chk.allowed);
        close(fd);
        return 1;
    }

    memset(&chk, 0, sizeof(chk));
    snprintf((char *)chk.server, sizeof(chk.server), "ShellMCP");
    snprintf((char *)chk.tool, sizeof(chk.tool), "run");
    snprintf((char *)chk.path, sizeof(chk.path), "/etc/shadow");
    if (ioctl(fd, JARVIS_IOC_POLICY_CHECK, &chk) != 0 || chk.tier != JARVIS_TIER_FORBIDDEN || chk.allowed != 0) {
        fprintf(stderr, "FAIL: policy /etc/shadow tier=%u allowed=%u\n", chk.tier, chk.allowed);
        close(fd);
        return 1;
    }

    close(fd);
    printf("JARVIS_USERSPACE_IOCTL_OK\n");
    return 0;
}
