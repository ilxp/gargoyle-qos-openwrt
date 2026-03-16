#!/bin/sh
# version=2.20
# HFSC_CAKE算法实现模块
# 基于HFSC与CAKE组合算法实现QoS流量控制。
# 必要工具：tc, nft, conntrack, ethtool, sysctl
# 内核模块：ifb, sch_hfsc, sch_cake
# 注意：规则应用由外部init.d脚本负责，本脚本仅创建队列和基础nftables链。

# ========== 全局配置常量 ==========
: ${CONFIG_FILE:=qos_gargoyle}
: ${LOCK_FILE:=/var/run/hfsc_cake.lock}            # 并发锁文件
: ${RUNNING_FILE:=/var/run/hfsc_cake.running}      # 运行标记文件
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}               # 最大物理带宽10Gbps（单位kbit），实际会尽力检测
: ${UPLOAD_MASK:=0xFFFF}           					# 上传方向标记掩码，使用低 16 位
: ${DOWNLOAD_MASK:=0xFFFF0000}    				 	# 下载方向标记掩码，使用高 16 位
: ${DELETE_IFB_ON_STOP:=0}                           # 停止时是否删除IFB设备（默认0不删除）
: ${DEBUG:=0}                                         # 调试开关，0关闭，1开启
# 全局变量
upload_class_list=""
download_class_list=""
upload_class_mark_list=""
download_class_mark_list=""
qos_interface=""
IFB_DEVICE=""

# 加载规则辅助模块（必须）
if [ -f "/usr/lib/qos_gargoyle/rule.sh" ]; then
    . /usr/lib/qos_gargoyle/rule.sh
    # 将别名改为函数定义
    qos_log() { log "$@"; }
else
    echo "错误: 规则辅助模块 /usr/lib/qos_gargoyle/rule.sh 未找到" >&2
    exit 1
fi

# 加载必要的库
. /lib/functions.sh
. /lib/functions/network.sh
include /lib/network

# ========== 辅助函数 ==========
# 带宽单位转换（支持 kbit, mbit, gbit, KB, MB 等）
convert_bandwidth_to_kbit() {
    local bw="$1"
    local num unit result

    [ -z "$bw" ] && { qos_log "ERROR" "带宽值为空"; return 1; }

    # 纯数字直接返回
    if echo "$bw" | grep -qE '^[0-9]+$'; then
        echo "$bw"
        return 0
    fi

    # 处理数字+单位格式
    if echo "$bw" | grep -qiE '^[0-9]+(\.[0-9]+)?[a-zA-Z]+$'; then
        num=$(echo "$bw" | grep -oE '^[0-9]+(\.[0-9]+)?')
        unit=$(echo "$bw" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

        case "$unit" in
            K|KB|KIB|Kbit|KBIT|KILOBIT)
                result=$(awk "BEGIN {printf \"%.0f\", $num * 1}")
                ;;
            M|MB|MIB|Mbit|MBIT|MEGABIT)
                result=$(awk "BEGIN {printf \"%.0f\", $num * 1000}")
                ;;
            G|GB|GIB|Gbit|GBIT|GIGABIT)
                result=$(awk "BEGIN {printf \"%.0f\", $num * 1000000}")
                ;;
            *)
                qos_log "ERROR" "未知带宽单位: $unit"
                return 1
                ;;
        esac

        if [ -z "$result" ] || ! echo "$result" | grep -qE '^[0-9]+$' || [ "$result" -lt 0 ] 2>/dev/null; then
            qos_log "ERROR" "带宽转换结果无效: $result"
            return 1
        fi

        echo "$result"
        return 0
    else
        qos_log "ERROR" "无效带宽格式: $bw (应为数字或数字+单位，例如 100mbit、10M)"
        return 1
    fi
}

# 检查 tc 是否支持 action connmark
check_tc_connmark_support() {
    # 尝试在 lo 上添加临时 ingress 规则，使用 connmark 动作
    tc qdisc del dev lo ingress 2>/dev/null
    if ! tc qdisc add dev lo ingress 2>/dev/null; then
        qos_log "WARN" "无法在 lo 上创建 ingress 队列，无法测试 connmark 支持"
        return 1
    fi
    if tc filter add dev lo parent ffff: protocol ip u32 match u32 0 0 action connmark 2>/dev/null; then
        tc filter del dev lo parent ffff: 2>/dev/null
        tc qdisc del dev lo ingress 2>/dev/null
        return 0
    else
        tc qdisc del dev lo ingress 2>/dev/null
        return 1
    fi
}

# 检查必需的命令是否存在
check_required_commands() {
    local missing=0
    for cmd in tc nft conntrack ethtool ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            qos_log "ERROR" "命令 '$cmd' 未找到，请安装相应软件包"
            missing=1
        fi
    done
    return $missing
}

# 检查并加载必需的内核模块
load_required_modules() {
    local missing=0
    for mod in ifb sch_hfsc sch_cake; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            qos_log "INFO" "尝试加载内核模块: $mod"
            modprobe "$mod" 2>/dev/null || {
                qos_log "ERROR" "无法加载内核模块 $mod"
                missing=1
            }
        fi
    done
    return $missing
}

# 检查IFB设备是否存在并启用（不创建）
ensure_ifb_device() {
    local dev="$1"
    if ! ip link show "$dev" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $dev 不存在，请检查配置或启动IFB管理脚本"
        return 1
    fi
    ip link set dev "$dev" up || {
        qos_log "ERROR" "无法启动IFB设备 $dev"
        return 1
    }
    qos_log "INFO" "IFB设备 $dev 已就绪"
    return 0
}

