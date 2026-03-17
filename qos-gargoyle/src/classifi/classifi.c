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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <ctype.h>
#include <time.h>
#include <arpa/inet.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <ndpi/ndpi_api.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <ifaddrs.h>
#include <regex.h>
#include <libubox/uloop.h>
#include <libubox/blobmsg.h>
#include <libubus.h>

#include "classifi.h"
#include "classifi_ubus.h"
#include "classifi_pcap.h"
#include "classifi_dump.h"

volatile int keep_running = 1;

static struct interface_info *interface_by_index(struct classifi_ctx *ctx, int ifindex)
{
	for (int i = 0; i < ctx->num_interfaces; i++) {
		if (ctx->interfaces[i].ifindex == ifindex)
			return &ctx->interfaces[i];
	}
	return NULL;
}

static const char *interface_name_by_index(struct classifi_ctx *ctx, int ifindex)
{
	struct interface_info *iface = interface_by_index(ctx, ifindex);
	return iface ? iface->name : "unknown";
}

struct interface_info *interface_by_name(struct classifi_ctx *ctx, const char *name)
{
	for (int i = 0; i < ctx->num_interfaces; i++) {
		if (ctx->interfaces[i].name && strcmp(ctx->interfaces[i].name, name) == 0)
			return &ctx->interfaces[i];
	}
	return NULL;
}

static void cleanup_flow_table(struct classifi_ctx *ctx)
{
	for (int i = 0; i < FLOW_TABLE_SIZE; i++) {
		struct ndpi_flow *flow = ctx->flow_table[i];
		while (flow) {
			struct ndpi_flow *next = flow->next;
			if (flow->flow)
				ndpi_flow_free(flow->flow);
			free(flow);
			flow = next;
		}
		ctx->flow_table[i] = NULL;
	}
}

#define FNV_OFFSET 2166136261u
#define FNV_PRIME 16777619u

#define DNS_HEADER_SIZE 12
#define DNS_MAX_LABEL_LEN 63
#define DNS_COMPRESSION_PTR 0xC0

static inline unsigned int fnv_mix64(unsigned int hash, __u64 value)
{
	hash ^= (unsigned int)(value >> 32);
	hash *= FNV_PRIME;
	hash ^= (unsigned int)value;
	hash *= FNV_PRIME;
	return hash;
}

static const char *dns_qtype_str(uint16_t qtype, char *buf, size_t buflen)
{
	switch (qtype) {
	case 1:  return "A";
	case 2:  return "NS";
	case 5:  return "CNAME";
	case 6:  return "SOA";
	case 12: return "PTR";
	case 15: return "MX";
	case 16: return "TXT";
	case 28: return "AAAA";
	case 33: return "SRV";
	case 64: return "SVCB";
	case 65: return "HTTPS";
	default:
		snprintf(buf, buflen, "TYPE%u", qtype);
		return buf;
	}
}

int extract_dns_query_name(const unsigned char *dns_payload, unsigned int len,
			   char *out, size_t out_len, uint16_t *qtype)
{
	unsigned int pos = DNS_HEADER_SIZE;
	unsigned int out_pos = 0;

	if (len < DNS_HEADER_SIZE)
		return -1;

	while (pos < len && out_pos < out_len - 1) {
		unsigned char label_len = dns_payload[pos];

		if (label_len == 0) {
			if (out_pos > 0)
				out[out_pos - 1] = '\0';
			else
				out[0] = '\0';

			pos++;
			if (pos + 2 <= len && qtype)
				*qtype = (dns_payload[pos] << 8) | dns_payload[pos + 1];

			return 0;
		}

		if (label_len >= DNS_COMPRESSION_PTR)
			break;

		if (label_len > DNS_MAX_LABEL_LEN || pos + 1 + label_len > len)
			break;

		pos++;
		for (unsigned int i = 0; i < label_len && out_pos < out_len - 2; i++) {
			out[out_pos++] = dns_payload[pos++];
		}
		if (out_pos < out_len - 1)
			out[out_pos++] = '.';
	}

	out[0] = '\0';
	return -1;
}

static unsigned int flow_hash(const struct flow_key *key)
{
	unsigned int hash = FNV_OFFSET;
	hash ^= key->family;
	hash *= FNV_PRIME;
	hash ^= key->protocol;
	hash *= FNV_PRIME;
	hash ^= ((unsigned int)key->src_port << 16) | key->dst_port;
	hash *= FNV_PRIME;
	hash = fnv_mix64(hash, key->src.hi);
	hash = fnv_mix64(hash, key->src.lo);
	hash = fnv_mix64(hash, key->dst.hi);
	hash = fnv_mix64(hash, key->dst.lo);
	return hash % FLOW_TABLE_SIZE;
}

static int flow_key_equal(const struct flow_key *a, const struct flow_key *b)
{
	return memcmp(a, b, sizeof(*a)) == 0;
}

struct ndpi_flow *flow_table_lookup(struct classifi_ctx *ctx, const struct flow_key *key)
{
	unsigned int hash = flow_hash(key);
	struct ndpi_flow *flow = ctx->flow_table[hash];

	while (flow) {
		if (flow_key_equal(&flow->key, key))
			return flow;
		flow = flow->next;
	}
	return NULL;
}

void flow_key_to_strings(const struct flow_key *key,
			 char *src_ip, size_t src_len,
			 char *dst_ip, size_t dst_len)
{
	flow_addr_to_string(&key->src, key->family, src_ip, src_len);
	flow_addr_to_string(&key->dst, key->family, dst_ip, dst_len);
}

void flow_addr_to_string(const struct flow_addr *addr, __u8 family,
			 char *out, size_t out_len)
{
	if (family == FLOW_FAMILY_IPV4) {
		uint32_t ip = (uint32_t)addr->lo;
		inet_ntop(AF_INET, &ip, out, out_len);
	} else if (family == FLOW_FAMILY_IPV6) {
		struct in6_addr addr6;
		memcpy(&addr6, addr, sizeof(addr6));
		inet_ntop(AF_INET6, &addr6, out, out_len);
	} else {
		snprintf(out, out_len, "unknown");
	}
}

struct ndpi_flow *flow_table_insert(struct classifi_ctx *ctx, struct flow_key *key)
{
	unsigned int hash = flow_hash(key);
	struct ndpi_flow *flow = calloc(1, sizeof(*flow));

	if (!flow)
		return NULL;

	memcpy(&flow->key, key, sizeof(*key));
	flow->flow = ndpi_flow_malloc(SIZEOF_FLOW_STRUCT);

	if (!flow->flow) {
		free(flow);
		return NULL;
	}

	memset(flow->flow, 0, SIZEOF_FLOW_STRUCT);

	flow->first_seen = monotonic_time_sec();
	flow->last_seen = flow->first_seen;

	flow->next = ctx->flow_table[hash];
	ctx->flow_table[hash] = flow;

	return flow;
}

struct ndpi_flow *flow_get_or_create(struct classifi_ctx *ctx, struct flow_key *key,
				     const struct flow_key *packet_view, __u8 direction)
{
	struct ndpi_flow *flow;
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];

	flow = flow_table_lookup(ctx, key);
	if (!flow) {
		flow = flow_table_insert(ctx, key);
		if (!flow) {
			flow_key_to_strings(packet_view, src_ip, sizeof(src_ip),
					    dst_ip, sizeof(dst_ip));
			fprintf(stderr, "failed to create flow for %s:%u -> %s:%u\n",
				src_ip, packet_view->src_port,
				dst_ip, packet_view->dst_port);
			return NULL;
		}
		if (ctx->verbose) {
			flow_key_to_strings(packet_view, src_ip, sizeof(src_ip),
					    dst_ip, sizeof(dst_ip));
			fprintf(stderr, "new flow: %s:%u -> %s:%u proto=%u\n",
				src_ip, packet_view->src_port,
				dst_ip, packet_view->dst_port, packet_view->protocol);
		}
	}

	if (!flow->have_first_packet_key) {
		flow->first_packet_key = *packet_view;
		flow->have_first_packet_key = 1;
	}

	flow->packets_processed++;
	flow->last_seen = monotonic_time_sec();
	if (direction == 0)
		flow->packets_dir0++;
	else
		flow->packets_dir1++;

	return flow;
}

static void signal_handler(int sig)
{
	keep_running = 0;
	uloop_end();
}

static void setup_signals(void)
{
	signal(SIGINT, signal_handler);
	signal(SIGTERM, signal_handler);
}

