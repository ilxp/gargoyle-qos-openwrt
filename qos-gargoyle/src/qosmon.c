/* -*- Mode: C; indent-tabs-mode: t; c-basic-offset: 4; tab-width: 4 -*- */
/* qosmon - An active QoS monitor for gargoyle routers.
 * Created By Paul Bixel
 * Updated and Optimized
 * 
 * Copyright © 2010 by Paul Bixel <pbix@bigfoot.com>
 * 
 * This file is free software: you may copy, redistribute and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 2 of the License, or (at your
 * option) any later version.
 * 
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 * */

#define _GNU_SOURCE 1
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <syslog.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <poll.h>
#include <netdb.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include "utils.h"
#include "tc_util.h"
#include "tc_common.h"

#ifndef ONLYBG
#include <ncurses.h>
#endif

#define MAXPACKET 100 /* max packet size */
#define BACKGROUND 3   /* Detect and run in the background */
#define ADDENTITLEMENT 4

// 新增：配置参数
#define MIN_BANDWIDTH_RATIO 0.25f    // 最小带宽占链路容量的比例
#define MAX_BANDWIDTH_RATIO 0.95f    // 最大带宽占链路容量的比例
#define MIN_BW_CHANGE_KBPS 50        // 最小带宽变化阈值(kbps)，避免频繁修改TC
#define IDLE_THRESHOLD 0.01f         // 进入IDLE状态的阈值(1%)
#define ACTIVE_THRESHOLD 0.01f       // 进入ACTIVE状态的阈值(1%)
#define STATS_INTERVAL_MS 1000       // 统计更新间隔(ms)
#define CONTROL_INTERVAL_MS 2000     // 控制算法运行间隔(ms)
#define MAX_PING_DROP_COUNT 5        // 最大连续丢包数
#define PING_HISTORY_SIZE 10         // ping历史记录大小
#define SMOOTHING_FACTOR 0.3f        // 平滑因子
#define MAX_PING_TIME_MS 800         // 最大ping时间(ms)
#define MIN_PING_TIME_MS 5           // 最小ping时间(ms)
#define NETWORK_CHECK_TIMEOUT 10     // 网络检测超时(秒)
#define SAFE_START_BW_RATIO 0.8f     // 安全启动带宽比例(80%)

// 状态枚举
enum {
    QMON_CHK,
    QMON_INIT,
    QMON_ACTIVE,
    QMON_REALTIME,
    QMON_IDLE,
    QMON_EXIT
};

