#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
/* usage: regdump base len [base len ...]  (hex) ; prints "addr val" per word */
int main(int c, char **v) {
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) { perror("open"); return 1; }
	for (int i = 1; i + 1 < c; i += 2) {
		unsigned long base = strtoul(v[i], 0, 16), len = strtoul(v[i+1], 0, 16);
		unsigned long pb = base & ~0xfffUL, off = base - pb;
		volatile uint32_t *m = mmap(0, len + off, PROT_READ, MAP_SHARED, fd, pb);
		if (m == MAP_FAILED) { perror("mmap"); continue; }
		for (unsigned long o = 0; o < len; o += 4)
			printf("%08lx %08x\n", base + o, m[(off + o) / 4]);
		munmap((void *)m, len + off);
	}
	return 0;
}