int get_interface_ip(struct interface_info *iface)
{
	struct ifaddrs *ifaddr, *ifa;
	int found = 0;

	if (getifaddrs(&ifaddr) == -1) {
		fprintf(stderr, "failed to get interface addresses: %s\n", strerror(errno));
		return -1;
	}

	for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
		if (ifa->ifa_addr == NULL)
			continue;

		if (strcmp(ifa->ifa_name, iface->name) != 0)
			continue;

		if (ifa->ifa_addr->sa_family == AF_INET) {
			struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
			struct sockaddr_in *netmask = (struct sockaddr_in *)ifa->ifa_netmask;
			char ip_str[INET_ADDRSTRLEN];

			iface->local_ip_family = FLOW_FAMILY_IPV4;
			iface->local_ip.hi = 0;
			iface->local_ip.lo = (__u64)addr->sin_addr.s_addr;

			if (netmask)
				iface->local_subnet_mask = netmask->sin_addr.s_addr;

			found = 1;
			inet_ntop(AF_INET, &addr->sin_addr, ip_str, sizeof(ip_str));

			if (netmask) {
				char mask_str[INET_ADDRSTRLEN];
				inet_ntop(AF_INET, &netmask->sin_addr, mask_str, sizeof(mask_str));
				printf("interface %s IPv4: %s/%s\n", iface->name, ip_str, mask_str);
			} else {
				printf("interface %s IPv4: %s\n", iface->name, ip_str);
			}
			break;
		}

		if (ifa->ifa_addr->sa_family == AF_INET6 && !found) {
			struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)ifa->ifa_addr;
			char ip_str[INET6_ADDRSTRLEN];

			iface->local_ip_family = FLOW_FAMILY_IPV6;
			memcpy(&iface->local_ip, &addr6->sin6_addr, sizeof(struct in6_addr));
			found = 1;

			inet_ntop(AF_INET6, &addr6->sin6_addr, ip_str, sizeof(ip_str));
			printf("interface %s IPv6: %s\n", iface->name, ip_str);
		}
	}

	freeifaddrs(ifaddr);

	if (!found)
		fprintf(stderr, "warning: could not determine IP address for %s\n", iface->name);

	return found ? 0 : -1;
}

static int is_tls_or_quic(u_int16_t proto)
{
	return proto == NDPI_PROTOCOL_TLS || proto == NDPI_PROTOCOL_QUIC;
}

int tls_quic_metadata_ready(struct ndpi_flow *flow)
{
	u_int16_t master = flow->protocol.proto.master_protocol;
	u_int16_t app = flow->protocol.proto.app_protocol;

	if (!is_tls_or_quic(master) && !is_tls_or_quic(app))
		return 1;

	return flow->detection_finalized ||
	       flow->flow->protos.tls_quic.client_hello_processed;
}

void geoip_flow_resolve(struct classifi_ctx *ctx, struct ndpi_flow *flow)
{
	struct flow_key *key;
	char ip_str[INET6_ADDRSTRLEN];

	if (!ctx->geoip_loaded)
		return;

	if (flow->src_country[0] || flow->dst_country[0])
		return;

	key = flow_display_key(flow);

	flow_addr_to_string(&key->src, key->family, ip_str, sizeof(ip_str));
	ndpi_get_geoip_country_continent(ctx->ndpi, ip_str,
		flow->src_country, sizeof(flow->src_country), NULL, 0);
	ndpi_get_geoip_asn(ctx->ndpi, ip_str, &flow->src_asn);
	ndpi_get_geoip_aso(ctx->ndpi, ip_str, flow->src_aso, sizeof(flow->src_aso));

	flow_addr_to_string(&key->dst, key->family, ip_str, sizeof(ip_str));
	ndpi_get_geoip_country_continent(ctx->ndpi, ip_str,
		flow->dst_country, sizeof(flow->dst_country), NULL, 0);
	ndpi_get_geoip_asn(ctx->ndpi, ip_str, &flow->dst_asn);
	ndpi_get_geoip_aso(ctx->ndpi, ip_str, flow->dst_aso, sizeof(flow->dst_aso));
}

void emit_classification_event(struct classifi_ctx *ctx, struct ndpi_flow *flow, const char *ifname)
{
	struct blob_buf b = {};
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];
	const char *master_name, *app_name, *category_name;
	struct flow_key summary_key;

	if (!ctx->ubus_ctx)
		return;

	summary_key = *flow_display_key(flow);

	flow_key_to_strings(&summary_key, src_ip, sizeof(src_ip), dst_ip, sizeof(dst_ip));
	flow_get_protocol_names(ctx, flow, &master_name, &app_name);
	category_name = ndpi_category_get_name(ctx->ndpi, flow->protocol.category);

	blob_buf_init(&b, 0);
	blobmsg_add_string(&b, "interface", ifname);
	blobmsg_add_string(&b, "src_ip", src_ip);
	blobmsg_add_u32(&b, "src_port", summary_key.src_port);
	blobmsg_add_string(&b, "dst_ip", dst_ip);
	blobmsg_add_u32(&b, "dst_port", summary_key.dst_port);
	blobmsg_add_u32(&b, "protocol", summary_key.protocol);
	blobmsg_add_string(&b, "master_protocol", master_name);
	blobmsg_add_string(&b, "app_protocol", app_name);
	blobmsg_add_string(&b, "category", category_name);
	if (flow->protocol.protocol_by_ip != NDPI_PROTOCOL_UNKNOWN)
		blobmsg_add_string(&b, "protocol_by_ip",
				   ndpi_get_proto_name(ctx->ndpi, flow->protocol.protocol_by_ip));

	if (flow->tcp_fingerprint[0])
		blobmsg_add_string(&b, "tcp_fingerprint", flow->tcp_fingerprint);
	if (flow->os_hint[0])
		blobmsg_add_string(&b, "os_hint", flow->os_hint);
	if (flow->ja4_fingerprint[0])
		blobmsg_add_string(&b, "ja4", flow->ja4_fingerprint);
	if (flow->ja4_client[0])
		blobmsg_add_string(&b, "ja4_client", flow->ja4_client);
	if (flow->ndpi_fingerprint[0])
		blobmsg_add_string(&b, "ndpi_fingerprint", flow->ndpi_fingerprint);
	if (flow->detection_method[0])
		blobmsg_add_string(&b, "detection_method", flow->detection_method);
	if (flow->flow->host_server_name[0])
		blobmsg_add_string(&b, "hostname", flow->flow->host_server_name);

	if (flow->src_country[0])
		blobmsg_add_string(&b, "src_country", flow->src_country);
	if (flow->dst_country[0])
		blobmsg_add_string(&b, "dst_country", flow->dst_country);
	if (flow->src_asn)
		blobmsg_add_u32(&b, "src_asn", flow->src_asn);
	if (flow->dst_asn)
		blobmsg_add_u32(&b, "dst_asn", flow->dst_asn);
	if (flow->src_aso[0])
		blobmsg_add_string(&b, "src_aso", flow->src_aso);
	if (flow->dst_aso[0])
		blobmsg_add_string(&b, "dst_aso", flow->dst_aso);

	if (flow->protocol_stack_count > 1) {
		void *stack = blobmsg_open_array(&b, "protocol_stack");
		for (int i = 0; i < flow->protocol_stack_count; i++)
			blobmsg_add_string(&b, NULL, ndpi_get_proto_name(ctx->ndpi, flow->protocol_stack[i]));
		blobmsg_close_array(&b, stack);
	}

	if (flow->risk_score >= NDPI_SCORE_RISK_HIGH) {
		blobmsg_add_u32(&b, "risk_score", flow->risk_score);
		blobmsg_add_u32(&b, "risk_score_client", flow->risk_score_client);
		blobmsg_add_u32(&b, "risk_score_server", flow->risk_score_server);

		void *risks = blobmsg_open_array(&b, "risks");
		for (int i = 0; i < MAX_RISK_BITS; i++) {
			if (flow->risk & (1ULL << i))
				blobmsg_add_string(&b, NULL, ndpi_risk2str((ndpi_risk_enum)i));
		}
		blobmsg_close_array(&b, risks);
	}

	if (flow->multimedia_types) {
		char stream_content[64];
		if (ndpi_multimedia_flowtype2str(stream_content, sizeof(stream_content),
						 flow->multimedia_types))
			blobmsg_add_string(&b, "stream_content", stream_content);
	}

	if (ubus_send_event(ctx->ubus_ctx, "classifi.classified", b.head) != 0) {
		if (ctx->verbose)
			fprintf(stderr, "failed to send ubus event for flow %s:%u -> %s:%u\n",
				src_ip, summary_key.src_port, dst_ip, summary_key.dst_port);
	}

	blob_buf_free(&b);
}

void emit_dns_event(struct classifi_ctx *ctx, const char *client_ip, const char *domain,
		    uint16_t qtype, const char *ifname)
{
	struct blob_buf b = {};
	char qtype_buf[16];

	if (!ctx->ubus_ctx || !ifname)
		return;

	blob_buf_init(&b, 0);
	blobmsg_add_string(&b, "interface", ifname);
	blobmsg_add_string(&b, "client_ip", client_ip);
	blobmsg_add_string(&b, "domain", domain);
	blobmsg_add_string(&b, "query_type", dns_qtype_str(qtype, qtype_buf, sizeof(qtype_buf)));

	if (ubus_send_event(ctx->ubus_ctx, "classifi.dns_query", b.head) != 0) {
		if (ctx->verbose)
			fprintf(stderr, "failed to send DNS event for %s -> %s\n", client_ip, domain);
	}

	blob_buf_free(&b);
}

