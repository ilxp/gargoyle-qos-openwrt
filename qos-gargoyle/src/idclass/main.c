// SPDX-License-Identifier: GPL-2.0+
/*
 * Copyright (C) 2021 Felix Fietkau <nbd@nbd.name>
 */
#include <sys/wait.h>
#include <stdio.h>
#include <unistd.h>
#include <stdint.h>

#include <libubox/uloop.h>

#include "idclass.h"

static int usage(const char *progname)
{
	fprintf(stderr, "Usage: %s [options]\n"
		"Options:\n"
		"	-l <file>	Load defaults from <file>\n"
		"	-o		only load program/maps without running as daemon\n"
		"\n", progname);

	return 1;
}

int idclass_run_cmd(char *cmd, bool ignore_error)
{
	char *argv[] = { "sh", "-c", cmd, NULL };
	bool first = true;
	int status = -1;
	char buf[512];
	int fds[2];
	FILE *f;
	int pid;

	if (pipe(fds))
		return -1;

	pid = fork();
	if (!pid) {
		close(fds[0]);
		if (fds[1] != STDOUT_FILENO)
			dup2(fds[1], STDOUT_FILENO);
		if (fds[1] != STDERR_FILENO)
			dup2(fds[1], STDERR_FILENO);
		if (fds[1] > STDERR_FILENO)
			close(fds[1]);
		execv("/bin/sh", argv);
		exit(1);
	}

	if (pid < 0)
		return -1;

	close(fds[1]);
	f = fdopen(fds[0], "r");
	if (!f) {
		close(fds[0]);
		goto out;
	}

	while (fgets(buf, sizeof(buf), f) != NULL) {
		if (!strlen(buf))
			break;
		if (ignore_error)
			continue;
		if (first) {
			ULOG_WARN("Command: %s\n", cmd);
			first = false;
		}
		ULOG_WARN("%s%s", buf, strchr(buf, '\n') ? "" : "\n");
	}

	fclose(f);

out:
	while (waitpid(pid, &status, 0) < 0)
		if (errno != EINTR)
			break;

	return status;
}


int main(int argc, char **argv)
{
	const char *load_file = NULL;
	const char *config_name = "qos_gargoyle"; /* 默认配置名 */
	bool oneshot = false;
	int ch;

	while ((ch = getopt(argc, argv, "fl:oc:")) != -1) {
		switch (ch) {
		case 'f':
			break;
		case 'l':
			load_file = optarg;
			break;
		case 'o':
			oneshot = true;
			break;
		case 'c':
			config_name = optarg;
			break;
		default:
			return usage(argv[0]);
		}
	}

	/* 传递配置名给 map 模块（可通过全局变量或函数） */
	idclass_set_config_name(config_name);

	if (idclass_loader_init())
		return 2;

	if (idclass_map_init())
		return 2;

	if (idclass_map_load_file(load_file))
		return 2;

	if (oneshot)
		return 0;

	ulog_open(ULOG_SYSLOG, LOG_DAEMON, "idclass");
	uloop_init();

	if (idclass_ubus_init() ||
	    idclass_iface_init())
		return 2;

	idclass_dns_init();

	uloop_run();

	idclass_ubus_stop();
	idclass_iface_stop();

	uloop_done();

	return 0;
}
