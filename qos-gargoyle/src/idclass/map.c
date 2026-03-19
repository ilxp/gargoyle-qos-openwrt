// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 * Modified to support multi-feature classification (idclass)
 */
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <ctype.h>
#include <stdlib.h>
#include <time.h>
#include <fnmatch.h>
#include <glob.h>
#include <libubox/uloop.h>
#include <libubox/avl-cmp.h>
#include <bpf/bpf.h>
#include <uci.h>
#include "idclass.h"

static int idclass_map_fds[__CL_MAP_MAX];
static AVL_TREE(map_data, idclass_map_entry_cmp, false, NULL);
static LIST_HEAD(map_files);
static struct idclass_class *map_class[IDCLASS_MAX_CLASS_ENTRIES];
static uint32_t next_timeout;
static uint8_t idclass_dscp_default[2] = { 0xff, 0xff };
int idclass_map_timeout = 3600;
int idclass_active_timeout = 300;
struct idclass_global_config global_config;
struct idclass_flow_config global_flow_config;
static uint32_t map_dns_seq;

struct uloop_timeout idclass_map_timer;

/* 动态 UCI 配置名 */
static const char *uci_config_name = "qos_gargoyle";

void idclass_set_config_name(const char *name)
{
	uci_config_name = name;
}

const struct {
	const char *name;
	const char *type_name;
} idclass_map_info[] = {
	[CL_MAP_TCP_PORTS] = { "tcp_ports", "tcp_port" },
	[CL_MAP_UDP_PORTS] = { "udp_ports", "udp_port" },
	[CL_MAP_IPV4_ADDR] = { "ipv4_map", "ipv4_addr" },
	[CL_MAP_IPV6_ADDR] = { "ipv6_map", "ipv6_addr" },
	[CL_MAP_CLASS] = { "class_map", "class" },
	[CL_MAP_GLOBAL_CONFIG] = { "global_config", "config" },
	[CL_MAP_DNS] = { "dns", "dns" },
	[CL_MAP_PRIO_CLASS_UP] = { "prio_class_up", "prio_class_up" },
	[CL_MAP_PRIO_CLASS_DOWN] = { "prio_class_down", "prio_class_down" },
	[CL_MAP_CLASS_MARK] = { "class_mark", "class_mark" },
};

static const struct {
	const char name[5];
	uint8_t val;
} codepoints[] = {
	{ "CS0", 0 }, { "CS1", 8 }, { "CS2", 16 }, { "CS3", 24 },
	{ "CS4", 32 }, { "CS5", 40 }, { "CS6", 48 }, { "CS7", 56 },
	{ "AF11", 10 }, { "AF12", 12 }, { "AF13", 14 },
	{ "AF21", 18 }, { "AF22", 20 }, { "AF23", 22 },
	{ "AF31", 26 }, { "AF32", 28 }, { "AF33", 30 },
	{ "AF41", 34 }, { "AF42", 36 }, { "AF43", 38 },
	{ "EF", 46 }, { "VA", 44 }, { "LE", 1 }, { "DF", 0 },
};

char *str_skip(char *str, bool space)
{
	while (*str && isspace(*str) == space)
		str++;
	return str;
}

int idclass_map_codepoint(const char *val)
{
	int i;
	for (i = 0; i < ARRAY_SIZE(codepoints); i++)
		if (!strcmp(codepoints[i].name, val))
			return codepoints[i].val;
	return 0xff;
}

static int read_float_mult100(const char *val)
{
	double d = atof(val);
	return (int)(d * 100 + 0.5);
}

static int idclass_map_entry_cmp(const void *k1, const void *k2, void *ptr)
{
    const struct idclass_map_data *d1 = k1;
    const struct idclass_map_data *d2 = k2;

    if (d1->id != d2->id)
        return d2->id - d1->id;
    if (d1->id == CL_MAP_DNS)
        return strcmp(d1->addr.dns.pattern, d2->addr.dns.pattern);
    return memcmp(&d1->addr, &d2->addr, sizeof(d1->addr));
}

