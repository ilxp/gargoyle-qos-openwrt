// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 * Modified to support multi-feature classification
 */
#define KBUILD_MODNAME "foo"
#include <uapi/linux/bpf.h>
#include <uapi/linux/if_ether.h>
#include <uapi/linux/if_packet.h>
#include <uapi/linux/ip.h>
#include <uapi/linux/ipv6.h>
#include <uapi/linux/in.h>
#include <uapi/linux/tcp.h>
#include <uapi/linux/udp.h>
#include <uapi/linux/filter.h>
#include <uapi/linux/pkt_cls.h>
#include <linux/ip.h>
#include <net/ipv6.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include "bpf_skb_utils.h"
#include "idclass-bpf.h"

#define INET_ECN_MASK 3

#define FLOW_CHECK_INTERVAL	((u32)((1000000000ULL) >> 24))
#define FLOW_TIMEOUT		((u32)((30ULL * 1000000000ULL) >> 24))
#define FLOW_BULK_TIMEOUT	5

#define EWMA_SHIFT		12

const volatile static uint32_t module_flags = 0;

/* 每流统计 map */
struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 65536);
	__type(key, __u32);          /* 流的 hash 值 */
	__type(value, struct flow_stats);
} flow_stats_map SEC(".maps");

/* 原有的 flow_bucket map 保留，用于兼容 */
struct flow_bucket {
	__u32 last_update;
	__u32 pkt_len_avg;
	__u32 pkt_count;
	__u32 bulk_timeout;
};

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

/* 原有的 flow_map 保留，用于 bulk 检测 */
struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(pinning, 1);
	__type(key, __u32);
	__type(value, struct flow_bucket);
	__uint(max_entries, IDCLASS_FLOW_BUCKETS);
} flow_map SEC(".maps");

/* IP maps */
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

/* 类配置 map */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(pinning, 1);
	__type(key, __u32);
	__type(value, struct idclass_class);
	__uint(max_entries, IDCLASS_MAX_CLASS_ENTRIES +
			    IDCLASS_DEFAULT_CLASS_ENTRIES);
} class_map SEC(".maps");

/* 静态规则 map（未在 eBPF 中使用，但在用户态使用）*/
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 1024);
	__type(key, struct rule_key);
	__type(value, uint32_t);
} static_rules SEC(".maps");

/* ip_conn_map（每客户端 IP 连接数） */
struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 16384);
	__type(key, __u32);
	__type(value, uint32_t);
} ip_conn_map SEC(".maps");

static struct global_config *get_global_config(void)
{
	__u32 key = 0;
	return bpf_map_lookup_elem(&global_config, &key);
}

static __always_inline __u32 cur_time(void)
{
	__u32 val = bpf_ktime_get_ns() >> 24;
	if (!val) val = 1;
	return val;
}

static __always_inline __u32 ewma(__u32 *avg, __u32 val)
{
	if (*avg)
		*avg = (*avg * 3) / 4 + (val << EWMA_SHIFT) / 4;
	else
		*avg = val << EWMA_SHIFT;
	return *avg >> EWMA_SHIFT;
}

static __always_inline __u8 dscp_val(struct idclass_dscp_val *val, bool ingress)
{
	return ingress ? val->ingress : val->egress;
}

static __always_inline void
ipv4_change_dsfield(struct __sk_buff *skb, __u32 offset,
		    __u8 mask, __u8 value, bool force)
{
	struct iphdr *iph;
	__u32 check;
	__u8 dsfield;

	iph = skb_ptr(skb, offset, sizeof(*iph));
	if (!iph) return;

	check = bpf_ntohs(iph->check);
	if ((iph->tos & mask) && !force) return;

	dsfield = (iph->tos & mask) | value;
	if (iph->tos == dsfield) return;

	check += iph->tos;
	if ((check + 1) >> 16)
		check = (check + 1) & 0xffff;
	check -= dsfield;
	check += check >> 16;
	iph->check = bpf_htons(check);
	iph->tos = dsfield;
}

