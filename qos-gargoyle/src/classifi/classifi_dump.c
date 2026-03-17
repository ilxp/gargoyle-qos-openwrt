/*
 * classifi - eBPF + nDPI traffic classifier
 * Copyright (C) 2025 Chad Monroe <chad@monroe.io>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2
 * as published by the Free Software Foundation
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#include "classifi_dump.h"

#define PCAPNG_SHB_TYPE		0x0A0D0D0A
#define PCAPNG_IDB_TYPE		0x00000001
#define PCAPNG_EPB_TYPE		0x00000006

#define PCAPNG_BYTE_ORDER_MAGIC	0x1A2B3C4D
#define PCAPNG_VERSION_MAJOR	1
#define PCAPNG_VERSION_MINOR	0

#define DLT_EN10MB		1

#define OPT_ENDOFOPT		0
#define OPT_IF_NAME		2
#define OPT_IF_TSRESOL		9

#define MAX_DUMP_INTERFACES	16

struct iface_map {
	int ifindex;
	uint32_t pcapng_id;
};

struct dump_writer {
	FILE *fp;
	uint64_t boot_ns;
	uint64_t wall_ns;
	struct iface_map ifaces[MAX_DUMP_INTERFACES];
	int num_ifaces;
};

static inline uint32_t pad4(uint32_t len)
{
	return (len + 3) & ~3;
}

static int write_u16(FILE *fp, uint16_t val)
{
	return fwrite(&val, sizeof(val), 1, fp) == 1 ? 0 : -1;
}

static int write_u32(FILE *fp, uint32_t val)
{
	return fwrite(&val, sizeof(val), 1, fp) == 1 ? 0 : -1;
}

static int write_i64(FILE *fp, int64_t val)
{
	return fwrite(&val, sizeof(val), 1, fp) == 1 ? 0 : -1;
}

static int write_shb(FILE *fp)
{
	uint32_t block_len = 28;

	if (write_u32(fp, PCAPNG_SHB_TYPE) < 0)
		return -1;
	if (write_u32(fp, block_len) < 0)
		return -1;
	if (write_u32(fp, PCAPNG_BYTE_ORDER_MAGIC) < 0)
		return -1;
	if (write_u16(fp, PCAPNG_VERSION_MAJOR) < 0)
		return -1;
	if (write_u16(fp, PCAPNG_VERSION_MINOR) < 0)
		return -1;
	if (write_i64(fp, -1) < 0)
		return -1;
	if (write_u32(fp, block_len) < 0)
		return -1;

	return 0;
}

static int write_idb(FILE *fp, const char *name)
{
	size_t name_len = name ? strlen(name) : 0;
	uint32_t name_padded = pad4(name_len);
	uint32_t opt_len = 0;
	uint32_t block_len;

	if (name_len > 0)
		opt_len += 4 + name_padded;
	opt_len += 4 + 4;
	opt_len += 4;

	block_len = 20 + opt_len;

	if (write_u32(fp, PCAPNG_IDB_TYPE) < 0)
		return -1;
	if (write_u32(fp, block_len) < 0)
		return -1;
	if (write_u16(fp, DLT_EN10MB) < 0)
		return -1;
	if (write_u16(fp, 0) < 0)
		return -1;
	if (write_u32(fp, 65535) < 0)
		return -1;

	if (name_len > 0) {
		uint8_t padding[4] = {0};
		uint32_t pad_bytes = name_padded - name_len;

		if (write_u16(fp, OPT_IF_NAME) < 0)
			return -1;
		if (write_u16(fp, name_len) < 0)
			return -1;
		if (fwrite(name, 1, name_len, fp) != name_len)
			return -1;
		if (pad_bytes > 0 && fwrite(padding, 1, pad_bytes, fp) != pad_bytes)
			return -1;
	}

	if (write_u16(fp, OPT_IF_TSRESOL) < 0)
		return -1;
	if (write_u16(fp, 1) < 0)
		return -1;
	{
		uint8_t tsresol = 9;
		uint8_t padding[3] = {0};
		if (fwrite(&tsresol, 1, 1, fp) != 1)
			return -1;
		if (fwrite(padding, 1, 3, fp) != 3)
			return -1;
	}

	if (write_u16(fp, OPT_ENDOFOPT) < 0)
		return -1;
	if (write_u16(fp, 0) < 0)
		return -1;

	if (write_u32(fp, block_len) < 0)
		return -1;

	return 0;
}

struct dump_writer *dump_open(const char *filename)
{
	struct dump_writer *w;
	struct timespec ts_boot, ts_wall;

	w = calloc(1, sizeof(*w));
	if (!w)
		return NULL;

	w->fp = fopen(filename, "wb");
	if (!w->fp) {
		fprintf(stderr, "failed to open %s for writing: %s\n",
			filename, strerror(errno));
		free(w);
		return NULL;
	}

	clock_gettime(CLOCK_BOOTTIME, &ts_boot);
	clock_gettime(CLOCK_REALTIME, &ts_wall);

	w->boot_ns = (uint64_t)ts_boot.tv_sec * 1000000000ULL + ts_boot.tv_nsec;
	w->wall_ns = (uint64_t)ts_wall.tv_sec * 1000000000ULL + ts_wall.tv_nsec;

	if (write_shb(w->fp) < 0) {
		fprintf(stderr, "failed to write pcapng section header\n");
		fclose(w->fp);
		free(w);
		return NULL;
	}

	fprintf(stderr, "opened pcapng file %s for writing\n", filename);
	return w;
}

int dump_add_interface(struct dump_writer *w, const char *name, int ifindex)
{
	if (!w || !w->fp)
		return -1;

	if (w->num_ifaces >= MAX_DUMP_INTERFACES) {
		fprintf(stderr, "too many interfaces for pcapng dump\n");
		return -1;
	}

	for (int i = 0; i < w->num_ifaces; i++) {
		if (w->ifaces[i].ifindex == ifindex)
			return 0;
	}

	if (write_idb(w->fp, name) < 0) {
		fprintf(stderr, "failed to write interface description block\n");
		return -1;
	}

	w->ifaces[w->num_ifaces].ifindex = ifindex;
	w->ifaces[w->num_ifaces].pcapng_id = w->num_ifaces;
	w->num_ifaces++;

	fprintf(stderr, "added interface %s (ifindex %d) to pcapng dump\n",
		name ? name : "unknown", ifindex);
	return 0;
}

int dump_write_packet(struct dump_writer *w, int ifindex,
		      uint64_t ts_ns, const uint8_t *data, uint32_t len)
{
	uint32_t pcapng_id = 0;
	uint64_t wall_ts;
	uint32_t data_padded;
	uint32_t block_len;
	int found = 0;

	if (!w || !w->fp || !data || len == 0)
		return -1;

	for (int i = 0; i < w->num_ifaces; i++) {
		if (w->ifaces[i].ifindex == ifindex) {
			pcapng_id = w->ifaces[i].pcapng_id;
			found = 1;
			break;
		}
	}

	if (!found)
		return -1;

	if (ts_ns >= w->boot_ns)
		wall_ts = w->wall_ns + (ts_ns - w->boot_ns);
	else
		wall_ts = w->wall_ns;

	data_padded = pad4(len);
	block_len = 32 + data_padded;

	if (write_u32(w->fp, PCAPNG_EPB_TYPE) < 0)
		return -1;
	if (write_u32(w->fp, block_len) < 0)
		return -1;
	if (write_u32(w->fp, pcapng_id) < 0)
		return -1;
	if (write_u32(w->fp, (uint32_t)(wall_ts >> 32)) < 0)
		return -1;
	if (write_u32(w->fp, (uint32_t)(wall_ts & 0xFFFFFFFF)) < 0)
		return -1;
	if (write_u32(w->fp, len) < 0)
		return -1;
	if (write_u32(w->fp, len) < 0)
		return -1;

	if (fwrite(data, 1, len, w->fp) != len)
		return -1;

	if (data_padded > len) {
		uint8_t padding[4] = {0};
		uint32_t pad_bytes = data_padded - len;
		if (fwrite(padding, 1, pad_bytes, w->fp) != pad_bytes)
			return -1;
	}

	if (write_u32(w->fp, block_len) < 0)
		return -1;

	return 0;
}

void dump_close(struct dump_writer *w)
{
	if (!w)
		return;

	if (w->fp) {
		fflush(w->fp);
		fclose(w->fp);
		fprintf(stderr, "closed pcapng dump file\n");
	}

	free(w);
}
