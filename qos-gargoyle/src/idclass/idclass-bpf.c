// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 * Modified to support multi-feature classification and DSCP setting
 */
#define KBUILD_MODNAME "foo"
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/in.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/filter.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include "bpf_skb_utils.h"
#include "idclass-bpf.h"

/* 确保 bpf_skb_set_mark 辅助函数可用 */
#ifndef BPF_FUNC_skb_set_mark
#define BPF_FUNC_skb_set_mark 63
#endif

static __always_inline int bpf_skb_set_mark(struct __sk_buff *skb, __u32 mark) {
    return ((int (*)(struct __sk_buff *, __u32))BPF_FUNC_skb_set_mark)(skb, mark);
}

#define INET_ECN_MASK 3
#define EWMA_SHIFT 12

const volatile static __u32 module_flags = 0;

/* 上传方向：逻辑优先级 (0-3) → class_id */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 4);
	__type(key, __u32);
	__type(value, __u32);
} prio_class_up SEC(".maps");

/* 下载方向：逻辑优先级 (0-3) → class_id */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 4);
	__type(key, __u32);
	__type(value, __u32);
} prio_class_down SEC(".maps");

/* class_mark map（用于最终 skb->mark 或 DSCP 值） */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, IDCLASS_MAX_CLASS_ENTRIES + 1);
	__type(key, __u32);
	__type(value, __u32);
} class_mark SEC(".maps");

/* 每流统计 map */
struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 65536);
	__type(key, __u32);
	__type(value, struct flow_stats);
	__uint(pinning, 1);
} flow_stats_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(pinning, 1);
	__type(key, __u32);
	__type(value, struct global_config);
	__uint(max_entries, 1);
} global_config SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(pinning, 1);
	__type(key, __u32);
	__type(value, __u8);
	__uint(max_entries, 1 << 16);
} tcp_ports SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(pinning, 1);
	__type(key, __u32);
	__type(value, __u8);
	__uint(max_entries, 1 << 16);
} udp_ports SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(pinning, 1);
	__uint(key_size, sizeof(struct in_addr));
	__type(value, struct idclass_ip_map_val);
	__uint(max_entries, 100000);
	__uint(map_flags, BPF_F_NO_PREALLOC);
} ipv4_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(pinning, 1);
	__uint(key_size, sizeof(struct in6_addr));
	__type(value, struct idclass_ip_map_val);
	__uint(max_entries, 100000);
	__uint(map_flags, BPF_F_NO_PREALLOC);
} ipv6_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(pinning, 1);
	__type(key, __u32);
	__type(value, struct idclass_class);
	__uint(max_entries, IDCLASS_MAX_CLASS_ENTRIES +
			    IDCLASS_DEFAULT_CLASS_ENTRIES);
} class_map SEC(".maps");

/* ip_conn_map 的 key 类型 */
struct ip_key {
	__u8 addr[16];
};

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 16384);
	__type(key, struct ip_key);
	__type(value, __u32);
	__uint(pinning, 1);
} ip_conn_map SEC(".maps");

static struct global_config *get_global_config(void)
{
	__u32 key = 0;
	return bpf_map_lookup_elem(&global_config, &key);
}

static __always_inline __u32 ewma(__u32 *avg, __u32 val)
{
	if (*avg)
		*avg = (*avg * 3) / 4 + (val << EWMA_SHIFT) / 4;
	else
		*avg = val << EWMA_SHIFT;
	return *avg >> EWMA_SHIFT;
}

static __always_inline __u8 dscp_val(struct idclass_dscp_val *val, __u8 ingress)
{
	return ingress ? val->ingress : val->egress;
}

static void
parse_l4proto(struct global_config *config, struct skb_parser_info *info,
	      __u8 ingress, __u8 *out_val)
{
	struct udphdr *udp;
	__u32 src, dest, key;
	__u8 *value;
	__u8 proto = info->proto;

	udp = skb_info_ptr(info, sizeof(*udp));
	if (!udp) return;

	if (config && (proto == IPPROTO_ICMP || proto == IPPROTO_ICMPV6)) {
		*out_val = config->dscp_icmp;
		return;
	}

	src = READ_ONCE(udp->source);
	dest = READ_ONCE(udp->dest);
	if (ingress)
		key = src;
	else
		key = dest;

	if (proto == IPPROTO_TCP)
		value = bpf_map_lookup_elem(&tcp_ports, &key);
	else {
		if (proto != IPPROTO_UDP) key = 0;
		value = bpf_map_lookup_elem(&udp_ports, &key);
	}
	if (value)
		*out_val = *value;
}

