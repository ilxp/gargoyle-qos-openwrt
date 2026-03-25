// SPDX-License-Identifier: GPL-2.0+
/*
 * main.c - Main entry point and command-line handling
 *
 * Initializes all modules (eBPF loader, map manager, config, interface,
 * DNS parser, ubus server) and starts the main loop. Also provides the
 * idclass_run_cmd() utility for executing shell commands.
 */
#include "common.h"

/* Forward declarations for module interfaces (already in common.h) */
/* All interfaces are declared in common.h, no need to repeat here. */

/* Global command execution helper (used by other modules) */
int idclass_run_cmd(char *cmd, bool ignore_error) {
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

/* Helper functions for string manipulation (used by config and map modules) */
char *str_skip(char *str, bool space) {
    while (*str && isspace(*str) == space)
        str++;
    return str;
}

int read_float_mult100(const char *val) {
    double d = atof(val);
    return (int)(d * 100 + 0.5);
}

int idclass_map_codepoint(const char *val) {
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
    for (int i = 0; i < ARRAY_SIZE(codepoints); i++)
        if (!strcmp(codepoints[i].name, val))
            return codepoints[i].val;
    return 0xff;
}

int idclass_map_dscp_value(const char *val, uint8_t *dscp_val) {
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

static int usage(const char *progname) {
    fprintf(stderr, "Usage: %s [options]\n"
            "Options:\n"
            "	-l <file>	Load defaults from <file>\n"
            "	-o		only load program/maps without running as daemon\n"
            "	-c <name>	UCI config name (default: qos_gargoyle)\n"
            "\n", progname);
    return 1;
}

int main(int argc, char **argv) {
    const char *load_file = NULL;
    const char *config_name = "qos_gargoyle";
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

    /* Set UCI config name before loading any config */
    config_set_name(config_name);

    /* Load eBPF programs */
    if (ebpf_loader_init()) {
        fprintf(stderr, "Failed to initialize eBPF loader\n");
        return 2;
    }

    /* Initialize BPF map manager (opens maps, but does not load config) */
    if (map_manager_init()) {
        fprintf(stderr, "Failed to initialize map manager\n");
        return 2;
    }

    /* Load UCI configuration (may also load class marks, etc.) */
    if (config_init()) {
        fprintf(stderr, "Failed to initialize config module\n");
        return 2;
    }

    /* Load optional additional configuration file (if given) */
    if (load_file && map_manager_load_file(load_file)) {
        fprintf(stderr, "Failed to load file: %s\n", load_file);
        return 2;
    }

    /* Initialize network interface handling */
    if (interface_init()) {
        fprintf(stderr, "Failed to initialize interface module\n");
        return 2;
    }

    /* Initialize DNS parser (requires ifb-dns) */
    if (dns_parser_init()) {
        fprintf(stderr, "Failed to initialize DNS parser\n");
        return 2;
    }

    /* Initialize ubus server */
    if (ubus_server_init()) {
        fprintf(stderr, "Failed to initialize ubus server\n");
        return 2;
    }

    /* If oneshot, just exit after setup */
    if (oneshot)
        return 0;

    /* Daemon mode: start main loop */
    ulog_open(ULOG_SYSLOG, LOG_DAEMON, "idclass");
    uloop_init();

    /* Run the main event loop */
    uloop_run();

    /* Cleanup */
    ubus_server_stop();
    interface_stop();
    dns_parser_stop();
    uloop_done();

    return 0;
}