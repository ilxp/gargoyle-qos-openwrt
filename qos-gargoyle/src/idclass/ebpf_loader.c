// SPDX-License-Identifier: GPL-2.0+
/*
 * ebpf_loader.c - eBPF program loader module
 * Loads two programs (ingress and egress) sharing the same maps.
 */
#include "common.h"
#include "idclass-bpf.h"   // 确保 IDCLASS_INGRESS 定义可见

/* fallback 定义，以防头文件未正确包含 */
#ifndef IDCLASS_INGRESS
#define IDCLASS_INGRESS (1 << 0)
#endif

#include <sys/resource.h>
#include <glob.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#define CLASSIFY_PROG_PATH   "/lib/bpf/idclass-bpf.o"
#define CLASSIFY_PIN_PATH    "/sys/fs/bpf/idclass"
#define CLASSIFY_DATA_PATH   "/sys/fs/bpf/idclass_data"

/* 程序变体信息 */
struct prog_info {
    const char *suffix;
    uint32_t flags;
    int fd;
};

static struct prog_info progs[] = {
    { "egress",  0, -1 },
    { "ingress", IDCLASS_INGRESS, -1 },
};

static void idclass_init_env(void) {
    struct rlimit limit = { RLIM_INFINITY, RLIM_INFINITY };
    setrlimit(RLIMIT_MEMLOCK, &limit);
}

/* 设置 .rodata 中的 module_flags */
static void idclass_fill_rodata(struct bpf_object *obj, uint32_t flags) {
    struct bpf_map *map = NULL;
    while ((map = bpf_object__next_map(obj, map)) != NULL) {
        if (!strstr(bpf_map__name(map), ".rodata"))
            continue;
        bpf_map__set_initial_value(map, &flags, sizeof(flags));
    }
}

/* 加载单个程序变体，重用已固定的 maps */
static int idclass_create_program(const struct prog_info *info, bool first) {
    DECLARE_LIBBPF_OPTS(bpf_object_open_opts, opts, .pin_root_path = CLASSIFY_DATA_PATH);
    struct bpf_program *prog;
    struct bpf_object *obj;
    char path[256];
    int err;

    snprintf(path, sizeof(path), CLASSIFY_PIN_PATH "_%s", info->suffix);

    obj = bpf_object__open_file(CLASSIFY_PROG_PATH, &opts);
    err = libbpf_get_error(obj);
    if (err) {
        fprintf(stderr, "bpf_object__open_file failed: %s\n", strerror(-err));
        return -1;
    }

    prog = bpf_object__find_program_by_name(obj, "classify");
    if (!prog) {
        fprintf(stderr, "Can't find classify prog\n");
        bpf_object__close(obj);
        return -1;
    }

    bpf_program__set_type(prog, BPF_PROG_TYPE_SCHED_CLS);
    idclass_fill_rodata(obj, info->flags);

    /* 如果不是第一个程序，重用已固定的 maps */
    if (!first) {
        struct bpf_map *map;
        bpf_object__for_each_map(map, obj) {
            const char *map_name = bpf_map__name(map);
            char map_path[256];
            snprintf(map_path, sizeof(map_path), "%s/%s", CLASSIFY_DATA_PATH, map_name);
            int reuse_fd = bpf_obj_get(map_path);
            if (reuse_fd < 0) {
                fprintf(stderr, "Failed to get pinned map %s: %s\n", map_path, strerror(errno));
                bpf_object__close(obj);
                return -1;
            }
            err = bpf_map__reuse_fd(map, reuse_fd);
            if (err) {
                fprintf(stderr, "Failed to reuse map %s: %s\n", map_name, strerror(-err));
                close(reuse_fd);
                bpf_object__close(obj);
                return -1;
            }
            close(reuse_fd);
        }
    }

    err = bpf_object__load(obj);
    if (err) {
        fprintf(stderr, "bpf_object__load failed: %s\n", strerror(-err));
        bpf_object__close(obj);
        return -1;
    }

    /* 第一个程序固定 maps */
    if (first) {
        err = bpf_object__pin_maps(obj, CLASSIFY_DATA_PATH);
        if (err) {
            fprintf(stderr, "Failed to pin maps: %s\n", strerror(-err));
            bpf_object__close(obj);
            return -1;
        }
    }

    /* 固定程序本身 */
    unlink(path);
    err = bpf_program__pin(prog, path);
    if (err) {
        fprintf(stderr, "Failed to pin program to %s: %s\n", path, strerror(-err));
        bpf_object__close(obj);
        return -1;
    }

    int fd = bpf_obj_get(path);
    if (fd < 0) {
        fprintf(stderr, "Failed to get pinned program fd %s: %s\n", path, strerror(errno));
        bpf_object__close(obj);
        return -1;
    }
    ((struct prog_info *)info)->fd = fd;

    bpf_object__close(obj);
    return 0;
}

int ebpf_loader_init(void) {
    glob_t g;
    int i;

    /* 清理旧文件 */
    if (glob(CLASSIFY_DATA_PATH "/*", 0, NULL, &g) == 0) {
        for (i = 0; i < g.gl_pathc; i++)
            unlink(g.gl_pathv[i]);
        globfree(&g);
    }
    for (i = 0; i < ARRAY_SIZE(progs); i++) {
        char path[256];
        snprintf(path, sizeof(path), CLASSIFY_PIN_PATH "_%s", progs[i].suffix);
        unlink(path);
    }

    idclass_init_env();

    /* 加载所有程序变体，第一个程序负责固定 maps */
    for (i = 0; i < ARRAY_SIZE(progs); i++) {
        if (idclass_create_program(&progs[i], i == 0))
            return -1;
    }

    return 0;
}

const char *ebpf_loader_get_program(uint32_t flags, int *fd) {
    for (int i = 0; i < ARRAY_SIZE(progs); i++) {
        if (progs[i].flags == flags && progs[i].fd >= 0) {
            *fd = progs[i].fd;
            return progs[i].suffix;
        }
    }
    return NULL;
}