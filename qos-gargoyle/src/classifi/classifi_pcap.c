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
#include <string.h>
#include <arpa/inet.h>
#define PCAP_DONT_INCLUDE_PCAP_BPF_H
#include <pcap/pcap.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <ndpi/ndpi_api.h>

#include "classifi.h"
#include "classifi_pcap.h"

#ifndef ETH_P_8021Q
#define ETH_P_8021Q 0x8100
#endif
#ifndef ETH_P_8021AD
#define ETH_P_8021AD 0x88A8
#endif
#ifndef DLT_EN10MB
#define DLT_EN10MB 1
#endif

struct vlan_hdr {
	__u16 h_vlan_TCI;
	__u16 h_vlan_encapsulated_proto;
} __attribute__((packed));

static int transport_ports_extract(const unsigned char *ptr, int offset, int packet_len,
				   __u8 protocol, struct flow_key *key)
{
	if (protocol == IPPROTO_TCP) {
		const struct tcphdr *tcph;

		if (offset + sizeof(struct tcphdr) > packet_len)
			return 0;

		tcph = (struct tcphdr *)ptr;
		key->src_port = ntohs(tcph->source);
		key->dst_port = ntohs(tcph->dest);
	} else if (protocol == IPPROTO_UDP) {
		const struct udphdr *udph;

		if (offset + sizeof(struct udphdr) > packet_len)
			return 0;

		udph = (struct udphdr *)ptr;
		key->src_port = ntohs(udph->source);
		key->dst_port = ntohs(udph->dest);
	}

	return 0;
}

static int parse_packet_libpcap(const unsigned char *packet, int packet_len,
				struct flow_key *key, unsigned char **l3_data,
				unsigned int *l3_len)
{
	const struct ethhdr *eth;
	__u16 eth_type;
	const unsigned char *ptr;
	int offset = 0;
	int i;

	if (packet_len < sizeof(struct ethhdr))
		return -1;

	eth = (struct ethhdr *)packet;
	eth_type = ntohs(eth->h_proto);
	offset = sizeof(struct ethhdr);
	ptr = packet + offset;

	for (i = 0; i < 2; i++) {
		if (eth_type == ETH_P_8021Q || eth_type == ETH_P_8021AD) {
			const struct vlan_hdr *vlan;

			if (offset + sizeof(struct vlan_hdr) > packet_len)
				return -1;

			vlan = (struct vlan_hdr *)ptr;
			eth_type = ntohs(vlan->h_vlan_encapsulated_proto);
			offset += sizeof(struct vlan_hdr);
			ptr = packet + offset;
		}
	}

	memset(key, 0, sizeof(*key));

	if (eth_type == ETH_P_IP) {
		const struct iphdr *iph;
		unsigned int ip_hdr_len;

		if (offset + sizeof(struct iphdr) > packet_len)
			return -1;

		iph = (struct iphdr *)ptr;
		ip_hdr_len = iph->ihl * 4;

		if (ip_hdr_len < sizeof(struct iphdr))
			return -1;
		if (offset + ip_hdr_len > packet_len)
			return -1;

		key->family = FLOW_FAMILY_IPV4;
		key->protocol = iph->protocol;
		key->src.hi = 0;
		key->src.lo = (__u64)iph->saddr;
		key->dst.hi = 0;
		key->dst.lo = (__u64)iph->daddr;

		*l3_data = (unsigned char *)ptr;
		*l3_len = packet_len - offset;

		offset += ip_hdr_len;
		ptr = packet + offset;

		return transport_ports_extract(ptr, offset, packet_len, iph->protocol, key);
	}

	if (eth_type == ETH_P_IPV6) {
		const struct ipv6hdr *ip6h;

		if (offset + sizeof(struct ipv6hdr) > packet_len)
			return -1;

		ip6h = (struct ipv6hdr *)ptr;

		key->family = FLOW_FAMILY_IPV6;
		key->protocol = ip6h->nexthdr;
		memcpy(&key->src, &ip6h->saddr, sizeof(struct in6_addr));
		memcpy(&key->dst, &ip6h->daddr, sizeof(struct in6_addr));

		*l3_data = (unsigned char *)ptr;
		*l3_len = packet_len - offset;

		offset += sizeof(struct ipv6hdr);
		ptr = packet + offset;

		return transport_ports_extract(ptr, offset, packet_len, ip6h->nexthdr, key);
	}

	return -1;
}