static __always_inline void
ipv6_change_dsfield(struct __sk_buff *skb, __u32 offset,
		    __u8 mask, __u8 value, bool force)
{
	struct ipv6hdr *ipv6h;
	__u16 *p;
	__u16 val;

	ipv6h = skb_ptr(skb, offset, sizeof(*ipv6h));
	if (!ipv6h) return;

	p = (__u16 *)ipv6h;
	if (((*p >> 4) & mask) && !force) return;

	val = (*p & bpf_htons((((__u16)mask << 4) | 0xf00f))) | bpf_htons((__u16)value << 4);
	if (val == *p) return;
	*p = val;
}

static void
parse_l4proto(struct global_config *config, struct skb_parser_info *info,
	      bool ingress, __u8 *out_val)
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

/* 原有的 bulk 检测函数（可保留） */
static __always_inline bool
check_flow_bulk(struct idclass_flow_config *config, struct __sk_buff *skb,
		struct flow_bucket *flow, __u8 *out_val)
{
	bool trigger = false;
	__s32 delta;
	__u32 time;
	int segs = 1;
	bool ret = false;

	if (!config->bulk_trigger_pps) return false;

	time = cur_time();
	if (!flow->last_update) goto reset;

	delta = time - flow->last_update;
	if ((u32)delta > FLOW_TIMEOUT) goto reset;

	if (skb->gso_segs)
		segs = skb->gso_segs;
	flow->pkt_count += segs;
	if (flow->pkt_count > config->bulk_trigger_pps) {
		flow->bulk_timeout = config->bulk_trigger_timeout + 1;
		trigger = true;
	}
	if (delta >= FLOW_CHECK_INTERVAL) {
		if (flow->bulk_timeout && !trigger)
			flow->bulk_timeout--;
		goto clear;
	}
	goto out;

reset:
	flow->pkt_len_avg = 0;
clear:
	flow->pkt_count = 1;
	flow->last_update = time;
out:
	if (flow->bulk_timeout) {
		*out_val = config->dscp_bulk;
		return true;
	}
	return false;
}

/* 原有的 prio 检测函数 */
static __always_inline bool
check_flow_prio(struct idclass_flow_config *config, struct __sk_buff *skb,
		struct flow_bucket *flow, __u8 *out_val)
{
	int cur_len = skb->len;

	if (flow->bulk_timeout) return false;
	if (!config->prio_max_avg_pkt_len) return false;

	if (skb->gso_segs > 1)
		cur_len /= skb->gso_segs;

	if (ewma(&flow->pkt_len_avg, cur_len) <= config->prio_max_avg_pkt_len) {
		*out_val = config->dscp_prio;
		return true;
	}
	return false;
}

static __always_inline struct idclass_ip_map_val *
parse_ipv4(struct global_config *config, struct skb_parser_info *info,
	   bool ingress, __u8 *out_val, struct tcphdr **tcph_ptr)
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
	   bool ingress, __u8 *out_val, struct tcphdr **tcph_ptr)
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

/* 更新流统计（用于多特征评分） */
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

	/* 包间间隔 */
	if (prev_ts != 0) {
		__u64 iat_ns = ts_ns - prev_ts;
		stats->iat_us = iat_ns / 1000ULL;
	}

	/* 平均包长（EWMA） */
	ewma(&stats->avg_pkt_len, pkt_len);

	/* 方向流量 */
	if (direction == 1)
		__sync_fetch_and_add(&stats->up_bytes, pkt_len);
	else if (direction == 2)
		__sync_fetch_and_add(&stats->down_bytes, pkt_len);

	/* PPS */
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

	/* 突发检测 */
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

	/* TCP 标志和重传 */
	if (tcph) {
		__u8 tcp_flags = ((__u8 *)tcph)[13];
		if (tcp_flags & 0x02) /* SYN */
			__sync_fetch_and_add(&stats->syn_count, 1);
		if (tcp_flags & 0x10) /* ACK */
			__sync_fetch_and_add(&stats->ack_count, 1);
		if (tcp_flags & 0x01) /* FIN */
			__sync_fetch_and_add(&stats->fin_count, 1);
		if (tcp_flags & 0x04) /* RST */
			__sync_fetch_and_add(&stats->rst_count, 1);

		__u32 old_seq = __sync_lock_test_and_set(&stats->tcp_seq, bpf_ntohl(tcph->seq));
		if (old_seq == bpf_ntohl(tcph->seq))
			__sync_fetch_and_add(&stats->retrans_count, 1);
	}
}