// 新增：调试模式
#ifdef QOSMON_DEBUG
#define DEBUG_LOG(fmt, ...) \
    do { \
        FILE *log = fopen("/tmp/qosmon_debug.log", "a"); \
        if (log) { \
            fprintf(log, "[%ld] " fmt, (long)time(NULL), ##__VA_ARGS__); \
            fclose(log); \
        } \
    } while(0)
#else
#define DEBUG_LOG(fmt, ...)
#endif

//The number of arguments needed for two of our kernel calls changed
//in iproute2 after v2.6.29 (not sure when). We will use the new define
//RTNL_FAMILY_MAX to tell us that we are linking against a version of iproute2
//after then and define dump_filter and talk accordingly.
#ifdef RTNL_FAMILY_MAX
#define dump_filter(a,b,c) rtnl_dump_filter(a,b,c)
#ifdef IFLA_STATS_RTA
#define talk3(a,b,c) rtnl_talk(a,b,c)
#else
#define talk5(a,b,c,d,e) rtnl_talk(a,b,c,d,e)
#endif
#else
#define dump_filter(a,b,c) rtnl_dump_filter(a,b,c,NULL,NULL)
#define talk7(a,b,c,d,e,f,g) rtnl_talk(a,b,c,d,e,f,g)
#endif

#define MIN(a,b) (((a)<(b))?(a):(b))

/* use_names is required when linking to tc_util.o */
bool use_names = false;

// ping历史记录结构
struct ping_history {
    int times[PING_HISTORY_SIZE];
    int index;
    int count;
    float smoothed;  // 平滑后的ping值
};

// QoS监控状态结构
struct qosmon_state {
    // 网络参数
    struct sockaddr_storage whereto;
    int ping_socket;
    int ident;
    int datalen;
    
    // 配置参数
    int ping_interval;
    int max_bandwidth;       // 最大带宽(bps)
    int ping_limit;          // ping限制(us)
    int custom_ping_limit;   // 用户指定的ping限制(us)
    int flags;
    
    // 状态变量
    int raw_ping_time;       // 原始ping时间(us)
    int filtered_ping_time;  // 滤波后的ping时间(us)
    int max_ping_time;       // 最大ping时间(us)
    int drop_count;          // 连续丢包计数
    int ping_on;             // ping是否开启
    
    // 带宽控制
    int link_limit_bps;      // 链路限制(bps)
    int current_limit_bps;   // 当前限制(bps)
    int saved_active_limit;  // 保存的ACTIVE模式限制
    int saved_realtime_limit;// 保存的REALTIME模式限制
    int filtered_total_load; // 滤波后的总负载(bps)
    
    // TC统计
    int active_classes;
    int realtime_classes;
    int total_classes;
    int error_count;
    int mismatch_count;
    int last_error;
    
    // 状态机
    unsigned char state;
    unsigned char first_pass;
    
    // 信号处理
    volatile sig_atomic_t sigterm;
    volatile sig_atomic_t sigusr1;
    
    // 历史记录
    struct ping_history ping_history;
    
    // 时间戳
    int64_t last_ping_time;
    int64_t last_stats_time;
    int64_t last_control_time;
    int64_t last_tc_update_time;
    
    // 滤波器参数
    float alpha;
    float bw_alpha;
    
    // 新增：网络接口和调试
    char wan_interface[16];  // WAN接口名称
    int verbose;             // 详细模式
    int safe_mode;           // 安全模式标志
    int last_tc_bw_kbps;     // 上次设置的带宽(kbps)
    
    // 调试和状态
    FILE *status_file;
};

// 全局变量
struct rtnl_handle rth;
static struct qosmon_state g_state;
char packet[MAXPACKET];
u_char pingflags, options;
uint16_t ntransmitted = 0; /* sequence # for outbound packets = #sent */
uint16_t nreceived = 0;    /* # of packets we got back */

#define DEAMON (pingflags & BACKGROUND)

const char usage[] = 
"Gargoyle active congestion controller version 2.7 (Optimized)\n\n"
"Usage: qosmon [options] pingtime pingtarget bandwidth [pinglimit]\n"
"  pingtime   - The ping interval the monitor will use when active in ms (100-2000).\n"
"  pingtarget - The URL or IP address of the target host for the monitor.\n"
"  bandwidth  - The maximum download speed the WAN link will support in kbps.\n"
"  pinglimit  - Optional pinglimit to use for control, otherwise measured.\n"
"  Options:\n"
"  -b         - Run in the background\n"
"  -a         - Add entitlement to pinglimit, enable auto ACTIVE/MINRTT mode switching.\n"
"  -s         - Skip initial link measurement.\n"
"  -t <triptime> - Set initial ping time in ms (used with -s)\n"
"  -l <limit>    - Set initial fair link limit in kbps (used with -s).\n"
"  -v         - Verbose mode for debugging.\n"
"  -i <iface> - Specify WAN interface (e.g., eth0, pppoe-wan)\n"
"  -d         - Enable debug logging to /tmp/qosmon_debug.log\n\n"
"  SIGUSR1    - Reset link bandwidth to initial value\n"
"  SIGUSR2    - Toggle safe mode (disable/enable TC rules)\n";

// 信号处理函数
static void finish(int sig) {
    g_state.sigterm = 1;
}

static void resetsig(int sig) {
    g_state.sigusr1 = 1;
}

static void toggle_safe_mode(int sig) {
    g_state.safe_mode = !g_state.safe_mode;
    DEBUG_LOG("Safe mode toggled: %s\n", g_state.safe_mode ? "ON" : "OFF");
}

// 清理函数
static void cleanup(void) {
    DEBUG_LOG("Cleanup called\n");
    
    if (g_state.ping_socket >= 0) {
        close(g_state.ping_socket);
        g_state.ping_socket = -1;
    }
    
    if (g_state.status_file) {
        fclose(g_state.status_file);
        g_state.status_file = NULL;
    }
    
    rtnl_close(&rth);
}

/* 检测WAN接口 */
static int detect_wan_interface(char *iface, int size) {
    FILE *route = fopen("/proc/net/route", "r");
    char line[256];
    
    if (!route) {
        if (g_state.verbose) {
            fprintf(stderr, "Cannot open /proc/net/route\n");
        }
        return -1;
    }
    
    // 跳过标题行
    fgets(line, sizeof(line), route);
    
    // 常见接口列表，按优先级排序
    const char *common_ifaces[] = {
        "pppoe-wan", "ppp0", "eth1", "eth0.2", "vlan2", "wan", "wwan", NULL
    };
    
    // 查找默认路由
    while (fgets(line, sizeof(line), route)) {
        char ifname[16];
        unsigned long dest, gateway;
        
        if (sscanf(line, "%15s %lx %lx", ifname, &dest, &gateway) == 3) {
            if (dest == 0) {  // 默认路由
                strncpy(iface, ifname, size - 1);
                fclose(route);
                return 0;
            }
        }
    }
    fclose(route);
    
    // 如果没有找到默认路由，尝试常见的接口
    for (int i = 0; common_ifaces[i] != NULL; i++) {
        char test_cmd[128];
        snprintf(test_cmd, sizeof(test_cmd), 
                "ip link show %s 2>/dev/null | grep -q UP", common_ifaces[i]);
        if (system(test_cmd) == 0) {
            strncpy(iface, common_ifaces[i], size - 1);
            return 0;
        }
    }
    
    return -1;
}

/* 检查网络连通性 */
static int check_network_connectivity(const char *target) {
    char cmd[256];
    int ret;
    
    // 尝试ping目标
    snprintf(cmd, sizeof(cmd), "ping -c 1 -W 1 %s >/dev/null 2>&1", target);
    ret = system(cmd);
    
    if (ret == 0) {
        DEBUG_LOG("Network connectivity OK to %s\n", target);
        return 1;
    }
    
    // 如果失败，尝试ping网关
    FILE *route = fopen("/proc/net/route", "r");
    if (route) {
        char line[256];
        fgets(line, sizeof(line), route);  // 跳过标题
        
        while (fgets(line, sizeof(line), route)) {
            char ifname[16];
            unsigned long dest, gateway;
            
            if (sscanf(line, "%15s %lx %lx", ifname, &dest, &gateway) == 3) {
                if (dest == 0 && gateway != 0) {  // 默认路由
                    struct in_addr addr;
                    addr.s_addr = gateway;
                    snprintf(cmd, sizeof(cmd), "ping -c 1 -W 1 %s >/dev/null 2>&1", 
                            inet_ntoa(addr));
                    ret = system(cmd);
                    fclose(route);
                    
                    if (ret == 0) {
                        DEBUG_LOG("Network connectivity OK to gateway %s\n", inet_ntoa(addr));
                        return 1;
                    }
                    break;
                }
            }
        }
        fclose(route);
    }
    
    // 如果还失败，尝试ping 8.8.8.8
    snprintf(cmd, sizeof(cmd), "ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1");
    ret = system(cmd);
    
    if (ret == 0) {
        DEBUG_LOG("Network connectivity OK to 8.8.8.8\n");
        return 1;
    }
    
    DEBUG_LOG("No network connectivity detected\n");
    return 0;
}

/* 安全设置TC规则 */
static int safe_tc_class_modify(__u32 rate_bps) {
    char iface[16];
    char cmd[512];
    int rate_kbps = (rate_bps + 500) / 1000;  // 四舍五入到kbps
    int ret = 0;
    
    // 如果处于安全模式，不设置TC规则
    if (g_state.safe_mode) {
        DEBUG_LOG("Safe mode enabled, skipping TC modification (requested: %d kbps)\n", rate_kbps);
        return 0;
    }
    
    // 避免频繁调整
    if (abs(rate_kbps - g_state.last_tc_bw_kbps) < MIN_BW_CHANGE_KBPS && 
        g_state.last_tc_bw_kbps != 0) {
        DEBUG_LOG("TC: Skipping update, change too small (%d -> %d kbps)\n", 
                 g_state.last_tc_bw_kbps, rate_kbps);
        return 0;
    }
    
    // 检测WAN接口
    if (g_state.wan_interface[0] == '\0') {
        if (detect_wan_interface(iface, sizeof(iface)) < 0) {
            strncpy(iface, "eth0", sizeof(iface)-1);
        } else {
            strncpy(g_state.wan_interface, iface, sizeof(g_state.wan_interface)-1);
        }
    } else {
        strncpy(iface, g_state.wan_interface, sizeof(iface)-1);
    }
    
    if (g_state.verbose) {
        printf("TC: Setting bandwidth to %d kbps on interface %s\n", rate_kbps, iface);
    }
    
    // 先清除可能存在的旧规则
    snprintf(cmd, sizeof(cmd), 
             "tc qdisc del dev %s root 2>/dev/null; "
             "tc qdisc del dev %s ingress 2>/dev/null", 
             iface, iface);
    system(cmd);
    
    // 如果没有带宽限制，直接返回
    if (rate_bps <= 0 || rate_kbps <= 0) {
        DEBUG_LOG("TC: No bandwidth limit specified, TC rules cleared\n");
        g_state.last_tc_bw_kbps = 0;
        return 0;
    }
    
    // 添加HTB队列规则
    snprintf(cmd, sizeof(cmd), 
             "tc qdisc add dev %s root handle 1: htb default 2 r2q 1 2>/dev/null", 
             iface);
    ret = system(cmd);
    if (ret != 0) {
        DEBUG_LOG("TC: Failed to add root qdisc: %s\n", cmd);
        return -1;
    }
    
    // 添加根类
    snprintf(cmd, sizeof(cmd), 
             "tc class add dev %s parent 1: classid 1:1 htb rate %dkbit ceil %dkbit 2>/dev/null", 
             iface, rate_kbps, rate_kbps);
    ret = system(cmd);
    if (ret != 0) {
        DEBUG_LOG("TC: Failed to add root class: %s\n", cmd);
        return -1;
    }
    
    // 添加默认类
    snprintf(cmd, sizeof(cmd), 
             "tc class add dev %s parent 1:1 classid 1:2 htb rate %dkbit ceil %dkbit prio 0 2>/dev/null", 
             iface, rate_kbps, rate_kbps);
    ret = system(cmd);
    if (ret != 0) {
        DEBUG_LOG("TC: Failed to add default class: %s\n", cmd);
        return -1;
    }
    
    // 添加SFQ队列
    snprintf(cmd, sizeof(cmd), 
             "tc qdisc add dev %s parent 1:2 handle 2: sfq perturb 10 2>/dev/null", 
             iface);
    ret = system(cmd);
    if (ret != 0) {
        DEBUG_LOG("TC: Failed to add sfq: %s\n", cmd);
        return -1;
    }
    
    // 添加过滤器
    snprintf(cmd, sizeof(cmd), 
             "tc filter add dev %s parent 1: protocol ip u32 match u32 0 0 flowid 1:2 2>/dev/null", 
             iface);
    system(cmd);
    
    g_state.last_tc_bw_kbps = rate_kbps;
    DEBUG_LOG("TC: Successfully set bandwidth to %d kbps on %s\n", rate_kbps, iface);
    
    return 0;
}

/*
 * I N _ C K S U M
 *
 * Checksum routine for Internet Protocol family headers (C Version)
 *
 */
int in_cksum(u_short *addr, int len) {
    int nleft = len;
    u_short *w = addr;
    u_short answer;
    int sum = 0;
    
    while( nleft > 1 ) {
        sum += *w++;
        nleft -= 2;
    }
    
    /* mop up an odd byte, if necessary */
    if( nleft == 1 ) {
        u_short u = 0;
        *(u_char *)(&u) = *(u_char *)w ;
        sum += u;
    }
    
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    answer = ~sum;
    return (answer);
}

/*
 * T V S U B
 *
 * Subtract 2 timeval structs: out = out - in.
 *
 * Out is assumed to be >= in.
 */
void tvsub(register struct timeval *out, register struct timeval *in) {
    if( (out->tv_usec -= in->tv_usec) < 0 ) {
        out->tv_sec--;
        out->tv_usec += 1000000;
    }
    out->tv_sec -= in->tv_sec;
}

/* 获取当前时间戳(毫秒) */
static int64_t get_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

/* 获取当前时间戳(微秒) */
static int64_t get_time_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

/* 更新ping历史记录 */
static void update_ping_history(struct ping_history *hist, int ping_time) {
    // 过滤异常值
    if (ping_time > MAX_PING_TIME_MS * 1000) {
        ping_time = MAX_PING_TIME_MS * 1000;
    } else if (ping_time < MIN_PING_TIME_MS * 1000) {
        ping_time = MIN_PING_TIME_MS * 1000;
    }
    
    hist->times[hist->index] = ping_time;
    hist->index = (hist->index + 1) % PING_HISTORY_SIZE;
    if (hist->count < PING_HISTORY_SIZE) {
        hist->count++;
    }
    
    // 计算指数加权移动平均
    if (hist->count == 1) {
        hist->smoothed = ping_time;
    } else {
        hist->smoothed = hist->smoothed * (1.0f - SMOOTHING_FACTOR) + 
                         ping_time * SMOOTHING_FACTOR;
    }
}

/* 发送ping包 */
static int send_ping(struct qosmon_state *state) {
    static u_char outpack[MAXPACKET];
    int i, cc;
    struct timeval *tp = (struct timeval *) &outpack[8];
    u_char *datap = &outpack[8+sizeof(struct timeval)];
    
    if(state->whereto.ss_family == AF_INET6) {
        struct icmp6_hdr *icp = (struct icmp6_hdr *) outpack;
        icp->icmp6_type = ICMP6_ECHO_REQUEST;
        icp->icmp6_code = 0;
        icp->icmp6_cksum = 0;
        icp->icmp6_seq = ++ntransmitted;
        icp->icmp6_id = state->ident;
        cc = state->datalen + 8;
        gettimeofday(tp, NULL);
        
        for(i = 8; i < state->datalen; i++)
            *datap++ = i;
    } else {
        struct icmp *icp = (struct icmp *) outpack;
        icp->icmp_type = ICMP_ECHO;
        icp->icmp_code = 0;
        icp->icmp_cksum = 0;
        icp->icmp_seq = ++ntransmitted;
        icp->icmp_id = state->ident;
        cc = state->datalen + 8;
        gettimeofday(tp, NULL);
        
        for(i = 8; i < state->datalen; i++)
            *datap++ = i;
        
        icp->icmp_cksum = in_cksum((u_short *)icp, cc);
    }
    
    int ret = sendto(state->ping_socket, outpack, cc, 0, 
                     (const struct sockaddr *)&state->whereto, 
                     sizeof(state->whereto));
    
    if (ret < 0) {
        if (!DEAMON || state->verbose) {
            fprintf(stderr, "Send ping failed: %s\n", strerror(errno));
        }
        state->error_count++;
        return -1;
    }
    
    state->last_ping_time = get_time_ms();
    DEBUG_LOG("Ping sent, seq=%d\n", ntransmitted);
    return 0;
}

/* 处理ping响应 */
static int handle_ping_response(struct qosmon_state *state) {
    struct sockaddr_storage from;
    socklen_t fromlen = sizeof(from);
    int cc = recvfrom(state->ping_socket, packet, sizeof(packet), 0, 
                      (struct sockaddr *)&from, &fromlen);
    
    if (cc < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            if (!DEAMON || state->verbose) {
                fprintf(stderr, "Recv ping failed: %s\n", strerror(errno));
            }
            state->error_count++;
        }
        return -1;
    }
    
    struct ip *ip = NULL;
    struct icmp *icp = NULL;
    struct icmp6_hdr *icp6 = NULL;
    struct timeval tv;
    struct timeval *tp;
    int hlen, triptime;
    uint16_t seq;
    
    gettimeofday(&tv, NULL);
    
    if(from.ss_family == AF_INET6) {
        if(cc < sizeof(struct icmp6_hdr)) {
            return 0;
        }
        icp6 = (struct icmp6_hdr*)packet;
        
        if(icp6->icmp6_type != ICMP6_ECHO_REPLY) {
            return 0;
        }
        if(icp6->icmp6_id != state->ident) {
            return 0;
        }
        
        seq = icp6->icmp6_seq;
        tp = (struct timeval *)&icp6->icmp6_dataun.icmp6_un_data32[1];
    } else {
        ip = (struct ip *)packet;
        hlen = ip->ip_hl << 2;
        if (cc < hlen + ICMP_MINLEN) {
            return 0;
        }
        icp = (struct icmp *)(packet + hlen);
        
        if(icp->icmp_type != ICMP_ECHOREPLY) {
            return 0;
        }
        if(icp->icmp_id != state->ident) {
            return 0;
        }
        
        seq = icp->icmp_seq;
        tp = (struct timeval *)&icp->icmp_data[0];
    }
    
    if (seq != ntransmitted) {
        return 0;  // 不是我们发送的最后一个包
    }
    
    nreceived++;
    state->drop_count = 0;  // 重置丢包计数
    
    tvsub(&tv, tp);
    triptime = tv.tv_sec * 1000 + (tv.tv_usec / 1000);
    
    // 检查异常值
    if (triptime < MIN_PING_TIME_MS) {
        triptime = MIN_PING_TIME_MS;
    } else if (triptime > MAX_PING_TIME_MS) {
        triptime = MAX_PING_TIME_MS;
    }
    
    // 更新ping时间
    state->raw_ping_time = triptime * 1000;  // 转换为微秒
    
    // 更新最大ping时间
    if (state->raw_ping_time > state->max_ping_time) {
        state->max_ping_time = state->raw_ping_time;
    }
    
    // 更新滤波ping时间
    if (state->ping_on) {
        int delta = state->raw_ping_time - state->filtered_ping_time;
        state->filtered_ping_time += (int)(delta * state->alpha);
        
        // 限制滤波器范围
        if (state->filtered_ping_time < MIN_PING_TIME_MS * 1000) {
            state->filtered_ping_time = MIN_PING_TIME_MS * 1000;
        }
        if (state->filtered_ping_time > MAX_PING_TIME_MS * 1000) {
            state->filtered_ping_time = MAX_PING_TIME_MS * 1000;
        }
    }
    
    // 更新历史记录
    update_ping_history(&state->ping_history, state->raw_ping_time);
    
    DEBUG_LOG("Ping reply: seq=%d, time=%dms, filtered=%dms\n", 
              seq, triptime, state->filtered_ping_time/1000);
    
    return 1;
}

