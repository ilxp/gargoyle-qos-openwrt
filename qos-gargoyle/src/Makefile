BINDIR = /usr/sbin

# 不再需要iproute2的路径设置
# TCDIR:=$(shell if [ -e "${BUILD_DIR}/iproute2-tcfull" ] ; then echo "${BUILD_DIR}/iproute2-tcfull"/ip* ; else echo "${BUILD_DIR}/iproute2-tctiny"/ip* ; fi ; )

# 链接库设置 - 添加libnl
LDLIBS += -lm -lnl-3 -lnl-route-3
# 如果需要支持ncurses（调试界面），可以取消下面注释
# LDLIBS += -lncurses

# 编译标志
CFLAGS += -Wall -O2
LDFLAGS += -Wl,-export-dynamic 

# 移除ONLYBG标志，因为代码中已不依赖此宏
# 如果需要后台模式，代码中已通过命令行参数控制

all: qosmon

qosmon: qosmon.o
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

qosmon.o: qosmon.c
	$(CC) $(CFLAGS) -c $^ -o $@

install: all uninstall
	-mkdir -p $(BINDIR)
	cp qosmon $(BINDIR)

uninstall:
	rm -f $(BINDIR)/qosmon

clean:
	rm -rf *.o *~ .*sw* qosmon
