#!/bin/sh
# HFSC_FQCODEL算法实现模块
# 基于HFSC与FQ_CODEL组合算法实现QoS流量控制。
# version=1.3 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>
# 优化版：配置文件驱动，不设默认值，统一使用rule.sh的日志

# ========== 全局配置常量 ==========
# 核心配置常量
: ${CONFIG_FILE:=qos_gargoyle}
: ${MARK_FILE_DIR:=/etc/qos_gargoyle}

# 全局变量声明
upload_class_list=""
download_class_list=""
upload_class_mark_list=""
download_class_mark_list=""

# 加载公共规则辅助模块
if [ -f "/usr/lib/qos_gargoyle/rule.sh" ]; then
    . /usr/lib/qos_gargoyle/rule.sh
    # 定义qos_log为log的别名
    alias qos_log=log
else
    echo "错误: 规则辅助模块未找到" >&2
    exit 1
fi

# 加载必要的库
. /lib/functions.sh
. /lib/functions/network.sh
include /lib/network

# 如果 qos_interface 未设置，尝试获取
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
        exit 1
    fi
fi

# 初始化总带宽变量
total_upload_bandwidth=""
total_download_bandwidth=""
upload_shift=0
download_shift=8

# ========== 验证函数 ==========
# 验证数值参数
validate_number() {
    local value="$1"
    local param_name="$2"
    local min="${3:-0}"
    local max="${4:-2147483647}"
    
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        qos_log "ERROR" "参数 $param_name 必须是整数: $value"
        return 1
    fi
    
    if [ "$value" -lt "$min" ] 2>/dev/null; then
        qos_log "ERROR" "参数 $param_name 必须大于等于 $min: $value"
        return 1
    fi
    
    if [ "$value" -gt "$max" ] 2>/dev/null; then
        qos_log "ERROR" "参数 $param_name 必须小于等于 $max: $value"
        return 1
    fi
    
    return 0
}

# 验证百分比参数
validate_percentage() {
    local value="$1"
    local param_name="$2"
    
    if ! validate_number "$value" "$param_name" 0 100; then
        return 1
    fi
    
    return 0
}

# 验证带宽参数
validate_bandwidth() {
    local value="$1"
    local param_name="$2"
    
    if ! validate_number "$value" "$param_name" 1 100000000; then
        return 1
    fi
    
    return 0
}

# 验证端口参数
validate_port() {
    local value="$1"
    local param_name="$2"
    
    # 检查是否为空
    if [ -z "$value" ]; then
        return 0
    fi
    
    # 检查是否包含逗号分隔的端口列表
    if echo "$value" | grep -q ','; then
        local IFS=','
        for port in $value; do
            if ! validate_number "$port" "$param_name" 1 65535; then
                return 1
            fi
        done
    # 检查是否是端口范围
    elif echo "$value" | grep -q '-'; then
        local min_port=$(echo "$value" | cut -d'-' -f1)
        local max_port=$(echo "$value" | cut -d'-' -f2)
        
        if ! validate_number "$min_port" "$param_name" 1 65535; then
            return 1
        fi
        if ! validate_number "$max_port" "$param_name" 1 65535; then
            return 1
        fi
        if [ "$min_port" -gt "$max_port" ]; then
            qos_log "ERROR" "端口范围 $param_name 起始端口 $min_port 大于结束端口 $max_port"
            return 1
        fi
    # 检查是否是单个端口
    else
        if ! validate_number "$value" "$param_name" 1 65535; then
            return 1
        fi
    fi
    
    return 0
}

# ========== 配置加载函数 ==========
# 加载带宽配置
load_bandwidth_from_config() {
    qos_log "INFO" "加载带宽配置"
    
    # 读取上传总带宽
    local config_upload_bw=$(uci -q get qos_gargoyle.upload.total_bandwidth 2>/dev/null)
    if [ -z "$config_upload_bw" ]; then
        qos_log "ERROR" "上传总带宽未配置"
        return 1
    fi
    
    if validate_bandwidth "$config_upload_bw" "upload.total_bandwidth"; then
        total_upload_bandwidth="$config_upload_bw"
        qos_log "INFO" "从配置文件读取上传总带宽: ${total_upload_bandwidth}kbit/s"
    else
        qos_log "ERROR" "上传总带宽配置无效: $config_upload_bw"
        return 1
    fi

    # 读取下载总带宽
    local config_download_bw=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    if [ -z "$config_download_bw" ]; then
        qos_log "ERROR" "下载总带宽未配置"
        return 1
    fi
    
    if validate_bandwidth "$config_download_bw" "download.total_bandwidth"; then
        total_download_bandwidth="$config_download_bw"
        qos_log "INFO" "从配置文件读取下载总带宽: ${total_download_bandwidth}kbit/s"
    else
        qos_log "ERROR" "下载总带宽配置无效: $config_download_bw"
        return 1
    fi
    
    return 0
}