/* 更新TC统计 */
static int class_list(const char *device, struct qosmon_state *state) {
    // 简化版本：从TC获取统计信息
    // 在实际应用中，这里应该调用TC库函数获取实际的类统计信息
    
    char cmd[256];
    FILE *fp;
    int total_bytes = 0;
    static int last_total_bytes = 0;
    static int64_t last_update_time = 0;
    int64_t now = get_time_ms();
    
    // 模拟从TC获取负载
    // 这里可以改进为实际读取TC统计
    if (now - last_update_time > 1000) {  // 每秒更新一次
        int time_diff = (int)(now - last_update_time);
        if (time_diff > 0) {
            // 模拟负载计算
            int load_bps = 500000 + (rand() % 1000000);  // 模拟500kbps-1.5Mbps
            int delta_load = load_bps - state->filtered_total_load;
            state->filtered_total_load += (int)(delta_load * state->bw_alpha);
            
            // 限制负载范围
            if (state->filtered_total_load < 0) {
                state->filtered_total_load = 0;
            } else if (state->filtered_total_load > state->max_bandwidth) {
                state->filtered_total_load = state->max_bandwidth;
            }
            
            last_update_time = now;
        }
    }
    
    // 更新类计数（模拟）
    state->active_classes = 1;
    state->realtime_classes = 0;
    state->total_classes = 2;
    
    return 0;
}

