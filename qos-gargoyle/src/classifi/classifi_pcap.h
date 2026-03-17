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
#ifndef CLASSIFI_PCAP_H
#define CLASSIFI_PCAP_H

#include "classifi.h"

int run_pcap_mode(struct classifi_ctx *ctx, const char *ifname);
int run_pcap_replay(struct classifi_ctx *ctx, const char *filename);

#endif /* CLASSIFI_PCAP_H */
