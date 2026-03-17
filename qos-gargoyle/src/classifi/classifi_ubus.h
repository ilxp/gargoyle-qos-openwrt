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
#ifndef CLASSIFI_UBUS_H
#define CLASSIFI_UBUS_H

#include "classifi.h"

int classifi_ubus_init(struct classifi_ctx *ctx);
int discover_interfaces_from_uci(const char **iface_names, int max_ifaces);
int reload_config(struct classifi_ctx *ctx, int *out_added, int *out_removed);
int rules_load_from_uci(struct classifi_ctx *ctx);
void rules_free(struct classifi_ctx *ctx);

#endif /* CLASSIFI_UBUS_H */
