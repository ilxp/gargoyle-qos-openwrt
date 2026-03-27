// SPDX-License-Identifier: GPL-2.0+
/*
 * map_manager.c - BPF map management module
 *
 * Handles all BPF map operations: open, update, delete, garbage collection,
 * statistics, DNS entry management, IP connection tracking, and configuration
 * synchronization with the kernel.
 */
#include "common.h"
#include <arpa/inet.h>
#include <fnmatch.h>
#include <glob.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <bpf/bpf.h>
#include <libubox/avl-cmp.h>
#include <libubox/uloop.h>
#include <libubox/list.h>
#include <ctype.h>
#include <sys/wait.h>

#define PERSISTENT_CLASS_MARKS "/etc/qos_gargoyle/class_marks"

/* 内部结构体定义（仅用于 map_manager 内部） */
struct idclass_map_entry {
    struct avl_node avl;
    uint32_t timeout;
    struct idclass_map_data data;
};

struct idclass_class_entry {
    const char *name;
    struct idclass_class data;
};

struct idclass_map_file {
    struct list_head list;
    char filename[];
};

/* Global configuration instances */
struct global_config global_config;
struct idclass_flow_config global_flow_config;
int idclass_map_timeout = 3600;
int idclass_active_timeout = 300;

/* Internal static data */
static int idclass_map_fds[__CL_MAP_MAX];
static AVL_TREE(map_data, idclass_map_entry_cmp, false, NULL);
static LIST_HEAD(map_files);
static struct idclass_class_entry *map_class[IDCLASS_MAX_CLASS_ENTRIES];
static uint32_t next_timeout;
static uint8_t idclass_dscp_default[2] = { 0xff, 0xff };
static uint32_t map_dns_seq;
static struct uloop_timeout idclass_map_timer;
static int ip_conn_fd = -1;
static int flow_stats_fd = -1;
static struct uloop_timeout ip_conn_timer;

/* 比较函数原型声明（供 AVL_TREE 使用） */
static int idclass_map_entry_cmp(const void *k1, const void *k2, void *ptr);

/* Helper: compare two map data entries for AVL tree */
static int idclass_map_entry_cmp(const void *k1, const void *k2, void *ptr) {
    const struct idclass_map_data *d1 = k1;
    const struct idclass_map_data *d2 = k2;

    if (d1->id != d2->id)
        return d2->id - d1->id;
    if (d1->id == CL_MAP_DNS)
        return strcmp(d1->addr.dns.pattern, d2->addr.dns.pattern);
    return memcmp(&d1->addr, &d2->addr, sizeof(d1->addr));
}