# ========== 并发安全锁机制（增强属主检查）==========
acquire_lock() {
    local lock_file="$LOCK_FILE"
    local timeout=10
    local count=0
    
    while [ $count -lt $timeout ]; do
        if [ -f "$lock_file" ]; then
            local pid=$(cat "$lock_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                sleep 1
                count=$((count + 1))
                continue
            else
                rm -f "$lock_file" 2>/dev/null
            fi
        fi
        
        if ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
            trap 'release_lock; exit 0' EXIT SIGINT SIGTERM SIGHUP
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    qos_log "ERROR" "无法获取锁 $lock_file，可能已有其他进程在运行"
    return 1
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || {
        qos_log "WARN" "锁文件删除失败，尝试强制删除"
        rm -rf "$LOCK_FILE" 2>/dev/null
    }
    qos_log "DEBUG" "锁已释放"
    return 0
}

# ========== 幂等性检查 ==========
check_already_running() {
    if [ -f "$RUNNING_FILE" ]; then
        local pid=$(cat "$RUNNING_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            qos_log "ERROR" "HFSC+CAKE QoS 已经在运行中 (PID: $pid)"
            return 1
        else
            qos_log "WARN" "发现残留的运行标记文件，清理中"
            rm -f "$RUNNING_FILE"
        fi
    fi
    echo "$$" > "$RUNNING_FILE"
    return 0
}

# ========== 配置加载函数 ==========
get_physical_interface_max_bandwidth() {
    local interface="$1"
    local max_bandwidth=""
    
    if command -v ethtool >/dev/null 2>&1; then
        local speed=$(ethtool "$interface" 2>/dev/null | grep -i speed | awk '{print $2}' | sed 's/[^0-9]//g')
        if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            max_bandwidth=$((speed * 1000))
            qos_log "INFO" "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
        fi
    fi
    
    if [ -z "$max_bandwidth" ] && [ -d "/sys/class/net/$interface" ]; then
        local speed_file="/sys/class/net/$interface/speed"
        if [ -f "$speed_file" ]; then
            local speed=$(cat "$speed_file" 2>/dev/null)
            if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
                max_bandwidth=$((speed * 1000))
                qos_log "INFO" "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
            fi
        fi
    fi
    
    if [ -z "$max_bandwidth" ]; then
        max_bandwidth="$MAX_PHYSICAL_BANDWIDTH"
        qos_log "WARN" "无法获取接口 $interface 的物理速度，使用默认最大值 ${max_bandwidth}kbit"
        qos_log "WARN" "建议在配置文件中手动设置总带宽以确保QoS效果"
    fi
    
    echo "$max_bandwidth"
}

load_bandwidth_from_config() {
    qos_log "INFO" "加载带宽配置"
    
    local max_physical_bw=$(get_physical_interface_max_bandwidth "$qos_interface")
    
    local config_upload_bw=$(uci -q get qos_gargoyle.upload.total_bandwidth 2>/dev/null)
    if [ -z "$config_upload_bw" ]; then
        qos_log "ERROR" "上传总带宽未配置，请检查UCI"
        return 1
    fi
    # 转换带宽为 kbit
    total_upload_bandwidth=$(convert_bandwidth_to_kbit "$config_upload_bw") || return 1
    if ! validate_number "$total_upload_bandwidth" "upload.total_bandwidth" 1 "$max_physical_bw"; then
        return 1
    fi
    qos_log "INFO" "上传总带宽: ${total_upload_bandwidth}kbit/s"

    local config_download_bw=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    if [ -z "$config_download_bw" ]; then
        qos_log "ERROR" "下载总带宽未配置，请检查UCI"
        return 1
    fi
    total_download_bandwidth=$(convert_bandwidth_to_kbit "$config_download_bw") || return 1
    if ! validate_number "$total_download_bandwidth" "download.total_bandwidth" 1 "$max_physical_bw"; then
        return 1
    fi
    qos_log "INFO" "下载总带宽: ${total_download_bandwidth}kbit/s"
    
    return 0
}

# 计算内存限制 - 使用向上取整避免除法结果为0（用于CAKE的memlimit）
calculate_memory_limit() {
    local config_value="$1"
    local result

    if [ -z "$config_value" ]; then
        echo ""
        return
    fi
    
    if [ "$config_value" = "auto" ]; then
        local total_mem_mb=0
        
        if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [ -n "$total_mem_bytes" ] && [ "$total_mem_bytes" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                qos_log "INFO" "从cgroups获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        
        if [ -z "$total_mem_mb" ] || [ "$total_mem_mb" -eq 0 ]; then
            local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [ -n "$total_mem_kb" ] && [ "$total_mem_kb" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_kb / 1024 ))
                qos_log "INFO" "从/proc/meminfo获取内存: ${total_mem_mb}MB"
            fi
        fi
        
        if [ -n "$total_mem_mb" ] && [ "$total_mem_mb" -gt 0 ] 2>/dev/null; then
            # 每256MB内存分配1MB给CAKE，向上取整确保至少1MB基数
            # 对于128GB（131072MB）内存，计算值为 (131072+255)/256 ≈ 513，安全在32位有符号范围内
            result="$(( (total_mem_mb + 255) / 256 ))Mb"
            
            local min_limit=4
            local max_limit=32
            local result_value=$(echo "$result" | sed 's/Mb//')
            if [ "$result_value" -lt "$min_limit" ] 2>/dev/null; then
                result="${min_limit}Mb"
            elif [ "$result_value" -gt "$max_limit" ] 2>/dev/null; then
                result="${max_limit}Mb"
            fi
            
            qos_log "INFO" "系统内存 ${total_mem_mb}MB，自动计算 memlimit=${result}"
        else
            qos_log "WARN" "无法读取内存信息，使用默认值 16Mb"
            result="16Mb"
        fi
    else
        # 用户自定义值，验证格式（必须为数字+Mb，例如 16Mb）
        if echo "$config_value" | grep -qE '^[0-9]+Mb$'; then
            result="$config_value"
            qos_log "INFO" "使用用户配置的 memlimit: ${result}"
        else
            qos_log "WARN" "无效的 memlimit 格式 '$config_value'，使用默认值 16Mb"
            result="16Mb"
        fi
    fi
    
    echo "$result"
}

# 加载HFSC与CAKE专属配置
load_hfsc_cake_config() {
    qos_log "INFO" "加载HFSC与CAKE配置"
    
    # 加载带宽配置
    if ! load_bandwidth_from_config; then
        echo "带宽配置加载失败" >&2
        return 1
    fi
    
    # 从UCI配置读取IFB设备（通过LuCI选择）
    IFB_DEVICE=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    if [ -z "$IFB_DEVICE" ]; then
        IFB_DEVICE="ifb0"
        qos_log "WARN" "IFB设备未配置，使用默认值: $IFB_DEVICE"
    else
        qos_log "INFO" "从配置文件读取IFB设备: $IFB_DEVICE"
    fi
    
    # 从UCI配置读取HFSC特定参数
    HFSC_LATENCY_MODE=$(uci -q get qos_gargoyle.hfsc.latency_mode 2>/dev/null)
    if [ -z "$HFSC_LATENCY_MODE" ]; then
        qos_log "WARN" "HFSC延迟模式未配置，将使用默认行为"
    else
        qos_log "INFO" "HFSC延迟模式: ${HFSC_LATENCY_MODE}"
    fi
    
    HFSC_MINRTT_ENABLED=$(uci -q get qos_gargoyle.hfsc.minrtt_enabled 2>/dev/null)
    if [ -z "$HFSC_MINRTT_ENABLED" ]; then
        HFSC_MINRTT_ENABLED=0
        qos_log "INFO" "HFSC最小RTT未配置，使用默认值: ${HFSC_MINRTT_ENABLED}"
    else
        qos_log "INFO" "HFSC最小RTT启用: ${HFSC_MINRTT_ENABLED}"
    fi
	
	# 读取minrtt_delay
    HFSC_MINRTT_DELAY=$(uci -q get qos_gargoyle.hfsc.minrtt_delay 2>/dev/null)
    # 如果未设置，则使用默认值 1000us
    if [ -z "$HFSC_MINRTT_DELAY" ]; then
        HFSC_MINRTT_DELAY=1000us
        qos_log "INFO" "HFSC最小RTT延迟未配置，使用默认值: ${HFSC_MINRTT_DELAY}"
    else
        qos_log "INFO" "HFSC最小RTT延迟已配置: ${HFSC_MINRTT_DELAY}"
    fi
    
    # 从UCI配置读取CAKE参数
    CAKE_BANDWIDTH=$(uci -q get qos_gargoyle.cake.bandwidth 2>/dev/null)   # 可选，HFSC场景下通常不应设置
    if [ -n "$CAKE_BANDWIDTH" ]; then
        qos_log "ERROR" "检测到 CAKE_BANDWIDTH 已配置 (值: $CAKE_BANDWIDTH)，这将导致CAKE二次整形，可能严重影响HFSC调度性能。建议删除此配置项以使用HFSC主导的整形。"
    fi
    CAKE_RTT=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null)
    CAKE_FLOWMODE=$(uci -q get qos_gargoyle.cake.flowmode 2>/dev/null)
    [ -z "$CAKE_FLOWMODE" ] && CAKE_FLOWMODE="srchost"
    
    CAKE_DIFFSERV=$(uci -q get qos_gargoyle.cake.diffserv_mode 2>/dev/null)
    [ -z "$CAKE_DIFFSERV" ] && CAKE_DIFFSERV="diffserv4"
    
    CAKE_NAT=$(uci -q get qos_gargoyle.cake.nat 2>/dev/null)
    [ -z "$CAKE_NAT" ] && CAKE_NAT="1"
    
    CAKE_WASH=$(uci -q get qos_gargoyle.cake.wash 2>/dev/null)
    [ -z "$CAKE_WASH" ] && CAKE_WASH="1"
    
    CAKE_OVERHEAD=$(uci -q get qos_gargoyle.cake.overhead 2>/dev/null)
    CAKE_MPU=$(uci -q get qos_gargoyle.cake.mpu 2>/dev/null)
    
    CAKE_ACK_FILTER=$(uci -q get qos_gargoyle.cake.ack_filter 2>/dev/null)
    [ -z "$CAKE_ACK_FILTER" ] && CAKE_ACK_FILTER="0"
    
    CAKE_SPLIT_GSO=$(uci -q get qos_gargoyle.cake.split_gso 2>/dev/null)
    [ -z "$CAKE_SPLIT_GSO" ] && CAKE_SPLIT_GSO="0"
    
    CAKE_LIMIT=$(uci -q get qos_gargoyle.cake.limit 2>/dev/null)
    if [ -n "$CAKE_LIMIT" ] && ! validate_number "$CAKE_LIMIT" "cake.limit" 1 65535; then
        CAKE_LIMIT=""
    fi
    
    CAKE_MEMLIMIT=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null)
    if [ -n "$CAKE_MEMLIMIT" ]; then
        CAKE_MEMLIMIT=$(calculate_memory_limit "$CAKE_MEMLIMIT")
    fi
    
    CAKE_ECN=$(uci -q get qos_gargoyle.cake.ecn 2>/dev/null)
    if [ -n "$CAKE_ECN" ]; then
        case "$CAKE_ECN" in
            yes|1|enable|on|true|ecn)
                CAKE_ECN="ecn"
                qos_log "INFO" "CAKE ECN 已启用"
                ;;
            no|0|disable|off|false|noecn)
                CAKE_ECN="noecn"   # 必须显式传递 noecn
                qos_log "INFO" "CAKE ECN 已禁用"
                ;;
            *)
                qos_log "WARN" "无效的 ECN 配置值 '$CAKE_ECN'，将禁用 ECN"
                CAKE_ECN=""
                ;;
        esac
    else
        CAKE_ECN=""   # 未配置时默认禁用，不传递参数
        qos_log "INFO" "CAKE ECN 未配置，使用默认禁用"
    fi
    
    qos_log "INFO" "HFSC配置: latency_mode=${HFSC_LATENCY_MODE}, minrtt_enabled=${HFSC_MINRTT_ENABLED}, minrtt_delay=${HFSC_MINRTT_DELAY}"
    qos_log "INFO" "CAKE参数: bandwidth=${CAKE_BANDWIDTH:-未配置}, rtt=${CAKE_RTT:-未配置}, flowmode=${CAKE_FLOWMODE}, diffserv=${CAKE_DIFFSERV}, nat=${CAKE_NAT}, wash=${CAKE_WASH}, overhead=${CAKE_OVERHEAD:-未配置}, mpu=${CAKE_MPU:-未配置}, ack_filter=${CAKE_ACK_FILTER}, split_gso=${CAKE_SPLIT_GSO}, limit=${CAKE_LIMIT:-未配置}, memlimit=${CAKE_MEMLIMIT:-未配置}, ecn=${CAKE_ECN}"
    
    return 0
}