static int get_tcp_payload(struct packet_sample *sample, char *buf, size_t buf_len)
{
	unsigned char *ip_packet;
	unsigned int ip_hdr_len, tcp_hdr_len;
	unsigned char *tcp_hdr;
	unsigned char *payload;
	unsigned int payload_len;
	unsigned int l3_offset = sample->l3_offset;

	if (l3_offset >= sample->data_len)
		return -1;

	ip_packet = sample->data + l3_offset;

	if (sample->key.family == FLOW_FAMILY_IPV4) {
		struct iphdr *iph = (struct iphdr *)ip_packet;

		if (l3_offset + sizeof(struct iphdr) > sample->data_len)
			return -1;
		if (iph->protocol != IPPROTO_TCP)
			return -1;

		ip_hdr_len = iph->ihl * 4;
		if (l3_offset + ip_hdr_len > sample->data_len)
			return -1;

		tcp_hdr = ip_packet + ip_hdr_len;
	} else if (sample->key.family == FLOW_FAMILY_IPV6) {
		struct ipv6hdr *ip6h = (struct ipv6hdr *)ip_packet;

		if (l3_offset + sizeof(struct ipv6hdr) > sample->data_len)
			return -1;
		if (ip6h->nexthdr != IPPROTO_TCP)
			return -1;

		ip_hdr_len = sizeof(struct ipv6hdr);
		tcp_hdr = ip_packet + ip_hdr_len;
	} else {
		return -1;
	}

	if (l3_offset + ip_hdr_len + sizeof(struct tcphdr) > sample->data_len)
		return -1;

	struct tcphdr *tcph = (struct tcphdr *)tcp_hdr;
	tcp_hdr_len = tcph->doff * 4;

	if (l3_offset + ip_hdr_len + tcp_hdr_len > sample->data_len)
		return -1;

	payload = tcp_hdr + tcp_hdr_len;
	payload_len = sample->data_len - l3_offset - ip_hdr_len - tcp_hdr_len;

	if (payload_len == 0)
		return -1;

	size_t copy_len = payload_len < buf_len - 1 ? payload_len : buf_len - 1;
	memcpy(buf, payload, copy_len);
	buf[copy_len] = '\0';

	return (int)copy_len;
}

static void emit_rule_match_event(struct classifi_ctx *ctx,
				  struct classifi_rule *rule,
				  struct flow_key *key,
				  char extracts[][256],
				  int num_extracts,
				  const char *ifname)
{
	struct blob_buf b = {};
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];

	if (!ctx->ubus_ctx)
		return;

	flow_key_to_strings(key, src_ip, sizeof(src_ip), dst_ip, sizeof(dst_ip));

	blob_buf_init(&b, 0);
	blobmsg_add_string(&b, "rule", rule->name);
	blobmsg_add_string(&b, "interface", ifname ? ifname : "unknown");
	blobmsg_add_string(&b, "src_ip", src_ip);
	blobmsg_add_u32(&b, "src_port", key->src_port);
	blobmsg_add_string(&b, "dst_ip", dst_ip);
	blobmsg_add_u32(&b, "dst_port", key->dst_port);
	blobmsg_add_u32(&b, "protocol", key->protocol);

	for (int i = 0; i < num_extracts && i < MAX_EXTRACTS; i++) {
		char field_name[16];
		snprintf(field_name, sizeof(field_name), "match_%d", i + 1);
		blobmsg_add_string(&b, field_name, extracts[i]);
	}

	if (ubus_send_event(ctx->ubus_ctx, "classifi.rule_match", b.head) != 0) {
		if (ctx->verbose)
			fprintf(stderr, "failed to send rule match event for rule '%s'\n", rule->name);
	}

	blob_buf_free(&b);
}

static void sanitize_for_shell(char *str)
{
	char *src = str, *dst = str;

	while (*src) {
		if (isalnum((unsigned char)*src) ||
		    *src == '-' || *src == '_' ||
		    *src == '.' || *src == ':' || *src == '/')
			*dst++ = *src;
		src++;
	}
	*dst = '\0';
}

static void execute_rule_script(struct classifi_ctx *ctx,
				struct classifi_rule *rule,
				struct flow_key *key,
				char extracts[][256],
				int num_extracts,
				const char *ifname)
{
	pid_t pid;
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];
	char port_str[8], proto_str[8];
	char safe_extracts[MAX_EXTRACTS][256];

	if (!rule->script[0])
		return;

	for (int i = 0; i < num_extracts && i < MAX_EXTRACTS; i++) {
		memcpy(safe_extracts[i], extracts[i], sizeof(safe_extracts[i]));
		sanitize_for_shell(safe_extracts[i]);
	}

	flow_key_to_strings(key, src_ip, sizeof(src_ip), dst_ip, sizeof(dst_ip));
	snprintf(port_str, sizeof(port_str), "%u", key->dst_port);
	snprintf(proto_str, sizeof(proto_str), "%u", key->protocol);

	pid = fork();
	if (pid < 0) {
		fprintf(stderr, "failed to fork for rule script '%s': %s\n",
			rule->script, strerror(errno));
		return;
	}

	if (pid == 0) {
		setenv("CLASSIFI_RULE", rule->name, 1);
		setenv("CLASSIFI_INTERFACE", ifname ? ifname : "unknown", 1);
		setenv("CLASSIFI_SRC_IP", src_ip, 1);
		setenv("CLASSIFI_DST_IP", dst_ip, 1);
		setenv("CLASSIFI_DST_PORT", port_str, 1);
		setenv("CLASSIFI_PROTOCOL", proto_str, 1);

		for (int i = 0; i < num_extracts && i < MAX_EXTRACTS; i++) {
			char env_name[32];
			snprintf(env_name, sizeof(env_name), "CLASSIFI_MATCH_%d", i + 1);
			setenv(env_name, safe_extracts[i], 1);
		}

		execl("/bin/sh", "sh", "-c", rule->script, NULL);
		_exit(127);
	}
}

static int ip_addr_match(struct flow_addr *a, struct flow_addr *b, __u8 family)
{
	if (family == FLOW_FAMILY_IPV4)
		return a->lo == b->lo;
	return a->hi == b->hi && a->lo == b->lo;
}

static int host_header_match(const char *payload, const char *expected_host)
{
	const char *host_start;
	const char *line_end;
	size_t host_len;

	host_start = strstr(payload, "Host: ");
	if (!host_start)
		host_start = strstr(payload, "host: ");
	if (!host_start)
		return 0;

	host_start += 6;

	line_end = strpbrk(host_start, "\r\n");
	if (!line_end)
		line_end = host_start + strlen(host_start);

	host_len = strlen(expected_host);

	if ((size_t)(line_end - host_start) < host_len)
		return 0;

	if (strncasecmp(host_start, expected_host, host_len) != 0)
		return 0;

	if (host_start[host_len] == ':' || host_start[host_len] == '\r' ||
	    host_start[host_len] == '\n' || host_start[host_len] == '\0')
		return 1;

	return 0;
}

static void check_rules_and_execute(struct classifi_ctx *ctx,
				    struct ndpi_flow *flow,
				    struct flow_key *packet_view,
				    struct packet_sample *sample,
				    const char *ifname)
{
	struct classifi_rule *rule;
	int rule_idx = 0;
	char payload_buf[1024];
	int payload_len;

	if (!ctx->rules)
		return;

	payload_len = get_tcp_payload(sample, payload_buf, sizeof(payload_buf));
	if (payload_len <= 0)
		return;

	for (rule = ctx->rules; rule && rule_idx < MAX_RULES; rule = rule->next, rule_idx++) {
		regmatch_t matches[MAX_EXTRACTS + 1];
		char extracts[MAX_EXTRACTS][256];
		int num_extracts = 0;

		if (!rule->enabled)
			continue;

		if (flow->rules_matched & (1u << rule_idx))
			continue;

		if (packet_view->dst_port != rule->dst_port)
			continue;

		if (packet_view->protocol != rule->protocol)
			continue;

		if (rule->has_dst_ip) {
			if (packet_view->family != rule->dst_family)
				continue;
			if (!ip_addr_match(&packet_view->dst, &rule->dst_ip, rule->dst_family))
				continue;
		}

		if (rule->host_header[0]) {
			if (!host_header_match(payload_buf, rule->host_header))
				continue;
		}

		if (regexec(&rule->regex, payload_buf, MAX_EXTRACTS + 1, matches, 0) != 0)
			continue;

		flow->rules_matched |= (1u << rule_idx);
		rule->hits++;

		for (int i = 1; i <= MAX_EXTRACTS && matches[i].rm_so >= 0; i++) {
			int len = matches[i].rm_eo - matches[i].rm_so;
			if (len > 255)
				len = 255;
			memcpy(extracts[num_extracts], payload_buf + matches[i].rm_so, len);
			extracts[num_extracts][len] = '\0';
			num_extracts++;
		}

		if (ctx->verbose)
			fprintf(stderr, "rule '%s' matched flow to %s:%u, %d capture(s)\n",
				rule->name,
				ifname ? ifname : "unknown",
				rule->dst_port, num_extracts);

		emit_rule_match_event(ctx, rule, packet_view, extracts, num_extracts, ifname);

		if (rule->script[0])
			execute_rule_script(ctx, rule, packet_view, extracts, num_extracts, ifname);
	}
}

static const unsigned char *dns_payload_extract(const unsigned char *l3_data,
						 unsigned int l3_len,
						 __u8 family,
						 unsigned int *out_len)
{
	unsigned int offset;

	if (family == FLOW_FAMILY_IPV4) {
		struct iphdr *iph = (struct iphdr *)l3_data;
		unsigned int ip_hdr_len = iph->ihl * 4;
		offset = ip_hdr_len + 8;
	} else {
		offset = 40 + 8;
	}

	if (offset >= l3_len)
		return NULL;

	*out_len = l3_len - offset;
	return l3_data + offset;
}