/* Helper: get monotonic time in seconds */
static uint32_t idclass_gettime(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

/* Helper: get path for a map by ID */
static const char *idclass_map_path(enum idclass_map_id id) {
    static char path[128];
    const char *name;

    static const char *map_names[] = {
        [CL_MAP_TCP_PORTS] = "tcp_ports",
        [CL_MAP_UDP_PORTS] = "udp_ports",
        [CL_MAP_IPV4_ADDR] = "ipv4_map",
        [CL_MAP_IPV6_ADDR] = "ipv6_map",
        [CL_MAP_CLASS] = "class_map",
        [CL_MAP_GLOBAL_CONFIG] = "global_config",
        [CL_MAP_DNS] = "dns",
        [CL_MAP_PRIO_CLASS_UP] = "prio_class_up",
        [CL_MAP_PRIO_CLASS_DOWN] = "prio_class_down",
        [CL_MAP_CLASS_MARK] = "class_mark",
        [CL_MAP_IP_CONN] = "ip_conn_map",
    };
    if (id >= __CL_MAP_MAX)
        return NULL;
    name = map_names[id];
    if (!name)
        return NULL;
    snprintf(path, sizeof(path), "%s/%s", CLASSIFY_DATA_PATH, name);
    return path;
}

/* Helper: get file descriptor for a map (opens if not already open) */
static int map_manager_get_fd_internal(enum idclass_map_id id) {
    if (idclass_map_fds[id] >= 0)
        return idclass_map_fds[id];
    const char *path = idclass_map_path(id);
    if (!path)
        return -1;
    int fd = bpf_obj_get(path);
    if (fd < 0) {
        fprintf(stderr, "Failed to open map %s: %s\n", path, strerror(errno));
        return -1;
    }
    idclass_map_fds[id] = fd;
    return fd;
}

/* External: get map file descriptor */
int map_manager_get_fd(enum idclass_map_id id) {
    return map_manager_get_fd_internal(id);
}

/* Helper: clear all entries in a map (for IPv4/IPv6 maps) */
static void idclass_map_clear_list(enum idclass_map_id id) {
    int fd = idclass_map_fds[id];
    __u32 key[4] = {0};
    while (bpf_map_get_next_key(fd, &key, &key) == 0)
        bpf_map_delete_elem(fd, &key);
}

/* Helper: set default DSCP for a port map */
static void __idclass_map_set_dscp_default(enum idclass_map_id id, uint8_t val) {
    struct idclass_map_data data = { .id = id };
    struct idclass_class class = {
        .val.ingress = val,
        .val.egress = val,
    };
    uint32_t key;
    int fd;
    int i;

    if (!(val & IDCLASS_DSCP_CLASS_FLAG)) {
        if (id == CL_MAP_TCP_PORTS)
            key = IDCLASS_MAX_CLASS_ENTRIES;
        else if (id == CL_MAP_UDP_PORTS)
            key = IDCLASS_MAX_CLASS_ENTRIES + 1;
        else
            return;
        fd = map_manager_get_fd_internal(CL_MAP_CLASS);
        memcpy(&class.config, &global_flow_config, sizeof(class.config));
        bpf_map_update_elem(fd, &key, &class, BPF_ANY);
        val = key | IDCLASS_DSCP_CLASS_FLAG;
    }

    fd = map_manager_get_fd_internal(id);
    for (i = 0; i < (1 << 16); i++) {
        data.addr.port = htons(i);
        if (avl_find(&map_data, &data))
            continue;
        bpf_map_update_elem(fd, &data.addr, &val, BPF_ANY);
    }
}

/* External: set default DSCP for TCP/UDP port maps */
void map_manager_set_dscp_default(enum idclass_map_id id, uint8_t val) {
    bool udp;

    if (id == CL_MAP_TCP_PORTS)
        udp = false;
    else if (id == CL_MAP_UDP_PORTS)
        udp = true;
    else
        return;

    if (val != 0xff) {
        if (idclass_dscp_default[udp] == val)
            return;
        idclass_dscp_default[udp] = val;
    }
    __idclass_map_set_dscp_default(id, idclass_dscp_default[udp]);
}

/* Helper: allocate a new map entry */
static struct idclass_map_entry *__idclass_map_alloc_entry(struct idclass_map_data *data) {
    struct idclass_map_entry *e;
    char *pattern;
    char *c;

    if (data->id < CL_MAP_DNS) {
        e = calloc(1, sizeof(*e));
        if (!e) return NULL;
        memcpy(&e->data.addr, &data->addr, sizeof(e->data.addr));
        return e;
    }

    e = calloc_a(sizeof(*e), &pattern, strlen(data->addr.dns.pattern) + 1);
    if (!e) return NULL;
    strcpy(pattern, data->addr.dns.pattern);
    e->data.addr.dns.pattern = pattern;
    for (c = pattern; *c; c++)
        *c = tolower(*c);
    if (pattern[0] == '/' &&
        regcomp(&e->data.addr.dns.regex, pattern + 1,
                REG_EXTENDED | REG_NOSUB)) {
        free(e);
        return NULL;
    }
    return e;
}

/* External: set a map entry (low-level) */
void map_manager_set_entry_data(struct idclass_map_data *data) {
    int fd = map_manager_get_fd_internal(data->id);
    struct idclass_map_entry *e;
    bool file = data->file;
    uint8_t prev_dscp = 0xff;
    int32_t delta = 0;
    bool add = data->dscp != 0xff;

    e = avl_find_element(&map_data, data, e, avl);
    if (!e) {
        if (!add)
            return;
        e = __idclass_map_alloc_entry(data);
        if (!e)
            return;
        e->avl.key = &e->data;
        e->data.id = data->id;
        avl_insert(&map_data, &e->avl);
    } else {
        prev_dscp = e->data.dscp;
    }

    if (file)
        e->data.file = add;
    else
        e->data.user = add;

    if (add) {
        if (file)
            e->data.file_dscp = data->dscp;
        if (!e->data.user || !file)
            e->data.dscp = data->dscp;
    } else if (e->data.file && !file) {
        e->data.dscp = e->data.file_dscp;
    }

    if (e->data.dscp != prev_dscp && data->id < CL_MAP_DNS) {
        struct idclass_ip_map_val val = {
            .dscp = e->data.dscp,
            .seen = 1,
        };
        bpf_map_update_elem(fd, &data->addr, &val, BPF_ANY);
    }

    if (data->id == CL_MAP_DNS)
        e->data.addr.dns.seq = ++map_dns_seq;

    if (add) {
        if (idclass_map_timeout == ~0 || file) {
            e->timeout = ~0;
            return;
        }
        e->timeout = idclass_gettime() + idclass_map_timeout;
        delta = e->timeout - next_timeout;
        if (next_timeout && delta >= 0)
            return;
    }
    uloop_timeout_set(&idclass_map_timer, 1);
}

/* External: set a map entry by string (for ubus) */
int map_manager_set_entry(enum idclass_map_id id, bool file, const char *str,
                         uint8_t dscp, bool only_cname) {
    struct idclass_map_data data = {
        .id = id,
        .file = file,
        .dscp = dscp,
    };
    switch (id) {
    case CL_MAP_DNS:
        data.addr.dns.pattern = str;
        data.addr.dns.only_cname = only_cname;
        break;
    case CL_MAP_TCP_PORTS:
    case CL_MAP_UDP_PORTS: {
        unsigned long start_port, end_port;
        char *err;
        start_port = end_port = strtoul(str, &err, 0);
        if (err && *err) {
            if (*err == '-')
                end_port = strtoul(err + 1, &err, 0);
            if (*err)
                return -1;
        }
        if (!start_port || end_port < start_port || end_port >= 65535)
            return -1;
        for (unsigned long i = start_port; i <= end_port; i++) {
            data.addr.port = htons(i);
            map_manager_set_entry_data(&data);
        }
        return 0;
    }
    case CL_MAP_IPV4_ADDR:
    case CL_MAP_IPV6_ADDR: {
        int af = (id == CL_MAP_IPV6_ADDR) ? AF_INET6 : AF_INET;
        if (inet_pton(af, str, &data.addr) != 1)
            return -1;
        break;
    }
    default:
        return -1;
    }
    map_manager_set_entry_data(&data);
    return 0;
}

/* External: clear all file-based entries and reload files */
void map_manager_reset_config(void) {
    struct idclass_map_file *f, *tmp;
    list_for_each_entry_safe(f, tmp, &map_files, list) {
        list_del(&f->list);
        free(f);
    }
    map_manager_set_dscp_default(CL_MAP_TCP_PORTS, 0);
    map_manager_set_dscp_default(CL_MAP_UDP_PORTS, 0);
    idclass_map_timeout = 3600;
    idclass_active_timeout = 300;
    memset(&global_config, 0, sizeof(global_config));
    global_config.dscp_icmp = 0xff;
    memset(&global_flow_config, 0, sizeof(global_flow_config));
}

/* Helper: parse a line from rule file (like original map.c) */
static void idclass_map_parse_line(char *str) {
    const char *key, *value;
    uint8_t dscp;
    bool only_cname = false;

    str = str_skip(str, true);
    key = str;
    str = str_skip(str, false);
    if (!*str)
        return;
    *(str++) = 0;
    str = str_skip(str, true);
    value = str;

    if (idclass_map_dscp_value(value, &dscp))
        return;

    if (!strncmp(key, "dns:", 4)) {
        map_manager_set_entry(CL_MAP_DNS, true, key + 4, dscp, false);
    } else if (!strncmp(key, "dns_c:", 6)) {
        map_manager_set_entry(CL_MAP_DNS, true, key + 6, dscp, true);
    } else if (!strncmp(key, "dns_q:", 6)) {
        map_manager_set_entry(CL_MAP_DNS, true, key + 6, dscp, false);
    } else if (!strncmp(key, "tcp:", 4)) {
        map_manager_set_entry(CL_MAP_TCP_PORTS, true, key + 4, dscp, false);
    } else if (!strncmp(key, "udp:", 4)) {
        map_manager_set_entry(CL_MAP_UDP_PORTS, true, key + 4, dscp, false);
    } else if (strchr(key, ':')) {
        map_manager_set_entry(CL_MAP_IPV6_ADDR, true, key, dscp, false);
    } else if (strchr(key, '.')) {
        map_manager_set_entry(CL_MAP_IPV4_ADDR, true, key, dscp, false);
    }
}

/* External: load a file containing rules */
int map_manager_load_file(const char *file) {
    struct idclass_map_file *f;
    FILE *fp;
    char line[1024];
    char *cur;

    if (!file)
        return 0;

    f = calloc(1, sizeof(*f) + strlen(file) + 1);
    if (!f) return -1;
    strcpy(f->filename, file);
    list_add_tail(&f->list, &map_files);

    fp = fopen(file, "r");
    if (!fp) {
        free(f);
        list_del(&f->list);
        return -1;
    }

    while (fgets(line, sizeof(line), fp)) {
        cur = strchr(line, '#');
        if (cur) *cur = 0;
        cur = line + strlen(line);
        while (cur > line && isspace(cur[-1])) cur--;
        *cur = 0;
        if (!*line) continue;

        idclass_map_parse_line(line);
    }
    fclose(fp);
    return 0;
}

/* External: clear all loaded files */
void map_manager_clear_files(void) {
    struct idclass_map_file *f, *tmp;
    list_for_each_entry_safe(f, tmp, &map_files, list) {
        list_del(&f->list);
        free(f);
    }
}

/* External: reload all file-based entries */
void map_manager_reload_files(void) {
    struct idclass_map_file *f;
    list_for_each_entry(f, &map_files, list) {
        FILE *fp = fopen(f->filename, "r");
        if (!fp) continue;
        char line[1024];
        while (fgets(line, sizeof(line), fp)) {
            char *cur = strchr(line, '#');
            if (cur) *cur = 0;
            cur = line + strlen(line);
            while (cur > line && isspace(cur[-1])) cur--;
            *cur = 0;
            if (!*line) continue;
            idclass_map_parse_line(line);
        }
        fclose(fp);
    }
    map_manager_gc();
    map_manager_set_dscp_default(CL_MAP_TCP_PORTS, 0xff);
    map_manager_set_dscp_default(CL_MAP_UDP_PORTS, 0xff);
}

/* Helper: free a map entry */
static void idclass_map_free_entry(struct idclass_map_entry *e) {
    int fd = map_manager_get_fd_internal(e->data.id);
    avl_delete(&map_data, &e->avl);
    if (e->data.id < CL_MAP_DNS)
        bpf_map_delete_elem(fd, &e->data.addr);
    free(e);
}

/* Helper: refresh timeout for active IP entries */
static bool idclass_map_entry_refresh_timeout(struct idclass_map_entry *e) {
    struct idclass_ip_map_val val;
    int fd = map_manager_get_fd_internal(e->data.id);

    if (e->data.id != CL_MAP_IPV4_ADDR && e->data.id != CL_MAP_IPV6_ADDR)
        return false;
    if (bpf_map_lookup_elem(fd, &e->data.addr, &val) != 0)
        return false;
    if (!val.seen)
        return false;
    e->timeout = idclass_gettime() + idclass_active_timeout;
    val.seen = 0;
    bpf_map_update_elem(fd, &e->data.addr, &val, BPF_ANY);
    return true;
}

/* External: garbage collect expired map entries */
void map_manager_gc(void) {
    struct idclass_map_entry *e, *tmp;
    int32_t timeout = 0;
    uint32_t cur_time = idclass_gettime();

    next_timeout = 0;
    avl_for_each_element_safe(&map_data, e, avl, tmp) {
        int32_t cur_timeout;

        if (e->data.user && e->timeout != ~0) {
            cur_timeout = e->timeout - cur_time;
            if (cur_timeout <= 0 &&
                idclass_map_entry_refresh_timeout(e))
                cur_timeout = e->timeout - cur_time;
            if (cur_timeout <= 0) {
                e->data.user = false;
                e->data.dscp = e->data.file_dscp;
            } else if (!timeout || cur_timeout < timeout) {
                timeout = cur_timeout;
                next_timeout = e->timeout;
            }
        }
        if (e->data.file || e->data.user)
            continue;
        idclass_map_free_entry(e);
    }
    if (!timeout)
        return;
    uloop_timeout_set(&idclass_map_timer, timeout * 1000);
}

/* External: dump map entries to blob */
void map_manager_dump(struct blob_buf *b) {
    struct idclass_map_entry *e;
    uint32_t cur_time = idclass_gettime();
    int buf_len = INET6_ADDRSTRLEN + 1;
    char *buf;
    void *a;
    int af;

    a = blobmsg_open_array(b, "entries");
    avl_for_each_element(&map_data, e, avl) {
        void *c;
        if (!e->data.file && !e->data.user)
            continue;

        c = blobmsg_open_table(b, NULL);
        if (e->data.user && e->timeout != ~0) {
            int32_t cur_timeout = e->timeout - cur_time;
            if (cur_timeout < 0) cur_timeout = 0;
            blobmsg_add_u32(b, "timeout", cur_timeout);
        }
        blobmsg_add_u8(b, "file", e->data.file);
        blobmsg_add_u8(b, "user", e->data.user);
        // dscp string omitted for brevity
        blobmsg_add_string(b, "type", "unknown");

        switch (e->data.id) {
        case CL_MAP_TCP_PORTS:
        case CL_MAP_UDP_PORTS:
            blobmsg_printf(b, "addr", "%d", ntohs(e->data.addr.port));
            break;
        case CL_MAP_IPV4_ADDR:
        case CL_MAP_IPV6_ADDR:
            buf = blobmsg_alloc_string_buffer(b, "addr", buf_len);
            af = (e->data.id == CL_MAP_IPV6_ADDR) ? AF_INET6 : AF_INET;
            inet_ntop(af, &e->data.addr, buf, buf_len);
            blobmsg_add_string_buffer(b);
            break;
        case CL_MAP_DNS:
            blobmsg_add_string(b, "addr", e->data.addr.dns.pattern);
            break;
        default:
            break;
        }
        blobmsg_close_table(b, c);
    }
    blobmsg_close_array(b, a);
}

/* External: get statistics (packet counts) per class */
void map_manager_stats(struct blob_buf *b, bool reset) {
    struct idclass_class data;
    uint32_t i;

    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        void *c;
        if (!map_class[i])
            continue;
        if (bpf_map_lookup_elem(map_manager_get_fd_internal(CL_MAP_CLASS), &i, &data) != 0)
            continue;
        c = blobmsg_open_table(b, map_class[i]->name);
        blobmsg_add_u64(b, "packets", data.packets);
        blobmsg_close_table(b, c);
        if (!reset)
            continue;
        data.packets = 0;
        bpf_map_update_elem(map_manager_get_fd_internal(CL_MAP_CLASS), &i, &data, BPF_ANY);
    }
}

