# Makefile for QoS DBA Daemon
CC = gcc
CFLAGS = -Wall -O2 -D_GNU_SOURCE
LDFLAGS = -lpthread -lm -luci  # 添加了-luci

TARGET = qosdba
OBJS = config_parser.o dba_core.o qos_dba_impl.o qos_dba.o main.o tc_monitor.o

# 源文件列表（用于显示和参考）
SRC_FILES = src/config_parser.c src/dba_core.c src/qos_dba_impl.c src/qos_dba.c src/main.c src/tc_monitor.c
OBJ_FILES = $(SRC_FILES:.c=.o)

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
	#install -d $(DESTDIR)/etc/config
	#install -m 644 qosdba.conf $(DESTDIR)/etc/config/qosdba

# 开发辅助目标
debug: CFLAGS += -g -DDEBUG
debug: clean $(TARGET)

# 显示源文件和目标文件列表
list:
	@echo "源文件列表:"
	@for file in $(SRC_FILES); do echo "  $$file"; done
	@echo ""
	@echo "目标文件列表:"
	@for file in $(OBJS); do echo "  $$file"; done
	@echo ""
	@echo "链接参数: $(LDFLAGS)"

# 生成依赖关系
depend: .depend

.depend: $(SRC_FILES)
	rm -f .depend
	$(CC) $(CFLAGS) -MM $^ > .depend

include .depend

.PHONY: all clean install debug list depend