#!/bin/sh
# HTB_FQCODEL算法实现模块
# 基于HTB与FQ_CODEL组合算法实现QoS流量控制。
# 必要工具：tc, nft, conntrack, ethtool, sysctl
# 内核模块：ifb, sch_htb, sch_fq_codel
# version=1.9.3 最终优化（确保rate≥1，恢复连接标记显示，添加IPv6链创建）

# ========== 全局配置常量 ==========
: ${CONFIG_FILE:=qos_gargoyle}
: ${LOCK_FILE:=/var/run/htb_qos.lock}      # 并发锁文件
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}       # 最大物理带宽10Gbps（单位kbit）
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

# ========== 并发安全锁机制 ==========
acquire_lock() {
    local lock_file="$LOCK_FILE"
    local timeout=10
    local count=0
    
    while [ $count -lt $timeout ]; do
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

# 释放锁（仅删除锁文件，不杀进程）
release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || {
        qos_log "WARN" "锁文件删除失败，尝试强制删除"
        rm -rf "$LOCK_FILE" 2>/dev/null
    }
    qos_log "DEBUG" "锁已释放"
    return 0
}

# ========== 配置加载函数 ==========
# 获取物理接口最大带宽
get_physical_interface_max_bandwidth() {
    local interface="$1"
    local max_bandwidth=""
    
    # 尝试从ethtool获取
    if command -v ethtool >/dev/null 2>&1; then
        local speed=$(ethtool "$interface" 2>/dev/null | grep -i speed | awk '{print $2}' | sed 's/[^0-9]//g')
        if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            # 转换为kbit（1Mbps = 1000kbit）
            max_bandwidth=$((speed * 1000))
            qos_log "INFO" "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
        fi
    fi
    
    # 尝试从sysfs获取
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
    
    # 如果无法获取物理速度，使用配置的最大值
    if [ -z "$max_bandwidth" ]; then
        max_bandwidth="$MAX_PHYSICAL_BANDWIDTH"
        qos_log "WARN" "无法获取接口 $interface 的物理速度，使用默认最大值: ${max_bandwidth}kbit"
    fi
    
    echo "$max_bandwidth"
}

# 验证带宽配置（使用rule.sh的validate_number）
validate_bandwidth_config() {
    local config_bw="$1"
    local param_name="$2"
    local max_physical_bw="$3"
    
    if [ -z "$config_bw" ]; then
        qos_log "ERROR" "$param_name 未配置"
        return 1
    fi
    
    # 使用validate_number验证是否为数字且在范围内
    if ! validate_number "$config_bw" "$param_name" 1 "$MAX_PHYSICAL_BANDWIDTH"; then
        return 1
    fi
    
    # 检查是否超过物理接口最大带宽
    if [ -n "$max_physical_bw" ] && [ "$config_bw" -gt "$max_physical_bw" ] 2>/dev/null; then
        qos_log "WARN" "$param_name 配置值(${config_bw}kbit)超过接口物理带宽(${max_physical_bw}kbit)，将使用物理带宽"
        config_bw="$max_physical_bw"
    fi
    
    echo "$config_bw"
    return 0
}

# 加载带宽配置
load_bandwidth_from_config() {
    qos_log "INFO" "加载带宽配置"
    
    # 获取物理接口最大带宽
    local max_physical_bw=$(get_physical_interface_max_bandwidth "$qos_interface")
    
    # 读取上传总带宽
    local config_upload_bw=$(uci -q get qos_gargoyle.upload.total_bandwidth 2>/dev/null)
    if ! validated_bw=$(validate_bandwidth_config "$config_upload_bw" "upload.total_bandwidth" "$max_physical_bw"); then
        qos_log "ERROR" "上传总带宽配置无效: $config_upload_bw"
        return 1
    fi
    total_upload_bandwidth="$validated_bw"
    qos_log "INFO" "从配置文件读取上传总带宽: ${total_upload_bandwidth}kbit/s"

    # 读取下载总带宽
    local config_download_bw=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    if ! validated_bw=$(validate_bandwidth_config "$config_download_bw" "download.total_bandwidth" "$max_physical_bw"); then
        qos_log "ERROR" "下载总带宽配置无效: $config_download_bw"
        return 1
    fi
    total_download_bandwidth="$validated_bw"
    qos_log "INFO" "从配置文件读取下载总带宽: ${total_download_bandwidth}kbit/s"
    
    return 0
}

# 计算内存限制 - 正确计算 memory_limit（单位Mb），并验证用户自定义值
calculate_memory_limit() {
    local config_value="$1"
    local result

    if [ -z "$config_value" ]; then
        echo ""
        return
    fi
    
    if [ "$config_value" = "auto" ]; then
        local total_mem_mb=0
        
        # 优先使用cgroups内存限制（容器环境）
        if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [ -n "$total_mem_bytes" ] && [ "$total_mem_bytes" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                qos_log "INFO" "从cgroups获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        
        # 如果cgroups不可用，从/proc/meminfo获取
        if [ -z "$total_mem_mb" ] || [ "$total_mem_mb" -eq 0 ]; then
            local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [ -n "$total_mem_kb" ] && [ "$total_mem_kb" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_kb / 1024 ))
                qos_log "INFO" "从/proc/meminfo获取内存: ${total_mem_mb}MB"
            fi
        fi
        
        if [ -n "$total_mem_mb" ] && [ "$total_mem_mb" -gt 0 ] 2>/dev/null; then
            # 每256MB内存分配1MB给FQCoDel
            result="$((total_mem_mb / 256))Mb"
            
            # 设置最小和最大限制
            local min_limit=4
            local max_limit=32
            
            local result_value=$(echo "$result" | sed 's/Mb//')
            if [ "$result_value" -lt "$min_limit" ] 2>/dev/null; then
                result="${min_limit}Mb"
            elif [ "$result_value" -gt "$max_limit" ] 2>/dev/null; then
                result="${max_limit}Mb"
            fi
            
            qos_log "INFO" "系统内存 ${total_mem_mb}MB，自动计算 memory_limit=${result}"
        else
            qos_log "WARN" "无法读取内存信息，使用默认值 16Mb"
            result="16Mb"
        fi
    else
        # 用户自定义值，验证格式（必须为数字+Mb，例如 16Mb）
        if echo "$config_value" | grep -qE '^[0-9]+Mb$'; then
            result="$config_value"
            qos_log "INFO" "使用用户配置的 memory_limit: ${result}"
        else
            qos_log "WARN" "无效的 memory_limit 格式 '$config_value'，使用默认值 16Mb"
            result="16Mb"
        fi
    fi
    
    echo "$result"
}