void flow_update_metadata(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			  ndpi_protocol *protocol)
{
	int stack_count;
	const char *method;
	const char *ja4_client;

	if (flow->flow->tcp.fingerprint && flow->flow->tcp.fingerprint[0] &&
	    !flow->tcp_fingerprint[0]) {
		snprintf(flow->tcp_fingerprint, sizeof(flow->tcp_fingerprint), "%s",
			 flow->flow->tcp.fingerprint);
		snprintf(flow->os_hint, sizeof(flow->os_hint), "%s",
			 ndpi_print_os_hint(flow->flow->tcp.os_hint));
	}

	if (flow->flow->protos.tls_quic.ja4_client[0] && !flow->ja4_fingerprint[0]) {
		snprintf(flow->ja4_fingerprint, sizeof(flow->ja4_fingerprint), "%s",
			 flow->flow->protos.tls_quic.ja4_client);

		ja4_client = ja4_table_lookup(ctx, flow->ja4_fingerprint);
		if (ja4_client && !flow->ja4_client[0])
			snprintf(flow->ja4_client, sizeof(flow->ja4_client), "%s", ja4_client);
	}

	if (flow->flow->ndpi.fingerprint && !flow->ndpi_fingerprint[0])
		snprintf(flow->ndpi_fingerprint, sizeof(flow->ndpi_fingerprint), "%s",
			 flow->flow->ndpi.fingerprint);

	if (protocol->protocol_stack.protos_num > 0 && flow->protocol_stack_count == 0) {
		stack_count = protocol->protocol_stack.protos_num;
		if (stack_count > MAX_PROTOCOL_STACK_SIZE)
			stack_count = MAX_PROTOCOL_STACK_SIZE;

		flow->protocol_stack_count = stack_count;
		for (int i = 0; i < stack_count; i++)
			flow->protocol_stack[i] = protocol->protocol_stack.protos[i];
	}

	flow->risk = flow->flow->risk;
	if (flow->risk)
		flow->risk_score = ndpi_risk2score(flow->risk,
			&flow->risk_score_client, &flow->risk_score_server);

	flow->multimedia_types = flow->flow->flow_multimedia_types;

	if (flow->flow->confidence != NDPI_CONFIDENCE_UNKNOWN) {
		method = ndpi_confidence_get_name(flow->flow->confidence);
		if (method)
			snprintf(flow->detection_method, sizeof(flow->detection_method),
				 "%s", method);
	}
}

void flow_get_protocol_names(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			     const char **master, const char **app)
{
	if (flow->protocol.proto.master_protocol == NDPI_PROTOCOL_UNKNOWN)
		*master = ndpi_get_proto_name(ctx->ndpi, flow->protocol.proto.app_protocol);
	else
		*master = ndpi_get_proto_name(ctx->ndpi, flow->protocol.proto.master_protocol);

	*app = ndpi_get_proto_name(ctx->ndpi, flow->protocol.proto.app_protocol);
}

void flow_check_dns_query(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			  const struct flow_key *packet_view,
			  const unsigned char *l3_data, unsigned int l3_len,
			  const char *src_ip, const char *ifname,
			  ndpi_protocol *protocol)
{
	const unsigned char *dns_payload;
	unsigned int dns_len;
	char query_name[256];
	uint16_t qtype = 0;

	if (protocol->proto.app_protocol != NDPI_PROTOCOL_DNS &&
	    packet_view->dst_port != 53)
		return;

	if (packet_view->protocol != IPPROTO_UDP)
		return;

	if (flow->packets_processed > 2)
		return;

	dns_payload = dns_payload_extract(l3_data, l3_len, packet_view->family, &dns_len);
	if (!dns_payload || dns_len == 0)
		return;

	if (extract_dns_query_name(dns_payload, dns_len, query_name, sizeof(query_name), &qtype) != 0)
		return;

	emit_dns_event(ctx, src_ip, query_name, qtype, ifname);
	if (ctx->verbose)
		fprintf(stderr, "  [DNS] Query: %s from %s\n", query_name, src_ip);
}

int flow_check_detection_finalized(struct ndpi_flow *flow, ndpi_protocol *protocol)
{
	if (flow->detection_finalized)
		return 1;

	if ((protocol->state == NDPI_STATE_CLASSIFIED ||
	     protocol->state == NDPI_STATE_MONITORING) &&
	    flow->flow->extra_packets_func == NULL) {
		flow->detection_finalized = 1;
		return 1;
	}

	return 0;
}

void flow_detection_giveup(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			   ndpi_protocol *protocol, int packets_threshold)
{
	if (flow->detection_finalized)
		return;

	if (flow->packets_processed < packets_threshold)
		return;

	if (ctx->verbose)
		fprintf(stderr, "  [PKT %d] Calling ndpi_detection_giveup() [dir0=%d dir1=%d]...\n",
			flow->packets_processed, flow->packets_dir0, flow->packets_dir1);

	*protocol = ndpi_detection_giveup(ctx->ndpi, flow->flow);
	flow->detection_finalized = 1;
	flow->protocol_guessed = (protocol->proto.app_protocol != NDPI_PROTOCOL_UNKNOWN);

	if (ctx->verbose) {
		fprintf(stderr, "  [PKT %d] After giveup (guessed=%d, dir0=%d dir1=%d): master=%u (%s) app=%u (%s)\n",
			flow->packets_processed,
			flow->protocol_guessed, flow->packets_dir0, flow->packets_dir1,
			protocol->proto.master_protocol,
			ndpi_get_proto_name(ctx->ndpi, protocol->proto.master_protocol),
			protocol->proto.app_protocol,
			ndpi_get_proto_name(ctx->ndpi, protocol->proto.app_protocol));
	}
}

static void flow_log_verbose_ndpi(struct classifi_ctx *ctx, struct ndpi_flow *flow,
				  ndpi_protocol *protocol,
				  const char *src_ip, const char *dst_ip)
{
	fprintf(stderr, "  [PKT %d] nDPI process_packet: master=%u (%s) app=%u (%s) category=%s state=%d\n",
		flow->packets_processed,
		protocol->proto.master_protocol,
		ndpi_get_proto_name(ctx->ndpi, protocol->proto.master_protocol),
		protocol->proto.app_protocol,
		ndpi_get_proto_name(ctx->ndpi, protocol->proto.app_protocol),
		ndpi_category_get_name(ctx->ndpi, protocol->category),
		protocol->state);

	if (flow->tcp_fingerprint[0])
		fprintf(stderr, "  [TCP FP] %s (OS: %s)\n",
			flow->tcp_fingerprint, flow->os_hint);

	if (flow->protocol_stack_count > 1) {
		fprintf(stderr, "  [Stack] ");
		for (int i = 0; i < flow->protocol_stack_count; i++) {
			fprintf(stderr, "%s%s", i > 0 ? " -> " : "",
				ndpi_get_proto_name(ctx->ndpi, flow->protocol_stack[i]));
		}
		fprintf(stderr, "\n");
	}

	if (flow->multimedia_types) {
		char stream_content[64];
		if (ndpi_multimedia_flowtype2str(stream_content, sizeof(stream_content),
						 flow->multimedia_types))
			fprintf(stderr, "  [Stream] %s\n", stream_content);
	}

	if (protocol->proto.app_protocol == NDPI_PROTOCOL_TLS && flow->packets_processed <= 10) {
		fprintf(stderr, "  [TLS] %s -> %s dir0=%d dir1=%d ch=%d sh=%d sni=%s\n",
			src_ip, dst_ip,
			flow->packets_dir0, flow->packets_dir1,
			flow->flow->protos.tls_quic.client_hello_processed,
			flow->flow->protos.tls_quic.server_hello_processed,
			flow->flow->host_server_name[0] ? flow->flow->host_server_name : "NONE");
	}
}

void flow_process_ndpi_result(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			      ndpi_protocol *protocol,
			      const struct flow_key *packet_view,
			      const unsigned char *l3_data, unsigned int l3_len,
			      const char *src_ip, const char *ifname)
{
	flow_update_metadata(ctx, flow, protocol);

	if (ctx->verbose && (flow->packets_processed <= PACKETS_TO_SAMPLE ||
			     flow->packets_processed % 20 == 0)) {
		char dst_ip[INET6_ADDRSTRLEN];
		flow_addr_to_string(&packet_view->dst, packet_view->family,
				    dst_ip, sizeof(dst_ip));
		flow_log_verbose_ndpi(ctx, flow, protocol, src_ip, dst_ip);
	}

	flow_check_dns_query(ctx, flow, packet_view, l3_data, l3_len, src_ip, ifname, protocol);

	if (flow_check_detection_finalized(flow, protocol) && ctx->verbose)
		fprintf(stderr, "  [PKT %d] Flow finalized via nDPI state=%d\n",
			flow->packets_processed, protocol->state);

	flow_detection_giveup(ctx, flow, protocol, PACKETS_TO_SAMPLE);
	flow_handle_classification(ctx, flow, protocol, ifname);
}

