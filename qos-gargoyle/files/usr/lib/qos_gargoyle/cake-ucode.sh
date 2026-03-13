// cake.uc - CAKE QoS 实现模块 (ucode 版)
// 基于 Shell 版 v5.2-mq 转换
// 修复: 使用反引号捕获命令输出，而非 system() 的退出码

// ========== 模块引入 ==========
let fs = require("fs");
let uci = require("uci");

// ========== 全局变量 ==========
let total_upload_bandwidth = 40000;
let total_download_bandwidth = 95000;
let IFB_DEVICE = "ifb0";
let qos_interface = "";

// CAKE 专属常量
let CAKE_DIFFSERV_MODE = "diffserv4";
let CAKE_OVERHEAD = "0";
let CAKE_MPU = "0";
let CAKE_RTT = "100ms";
let CAKE_ACK_FILTER = "0";
let CAKE_NAT = "0";
let CAKE_WASH = "0";
let CAKE_SPLIT_GSO = "0";
let CAKE_INGRESS = "0";
let CAKE_AUTORATE_INGRESS = "0";
let CAKE_MEMORY_LIMIT = "32mb";
let ENABLE_AUTO_TUNE = "1";
let CAKE_MQ_ENABLED = "1";
let CAKE_DELETE_IFB_ON_STOP = "1";

// 运行时标志
let RUNTIME_SPLIT_GSO = 0;
let RUNTIME_INGRESS = 0;
let RUNTIME_AUTORATE_INGRESS = 0;

// 文件路径常量
let LOCK_DIR = "/var/run/cake_qos.lock";
let LOCK_PID_FILE = LOCK_DIR + "/pid";
let RUNTIME_PARAMS_FILE = "/tmp/cake_runtime_params";

// 调试开关
let DEBUG = 0;

// ========== 工具函数 ==========
function sanitize_param(str) {
    return str.replace(/[^a-zA-Z0-9_./:-]/g, '');
}

function log_info(msg) {
    system(`logger -t 'qos_gargoyle' 'CAKE: ${msg}'`);
    printf("[%s] CAKE: %s\n", date("%H:%M:%S"), msg);
}

function log_error(msg) {
    system(`logger -t 'qos_gargoyle' 'CAKE错误: ${msg}'`);
    printf("[%s] ❌ CAKE错误: %s\n", date("%H:%M:%S"), msg) > "/dev/stderr";
}

function log_warn(msg) {
    system(`logger -t 'qos_gargoyle' 'CAKE警告: ${msg}'`);
    printf("[%s] ⚠️ CAKE警告: %s\n", date("%H:%M:%S"), msg);
}

function log_debug(msg) {
    if (DEBUG == 1) {
        system(`logger -t 'qos_gargoyle' 'CAKE调试: ${msg}'`);
        printf("[%s] 🔍 CAKE调试: %s\n", date("%H:%M:%S"), msg);
    }
}

// ========== 依赖检查 ==========
function check_dependencies() {
    let missing = false;
    if (system("command -v tc >/dev/null 2>&1") != 0) {
        log_error("tc 命令未找到，请安装 iproute2");
        missing = true;
    }
    if (system("command -v ip >/dev/null 2>&1") != 0) {
        log_error("ip 命令未找到，请安装 iproute2");
        missing = true;
    }
    if (system("command -v uci >/dev/null 2>&1") != 0) {
        log_error("uci 命令未找到，请安装 uci");
        missing = true;
    }
    if (system("command -v ethtool >/dev/null 2>&1") != 0) {
        log_warn("ethtool 命令未找到，队列数检测将回退到 sysfs");
    }
    return missing ? 1 : 0;
}

// ========== 带宽单位转换 ==========
function convert_bandwidth_to_kbit(bw) {
    let num, unit, result;
    if (bw.match(/^[0-9]+[kKmMgG]?/)) {
        num = bw.replace(/[^0-9]/g, '');
        unit = bw.replace(/[0-9]/g, '').toUpperCase().replace(/^([KMG]).*$/, "$1");
        switch (unit) {
            case "K": result = parseInt(num); break;
            case "M": result = parseInt(num) * 1000; break;
            case "G": result = parseInt(num) * 1000000; break;
            case "": result = parseInt(num); break;
            default:
                log_error("未知带宽单位: " + unit);
                return null;
        }
        let raw_unit = bw.replace(/[0-9]/g, '').toUpperCase();
        if (raw_unit != unit && raw_unit != "") {
            log_warn(`带宽单位 '${raw_unit}' 可能不标准，已按 '${unit}' 处理（${num}${unit}=${result}kbit）`);
        }
        return result;
    } else if (bw.match(/^[0-9]+$/)) {
        return parseInt(bw);
    } else {
        log_error("无效带宽格式: " + bw);
        return null;
    }
}