/* External: update global config to BPF map */
void map_manager_update_config(void) {
    int fd = map_manager_get_fd_internal(CL_MAP_GLOBAL_CONFIG);
    uint32_t key = 0;
    bpf_map_update_elem(fd, &key, &global_config, BPF_ANY);
}

/* Helper: get class ID by name */
static int32_t idclass_map_get_class_id(const char *name) {
    int i;
    for (i = 0; i < ARRAY_SIZE(map_class); i++)
        if (map_class[i] && !strcmp(map_class[i]->name, name))
            return i;
    for (i = 0; i < ARRAY_SIZE(map_class); i++)
        if (!map_class[i])
            return i;
    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        if (!(map_class[i]->data.flags & IDCLASS_CLASS_FLAG_PRESENT)) {
            free(map_class[i]);
            map_class[i] = NULL;
            return i;
        }
    }
    return -1;
}

/* Helper: create a class entry from blob */
static int idclass_map_create_class(struct blob_attr *attr) {
    struct idclass_class_entry *class;
    enum {
        MAP_CLASS_INGRESS,
        MAP_CLASS_EGRESS,
        __MAP_CLASS_MAX
    };
    static const struct blobmsg_policy policy[__MAP_CLASS_MAX] = {
        [MAP_CLASS_INGRESS] = { "ingress", BLOBMSG_TYPE_STRING },
        [MAP_CLASS_EGRESS] = { "egress", BLOBMSG_TYPE_STRING },
    };
    struct blob_attr *tb[__MAP_CLASS_MAX];
    const char *name;
    char *name_buf;
    int32_t slot;

    blobmsg_parse(policy, __MAP_CLASS_MAX, tb,
                  blobmsg_data(attr), blobmsg_len(attr));

    if (!tb[MAP_CLASS_INGRESS] || !tb[MAP_CLASS_EGRESS])
        return -1;

    name = blobmsg_name(attr);
    slot = idclass_map_get_class_id(name);
    if (slot < 0)
        return -1;

    class = map_class[slot];
    if (!class) {
        class = calloc_a(sizeof(*class), &name_buf, strlen(name) + 1);
        if (!class) return -1;
        class->name = strcpy(name_buf, name);
        map_class[slot] = class;
    }

    class->data.flags |= IDCLASS_CLASS_FLAG_PRESENT;
    if (idclass_map_dscp_value(blobmsg_get_string(tb[MAP_CLASS_INGRESS]),
                                &class->data.val.ingress) ||
        idclass_map_dscp_value(blobmsg_get_string(tb[MAP_CLASS_EGRESS]),
                                &class->data.val.egress)) {
        map_class[slot] = NULL;
        free(class);
        return -1;
    }

    class->data.config = global_flow_config;
    return 0;
}