static uint32_t idclass_gettime(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

static const char *idclass_map_path(enum idclass_map_id id)
{
    static char path[128];
    const char *name;

    if (id >= ARRAY_SIZE(idclass_map_info))
        return NULL;
    name = idclass_map_info[id].name;
    if (!name)
        return NULL;
    snprintf(path, sizeof(path), "%s/%s", CLASSIFY_DATA_PATH, name);
    return path;
}

int idclass_map_get_fd(enum idclass_map_id id)
{
    const char *path = idclass_map_path(id);
    int fd;

    if (!path)
        return -1;
    fd = bpf_obj_get(path);
    if (fd < 0)
        fprintf(stderr, "Failed to open map %s: %s\n", path, strerror(errno));
    return fd;
}

static void idclass_map_clear_list(enum idclass_map_id id)
{
    int fd = idclass_map_fds[id];
    __u32 key[4] = {};

    while (bpf_map_get_next_key(fd, &key, &key) == 0)
        bpf_map_delete_elem(fd, &key);
}

static void __idclass_map_set_dscp_default(enum idclass_map_id id, uint8_t val)
{
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
        fd = idclass_map_fds[CL_MAP_CLASS];
        memcpy(&class.config, &global_flow_config, sizeof(class.config));
        bpf_map_update_elem(fd, &key, &class, BPF_ANY);
        val = key | IDCLASS_DSCP_CLASS_FLAG;
    }

    fd = idclass_map_fds[id];
    for (i = 0; i < (1 << 16); i++) {
        data.addr.port = htons(i);
        if (avl_find(&map_data, &data))
            continue;
        bpf_map_update_elem(fd, &data.addr, &val, BPF_ANY);
    }
}

