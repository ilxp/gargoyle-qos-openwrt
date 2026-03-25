// SPDX-License-Identifier: GPL-2.0+
/*
 * config.c - UCI configuration management module
 *
 * Responsible for parsing UCI config files, maintaining global and flow
 * configuration, and synchronizing settings to BPF maps via map_manager.
 */
#include "common.h"
#include <uci.h>
#include <libubox/blobmsg.h>
#include <net/if.h>
#include <sys/stat.h>

/* 全局配置实例（由 map_manager 定义，此处仅引用） */
extern struct global_config global_config;
extern struct idclass_flow_config global_flow_config;

/* UCI 配置名称（可通过命令行参数 -c 设置） */
static const char *uci_config_name = "qos_gargoyle";

/* UCI 热重载定时器 */
static struct uloop_timeout uci_reload_timer;
static time_t last_uci_mtime = 0;

/* 内部函数：读取配置中的浮点数百分比（乘以100） */
static int read_float_mult100(const char *val) {
    double d = atof(val);
    return (int)(d * 100 + 0.5);
}

/* 外部接口：设置 UCI 配置名（由 main.c 调用） */
void config_set_name(const char *name) {
    uci_config_name = name;
}

/* 外部接口：获取当前 UCI 配置名（供 ebpf_loader 使用） */
const char *config_get_name(void) {
    return uci_config_name;
}

/* 内部函数：从 UCI 加载类配置（upload_class/download_class）并更新 BPF map */
static int load_class_config(void) {
    struct uci_context *uci;
    struct uci_package *pkg;
    struct uci_element *e;
    struct blob_buf b = {0};
    int ret = -1;

    uci = uci_alloc_context();
    if (!uci) return -1;
    if (uci_load(uci, uci_config_name, &pkg) != UCI_OK) goto out;

    blob_buf_init(&b, 0);

    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        const char *type = uci_lookup_option_string(uci, s, "type") ?: s->type;
        if (!type) continue;

        /* 处理上传类和下载类节 */
        if (strcmp(type, "upload_class") == 0 || strcmp(type, "download_class") == 0) {
            const char *ingress = uci_lookup_option_string(uci, s, "ingress");
            const char *egress = uci_lookup_option_string(uci, s, "egress");
            if (!ingress || !egress) continue;

            void *c = blobmsg_open_table(&b, s->e.name);
            blobmsg_add_string(&b, "ingress", ingress);
            blobmsg_add_string(&b, "egress", egress);
            blobmsg_close_table(&b, c);
        }
    }

    if (b.head) {
        map_manager_set_classes(b.head);
        ret = 0;
    }
    blob_buf_free(&b);

out:
    uci_unload(uci, pkg);
    uci_free_context(uci);
    return ret;
}

/* 内部函数：加载全局配置和 flow 配置 */
static int load_idclass_config(void) {
    struct uci_context *uci;
    struct uci_package *pkg;
    struct uci_element *e;
    struct blob_buf b = {0};
    int ret = -1;

    uci = uci_alloc_context();
    if (!uci) return -1;
    if (uci_load(uci, uci_config_name, &pkg) != UCI_OK) goto out;

    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        const char *type = uci_lookup_option_string(uci, s, "type") ?: s->type;
        if (!type || strcmp(type, "idclass") != 0) continue;

        /* 解析 wan_interface 和 ifb_device */
        const char *wan_iface = uci_lookup_option_string(uci, s, "wan_interface");
        if (wan_iface) global_config.wan_ifindex = if_nametoindex(wan_iface);
        const char *ifb_iface = uci_lookup_option_string(uci, s, "ifb_device");
        if (ifb_iface) global_config.ifb_ifindex = if_nametoindex(ifb_iface);

        /* 解析 dscp_icmp */
        const char *dscp_icmp = uci_lookup_option_string(uci, s, "dscp_icmp");
        if (dscp_icmp) idclass_map_dscp_value(dscp_icmp, &global_config.dscp_icmp);

        /* 将 section 中的所有选项打包成 blob，供 config_parse_flow_config 解析 */
        blob_buf_init(&b, 0);
        struct uci_element *opt;
        uci_foreach_element(&s->options, opt) {
            struct uci_option *o = uci_to_option(opt);
            if (o->type != UCI_TYPE_STRING) continue;
            blobmsg_add_string(&b, o->e.name, o->v.string);
        }
        config_parse_flow_config(&global_flow_config, b.head, true);
        blob_buf_free(&b);

        ret = 0;
        break; /* 只处理第一个 idclass 节 */
    }

    uci_unload(uci, pkg);