/* Helper: update IP mappings when class IDs change */
static void map_manager_update_ip_mappings(void) {
    int fd_v4 = map_manager_get_fd_internal(CL_MAP_IPV4_ADDR);
    int fd_v6 = map_manager_get_fd_internal(CL_MAP_IPV6_ADDR);
    struct in_addr key4;
    struct in6_addr key6;
    struct idclass_ip_map_val val;
    uint32_t next_key[4] = {0};
    uint32_t cur_key[4] = {0};
    int i;

    // Build class name -> new ID mapping
    int class_name_to_id[IDCLASS_MAX_CLASS_ENTRIES];
    memset(class_name_to_id, -1, sizeof(class_name_to_id));
    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        if (map_class[i] && (map_class[i]->data.flags & IDCLASS_CLASS_FLAG_PRESENT)) {
            class_name_to_id[i] = i; // store index as new ID
        }
    }

    // Update IPv4 map
    memset(&cur_key, 0, sizeof(cur_key));
    while (bpf_map_get_next_key(fd_v4, &cur_key, &key4) == 0) {
        if (bpf_map_lookup_elem(fd_v4, &key4, &val) == 0) {
            if (val.dscp & IDCLASS_DSCP_CLASS_FLAG) {
                uint8_t old_class_id = val.dscp & IDCLASS_DSCP_VALUE_MASK;
                // Find the class name for old_class_id
                const char *class_name = NULL;
                if (old_class_id < ARRAY_SIZE(map_class) && map_class[old_class_id]) {
                    class_name = map_class[old_class_id]->name;
                }
                if (class_name) {
                    // Find new ID for this class name
                    int new_id = -1;
                    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
                        if (map_class[i] && !strcmp(map_class[i]->name, class_name)) {
                            new_id = i;
                            break;
                        }
                    }
                    if (new_id >= 0 && new_id != old_class_id) {
                        val.dscp = (val.dscp & ~IDCLASS_DSCP_VALUE_MASK) | new_id;
                        bpf_map_update_elem(fd_v4, &key4, &val, BPF_ANY);
                    }
                }
            }
        }
        cur_key[0] = key4.s_addr;
    }

    // Update IPv6 map
    memset(&cur_key, 0, sizeof(cur_key));
    while (bpf_map_get_next_key(fd_v6, &cur_key, &key6) == 0) {
        if (bpf_map_lookup_elem(fd_v6, &key6, &val) == 0) {
            if (val.dscp & IDCLASS_DSCP_CLASS_FLAG) {
                uint8_t old_class_id = val.dscp & IDCLASS_DSCP_VALUE_MASK;
                const char *class_name = NULL;
                if (old_class_id < ARRAY_SIZE(map_class) && map_class[old_class_id]) {
                    class_name = map_class[old_class_id]->name;
                }
                if (class_name) {
                    int new_id = -1;
                    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
                        if (map_class[i] && !strcmp(map_class[i]->name, class_name)) {
                            new_id = i;
                            break;
                        }
                    }
                    if (new_id >= 0 && new_id != old_class_id) {
                        val.dscp = (val.dscp & ~IDCLASS_DSCP_VALUE_MASK) | new_id;
                        bpf_map_update_elem(fd_v6, &key6, &val, BPF_ANY);
                    }
                }
            }
        }
        memcpy(&cur_key, &key6, sizeof(key6));
    }
}

