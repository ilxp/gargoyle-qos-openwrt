// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 * Modified to support four-class classification (realtime, video, normal, bulk)
 */
#ifndef __BPF_IDCLASS_H
#define __BPF_IDCLASS_H

#include <linux/types.h>

#define IDCLASS_MAX_CLASS_ENTRIES	33
#define IDCLASS_DEFAULT_CLASS_ENTRIES	2

#ifndef IDCLASS_FLOW_BUCKET_SHIFT
#define IDCLASS_FLOW_BUCKET_SHIFT	13
#endif

#define IDCLASS_FLOW_BUCKETS		(1 << IDCLASS_FLOW_BUCKET_SHIFT)

#define IDCLASS_INGRESS			(1 << 0)
#define IDCLASS_IP_ONLY			(1 << 1)

#define IDCLASS_DSCP_VALUE_MASK		((1 << 6) - 1)
#define IDCLASS_DSCP_FALLBACK_FLAG	(1 << 6)
#define IDCLASS_DSCP_CLASS_FLAG		(1 << 7)
#define IDCLASS_SET_DSCP          (1 << 2)
#define IDCLASS_CLASS_FLAG_PRESENT	(1 << 0)

// 特征掩码宏
#define FEATURE_PKTLEN    (1 << 0)
#define FEATURE_CONN      (1 << 1)
#define FEATURE_PPS       (1 << 2)
#define FEATURE_IAT       (1 << 3)
#define FEATURE_RETRANS   (1 << 4)
#define FEATURE_TCPFLAGS  (1 << 5)
#define FEATURE_DURATION  (1 << 6)
#define FEATURE_RATIO     (1 << 7)
#define FEATURE_BURST     (1 << 8)

struct idclass_dscp_val {
	uint8_t ingress;
	uint8_t egress;
};

struct idclass_flow_config {
	uint8_t bulk_trigger_timeout;
	uint16_t bulk_trigger_pps;
	uint16_t prio_max_avg_pkt_len;

	uint16_t game_max_avg_pkt_len;
	uint16_t game_max_conn;
	uint16_t game_max_pps;
	uint16_t game_sample_packets;

	uint16_t video_min_avg_pkt_len;
	uint16_t video_max_avg_pkt_len;
	uint16_t video_max_conn;
	uint16_t video_min_pps;
	uint16_t video_max_pps;

	uint16_t bulk_min_avg_pkt_len;
	uint16_t bulk_min_conn;
	uint16_t bulk_min_pps;

	uint16_t tcp_flags_syn_ack_ratio;   /* 乘以 100 */
	uint16_t tcp_flags_window;

	uint16_t conn_duration_short;
	uint16_t conn_duration_long;

	uint16_t up_down_ratio_low;
	uint16_t up_down_ratio_high;

	uint16_t burst_window_ms;
	uint16_t burst_packets;
	uint16_t burst_bytes;

	uint16_t iat_threshold_us;
	uint16_t retrans_threshold;

	uint32_t feature_mask;

	uint16_t weight_pktlen_realtime;
	uint16_t weight_pktlen_video;
	uint16_t weight_pktlen_normal;
	uint16_t weight_pktlen_bulk;
	uint16_t weight_conn_realtime;
	uint16_t weight_conn_video;
	uint16_t weight_conn_normal;
	uint16_t weight_conn_bulk;
	uint16_t weight_pps_realtime;
	uint16_t weight_pps_video;
	uint16_t weight_pps_normal;
	uint16_t weight_pps_bulk;
	uint16_t weight_burst_bulk;
	uint16_t weight_tcpflags_bulk;
	uint16_t weight_retrans_bulk;
	uint16_t weight_duration_realtime;
	uint16_t weight_duration_video;
	uint16_t weight_duration_bulk;
	uint16_t weight_ratio_video;
	uint16_t weight_ratio_realtime;
	uint16_t weight_ratio_bulk;
	uint16_t weight_iat_realtime;

	uint32_t score_threshold;

	uint32_t prio_realtime;
	uint32_t prio_video;
	uint32_t prio_normal;
	uint32_t prio_bulk;
};

struct flow_stats {
	__u64 packets;
	__u64 bytes;
	__u32 avg_pkt_len;
	__u64 first_seen;
	__u64 last_seen;
	__u32 pps;
	__u64 last_pps_ts;
	__u32 packets_in_window;
	__u32 burst_packets;
	__u32 burst_bytes;
	__u64 burst_start_ts;
	__u32 syn_count;
	__u32 ack_count;
	__u32 fin_count;
	__u32 rst_count;
	__u32 retrans_count;
	__u32 tcp_seq;
	__u8  fin_rst_seen;
	__u64 up_bytes;
	__u64 down_bytes;
	__u64 last_pkt_ts;
	__u32 iat_us;
	// 新增字段（优化 IPv6 支持）
	__u8 client_ip[16];        // 客户端 IP（IPv4 用 IPv4-mapped 格式）
	__u8 client_family;        // 地址族：4 或 6
	__u32 max_seq;              // 最大 TCP 序列号
};

struct global_config {
	uint8_t dscp_icmp;
	uint32_t wan_ifindex;
	uint32_t ifb_ifindex;
};

struct idclass_class {
	struct idclass_flow_config config;
	struct idclass_dscp_val val;
	uint8_t flags;
	uint64_t packets;
};

#endif