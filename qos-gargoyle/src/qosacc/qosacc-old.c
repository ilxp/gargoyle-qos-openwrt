/* qosmon - 基于netlink的精简版QoS监控器
 * 功能：通过ping监控延迟，使用netlink动态调整ifb0根类的带宽
 * 基于Paul Bixel的原始代码优化
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <syslog.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <poll.h>
#include <netdb.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/pkt_sched.h>

// 添加缺失的宏定义
#ifndef NLMSG_TAIL
#define NLMSG_TAIL(nmsg) ((struct rtattr *)(((char *)(nmsg)) + NLMSG_ALIGN((nmsg)->nlmsg_len)))
#endif

// 修复1: 添加缺少的TC_HTB定义
#ifndef TCA_HTB_PRIO
#define TCA_HTB_PRIO 4
#endif

#ifndef TCA_HTB_RATE
#define TCA_HTB_RATE 5
#endif

#ifndef TCA_HTB_CEIL
#define TCA_HTB_CEIL 6
#endif

#ifndef TCA_HTB_RATE64
#define TCA_HTB_RATE64 10
#endif

#ifndef TCA_HTB_CEIL64
#define TCA_HTB_CEIL64 11
#endif

#ifndef TCA_HTB_PAD
#define TCA_HTB_PAD 12
#endif

// 修复2: 移除自定义的rtattr结构体，因为系统中已经定义了
// 添加缺少的RTA宏定义
#ifndef RTA_ALIGN
#define RTA_ALIGN(len) (((len) + 3) & ~3)
#endif

#ifndef RTA_LENGTH
#define RTA_LENGTH(len) (RTA_ALIGN(sizeof(struct rtattr)) + (len))
#endif

#ifndef RTA_DATA
#define RTA_DATA(rta) ((void *)((char *)(rta) + RTA_LENGTH(0)))
#endif

#ifndef RTA_OK
#define RTA_OK(rta, len) ((len) >= (int)sizeof(struct rtattr) && \
                         (rta)->rta_len >= sizeof(struct rtattr) && \
                         (rta)->rta_len <= (len))
#endif

#ifndef RTA_NEXT
#define RTA_NEXT(rta, len) ((len) -= RTA_ALIGN((rta)->rta_len), \
                           (struct rtattr *)((char *)(rta) + RTA_ALIGN((rta)->rta_len)))
#endif

#ifndef RTA_PAYLOAD
#define RTA_PAYLOAD(rta) ((int)((rta)->rta_len) - RTA_LENGTH(0))
#endif

#ifndef TCA_RTA
#define TCA_RTA(r) ((struct rtattr *)(((void *)(r)) + NLMSG_ALIGN(sizeof(struct tcmsg))))
#endif

#ifndef ONLYBG
#include <ncurses.h>
#endif

#define MAXPACKET 100
#define BACKGROUND 3
#define ADDENTITLEMENT 4

// 配置参数
#define MIN_BW_RATIO 0.15f      // 最小带宽比例
#define MAX_BW_RATIO 0.95f      // 最大带宽比例
#define MIN_BW_CHANGE_KBPS 50   // 最小带宽变化阈值
#define IDLE_THRESHOLD 0.05f    // 进入IDLE的阈值(5%)
#define ACTIVE_THRESHOLD 0.12f  // 进入ACTIVE的阈值(12%)
#define STATS_INTERVAL_MS 1000  // 统计间隔
#define CONTROL_INTERVAL_MS 2000 // 控制间隔
#define PING_HISTORY_SIZE 5     // ping历史记录大小
#define SMOOTHING_FACTOR 0.3f   // 平滑因子
#define MAX_PING_TIME_MS 800    // 最大ping时间
#define MIN_PING_TIME_MS 5      // 最小ping时间
#define SAFE_START_BW_RATIO 0.8f // 安全启动比例
#define DEFAULT_DEVICE "ifb0"   // 默认设备
#define DEFAULT_CLASSID 0x10001 // 1:1类的句柄
#define NETLINK_BUFFER_SIZE 8192
#define MAX_LOG_SIZE (10 * 1024 * 1024)  // 10MB日志文件大小限制

// 状态枚举
enum {
    QMON_CHK,
    QMON_INIT,
    QMON_ACTIVE,
    QMON_REALTIME,
    QMON_IDLE,
    QMON_EXIT
};

// 调试日志
#ifdef QOSMON_DEBUG
#define DEBUG_LOG(fmt, ...) \
    do { \
        static FILE *log = NULL; \
        static long log_size = 0; \
        if (!log) { \
            log = fopen("/tmp/qosmon_debug.log", "a"); \
            if (log) fseek(log, 0, SEEK_END); \
        } \
        if (log) { \
            if (log_size > MAX_LOG_SIZE) { \
                fclose(log); \
                log = fopen("/tmp/qosmon_debug.log", "w"); \
                log_size = 0; \
            } \
            int bytes = fprintf(log, "[%ld] " fmt, (long)time(NULL), ##__VA_ARGS__); \
            if (bytes > 0) log_size += bytes; \
            fflush(log); \
        } \
    } while(0)
#else
#define DEBUG_LOG(fmt, ...)
#endif

#define MIN(a,b) (((a)<(b))?(a):(b))
#define DEAMON (pingflags & BACKGROUND)

// 原子信号标志
static volatile sig_atomic_t sigterm_flag = 0;
static volatile sig_atomic_t sigusr1_flag = 0;

// 全局变量
u_char pingflags = 0;
uint16_t ntransmitted = 0;
uint16_t nreceived = 0;
char packet[MAXPACKET];

// ping历史记录
struct ping_history {
    int times[PING_HISTORY_SIZE];
    int index;
    int count;
    float smoothed;
};

// QoS监控状态
struct qosmon_state {
    // 网络参数
    struct sockaddr_storage whereto;
    int ping_socket;
    int ident;
    
    // 配置参数
    int ping_interval;      // ms
    int max_bandwidth;      // bps
    int ping_limit;         // us
    int custom_ping_limit;  // us
    int flags;
    
    // 状态变量
    int raw_ping_time;      // us
    int filtered_ping_time; // us
    int max_ping_time;      // us
    int ping_on;
    
    // 带宽控制
    int current_limit_bps;  // 当前限制(bps)
    int saved_active_limit; // 保存的ACTIVE模式限制
    int saved_realtime_limit; // 保存的REALTIME模式限制
    int filtered_total_load; // 滤波后的总负载(bps)
    
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
    int64_t last_tc_update_time;
    int64_t last_realtime_detect_time;
    
    // 滤波器参数
    float alpha;
    float bw_alpha;
    
    // 调试
    int verbose;
    int safe_mode;
    int last_tc_bw_kbps;
    
    // 状态文件
    FILE *status_file;
    
    // 实时类计数
    int realtime_classes;
    
    // netlink相关
    int netlink_socket;
    unsigned int seq;
};

static struct qosmon_state g_state;

const char usage[] = 
"qosmon - 基于ping延迟的QoS监控器\n\n"
"用法: qosmon [选项] ping间隔 ping目标 带宽 [ping限制]\n"
"  ping间隔   - ping间隔(ms, 100-2000)\n"
"  ping目标   - ping目标的IP或域名\n"
"  带宽       - 最大下载带宽(kbps)\n"
"  ping限制   - 可选的ping限制(ms)\n"
"  选项:\n"
"  -b         - 后台运行\n"
"  -a         - 启用ACTIVE/MINRTT自动切换\n"
"  -s         - 跳过初始链路测量\n"
"  -t <时间>  - 设置初始ping时间(ms, 与-s一起用)\n"
"  -l <限制>  - 设置初始链路限制(kbps, 与-s一起用)\n"
"  -v         - 详细模式\n\n"
"  SIGUSR1    - 重置链路带宽到初始值\n";

// 信号处理函数
static void finish(int sig) {
    (void)sig;
    sigterm_flag = 1;
}

static void resetsig(int sig) {
    (void)sig;
    sigusr1_flag = 1;
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

/* ICMP校验和计算 */
int in_cksum(u_short *addr, int len) {
    int nleft = len;
    u_short *w = addr;
    u_short answer;
    int sum = 0;
    
    while (nleft > 1) {
        sum += *w++;
        nleft -= 2;
    }
    
    if (nleft == 1) {
        u_short u = 0;
        *(u_char *)(&u) = *(u_char *)w;
        sum += u;
    }
    
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    answer = ~sum;
    return answer;
}