static __always_inline struct idclass_ip_map_val *
parse_ipv4(struct global_config *config, struct skb_parser_info *info,
	   __u8 ingress, __u8 *out_val, struct tcphdr **tcph_ptr)
{
	struct iphdr *iph;

	iph = skb_parse_ipv4(info, sizeof(struct udphdr));
	if (!iph)
		return NULL;

	*tcph_ptr = NULL;
	if (iph->protocol == IPPROTO_TCP) {
		struct tcphdr *tcph = (struct tcphdr *)((void *)iph + (iph->ihl * 4));
		if ((void *)tcph + sizeof(*tcph) <= (void *)(long)info->skb->data_end)
			*tcph_ptr = tcph;
	}

	parse_l4proto(config, info, ingress, out_val);

	void *key = ingress ? (void *)&iph->saddr : (void *)&iph->daddr;
	return bpf_map_lookup_elem(&ipv4_map, key);
}

static __always_inline struct idclass_ip_map_val *
parse_ipv6(struct global_config *config, struct skb_parser_info *info,
	   __u8 ingress, __u8 *out_val, struct tcphdr **tcph_ptr)
{
	struct ipv6hdr *ip6h;

	ip6h = skb_parse_ipv6(info, sizeof(struct udphdr));
	if (!ip6h)
		return NULL;

	*tcph_ptr = NULL;
	if (ip6h->nexthdr == IPPROTO_TCP) {
		struct tcphdr *tcph = (struct tcphdr *)(ip6h + 1);
		if ((void *)tcph + sizeof(*tcph) <= (void *)(long)info->skb->data_end)
			*tcph_ptr = tcph;
	}

	parse_l4proto(config, info, ingress, out_val);

	void *key = ingress ? (void *)&ip6h->saddr : (void *)&ip6h->daddr;
	return bpf_map_lookup_elem(&ipv6_map, key);
}

static __always_inline void update_flow_stats(struct flow_stats *stats,
					      __u32 pkt_len,
					      __u64 ts_ns,
					      __u8 direction,
					      struct idclass_flow_config *cfg,
					      struct tcphdr *tcph)
{
	__u32 packets = stats->packets;
	__u64 prev_ts = stats->last_seen;

	__sync_fetch_and_add(&stats->packets, 1);
	__sync_fetch_and_add(&stats->bytes, pkt_len);
	stats->last_seen = ts_ns;

	if (prev_ts != 0) {
		__u64 iat_ns = ts_ns - prev_ts;
		stats->iat_us = iat_ns / 1000ULL;
	}

	ewma(&stats->avg_pkt_len, pkt_len);

	if (direction == 1)
		__sync_fetch_and_add(&stats->up_bytes, pkt_len);
	else if (direction == 2)
		__sync_fetch_and_add(&stats->down_bytes, pkt_len);

	if (cfg && cfg->bulk_trigger_pps) {
		__u64 now_ns = ts_ns;
		if (stats->last_pps_ts == 0) {
			stats->last_pps_ts = now_ns;
			stats->packets_in_window = 1;
		} else {
			__u64 elapsed_ns = now_ns - stats->last_pps_ts;
			if (elapsed_ns >= 1000000000ULL) {
				stats->pps = (stats->packets_in_window * 1000000000ULL) / elapsed_ns;
				stats->last_pps_ts = now_ns;
				stats->packets_in_window = 1;
			} else {
				__sync_fetch_and_add(&stats->packets_in_window, 1);
			}
		}
	}

