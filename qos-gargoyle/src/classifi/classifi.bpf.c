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
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ipv6.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define __BPF__
#include "classifi_bpf.h"

#ifndef ETH_P_8021AD
#define ETH_P_8021AD 0x88A8
#endif

struct bpf_vlan_hdr {
	__be16 h_vlan_TCI;
	__be16 h_vlan_encapsulated_proto;
};

char LICENSE[] SEC("license") = "GPL v2";

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, MAX_FLOWS);
	__type(key, struct flow_key);
	__type(value, struct flow_info);
} flow_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 1024 * 1024);
} packet_samples SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} ringbuf_stats SEC(".maps");

static __always_inline int parse_flow_key(struct __sk_buff *skb,
                                          struct flow_key *key,
                                          __u16 *l3_offset)
{
	void *data = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;
	struct ethhdr *eth = data;
	__u32 offset = sizeof(*eth);
	__be16 h_proto;
	int i;

	if (data + offset > data_end)
		return -1;

	h_proto = eth->h_proto;

	#pragma unroll
	for (i = 0; i < 2; i++) {
		if (h_proto == bpf_htons(ETH_P_8021Q) || h_proto == bpf_htons(ETH_P_8021AD)) {
			struct bpf_vlan_hdr *vh = data + offset;

			if ((void *)vh + sizeof(*vh) > data_end)
				return -1;

			h_proto = vh->h_vlan_encapsulated_proto;
			offset += sizeof(*vh);
		}
	}

	if (h_proto == bpf_htons(ETH_P_IP)) {
		struct iphdr *iph = data + offset;
		__u32 ip_hdr_len;

		if ((void *)iph + sizeof(*iph) > data_end)
			return -1;

		ip_hdr_len = iph->ihl * 4;
		if (ip_hdr_len < sizeof(*iph))
			return -1;
		if ((void *)iph + ip_hdr_len > data_end)
			return -1;

		key->family = FLOW_FAMILY_IPV4;
		key->protocol = iph->protocol;
		key->src_port = 0;
		key->dst_port = 0;
		key->src.hi = 0;
		key->src.lo = (__u64)iph->saddr;
		key->dst.hi = 0;
		key->dst.lo = (__u64)iph->daddr;

		*l3_offset = offset;
		offset += ip_hdr_len;

		if (iph->protocol == IPPROTO_TCP) {
			struct tcphdr *tcph = data + offset;

			if ((void *)tcph + sizeof(*tcph) > data_end)
				return -1;

			key->src_port = bpf_ntohs(tcph->source);
			key->dst_port = bpf_ntohs(tcph->dest);
		} else if (iph->protocol == IPPROTO_UDP) {
			struct udphdr *udph = data + offset;

			if ((void *)udph + sizeof(*udph) > data_end)
				return -1;

			key->src_port = bpf_ntohs(udph->source);
			key->dst_port = bpf_ntohs(udph->dest);
		}

		return 0;
	}

	if (h_proto == bpf_htons(ETH_P_IPV6)) {
		struct ipv6hdr *ip6h = data + offset;

		if ((void *)ip6h + sizeof(*ip6h) > data_end)
			return -1;

		key->family = FLOW_FAMILY_IPV6;
		key->protocol = ip6h->nexthdr;
		key->src_port = 0;
		key->dst_port = 0;
		__builtin_memcpy(&key->src, &ip6h->saddr, sizeof(struct in6_addr));
		__builtin_memcpy(&key->dst, &ip6h->daddr, sizeof(struct in6_addr));

		*l3_offset = offset;
		offset += sizeof(*ip6h);

		if (ip6h->nexthdr == IPPROTO_TCP) {
			struct tcphdr *tcph = data + offset;

			if ((void *)tcph + sizeof(*tcph) > data_end)
				return -1;

			key->src_port = bpf_ntohs(tcph->source);
			key->dst_port = bpf_ntohs(tcph->dest);
		} else if (ip6h->nexthdr == IPPROTO_UDP) {
			struct udphdr *udph = data + offset;

			if ((void *)udph + sizeof(*udph) > data_end)
				return -1;

			key->src_port = bpf_ntohs(udph->source);
			key->dst_port = bpf_ntohs(udph->dest);
		}

		return 0;
	}

	return -1;
}

static __always_inline void sample_packet(struct __sk_buff *skb,
                                          struct flow_key *key,
                                          __u8 direction,
                                          __u64 ts_ns,
                                          __u16 l3_offset)
{
	struct packet_sample *sample;
	__u32 len;

	sample = bpf_ringbuf_reserve(&packet_samples, sizeof(*sample), 0);
	if (!sample) {
		__u32 stats_key = 0;
		__u64 *count = bpf_map_lookup_elem(&ringbuf_stats, &stats_key);
		if (count)
			__sync_fetch_and_add(count, 1);
		return;
	}

	len = skb->len;
	if (len > MAX_PACKET_SAMPLE)
		len = MAX_PACKET_SAMPLE;

	if (len == 0 || bpf_skb_load_bytes(skb, 0, sample->data, len) < 0) {
		bpf_ringbuf_discard(sample, 0);
		return;
	}

	__builtin_memcpy(&sample->key, key, sizeof(*key));
	sample->ts_ns = ts_ns;
	sample->ifindex = skb->ifindex;
	sample->l3_offset = l3_offset;
	sample->direction = direction;
	sample->pad = 0;
	sample->data_len = len;

	bpf_ringbuf_submit(sample, 0);
}

SEC("tc")
int classifi(struct __sk_buff *skb)
{
	struct flow_key key = {};
	struct flow_info *info, new_info = {};
	__u64 now = bpf_ktime_get_ns();
	__u8 direction;
	__u64 old_count;
	__u16 l3_offset = 0;

	/*
	 * Linearize packet data for GRO'd packets. GRO coalesces multiple
	 * TCP segments into one skb with data split across frags. Without
	 * this, skb->data only contains the first segment's worth of data.
	 * Pull min(skb->len, MAX_PACKET_SAMPLE) since pull_data fails if
	 * we request more than available.
	 */
	__u32 pull_len = skb->len < MAX_PACKET_SAMPLE ? skb->len : MAX_PACKET_SAMPLE;
	if (bpf_skb_pull_data(skb, pull_len) < 0)
		return TC_ACT_OK;

	if (parse_flow_key(skb, &key, &l3_offset) < 0)
		return TC_ACT_OK;

	direction = canonicalize_flow_key(&key);

	info = bpf_map_lookup_elem(&flow_map, &key);
	if (!info) {
		new_info.packets = 1;
		new_info.bytes = skb->len;
		new_info.first_seen = now;
		new_info.last_seen = now;
		new_info.state = FLOW_STATE_NEW;

		if (bpf_map_update_elem(&flow_map, &key, &new_info, BPF_ANY) < 0) {
			__u32 stats_key = 0;
			__u64 *count = bpf_map_lookup_elem(&ringbuf_stats, &stats_key);
			if (count)
				__sync_fetch_and_add(count, 1);
			return TC_ACT_OK;
		}
		sample_packet(skb, &key, direction, now, l3_offset);
	} else {
		old_count = __sync_fetch_and_add(&info->packets, 1);
		__sync_fetch_and_add(&info->bytes, skb->len);
		info->last_seen = now;

		if (info->state == FLOW_STATE_NEW && old_count < PACKETS_TO_SAMPLE) {
			sample_packet(skb, &key, direction, now, l3_offset);

			if (old_count + 1 >= PACKETS_TO_SAMPLE)
				info->state = FLOW_STATE_SAMPLED;
		}
	}

	return TC_ACT_OK;
}