void idclass_map_set_dscp_default(enum idclass_map_id id, uint8_t val)
{
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

static struct idclass_map_entry *
__idclass_map_alloc_entry(struct idclass_map_data *data)
{
    struct idclass_map_entry *e;
    char *pattern;
    char *c;

    if (data->id < CL_MAP_DNS) {
        e = calloc(1, sizeof(*e));
        memcpy(&e->data.addr, &data->addr, sizeof(e->data.addr));
        return e;
    }

    e = calloc_a(sizeof(*e), &pattern, strlen(data->addr.dns.pattern) + 1);
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

void __idclass_map_set_entry(struct idclass_map_data *data)
{
    int fd = idclass_map_fds[data->id];
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

static int idclass_map_set_port(struct idclass_map_data *data, const char *str)
{
    unsigned long start_port, end_port;
    char *err;
    int i;

    start_port = end_port = strtoul(str, &err, 0);
    if (err && *err) {
        if (*err == '-')
            end_port = strtoul(err + 1, &err, 0);
        if (*err)
            return -1;
    }
    if (!start_port || end_port < start_port || end_port >= 65535)
        return -1;
    for (i = start_port; i <= end_port; i++) {
        data->addr.port = htons(i);
        __idclass_map_set_entry(data);
    }
    return 0;
}

static int idclass_map_fill_ip(struct idclass_map_data *data, const char *str)
{
    int af;

    if (data->id == CL_MAP_IPV6_ADDR)
        af = AF_INET6;
    else
        af = AF_INET;

    if (inet_pton(af, str, &data->addr) != 1)
        return -1;
    return 0;
}

int idclass_map_set_entry(enum idclass_map_id id, bool file, const char *str,
                         uint8_t dscp)
{
    struct idclass_map_data data = {
        .id = id,
        .file = file,
        .dscp = dscp,
    };

    switch (id) {
    case CL_MAP_DNS:
        data.addr.dns.pattern = str;
        if (str[-2] == 'c')
            data.addr.dns.only_cname = 1;
        break;
    case CL_MAP_TCP_PORTS:
    case CL_MAP_UDP_PORTS:
        return idclass_map_set_port(&data, str);
    case CL_MAP_IPV4_ADDR:
    case CL_MAP_IPV6_ADDR:
        if (idclass_map_fill_ip(&data, str))
            return -1;
        break;
    default:
        return -1;
    }
    __idclass_map_set_entry(&data);
    return 0;
}

static int __idclass_map_dscp_value(const char *val, uint8_t *dscp_val)
{
    unsigned long dscp;
    bool fallback = false;
    char *err;

    if (*val == '+') {
        fallback = true;
        val++;
    }
    dscp = strtoul(val, &err, 0);
    if (err && *err)
        dscp = idclass_map_codepoint(val);
    if (dscp >= 64)
        return -1;
    *dscp_val = dscp | (fallback << 6);
    return 0;
}

static int idclass_map_check_class(const char *val, uint8_t *dscp_val)
{
    int i;

    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        if (map_class[i] && !strcmp(val, map_class[i]->name)) {
            *dscp_val = i | IDCLASS_DSCP_CLASS_FLAG;
            return 0;
        }
    }
    return -1;
}

int idclass_map_dscp_value(const char *val, uint8_t *dscp_val)
{
    uint8_t fallback = 0;

    if (*val == '+') {
        fallback = IDCLASS_DSCP_FALLBACK_FLAG;
        val++;
    }
    if (idclass_map_check_class(val, dscp_val) &&
        __idclass_map_dscp_value(val, dscp_val))
            return -1;
    *dscp_val |= fallback;
    return 0;
}

static void idclass_map_dscp_codepoint_str(char *dest, int len, uint8_t dscp)
{
    int i;

    if (dscp & IDCLASS_DSCP_FALLBACK_FLAG) {
        *(dest++) = '+';
        len--;
        dscp &= ~IDCLASS_DSCP_FALLBACK_FLAG;
    }
    for (i = 0; i < ARRAY_SIZE(codepoints); i++) {
        if (codepoints[i].val != dscp)
            continue;
        snprintf(dest, len, "%s", codepoints[i].name);
        return;
    }
    snprintf(dest, len, "0x%x", dscp);
}

static void idclass_map_parse_line(char *str)
{
    const char *key, *value;
    uint8_t dscp;

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

    if (!strncmp(key, "dns:", 4))
        idclass_map_set_entry(CL_MAP_DNS, true, key + 4, dscp);
    if (!strncmp(key, "dns_q:", 6) || !strncmp(key, "dns_c:", 6))
        idclass_map_set_entry(CL_MAP_DNS, true, key + 6, dscp);
    if (!strncmp(key, "tcp:", 4))
        idclass_map_set_entry(CL_MAP_TCP_PORTS, true, key + 4, dscp);
    else if (!strncmp(key, "udp:", 4))
        idclass_map_set_entry(CL_MAP_UDP_PORTS, true, key + 4, dscp);
    else if (strchr(key, ':'))
        idclass_map_set_entry(CL_MAP_IPV6_ADDR, true, key, dscp);
    else if (strchr(key, '.'))
        idclass_map_set_entry(CL_MAP_IPV4_ADDR, true, key, dscp);
}

static void __idclass_map_load_file_data(FILE *f)
{
    char line[1024];
    char *cur;

    while (fgets(line, sizeof(line), f)) {
        cur = strchr(line, '#');
        if (cur)
            *cur = 0;
        cur = line + strlen(line);
        if (cur == line)
            continue;
        while (cur > line && isspace(cur[-1]))
            cur--;
        *cur = 0;
        idclass_map_parse_line(line);
    }
}

static int __idclass_map_load_file(const char *file)
{
    glob_t gl;
    FILE *f;
    int i;

    if (!file)
        return 0;
    glob(file, 0, NULL, &gl);
    for (i = 0; i < gl.gl_pathc; i++) {
        f = fopen(gl.gl_pathv[i], "r");
        if (!f)
            continue;
        __idclass_map_load_file_data(f);
        fclose(f);
    }
    globfree(&gl);
    return 0;
}

int idclass_map_load_file(const char *file)
{
    struct idclass_map_file *f;

    if (!file)
        return 0;
    f = calloc(1, sizeof(*f) + strlen(file) + 1);
    strcpy(f->filename, file);
    list_add_tail(&f->list, &map_files);
    return __idclass_map_load_file(file);
}

static void idclass_map_reset_file_entries(void)
{
    struct idclass_map_entry *e;

    map_dns_seq = 0;
    avl_for_each_element(&map_data, e, avl)
        e->data.file = false;
}

void idclass_map_clear_files(void)
{
    struct idclass_map_file *f, *tmp;

    idclass_map_reset_file_entries();
    list_for_each_entry_safe(f, tmp, &map_files, list) {
        list_del(&f->list);
        free(f);
    }
}

void idclass_map_reset_config(void)
{
    idclass_map_clear_files();
    idclass_map_set_dscp_default(CL_MAP_TCP_PORTS, 0);
    idclass_map_set_dscp_default(CL_MAP_UDP_PORTS, 0);
    idclass_map_timeout = 3600;
    idclass_active_timeout = 300;
    memset(&global_config, 0, sizeof(global_config));
    global_config.dscp_icmp = 0xff;
    memset(&global_flow_config, 0, sizeof(global_flow_config));
}

void idclass_map_reload(void)
{
    struct idclass_map_file *f;

    idclass_map_reset_file_entries();
    list_for_each_entry(f, &map_files, list)
        __idclass_map_load_file(f->filename);
    idclass_map_gc();
    idclass_map_set_dscp_default(CL_MAP_TCP_PORTS, 0xff);
    idclass_map_set_dscp_default(CL_MAP_UDP_PORTS, 0xff);
}

static void idclass_map_free_entry(struct idclass_map_entry *e)
{
    int fd = idclass_map_fds[e->data.id];

    avl_delete(&map_data, &e->avl);
    if (e->data.id < CL_MAP_DNS)
        bpf_map_delete_elem(fd, &e->data.addr);
    free(e);
}

static bool idclass_map_entry_refresh_timeout(struct idclass_map_entry *e)
{
    struct idclass_ip_map_val val;
    int fd = idclass_map_fds[e->data.id];

    if (e->data.id != CL_MAP_IPV4_ADDR && e->data.id != CL_MAP_IPV6_ADDR)
        return false;
    if (bpf_map_lookup_elem(fd, &e->data.addr, &val))
        return false;
    if (!val.seen)
        return false;
    e->timeout = idclass_gettime() + idclass_active_timeout;
    val.seen = 0;
    bpf_map_update_elem(fd, &e->data.addr, &val, BPF_ANY);
    return true;
}

void idclass_map_gc(void)
{
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

int idclass_map_lookup_dns_entry(char *host, bool cname, uint8_t *dscp, uint32_t *seq)
{
    struct idclass_map_data data = {
        .id = CL_MAP_DNS,
        .addr.dns.pattern = "",
    };
    struct idclass_map_entry *e;
    bool ret = -1;
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

int idclass_map_add_dns_host(char *host, const char *addr, const char *type, int ttl)
{
    struct idclass_map_data data = { .dscp = 0xff };
    int prev_timeout = idclass_map_timeout;
    uint32_t lookup_seq = 0;

    if (idclass_map_lookup_dns_entry(host, false, &data.dscp, &lookup_seq))
        return 0;
    data.user = true;
    if (!strcmp(type, "A"))
        data.id = CL_MAP_IPV4_ADDR;
    else if (!strcmp(type, "AAAA"))
        data.id = CL_MAP_IPV6_ADDR;
    else
        return 0;
    if (idclass_map_fill_ip(&data, addr))
        return -1;
    if (ttl)
        idclass_map_timeout = ttl;
    __idclass_map_set_entry(&data);
    idclass_map_timeout = prev_timeout;
    return 0;
}

static void blobmsg_add_dscp(struct blob_buf *b, const char *name, uint8_t dscp)
{
    int buf_len = 8;
    char *buf;

    if (dscp & IDCLASS_DSCP_CLASS_FLAG) {
        const char *val;
        int idx;

        idx = dscp & IDCLASS_DSCP_VALUE_MASK;
        if (map_class[idx])
            val = map_class[idx]->name;
        else
            val = "<invalid>";
        blobmsg_printf(b, name, "%s%s",
                       (dscp & IDCLASS_DSCP_FALLBACK_FLAG) ? "+" : "", val);
        return;
    }
    buf = blobmsg_alloc_string_buffer(b, name, buf_len);
    idclass_map_dscp_codepoint_str(buf, buf_len, dscp);
    blobmsg_add_string_buffer(b);
}

void idclass_map_dump(struct blob_buf *b)
{
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
            if (cur_timeout < 0)
                cur_timeout = 0;
            blobmsg_add_u32(b, "timeout", cur_timeout);
        }
        blobmsg_add_u8(b, "file", e->data.file);
        blobmsg_add_u8(b, "user", e->data.user);
        blobmsg_add_dscp(b, "dscp", e->data.dscp);
        blobmsg_add_string(b, "type", idclass_map_info[e->data.id].type_name);

        switch (e->data.id) {
        case CL_MAP_TCP_PORTS:
        case CL_MAP_UDP_PORTS:
            blobmsg_printf(b, "addr", "%d", ntohs(e->data.addr.port));
            break;
        case CL_MAP_IPV4_ADDR:
        case CL_MAP_IPV6_ADDR:
            buf = blobmsg_alloc_string_buffer(b, "addr", buf_len);
            af = e->data.id == CL_MAP_IPV6_ADDR ? AF_INET6 : AF_INET;
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

void idclass_map_stats(struct blob_buf *b, bool reset)
{
    struct idclass_class data;
    uint32_t i;

    for (i = 0; i < ARRAY_SIZE(map_class); i++) {
        void *c;

        if (!map_class[i])
            continue;
        if (bpf_map_lookup_elem(idclass_map_fds[CL_MAP_CLASS], &i, &data) < 0)
            continue;
        c = blobmsg_open_table(b, map_class[i]->name);
        blobmsg_add_u64(b, "packets", data.packets);
        blobmsg_close_table(b, c);
        if (!reset)
            continue;
        data.packets = 0;
        bpf_map_update_elem(idclass_map_fds[CL_MAP_CLASS], &i, &data, BPF_ANY);
    }
}

static int32_t idclass_map_get_class_id(const char *name)
{
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

int map_fill_dscp_value(uint8_t *dest, struct blob_attr *attr, bool reset)
{
    if (reset)
        *dest = 0xff;
    if (!attr)
        return 0;
    if (idclass_map_dscp_value(blobmsg_get_string(attr), dest))
        return -1;
    return 0;
}

int map_parse_flow_config(struct idclass_flow_config *cfg, struct blob_attr *attr, bool reset)
{
    enum {
        CL_CONFIG_BULK_TIMEOUT,
        CL_CONFIG_BULK_PPS,
        CL_CONFIG_PRIO_PKT_LEN,
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
        [CL_CONFIG_PRIO_REALTIME] = { "prio_realtime", BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_VIDEO]    = { "prio_video",    BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_NORMAL]   = { "prio_normal",   BLOBMSG_TYPE_INT32 },
        [CL_CONFIG_PRIO_BULK]     = { "prio_bulk",     BLOBMSG_TYPE_INT32 },
    };
    struct blob_attr *tb[__CL_CONFIG_MAX];
    struct blob_attr *cur;

    if (reset) {
        memset(cfg, 0, sizeof(*cfg));
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
    }

    blobmsg_parse(policy, __CL_CONFIG_MAX, tb, blobmsg_data(attr), blobmsg_len(attr));

#define READ_U32(name, field) do { \
    if ((cur = tb[name]) != NULL) cfg->field = blobmsg_get_u32(cur); \
} while (0)

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

#undef READ_U32

    if ((cur = tb[CL_CONFIG_UP_DOWN_RATIO_LOW]) != NULL)
        cfg->up_down_ratio_low = read_float_mult100(blobmsg_get_string(cur));
    if ((cur = tb[CL_CONFIG_UP_DOWN_RATIO_HIGH]) != NULL)
        cfg->up_down_ratio_high = read_float_mult100(blobmsg_get_string(cur));

    cfg->feature_mask = 0;
    if ((cur = tb[CL_CONFIG_ENABLE_PKTLEN]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 0);
    if ((cur = tb[CL_CONFIG_ENABLE_CONN_COUNT]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 1);
    if ((cur = tb[CL_CONFIG_ENABLE_PPS]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 2);
    if ((cur = tb[CL_CONFIG_ENABLE_IAT]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 3);
    if ((cur = tb[CL_CONFIG_ENABLE_RETRANS]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 4);
    if ((cur = tb[CL_CONFIG_ENABLE_TCP_FLAGS]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 5);
    if ((cur = tb[CL_CONFIG_ENABLE_CONN_DURATION]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 6);
    if ((cur = tb[CL_CONFIG_ENABLE_UP_DOWN_RATIO]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 7);
    if ((cur = tb[CL_CONFIG_ENABLE_BURST]) != NULL && blobmsg_get_bool(cur))
        cfg->feature_mask |= (1 << 8);

    return 0;
}

static int load_idclass_config(void)
{
    struct uci_context *uci;
    struct uci_package *pkg;
    struct uci_element *e;
    struct uci_section *s;
    struct blob_buf b = { 0 };

    uci = uci_alloc_context();
    if (!uci) return -1;
    if (uci_load(uci, uci_config_name, &pkg) != UCI_OK) {
        uci_free_context(uci);
        return -1;
    }

    uci_foreach_element(&pkg->sections, e) {
        s = uci_to_section(e);
        const char *type = uci_lookup_option_string(uci, s, "type") ?: s->type;
        if (!type || strcmp(type, "idclass") != 0)
            continue;

        const char *wan_iface = uci_lookup_option_string(uci, s, "wan_interface");
        if (wan_iface) global_config.wan_ifindex = if_nametoindex(wan_iface);
        const char *ifb_iface = uci_lookup_option_string(uci, s, "ifb_device");
        if (ifb_iface) global_config.ifb_ifindex = if_nametoindex(ifb_iface);

        const char *dscp_icmp = uci_lookup_option_string(uci, s, "dscp_icmp");
        if (dscp_icmp) idclass_map_dscp_value(dscp_icmp, &global_config.dscp_icmp);

        blob_buf_init(&b, 0);
        struct uci_element *opt;
        uci_foreach_element(&s->options, opt) {
            struct uci_option *o = uci_to_option(opt);
            if (o->type != UCI_TYPE_STRING) continue;
            blobmsg_add_string(&b, o->e.name, o->v.string);
        }
        map_parse_flow_config(&global_flow_config, b.head, true);
        blob_buf_free(&b);

        int fd = idclass_map_fds[CL_MAP_GLOBAL_CONFIG];
        if (fd >= 0) {
            uint32_t key = 0;
            bpf_map_update_elem(fd, &key, &global_config, 0);
        }
        break;
    }

    uci_unload(uci, pkg);
    uci_free_context(uci);
    return 0;
}

static int idclass_map_create_class(struct blob_attr *attr)
{
    struct idclass_class *class;
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
        class->name = strcpy(name_buf, name);
        map_class[slot] = class;
    }

    class->data.flags |= IDCLASS_CLASS_FLAG_PRESENT;
    if (__idclass_map_dscp_value(blobmsg_get_string(tb[MAP_CLASS_INGRESS]),
                                &class->data.val.ingress) ||
        __idclass_map_dscp_value(blobmsg_get_string(tb[MAP_CLASS_EGRESS]),
                                &class->data.val.egress)) {
        map_class[slot] = NULL;
        free(class);
        return -1;
    }

    class->data.config = global_flow_config;
    return 0;
}

void idclass_map_set_classes(struct blob_attr *val)
{
    int fd = idclass_map_fds[CL_MAP_CLASS];
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
}

void idclass_map_update_config(void)
{
    int fd = idclass_map_fds[CL_MAP_GLOBAL_CONFIG];
    uint32_t key = 0;
    bpf_map_update_elem(fd, &key, &global_config, BPF_ANY);
}

static int compare_priority(const void *a, const void *b)
{
    int pa = ((const struct class_prio *)a)->priority;
    int pb = ((const struct class_prio *)b)->priority;
    if (pa < pb) return -1;
    if (pa > pb) return 1;
    int ca = ((const struct class_prio *)a)->class_id;
    int cb = ((const struct class_prio *)b)->class_id;
    return ca - cb;
}

static void build_priority_maps(void)
{
    struct uci_context *uci;
    struct uci_package *pkg;
    struct uci_element *e;
    struct uci_section *s;
    struct class_prio {
        int class_id;
        int priority;
    } up[16], down[16];
    int up_cnt = 0, down_cnt = 0;

    uci = uci_alloc_context();
    if (!uci) return;
    if (uci_load(uci, uci_config_name, &pkg) != UCI_OK) {
        uci_free_context(uci);
        return;
    }

    uci_foreach_element(&pkg->sections, e) {
        s = uci_to_section(e);
        const char *type = uci_lookup_option_string(uci, s, "type") ?: s->type;
        if (!type) continue;

        int class_id = 0;
        if (strcmp(type, "upload_class") == 0) {
            if (sscanf(s->e.name, "uclass_%d", &class_id) != 1) continue;
        } else if (strcmp(type, "download_class") == 0) {
            if (sscanf(s->e.name, "dclass_%d", &class_id) != 1) continue;
        } else {
            continue;
        }

        const char *prio_str = uci_lookup_option_string(uci, s, "priority");
        int priority = prio_str ? atoi(prio_str) : 999;

        if (strcmp(type, "upload_class") == 0) {
            up[up_cnt].class_id = class_id;
            up[up_cnt].priority = priority;
            up_cnt++;
        } else {
            down[down_cnt].class_id = class_id;
            down[down_cnt].priority = priority;
            down_cnt++;
        }
    }

    uci_unload(uci, pkg);
    uci_free_context(uci);

    qsort(up, up_cnt, sizeof(up[0]), compare_priority);
    qsort(down, down_cnt, sizeof(down[0]), compare_priority);

    uint32_t log_prio[4] = {
        global_flow_config.prio_realtime,
        global_flow_config.prio_video,
        global_flow_config.prio_normal,
        global_flow_config.prio_bulk
    };

    uint32_t up_map[4], down_map[4];

    for (int i = 0; i < 4; i++) {
        int target_prio = log_prio[i];
        int best = -1;
        for (int j = 0; j < up_cnt; j++) {
            if (up[j].priority >= target_prio) {
                best = up[j].class_id;
                break;
            }
        }
        if (best == -1 && up_cnt > 0) best = up[up_cnt-1].class_id;
        up_map[i] = best;

        best = -1;
        for (int j = 0; j < down_cnt; j++) {
            if (down[j].priority >= target_prio) {
                best = down[j].class_id;
                break;
            }
        }
        if (best == -1 && down_cnt > 0) best = down[down_cnt-1].class_id;
        down_map[i] = best;
    }

    int fd_up = idclass_map_fds[CL_MAP_PRIO_CLASS_UP];
    if (fd_up >= 0) {
        for (int i = 0; i < 4; i++)
            bpf_map_update_elem(fd_up, &i, &up_map[i], 0);
    }
    int fd_down = idclass_map_fds[CL_MAP_PRIO_CLASS_DOWN];
    if (fd_down >= 0) {
        for (int i = 0; i < 4; i++)
            bpf_map_update_elem(fd_down, &i, &down_map[i], 0);
    }
}

static void load_class_marks_from_file(void)
{
    FILE *fp = fopen("/tmp/idclass_class_marks", "r");
    if (!fp) {
        fprintf(stderr, "Warning: cannot open /tmp/idclass_class_marks, marks may be missing\n");
        return;
    }

    int class_id;
    unsigned int mark;
    while (fscanf(fp, "%d:%u", &class_id, &mark) == 2) {
        int fd = idclass_map_fds[CL_MAP_CLASS_MARK];
        if (fd >= 0 && class_id >= 0 && class_id < IDCLASS_MAX_CLASS_ENTRIES)
            bpf_map_update_elem(fd, &class_id, &mark, 0);
    }
    fclose(fp);
}

int idclass_map_init(void)
{
    int i;

    for (i = 0; i < CL_MAP_DNS; i++) {
        idclass_map_fds[i] = idclass_map_get_fd(i);
        if (idclass_map_fds[i] < 0)
            return -1;
    }

    idclass_map_fds[CL_MAP_GLOBAL_CONFIG] = idclass_map_get_fd(CL_MAP_GLOBAL_CONFIG);
    if (idclass_map_fds[CL_MAP_GLOBAL_CONFIG] < 0)
        return -1;

    idclass_map_fds[CL_MAP_PRIO_CLASS_UP] = idclass_map_get_fd(CL_MAP_PRIO_CLASS_UP);
    if (idclass_map_fds[CL_MAP_PRIO_CLASS_UP] < 0)
        return -1;

    idclass_map_fds[CL_MAP_PRIO_CLASS_DOWN] = idclass_map_get_fd(CL_MAP_PRIO_CLASS_DOWN);
    if (idclass_map_fds[CL_MAP_PRIO_CLASS_DOWN] < 0)
        return -1;

    idclass_map_fds[CL_MAP_CLASS_MARK] = idclass_map_get_fd(CL_MAP_CLASS_MARK);
    if (idclass_map_fds[CL_MAP_CLASS_MARK] < 0)
        return -1;

    idclass_map_clear_list(CL_MAP_IPV4_ADDR);
    idclass_map_clear_list(CL_MAP_IPV6_ADDR);
    idclass_map_reset_config();

    load_idclass_config();
    load_class_marks_from_file();
    build_priority_maps();

    return 0;
}