// ========== 参数验证 ==========
function validate_cake_parameters(param_value, param_name) {
    switch (param_name) {
        case "bandwidth":
            if (!param_value.match(/^[0-9]+$/)) {
                log_error("无效的带宽值 (必须是数字): " + param_value);
                return 1;
            }
            if (param_value < 8) log_warn(`带宽过小: ${param_value}kbit (建议至少8kbit)`);
            if (param_value > 1000000) log_warn(`带宽过大: ${param_value}kbit (超过1Gbit)`);
            break;
        case "rtt":
            if (param_value != "" && !param_value.match(/^[0-9]*\.?[0-9]+(us|ms|s)$/i)) {
                log_warn(`无效的RTT格式: ${param_value} (应为数字+单位: us/ms/s)`);
                return 1;
            }
            break;
        case "memory_limit":
            if (param_value != "" && !param_value.match(/^[0-9]+(b|kb|mb|gb)$/i)) {
                log_warn("无效的内存限制格式: " + param_value);
                return 1;
            }
            break;
    }
    return 0;
}

function validate_diffserv_mode(mode) {
    let valid_modes = ["besteffort", "diffserv3", "diffserv4", "diffserv5", "diffserv8"];
    if (valid_modes.indexOf(mode) != -1) return 0;
    log_warn(`无效的DiffServ模式: ${mode}，使用默认值diffserv4`);
    return 1;
}

// ========== 获取设备发送队列数 ==========
function get_tx_queues(dev) {
    let queues = 1;

    // 尝试 ethtool
    let ethtool_out = `ethtool -l ${dev} 2>/dev/null | awk '/^Current hardware settings:/ { in_current=1; next } /^[^ ]/ { in_current=0 } in_current && /Combined:/ { print $2; exit }'`;
    if (ethtool_out != "") {
        let val = parseInt(ethtool_out.trim());
        if (val > 0) {
            log_debug(`ethtool (current) 获取 ${dev} 队列数: ${val}`);
            return val;
        }
    }

    ethtool_out = `ethtool -l ${dev} 2>/dev/null | grep 'Combined:' | tail -1 | awk '{print $2}'`;
    if (ethtool_out != "") {
        let val = parseInt(ethtool_out.trim());
        if (val > 0) {
            log_debug(`ethtool (fallback) 获取 ${dev} 队列数: ${val}`);
            return val;
        }
    }

    // 回退到 sysfs
    let tx_queue_count = `ls -d /sys/class/net/${dev}/queues/tx-* 2>/dev/null | wc -l`;
    if (tx_queue_count != "") {
        queues = parseInt(tx_queue_count.trim());
        log_debug(`sysfs 获取 ${dev} 队列数: ${queues}`);
    }

    if (queues == 0) queues = 1;
    return queues;
}

// ========== 检测内核是否支持特定 CAKE 参数 ==========
function check_cake_param_support(param) {
    system("tc qdisc del dev lo root 2>/dev/null");
    let ret = system(`tc qdisc add dev lo root cake bandwidth 1mbit ${param} 2>/dev/null`);
    if (ret == 0) {
        system("tc qdisc del dev lo root 2>/dev/null");
        return true;
    }
    return false;
}

// ========== 配置加载 ==========
function load_cake_config() {
    log_info("加载CAKE配置");

    let uci_cursor = uci.cursor();

    let val = uci_cursor.get("qos_gargoyle", "global", "upload_bandwidth");
    if (val) total_upload_bandwidth = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "global", "download_bandwidth");
    if (val) total_download_bandwidth = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "global", "ifb_device");
    if (val) IFB_DEVICE = sanitize_param(val);

    // 如果 qos_interface 未设置，尝试获取
    if (qos_interface == "") {
        qos_interface = uci_cursor.get("qos_gargoyle", "global", "wan_interface") || "pppoe-wan";
    }

    // CAKE 参数
    val = uci_cursor.get("qos_gargoyle", "cake", "diffserv_mode");
    if (val) CAKE_DIFFSERV_MODE = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "overhead");
    if (val) CAKE_OVERHEAD = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "mpu");
    if (val) CAKE_MPU = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "rtt");
    if (val) CAKE_RTT = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "ack_filter");
    if (val) CAKE_ACK_FILTER = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "nat");
    if (val) CAKE_NAT = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "wash");
    if (val) CAKE_WASH = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "split_gso");
    if (val) CAKE_SPLIT_GSO = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "ingress");
    if (val) CAKE_INGRESS = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "autorate_ingress");
    if (val) CAKE_AUTORATE_INGRESS = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "memlimit");
    if (val) CAKE_MEMORY_LIMIT = sanitize_param(val).toLowerCase();

    val = uci_cursor.get("qos_gargoyle", "cake", "enable_auto_tune");
    if (val) ENABLE_AUTO_TUNE = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "enable_mq");
    if (val) CAKE_MQ_ENABLED = sanitize_param(val);

    val = uci_cursor.get("qos_gargoyle", "cake", "delete_ifb_on_stop");
    if (val) CAKE_DELETE_IFB_ON_STOP = sanitize_param(val);

    log_info("CAKE配置加载完成");
}

