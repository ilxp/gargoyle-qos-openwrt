// SPDX-License-Identifier: GPL-2.0+
/*
 * ubus_server.c - ubus server module
 *
 * Provides ubus methods for configuration, status, statistics, and DNS host
 * management. Integrates with other modules (config, map_manager, interface,
 * dns_parser) to expose runtime control and monitoring.
 */
#include "common.h"
#include <libubus.h>

static struct blob_buf b;
static struct ubus_auto_conn conn;
static struct ubus_object idclass_object;

/* 外部函数声明（来自 main.c） */
extern int idclass_run_cmd(char *cmd, bool ignore_error);

/* 内部辅助函数：解析数组并添加到 map */
static int ubus_add_array(struct blob_attr *attr, uint8_t val, enum idclass_map_id id) {
    struct blob_attr *cur;
    int rem;

    if (blobmsg_check_array(attr, BLOBMSG_TYPE_STRING) < 0)
        return UBUS_STATUS_INVALID_ARGUMENT;

    blobmsg_for_each_attr(cur, attr, rem)
        map_manager_set_entry(id, false, blobmsg_get_string(cur), val);

    return 0;
}

/* 内部辅助函数：设置文件列表 */
static int ubus_set_files(struct blob_attr *attr) {
    struct blob_attr *cur;
    int rem;

    if (blobmsg_check_array(attr, BLOBMSG_TYPE_STRING) < 0)
        return UBUS_STATUS_INVALID_ARGUMENT;

    map_manager_clear_files();

    blobmsg_for_each_attr(cur, attr, rem)
        map_manager_load_file(blobmsg_get_string(cur));

    map_manager_gc();
    return 0;
}

/* ubus 方法: reload */
static int ubus_reload(struct ubus_context *ctx, struct ubus_object *obj,
                       struct ubus_request_data *req, const char *method,
                       struct blob_attr *msg) {
    config_reload();
    return 0;
}

/* ubus 方法: add / remove */
enum {
    ADD_DSCP,
    ADD_TIMEOUT,
    ADD_IPV4,
    ADD_IPV6,
    ADD_TCP_PORT,
    ADD_UDP_PORT,
    ADD_DNS,
    __ADD_MAX
};

static const struct blobmsg_policy add_policy[__ADD_MAX] = {
    [ADD_DSCP] = { "dscp", BLOBMSG_TYPE_STRING },
    [ADD_TIMEOUT] = { "timeout", BLOBMSG_TYPE_INT32 },
    [ADD_IPV4] = { "ipv4", BLOBMSG_TYPE_ARRAY },
    [ADD_IPV6] = { "ipv6", BLOBMSG_TYPE_ARRAY },
    [ADD_TCP_PORT] = { "tcp_port", BLOBMSG_TYPE_ARRAY },
    [ADD_UDP_PORT] = { "udp_port", BLOBMSG_TYPE_ARRAY },
    [ADD_DNS] = { "dns", BLOBMSG_TYPE_ARRAY },
};

static int ubus_add(struct ubus_context *ctx, struct ubus_object *obj,
                    struct ubus_request_data *req, const char *method,
                    struct blob_attr *msg) {
    int prev_timeout = idclass_map_timeout;
    struct blob_attr *tb[__ADD_MAX];
    struct blob_attr *cur;
    uint8_t dscp = 0xff;
    int ret;

    blobmsg_parse(add_policy, __ADD_MAX, tb,
                  blobmsg_data(msg), blobmsg_len(msg));

    if (!strcmp(method, "add")) {
        if ((cur = tb[ADD_DSCP]) == NULL ||
            idclass_map_dscp_value(blobmsg_get_string(cur), &dscp))
            return UBUS_STATUS_INVALID_ARGUMENT;

        if ((cur = tb[ADD_TIMEOUT]) != NULL)
            idclass_map_timeout = blobmsg_get_u32(cur);
    }

    if ((cur = tb[ADD_IPV4]) != NULL &&
        (ret = ubus_add_array(cur, dscp, CL_MAP_IPV4_ADDR) != 0))
        return ret;

    if ((cur = tb[ADD_IPV6]) != NULL &&
        (ret = ubus_add_array(cur, dscp, CL_MAP_IPV6_ADDR) != 0))
        return ret;

    if ((cur = tb[ADD_TCP_PORT]) != NULL &&
        (ret = ubus_add_array(cur, dscp, CL_MAP_TCP_PORTS) != 0))
        return ret;

    if ((cur = tb[ADD_UDP_PORT]) != NULL &&
        (ret = ubus_add_array(cur, dscp, CL_MAP_UDP_PORTS) != 0))
        return ret;

    if ((cur = tb[ADD_DNS]) != NULL &&
        (ret = ubus_add_array(cur, dscp, CL_MAP_DNS) != 0))
        return ret;

    idclass_map_timeout = prev_timeout;
    return 0;
}

