#!/bin/sh
# version=2.5
# HFSC_CAKE算法实现模块
# 基于HFSC与CAKE组合算法实现QoS流量控制。
# 必要工具：tc, nft, conntrack, ethtool, sysctl
# 内核模块：ifb, sch_hfsc, sch_cake

# ========== 全局配置常量 ==========
: ${CONFIG_FILE:=qos_gargoyle}
: ${LOCK_FILE:=/var/run/hfsc_cake.lock}      # 并发锁文件
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}       # 最大物理带宽10Gbps（单位kbit）
: ${HFSC_MINRTT_DELAY:=1000us}              # 最小RTT延迟默认值
: ${IFB_DEVICE:=ifb0}                       # 默认IFB设备
: ${UPLOAD_MASK:=0x007F}                     # 上传方向标记掩码
: ${DOWNLOAD_MASK:=0x7F00}                   # 下载方向标记掩码

# 全局变量声明
upload_class_list=""
download_class_list=""
upload_class_mark_list=""
download_class_mark_list=""
qos_interface=""

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

# ========== 并发安全锁机制（增强版） ==========
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
        qos_log "WARN" "无法获取接口 $interface 的物理速度，使用默认最大值: ${max_bandwidth}kbit"
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
    if ! validate_number "$config_upload_bw" "upload.total_bandwidth" 1 "$max_physical_bw"; then
        return 1
    fi
    total_upload_bandwidth="$config_upload_bw"
    qos_log "INFO" "从配置文件读取上传总带宽: ${total_upload_bandwidth}kbit/s"

    local config_download_bw=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    if [ -z "$config_download_bw" ]; then
        qos_log "ERROR" "下载总带宽未配置，请检查UCI"
        return 1
    fi
    if ! validate_number "$config_download_bw" "download.total_bandwidth" 1 "$max_physical_bw"; then
        return 1
    fi
    total_download_bandwidth="$config_download_bw"
    qos_log "INFO" "从配置文件读取下载总带宽: ${total_download_bandwidth}kbit/s"
    
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
            result="$(((total_mem_mb + 255) / 256))Mb"
            
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
    
    # 从UCI配置读取CAKE参数
    CAKE_BANDWIDTH=$(uci -q get qos_gargoyle.cake.bandwidth 2>/dev/null)
    CAKE_RTT=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null)
    CAKE_FLOWMODE=$(uci -q get qos_gargoyle.cake.flowmode 2>/dev/null)
    [ -z "$CAKE_FLOWMODE" ] && CAKE_FLOWMODE="srchost"
    
    CAKE_DIFFSERV=$(uci -q get qos_gargoyle.cake.diffserv 2>/dev/null)
    [ -z "$CAKE_DIFFSERV" ] && CAKE_DIFFSERV="diffserv3"
    
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
            yes|1|enable|on|true)
                CAKE_ECN="ecn"
                ;;
            no|0|disable|off|false)
                CAKE_ECN="noecn"
                ;;
            ecn|noecn)
                # keep as is
                ;;
            *)
                qos_log "WARN" "无效的ECN配置值 '$CAKE_ECN'，将使用noecn"
                CAKE_ECN="noecn"
                ;;
        esac
    else
        CAKE_ECN="noecn"
    fi
    
    qos_log "INFO" "HFSC配置: latency_mode=${HFSC_LATENCY_MODE}, minrtt_enabled=${HFSC_MINRTT_ENABLED}"
    qos_log "INFO" "CAKE参数: bandwidth=${CAKE_BANDWIDTH:-未配置}, rtt=${CAKE_RTT:-未配置}, flowmode=${CAKE_FLOWMODE}, diffserv=${CAKE_DIFFSERV}, nat=${CAKE_NAT}, wash=${CAKE_WASH}, overhead=${CAKE_OVERHEAD:-未配置}, mpu=${CAKE_MPU:-未配置}, ack_filter=${CAKE_ACK_FILTER}, split_gso=${CAKE_SPLIT_GSO}, limit=${CAKE_LIMIT:-未配置}, memlimit=${CAKE_MEMLIMIT:-未配置}, ecn=${CAKE_ECN}"
    
    return 0
}

# 加载HFSC类别配置（同原脚本，但可用于CAKE）
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
    if [ -n "$per_max_bandwidth" ] && ! validate_number "$per_max_bandwidth" "$class_name.per_max_bandwidth" 0 100; then
        per_max_bandwidth=""
    fi
    if [ -n "$priority" ] && ! validate_number "$priority" "$class_name.priority" 1 255; then
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
        return 1
    fi
    
    qos_log "INFO" "$device的$direction方向HFSC根队列创建完成"
    return 0
}