// ========== 自动调优 ==========
function auto_tune_cake() {
    log_info("自动调整CAKE参数");

    let total_bw = 0;
    if (total_upload_bandwidth > 0 && total_download_bandwidth > 0) {
        total_bw = total_upload_bandwidth + total_download_bandwidth;
    } else if (total_upload_bandwidth > 0) {
        total_bw = total_upload_bandwidth;
    } else if (total_download_bandwidth > 0) {
        total_bw = total_download_bandwidth;
    }

    let uci_cursor = uci.cursor();
    let user_set_rtt = uci_cursor.get("qos_gargoyle", "cake", "rtt");
    let user_set_mem = uci_cursor.get("qos_gargoyle", "cake", "memlimit");

    if (total_bw > 200000) {
        if (!user_set_mem) CAKE_MEMORY_LIMIT = "128mb";
        if (!user_set_rtt) CAKE_RTT = "20ms";
        log_info(`自动调整: 超高带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}`);
    } else if (total_bw > 100000) {
        if (!user_set_mem) CAKE_MEMORY_LIMIT = "64mb";
        if (!user_set_rtt) CAKE_RTT = "50ms";
        log_info(`自动调整: 高带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}`);
    } else if (total_bw > 50000) {
        if (!user_set_mem) CAKE_MEMORY_LIMIT = "32mb";
        if (!user_set_rtt) CAKE_RTT = "100ms";
        log_info(`自动调整: 中等带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}`);
    } else if (total_bw > 10000) {
        if (!user_set_mem) CAKE_MEMORY_LIMIT = "16mb";
        if (!user_set_rtt) CAKE_RTT = "150ms";
        log_info(`自动调整: 低带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}`);
    } else {
        if (!user_set_mem) CAKE_MEMORY_LIMIT = "8mb";
        if (!user_set_rtt) CAKE_RTT = "200ms";
        log_info(`自动调整: 极低带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}`);
    }
}

// ========== 配置验证 ==========
function validate_cake_config() {
    log_info("验证CAKE配置...");

    if (!qos_interface) {
        log_error("缺少必要变量: qos_interface");
        return 1;
    }
    if (system(`ip link show dev ${qos_interface} >/dev/null 2>&1`) != 0) {
        log_error(`接口 ${qos_interface} 不存在`);
        return 1;
    }

    if (total_upload_bandwidth <= 0) {
        log_warn("上传带宽未配置或为0，跳过上传方向");
    } else {
        if (validate_cake_parameters(total_upload_bandwidth, "bandwidth") != 0) return 1;
    }

    if (total_download_bandwidth <= 0) {
        log_warn("下载带宽未配置或为0，跳过下载方向");
    } else {
        if (validate_cake_parameters(total_download_bandwidth, "bandwidth") != 0) return 1;
    }

    if (validate_diffserv_mode(CAKE_DIFFSERV_MODE) != 0) CAKE_DIFFSERV_MODE = "diffserv4";
    validate_cake_parameters(CAKE_RTT, "rtt");
    validate_cake_parameters(CAKE_MEMORY_LIMIT, "memory_limit");

    log_info("✅ CAKE配置验证通过");
    return 0;
}

// ========== 入口重定向 ==========
function setup_ingress_redirect() {
    log_info(`设置入口重定向: ${qos_interface} -> ${IFB_DEVICE}`);

    system(`tc qdisc del dev ${qos_interface} ingress 2>/dev/null`);

    if (system(`tc qdisc add dev ${qos_interface} handle ffff: ingress`) != 0) {
        log_error(`无法在${qos_interface}上创建入口队列`);
        return 1;
    }

    let ipv4_success = false;
    let ipv6_success = false;

    // IPv4
    if (system(`tc filter add dev ${qos_interface} parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ${IFB_DEVICE} 2>/dev/null`) == 0) {
        ipv4_success = true;
    } else {
        log_error("IPv4入口重定向规则添加失败");
        system(`tc qdisc del dev ${qos_interface} ingress 2>/dev/null`);
        return 1;
    }

    // IPv6
    if (system(`tc filter add dev ${qos_interface} parent ffff: protocol ipv6 match ip6 dst 2000::/3 action mirred egress redirect dev ${IFB_DEVICE} 2>/dev/null`) == 0) {
        ipv6_success = true;
    } else {
        log_warn("IPv6入口重定向规则（全球单播）添加失败，尝试无过滤规则");
        if (system(`tc filter add dev ${qos_interface} parent ffff: protocol ipv6 u32 match u32 0 0 action mirred egress redirect dev ${IFB_DEVICE} 2>/dev/null`) == 0) {
            ipv6_success = true;
        } else {
            log_warn("IPv6入口重定向规则添加失败，IPv6流量将不会通过IFB");
        }
    }

    log_info(`入口重定向设置完成 (IPv4: ${ipv4_success}, IPv6: ${ipv6_success})`);
    return 0;
}

