// SPDX-License-Identifier: GPL-2.0+
/*
 * dns_parser.c - DNS traffic parsing and mapping module
 *
 * Listens to DNS responses on a dedicated IFB interface, extracts domain names,
 * and updates IP address mappings via map_manager. Also manages CNAME caching
 * for chained lookups.
 */
#include "common.h"
#include <netinet/if_ether.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/udp.h>
#include <netpacket/packet.h>
#include <net/if.h>
#include <sys/socket.h>
#include <errno.h>
#include <resolv.h>
#include <libubox/uloop.h>
#include <libubox/avl-cmp.h>

#define FLAG_RESPONSE  0x8000
#define FLAG_OPCODE    0x7800
#define FLAG_RCODE     0x000f

#define TYPE_A         0x0001
#define TYPE_CNAME     0x0005
#define TYPE_PTR       0x000c
#define TYPE_TXT       0x0010
#define TYPE_AAAA      0x001c
#define TYPE_SRV       0x0021
#define TYPE_ANY       0x00ff

#define IS_COMPRESSED(x) ((x & 0xc0) == 0xc0)
#define CLASS_IN        0x0001

#define MAX_NAME_LEN    256
#define MAX_DATA_LEN    8096

/* VLAN 头部定义（内核可能未包含完整） */
struct vlan_hdr {
    uint16_t tci;
    uint16_t proto;
};

/* 数据包结构 */
struct packet {
    void *buffer;
    unsigned int len;
};

/* DNS 头部结构 */
struct dns_header {
    uint16_t id;
    uint16_t flags;
    uint16_t questions;
    uint16_t answers;
    uint16_t authority;
    uint16_t additional;
} __packed;

/* DNS 问题结构 */
struct dns_question {
    uint16_t type;
    uint16_t class;
} __packed;

/* DNS 应答结构 */
struct dns_answer {
    uint16_t type;
    uint16_t class;
    uint32_t ttl;
    uint16_t rdlength;
} __packed;

/* CNAME 缓存条目 */
struct cname_entry {
    struct avl_node node;
    uint32_t seq;
    uint8_t dscp;
    uint8_t age;
    regex_t regex;           /* 用于正则匹配（如果 pattern 以 '/' 开头） */
    char pattern[];          /* 可变长度，存储 pattern 字符串 */
};

/* 全局变量 */
static struct uloop_fd ufd;
static struct uloop_timeout cname_gc_timer;
static AVL_TREE(cname_cache, avl_strcmp, false, NULL);

/* 内部函数：从数据包中拉取指定长度 */
static void *pkt_pull(struct packet *pkt, unsigned int len) {
    if (len > pkt->len)
        return NULL;
    void *ret = pkt->buffer;
    pkt->buffer += len;
    pkt->len -= len;
    return ret;
}

/* 内部函数：解析 DNS 域名（可能压缩），可选存储到 dest */
static int pkt_pull_name(struct packet *pkt, const void *hdr, char *dest) {
    int len;
    if (dest) {
        len = dn_expand(hdr, pkt->buffer + pkt->len, pkt->buffer,
                        (void *)dest, MAX_NAME_LEN);
    } else {
        len = dn_skipname(pkt->buffer, pkt->buffer + pkt->len - 1);
    }
    if (len < 0 || !pkt_pull(pkt, len))
        return -1;
    return 0;
}

/* 内部函数：判断协议是否为 VLAN */
static bool proto_is_vlan(uint16_t proto) {
    return proto == ETH_P_8021Q || proto == ETH_P_8021AD;
}

/* CNAME 缓存操作（普通域名） */
static void cname_cache_set(const char *name, uint8_t dscp, uint32_t seq) {
    struct cname_entry *e = avl_find_element(&cname_cache, name, e, node);
    if (!e) {
        char *pattern;
        e = calloc_a(sizeof(*e), &pattern, strlen(name) + 1);
        if (!e) return;
        strcpy(pattern, name);
        e->pattern[0] = 0; /* 不是正则，没有 pattern */
        e->node.key = pattern;
        avl_insert(&cname_cache, &e->node);
    }
    e->age = 0;
    e->dscp = dscp;
    e->seq = seq;
}

