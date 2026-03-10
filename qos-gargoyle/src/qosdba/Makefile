# ============================================================================
# QoS DBA 2.1.1 模块化Makefile
# 版本: 2.1.1
# 支持OpenWrt和标准Linux构建
# ============================================================================

# 基本配置
CC = gcc
CFLAGS = -Wall -O2 -pthread -D_GNU_SOURCE
LDFLAGS = 
LDLIBS = -lpthread -lm
TARGET = qosdba
VERSION = 2.1.1

# 版本信息
CFLAGS += -DQOSDBA_VERSION=\"$(VERSION)\"
CFLAGS += -DQOSDBA_MAJOR_VERSION=2
CFLAGS += -DQOSDBA_MINOR_VERSION=1
CFLAGS += -DQOSDBA_PATCH_VERSION=1
CFLAGS += -D_FILE_OFFSET_BITS=64

# 构建模式
BUILD_MODE ?= linux
ifeq ($(BUILD_MODE),openwrt)
    CFLAGS += -DQOSDBA_OPENWRT
    LDLIBS += -ldl
    # OpenWrt使用TC库
    ifdef BUILD_DIR
        TCDIR:=$(shell if [ -e "${BUILD_DIR}/iproute2-tcfull" ] ; then echo "${BUILD_DIR}/iproute2-tcfull"/ip* ; else echo "${BUILD_DIR}/iproute2-tctiny"/ip* ; fi ; )
        CFLAGS += -I$(STAGING_DIR)/usr/include
        LDFLAGS += -L$(STAGING_DIR)/usr/lib
        TCOBJS := $(TCDIR)/tc/tc_util.o
        TCOBJS += $(TCDIR)/tc/tc_core.o
        TCOBJS += $(TCDIR)/tc/q_htb.o
        TCOBJS += $(TCDIR)/lib/libnetlink.a
        TCOBJS += $(TCDIR)/lib/libutil.a
        LDLIBS += 
        LDFLAGS += -Wl,-export-dynamic
        TC_CFLAGS = -I $(TCDIR)/include -I $(TCDIR)/tc
    endif
else
    # 标准Linux使用libnl
    LDLIBS += -lnl-3 -lnl-route-3
    TC_CFLAGS = 
endif

# 调试选项
DEBUG ?= 0
ifeq ($(DEBUG),1)
    CFLAGS += -g -O0 -DQOSDBA_DEBUG
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

# 目录结构
SRC_DIR = src
INC_DIR = include
OBJ_DIR = obj
BIN_DIR = bin

# 源文件列表
SRCS = $(SRC_DIR)/main.c \
       $(SRC_DIR)/tc_ops.c \
       $(SRC_DIR)/bandwidth.c \
       $(SRC_DIR)/config.c \
       $(SRC_DIR)/monitor.c \
       $(SRC_DIR)/utils.c \
       $(SRC_DIR)/signal.c \
       $(SRC_DIR)/test.c

# 头文件列表
HEADERS = $(INC_DIR)/qosdba.h

# 对象文件
OBJS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.o,$(SRCS))

# 依赖文件
DEPS = $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.d,$(SRCS))

# 包含路径
CFLAGS += -I$(INC_DIR)

# 默认目标
all: directories $(BIN_DIR)/$(TARGET)

# 创建目录
directories:
	@mkdir -p $(OBJ_DIR) $(BIN_DIR)

# 链接可执行文件
$(BIN_DIR)/$(TARGET): $(OBJS)
ifeq ($(BUILD_MODE),openwrt)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(TCOBJS) $(LDLIBS)
else
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)
endif
	@echo "构建完成: $(TARGET) $(VERSION)"

# 包含依赖文件
-include $(DEPS)

# 编译源文件并生成依赖
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c $(HEADERS)
	$(CC) $(CFLAGS) $(TC_CFLAGS) -MMD -MP -c $< -o $@

# 清理
clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR) $(TARGET)
	@echo "已清理构建文件"

# 完全清理
distclean: clean
	rm -f tags cscope.out
	@echo "已完全清理"

# 安装
install: all
	@echo "安装 $(TARGET) 到系统..."
	install -D -m 755 $(BIN_DIR)/$(TARGET) /usr/sbin/$(TARGET)
	install -D -m 644 files/qosdba.conf /etc/qosdba.conf
	install -d -m 755 /etc/init.d
	install -m 755 files/qosdba.init /etc/init.d/qosdba
	install -d -m 755 /var/log
	touch /var/log/qosdba.log
	chmod 644 /var/log/qosdba.log
	@echo "安装完成"

# 卸载
uninstall:
	@echo "卸载 $(TARGET)..."
	rm -f /usr/sbin/$(TARGET)
	rm -f /etc/qosdba.conf
	rm -f /etc/init.d/qosdba
	@echo "卸载完成"

# 测试
test: CFLAGS += -DQOSDBA_TEST
test: all
	@echo "运行测试..."
	$(BIN_DIR)/$(TARGET) -t -f

# OpenWrt构建
openwrt: BUILD_MODE = openwrt
openwrt: all
	@echo "OpenWrt构建完成"

# 调试版本
debug: DEBUG = 1
debug: all
	@echo "调试版本构建完成"

# 发布版本
release: DEBUG = 0
release: CFLAGS += -DNDEBUG
release: all
	@echo "发布版本构建完成"

# 生成tags
tags: $(SRCS) $(HEADERS)
	ctags -R $(SRC_DIR) $(INC_DIR)
	cscope -Rb

# 代码统计
stats:
	@echo "代码统计:"
	@echo "源代码文件:"
	@wc -l $(SRCS) | tail -1
	@echo "头文件:"
	@wc -l $(HEADERS) | tail -1
	@echo "总行数:"
	@wc -l $(SRCS) $(HEADERS) | tail -1

# 帮助
help:
	@echo "QoS DBA 2.1.1 构建系统"
	@echo ""
	@echo "可用目标:"
	@echo "  all         - 默认构建 (默认)"
	@echo "  clean       - 清理构建文件"
	@echo "  distclean   - 完全清理"
	@echo "  install     - 安装到系统"
	@echo "  uninstall   - 从系统卸载"
	@echo "  test        - 构建并运行测试"
	@echo "  openwrt     - OpenWrt构建模式"
	@echo "  debug       - 调试版本构建"
	@echo "  release     - 发布版本构建"
	@echo "  tags        - 生成代码标签"
	@echo "  stats       - 代码统计"
	@echo "  help        - 显示此帮助"
	@echo ""
	@echo "环境变量:"
	@echo "  BUILD_MODE=openwrt   - 使用OpenWrt模式构建"
	@echo "  DEBUG=1              - 启用调试"
	@echo "  TEST=1               - 启用测试模式"
	@echo "  MEMDEBUG=1           - 启用内存调试"
	@echo ""
	@echo "OpenWrt构建示例:"
	@echo "  make BUILD_MODE=openwrt"
	@echo "  或"
	@echo "  make openwrt"

.PHONY: all directories clean distclean install uninstall test openwrt debug release tags stats help