# 加载HFSC类别配置
load_hfsc_class_config() {
    local class_name="$1"
    local percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name
    
    qos_log "INFO" "加载HFSC类别配置: $class_name"
    
    percent_bandwidth=$(uci -q get qos_gargoyle.$class_name.percent_bandwidth 2>/dev/null)
    per_min_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_min_bandwidth 2>/dev/null)
    per_max_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_max_bandwidth 2>/dev/null)
    minRTT=$(uci -q get qos_gargoyle.$class_name.minRTT 2>/dev/null)
    priority=$(uci -q get qos_gargoyle.$class_name.priority 2>/dev/null)
    name=$(uci -q get qos_gargoyle.$class_name.name 2>/dev/null)
    
    if [ -n "$percent_bandwidth" ] && ! validate_number "$percent_bandwidth" "$class_name.percent_bandwidth" 0 100; then
        percent_bandwidth=""
    fi
    if [ -n "$per_min_bandwidth" ] && ! validate_number "$per_min_bandwidth" "$class_name.per_min_bandwidth" 0 100; then
        per_min_bandwidth=""
    fi
    if [ -n "$per_max_bandwidth" ] && ! validate_number "$per_max_bandwidth" "$class_name.per_max_bandwidth" 0 1000; then  #允许借用
        per_max_bandwidth=""
    fi
	# 允许优先级0（最高）
    if [ -n "$priority" ] && ! validate_number "$priority" "$class_name.priority" 0 255; then
        priority=""
    fi
    
    qos_log "DEBUG" "HFSC配置: $class_name -> percent=$percent_bandwidth, min=$per_min_bandwidth, max=$per_max_bandwidth, minRTT=$minRTT"
    
    if [ -z "$percent_bandwidth" ] && [ -z "$per_min_bandwidth" ] && [ -z "$per_max_bandwidth" ]; then
        qos_log "WARN" "未找到 $class_name 的带宽参数"
        return 1
    fi
    
    echo "percent_bandwidth='$percent_bandwidth' per_min_bandwidth='$per_min_bandwidth' per_max_bandwidth='$per_max_bandwidth' minRTT='$minRTT' priority='$priority' name='$name'"
    return 0
}

load_upload_class_configurations() {
    qos_log "INFO" "正在加载上传类别配置..."
    upload_class_list=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    if [ -n "$upload_class_list" ]; then
        qos_log "INFO" "找到上传类别: $upload_class_list"
    else
        qos_log "WARN" "没有找到上传类别配置"
        upload_class_list=""
    fi
    return 0
}

load_download_class_configurations() {
    qos_log "INFO" "正在加载下载类别配置..."
    download_class_list=$(load_all_config_sections "$CONFIG_FILE" "download_class")
    if [ -n "$download_class_list" ]; then
        qos_log "INFO" "找到下载类别: $download_class_list"
    else
        qos_log "WARN" "没有找到下载类别配置"
        download_class_list=""
    fi
    return 0
}

# ========== IPv6增强支持 ==========
setup_ipv6_specific_rules() {
    qos_log "INFO" "设置IPv6特定规则（优化版）"
    
    # 确保表存在
    nft add table inet gargoyle-qos-priority 2>/dev/null || true
    
    nft add chain inet gargoyle-qos-priority filter_prerouting '{ type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority filter_prerouting 2>/dev/null || true
    
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3 } \
        meta mark set 0x3F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ::1 \
        meta mark set 0x3F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } \
        meta mark set 0x7F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } \
        meta mark set 0x7F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 53 \
        meta mark set 0x7F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport 53 \
        meta mark set 0x7F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport { 80, 443 } \
        meta mark set 0x7F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 123 \
        meta mark set 0x7F counter 2>/dev/null || true
    
    qos_log "INFO" "IPv6关键流量规则设置完成"
}

# ========== 增强规则链 ==========
setup_hfsc_enhance_chains() {
    qos_log "INFO" "设置HFSC增强规则链"
    nft add chain inet gargoyle-qos-priority filter_qos_egress_enhance 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority filter_qos_ingress_enhance 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_qos_egress \
        jump filter_qos_egress_enhance 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_qos_ingress \
        jump filter_qos_ingress_enhance 2>/dev/null || true
}

# ========== HFSC核心队列函数（使用CAKE） ==========
create_hfsc_root_qdisc() {
    local device="$1"
    local direction="$2"
    local root_handle="$3"
    local root_classid="$4"
    local bandwidth=""
    
    if [ "$direction" = "upload" ]; then
        bandwidth="$total_upload_bandwidth"
    elif [ "$direction" = "download" ]; then
        bandwidth="$total_download_bandwidth"
    else
        qos_log "ERROR" "未知方向: $direction"
        return 1
    fi
    
    # 验证带宽值
    if ! validate_number "$bandwidth" "bandwidth" 1 "$MAX_PHYSICAL_BANDWIDTH"; then
        qos_log "ERROR" "无效的带宽值: $bandwidth"
        return 1
    fi
    
    qos_log "INFO" "为$device创建$direction方向HFSC根队列 (带宽: ${bandwidth}kbit)"
    
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    tc qdisc del dev "$device" root 2>/dev/null || true
    
    qos_log "INFO" "正在为 $device 创建 HFSC 根队列..."
    if ! tc qdisc add dev "$device" root handle $root_handle hfsc; then
        qos_log "ERROR" "无法在 $device 上创建HFSC根队列"
        return 1
    fi
    
    qos_log "INFO" "正在为 $device 创建 HFSC 根类..."
    if ! tc class add dev "$device" parent $root_handle classid $root_classid hfsc ls rate ${bandwidth}kbit ul rate ${bandwidth}kbit; then
        qos_log "ERROR" "无法在$device上创建HFSC根类"
        # 清理已创建的根队列
        tc qdisc del dev "$device" root 2>/dev/null
        return 1
    fi
    
    qos_log "INFO" "$device的$direction方向HFSC根队列创建完成"
    return 0
}

# 构建CAKE参数字符串
build_cake_params() {
    local params=""
    
    # 仅在用户显式配置了CAKE_BANDWIDTH时添加，HFSC场景下通常不应设置
    if [ -n "$CAKE_BANDWIDTH" ]; then
        params="$params bandwidth $CAKE_BANDWIDTH"
        qos_log "INFO" "用户显式配置了CAKE bandwidth: $CAKE_BANDWIDTH，CAKE将进行二次整形（可能影响HFSC调度）"
    fi
    
    [ -n "$CAKE_RTT" ] && params="$params rtt $CAKE_RTT"
    [ -n "$CAKE_FLOWMODE" ] && params="$params $CAKE_FLOWMODE"
    [ -n "$CAKE_DIFFSERV" ] && params="$params $CAKE_DIFFSERV"
    
    if [ "$CAKE_NAT" = "1" ] || [ "$CAKE_NAT" = "yes" ] || [ "$CAKE_NAT" = "true" ]; then
        params="$params nat"
    else
        params="$params nonat"
    fi
    
    if [ "$CAKE_WASH" = "1" ] || [ "$CAKE_WASH" = "yes" ] || [ "$CAKE_WASH" = "true" ]; then
        params="$params wash"
    else
        params="$params nowash"
    fi
    
    [ -n "$CAKE_OVERHEAD" ] && params="$params overhead $CAKE_OVERHEAD"
    [ -n "$CAKE_MPU" ] && params="$params mpu $CAKE_MPU"
    
    if [ "$CAKE_ACK_FILTER" = "1" ] || [ "$CAKE_ACK_FILTER" = "yes" ] || [ "$CAKE_ACK_FILTER" = "true" ]; then
        params="$params ack-filter"
    else
        params="$params noack-filter"
    fi
    
    if [ "$CAKE_SPLIT_GSO" = "1" ] || [ "$CAKE_SPLIT_GSO" = "yes" ] || [ "$CAKE_SPLIT_GSO" = "true" ]; then
        params="$params split-gso"
    else
        params="$params no-split-gso"
    fi
    
    [ -n "$CAKE_LIMIT" ] && params="$params limit $CAKE_LIMIT"
    [ -n "$CAKE_MEMLIMIT" ] && params="$params memlimit $CAKE_MEMLIMIT"
        
    if [ "$CAKE_ECN" = "ecn" ]; then
        params="$params ecn"
    fi
    
    echo "$params"
}