/* CNAME 缓存操作（正则表达式） */
static void cname_cache_set_regex(const char *pattern, uint8_t dscp, uint32_t seq) {
    struct cname_entry *e = avl_find_element(&cname_cache, pattern, e, node);
    if (!e) {
        char *pattern_copy;
        e = calloc_a(sizeof(*e), &pattern_copy, strlen(pattern) + 1);
        if (!e) return;
        strcpy(pattern_copy, pattern);
        e->pattern[0] = pattern[0];
        e->node.key = pattern_copy;
        if (regcomp(&e->regex, pattern + 1, REG_EXTENDED | REG_NOSUB) != 0) {
            free(e);
            return;
        }
        avl_insert(&cname_cache, &e->node);
    }
    e->age = 0;
    e->dscp = dscp;
    e->seq = seq;
}

static int cname_cache_get(const char *name, uint8_t *dscp, uint32_t *seq) {
    struct cname_entry *e = avl_find_element(&cname_cache, name, e, node);
    if (!e) return -1;
    if (*dscp == 0xff || e->seq < *seq) {
        *dscp = e->dscp;
        *seq = e->seq;
    }
    return 0;
}

/* 内部函数：解析 DNS 问题部分 */
static int dns_parse_question(struct packet *pkt, const void *hdr,
                              uint8_t *dscp, uint32_t *seq) {
    char qname[MAX_NAME_LEN];
    if (pkt_pull_name(pkt, hdr, qname) ||
        !pkt_pull(pkt, sizeof(struct dns_question))) {
        return -1;
    }
    cname_cache_get(qname, dscp, seq);
    map_manager_lookup_dns_entry(qname, false, dscp, seq);
    return 0;
}

/* 内部函数：解析 DNS 应答部分 */
static int dns_parse_answer(struct packet *pkt, void *hdr,
                            uint8_t *dscp, uint32_t *seq) {
    struct dns_answer *a;
    void *rdata;
    int len;
    uint32_t ttl;
    struct idclass_map_data data = { .dscp = *dscp, .user = true };

    if (pkt_pull_name(pkt, hdr, NULL))
        return -1;

    a = pkt_pull(pkt, sizeof(*a));
    if (!a)
        return -1;

    len = be16_to_cpu(a->rdlength);
    rdata = pkt_pull(pkt, len);
    if (!rdata)
        return -1;

    ttl = be32_to_cpu(a->ttl);

    switch (be16_to_cpu(a->type)) {
    case TYPE_CNAME: {
        char cname[MAX_NAME_LEN];
        if (dn_expand(hdr, pkt->buffer + pkt->len, rdata,
                      cname, sizeof(cname)) < 0)
            return -1;
        map_manager_lookup_dns_entry(cname, true, dscp, seq);
        if (cname[0] == '/')
            cname_cache_set_regex(cname, *dscp, *seq);
        else
            cname_cache_set(cname, *dscp, *seq);
        break;
    }
    case TYPE_A:
        data.id = CL_MAP_IPV4_ADDR;
        memcpy(&data.addr.ip, rdata, 4);
        map_manager_add_ip_to_nft_sets(rdata, AF_INET, ttl, *dscp);
        map_manager_set_entry_data(&data);
        break;
    case TYPE_AAAA:
        data.id = CL_MAP_IPV6_ADDR;
        memcpy(&data.addr.ip6, rdata, 16);
        map_manager_add_ip_to_nft_sets(rdata, AF_INET6, ttl, *dscp);
        map_manager_set_entry_data(&data);
        break;
    default:
        return 0;
    }
    return 0;
}

/* 内部函数：处理 DNS 数据包内容 */
static void idclass_dns_data_cb(struct packet *pkt) {
    struct dns_header *h;
    uint32_t lookup_seq = 0;
    uint8_t dscp = 0xff;
    int i;

    h = pkt_pull(pkt, sizeof(*h));
    if (!h)
        return;

    if ((h->flags & cpu_to_be16(FLAG_RESPONSE | FLAG_OPCODE | FLAG_RCODE)) !=
        cpu_to_be16(FLAG_RESPONSE))
        return;

    if (h->questions != cpu_to_be16(1))
        return;

    if (dns_parse_question(pkt, h, &dscp, &lookup_seq))
        return;

    for (i = 0; i < be16_to_cpu(h->answers); i++)
        if (dns_parse_answer(pkt, h, &dscp, &lookup_seq))
            return;
}

