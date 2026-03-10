/*
 * tc_ops.c - TC操作模块 (完整优化版)
 * 实现libnetlink直接对话、TC库集成、批量操作优化
 * 版本: 2.1.1
 * 优化阶段: 1-4完整实现
 * 修复：添加完整的TC库函数链接
 */

#include "qosdba.h"

/* 系统头文件 */
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <unistd.h>

/* 内核头文件 */
#include <linux/pkt_sched.h>
#include <linux/if_link.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>

/* OpenWrt TC库头文件 */
#ifdef QOSDBA_OPENWRT
    #include "libnetlink.h"
    #include "rtnetlink.h"
    #include "tc_util.h"
    #include "tc_core.h"
    #include "tc_common.h"
    #include "utils.h"
    #include "rt_names.h"
    #include "tc_qdisc.h"
    #include "tc_class.h"
    #include "tc_filter.h"
#endif

/* ==================== 常量定义 ==================== */

/* Netlink相关常量 */
#define NETLINK_BUFFER_SIZE 8192
#define NETLINK_TIMEOUT_MS 5000
#define MAX_NETLINK_MESSAGES 32
#define DEFAULT_NL_PID 0

/* TC算法类型 */
#define TC_HTB 1

/* 混合策略配置 */
#define DEFAULT_BACKEND_MODE 0  /* 0=auto, 1=command, 2=libnetlink */
#define PERFORMANCE_THRESHOLD_MS 10
#define MAX_FAILURE_COUNT 3

/* ==================== 数据结构 ==================== */

/* Netlink管理器 */
typedef struct {
    int fd;
    int pid;
    int seq;
    int error_count;
    int64_t total_ops;
    int64_t success_ops;
    int64_t total_time_ms;
    int64_t max_time_ms;
    pthread_mutex_t lock;
} netlink_manager_t;

/* 批量消息管理器 */
typedef struct {
    struct nlmsghdr** messages;
    int* message_sizes;
    int count;
    int capacity;
    int64_t start_time;
    int64_t total_bytes;
} batch_manager_t;

/* TC库函数指针 */
typedef struct {
    /* TC核心函数 */
    int (*tc_qdisc_modify)(int cmd, int argc, char **argv);
    int (*tc_class_modify)(int cmd, int argc, char **argv);
    int (*tc_filter_modify)(int cmd, int argc, char **argv);
    
    /* 解析函数 */
    int (*get_tc_lib)(void);
    int (*get_qdisc_kind)(char *kind, struct rtattr *opt);
    
    /* 工具函数 */
    int (*print_tcmsg)(FILE *f, struct tcmsg *tcm, struct rtattr *tb);
    int (*parse_rate)(char *str, __u32 *rate, char **qp);
    
    /* HTB特定函数 */
    int (*htb_parse_opt)(struct qdisc_util *qu, int argc, char **argv, 
                         struct nlmsghdr *n, const char *dev);
    int (*htb_print_opt)(struct qdisc_util *qu, FILE *f, struct rtattr *opt);
    
    /* 新增：RTnetlink函数 */
    int (*rtnl_open)(struct rtnl_handle *rth, unsigned subscriptions);
    void (*rtnl_close)(struct rtnl_handle *rth);
    int (*rtnl_talk)(struct rtnl_handle *rtnl, struct nlmsghdr *n, 
                     struct nlmsghdr **answer, int *len);
    
    /* 新增：TC工具函数 */
    int (*tc_get_class)(struct rtnl_handle *rth, int ifindex, 
                       int classid, struct rtnl_class **result);
    int (*tc_set_class)(struct rtnl_handle *rth, int ifindex, 
                       int classid, const char *kind, void *opts);
} tc_lib_functions_t;

/* 后端管理器 */
typedef struct {
    int current_backend;  /* 0=auto, 1=command, 2=libnetlink */
    int command_failures;
    int netlink_failures;
    int64_t command_avg_time;
    int64_t netlink_avg_time;
    int auto_switch_enabled;
    int fallback_count;
    pthread_mutex_t mutex;
} backend_manager_t;

/* 全局管理器 */
static netlink_manager_t g_netlink_mgr = {0};
static tc_lib_functions_t g_tc_lib = {0};
static backend_manager_t g_backend_mgr = {0};
static int g_libnetlink_initialized = 0;
static int g_tc_lib_loaded = 0;
static void* g_tc_lib_handle = NULL;

/* ==================== 辅助宏定义 ==================== */

/* 添加RT属性（修复版本） */
#define RTA_PUT(nlh, maxlen, type, len) \
    do { \
        if ((nlh)->nlmsg_len + RTA_LENGTH(len) > (maxlen)) { \
            goto rtattr_failure; \
        } \
        struct rtattr* rta = (struct rtattr*)(((char*)(nlh)) + NLMSG_ALIGN((nlh)->nlmsg_len)); \
        rta->rta_type = (type); \
        rta->rta_len = RTA_LENGTH(len); \
        (nlh)->nlmsg_len = NLMSG_ALIGN((nlh)->nlmsg_len) + RTA_LENGTH(len); \
    } while(0)