	if (cfg && cfg->burst_window_ms) {
		__u64 now_ms_val = bpf_ktime_get_ns() / 1000000ULL;
		if (stats->burst_start_ts == 0) {
			stats->burst_start_ts = now_ms_val;
			stats->burst_packets = 1;
			stats->burst_bytes = pkt_len;
		} else {
			__u64 elapsed_ms = now_ms_val - stats->burst_start_ts;
			if (elapsed_ms <= cfg->burst_window_ms) {
				__sync_fetch_and_add(&stats->burst_packets, 1);
				__sync_fetch_and_add(&stats->burst_bytes, pkt_len);
			} else {
				stats->burst_start_ts = now_ms_val;
				stats->burst_packets = 1;
				stats->burst_bytes = pkt_len;
			}
		}
	}

	if (tcph) {
		__u8 tcp_flags = ((__u8 *)tcph)[13];
		if (tcp_flags & 0x02)
			__sync_fetch_and_add(&stats->syn_count, 1);
		if (tcp_flags & 0x10)
			__sync_fetch_and_add(&stats->ack_count, 1);
		if (tcp_flags & 0x01)
			__sync_fetch_and_add(&stats->fin_count, 1);
		if (tcp_flags & 0x04)
			__sync_fetch_and_add(&stats->rst_count, 1);

		__u32 seq = bpf_ntohl(tcph->seq);
        __u64 old_max = stats->max_seq;   // 注意类型变化
        __u64 now_ns = bpf_ktime_get_ns();

        if (seq > old_max) {
            __sync_lock_test_and_set(&stats->max_seq, (__u64)seq);
        } else if (seq < old_max) {
            __u64 last_pkt = stats->last_pkt_ts;
            if (last_pkt != 0 && (now_ns - last_pkt) < 200000000) {
                __sync_fetch_and_add(&stats->retrans_count, 1);
            }
        }

        __sync_lock_test_and_set(&stats->tcp_seq, (__u64)seq);
        stats->last_pkt_ts = now_ns;
    }

static __always_inline __u32 classify_score(struct flow_stats *stats,
                                           struct idclass_flow_config *cfg)
{
    __u32 score_realtime = 0, score_video = 0, score_normal = 0, score_bulk = 0;
    __u32 packets = stats->packets;
    __u32 *conn = NULL;
    __u32 mask = cfg->feature_mask;

    if ((mask & FEATURE_PKTLEN) && packets >= cfg->game_sample_packets) {
        if (stats->avg_pkt_len <= cfg->game_max_avg_pkt_len)
            score_realtime += cfg->weight_pktlen_realtime;
        else if (stats->avg_pkt_len >= cfg->video_min_avg_pkt_len &&
                 stats->avg_pkt_len <= cfg->video_max_avg_pkt_len)
            score_video += cfg->weight_pktlen_video;
        else if (stats->avg_pkt_len >= cfg->bulk_min_avg_pkt_len)
            score_bulk += cfg->weight_pktlen_bulk;
        else
            score_normal += cfg->weight_pktlen_normal;
    }

    if (mask & FEATURE_CONN) {
        struct ip_key key;
        __builtin_memcpy(key.addr, stats->client_ip, 16);
        conn = bpf_map_lookup_elem(&ip_conn_map, &key);
        if (conn) {
            if (*conn <= cfg->game_max_conn)
                score_realtime += cfg->weight_conn_realtime;
            else if (*conn >= cfg->bulk_min_conn)
                score_bulk += cfg->weight_conn_bulk;
            else if (*conn <= cfg->video_max_conn)
                score_video += cfg->weight_conn_video;
            else
                score_normal += cfg->weight_conn_normal;
        }
    }

    if ((mask & FEATURE_PPS) && packets >= cfg->game_sample_packets) {
        if (stats->pps <= cfg->game_max_pps)
            score_realtime += cfg->weight_pps_realtime;
        else if (stats->pps >= cfg->video_min_pps && stats->pps <= cfg->video_max_pps)
            score_video += cfg->weight_pps_video;
        else if (stats->pps >= cfg->bulk_min_pps)
            score_bulk += cfg->weight_pps_bulk;
        else
            score_normal += cfg->weight_pps_normal;
    }

    if ((mask & FEATURE_BURST) &&
        (stats->burst_packets > cfg->burst_packets || stats->burst_bytes > cfg->burst_bytes))
        score_bulk += cfg->weight_burst_bulk;

