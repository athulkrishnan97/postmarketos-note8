#include <errno.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void)
{
    const char mode[] = "download";
    long ret;

    /* flush the rootfs first: a raw reboot loses unwritten data */
    sync();
    ret = syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                       LINUX_REBOOT_CMD_RESTART2, mode);

    if (ret < 0) {
        fprintf(stderr, "reboot download failed: %s\n", strerror(errno));
        return 1;
    }

    return 0;
}
