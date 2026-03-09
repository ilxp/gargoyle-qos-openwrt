# qosdba Makefile - 优化版本1.7.1
BINDIR = /usr/sbin

# 检测构建环境
ifdef BUILD_DIR
    # OpenWrt构建系统
    TCDIR:=$(shell if [ -e "${BUILD_DIR}/iproute2-tcfull" ] ; then echo "${BUILD_DIR}/iproute2-tcfull"/ip* ; else echo "${BUILD_DIR}/iproute2-tctiny"/ip* ; fi ; )
    CFLAGS += -I$(STAGING_DIR)/usr/include
    LDFLAGS += -L$(STAGING_DIR)/usr/lib
    # TC库对象文件
    TCOBJS := $(TCDIR)/tc/tc_util.o
	TCOBJS += $(TCDIR)/tc/tc_core.o
	TCOBJS += $(TCDIR)/tc/q_hfsc.o
	TCOBJS += $(TCDIR)/tc/q_htb.o
	TCOBJS += $(TCDIR)/tc/q_cake.o
	TCOBJS += $(TCDIR)/lib/libnetlink.a
	TCOBJS += $(TCDIR)/lib/libutil.a
    LDLIBS += -lm
    LDFLAGS += -Wl,-export-dynamic
	# 添加内核头文件路径
	TC_CFLAGS = -I $(TCDIR)/include -I $(TCDIR)/tc -I $(LINUX_DIR)/include/uapi
    # 添加内核头文件路径
	#LINUX_HEADERS := $(shell find $(STAGING_DIR) -name "linux" -type d | grep -E "usr/include/linux$$" | head -1)
	#ifneq ($(LINUX_HEADERS),)
		#TC_CFLAGS = -I $(TCDIR)/include -I $(TCDIR)/tc -I $(dir $(LINUX_HEADERS))
	#else
		#TC_CFLAGS = -I $(TCDIR)/include -I $(TCDIR)/tc
	#endif
else
    # 标准Linux系统构建
    LDLIBS += -lnl-3 -lnl-route-3 -lpthread -lm
    CFLAGS += -D_GNU_SOURCE
    TC_CFLAGS = 
endif

# qosdba版本信息
VERSION = 2.0.0
CFLAGS += -DQOSDBA_VERSION=\"$(VERSION)\"

# 调试选项
DEBUG ?= 0
ifeq ($(DEBUG),1)
    CFLAGS += -g -O0 -DQOSDBA_DEBUG
else
    CFLAGS += -O2
endif

# 测试选项
TEST ?= 0
ifeq ($(TEST),1)
    CFLAGS += -DQOSDBA_TEST
endif

# 内存调试选项
MEMDEBUG ?= 0
ifeq ($(MEMDEBUG),1)
    CFLAGS += -DQOSDBA_DEBUG_MEMORY
endif

# qosdba构建目标
all: qosdba

# 构建可执行文件
qosdba: qosdba.o
ifdef BUILD_DIR
	$(CC) $(LDFLAGS) $^ $(TCOBJS) -o $@ $(LDLIBS)
else
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)
endif

# 编译源文件
qosdba.o: qosdba.c
	$(CC) -D ONLYBG $(CFLAGS) $(TC_CFLAGS) -c $< -o $@

# 安装目标
install: all uninstall
	-mkdir -p $(BINDIR)
	#-mkdir -p /etc/init.d
	#-mkdir -p /etc/config
	#-mkdir -p /etc
	cp qosdba $(BINDIR)
	chmod 755 $(BINDIR)/qosdba
	#cp files/qosdba.init /etc/init.d/qosdba
	#chmod 755 /etc/init.d/qosdba
	#cp files/qosdba.conf /etc/qosdba.conf
	#chmod 644 /etc/qosdba.conf
	# 创建状态文件目录
	#-mkdir -p /var/log
	#touch /var/log/qosdba.log
	#chmod 644 /var/log/qosdba.log
	# 如果存在，启用init脚本
	#if [ -f /etc/init.d/qosdba ]; then \
		#/etc/init.d/qosdba enable; \
	#fi

# 卸载目标
uninstall:
	rm -f $(BINDIR)/qosdba
	rm -f /etc/init.d/qosdba
	rm -f /etc/config/qosdba
	rm -f /etc/qosdba.conf
	# 停止并禁用服务
	if [ -f /etc/init.d/qosdba ]; then \
		/etc/init.d/qosdba stop; \
		/etc/init.d/qosdba disable; \
	fi

# 清理目标
clean:
	rm -rf *.o *~ .*sw* qosdba

.PHONY: all install uninstall clean test once debug release