    if ((mask & FEATURE_TCPFLAGS) && packets >= cfg->tcp_flags_window) {
        if (stats->ack_count > 0) {
            if (stats->syn_count * 100 > stats->ack_count * cfg->tcp_flags_syn_ack_ratio)
                score_bulk += cfg->weight_tcpflags_bulk;
        }
        if (stats->rst_count > packets / 10)
            score_bulk += cfg->weight_tcpflags_bulk;
    }

    if ((mask & FEATURE_RETRANS) && packets >= 10) {
        if (stats->retrans_count * 100 > packets * cfg->retrans_threshold)
            score_bulk += cfg->weight_retrans_bulk;
    }

    if ((mask & FEATURE_DURATION) && packets >= cfg->game_sample_packets) {
        __u64 duration = (stats->last_seen - stats->first_seen) / 1000000000ULL;
        if (duration < cfg->conn_duration_short)
            score_realtime += cfg->weight_duration_realtime;
        else if (duration > cfg->conn_duration_long)
            score_bulk += cfg->weight_duration_bulk;
        else
            score_video += cfg->weight_duration_video;
    }

    if ((mask & FEATURE_RATIO) && stats->down_bytes > 0) {
        __u32 ratio = (stats->up_bytes * 100) / stats->down_bytes;
        if (ratio < cfg->up_down_ratio_low)
            score_video += cfg->weight_ratio_video;
        else if (ratio > cfg->up_down_ratio_high)
            score_realtime += cfg->weight_ratio_realtime;
        else
            score_bulk += cfg->weight_ratio_bulk;
    }

    if ((mask & FEATURE_IAT) && stats->iat_us > 0 && stats->iat_us < cfg->iat_threshold_us)
        score_realtime += cfg->weight_iat_realtime;

    __u32 threshold = cfg->score_threshold;
    __u32 max_score = 0;
    __u32 selected = 0;