/* 多特征评分函数，返回 class_id */
static __always_inline __u32 classify_score(struct flow_stats *stats,
                                           __u32 client_ip,
                                           struct idclass_flow_config *cfg)
{
    __u32 score_realtime = 0, score_video = 0, score_normal = 0, score_bulk = 0;
    __u32 packets = stats->packets;
    __u32 *conn = NULL;

    /* 包长 */
    if (packets >= cfg->game_sample_packets) {
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

    /* 连接数 */
    conn = bpf_map_lookup_elem(&ip_conn_map, &client_ip);
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

    /* PPS */
    if (packets >= cfg->game_sample_packets) {
        if (stats->pps <= cfg->game_max_pps)
            score_realtime += cfg->weight_pps_realtime;
        else if (stats->pps >= cfg->video_min_pps && stats->pps <= cfg->video_max_pps)
            score_video += cfg->weight_pps_video;
        else if (stats->pps >= cfg->bulk_min_pps)
            score_bulk += cfg->weight_pps_bulk;
        else
            score_normal += cfg->weight_pps_normal;
    }

    /* 突发 */
    if (stats->burst_packets > cfg->burst_packets || stats->burst_bytes > cfg->burst_bytes)
        score_bulk += cfg->weight_burst_bulk;

    /* TCP 标志分布 */
    if (packets >= cfg->tcp_flags_window) {
        if (stats->ack_count > 0) {
            __u32 ratio = (stats->syn_count * 100) / stats->ack_count;
            if (ratio > cfg->tcp_flags_syn_ack_ratio)
                score_bulk += cfg->weight_tcpflags_bulk;
        }
        if (stats->rst_count > packets / 10)
            score_bulk += cfg->weight_tcpflags_bulk; /* 可选复用同一权重，或另设 */
    }

    /* 重传 */
    if (packets >= 10) {
        __u32 retrans_ratio = (stats->retrans_count * 100) / packets;
        if (retrans_ratio > cfg->retrans_threshold)
            score_bulk += cfg->weight_retrans_bulk;
    }

    /* 连接持续时间 */
    if (packets >= cfg->game_sample_packets) {
        __u64 duration = (stats->last_seen - stats->first_seen) / 1000000000ULL;
        if (duration < cfg->conn_duration_short)
            score_realtime += cfg->weight_duration_realtime;
        else if (duration > cfg->conn_duration_long)
            score_bulk += cfg->weight_duration_bulk;
        else
            score_video += cfg->weight_duration_video;
    }

    /* 上下行流量比 */
    if (stats->down_bytes > 0) {
        __u32 ratio = (stats->up_bytes * 100) / stats->down_bytes;
        if (ratio < cfg->up_down_ratio_low)
            score_video += cfg->weight_ratio_video;
        else if (ratio > cfg->up_down_ratio_high)
            score_realtime += cfg->weight_ratio_realtime;
        else
            score_bulk += cfg->weight_ratio_bulk;
    }

    /* IAT */
    if (stats->iat_us > 0 && stats->iat_us < cfg->iat_threshold_us)
        score_realtime += cfg->weight_iat_realtime;

    /* 选择得分最高的类，要求至少达到阈值 */
    __u32 threshold = cfg->score_threshold;
    __u32 max_score = 0;
    __u32 selected = 0;

    if (score_realtime >= threshold && score_realtime > max_score) {
        max_score = score_realtime;
        selected = cfg->class_realtime;
    }
    if (score_video >= threshold && score_video > max_score) {
        max_score = score_video;
        selected = cfg->class_video;
    }
    if (score_normal >= threshold && score_normal > max_score) {
        max_score = score_normal;
        selected = cfg->class_normal;
    }
    if (score_bulk >= threshold && score_bulk > max_score) {
        max_score = score_bulk;
        selected = cfg->class_bulk;
    }

    return selected;
}

SEC("classifier")
int classify(struct __sk_buff *skb)
{
	struct skb_parser_info info;
	bool ingress = module_flags & IDCLASS_INGRESS;
	struct global_config *gcfg;
	struct idclass_class *class = NULL;
	struct idclass_ip_map_val *ip_val;
	__u32 iph_offset;
	__u8 dscp = 0;
	int type;
	__u32 hash;
	struct flow_stats *stats;
	struct flow_bucket *flow;
	__u32 class_id = 0;
	__u32 client_ip_mapped = 0;

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

	/* 获取类配置 */
	if (dscp & IDCLASS_DSCP_CLASS_FLAG) {
		__u32 key = dscp & IDCLASS_DSCP_VALUE_MASK;
		class = bpf_map_lookup_elem(&class_map, &key);
		if (class && !(class->flags & IDCLASS_CLASS_FLAG_PRESENT))
			class = NULL;
	}
	
	/* 计算客户端 IP（用于连接数统计） */
	if (key.family == 4) {
		__u32 src = *(__u32 *)key.saddr;
		__u32 dst = *(__u32 *)key.daddr;
		client_ip_mapped = (ingress) ? src : dst;  /* 上传方向源 IP 是客户端，下载方向目的 IP 是客户端 */
	} else {
		/* IPv6 简化：取前32位作为客户端标识（实际应用中应使用完整 IPv6，但为简化暂用前32位） */
		if (ingress)
			__builtin_memcpy(&client_ip_mapped, key.saddr, 4);
		else
			__builtin_memcpy(&client_ip_mapped, key.daddr, 4);
	}

	/* 获取或创建 flow_stats */
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
		bpf_map_update_elem(&flow_stats_map, &hash, &new, BPF_NOEXIST);
		stats = bpf_map_lookup_elem(&flow_stats_map, &hash);
	}