/* External: set class map from blob (called by config module) */
void map_manager_set_classes(struct blob_attr *val) {
    int fd = map_manager_get_fd_internal(CL_MAP_CLASS);
    struct idclass_class empty_data = {};
    struct blob_attr *cur;
    int32_t i;
    int rem;

    for (i = 0; i < ARRAY_SIZE(map_class); i++)
        if (map_class[i])
            map_class[i]->data.flags &= ~IDCLASS_CLASS_FLAG_PRESENT;

    blobmsg_for_each_attr(cur, val, rem)
        idclass_map_create_class(cur);

    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        if (map_class[i] &&
            (map_class[i]->data.flags & IDCLASS_CLASS_FLAG_PRESENT))
            continue;
        free(map_class[i]);
        map_class[i] = NULL;
    }

    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        struct idclass_class *data;
        data = map_class[i] ? &map_class[i]->data : &empty_data;
        bpf_map_update_elem(fd, &i, data, BPF_ANY);
    }

    // Update IP mappings to reflect class ID changes
    map_manager_update_ip_mappings();
}

/* External: synchronize flow config to all classes */
void map_manager_sync_class_config(void) {
    int fd = map_manager_get_fd_internal(CL_MAP_CLASS);
    uint32_t key = 0, next;
    struct idclass_class class;

    while (bpf_map_get_next_key(fd, &key, &next) == 0) {
        if (bpf_map_lookup_elem(fd, &next, &class) == 0) {
            memcpy(&class.config, &global_flow_config, sizeof(global_flow_config));
            bpf_map_update_elem(fd, &next, &class, BPF_EXIST);
        }
        key = next;
    }
}