int flow_handle_classification(struct classifi_ctx *ctx, struct ndpi_flow *flow,
			       ndpi_protocol *protocol, const char *ifname)
{
	int newly_classified = 0;

	if (protocol->proto.master_protocol == NDPI_PROTOCOL_UNKNOWN &&
	    protocol->proto.app_protocol == NDPI_PROTOCOL_UNKNOWN)
		return 0;

	if (flow->protocol.proto.master_protocol != protocol->proto.master_protocol ||
	    flow->protocol.proto.app_protocol != protocol->proto.app_protocol) {
		if (flow->protocol.proto.master_protocol == NDPI_PROTOCOL_UNKNOWN &&
		    flow->protocol.proto.app_protocol == NDPI_PROTOCOL_UNKNOWN)
			newly_classified = 1;

		if (ctx->verbose) {
			fprintf(stderr, "  [PKT %d] Classification changed: old master=%u app=%u -> new master=%u app=%u\n",
				flow->packets_processed,
				flow->protocol.proto.master_protocol,
				flow->protocol.proto.app_protocol,
				protocol->proto.master_protocol,
				protocol->proto.app_protocol);
		}
	}

	flow->protocol = *protocol;

	if (!ifname)
		return newly_classified;

	if (newly_classified) {
		if (tls_quic_metadata_ready(flow)) {
			geoip_flow_resolve(ctx, flow);
			emit_classification_event(ctx, flow, ifname);
		} else {
			flow->classification_event_pending = 1;
			if (ctx->verbose)
				fprintf(stderr, "  [PKT %d] Deferring event for TLS/QUIC metadata\n",
					flow->packets_processed);
		}
	} else if (flow->classification_event_pending && tls_quic_metadata_ready(flow)) {
		geoip_flow_resolve(ctx, flow);
		emit_classification_event(ctx, flow, ifname);
		flow->classification_event_pending = 0;
		if (ctx->verbose)
			fprintf(stderr, "  [PKT %d] Emitting deferred TLS/QUIC event (SNI=%s)\n",
				flow->packets_processed,
				flow->flow->host_server_name[0] ? flow->flow->host_server_name : "none");
	}

	return newly_classified;
}

static int ja4_avl_cmp(const void *k1, const void *k2, void *ptr)
{
	(void)ptr;
	return strcmp(k1, k2);
}

int ja4_table_load(struct classifi_ctx *ctx, const char *path)
{
	FILE *fp;
	char line[256];
	int count = 0;

	avl_init(&ctx->ja4_table, ja4_avl_cmp, false, NULL);

	fp = fopen(path, "r");
	if (!fp)
		return -1;

	while (fgets(line, sizeof(line), fp)) {
		struct ja4_entry *entry;
		char *p, *at;

		p = line;
		while (*p == ' ' || *p == '\t')
			p++;

		if (*p == '#' || *p == '\n' || *p == '\0')
			continue;

		if (strncmp(p, "ja4:", 4) != 0)
			continue;

		p += 4;

		at = strchr(p, '@');
		if (!at)
			continue;

		at[strcspn(at, "\r\n")] = '\0';

		entry = calloc(1, sizeof(*entry));
		if (!entry)
			continue;

		*at = '\0';
		snprintf(entry->fingerprint, sizeof(entry->fingerprint), "%s", p);
		snprintf(entry->client, sizeof(entry->client), "%s", at + 1);

		entry->node.key = entry->fingerprint;
		if (avl_insert(&ctx->ja4_table, &entry->node) != 0) {
			free(entry);
			continue;
		}

		count++;
	}

	fclose(fp);
	ctx->ja4_entries = count;

	return count;
}

const char *ja4_table_lookup(struct classifi_ctx *ctx, const char *fingerprint)
{
	struct ja4_entry *entry;
	struct avl_node *node;

	if (!fingerprint || !fingerprint[0])
		return NULL;

	node = avl_find(&ctx->ja4_table, fingerprint);
	if (!node)
		return NULL;

	entry = container_of(node, struct ja4_entry, node);
	return entry->client;
}

void ja4_table_free(struct classifi_ctx *ctx)
{
	struct ja4_entry *entry, *tmp;

	avl_for_each_element_safe(&ctx->ja4_table, entry, node, tmp) {
		avl_delete(&ctx->ja4_table, &entry->node);
		free(entry);
	}

	ctx->ja4_entries = 0;
}

static struct ndpi_detection_module_struct *setup_ndpi(void)
{
	struct ndpi_detection_module_struct *ndpi_struct;

	ndpi_struct = ndpi_init_detection_module(NULL);
	if (!ndpi_struct) {
		fprintf(stderr, "failed to initialize nDPI\n");
		return NULL;
	}

	/* Fix TCP ACK payload heuristic issues (see nDPI issue #1946) */
	ndpi_set_config(ndpi_struct, NULL, "tcp_ack_payload_heuristic", "enable");

	/* We sample 50 packets, not the default 32 */
	ndpi_set_config(ndpi_struct, NULL, "packets_limit_per_flow", "50");

	ndpi_set_config(ndpi_struct, "tls", "application_blocks_tracking", "enable");
	ndpi_set_config(ndpi_struct, "dns", "subclassification", "enable");
	ndpi_set_config(ndpi_struct, NULL, "fully_encrypted_heuristic", "enable");

	/* 0x07 enables all TLS heuristics for obfuscated/proxied traffic */
	ndpi_set_config(ndpi_struct, "tls", "dpi.heuristics", "0x07");

	ndpi_set_config(ndpi_struct, NULL, "lru.tls_cert.size", "4096");
	ndpi_set_config(ndpi_struct, NULL, "lru.stun.size", "4096");
	ndpi_set_config(ndpi_struct, NULL, "lru.fpc_dns.size", "4096");
	ndpi_set_config(ndpi_struct, "any", "ip_list.load", "enable");
	ndpi_set_config(ndpi_struct, NULL, "dpi.guess_ip_before_port", "enable");
	ndpi_set_config(ndpi_struct, NULL, "hostname_dns_check", "1");
	ndpi_set_config(ndpi_struct, NULL, "metadata.tcp_fingerprint", "1");
	ndpi_set_config(ndpi_struct, "tls", "blocks_analysis", "1");

	ndpi_set_config(ndpi_struct, NULL, "metadata.ndpi_fingerprint", "enable");
	ndpi_set_config(ndpi_struct, NULL, "metadata.ndpi_fingerprint_format", "1");

	/*
	 * Disabled for now: nDPI's ja4 custom rules (from protos.txt) overwrite
	 * app_protocol with client identification (e.g., "Safari"), losing service
	 * detection (e.g., "Microsoft365"). We handle JA4 client lookup separately
	 * via ja4_table_load() to preserve both pieces of information. Needs more
	 * research to determine if nDPI can be configured to augment rather than
	 * replace app_protocol.
	 */
	//if (ndpi_load_protocols_file(ndpi_struct, "/etc/classifi/protos.txt") < 0)
	//	fprintf(stderr, "warning: failed to load /etc/classifi/protos.txt\n");

	if (ndpi_finalize_initialization(ndpi_struct) != 0) {
		fprintf(stderr, "failed to finalize nDPI initialization\n");
		ndpi_exit_detection_module(ndpi_struct);
		return NULL;
	}

	printf("initialized nDPI version %s\n",
	       ndpi_revision());

	return ndpi_struct;
}

static void log_ip_header_debug(unsigned char *ip_packet, unsigned int ip_packet_len,
				__u8 direction, const char *src_ip, const char *dst_ip,
				unsigned int l3_offset)
{
	uint8_t ip_version = (ip_packet[0] >> 4) & 0x0f;

	if (ip_version == 4 && ip_packet_len >= 20) {
		struct iphdr *iph = (struct iphdr *)ip_packet;
		char pkt_src[INET_ADDRSTRLEN], pkt_dst[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &iph->saddr, pkt_src, sizeof(pkt_src));
		inet_ntop(AF_INET, &iph->daddr, pkt_dst, sizeof(pkt_dst));
		fprintf(stderr, "  [IP HDR] ver=%u src=%s dst=%s proto=%u bpf_dir=%u (flow_view: %s -> %s)\n",
			ip_version, pkt_src, pkt_dst, iph->protocol, direction, src_ip, dst_ip);
		return;
	}

	if (ip_version == 6 && ip_packet_len >= 40) {
		struct ipv6hdr *ip6h = (struct ipv6hdr *)ip_packet;
		char pkt_src[INET6_ADDRSTRLEN], pkt_dst[INET6_ADDRSTRLEN];
		inet_ntop(AF_INET6, &ip6h->saddr, pkt_src, sizeof(pkt_src));
		inet_ntop(AF_INET6, &ip6h->daddr, pkt_dst, sizeof(pkt_dst));
		fprintf(stderr, "  [IP HDR] ver=%u src=%s dst=%s proto=%u bpf_dir=%u (flow_view: %s -> %s)\n",
			ip_version, pkt_src, pkt_dst, ip6h->nexthdr, direction, src_ip, dst_ip);
		return;
	}

	fprintf(stderr, "  [IP HDR] warning: invalid IP version %u at l3_offset %u\n",
		ip_version, l3_offset);
}

static void log_ndpi_direction_debug(struct ndpi_flow *flow, const struct flow_key *packet_view,
				     unsigned char *ip_packet, unsigned int ip_packet_len,
				     const char *src_ip, const char *dst_ip)
{
	unsigned int ip_hdr_len, tcp_hdr_len, payload_off, payload_len;
	const uint8_t *payload;
	struct tcphdr *tcph;
	struct iphdr *iph;

	fprintf(stderr, "  [nDPI DIR] %s -> %s pkt_dir_counter[0]=%u [1]=%u client_dir=%u input_dir=%u pkt_dir=%u\n",
		src_ip, dst_ip,
		flow->flow->packet_direction_complete_counter[0],
		flow->flow->packet_direction_complete_counter[1],
		flow->flow->client_packet_direction,
		flow->input_info.in_pkt_dir,
		flow->flow->packet_direction);

	if ((packet_view->dst_port != 443 && packet_view->src_port != 443) ||
	    packet_view->protocol != IPPROTO_TCP)
		return;

	iph = (struct iphdr *)ip_packet;
	ip_hdr_len = iph->ihl * 4;
	tcph = (struct tcphdr *)(ip_packet + ip_hdr_len);
	tcp_hdr_len = tcph->doff * 4;
	payload_off = ip_hdr_len + tcp_hdr_len;

	if (payload_off >= ip_packet_len)
		return;

	payload = ip_packet + payload_off;
	payload_len = ip_packet_len - payload_off;

	if (payload_len >= 5) {
		fprintf(stderr, "  [TLS RAW] %s -> %s payload_len=%u first_bytes=%02x %02x %02x %02x %02x tcp_seq=%u\n",
			src_ip, dst_ip,
			payload_len, payload[0], payload[1], payload[2], payload[3], payload[4],
			ntohl(tcph->seq));
	} else if (payload_len > 0) {
		fprintf(stderr, "  [TLS RAW] %s -> %s payload_len=%u (too short for TLS header)\n",
			src_ip, dst_ip, payload_len);
	}
}