/* 时间差计算 */
void tvsub(struct timeval *out, struct timeval *in) {
    if ((out->tv_usec -= in->tv_usec) < 0) {
        out->tv_sec--;
        out->tv_usec += 1000000;
    }
    out->tv_sec -= in->tv_sec;
}

/* 更新ping历史记录 */
static void update_ping_history(struct ping_history *hist, int ping_time) {
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
    struct timeval *tp = (struct timeval *)&outpack[8];
    u_char *datap = &outpack[8 + sizeof(struct timeval)];
    
    if (state->whereto.ss_family == AF_INET6) {
        struct icmp6_hdr *icp = (struct icmp6_hdr *)outpack;
        icp->icmp6_type = ICMP6_ECHO_REQUEST;
        icp->icmp6_code = 0;
        icp->icmp6_cksum = 0;
        icp->icmp6_seq = ++ntransmitted;
        icp->icmp6_id = state->ident;
        cc = 56;  // 默认数据长度
        gettimeofday(tp, NULL);
        
        for (i = 8; i < 56; i++) {
            *datap++ = i;
        }
        
        // 为IPv6设置校验和计算
        int offset = 2;
        if (setsockopt(state->ping_socket, IPPROTO_IPV6, IPV6_CHECKSUM, 
                       &offset, sizeof(offset)) < 0) {
            DEBUG_LOG("设置IPv6校验和失败: %s\n", strerror(errno));
        }
    } else {
        struct icmp *icp = (struct icmp *)outpack;
        icp->icmp_type = ICMP_ECHO;
        icp->icmp_code = 0;
        icp->icmp_cksum = 0;
        icp->icmp_seq = ++ntransmitted;
        icp->icmp_id = state->ident;
        cc = 56;
        gettimeofday(tp, NULL);
        
        for (i = 8; i < 56; i++) {
            *datap++ = i;
        }
        
        icp->icmp_cksum = in_cksum((u_short *)icp, cc);
    }
    
    int ret = sendto(state->ping_socket, outpack, cc, 0,
                    (const struct sockaddr *)&state->whereto,
                    sizeof(state->whereto));
    
    if (ret < 0) {
        if (!DEAMON || state->verbose) {
            fprintf(stderr, "发送ping失败: %s\n", strerror(errno));
        }
        return -1;
    }
    
    state->last_ping_time = get_time_ms();
    DEBUG_LOG("发送ping, seq=%d\n", ntransmitted);
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
                fprintf(stderr, "接收ping失败: %s\n", strerror(errno));
            }
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
    
    if (from.ss_family == AF_INET6) {
        if (cc < sizeof(struct icmp6_hdr)) {
            return 0;
        }
        icp6 = (struct icmp6_hdr *)packet;
        
        if (icp6->icmp6_type != ICMP6_ECHO_REPLY) {
            return 0;
        }
        if (icp6->icmp6_id != state->ident) {
            return 0;
        }
        
        seq = icp6->icmp6_seq;
        tp = (struct timeval *)&icp6->icmp6_dataun.icmp6_un_data32[1];
    } else {
        ip = (struct ip *)packet;
        hlen = ip->ip_hl << 2;
        if (cc < hlen + 8) {  // ICMP最小长度
            return 0;
        }
        icp = (struct icmp *)(packet + hlen);
        
        if (icp->icmp_type != ICMP_ECHOREPLY) {
            return 0;
        }
        if (icp->icmp_id != state->ident) {
            return 0;
        }
        
        seq = icp->icmp_seq;
        tp = (struct timeval *)&icp->icmp_data[0];
    }
    
    if (seq != ntransmitted) {
        return 0;  // 不是我们发送的最后一个包
    }
    
    nreceived++;
    
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
    
    DEBUG_LOG("Ping回复: seq=%d, 时间=%dms, 滤波=%dms\n",
             seq, triptime, state->filtered_ping_time/1000);
    
    return 1;
}