/* External: lookup DNS entry by hostname */
int map_manager_lookup_dns_entry(char *host, bool cname, uint8_t *dscp, uint32_t *seq) {
    struct idclass_map_data data = {
        .id = CL_MAP_DNS,
        .addr.dns.pattern = "",
    };
    struct idclass_map_entry *e;
    int ret = -1;
    char *c;

    e = avl_find_ge_element(&map_data, &data, e, avl);
    if (!e)
        return -1;
    for (c = host; *c; c++)
        *c = tolower(*c);
    avl_for_element_to_last(&map_data, e, e, avl) {
        regex_t *regex = &e->data.addr.dns.regex;

        if (e->data.id != CL_MAP_DNS)
            break;
        if (!cname && e->data.addr.dns.only_cname)
            continue;
        if (e->data.addr.dns.pattern[0] == '/') {
            if (regexec(regex, host, 0, NULL, 0) != 0)
                continue;
        } else {
            if (fnmatch(e->data.addr.dns.pattern, host, 0))
                continue;
        }
        if (*dscp == 0xff || e->data.addr.dns.seq < *seq) {
            *dscp = e->data.dscp;
            *seq = e->data.addr.dns.seq;
        }
        ret = 0;
    }
    return ret;
}

/* Helper: get class name by DSCP */
static const char *idclass_dscp_to_class_name(uint8_t dscp) {
    int i;
    if (!(dscp & IDCLASS_DSCP_CLASS_FLAG))
        return NULL;
    uint8_t class_id = dscp & IDCLASS_DSCP_VALUE_MASK;
    if (class_id < ARRAY_SIZE(map_class) && map_class[class_id])
        return map_class[class_id]->name;
    return NULL;
}