static void classify_packet(struct classifi_ctx *ctx, struct packet_sample *sample)
{
	struct ndpi_flow *flow;
	ndpi_protocol protocol;
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];
	struct flow_key packet_view;
	static int total_samples = 0;

	total_samples++;

	packet_view = sample->key;
	if (sample->direction)
		swap_flow_endpoints(&packet_view);

	flow = flow_get_or_create(ctx, &sample->key, &packet_view, sample->direction);
	if (!flow)
		return;

	flow_key_to_strings(&packet_view, src_ip, sizeof(src_ip), dst_ip, sizeof(dst_ip));

	check_rules_and_execute(ctx, flow, &packet_view, sample,
				interface_name_by_index(ctx, sample->ifindex));

	if (ctx->verbose) {
		fprintf(stderr, "sample %d (flow pkt %d, dir=%u): %s:%u -> %s:%u proto=%u len=%u l3_off=%u [dir0=%d dir1=%d]\n",
			total_samples, flow->packets_processed, sample->direction,
			src_ip, packet_view.src_port,
			dst_ip, packet_view.dst_port, packet_view.protocol,
			sample->data_len, sample->l3_offset,
			flow->packets_dir0, flow->packets_dir1);

		if (flow->packets_processed == 1 || flow->packets_processed == 2) {
			fprintf(stderr, "  packet %d hex dump (first 64 bytes):\n  ", flow->packets_processed);
			for (int i = 0; i < 64 && i < sample->data_len; i++) {
				fprintf(stderr, "%02x ", sample->data[i]);
				if ((i + 1) % 16 == 0)
					fprintf(stderr, "\n  ");
			}
			fprintf(stderr, "\n");
		}
	}

	unsigned int l3_offset = sample->l3_offset;
	unsigned char *ip_packet = NULL;
	unsigned int ip_packet_len = 0;

	if (l3_offset < sample->data_len) {
		ip_packet = sample->data + l3_offset;
		ip_packet_len = sample->data_len - l3_offset;
	}

	if (!ip_packet || ip_packet_len == 0) {
		if (ctx->verbose)
			fprintf(stderr, "  packet shorter than L3 offset (%u), skipping\n", l3_offset);
		return;
	}

	if (ctx->verbose && flow->packets_processed <= 5)
		log_ip_header_debug(ip_packet, ip_packet_len, sample->direction,
				    src_ip, dst_ip, l3_offset);

	u_int64_t time_ms = sample->ts_ns ? sample->ts_ns / 1000000ULL : monotonic_time_sec() * 1000ULL;

	flow->input_info.in_pkt_dir = NDPI_IN_PKT_DIR_UNKNOWN;

	protocol = ndpi_detection_process_packet(
		ctx->ndpi, flow->flow, ip_packet, ip_packet_len,
		time_ms, &flow->input_info);

	if (ctx->verbose && flow->packets_processed <= 10)
		log_ndpi_direction_debug(flow, &packet_view, ip_packet, ip_packet_len,
					 src_ip, dst_ip);

	flow_process_ndpi_result(ctx, flow, &protocol, &packet_view, ip_packet, ip_packet_len,
				 src_ip, interface_name_by_index(ctx, sample->ifindex));
}

static int handle_sample(void *ctx, void *data, size_t len)
{
	struct classifi_ctx *classifi_ctx = ctx;
	struct packet_sample *sample = data;

	if (len < sizeof(*sample))
		return 0;

	if (sample->data_len > MAX_PACKET_SAMPLE)
		return 0;

	if (sample->l3_offset > sample->data_len)
		return 0;

	if (classifi_ctx->dump)
		dump_write_packet(classifi_ctx->dump, sample->ifindex,
				  sample->ts_ns, sample->data, sample->data_len);

	classify_packet(classifi_ctx, sample);
	return 0;
}

int detach_interface(struct classifi_ctx *ctx, struct interface_info *iface)
{
	LIBBPF_OPTS(bpf_tc_hook, hook);
	LIBBPF_OPTS(bpf_tc_opts, opts);
	int ret, idx;

	if (!iface || !iface->ifindex || !iface->name)
		return -1;

	hook.ifindex = iface->ifindex;
	hook.attach_point = BPF_TC_INGRESS | BPF_TC_EGRESS;

	hook.attach_point = BPF_TC_INGRESS;
	opts.handle = iface->tc_handle_ingress;
	opts.priority = iface->tc_priority_ingress;
	ret = bpf_tc_detach(&hook, &opts);
	if (ret && ret != -ENOENT)
		fprintf(stderr, "warning: failed to detach TC program from %s ingress: %s\n",
			iface->name, strerror(-ret));

	hook.attach_point = BPF_TC_EGRESS;
	opts.handle = iface->tc_handle_egress;
	opts.priority = iface->tc_priority_egress;
	ret = bpf_tc_detach(&hook, &opts);
	if (ret && ret != -ENOENT)
		fprintf(stderr, "warning: failed to detach TC program from %s egress: %s\n",
			iface->name, strerror(-ret));

	hook.attach_point = BPF_TC_INGRESS | BPF_TC_EGRESS;
	bpf_tc_hook_destroy(&hook);

	printf("detached BPF program from %s (ifindex %d)\n", iface->name, iface->ifindex);

	if (iface->discovered && iface->name) {
		free((void *)iface->name);
		iface->name = NULL;
	}

	idx = iface - ctx->interfaces;
	if (idx >= 0 && idx < ctx->num_interfaces) {
		memmove(&ctx->interfaces[idx], &ctx->interfaces[idx + 1],
			(ctx->num_interfaces - idx - 1) * sizeof(struct interface_info));
		ctx->num_interfaces--;
		memset(&ctx->interfaces[ctx->num_interfaces], 0, sizeof(struct interface_info));
	}

	return 0;
}

static void detach_tc_program(struct classifi_ctx *ctx)
{
	while (ctx->num_interfaces > 0)
		detach_interface(ctx, &ctx->interfaces[0]);
}

int attach_tc_program(struct classifi_ctx *ctx, int prog_fd,
		      const char *ifname, int discovered)
{
	int ifindex;
	LIBBPF_OPTS(bpf_tc_hook, hook);
	LIBBPF_OPTS(bpf_tc_opts, opts_ingress);
	LIBBPF_OPTS(bpf_tc_opts, opts_egress);
	int ret;

	if (ctx->num_interfaces >= MAX_INTERFACES) {
		fprintf(stderr, "maximum number of interfaces (%d) reached\n", MAX_INTERFACES);
		return -1;
	}

	if (interface_by_name(ctx, ifname)) {
		if (ctx->verbose)
			fprintf(stderr, "interface %s already attached, skipping\n", ifname);
		return 0;
	}

	ifindex = if_nametoindex(ifname);
	if (!ifindex) {
		fprintf(stderr, "failed to get ifindex for %s: %s\n",
			ifname, strerror(errno));
		return -1;
	}

	hook.ifindex = ifindex;
	hook.attach_point = BPF_TC_INGRESS | BPF_TC_EGRESS;

	/* safety net: previous instance may not have cleaned up (SIGKILL, crash) */
	bpf_tc_hook_destroy(&hook);

	ret = bpf_tc_hook_create(&hook);
	if (ret && ret != -EEXIST) {
		fprintf(stderr, "failed to create TC hook for %s: %s\n", ifname, strerror(-ret));
		return ret;
	}

	hook.attach_point = BPF_TC_INGRESS;
	opts_ingress.prog_fd = prog_fd;
	opts_ingress.flags = BPF_TC_F_REPLACE;
	ret = bpf_tc_attach(&hook, &opts_ingress);
	if (ret) {
		fprintf(stderr, "failed to attach TC program to %s ingress: %s\n", ifname, strerror(-ret));
		return ret;
	}

	hook.attach_point = BPF_TC_EGRESS;
	opts_egress.prog_fd = prog_fd;
	opts_egress.flags = BPF_TC_F_REPLACE;
	ret = bpf_tc_attach(&hook, &opts_egress);
	if (ret) {
		fprintf(stderr, "failed to attach TC program to %s egress: %s\n", ifname, strerror(-ret));
		hook.attach_point = BPF_TC_INGRESS;
		bpf_tc_detach(&hook, &opts_ingress);
		hook.attach_point = BPF_TC_INGRESS | BPF_TC_EGRESS;
		bpf_tc_hook_destroy(&hook);
		return ret;
	}

	printf("attached BPF program to %s ingress+egress (ifindex %d)\n", ifname, ifindex);

	ctx->interfaces[ctx->num_interfaces].name = ifname;
	ctx->interfaces[ctx->num_interfaces].ifindex = ifindex;
	ctx->interfaces[ctx->num_interfaces].discovered = discovered;
	ctx->interfaces[ctx->num_interfaces].tc_handle_ingress = opts_ingress.handle;
	ctx->interfaces[ctx->num_interfaces].tc_priority_ingress = opts_ingress.priority;
	ctx->interfaces[ctx->num_interfaces].tc_handle_egress = opts_egress.handle;
	ctx->interfaces[ctx->num_interfaces].tc_priority_egress = opts_egress.priority;
	ctx->num_interfaces++;

	return 0;
}