# 计算HTB的burst参数（简化公式）
calculate_htb_burst() {
    local rate="$1"  # 单位: kbit
    local ceil="$2"  # 单位: kbit
    local mtu="$3"   # MTU大小
    
    if [ -z "$mtu" ]; then
        mtu=1500
    fi
    
    # HTB burst计算公式: (rate * 1ms) 或至少3个MTU
    # 简化：rate * 1000 / 8 / 1000 = rate / 8
    local burst_kb=$((rate / 8))  # 转换为KB
    if [ "$burst_kb" -lt 1 ]; then
        burst_kb=1
    fi
    
    # 确保至少3个MTU
    local mtu_kb=$((mtu * 3 / 1024))
    if [ "$burst_kb" -lt "$mtu_kb" ]; then
        burst_kb="$mtu_kb"
    fi
    
    # 计算cburst（通常为burst的2倍）
    local cburst_kb=$((burst_kb * 2))
    
    echo "${burst_kb}kb ${cburst_kb}kb"
}

# 加载HTB与fq_codel专属配置
load_htb_config() {
    qos_log "INFO" "加载HTB与fq_codel配置"
    
    # 加载带宽配置
    if ! load_bandwidth_from_config; then
        echo "带宽配置加载失败" >&2
        return 1
    fi
    
    # 从UCI配置读取HTB特定参数
    HTB_R2Q=$(uci -q get qos_gargoyle.htb.r2q 2>/dev/null)
    if [ -z "$HTB_R2Q" ]; then
        HTB_R2Q=10
        qos_log "INFO" "HTB R2Q使用默认值: ${HTB_R2Q}"
    fi
    
    HTB_DRR_QUANTUM=$(uci -q get qos_gargoyle.htb.drr_quantum 2>/dev/null)
    if [ -z "$HTB_DRR_QUANTUM" ]; then
        HTB_DRR_QUANTUM="auto"
    fi
    
    # 从UCI配置读取fq_codel参数
    FQCODEL_LIMIT=$(uci -q get qos_gargoyle.fq_codel.limit 2>/dev/null)
    if [ -z "$FQCODEL_LIMIT" ]; then
        qos_log "ERROR" "fq_codel limit 未配置"
        return 1
    fi
    if ! validate_number "$FQCODEL_LIMIT" "fq_codel.limit" 1 65535; then
        return 1
    fi
    
    FQCODEL_INTERVAL=$(uci -q get qos_gargoyle.fq_codel.interval 2>/dev/null)
    if [ -z "$FQCODEL_INTERVAL" ]; then
        qos_log "ERROR" "fq_codel interval 未配置"
        return 1
    fi
    if ! validate_number "$FQCODEL_INTERVAL" "fq_codel.interval" 1 1000000; then
        return 1
    fi
      
    FQCODEL_TARGET=$(uci -q get qos_gargoyle.fq_codel.target 2>/dev/null)
    if [ -z "$FQCODEL_TARGET" ]; then
        qos_log "ERROR" "fq_codel target 未配置"
        return 1
    fi
    if ! validate_number "$FQCODEL_TARGET" "fq_codel.target" 1 1000000; then
        return 1
    fi
    
    FQCODEL_FLOWS=$(uci -q get qos_gargoyle.fq_codel.flows 2>/dev/null)
    if [ -z "$FQCODEL_FLOWS" ]; then
        qos_log "ERROR" "fq_codel flows 未配置"
        return 1
    fi
    if ! validate_number "$FQCODEL_FLOWS" "fq_codel.flows" 1 65535; then
        return 1
    fi
    
    FQCODEL_QUANTUM=$(uci -q get qos_gargoyle.fq_codel.quantum 2>/dev/null)
    if [ -z "$FQCODEL_QUANTUM" ]; then
        qos_log "ERROR" "fq_codel quantum 未配置"
        return 1
    fi
    if ! validate_number "$FQCODEL_QUANTUM" "fq_codel.quantum" 1 10000; then
        return 1
    fi
    
    # 读取 memory_limit 参数
    FQCODEL_MEMORY_LIMIT=$(uci -q get qos_gargoyle.fq_codel.memory_limit 2>/dev/null)
    if [ -n "$FQCODEL_MEMORY_LIMIT" ]; then
        FQCODEL_MEMORY_LIMIT=$(calculate_memory_limit "$FQCODEL_MEMORY_LIMIT")
    fi
    
    # 读取 ce_threshold 参数
    FQCODEL_CE_THRESHOLD=$(uci -q get qos_gargoyle.fq_codel.ce_threshold 2>/dev/null)
    if [ -n "$FQCODEL_CE_THRESHOLD" ]; then
        # 验证格式：支持 0, 纯数字（微秒）, 数字+us/ms
        if ! echo "$FQCODEL_CE_THRESHOLD" | grep -qiE '^0$|^[0-9]+(\.[0-9]+)?(us|ms)?$'; then
            qos_log "WARN" "无效的 ce_threshold 格式 '$FQCODEL_CE_THRESHOLD'，将忽略此设置"
            FQCODEL_CE_THRESHOLD=""
        fi
    fi
    
    # 读取ecn参数
    FQCODEL_ECN=$(uci -q get qos_gargoyle.fq_codel.ecn 2>/dev/null)
    if [ -n "$FQCODEL_ECN" ]; then
        case "$FQCODEL_ECN" in
            yes|1|enable|on|true)
                FQCODEL_ECN="ecn"
                qos_log "INFO" "fq_codel ECN: 启用"
                ;;
            no|0|disable|off|false)
                FQCODEL_ECN="noecn"
                qos_log "INFO" "fq_codel ECN: 禁用"
                ;;
            ecn|noecn)
                qos_log "INFO" "fq_codel ECN: 使用配置值 ($FQCODEL_ECN)"
                ;;
            *)
                qos_log "WARN" "无效的ECN配置值 '$FQCODEL_ECN'，将不使用ECN"
                FQCODEL_ECN=""
                ;;
        esac
    else
        FQCODEL_ECN=""
        qos_log "INFO" "fq_codel ECN: 未配置"
    fi
    
    qos_log "INFO" "HTB配置: R2Q=${HTB_R2Q}, DRR量子=${HTB_DRR_QUANTUM}"
    qos_log "INFO" "fq_codel参数: limit=${FQCODEL_LIMIT}, interval=${FQCODEL_INTERVAL}us, target=${FQCODEL_TARGET}us, flows=${FQCODEL_FLOWS}, quantum=${FQCODEL_QUANTUM}, memory_limit=${FQCODEL_MEMORY_LIMIT}, ce_threshold=${FQCODEL_CE_THRESHOLD}, ecn=${FQCODEL_ECN:-未配置}"
    
    return 0
}