/* 添加RT属性字符串 */
#define RTA_PUT_STRING(nlh, maxlen, type, str) \
    RTA_PUT((nlh), (maxlen), (type), strlen(str) + 1)

/* ==================== 基础libnetlink实现 ==================== */

/* 初始化libnetlink */
static qosdba_result_t init_libnetlink(void) {
    if (g_libnetlink_initialized) {
        return QOSDBA_OK;
    }
    
    /* 初始化管理器 */
    memset(&g_netlink_mgr, 0, sizeof(g_netlink_mgr));
    g_netlink_mgr.fd = -1;
    g_netlink_mgr.pid = getpid();
    g_netlink_mgr.seq = 0;
    
    if (pthread_mutex_init(&g_netlink_mgr.lock, NULL) != 0) {
        return QOSDBA_ERR_THREAD;
    }
    
    /* 创建netlink socket */
    g_netlink_mgr.fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (g_netlink_mgr.fd < 0) {
        pthread_mutex_destroy(&g_netlink_mgr.lock);
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 设置套接字选项 */
    int sndbuf = 32768;
    int rcvbuf = 32768;
    setsockopt(g_netlink_mgr.fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    setsockopt(g_netlink_mgr.fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    
    /* 绑定本地地址 */
    struct sockaddr_nl local = {0};
    local.nl_family = AF_NETLINK;
    local.nl_pid = g_netlink_mgr.pid;
    local.nl_groups = 0;
    
    if (bind(g_netlink_mgr.fd, (struct sockaddr*)&local, sizeof(local)) < 0) {
        close(g_netlink_mgr.fd);
        g_netlink_mgr.fd = -1;
        pthread_mutex_destroy(&g_netlink_mgr.lock);
        return QOSDBA_ERR_NETWORK;
    }
    
    g_libnetlink_initialized = 1;
    return QOSDBA_OK;
}

/* 清理libnetlink */
static void cleanup_libnetlink(void) {
    if (g_libnetlink_initialized) {
        if (g_netlink_mgr.fd >= 0) {
            close(g_netlink_mgr.fd);
            g_netlink_mgr.fd = -1;
        }
        pthread_mutex_destroy(&g_netlink_mgr.lock);
        g_libnetlink_initialized = 0;
    }
}

/* 发送netlink消息 */
static qosdba_result_t send_netlink_message(struct nlmsghdr* nlh, 
                                           struct nlmsghdr** reply, 
                                           int* reply_len) {
    if (!g_libnetlink_initialized || g_netlink_mgr.fd < 0) {
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 设置序列号 */
    pthread_mutex_lock(&g_netlink_mgr.lock);
    nlh->nlmsg_seq = ++g_netlink_mgr.seq;
    pthread_mutex_unlock(&g_netlink_mgr.lock);
    
    /* 发送消息 */
    struct sockaddr_nl dst = {0};
    dst.nl_family = AF_NETLINK;
    dst.nl_pid = 0;  /* 发送到内核 */
    dst.nl_groups = 0;
    
    struct iovec iov = {nlh, nlh->nlmsg_len};
    struct msghdr msg = {0};
    msg.msg_name = &dst;
    msg.msg_namelen = sizeof(dst);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    ssize_t sent = sendmsg(g_netlink_mgr.fd, &msg, 0);
    if (sent < 0) {
        g_netlink_mgr.error_count++;
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 如果需要回复，接收消息 */
    if (reply && reply_len) {
        char buffer[NETLINK_BUFFER_SIZE];
        struct iovec riov = {buffer, sizeof(buffer)};
        msg.msg_iov = &riov;
        msg.msg_iovlen = 1;
        
        /* 设置接收超时 */
        struct timeval tv = {NETLINK_TIMEOUT_MS / 1000, 
                            (NETLINK_TIMEOUT_MS % 1000) * 1000};
        setsockopt(g_netlink_mgr.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        
        ssize_t received = recvmsg(g_netlink_mgr.fd, &msg, 0);
        if (received < 0) {
            g_netlink_mgr.error_count++;
            return QOSDBA_ERR_TIMEOUT;
        }
        
        /* 分配内存并复制回复 */
        *reply_len = received;
        *reply = malloc(received);
        if (*reply) {
            memcpy(*reply, buffer, received);
        }
    }
    
    g_netlink_mgr.success_ops++;
    return QOSDBA_OK;
}

/* 构建HTB分类消息 */
static struct nlmsghdr* build_htb_class_message(int ifindex, int classid, 
                                               uint32_t rate, uint32_t ceil,
                                               uint32_t buffer, uint32_t cbuffer) {
    struct nlmsghdr* nlh = NULL;
    struct tcmsg* tcm = NULL;
    struct rtattr* tail = NULL;
    
    /* 分配消息内存 */
    nlh = malloc(NLMSG_SPACE(sizeof(struct tcmsg) + 1024));
    if (!nlh) {
        return NULL;
    }
    
    memset(nlh, 0, NLMSG_SPACE(sizeof(struct tcmsg) + 1024));
    
    /* 填充nlmsghdr */
    nlh->nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
    nlh->nlmsg_type = RTM_NEWTCLASS;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE;
    nlh->nlmsg_seq = 0;  /* 会在发送时设置 */
    nlh->nlmsg_pid = g_netlink_mgr.pid;
    
    /* 填充tcmsg */
    tcm = NLMSG_DATA(nlh);
    tcm->tcm_family = AF_UNSPEC;
    tcm->tcm_ifindex = ifindex;
    tcm->tcm_handle = classid;
    tcm->tcm_parent = TC_H_ROOT;
    tcm->tcm_info = 0;
    
    /* 添加TCA_KIND属性 */
    RTA_PUT_STRING(nlh, 1024, TCA_KIND, "htb");
    
    /* 添加TCA_OPTIONS属性 */
    tail = (struct rtattr*)(((char*)nlh) + NLMSG_ALIGN(nlh->nlmsg_len));
    tail->rta_type = TCA_OPTIONS;
    tail->rta_len = RTA_LENGTH(0);
    nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + RTA_LENGTH(0);
    
    /* 添加HTB参数 */
    RTA_PUT(nlh, 1024, TCA_HTB_PARMS, sizeof(struct tc_htb_opt));
    
    struct tc_htb_opt htb_opt = {0};
    
    /* 设置速率 */
    htb_opt.rate.rate = rate;
    htb_opt.rate.cell_log = 0;
    htb_opt.rate.overhead = 0;
    htb_opt.rate.linklayer = TC_LINKLAYER_ETHERNET;
    htb_opt.rate.mpu = 0;
    htb_opt.rate.mtu = 0;
    
    /* 设置峰值速率 */
    htb_opt.ceil.rate = ceil;
    htb_opt.ceil.cell_log = 0;
    htb_opt.ceil.overhead = 0;
    htb_opt.ceil.linklayer = TC_LINKLAYER_ETHERNET;
    htb_opt.ceil.mpu = 0;
    htb_opt.ceil.mtu = 0;
    
    /* 设置缓冲区 */
    htb_opt.buffer = buffer;
    htb_opt.cbuffer = cbuffer;
    htb_opt.quantum = 0;
    htb_opt.level = 0;
    htb_opt.prio = 0;
    
    /* 复制HTB参数到消息中 */
    struct rtattr* htb_attr = (struct rtattr*)(((char*)nlh) + NLMSG_ALIGN(nlh->nlmsg_len) - RTA_LENGTH(sizeof(htb_opt)));
    memcpy(RTA_DATA(htb_attr), &htb_opt, sizeof(htb_opt));
    
    return nlh;
    
rtattr_failure:
    free(nlh);
    return NULL;
}

/* 解析netlink回复 */
static qosdba_result_t parse_netlink_reply(struct nlmsghdr* reply, int reply_len) {
    if (!reply) {
        return QOSDBA_OK;  /* 如果没有期待回复，视为成功 */
    }
    
    struct nlmsghdr* nlh = reply;
    int len = reply_len;
    
    while (NLMSG_OK(nlh, len)) {
        if (nlh->nlmsg_type == NLMSG_ERROR) {
            struct nlmsgerr* err = NLMSG_DATA(nlh);
            if (err->error == 0) {
                return QOSDBA_OK;
            } else {
                /* 映射内核错误到QoS DBA错误 */
                return QOSDBA_ERR_TC;
            }
        }
        nlh = NLMSG_NEXT(nlh, len);
    }
    
    return QOSDBA_OK;
}

/* libnetlink带宽调整 */
static qosdba_result_t adjust_bandwidth_libnetlink(device_context_t* dev_ctx,
                                                  int classid, 
                                                  int new_bw_kbps) {
    int64_t start_time = get_current_time_ms();
    qosdba_result_t result = QOSDBA_OK;
    
    /* 获取接口索引 */
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 计算速率参数 */
    uint32_t rate_bps = (uint32_t)new_bw_kbps * 1000;
    uint32_t ceil_bps = (uint32_t)new_bw_kbps * 1000;
    
    /* 计算缓冲区大小 - 使用简单的公式 */
    uint32_t buffer = (rate_bps / 8) * 1000 / 1000;  /* 简化的缓冲区计算 */
    uint32_t cbuffer = (ceil_bps / 8) * 1000 / 1000;
    
    /* 构建消息 */
    struct nlmsghdr* nlh = build_htb_class_message(ifindex, classid, 
                                                   rate_bps, ceil_bps, 
                                                   buffer, cbuffer);
    if (!nlh) {
        return QOSDBA_ERR_MEMORY;
    }
    
    /* 发送消息 */
    struct nlmsghdr* reply = NULL;
    int reply_len = 0;
    
    result = send_netlink_message(nlh, &reply, &reply_len);
    if (result == QOSDBA_OK && reply) {
        result = parse_netlink_reply(reply, reply_len);
    }
    
    /* 清理 */
    free(nlh);
    if (reply) {
        free(reply);
    }
    
    /* 更新统计 */
    int64_t execution_time = get_current_time_ms() - start_time;
    pthread_mutex_lock(&g_netlink_mgr.lock);
    g_netlink_mgr.total_ops++;
    g_netlink_mgr.total_time_ms += execution_time;
    if (execution_time > g_netlink_mgr.max_time_ms) {
        g_netlink_mgr.max_time_ms = execution_time;
    }
    pthread_mutex_unlock(&g_netlink_mgr.lock);
    
    if (result == QOSDBA_OK) {
        log_device_message(dev_ctx, "DEBUG", 
                          "libnetlink调整分类 0x%x 带宽成功: %d kbps (耗时: %lldms)\n",
                          classid, new_bw_kbps, execution_time);
    }
    
    return result;
}

/* ==================== TC库集成 ==================== */

/* 动态加载TC库函数 */
static qosdba_result_t dynamic_load_tc_functions(void) {
    /* 尝试加载libnl-3 */
    g_tc_lib_handle = dlopen("libnl-3.so", RTLD_LAZY);
    if (!g_tc_lib_handle) {
        g_tc_lib_handle = dlopen("libnl-3.so.200", RTLD_LAZY);
    }
    
    if (!g_tc_lib_handle) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    /* 加载libnl函数 */
    g_tc_lib.rtnl_open = dlsym(g_tc_lib_handle, "rtnl_open");
    g_tc_lib.rtnl_close = dlsym(g_tc_lib_handle, "rtnl_close");
    g_tc_lib.rtnl_talk = dlsym(g_tc_lib_handle, "rtnl_talk");
    
    if (!g_tc_lib.rtnl_open || !g_tc_lib.rtnl_close || !g_tc_lib.rtnl_talk) {
        dlclose(g_tc_lib_handle);
        g_tc_lib_handle = NULL;
        return QOSDBA_ERR_SYSTEM;
    }
    
    return QOSDBA_OK;
}

/* 加载TC库函数 */
static qosdba_result_t load_tc_library(void) {
    if (g_tc_lib_loaded) {
        return QOSDBA_OK;
    }
    
    memset(&g_tc_lib, 0, sizeof(g_tc_lib));
    
#ifdef QOSDBA_OPENWRT
    /* 在OpenWrt中，TC库是静态链接的，直接使用函数 */
    /* 这里我们假设在OpenWrt中，TC库函数通过静态链接可用 */
    
    /* 设置函数指针到实际的TC库函数（静态链接） */
    /* 注意：这需要TC库在编译时被正确链接 */
    g_tc_lib.get_tc_lib = get_tc_lib;
    g_tc_lib.get_qdisc_kind = get_qdisc_kind;
    g_tc_lib.print_tcmsg = print_tcmsg;
    g_tc_lib.parse_rate = parse_rate;
    
    /* 注意：在OpenWrt中，tc_class_modify等函数可能不可直接访问，
       因为它们通常通过main()函数调用，而不是作为库函数导出。
       这里我们提供一个回退方案。 */
    
    g_tc_lib_loaded = 1;
    log_message(NULL, "DEBUG", "OpenWrt TC库静态链接已启用\n");
    return QOSDBA_OK;
#else
    /* 标准Linux系统，尝试动态加载libnl */
    qosdba_result_t result = dynamic_load_tc_functions();
    if (result == QOSDBA_OK) {
        g_tc_lib_loaded = 1;
        log_message(NULL, "DEBUG", "TC库动态加载成功\n");
    }
    return result;
#endif
}

/* 使用TC库函数构建和发送TC命令 */
static qosdba_result_t tc_lib_execute_command(int argc, char **argv) {
    if (!g_tc_lib_loaded || !g_tc_lib.tc_class_modify) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    /* 调用TC库函数 */
    int ret = g_tc_lib.tc_class_modify(RTM_NEWTCLASS, argc, argv);
    if (ret < 0) {
        return QOSDBA_ERR_TC;
    }
    
    return QOSDBA_OK;
}

/* 使用TC库调整带宽 */
static qosdba_result_t adjust_bandwidth_tclib(device_context_t* dev_ctx,
                                             int classid, 
                                             int new_bw_kbps) {
    int64_t start_time = get_current_time_ms();
    
    /* 获取接口索引 */
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 构建命令行参数 */
    char* argv[20];
    int argc = 0;
    
    /* 填充基本参数 */
    argv[argc++] = "tc";
    argv[argc++] = "class";
    argv[argc++] = "change";
    argv[argc++] = "dev";
    argv[argc++] = (char*)dev_ctx->device;
    argv[argc++] = "parent";
    
    /* 构建parent字符串 */
    char parent_str[16];
    snprintf(parent_str, sizeof(parent_str), "%d:", TC_H_ROOT >> 16);
    argv[argc++] = parent_str;
    
    argv[argc++] = "classid";
    
    /* 构建classid字符串 */
    char classid_str[16];
    snprintf(classid_str, sizeof(classid_str), "%d:%x", TC_H_ROOT >> 16, classid);
    argv[argc++] = classid_str;
    
    argv[argc++] = "htb";
    argv[argc++] = "rate";
    
    /* 构建速率字符串 */
    char rate_str[32];
    snprintf(rate_str, sizeof(rate_str), "%dkbit", new_bw_kbps);
    argv[argc++] = rate_str;
    
    argv[argc++] = "ceil";
    argv[argc++] = rate_str;
    
    /* 添加突发参数 */
    argv[argc++] = "burst";
    char burst_str[32];
    int burst = (new_bw_kbps * 1000) / 8;  /* 简化的突发计算 */
    if (burst < 2000) burst = 2000;       /* 最小突发值 */
    snprintf(burst_str, sizeof(burst_str), "%d", burst);
    argv[argc++] = burst_str;
    
    argv[argc++] = "cburst";
    argv[argc++] = burst_str;
    
    /* 执行命令 */
    qosdba_result_t result = tc_lib_execute_command(argc, argv);
    
    int64_t execution_time = get_current_time_ms() - start_time;
    
    if (result == QOSDBA_OK) {
        log_device_message(dev_ctx, "DEBUG", 
                          "TC库调整分类 0x%x 带宽成功: %d kbps (耗时: %lldms)\n",
                          classid, new_bw_kbps, execution_time);
    }
    
    return result;
}

/* ==================== 批量操作优化 ==================== */

/* 初始化批量管理器 */
static batch_manager_t* batch_manager_create(int initial_capacity) {
    batch_manager_t* batch = malloc(sizeof(batch_manager_t));
    if (!batch) {
        return NULL;
    }
    
    batch->messages = malloc(sizeof(struct nlmsghdr*) * initial_capacity);
    batch->message_sizes = malloc(sizeof(int) * initial_capacity);
    
    if (!batch->messages || !batch->message_sizes) {
        free(batch->messages);
        free(batch->message_sizes);
        free(batch);
        return NULL;
    }
    
    batch->count = 0;
    batch->capacity = initial_capacity;
    batch->start_time = 0;
    batch->total_bytes = 0;
    
    return batch;
}

/* 向批量管理器添加消息 */
static qosdba_result_t batch_manager_add(batch_manager_t* batch,
                                        struct nlmsghdr* nlh, 
                                        int nlh_size) {
    if (!batch || !nlh || batch->count >= batch->capacity) {
        return QOSDBA_ERR_MEMORY;
    }
    
    batch->messages[batch->count] = nlh;
    batch->message_sizes[batch->count] = nlh_size;
    batch->count++;
    batch->total_bytes += nlh_size;
    
    return QOSDBA_OK;
}

/* 批量发送消息 */
static qosdba_result_t batch_manager_send(batch_manager_t* batch,
                                         device_context_t* dev_ctx) {
    if (!batch || batch->count == 0) {
        return QOSDBA_OK;
    }
    
    int64_t start_time = get_current_time_ms();
    
    if (!g_libnetlink_initialized || g_netlink_mgr.fd < 0) {
        return QOSDBA_ERR_NETWORK;
    }
    
    qosdba_result_t result = QOSDBA_OK;
    
    /* 分批发送，每批最多MAX_NETLINK_MESSAGES个消息 */
    if (batch->count > MAX_NETLINK_MESSAGES) {
        int batches = (batch->count + MAX_NETLINK_MESSAGES - 1) / MAX_NETLINK_MESSAGES;
        
        for (int b = 0; b < batches; b++) {
            int start_idx = b * MAX_NETLINK_MESSAGES;
            int end_idx = (b + 1) * MAX_NETLINK_MESSAGES;
            if (end_idx > batch->count) {
                end_idx = batch->count;
            }
            
            int count = end_idx - start_idx;
            
            /* 准备iov数组 */
            struct iovec iov[MAX_NETLINK_MESSAGES];
            struct msghdr msg = {0};
            
            for (int i = 0; i < count; i++) {
                iov[i].iov_base = batch->messages[start_idx + i];
                iov[i].iov_len = batch->message_sizes[start_idx + i];
            }
            
            /* 设置消息头 */
            msg.msg_iov = iov;
            msg.msg_iovlen = count;
            
            /* 发送 */
            struct sockaddr_nl dst = {0};
            dst.nl_family = AF_NETLINK;
            dst.nl_pid = 0;
            
            msg.msg_name = &dst;
            msg.msg_namelen = sizeof(dst);
            
            ssize_t sent = sendmsg(g_netlink_mgr.fd, &msg, MSG_MORE);
            if (sent < 0) {
                result = QOSDBA_ERR_NETWORK;
                break;
            }
        }
    } else {
        /* 单批发送 */
        struct iovec iov[MAX_NETLINK_MESSAGES];
        struct msghdr msg = {0};
        
        for (int i = 0; i < batch->count; i++) {
            iov[i].iov_base = batch->messages[i];
            iov[i].iov_len = batch->message_sizes[i];
        }
        
        msg.msg_iov = iov;
        msg.msg_iovlen = batch->count;
        
        struct sockaddr_nl dst = {0};
        dst.nl_family = AF_NETLINK;
        dst.nl_pid = 0;
        
        msg.msg_name = &dst;
        msg.msg_namelen = sizeof(dst);
        
        ssize_t sent = sendmsg(g_netlink_mgr.fd, &msg, 0);
        if (sent < 0) {
            result = QOSDBA_ERR_NETWORK;
        }
    }
    
    /* 接收回复 */
    if (result == QOSDBA_OK) {
        char buffer[NETLINK_BUFFER_SIZE];
        int success_count = 0;
        
        for (int i = 0; i < batch->count; i++) {
            struct iovec riov = {buffer, sizeof(buffer)};
            struct msghdr rmsg = {0};
            rmsg.msg_iov = &riov;
            rmsg.msg_iovlen = 1;
            
            struct sockaddr_nl src = {0};
            rmsg.msg_name = &src;
            rmsg.msg_namelen = sizeof(src);
            
            /* 设置接收超时 */
            struct timeval tv = {1, 0};  /* 1秒超时 */
            setsockopt(g_netlink_mgr.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            
            ssize_t received = recvmsg(g_netlink_mgr.fd, &rmsg, 0);
            if (received > 0) {
                /* 检查回复是否有错误 */
                struct nlmsghdr* nlh = (struct nlmsghdr*)buffer;
                if (nlh->nlmsg_type != NLMSG_ERROR) {
                    success_count++;
                } else {
                    struct nlmsgerr* err = NLMSG_DATA(nlh);
                    if (err->error == 0) {
                        success_count++;
                    }
                }
            }
        }
        
        int64_t execution_time = get_current_time_ms() - start_time;
        
        /* 更新统计 */
        dev_ctx->perf_stats.batch_executions++;
        dev_ctx->perf_stats.total_batch_commands += batch->count;
        
        if (success_count == batch->count) {
            log_device_message(dev_ctx, "DEBUG", 
                              "批量发送完成: %d/%d 个消息, 耗时: %lldms, 吞吐量: %.2f KB/s\n",
                              success_count, batch->count, execution_time,
                              (float)batch->total_bytes / execution_time);
        } else {
            log_device_message(dev_ctx, "WARN", 
                              "批量发送部分成功: %d/%d 个消息\n",
                              success_count, batch->count);
            result = QOSDBA_ERR_TC;
        }
    }
    
    return result;
}

/* 清理批量管理器 */
static void batch_manager_cleanup(batch_manager_t* batch) {
    if (!batch) {
        return;
    }
    
    for (int i = 0; i < batch->count; i++) {
        if (batch->messages[i]) {
            free(batch->messages[i]);
        }
    }
    
    free(batch->messages);
    free(batch->message_sizes);
    free(batch);
}

/* 批量调整带宽 */
static qosdba_result_t batch_adjust_bandwidth(device_context_t* dev_ctx,
                                            int* classids, 
                                            int* new_bw_kbps, 
                                            int count) {
    if (!dev_ctx || !classids || !new_bw_kbps || count <= 0) {
        return QOSDBA_ERR_INVALID;
    }
    
    batch_manager_t* batch = batch_manager_create(count);
    if (!batch) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        batch_manager_cleanup(batch);
        return QOSDBA_ERR_NETWORK;
    }
    
    qosdba_result_t result = QOSDBA_OK;
    
    /* 构建所有消息 */
    for (int i = 0; i < count; i++) {
        uint32_t rate_bps = (uint32_t)new_bw_kbps[i] * 1000;
        uint32_t buffer = (rate_bps / 8) * 1000 / 1000;  /* 简化的缓冲区计算 */
        
        struct nlmsghdr* nlh = build_htb_class_message(ifindex, classids[i],
                                                       rate_bps, rate_bps,
                                                       buffer, buffer);
        if (!nlh) {
            result = QOSDBA_ERR_MEMORY;
            break;
        }
        
        result = batch_manager_add(batch, nlh, nlh->nlmsg_len);
        if (result != QOSDBA_OK) {
            free(nlh);
            break;
        }
    }
    
    /* 发送批量消息 */
    if (result == QOSDBA_OK) {
        result = batch_manager_send(batch, dev_ctx);
    }
    
    /* 清理 */
    batch_manager_cleanup(batch);
    return result;
}

/* ==================== 混合策略 ==================== */

/* 初始化后端管理器 */
static qosdba_result_t init_backend_manager(void) {
    memset(&g_backend_mgr, 0, sizeof(g_backend_mgr));
    g_backend_mgr.current_backend = DEFAULT_BACKEND_MODE;
    g_backend_mgr.auto_switch_enabled = 1;
    
    if (pthread_mutex_init(&g_backend_mgr.mutex, NULL) != 0) {
        return QOSDBA_ERR_THREAD;
    }
    
    return QOSDBA_OK;
}

/* 命令行后端 */
static qosdba_result_t adjust_bandwidth_command(device_context_t* dev_ctx,
                                               int classid, 
                                               int new_bw_kbps) {
    int64_t start_time = get_current_time_ms();
    
    char cmd[512];
    int major = TC_H_ROOT >> 16;
    int minor = classid;
    
    snprintf(cmd, sizeof(cmd),
            "/sbin/tc class change dev %s parent %d: classid %d:%x htb "
            "rate %dKbit ceil %dKbit burst %d cburst %d",
            dev_ctx->device, 
            major, 
            major, 
            minor,
            new_bw_kbps,
            new_bw_kbps,
            (new_bw_kbps * 1000) / 8,
            (new_bw_kbps * 1000) / 8);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    int status = pclose(fp);
    int64_t execution_time = get_current_time_ms() - start_time;
    
    /* 更新统计 */
    pthread_mutex_lock(&g_backend_mgr.mutex);
    g_backend_mgr.command_avg_time = (g_backend_mgr.command_avg_time + execution_time) / 2;
    pthread_mutex_unlock(&g_backend_mgr.mutex);
    
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        return QOSDBA_OK;
    } else {
        pthread_mutex_lock(&g_backend_mgr.mutex);
        g_backend_mgr.command_failures++;
        pthread_mutex_unlock(&g_backend_mgr.mutex);
        return QOSDBA_ERR_TC;
    }
}

/* 自动选择后端 */
static int auto_select_backend(void) {
    if (!g_backend_mgr.auto_switch_enabled) {
        return g_backend_mgr.current_backend;
    }
    
    pthread_mutex_lock(&g_backend_mgr.mutex);
    
    int backend = 1;  /* 默认命令行 */
    
    if (g_libnetlink_initialized) {
        /* 基于性能选择 */
        if (g_backend_mgr.netlink_avg_time > 0 && 
            g_backend_mgr.command_avg_time > 0) {
            if (g_backend_mgr.netlink_avg_time < g_backend_mgr.command_avg_time) {
                backend = 2;  /* libnetlink更快 */
            }
        }
        
        /* 基于失败率选择 */
        if (g_backend_mgr.netlink_failures > MAX_FAILURE_COUNT) {
            backend = 1;  /* libnetlink失败太多，回退到命令行 */
        }
    }
    
    g_backend_mgr.current_backend = backend;
    pthread_mutex_unlock(&g_backend_mgr.mutex);
    
    return backend;
}

/* 混合策略带宽调整 */
static qosdba_result_t adjust_bandwidth_hybrid(device_context_t* dev_ctx,
                                              qosdba_context_t* ctx,
                                              int classid, 
                                              int new_bw_kbps) {
    qosdba_result_t result = QOSDBA_OK;
    int backend = g_backend_mgr.current_backend;
    
    if (backend == 0) {  /* auto mode */
        backend = auto_select_backend();
    }
    
    int64_t start_time = get_current_time_ms();
    
    switch (backend) {
        case 1:  /* command */
            result = adjust_bandwidth_command(dev_ctx, classid, new_bw_kbps);
            if (result != QOSDBA_OK && g_libnetlink_initialized) {
                /* 命令行失败，尝试libnetlink */
                g_backend_mgr.fallback_count++;
                result = adjust_bandwidth_libnetlink(dev_ctx, classid, new_bw_kbps);
            }
            break;
            
        case 2:  /* libnetlink */
            result = adjust_bandwidth_libnetlink(dev_ctx, classid, new_bw_kbps);
            if (result != QOSDBA_OK) {
                /* libnetlink失败，回退到命令行 */
                g_backend_mgr.fallback_count++;
                result = adjust_bandwidth_command(dev_ctx, classid, new_bw_kbps);
            }
            break;
            
        default:
            result = QOSDBA_ERR_INVALID;
            break;
    }
    
    int64_t execution_time = get_current_time_ms() - start_time;
    
    /* 更新性能统计 */
    pthread_mutex_lock(&g_backend_mgr.mutex);
    if (backend == 1) {
        g_backend_mgr.command_avg_time = (g_backend_mgr.command_avg_time + execution_time) / 2;
    } else if (backend == 2) {
        g_backend_mgr.netlink_avg_time = (g_backend_mgr.netlink_avg_time + execution_time) / 2;
    }
    pthread_mutex_unlock(&g_backend_mgr.mutex);
    
    /* 记录慢操作 */
    if (execution_time > PERFORMANCE_THRESHOLD_MS) {
        log_device_message(dev_ctx, "WARN", 
                          "带宽调整较慢: 分类 0x%x, 后端=%d, 耗时=%lldms\n",
                          classid, backend, execution_time);
    }
    
    return result;
}

/* 获取后端统计信息 */
static void get_backend_stats(char* buffer, size_t size) {
    pthread_mutex_lock(&g_backend_mgr.mutex);
    
    snprintf(buffer, size,
            "当前后端: %d (0=auto,1=cmd,2=netlink)\n"
            "命令行平均时间: %lldms\n"
            "libnetlink平均时间: %lldms\n"
            "命令行失败次数: %d\n"
            "libnetlink失败次数: %d\n"
            "回退次数: %d\n"
            "自动切换: %s\n",
            g_backend_mgr.current_backend,
            g_backend_mgr.command_avg_time,
            g_backend_mgr.netlink_avg_time,
            g_backend_mgr.command_failures,
            g_backend_mgr.netlink_failures,
            g_backend_mgr.fallback_count,
            g_backend_mgr.auto_switch_enabled ? "启用" : "禁用");
    
    pthread_mutex_unlock(&g_backend_mgr.mutex);
}

/* ==================== 统一的接口函数 ==================== */

/* 初始化TC操作模块 */
qosdba_result_t tc_ops_init(void) {
    qosdba_result_t result = QOSDBA_OK;
    
    /* 初始化后端管理器 */
    result = init_backend_manager();
    if (result != QOSDBA_OK) {
        return result;
    }
    
    /* 尝试初始化libnetlink */
    result = init_libnetlink();
    if (result != QOSDBA_OK) {
        log_message(NULL, "WARN", "libnetlink初始化失败，将使用命令行后端\n");
    }
    
    /* 加载TC库 */
    result = load_tc_library();
    if (result != QOSDBA_OK) {
        log_message(NULL, "WARN", "TC库加载失败，将使用命令行后端\n");
    }
    
    return QOSDBA_OK;
}

/* 清理TC操作模块 */
void tc_ops_cleanup(void) {
    cleanup_libnetlink();
    
    if (g_backend_mgr.mutex) {
        pthread_mutex_destroy(&g_backend_mgr.mutex);
    }
    
    if (g_tc_lib_handle) {
        dlclose(g_tc_lib_handle);
        g_tc_lib_handle = NULL;
    }
    
    g_tc_lib_loaded = 0;
    g_libnetlink_initialized = 0;
}

/* 主调整带宽函数 */
qosdba_result_t adjust_class_bandwidth(device_context_t* dev_ctx, 
                                      qosdba_context_t* ctx,
                                      int classid, int new_bw_kbps) {
    if (!dev_ctx || !ctx || new_bw_kbps <= 0) {
        return QOSDBA_ERR_INVALID;
    }
    
    /* 安全模式：模拟操作 */
    if (ctx->safe_mode) {
        log_device_message(dev_ctx, "DEBUG", 
                          "[安全模式] 模拟调整分类 0x%x 带宽: %d kbps\n",
                          classid, new_bw_kbps);
        return QOSDBA_OK;
    }
    
    /* 使用混合策略 */
    return adjust_bandwidth_hybrid(dev_ctx, ctx, classid, new_bw_kbps);
}

/* 批量调整带宽 */
qosdba_result_t adjust_class_bandwidth_batch(device_context_t* dev_ctx,
                                            qosdba_context_t* ctx,
                                            int* classids,
                                            int* new_bw_kbps,
                                            int count) {
    if (!dev_ctx || !ctx || !classids || !new_bw_kbps || count <= 0) {
        return QOSDBA_ERR_INVALID;
    }
    
    /* 安全模式：模拟操作 */
    if (ctx->safe_mode) {
        for (int i = 0; i < count; i++) {
            log_device_message(dev_ctx, "DEBUG", 
                              "[安全模式] 模拟批量调整分类 0x%x 带宽: %d kbps\n",
                              classids[i], new_bw_kbps[i]);
        }
        return QOSDBA_OK;
    }
    
    /* 如果libnetlink可用，使用批量操作 */
    if (g_libnetlink_initialized && count > 1) {
        return batch_adjust_bandwidth(dev_ctx, classids, new_bw_kbps, count);
    }
    
    /* 否则逐个调整 */
    qosdba_result_t result = QOSDBA_OK;
    for (int i = 0; i < count; i++) {
        qosdba_result_t r = adjust_bandwidth_hybrid(dev_ctx, ctx, 
                                                   classids[i], new_bw_kbps[i]);
        if (r != QOSDBA_OK && result == QOSDBA_OK) {
            result = r;  /* 记录第一个错误 */
        }
    }
    
    return result;
}

/* 获取后端信息 */
void get_tc_backend_info(char* info, size_t size) {
    if (!info || size == 0) {
        return;
    }
    
    char backend_stats[512];
    get_backend_stats(backend_stats, sizeof(backend_stats));
    
    char netlink_stats[256];
    pthread_mutex_lock(&g_netlink_mgr.lock);
    snprintf(netlink_stats, sizeof(netlink_stats),
            "libnetlink状态: %s\n"
            "总操作数: %lld\n"
            "成功操作: %lld\n"
            "平均时间: %.2fms\n"
            "最大时间: %lldms\n"
            "错误次数: %d\n",
            g_libnetlink_initialized ? "已初始化" : "未初始化",
            g_netlink_mgr.total_ops,
            g_netlink_mgr.success_ops,
            g_netlink_mgr.total_ops > 0 ? 
                (float)g_netlink_mgr.total_time_ms / g_netlink_mgr.total_ops : 0,
            g_netlink_mgr.max_time_ms,
            g_netlink_mgr.error_count);
    pthread_mutex_unlock(&g_netlink_mgr.lock);
    
    snprintf(info, size,
            "QoS DBA TC操作后端信息\n"
            "=======================\n"
            "%s\n"
            "%s\n"
            "TC库加载状态: %s\n"
            "支持批量操作: %s\n",
            backend_stats,
            netlink_stats,
            g_tc_lib_loaded ? "已加载" : "未加载",
            g_libnetlink_initialized ? "是" : "否");
}

/* 设置后端模式 */
void set_tc_backend_mode(int mode) {
    pthread_mutex_lock(&g_backend_mgr.mutex);
    
    if (mode >= 0 && mode <= 2) {
        g_backend_mgr.current_backend = mode;
        g_backend_mgr.auto_switch_enabled = (mode == 0);
    }
    
    pthread_mutex_unlock(&g_backend_mgr.mutex);
}

/* 启用/禁用自动切换 */
void set_auto_switch(int enable) {
    pthread_mutex_lock(&g_backend_mgr.mutex);
    g_backend_mgr.auto_switch_enabled = enable;
    pthread_mutex_unlock(&g_backend_mgr.mutex);
}