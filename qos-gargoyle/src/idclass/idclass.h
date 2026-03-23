// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 * Modified to support multi-feature classification
 */
#ifndef __IDCLASS_H
#define __IDCLASS_H

#include <stdbool.h>
#include <regex.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <libubox/utils.h>
#include <libubox/avl.h>
#include <libubox/blobmsg.h>
#include <libubox/ulog.h>
#include <netinet/in.h>
#include <net/if.h>          // 添加此头文件以使用 if_nametoindex

#include "idclass-bpf.h"

#define CLASSIFY_PROG_PATH   "/lib/bpf/idclass-bpf.o"
#define CLASSIFY_PIN_PATH    "/sys/fs/bpf/idclass"
#define CLASSIFY_DATA_PATH   "/sys/fs/bpf/idclass_data"

#define IDCLASS_DNS_IFNAME "ifb-dns"

#define IDCLASS_PRIO_BASE   0x110

struct idclass_map_info_entry {
    const char *name;
    const char *type_name;
};

extern const struct idclass_map_info_entry idclass_map_info[];

enum idclass_map_id {
    CL_MAP_TCP_PORTS,
    CL_MAP_UDP_PORTS,
    CL_MAP_IPV4_ADDR,
    CL_MAP_IPV6_ADDR,
    CL_MAP_CLASS,
    CL_MAP_GLOBAL_CONFIG,
    CL_MAP_DNS,
    CL_MAP_PRIO_CLASS_UP,
    CL_MAP_PRIO_CLASS_DOWN,
    CL_MAP_CLASS_MARK,
    CL_MAP_IP_CONN,
    __CL_MAP_MAX,
};

/* 用户态专用的类结构体（包含名称和 BPF 数据） */
struct idclass_class_entry {
    const char *name;
    struct idclass_class data;
};

/* 用户态映射数据 */
struct idclass_map_data {
    enum idclass_map_id id;
    bool file : 1;
    bool user : 1;
    uint8_t dscp;
    uint8_t file_dscp;
    union {
        uint32_t port;
        struct in_addr ip;
        struct in6_addr ip6;
        struct {
            uint32_t seq : 30;
            uint32_t only_cname : 1;
            const char *pattern;
            regex_t regex;
        } dns;
    } addr;
};

struct idclass_map_entry {
    struct avl_node avl;
    uint32_t timeout;
    struct idclass_map_data data;
};

struct idclass_map_file {
    struct list_head list;
    char filename[];
};

extern int idclass_map_timeout;
extern int idclass_active_timeout;
extern struct global_config global_config;          // 使用 BPF 结构体
extern struct idclass_flow_config global_flow_config;
extern struct uloop_timeout idclass_map_timer;

int idclass_run_cmd(char *cmd, bool ignore_error);
int idclass_loader_init(void);
const char *idclass_get_program(uint32_t flags, int *fd);
int idclass_map_init(void);
int idclass_map_dscp_value(const char *val, uint8_t *dscp);
int idclass_map_load_file(const char *file);
void __idclass_map_set_entry(struct idclass_map_data *data);
int idclass_map_set_entry(enum idclass_map_id id, bool file, const char *str,
                         uint8_t dscp);
void idclass_map_reload(void);
void idclass_map_clear_files(void);
void idclass_map_gc(void);
void idclass_map_dump(struct blob_buf *b);
void idclass_map_stats(struct blob_buf *b, bool reset);
void idclass_map_set_dscp_default(enum idclass_map_id id, uint8_t val);
void idclass_map_reset_config(void);
void idclass_map_update_config(void);
void idclass_map_set_classes(struct blob_attr *val);
int idclass_map_lookup_dns_entry(char *host, bool cname, uint8_t *dscp, uint32_t *seq);
int idclass_map_add_dns_host(char *host, const char *addr, const char *type, int ttl);
int map_parse_flow_config(struct idclass_flow_config *cfg, struct blob_attr *attr,
                          bool reset);
int map_fill_dscp_value(uint8_t *dest, struct blob_attr *attr, bool reset);
int idclass_iface_init(void);
void idclass_iface_config_update(struct blob_attr *ifaces, struct blob_attr *devs);
void idclass_iface_check(void);
void idclass_iface_status(struct blob_buf *b);
void idclass_iface_get_devices(struct blob_buf *b);
void idclass_iface_stop(void);
int idclass_dns_init(void);
void idclass_dns_stop(void);
int idclass_ubus_init(void);
void idclass_ubus_stop(void);
int idclass_ubus_check_interface(const char *name, char *ifname, int ifname_len);
void idclass_ubus_update_bridger(bool shutdown);
int idclass_map_get_fd(enum idclass_map_id id);
void idclass_set_config_name(const char *name);
void sync_class_config(void);
const char *idclass_dscp_to_class_name(uint8_t dscp);

char *str_skip(char *str, bool space);
int idclass_map_codepoint(const char *val);

extern const struct idclass_map_info_entry {
    const char *name;
    const char *type_name;
} idclass_map_info[];

#endif