# 加载HTB类别配置
load_htb_class_config() {
    local class_name="$1"
    local percent_bandwidth per_min_bandwidth per_max_bandwidth priority name
    
    qos_log "INFO" "加载HTB类别配置: $class_name"
    
    # 直接通过UCI读取HTB类别配置
    percent_bandwidth=$(uci -q get qos_gargoyle.$class_name.percent_bandwidth 2>/dev/null)
    per_min_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_min_bandwidth 2>/dev/null)
    per_max_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_max_bandwidth 2>/dev/null)
    priority=$(uci -q get qos_gargoyle.$class_name.priority 2>/dev/null)
    name=$(uci -q get qos_gargoyle.$class_name.name 2>/dev/null)
    
    # 验证百分比参数
    if [ -n "$percent_bandwidth" ] && ! validate_number "$percent_bandwidth" "$class_name.percent_bandwidth" 0 100; then
        percent_bandwidth=""
    fi
    
    if [ -n "$per_min_bandwidth" ] && ! validate_number "$per_min_bandwidth" "$class_name.per_min_bandwidth" 0 100; then
        per_min_bandwidth=""
    fi
    
    if [ -n "$per_max_bandwidth" ] && ! validate_number "$per_max_bandwidth" "$class_name.per_max_bandwidth" 0 100; then
        per_max_bandwidth=""
    fi
    
    # 验证priority（1-7）
    if [ -n "$priority" ] && ! validate_number "$priority" "$class_name.priority" 1 7; then
        priority=""
    fi
    
    # 调试日志
    qos_log "DEBUG" "HTB配置: $class_name -> percent=$percent_bandwidth, min=$per_min_bandwidth, max=$per_max_bandwidth, priority=$priority"
    
    # 验证是否加载了关键参数
    if [ -z "$percent_bandwidth" ] && [ -z "$per_min_bandwidth" ] && [ -z "$per_max_bandwidth" ]; then
        qos_log "WARN" "未找到 $class_name 的带宽参数"
        return 1
    fi
    
    # 输出变量值，供调用者使用eval捕获
    echo "percent_bandwidth='$percent_bandwidth' per_min_bandwidth='$per_min_bandwidth' per_max_bandwidth='$per_max_bandwidth' priority='$priority' name='$name'"
    return 0
}

# 加载上传类别配置
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

# 加载下载类别配置
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
    
    # 确保filter_prerouting链存在（注意花括号需引号）
    nft add chain inet gargoyle-qos-priority filter_prerouting '{ type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    
    # ICMPv6关键类型（邻居发现、路由通告等）
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    
    # 使用地址聚合
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3, ::1/128 } \
        meta mark set 0x3F counter 2>/dev/null || true
    
    # 使用nftables设置IPv6关键流量标记
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } \
        meta mark set 0x7F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6 ICMPv6关键类型规则添加成功"
    else
        qos_log "WARN" "IPv6 ICMPv6关键类型规则添加失败"
    fi
    
    # DHCPv6流量（UDP 546/547）
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } \
        meta mark set 0x7F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6 DHCPv6流量规则添加成功"
    else
        qos_log "WARN" "IPv6 DHCPv6流量规则添加失败"
    fi
    
    # 仅匹配LLMNR/MDNS等关键多播组
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3 } \
        meta mark set 0x3F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6多播流量规则添加成功"
    else
        qos_log "WARN" "IPv6多播流量规则添加失败"
    fi
    
    # DNS over IPv6 (TCP/UDP 53)
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 53 \
        meta mark set 0x7F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6 DNS (UDP)流量规则添加成功"
    else
        qos_log "WARN" "IPv6 DNS (UDP)流量规则添加失败"
    fi
    
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport 53 \
        meta mark set 0x7F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6 DNS (TCP)流量规则添加成功"
    else
        qos_log "WARN" "IPv6 DNS (TCP)流量规则添加失败"
    fi
    
    # HTTP/HTTPS over IPv6
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport { 80, 443 } \
        meta mark set 0x7F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6 HTTP/HTTPS流量规则添加成功"
    else
        qos_log "WARN" "IPv6 HTTP/HTTPS流量规则添加失败"
    fi
    
    # NTP over IPv6
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 123 \
        meta mark set 0x7F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6 NTP流量规则添加成功"
    else
        qos_log "WARN" "IPv6 NTP流量规则添加失败"
    fi
    
    qos_log "INFO" "IPv6关键流量规则设置完成"
}

# ========== HTB核心队列函数 ==========
# 创建HTB根队列
create_htb_root_qdisc() {
    local device="$1"
    local direction="$2"  # upload 或 download
    local root_handle="$3"  # 1:0 或 2:0
    local root_classid="$4"  # 1:1 或 2:1
    local bandwidth=""
    
    # 根据方向获取带宽
    if [ "$direction" = "upload" ]; then
        bandwidth="$total_upload_bandwidth"
    elif [ "$direction" = "download" ]; then
        bandwidth="$total_download_bandwidth"
    else
        qos_log "ERROR" "未知方向: $direction"
        return 1
    fi
    
    qos_log "INFO" "为$device创建$direction方向HTB根队列 (带宽: ${bandwidth}kbit)"
    
    # 删除现有队列
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    tc qdisc del dev "$device" root 2>/dev/null || true
    
    # 创建HTB根队列（不设置默认类，稍后通过tc qdisc change设置）
    qos_log "INFO" "正在为 $device 创建 HTB 根队列..."
    if ! tc qdisc add dev "$device" root handle $root_handle htb r2q $HTB_R2Q; then
        qos_log "ERROR" "无法在 $device 上创建HTB根队列"
        return 1
    fi
    
    # 计算burst参数
    local burst_params=$(calculate_htb_burst "$bandwidth" "$bandwidth")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    
    # 创建根类
    qos_log "INFO" "正在为 $device 创建 HTB 根类..."
    if ! tc class add dev "$device" parent $root_handle classid $root_classid htb \
        rate ${bandwidth}kbit ceil ${bandwidth}kbit burst $burst cburst $cburst; then
        qos_log "ERROR" "无法在$device上创建HTB根类"
        return 1
    fi
    
    qos_log "INFO" "$device的$direction方向HTB根队列创建完成"
    return 0
}