static void pcap_packet_handler(unsigned char *user, const struct pcap_pkthdr *pkthdr,
				const unsigned char *packet)
{
	struct classifi_ctx *ctx = (struct classifi_ctx *)user;
	struct flow_key key, packet_view;
	unsigned char *l3_data = NULL;
	unsigned int l3_len = 0;
	__u8 direction;
	struct ndpi_flow *flow;
	ndpi_protocol protocol;
	char src_ip[INET6_ADDRSTRLEN], dst_ip[INET6_ADDRSTRLEN];
	static unsigned long long total_packets = 0;

	total_packets++;

	if (parse_packet_libpcap(packet, pkthdr->caplen, &key, &l3_data, &l3_len) < 0)
		return;

	direction = canonicalize_flow_key(&key);

	packet_view = key;
	if (direction)
		swap_flow_endpoints(&packet_view);

	flow = flow_get_or_create(ctx, &key, &packet_view, direction);
	if (!flow)
		return;

	flow_key_to_strings(&packet_view, src_ip, sizeof(src_ip), dst_ip, sizeof(dst_ip));

	if (ctx->verbose && (flow->packets_processed <= PACKETS_TO_SAMPLE || flow->packets_processed % 20 == 0)) {
		fprintf(stderr, "packet %llu (flow pkt %d, dir=%u): %s:%u -> %s:%u proto=%u len=%u [dir0=%d dir1=%d]\n",
			total_packets, flow->packets_processed, direction,
			src_ip, packet_view.src_port,
			dst_ip, packet_view.dst_port, packet_view.protocol,
			l3_len, flow->packets_dir0, flow->packets_dir1);
	}

	if (flow->detection_finalized) {
		if (ctx->verbose)
			fprintf(stderr, "  [SKIP CHECK] finalized=%d hsn=%d ch=%d pkts=%d\n",
				flow->detection_finalized,
				flow->flow->host_server_name[0] ? 1 : 0,
				flow->flow->protos.tls_quic.client_hello_processed,
				flow->packets_processed);
		if (flow->flow->host_server_name[0] ||
		    flow->flow->protos.tls_quic.client_hello_processed ||
		    flow->packets_processed >= PACKETS_TO_SAMPLE)
			return;
	}

	if (!l3_data || l3_len == 0) {
		if (ctx->verbose)
			fprintf(stderr, "  no L3 data, skipping nDPI\n");
		return;
	}

	u_int64_t time_ms = pkthdr->ts.tv_sec * 1000ULL + pkthdr->ts.tv_usec / 1000ULL;

	flow->input_info.in_pkt_dir = NDPI_IN_PKT_DIR_UNKNOWN;

	protocol = ndpi_detection_process_packet(
		ctx->ndpi, flow->flow, l3_data, l3_len,
		time_ms, &flow->input_info);

	flow_process_ndpi_result(ctx, flow, &protocol, &packet_view, l3_data, l3_len,
				 src_ip, ctx->pcap_ifname);
}

int run_pcap_mode(struct classifi_ctx *ctx, const char *ifname)
{
	char errbuf[PCAP_ERRBUF_SIZE];
	pcap_t *handle;

	fprintf(stderr, "starting libpcap capture on %s\n", ifname);
	fprintf(stderr, "warning: this mode captures all packets and is CPU-intensive\n");

	handle = pcap_open_live(ifname, 65535, 1, 100, errbuf);
	if (!handle) {
		fprintf(stderr, "failed to open interface %s: %s\n", ifname, errbuf);
		return -1;
	}

	ctx->flow_map_fd = -1;

	uint64_t last_cleanup = monotonic_time_sec();
	while (keep_running) {
		int ret = pcap_dispatch(handle, 100, pcap_packet_handler, (unsigned char *)ctx);

		if (ret < 0) {
			fprintf(stderr, "pcap_dispatch error: %s\n", pcap_geterr(handle));
			break;
		}

		uint64_t now = monotonic_time_sec();
		if (now - last_cleanup >= CLEANUP_INTERVAL) {
			cleanup_expired_flows(ctx);
			last_cleanup = now;
		}
	}

	pcap_close(handle);
	return 0;
}

static void print_flow_summary(struct classifi_ctx *ctx)
{
	int total = 0, classified = 0, unknown = 0;

	fprintf(stderr, "\n--- Flow Summary ---\n");

	for (int i = 0; i < FLOW_TABLE_SIZE; i++) {
		struct ndpi_flow *f = ctx->flow_table[i];

		while (f) {
			total++;

			char src[INET6_ADDRSTRLEN], dst[INET6_ADDRSTRLEN];
			struct flow_key *dk = flow_display_key(f);

			flow_key_to_strings(dk, src, sizeof(src), dst, sizeof(dst));

			const char *master = ndpi_get_proto_name(ctx->ndpi,
				f->protocol.proto.master_protocol);
			const char *app = ndpi_get_proto_name(ctx->ndpi,
				f->protocol.proto.app_protocol);

			if (f->protocol.proto.app_protocol != NDPI_PROTOCOL_UNKNOWN ||
			    f->protocol.proto.master_protocol != NDPI_PROTOCOL_UNKNOWN)
				classified++;
			else
				unknown++;

			fprintf(stderr, "  %s:%u -> %s:%u  %s/%s  pkts=%d",
				src, dk->src_port, dst, dk->dst_port,
				master, app, f->packets_processed);

			if (f->protocol_guessed)
				fprintf(stderr, " (guessed)");
			fprintf(stderr, "\n");

			if (f->flow->host_server_name[0])
				fprintf(stderr, "    hostname: %s\n",
					f->flow->host_server_name);

			if (f->tcp_fingerprint[0])
				fprintf(stderr, "    tcp_fp: %s (%s)\n",
					f->tcp_fingerprint, f->os_hint);

			f = f->next;
		}
	}

	fprintf(stderr, "\nReplay complete: %d flows (%d classified, %d unknown)\n",
		total, classified, unknown);
}

int run_pcap_replay(struct classifi_ctx *ctx, const char *filename)
{
	char errbuf[PCAP_ERRBUF_SIZE];
	pcap_t *handle;
	int ret;

	fprintf(stderr, "replaying pcap file: %s\n", filename);

	handle = pcap_open_offline(filename, errbuf);
	if (!handle) {
		fprintf(stderr, "failed to open %s: %s\n", filename, errbuf);
		return -1;
	}

	int dlt = pcap_datalink(handle);
	if (dlt != DLT_EN10MB) {
		fprintf(stderr, "unsupported datalink type %d (expected Ethernet)\n", dlt);
		pcap_close(handle);
		return -1;
	}

	ctx->pcap_ifname = "replay";
	ctx->flow_map_fd = -1;

	while ((ret = pcap_dispatch(handle, 1000, pcap_packet_handler,
				    (unsigned char *)ctx)) > 0)
		;

	if (ret < 0 && ret != PCAP_ERROR_BREAK)
		fprintf(stderr, "pcap_dispatch error: %s\n", pcap_geterr(handle));

	print_flow_summary(ctx);

	pcap_close(handle);
	return 0;
}