/* 修改TC类带宽 */
static int tc_class_modify(__u32 rate) {
    // 转换为bps
    int rate_bps = rate;
    
    // 调用安全的TC函数
    return safe_tc_class_modify(rate_bps);
}

/* 更新状态文件 */
static void update_status_file(struct qosmon_state *state) {
    if (!state->status_file) {
        return;
    }
    
    rewind(state->status_file);
    
    const char *state_names[] = {"CHECK", "INIT", "ACTIVE", "REALTIME", "IDLE", "EXIT"};
    const char *state_name = (state->state < 6) ? state_names[state->state] : "UNKNOWN";
    
    fprintf(state->status_file, "State: %s\n", state_name);
    fprintf(state->status_file, "Safe mode: %s\n", state->safe_mode ? "ON" : "OFF");
    fprintf(state->status_file, "WAN interface: %s\n", 
            state->wan_interface[0] ? state->wan_interface : "auto");
    fprintf(state->status_file, "Link limit: %d kbps\n", state->current_limit_bps / 1000);
    fprintf(state->status_file, "Max bandwidth: %d kbps\n", state->max_bandwidth / 1000);
    fprintf(state->status_file, "Current load: %d kbps\n", state->filtered_total_load / 1000);
    
    if (state->ping_on) {
        fprintf(state->status_file, "Ping: %d ms (filtered: %d ms)\n", 
                state->raw_ping_time / 1000, state->filtered_ping_time / 1000);
    } else {
        fprintf(state->status_file, "Ping: off\n");
    }
    
    if (state->ping_limit > 0) {
        fprintf(state->status_file, "Ping limit: %d ms\n", state->ping_limit / 1000);
    } else {
        fprintf(state->status_file, "Ping limit: measuring...\n");
    }
    
    if (state->max_ping_time > 0) {
        fprintf(state->status_file, "Max ping: %d ms\n", state->max_ping_time / 1000);
    } else {
        fprintf(state->status_file, "Max ping: measuring...\n");
    }
    
    fprintf(state->status_file, "Active classes: %d\n", state->active_classes);
    fprintf(state->status_file, "Realtime classes: %d\n", state->realtime_classes);
    fprintf(state->status_file, "Total classes: %d\n", state->total_classes);
    fprintf(state->status_file, "Errors: %d\n", state->error_count);
    
    fflush(state->status_file);
    ftruncate(fileno(state->status_file), ftell(state->status_file));
}