# 构建CAKE参数字符串
build_cake_params() {
    local params=""
    
    if [ -n "$CAKE_BANDWIDTH" ]; then
        params="$params bandwidth $CAKE_BANDWIDTH"
    else
        qos_log "WARN" "CAKE bandwidth 未配置，CAKE 将使用接口速率，可能影响 HFSC 调度"
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
    [ -n "$CAKE_ECN" ] && params="$params $CAKE_ECN"
    
    echo "$params"
}

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
            m2="0kbit"
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
    
    # 改进的 minRTT 判断，支持不区分大小写及常见值
    case "${minRTT:-No}" in
        [Yy]es|[Yy]|1|[Tt]rue)
            d="$HFSC_MINRTT_DELAY"
            qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d)"
            ;;
    esac
    
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
            qos_log "WARN" "添加上传IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加上传IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    
    qos_log "INFO" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

create_hfsc_download_class() {
    local class_name="$1"
    local class_index="$2"
    local filter_prio="$3"
    
    local ifb_dev="$IFB_DEVICE"
    
    qos_log "INFO" "创建下载类别: $class_name, ID: 1:$class_index, 过滤器优先级: $filter_prio"
    
    local retries=5
    while ! ip link show dev "$ifb_dev" >/dev/null 2>&1 && ((retries-- > 0)); do
        ip link add dev "$ifb_dev" type ifb
        sleep 1
    done
    if [ $retries -eq 0 ]; then
        qos_log "ERROR" "IFB设备创建失败"
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
            m2="0kbit"
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
    
    case "${minRTT:-No}" in
        [Yy]es|[Yy]|1|[Tt]rue)
            d="$HFSC_MINRTT_DELAY"
            qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d)"
            ;;
    esac
    
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
            qos_log "WARN" "添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    
    qos_log "INFO" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

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
        prio 2 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加上传默认IPv6过滤器失败"
    fi
    
    upload_class_mark_list="default_class:$mark_hex"
    qos_log "INFO" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