# 创建HTB上传类别（优化：确保rate至少1kbit）
create_htb_upload_class() {
    local class_name="$1"
    local class_index="$2"
    
    qos_log "INFO" "创建上传类别: $class_name, ID: 1:$class_index"
    
    # 加载类别配置
    local class_config
    if ! class_config=$(load_htb_class_config "$class_name"); then
        qos_log "ERROR" "加载HTB配置失败: $class_name"
        return 1
    fi
    # 在eval前声明所有可能出现的变量为局部
    local percent_bandwidth per_min_bandwidth per_max_bandwidth priority name
    eval "$class_config"
    
    # 获取标记值（使用rule.sh的统一接口）
    local class_mark
    if ! class_mark=$(get_class_mark_for_rule "$class_name" "upload"); then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: $class_mark"
    
    # 计算带宽参数
    local rate=""  # 保证带宽
    local ceil=""  # 上限带宽
    local rate_value=0
    
    # 1. 计算类别总带宽
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
    
    # 2. 计算保证带宽 (rate)
    if [ -n "$per_min_bandwidth" ] && [ "$per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$per_min_bandwidth" -eq 0 ]; then
            # 如果配置为0，则强制设为1kbit（HTB不允许0）
            rate="1kbit"
            rate_value=1
            qos_log "INFO" "类别 $class_name 设置最小保证带宽: $rate (per_min_bandwidth=0)"
        else
            rate_value=$((class_total_bw * per_min_bandwidth / 100))
            if [ "$rate_value" -lt 1 ]; then
                rate_value=1
            fi
            rate="${rate_value}kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $rate (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        # 默认保证带宽为类别总带宽的50%，但至少1kbit
        rate_value=$((class_total_bw * 50 / 100))
        if [ "$rate_value" -lt 1 ]; then
            rate_value=1
        fi
        rate="${rate_value}kbit"
        qos_log "INFO" "类别 $class_name 使用默认保证带宽: $rate (50% of ${class_total_bw}kbit)"
    fi
    
    # 3. 计算上限带宽 (ceil)
    if [ -n "$per_max_bandwidth" ] && [ "$per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ceil="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ceil (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ceil="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ceil"
    fi
    
    # 4. 验证保证带宽不超过上限带宽
    local ceil_value=$(echo "$ceil" | sed 's/kbit//')
    
    if [ "$rate_value" -gt "$ceil_value" ]; then
        qos_log "WARN" "类别 $class_name 保证带宽($rate)超过上限带宽($ceil)，调整为上限带宽"
        rate="$ceil"
        rate_value="$ceil_value"
    fi
    
    # 5. 获取接口MTU
    local mtu=$(cat /sys/class/net/$qos_interface/mtu 2>/dev/null || echo 1500)
    
    # 6. 计算burst参数
    local burst_params=$(calculate_htb_burst "$rate_value" "$ceil_value" "$mtu")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    
    # 7. 设置优先级
    local prio="prio 3"  # 默认优先级
    if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
        prio="prio $priority"
    fi
    
    # 创建HTB类别
    qos_log "INFO" "正在创建HTB类别 1:$class_index (rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst, $prio)"
    
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        qos_log "ERROR" "创建上传类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM}"
    
    if [ -n "$FQCODEL_MEMORY_LIMIT" ]; then
        fq_codel_params="$fq_codel_params memory_limit ${FQCODEL_MEMORY_LIMIT}"
    fi
    
    if [ -n "$FQCODEL_CE_THRESHOLD" ]; then
        fq_codel_params="$fq_codel_params ce_threshold ${FQCODEL_CE_THRESHOLD}"
    fi
    
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    qos_log "INFO" "添加上传fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params; then
        qos_log "ERROR" "添加上传fq_codel队列失败"
        return 1
    fi
    
    # 添加IPv4过滤器（使用掩码）
    if [ "$class_mark" != "0x0" ]; then
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle ${class_mark}/$UPLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加上传IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    
    # 添加IPv6过滤器（使用掩码）
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
    
    qos_log "INFO" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: rate=$rate, ceil=$ceil)"
    return 0
}

# 创建HTB下载类别（优化：确保rate至少1kbit）
create_htb_download_class() {
    local class_name="$1"
    local class_index="$2"
    local filter_prio="$3"   # 用于TC过滤器的优先级（避免与类别配置的priority冲突）
    
    qos_log "INFO" "创建下载类别: $class_name, ID: 1:$class_index, 过滤器优先级: $filter_prio"
    
    # IFB设备热插拔支持
    local retries=5
    while ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1 && ((retries-- > 0)); do
        ip link add dev "$IFB_DEVICE" type ifb
        sleep 1
    done
    if [ $retries -eq 0 ]; then
        qos_log "ERROR" "IFB设备创建失败"
        return 1
    fi
    
    # 加载类别配置
    local class_config
    if ! class_config=$(load_htb_class_config "$class_name"); then
        qos_log "ERROR" "加载HTB配置失败: $class_name"
        return 1
    fi
    # 在eval前声明所有可能出现的变量为局部
    local percent_bandwidth per_min_bandwidth per_max_bandwidth priority name
    eval "$class_config"
    
    # 获取标记值
    local class_mark
    if ! class_mark=$(get_class_mark_for_rule "$class_name" "download"); then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: $class_mark"
    
    # 计算带宽参数
    local rate=""  # 保证带宽
    local ceil=""  # 上限带宽
    local rate_value=0
    
    # 1. 计算类别总带宽
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
    
    # 2. 计算保证带宽 (rate)
    if [ -n "$per_min_bandwidth" ] && [ "$per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$per_min_bandwidth" -eq 0 ]; then
            rate="1kbit"
            rate_value=1
            qos_log "INFO" "类别 $class_name 设置最小保证带宽: $rate (per_min_bandwidth=0)"
        else
            rate_value=$((class_total_bw * per_min_bandwidth / 100))
            if [ "$rate_value" -lt 1 ]; then
                rate_value=1
            fi
            rate="${rate_value}kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $rate (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        # 默认保证带宽为类别总带宽的50%
        rate_value=$((class_total_bw * 50 / 100))
        if [ "$rate_value" -lt 1 ]; then
            rate_value=1
        fi
        rate="${rate_value}kbit"
        qos_log "INFO" "类别 $class_name 使用默认保证带宽: $rate (50% of ${class_total_bw}kbit)"
    fi
    
    # 3. 计算上限带宽 (ceil)
    if [ -n "$per_max_bandwidth" ] && [ "$per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ceil="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ceil (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ceil="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ceil"
    fi
    
    # 4. 验证保证带宽不超过上限带宽
    local ceil_value=$(echo "$ceil" | sed 's/kbit//')
    
    if [ "$rate_value" -gt "$ceil_value" ]; then
        qos_log "WARN" "类别 $class_name 保证带宽($rate)超过上限带宽($ceil)，调整为上限带宽"
        rate="$ceil"
        rate_value="$ceil_value"
    fi
    
    # 5. 获取接口MTU
    local mtu=$(cat /sys/class/net/$IFB_DEVICE/mtu 2>/dev/null || echo 1500)
    
    # 6. 计算burst参数
    local burst_params=$(calculate_htb_burst "$rate_value" "$ceil_value" "$mtu")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    
    # 7. 设置优先级（使用类别配置中的priority）
    local prio="prio 3"  # 默认优先级
    if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
        prio="prio $priority"
    fi
    
    # 创建HTB类别
    qos_log "INFO" "正在创建下载HTB类别 1:$class_index (rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst, $prio)"
    
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        qos_log "ERROR" "创建下载类别 1:$class_index 失败"
        return 1
    fi
    
    # 创建fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM}"
    
    if [ -n "$FQCODEL_MEMORY_LIMIT" ]; then
        fq_codel_params="$fq_codel_params memory_limit ${FQCODEL_MEMORY_LIMIT}"
    fi
    
    if [ -n "$FQCODEL_CE_THRESHOLD" ]; then
        fq_codel_params="$fq_codel_params ce_threshold ${FQCODEL_CE_THRESHOLD}"
    fi
    
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    qos_log "INFO" "添加下载fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params; then
        qos_log "ERROR" "添加下载fq_codel队列失败"
        return 1
    fi
    
    # 添加IPv4过滤器（使用 filter_prio）
    if [ "$class_mark" != "0x0" ]; then
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
            prio $filter_prio handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$filter_prio)"
        fi
    fi
    
    # 添加IPv6过滤器（使用 filter_prio + 100）
    if [ "$class_mark" != "0x0" ]; then
        local base_prio=100
        local ipv6_priority=$((base_prio + filter_prio))
        
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    
    qos_log "INFO" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: rate=$rate, ceil=$ceil)"
    return 0
}

# 创建默认上传类别
create_default_upload_class() {
    qos_log "INFO" "创建默认上传类别"
    
    # 首先创建根队列
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi
    
    # 计算默认类别的rate和ceil
    local rate="$((total_upload_bandwidth * 80 / 100))kbit"  # 默认使用80%带宽
    local ceil="${total_upload_bandwidth}kbit"
    local mtu=$(cat /sys/class/net/$qos_interface/mtu 2>/dev/null || echo 1500)
    local burst_params=$(calculate_htb_burst "$((total_upload_bandwidth * 80 / 100))" "$total_upload_bandwidth" "$mtu")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    
    # 创建默认类别
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:2 htb rate $rate ceil $ceil burst $burst cburst $cburst prio 4; then
        qos_log "ERROR" "创建上传类 1:2 失败"
        return 1
    fi
    
    # 添加fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM}"
    
    if [ -n "$FQCODEL_MEMORY_LIMIT" ]; then
        fq_codel_params="$fq_codel_params memory_limit ${FQCODEL_MEMORY_LIMIT}"
    fi
    
    if [ -n "$FQCODEL_CE_THRESHOLD" ]; then
        fq_codel_params="$fq_codel_params ce_threshold ${FQCODEL_CE_THRESHOLD}"
    fi
    
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    qos_log "INFO" "添加上传默认fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$qos_interface" parent 1:2 \
        handle 2:1 fq_codel $fq_codel_params; then
        qos_log "ERROR" "添加上传默认fq_codel队列失败"
        return 1
    fi
    
    # 设置根队列的默认类（此时默认类已经存在）
    tc qdisc change dev "$qos_interface" root handle 1:0 htb default 2 2>/dev/null || true
    
    # 添加IPv4过滤器
    local mark_hex="0x1"
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加上传默认IPv4过滤器失败"
    fi
    
    # 添加IPv6过滤器
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加上传默认IPv6过滤器失败"
    fi
    
    upload_class_mark_list="default_class:$mark_hex"
    qos_log "INFO" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

# 创建默认下载类别
create_default_download_class() {
    qos_log "INFO" "创建默认下载类别"
    
    # 从配置获取IFB设备名称（兼容原有配置）
    local ifb_device="$IFB_DEVICE"
    
    # IFB设备热插拔支持
    local retries=5
    while ! ip link show dev "$ifb_device" >/dev/null 2>&1 && ((retries-- > 0)); do
        ip link add dev "$ifb_device" type ifb
        sleep 1
    done
    if [ $retries -eq 0 ]; then
        qos_log "ERROR" "IFB设备创建失败"
        return 1
    fi
    
    # 确保IFB设备已启动
    if ! ip link set dev "$ifb_device" up; then
        qos_log "ERROR" "无法启动IFB设备 $ifb_device"
        return 1
    fi
    
    # 首先创建根队列
    if ! create_htb_root_qdisc "$ifb_device" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi
    
    # 计算默认类别的rate和ceil
    local rate="$((total_download_bandwidth * 80 / 100))kbit"  # 默认使用80%带宽
    local ceil="${total_download_bandwidth}kbit"
    local mtu=$(cat /sys/class/net/$ifb_device/mtu 2>/dev/null || echo 1500)
    local burst_params=$(calculate_htb_burst "$((total_download_bandwidth * 80 / 100))" "$total_download_bandwidth" "$mtu")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    
    # 创建默认类别
    if ! tc class add dev "$ifb_device" parent 1:1 \
        classid 1:2 htb rate $rate ceil $ceil burst $burst cburst $cburst prio 4; then
        qos_log "ERROR" "创建下载类 1:2 失败"
        return 1
    fi
    
    # 添加fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM}"
    
    if [ -n "$FQCODEL_MEMORY_LIMIT" ]; then
        fq_codel_params="$fq_codel_params memory_limit ${FQCODEL_MEMORY_LIMIT}"
    fi
    
    if [ -n "$FQCODEL_CE_THRESHOLD" ]; then
        fq_codel_params="$fq_codel_params ce_threshold ${FQCODEL_CE_THRESHOLD}"
    fi
    
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    qos_log "INFO" "添加下载默认fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$ifb_device" parent 1:2 \
        handle 2:1 fq_codel $fq_codel_params; then
        qos_log "ERROR" "添加下载默认fq_codel队列失败"
        return 1
    fi
    
    # 设置根队列的默认类
    tc qdisc change dev "$ifb_device" root handle 1:0 htb default 2 2>/dev/null || true
    
    # 添加IPv4过滤器
    local mark_hex="0x100"
    if ! tc filter add dev "$ifb_device" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加下载默认IPv4过滤器失败"
    fi
    
    # 添加IPv6过滤器
    if ! tc filter add dev "$ifb_device" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null; then
        qos_log "WARN" "添加下载默认IPv6过滤器失败"
    fi
    
    # 设置入口重定向
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
    
    # 在WAN接口上创建ingress队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    # 清除现有的入口过滤器
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null || true
    
    # 重定向所有IPv4流量到IFB设备
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
        qos_log "ERROR" "IPv4入口重定向规则添加失败"
        return 1
    else
        qos_log "INFO" "IPv4入口重定向规则添加成功"
    fi
    
    # 重定向所有IPv6流量到IFB设备
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
        qos_log "ERROR" "IPv6入口重定向规则添加失败"
        return 1
    else
        qos_log "INFO" "IPv6入口重定向规则添加成功"
    fi
    
    # 验证入口重定向配置
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
    
    if [ -z "$ifb_dev" ]; then
        ifb_dev="$IFB_DEVICE"
    fi
    
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
initialize_htb_upload() {
    qos_log "INFO" "初始化上传方向HTB"
    
    # 加载上传类别配置
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        qos_log "WARN" "未找到上传类别配置，使用默认类别"
        if ! create_default_upload_class; then
            return 1
        fi
        return 0
    fi
    
    # 创建根队列
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        if create_htb_upload_class "$class_name" "$class_index"; then
            # 获取标记值（用于列表记录）
            local class_mark_hex=$(get_class_mark_for_rule "$class_name" "upload")
            
            # 添加标记到列表
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
        fi
        class_index=$((class_index + 1))
    done
    
    # 设置默认类别
    set_default_upload_class
    
    qos_log "INFO" "上传方向HTB初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========
initialize_htb_download() {
    qos_log "INFO" "初始化下载方向HTB"
    
    # 加载下载类别配置
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        qos_log "WARN" "未找到下载类别配置，使用默认类别"
        if ! create_default_download_class; then
            return 1
        fi
        return 0
    fi
    
    # IFB设备热插拔支持
    local retries=5
    while ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1 && ((retries-- > 0)); do
        ip link add dev "$IFB_DEVICE" type ifb
        sleep 1
    done
    if [ $retries -eq 0 ]; then
        qos_log "ERROR" "IFB设备创建失败"
        return 1
    fi
    
    # 确保IFB设备已启动
    if ! ip link set dev "$IFB_DEVICE" up; then
        qos_log "ERROR" "无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    
    # 创建根队列
    if ! create_htb_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    local filter_prio=3  # 初始过滤器优先级
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        if create_htb_download_class "$class_name" "$class_index" "$filter_prio"; then
            local class_mark_hex=$(get_class_mark_for_rule "$class_name" "download")
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
        fi
        class_index=$((class_index + 1))
        filter_prio=$((filter_prio + 2))
    done
    
    # 设置默认类别
    set_default_download_class
    
    # 设置入口重定向
    if ! setup_ingress_redirect; then
        qos_log "ERROR" "设置入口重定向失败"
        return 1
    fi
    
    qos_log "INFO" "下载方向HTB初始化完成"
    return 0
}

set_default_upload_class() {
    qos_log "INFO" "设置上传默认类别"
    
    local default_class_name=$(uci -q get qos_gargoyle.upload.default_class 2>/dev/null)
    if [ -z "$default_class_name" ]; then
        qos_log "ERROR" "上传默认类别未配置"
        return
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
        qos_log "ERROR" "未找到上传默认类别 '$default_class_name'"
        return
    fi
    
    # 设置TC默认类别
    tc qdisc change dev "$qos_interface" root handle 1:0 htb default $found_index 2>/dev/null || true
    qos_log "INFO" "上传默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

set_default_download_class() {
    qos_log "INFO" "设置下载默认类别"
    
    local default_class_name=$(uci -q get qos_gargoyle.download.default_class 2>/dev/null)
    if [ -z "$default_class_name" ]; then
        qos_log "ERROR" "下载默认类别未配置"
        return
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
        qos_log "ERROR" "未找到下载默认类别 '$default_class_name'"
        return
    fi
    
    # 设置TC默认类别
    tc qdisc change dev "$IFB_DEVICE" root handle 1:0 htb default $found_index 2>/dev/null || true
    qos_log "INFO" "下载默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

apply_htb_specific_rules() {
    qos_log "INFO" "应用HTB特定增强规则"
    
    # DoS防护：限制单个IP的新连接速率
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        ct state new \
        limit rate 100/second burst 20 packets \
        meta mark set 0x7F counter 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        ct state new \
        limit rate 100/second burst 20 packets \
        meta mark set 0x7F00 counter 2>/dev/null || true
    
    # 防御DoS攻击 - 增强
    nft add rule inet filter input ct state new limit rate 100/second burst 20 accept 2>/dev/null || true
    
    # HTB优先级映射规则
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        meta mark and 0x007f != 0 counter meta priority set "bulk" 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        meta mark and 0x7f00 != 0 counter meta priority set "bulk" 2>/dev/null || true
    
    # HTB连接跟踪优化
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        ct state established,related counter meta mark set ct mark 2>/dev/null || true
    
    # HTB延迟敏感流量优化
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        meta mark and 0x0010 != 0 counter meta priority set "critical" 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        meta mark and 0x1000 != 0 counter meta priority set "critical" 2>/dev/null || true
    
    # 小包优先处理（VoIP、游戏等）
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        ct bytes lt 200 counter meta priority set "normal" 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        ct bytes lt 200 counter meta priority set "normal" 2>/dev/null || true
    
    # HTB特定的TCP优化
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        tcp flags syn tcp option maxseg size set rt mtu counter meta mark set 0x3F 2>/dev/null || true
    
    qos_log "INFO" "HTB特定增强规则应用完成"
}

# 主初始化函数
initialize_htb_qos() {
    qos_log "INFO" "开始初始化HTB QoS系统"
    
    # 获取并发锁
    if ! acquire_lock; then
        qos_log "ERROR" "无法获取并发锁，可能已有其他QoS进程在运行"
        return 1
    fi
    
    # 检查qos_interface是否已设置
    if [ -z "$qos_interface" ]; then
        # 尝试从 UCI 配置读取
        qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
        
        # 如果配置中没有，尝试系统检测
        if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        
        # 如果没有配置，记录错误
        if [ -z "$qos_interface" ]; then
            qos_log "ERROR" "无法确定 WAN 接口，请检查配置"
            release_lock
            return 1
        fi
    fi
    
    qos_log "INFO" "使用WAN接口: $qos_interface"
    
    # 1. 加载HTB与fq_codel专属配置
    if ! load_htb_config; then
        qos_log "ERROR" "加载HTB配置失败"
        release_lock
        return 1
    fi
    
    # 2. 设置IPv6特定规则
    setup_ipv6_specific_rules
    
    # 3. 初始化上传方向
    if [ "$total_upload_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_htb_upload; then
            qos_log "ERROR" "上传方向初始化失败"
            release_lock
            return 1
        fi
    else
        qos_log "ERROR" "上传带宽未配置"
        release_lock
        return 1
    fi
    
    # 4. 初始化下载方向
    if [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_htb_download; then
            qos_log "ERROR" "下载方向初始化失败"
            release_lock
            return 1
        fi
    else
        qos_log "ERROR" "下载带宽未配置"
        release_lock
        return 1
    fi
    
    # 5. 应用HTB特定的nftables规则
    apply_htb_specific_rules
    
    qos_log "INFO" "HTB QoS初始化完成"
    release_lock
    return 0
}

# ========== 停止和清理函数 ==========
stop_htb_qos() {
    qos_log "INFO" "停止HTB QoS"
    
    # 获取并发锁
    if ! acquire_lock; then
        qos_log "WARN" "无法获取并发锁，但将继续尝试停止QoS"
    fi
    
    # 资源泄漏检测
    local tc_count_before=$(tc qdisc show 2>/dev/null | grep -c htb || echo 0)
    local nft_count_before=$(nft list ruleset 2>/dev/null | grep -c "gargoyle-qos-priority" || echo 0)
    
    if [ "$tc_count_before" -gt 0 ]; then
        qos_log "INFO" "检测到 $tc_count_before 个HTB队列，开始清理"
    fi
    
    if [ "$nft_count_before" -gt 0 ]; then
        qos_log "INFO" "检测到 $nft_count_before 个NFTables规则，开始清理"
    fi
    
    # 清理上传方向队列
    tc filter show dev "$qos_interface" 2>/dev/null | grep -q htb && {
        tc filter del dev "$qos_interface" parent 1:0 protocol all 2>/dev/null || true
    }
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    tc qdisc del dev "$qos_interface" root 2>/dev/null || true
    
    # 清理下载方向
    tc filter show dev "$IFB_DEVICE" 2>/dev/null | grep -q htb && {
        tc filter del dev "$IFB_DEVICE" parent 1:0 protocol all 2>/dev/null || true
    }
    tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
    tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    
    # 清理NFTables规则
    nft delete chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
    
    # 清理入口队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    
    # 停用IFB设备
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        qos_log "INFO" "停用IFB设备: $IFB_DEVICE"
    fi
    
    # 清理连接标记
    conntrack -U --mark 0 2>/dev/null || true
    
    # 资源泄漏验证
    local tc_count_after=$(tc qdisc show 2>/dev/null | grep -c htb || echo 0)
    local nft_count_after=$(nft list ruleset 2>/dev/null | grep -c "gargoyle-qos-priority" || echo 0)
    
    if [ "$tc_count_after" -gt 0 ]; then
        qos_log "WARN" "清理后仍有 $tc_count_after 个HTB队列残留"
    fi
    
    if [ "$nft_count_after" -gt 0 ]; then
        qos_log "WARN" "清理后仍有 $nft_count_after 个NFTables规则残留"
    fi
    
    release_lock
    qos_log "INFO" "HTB QoS停止完成 (清理前: ${tc_count_before}队列/${nft_count_before}规则, 清理后: ${tc_count_after}队列/${nft_count_after}规则)"
}

# ========== 状态查询函数 ==========
show_htb_status() {
    # 确保必要的变量已设置
    local qos_ifb="$IFB_DEVICE"
    local mark_dir="/etc/qos_gargoyle"
    local upload_marks_file="$mark_dir/upload_class_marks"
    local download_marks_file="$mark_dir/download_class_marks"
    
    # 如果接口未定义，尝试获取
    if [ -z "$qos_interface" ]; then
        # 尝试从TC输出推断接口
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "htb.*root" | awk '{print $5}' | head -1)
        [ -z "$qos_interface" ] && qos_interface="未知"
    fi
    
    echo "===== HTB-FQ_CODEL QoS 状态报告 ====="
    echo "时间: $(date)"
    echo "WAN接口: ${qos_interface}"
    
    # 检查QoS是否实际运行
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q htb; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    # 检查IFB设备
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        if tc qdisc show dev "$qos_ifb" >/dev/null 2>&1; then
            echo "IFB设备: 已启动且运行中 ($qos_ifb)"
        else
            echo "IFB设备: 已创建但无 TC 队列 ($qos_ifb)"
        fi
    else
        echo "IFB设备: 未创建"
    fi
    
    # 显示出口配置
    echo -e "\n======== 出口QoS ($qos_interface) ========"
    
    echo -e "\nTC队列:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "htb\|fq_codel"; then
            echo "  $line"
        fi
    done
    
    if tc class show dev "$qos_interface" >/dev/null 2>&1; then
        echo -e "\nTC类别:"
        tc -s class show dev "$qos_interface" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "htb"; then
                echo "  $line"
            fi
        done
    fi
    
    echo -e "\nTC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null | while read -r line; do
        echo "  $line"
    done
    
    # 显示入口配置
    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "htb\|fq_codel"; then
                echo "  $line"
            fi
        done
        
        if tc class show dev "$qos_ifb" >/dev/null 2>&1; then
            echo -e "\nTC类别:"
            tc -s class show dev "$qos_ifb" 2>/dev/null | while read -r line; do
                if echo "$line" | grep -q "htb"; then
                    echo "  $line"
                fi
            done
        fi
        
        echo -e "\nTC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            echo "  $line"
        done
        
        # 检查入口重定向
        echo -e "\n入口重定向检查:"
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            check_ingress_redirect "$qos_interface" "$qos_ifb"
        else
            echo "  ✗ 入口队列未配置"
        fi
    else
        echo "  IFB设备不存在，无入口配置"
    fi
    
    # 显示标记文件
    echo -e "\n======== QoS分类标记 ========"
    
    if [ -f "$upload_marks_file" ]; then
        echo "上传标记文件 ($upload_marks_file):"
        cat "$upload_marks_file" 2>/dev/null || echo "  文件读取错误"
    else
        echo "上传标记文件: 未找到"
    fi
    
    echo ""
    
    if [ -f "$download_marks_file" ]; then
        echo "下载标记文件 ($download_marks_file):"
        cat "$download_marks_file" 2>/dev/null || echo "  文件读取错误"
    else
        echo "下载标记文件: 未找到"
    fi
    
    # QoS运行状态摘要
    echo -e "\n===== QoS运行状态 ====="
    local upload_active=0
    local download_active=0
    
    # 检查上传QoS
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "htb"; then
        upload_active=1
        echo "上传QoS: 已启用 (HTB+fq_codel)"
        
        # 显示上传带宽配置
        tc -s class show dev "$qos_interface" 2>/dev/null | grep "rate\|ceil" | while read -r line; do
            echo "  $line"
        done
    else
        echo "上传QoS: 未启用"
    fi
    
    # 检查下载QoS
    if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "htb"; then
        download_active=1
        echo -e "\n下载QoS: 已启用 (HTB+fq_codel)"
        
        # 显示下载带宽配置
        tc -s class show dev "$qos_ifb" 2>/dev/null | grep "rate\|ceil" | while read -r line; do
            echo "  $line"
        done
    else
        echo -e "\n下载QoS: 未启用"
    fi
    
    # 总体状态
    if [ "$upload_active" -eq 1 ] && [ "$download_active" -eq 1 ]; then
        echo -e "\n✓ QoS双向流量整形已启用 (HTB+fq_codel)"
    elif [ "$upload_active" -eq 1 ]; then
        echo -e "\n⚠ 仅上传QoS已启用 (HTB+fq_codel)"
    elif [ "$download_active" -eq 1 ]; then
        echo -e "\n⚠ 仅下载QoS已启用 (HTB+fq_codel)"
    else
        echo -e "\n✗ QoS未运行"
    fi
    
    # 显示详细的队列统计
    echo -e "\n===== 详细队列统计 ====="
    
    # 检查上传方向fq_codel队列统计
    echo -e "\n上传方向fq_codel队列:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null | grep -A 3 "fq_codel" | while read -r line; do
        if echo "$line" | grep -q "parent"; then
            echo "  $line"
        elif echo "$line" | grep -q "Sent" || echo "$line" | grep -q "maxpacket" || echo "$line" | grep -q "ecn_mark" || echo "$line" | grep -q "new_flows_len"; then
            echo "    $line"
        fi
    done
    
    # 检查下载方向fq_codel队列统计
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\n下载方向fq_codel队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | grep -A 3 "fq_codel" | while read -r line; do
            if echo "$line" | grep -q "parent"; then
                echo "  $line"
            elif echo "$line" | grep -q "Sent" || echo "$line" | grep -q "maxpacket" || echo "$line" | grep -q "ecn_mark" || echo "$line" | grep -q "new_flows_len"; then
                echo "    $line"
            fi
        done
    fi
    
    # 显示活动连接标记（从HFSC版本移植）
    echo -e "\n======== 活动连接标记 ========"

    # 获取 WAN 接口的 IP 地址
    local wan_ipv4=""
    local wan_ipv6=""

    # 多种方法获取 IPv4 地址
    wan_ipv4=$(ip -4 addr show dev "$qos_interface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [ -z "$wan_ipv4" ]; then
        wan_ipv4=$(ifconfig "$qos_interface" 2>/dev/null | grep "inet addr:" | awk '{print $2}' | cut -d: -f2)
    fi

    # 多种方法获取 IPv6 地址
    wan_ipv6=$(ip -6 addr show dev "$qos_interface" 2>/dev/null | grep "inet6 " | grep -v "fe80::" | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [ -z "$wan_ipv6" ]; then
        wan_ipv6=$(ifconfig "$qos_interface" 2>/dev/null | grep "inet6 addr:" | grep -v "fe80::" | awk '{print $3}' | cut -d/ -f1)
    fi

    # IPv4 连接标记
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

    # IPv6 连接标记
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

    # 同时显示源地址为 WAN 的连接（上传方向）
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
    
    # 显示网络接口统计
    echo -e "\n===== 网络接口统计 ====="
    
    # 获取接口统计
    echo -e "\n接口流量统计:"
    echo "WAN接口 ($qos_interface):"
    ifconfig "$qos_interface" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($qos_ifb):"
        ifconfig "$qos_ifb" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    fi
    
    echo -e "\n===== HTB-FQ_CODEL 状态报告结束 ====="
    
    return 0
}

# ========== 主程序入口 ==========
main_htb_qos() {
    local action="$1"
    
    case "$action" in
        "start")
            if ! initialize_htb_qos; then
                qos_log "ERROR" "HTB QoS启动失败"
                exit 1
            fi
            ;;
        "stop")
            stop_htb_qos
            ;;
        "restart")
            stop_htb_qos
            sleep 1
            if ! initialize_htb_qos; then
                qos_log "ERROR" "HTB QoS重启失败"
                exit 1
            fi
            ;;
        "status")
            show_htb_status
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status}"
            echo ""
            echo "命令:"
            echo "  start        启动HTB QoS"
            echo "  stop         停止HTB QoS"
            echo "  restart      重启HTB QoS"
            echo "  status       显示状态"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "htb_fqcodel.sh" ] || [ "$(basename "$0")" = "htb-qos.sh" ]; then
    main_htb_qos "$1"
fi