/* ubus 方法: config */
enum {
    CL_CONFIG_RESET,
    CL_CONFIG_FILES,
    CL_CONFIG_TIMEOUT,
    CL_CONFIG_DSCP_UDP,
    CL_CONFIG_DSCP_TCP,
    CL_CONFIG_DSCP_ICMP,
    CL_CONFIG_INTERFACES,
    CL_CONFIG_DEVICES,
    CL_CONFIG_CLASSES,
    CL_CONFIG_GAME_MAX_AVG_PKT_LEN,
    CL_CONFIG_GAME_MIN_CONN,
    CL_CONFIG_GAME_MAX_CONN,
    CL_CONFIG_GAME_MAX_PPS,
    CL_CONFIG_GAME_SAMPLE_PACKETS,
    CL_CONFIG_VIDEO_MIN_AVG_PKT_LEN,
    CL_CONFIG_VIDEO_MAX_AVG_PKT_LEN,
    CL_CONFIG_VIDEO_MIN_CONN,
    CL_CONFIG_VIDEO_MAX_CONN,
    CL_CONFIG_VIDEO_MIN_PPS,
    CL_CONFIG_VIDEO_MAX_PPS,
    CL_CONFIG_BULK_MIN_AVG_PKT_LEN,
    CL_CONFIG_BULK_MIN_CONN,
    CL_CONFIG_BULK_MIN_PPS,
    CL_CONFIG_TCP_FLAGS_SYN_ACK_RATIO,
    CL_CONFIG_TCP_FLAGS_WINDOW,
    CL_CONFIG_CONN_DURATION_SHORT,
    CL_CONFIG_CONN_DURATION_LONG,
    CL_CONFIG_UP_DOWN_RATIO_LOW,
    CL_CONFIG_UP_DOWN_RATIO_HIGH,
    CL_CONFIG_BURST_WINDOW_MS,
    CL_CONFIG_BURST_PACKETS,
    CL_CONFIG_BURST_BYTES,
    CL_CONFIG_IAT_THRESHOLD_US,
    CL_CONFIG_RETRANS_THRESHOLD,
    CL_CONFIG_ENABLE_PKTLEN,
    CL_CONFIG_ENABLE_CONN_COUNT,
    CL_CONFIG_ENABLE_PPS,
    CL_CONFIG_ENABLE_IAT,
    CL_CONFIG_ENABLE_RETRANS,
    CL_CONFIG_ENABLE_TCP_FLAGS,
    CL_CONFIG_ENABLE_CONN_DURATION,
    CL_CONFIG_ENABLE_UP_DOWN_RATIO,
    CL_CONFIG_ENABLE_BURST,
    CL_CONFIG_WEIGHT_PKTLEN_REALTIME,
    CL_CONFIG_WEIGHT_PKTLEN_VIDEO,
    CL_CONFIG_WEIGHT_PKTLEN_NORMAL,
    CL_CONFIG_WEIGHT_PKTLEN_BULK,
    CL_CONFIG_WEIGHT_CONN_REALTIME,
    CL_CONFIG_WEIGHT_CONN_VIDEO,
    CL_CONFIG_WEIGHT_CONN_NORMAL,
    CL_CONFIG_WEIGHT_CONN_BULK,
    CL_CONFIG_WEIGHT_PPS_REALTIME,
    CL_CONFIG_WEIGHT_PPS_VIDEO,
    CL_CONFIG_WEIGHT_PPS_NORMAL,
    CL_CONFIG_WEIGHT_PPS_BULK,
    CL_CONFIG_WEIGHT_BURST_BULK,
    CL_CONFIG_WEIGHT_TCPFLAGS_BULK,
    CL_CONFIG_WEIGHT_RETRANS_BULK,
    CL_CONFIG_WEIGHT_DURATION_REALTIME,
    CL_CONFIG_WEIGHT_DURATION_VIDEO,
    CL_CONFIG_WEIGHT_DURATION_BULK,
    CL_CONFIG_WEIGHT_RATIO_VIDEO,
    CL_CONFIG_WEIGHT_RATIO_REALTIME,
    CL_CONFIG_WEIGHT_RATIO_BULK,
    CL_CONFIG_WEIGHT_IAT_REALTIME,
    CL_CONFIG_SCORE_THRESHOLD,
    CL_CONFIG_PRIO_REALTIME,
    CL_CONFIG_PRIO_VIDEO,
    CL_CONFIG_PRIO_NORMAL,
    CL_CONFIG_PRIO_BULK,
    // 新增 TCP 特征相关选项
    CL_CONFIG_TCP_WINDOW_LOW,
    CL_CONFIG_TCP_WINDOW_HIGH,
    CL_CONFIG_TCP_MSS_LOW,
    CL_CONFIG_TCP_MSS_HIGH,
    CL_CONFIG_TCP_RTT_LOW_US,
    CL_CONFIG_TCP_RTT_HIGH_US,
    CL_CONFIG_WEIGHT_WINDOW_REALTIME,
    CL_CONFIG_WEIGHT_WINDOW_VIDEO,
    CL_CONFIG_WEIGHT_WINDOW_NORMAL,
    CL_CONFIG_WEIGHT_WINDOW_BULK,
    CL_CONFIG_WEIGHT_MSS_REALTIME,
    CL_CONFIG_WEIGHT_MSS_VIDEO,
    CL_CONFIG_WEIGHT_MSS_NORMAL,
    CL_CONFIG_WEIGHT_MSS_BULK,
    CL_CONFIG_WEIGHT_RTT_REALTIME,
    CL_CONFIG_WEIGHT_RTT_VIDEO,
    CL_CONFIG_WEIGHT_RTT_NORMAL,
    CL_CONFIG_WEIGHT_RTT_BULK,
    CL_CONFIG_ENABLE_TCP_WINDOW,
    CL_CONFIG_ENABLE_TCP_MSS,
    CL_CONFIG_ENABLE_TCP_RTT,
    __CL_CONFIG_MAX
};