static void print_classified_flows(struct classifi_ctx *ctx)
{
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];
	const char *master_name, *app_name;
	uint64_t now = monotonic_time_sec();
	struct flow_key summary_key;

	for (int i = 0; i < FLOW_TABLE_SIZE; i++) {
		struct ndpi_flow *flow = ctx->flow_table[i];
		while (flow) {
			if (flow->protocol.proto.master_protocol != NDPI_PROTOCOL_UNKNOWN ||
			    flow->protocol.proto.app_protocol != NDPI_PROTOCOL_UNKNOWN) {

				summary_key = *flow_display_key(flow);

				flow_key_to_strings(&summary_key, src_ip, sizeof(src_ip), dst_ip, sizeof(dst_ip));
				flow_get_protocol_names(ctx, flow, &master_name, &app_name);

				const char *category_name = ndpi_category_get_name(ctx->ndpi, flow->protocol.category);

				printf("%-39s:%-5u -> %-39s:%-5u proto=%-3u | %-8s / %-20s | %-16s | pkts=%d (d0:%d d1:%d) age=%llus\n",
				       src_ip, summary_key.src_port,
				       dst_ip, summary_key.dst_port,
				       summary_key.protocol,
				       master_name, app_name,
				       category_name,
				       flow->packets_processed,
				       flow->packets_dir0, flow->packets_dir1,
				       (unsigned long long)(now - flow->first_seen));
			}
			flow = flow->next;
		}
	}
}

static void flow_free(struct classifi_ctx *ctx, struct ndpi_flow *flow)
{
	if (ctx->flow_map_fd >= 0)
		bpf_map_delete_elem(ctx->flow_map_fd, &flow->key);
	if (flow->flow)
		ndpi_flow_free(flow->flow);
	free(flow);
}

void cleanup_expired_flows(struct classifi_ctx *ctx)
{
	uint64_t now = monotonic_time_sec();
	int total_flows = 0;
	int expired_flows = 0;

	for (int i = 0; i < FLOW_TABLE_SIZE; i++) {
		struct ndpi_flow **prev = &ctx->flow_table[i];
		struct ndpi_flow *flow = ctx->flow_table[i];

		while (flow) {
			struct ndpi_flow *next = flow->next;
			uint64_t idle_time = now - flow->last_seen;
			uint64_t age = now - flow->first_seen;

			total_flows++;

			if (idle_time < FLOW_IDLE_TIMEOUT && age < FLOW_ABSOLUTE_TIMEOUT) {
				prev = &flow->next;
				flow = next;
				continue;
			}

			if (ctx->verbose) {
				if (idle_time >= FLOW_IDLE_TIMEOUT)
					fprintf(stderr, "expiring idle flow (idle %llu sec)\n",
						(unsigned long long)idle_time);
				else
					fprintf(stderr, "expiring old flow (age %llu sec)\n",
						(unsigned long long)age);
			}

			*prev = next;
			flow_free(ctx, flow);
			flow = next;
			expired_flows++;
		}
	}

	if (ctx->verbose && expired_flows > 0)
		fprintf(stderr, "flow cleanup: %d active, %d expired\n",
			total_flows - expired_flows, expired_flows);
}

void flow_table_iterate(struct classifi_ctx *ctx, flow_visitor_fn visitor, void *user_data)
{
	for (int i = 0; i < FLOW_TABLE_SIZE; i++) {
		struct ndpi_flow *flow = ctx->flow_table[i];
		while (flow) {
			visitor(ctx, flow, user_data);
			flow = flow->next;
		}
	}
}

static void print_ringbuf_stats(struct classifi_ctx *ctx)
{
	__u32 key = 0;
	__u64 drops = 0;

	if (ctx->ringbuf_stats_fd >= 0 &&
	    bpf_map_lookup_elem(ctx->ringbuf_stats_fd, &key, &drops) == 0) {
		if (drops > ctx->last_ringbuf_drops) {
			__u64 new_drops = drops - ctx->last_ringbuf_drops;
			fprintf(stderr, "warning: ring buffer dropped %llu packet samples (total: %llu)\n",
				new_drops, drops);
			ctx->last_ringbuf_drops = drops;
		}
	}
}

static void ringbuf_fd_cb(struct uloop_fd *fd, unsigned int events)
{
	struct classifi_ctx *ctx = container_of(fd, struct classifi_ctx, ringbuf_uloop_fd);

	if (!ctx->ringbuf)
		return;

	int err = ring_buffer__consume(ctx->ringbuf);
	if (err < 0 && err != -EAGAIN)
		fprintf(stderr, "error consuming ring buffer: %d\n", err);
}

static void cleanup_timer_cb(struct uloop_timeout *t)
{
	struct classifi_ctx *ctx = container_of(t, struct classifi_ctx, cleanup_timer);
	cleanup_expired_flows(ctx);
	uloop_timeout_set(t, CLEANUP_INTERVAL * 1000);
}

static void stats_timer_cb(struct uloop_timeout *t)
{
	struct classifi_ctx *ctx = container_of(t, struct classifi_ctx, stats_timer);
	print_ringbuf_stats(ctx);
	uloop_timeout_set(t, 10 * 1000);
}

struct classifi_options {
	const char *iface_names[MAX_INTERFACES];
	int num_ifaces;
	const char *bpf_obj_path;
	const char *dump_filename;
	const char *replay_filename;
	int verbose;
	int periodic_stats;
	int pcap_mode;
	int discover_mode;
};

static void print_usage(const char *prog)
{
	fprintf(stderr, "usage: %s [options] <bpf_object.o>\n", prog);
	fprintf(stderr, "\n");
	fprintf(stderr, "options:\n");
	fprintf(stderr, "  -h, --help            Display this help message\n");
	fprintf(stderr, "  -v, --verbose         Enable verbose output\n");
	fprintf(stderr, "  -s, --stats           Enable periodic statistics output\n");
	fprintf(stderr, "  -p, --pcap            Use libpcap mode instead of eBPF\n");
	fprintf(stderr, "  -i, --interface <if>  Attach to interface (may be repeated)\n");
	fprintf(stderr, "  -d, --discover        Discover LAN interfaces from UCI config\n");
	fprintf(stderr, "  -w, --write <file>    Write packet samples to pcapng file\n");
	fprintf(stderr, "  -r, --read <file>     Replay packets from pcap file\n");
	fprintf(stderr, "\n");
	fprintf(stderr, "modes:\n");
	fprintf(stderr, "  eBPF mode (default):  requires <bpf_object.o> and at least one interface\n");
	fprintf(stderr, "  pcap mode (-p):       requires exactly one interface, no BPF object\n");
	fprintf(stderr, "  replay mode (-r):     replays pcap file for offline analysis\n");
	fprintf(stderr, "\n");
	fprintf(stderr, "examples:\n");
	fprintf(stderr, "  %s -d /usr/lib/bpf/classifi.bpf.o\n", prog);
	fprintf(stderr, "      Start in eBPF mode, discover interfaces from UCI\n");
	fprintf(stderr, "  %s -i br-lan /usr/lib/bpf/classifi.bpf.o\n", prog);
	fprintf(stderr, "      Start in eBPF mode on br-lan interface\n");
	fprintf(stderr, "  %s -p -i br-lan\n", prog);
	fprintf(stderr, "      Start in libpcap mode on br-lan interface\n");
	fprintf(stderr, "  %s -r capture.pcap\n", prog);
	fprintf(stderr, "      Replay and analyze packets from capture.pcap\n");
}