/* 从/proc/net/dev读取ifb0的流量统计 */
static int update_load_from_proc(struct qosmon_state *state) {
    int ret = -1;
    char line[256];
    unsigned long long rx_bytes = 0;
    static unsigned long long last_rx_bytes = 0;
    static int64_t last_read_time = 0;
    
    FILE *fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        DEBUG_LOG("无法打开 /proc/net/dev\n");
        return -1;
    }
    
    // 跳过前两行标题
    if (!fgets(line, sizeof(line), fp) || !fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return -1;
    }
    
    // 查找ifb0接口
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, "ifb0:")) {
            char *p = strchr(line, ':');
            if (p) {
                p++;
                if (sscanf(p, "%llu", &rx_bytes) == 1) {
                    ret = 0;
                }
            }
            break;
        }
    }
    
    fclose(fp);
    
    if (ret == 0) {
        int64_t now = get_time_ms();
        
        if (last_read_time > 0 && last_rx_bytes > 0 && rx_bytes >= last_rx_bytes) {
            int time_diff = (int)(now - last_read_time);
            if (time_diff > 0) {
                unsigned long long bytes_diff = rx_bytes - last_rx_bytes;
                // 计算bps: bytes_diff * 8 * 1000 / time_diff_ms
                int bps = (int)((bytes_diff * 8000) / time_diff);
                
                // 应用滤波
                int delta = bps - state->filtered_total_load;
                state->filtered_total_load += (int)(delta * state->bw_alpha);
                
                // 限制范围
                if (state->filtered_total_load < 0) {
                    state->filtered_total_load = 0;
                } else if (state->filtered_total_load > state->max_bandwidth) {
                    state->filtered_total_load = state->max_bandwidth;
                }
                
                DEBUG_LOG("负载: 原始=%d bps, 滤波=%d bps\n", bps, state->filtered_total_load);
            }
        }
        
        last_rx_bytes = rx_bytes;
        last_read_time = now;
    }
    
    return ret;
}

/* Netlink辅助函数 - 添加属性 */
static void addattr_l(struct nlmsghdr *n, int maxlen, int type, const void *data, int alen) {
    int len = alen;
    
    if (NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len + 4) > maxlen) {
        return;
    }
    
    struct rtattr *rta = (struct rtattr *)(((char *)n) + NLMSG_ALIGN(n->nlmsg_len));
    rta->rta_type = type;
    rta->rta_len = len + 4;
    
    if (data && alen > 0) {
        memcpy(((char *)rta) + 4, data, alen);
    }
    
    n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len + 4);
}