# 创建单个上传类
create_hfsc_upload_class() {
    local class_name="$1"
    local class_index="$2"
    
    qos_log "INFO" "创建上传类别: $class_name, ID: 1:$class_index"
    
    local class_config
    if ! class_config=$(load_hfsc_class_config "$class_name"); then
        qos_log "ERROR" "加载HFSC配置失败: $class_name"
        return 1
    fi
    local percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name
    eval "$class_config"
    
    local class_mark
    if ! class_mark=$(get_class_mark_for_rule "$class_name" "upload"); then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: $class_mark"
    
    local m1="0bit"
    local d="0us"
    local m2=""
    local ul_m2=""
    
    local class_total_bw=0
    if [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ] 2>/dev/null; then
            class_total_bw=$((total_upload_bandwidth * percent_bandwidth / 100))
            qos_log "INFO" "类别 $class_name 总带宽: ${class_total_bw}kbit (${percent_bandwidth}% of ${total_upload_bandwidth}kbit)"
        else
            qos_log "ERROR" "total_upload_bandwidth无效"
            return 1
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 percent_bandwidth"
        return 1
    fi
    
    if [ -n "$per_min_bandwidth" ] && [ "$per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$per_min_bandwidth" -eq 0 ]; then
            m2="1kbit"   # 设置为极小值避免 HFSC 报错
            qos_log "INFO" "类别 $class_name 不保证最小带宽 (per_min_bandwidth=0)"
        else
            m2="$((class_total_bw * per_min_bandwidth / 100))kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $m2 (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 per_min_bandwidth"
        return 1
    fi
    
    if [ -n "$per_max_bandwidth" ] && [ "$per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ul_m2="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ul_m2 (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ul_m2="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ul_m2"
    fi
    
    local m2_value=$(echo "$m2" | sed 's/kbit//')
    local ul_m2_value=$(echo "$ul_m2" | sed 's/kbit//')
    if [ "$m2_value" -gt "$ul_m2_value" ]; then
        qos_log "WARN" "类别 $class_name 保证带宽($m2)超过上限带宽($ul_m2)，调整为上限带宽"
        m2="$ul_m2"
    fi
    
    # 确定是否启用最小延迟
	local enable_minrtt=0
	if [ -n "$minRTT" ]; then
		# 类别已显式配置 minRTT
		case "$minRTT" in
			[Yy]es|[Yy]|1|[Tt]rue) enable_minrtt=1 ;;
			[Nn]o|[Nn]|0|[Ff]alse) enable_minrtt=0 ;;
			*) enable_minrtt="${HFSC_MINRTT_ENABLED:-0}" ;;  # 无效值时回退全局
		esac
	else
		# 类别未配置 minRTT，使用全局开关
		enable_minrtt="${HFSC_MINRTT_ENABLED:-0}"
	fi

	if [ "$enable_minrtt" = "1" ]; then
		d="${HFSC_MINRTT_DELAY:-1000us}"
		qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d, 来源: $([ -n "$minRTT" ] && echo "类别配置" || echo "全局开关"))"
	fi
    
    qos_log "INFO" "正在创建HFSC类别 1:$class_index (带宽: ls=$m2, ul=$ul_m2)"
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul rate $ul_m2; then
        qos_log "ERROR" "创建上传类别 1:$class_index 失败"
        return 1
    fi
    
    # 构建CAKE参数
    local cake_params=$(build_cake_params)
    qos_log "INFO" "添加上传CAKE队列参数: $cake_params"
    
    if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
        handle ${class_index}:1 cake $cake_params; then
        qos_log "ERROR" "添加上传CAKE队列失败"
        # 清理已创建的类
        tc class del dev "$qos_interface" classid 1:$class_index 2>/dev/null
        return 1
    fi
    
    if [ "$class_mark" != "0x0" ]; then
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle ${class_mark}/$UPLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加上传IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    
    if [ "$class_mark" != "0x0" ]; then
        local base_prio=100
        local ipv6_priority=$((base_prio + class_index))
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle ${class_mark}/$UPLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index, 优先级:$ipv6_priority)"
            # 可选：记录详细错误信息
            local err_msg=$(tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
                prio $ipv6_priority handle ${class_mark}/$UPLOAD_MASK fw classid 1:$class_index 2>&1)
            qos_log "DEBUG" "详细错误: $err_msg"
        else
            qos_log "INFO" "添加上传IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    
    qos_log "INFO" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

# 创建单个下载类（使用IFB设备）
create_hfsc_download_class() {
    local class_name="$1"
    local class_index="$2"
    local filter_prio="$3"
    
    local ifb_dev="$IFB_DEVICE"
    
    qos_log "INFO" "创建下载类别: $class_name, ID: 1:$class_index, 过滤器优先级: $filter_prio"
    
    # 确保IFB设备已存在并启用
    if ! ip link show dev "$ifb_dev" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $ifb_dev 不存在，无法创建下载类"
        return 1
    fi
    
    local class_config
    if ! class_config=$(load_hfsc_class_config "$class_name"); then
        qos_log "ERROR" "加载HFSC配置失败: $class_name"
        return 1
    fi
    local percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name
    eval "$class_config"
    
    local class_mark
    if ! class_mark=$(get_class_mark_for_rule "$class_name" "download"); then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: $class_mark"
    
    local m1="0bit"
    local d="0us"
    local m2=""
    local ul_m2=""
    
    local class_total_bw=0
    if [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
            class_total_bw=$((total_download_bandwidth * percent_bandwidth / 100))
            qos_log "INFO" "类别 $class_name 总带宽: ${class_total_bw}kbit (${percent_bandwidth}% of ${total_download_bandwidth}kbit)"
        else
            qos_log "ERROR" "total_download_bandwidth无效"
            return 1
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 percent_bandwidth"
        return 1
    fi
    
    if [ -n "$per_min_bandwidth" ] && [ "$per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$per_min_bandwidth" -eq 0 ]; then
            m2="1kbit"   # 设置为极小值避免 HFSC 报错
            qos_log "INFO" "类别 $class_name 不保证最小带宽 (per_min_bandwidth=0)"
        else
            m2="$((class_total_bw * per_min_bandwidth / 100))kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $m2 (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 per_min_bandwidth"
        return 1
    fi
    
    if [ -n "$per_max_bandwidth" ] && [ "$per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ul_m2="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ul_m2 (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ul_m2="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ul_m2"
    fi
    
    local m2_value=$(echo "$m2" | sed 's/kbit//')
    local ul_m2_value=$(echo "$ul_m2" | sed 's/kbit//')
    if [ "$m2_value" -gt "$ul_m2_value" ]; then
        qos_log "WARN" "类别 $class_name 保证带宽($m2)超过上限带宽($ul_m2)，调整为上限带宽"
        m2="$ul_m2"
    fi
    
    # 确定是否启用最小延迟
	local enable_minrtt=0
	if [ -n "$minRTT" ]; then
		# 类别已显式配置 minRTT
		case "$minRTT" in
			[Yy]es|[Yy]|1|[Tt]rue) enable_minrtt=1 ;;
			[Nn]o|[Nn]|0|[Ff]alse) enable_minrtt=0 ;;
			*) enable_minrtt="${HFSC_MINRTT_ENABLED:-0}" ;;  # 无效值时回退全局
		esac
	else
		# 类别未配置 minRTT，使用全局开关
		enable_minrtt="${HFSC_MINRTT_ENABLED:-0}"
	fi

	if [ "$enable_minrtt" = "1" ]; then
		d="${HFSC_MINRTT_DELAY:-1000us}"
		qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d, 来源: $([ -n "$minRTT" ] && echo "类别配置" || echo "全局开关"))"
	fi
    
    qos_log "INFO" "正在创建下载HFSC类别 1:$class_index (带宽: ls=$m2, ul=$ul_m2)"
    if ! tc class add dev "$ifb_dev" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul rate $ul_m2; then
        qos_log "ERROR" "创建下载类别 1:$class_index 失败"
        return 1
    fi
    
    local cake_params=$(build_cake_params)
    qos_log "INFO" "添加下载CAKE队列参数: $cake_params"
    
    if ! tc qdisc add dev "$ifb_dev" parent 1:$class_index \
        handle ${class_index}:1 cake $cake_params; then
        qos_log "ERROR" "添加下载CAKE队列失败"
        # 清理已创建的类
        tc class del dev "$ifb_dev" classid 1:$class_index 2>/dev/null
        return 1
    fi
    
    if [ "$class_mark" != "0x0" ]; then
        if ! tc filter add dev "$ifb_dev" parent 1:0 protocol ip \
            prio $filter_prio handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$filter_prio)"
        fi
    fi
    
    if [ "$class_mark" != "0x0" ]; then
        local base_prio=100
        local ipv6_priority=$((base_prio + filter_prio))
        if ! tc filter add dev "$ifb_dev" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index, 优先级:$ipv6_priority)"
            local err_msg=$(tc filter add dev "$ifb_dev" parent 1:0 protocol ipv6 \
                prio $ipv6_priority handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>&1)
            qos_log "DEBUG" "详细错误: $err_msg"
        else
            qos_log "INFO" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    
    qos_log "INFO" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