function check_ingress_redirect() {
    log_info("检查入口重定向状态");
    let output = `tc filter show dev ${qos_interface} parent ffff: 2>/dev/null`;
    if (output.indexOf(IFB_DEVICE) != -1) {
        printf("✅ 入口重定向: 已生效\n");
        return 0;
    } else {
        printf("❌ 入口重定向: 未生效\n");
        return 1;
    }
}

// ========== 清理队列 ==========
function cleanup_existing_queues(device, direction) {
    log_info(`清理${device}上的现有${direction}队列`);

    if (direction == "upload") {
        if (system(`tc qdisc del dev ${device} root 2>/dev/null`) == 0) {
            printf("  清理上传队列完成\n");
        } else {
            printf("  无上传队列可清理\n");
        }
    } else if (direction == "download") {
        if (device == IFB_DEVICE) {
            if (system(`tc qdisc del dev ${device} root 2>/dev/null`) == 0) {
                printf("  清理IFB队列完成\n");
            } else {
                printf("  无IFB队列可清理\n");
            }
        }
    }
}

// ========== 构建CAKE参数串 ==========
function build_cake_params(bandwidth, direction) {
    let params = `bandwidth ${bandwidth}kbit ${CAKE_DIFFSERV_MODE}`;

    if (CAKE_OVERHEAD != "0") params += ` overhead ${CAKE_OVERHEAD}`;
    if (CAKE_MPU != "0") params += ` mpu ${CAKE_MPU}`;
    if (CAKE_RTT != "") params += ` rtt ${CAKE_RTT}`;
    if (CAKE_ACK_FILTER == "1") params += " ack-filter";
    if (CAKE_NAT == "1") params += " nat";
    if (CAKE_WASH == "1") params += " wash";
    if (CAKE_MEMORY_LIMIT != "") params += ` memlimit ${CAKE_MEMORY_LIMIT}`;

    // split-gso
    if (CAKE_SPLIT_GSO == "1") {
        if (check_cake_param_support("split-gso")) {
            params += " split-gso";
            RUNTIME_SPLIT_GSO = 1;
        } else {
            log_warn("内核不支持 split-gso 参数，已禁用");
        }
    }

    // ingress 相关（仅下载方向）
    if (direction == "download" && CAKE_INGRESS == "1") {
        if (check_cake_param_support("ingress")) {
            params += " ingress";
            RUNTIME_INGRESS = 1;
            if (CAKE_AUTORATE_INGRESS == "1") {
                if (check_cake_param_support("autorate-ingress")) {
                    params += " autorate-ingress";
                    RUNTIME_AUTORATE_INGRESS = 1;
                } else {
                    log_warn("内核不支持 autorate-ingress 参数，已禁用");
                }
            }
        } else {
            log_warn("内核不支持 ingress 参数，已禁用 ingress 相关功能");
        }
    }

    return params;
}

// ========== 创建CAKE根队列 ==========
function create_cake_root_qdisc(device, direction, bandwidth) {
    log_info(`为${device}创建${direction}方向CAKE队列 (带宽: ${bandwidth}kbit)`);

    if (validate_cake_parameters(bandwidth, "bandwidth") != 0) return 1;

    cleanup_existing_queues(device, direction);

    let queues = 1;
    let use_mq = 0;
    if (CAKE_MQ_ENABLED == "1") {
        queues = get_tx_queues(device);
        if (queues > 1) {
            use_mq = 1;
            log_info(`设备 ${device} 支持 ${queues} 个发送队列，启用 CAKE-MQ`);
        } else {
            log_info(`设备 ${device} 仅单个队列，使用普通 CAKE`);
        }
    } else {
        log_info("CAKE-MQ 已被禁用，使用普通 CAKE");
    }

    if (use_mq == 1) {
        let base_bw = Math.floor(bandwidth / queues);
        let remainder = bandwidth % queues;
        log_info(`带宽分配: 基础 ${base_bw}kbit/队列，余数 ${remainder}kbit 给队列1`);

        // 添加 mq 根
        if (system(`tc qdisc add dev ${device} root handle 1: mq`) != 0) {
            log_error(`无法在${device}上创建 mq 根队列`);
            return 1;
        }

        let full_params = build_cake_params(bandwidth, direction);
        // 移除开头的 "bandwidth Xkbit " 以得到基础参数
        let base_params = full_params.replace(/bandwidth [0-9]+kbit /, "");

        let success = 0;
        for (let i = 1; i <= queues; i++) {
            let queue_bw = base_bw;
            if (i == 1) queue_bw += remainder;

            printf(`正在为 %s 队列 %d 创建 CAKE 子队列 (带宽: %dkbit)...\n`, device, i, queue_bw);
            if (system(`tc qdisc add dev ${device} parent 1:${i} cake bandwidth ${queue_bw}kbit ${base_params}`) != 0) {
                log_error(`无法在${device}队列${i}上创建CAKE子队列`);
                success = 1;
                break;
            }
        }

        if (success != 0) {
            system(`tc qdisc del dev ${device} root 2>/dev/null`);
            return 1;
        }

        log_info(`${device} 的 ${direction} 方向 CAKE-MQ 队列创建完成 (共 ${queues} 个队列)`);
        printf(`✅ %s 的 %s 方向 CAKE-MQ 队列创建完成 (队列数: %d)\n`, device, direction, queues);
    } else {
        let cake_params = build_cake_params(bandwidth, direction);
        printf(`正在为 %s 创建普通CAKE队列...\n`, device);
        printf(`  参数: %s\n`, cake_params);
        if (system(`tc qdisc add dev ${device} root cake ${cake_params}`) != 0) {
            log_error(`无法在${device}上创建普通CAKE队列`);
            return 1;
        }
        log_info(`${device} 的 ${direction} 方向普通CAKE队列创建完成`);
        printf(`✅ %s 的 %s 方向普通CAKE队列创建完成\n`, device, direction);
    }

    return 0;
}

