// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 * Modified to support four-class classification (realtime, video, normal, bulk)
 * Extended with TCP window, MSS, RTT features (12 features total).
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
#define IDCLASS_SET_DSCP			(1 << 2)

#define IDCLASS_DSCP_VALUE_MASK		((1 << 6) - 1)
#define IDCLASS_DSCP_FALLBACK_FLAG	(1 << 6)
#define IDCLASS_DSCP_CLASS_FLAG		(1 << 7)

#define IDCLASS_CLASS_FLAG_PRESENT	(1 << 0)

// 特征掩码宏（共12个）
#define FEATURE_PKTLEN      (1 << 0)
#define FEATURE_CONN        (1 << 1)
#define FEATURE_PPS         (1 << 2)
#define FEATURE_IAT         (1 << 3)
#define FEATURE_RETRANS     (1 << 4)
#define FEATURE_TCPFLAGS    (1 << 5)
#define FEATURE_DURATION    (1 << 6)
#define FEATURE_RATIO       (1 << 7)
#define FEATURE_BURST       (1 << 8)
#define FEATURE_TCP_WINDOW  (1 << 9)
#define FEATURE_TCP_MSS     (1 << 10)
#define FEATURE_TCP_RTT     (1 << 11)

/* 定义结构体，放在 map 定义之前 */
struct idclass_ip_map_val {
    __u8 dscp;
    __u8 seen;
};

struct idclass_dscp_val {
    __u8 ingress;
    __u8 egress;
};

struct idclass_flow_config {
    __u8 bulk_trigger_timeout;
    __u16 bulk_trigger_pps;
    __u16 prio_max_avg_pkt_len;

    __u16 game_max_avg_pkt_len;
    __u16 game_min_conn;
    __u16 game_max_conn;
    __u16 game_max_pps;
    __u16 game_sample_packets;

    __u16 video_min_avg_pkt_len;
    __u16 video_max_avg_pkt_len;
    __u16 video_min_conn;
    __u16 video_max_conn;
    __u16 video_min_pps;
    __u16 video_max_pps;

    __u16 bulk_min_avg_pkt_len;
    __u16 bulk_min_conn;
    __u16 bulk_min_pps;

    __u16 tcp_flags_syn_ack_ratio;   /* 乘以 100 */
    __u16 tcp_flags_window;

    __u16 conn_duration_short;
    __u16 conn_duration_long;

    __u16 up_down_ratio_low;
    __u16 up_down_ratio_high;

    __u16 burst_window_ms;
    __u16 burst_packets;
    __u16 burst_bytes;

    __u16 iat_threshold_us;
    __u16 retrans_threshold;

    __u32 feature_mask;

    __u16 weight_pktlen_realtime;
    __u16 weight_pktlen_video;
    __u16 weight_pktlen_normal;
    __u16 weight_pktlen_bulk;
    __u16 weight_conn_realtime;
    __u16 weight_conn_video;
    __u16 weight_conn_normal;
    __u16 weight_conn_bulk;
    __u16 weight_pps_realtime;
    __u16 weight_pps_video;
    __u16 weight_pps_normal;
    __u16 weight_pps_bulk;
    __u16 weight_burst_bulk;
    __u16 weight_tcpflags_bulk;
    __u16 weight_retrans_bulk;
    __u16 weight_duration_realtime;
    __u16 weight_duration_video;
    __u16 weight_duration_bulk;
    __u16 weight_ratio_video;
    __u16 weight_ratio_realtime;
    __u16 weight_ratio_bulk;
    __u16 weight_iat_realtime;

    // 新增 TCP 特征权重
    __u16 weight_window_realtime;
    __u16 weight_window_video;
    __u16 weight_window_normal;
    __u16 weight_window_bulk;
    __u16 weight_mss_realtime;
    __u16 weight_mss_video;
    __u16 weight_mss_normal;
    __u16 weight_mss_bulk;
    __u16 weight_rtt_realtime;
    __u16 weight_rtt_video;
    __u16 weight_rtt_normal;
    __u16 weight_rtt_bulk;

    // 新增 TCP 特征阈值
    __u16 tcp_window_low;      // 窗口低于此值视为实时（小窗口）
    __u16 tcp_window_high;     // 窗口高于此值视为批量（大窗口）
    __u16 tcp_mss_low;         // MSS 低于此值视为实时（小包）
    __u16 tcp_mss_high;        // MSS 高于此值视为批量（大包）
    __u16 tcp_rtt_low_us;      // RTT 低于此值视为实时（微秒）
    __u16 tcp_rtt_high_us;     // RTT 高于此值视为批量（微秒）

    __u32 score_threshold;

    __u32 prio_realtime;
    __u32 prio_video;
    __u32 prio_normal;
    __u32 prio_bulk;
} __attribute__((packed));

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
    __u64 tcp_seq;
    __u8  fin_rst_seen;
    __u64 up_bytes;
    __u64 down_bytes;
    __u64 last_pkt_ts;
    __u32 iat_us;
    // 新增字段（优化 IPv6 支持）
    __u8 client_ip[16];        // 客户端 IP（IPv4 用 IPv4-mapped 格式）
    __u8 client_family;        // 地址族：4 或 6
    __u64 max_seq;              // 最大 TCP 序列号

    // 新增 TCP 特征字段
    __u16 tcp_window;          // 当前 TCP 接收窗口大小（EWMA）
    __u16 tcp_mss;             // TCP 最大段大小（从 SYN 包提取）
    __u32 tcp_rtt_us;          // RTT 估计值（微秒，EWMA）
    __u32 tcp_rtt_var_us;      // RTT 方差（可选，暂未使用）
} __attribute__((packed));

struct global_config {
    __u8 dscp_icmp;
    __u32 wan_ifindex;
    __u32 ifb_ifindex;
} __attribute__((packed));

struct idclass_class {
    struct idclass_flow_config config;
    struct idclass_dscp_val val;
    __u8 flags;
    __u64 packets;
} __attribute__((packed));

#endif /* __BPF_IDCLASS_H */