static int parse_args(int argc, char **argv, struct classifi_options *opts)
{
	int opt_idx = 1;

	memset(opts, 0, sizeof(*opts));

	while (opt_idx < argc && argv[opt_idx][0] == '-') {
		if (strcmp(argv[opt_idx], "-h") == 0 ||
		    strcmp(argv[opt_idx], "--help") == 0) {
			print_usage(argv[0]);
			exit(0);
		}

		if (strcmp(argv[opt_idx], "-v") == 0 ||
		    strcmp(argv[opt_idx], "--verbose") == 0) {
			opts->verbose = 1;
			opt_idx++;
			continue;
		}

		if (strcmp(argv[opt_idx], "-s") == 0 ||
		    strcmp(argv[opt_idx], "--stats") == 0) {
			opts->periodic_stats = 1;
			opt_idx++;
			continue;
		}

		if (strcmp(argv[opt_idx], "-p") == 0 ||
		    strcmp(argv[opt_idx], "--pcap") == 0) {
			opts->pcap_mode = 1;
			opt_idx++;
			continue;
		}

		if (strcmp(argv[opt_idx], "-i") == 0 ||
		    strcmp(argv[opt_idx], "--interface") == 0) {
			if (opt_idx + 1 >= argc) {
				fprintf(stderr, "option %s requires an interface name\n", argv[opt_idx]);
				return -1;
			}
			if (opts->num_ifaces >= MAX_INTERFACES) {
				fprintf(stderr, "too many interfaces (max %d)\n", MAX_INTERFACES);
				return -1;
			}
			opts->iface_names[opts->num_ifaces++] = argv[opt_idx + 1];
			opt_idx += 2;
			continue;
		}

		if (strcmp(argv[opt_idx], "-d") == 0 ||
		    strcmp(argv[opt_idx], "--discover") == 0) {
			opts->num_ifaces = discover_interfaces_from_uci(opts->iface_names, MAX_INTERFACES);
			opts->discover_mode = 1;
			opt_idx++;
			continue;
		}

		if (strcmp(argv[opt_idx], "-w") == 0 ||
		    strcmp(argv[opt_idx], "--write") == 0) {
			if (opt_idx + 1 >= argc) {
				fprintf(stderr, "option %s requires a filename\n", argv[opt_idx]);
				return -1;
			}
			opts->dump_filename = argv[opt_idx + 1];
			opt_idx += 2;
			continue;
		}

		if (strcmp(argv[opt_idx], "-r") == 0 ||
		    strcmp(argv[opt_idx], "--read") == 0) {
			if (opt_idx + 1 >= argc) {
				fprintf(stderr, "option %s requires a filename\n", argv[opt_idx]);
				return -1;
			}
			opts->replay_filename = argv[opt_idx + 1];
			opt_idx += 2;
			continue;
		}

		fprintf(stderr, "unknown option: %s\n\n", argv[opt_idx]);
		print_usage(argv[0]);
		return -1;
	}

	if (opts->replay_filename) {
		if (opts->pcap_mode) {
			fprintf(stderr, "-r and -p are mutually exclusive\n");
			return -1;
		}
		return 0;
	}

	if (opts->pcap_mode) {
		if (opts->num_ifaces != 1) {
			print_usage(argv[0]);
			fprintf(stderr, "\nerror: pcap mode requires exactly one interface\n");
			return -1;
		}
		if (opts->dump_filename) {
			fprintf(stderr, "warning: -w ignored in pcap mode\n");
			opts->dump_filename = NULL;
		}
		return 0;
	}

	if (opts->num_ifaces < 1) {
		fprintf(stderr, "no interfaces specified. Use -i <interface> or -d to discover.\n");
		return -1;
	}

	if (argc - opt_idx < 1) {
		print_usage(argv[0]);
		fprintf(stderr, "\nerror: BPF object file required\n");
		return -1;
	}

	opts->bpf_obj_path = argv[opt_idx];
	return 0;
}

int main(int argc, char **argv)
{
	struct classifi_ctx ctx = {0};
	struct classifi_options opts;
	struct bpf_program *prog;
	int prog_fd, samples_fd;
	int err = 0;

	signal(SIGCHLD, SIG_IGN);

	if (parse_args(argc, argv, &opts) < 0)
		return 1;

	ctx.verbose = opts.verbose;
	ctx.periodic_stats = opts.periodic_stats;
	ctx.pcap_mode = opts.pcap_mode;

	setup_signals();

	uloop_init();
	ctx.ubus_ctx = ubus_connect(NULL);
	if (!ctx.ubus_ctx) {
		fprintf(stderr, "warning: failed to connect to ubus, events will not be emitted\n");
	} else {
		ubus_add_uloop(ctx.ubus_ctx);
		if (classifi_ubus_init(&ctx) != 0)
			fprintf(stderr, "warning: failed to initialize classifi ubus\n");
		if (ctx.verbose)
			fprintf(stderr, "connected to ubus for event emission\n");
	}

	ctx.ndpi = setup_ndpi();
	if (!ctx.ndpi) {
		fprintf(stderr, "failed to initialize nDPI\n");
		return 1;
	}

	rules_load_from_uci(&ctx);

	if (ja4_table_load(&ctx, "/etc/classifi/protos.txt") > 0)
		printf("loaded %d JA4 fingerprint(s) from protos.txt\n", ctx.ja4_entries);

	{
		int geoip_rc;

		geoip_rc = ndpi_load_geoip(ctx.ndpi,
			"/usr/share/geoip/ip-to-country.mmdb",
			"/usr/share/geoip/ip-to-asn.mmdb");
		if (geoip_rc == 0) {
			ctx.geoip_loaded = 1;
			printf("loaded GeoIP country and ASN databases\n");
		} else if (geoip_rc == -2) {
			ctx.geoip_loaded = 1;
			printf("loaded GeoIP country database (ASN database not available)\n");
		} else {
			fprintf(stderr, "warning: GeoIP databases not available, country/ASN lookups disabled\n");
		}
	}

	if (opts.replay_filename) {
		err = run_pcap_replay(&ctx, opts.replay_filename);
		goto cleanup;
	}

	if (ctx.pcap_mode) {
		ctx.pcap_ifname = opts.iface_names[0];
		err = run_pcap_mode(&ctx, opts.iface_names[0]);
		goto cleanup;
	}

	ctx.bpf_obj = bpf_object__open_file(opts.bpf_obj_path, NULL);
	if (libbpf_get_error(ctx.bpf_obj)) {
		fprintf(stderr, "failed to open BPF object: %s\n", opts.bpf_obj_path);
		ctx.bpf_obj = NULL;
		return 1;
	}

	if (bpf_object__load(ctx.bpf_obj)) {
		fprintf(stderr, "failed to load BPF object\n");
		goto cleanup;
	}

	prog = bpf_object__find_program_by_name(ctx.bpf_obj, "classifi");
	if (!prog) {
		fprintf(stderr, "failed to find classifi program\n");
		goto cleanup;
	}

	prog_fd = bpf_program__fd(prog);
	if (prog_fd < 0) {
		fprintf(stderr, "failed to get program fd\n");
		goto cleanup;
	}

	ctx.flow_map_fd = bpf_object__find_map_fd_by_name(ctx.bpf_obj, "flow_map");
	samples_fd = bpf_object__find_map_fd_by_name(ctx.bpf_obj, "packet_samples");
	ctx.ringbuf_stats_fd = bpf_object__find_map_fd_by_name(ctx.bpf_obj, "ringbuf_stats");

	if (ctx.flow_map_fd < 0 || samples_fd < 0 || ctx.ringbuf_stats_fd < 0) {
		fprintf(stderr, "failed to find BPF maps\n");
		goto cleanup;
	}

	ctx.bpf_prog_fd = prog_fd;

	for (int i = 0; i < opts.num_ifaces; i++) {
		if (attach_tc_program(&ctx, prog_fd, opts.iface_names[i], opts.discover_mode) < 0) {
			fprintf(stderr, "failed to attach program to interface %s\n", opts.iface_names[i]);
			goto cleanup;
		}
		get_interface_ip(&ctx.interfaces[ctx.num_interfaces - 1]);
	}

	if (opts.dump_filename) {
		ctx.dump = dump_open(opts.dump_filename);
		if (!ctx.dump) {
			fprintf(stderr, "failed to open dump file, continuing without pcapng output\n");
		} else {
			for (int i = 0; i < ctx.num_interfaces; i++)
				dump_add_interface(ctx.dump, ctx.interfaces[i].name,
						   ctx.interfaces[i].ifindex);
		}
	}

	ctx.ringbuf = ring_buffer__new(samples_fd, handle_sample, &ctx, NULL);
	if (!ctx.ringbuf) {
		fprintf(stderr, "failed to create ring buffer\n");
		goto cleanup;
	}

	int rb_epoll_fd = ring_buffer__epoll_fd(ctx.ringbuf);
	if (rb_epoll_fd < 0) {
		fprintf(stderr, "failed to get ring buffer epoll fd\n");
		goto cleanup;
	}

	ctx.ringbuf_uloop_fd.fd = rb_epoll_fd;
	ctx.ringbuf_uloop_fd.cb = ringbuf_fd_cb;
	uloop_fd_add(&ctx.ringbuf_uloop_fd, ULOOP_READ);

	ctx.cleanup_timer.cb = cleanup_timer_cb;
	uloop_timeout_set(&ctx.cleanup_timer, CLEANUP_INTERVAL * 1000);

	ctx.stats_timer.cb = stats_timer_cb;
	uloop_timeout_set(&ctx.stats_timer, 10 * 1000);

	__u32 stats_key = 0;
	bpf_map_lookup_elem(ctx.ringbuf_stats_fd, &stats_key, &ctx.last_ringbuf_drops);

	printf("classifi running on %d interface(s):", ctx.num_interfaces);
	for (int i = 0; i < ctx.num_interfaces; i++)
		printf(" %s", ctx.interfaces[i].name);
	printf("\n");

	uloop_run();

	printf("\nshutting down...\n");

cleanup:
	uloop_fd_delete(&ctx.ringbuf_uloop_fd);
	uloop_timeout_cancel(&ctx.cleanup_timer);
	uloop_timeout_cancel(&ctx.stats_timer);
	detach_tc_program(&ctx);
	ring_buffer__free(ctx.ringbuf);
	ctx.ringbuf = NULL;
	bpf_object__close(ctx.bpf_obj);
	cleanup_flow_table(&ctx);
	rules_free(&ctx);
	ja4_table_free(&ctx);
	if (ctx.dump) {
		dump_close(ctx.dump);
		ctx.dump = NULL;
	}
	if (ctx.ndpi)
		ndpi_exit_detection_module(ctx.ndpi);

	if (ctx.ubus_ctx) {
		ubus_free(ctx.ubus_ctx);
		ctx.ubus_ctx = NULL;
	}
	uloop_done();

	return err != 0;
}