static const struct blobmsg_policy config_policy[__CL_CONFIG_MAX] = {
    [CL_CONFIG_RESET] = { "reset", BLOBMSG_TYPE_BOOL },
    [CL_CONFIG_FILES] = { "files", BLOBMSG_TYPE_ARRAY },
    [CL_CONFIG_TIMEOUT] = { "timeout", BLOBMSG_TYPE_INT32 },
    [CL_CONFIG_DSCP_UDP] = { "dscp_default_udp", BLOBMSG_TYPE_STRING },
    [CL_CONFIG_DSCP_TCP] = { "dscp_default_tcp", BLOBMSG_TYPE_STRING },
    [CL_CONFIG_DSCP_ICMP] = { "dscp_icmp", BLOBMSG_TYPE_STRING },
    [CL_CONFIG_INTERFACES] = { "interfaces", BLOBMSG_TYPE_TABLE },
    [CL_CONFIG_DEVICES] = { "devices", BLOBMSG_TYPE_TABLE },
    [CL_CONFIG_CLASSES] = { "classes", BLOBMSG_TYPE_TABLE },
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

static int ubus_config(struct ubus_context *ctx, struct ubus_object *obj,
                       struct ubus_request_data *req, const char *method,
                       struct blob_attr *msg) {
    struct blob_attr *tb[__CL_CONFIG_MAX];
    struct blob_attr *cur;
    uint8_t dscp;
    bool reset = false;
    int ret;

    blobmsg_parse(config_policy, __CL_CONFIG_MAX, tb,
                  blobmsg_data(msg), blobmsg_len(msg));

    if ((cur = tb[CL_CONFIG_RESET]) != NULL)
        reset = blobmsg_get_bool(cur);

    if (reset)
        map_manager_reset_config();

    if ((cur = tb[CL_CONFIG_CLASSES]) != NULL || reset)
        config_set_classes(cur);

    if ((cur = tb[CL_CONFIG_TIMEOUT]) != NULL)
        idclass_map_timeout = blobmsg_get_u32(cur);

    if ((cur = tb[CL_CONFIG_FILES]) != NULL &&
        (ret = ubus_set_files(cur) != 0))
        return ret;

    if (config_parse_dscp_value(&global_config.dscp_icmp, tb[CL_CONFIG_DSCP_ICMP], reset))
        return UBUS_STATUS_INVALID_ARGUMENT;

    config_parse_dscp_value(&dscp, tb[CL_CONFIG_DSCP_UDP], true);
    if (dscp != 0xff)
        map_manager_set_dscp_default(CL_MAP_UDP_PORTS, dscp);

    config_parse_dscp_value(&dscp, tb[CL_CONFIG_DSCP_TCP], true);
    if (dscp != 0xff)
        map_manager_set_dscp_default(CL_MAP_TCP_PORTS, dscp);

    map_manager_update_config();

    interface_config_update(tb[CL_CONFIG_INTERFACES], tb[CL_CONFIG_DEVICES]);
    interface_check();

    map_manager_sync_class_config();

    return 0;
}

/* ubus 方法: dump */
static int ubus_dump(struct ubus_context *ctx, struct ubus_object *obj,
                     struct ubus_request_data *req, const char *method,
                     struct blob_attr *msg) {
    blob_buf_init(&b, 0);
    map_manager_dump(&b);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return 0;
}

/* ubus 方法: status */
static int ubus_status(struct ubus_context *ctx, struct ubus_object *obj,
                       struct ubus_request_data *req, const char *method,
                       struct blob_attr *msg) {
    blob_buf_init(&b, 0);
    interface_status(&b);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return 0;
}

/* ubus 方法: get_stats */
static int ubus_get_stats(struct ubus_context *ctx, struct ubus_object *obj,
                          struct ubus_request_data *req, const char *method,
                          struct blob_attr *msg) {
    static const struct blobmsg_policy policy = { "reset", BLOBMSG_TYPE_BOOL };
    struct blob_attr *tb;
    bool reset = false;

    blobmsg_parse(&policy, 1, &tb, blobmsg_data(msg), blobmsg_len(msg));
    reset = tb && blobmsg_get_u8(tb);

    blob_buf_init(&b, 0);
    map_manager_stats(&b, reset);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return 0;
}

/* ubus 方法: check_devices */
static int ubus_check_devices(struct ubus_context *ctx, struct ubus_object *obj,
                              struct ubus_request_data *req, const char *method,
                              struct blob_attr *msg) {
    interface_check();
    return 0;
}

/* ubus 方法: add_dns_host */
enum {
    DNS_HOST_NAME,
    DNS_HOST_TYPE,
    DNS_HOST_ADDR,
    DNS_HOST_TTL,
    __DNS_HOST_MAX
};

static const struct blobmsg_policy dns_policy[__DNS_HOST_MAX] = {
    [DNS_HOST_NAME] = { "name", BLOBMSG_TYPE_STRING },
    [DNS_HOST_TYPE] = { "type", BLOBMSG_TYPE_STRING },
    [DNS_HOST_ADDR] = { "address", BLOBMSG_TYPE_STRING },
    [DNS_HOST_TTL] = { "ttl", BLOBMSG_TYPE_INT32 },
};

static int ubus_add_dns_host(struct ubus_context *ctx, struct ubus_object *obj,
                             struct ubus_request_data *req, const char *method,
                             struct blob_attr *msg) {
    struct blob_attr *tb[__DNS_HOST_MAX];
    struct blob_attr *cur;
    uint32_t ttl = 0;

    blobmsg_parse(dns_policy, __DNS_HOST_MAX, tb,
                  blobmsg_data(msg), blobmsg_len(msg));

    if (!tb[DNS_HOST_NAME] || !tb[DNS_HOST_TYPE] || !tb[DNS_HOST_ADDR])
        return UBUS_STATUS_INVALID_ARGUMENT;

    if ((cur = tb[DNS_HOST_TTL]) != NULL)
        ttl = blobmsg_get_u32(cur);

    if (map_manager_add_dns_host(blobmsg_get_string(tb[DNS_HOST_NAME]),
                                 blobmsg_get_string(tb[DNS_HOST_ADDR]),
                                 blobmsg_get_string(tb[DNS_HOST_TYPE]),
                                 ttl))
        return UBUS_STATUS_INVALID_ARGUMENT;

    return 0;
}

/* ubus 对象方法列表 */
static const struct ubus_method idclass_methods[] = {
    UBUS_METHOD_NOARG("reload", ubus_reload),
    UBUS_METHOD("add", ubus_add, add_policy),
    UBUS_METHOD_MASK("remove", ubus_add, add_policy,
                     ((1 << __ADD_MAX) - 1) & ~(1 << ADD_DSCP)),
    UBUS_METHOD("config", ubus_config, config_policy),
    UBUS_METHOD_NOARG("dump", ubus_dump),
    UBUS_METHOD_NOARG("status", ubus_status),
    UBUS_METHOD_NOARG("get_stats", ubus_get_stats),
    UBUS_METHOD("add_dns_host", ubus_add_dns_host, dns_policy),
    UBUS_METHOD_NOARG("check_devices", ubus_check_devices),
};

static struct ubus_object_type idclass_object_type =
    UBUS_OBJECT_TYPE("idclass", idclass_methods);

static struct ubus_object idclass_object = {
    .name = "idclass",
    .type = &idclass_object_type,
    .methods = idclass_methods,
    .n_methods = ARRAY_SIZE(idclass_methods),
};

/* 订阅 dnsmasq 事件 */
static void ubus_subscribe_dnsmasq(struct ubus_context *ctx) {
    static struct ubus_subscriber sub = {
        .cb = ubus_add_dns_host,
    };
    uint32_t id;

    if (!sub.obj.id && ubus_register_subscriber(ctx, &sub))
        return;

    if (ubus_lookup_id(ctx, "dnsmasq.dns", &id))
        return;

    ubus_subscribe(ctx, &sub, id);
}

/* ubus 事件处理 */
static void ubus_event_cb(struct ubus_context *ctx, struct ubus_event_handler *ev,
                          const char *type, struct blob_attr *msg) {
    static const struct blobmsg_policy policy = { "path", BLOBMSG_TYPE_STRING };
    struct blob_attr *attr;
    const char *path;

    blobmsg_parse(&policy, 1, &attr, blobmsg_data(msg), blobmsg_len(msg));
    if (!attr)
        return;

    path = blobmsg_get_string(attr);
    if (!strcmp(path, "dnsmasq.dns"))
        ubus_subscribe_dnsmasq(ctx);
    else if (!strcmp(path, "bridger"))
        ubus_server_update_bridger(false);
}

/* ubus 连接回调 */
static void ubus_connect_handler(struct ubus_context *ctx) {
    static struct ubus_event_handler ev = { .cb = ubus_event_cb };

    ubus_add_object(ctx, &idclass_object);
    ubus_register_event_handler(ctx, &ev, "ubus.object.add");
    ubus_subscribe_dnsmasq(ctx);
}

/* 外部接口：更新 bridger 黑名单 */
void ubus_server_update_bridger(bool shutdown) {
    struct ubus_request req;
    uint32_t id;
    void *c;

    if (ubus_lookup_id(&conn.ctx, "bridger", &id))
        return;

    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "name", "idclass");
    c = blobmsg_open_array(&b, "devices");
    if (!shutdown)
        interface_get_devices(&b);
    blobmsg_close_array(&b, c);

    ubus_invoke_async(&conn.ctx, id, "set_blacklist", b.head, &req);
}