	/* 原有的 flow_bucket 检测（仍可保留） */
	flow = bpf_map_lookup_elem(&flow_map, &hash);
	if (!flow) {
		struct flow_bucket new = {};
		bpf_map_update_elem(&flow_map, &hash, &new, BPF_ANY);
		flow = bpf_map_lookup_elem(&flow_map, &hash);
	}

	if (stats && class) {
		/* 更新统计 */
		update_flow_stats(stats, skb->len, bpf_ktime_get_ns(), ingress, &class->config, tcph);

		/* 多特征评分，得到 class_id */
		class_id = classify_score(stats, client_ip_mapped, &class->config);
	}

	/* 如果评分未决定，则使用原有的 bulk/prio 检测（可选） */
	if (!class_id && flow && class) {
		__u8 tmp_dscp = 0;
		if (check_flow_bulk(&class->config, skb, flow, &tmp_dscp) ||
		    check_flow_prio(&class->config, skb, flow, &tmp_dscp)) {
			/* 根据 tmp_dscp 确定 class_id */
			if (tmp_dscp == class->config.dscp_prio)
				class_id = class->config.class_realtime;
			else if (tmp_dscp == class->config.dscp_bulk)
				class_id = class->config.class_bulk;
		}
	}

	if (class_id) {
		__u32 mark;
		if (ingress)
			mark = class_id;          /* 上传方向 mark = class_id */
		else
			mark = 0x10000 | class_id; /* 下载方向 mark = 0x10000 + class_id */
		bpf_skb_set_mark(skb, mark);
	}

	return TC_ACT_UNSPEC;
}

char _license[] SEC("license") = "GPL";