// ========== 上传初始化 ==========
function initialize_cake_upload() {
    log_info("初始化上传方向CAKE");

    if (!total_upload_bandwidth || total_upload_bandwidth <= 0) {
        log_info("上传带宽未配置，跳过上传方向初始化");
        return 0;
    }

    printf(`为 %s 创建上传CAKE队列 (带宽: %dkbit/s)\n`, qos_interface, total_upload_bandwidth);
    return create_cake_root_qdisc(qos_interface, "upload", total_upload_bandwidth);
}

// ========== 下载初始化 ==========
function initialize_cake_download() {
    log_info("初始化下载方向CAKE");

    if (!total_download_bandwidth || total_download_bandwidth <= 0) {
        log_info("下载带宽未配置，跳过下载方向初始化");
        return 0;
    }

    let expected_queues = 1;
    if (CAKE_MQ_ENABLED == "1") {
        expected_queues = get_tx_queues(qos_interface);
    }

    // 检查 IFB 设备
    let ifb_exists = system(`ip link show dev ${IFB_DEVICE} >/dev/null 2>&1`) == 0;
    if (ifb_exists) {
        log_info(`IFB设备 ${IFB_DEVICE} 已存在，检查队列数一致性`);
        let current_queues = get_tx_queues(IFB_DEVICE);
        if (current_queues != expected_queues) {
            log_warn(`IFB设备队列数 (${current_queues}) 与期望值 (${expected_queues}) 不符，将删除并重建`);
            system(`ip link set dev ${IFB_DEVICE} down`);
            system(`ip link del ${IFB_DEVICE} 2>/dev/null`);
            ifb_exists = false;
        } else {
            log_info(`IFB设备队列数一致 (${current_queues})，继续使用`);
        }
    }

    if (!ifb_exists) {
        log_info(`创建IFB设备 ${IFB_DEVICE}，队列数: ${expected_queues}`);
        if (system(`ip link add ${IFB_DEVICE} numtxqueues ${expected_queues} numrxqueues ${expected_queues} type ifb`) != 0) {
            log_error(`无法创建IFB设备 ${IFB_DEVICE} (队列数: ${expected_queues})`);
            return 1;
        }
    }

    // 确保 IFB 设备 up
    let ifb_up = system(`ip link show dev ${IFB_DEVICE} | grep -q UP`) == 0;
    if (!ifb_up) {
        if (system(`ip link set dev ${IFB_DEVICE} up`) != 0) {
            log_error(`无法启动IFB设备 ${IFB_DEVICE}`);
            return 1;
        }
    } else {
        log_info(`IFB设备 ${IFB_DEVICE} 已是 UP 状态`);
    }

    if (setup_ingress_redirect() != 0) return 1;
    return create_cake_root_qdisc(IFB_DEVICE, "download", total_download_bandwidth);
}

// ========== 健康检查 ==========
function health_check_cake() {
    printf("执行CAKE健康检查...\n");

    let health_score = 100;
    let issues = "";

    if (system(`ip link show dev ${qos_interface} >/dev/null 2>&1`) != 0) {
        health_score -= 30;
        issues += `接口 ${qos_interface} 不存在\n`;
    }

    let upload_qdisc = `tc qdisc show dev ${qos_interface} root 2>/dev/null`;
    if (upload_qdisc.indexOf("cake") == -1) {
        health_score -= 20;
        issues += "上传CAKE队列未启用\n";
    }

    if (system(`ip link show dev ${IFB_DEVICE} >/dev/null 2>&1`) != 0) {
        health_score -= 10;
        issues += "IFB设备不存在\n";
    } else {
        let download_qdisc = `tc qdisc show dev ${IFB_DEVICE} root 2>/dev/null`;
        if (download_qdisc.indexOf("cake") == -1) {
            health_score -= 20;
            issues += "下载CAKE队列未启用\n";
        }
    }

    let ingress_qdisc = `tc qdisc show dev ${qos_interface} ingress 2>/dev/null`;
    if (ingress_qdisc == "") {
        health_score -= 10;
        issues += "入口重定向未配置\n";
    }

    printf("\n健康检查结果:\n");
    printf("  健康分数: %d/100\n", health_score);
    if (issues == "") {
        printf("  ✅ 所有检查通过\n");
    } else {
        printf("  ⚠️ 发现的问题:\n");
        let lines = issues.split("\n");
        for (let i in lines) {
            if (lines[i] != "") printf("    - %s\n", lines[i]);
        }
    }

    return health_score >= 70 ? 0 : 1;
}