/* 通过netlink修改TC规则（修复版本） */
static int tc_class_modify(__u32 rate_bps) {
    int rate_kbps = (rate_bps + 500) / 1000;  // 四舍五入到kbps
    char reply[1024];  // 用于接收回复
    struct nlmsghdr *nh;  // 用于解析回复
    
    if (g_state.safe_mode) {
        DEBUG_LOG("安全模式启用，跳过TC修改(请求: %d kbps)\n", rate_kbps);
        return 0;
    }
    
    if (abs(rate_kbps - g_state.last_tc_bw_kbps) < MIN_BW_CHANGE_KBPS && 
        g_state.last_tc_bw_kbps != 0) {
        DEBUG_LOG("TC: 跳过更新，变化太小(%d -> %d kbps)\n", 
                 g_state.last_tc_bw_kbps, rate_kbps);
        return 0;
    }
    
    DEBUG_LOG("TC: 通过netlink设置带宽为 %d kbps\n", rate_kbps);
    
    char buf[4096];
    struct nlmsghdr *n = (struct nlmsghdr *)buf;
    struct tcmsg *t = NLMSG_DATA(n);
    struct rtattr *tail;
    int ret = -1;
    int ifindex = if_nametoindex(DEFAULT_DEVICE);
    
    if (ifindex == 0) {
        DEBUG_LOG("无法获取ifb0的接口索引: %s\n", strerror(errno));
        return -1;
    }
    
    // 首先尝试HTB格式
    memset(buf, 0, sizeof(buf));
    n->nlmsg_len = NLMSG_LENGTH(sizeof(*t));
    n->nlmsg_type = RTM_NEWTCLASS;
    n->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE;
    n->nlmsg_seq = ++g_state.seq;
    n->nlmsg_pid = getpid();
    
    t->tcm_family = AF_UNSPEC;
    t->tcm_ifindex = ifindex;
    t->tcm_handle = TC_H_MAKE(1, 1);  // 1:1类的句柄
    t->tcm_parent = TC_H_MAKE(1, 0);  // 1:0类的句柄
    
    // 添加TC种类属性
    addattr_l(n, sizeof(buf), TCA_KIND, "htb", 4);
    
    // 添加HTB选项
    tail = (struct rtattr *)((char *)n + n->nlmsg_len);
    addattr_l(n, sizeof(buf), TCA_OPTIONS, NULL, 0);
    
    // HTB参数
    struct tc_htb_opt {
        struct tc_ratespec rate;
        struct tc_ratespec ceil;
        __u32   buffer;
        __u32   cbuffer;
        __u32   quantum;
        __u32   level;
        __u32   prio;
    } opt = {0};
    
    opt.rate.rate = rate_kbps * 1000;  // 转换为bit/s
    opt.ceil.rate = rate_kbps * 1000;  // 转换为bit/s
    opt.buffer = 1600;  // 默认缓冲区
    opt.cbuffer = 1600; // 默认ceil缓冲区
    opt.quantum = 0x600;  // 默认quantum
    opt.level = 0;
    opt.prio = 1;
    
    addattr_l(n, sizeof(buf), TCA_HTB_PARMS, &opt, sizeof(opt));
    
    // 结束TCA_OPTIONS
    tail->rta_len = (void *)NLMSG_TAIL(n) - (void *)tail;
    
    // 发送netlink消息
    struct sockaddr_nl nladdr = {0};
    struct iovec iov = { buf, n->nlmsg_len };
    struct msghdr msg = {0};
    
    nladdr.nl_family = AF_NETLINK;
    nladdr.nl_pid = 0;  // 发送到内核
    nladdr.nl_groups = 0;
    
    msg.msg_name = &nladdr;
    msg.msg_namelen = sizeof(nladdr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    ret = sendmsg(g_state.netlink_socket, &msg, 0);
    if (ret < 0) {
        DEBUG_LOG("发送HTB netlink消息失败: %s\n", strerror(errno));
    } else {
        iov.iov_base = reply;
        iov.iov_len = sizeof(reply);
        
        // 设置接收超时
        struct timeval tv = {1, 0};  // 1秒超时
        setsockopt(g_state.netlink_socket, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
        
        ret = recvmsg(g_state.netlink_socket, &msg, 0);
        if (ret < 0) {
            DEBUG_LOG("接收HTB响应失败: %s\n", strerror(errno));
        } else {
            nh = (struct nlmsghdr *)reply;
            if (nh->nlmsg_type == NLMSG_ERROR) {
                struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nh);
                if (err->error != 0) {
                    DEBUG_LOG("HTB netlink错误: %s\n", strerror(-err->error));
                    ret = -1;
                } else {
                    DEBUG_LOG("HTB netlink成功\n");
                    ret = 0;
                }
            } else {
                DEBUG_LOG("HTB: 接收到非错误响应，类型=%d\n", nh->nlmsg_type);
                ret = 0;
            }
        }
    }
    
    // 如果HTB失败，尝试HFSC
    if (ret != 0) {
        DEBUG_LOG("HTB格式失败，尝试HFSC格式\n");
        
        memset(buf, 0, sizeof(buf));
        n = (struct nlmsghdr *)buf;
        t = NLMSG_DATA(n);
        
        n->nlmsg_len = NLMSG_LENGTH(sizeof(*t));
        n->nlmsg_type = RTM_NEWTCLASS;
        n->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE;
        n->nlmsg_seq = ++g_state.seq;
        n->nlmsg_pid = getpid();
        
        t->tcm_family = AF_UNSPEC;
        t->tcm_ifindex = ifindex;
        t->tcm_handle = TC_H_MAKE(1, 1);  // 1:1类的句柄
        t->tcm_parent = TC_H_MAKE(1, 0);  // 1:0类的句柄
        
        // 添加TC种类属性
        addattr_l(n, sizeof(buf), TCA_KIND, "hfsc", 5);
        
        // 添加HFSC选项
        tail = (struct rtattr *)((char *)n + n->nlmsg_len);
        addattr_l(n, sizeof(buf), TCA_OPTIONS, NULL, 0);
        
        // HFSC服务曲线
        struct tc_service_curve {
            __u32 m1, d, m2;
        } rsc = {0}, fsc = {0}, usc = {0};
        
        // 设置实时服务曲线
        rsc.m2 = rate_kbps * 125;  // 转换为字节/秒
        addattr_l(n, sizeof(buf), TCA_HFSC_RSC, &rsc, sizeof(rsc));
        
        // 设置公平服务曲线
        fsc.m2 = rate_kbps * 125;
        addattr_l(n, sizeof(buf), TCA_HFSC_FSC, &fsc, sizeof(fsc));
        
        // 设置上限服务曲线
        usc.m2 = rate_kbps * 125;
        addattr_l(n, sizeof(buf), TCA_HFSC_USC, &usc, sizeof(usc));
        
        // 结束TCA_OPTIONS
        tail->rta_len = (void *)NLMSG_TAIL(n) - (void *)tail;
        
        // 发送HFSC消息
        iov.iov_base = buf;
        iov.iov_len = n->nlmsg_len;
        
        ret = sendmsg(g_state.netlink_socket, &msg, 0);
        if (ret < 0) {
            DEBUG_LOG("发送HFSC netlink消息失败: %s\n", strerror(errno));
        } else {
            iov.iov_base = reply;
            iov.iov_len = sizeof(reply);
            
            ret = recvmsg(g_state.netlink_socket, &msg, 0);
            if (ret < 0) {
                DEBUG_LOG("接收HFSC响应失败: %s\n", strerror(errno));
            } else {
                nh = (struct nlmsghdr *)reply;
                if (nh->nlmsg_type == NLMSG_ERROR) {
                    struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nh);
                    if (err->error != 0) {
                        DEBUG_LOG("HFSC netlink错误: %s\n", strerror(-err->error));
                        ret = -1;
                    } else {
                        DEBUG_LOG("HFSC netlink成功\n");
                        ret = 0;
                    }
                } else {
                    DEBUG_LOG("HFSC: 接收到非错误响应，类型=%d\n", nh->nlmsg_type);
                    ret = 0;
                }
            }
        }
    }
    
    if (ret == 0) {
        g_state.last_tc_bw_kbps = rate_kbps;
        DEBUG_LOG("通过netlink成功设置带宽: %d kbps\n", rate_kbps);
    } else {
        DEBUG_LOG("所有netlink格式尝试失败\n");
    }
    
    return ret;
}

