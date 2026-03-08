# qosdba Makefile - 基于qosmon Makefile适配
BINDIR = /usr/sbin
#TCDIR:=$(BUILD_DIR)/iproute2-tc*/ip*
TCDIR:=$(shell if [ -e "${BUILD_DIR}/iproute2-tcfull" ] ; then echo "${BUILD_DIR}/iproute2-tcfull"/ip* ; else echo "${BUILD_DIR}/iproute2-tctiny"/ip* ; fi ; )
# The ncurses library only needed if we remove the ONLYBG switch
# below. Mostly for debug
# LDLIBS += -lncurses

# CFLAGS += -I$(STAGING_DIR)/usr/include
# LDFLAGS += -L$(STAGING_DIR)/usr/lib

LDLIBS += -lm

# TC库对象文件
TCOBJS := $(TCDIR)/tc/tc_util.o
TCOBJS += $(TCDIR)/tc/tc_core.o
TCOBJS += $(TCDIR)/tc/q_hfsc.o
TCOBJS += $(TCDIR)/lib/libnetlink.a
TCOBJS += $(TCDIR)/lib/libutil.a
LDFLAGS += -Wl,-export-dynamic

# qosdba构建目标
all: qosdba

qosdba: qosdba.o
	$(CC) $(LDFLAGS) $^ $(TCOBJS) -o $@ $(LDLIBS)

qosdba.o: qosdba.c
	$(CC) -D ONLYBG $(CFLAGS) -I $(TCDIR)/include -I $(TCDIR)/tc -c $< -o $@

install: all uninstall
	-mkdir -p $(BINDIR)
	#-mkdir -p /etc/init.d
	#-mkdir -p /etc/config
	#-mkdir -p /etc
	#-mkdir -p /etc/hotplug.d/iface
	cp qosdba $(BINDIR)
	#cp files/qosdba.init /etc/init.d/qosdba
	#chmod 755 /etc/init.d/qosdba
	#cp files/qosdba.conf /etc/qosdba.conf
	#cp files/qosdba.hotplug /etc/hotplug.d/iface/99-qosdba

uninstall:
	rm -f $(BINDIR)/qosdba
	#rm -f /etc/init.d/qosdba
	#rm -f /etc/config/qosdba
	#rm -f /etc/qosdba.conf
	#rm -f /etc/hotplug.d/iface/99-qosdba

clean:
	rm -rf *.o *~ .*sw* qosdba