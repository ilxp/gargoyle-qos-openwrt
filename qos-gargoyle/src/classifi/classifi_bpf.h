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
#ifndef CLASSIFI_BPF_H
#define CLASSIFI_BPF_H

#include <linux/types.h>

#ifndef offsetof
#define offsetof(TYPE, MEMBER) __builtin_offsetof(TYPE, MEMBER)
#endif

#define MAX_FLOWS 8192

/*
 * GRO can coalesce multiple TCP segments into a single skb, producing
 * packets larger than MTU. TLS ClientHello with many extensions or
 * certificate data can span multiple segments. 8192 bytes captures
 * these coalesced packets for proper nDPI reassembly and classification.
 */
#define MAX_PACKET_SAMPLE 8192
#define PACKETS_TO_SAMPLE 50

#define FLOW_FAMILY_IPV4 4
#define FLOW_FAMILY_IPV6 6

struct flow_addr {
	__u64 hi;
	__u64 lo;
} __attribute__((packed));

#define FLOW_STATE_NEW       0
#define FLOW_STATE_SAMPLED   1
#define FLOW_STATE_CLASSIFIED 2

struct flow_key {
	__u8 family;
	__u8 protocol;
	__u16 pad0;
	__u16 src_port;
	__u16 dst_port;
	struct flow_addr src;
	struct flow_addr dst;
} __attribute__((packed));

struct flow_info {
	__u64 packets;
	__u64 bytes;
	__u64 first_seen;
	__u64 last_seen;
	__u8 state;
	__u8 pad[7];
};

struct packet_sample {
	struct flow_key key;
	__u64 ts_ns;
	__u32 data_len;
	__u32 ifindex;
	__u16 l3_offset;
	__u8 direction;
	__u8 pad;
	__u8 data[MAX_PACKET_SAMPLE];
} __attribute__((packed));

#ifdef __BPF__
#define FLOW_INLINE static __always_inline
#else
#define FLOW_INLINE static inline
#endif

FLOW_INLINE void swap_flow_endpoints(struct flow_key *key)
{
	__u16 tmp_port = key->src_port;
	__u64 tmp_hi = key->src.hi;
	__u64 tmp_lo = key->src.lo;

	key->src_port = key->dst_port;
	key->dst_port = tmp_port;

	key->src.hi = key->dst.hi;
	key->src.lo = key->dst.lo;
	key->dst.hi = tmp_hi;
	key->dst.lo = tmp_lo;
}

FLOW_INLINE __u8 canonicalize_flow_key(struct flow_key *key)
{
	__u8 swapped = 0;

	if (key->family == FLOW_FAMILY_IPV4) {
		__u32 src = (__u32)key->src.lo;
		__u32 dst = (__u32)key->dst.lo;

		if (src > dst)
			swapped = 1;
		else if (src == dst && key->src_port > key->dst_port)
			swapped = 1;
	} else if (key->family == FLOW_FAMILY_IPV6) {
		if (key->src.hi > key->dst.hi)
			swapped = 1;
		else if (key->src.hi == key->dst.hi && key->src.lo > key->dst.lo)
			swapped = 1;
		else if (key->src.hi == key->dst.hi && key->src.lo == key->dst.lo &&
			 key->src_port > key->dst_port)
			swapped = 1;
	} else {
		if (key->src.hi > key->dst.hi)
			swapped = 1;
		else if (key->src.hi == key->dst.hi && key->src.lo > key->dst.lo)
			swapped = 1;
	}

	if (swapped)
		swap_flow_endpoints(key);

	return swapped;
}

#endif /* CLASSIFI_BPF_H */