create_default_download_class() {
    qos_log "INFO" "创建默认下载类别"
    
    local ifb_dev="$IFB_DEVICE"
    
    local retries=5
    while ! ip link show dev "$ifb_dev" >/dev/null 2>&1 && ((retries-- > 0)); do
        ip link add dev "$ifb_dev" type ifb
        sleep 1
    done
    if [ $retries -eq 0 ]; then
        qos_log "ERROR" "IFB设备创建失败"
        return 1
    fi
    
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
        prio 2 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null; then
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

# ========== 入口重定向 ==========
setup_ingress_redirect() {
    if [ -z "$qos_interface" ]; then
        qos_log "ERROR" "无法确定 WAN 接口"
        return 1
    fi
    
    qos_log "INFO" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null || true
    
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
        qos_log "ERROR" "IPv4入口重定向规则添加失败"
        return 1
    else
        qos_log "INFO" "IPv4入口重定向规则添加成功"
    fi
    
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
        qos_log "ERROR" "IPv6入口重定向规则添加失败"
        return 1
    else
        qos_log "INFO" "IPv6入口重定向规则添加成功"
    fi
    
    local ingress_rules=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | wc -l)
    if [ "$ingress_rules" -ge 2 ]; then
        qos_log "INFO" "入口重定向已成功设置: $qos_interface -> $IFB_DEVICE ($ingress_rules 条规则)"
    else
        qos_log "WARN" "入口重定向规则数量不足 ($ingress_rules 条)"
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
    
    local retries=5
    while ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1 && ((retries-- > 0)); do
        ip link add dev "$IFB_DEVICE" type ifb
        sleep 1
    done
    if [ $retries -eq 0 ]; then
        qos_log "ERROR" "IFB设备创建失败"
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
    
    tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default $found_index 2>/dev/null || true
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
    
    tc qdisc change dev "$IFB_DEVICE" root handle 1:0 hfsc default $found_index 2>/dev/null || true
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
    
    # 移除直接操作系统 filter 表的规则，避免冲突
    # nft add rule inet filter input ct state new limit rate 100/second burst 20 accept 2>/dev/null || true
    
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

initialize_hfsc_cake_qos() {
    qos_log "INFO" "开始初始化HFSC+CAKE QoS系统"
    
    if ! acquire_lock; then
        qos_log "ERROR" "无法获取并发锁，可能已有其他QoS进程在运行"
        return 1
    fi
    
    if [ -z "$qos_interface" ]; then
        qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
        if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        if [ -z "$qos_interface" ]; then
            qos_log "ERROR" "无法确定 WAN 接口，请检查配置"
            release_lock
            return 1
        fi
    fi
    
    qos_log "INFO" "使用WAN接口: $qos_interface"
    
    if ! load_hfsc_cake_config; then
        qos_log "ERROR" "加载HFSC+CAKE配置失败"
        release_lock
        return 1
    fi
    
    setup_ipv6_specific_rules
    
    if [ "$total_upload_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_hfsc_upload; then
            qos_log "ERROR" "上传方向初始化失败"
            release_lock
            return 1
        fi
    else
        qos_log "ERROR" "上传带宽未配置"
        release_lock
        return 1
    fi
    
    if [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_hfsc_download; then
            qos_log "ERROR" "下载方向初始化失败"
            release_lock
            return 1
        fi
    else
        qos_log "ERROR" "下载带宽未配置"
        release_lock
        return 1
    fi
    
    setup_hfsc_enhance_chains
    apply_hfsc_specific_rules
    
    qos_log "INFO" "HFSC+CAKE QoS初始化完成"
    release_lock
    return 0
}

stop_hfsc_cake_qos() {
    qos_log "INFO" "停止HFSC+CAKE QoS"
    
    if ! acquire_lock; then
        qos_log "WARN" "无法获取并发锁，但将继续尝试停止QoS"
    fi
    
    local tc_count_before=$(tc qdisc show 2>/dev/null | grep -c hfsc || echo 0)
    local nft_count_before=$(nft list ruleset 2>/dev/null | grep -c "gargoyle-qos-priority" || echo 0)
    
    if [ "$tc_count_before" -gt 0 ]; then
        qos_log "INFO" "检测到 $tc_count_before 个HFSC队列，开始清理"
    fi
    if [ "$nft_count_before" -gt 0 ]; then
        qos_log "INFO" "检测到 $nft_count_before 个NFTables规则，开始清理"
    fi
    
    tc filter show dev "$qos_interface" 2>/dev/null | grep -q hfsc && {
        tc filter del dev "$qos_interface" parent 1:0 protocol all 2>/dev/null || true
    }
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    tc qdisc del dev "$qos_interface" root 2>/dev/null || true
    
    tc filter show dev "$IFB_DEVICE" 2>/dev/null | grep -q hfsc && {
        tc filter del dev "$IFB_DEVICE" parent 1:0 protocol all 2>/dev/null || true
    }
    tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
    tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    
    # 先删除跳转规则，再删除增强链
    nft delete rule inet gargoyle-qos-priority filter_qos_egress handle \
        $(nft -a list chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null | \
          grep "jump filter_qos_egress_enhance" | awk '{print $NF}' | head -1) 2>/dev/null || true
    nft delete rule inet gargoyle-qos-priority filter_qos_ingress handle \
        $(nft -a list chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null | \
          grep "jump filter_qos_ingress_enhance" | awk '{print $NF}' | head -1) 2>/dev/null || true
    
    nft delete chain inet gargoyle-qos-priority filter_qos_egress_enhance 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority filter_qos_ingress_enhance 2>/dev/null || true
    
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        qos_log "INFO" "停用IFB设备: $IFB_DEVICE"
    fi
    
    conntrack -U --mark 0 2>/dev/null || true
    
    local tc_count_after=$(tc qdisc show 2>/dev/null | grep -c hfsc || echo 0)
    local nft_count_after=$(nft list ruleset 2>/dev/null | grep -c "gargoyle-qos-priority" || echo 0)
    
    if [ "$tc_count_after" -gt 0 ]; then
        qos_log "WARN" "清理后仍有 $tc_count_after 个HFSC队列残留"
    fi
    if [ "$nft_count_after" -gt 0 ]; then
        qos_log "WARN" "清理后仍有 $nft_count_after 个NFTables规则残留"
    fi
    
    release_lock
    qos_log "INFO" "HFSC+CAKE QoS停止完成 (清理前: ${tc_count_before}队列/${nft_count_before}规则, 清理后: ${tc_count_after}队列/${nft_count_after}规则)"
}

show_hfsc_cake_status() {
    local qos_ifb="$IFB_DEVICE"
    
    if [ -z "$qos_interface" ]; then
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "hfsc.*root" | awk '{print $5}' | head -1)
        [ -z "$qos_interface" ] && qos_interface="未知"
    fi
    
    echo "===== HFSC-CAKE QoS 状态报告 ====="
    echo "时间: $(date)"
    echo "WAN接口: ${qos_interface}"
    
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q hfsc; then
        echo "警告: QoS 未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
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
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
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
    tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "hfsc" && download_active=1
    
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
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
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
    
    echo -e "\n===== 网络接口统计 ====="
    
    echo -e "\n接口流量统计:"
    echo "WAN接口 ($qos_interface):"
    ifconfig "$qos_interface" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($qos_ifb):"
        ifconfig "$qos_ifb" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    fi
    
    echo -e "\n===== HFSC-CAKE 状态报告结束 ====="
    
    return 0
}

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