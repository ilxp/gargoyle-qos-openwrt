# Development Makefile for building outside OpenWrt
# This is for testing purposes only

CC ?= gcc
CLANG ?= clang
BPFTOOL ?= bpftool

CFLAGS := -Wall -O2 -g
LDFLAGS := -lbpf -lelf -lz -lndpi -lubus -lubox -lblobmsg_json -luci -lpcap

BPF_CFLAGS := -O2 -g -target bpf -D__TARGET_ARCH_x86
BPF_INCLUDE := -I/usr/include/bpf

TARGETS := classifi classifi.bpf.o

.PHONY: all clean

all: $(TARGETS)

classifi.bpf.o: classifi.bpf.c classifi_bpf.h
	$(CLANG) $(BPF_CFLAGS) $(BPF_INCLUDE) -c $< -o $@

classifi: classifi.c classifi_ubus.c classifi_pcap.c classifi_dump.c classifi.h classifi_bpf.h classifi_ubus.h classifi_pcap.h classifi_dump.h
	$(CC) $(CFLAGS) -o $@ classifi.c classifi_ubus.c classifi_pcap.c classifi_dump.c $(LDFLAGS)

clean:
	rm -f $(TARGETS)

install: all
	install -D -m 0755 classifi $(DESTDIR)/usr/sbin/classifi
	install -D -m 0644 classifi.bpf.o $(DESTDIR)/usr/lib/bpf/classifi.bpf.o

.DEFAULT_GOAL := all
