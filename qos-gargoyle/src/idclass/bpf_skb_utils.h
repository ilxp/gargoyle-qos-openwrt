// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (C) 2022 Felix Fietkau <nbd@nbd.name>
 * Version: 2022-09-21
 * Modified for idclass: added READ_ONCE definition and removed unnecessary includes
 */
#ifndef __BPF_SKB_UTILS_H
#define __BPF_SKB_UTILS_H

#include <linux/types.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* 确保 vlan_hdr 完整定义 */
#ifndef __LINUX_IF_VLAN_H
struct vlan_hdr {
    __be16 h_vlan_TCI;
    __be16 h_vlan_encapsulated_proto;
};
#endif

#ifndef READ_ONCE
#define READ_ONCE(x) (*(volatile typeof(x) *)&(x))
#endif

struct skb_parser_info {
	struct __sk_buff *skb;
	__u32 offset;
	int proto;
};

static __always_inline void *__skb_data(struct __sk_buff *skb)
{
	return (void *)(long)READ_ONCE(skb->data);
}

static __always_inline void *
skb_ptr(struct __sk_buff *skb, __u32 offset, __u32 len)
{
	void *ptr = __skb_data(skb) + offset;
	void *end = (void *)(long)(skb->data_end);

	if (ptr + len >= end)
		return NULL;

	return ptr;
}

static __always_inline void *
skb_info_ptr(struct skb_parser_info *info, __u32 len)
{
	__u32 offset = info->offset;
	return skb_ptr(info->skb, offset, len);
}

static __always_inline void
skb_parse_init(struct skb_parser_info *info, struct __sk_buff *skb)
{
	*info = (struct skb_parser_info){
		.skb = skb
	};
}

static __always_inline struct ethhdr *
skb_parse_ethernet(struct skb_parser_info *info)
{
	struct ethhdr *eth;
	int len;

	len = sizeof(*eth) + 2 * sizeof(struct vlan_hdr) + sizeof(struct ipv6hdr);
	if (len > info->skb->len)
		len = info->skb->len;
	bpf_skb_pull_data(info->skb, len);

	eth = skb_info_ptr(info, sizeof(*eth));
	if (!eth)
		return NULL;

	info->proto = eth->h_proto;
	info->offset += sizeof(*eth);

	return eth;
}

static __always_inline struct vlan_hdr *
skb_parse_vlan(struct skb_parser_info *info)
{
	struct vlan_hdr *vlh;

	if (info->proto != bpf_htons(ETH_P_8021Q) &&
	    info->proto != bpf_htons(ETH_P_8021AD))
		return NULL;

	vlh = skb_info_ptr(info, sizeof(*vlh));
	if (!vlh)
		return NULL;

	info->proto = vlh->h_vlan_encapsulated_proto;
	info->offset += sizeof(*vlh);

	return vlh;
}

static __always_inline struct iphdr *
skb_parse_ipv4(struct skb_parser_info *info, int min_l4_bytes)
{
	struct iphdr *iph;
	int proto, hdr_len;
	__u32 pull_len;

	if (info->proto != bpf_htons(ETH_P_IP))
		return NULL;

	iph = skb_info_ptr(info, sizeof(*iph));
	if (!iph)
		return NULL;

	hdr_len = iph->ihl * 4;
	hdr_len = READ_ONCE(hdr_len) & 0xff;
	if (hdr_len < sizeof(*iph))
		return NULL;

	pull_len = info->offset + hdr_len + min_l4_bytes;
	if (pull_len > info->skb->len)
		pull_len = info->skb->len;

	if (bpf_skb_pull_data(info->skb, pull_len))
		return NULL;

	iph = skb_info_ptr(info, sizeof(*iph));
	if (!iph)
		return NULL;

	info->proto = iph->protocol;
	info->offset += hdr_len;

	return iph;
}

static __always_inline struct ipv6hdr *
skb_parse_ipv6(struct skb_parser_info *info, int max_l4_bytes)
{
	struct ipv6hdr *ip6h;
	__u32 pull_len;

	if (info->proto != bpf_htons(ETH_P_IPV6))
		return NULL;

	pull_len = info->offset + sizeof(*ip6h) + max_l4_bytes;
	if (pull_len > info->skb->len)
		pull_len = info->skb->len;

	if (bpf_skb_pull_data(info->skb, pull_len))
		return NULL;

	ip6h = skb_info_ptr(info, sizeof(*ip6h));
	if (!ip6h)
		return NULL;

	info->proto = READ_ONCE(ip6h->nexthdr);
	info->offset += sizeof(*ip6h);

	return ip6h;
}

static __always_inline struct tcphdr *
skb_parse_tcp(struct skb_parser_info *info)
{
	struct tcphdr *tcph;

	if (info->proto != IPPROTO_TCP)
		return NULL;

	tcph = skb_info_ptr(info, sizeof(*tcph));
	if (!tcph)
		return NULL;

	info->offset += tcph->doff * 4;

	return tcph;
}

#endif