/*
 * classifi - eBPF + nDPI traffic classifier
 * Copyright (C) 2025 Chad Monroe <chad@monroe.io>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2
 * as published by the Free Software Foundation
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */
#ifndef CLASSIFI_H
#define CLASSIFI_H

#include <stdint.h>
#include <time.h>
#include <regex.h>
#include <ndpi/ndpi_api.h>
#include <bpf/libbpf.h>
#include <libubox/uloop.h>
#include <libubox/avl.h>
#include <libubus.h>

#include "classifi_bpf.h"

struct dump_writer;

struct ja4_entry {
	struct avl_node node;
	char fingerprint[40];
	char client[64];
};

#define MAX_RULES 32
#define MAX_PATTERN_LEN 256
#define MAX_EXTRACTS 4

#define FLOW_IDLE_TIMEOUT 30
#define FLOW_ABSOLUTE_TIMEOUT 60
#define CLEANUP_INTERVAL 30

#define MAX_PROTOCOL_STACK_SIZE 8
#define MAX_RISK_BITS 64

struct classifi_rule {
	char name[64];
	int enabled;

	struct flow_addr dst_ip;
	__u8 dst_family;
	__u16 dst_port;
	__u8 protocol;
	int has_dst_ip;

	char host_header[128];

	char pattern[MAX_PATTERN_LEN];
	regex_t regex;
	int regex_compiled;

	char script[128];

	uint64_t hits;

	struct classifi_rule *next;
};

static inline uint64_t monotonic_time_sec(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec;
}

#define FLOW_TABLE_SIZE 1024
#define MAX_INTERFACES 8

struct interface_info {
	const char *name;
	int ifindex;
	struct flow_addr local_ip;
	__u8 local_ip_family;
	__u32 local_subnet_mask;
	__u8 discovered;
	__u32 tc_handle_ingress;
	__u32 tc_priority_ingress;
	__u32 tc_handle_egress;
	__u32 tc_priority_egress;
};

struct ndpi_flow {
	struct flow_key key;
	struct flow_key first_packet_key;
	struct ndpi_flow_struct *flow;
	ndpi_protocol protocol;
	int packets_processed;
	int packets_dir0;
	int packets_dir1;
	int detection_finalized;
	int protocol_guessed;
	int have_first_packet_key;
	int classification_event_pending;
	uint64_t first_seen;
	uint64_t last_seen;
	char tcp_fingerprint[64];
	char os_hint[32];
	char ja4_fingerprint[40];
	char ndpi_fingerprint[36];
	char ja4_client[64];
	char detection_method[32];
	char src_country[4];
	char dst_country[4];
	uint32_t src_asn;
	uint32_t dst_asn;
	char src_aso[64];
	char dst_aso[64];
	int protocol_stack_count;
	u_int16_t protocol_stack[MAX_PROTOCOL_STACK_SIZE];
	__u32 rules_matched;

	ndpi_risk risk;
	u_int16_t risk_score;
	u_int16_t risk_score_client;
	u_int16_t risk_score_server;

	u_int8_t multimedia_types;

	struct ndpi_flow_input_info input_info;

	struct ndpi_flow *next;
};

static inline struct flow_key *flow_display_key(struct ndpi_flow *flow)
{
	return flow->have_first_packet_key ? &flow->first_packet_key : &flow->key;
}

struct classifi_ctx {
	struct ndpi_detection_module_struct *ndpi;

	struct avl_tree ja4_table;
	int ja4_entries;

	struct ndpi_flow *flow_table[FLOW_TABLE_SIZE];

	struct interface_info interfaces[MAX_INTERFACES];
	int num_interfaces;

	struct classifi_rule *rules;
	int num_rules;

	struct bpf_object *bpf_obj;
	int bpf_prog_fd;
	int flow_map_fd;
	int ringbuf_stats_fd;
	struct ring_buffer *ringbuf;

	struct uloop_fd ringbuf_uloop_fd;
	struct uloop_timeout cleanup_timer;
	struct uloop_timeout stats_timer;

	struct ubus_context *ubus_ctx;

	int verbose;
	int periodic_stats;
	int pcap_mode;
	int geoip_loaded;

	const char *pcap_ifname;

	struct dump_writer *dump;

	__u64 last_ringbuf_drops;
};

typedef void (*flow_visitor_fn)(struct classifi_ctx *ctx,
				struct ndpi_flow *flow,
				void *user_data);

void flow_table_iterate(struct classifi_ctx *ctx,
			flow_visitor_fn visitor,
			void *user_data);

void flow_key_to_strings(const struct flow_key *key,
			 char *src_ip, size_t src_len,
			 char *dst_ip, size_t dst_len);
void flow_addr_to_string(const struct flow_addr *addr, __u8 family,
			 char *out, size_t out_len);
struct ndpi_flow *flow_table_lookup(struct classifi_ctx *ctx, const struct flow_key *key);
struct ndpi_flow *flow_table_insert(struct classifi_ctx *ctx, struct flow_key *key);
struct ndpi_flow *flow_get_or_create(struct classifi_ctx *ctx, struct flow_key *key,
				     const struct flow_key *packet_view, __u8 direction);
int tls_quic_metadata_ready(struct ndpi_flow *flow);
void emit_classification_event(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			       const char *ifname);
void emit_dns_event(struct classifi_ctx *ctx, const char *client_ip,
		    const char *domain, uint16_t qtype, const char *ifname);
int extract_dns_query_name(const unsigned char *dns_payload, unsigned int len,
			   char *out, size_t out_len, uint16_t *qtype);
void cleanup_expired_flows(struct classifi_ctx *ctx);

void flow_update_metadata(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			  ndpi_protocol *protocol);
void flow_get_protocol_names(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			     const char **master, const char **app);
void flow_check_dns_query(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			  const struct flow_key *packet_view,
			  const unsigned char *l3_data, unsigned int l3_len,
			  const char *src_ip, const char *ifname,
			  ndpi_protocol *protocol);
int flow_check_detection_finalized(struct ndpi_flow *flow, ndpi_protocol *protocol);
void flow_detection_giveup(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			   ndpi_protocol *protocol, int packets_threshold);
int flow_handle_classification(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			       ndpi_protocol *protocol, const char *ifname);
void flow_process_ndpi_result(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			      ndpi_protocol *protocol,
			      const struct flow_key *packet_view,
			      const unsigned char *l3_data, unsigned int l3_len,
			      const char *src_ip, const char *ifname);

struct interface_info *interface_by_name(struct classifi_ctx *ctx, const char *name);
int attach_tc_program(struct classifi_ctx *ctx, int prog_fd,
		      const char *ifname, int discovered);
int detach_interface(struct classifi_ctx *ctx, struct interface_info *iface);

int ja4_table_load(struct classifi_ctx *ctx, const char *path);
const char *ja4_table_lookup(struct classifi_ctx *ctx, const char *fingerprint);
void ja4_table_free(struct classifi_ctx *ctx);

void geoip_flow_resolve(struct classifi_ctx *ctx, struct ndpi_flow *flow);

extern volatile int keep_running;

#endif /* CLASSIFI_H */