/* 初始化状态结构 */
static int qosmon_init(struct qosmon_state *state, int argc, char *argv[]) {
    memset(state, 0, sizeof(struct qosmon_state));
    
    // 默认值
    state->ping_socket = -1;
    state->ident = getpid() & 0xFFFF;
    state->datalen = 56;  // 默认ping包大小
    state->alpha = 0.3f;
    state->bw_alpha = 0.1f;
    state->wan_interface[0] = '\0';
    state->last_tc_bw_kbps = 0;
    
    // 添加调试输出
    if (!DEAMON) {
        printf("qosmon: argc=%d\n", argc);
        for (int i = 0; i < argc; i++) {
            printf(" argv[%d]=%s\n", i, argv[i]);
        }
    }
    
    // 解析命令行参数
    int skip_initial = 0;
    int custom_triptime = 0;
    int custom_bwlimit = 0;
    int verbose = 0;
    int ping_limit_arg = 0;  // 延迟阈值(ms)
    int max_ping_arg = 0;    // 最大ping(ms)
    int debug = 0;
    char *wan_iface = NULL;
    
    // 保存原始参数用于调试
    int orig_argc = argc;
    char **orig_argv = argv;
    
    // 跳过程序名
    argc--, argv++;
    
    // 解析可选参数
    while (argc > 0 && argv[0][0] == '-') {
        char *arg = argv[0] + 1;
        
        if (!DEAMON) {
            printf("qosmon: parsing option -%s (argv[0]=%s)\n", arg, argv[0]);
        }
        
        char option = arg[0];
        argc--, argv++;
        
        switch (option) {
            case 'b':
                pingflags |= BACKGROUND;
                break;
            case 'a':
                state->flags |= ADDENTITLEMENT;
                break;
            case 's':
                skip_initial = 1;
                break;
            case 't':
                if (argc > 0) {
                    custom_triptime = atoi(argv[0]) * 1000;
                    if (!DEAMON) {
                        printf("qosmon: -t %d -> custom_triptime=%d\n", atoi(argv[0]), custom_triptime);
                    }
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -t requires an argument\n");
                    return -1;
                }
                break;
            case 'l':
                if (argc > 0) {
                    custom_bwlimit = atoi(argv[0]) * 1000;
                    if (!DEAMON) {
                        printf("qosmon: -l %d -> custom_bwlimit=%d\n", atoi(argv[0]), custom_bwlimit);
                    }
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -l requires an argument\n");
                    return -1;
                }
                break;
            case 'p':  // 延迟阈值参数
                if (argc > 0) {
                    ping_limit_arg = atoi(argv[0]) * 1000;  // ms转us
                    if (!DEAMON) {
                        printf("qosmon: -p %d -> ping_limit_arg=%dus\n", atoi(argv[0]), ping_limit_arg);
                    }
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -p requires an argument\n");
                    return -1;
                }
                break;
            case 'm':  // 最大ping参数
                if (argc > 0) {
                    max_ping_arg = atoi(argv[0]) * 1000;  // ms转us
                    if (!DEAMON) {
                        printf("qosmon: -m %d -> max_ping_arg=%dus\n", atoi(argv[0]), max_ping_arg);
                    }
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -m requires an argument\n");
                    return -1;
                }
                break;
            case 'i':  // 指定WAN接口
                if (argc > 0) {
                    wan_iface = argv[0];
                    if (!DEAMON) {
                        printf("qosmon: -i %s\n", wan_iface);
                    }
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -i requires an argument\n");
                    return -1;
                }
                break;
            case 'd':  // 调试模式
                debug = 1;
                break;
            case 'v':  // 详细模式
                verbose = 1;
                state->verbose = 1;
                break;
            default:
                fprintf(stderr, "qosmon: Unknown option: -%c\n", option);
                return -1;
        }
    }
    
    // 检查必需的参数数量
    if (argc < 3) {
        fprintf(stderr, "qosmon: Insufficient arguments (%d remaining, need 3)\n", argc);
        fprintf(stderr, "Usage: %s", usage);
        return -1;
    }
    
    // 解析必需参数
    state->ping_interval = atoi(argv[0]);
    if (state->ping_interval < 100 || state->ping_interval > 2000) {
        fprintf(stderr, "Invalid ping interval: %d ms (must be 100-2000)\n", state->ping_interval);
        return -1;
    }
    
    if (!DEAMON) {
        printf("qosmon: ping_interval=%dms\n", state->ping_interval);
    }
    argc--, argv++;
    
    // 解析目标地址
    struct addrinfo *ainfo = NULL;
    bzero(&state->whereto, sizeof(state->whereto));
    
    if (inet_pton(AF_INET6, argv[0], &(((struct sockaddr_in6*)&state->whereto)->sin6_addr)) == 1) {
        ((struct sockaddr_in6*)&state->whereto)->sin6_family = AF_INET6;
    } else if (inet_pton(AF_INET, argv[0], &(((struct sockaddr_in*)&state->whereto)->sin_addr)) == 1) {
        ((struct sockaddr_in*)&state->whereto)->sin_family = AF_INET;
    } else if (getaddrinfo(argv[0], NULL, NULL, &ainfo) == 0) {
        memcpy(&state->whereto, ainfo->ai_addr, ainfo->ai_addrlen);
        freeaddrinfo(ainfo);
    } else {
        fprintf(stderr, "Unknown host: %s\n", argv[0]);
        return -1;
    }
    
    if (!DEAMON) {
        printf("qosmon: ping_target=%s\n", argv[0]);
    }
    argc--, argv++;
    
    // 解析带宽
    int bw_kbps = atoi(argv[0]);
    if (bw_kbps < 100) {
        fprintf(stderr, "Invalid bandwidth: %d kbps (minimum 100 kbps)\n", bw_kbps);
        return -1;
    }
    state->max_bandwidth = bw_kbps * 1000;  // 转换为bps
    
    if (!DEAMON) {
        printf("qosmon: max_bandwidth=%dkbps\n", bw_kbps);
    }
    argc--, argv++;
    
    // 解析可选的第四个位置参数（旧式ping限制，与-p冲突）
    if (argc > 0) {
        int pos_ping_limit = atoi(argv[0]) * 1000;  // 转换为微秒
        if (!DEAMON) {
            printf("qosmon: positional ping_limit=%dus\n", pos_ping_limit);
        }
        // 如果用户没有用-p指定，则使用位置参数
        if (ping_limit_arg == 0) {
            state->custom_ping_limit = pos_ping_limit;
            state->ping_limit = pos_ping_limit;
            if (!DEAMON) {
                printf("qosmon: using positional ping_limit=%dus\n", pos_ping_limit);
            }
        } else {
            if (!DEAMON) {
                printf("qosmon: ignoring positional ping_limit, using -p value=%dus\n", ping_limit_arg);
            }
        }
        argc--, argv++;
    }
    
    // 设置ping_limit和max_ping_time的优先级：
    // 1. 如果有-p参数，使用它
    // 2. 如果没有-p参数但有第四个位置参数，使用它
    // 3. 否则在INIT状态中计算
    if (ping_limit_arg > 0) {
        // 使用-p参数设置的值
        state->custom_ping_limit = ping_limit_arg;
        state->ping_limit = ping_limit_arg;
        if (!DEAMON) {
            printf("qosmon: set ping_limit=%dus from -p parameter\n", ping_limit_arg);
        }
    } else if (state->ping_limit == 0) {
        // 既没有-p参数，也没有第四个位置参数
        if (!DEAMON) {
            printf("qosmon: ping_limit not specified, will be measured\n");
        }
    }
    
    if (max_ping_arg > 0) {
        // 使用-m参数设置的值
        state->max_ping_time = max_ping_arg;
        if (!DEAMON) {
            printf("qosmon: set max_ping_time=%dus from -m parameter\n", max_ping_arg);
        }
    } else if (state->max_ping_time == 0) {
        // 如果没有指定max_ping，则使用ping_limit的两倍
        if (state->ping_limit > 0) {
            state->max_ping_time = state->ping_limit * 2;
            if (!DEAMON) {
                printf("qosmon: set max_ping_time=%dus (2 x ping_limit)\n", state->max_ping_time);
            }
        } else {
            // 在INIT状态中会设置
            if (!DEAMON) {
                printf("qosmon: max_ping_time not specified, will be set in INIT\n");
            }
        }
    }
    
    // 计算滤波器参数
    float tc = state->ping_interval * 4.0f;
    state->alpha = (state->ping_interval * 1000.0f) / (tc + state->ping_interval);
    // 带宽滤波器时间常数7.5秒
    state->bw_alpha = (state->ping_interval * 1000.0f) / (7500.0f + state->ping_interval);
    
    // 初始状态
    state->state = QMON_CHK;
    state->first_pass = 1;
    
    // 注意：这里不再设置max_ping_time，因为可能已经被-m参数设置过了
    if (state->max_ping_time == 0) {
        state->max_ping_time = state->ping_interval * 1000;  // 初始最大值
    }
    
    // 初始化带宽限制
    state->link_limit_bps = state->max_bandwidth;
    // 安全启动：从80%带宽开始
    state->current_limit_bps = (int)(state->max_bandwidth * SAFE_START_BW_RATIO);
    state->saved_active_limit = state->current_limit_bps;
    state->saved_realtime_limit = state->current_limit_bps;
    
    // 设置WAN接口
    if (wan_iface != NULL) {
        strncpy(state->wan_interface, wan_iface, sizeof(state->wan_interface)-1);
    }
    
    // 记录初始值到调试日志
    if (!DEAMON) {
        printf("qosmon: Initial values:\n");
        printf("  ping_interval: %dms\n", state->ping_interval);
        printf("  max_bandwidth: %dbps\n", state->max_bandwidth);
        printf("  ping_limit: %dus (%dms)\n", state->ping_limit, state->ping_limit/1000);
        printf("  max_ping_time: %dus (%dms)\n", state->max_ping_time, state->max_ping_time/1000);
        printf("  state: %d\n", state->state);
        printf("  WAN interface: %s\n", state->wan_interface[0] ? state->wan_interface : "auto");
    }
    
    // 如果跳过初始测量，设置初始值
    if (skip_initial) {
        state->state = QMON_IDLE;
        state->ping_on = 0;
        state->filtered_ping_time = (custom_triptime > 0) ? custom_triptime : 20000;  // 默认20ms
        
        // 如果没有指定ping_limit，则基于测量值计算
        if (state->ping_limit == 0) {
            if (state->flags & ADDENTITLEMENT) {
                state->ping_limit = (int)(state->filtered_ping_time * 1.1f);
            } else {
                state->ping_limit = state->filtered_ping_time * 2;
            }
        }
        
        if (custom_bwlimit > 0) {
            state->current_limit_bps = custom_bwlimit;
        } else {
            state->current_limit_bps = (int)(state->max_bandwidth * 0.9f);
        }
        state->saved_active_limit = state->current_limit_bps;
        state->saved_realtime_limit = state->current_limit_bps;
    }
    
    return 0;
}