out:
    uci_free_context(uci);
    return ret;
}

/* UCI 文件监控回调 */
static void config_check_uci_reload(struct uloop_timeout *t) {
    struct stat st;
    char path[256];
    snprintf(path, sizeof(path), "/etc/config/%s", uci_config_name);
    if (stat(path, &st) == 0) {
        if (st.st_mtime != last_uci_mtime) {
            last_uci_mtime = st.st_mtime;
            if (load_idclass_config() == 0) {
                /* 配置更新后同步到 BPF map */
                map_manager_update_config();
                map_manager_sync_class_config();
                ULOG_INFO("UCI config reloaded\n");
            } else {
                ULOG_ERR("Failed to reload UCI config\n");
            }
            /* 重新加载类配置（无论 idclass 节是否变化，类配置可能独立变化） */
            if (load_class_config() == 0) {
                ULOG_INFO("UCI class config reloaded\n");
            } else {
                ULOG_ERR("Failed to reload UCI class config\n");
            }
        }
    }
    uloop_timeout_set(t, 1000);
}

/* 外部接口：解析 DSCP 值 */
int config_parse_dscp_value(uint8_t *dest, struct blob_attr *attr, bool reset) {
    if (reset) *dest = 0xff;
    if (!attr) return 0;
    return idclass_map_dscp_value(blobmsg_get_string(attr), dest);
}

