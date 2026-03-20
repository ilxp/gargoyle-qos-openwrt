# idclass Makefile
CC = gcc
CFLAGS = -O2 -Wall
LDFLAGS = -lbpf -luci -lelf -lz -lubox -lubus

DESTDIR ?=
BINDIR ?= /usr/sbin
INITDIR ?= /etc/init.d

TARGET = idclass
BPF_OBJ = idclass-bpf.o
SKEL = idclass.skel.h

USER_SRCS = main.c loader.c map.c interface.c dns.c ubus.c
USER_OBJS = $(USER_SRCS:.c=.o)

# 内核头文件路径（使用 LINUX_DIR，并尝试多个可能位置）
LINUX_UAPI_DIR = $(LINUX_DIR)/user_headers/include
ifeq ($(wildcard $(LINUX_UAPI_DIR)),)
    LINUX_UAPI_DIR = $(LINUX_DIR)/include
endif
ifeq ($(wildcard $(LINUX_UAPI_DIR)),)
    LINUX_UAPI_DIR = $(STAGING_DIR)/usr/include
endif

BPF_CFLAGS = -I$(STAGING_DIR)/usr/include -I$(LINUX_UAPI_DIR)

all: $(TARGET)

# 编译 BPF 程序
$(BPF_OBJ): idclass-bpf.c idclass.h idclass-bpf.h
	clang -target bpf -g -O2 $(BPF_CFLAGS) -c $< -o $@

# 生成 BPF 骨架头文件
$(SKEL): $(BPF_OBJ)
	bpftool gen skeleton $(BPF_OBJ) > $(SKEL)

# 编译用户态程序
$(TARGET): $(USER_OBJS) $(SKEL)
	$(CC) $(CFLAGS) -o $@ $(USER_OBJS) $(LDFLAGS)

%.o: %.c idclass.h $(SKEL)
	$(CC) $(CFLAGS) -c $< -o $@

install: $(TARGET)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 $(TARGET) $(DESTDIR)$(BINDIR)/
	install -d $(DESTDIR)$(INITDIR)
	install -m 755 files/idclass.init $(DESTDIR)$(INITDIR)/idclass

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)
	rm -f $(DESTDIR)$(INITDIR)/idclass

clean:
	rm -f $(BPF_OBJ) $(SKEL) $(USER_OBJS) $(TARGET)

.PHONY: all install uninstall clean