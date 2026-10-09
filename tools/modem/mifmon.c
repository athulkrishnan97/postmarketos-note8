// SPDX-License-Identifier: GPL-2.0
/*
 * mifmon - watch the Shannon CP's IPC channels on postmarketOS.
 *
 * The modem driver tells the CP that the AP side is ready (CMD_INIT_END)
 * only while both /dev/umts_ipc0 (FMT: Samsung IPC) and /dev/umts_rfs0
 * (RFS: remote file system) are open, so this tool also acts as the
 * "RIL is up" placeholder during bring-up. Every frame is printed with a
 * timestamp and the decoded header; nothing is answered yet.
 *
 *   mifmon                     log umts_ipc0 + umts_rfs0 (+ umts_router)
 *   mifmon -a 'AT+CPIN?'       also send an AT command on umts_router
 *   mifmon -f <hex bytes>      also send a raw FMT frame on umts_ipc0
 *
 * Frame formats (Samsung IPC 4.x, as used by libsec-ril):
 *   FMT: u16 len; u8 mseq; u8 aseq; u8 group; u8 index; u8 type; data
 *   RFS: u32 len; u8 cmd; u8 id; data
 *
 * Build on the phone: gcc -O2 -Wall -o mifmon mifmon.c
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUF_SIZE	(64 * 1024)

static const char *const fmt_types[] = {
	[1] = "EXEC", [2] = "GET", [3] = "SET", [4] = "CFRM",
	[5] = "EVENT", [6] = "INDI", [7] = "RESP", [8] = "NOTI",
};

/* Samsung IPC main command groups (libsamsung-ipc / RIL naming) */
static const char *fmt_group(uint8_t g)
{
	switch (g) {
	case 0x01: return "PWR";
	case 0x02: return "CALL";
	case 0x04: return "SMS";
	case 0x05: return "SEC";
	case 0x06: return "PB";
	case 0x07: return "DISP";
	case 0x08: return "NET";
	case 0x09: return "SND";
	case 0x0a: return "MISC";
	case 0x0b: return "SVC";
	case 0x0c: return "SS";
	case 0x0d: return "GPRS";
	case 0x0e: return "SAT";
	case 0x0f: return "CFG";
	case 0x10: return "IMEI";
	case 0x11: return "GPS";
	case 0x12: return "SAP";
	case 0x80: return "GEN";
	default: return "?";
	}
}

static void stamp(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	printf("[%5ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
}

static void hexdump(const uint8_t *p, size_t n)
{
	size_t i, j;

	for (i = 0; i < n; i += 16) {
		printf("    %04zx:", i);
		for (j = i; j < i + 16; j++) {
			if (j < n)
				printf(" %02x", p[j]);
			else
				printf("   ");
		}
		printf("  ");
		for (j = i; j < i + 16 && j < n; j++)
			putchar(isprint(p[j]) ? p[j] : '.');
		putchar('\n');
	}
}

static void show_fmt(const char *dir, const uint8_t *p, size_t n)
{
	stamp();
	if (n >= 7) {
		uint16_t len = p[0] | p[1] << 8;
		uint8_t type = p[6];

		printf("FMT %s len=%u mseq=%u aseq=%u %s(0x%02x) idx=0x%02x %s\n",
		       dir, len, p[2], p[3], fmt_group(p[4]), p[4], p[5],
		       type < 9 && fmt_types[type] ? fmt_types[type] : "?");
	} else {
		printf("FMT %s short frame (%zu bytes)\n", dir, n);
	}
	hexdump(p, n);
}

static void show_rfs(const char *dir, const uint8_t *p, size_t n)
{
	stamp();
	if (n >= 6) {
		uint32_t len = p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;

		printf("RFS %s len=%u cmd=0x%02x id=%u\n", dir, len, p[4], p[5]);
	} else {
		printf("RFS %s short frame (%zu bytes)\n", dir, n);
	}
	hexdump(p, n > 256 ? 256 : n);
}

static void show_raw(const char *name, const uint8_t *p, size_t n)
{
	size_t i;

	stamp();
	printf("%s rx %zu bytes: \"", name, n);
	for (i = 0; i < n; i++) {
		if (p[i] == '\r')
			printf("\\r");
		else if (p[i] == '\n')
			printf("\\n");
		else
			putchar(isprint(p[i]) ? p[i] : '.');
	}
	printf("\"\n");
}

static int open_dev(const char *path)
{
	int fd = open(path, O_RDWR | O_NONBLOCK);

	if (fd < 0)
		fprintf(stderr, "mifmon: %s: %s\n", path, strerror(errno));
	return fd;
}

static size_t parse_hex(const char *s, uint8_t *out, size_t max)
{
	size_t n = 0;
	unsigned int b;
	int used;

	while (n < max && sscanf(s, " %2x%n", &b, &used) == 1) {
		out[n++] = b;
		s += used;
	}
	return n;
}

int main(int argc, char **argv)
{
	static uint8_t buf[BUF_SIZE];
	const char *at_cmd = NULL, *fmt_hex = NULL;
	struct pollfd pfd[3];
	int opt, i;

	while ((opt = getopt(argc, argv, "a:f:")) != -1) {
		switch (opt) {
		case 'a': at_cmd = optarg; break;
		case 'f': fmt_hex = optarg; break;
		default:
			fprintf(stderr, "usage: %s [-a AT-command] [-f hex-fmt-frame]\n",
				argv[0]);
			return 2;
		}
	}
	setvbuf(stdout, NULL, _IOLBF, 0);

	pfd[0].fd = open_dev("/dev/umts_ipc0");
	pfd[1].fd = open_dev("/dev/umts_rfs0");
	pfd[2].fd = open_dev("/dev/umts_router");
	for (i = 0; i < 3; i++)
		pfd[i].events = POLLIN;
	if (pfd[0].fd < 0 || pfd[1].fd < 0)
		return 1;

	if (fmt_hex) {
		size_t n = parse_hex(fmt_hex, buf, sizeof(buf));

		show_fmt("tx", buf, n);
		if (write(pfd[0].fd, buf, n) < 0)
			perror("mifmon: write umts_ipc0");
	}
	if (at_cmd && pfd[2].fd >= 0) {
		snprintf((char *)buf, sizeof(buf), "%s\r", at_cmd);
		stamp();
		printf("ROUTER tx \"%s\\r\"\n", at_cmd);
		if (write(pfd[2].fd, buf, strlen((char *)buf)) < 0)
			perror("mifmon: write umts_router");
	}

	for (;;) {
		if (poll(pfd, 3, -1) < 0) {
			if (errno == EINTR)
				continue;
			perror("mifmon: poll");
			return 1;
		}
		for (i = 0; i < 3; i++) {
			ssize_t n;

			if (pfd[i].fd < 0 || !pfd[i].revents)
				continue;
			if (pfd[i].revents & (POLLERR | POLLHUP)) {
				stamp();
				printf("channel %d: %s (CP state change)\n", i,
				       pfd[i].revents & POLLHUP ? "HUP" : "ERR");
			}
			n = read(pfd[i].fd, buf, sizeof(buf));
			if (n <= 0)
				continue;
			if (i == 0)
				show_fmt("rx", buf, n);
			else if (i == 1)
				show_rfs("rx", buf, n);
			else
				show_raw("ROUTER", buf, n);
		}
	}
}