/* External: add IP address to nftables sets */
void map_manager_add_ip_to_nft_sets(const void *addr, int family, uint32_t ttl, uint8_t dscp) {
    char ip_str[INET6_ADDRSTRLEN];
    const char *class_name;
    char cmd[512];
    int ret;

    if (inet_ntop(family, addr, ip_str, sizeof(ip_str)) == NULL) {
        ULOG_ERR("inet_ntop failed\n");
        return;
    }

    class_name = idclass_dscp_to_class_name(dscp);
    if (!class_name) {
        ULOG_WARN("Cannot find class name for DSCP 0x%02x, skipping nft add\n", dscp);
        return;
    }

    snprintf(cmd, sizeof(cmd),
             "nft add element inet gargoyle-qos-priority upload_%s { %s timeout %ds } 2>/dev/null",
             class_name, ip_str, ttl);
    ret = system(cmd);
    if (ret != 0) {
        ULOG_WARN("Failed to add to upload set: %s\n", cmd);
    }

    snprintf(cmd, sizeof(cmd),
             "nft add element inet gargoyle-qos-priority download_%s { %s timeout %ds } 2>/dev/null",
             class_name, ip_str, ttl);
    ret = system(cmd);
    if (ret != 0) {
        ULOG_WARN("Failed to add to download set: %s\n", cmd);
    }
}