/* 外部接口：解析流特征配置（包含所有12个特征） */
int config_parse_flow_config(struct idclass_flow_config *cfg, struct blob_attr *attr, bool reset) {
    enum {
        CL_CONFIG_BULK_TIMEOUT, CL_CONFIG_BULK_PPS, CL_CONFIG_PRIO_PKT_LEN,
        CL_CONFIG_GAME_MAX_AVG_PKT_LEN, CL_CONFIG_GAME_MIN_CONN, CL_CONFIG_GAME_MAX_CONN,
        CL_CONFIG_GAME_MAX_PPS, CL_CONFIG_GAME_SAMPLE_PACKETS,
        CL_CONFIG_VIDEO_MIN_AVG_PKT_LEN, CL_CONFIG_VIDEO_MAX_AVG_PKT_LEN,
        CL_CONFIG_VIDEO_MIN_CONN, CL_CONFIG_VIDEO_MAX_CONN,
        CL_CONFIG_VIDEO_MIN_PPS, CL_CONFIG_VIDEO_MAX_PPS,
        CL_CONFIG_BULK_MIN_AVG_PKT_LEN, CL_CONFIG_BULK_MIN_CONN, CL_CONFIG_BULK_MIN_PPS,
        CL_CONFIG_TCP_FLAGS_SYN_ACK_RATIO, CL_CONFIG_TCP_FLAGS_WINDOW,
        CL_CONFIG_CONN_DURATION_SHORT, CL_CONFIG_CONN_DURATION_LONG,
        CL_CONFIG_UP_DOWN_RATIO_LOW, CL_CONFIG_UP_DOWN_RATIO_HIGH,
        CL_CONFIG_BURST_WINDOW_MS, CL_CONFIG_BURST_PACKETS, CL_CONFIG_BURST_BYTES,
        CL_CONFIG_IAT_THRESHOLD_US, CL_CONFIG_RETRANS_THRESHOLD,
        CL_CONFIG_ENABLE_PKTLEN, CL_CONFIG_ENABLE_CONN_COUNT, CL_CONFIG_ENABLE_PPS,
        CL_CONFIG_ENABLE_IAT, CL_CONFIG_ENABLE_RETRANS, CL_CONFIG_ENABLE_TCP_FLAGS,
        CL_CONFIG_ENABLE_CONN_DURATION, CL_CONFIG_ENABLE_UP_DOWN_RATIO, CL_CONFIG_ENABLE_BURST,
        CL_CONFIG_WEIGHT_PKTLEN_REALTIME, CL_CONFIG_WEIGHT_PKTLEN_VIDEO,
        CL_CONFIG_WEIGHT_PKTLEN_NORMAL, CL_CONFIG_WEIGHT_PKTLEN_BULK,
        CL_CONFIG_WEIGHT_CONN_REALTIME, CL_CONFIG_WEIGHT_CONN_VIDEO,
        CL_CONFIG_WEIGHT_CONN_NORMAL, CL_CONFIG_WEIGHT_CONN_BULK,
        CL_CONFIG_WEIGHT_PPS_REALTIME, CL_CONFIG_WEIGHT_PPS_VIDEO,
        CL_CONFIG_WEIGHT_PPS_NORMAL, CL_CONFIG_WEIGHT_PPS_BULK,
        CL_CONFIG_WEIGHT_BURST_BULK, CL_CONFIG_WEIGHT_TCPFLAGS_BULK,
        CL_CONFIG_WEIGHT_RETRANS_BULK, CL_CONFIG_WEIGHT_DURATION_REALTIME,
        CL_CONFIG_WEIGHT_DURATION_VIDEO, CL_CONFIG_WEIGHT_DURATION_BULK,
        CL_CONFIG_WEIGHT_RATIO_VIDEO, CL_CONFIG_WEIGHT_RATIO_REALTIME,
        CL_CONFIG_WEIGHT_RATIO_BULK, CL_CONFIG_WEIGHT_IAT_REALTIME,
        CL_CONFIG_SCORE_THRESHOLD, CL_CONFIG_PRIO_REALTIME, CL_CONFIG_PRIO_VIDEO,
        CL_CONFIG_PRIO_NORMAL, CL_CONFIG_PRIO_BULK,
        // 新增 TCP 特征相关选项
        CL_CONFIG_TCP_WINDOW_LOW, CL_CONFIG_TCP_WINDOW_HIGH,
        CL_CONFIG_TCP_MSS_LOW, CL_CONFIG_TCP_MSS_HIGH,
        CL_CONFIG_TCP_RTT_LOW_US, CL_CONFIG_TCP_RTT_HIGH_US,
        CL_CONFIG_WEIGHT_WINDOW_REALTIME, CL_CONFIG_WEIGHT_WINDOW_VIDEO,
        CL_CONFIG_WEIGHT_WINDOW_NORMAL, CL_CONFIG_WEIGHT_WINDOW_BULK,
        CL_CONFIG_WEIGHT_MSS_REALTIME, CL_CONFIG_WEIGHT_MSS_VIDEO,
        CL_CONFIG_WEIGHT_MSS_NORMAL, CL_CONFIG_WEIGHT_MSS_BULK,
        CL_CONFIG_WEIGHT_RTT_REALTIME, CL_CONFIG_WEIGHT_RTT_VIDEO,
        CL_CONFIG_WEIGHT_RTT_NORMAL, CL_CONFIG_WEIGHT_RTT_BULK,
        CL_CONFIG_ENABLE_TCP_WINDOW, CL_CONFIG_ENABLE_TCP_MSS, CL_CONFIG_ENABLE_TCP_RTT,
        __CL_CONFIG_MAX
    };
    static const struct blobmsg_policy policy[__CL_CONFIG_MAX] = {
        [CL_CONFIG_BULK_TIMEOUT] = { "bulk_trigger_timeout", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_BULK_PPS] = { "bulk_trigger_pps", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_PKT_LEN] = { "prio_max_avg_pkt_len", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_GAME_MAX_AVG_PKT_LEN] = { "game_max_avg_pktlen", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_GAME_MIN_CONN] = { "game_min_conn", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_GAME_MAX_CONN] = { "game_max_conn", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_GAME_MAX_PPS] = { "game_max_pps", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_GAME_SAMPLE_PACKETS] = { "game_sample_packets", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_VIDEO_MIN_AVG_PKT_LEN] = { "video_min_avg_pktlen", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_VIDEO_MAX_AVG_PKT_LEN] = { "video_max_avg_pktlen", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_VIDEO_MIN_CONN] = { "video_min_conn", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_VIDEO_MAX_CONN] = { "video_max_conn", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_VIDEO_MIN_PPS] = { "video_min_pps", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_VIDEO_MAX_PPS] = { "video_max_pps", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_BULK_MIN_AVG_PKT_LEN] = { "bulk_min_avg_pktlen", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_BULK_MIN_CONN] = { "bulk_min_conn", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_BULK_MIN_PPS] = { "bulk_min_pps", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_FLAGS_SYN_ACK_RATIO] = { "tcp_flags_syn_ack_ratio", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_FLAGS_WINDOW] = { "tcp_flags_window", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_CONN_DURATION_SHORT] = { "conn_duration_short", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_CONN_DURATION_LONG] = { "conn_duration_long", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_UP_DOWN_RATIO_LOW] = { "up_down_ratio_low", BLOBMSG_TYPE_STRING },
        [CL_CONFIG_UP_DOWN_RATIO_HIGH] = { "up_down_ratio_high", BLOBMSG_TYPE_STRING },
        [CL_CONFIG_BURST_WINDOW_MS] = { "burst_window_ms", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_BURST_PACKETS] = { "burst_packets", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_BURST_BYTES] = { "burst_bytes", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_IAT_THRESHOLD_US] = { "iat_threshold_us", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_RETRANS_THRESHOLD] = { "retrans_threshold", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_ENABLE_PKTLEN] = { "enable_pktlen", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_CONN_COUNT] = { "enable_conn_count", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_PPS] = { "enable_pps", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_IAT] = { "enable_iat", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_RETRANS] = { "enable_retrans", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_TCP_FLAGS] = { "enable_tcp_flags", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_CONN_DURATION] = { "enable_conn_duration", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_UP_DOWN_RATIO] = { "enable_up_down_ratio", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_BURST] = { "enable_burst", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_WEIGHT_PKTLEN_REALTIME] = { "weight_pktlen_realtime", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PKTLEN_VIDEO]    = { "weight_pktlen_video",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PKTLEN_NORMAL]   = { "weight_pktlen_normal",   BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PKTLEN_BULK]     = { "weight_pktlen_bulk",     BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_CONN_REALTIME]   = { "weight_conn_realtime",   BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_CONN_VIDEO]      = { "weight_conn_video",      BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_CONN_NORMAL]     = { "weight_conn_normal",     BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_CONN_BULK]       = { "weight_conn_bulk",       BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PPS_REALTIME]    = { "weight_pps_realtime",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PPS_VIDEO]       = { "weight_pps_video",       BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PPS_NORMAL]      = { "weight_pps_normal",      BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_PPS_BULK]        = { "weight_pps_bulk",        BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_BURST_BULK]      = { "weight_burst_bulk",      BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_TCPFLAGS_BULK]   = { "weight_tcpflags_bulk",   BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RETRANS_BULK]    = { "weight_retrans_bulk",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_DURATION_REALTIME] = { "weight_duration_realtime", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_DURATION_VIDEO]  = { "weight_duration_video",  BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_DURATION_BULK]   = { "weight_duration_bulk",   BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RATIO_VIDEO]     = { "weight_ratio_video",     BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RATIO_REALTIME]  = { "weight_ratio_realtime",  BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RATIO_BULK]      = { "weight_ratio_bulk",      BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_IAT_REALTIME]    = { "weight_iat_realtime",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_SCORE_THRESHOLD]        = { "score_threshold",        BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_REALTIME]          = { "prio_realtime",          BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_VIDEO]             = { "prio_video",             BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_NORMAL]            = { "prio_normal",            BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_BULK]              = { "prio_bulk",              BLOBMSG_TYPE_INT32 },
        // 新增 TCP 特征
        [CL_CONFIG_TCP_WINDOW_LOW] = { "tcp_window_low", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_WINDOW_HIGH] = { "tcp_window_high", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_MSS_LOW] = { "tcp_mss_low", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_MSS_HIGH] = { "tcp_mss_high", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_RTT_LOW_US] = { "tcp_rtt_low_us", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_TCP_RTT_HIGH_US] = { "tcp_rtt_high_us", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_WINDOW_REALTIME] = { "weight_window_realtime", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_WINDOW_VIDEO]    = { "weight_window_video",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_WINDOW_NORMAL]   = { "weight_window_normal",   BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_WINDOW_BULK]     = { "weight_window_bulk",     BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_MSS_REALTIME]    = { "weight_mss_realtime",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_MSS_VIDEO]       = { "weight_mss_video",       BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_MSS_NORMAL]      = { "weight_mss_normal",      BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_MSS_BULK]        = { "weight_mss_bulk",        BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RTT_REALTIME]    = { "weight_rtt_realtime",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RTT_VIDEO]       = { "weight_rtt_video",       BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RTT_NORMAL]      = { "weight_rtt_normal",      BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_WEIGHT_RTT_BULK]        = { "weight_rtt_bulk",        BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_ENABLE_TCP_WINDOW] = { "enable_tcp_window", BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_TCP_MSS]    = { "enable_tcp_mss",    BLOBMSG_TYPE_BOOL },
        [CL_CONFIG_ENABLE_TCP_RTT]    = { "enable_tcp_rtt",    BLOBMSG_TYPE_BOOL },
    };
    struct blob_attr *tb[__CL_CONFIG_MAX];
    struct blob_attr *cur;

    if (reset) {
        memset(cfg, 0, sizeof(*cfg));
        // 设置默认值（原有）
        cfg->bulk_trigger_pps = 500;
        cfg->prio_max_avg_pkt_len = 200;
        cfg->game_max_avg_pkt_len = 200;
        cfg->game_max_conn = 5;
        cfg->game_max_pps = 50;
        cfg->game_sample_packets = 10;
        cfg->video_min_avg_pkt_len = 1000;
        cfg->video_max_avg_pkt_len = 1400;
        cfg->video_max_conn = 20;
        cfg->video_min_pps = 100;
        cfg->video_max_pps = 500;
        cfg->bulk_min_avg_pkt_len = 1400;
        cfg->bulk_min_conn = 50;
        cfg->bulk_min_pps = 500;
        cfg->tcp_flags_syn_ack_ratio = 10;
        cfg->tcp_flags_window = 20;
        cfg->conn_duration_short = 10;
        cfg->conn_duration_long = 60;
        cfg->up_down_ratio_low = 10;
        cfg->up_down_ratio_high = 90;
        cfg->burst_window_ms = 100;
        cfg->burst_packets = 10;
        cfg->burst_bytes = 10000;
        cfg->iat_threshold_us = 10000;
        cfg->retrans_threshold = 5;
        // 权重默认值
        cfg->weight_pktlen_realtime = 3;
        cfg->weight_pktlen_video    = 3;
        cfg->weight_pktlen_normal   = 1;
        cfg->weight_pktlen_bulk     = 3;
        cfg->weight_conn_realtime   = 2;
        cfg->weight_conn_video      = 1;
        cfg->weight_conn_normal     = 1;
        cfg->weight_conn_bulk       = 2;
        cfg->weight_pps_realtime    = 2;
        cfg->weight_pps_video       = 2;
        cfg->weight_pps_normal      = 1;
        cfg->weight_pps_bulk        = 2;
        cfg->weight_burst_bulk      = 3;
        cfg->weight_tcpflags_bulk   = 2;
        cfg->weight_retrans_bulk    = 2;
        cfg->weight_duration_realtime = 1;
        cfg->weight_duration_video  = 1;
        cfg->weight_duration_bulk   = 2;
        cfg->weight_ratio_video     = 1;
        cfg->weight_ratio_realtime  = 1;
        cfg->weight_ratio_bulk      = 1;
        cfg->weight_iat_realtime    = 2;
        cfg->score_threshold        = 3;
        cfg->prio_realtime = 0;
        cfg->prio_video    = 1;
        cfg->prio_normal   = 2;
        cfg->prio_bulk     = 3;

        // 新增 TCP 特征默认值
        cfg->tcp_window_low = 1024;
        cfg->tcp_window_high = 32768;
        cfg->tcp_mss_low = 500;
        cfg->tcp_mss_high = 1400;
        cfg->tcp_rtt_low_us = 10000;   // 10ms
        cfg->tcp_rtt_high_us = 50000;  // 50ms

        cfg->weight_window_realtime = 2;
        cfg->weight_window_video    = 1;
        cfg->weight_window_normal   = 1;
        cfg->weight_window_bulk     = 2;

        cfg->weight_mss_realtime    = 2;
        cfg->weight_mss_video       = 1;
        cfg->weight_mss_normal      = 1;
        cfg->weight_mss_bulk        = 2;

        cfg->weight_rtt_realtime    = 3;
        cfg->weight_rtt_video       = 1;
        cfg->weight_rtt_normal      = 1;
        cfg->weight_rtt_bulk        = 2;
    }

    blobmsg_parse(policy, __CL_CONFIG_MAX, tb, blobmsg_data(attr), blobmsg_len(attr));

#define READ_U32(name, field) do { if ((cur = tb[name]) != NULL) cfg->field = blobmsg_get_u32(cur); } while (0)
    READ_U32(CL_CONFIG_BULK_TIMEOUT, bulk_trigger_timeout);
    READ_U32(CL_CONFIG_BULK_PPS, bulk_trigger_pps);
    READ_U32(CL_CONFIG_PRIO_PKT_LEN, prio_max_avg_pkt_len);
    READ_U32(CL_CONFIG_GAME_MAX_AVG_PKT_LEN, game_max_avg_pkt_len);
    READ_U32(CL_CONFIG_GAME_MIN_CONN, game_min_conn);
    READ_U32(CL_CONFIG_GAME_MAX_CONN, game_max_conn);
    READ_U32(CL_CONFIG_GAME_MAX_PPS, game_max_pps);
    READ_U32(CL_CONFIG_GAME_SAMPLE_PACKETS, game_sample_packets);
    READ_U32(CL_CONFIG_VIDEO_MIN_AVG_PKT_LEN, video_min_avg_pkt_len);
    READ_U32(CL_CONFIG_VIDEO_MAX_AVG_PKT_LEN, video_max_avg_pkt_len);
    READ_U32(CL_CONFIG_VIDEO_MIN_CONN, video_min_conn);
    READ_U32(CL_CONFIG_VIDEO_MAX_CONN, video_max_conn);
    READ_U32(CL_CONFIG_VIDEO_MIN_PPS, video_min_pps);
    READ_U32(CL_CONFIG_VIDEO_MAX_PPS, video_max_pps);
    READ_U32(CL_CONFIG_BULK_MIN_AVG_PKT_LEN, bulk_min_avg_pkt_len);
    READ_U32(CL_CONFIG_BULK_MIN_CONN, bulk_min_conn);
    READ_U32(CL_CONFIG_BULK_MIN_PPS, bulk_min_pps);
    READ_U32(CL_CONFIG_TCP_FLAGS_SYN_ACK_RATIO, tcp_flags_syn_ack_ratio);
    READ_U32(CL_CONFIG_TCP_FLAGS_WINDOW, tcp_flags_window);
    READ_U32(CL_CONFIG_CONN_DURATION_SHORT, conn_duration_short);
    READ_U32(CL_CONFIG_CONN_DURATION_LONG, conn_duration_long);
    READ_U32(CL_CONFIG_BURST_WINDOW_MS, burst_window_ms);
    READ_U32(CL_CONFIG_BURST_PACKETS, burst_packets);
    READ_U32(CL_CONFIG_BURST_BYTES, burst_bytes);
    READ_U32(CL_CONFIG_IAT_THRESHOLD_US, iat_threshold_us);
    READ_U32(CL_CONFIG_RETRANS_THRESHOLD, retrans_threshold);
    READ_U32(CL_CONFIG_WEIGHT_PKTLEN_REALTIME, weight_pktlen_realtime);
    READ_U32(CL_CONFIG_WEIGHT_PKTLEN_VIDEO,    weight_pktlen_video);
    READ_U32(CL_CONFIG_WEIGHT_PKTLEN_NORMAL,   weight_pktlen_normal);
    READ_U32(CL_CONFIG_WEIGHT_PKTLEN_BULK,     weight_pktlen_bulk);
    READ_U32(CL_CONFIG_WEIGHT_CONN_REALTIME,   weight_conn_realtime);
    READ_U32(CL_CONFIG_WEIGHT_CONN_VIDEO,      weight_conn_video);
    READ_U32(CL_CONFIG_WEIGHT_CONN_NORMAL,     weight_conn_normal);
    READ_U32(CL_CONFIG_WEIGHT_CONN_BULK,       weight_conn_bulk);
    READ_U32(CL_CONFIG_WEIGHT_PPS_REALTIME,    weight_pps_realtime);
    READ_U32(CL_CONFIG_WEIGHT_PPS_VIDEO,       weight_pps_video);
    READ_U32(CL_CONFIG_WEIGHT_PPS_NORMAL,      weight_pps_normal);
    READ_U32(CL_CONFIG_WEIGHT_PPS_BULK,        weight_pps_bulk);
    READ_U32(CL_CONFIG_WEIGHT_BURST_BULK,      weight_burst_bulk);
    READ_U32(CL_CONFIG_WEIGHT_TCPFLAGS_BULK,   weight_tcpflags_bulk);
    READ_U32(CL_CONFIG_WEIGHT_RETRANS_BULK,    weight_retrans_bulk);
    READ_U32(CL_CONFIG_WEIGHT_DURATION_REALTIME, weight_duration_realtime);
    READ_U32(CL_CONFIG_WEIGHT_DURATION_VIDEO,  weight_duration_video);
    READ_U32(CL_CONFIG_WEIGHT_DURATION_BULK,   weight_duration_bulk);
    READ_U32(CL_CONFIG_WEIGHT_RATIO_VIDEO,     weight_ratio_video);
    READ_U32(CL_CONFIG_WEIGHT_RATIO_REALTIME,  weight_ratio_realtime);
    READ_U32(CL_CONFIG_WEIGHT_RATIO_BULK,      weight_ratio_bulk);
    READ_U32(CL_CONFIG_WEIGHT_IAT_REALTIME,    weight_iat_realtime);
    READ_U32(CL_CONFIG_SCORE_THRESHOLD,        score_threshold);
    READ_U32(CL_CONFIG_PRIO_REALTIME, prio_realtime);
    READ_U32(CL_CONFIG_PRIO_VIDEO,    prio_video);
    READ_U32(CL_CONFIG_PRIO_NORMAL,   prio_normal);
    READ_U32(CL_CONFIG_PRIO_BULK,     prio_bulk);
    // 新增 TCP 特征读取
    READ_U32(CL_CONFIG_TCP_WINDOW_LOW, tcp_window_low);
    READ_U32(CL_CONFIG_TCP_WINDOW_HIGH, tcp_window_high);
    READ_U32(CL_CONFIG_TCP_MSS_LOW, tcp_mss_low);
    READ_U32(CL_CONFIG_TCP_MSS_HIGH, tcp_mss_high);
    READ_U32(CL_CONFIG_TCP_RTT_LOW_US, tcp_rtt_low_us);
    READ_U32(CL_CONFIG_TCP_RTT_HIGH_US, tcp_rtt_high_us);
    READ_U32(CL_CONFIG_WEIGHT_WINDOW_REALTIME, weight_window_realtime);
    READ_U32(CL_CONFIG_WEIGHT_WINDOW_VIDEO,    weight_window_video);
    READ_U32(CL_CONFIG_WEIGHT_WINDOW_NORMAL,   weight_window_normal);
    READ_U32(CL_CONFIG_WEIGHT_WINDOW_BULK,     weight_window_bulk);
    READ_U32(CL_CONFIG_WEIGHT_MSS_REALTIME,    weight_mss_realtime);
    READ_U32(CL_CONFIG_WEIGHT_MSS_VIDEO,       weight_mss_video);
    READ_U32(CL_CONFIG_WEIGHT_MSS_NORMAL,      weight_mss_normal);
    READ_U32(CL_CONFIG_WEIGHT_MSS_BULK,        weight_mss_bulk);
    READ_U32(CL_CONFIG_WEIGHT_RTT_REALTIME,    weight_rtt_realtime);
    READ_U32(CL_CONFIG_WEIGHT_RTT_VIDEO,       weight_rtt_video);
    READ_U32(CL_CONFIG_WEIGHT_RTT_NORMAL,      weight_rtt_normal);
    READ_U32(CL_CONFIG_WEIGHT_RTT_BULK,        weight_rtt_bulk);
#undef READ_U32

    if ((cur = tb[CL_CONFIG_UP_DOWN_RATIO_LOW]) != NULL)
        cfg->up_down_ratio_low = read_float_mult100(blobmsg_get_string(cur));
    if ((cur = tb[CL_CONFIG_UP_DOWN_RATIO_HIGH]) != NULL)
        cfg->up_down_ratio_high = read_float_mult100(blobmsg_get_string(cur));

    cfg->feature_mask = 0;
    if ((cur = tb[CL_CONFIG_ENABLE_PKTLEN]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_PKTLEN;
    if ((cur = tb[CL_CONFIG_ENABLE_CONN_COUNT]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_CONN;
    if ((cur = tb[CL_CONFIG_ENABLE_PPS]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_PPS;
    if ((cur = tb[CL_CONFIG_ENABLE_IAT]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_IAT;
    if ((cur = tb[CL_CONFIG_ENABLE_RETRANS]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_RETRANS;
    if ((cur = tb[CL_CONFIG_ENABLE_TCP_FLAGS]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_TCPFLAGS;
    if ((cur = tb[CL_CONFIG_ENABLE_CONN_DURATION]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_DURATION;
    if ((cur = tb[CL_CONFIG_ENABLE_UP_DOWN_RATIO]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_RATIO;
    if ((cur = tb[CL_CONFIG_ENABLE_BURST]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_BURST;
    // 新增 TCP 特征启用
    if ((cur = tb[CL_CONFIG_ENABLE_TCP_WINDOW]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_TCP_WINDOW;
    if ((cur = tb[CL_CONFIG_ENABLE_TCP_MSS]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_TCP_MSS;
    if ((cur = tb[CL_CONFIG_ENABLE_TCP_RTT]) && blobmsg_get_bool(cur)) cfg->feature_mask |= FEATURE_TCP_RTT;

    return 0;
}

/* 外部接口：设置类配置（由 ubus 调用，或热重载时调用） */
void config_set_classes(struct blob_attr *val) {
    map_manager_set_classes(val);
}

/* 外部接口：获取类 ID（简化实现，实际需维护 map_class 表） */
int config_get_class_id(const char *name) {
    // 原 map_manager 中有 map_class 数组，但为保持模块独立，此处应调用 map_manager 接口
    // 由于 map_manager 未提供此接口，暂时返回 -1，待后续扩展
    return -1;
}

/* 外部接口：将类名转换为 DSCP 值 */
int config_name_to_dscp(const char *name, uint8_t *dscp) {
    return -1;
}

/* 外部接口：将全局配置同步到 BPF map */
void config_sync_to_bpf(void) {
    map_manager_update_config();
    map_manager_sync_class_config();
}

/* 外部接口：获取全局配置指针 */
struct global_config *config_get_global(void) {
    return &global_config;
}

/* 外部接口：获取流特征配置指针 */
struct idclass_flow_config *config_get_flow(void) {
    return &global_flow_config;
}

/* 外部接口：重新加载配置（用于 ubus reload 命令） */
int config_reload(void) {
    if (load_idclass_config() != 0) return -1;
    if (load_class_config() != 0) return -1;
    config_sync_to_bpf();
    ULOG_INFO("Configuration reloaded via ubus\n");
    return 0;
}

/* 外部接口：初始化配置模块 */
int config_init(void) {
    if (load_idclass_config() != 0) {
        ULOG_ERR("Failed to load initial UCI config\n");
        return -1;
    }
    if (load_class_config() != 0) {
        ULOG_WARN("Failed to load class config, continuing\n");
    }
    last_uci_mtime = 0;
    uci_reload_timer.cb = config_check_uci_reload;
    uloop_timeout_set(&uci_reload_timer, 1000);
    return 0;
}