/* 内部函数：解析以太网帧，定位 DNS/UDP 载荷 */
static void idclass_dns_packet_cb(struct packet *pkt) {
    struct ethhdr *eth;
    struct iphdr *ip;
    struct ipv6hdr *ip6;
    uint16_t proto;

    eth = pkt_pull(pkt, sizeof(*eth));
    if (!eth)
        return;

    proto = be16_to_cpu(eth->h_proto);
    if (proto_is_vlan(proto)) {
        struct vlan_hdr *vlan;
        vlan = pkt_pull(pkt, sizeof(*vlan));
        if (!vlan)
            return;
        proto = be16_to_cpu(vlan->proto);
    }

    switch (proto) {
    case ETH_P_IP:
        ip = pkt_pull(pkt, sizeof(*ip));
        if (!ip)
            return;
        if (!pkt_pull(pkt, (ip->ihl * 4) - sizeof(*ip)))
            return;
        proto = ip->protocol;
        break;
    case ETH_P_IPV6:
        ip6 = pkt_pull(pkt, sizeof(*ip6));
        if (!ip6)
            return;
        proto = ip6->nexthdr;
        break;
    default:
        return;
    }

    if (proto != IPPROTO_UDP)
        return;

    if (!pkt_pull(pkt, sizeof(struct udphdr)))
        return;

    idclass_dns_data_cb(pkt);
}

/* 内部函数：原始套接字回调 */
static void idclass_dns_socket_cb(struct uloop_fd *fd, unsigned int events) {
    static uint8_t buf[8192];
    struct packet pkt = { .buffer = buf };
    int len;

retry:
    len = recvfrom(fd->fd, buf, sizeof(buf), MSG_DONTWAIT, NULL, NULL);
    if (len < 0) {
        if (errno == EINTR)
            goto retry;
        return;
    }
    if (!len)
        return;

    pkt.len = len;
    idclass_dns_packet_cb(&pkt);
}

/* 内部函数：CNAME 缓存垃圾回收 */
static void idclass_cname_cache_gc(struct uloop_timeout *timeout) {
    struct cname_entry *e, *tmp;
    avl_for_each_element_safe(&cname_cache, e, node, tmp) {
        if (e->age++ < 5)
            continue;
        avl_delete(&cname_cache, &e->node);
        if (e->pattern[0] == '/')
            regfree(&e->regex);
        free(e);
    }
    uloop_timeout_set(timeout, 1000);
}

/* 内部函数：打开原始套接字监听 DNS 流量（在 ifb-dns 上） */
static int idclass_open_dns_socket(void) {
    struct sockaddr_ll sll = {
        .sll_family = AF_PACKET,
        .sll_protocol = htons(ETH_P_ALL),
    };
    int sock;

    sock = socket(PF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (sock == -1) {
        ULOG_ERR("failed to create raw socket: %s\n", strerror(errno));
        return -1;
    }

    sll.sll_ifindex = if_nametoindex(IDCLASS_DNS_IFNAME);
    if (bind(sock, (struct sockaddr *)&sll, sizeof(sll))) {
        ULOG_ERR("failed to bind socket to " IDCLASS_DNS_IFNAME ": %s\n",
                 strerror(errno));
        close(sock);
        return -1;
    }

    ufd.fd = sock;
    ufd.cb = idclass_dns_socket_cb;
    uloop_fd_add(&ufd, ULOOP_READ);
    return 0;
}

/* 内部函数：删除 ifb-dns 设备 */
static void idclass_dns_del_ifb(void) {
    idclass_run_cmd("ip link del ifb-dns type ifb", true);
}

/* 外部接口：初始化 DNS 解析模块 */
int dns_parser_init(void) {
    cname_gc_timer.cb = idclass_cname_cache_gc;
    idclass_cname_cache_gc(&cname_gc_timer);

    idclass_dns_del_ifb();

    if (idclass_run_cmd("ip link add ifb-dns type ifb", false) ||
        idclass_run_cmd("ip link set dev ifb-dns up", false) ||
        idclass_open_dns_socket()) {
        return -1;
    }

    return 0;
}

/* 外部接口：停止 DNS 解析模块 */
void dns_parser_stop(void) {
    struct cname_entry *e, *tmp;

    if (ufd.registered) {
        uloop_fd_delete(&ufd);
        close(ufd.fd);
    }

    idclass_dns_del_ifb();

    avl_remove_all_elements(&cname_cache, e, node, tmp) {
        if (e->pattern[0] == '/')
            regfree(&e->regex);
        free(e);
    }
}