/* 外部接口：检查逻辑接口对应的物理设备 */
struct iface_req {
    char *name;
    int len;
};

static void netifd_if_cb(struct ubus_request *req, int type, struct blob_attr *msg) {
    struct iface_req *ifr = req->priv;
    enum {
        IFS_ATTR_UP,
        IFS_ATTR_DEV,
        __IFS_ATTR_MAX
    };
    static const struct blobmsg_policy policy[__IFS_ATTR_MAX] = {
        [IFS_ATTR_UP] = { "up", BLOBMSG_TYPE_BOOL },
        [IFS_ATTR_DEV] = { "l3_device", BLOBMSG_TYPE_STRING },
    };
    struct blob_attr *tb[__IFS_ATTR_MAX];

    blobmsg_parse(policy, __IFS_ATTR_MAX, tb, blobmsg_data(msg), blobmsg_len(msg));

    if (!tb[IFS_ATTR_UP] || !tb[IFS_ATTR_DEV])
        return;

    if (!blobmsg_get_bool(tb[IFS_ATTR_UP]))
        return;

    snprintf(ifr->name, ifr->len, "%s", blobmsg_get_string(tb[IFS_ATTR_DEV]));
}

int ubus_server_check_interface(const char *name, char *ifname, int ifname_len) {
    struct iface_req req = { ifname, ifname_len };
    char *obj_name = alloca(sizeof("network.interface.") + strlen(name) + 1);
    uint32_t id;

    sprintf(obj_name, "network.interface.%s", name);
    ifname[0] = 0;

    if (ubus_lookup_id(&conn.ctx, obj_name, &id))
        return -1;

    blob_buf_init(&b, 0);
    ubus_invoke(&conn.ctx, id, "status", b.head, netifd_if_cb, &req, 1000);
    blob_buf_free(&b);  // 释放临时缓冲区
    return ifname[0] ? 0 : -1;
}

/* 外部接口：初始化 ubus 服务器 */
int ubus_server_init(void) {
    conn.cb = ubus_connect_handler;
    ubus_auto_connect(&conn);
    return 0;
}

/* 外部接口：停止 ubus 服务器 */
void ubus_server_stop(void) {
    ubus_server_update_bridger(true);
    ubus_auto_shutdown(&conn);
}