# 创建默认上传类
create_default_upload_class() {
    qos_log "INFO" "创建默认上传类别"
    
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi
    
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:2 hfsc ls rate ${total_upload_bandwidth}kbit ul rate ${total_upload_bandwidth}kbit; then
        qos_log "ERROR" "创建上传类 1:2 失败"
        return 1
    fi
    
    local cake_params=$(build_cake_params)
    qos_log "INFO" "添加上传默认CAKE队列参数: $cake_params"
    
    if ! tc qdisc add dev "$qos_interface" parent 1:2 \
        handle 2:1 cake $cake_params; then
        qos_log "ERROR" "添加上传默认CAKE队列失败"
        return 1
    fi
    
    tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default 2 2>/dev/null || true
    
    local mark_hex="0x1"
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加上传默认IPv4过滤器失败"
    fi
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加上传默认IPv6过滤器失败"
    fi
    
    upload_class_mark_list="default_class:$mark_hex"
    qos_log "INFO" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

# 创建默认下载类
create_default_download_class() {
    qos_log "INFO" "创建默认下载类别"
    
    local ifb_dev="$IFB_DEVICE"
    
    if ! ip link set dev "$ifb_dev" up; then
        qos_log "ERROR" "无法启动IFB设备 $ifb_dev"
        return 1
    fi
    
    if ! create_hfsc_root_qdisc "$ifb_dev" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi
    
    if ! tc class add dev "$ifb_dev" parent 1:1 \
        classid 1:2 hfsc ls rate ${total_download_bandwidth}kbit ul rate ${total_download_bandwidth}kbit; then
        qos_log "ERROR" "创建下载类 1:2 失败"
        return 1
    fi
    
    local cake_params=$(build_cake_params)
    qos_log "INFO" "添加下载默认CAKE队列参数: $cake_params"
    
    if ! tc qdisc add dev "$ifb_dev" parent 1:2 \
        handle 2:1 cake $cake_params; then
        qos_log "ERROR" "添加下载默认CAKE队列失败"
        return 1
    fi
    
    tc qdisc change dev "$ifb_dev" root handle 1:0 hfsc default 2 2>/dev/null || true
    
    local mark_hex="0x100"
    if ! tc filter add dev "$ifb_dev" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加下载默认IPv4过滤器失败"
    fi
    if ! tc filter add dev "$ifb_dev" parent 1:0 protocol ipv6 \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加下载默认IPv6过滤器失败"
    fi
    
    if ! setup_ingress_redirect; then
        qos_log "ERROR" "设置入口重定向失败"
        return 1
    fi
    
    download_class_mark_list="default_class:$mark_hex"
    qos_log "INFO" "默认下载类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

# ========== 入口重定向（依赖conntrack恢复标记）==========
setup_ingress_redirect() {
    if [ -z "$qos_interface" ]; then
        qos_log "ERROR" "无法确定 WAN 接口"
        return 1
    fi
    
    # 检测 connmark 支持
    if ! check_tc_connmark_support; then
        qos_log "ERROR" "内核不支持 tc action connmark，无法实现下载方向QoS"
        return 1
    fi
    
    qos_log "INFO" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null || true
    
    # IPv4重定向（必须成功）
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
        qos_log "ERROR" "IPv4入口重定向规则添加失败"
        tc qdisc del dev "$qos_interface" ingress 2>/dev/null
        return 1
    else
        qos_log "INFO" "IPv4入口重定向规则添加成功"
    fi
    
    # ========== IPv6 重定向：三阶尝试 ==========
    local ipv6_success=false
    
    # 第一优先：flower 匹配全球单播地址 (2000::/3)
    if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        flower ip6_dst 2000::/3 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
        ipv6_success=true
        qos_log "INFO" "IPv6入口重定向规则（flower 匹配全球单播）添加成功"
    else
        qos_log "WARN" "flower 规则添加失败，尝试 u32 全球单播匹配"
        
        # 第二优先：u32 匹配全球单播地址 (2000::/3)
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            u32 match u32 0x20000000 0xe0000000 at 24 \
            action connmark \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            ipv6_success=true
            qos_log "INFO" "IPv6入口重定向规则（u32 全球单播）添加成功"
        else
            qos_log "WARN" "u32 全球单播规则添加失败，尝试无过滤规则"
            
            # 第三优先：无过滤的 u32 全匹配
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0 0 \
                action connmark \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                qos_log "INFO" "IPv6入口重定向规则（无过滤）添加成功"
            else
                qos_log "WARN" "IPv6入口重定向规则添加失败，IPv6流量将不会通过IFB"
            fi
        fi
    fi
    
    if [ "$ipv6_success" = "true" ]; then
        qos_log "INFO" "IPv6入口重定向规则添加成功"
    fi
    
    # 检查是否有规则指向 IFB 设备
    local ipv4_rule_count=$(tc filter show dev "$qos_interface" parent ffff: protocol ip 2>/dev/null | grep -c "mirred.*Redirect to device $IFB_DEVICE")
    local ipv6_rule_count=$(tc filter show dev "$qos_interface" parent ffff: protocol ipv6 2>/dev/null | grep -c "mirred.*Redirect to device $IFB_DEVICE")
    if [ "$ipv4_rule_count" -ge 1 ] && [ "$ipv6_rule_count" -ge 1 ]; then
        qos_log "INFO" "入口重定向已成功设置: IPv4和IPv6规则均生效"
    elif [ "$ipv4_rule_count" -ge 1 ]; then
        qos_log "WARN" "入口重定向仅IPv4生效，IPv6未生效"
    else
        qos_log "ERROR" "入口重定向规则均未生效"
        return 1
    fi
    
    return 0
}

check_ingress_redirect() {
    local iface="$1"
    local ifb_dev="$2"
    
    [ -z "$ifb_dev" ] && ifb_dev="$IFB_DEVICE"
    
    echo "检查入口重定向 (接口: $iface, IFB设备: $ifb_dev)"
    
    echo "  IPv4入口规则:"
    local ipv4_rules=$(tc filter show dev "$iface" parent ffff: protocol ip 2>/dev/null)
    if [ -n "$ipv4_rules" ]; then
        echo "$ipv4_rules" | sed 's/^/    /'
        if echo "$ipv4_rules" | grep -q "mirred.*Redirect to device $ifb_dev"; then
            echo "    ✓ IPv4 重定向到 $ifb_dev: 已生效"
        else
            echo "    ✗ IPv4 重定向: mirred动作未找到"
        fi
    else
        echo "    无IPv4入口规则"
    fi
    
    echo ""
    echo "  IPv6入口规则:"
    local ipv6_rules=$(tc filter show dev "$iface" parent ffff: protocol ipv6 2>/dev/null)
    if [ -n "$ipv6_rules" ]; then
        echo "$ipv6_rules" | sed 's/^/    /'
        if echo "$ipv6_rules" | grep -q "mirred.*Redirect to device $ifb_dev"; then
            echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效"
        else
            echo "    ✗ IPv6 重定向: mirred动作未找到"
        fi
    else
        echo "    无IPv6入口规则"
    fi
    
    return 0
}

# ========== 上传方向初始化 ==========
initialize_hfsc_upload() {
    qos_log "INFO" "初始化上传方向HFSC"
    
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        qos_log "WARN" "未找到上传类别配置，使用默认类别"
        if ! create_default_upload_class; then
            return 1
        fi
        return 0
    fi
    
    # 统计启用类数量（包括默认类？实际上默认类单独处理，但这里已有自定义类）
    local class_count=0
    for class in $upload_class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        [ "$enabled" = "1" ] || [ -z "$enabled" ] && class_count=$((class_count + 1))
    done
    
    if [ $class_count -gt 16 ]; then
        qos_log "ERROR" "上传方向启用类数量为 $class_count，超过16个，将导致标记冲突，启动中止！"
        return 1
    fi
    
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi
    
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        if create_hfsc_upload_class "$class_name" "$class_index"; then
            local class_mark_hex=$(get_class_mark_for_rule "$class_name" "upload")
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
        else
            qos_log "ERROR" "创建上传类别 $class_name 失败，停止初始化"
            # 清理已创建的根队列
            tc qdisc del dev "$qos_interface" root 2>/dev/null
            return 1
        fi
        class_index=$((class_index + 1))
    done
    
    set_default_upload_class
    
    qos_log "INFO" "上传方向HFSC初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========
initialize_hfsc_download() {
    qos_log "INFO" "初始化下载方向HFSC"
    
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        qos_log "WARN" "未找到下载类别配置，使用默认类别"
        if ! create_default_download_class; then
            return 1
        fi
        return 0
    fi
    
    # 统计启用类数量
    local class_count=0
    for class in $download_class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        [ "$enabled" = "1" ] || [ -z "$enabled" ] && class_count=$((class_count + 1))
    done
    
    if [ $class_count -gt 16 ]; then
        qos_log "ERROR" "下载方向启用类数量为 $class_count，超过16个，将导致标记冲突，启动中止！"
        return 1
    fi
    
    # 确保IFB设备已存在并启用
    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $IFB_DEVICE 不存在"
        return 1
    fi
    
    if ! ip link set dev "$IFB_DEVICE" up; then
        qos_log "ERROR" "无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    
    if ! create_hfsc_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi
    
    local class_index=2
    local filter_prio=3
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        if create_hfsc_download_class "$class_name" "$class_index" "$filter_prio"; then
            local class_mark_hex=$(get_class_mark_for_rule "$class_name" "download")
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
        else
            qos_log "ERROR" "创建下载类别 $class_name 失败，停止初始化"
            # 清理已创建的根队列
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
            return 1
        fi
        class_index=$((class_index + 1))
        filter_prio=$((filter_prio + 2))
    done
    
    set_default_download_class
    
    if ! setup_ingress_redirect; then
        qos_log "ERROR" "设置入口重定向失败"
        return 1
    fi
    
    qos_log "INFO" "下载方向HFSC初始化完成"
    return 0
}

set_default_upload_class() {
    qos_log "INFO" "设置上传默认类别"
    
    if ! tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "hfsc"; then
        qos_log "ERROR" "上传根队列不存在，无法设置默认类"
        return
    fi
    
    local default_class_name=$(uci -q get qos_gargoyle.upload.default_class 2>/dev/null)
    if [ -z "$default_class_name" ]; then
        qos_log "WARN" "上传默认类别未配置，将使用第一个类别"
        if [ -n "$upload_class_list" ]; then
            default_class_name=$(echo "$upload_class_list" | awk '{print $1}')
            qos_log "INFO" "自动选择第一个类别: $default_class_name"
        else
            tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default 2 2>/dev/null || true
            qos_log "INFO" "上传默认类别设置为TC类ID: 1:2"
            return
        fi
    fi
    
    qos_log "INFO" "用户配置的上传默认类别名称: $default_class_name"
    
    local class_index=2
    local found_index=2
    local found=0
    
    for class_name in $upload_class_list; do
        if [ "$class_name" = "$default_class_name" ]; then
            found_index=$class_index
            found=1
            qos_log "INFO" "找到上传默认类别 '$default_class_name' 在索引位置 $found_index"
            break
        fi
        class_index=$((class_index + 1))
    done
    
    if [ $found -eq 0 ]; then
        qos_log "WARN" "未找到上传默认类别 '$default_class_name'，使用第一个类别"
        local first_class=$(echo "$upload_class_list" | awk '{print $1}')
        if [ -n "$first_class" ]; then
            class_index=2
            found_index=2
            for cn in $upload_class_list; do
                if [ "$cn" = "$first_class" ]; then
                    found_index=$class_index
                    break
                fi
                class_index=$((class_index + 1))
            done
            qos_log "INFO" "回退使用类别 '$first_class' (ID: 1:$found_index)"
        else
            found_index=2
            qos_log "INFO" "无自定义类别，使用默认类ID 1:2"
        fi
    fi
    #hfsc qdisc 不支持 default 参数（htb 支持），导致未匹配任何规则的流量可能被丢弃。
    #tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default $found_index 2>/dev/null || true 
	#改为根 qdisc 上添加一条低优先级的全匹配规则，指向默认类
	tc filter add dev "$qos_interface" parent 1:0 protocol all prio 999 u32 match u32 0 0 flowid 1:$found_index
	
    qos_log "INFO" "上传默认类别设置为TC类ID: 1:$found_index"
}

set_default_download_class() {
    qos_log "INFO" "设置下载默认类别"
    
    if ! tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "hfsc"; then
        qos_log "ERROR" "下载根队列不存在，无法设置默认类"
        return
    fi
    
    local default_class_name=$(uci -q get qos_gargoyle.download.default_class 2>/dev/null)
    if [ -z "$default_class_name" ]; then
        qos_log "WARN" "下载默认类别未配置，将使用第一个类别"
        if [ -n "$download_class_list" ]; then
            default_class_name=$(echo "$download_class_list" | awk '{print $1}')
            qos_log "INFO" "自动选择第一个类别: $default_class_name"
        else
            tc qdisc change dev "$IFB_DEVICE" root handle 1:0 hfsc default 2 2>/dev/null || true
            qos_log "INFO" "下载默认类别设置为TC类ID: 1:2"
            return
        fi
    fi
    
    qos_log "INFO" "用户配置的下载默认类别名称: $default_class_name"
    
    local class_index=2
    local found_index=2
    local found=0
    
    for class_name in $download_class_list; do
        if [ "$class_name" = "$default_class_name" ]; then
            found_index=$class_index
            found=1
            qos_log "INFO" "找到下载默认类别 '$default_class_name' 在索引位置 $found_index"
            break
        fi
        class_index=$((class_index + 1))
    done
    
    if [ $found -eq 0 ]; then
        qos_log "WARN" "未找到下载默认类别 '$default_class_name'，使用第一个类别"
        local first_class=$(echo "$download_class_list" | awk '{print $1}')
        if [ -n "$first_class" ]; then
            class_index=2
            found_index=2
            for cn in $download_class_list; do
                if [ "$cn" = "$first_class" ]; then
                    found_index=$class_index
                    break
                fi
                class_index=$((class_index + 1))
            done
            qos_log "INFO" "回退使用类别 '$first_class' (ID: 1:$found_index)"
        else
            found_index=2
            qos_log "INFO" "无自定义类别，使用默认类ID 1:2"
        fi
    fi
    
	#hfsc qdisc 不支持 default 参数（htb 支持），导致未匹配任何规则的流量可能被丢弃。
    #tc qdisc change dev "$IFB_DEVICE" root handle 1:0 hfsc default $found_index 2>/dev/null || true 
	#改为根 qdisc 上添加一条低优先级的全匹配规则，指向默认类
	tc filter add dev "$IFB_DEVICE" parent 1:0 protocol all prio 999 u32 match u32 0 0 flowid 1:$found_index
	
    qos_log "INFO" "下载默认类别设置为TC类ID: 1:$found_index"
}

apply_hfsc_specific_rules() {
    qos_log "INFO" "应用HFSC特定增强规则（专用链）"
    
    nft flush chain inet gargoyle-qos-priority filter_qos_egress_enhance 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority filter_qos_ingress_enhance 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        ct state new \
        limit rate 100/second burst 20 packets \
        meta mark set 0x7F counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        ct state new \
        limit rate 100/second burst 20 packets \
        meta mark set 0x7F00 counter 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        meta mark and 0x007f != 0 counter meta priority set "bulk" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        meta mark and 0x7f00 != 0 counter meta priority set "bulk" 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        ct state established,related counter meta mark set ct mark 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        meta mark and 0x0010 != 0 counter meta priority set "critical" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        meta mark and 0x1000 != 0 counter meta priority set "critical" 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        ct bytes lt 200 counter meta priority set "normal" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        ct bytes lt 200 counter meta priority set "normal" 2>/dev/null || true
    
    qos_log "INFO" "HFSC特定增强规则应用完成"
}

# ========== 主初始化函数 ==========
initialize_hfsc_cake_qos() {
    qos_log "INFO" "开始初始化HFSC+CAKE QoS系统"
    
    # 获取并发锁
    if ! acquire_lock; then
        qos_log "ERROR" "无法获取并发锁，可能已有其他QoS进程在运行"
        rm -f "$RUNNING_FILE"
        return 1
    fi
    
    # 检查必需命令
    if ! check_required_commands; then
        qos_log "ERROR" "缺少必需的命令，请安装对应软件包"
        release_lock
        rm -f "$RUNNING_FILE"
        return 1
    fi
    
    # 检查并加载内核模块
    if ! load_required_modules; then
        qos_log "ERROR" "无法加载必需的内核模块"
        release_lock
        rm -f "$RUNNING_FILE"
        return 1
    fi
    
    # 幂等性检查
    if ! check_already_running; then
        qos_log "ERROR" "HFSC+CAKE QoS 已经在运行中"
        release_lock
        return 1
    fi
    
    # 确保 nftables 表存在
    nft add table inet gargoyle-qos-priority 2>/dev/null || true
    
    # 检查qos_interface是否已设置
    if [ -z "$qos_interface" ]; then
        qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
        if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        if [ -z "$qos_interface" ]; then
            qos_log "ERROR" "无法确定 WAN 接口，请检查配置"
            release_lock
            rm -f "$RUNNING_FILE"
            return 1
        fi
    fi
    
    qos_log "INFO" "使用WAN接口: $qos_interface"
    
    if ! load_hfsc_cake_config; then
        qos_log "ERROR" "加载HFSC+CAKE配置失败"
        release_lock
        rm -f "$RUNNING_FILE"
        return 1
    fi
    
    # 确保IFB设备存在（仅检查，不创建）——此时已从配置读取IFB_DEVICE
    if ! ensure_ifb_device "$IFB_DEVICE"; then
        qos_log "ERROR" "IFB设备 $IFB_DEVICE 无法使用，请检查配置或启动IFB管理脚本"
        release_lock
        rm -f "$RUNNING_FILE"
        return 1
    fi
    
    setup_ipv6_specific_rules
    
    local upload_success=0
    local download_success=0
    
    if [ "$total_upload_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_hfsc_upload; then
            qos_log "ERROR" "上传方向初始化失败"
            upload_success=1
        fi
    else
        qos_log "ERROR" "上传带宽未配置"
        upload_success=1
    fi
    
    if [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_hfsc_download; then
            qos_log "ERROR" "下载方向初始化失败"
            download_success=1
        fi
    else
        qos_log "ERROR" "下载带宽未配置"
        download_success=1
    fi
    
    if [ $upload_success -eq 1 ] || [ $download_success -eq 1 ]; then
        qos_log "ERROR" "HFSC+CAKE QoS 初始化部分失败"
        stop_hfsc_cake_qos
        release_lock
        rm -f "$RUNNING_FILE"
        return 1
    fi
    
    setup_hfsc_enhance_chains
    apply_hfsc_specific_rules
    
    qos_log "INFO" "HFSC+CAKE QoS初始化完成"
    release_lock
    return 0
}

# ========== 停止函数（改进锁处理，增加重试）==========
stop_hfsc_cake_qos() {
    qos_log "INFO" "停止HFSC+CAKE QoS"
    
    local got_lock=false
    local retry=3
    while [ $retry -gt 0 ]; do
        if acquire_lock 2>/dev/null; then
            got_lock=true
            qos_log "DEBUG" "停止时获取锁成功"
            break
        else
            retry=$((retry - 1))
            [ $retry -gt 0 ] && sleep 1
        fi
    done

    if ! $got_lock; then
        qos_log "ERROR" "无法获取锁，停止操作退出，请稍后重试"
        return 1
    fi

    # 删除运行标记
    rm -f "$RUNNING_FILE"
    
    local tc_count_before=$(tc qdisc show 2>/dev/null | grep -c hfsc || echo 0)
    local nft_count_before=$(nft list ruleset 2>/dev/null | grep -c "gargoyle-qos-priority" || echo 0)
    
    if [ "$tc_count_before" -gt 0 ]; then
        qos_log "INFO" "检测到 $tc_count_before 个HFSC队列，开始清理"
    fi
    if [ "$nft_count_before" -gt 0 ]; then
        qos_log "INFO" "检测到 $nft_count_before 个NFTables规则，开始清理"
    fi
    
    # 清理上传方向队列
    if [ -n "$qos_interface" ] && ip link show "$qos_interface" >/dev/null 2>&1; then
        tc filter del dev "$qos_interface" parent 1:0 protocol all 2>/dev/null || true
        tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
        tc qdisc del dev "$qos_interface" root 2>/dev/null || true
    fi
    
    # 清理下载方向队列
    if [ -n "$IFB_DEVICE" ] && ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        tc filter del dev "$IFB_DEVICE" parent 1:0 protocol all 2>/dev/null || true
        tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    fi
    
    # 彻底删除nftables表（更干净）
    nft delete table inet gargoyle-qos-priority 2>/dev/null || true
    
    # 处理IFB设备（仅当配置允许删除时）
    if [ -n "$IFB_DEVICE" ] && ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        if [ "${DELETE_IFB_ON_STOP:-0}" = "1" ]; then
            # 注意：这里不删除设备，因为可能被其他服务使用
            qos_log "INFO" "IFB设备 $IFB_DEVICE 已停用（保留）"
        else
            qos_log "INFO" "IFB设备 $IFB_DEVICE 已停用"
        fi
    fi
    
    # 清理连接标记（已不再需要，保留注释）
    # conntrack -U --mark 0 2>/dev/null || true
    
    local tc_count_after=$(tc qdisc show 2>/dev/null | grep -c hfsc || echo 0)
    local nft_count_after=$(nft list ruleset 2>/dev/null | grep -c "gargoyle-qos-priority" || echo 0)
    
    if [ "$tc_count_after" -gt 0 ]; then
        qos_log "WARN" "清理后仍有 $tc_count_after 个HFSC队列残留"
    fi
    if [ "$nft_count_after" -gt 0 ]; then
        qos_log "WARN" "清理后仍有 $nft_count_after 个NFTables规则残留"
    fi
    
    qos_log "INFO" "HFSC+CAKE QoS停止完成 (清理前: ${tc_count_before}队列/${nft_count_before}规则, 清理后: ${tc_count_after}队列/${nft_count_after}规则)"
    
    if $got_lock; then
        release_lock
    fi
}

# ========== 状态显示函数（增加 conntrack 命令检查）==========
show_hfsc_cake_status() {
    if [ -z "$IFB_DEVICE" ]; then
        IFB_DEVICE=$(uci -q get qos_gargoyle.download.ifb_device)
        [ -z "$IFB_DEVICE" ] && IFB_DEVICE="ifb0"
    fi
    local qos_ifb="$IFB_DEVICE"
    
    if [ -z "$qos_interface" ]; then
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "hfsc.*root" | awk '{print $5}' | head -1)
        [ -z "$qos_interface" ] && qos_interface="未知"
    fi
    
    echo "===== HFSC-CAKE QoS 状态报告 (v2.20) ====="
    echo "时间: $(date)"
    echo "WAN接口: ${qos_interface}"
    
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q hfsc; then
        echo "警告: QoS 未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    if [ -n "$qos_ifb" ] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "qdisc"; then
            echo "IFB设备: 已启动且运行中 ($qos_ifb)"
        else
            echo "IFB设备: 已创建但无 TC 队列 ($qos_ifb)"
        fi
    else
        echo "IFB设备: 未创建"
    fi
    
    echo -e "\n======== 出口QoS ($qos_interface) ========"
    
    echo -e "\nTC队列:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "hfsc\|cake"; then
            echo "  $line"
        fi
    done
    
    if tc class show dev "$qos_interface" >/dev/null 2>&1; then
        echo -e "\nTC类别:"
        tc -s class show dev "$qos_interface" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "hfsc"; then
                echo "  $line"
            fi
        done
    fi
    
    echo -e "\nTC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null | while read -r line; do
        echo "  $line"
    done
    
    echo -e "\n======== nftables 分类规则 ========"
    if nft list table inet gargoyle-qos-priority &>/dev/null; then
        nft list table inet gargoyle-qos-priority 2>/dev/null | sed 's/^/  /'
    else
        echo "  nftables 表不存在"
    fi
    
    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    
    if [ -n "$qos_ifb" ] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "hfsc\|cake"; then
                echo "  $line"
            fi
        done
        
        if tc class show dev "$qos_ifb" >/dev/null 2>&1; then
            echo -e "\nTC类别:"
            tc -s class show dev "$qos_ifb" 2>/dev/null | while read -r line; do
                if echo "$line" | grep -q "hfsc"; then
                    echo "  $line"
                fi
            done
        fi
        
        echo -e "\nTC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            echo "  $line"
        done
        
        echo -e "\n入口重定向检查:"
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            check_ingress_redirect "$qos_interface" "$qos_ifb"
        else
            echo "  ✗ 入口队列未配置"
        fi
    else
        echo "  IFB设备不存在，无入口配置"
    fi
    
    echo -e "\n===== QoS运行状态 ====="
    local upload_active=0
    local download_active=0
    
    tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "hfsc" && upload_active=1
    [ -n "$qos_ifb" ] && tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "hfsc" && download_active=1
    
    echo "上传QoS: $([ $upload_active -eq 1 ] && echo "已启用 (HFSC+cake)" || echo "未启用")"
    echo "下载QoS: $([ $download_active -eq 1 ] && echo "已启用 (HFSC+cake)" || echo "未启用")"
    
    if [ $upload_active -eq 1 ] && [ $download_active -eq 1 ]; then
        echo -e "\n✓ QoS双向流量整形已启用"
    elif [ $upload_active -eq 1 ] || [ $download_active -eq 1 ]; then
        echo -e "\n⚠ 部分方向QoS已启用"
    else
        echo -e "\n✗ QoS未运行"
    fi
    
    echo -e "\n===== 详细队列统计 ====="
    
    echo -e "\n上传方向cake队列:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null | grep -A 3 "cake" | while read -r line; do
        if echo "$line" | grep -q "parent"; then
            echo "  $line"
        elif echo "$line" | grep -q "Sent" || echo "$line" | grep -q "maxpacket" || \
             echo "$line" | grep -q "ecn_mark" || echo "$line" | grep -q "memory_used"; then
            echo "    $line"
        fi
    done
    
    if [ -n "$qos_ifb" ] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\n下载方向cake队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | grep -A 3 "cake" | while read -r line; do
            if echo "$line" | grep -q "parent"; then
                echo "  $line"
            elif echo "$line" | grep -q "Sent" || echo "$line" | grep -q "maxpacket" || \
                 echo "$line" | grep -q "ecn_mark" || echo "$line" | grep -q "memory_used"; then
                echo "    $line"
            fi
        done
    fi
    
    # ========== 活动连接标记 ==========
    echo -e "\n======== 活动连接标记 ========"

    # 检查 conntrack 命令是否存在
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "  conntrack 命令未安装，无法显示连接标记信息。"
        echo "  请安装 conntrack-tools 包以获取此功能。"
    else
        # 获取 WAN 接口的 IP 地址
        local wan_ipv4=""
        local wan_ipv6=""

        # IPv4 地址
        wan_ipv4=$(ip -4 addr show dev "$qos_interface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1)
        if [ -z "$wan_ipv4" ]; then
            wan_ipv4=$(ifconfig "$qos_interface" 2>/dev/null | grep "inet addr:" | awk '{print $2}' | cut -d: -f2)
        fi

        # IPv6 地址
        wan_ipv6=$(ip -6 addr show dev "$qos_interface" 2>/dev/null | grep "inet6 " | grep -v "fe80::" | awk '{print $2}' | cut -d/ -f1 | head -1)
        if [ -z "$wan_ipv6" ]; then
            wan_ipv6=$(ifconfig "$qos_interface" 2>/dev/null | grep "inet6 addr:" | grep -v "fe80::" | awk '{print $3}' | cut -d/ -f1)
        fi

        # IPv4 连接标记（目的地址为 WAN）
        echo -e "\nIPv4 连接标记 (目标地址为 WAN):"
        if [ -n "$wan_ipv4" ]; then
            echo "WAN IPv4: $wan_ipv4"
            local ipv4_marks=$(conntrack -L -d "$wan_ipv4" 2>/dev/null | grep -E "mark=[0-9]+" | head -n 5)
            if [ -n "$ipv4_marks" ]; then
                echo "$ipv4_marks" | while IFS= read -r line; do
                    local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
                    local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
                    local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
                    local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
                    local proto=$(echo "$line" | awk '{print $1}')
                    local dec_mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2 | head -1)
                    local mark_hex="0x$(printf '%x' "$dec_mark" 2>/dev/null || echo '0')"
                    
                    printf "  %-7s %-15s:%-5s → %-15s:%-5s [标记: %s]\n" \
                        "$proto" "${src_ip:-N/A}" "${sport:-N/A}" "${dst_ip:-N/A}" "${dport:-N/A}" "$mark_hex"
                done
            else
                echo "  未找到带标记的 IPv4 连接"
            fi
        else
            echo "  WAN IPv4 地址不可用"
        fi

        # IPv6 连接标记（目的地址为 WAN）
        echo -e "\nIPv6 连接标记 (目标地址为 WAN):"
        if [ -n "$wan_ipv6" ]; then
            echo "WAN IPv6: $wan_ipv6"
            local ipv6_marks=$(conntrack -L -d "$wan_ipv6" 2>/dev/null | grep -E "mark=[0-9]+" | head -n 5)
            if [ -n "$ipv6_marks" ]; then
                echo "$ipv6_marks" | while IFS= read -r line; do
                    local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
                    local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
                    local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
                    local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
                    local proto=$(echo "$line" | awk '{print $1}')
                    local dec_mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2 | head -1)
                    local mark_hex="0x$(printf '%x' "$dec_mark" 2>/dev/null || echo '0')"
                    
                    # 简化 IPv6 地址显示（压缩连续的零）
                    src_ip=$(echo "$src_ip" | sed 's/\(:\)[0:]*/\1/g')
                    dst_ip=$(echo "$dst_ip" | sed 's/\(:\)[0:]*/\1/g')
                    
                    printf "  %-7s %-30s:%-5s → %-30s:%-5s [标记: %s]\n" \
                        "$proto" "${src_ip:-N/A}" "${sport:-N/A}" "${dst_ip:-N/A}" "${dport:-N/A}" "$mark_hex"
                done
            else
                echo "  未找到带标记的 IPv6 连接"
            fi
        else
            echo "  WAN IPv6 地址不可用"
        fi

        # 上传方向连接标记（源地址为 WAN）
        echo -e "\n上传方向连接标记 (源地址为 WAN):"
        if [ -n "$wan_ipv4" ]; then
            local upload_marks=$(conntrack -L -s "$wan_ipv4" 2>/dev/null | grep -E "mark=[0-9]+" | head -n 3)
            if [ -n "$upload_marks" ]; then
                echo "$upload_marks" | while IFS= read -r line; do
                    local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
                    local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
                    local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
                    local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
                    local proto=$(echo "$line" | awk '{print $1}')
                    local dec_mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2 | head -1)
                    local mark_hex="0x$(printf '%x' "$dec_mark" 2>/dev/null || echo '0')"
                    
                    printf "  %-7s %-15s:%-5s → %-15s:%-5s [标记: %s]\n" \
                        "$proto" "${src_ip:-N/A}" "${sport:-N/A}" "${dst_ip:-N/A}" "${dport:-N/A}" "$mark_hex"
                done
            else
                echo "  未找到带标记的上传方向连接"
            fi
        fi
    fi
    
    echo -e "\n===== 网络接口统计 ====="
    
    echo -e "\n接口流量统计:"
    echo "WAN接口 ($qos_interface):"
    ifconfig "$qos_interface" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    
    if [ -n "$qos_ifb" ] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($qos_ifb):"
        ifconfig "$qos_ifb" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    fi
    
    echo -e "\n===== HFSC-CAKE 状态报告结束 ====="
    
    return 0
}

# ========== 主入口 ==========
main_hfsc_cake_qos() {
    local action="$1"
    
    case "$action" in
        "start")
            if ! initialize_hfsc_cake_qos; then
                qos_log "ERROR" "HFSC+CAKE QoS启动失败"
                exit 1
            fi
            ;;
        "stop")
            stop_hfsc_cake_qos
            ;;
        "restart")
            stop_hfsc_cake_qos
            sleep 1
            if ! initialize_hfsc_cake_qos; then
                qos_log "ERROR" "HFSC+CAKE QoS重启失败"
                exit 1
            fi
            ;;
        "status")
            show_hfsc_cake_status
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status}"
            echo ""
            echo "命令:"
            echo "  start        启动HFSC+CAKE QoS"
            echo "  stop         停止HFSC+CAKE QoS"
            echo "  restart      重启HFSC+CAKE QoS"
            echo "  status       显示状态"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "hfsc_cake.sh" ] || [ "$(basename "$0")" = "hfsc-cake.sh" ]; then
    main_hfsc_cake_qos "$1"
fi