// ========== 状态显示 ==========
function show_cake_status() {
    printf("===== CAKE QoS状态报告 (v5.2-mq-ucode) =====\n");
    printf("时间: %s\n", date());
    printf("网络接口: %s\n", qos_interface || "未知");

    // 重新加载配置以获取最新值，但保留运行时标志覆盖
    load_cake_config();

    // 如果运行时参数文件存在，读取
    if (fs.access(RUNTIME_PARAMS_FILE, "r") == 0) {
        let content = fs.readfile(RUNTIME_PARAMS_FILE);
        let lines = content.split("\n");
        for (let i in lines) {
            let line = lines[i].trim();
            if (line == "") continue;
            let parts = line.split("=");
            if (parts.length == 2) {
                let key = parts[0].trim();
                let value = parts[1].trim().replace(/'/g, '');
                if (key == "CAKE_RTT") CAKE_RTT = value;
                else if (key == "CAKE_MEMORY_LIMIT") CAKE_MEMORY_LIMIT = value;
                else if (key == "RUNTIME_SPLIT_GSO") RUNTIME_SPLIT_GSO = parseInt(value);
                else if (key == "RUNTIME_INGRESS") RUNTIME_INGRESS = parseInt(value);
                else if (key == "RUNTIME_AUTORATE_INGRESS") RUNTIME_AUTORATE_INGRESS = parseInt(value);
            }
        }
        log_debug(`使用运行时参数: RTT=${CAKE_RTT}, MEM=${CAKE_MEMORY_LIMIT}, SPLIT_GSO=${RUNTIME_SPLIT_GSO}, INGRESS=${RUNTIME_INGRESS}, AUTORATE=${RUNTIME_AUTORATE_INGRESS}`);
    } else {
        log_debug("无运行时参数文件，使用UCI配置");
    }

    let root_qdisc = `tc qdisc show dev ${qos_interface} root 2>/dev/null`;
    if (root_qdisc == "") {
        printf(`警告: QoS未在接口 %s 上激活\n`, qos_interface);
        return 1;
    }

    // 出口队列
    printf("\n===== 出口CAKE队列 (%s) =====\n", qos_interface);
    if (root_qdisc.indexOf("cake") != -1) {
        printf("状态: 已启用 ✅\n");
        if (root_qdisc.indexOf("qdisc mq") != -1) {
            printf("模式: CAKE-MQ (多队列)\n");
            let queues = (root_qdisc.match(/qdisc cake/g) || []).length;
            printf("队列数: %d\n", queues);
        } else {
            printf("模式: 普通CAKE\n");
        }
        printf("队列参数:\n");
        let first_line = root_qdisc.split("\n")[0];
        printf("  %s\n", first_line);
        printf("\nTC队列统计:\n");
        let stats = `tc -s qdisc show dev ${qos_interface} root 2>/dev/null`;
        printf("%s\n", stats.replace(/^/gm, "  "));
    } else {
        printf("状态: 未启用 ❌\n");
    }

    // 入口队列
    printf("\n===== 入口CAKE队列 (%s) =====\n", IFB_DEVICE);
    if (system(`ip link show ${IFB_DEVICE} >/dev/null 2>&1`) == 0) {
        let ifb_qdisc = `tc qdisc show dev ${IFB_DEVICE} root 2>/dev/null`;
        if (ifb_qdisc.indexOf("cake") != -1) {
            printf("状态: 已启用 ✅\n");
            if (ifb_qdisc.indexOf("qdisc mq") != -1) {
                printf("模式: CAKE-MQ (多队列)\n");
                let queues = (ifb_qdisc.match(/qdisc cake/g) || []).length;
                printf("队列数: %d\n", queues);
            } else {
                printf("模式: 普通CAKE\n");
            }
            printf("队列参数:\n");
            let first_line = ifb_qdisc.split("\n")[0];
            printf("  %s\n", first_line);
            printf("\nTC队列统计:\n");
            let stats = `tc -s qdisc show dev ${IFB_DEVICE} root 2>/dev/null`;
            printf("%s\n", stats.replace(/^/gm, "  "));
        } else {
            printf("状态: IFB设备存在但无CAKE队列\n");
        }
    } else {
        printf("状态: IFB设备未创建\n");
    }

    // 入口重定向
    printf("\n===== 入口重定向检查 =====\n");
    let ingress_qdisc = `tc qdisc show dev ${qos_interface} ingress 2>/dev/null`;
    if (ingress_qdisc != "") {
        printf("入口队列状态: 已配置\n");
        let filters = `tc filter show dev ${qos_interface} parent ffff: 2>/dev/null`;
        if (filters == "") filters = "  无过滤器规则";
        printf("%s\n", filters.replace(/^/gm, "  "));
    } else {
        printf("入口队列状态: 未配置\n");
    }

    // CAKE配置参数
    printf("\n===== CAKE配置参数 =====\n");
    printf("DiffServ模式: %s\n", CAKE_DIFFSERV_MODE);
    printf("RTT: %s\n", CAKE_RTT);
    printf("Overhead: %s\n", CAKE_OVERHEAD);
    printf("MPU: %s\n", CAKE_MPU);
    printf("Memory Limit: %s\n", CAKE_MEMORY_LIMIT);
    printf("ACK过滤: %s\n", CAKE_ACK_FILTER == "1" ? "启用 ✅" : "禁用 ❌");
    printf("NAT支持: %s\n", CAKE_NAT == "1" ? "启用 ✅" : "禁用 ❌");
    printf("Wash: %s\n", CAKE_WASH == "1" ? "启用 ✅" : "禁用 ❌");
    let split_gso_display = (fs.access(RUNTIME_PARAMS_FILE, "r") == 0) ? RUNTIME_SPLIT_GSO : CAKE_SPLIT_GSO;
    printf("Split GSO: %s\n", split_gso_display == 1 ? "启用 ✅" : "禁用 ❌");
    let ingress_display = (fs.access(RUNTIME_PARAMS_FILE, "r") == 0) ? RUNTIME_INGRESS : CAKE_INGRESS;
    printf("Ingress模式: %s\n", ingress_display == 1 ? "启用 ✅" : "禁用 ❌");
    let autorate_display = (fs.access(RUNTIME_PARAMS_FILE, "r") == 0) ? RUNTIME_AUTORATE_INGRESS : CAKE_AUTORATE_INGRESS;
    printf("AutoRate Ingress: %s\n", autorate_display == 1 ? "启用 ✅" : "禁用 ❌");
    printf("自动调优: %s\n", ENABLE_AUTO_TUNE == "1" ? "启用 ✅" : "禁用 ❌");
    printf("CAKE-MQ多队列: %s\n", CAKE_MQ_ENABLED == "1" ? "启用 ✅" : "禁用 ❌");
    printf("停止时删除IFB: %s\n", CAKE_DELETE_IFB_ON_STOP == "1" ? "是 ✅" : "否 ❌");

    printf("\n===== 状态报告结束 =====\n");
    return 0;
}

// ========== 停止清理 ==========
function stop_cake_qos() {
    log_info("停止CAKE QoS");

    if (system(`tc qdisc show dev ${qos_interface} root 2>/dev/null | grep -q cake`) == 0) {
        system(`tc qdisc del dev ${qos_interface} root 2>/dev/null`);
        log_info("清理上传方向CAKE队列");
    }

    if (system(`ip link show dev ${IFB_DEVICE} >/dev/null 2>&1`) == 0) {
        if (system(`tc qdisc show dev ${IFB_DEVICE} root 2>/dev/null | grep -q cake`) == 0) {
            system(`tc qdisc del dev ${IFB_DEVICE} root 2>/dev/null`);
            log_info("清理下载方向CAKE队列 (IFB)");
        }
    }
    system(`tc qdisc del dev ${qos_interface} ingress 2>/dev/null`);
    log_info("清理入口重定向队列");

    if (system(`ip link show dev ${IFB_DEVICE} >/dev/null 2>&1`) == 0) {
        system(`ip link set dev ${IFB_DEVICE} down`);
        if (CAKE_DELETE_IFB_ON_STOP == "1") {
            system(`ip link del ${IFB_DEVICE} 2>/dev/null`);
            log_info(`删除IFB设备: ${IFB_DEVICE}`);
        } else {
            log_info(`停用IFB设备: ${IFB_DEVICE} (保留)`);
        }
    }

    fs.unlink(RUNTIME_PARAMS_FILE);
    log_info("CAKE QoS停止完成");
}

// ========== 锁函数 ==========
function acquire_lock() {
    if (fs.stat(LOCK_DIR) != null) {
        if (fs.stat(LOCK_PID_FILE) != null) {
            let old_pid = fs.readfile(LOCK_PID_FILE).trim();
            if (old_pid != "" && system(`kill -0 ${old_pid} 2>/dev/null`) != 0) {
                log_warn(`发现残留锁目录，进程 ${old_pid} 已不存在，清理中`);
                system(`rm -rf ${LOCK_DIR}`);
            } else {
                log_error(`无法获取锁，进程 ${old_pid} 仍在运行`);
                return 1;
            }
        } else {
            log_warn(`锁目录 ${LOCK_DIR} 存在但无PID文件，尝试强制清理`);
            system(`rm -rf ${LOCK_DIR} 2>/dev/null`);
            if (fs.stat(LOCK_DIR) != null) {
                log_error(`无法清理锁目录 ${LOCK_DIR}`);
                return 1;
            }
        }
    }

    if (system(`mkdir ${LOCK_DIR}`) != 0) {
        log_error("无法创建锁目录");
        return 1;
    }
    fs.writefile(LOCK_PID_FILE, "" + $$);
    log_debug(`已获取锁: ${LOCK_DIR} (PID: ${$$})`);
    return 0;
}

function release_lock() {
    fs.unlink(LOCK_PID_FILE);
    system(`rmdir ${LOCK_DIR} 2>/dev/null`);
    log_debug("锁已释放");
}

// ========== 主函数 ==========
function initialize_cake_qos(action) {
    switch (action) {
        case "start":
            log_info("启动CAKE QoS");
            if (check_dependencies() != 0) exit(1);
            if (acquire_lock() != 0) exit(1);

            // 重置运行时标志
            RUNTIME_SPLIT_GSO = 0;
            RUNTIME_INGRESS = 0;
            RUNTIME_AUTORATE_INGRESS = 0;

            load_cake_config();

            let up_bw = convert_bandwidth_to_kbit(total_upload_bandwidth);
            if (up_bw == null) { release_lock(); exit(1); }
            total_upload_bandwidth = up_bw;

            let down_bw = convert_bandwidth_to_kbit(total_download_bandwidth);
            if (down_bw == null) { release_lock(); exit(1); }
            total_download_bandwidth = down_bw;

            if (ENABLE_AUTO_TUNE == "1") auto_tune_cake();

            if (validate_cake_config() != 0) { release_lock(); exit(1); }

            if (initialize_cake_upload() != 0) { release_lock(); exit(1); }
            if (initialize_cake_download() != 0) { release_lock(); exit(1); }

            if (total_download_bandwidth > 0) check_ingress_redirect();

            // 保存运行时参数
            let runtime_content = `CAKE_RTT='${CAKE_RTT}'\n`;
            runtime_content += `CAKE_MEMORY_LIMIT='${CAKE_MEMORY_LIMIT}'\n`;
            runtime_content += `RUNTIME_SPLIT_GSO='${RUNTIME_SPLIT_GSO}'\n`;
            runtime_content += `RUNTIME_INGRESS='${RUNTIME_INGRESS}'\n`;
            runtime_content += `RUNTIME_AUTORATE_INGRESS='${RUNTIME_AUTORATE_INGRESS}'\n`;
            fs.writefile(RUNTIME_PARAMS_FILE, runtime_content);

            health_check_cake();
            release_lock();
            break;

        case "stop":
            log_info("停止CAKE QoS");
            stop_cake_qos();
            break;

        case "restart":
            log_info("重启CAKE QoS");
            stop_cake_qos();
            sleep(2);
            initialize_cake_qos("start");
            break;

        case "status":
        case "show":
            show_cake_status();
            break;

        case "health":
            health_check_cake();
            break;

        case "validate":
            if (check_dependencies() != 0) exit(1);
            load_cake_config();
            let up_bw = convert_bandwidth_to_kbit(total_upload_bandwidth);
            if (up_bw == null) exit(1);
            total_upload_bandwidth = up_bw;
            let down_bw = convert_bandwidth_to_kbit(total_download_bandwidth);
            if (down_bw == null) exit(1);
            total_download_bandwidth = down_bw;
            validate_cake_config();
            break;

        case "help":
            printf("用法: %s {start|stop|restart|status|health|validate|help}\n", ARGV[0]);
            printf("  start    启动CAKE QoS\n");
            printf("  stop     停止CAKE QoS\n");
            printf("  restart  重启CAKE QoS\n");
            printf("  status   显示CAKE状态\n");
            printf("  health   执行健康检查\n");
            printf("  validate 验证CAKE配置\n");
            printf("  help     显示此帮助信息\n");
            break;

        default:
            printf("错误: 未知参数 %s\n", action);
            printf("用法: %s {start|stop|restart|status|health|validate|help}\n", ARGV[0]);
            exit(1);
    }
}

// ========== 脚本入口 ==========
let args = ARGV;
if (args.length == 0) {
    printf("错误: 缺少参数\n\n");
    initialize_cake_qos("help");
    exit(1);
}

// 锁清理已在每个退出点手动处理，此处无需额外 trap
initialize_cake_qos(args[0]);

log_info("CAKE模块加载完成");