/* 处理CHECK状态 */
static void handle_check_state(struct qosmon_state *state) {
    state->ping_on = 1;
    
    // 等待至少2个ping响应
    if (nreceived >= 2) {
        if (state->custom_ping_limit > 0 && !(state->flags & ADDENTITLEMENT)) {
            // 用户指定了ping限制但没有-a标志，直接进入IDLE
            state->current_limit_bps = 0;  // 强制TC更新
            safe_tc_class_modify(state->current_limit_bps);
            state->filtered_ping_time = state->raw_ping_time;
            state->state = QMON_IDLE;
        } else {
            // 开始初始化测量
            safe_tc_class_modify(10000);  // 卸载链路(10kbps，避免网络中断)
            nreceived = 0;
            state->state = QMON_INIT;
        }
    }
}

/* 处理INIT状态 */
static void handle_init_state(struct qosmon_state *state) {
    // 测量基础延迟
    static int init_count = 0;
    init_count++;
    
    // 测量15秒
    int needed_pings = 15000 / state->ping_interval;
    if (init_count > needed_pings) {
        // 完成测量
        state->state = QMON_IDLE;
        safe_tc_class_modify(state->current_limit_bps);
        
        // 计算ping限制
        if (state->flags & ADDENTITLEMENT) {
            state->ping_limit = (int)(state->filtered_ping_time * 1.1f);
            if (state->custom_ping_limit > 0) {
                state->ping_limit += state->custom_ping_limit;
            }
        } else {
            state->ping_limit = state->filtered_ping_time * 2;
        }
        
        // 合理性检查
        if (state->ping_limit < 10000)  // 最小10ms
            state->ping_limit = 10000;
        if (state->ping_limit > 800000)  // 最大800ms
            state->ping_limit = 800000;
            
        state->max_ping_time = state->ping_limit * 2;
        init_count = 0;
        
        DEBUG_LOG("INIT complete: ping_limit=%dus, max_ping_time=%dus\n", 
                 state->ping_limit, state->max_ping_time);
    }
}

