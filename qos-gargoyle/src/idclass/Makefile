# idclass Makefile
CC = gcc
CFLAGS = -O2 -Wall -Wno-unused-result
LDFLAGS = -lbpf -luci -lubox -lubus -lnl-3 -lnl-route-3 -lresolv -lpthread

# 安装路径
DESTDIR ?=
BINDIR ?= /usr/sbin
INITDIR ?= /etc/init.d
BPFDIR ?= /lib/bpf

# 目标文件
TARGET = idclass
BPF_OBJ = idclass-bpf.o

# 用户态源文件（根据新的模块化文件）
USER_SRCS = main.c ebpf_loader.c map_manager.c config.c dns_parser.c interface.c ubus_server.c
USER_OBJS = $(USER_SRCS:.c=.o)

# 内核头文件路径（用于编译 eBPF 程序）
LINUX_UAPI_DIR ?= $(STAGING_DIR)/usr/include
BPF_CFLAGS = -I$(STAGING_DIR)/usr/include -I$(LINUX_UAPI_DIR)

# 用户态头文件搜索路径（添加 libnl3 路径，解决 netlink/msg.h 缺失）
INCLUDES = -I. -I$(STAGING_DIR)/usr/include/libnl3

# 默认目标
all: $(TARGET) $(BPF_OBJ)

# 编译 eBPF 程序
$(BPF_OBJ): idclass-bpf.c bpf_skb_utils.h idclass-bpf.h
	clang -target bpf -g -O2 $(BPF_CFLAGS) -c $< -o $@

# 编译用户态程序
$(TARGET): $(USER_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

# 通用编译规则
%.o: %.c common.h idclass-bpf.h
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

# 安装规则
install: $(TARGET) $(BPF_OBJ)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 $(TARGET) $(DESTDIR)$(BINDIR)/
	install -d $(DESTDIR)$(BPFDIR)
	install -m 644 $(BPF_OBJ) $(DESTDIR)$(BPFDIR)/

	# 安装初始化脚本（如果有）
	install -d $(DESTDIR)$(INITDIR)
	[ -f files/idclass.init ] && install -m 755 files/idclass.init $(DESTDIR)$(INITDIR)/idclass || true

# 卸载
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)
	rm -f $(DESTDIR)$(BPFDIR)/$(BPF_OBJ)
	rm -f $(DESTDIR)$(INITDIR)/idclass

# 清理
clean:
	rm -f $(BPF_OBJ) $(USER_OBJS) $(TARGET)

# 声明伪目标
.PHONY: all install uninstall clean