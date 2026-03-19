# idclass Makefile
CC = gcc
CFLAGS = -O2 -Wall
LDFLAGS = -lbpf -luci -lelf -lz -lubox -lubus

DESTDIR ?=
BINDIR ?= /usr/sbin
INITDIR ?= /etc/init.d

TARGET = idclass
BPF_OBJ = idclass_kern.o
SKEL = idclass.skel.h

USER_SRCS = main.c loader.c map.c interface.c dns.c ubus.c
USER_OBJS = $(USER_SRCS:.c=.o)

all: $(TARGET)

$(BPF_OBJ): idclass-bpf.c idclass.h
	clang -target bpf -g -O2 -c $< -o $@

$(SKEL): $(BPF_OBJ)
	bpftool gen skeleton $(BPF_OBJ) > $(SKEL)

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