# 计算内存限制
calculate_memory_limit() {
    local config_value="$1"
    local result

    # 如果没有配置，返回空
    if [ -z "$config_value" ]; then
        echo ""
        return
    fi
    
    # 如果配置了 'auto'，则自动计算
    if [ "$config_value" = "auto" ]; then
        local total_mem_kb=$(grep -E '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
        
        if [ -n "$total_mem_kb" ] && [ "$total_mem_kb" -gt 0 ] 2>/dev/null; then
            if [ "$total_mem_kb" -lt 128000 ]; then
                result="4Mb"  # < 128MB RAM
            elif [ "$total_mem_kb" -lt 256000 ]; then
                result="8Mb"   # < 256MB RAM
            elif [ "$total_mem_kb" -lt 512000 ]; then
                result="16Mb"   # < 512MB RAM
            else
                result="32Mb"   # > 512MB RAM
            fi
            qos_log "INFO" "系统内存 ${total_mem_kb}KB，自动计算 memory_limit=${result}"
        else
            qos_log "WARN" "无法读取内存信息，使用默认值 16Mb"
            result="16Mb"
        fi
    else
        # 用户提供了具体值，直接使用
        result="$config_value"
    fi
    
    echo "$result"
}

# 加载HFSC与fq_codel专属配置
load_hfsc_config() {
    qos_log "INFO" "加载HFSC与fq_codel配置"
    
    # 加载带宽配置
    if ! load_bandwidth_from_config; then
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
    
    qos_log "INFO" "HFSC配置: latency_mode=${HFSC_LATENCY_MODE}, minrtt_enabled=${HFSC_MINRTT_ENABLED}"
    qos_log "INFO" "fq_codel参数: limit=${FQCODEL_LIMIT}, interval=${FQCODEL_INTERVAL}us, target=${FQCODEL_TARGET}us, flows=${FQCODEL_FLOWS}, quantum=${FQCODEL_QUANTUM}, memory_limit=${FQCODEL_MEMORY_LIMIT}, ce_threshold=${FQCODEL_CE_THRESHOLD}, ecn=${FQCODEL_ECN:-未配置}"
    
    return 0
}

# 加载HFSC类别配置 - 修复变量作用域问题
load_hfsc_class_config() {
    local class_name="$1"
    local percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name
    
    qos_log "INFO" "加载HFSC类别配置: $class_name"
    
    # 清空之前设置的变量
    unset percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name
    
    # 直接通过UCI读取HFSC类别配置
    percent_bandwidth=$(uci -q get qos_gargoyle.$class_name.percent_bandwidth 2>/dev/null)
    per_min_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_min_bandwidth 2>/dev/null)
    per_max_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_max_bandwidth 2>/dev/null)
    minRTT=$(uci -q get qos_gargoyle.$class_name.minRTT 2>/dev/null)
    priority=$(uci -q get qos_gargoyle.$class_name.priority 2>/dev/null)
    name=$(uci -q get qos_gargoyle.$class_name.name 2>/dev/null)
    
    # 验证百分比参数
    if [ -n "$percent_bandwidth" ] && ! validate_percentage "$percent_bandwidth" "$class_name.percent_bandwidth"; then
        percent_bandwidth=""
    fi
    
    if [ -n "$per_min_bandwidth" ] && ! validate_percentage "$per_min_bandwidth" "$class_name.per_min_bandwidth"; then
        per_min_bandwidth=""
    fi
    
    if [ -n "$per_max_bandwidth" ] && ! validate_percentage "$per_max_bandwidth" "$class_name.per_max_bandwidth"; then
        per_max_bandwidth=""
    fi
    
    # 调试日志
    qos_log "DEBUG" "HFSC配置: $class_name -> percent=$percent_bandwidth, min=$per_min_bandwidth, max=$per_max_bandwidth, minRTT=$minRTT"
    
    # 验证是否加载了关键参数
    if [ -z "$percent_bandwidth" ] && [ -z "$per_min_bandwidth" ] && [ -z "$per_max_bandwidth" ]; then
        qos_log "WARN" "未找到 $class_name 的带宽参数"
        return 1
    fi
    
    # 创建输出字符串，避免export污染
    echo "${percent_bandwidth}:${per_min_bandwidth}:${per_max_bandwidth}:${minRTT}:${priority}:${name}"
    return 0
}

# 解析加载的类别配置
parse_class_config() {
    local config_line="$1"
    local var_prefix="$2"
    
    # 解析配置行
    IFS=':' read -r percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name <<EOF
$config_line
EOF
    
    # 导出到调用者变量
    eval "${var_prefix}_percent_bandwidth=\"$percent_bandwidth\""
    eval "${var_prefix}_per_min_bandwidth=\"$per_min_bandwidth\""
    eval "${var_prefix}_per_max_bandwidth=\"$per_max_bandwidth\""
    eval "${var_prefix}_minRTT=\"$minRTT\""
    eval "${var_prefix}_priority=\"$priority\""
    eval "${var_prefix}_name=\"$name\""
}

