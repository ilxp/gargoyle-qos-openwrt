// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 */
#include <sys/resource.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <glob.h>
#include <unistd.h>
#include <uci.h>

#include "idclass.h"

static struct {
	const char *suffix;
	uint32_t flags;
	int fd;
} bpf_progs[] = {
	{ "egress_eth",  0 },
	{ "egress_ip",   IDCLASS_IP_ONLY },
	{ "ingress_eth", IDCLASS_INGRESS },
	{ "ingress_ip",  IDCLASS_INGRESS | IDCLASS_IP_ONLY },
};

static int idclass_bpf_pr(enum libbpf_print_level level, const char *format,
		     va_list args)
{
	return vfprintf(stderr, format, args);
}

static void idclass_init_env(void)
{
	struct rlimit limit = {
		.rlim_cur = RLIM_INFINITY,
		.rlim_max = RLIM_INFINITY,
	};
	setrlimit(RLIMIT_MEMLOCK, &limit);
}

static void idclass_fill_rodata(struct bpf_object *obj, uint32_t flags)
{
	struct bpf_map *map = NULL;

	while ((map = bpf_object__next_map(obj, map)) != NULL) {
		if (!strstr(bpf_map__name(map), ".rodata"))
			continue;
		bpf_map__set_initial_value(map, &flags, sizeof(flags));
	}
}

const char *idclass_get_program(uint32_t flags, int *fd)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(bpf_progs); i++) {
		if (bpf_progs[i].flags != flags)
			continue;
		*fd = bpf_progs[i].fd;
		return bpf_progs[i].suffix;
	}
	return NULL;
}

static int idclass_create_program(int idx)
{
	DECLARE_LIBBPF_OPTS(bpf_object_open_opts, opts,
		.pin_root_path = CLASSIFY_DATA_PATH,
	);
	struct bpf_program *prog;
	struct bpf_object *obj;
	char path[256];
	int err;
	uint32_t flags = bpf_progs[idx].flags;

	// 读取算法配置，若为 cake 或 cake_dscp，则设置 DSCP 标志
	const char *alg = NULL;
	struct uci_context *uci = uci_alloc_context();
	if (uci) {
		struct uci_package *pkg;
		if (uci_load(uci, "qos_gargoyle", &pkg) == UCI_OK) {
			struct uci_section *s = uci_lookup_section(uci, pkg, "global");
			if (s) {
				alg = uci_lookup_option_string(uci, s, "algorithm");
			}
			uci_unload(uci, pkg);
		}
		uci_free_context(uci);
	}
	if (alg && (strcmp(alg, "cake") == 0 || strcmp(alg, "cake_dscp") == 0)) {
		flags |= IDCLASS_SET_DSCP;
	}

	snprintf(path, sizeof(path), CLASSIFY_PIN_PATH "_" "%s", bpf_progs[idx].suffix);

	obj = bpf_object__open_file(CLASSIFY_PROG_PATH, &opts);
	err = libbpf_get_error(obj);
	if (err) {
		perror("bpf_object__open_file");
		return -1;
	}

	prog = bpf_object__find_program_by_name(obj, "classify");
	if (!prog) {
		fprintf(stderr, "Can't find classifier prog\n");
		return -1;
	}

	bpf_program__set_type(prog, BPF_PROG_TYPE_SCHED_CLS);

	idclass_fill_rodata(obj, flags);

	err = bpf_object__load(obj);
	if (err) {
		perror("bpf_object__load");
		return -1;
	}

	libbpf_set_print(NULL);

	unlink(path);
	err = bpf_program__pin(prog, path);
	if (err) {
		fprintf(stderr, "Failed to pin program to %s: %s\n",
			path, strerror(-err));
		return -1;
	}

	bpf_object__close(obj);

	err = bpf_obj_get(path);
	if (err < 0) {
		fprintf(stderr, "Failed to load pinned program %s: %s\n",
			path, strerror(errno));
	}
	bpf_progs[idx].fd = err;

	return 0;
}

int idclass_loader_init(void)
{
	glob_t g;
	int i;

	if (glob(CLASSIFY_DATA_PATH "/*", 0, NULL, &g) == 0) {
		for (i = 0; i < g.gl_pathc; i++)
			unlink(g.gl_pathv[i]);
	}

	libbpf_set_print(idclass_bpf_pr);

	idclass_init_env();

	for (i = 0; i < ARRAY_SIZE(bpf_progs); i++) {
		if (idclass_create_program(i))
			return -1;
	}

	return 0;
}