/* 处理IDLE状态 */
static void handle_idle_state(struct qosmon_state *state) {
    state->ping_on = 0;
    
    // 检查是否应该激活
    float utilization = (float)state->filtered_total_load / state->max_bandwidth;
    if (utilization > ACTIVE_THRESHOLD) {
        // 利用率超过15%时激活
        if (state->realtime_classes == 0 && (state->flags & ADDENTITLEMENT)) {
            state->state = QMON_ACTIVE;
            state->current_limit_bps = state->saved_active_limit;
        } else {
            state->state = QMON_REALTIME;
            state->current_limit_bps = state->saved_realtime_limit;
        }
        state->ping_on = 1;
        
        DEBUG_LOG("Transition to %s: utilization=%.1f%%\n", 
                 (state->state == QMON_ACTIVE) ? "ACTIVE" : "REALTIME",
                 utilization * 100.0f);
    }
}

/* 处理ACTIVE/REALTIME状态 */
static void handle_active_state(struct qosmon_state *state) {
    state->ping_on = 1;
    
    // 保存各模式的限制
    if (state->state == QMON_REALTIME) {
        state->saved_realtime_limit = state->current_limit_bps;
    } else {
        state->saved_active_limit = state->current_limit_bps;
    }
    
    // 设置ping限制
    int current_plimit = state->ping_limit;
    if (state->realtime_classes == 0 && (state->flags & ADDENTITLEMENT)) {
        if (state->custom_ping_limit > 0) {
            current_plimit = 135 * state->custom_ping_limit / 100 + state->ping_limit;
        }
    }
    
    // 避免除零
    if (current_plimit <= 0) {
        current_plimit = 10000;  // 默认10ms
    }
    
    // 检查低利用率
    float utilization = (float)state->filtered_total_load / state->max_bandwidth;
    if (utilization < IDLE_THRESHOLD) {
        // 利用率低于5%进入IDLE
        state->state = QMON_IDLE;
        state->ping_on = 0;
        DEBUG_LOG("Transition to IDLE: utilization=%.1f%%\n", utilization * 100.0f);
        return;
    }
    
    // 计算ping误差
    float error = state->filtered_ping_time - current_plimit;
    float error_ratio = error / (float)current_plimit;
    
    // 计算带宽调整因子
    float adjust_factor = 1.0f;
    if (error_ratio < 0) {
        // ping时间低于限制，可以增加带宽
        if (state->filtered_total_load < state->current_limit_bps * 0.85f) {
            return;  // 当前利用率不足85%，不增加带宽
        }
        adjust_factor = 1.0f - 0.002f * error_ratio;  // 缓慢增加
    } else {
        // ping时间超过限制，减少带宽
        adjust_factor = 1.0f - 0.004f * (error_ratio + 0.1f);  // 快速减少
        if (adjust_factor < 0.85f)  // 单次最多减少15%
            adjust_factor = 0.85f;
    }
    
    // 应用调整
    int old_limit = state->current_limit_bps;
    int new_limit = (int)(state->current_limit_bps * adjust_factor);
    
    // 带宽限幅
    int min_bw = (int)(state->max_bandwidth * MIN_BANDWIDTH_RATIO);
    int max_bw = (int)(state->max_bandwidth * MAX_BANDWIDTH_RATIO);
    
    if (new_limit > max_bw)
        new_limit = max_bw;
    else if (new_limit < min_bw)
        new_limit = min_bw;
    
    // 避免频繁调整
    int change = abs(new_limit - old_limit);
    if (change > MIN_BW_CHANGE_KBPS * 1000) {
        state->current_limit_bps = new_limit;
        DEBUG_LOG("Bandwidth adjustment: %d -> %d kbps (error_ratio=%.3f)\n", 
                 old_limit/1000, new_limit/1000, error_ratio);
    }
    
    // 更新最大ping时间
    if (state->max_ping_time > current_plimit) {
        state->max_ping_time -= 100;  // 缓慢下降
    }
}

/* 运行控制算法 */
static void run_control_algorithm(struct qosmon_state *state) {
    int64_t now = get_time_ms();
    
    // 检查是否应该发送ping
    if (state->ping_on && (now - state->last_ping_time >= state->ping_interval)) {
        send_ping(state);
    }
    
    // 检查是否应该更新统计
    if (now - state->last_stats_time >= STATS_INTERVAL_MS) {
        class_list("ifb0", state);
        state->last_stats_time = now;
    }
    
    // 运行状态机
    switch (state->state) {
        case QMON_CHK:
            handle_check_state(state);
            break;
        case QMON_INIT:
            handle_init_state(state);
            break;
        case QMON_IDLE:
            handle_idle_state(state);
            break;
        case QMON_ACTIVE:
        case QMON_REALTIME:
            handle_active_state(state);
            break;
    }
    
    // 更新TC带宽
    if (now - state->last_tc_update_time >= CONTROL_INTERVAL_MS) {
        static int last_bw = 0;
        int change = abs(state->current_limit_bps - last_bw);
        
        if (change > MIN_BW_CHANGE_KBPS * 1000 || last_bw == 0) {
            // 只有变化大于阈值时才更新，或者首次设置
            safe_tc_class_modify(state->current_limit_bps);
            last_bw = state->current_limit_bps;
        }
        
        state->last_tc_update_time = now;
    }
}