/* 改进的实时类检测函数 */
static int is_realtime_class(struct rtattr *tb[]) {
    // 方法1: 检查是否有实时服务曲线
    if (tb[TCA_HFSC_RSC]) {
        return 1;
    }
    
    // 方法2: 检查类优先级
    if (tb[TCA_HTB_PRIO]) {
        int prio = *(int *)RTA_DATA(tb[TCA_HTB_PRIO]);
        if (prio == 0) {  // 最高优先级可能是实时类
            return 1;
        }
    }
    
    return 0;
}

/* 通过netlink获取TC分类信息，检测实时类 */
static int detect_realtime_classes(void) {
    char buf[NETLINK_BUFFER_SIZE];
    char reply[1024];
    struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
    struct tcmsg *t = NLMSG_DATA(nlh);
    struct sockaddr_nl nladdr = {0};
    struct iovec iov = { buf, sizeof(buf) };
    struct msghdr msg = {0};
    int ret, realtime_count = 0;
    int ifindex = if_nametoindex(DEFAULT_DEVICE);
    
    if (ifindex == 0) {
        DEBUG_LOG("无法获取ifb0的接口索引\n");
        return 0;
    }
    
    // 构造获取TC分类的netlink消息
    nlh->nlmsg_len = NLMSG_LENGTH(sizeof(*t));
    nlh->nlmsg_type = RTM_GETTCLASS;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    nlh->nlmsg_seq = ++g_state.seq;
    nlh->nlmsg_pid = getpid();
    
    memset(t, 0, sizeof(*t));
    t->tcm_family = AF_UNSPEC;
    t->tcm_ifindex = ifindex;
    t->tcm_parent = 0;
    
    // 发送请求
    nladdr.nl_family = AF_NETLINK;
    
    msg.msg_name = &nladdr;
    msg.msg_namelen = sizeof(nladdr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    ret = sendmsg(g_state.netlink_socket, &msg, 0);
    if (ret < 0) {
        DEBUG_LOG("发送TC获取请求失败: %s\n", strerror(errno));
        return 0;
    }
    
    // 设置接收超时
    struct timeval tv = {2, 0};  // 2秒超时
    setsockopt(g_state.netlink_socket, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    
    // 接收响应
    int len = 0;
    while (1) {
        iov.iov_len = sizeof(reply);
        len = recvmsg(g_state.netlink_socket, &msg, 0);
        if (len <= 0) {
            if (len < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                DEBUG_LOG("接收TC响应超时\n");
            }
            break;
        }
        
        // 解析所有netlink消息
        for (nlh = (struct nlmsghdr *)reply; NLMSG_OK(nlh, len); nlh = NLMSG_NEXT(nlh, len)) {
            if (nlh->nlmsg_type == NLMSG_DONE) {
                break;
            }
            
            if (nlh->nlmsg_type == NLMSG_ERROR) {
                struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nlh);
                if (err->error != 0) {
                    DEBUG_LOG("获取TC类错误: %s\n", strerror(-err->error));
                }
                return 0;
            }
            
            t = NLMSG_DATA(nlh);
            
            // 检查是否是我们感兴趣的接口
            if (t->tcm_ifindex != ifindex) {
                continue;
            }
            
            // 解析属性
            int attr_len = nlh->nlmsg_len - NLMSG_LENGTH(sizeof(*t));
            struct rtattr *tb[TCA_MAX + 1];
            struct rtattr *rta = (struct rtattr *)((char *)t + NLMSG_ALIGN(sizeof(*t)));
            
            // 简化解析，跳过复杂的属性解析
            // 假设有TCA_KIND属性就检查是否为"realtime"
            for (; RTA_OK(rta, attr_len); rta = RTA_NEXT(rta, attr_len)) {
                if (rta->rta_type == TCA_KIND) {
                    char *kind = (char *)RTA_DATA(rta);
                    if (kind && (strcmp(kind, "realtime") == 0 || 
                                 strstr(kind, "realtime") != NULL || 
                                 strstr(kind, "hfsc") != NULL)) {
                        DEBUG_LOG("发现实时类: handle=0x%x, kind=%s\n", t->tcm_handle, kind);
                        realtime_count++;
                        break;
                    }
                }
            }
        }
    }
    
    DEBUG_LOG("检测到%d个实时类\n", realtime_count);
    return realtime_count;
}

/* 更新状态文件 */
static void update_status_file(struct qosmon_state *state) {
    if (!state->status_file) {
        return;
    }
    
    ftruncate(fileno(state->status_file), 0);
    rewind(state->status_file);
    
    const char *state_names[] = {"CHECK", "INIT", "ACTIVE", "REALTIME", "IDLE", "EXIT"};
    const char *state_name = (state->state < 6) ? state_names[state->state] : "UNKNOWN";
    
    fprintf(state->status_file, "状态: %s\n", state_name);
    fprintf(state->status_file, "安全模式: %s\n", state->safe_mode ? "ON" : "OFF");
    fprintf(state->status_file, "链路限制: %d kbps\n", state->current_limit_bps / 1000);
    fprintf(state->status_file, "上次成功设置: %d kbps\n", state->last_tc_bw_kbps);
    fprintf(state->status_file, "最大带宽: %d kbps\n", state->max_bandwidth / 1000);
    fprintf(state->status_file, "当前负载: %d kbps\n", state->filtered_total_load / 1000);
    
    if (state->ping_on) {
        fprintf(state->status_file, "Ping: %d ms (滤波: %d ms)\n", 
                state->raw_ping_time / 1000, state->filtered_ping_time / 1000);
    } else {
        fprintf(state->status_file, "Ping: 关闭\n");
    }
    
    if (state->ping_limit > 0) {
        fprintf(state->status_file, "Ping限制: %d ms\n", state->ping_limit / 1000);
    } else {
        fprintf(state->status_file, "Ping限制: 测量中...\n");
    }
    
    fprintf(state->status_file, "实时类: %d\n", state->realtime_classes);
    
    fflush(state->status_file);
}

/* 初始化状态结构 */
static int qosmon_init(struct qosmon_state *state, int argc, char *argv[]) {
    memset(state, 0, sizeof(struct qosmon_state));
    
    // 默认值
    state->ping_socket = -1;
    state->netlink_socket = -1;
    state->ident = getpid() & 0xFFFF;
    state->alpha = 0.3f;
    state->bw_alpha = 0.1f;
    state->last_tc_bw_kbps = 0;
    state->realtime_classes = 0;
    state->seq = 1;
    
    // 解析命令行参数
    int skip_initial = 0;
    int custom_triptime = 0;
    int custom_bwlimit = 0;
    
    // 跳过程序名
    argc--, argv++;
    
    // 解析可选参数
    while (argc > 0 && argv[0][0] == '-') {
        char *arg = argv[0] + 1;
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
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -t 需要一个参数\n");
                    return -1;
                }
                break;
            case 'l':
                if (argc > 0) {
                    custom_bwlimit = atoi(argv[0]) * 1000;
                    argc--, argv++;
                } else {
                    fprintf(stderr, "qosmon: -l 需要一个参数\n");
                    return -1;
                }
                break;
            case 'v':
                state->verbose = 1;
                break;
            default:
                fprintf(stderr, "qosmon: 未知选项: -%c\n", option);
                return -1;
        }
    }
    
    // 检查必需的参数数量
    if (argc < 3) {
        fprintf(stderr, "qosmon: 参数不足 (%d 剩余, 需要3个)\n", argc);
        fprintf(stderr, "%s", usage);
        return -1;
    }
    
    // 解析必需参数
    state->ping_interval = atoi(argv[0]);
    if (state->ping_interval < 100 || state->ping_interval > 2000) {
        fprintf(stderr, "无效的ping间隔: %d ms (必须是100-2000)\n", state->ping_interval);
        return -1;
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
        fprintf(stderr, "未知主机: %s\n", argv[0]);
        return -1;
    }
    argc--, argv++;
    
    // 解析带宽
    int bw_kbps = atoi(argv[0]);
    if (bw_kbps < 100) {
        fprintf(stderr, "无效的带宽: %d kbps (最小100 kbps)\n", bw_kbps);
        return -1;
    }
    state->max_bandwidth = bw_kbps * 1000;  // 转换为bps
    argc--, argv++;
    
    // 解析可选的ping限制
    if (argc > 0) {
        state->custom_ping_limit = atoi(argv[0]) * 1000;  // 转换为微秒
        state->ping_limit = state->custom_ping_limit;
        argc--, argv++;
    }
    
    // 计算滤波器参数
    float tc = state->ping_interval * 4.0f;
    state->alpha = (state->ping_interval * 1000.0f) / (tc + state->ping_interval);
    // 带宽滤波器时间常数7.5秒
    state->bw_alpha = (state->ping_interval * 1000.0f) / (7500.0f + state->ping_interval);
    
    // 初始状态
    state->state = QMON_CHK;
    state->first_pass = 1;
    
    // 初始化带宽限制
    state->current_limit_bps = (int)(state->max_bandwidth * SAFE_START_BW_RATIO);
    state->saved_active_limit = state->current_limit_bps;
    state->saved_realtime_limit = state->current_limit_bps;
    
    // 如果跳过初始测量，设置初始值
    if (skip_initial) {
        state->state = QMON_IDLE;
        state->ping_on = 0;
        state->filtered_ping_time = (custom_triptime > 0) ? custom_triptime : 20000;  // 默认20ms
        
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
            if (tc_class_modify(state->current_limit_bps) < 0) {
                DEBUG_LOG("警告: 进入IDLE状态时TC修改失败\n");
            }
            state->filtered_ping_time = state->raw_ping_time;
            state->state = QMON_IDLE;
        } else {
            // 开始初始化测量
            if (tc_class_modify(10000) < 0) {  // 卸载链路(10kbps)
                DEBUG_LOG("警告: 初始化测量时TC修改失败\n");
            }
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
        if (tc_class_modify(state->current_limit_bps) < 0) {
            DEBUG_LOG("警告: 初始化完成时TC修改失败\n");
        }
        
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
        
        DEBUG_LOG("INIT完成: ping限制=%dus, 最大ping时间=%dus\n", 
                 state->ping_limit, state->max_ping_time);
    }
}