    if (score_realtime >= threshold && score_realtime > max_score) {
        max_score = score_realtime;
        selected = 0;
    }
    if (score_video >= threshold && score_video > max_score) {
        max_score = score_video;
        selected = 1;
    }
    if (score_normal >= threshold && score_normal > max_score) {
        max_score = score_normal;
        selected = 2;
    }
    if (score_bulk >= threshold && score_bulk > max_score) {
        max_score = score_bulk;
        selected = 3;
    }
    return selected;
}

static __always_inline void ipv4_set_dscp(struct __sk_buff *skb, __u32 offset, __u8 dscp)
{
    struct iphdr *iph;
    __u32 check;
    __u8 old_tos;

    iph = skb_ptr(skb, offset, sizeof(*iph));
    if (!iph) return;

    old_tos = iph->tos;
    if (old_tos == ((old_tos & 0xFC) | dscp)) return;

    check = bpf_ntohs(iph->check);
    check += old_tos;
    check -= ((old_tos & 0xFC) | dscp);
    check = (check & 0xFFFF) + (check >> 16);
    iph->check = bpf_htons((__u16)check);
    iph->tos = (iph->tos & 0xFC) | dscp;
}

static __always_inline void ipv6_set_dscp(struct __sk_buff *skb, __u32 offset, __u8 dscp)
{
    struct ipv6hdr *ip6h;
    __u16 *p;
    __u16 val;

    ip6h = skb_ptr(skb, offset, sizeof(*ip6h));
    if (!ip6h) return;

    p = (__u16 *)ip6h;
    // 前 4 位是版本，接着 12 位流标签，再 8 位流量类型（包括 DSCP 和 ECN）
    val = (*p & bpf_htons(0x0F00)) | bpf_htons(((__u16)dscp << 4) & 0x0FF0);
    if (val == *p) return;
    *p = val;
}

SEC("classifier")
int classify(struct __sk_buff *skb)
{
	struct skb_parser_info info;
	__u8 ingress = !!(module_flags & IDCLASS_INGRESS);
	struct global_config *gcfg;
	struct idclass_class *class = NULL;
	struct idclass_ip_map_val *ip_val;
	__u32 iph_offset;
	__u8 dscp = 0;
	int type;
	__u32 hash;
	struct flow_stats *stats;
	__u32 prio_level = 0;

	gcfg = get_global_config();
	if (!gcfg) return TC_ACT_UNSPEC;

	skb_parse_init(&info, skb);
	if (module_flags & IDCLASS_IP_ONLY) {
		type = info.proto = skb->protocol;
	} else if (skb_parse_ethernet(&info)) {
		skb_parse_vlan(&info);
		skb_parse_vlan(&info);
		type = info.proto;
	} else {
		return TC_ACT_UNSPEC;
	}

	iph_offset = info.offset;
	struct tcphdr *tcph = NULL;
	if (type == bpf_htons(ETH_P_IP))
		ip_val = parse_ipv4(gcfg, &info, ingress, &dscp, &tcph);
	else if (type == bpf_htons(ETH_P_IPV6))
		ip_val = parse_ipv6(gcfg, &info, ingress, &dscp, &tcph);
	else
		return TC_ACT_UNSPEC;

	if (ip_val) {
		if (!ip_val->seen)
			ip_val->seen = 1;
		dscp = ip_val->dscp;
	}

	if (dscp & IDCLASS_DSCP_CLASS_FLAG) {
		__u32 key = dscp & IDCLASS_DSCP_VALUE_MASK;
		class = bpf_map_lookup_elem(&class_map, &key);
		if (class && !(class->flags & IDCLASS_CLASS_FLAG_PRESENT))
			class = NULL;
	}

	hash = bpf_get_hash_recalc(skb);
	stats = bpf_map_lookup_elem(&flow_stats_map, &hash);
	if (!stats) {
		struct flow_stats new = {};
		new.first_seen = bpf_ktime_get_ns();
		new.last_seen = new.first_seen;
		new.last_pkt_ts = new.first_seen;
		new.avg_pkt_len = skb->len;
		new.burst_start_ts = bpf_ktime_get_ns() / 1000000ULL;
		new.burst_packets = 1;
		new.burst_bytes = skb->len;
		__builtin_memset(new.client_ip, 0, 16);
		new.client_family = 0;
		bpf_map_update_elem(&flow_stats_map, &hash, &new, BPF_NOEXIST);
		stats = bpf_map_lookup_elem(&flow_stats_map, &hash);
	}

	if (stats && class) {
		update_flow_stats(stats, skb->len, bpf_ktime_get_ns(), ingress, &class->config, tcph);

		if (type == bpf_htons(ETH_P_IP)) {
			struct iphdr *iph = skb_ptr(skb, iph_offset, sizeof(*iph));
			if (iph) {
				__u32 src = iph->saddr;
				__u32 dst = iph->daddr;
				__u32 ip = (ingress) ? src : dst;
				__builtin_memset(stats->client_ip, 0, 10);
				stats->client_ip[10] = 0xff;
				stats->client_ip[11] = 0xff;
				__builtin_memcpy(stats->client_ip + 12, &ip, 4);
				stats->client_family = 4;
			}
		} else if (type == bpf_htons(ETH_P_IPV6)) {
			struct ipv6hdr *ip6h = skb_ptr(skb, iph_offset, sizeof(*ip6h));
			if (ip6h) {
				void *addr = ingress ? (void *)&ip6h->saddr : (void *)&ip6h->daddr;
				__builtin_memcpy(stats->client_ip, addr, 16);
				stats->client_family = 6;
			}
		}

		prio_level = classify_score(stats, &class->config);
	}

	__u32 *class_id_ptr;
	if (ingress)
		class_id_ptr = bpf_map_lookup_elem(&prio_class_up, &prio_level);
	else
		class_id_ptr = bpf_map_lookup_elem(&prio_class_down, &prio_level);

	if (class_id_ptr) {
		__u32 *val = bpf_map_lookup_elem(&class_mark, class_id_ptr);
		if (val) {
			if (module_flags & IDCLASS_SET_DSCP) {
				__u8 dscp_val = *val & 0x3F;
				if (type == bpf_htons(ETH_P_IP))
					ipv4_set_dscp(skb, iph_offset, dscp_val);
				else if (type == bpf_htons(ETH_P_IPV6))
					ipv6_set_dscp(skb, iph_offset, dscp_val);
			} else {
				bpf_skb_set_mark(skb, *val);
			}
		}
	}

	return TC_ACT_UNSPEC;
}

char _license[] SEC("license") = "GPL";