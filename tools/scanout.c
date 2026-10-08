/* Build: aarch64-linux-gnu-gcc -O2 -static -o scanout scanout.c
 * Run as root on the phone: ./scanout /dev/dri/card0 /tmp/frame.ppm */
/* Dump the framebuffer currently scanned out on each active CRTC to a PPM.
 * Raw DRM ioctls (no libdrm), needs root (GETFB2 handles). */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

int main(int argc, char **argv)
{
	const char *card = argc > 1 ? argv[1] : "/dev/dri/card0";
	const char *out = argc > 2 ? argv[2] : "/tmp/scanout.ppm";
	int fd = open(card, O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror(card); return 1; }

	struct drm_mode_card_res res = {0};
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("GETRESOURCES"); return 1; }
	uint32_t *crtcs = calloc(res.count_crtcs, 4);
	res.crtc_id_ptr = (uintptr_t)crtcs;
	res.count_fbs = res.count_connectors = res.count_encoders = 0;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("GETRESOURCES2"); return 1; }

	for (uint32_t i = 0; i < res.count_crtcs; i++) {
		struct drm_mode_crtc crtc = { .crtc_id = crtcs[i] };
		if (ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &crtc) || !crtc.fb_id)
			continue;
		struct drm_mode_fb_cmd2 fb = { .fb_id = crtc.fb_id };
		if (ioctl(fd, DRM_IOCTL_MODE_GETFB2, &fb)) { perror("GETFB2"); continue; }
		printf("crtc %u fb %u %ux%u fourcc %.4s pitch %u offset %u modifier 0x%llx handle %u\n",
		       crtc.crtc_id, fb.fb_id, fb.width, fb.height, (char *)&fb.pixel_format,
		       fb.pitches[0], fb.offsets[0], (unsigned long long)fb.modifier[0], fb.handles[0]);
		if (!fb.handles[0]) { fprintf(stderr, "no handle (not root?)\n"); return 1; }

		struct drm_prime_handle prime = { .handle = fb.handles[0], .flags = DRM_CLOEXEC | DRM_RDWR };
		if (ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime)) {
			prime.flags = DRM_CLOEXEC;
			if (ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime)) { perror("PRIME"); return 1; }
		}
		size_t len = (size_t)fb.pitches[0] * fb.height + fb.offsets[0];
		uint8_t *map = mmap(NULL, len, PROT_READ, MAP_SHARED, prime.fd, 0);
		if (map == MAP_FAILED) { perror("mmap"); return 1; }

		FILE *f = fopen(out, "wb");
		fprintf(f, "P6\n%u %u\n255\n", fb.width, fb.height);
		uint8_t *row = malloc(fb.width * 3);
		for (uint32_t y = 0; y < fb.height; y++) {
			uint8_t *s = map + fb.offsets[0] + (size_t)y * fb.pitches[0];
			for (uint32_t x = 0; x < fb.width; x++) {
				/* XRGB8888/ARGB8888 little endian: B G R X */
				row[x * 3 + 0] = s[x * 4 + 2];
				row[x * 3 + 1] = s[x * 4 + 1];
				row[x * 3 + 2] = s[x * 4 + 0];
			}
			fwrite(row, 3, fb.width, f);
		}
		fclose(f);
		printf("wrote %s\n", out);
		return 0;
	}
	fprintf(stderr, "no active CRTC with a framebuffer on %s\n", card);
	return 1;
}