# 加载上传类别配置
load_upload_class_configurations() {
    qos_log "INFO" "正在加载上传类别配置..."
    
    # 直接使用UCI命令查找upload_class配置节
    upload_class_list=""
    config_get upload_class_list global upload_classes
    if [ -z "$upload_class_list" ]; then
        # 如果没有预定义列表，从UCI配置中查找
        upload_class_list=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "^qos_gargoyle\.[a-zA-Z0-9_]+=upload_class$" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
    fi
    
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
    
    # 直接使用UCI命令查找download_class配置节
    download_class_list=""
    config_get download_class_list global download_classes
    if [ -z "$download_class_list" ]; then
        # 如果没有预定义列表，从UCI配置中查找
        download_class_list=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "^qos_gargoyle\.[a-zA-Z0-9_]+=download_class$" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
    fi
    
    if [ -n "$download_class_list" ]; then
        qos_log "INFO" "找到下载类别: $download_class_list"
    else
        qos_log "WARN" "没有找到下载类别配置"
        download_class_list=""
    fi
    
    return 0
}

# 读取标记文件
read_mark_from_file() {
    local class_name="$1"      # 类别名称
    local direction="$2"       # 方向: "upload" 或 "download"
    local mark_file=""
    local class_pattern=""
    
    # 根据方向选择文件
    if [ "$direction" = "upload" ]; then
        mark_file="${MARK_FILE_DIR}/upload_class_marks"
        # 支持多种类别名称格式
        if echo "$class_name" | grep -q "^upload_class_"; then
            class_pattern="u${class_name#upload_class_}"
        elif echo "$class_name" | grep -q "^uclass_"; then
            class_pattern="${class_name#uclass_}"
        else
            class_pattern="$class_name"
        fi
    elif [ "$direction" = "download" ]; then
        mark_file="${MARK_FILE_DIR}/download_class_marks"
        # 支持多种类别名称格式
        if echo "$class_name" | grep -q "^download_class_"; then
            class_pattern="d${class_name#download_class_}"
        elif echo "$class_name" | grep -q "^dclass_"; then
            class_pattern="${class_name#dclass_}"
        else
            class_pattern="$class_name"
        fi
    else
        qos_log "ERROR" "未知方向: $direction"
        echo ""
        return 1
    fi
    
    # 检查文件是否存在
    if [ ! -f "$mark_file" ]; then
        qos_log "ERROR" "标记文件不存在: $mark_file"
        echo ""
        return 1
    fi
    
    # 尝试多种格式查找
    local mark=""
    
    # 格式1: 完整格式 (upload:upload_class_1:0x1)
    if echo "$class_name" | grep -q "_class_"; then
        mark=$(grep "^${direction}:${class_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    fi
    
    # 格式2: 简短格式 (upload:uclass_1:0x1 或 download:dclass_1:0x100)
    if [ -z "$mark" ]; then
        local short_name=""
        if [ "$direction" = "upload" ]; then
            short_name="uclass_${class_pattern}"
        else
            short_name="dclass_${class_pattern}"
        fi
        mark=$(grep "^${direction}:${short_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    fi
    
    # 格式3: 仅数字 (1, 2, 3...)
    if [ -z "$mark" ] && echo "$class_pattern" | grep -qE '^[0-9]+$'; then
        if [ "$direction" = "upload" ]; then
            mark=$(grep "^upload:uclass_${class_pattern}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
        else
            mark=$(grep "^download:dclass_${class_pattern}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
        fi
    fi
    
    if [ -n "$mark" ]; then
        # 确保标记格式正确
        if echo "$mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
            echo "$mark"
            return 0
        else
            qos_log "WARN" "读取的标记格式不正确: $mark"
        fi
    fi
    
    # 如果文件中没有找到，返回空值
    qos_log "ERROR" "在 $mark_file 中未找到 $direction:$class_name 的标记"
    echo ""
    return 1
}

# 计算回退标记
calculate_fallback_mark() {
    local direction="$1"
    local class_index="$2"
    local class_name="$3"
    
    if [ "$direction" = "upload" ]; then
        # 上传标记计算
        local class_num=$(echo "$class_name" | sed -E 's/^upload_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            printf "0x%X" $((0x1 << (class_num - 1)))
        else
            printf "0x%X" $((0x1 << (class_index - 2)))
        fi
    else
        # 下载标记计算
        local class_num=$(echo "$class_name" | sed -E 's/^download_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            printf "0x%X" $((0x100 << (class_num - 1)))
        else
            printf "0x%X" $((0x100 << (class_index - 2)))
        fi
    fi
}

# ========== IPv6增强支持 ==========
setup_ipv6_specific_rules() {
    qos_log "INFO" "设置IPv6特定规则"
    
    # ICMPv6关键类型（邻居发现、路由通告等）
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    
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
    
    # IPv6多播流量（ff00::/8）
    if nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ff00::/8 \
        meta mark set 0x3F counter 2>/dev/null; then
        qos_log "DEBUG" "IPv6多播流量规则添加成功"
    else
        qos_log "WARN" "IPv6多播流量规则添加失败"
    fi
    
    qos_log "INFO" "IPv6关键流量规则设置完成"
}

# ========== HFSC核心队列函数 ==========
create_hfsc_root_qdisc() {
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
    
    qos_log "INFO" "为$device创建$direction方向HFSC根队列 (带宽: ${bandwidth}kbit)"
    
    # 删除现有队列
    tc qdisc del dev "$device" root 2>/dev/null
    tc qdisc del dev "$device" ingress 2>/dev/null
    
    # 创建HFSC根队列
    qos_log "INFO" "正在为 $device 创建 HFSC 根队列..."
    if ! tc qdisc add dev "$device" root handle $root_handle hfsc; then
        qos_log "ERROR" "无法在 $device 上创建HFSC根队列"
        return 1
    fi
    
    # 创建根类
    qos_log "INFO" "正在为 $device 创建 HFSC 根类..."
    if ! tc class add dev "$device" parent $root_handle classid $root_classid hfsc ls m2 ${bandwidth}kbit ul m2 ${bandwidth}kbit; then
        qos_log "ERROR" "无法在$device上创建HFSC根类"
        return 1
    fi
    
    qos_log "INFO" "$device的$direction方向HFSC根队列创建完成"
    return 0
}

# 创建HFSC上传类别
create_hfsc_upload_class() {
    local class_name="$1"
    local class_index="$2"
    
    qos_log "INFO" "创建上传类别: $class_name, ID: 1:$class_index"
    
    # 加载类别配置
    local class_config
    if class_config=$(load_hfsc_class_config "$class_name"); then
        parse_class_config "$class_config" "class"
    else
        qos_log "ERROR" "加载HFSC配置失败: $class_name"
        return 1
    fi
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "upload")
    
    if [ -z "$class_mark" ]; then
        # 使用回退计算
        class_mark=$(calculate_fallback_mark "upload" "$class_index" "$class_name")
        qos_log "WARN" "从文件读取标记失败，使用计算值: $class_mark"
    else
        qos_log "INFO" "从文件获取上传标记: $class_mark"
    fi
    
    # 计算带宽参数
    local m1="0bit"
    local d="0us"
    local m2=""  # 保证带宽
    local ul_m2="" # 上限带宽
    
    # 1. 计算类别总带宽
    local class_total_bw=0
    if [ -n "$class_percent_bandwidth" ] && [ "$class_percent_bandwidth" -gt 0 ] 2>/dev/null; then
        if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ] 2>/dev/null; then
            class_total_bw=$((total_upload_bandwidth * class_percent_bandwidth / 100))
            qos_log "INFO" "类别 $class_name 总带宽: ${class_total_bw}kbit (${class_percent_bandwidth}% of ${total_upload_bandwidth}kbit)"
        else
            qos_log "ERROR" "total_upload_bandwidth无效"
            return 1
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 percent_bandwidth"
        return 1
    fi
    
    # 2. 计算保证带宽 (m2)
    if [ -n "$class_per_min_bandwidth" ] && [ "$class_per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$class_per_min_bandwidth" -eq 0 ]; then
            m2="0kbit"
            qos_log "INFO" "类别 $class_name 不保证最小带宽 (per_min_bandwidth=0)"
        else
            m2="$((class_total_bw * class_per_min_bandwidth / 100))kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $m2 (${class_per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 per_min_bandwidth"
        return 1
    fi
    
    # 3. 计算上限带宽 (ul_m2)
    if [ -n "$class_per_max_bandwidth" ] && [ "$class_per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ul_m2="$((class_total_bw * class_per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ul_m2 (${class_per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ul_m2="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ul_m2"
    fi
    
    # 4. 验证保证带宽不超过上限带宽
    local m2_value=$(echo "$m2" | sed 's/kbit//')
    local ul_m2_value=$(echo "$ul_m2" | sed 's/kbit//')
    
    if [ "$m2_value" -gt "$ul_m2_value" ]; then
        qos_log "WARN" "类别 $class_name 保证带宽($m2)超过上限带宽($ul_m2)，调整为上限带宽"
        m2="$ul_m2"
    fi
    
    # 5. 应用最小延迟参数
    if [ "${class_minRTT:-No}" = "Yes" ]; then
        d="$HFSC_MINRTT_DELAY"
        qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d)"
    fi
    
    # 创建HFSC类别
    qos_log "INFO" "正在创建HFSC类别 1:$class_index (带宽: ls=$m2, ul=$ul_m2)"
    
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul rate $ul_m2; then
        qos_log "ERROR" "创建上传类别 1:$class_index 失败 (带宽: ls=$m2, ul=$ul_m2)"
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
    
    # 添加过滤器
    if [ "$class_mark" != "0x0" ]; then
        # IPv4过滤器
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加上传IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((class_index + 100))
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加上传IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    
    qos_log "INFO" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

# 创建HFSC下载类别
create_hfsc_download_class() {
    local class_name="$1"
    local class_index="$2"
    local priority="$3"
    
    qos_log "INFO" "创建下载类别: $class_name, ID: 1:$class_index, 优先级: $priority"
    
    # 加载类别配置
    local class_config
    if class_config=$(load_hfsc_class_config "$class_name"); then
        parse_class_config "$class_config" "class"
    else
        qos_log "ERROR" "加载HFSC配置失败: $class_name"
        return 1
    fi
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "download")
    
    if [ -z "$class_mark" ]; then
        # 使用回退计算
        class_mark=$(calculate_fallback_mark "download" "$class_index" "$class_name")
        qos_log "WARN" "从文件读取标记失败，使用计算值: $class_mark"
    else
        qos_log "INFO" "从文件获取下载标记: $class_mark"
    fi
    
    # 计算带宽参数
    local m1="0bit"
    local d="0us"
    local m2=""  # 保证带宽
    local ul_m2="" # 上限带宽
    
    # 1. 计算类别总带宽
    local class_total_bw=0
    if [ -n "$class_percent_bandwidth" ] && [ "$class_percent_bandwidth" -gt 0 ] 2>/dev/null; then
        if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
            class_total_bw=$((total_download_bandwidth * class_percent_bandwidth / 100))
            qos_log "INFO" "类别 $class_name 总带宽: ${class_total_bw}kbit (${class_percent_bandwidth}% of ${total_download_bandwidth}kbit)"
        else
            qos_log "ERROR" "total_download_bandwidth无效"
            return 1
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 percent_bandwidth"
        return 1
    fi
    
    # 2. 计算保证带宽 (m2)
    if [ -n "$class_per_min_bandwidth" ] && [ "$class_per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$class_per_min_bandwidth" -eq 0 ]; then
            m2="0kbit"
            qos_log "INFO" "类别 $class_name 不保证最小带宽 (per_min_bandwidth=0)"
        else
            m2="$((class_total_bw * class_per_min_bandwidth / 100))kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $m2 (${class_per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        qos_log "ERROR" "类别 $class_name 未配置 per_min_bandwidth"
        return 1
    fi
    
    # 3. 计算上限带宽 (ul_m2)
    if [ -n "$class_per_max_bandwidth" ] && [ "$class_per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ul_m2="$((class_total_bw * class_per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ul_m2 (${class_per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ul_m2="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ul_m2"
    fi
    
    # 4. 验证保证带宽不超过上限带宽
    local m2_value=$(echo "$m2" | sed 's/kbit//')
    local ul_m2_value=$(echo "$ul_m2" | sed 's/kbit//')
    
    if [ "$m2_value" -gt "$ul_m2_value" ]; then
        qos_log "WARN" "类别 $class_name 保证带宽($m2)超过上限带宽($ul_m2)，调整为上限带宽"
        m2="$ul_m2"
    fi
    
    # 5. 应用最小延迟参数
    if [ "${class_minRTT:-No}" = "Yes" ]; then
        d="$HFSC_MINRTT_DELAY"
        qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d)"
    fi
    
    # 创建HFSC类别
    qos_log "INFO" "正在创建下载HFSC类别 1:$class_index (带宽: ls=$m2, ul=$ul_m2)"
    
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul m1 0bit d 0us m2 $ul_m2; then
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
    
    # 添加过滤器
    if [ "$class_mark" != "0x0" ]; then
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
            prio $priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((priority + 100))
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    
    qos_log "INFO" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

# 创建默认上传类别
create_default_upload_class() {
    qos_log "INFO" "创建默认上传类别"
    
    # 首先创建根队列
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi
    
    # 创建默认类别
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:2 hfsc ls m2 ${total_upload_bandwidth}kbit ul m2 ${total_upload_bandwidth}kbit; then
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
    
    # 设置根队列的默认类
    tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default 2 2>/dev/null || true
    
    # 添加过滤器
    local mark_hex="0x1"
    tc filter add dev "$qos_interface" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null || true
    
    tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2 2>/dev/null || true
    
    upload_class_mark_list="default_class:$mark_hex"
    qos_log "INFO" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

# 创建默认下载类别
create_default_download_class() {
    qos_log "INFO" "创建默认下载类别"
    
    # 从配置获取IFB设备名称
    local ifb_device=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    if [ -z "$ifb_device" ]; then
        qos_log "ERROR" "IFB设备名称未配置"
        return 1
    fi
    
    # 确保IFB设备存在并已启动
    if ! ip link show dev "$ifb_device" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $ifb_device 不存在"
        return 1
    fi
    
    if ! ip link set dev "$ifb_device" up; then
        qos_log "ERROR" "无法启动IFB设备 $ifb_device"
        return 1
    fi
    
    # 首先创建根队列
    if ! create_hfsc_root_qdisc "$ifb_device" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi
    
    # 创建默认类别
    if ! tc class add dev "$ifb_device" parent 1:1 \
        classid 1:2 hfsc ls m2 ${total_download_bandwidth}kbit ul m2 ${total_download_bandwidth}kbit; then
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
    tc qdisc change dev "$ifb_device" root handle 1:0 hfsc default 2 2>/dev/null || true
    
    # 添加过滤器
    local mark_hex="0x100"
    tc filter add dev "$ifb_device" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null || true
    
    tc filter add dev "$ifb_device" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2 2>/dev/null || true
    
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
    # 从配置获取IFB设备名称
    local ifb_device=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    if [ -z "$ifb_device" ]; then
        qos_log "ERROR" "IFB设备名称未配置"
        return 1
    fi
    
    if [ -z "$qos_interface" ]; then
        qos_log "ERROR" "无法确定 WAN 接口"
        return 1
    fi
    
    qos_log "INFO" "设置入口重定向: $qos_interface -> $ifb_device"
    
    # 在WAN接口上创建ingress队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    # 清除现有的入口过滤器
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null
    
    # 重定向所有IPv4流量到IFB设备
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$ifb_device"; then
        qos_log "WARN" "IPv4入口重定向规则添加失败"
    else
        qos_log "INFO" "IPv4入口重定向规则添加成功"
    fi
    
    # 重定向所有IPv6流量到IFB设备
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$ifb_device"; then
        qos_log "WARN" "IPv6入口重定向规则添加失败"
    else
        qos_log "INFO" "IPv6入口重定向规则添加成功"
    fi
    
    # 验证入口重定向配置
    local ingress_rules=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | wc -l)
    
    if [ "$ingress_rules" -ge 2 ]; then
        qos_log "INFO" "入口重定向已成功设置: $qos_interface -> $ifb_device ($ingress_rules 条规则)"
    else
        qos_log "WARN" "入口重定向规则数量不足 ($ingress_rules 条)"
        return 1
    fi
    
    return 0
}

check_ingress_redirect() {
    local iface="$1"
    local ifb_device=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    if [ -z "$ifb_device" ]; then
        echo "IFB设备未配置"
        return
    fi
    
    echo "检查入口重定向 (接口: $iface, IFB设备: $ifb_device)"
    
    echo "  IPv4入口规则:"
    local ipv4_rules=$(tc filter show dev "$iface" parent ffff: protocol ip 2>/dev/null)
    if [ -n "$ipv4_rules" ]; then
        echo "$ipv4_rules" | sed 's/^/    /'
        if echo "$ipv4_rules" | grep -q "mirred.*Redirect to device $ifb_device"; then
            echo "    ✓ IPv4 重定向到 $ifb_device: 已生效"
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
        if echo "$ipv6_rules" | grep -q "mirred.*Redirect to device $ifb_device"; then
            echo "    ✓ IPv6 重定向到 $ifb_device: 已生效"
        else
            echo "    ✗ IPv6 重定向: mirred动作未找到"
        fi
    else
        echo "    无IPv6入口规则"
    fi
}

# ========== 上传方向初始化 ==========
initialize_hfsc_upload() {
    qos_log "INFO" "初始化上传方向HFSC"
    
    # 加载上传类别配置
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        qos_log "WARN" "未找到上传类别配置，使用默认类别"
        create_default_upload_class
        return 0
    fi
    
    # 创建根队列
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        if create_hfsc_upload_class "$class_name" "$class_index"; then
            local class_mark_hex=""
            
            # 从配置文件获取class_mark
            local config_class_mark=$(uci -q get "${CONFIG_FILE}.${class_name}.class_mark" 2>/dev/null)
            if [ -n "$config_class_mark" ] && [ "$config_class_mark" != "0x0" ]; then
                class_mark_hex="$config_class_mark"
                qos_log "INFO" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                # 否则使用自动计算的值
                local mark_value=$((class_index << upload_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                qos_log "INFO" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            # 添加标记到列表
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                # 从配置获取掩码
                local upload_mask=$(uci -q get "${CONFIG_FILE}.upload.upload_mask" 2>/dev/null)
                if [ -z "$upload_mask" ]; then
                    upload_mask="0x007F"
                fi
                
                tc filter add dev "$qos_interface" parent 1:0 protocol ip \
                    prio 1 handle ${class_mark_hex}/$upload_mask fw flowid 1:$class_index 2>/dev/null || true
                    
                tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
                    prio 2 handle ${class_mark_hex}/$upload_mask fw flowid 1:$class_index 2>/dev/null || true
            fi
        fi
        class_index=$((class_index + 1))
    done
    
    # 设置默认类别
    set_default_upload_class
    
    qos_log "INFO" "上传方向HFSC初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========
initialize_hfsc_download() {
    qos_log "INFO" "初始化下载方向HFSC"
    
    # 加载下载类别配置
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        qos_log "WARN" "未找到下载类别配置，使用默认类别"
        create_default_download_class
        return 0
    fi
    
    # 从配置获取IFB设备名称
    local ifb_device=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    if [ -z "$ifb_device" ]; then
        qos_log "ERROR" "IFB设备名称未配置"
        return 1
    fi
    
    # 确保IFB设备已启动
    if ! ip link show dev "$ifb_device" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $ifb_device 不存在"
        return 1
    fi
    
    if ! ip link set dev "$ifb_device" up; then
        qos_log "ERROR" "无法启动IFB设备 $ifb_device"
        return 1
    fi
    
    # 创建根队列
    if ! create_hfsc_root_qdisc "$ifb_device" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    local priority=3
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        if create_hfsc_download_class "$class_name" "$class_index" "$priority"; then
            local class_mark_hex=""
            
            # 从配置文件获取class_mark
            local config_class_mark=$(uci -q get "${CONFIG_FILE}.${class_name}.class_mark" 2>/dev/null)
            if [ -n "$config_class_mark" ] && [ "$config_class_mark" != "0x0" ]; then
                class_mark_hex="$config_class_mark"
                qos_log "INFO" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                # 否则使用自动计算的值
                local mark_value=$((class_index << download_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                qos_log "INFO" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            # 添加标记到列表
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                # 从配置获取掩码
                local download_mask=$(uci -q get "${CONFIG_FILE}.download.download_mask" 2>/dev/null)
                if [ -z "$download_mask" ]; then
                    download_mask="0x7F00"
                fi
                
                if ! tc filter add dev "$ifb_device" parent 1:0 protocol ip \
                    prio $priority handle ${class_mark_hex}/$download_mask fw flowid 1:$class_index 2>/dev/null; then
                    qos_log "WARN" "添加下载IPv4过滤器失败 (类别: $class_name)"
                fi
                
                if ! tc filter add dev "$ifb_device" parent 1:0 protocol ipv6 \
                    prio $((priority + 1)) handle ${class_mark_hex}/$download_mask fw flowid 1:$class_index 2>/dev/null; then
                    qos_log "WARN" "添加下载IPv6过滤器失败 (类别: $class_name)"
                fi
            fi
        fi
        class_index=$((class_index + 1))
        priority=$((priority + 2))
    done
    
    # 设置默认类别
    set_default_download_class
    
    # 设置入口重定向
    if ! setup_ingress_redirect; then
        qos_log "ERROR" "设置入口重定向失败"
        return 1
    fi
    
    qos_log "INFO" "下载方向HFSC初始化完成"
    return 0
}

# 设置上传默认类别
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
    tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default $found_index 2>/dev/null || true
    qos_log "INFO" "上传默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

# 设置下载默认类别
set_default_download_class() {
    qos_log "INFO" "设置下载默认类别"
    
    local default_class_name=$(uci -q get qos_gargoyle.download.default_class 2>/dev/null)
    if [ -z "$default_class_name" ]; then
        qos_log "ERROR" "下载默认类别未配置"
        return
    fi
    
    qos_log "INFO" "用户配置的下载默认类别名称: $default_class_name"
    
    # 从配置获取IFB设备名称
    local ifb_device=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    if [ -z "$ifb_device" ]; then
        qos_log "ERROR" "IFB设备名称未配置"
        return
    fi
    
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
    tc qdisc change dev "$ifb_device" root handle 1:0 hfsc default $found_index 2>/dev/null || true
    qos_log "INFO" "下载默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

# 应用HFSC特定增强规则
apply_hfsc_specific_rules() {
    qos_log "INFO" "应用HFSC特定增强规则"
    
    # HFSC优先级设置
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        meta mark and 0x007f != 0 counter meta priority set "bulk" 2>/dev/null || true
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        meta mark and 0x7f00 != 0 counter meta priority set "bulk" 2>/dev/null || true
    
    # HFSC连接跟踪优化
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        ct state established,related counter meta mark set ct mark 2>/dev/null || true
    
    qos_log "INFO" "HFSC特定增强规则应用完成"
}

# 主初始化函数
initialize_hfsc_qos() {
    qos_log "INFO" "开始初始化HFSC QoS系统"
    
    # 1. 加载HFSC与fq_codel专属配置
    if ! load_hfsc_config; then
        qos_log "ERROR" "加载HFSC配置失败"
        return 1
    fi
    
    # 2. 设置IPv6特定规则
    setup_ipv6_specific_rules
    
    # 3. 初始化上传方向
    if [ "$total_upload_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_hfsc_upload; then
            qos_log "ERROR" "上传方向初始化失败"
            return 1
        fi
    else
        qos_log "ERROR" "上传带宽未配置"
        return 1
    fi
    
    # 4. 初始化下载方向
    if [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
        if ! initialize_hfsc_download; then
            qos_log "ERROR" "下载方向初始化失败"
            return 1
        fi
    else
        qos_log "ERROR" "下载带宽未配置"
        return 1
    fi
    
    # 5. 应用HFSC特定的nftables规则
    apply_hfsc_specific_rules
    
    qos_log "INFO" "HFSC QoS初始化完成"
    return 0
}

# ========== 停止和清理函数 ==========
stop_hfsc_qos() {
    qos_log "INFO" "停止HFSC QoS"
    
    # 从配置获取IFB设备名称
    local ifb_device=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    
    # 清理上传方向
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "hfsc"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        qos_log "INFO" "清理上传方向HFSC队列"
    fi
    
    # 清理下载方向
    if [ -n "$ifb_device" ]; then
        if tc qdisc show dev "$ifb_device" 2>/dev/null | grep -q "hfsc"; then
            tc qdisc del dev "$ifb_device" root 2>/dev/null
            qos_log "INFO" "清理下载方向HFSC队列"
        fi
    fi
    
    # 清理NFTables规则
    nft delete chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
    
    # 清理入口队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    
    # 停用IFB设备
    if [ -n "$ifb_device" ]; then
        if ip link show dev "$ifb_device" >/dev/null 2>&1; then
            ip link set dev "$ifb_device" down
            qos_log "INFO" "停用IFB设备: $ifb_device"
        fi
    fi
    
    # 清理连接标记
    conntrack -U --mark 0 2>/dev/null || true
    
    qos_log "INFO" "HFSC QoS停止完成"
}

# ========== 状态查询函数 ==========
show_hfsc_status() {
    # 确保必要的变量已设置
    local qos_ifb="${IFB_DEVICE:-ifb0}"
    local mark_dir="/etc/qos_gargoyle"
    local upload_marks_file="$mark_dir/upload_class_marks"
    local download_marks_file="$mark_dir/download_class_marks"
    
    # 如果接口未定义，尝试获取
    if [ -z "$qos_interface" ]; then
        # 尝试从TC输出推断接口
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "hfsc.*root" | awk '{print $5}' | head -1)
        [ -z "$qos_interface" ] && qos_interface="未知"
    fi
    
    echo "===== HFSC-FQ_CODEL QoS 状态报告 ====="
    echo "时间: $(date)"
    echo "WAN接口: ${qos_interface}"
    
    # 检查QoS是否实际运行
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q hfsc; then
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
        if echo "$line" | grep -q "hfsc\|fq_codel"; then
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
    
    # 显示入口配置
    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "hfsc\|fq_codel"; then
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
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "hfsc"; then
        upload_active=1
        echo "上传QoS: 已启用 (HFSC+fq_codel)"
        
        # 显示上传带宽配置
        tc -s class show dev "$qos_interface" 2>/dev/null | grep "m2" | while read -r line; do
            echo "  $line"
        done
    else
        echo "上传QoS: 未启用"
    fi
    
    # 检查下载QoS
    if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "hfsc"; then
        download_active=1
        echo -e "\n下载QoS: 已启用 (HFSC+fq_codel)"
        
        # 显示下载带宽配置
        tc -s class show dev "$qos_ifb" 2>/dev/null | grep "m2" | while read -r line; do
            echo "  $line"
        done
    else
        echo -e "\n下载QoS: 未启用"
    fi
    
    # 总体状态
    if [ "$upload_active" -eq 1 ] && [ "$download_active" -eq 1 ]; then
        echo -e "\n✓ QoS双向流量整形已启用 (HFSC+fq_codel)"
    elif [ "$upload_active" -eq 1 ]; then
        echo -e "\n⚠ 仅上传QoS已启用 (HFSC+fq_codel)"
    elif [ "$download_active" -eq 1 ]; then
        echo -e "\n⚠ 仅下载QoS已启用 (HFSC+fq_codel)"
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
	
	# 显示活动连接标记
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
            # 使用 awk 精确提取原始方向（第一个方向）的字段
            local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
            local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
            local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
            local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
            local proto=$(echo "$line" | awk '{print $1}')
            # 提取十进制标记并转换为十六进制
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
            # 提取字段（针对 IPv6）
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
            # 提取原始方向字段（这是上传流量，原始方向的 src 是 WAN IP）
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
    
    echo -e "\n===== HFSC-FQ_CODEL 状态报告结束 ====="
    
    return 0
}


# ========== 主程序入口 ==========
main_hfsc_qos() {
    local action="$1"
    
    case "$action" in
        "start")
            if ! initialize_hfsc_qos; then
                qos_log "ERROR" "HFSC QoS启动失败"
                exit 1
            fi
            ;;
        "stop")
            stop_hfsc_qos
            ;;
        "restart")
            stop_hfsc_qos
            sleep 1
            if ! initialize_hfsc_qos; then
                qos_log "ERROR" "HFSC QoS重启失败"
                exit 1
            fi
            ;;
        "status")
            show_hfsc_status
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status}"
            echo ""
            echo "命令:"
            echo "  start        启动HFSC QoS"
            echo "  stop         停止HFSC QoS"
            echo "  restart      重启HFSC QoS"
            echo "  status       显示状态"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "hfsc-qos.sh" ]; then
    main_hfsc_qos "$1"
fi