#ifndef __IDCLASS_COMMON_H
#define __IDCLASS_COMMON_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <libubox/utils.h>
#include <libubox/avl.h>
#include <libubox/ulog.h>
#include <libubox/blobmsg.h>
#include <libubox/uloop.h>
#include <net/if.h>
#include <regex.h>

#include "idclass-bpf.h"

#define CLASSIFY_DATA_PATH   "/sys/fs/bpf/idclass_data"
#define CLASSIFY_PIN_PATH    "/sys/fs/bpf/idclass"
#define IDCLASS_DNS_IFNAME   "ifb-dns"
#define IDCLASS_PRIO_BASE    0x110

/* 全局配置实例（由 map_manager.c 定义） */
extern struct global_config global_config;
extern struct idclass_flow_config global_flow_config;
extern int idclass_map_timeout;
extern int idclass_active_timeout;

/* 辅助函数（由 main.c 提供） */
int idclass_run_cmd(char *cmd, bool ignore_error);
int idclass_map_codepoint(const char *val);
int idclass_map_dscp_value(const char *val, uint8_t *dscp_val);
char *str_skip(char *str, bool space);
int read_float_mult100(const char *val);

/* ======================= ebpf_loader 接口 ======================= */
int ebpf_loader_init(void);
const char *ebpf_loader_get_program(uint32_t flags, int *fd);

/* ======================= map_manager 接口 ======================= */
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

int map_manager_init(void);
int map_manager_get_fd(enum idclass_map_id id);
int map_manager_set_entry(enum idclass_map_id id, bool file, const char *str,
                         uint8_t dscp, bool only_cname);
void map_manager_set_entry_data(struct idclass_map_data *data);
void map_manager_set_dscp_default(enum idclass_map_id id, uint8_t val);
void map_manager_reset_config(void);
void map_manager_reload_files(void);
void map_manager_gc(void);
void map_manager_dump(struct blob_buf *b);
void map_manager_stats(struct blob_buf *b, bool reset);
void map_manager_update_config(void);
void map_manager_set_classes(struct blob_attr *val);
void map_manager_sync_class_config(void);
void map_manager_add_ip_to_nft_sets(const void *addr, int family, uint32_t ttl, uint8_t dscp);
int map_manager_lookup_dns_entry(char *host, bool cname, uint8_t *dscp, uint32_t *seq);
int map_manager_add_dns_host(char *host, const char *addr, const char *type, int ttl);
int map_manager_load_file(const char *file);
void map_manager_clear_files(void);

/* ======================= config 接口 ======================= */
int config_init(void);
int config_reload(void);
struct global_config *config_get_global(void);
struct idclass_flow_config *config_get_flow(void);
int config_parse_flow_config(struct idclass_flow_config *cfg, struct blob_attr *attr, bool reset);
int config_parse_dscp_value(uint8_t *dest, struct blob_attr *attr, bool reset);
void config_set_classes(struct blob_attr *val);
int config_get_class_id(const char *name);
int config_name_to_dscp(const char *name, uint8_t *dscp);
void config_sync_to_bpf(void);
void config_set_name(const char *name);          /* 设置 UCI 配置名（由 main.c 调用） */
const char *config_get_name(void);              /* 获取当前 UCI 配置名（供 ebpf_loader 使用） */

/* ======================= dns_parser 接口 ======================= */
int dns_parser_init(void);
void dns_parser_stop(void);

/* ======================= interface 接口 ======================= */
int interface_init(void);
void interface_config_update(struct blob_attr *ifaces, struct blob_attr *devs);
void interface_check(void);
void interface_get_devices(struct blob_buf *b);
void interface_status(struct blob_buf *b);
void interface_stop(void);

/* ======================= ubus_server 接口 ======================= */
int ubus_server_init(void);
void ubus_server_stop(void);
int ubus_server_check_interface(const char *name, char *ifname, int ifname_len);
void ubus_server_update_bridger(bool shutdown);

#endif /* __IDCLASS_COMMON_H */