/* 主函数 */
int main(int argc, char *argv[]) {
    // 初始化全局状态
    struct qosmon_state *state = &g_state;
    int ret = 0;
    
    // 初始化
    if (qosmon_init(state, argc, argv) != 0) {
        return EXIT_FAILURE;
    }
    
    // 设置清理函数
    atexit(cleanup);
    
    // 初始化TC
    tc_core_init();
    if (rtnl_open(&rth, 0) < 0) {
        fprintf(stderr, "Cannot open rtnetlink\n");
        return EXIT_FAILURE;
    }
    
    // 创建socket
    const char *proto_name = (state->whereto.ss_family == AF_INET) ? "icmp" : "ipv6-icmp";
    struct protoent *proto = getprotobyname(proto_name);
    if (!proto) {
        fprintf(stderr, "Unknown protocol: %s\n", proto_name);
        rtnl_close(&rth);
        return EXIT_FAILURE;
    }
    
    state->ping_socket = socket(state->whereto.ss_family, SOCK_RAW, proto->p_proto);
    if (state->ping_socket < 0) {
        perror("socket");
        rtnl_close(&rth);
        return EXIT_FAILURE;
    }
    
    // 设置非阻塞
    int flags = fcntl(state->ping_socket, F_GETFL, 0);
    fcntl(state->ping_socket, F_SETFL, flags | O_NONBLOCK);
    
    // 创建状态文件
    state->status_file = fopen("/tmp/qosmon.status", "w");
    if (!state->status_file) {
        perror("fopen /tmp/qosmon.status");
        close(state->ping_socket);
        rtnl_close(&rth);
        return EXIT_FAILURE;
    }
    
    // 信号处理
    signal(SIGTERM, finish);
    signal(SIGUSR1, resetsig);
    signal(SIGUSR2, toggle_safe_mode);
    
    // 检测网络连通性
    char target_str[INET6_ADDRSTRLEN];
    if (state->whereto.ss_family == AF_INET) {
        struct sockaddr_in *sa = (struct sockaddr_in *)&state->whereto;
        inet_ntop(AF_INET, &sa->sin_addr, target_str, sizeof(target_str));
    } else {
        struct sockaddr_in6 *sa6 = (struct sockaddr_in6 *)&state->whereto;
        inet_ntop(AF_INET6, &sa6->sin6_addr, target_str, sizeof(target_str));
    }
    
    DEBUG_LOG("Checking network connectivity to %s...\n", target_str);
    
    int network_ok = 0;
    for (int i = 0; i < NETWORK_CHECK_TIMEOUT; i++) {
        if (check_network_connectivity(target_str)) {
            network_ok = 1;
            break;
        }
        if (!DEAMON) {
            printf("Network check %d/%d failed, retrying...\n", i+1, NETWORK_CHECK_TIMEOUT);
        }
        sleep(1);
    }
    
    if (!network_ok) {
        fprintf(stderr, "qosmon: No network connectivity to %s, starting in safe mode\n", target_str);
        state->safe_mode = 1;
        state->state = QMON_IDLE;
        state->ping_on = 0;
    } else {
        DEBUG_LOG("Network connectivity OK, starting normally\n");
    }
    
    if (DEAMON) {
        if (daemon(0, 0) < 0) {
            perror("daemon");
            close(state->ping_socket);
            fclose(state->status_file);
            rtnl_close(&rth);
            return EXIT_FAILURE;
        }
        openlog("qosmon", LOG_PID, LOG_LOCAL5);
        syslog(LOG_INFO, "qosmon started: ping_interval=%d, bandwidth=%d kbps, target=%s", 
               state->ping_interval, state->max_bandwidth/1000, target_str);
    } else {
#ifndef ONLYBG
        initscr();
#endif
    }
    
    // 初始ping
    if (state->state == QMON_CHK && !state->safe_mode) {
        send_ping(state);
    }
    
    // 初始化时间戳
    state->last_ping_time = get_time_ms();
    state->last_stats_time = get_time_ms();
    state->last_control_time = get_time_ms();
    state->last_tc_update_time = get_time_ms();
    
    // 主循环
    while (!state->sigterm) {
        struct pollfd fds[1];
        fds[0].fd = state->ping_socket;
        fds[0].events = POLLIN;
        
        int timeout = state->ping_interval;
        if (state->ping_on) {
            int64_t now = get_time_ms();
            int64_t time_since_ping = now - state->last_ping_time;
            if (time_since_ping < state->ping_interval) {
                timeout = state->ping_interval - time_since_ping;
            }
        }
        
        int poll_result = poll(fds, 1, timeout);
        if (poll_result > 0) {
            if (fds[0].revents & POLLIN) {
                handle_ping_response(state);
            }
        } else if (poll_result < 0 && errno != EINTR) {
            perror("poll");
            break;
        }
        
        // 运行控制算法
        run_control_algorithm(state);
        
        // 更新状态文件
        update_status_file(state);
        
#ifndef ONLYBG
        if (!DEAMON) {
            // 简单控制台输出
            const char *state_names[] = {"CHECK", "INIT", "ACTIVE", "REALTIME", "IDLE", "EXIT"};
            const char *state_name = (state->state < 6) ? state_names[state->state] : "UNKNOWN";
            printf("\rState: %s, Ping: %dms, Limit: %dkbps, Load: %dkbps, Safe: %s", 
                   state_name, 
                   state->filtered_ping_time/1000, 
                   state->current_limit_bps/1000, 
                   state->filtered_total_load/1000,
                   state->safe_mode ? "ON" : "OFF");
            fflush(stdout);
        }
#endif
        
        // 处理信号
        if (state->sigusr1) {
            // 重置带宽
            state->current_limit_bps = (int)(state->max_bandwidth * 0.9f);
            safe_tc_class_modify(state->current_limit_bps);
            state->sigusr1 = 0;
            DEBUG_LOG("SIGUSR1 received, reset bandwidth to %d kbps\n", state->current_limit_bps/1000);
        }
    }
    
    // 清理
    state->state = QMON_EXIT;
    
    // 恢复原始带宽
    if (!state->safe_mode) {
        if (safe_tc_class_modify(state->max_bandwidth) < 0) {
            if (!DEAMON) {
                fprintf(stderr, "Failed to restore bandwidth\n");
            }
        } else {
            DEBUG_LOG("Restored bandwidth to %d kbps\n", state->max_bandwidth/1000);
        }
    }
    
    update_status_file(state);
    
    if (DEAMON) {
        syslog(LOG_INFO, "qosmon terminated");
        closelog();
    }
    
    cleanup();
    
#ifndef ONLYBG
    if (!DEAMON) {
        endwin();
    }
#endif
    
    return ret;
}