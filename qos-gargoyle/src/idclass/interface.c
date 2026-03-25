// SPDX-License-Identifier: GPL-2.0+
/*
 * interface.c - Network interface TC qdisc/filter management module
 *
 * Attaches eBPF classifiers to network interfaces using tc, and manages
 * IFB devices for ingress redirection. Supports both devices (like eth0)
 * and logical interfaces (like lan) that may be bridged.
 */
#include "common.h"
#include "ebpf_loader.h"
#include "ubus_server.h"

#include <sys/ioctl.h>
#include <net/if_arp.h>
#include <linux/rtnetlink.h>
#include <linux/pkt_cls.h>
#include <netlink/msg.h>
#include <netlink/attr.h>
#include <netlink/socket.h>
#include <libubox/vlist.h>

#define APPEND(_buf, _ofs, _format, ...) \
    _ofs += snprintf(_buf + _ofs, sizeof(_buf) - _ofs, _format, ##__VA_ARGS__)

struct idclass_iface_config {
    struct blob_attr *data;

    bool ingress;
    bool egress;
    bool nat;
    bool host_isolate;
    bool autorate_ingress;

    const char *bandwidth_up;
    const char *bandwidth_down;
    const char *mode;
    const char *common_opts;
    const char *ingress_opts;
    const char *egress_opts;
};

struct idclass_iface {
    struct vlist_node node;

    char ifname[IFNAMSIZ];
    bool active;

    bool device;
    struct blob_attr *config_data;
    struct idclass_iface_config config;
};

enum {
    IFACE_ATTR_BW_UP,
    IFACE_ATTR_BW_DOWN,
    IFACE_ATTR_INGRESS,
    IFACE_ATTR_EGRESS,
    IFACE_ATTR_MODE,
    IFACE_ATTR_NAT,
    IFACE_ATTR_HOST_ISOLATE,
    IFACE_ATTR_AUTORATE_IN,
    IFACE_ATTR_INGRESS_OPTS,
    IFACE_ATTR_EGRESS_OPTS,
    IFACE_ATTR_OPTS,
    __IFACE_ATTR_MAX
};

static VLIST_TREE(devices, avl_strcmp, interface_update_cb, true, false);
static VLIST_TREE(interfaces, avl_strcmp, interface_update_cb, true, false);
static int socket_fd;
static struct nl_sock *rtnl_sock;

/* 外部函数声明（来自 main.c 或 util.c） */
extern int idclass_run_cmd(char *cmd, bool ignore_error);

/* 前向声明 */
static void interface_update_cb(struct vlist_tree *tree,
                                struct vlist_node *node_new,
                                struct vlist_node *node_old);

/* 获取 IFB 设备名（用于 ingress 重定向） */
static const char *interface_ifb_name(struct idclass_iface *iface) {
    static char ifname[IFNAMSIZ + 1] = "ifb-";
    int len = strlen(iface->ifname);

    if (len + 4 < IFNAMSIZ) {
        snprintf(ifname + 4, IFNAMSIZ - 4, "%s", iface->ifname);
        return ifname;
    }

    ifname[4] = iface->ifname[0];
    ifname[5] = iface->ifname[1];
    snprintf(ifname + 6, IFNAMSIZ - 6, "%s",
             iface->ifname + len - (IFNAMSIZ + 6) - 1);
    return ifname;
}

/* 生成 qdisc 命令 */
static int prepare_qdisc_cmd(char *buf, int len, const char *dev,
                             bool add, const char *type) {
    return snprintf(buf, len, "tc qdisc %s dev '%s' %s",
                    add ? "add" : "del", dev, type);
}

/* 生成 filter 命令 */
static int prepare_filter_cmd(char *buf, int len, const char *dev, int prio,
                              bool add, bool egress) {
    return snprintf(buf, len, "tc filter %s dev '%s' %sgress prio %d",
                    add ? "add" : "del", dev, egress ? "e" : "in", prio);
}

/* 添加 BPF 过滤器（使用 netlink） */
static int cmd_add_bpf_filter(const char *ifname, int prio, bool egress, bool eth) {
    struct tcmsg tcmsg = {
        .tcm_family = AF_UNSPEC,
        .tcm_ifindex = if_nametoindex(ifname),
    };
    struct nl_msg *msg;
    struct nlattr *opts;
    int prog_fd = -1;
    const char *suffix;
    char name[32];

    uint32_t flags = 0;
    if (!egress) flags |= IDCLASS_INGRESS;
    if (!eth) flags |= IDCLASS_IP_ONLY;
    suffix = ebpf_loader_get_program(flags, &prog_fd);
    if (!suffix || prog_fd < 0) {
        ULOG_ERR("Failed to get eBPF program for iface %s (flags=0x%x), fd=%d\n",
                 ifname, flags, prog_fd);
        return -1;
    }
    snprintf(name, sizeof(name), "idclass_%s", suffix);

    if (egress)
        tcmsg.tcm_parent = TC_H_MAKE(TC_H_CLSACT, TC_H_MIN_EGRESS);
    else
        tcmsg.tcm_parent = TC_H_MAKE(TC_H_CLSACT, TC_H_MIN_INGRESS);
    tcmsg.tcm_info = TC_H_MAKE(prio << 16, htons(ETH_P_ALL));

    msg = nlmsg_alloc_simple(RTM_NEWTFILTER, NLM_F_REQUEST | NLM_F_CREATE | NLM_F_EXCL);
    if (!msg) {
        ULOG_ERR("Failed to allocate netlink message\n");
        return -1;
    }
    nlmsg_append(msg, &tcmsg, sizeof(tcmsg), NLMSG_ALIGNTO);
    nla_put_string(msg, TCA_KIND, "bpf");

    opts = nla_nest_start(msg, TCA_OPTIONS);
    nla_put_u32(msg, TCA_BPF_FD, prog_fd);
    nla_put_string(msg, TCA_BPF_NAME, name);
    nla_put_u32(msg, TCA_BPF_FLAGS, TCA_BPF_FLAG_ACT_DIRECT);
    nla_put_u32(msg, TCA_BPF_FLAGS_GEN, TCA_CLS_FLAGS_SKIP_HW);
    nla_nest_end(msg, opts);

    nl_send_auto_complete(rtnl_sock, msg);
    nlmsg_free(msg);

    return nl_wait_for_ack(rtnl_sock);
}

/* 添加 qdisc 和 cake 整形器 */
static int cmd_add_qdisc(struct idclass_iface *iface, const char *ifname,
                         bool egress, bool eth) {
    struct idclass_iface_config *cfg = &iface->config;
    const char *bw = egress ? cfg->bandwidth_up : cfg->bandwidth_down;
    const char *dir_opts = egress ? cfg->egress_opts : cfg->ingress_opts;
    char buf[512];
    int ofs;

    /* 先添加 clsact qdisc（用于 ingress 和 egress 钩子） */
    ofs = prepare_qdisc_cmd(buf, sizeof(buf), ifname, true, "clsact");
    idclass_run_cmd(buf, true);

    /* 添加 root cake qdisc */
    ofs = prepare_qdisc_cmd(buf, sizeof(buf), ifname, true, "root cake");
    if (bw)
        APPEND(buf, ofs, " bandwidth %s", bw);
    APPEND(buf, ofs, " %s %sgress", cfg->mode, egress ? "e" : "in");
    if (!egress && cfg->autorate_ingress)
        APPEND(buf, ofs, " autorate-ingress");
    if (cfg->host_isolate)
        APPEND(buf, ofs, " %snat dual-%shost",
               cfg->nat ? "" : "no", egress ? "src" : "dst");
    else
        APPEND(buf, ofs, " flows");
    APPEND(buf, ofs, " %s %s", cfg->common_opts ?: "", dir_opts ?: "");

    return idclass_run_cmd(buf, false);
}

/* 添加 ingress 方向的所有配置（包括 IFB 重定向） */
static int cmd_add_ingress(struct idclass_iface *iface, bool eth) {
    const char *ifbdev = interface_ifb_name(iface);
    char buf[256];
    int prio = IDCLASS_PRIO_BASE;
    int ofs;

    /* 添加主 BPF 过滤器（ingress） */
    if (cmd_add_bpf_filter(iface->ifname, prio++, false, eth) != 0) {
        ULOG_ERR("Failed to add ingress BPF filter on %s\n", iface->ifname);
        return -1;
    }

    /* DNS 重定向到 ifb-dns（用于 DNS 解析模块） */
    ofs = prepare_filter_cmd(buf, sizeof(buf), iface->ifname, prio++, true, false);
    APPEND(buf, ofs, " protocol ip u32 match ip sport 53 0xffff "
                     "flowid 1:1 action mirred egress redirect dev "
                     IDCLASS_DNS_IFNAME);
    idclass_run_cmd(buf, false);

    ofs = prepare_filter_cmd(buf, sizeof(buf), iface->ifname, prio++, true, false);
    APPEND(buf, ofs, " protocol 802.1Q u32 offset plus 4 match ip sport 53 0xffff "
                     "flowid 1:1 action mirred egress redirect dev "
                     IDCLASS_DNS_IFNAME);
    idclass_run_cmd(buf, false);

    ofs = prepare_filter_cmd(buf, sizeof(buf), iface->ifname, prio++, true, false);
    APPEND(buf, ofs, " protocol ipv6 u32 match ip6 sport 53 0xffff "
                     "flowid 1:1 action mirred egress redirect dev "
                     IDCLASS_DNS_IFNAME);
    idclass_run_cmd(buf, false);

    ofs = prepare_filter_cmd(buf, sizeof(buf), iface->ifname, prio++, true, false);
    APPEND(buf, ofs, " protocol ipv6 u32 offset plus 4 match ip6 sport 53 0xffff "
                     "flowid 1:1 action mirred egress redirect dev "
                     IDCLASS_DNS_IFNAME);
    idclass_run_cmd(buf, false);

    if (!iface->config.ingress)
        return 0;

    /* 创建 IFB 设备用于 ingress 重定向 */
    snprintf(buf, sizeof(buf), "ip link add '%s' type ifb", ifbdev);
    idclass_run_cmd(buf, false);

    cmd_add_qdisc(iface, ifbdev, false, eth);

    snprintf(buf, sizeof(buf), "ip link set dev '%s' up", ifbdev);
    idclass_run_cmd(buf, false);

    /* 将所有流量重定向到 IFB 设备 */
    ofs = prepare_filter_cmd(buf, sizeof(buf), iface->ifname, prio++, true, false);
    APPEND(buf, ofs, " protocol all u32 match u32 0 0 flowid 1:1"
                     " action mirred egress redirect dev '%s'", ifbdev);
    return idclass_run_cmd(buf, false);
}

/* 添加 egress 方向配置 */
static int cmd_add_egress(struct idclass_iface *iface, bool eth) {
    if (!iface->config.egress)
        return 0;

    cmd_add_qdisc(iface, iface->ifname, true, eth);
    return cmd_add_bpf_filter(iface->ifname, IDCLASS_PRIO_BASE, true, eth);
}

/* 清除接口上的所有 qdisc 和 filter */
static void interface_clear_qdisc(struct idclass_iface *iface) {
    char buf[64];
    int i;

    prepare_qdisc_cmd(buf, sizeof(buf), iface->ifname, false, "root");
    idclass_run_cmd(buf, true);

    for (i = 0; i < 6; i++) {
        prepare_filter_cmd(buf, sizeof(buf), iface->ifname,
                           IDCLASS_PRIO_BASE + i, false, false);
        idclass_run_cmd(buf, true);
    }

    prepare_filter_cmd(buf, sizeof(buf), iface->ifname,
                       IDCLASS_PRIO_BASE, false, true);
    idclass_run_cmd(buf, true);

    snprintf(buf, sizeof(buf), "ip link del '%s'", interface_ifb_name(iface));
    idclass_run_cmd(buf, true);
}

/* 启动接口上的 QoS */
static void interface_start(struct idclass_iface *iface) {
    struct ifreq ifr = {};
    bool eth;

    if (!iface->ifname[0] || iface->active)
        return;

    ULOG_INFO("start interface %s\n", iface->ifname);

    strncpy(ifr.ifr_name, iface->ifname, sizeof(ifr.ifr_name));
    if (ioctl(socket_fd, SIOCGIFHWADDR, &ifr) < 0) {
        ULOG_ERR("ioctl(SIOCGIFHWADDR, %s) failed: %s\n",
                 iface->ifname, strerror(errno));
        return;
    }

    eth = (ifr.ifr_hwaddr.sa_family == ARPHRD_ETHER);

    interface_clear_qdisc(iface);
    cmd_add_egress(iface, eth);
    cmd_add_ingress(iface, eth);

    iface->active = true;
}

/* 停止接口上的 QoS */
static void interface_stop(struct idclass_iface *iface) {
    if (!iface->ifname[0] || !iface->active)
        return;

    ULOG_INFO("stop interface %s\n", iface->ifname);
    iface->active = false;
    interface_clear_qdisc(iface);
}

/* 解析接口配置 */
static void iface_config_parse(struct blob_attr *attr, struct blob_attr **tb) {
    static const struct blobmsg_policy policy[__IFACE_ATTR_MAX] = {
        [IFACE_ATTR_BW_UP] = { "bandwidth_up", BLOBMSG_TYPE_STRING },
        [IFACE_ATTR_BW_DOWN] = { "bandwidth_down", BLOBMSG_TYPE_STRING },
        [IFACE_ATTR_INGRESS] = { "ingress", BLOBMSG_TYPE_BOOL },
        [IFACE_ATTR_EGRESS] = { "egress", BLOBMSG_TYPE_BOOL },
        [IFACE_ATTR_MODE] = { "mode", BLOBMSG_TYPE_STRING },
        [IFACE_ATTR_NAT] = { "nat", BLOBMSG_TYPE_BOOL },
        [IFACE_ATTR_HOST_ISOLATE] = { "host_isolate", BLOBMSG_TYPE_BOOL },
        [IFACE_ATTR_AUTORATE_IN] = { "autorate_ingress", BLOBMSG_TYPE_BOOL },
        [IFACE_ATTR_INGRESS_OPTS] = { "ingress_options", BLOBMSG_TYPE_STRING },
        [IFACE_ATTR_EGRESS_OPTS] = { "egress_options", BLOBMSG_TYPE_STRING },
        [IFACE_ATTR_OPTS] = { "options", BLOBMSG_TYPE_STRING },
    };
    blobmsg_parse(policy, __IFACE_ATTR_MAX, tb, blobmsg_data(attr), blobmsg_len(attr));
}

/* 检查两个接口配置是否相等 */
static bool iface_config_equal(struct idclass_iface *if1, struct idclass_iface *if2) {
    struct blob_attr *tb1[__IFACE_ATTR_MAX], *tb2[__IFACE_ATTR_MAX];
    int i;

    iface_config_parse(if1->config_data, tb1);
    iface_config_parse(if2->config_data, tb2);

    for (i = 0; i < __IFACE_ATTR_MAX; i++) {
        if (!!tb1[i] != !!tb2[i])
            return false;
        if (!tb1[i])
            continue;
        if (blob_raw_len(tb1[i]) != blob_raw_len(tb2[i]))
            return false;
        if (memcmp(tb1[i], tb2[i], blob_raw_len(tb1[i])) != 0)
            return false;
    }
    return true;
}

/* 从配置中提取字符串选项（检查单引号） */
static const char *check_str(struct blob_attr *attr) {
    const char *str = blobmsg_get_string(attr);
    if (strchr(str, '\''))
        return NULL;
    return str;
}

/* 设置接口配置 */
static void iface_config_set(struct idclass_iface *iface, struct blob_attr *attr) {
    struct idclass_iface_config *cfg = &iface->config;
    struct blob_attr *tb[__IFACE_ATTR_MAX];
    struct blob_attr *cur;

    iface_config_parse(attr, tb);
    memset(cfg, 0, sizeof(*cfg));

    /* 默认值 */
    cfg->mode = "diffserv4";
    cfg->ingress = true;
    cfg->egress = true;
    cfg->host_isolate = true;
    cfg->autorate_ingress = false;
    cfg->nat = !iface->device;

    if ((cur = tb[IFACE_ATTR_BW_UP]) != NULL)
        cfg->bandwidth_up = check_str(cur);
    if ((cur = tb[IFACE_ATTR_BW_DOWN]) != NULL)
        cfg->bandwidth_down = check_str(cur);
    if ((cur = tb[IFACE_ATTR_MODE]) != NULL)
        cfg->mode = check_str(cur);
    if ((cur = tb[IFACE_ATTR_OPTS]) != NULL)
        cfg->common_opts = check_str(cur);
    if ((cur = tb[IFACE_ATTR_EGRESS_OPTS]) != NULL)
        cfg->egress_opts = check_str(cur);
    if ((cur = tb[IFACE_ATTR_INGRESS_OPTS]) != NULL)
        cfg->ingress_opts = check_str(cur);
    if ((cur = tb[IFACE_ATTR_INGRESS]) != NULL)
        cfg->ingress = blobmsg_get_bool(cur);
    if ((cur = tb[IFACE_ATTR_EGRESS]) != NULL)
        cfg->egress = blobmsg_get_bool(cur);
    if ((cur = tb[IFACE_ATTR_NAT]) != NULL)
        cfg->nat = blobmsg_get_bool(cur);
    if ((cur = tb[IFACE_ATTR_HOST_ISOLATE]) != NULL)
        cfg->host_isolate = blobmsg_get_bool(cur);
    if ((cur = tb[IFACE_ATTR_AUTORATE_IN]) != NULL)
        cfg->autorate_ingress = blobmsg_get_bool(cur);
}

/* 应用接口配置（创建或更新） */
static void interface_set_config(struct idclass_iface *iface, struct blob_attr *config) {
    iface->config_data = blob_memdup(config);
    iface_config_set(iface, iface->config_data);
    interface_start(iface);
}

/* vlist 回调：接口或设备变更时处理 */
static void interface_update_cb(struct vlist_tree *tree,
                                struct vlist_node *node_new,
                                struct vlist_node *node_old) {
    struct idclass_iface *if_new = NULL, *if_old = NULL;

    if (node_new)
        if_new = container_of(node_new, struct idclass_iface, node);
    if (node_old)
        if_old = container_of(node_old, struct idclass_iface, node);

    if (if_new && if_old) {
        if (!iface_config_equal(if_old, if_new)) {
            interface_stop(if_old);
            free(if_old->config_data);
            interface_set_config(if_old, if_new->config_data);
        }
        free(if_new);
        return;
    }

    if (if_old) {
        interface_stop(if_old);
        free(if_old->config_data);
        free(if_old);
    }
    if (if_new)
        interface_set_config(if_new, if_new->config_data);
}

/* 创建接口或设备实例 */
static void interface_create(struct blob_attr *attr, bool device) {
    struct idclass_iface *iface;
    const char *name = blobmsg_name(attr);
    int name_len = strlen(name);
    char *name_buf;

    if (strchr(name, '\''))
        return;
    if (name_len >= IFNAMSIZ)
        return;
    if (blobmsg_type(attr) != BLOBMSG_TYPE_TABLE)
        return;

    iface = calloc_a(sizeof(*iface), &name_buf, name_len + 1);
    if (!iface) {
        ULOG_ERR("Failed to allocate interface %s\n", name);
        return;
    }
    strcpy(name_buf, blobmsg_name(attr));
    iface->config_data = attr;
    iface->device = device;
    vlist_add(device ? &devices : &interfaces, &iface->node, name_buf);
}

/* 外部接口：更新接口配置（由 ubus 调用） */
void interface_config_update(struct blob_attr *ifaces, struct blob_attr *devs) {
    struct blob_attr *cur;
    int rem;

    vlist_update(&devices);
    blobmsg_for_each_attr(cur, devs, rem)
        interface_create(cur, true);
    vlist_flush(&devices);

    vlist_update(&interfaces);
    blobmsg_for_each_attr(cur, ifaces, rem)
        interface_create(cur, false);
    vlist_flush(&interfaces);
}

/* 检查设备接口是否存在并更新状态 */
static void idclass_iface_check_device(struct idclass_iface *iface) {
    const char *name = (const char *)iface->node.avl.key;
    int ifindex;

    ifindex = if_nametoindex(name);
    if (!ifindex) {
        interface_stop(iface);
        iface->ifname[0] = 0;
    } else {
        snprintf(iface->ifname, sizeof(iface->ifname), "%s", name);
        interface_start(iface);
    }
}

/* 检查逻辑接口是否存在（通过 ubus）并更新状态 */
static void idclass_iface_check_interface(struct idclass_iface *iface) {
    const char *name = (const char *)iface->node.avl.key;
    char ifname[IFNAMSIZ];

    if (ubus_server_check_interface(name, ifname, sizeof(ifname)) == 0) {
        snprintf(iface->ifname, sizeof(iface->ifname), "%s", ifname);
        interface_start(iface);
    } else {
        interface_stop(iface);
        iface->ifname[0] = 0;
    }
}

/* 定期检查接口状态的定时器回调 */
static void qos_iface_check_cb(struct uloop_timeout *t) {
    struct idclass_iface *iface;

    vlist_for_each_element(&devices, iface, node)
        idclass_iface_check_device(iface);
    vlist_for_each_element(&interfaces, iface, node)
        idclass_iface_check_interface(iface);
    ubus_server_update_bridger(false);
}

/* 外部接口：触发接口状态检查（由 ubus 调用） */
void interface_check(void) {
    static struct uloop_timeout timer = { .cb = qos_iface_check_cb };
    uloop_timeout_set(&timer, 10);
}

/* 外部接口：获取所有活动设备名（用于 bridger 黑名单） */
void interface_get_devices(struct blob_buf *b) {
    struct idclass_iface *iface;

    vlist_for_each_element(&devices, iface, node) {
        if (iface->ifname[0] && iface->active)
            blobmsg_add_string(b, NULL, iface->ifname);
    }
    vlist_for_each_element(&interfaces, iface, node) {
        if (iface->ifname[0] && iface->active)
            blobmsg_add_string(b, NULL, iface->ifname);
    }
}

/* 外部接口：输出接口状态（用于 ubus status） */
void interface_status(struct blob_buf *b) {
    struct idclass_iface *iface;
    void *c;

    c = blobmsg_open_table(b, "devices");
    vlist_for_each_element(&devices, iface, node) {
        void *d = blobmsg_open_table(b, (const char *)iface->node.avl.key);
        blobmsg_add_u8(b, "active", iface->active);
        if (iface->ifname[0])
            blobmsg_add_string(b, "ifname", iface->ifname);
        blobmsg_add_u8(b, "egress", iface->config.egress);
        blobmsg_add_u8(b, "ingress", iface->config.ingress);
        blobmsg_close_table(b, d);
    }
    blobmsg_close_table(b, c);

    c = blobmsg_open_table(b, "interfaces");
    vlist_for_each_element(&interfaces, iface, node) {
        void *d = blobmsg_open_table(b, (const char *)iface->node.avl.key);
        blobmsg_add_u8(b, "active", iface->active);
        if (iface->ifname[0])
            blobmsg_add_string(b, "ifname", iface->ifname);
        blobmsg_add_u8(b, "egress", iface->config.egress);
        blobmsg_add_u8(b, "ingress", iface->config.ingress);
        blobmsg_close_table(b, d);
    }
    blobmsg_close_table(b, c);
}

/* Netlink 错误回调 */
static int idclass_nl_error_cb(struct sockaddr_nl *nla, struct nlmsgerr *err,
                               void *arg) {
    struct nlmsghdr *nlh = (struct nlmsghdr *)err - 1;
    struct nlattr *tb[NLMSGERR_ATTR_MAX + 1];
    struct nlattr *attrs;
    int ack_len = sizeof(*nlh) + sizeof(int) + sizeof(*nlh);
    int len = nlh->nlmsg_len;
    const char *errstr = "(unknown)";

    if (!(nlh->nlmsg_flags & NLM_F_ACK_TLVS))
        return NL_STOP;
    if (!(nlh->nlmsg_flags & NLM_F_CAPPED))
        ack_len += err->msg.nlmsg_len - sizeof(*nlh);
    attrs = (void *)((unsigned char *)nlh + ack_len);
    len -= ack_len;

    nla_parse(tb, NLMSGERR_ATTR_MAX, attrs, len, NULL);
    if (tb[NLMSGERR_ATTR_MSG])
        errstr = nla_data(tb[NLMSGERR_ATTR_MSG]);

    ULOG_ERR("Netlink error(%d): %s\n", err->error, errstr);
    return NL_STOP;
}

/* 外部接口：初始化接口模块 */
int interface_init(void) {
    int fd, opt;

    socket_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socket_fd < 0) {
        ULOG_ERR("Failed to create AF_UNIX socket: %s\n", strerror(errno));
        return -1;
    }

    rtnl_sock = nl_socket_alloc();
    if (!rtnl_sock) {
        close(socket_fd);
        return -1;
    }

    if (nl_connect(rtnl_sock, NETLINK_ROUTE)) {
        nl_socket_free(rtnl_sock);
        close(socket_fd);
        return -1;
    }

    nl_cb_err(nl_socket_get_cb(rtnl_sock), NL_CB_CUSTOM,
              idclass_nl_error_cb, NULL);

    fd = nl_socket_get_fd(rtnl_sock);
    opt = 1;
    setsockopt(fd, SOL_NETLINK, NETLINK_EXT_ACK, &opt, sizeof(opt));
    opt = 1;
    setsockopt(fd, SOL_NETLINK, NETLINK_CAP_ACK, &opt, sizeof(opt));

    return 0;
}

/* 外部接口：停止所有接口的 QoS 并释放资源 */
void interface_stop(void) {
    struct idclass_iface *iface;

    vlist_for_each_element(&interfaces, iface, node)
        interface_stop(iface);
    vlist_for_each_element(&devices, iface, node)
        interface_stop(iface);

    nl_socket_free(rtnl_sock);
    close(socket_fd);
}