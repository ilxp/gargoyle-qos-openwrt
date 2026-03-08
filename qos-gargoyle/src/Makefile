BINDIR = /usr/sbin
#TCDIR:=$(BUILD_DIR)/iproute2-tc*/ip*
TCDIR:=$(shell if [ -e "${BUILD_DIR}/iproute2-tcfull" ] ; then echo "${BUILD_DIR}/iproute2-tcfull"/ip* ; else echo "${BUILD_DIR}/iproute2-tctiny"/ip* ; fi ; )
#The ncurses library only needed if we remove the ONLYBG switch
#below.  Mostly for debug
#LDLIBS += -lncurses

LDLIBS += -lm

TCOBJS := $(TCDIR)/tc/tc_util.o
TCOBJS += $(TCDIR)/tc/tc_core.o
TCOBJS += $(TCDIR)/tc/q_hfsc.o
TCOBJS += $(TCDIR)/tc/q_htb.o
TCOBJS += $(TCDIR)/tc/q_cake.o
TCOBJS += $(TCDIR)/lib/libnetlink.a
TCOBJS += $(TCDIR)/lib/libutil.a
LDFLAGS += -Wl,-export-dynamic 

all: qosacc

qosacc: qosacc.o
	$(CC) $(LDFLAGS) $^ $(TCOBJS) -o $@ $(LDLIBS)

qosacc.o: qosacc.c
	$(CC) -D ONLYBG $(CFLAGS) -I $(TCDIR)/include -I $(TCDIR)/tc -c $^ -o $@

install: all uninstall
	-mkdir -p $(BINDIR)
	cp qosacc  $(BINDIR)

uninstall:
	rm -f $(BINDIR)/qosacc

clean:
	rm -rf *.o *~ .*sw* qosacc
