CC = gcc
CFLAGS = -Wall -O2 -D_GNU_SOURCE
LDFLAGS = -lpthread

TARGET = qos_dba
OBJS = config_parser.o tc_monitor.o dba_core.o qos_dba.o main.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c qos_dba.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS)

install: $(TARGET)
	install -d /usr/sbin
	install -m 755 $(TARGET) /usr/sbin/
	install -d /etc/init.d
	install -m 755 qos_dba.init /etc/init.d/qos_dba
	update-rc.d qos_dba defaults

uninstall:
	rm -f /usr/sbin/$(TARGET)
	rm -f /etc/init.d/qos_dba
	update-rc.d qos_dba remove

.PHONY: all clean install uninstall