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
#ifndef CLASSIFI_DUMP_H
#define CLASSIFI_DUMP_H

#include <stdint.h>

struct dump_writer;

struct dump_writer *dump_open(const char *filename);
int dump_add_interface(struct dump_writer *w, const char *name, int ifindex);
int dump_write_packet(struct dump_writer *w, int ifindex,
		      uint64_t ts_ns, const uint8_t *data, uint32_t len);
void dump_close(struct dump_writer *w);

#endif /* CLASSIFI_DUMP_H */