/* External: add DNS host mapping (from ubus or dnsmasq) */
int map_manager_add_dns_host(char *host, const char *addr, const char *type, int ttl) {
    struct idclass_map_data data = { .dscp = 0xff };
    int prev_timeout = idclass_map_timeout;
    uint32_t lookup_seq = 0;

    /* Only used to get DSCP if host is given */
    if (host && map_manager_lookup_dns_entry(host, false, &data.dscp, &lookup_seq) != 0)
        return 0; /* no DSCP found, ignore */

    data.user = true;
    if (!strcmp(type, "A"))
        data.id = CL_MAP_IPV4_ADDR;
    else if (!strcmp(type, "AAAA"))
        data.id = CL_MAP_IPV6_ADDR;
    else
        return 0;

    if (inet_pton((data.id == CL_MAP_IPV6_ADDR) ? AF_INET6 : AF_INET, addr, &data.addr) != 1)
        return -1;

    if (ttl)
        idclass_map_timeout = ttl;
    map_manager_set_entry_data(&data);
    idclass_map_timeout = prev_timeout;
    return 0;
}

/* Helper: update ip_conn_map from flow_stats_map (periodic) */
static void idclass_update_ip_conn(struct uloop_timeout *t) {
    __u32 key = 0, next_key;
    struct flow_stats stats;
    __u32 cur_time = idclass_gettime();
    int fd = ip_conn_fd;
    struct ip_key {
        __u8 addr[16];
    } cur_key = {0}, next_key_ip;

    // Clear ip_conn_map
    while (bpf_map_get_next_key(fd, &cur_key, &next_key_ip) == 0) {
        bpf_map_delete_elem(fd, &next_key_ip);
        cur_key = next_key_ip;
    }

    // Scan flow_stats_map
    key = 0;
    while (bpf_map_get_next_key(flow_stats_fd, &key, &next_key) == 0) {
        if (bpf_map_lookup_elem(flow_stats_fd, &next_key, &stats) == 0) {
            __u64 last_seen_sec = stats.last_seen / 1000000000ULL;
            if (cur_time - last_seen_sec <= idclass_active_timeout) {
                if (stats.client_ip[0] != 0 || stats.client_ip[1] != 0) {
                    struct ip_key ipkey;
                    memcpy(ipkey.addr, stats.client_ip, 16);
                    uint32_t cnt_val;
                    if (bpf_map_lookup_elem(fd, &ipkey, &cnt_val) == 0) {
                        uint32_t new_cnt = cnt_val + 1;
                        bpf_map_update_elem(fd, &ipkey, &new_cnt, BPF_EXIST);
                    } else {
                        uint32_t one = 1;
                        bpf_map_update_elem(fd, &ipkey, &one, BPF_NOEXIST);
                    }
                }
            }
        }
        key = next_key;
    }
    uloop_timeout_set(t, 1000);
}

/* External: initialize map manager */
int map_manager_init(void) {
    int i;
    for (i = 0; i < __CL_MAP_MAX; i++)
        idclass_map_fds[i] = -1;

    for (i = 0; i < __CL_MAP_MAX; i++) {
        if (map_manager_get_fd_internal(i) < 0)
            return -1;
    }

    idclass_map_clear_list(CL_MAP_IPV4_ADDR);
    idclass_map_clear_list(CL_MAP_IPV6_ADDR);
    map_manager_reset_config();

    flow_stats_fd = bpf_obj_get("/sys/fs/bpf/idclass_data/flow_stats_map");
    if (flow_stats_fd < 0) {
        fprintf(stderr, "Failed to open flow_stats_map\n");
        return -1;
    }
    ip_conn_fd = map_manager_get_fd_internal(CL_MAP_IP_CONN);
    ip_conn_timer.cb = idclass_update_ip_conn;
    uloop_timeout_set(&ip_conn_timer, 1000);

    return 0;
}