/* 处理IDLE状态 */
static void handle_idle_state(struct qosmon_state *state) {
    state->ping_on = 0;
    
    // 检查是否应该激活
    float utilization = (float)state->filtered_total_load / state->max_bandwidth;
    if (utilization > ACTIVE_THRESHOLD) {
        // 利用率超过阈值时激活
        if (state->realtime_classes == 0 && (state->flags & ADDENTITLEMENT)) {
            state->state = QMON_ACTIVE;
            state->current_limit_bps = state->saved_active_limit;
        } else {
            state->state = QMON_REALTIME;
            state->current_limit_bps = state->saved_realtime_limit;
        }
        state->ping_on = 1;
        
        DEBUG_LOG("切换到 %s: 利用率=%.1f%%\n", 
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
        // 利用率低于阈值进入IDLE
        state->state = QMON_IDLE;
        state->ping_on = 0;
        DEBUG_LOG("切换到IDLE: 利用率=%.1f%%\n", utilization * 100.0f);
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
    int min_bw = (int)(state->max_bandwidth * MIN_BW_RATIO);
    int max_bw = (int)(state->max_bandwidth * MAX_BW_RATIO);
    
    if (new_limit > max_bw)
        new_limit = max_bw;
    else if (new_limit < min_bw)
        new_limit = min_bw;
    
    // 避免频繁调整
    int change = abs(new_limit - old_limit);
    if (change > MIN_BW_CHANGE_KBPS * 1000) {
        state->current_limit_bps = new_limit;
        DEBUG_LOG("带宽调整: %d -> %d kbps (误差比例=%.3f)\n", 
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
    
    // 定期检测实时类
    if (now - state->last_realtime_detect_time >= 5000) {  // 每5秒检测一次
        int realtime_classes = detect_realtime_classes();
        if (realtime_classes != state->realtime_classes) {
            state->realtime_classes = realtime_classes;
            DEBUG_LOG("实时类数量更新: %d\n", realtime_classes);
        }
        state->last_realtime_detect_time = now;
    }
    
    // 检查是否应该发送ping
    if (state->ping_on && (now - state->last_ping_time >= state->ping_interval)) {
        send_ping(state);
    }
    
    // 检查是否应该更新统计
    if (now - state->last_stats_time >= STATS_INTERVAL_MS) {
        update_load_from_proc(state);
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
            if (tc_class_modify(state->current_limit_bps) < 0) {
                DEBUG_LOG("警告: TC带宽修改失败\n");
            }
            last_bw = state->current_limit_bps;
        }
        
        state->last_tc_update_time = now;
    }
}

/* 清理函数 */
static void cleanup(void) {
    DEBUG_LOG("清理中...\n");
    
    if (g_state.ping_socket >= 0) {
        close(g_state.ping_socket);
        g_state.ping_socket = -1;
    }
    
    if (g_state.netlink_socket >= 0) {
        close(g_state.netlink_socket);
        g_state.netlink_socket = -1;
    }
    
    if (g_state.status_file) {
        fclose(g_state.status_file);
        g_state.status_file = NULL;
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
    
    // 创建ping socket
    int proto = (state->whereto.ss_family == AF_INET) ? IPPROTO_ICMP : IPPROTO_ICMPV6;
    
    state->ping_socket = socket(state->whereto.ss_family, SOCK_RAW, proto);
    if (state->ping_socket < 0) {
        perror("创建ping socket失败");
        if (errno == EPERM) {
            fprintf(stderr, "需要root权限运行\n");
        }
        return EXIT_FAILURE;
    }
    
    // 设置socket选项
    int ttl = 64;
    if (state->whereto.ss_family == AF_INET) {
        setsockopt(state->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));
    } else {
        setsockopt(state->ping_socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &ttl, sizeof(ttl));
    }
    
    // 设置非阻塞
    int flags = fcntl(state->ping_socket, F_GETFL, 0);
    fcntl(state->ping_socket, F_SETFL, flags | O_NONBLOCK);
    
    // 创建netlink socket
    state->netlink_socket = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (state->netlink_socket < 0) {
        perror("创建netlink socket失败");
        close(state->ping_socket);
        return EXIT_FAILURE;
    }
    
    // 绑定netlink socket
    struct sockaddr_nl addr = {0};
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = getpid();
    addr.nl_groups = 0;
    
    if (bind(state->netlink_socket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("绑定netlink socket失败");
        close(state->ping_socket);
        close(state->netlink_socket);
        return EXIT_FAILURE;
    }
    
    // 打开状态文件
    state->status_file = fopen("/tmp/qosmon_status.txt", "w");
    if (!state->status_file) {
        DEBUG_LOG("无法打开状态文件: %s\n", strerror(errno));
    }
    
    // 设置信号处理
    struct sigaction sa = {0};
    sa.sa_handler = finish;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    
    sa.sa_handler = resetsig;
    sigaction(SIGUSR1, &sa, NULL);
    
    // 忽略SIGPIPE
    signal(SIGPIPE, SIG_IGN);
    
    if (DEAMON) {
        // 后台运行设置
        if (daemon(0, 0) < 0) {
            perror("daemon失败");
            return EXIT_FAILURE;
        }
        
        openlog("qosmon", LOG_PID, LOG_DAEMON);
        syslog(LOG_INFO, "qosmon启动: 目标=%s, 带宽=%dkbps, 间隔=%dms", 
               argv[1], state->max_bandwidth/1000, state->ping_interval);
    } else if (state->verbose) {
        fprintf(stderr, "qosmon启动:\n");
        fprintf(stderr, "  目标: %s\n", argv[1]);
        fprintf(stderr, "  带宽: %d kbps\n", state->max_bandwidth/1000);
        fprintf(stderr, "  Ping间隔: %d ms\n", state->ping_interval);
        if (state->ping_limit > 0) {
            fprintf(stderr, "  Ping限制: %d ms\n", state->ping_limit/1000);
        }
        if (state->flags & ADDENTITLEMENT) {
            fprintf(stderr, "  ACTIVE/MINRTT自动切换: 启用\n");
        }
    }
    
    // 初始ping
    if (state->ping_on) {
        if (send_ping(state) < 0) {
            if (!DEAMON) {
                fprintf(stderr, "初始ping发送失败\n");
            }
            if (DEAMON) {
                syslog(LOG_ERR, "初始ping发送失败");
            }
        }
    }
    
    // 如果跳过初始化，直接进入IDLE状态
    if (state->first_pass && state->state == QMON_IDLE) {
        DEBUG_LOG("跳过初始测量，直接进入IDLE状态\n");
        state->current_limit_bps = 0;  // 强制TC更新
        if (tc_class_modify(state->current_limit_bps) < 0) {
            DEBUG_LOG("警告: 初始TC修改失败\n");
        }
        state->first_pass = 0;
    }
    
    // 设置初始时间戳
    int64_t now = get_time_ms();
    state->last_ping_time = now;
    state->last_stats_time = now;
    state->last_tc_update_time = now;
    state->last_realtime_detect_time = now;
    
    // 主循环
    while (!state->sigterm) {
        // 检查原子信号标志
        if (sigterm_flag) {
            state->sigterm = 1;
        }
        if (sigusr1_flag) {
            state->sigusr1 = 1;
            sigusr1_flag = 0;  // 重置标志
        }
        
        struct pollfd fds[2];
        fds[0].fd = state->ping_socket;
        fds[0].events = POLLIN;
        fds[1].fd = state->netlink_socket;
        fds[1].events = POLLIN;
        
        int timeout = state->ping_interval;
        if (state->ping_on) {
            int64_t now = get_time_ms();
            int64_t time_since_ping = now - state->last_ping_time;
            if (time_since_ping < state->ping_interval) {
                timeout = state->ping_interval - time_since_ping;
            }
        }
        
        int poll_result = poll(fds, 2, timeout);
        if (poll_result > 0) {
            if (fds[0].revents & POLLIN) {
                handle_ping_response(state);
            }
            if (fds[1].revents & POLLIN) {
                // 处理netlink消息
                char buf[1024];
                int len = recv(state->netlink_socket, buf, sizeof(buf), 0);
                if (len > 0) {
                    DEBUG_LOG("收到netlink消息，长度=%d\n", len);
                }
            }
        } else if (poll_result < 0 && errno != EINTR) {
            perror("poll");
            break;
        }
        
        // 运行控制算法
        run_control_algorithm(state);
        
        // 更新状态文件
        update_status_file(state);
        
        // 处理信号
        if (state->sigusr1) {
            // 重置带宽
            state->current_limit_bps = (int)(state->max_bandwidth * 0.9f);
            if (tc_class_modify(state->current_limit_bps) < 0) {
                DEBUG_LOG("警告: 重置带宽失败\n");
            }
            state->sigusr1 = 0;
            DEBUG_LOG("收到SIGUSR1，重置带宽为 %d kbps\n", state->current_limit_bps/1000);
        }
    }
    
    // 清理
    state->state = QMON_EXIT;
    
    // 恢复原始带宽
    if (!state->safe_mode) {
        if (tc_class_modify(state->max_bandwidth) < 0) {
            if (!DEAMON) {
                fprintf(stderr, "恢复带宽失败\n");
            }
        } else {
            DEBUG_LOG("恢复带宽为 %d kbps\n", state->max_bandwidth/1000);
        }
    }
    
    update_status_file(state);
    
    if (DEAMON) {
        syslog(LOG_INFO, "qosmon终止");
        closelog();
    }
    
    cleanup();
    
    return ret;
}