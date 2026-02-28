# Makefile for QoS DBA Daemon
CC = gcc
CFLAGS = -Wall -O2 -D_GNU_SOURCE
LDFLAGS = -lpthread -lm -luci  # 添加了-luci

TARGET = qosdba
OBJS = config_parser.o dba_core.o qos_dba.o main.o tc_monitor.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS)

install: $(TARGET)
	install -d $(DESTDIR)/usr/sbin
	install -m 755 $(TARGET) $(DESTDIR)/usr/sbin/
	install -d $(DESTDIR)/etc/init.d
	install -m 755 qosdba.init $(DESTDIR)/etc/init.d/qosdba

.PHONY: all clean install