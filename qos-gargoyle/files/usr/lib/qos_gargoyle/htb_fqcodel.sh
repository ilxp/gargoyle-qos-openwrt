#!/bin/sh
# HTB_FQCODEL算法实现模块
# 基于HTB与FQ_CODEL组合算法实现QoS流量控制。
# version=1.0 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

# ========== 变量初始化 ==========
# 确保变量只在使用前才设置默认值
: ${upload_shift:=0}
: ${download_shift:=8}
: ${UPLOAD_MASK:=0x007F}
: ${DOWNLOAD_MASK:=0x7F00}
: ${total_upload_bandwidth:=40000}
: ${total_download_bandwidth:=95000}
: ${CONFIG_FILE:=qos_gargoyle}
: ${IFB_DEVICE:=ifb0}

# 全局变量声明
upload_class_list=""
download_class_list=""
upload_class_mark_list=""
download_class_mark_list=""

# 如果 qos_interface 未设置，尝试获取
if [ -z "$qos_interface" ]; then
    # 尝试从 UCI 配置读取
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    
    # 如果配置中没有，尝试系统检测
    if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
        . /lib/functions/network.sh
        network_find_wan qos_interface
    fi
    
    # 设置默认值
    qos_interface="${qos_interface:-pppoe-wan}"
fi

echo "HTB 模块初始化完成"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"

# 加载必要的库
. /lib/functions.sh
. /lib/functions/network.sh
include /lib/network

# 加载公共规则辅助模块
if [ -f "/usr/lib/qos_gargoyle/rule.sh" ]; then
    . /usr/lib/qos_gargoyle/rule.sh
    logger -t "qos_gargoyle" "已加载规则辅助模块"
else
    logger -t "qos_gargoyle" "警告: 规则辅助模块未找到"
fi

# 加载dba_conf.sh模块
if [ -f "/usr/lib/qos_gargoyle/dba_conf.sh" ]; then
    . /usr/lib/qos_gargoyle/dba_conf.sh
    logger -t "qos_gargoyle" "已加载dba_conf配置模块"
else
    logger -t "qos_gargoyle" "警告: 未找到dba_conf.sh模块"
fi

# ========= HTB与fq_codel专属常量 ==========
HTB_PRIOMAP_ENABLED="1"
HTB_DRR_QUANTUM="auto"
# fq_codel 默认参数
FQCODEL_LIMIT="10240"
FQCODEL_INTERVAL="100000"
FQCODEL_TARGET="5000"
FQCODEL_FLOWS="1024"
FQCODEL_QUANTUM="1514"
FQCODEL_ECN=""

# ========== 配置加载函数 ==========

# 加载带宽配置
load_bandwidth_from_config() {
    logger -t "qos_gargoyle" "加载带宽配置"
    
    # 读取上传总带宽
    config_upload_bw=$(uci -q get qos_gargoyle.upload.total_bandwidth 2>/dev/null)
    if [ -n "$config_upload_bw" ] && [ "$config_upload_bw" -gt 0 ] 2>/dev/null; then
        total_upload_bandwidth="$config_upload_bw"
        logger -t "qos_gargoyle" "从配置文件读取上传总带宽: ${total_upload_bandwidth}kbit/s"
    else
        logger -t "qos_gargoyle" "使用默认上传总带宽: ${total_upload_bandwidth}kbit/s"
    fi

    # 读取下载总带宽
    config_download_bw=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    if [ -n "$config_download_bw" ] && [ "$config_download_bw" -gt 0 ] 2>/dev/null; then
        total_download_bandwidth="$config_download_bw"
        logger -t "qos_gargoyle" "从配置文件读取下载总带宽: ${total_download_bandwidth}kbit/s"
    else
        logger -t "qos_gargoyle" "使用默认下载总带宽: ${total_download_bandwidth}kbit/s"
    fi
}

calculate_memory_limit() {
    local config_value="$1"
    local total_mem_kb=$(grep -E '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    local result

    # 如果用户明确指定了 'auto' 或配置为空，则自动计算
    if [ -z "$config_value" ] || [ "$config_value" = "auto" ]; then
        if [ -n "$total_mem_kb" ] && [ "$total_mem_kb" -gt 0 ]; then
            if [ "$total_mem_kb" -lt 128000 ]; then
                result="4Mb"  # < 128MB RAM
            elif [ "$total_mem_kb" -lt 256000 ]; then
                result="8Mb"   # < 256MB RAM
            elif [ "$total_mem_kb" -lt 512000 ]; then
                result="16Mb"   # < 512MB RAM
            else
                result="32Mb"   # > 512MB RAM
            fi
            logger -t "qos_gargoyle" "系统内存 ${total_mem_kb}KB，自动计算 memory_limit=${result}"
        else
            logger -t "qos_gargoyle" "警告: 无法读取内存信息，使用保守默认值 16Mb"
            result="16Mb"
        fi
    else
        # 用户提供了具体值，直接使用（格式验证在调用前完成）
        result="$config_value"
    fi
    echo "$result"
}

# 加载HTB与fq_codel专属配置
load_htb_config() {
    logger -t "qos_gargoyle" "加载HTB与fq_codel配置"
    
    # 加载带宽配置
    load_bandwidth_from_config
    
    # 从UCI配置读取HTB特定参数
    HTB_PRIOMAP_ENABLED=$(uci -q get qos_gargoyle.htb.priomap_enabled 2>/dev/null)
    HTB_PRIOMAP_ENABLED="${HTB_PRIOMAP_ENABLED:-1}"
    
    HTB_DRR_QUANTUM=$(uci -q get qos_gargoyle.htb.drr_quantum 2>/dev/null)
    HTB_DRR_QUANTUM="${HTB_DRR_QUANTUM:-auto}"
    
    # 从UCI配置读取fq_codel参数
    FQCODEL_LIMIT=$(uci -q get qos_gargoyle.fq_codel.limit 2>/dev/null)
    FQCODEL_LIMIT="${FQCODEL_LIMIT:-10240}"
    
    FQCODEL_INTERVAL=$(uci -q get qos_gargoyle.fq_codel.interval 2>/dev/null)
    FQCODEL_INTERVAL="${FQCODEL_INTERVAL:-100000}"    # 单位：微秒
    
    FQCODEL_TARGET=$(uci -q get qos_gargoyle.fq_codel.target 2>/dev/null)
    FQCODEL_TARGET="${FQCODEL_TARGET:-5000}"          # 单位：微秒
      
    FQCODEL_FLOWS=$(uci -q get qos_gargoyle.fq_codel.flows 2>/dev/null)
    FQCODEL_FLOWS="${FQCODEL_FLOWS:-1024}"
    
    FQCODEL_QUANTUM=$(uci -q get qos_gargoyle.fq_codel.quantum 2>/dev/null)
    FQCODEL_QUANTUM="${FQCODEL_QUANTUM:-1514}"
    
	# === 读取 memory_limit 参数 ===
	# 1. 从UCI读取原始配置值
    local mem_limit_config=$(uci -q get qos_gargoyle.fq_codel.memory_limit 2>/dev/null)
    
    # 2. （可选）在调用计算函数前进行基础格式验证
    if [ -n "$mem_limit_config" ] && [ "$mem_limit_config" != "auto" ]; then
        if ! echo "$mem_limit_config" | grep -qiE '^[0-9]+(\.[0-9]+)?[KMGT]?[Bb]?$'; then
            logger -t "qos_gargoyle" "警告: memory_limit 配置值 '$mem_limit_config' 格式无效，将按 'auto' 处理"
            mem_limit_config="auto"
        fi
    fi

    # 3. 调用函数获取最终值
    FQCODEL_MEMORY_LIMIT=$(calculate_memory_limit "$mem_limit_config")
    
    # 4. 记录最终决定使用的值
    logger -t "qos_gargoyle" "最终确定的 fq_codel memory_limit: ${FQCODEL_MEMORY_LIMIT}"

    # === 读取 ce_threshold 参数 ===
    FQCODEL_CE_THRESHOLD=$(uci -q get qos_gargoyle.fq_codel.ce_threshold 2>/dev/null)
    # 默认值为 0，即不主动启用此特性。配置示例：1ms, 5ms
    FQCODEL_CE_THRESHOLD="${FQCODEL_CE_THRESHOLD:-0}"
    # 验证格式（支持 0, 1ms, 5.5ms, 1000us）
    if ! echo "$FQCODEL_CE_THRESHOLD" | grep -qiE '^0$|^[0-9]+(\.[0-9]+)?(us|ms)$'; then
        logger -t "qos_gargoyle" "警告: 无效的 ce_threshold 格式 '$FQCODEL_CE_THRESHOLD'，使用默认值 0"
        FQCODEL_CE_THRESHOLD="0"
    fi
	
    # 处理ecn参数
    FQCODEL_ECN=$(uci -q get qos_gargoyle.fq_codel.ecn 2>/dev/null)
    if [ -n "$FQCODEL_ECN" ]; then
        case "$FQCODEL_ECN" in
            yes|1|enable|on|true)
                FQCODEL_ECN="ecn"
                logger -t "qos_gargoyle" "fq_codel ECN: 启用 (yes -> ecn)"
                ;;
            no|0|disable|off|false)
                FQCODEL_ECN="noecn"
                logger -t "qos_gargoyle" "fq_codel ECN: 禁用 (no -> noecn)"
                ;;
            ecn|noecn)
                # 保持原样
                logger -t "qos_gargoyle" "fq_codel ECN: 使用配置值 ($FQCODEL_ECN)"
                ;;
            *)
                logger -t "qos_gargoyle" "警告: 无效的ECN配置值 '$FQCODEL_ECN'，将不使用ECN"
                FQCODEL_ECN=""
                ;;
        esac
    else
        FQCODEL_ECN=""
        logger -t "qos_gargoyle" "fq_codel ECN: 未配置，将不使用ECN"
    fi
    
    # 处理DRR quantum参数
    if [ "$HTB_DRR_QUANTUM" = "auto" ]; then
        # 根据MTU自动计算quantum
        local mtu=$(cat /sys/class/net/pppoe-wan/mtu 2>/dev/null || echo 1500)
        HTB_DRR_QUANTUM=$((mtu + 100))
    fi
    
    logger -t "qos_gargoyle" "HTB配置: 优先级映射=${HTB_PRIOMAP_ENABLED}, DRR quantum=${HTB_DRR_QUANTUM}"
    logger -t "qos_gargoyle" "fq_codel参数: limit=${FQCODEL_LIMIT}, interval=${FQCODEL_INTERVAL}ms, target=${FQCODEL_TARGET}ms, flows=${FQCODEL_FLOWS}, quantum=${FQCODEL_QUANTUM}, memory_limit=${FQCODEL_MEMORY_LIMIT}, ce_threshold=${FQCODEL_CE_THRESHOLD}, ecn=${FQCODEL_ECN:-未配置}"
}

# 加载HTB类别配置
load_htb_class_config() {
    local class_name="$1"
    
    logger -t "qos_gargoyle" "加载HTB类别配置: $class_name"
    
    # 清空所有相关变量
    unset percent_bandwidth per_min_bandwidth per_max_bandwidth minRTT priority name class_mark
    
    # 直接通过UCI读取HTB类别配置
    percent_bandwidth=$(uci -q get qos_gargoyle.$class_name.percent_bandwidth 2>/dev/null)
    per_min_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_min_bandwidth 2>/dev/null)
    per_max_bandwidth=$(uci -q get qos_gargoyle.$class_name.per_max_bandwidth 2>/dev/null)
    minRTT=$(uci -q get qos_gargoyle.$class_name.minRTT 2>/dev/null)
    priority=$(uci -q get qos_gargoyle.$class_name.priority 2>/dev/null)
    name=$(uci -q get qos_gargoyle.$class_name.name 2>/dev/null)
    
    # 调试日志
    logger -t "qos_gargoyle" "HTB配置: $class_name -> percent=$percent_bandwidth, min=$per_min_bandwidth, max=$per_max_bandwidth, minRTT=$minRTT"
    
    # 验证是否加载了关键参数
    if [ -z "$percent_bandwidth" ] && [ -z "$per_min_bandwidth" ] && [ -z "$per_max_bandwidth" ]; then
        logger -t "qos_gargoyle" "警告: 未找到 $class_name 的带宽参数"
        return 1
    fi
    
    return 0
}

# 加载上传类别配置
load_upload_class_configurations() {
    logger -t "qos_gargoyle" "正在加载上传类别配置..."
    
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
        logger -t "qos_gargoyle" "找到上传类别: $upload_class_list"
    else
        logger -t "qos_gargoyle" "警告: 没有找到上传类别配置"
        upload_class_list=""
    fi
    
    return 0
}

# 加载下载类别配置
load_download_class_configurations() {
    logger -t "qos_gargoyle" "正在加载下载类别配置..."
    
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
        logger -t "qos_gargoyle" "找到下载类别: $download_class_list"
    else
        logger -t "qos_gargoyle" "警告: 没有找到下载类别配置"
        download_class_list=""
    fi
    
    return 0
}

# 读取标记文件
read_mark_from_file() {
    local class_name="$1"      # 类别名称 (如: upload_class_1, download_class_1)
    local direction="$2"       # 方向: "upload" 或 "download"
    local mark_file=""
    local class_pattern=""
    
    # 根据方向选择文件
    if [ "$direction" = "upload" ]; then
        mark_file="/etc/qos_gargoyle/upload_class_marks"
        # 支持多种类别名称格式
        if echo "$class_name" | grep -q "^upload_class_"; then
            class_pattern="u${class_name#upload_class_}"
        elif echo "$class_name" | grep -q "^uclass_"; then
            class_pattern="${class_name#uclass_}"
        else
            class_pattern="$class_name"
        fi
    elif [ "$direction" = "download" ]; then
        mark_file="/etc/qos_gargoyle/download_class_marks"
        # 支持多种类别名称格式
        if echo "$class_name" | grep -q "^download_class_"; then
            class_pattern="d${class_name#download_class_}"
        elif echo "$class_name" | grep -q "^dclass_"; then
            class_pattern="${class_name#dclass_}"
        else
            class_pattern="$class_name"
        fi
    else
        logger -t "qos_gargoyle" "错误: 未知方向: $direction"
        echo ""
        return 1
    fi
    
    # 检查文件是否存在
    if [ ! -f "$mark_file" ]; then
        logger -t "qos_gargoyle" "错误: 标记文件不存在: $mark_file"
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
            logger -t "qos_gargoyle" "警告: 读取的标记格式不正确: $mark"
        fi
    fi
    
    # 如果文件中没有找到，返回空值
    logger -t "qos_gargoyle" "错误: 在 $mark_file 中未找到 $direction:$class_name 的标记"
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

# 设置IPv6特定规则（关键流量高优先级）
setup_ipv6_specific_rules() {
    logger -t "qos_gargoyle" "设置IPv6特定规则"
    
    # ICMPv6关键类型（邻居发现、路由通告等）
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    
    # 使用nftables设置IPv6关键流量标记
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } \
        meta mark set 0x7F counter
    
    # DHCPv6流量（UDP 546/547）
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } \
        meta mark set 0x7F counter
    
    # IPv6多播流量（ff00::/8）
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ff00::/8 \
        meta mark set 0x3F counter
    
    logger -t "qos_gargoyle" "IPv6关键流量规则设置完成"
}

# ========== HTB核心队列函数 ==========

# 创建HTB根队列
create_htb_root_qdisc() {
    local device="$1"
    local direction="$2"  # upload 或 download
    local root_handle="$3"  # 1:0 或 2:0
    local root_classid="$4"  # 1:1 或 2:1
    
    # 根据方向获取带宽
    local bandwidth=""
    if [ "$direction" = "upload" ]; then
        bandwidth="${total_upload_bandwidth}"
    elif [ "$direction" = "download" ]; then
        bandwidth="${total_download_bandwidth}"
    else
        logger -t "qos_gargoyle" "错误: 未知方向: $direction"
        return 1
    fi
    
    logger -t "qos_gargoyle" "为$device创建$direction方向HTB根队列 (带宽: ${bandwidth}kbit)"
    
    # 删除现有队列
    tc qdisc del dev "$device" root 2>/dev/null || true
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    
    # 创建HTB根队列
    echo "正在为 $device 创建 HTB 根队列..."
    if ! tc qdisc add dev "$device" root handle $root_handle htb default 1 r2q 10; then
        logger -t "qos_gargoyle" "错误: 无法在 $device 上创建HTB根队列"
        return 1
    fi
    
    # 创建根类
    echo "正在为 $device 创建 HTB 根类..."
    if ! tc class add dev "$device" parent 1:0 classid 1:1 htb \
        rate ${bandwidth}kbit ceil ${bandwidth}kbit burst 15k cburst 15k; then
        logger -t "qos_gargoyle" "错误: 无法在$device上创建HTB根类"
        echo "错误: 无法在 $device 上创建 HTB 根类"
        return 1
    fi
    
    logger -t "qos_gargoyle" "$device的$direction方向HTB根队列创建完成"
    echo "$device 的 $direction 方向 HTB 根队列创建完成"
    return 0
}

# 计算HTB参数
calculate_htb_parameters() {
    local class_name="$1"
    local direction="$2"  # upload 或 download
    
    # 获取方向总带宽
    local total_bandwidth=0
    if [ "$direction" = "upload" ]; then
        total_bandwidth=$total_upload_bandwidth
    else
        total_bandwidth=$total_download_bandwidth
    fi
    
    # 计算类别总带宽（基于总带宽的百分比）
    local class_total_bw=0
    if [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        if [ -n "$total_bandwidth" ] && [ "$total_bandwidth" -gt 0 ] 2>/dev/null; then
            class_total_bw=$((total_bandwidth * percent_bandwidth / 100))
            logger -t "qos_gargoyle" "类别 $class_name 总带宽: ${class_total_bw}kbit (${percent_bandwidth}% of ${total_bandwidth}kbit)"
        else
            class_total_bw=$total_bandwidth
            logger -t "qos_gargoyle" "警告: total_${direction}_bandwidth无效，使用默认值: $class_total_bw kbit"
        fi
    else
        class_total_bw=$total_bandwidth
        logger -t "qos_gargoyle" "类别 $class_name 使用总带宽作为类别总带宽: $class_total_bw kbit"
    fi
    
    # 计算rate（保证带宽）：基于类别总带宽的百分比
    local rate=""
    if [ -n "$per_min_bandwidth" ] && [ "$per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$per_min_bandwidth" -eq 0 ]; then
            rate="1kbit"  # 最小保证带宽，不能为0
            logger -t "qos_gargoyle" "类别 $class_name 设置最小保证带宽: $rate (per_min_bandwidth=0)"
        else
            rate="$((class_total_bw * per_min_bandwidth / 100))kbit"
            logger -t "qos_gargoyle" "类别 $class_name 使用百分比计算保证带宽: $rate (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        # 默认保证带宽为类别总带宽的50%
        rate="$((class_total_bw * 50 / 100))kbit"
        logger -t "qos_gargoyle" "类别 $class_name 使用默认保证带宽: $rate (50% of ${class_total_bw}kbit)"
    fi
    
    # 计算ceil（最大带宽）：基于类别总带宽的百分比
    local ceil=""
    if [ -n "$per_max_bandwidth" ] && [ "$per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        ceil="$((class_total_bw * per_max_bandwidth / 100))kbit"
        logger -t "qos_gargoyle" "类别 $class_name 使用百分比计算上限带宽: $ceil (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ceil="${class_total_bw}kbit"
        logger -t "qos_gargoyle" "类别 $class_name 使用类别总带宽作为上限带宽: $ceil"
    fi
    
    # 验证rate不超过ceil
    local rate_value=$(echo "$rate" | sed 's/kbit//')
    local ceil_value=$(echo "$ceil" | sed 's/kbit//')
    
    if [ "$rate_value" -gt "$ceil_value" ]; then
        logger -t "qos_gargoyle" "警告: 类别 $class_name 保证带宽($rate)超过上限带宽($ceil)，调整为上限带宽"
        rate="$ceil"
        rate_value=$ceil_value
    fi
    
    # 计算burst和cburst
    # HTB的burst和cburst计算公式：burst = rate * 1ms
    # 这里我们使用更保守的计算
    local burst=""
    local cburst=""
    
    # burst通常为rate * 1ms的字节数
    burst="$((rate_value * 1000 / 8 / 1000))"
    if [ "$burst" -lt 1 ]; then
        burst=1
    fi
    burst="${burst}kb"
    
    # cburst通常是burst的2倍
    cburst="$((rate_value * 1000 / 8 / 500))"
    if [ "$cburst" -lt 2 ]; then
        cburst=2
    fi
    cburst="${cburst}kb"
    
    # 调整最小burst大小
    if [ "$burst" = "0kb" ]; then
        burst="1kb"
    fi
    if [ "$cburst" = "0kb" ]; then
        cburst="2kb"
    fi
    
    logger -t "qos_gargoyle" "HTB参数计算完成: rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst"
    
    echo "$rate $ceil $burst $cburst"
}

# 创建HTB上传类别 (使用fq_codel叶队列)
create_htb_upload_class() {
    local class_name="$1"
    local class_index="$2"
    
    logger -t "qos_gargoyle" "创建上传类别: $class_name, ID: 1:$class_index"
    
    # 加载HTB类别配置
    if ! load_htb_class_config "$class_name"; then
        logger -t "qos_gargoyle" "警告: 加载HTB配置失败，使用默认值"
    fi
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "upload")
    
    if [ -z "$class_mark" ]; then
        # 使用回退计算
        class_mark=$(calculate_fallback_mark "upload" "$class_index" "$class_name")
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取上传标记: $class_mark"
    fi
    
    # ========== 计算HTB参数 ==========
    local htb_params=$(calculate_htb_parameters "$class_name" "upload")
    local rate=$(echo "$htb_params" | awk '{print $1}')
    local ceil=$(echo "$htb_params" | awk '{print $2}')
    local burst=$(echo "$htb_params" | awk '{print $3}')
    local cburst=$(echo "$htb_params" | awk '{print $4}')
    
    # 如果有优先级设置
    local prio=""
    if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
        prio="prio $priority"
    else
        # 默认优先级
        prio="prio 3"
    fi
    
    # 如果是最小延迟类别
    if [ "${minRTT:-No}" = "Yes" ]; then
        prio="prio 1"  # 最高优先级
        logger -t "qos_gargoyle" "类别 $class_name 设置为最高优先级(prio 1)"
    fi
    
    # 创建HTB类别
    logger -t "qos_gargoyle" "正在创建上传HTB类别 1:$class_index (rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst, $prio)"
    
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        logger -t "qos_gargoyle" "错误: 创建上传类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM} memory_limit ${FQCODEL_MEMORY_LIMIT} ce_threshold ${FQCODEL_CE_THRESHOLD}"
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    logger -t "qos_gargoyle" "添加上传fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params; then
        logger -t "qos_gargoyle" "错误: 添加上传fq_codel队列失败"
        return 1
    fi
    
    # 添加过滤器（如果配置了标记）
    if [ "$class_mark" != "0x0" ]; then
        # IPv4过滤器
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加上传IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加上传IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((class_index + 100))
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加上传IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加上传IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # 启用优先级映射
        if [ "$HTB_PRIOMAP_ENABLED" = "1" ]; then
            # 为高优先级类别添加优先级映射
            if [ "${minRTT:-No}" = "Yes" ]; then
                logger -t "qos_gargoyle" "为最小延迟类别启用优先级映射: $class_name"
            fi
        fi
    fi
    
    logger -t "qos_gargoyle" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, rate=$rate, ceil=$ceil, priority=$prio)"
    return 0
}

# 创建HTB下载类别 (使用fq_codel叶队列)
create_htb_download_class() {
    local class_name="$1"
    local class_index="$2"
    local priority="$3"
    
    logger -t "qos_gargoyle" "创建下载类别: $class_name, ID: 1:$class_index, 优先级: $priority"
    
    # 加载HTB类别配置
    if ! load_htb_class_config "$class_name"; then
        logger -t "qos_gargoyle" "警告: 加载HTB配置失败，使用默认值"
    fi
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "download")
    
    if [ -z "$class_mark" ]; then
        # 使用回退计算
        class_mark=$(calculate_fallback_mark "download" "$class_index" "$class_name")
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取下载标记: $class_mark"
    fi
    
    # ========== 【修复】计算HTB参数 ==========
    local htb_params=$(calculate_htb_parameters "$class_name" "download")
    local rate=$(echo "$htb_params" | awk '{print $1}')
    local ceil=$(echo "$htb_params" | awk '{print $2}')
    local burst=$(echo "$htb_params" | awk '{print $3}')
    local cburst=$(echo "$htb_params" | awk '{print $4}')
    
    # 如果有优先级设置
    local prio=""
    if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
        prio="prio $priority"
    else
        # 使用配置中的优先级
        if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
            prio="prio $priority"
        else
            prio="prio 3"
        fi
    fi
    
    # 如果是最小延迟类别
    if [ "${minRTT:-No}" = "Yes" ]; then
        prio="prio 1"  # 最高优先级
        logger -t "qos_gargoyle" "类别 $class_name 设置为最高优先级(prio 1)"
    fi
    
    # 创建HTB类别
    logger -t "qos_gargoyle" "正在创建下载HTB类别 1:$class_index (rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst, $prio)"
    
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        logger -t "qos_gargoyle" "错误: 创建下载类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM} memory_limit ${FQCODEL_MEMORY_LIMIT} ce_threshold ${FQCODEL_CE_THRESHOLD}"
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    logger -t "qos_gargoyle" "添加下载fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params; then
        logger -t "qos_gargoyle" "错误: 添加下载fq_codel队列失败"
        return 1
    fi
    
    # 添加过滤器（如果配置了标记）
    if [ "$class_mark" != "0x0" ]; then
        # 下载过滤器使用优先级参数
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
            prio $priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加下载IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((priority + 100))
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # 处理IPv4-mapped IPv6地址的过滤器
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
            u32 match ip6 dst ::ffff:0:0/96 \
            action connmark set $class_mark \
            flowid 1:$class_index; then
            logger -t "qos_gargoyle" "警告: 添加IPv4-mapped IPv6过滤器失败 (类别: $class_name)"
        fi
        
        # 启用优先级映射
        if [ "$HTB_PRIOMAP_ENABLED" = "1" ]; then
            # 为高优先级类别添加优先级映射
            if [ "${minRTT:-No}" = "Yes" ]; then
                logger -t "qos_gargoyle" "为最小延迟类别启用优先级映射: $class_name"
            fi
        fi
    fi
    
    logger -t "qos_gargoyle" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, rate=$rate, ceil=$ceil, priority=$prio)"
    return 0
}

# 创建默认上传类别 (使用fq_codel叶队列)
create_default_upload_class() {
    logger -t "qos_gargoyle" "创建默认上传类别"
    
    # 首先创建根队列
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建默认类别（类ID为1:2）
    local rate="$((total_upload_bandwidth * 80 / 100))kbit"  # 默认使用80%带宽
    local ceil="${total_upload_bandwidth}kbit"
    local burst="5kb"
    local cburst="10kb"
    
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:2 htb rate $rate ceil $ceil burst $burst cburst $cburst prio 4; then
        logger -t "qos_gargoyle" "错误: 创建上传类 1:2 失败"
        return 1
    fi
    
    # 添加fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM} memory_limit ${FQCODEL_MEMORY_LIMIT} ce_threshold ${FQCODEL_CE_THRESHOLD}"
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    logger -t "qos_gargoyle" "添加上传默认fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$qos_interface" parent 1:2 \
        handle 2:1 fq_codel $fq_codel_params; then
        logger -t "qos_gargoyle" "错误: 添加上传默认fq_codel队列失败"
        return 1
    fi
    
    # 添加过滤器（将标记为0x1的流量导向该类）
    local mark_hex="0x1"
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加上传IPv4过滤器失败"
    fi
    
    # IPv6过滤器
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加上传IPv6过滤器失败"
    fi
    
    upload_class_mark_list="default_class:$mark_hex"
    logger -t "qos_gargoyle" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex, rate=$rate, ceil=$ceil)"
    return 0
}

# 创建默认下载类别 (使用fq_codel叶队列)
create_default_download_class() {
    logger -t "qos_gargoyle" "创建默认下载类别"
    
    # 确保IFB设备存在并已启动
    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        logger -t "qos_gargoyle" "错误: IFB设备 $IFB_DEVICE 不存在"
        return 1
    fi
    
    if ! ip link set dev "$IFB_DEVICE" up; then
        logger -t "qos_gargoyle" "错误: 无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    
    # 首先创建根队列
    if ! create_htb_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建默认类别（类ID为1:2）
    local rate="$((total_download_bandwidth * 80 / 100))kbit"  # 默认使用80%带宽
    local ceil="${total_download_bandwidth}kbit"
    local burst="5kb"
    local cburst="10kb"
    
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:2 htb rate $rate ceil $ceil burst $burst cburst $cburst prio 4; then
        logger -t "qos_gargoyle" "错误: 创建下载类 1:2 失败"
        return 1
    fi
    
    # 添加fq_codel队列
    local fq_codel_params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM} memory_limit ${FQCODEL_MEMORY_LIMIT} ce_threshold ${FQCODEL_CE_THRESHOLD}"
    if [ -n "$FQCODEL_ECN" ]; then
        fq_codel_params="$fq_codel_params $FQCODEL_ECN"
    fi
    
    logger -t "qos_gargoyle" "添加下载默认fq_codel队列参数: $fq_codel_params"
    
    if ! tc qdisc add dev "$IFB_DEVICE" parent 1:2 \
        handle 2:1 fq_codel $fq_codel_params; then
        logger -t "qos_gargoyle" "错误: 添加下载默认fq_codel队列失败"
        return 1
    fi
    
    # 添加过滤器（将标记为0x100的流量导向该类）
    local mark_hex="0x100"
    if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败"
    fi
    
    # IPv6过滤器
    if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败"
    fi
    
    # 设置入口重定向
    if ! setup_ingress_redirect; then
        logger -t "qos_gargoyle" "警告: 设置入口重定向失败"
    fi
    
    download_class_mark_list="default_class:$mark_hex"
    logger -t "qos_gargoyle" "默认下载类别创建完成 (类ID: 1:2, 标记: $mark_hex, rate=$rate, ceil=$ceil)"
    return 0
}

# ========== 入口重定向相关函数 ==========

# 设置入口重定向
setup_ingress_redirect() {
    # 确保 qos_interface 有值
    if [ -z "$qos_interface" ]; then
        # 从配置获取
        qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
        
        # 如果配置中没有，尝试从系统检测
        if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        
        # 如果还是没有，使用默认值
        qos_interface="${qos_interface:-pppoe-wan}"
    fi
    
    # 确保 IFB_DEVICE 有值
    if [ -z "$IFB_DEVICE" ]; then
        IFB_DEVICE="ifb0"
    fi
    
    # 检查变量是否有效
    if [ -z "$qos_interface" ]; then
        logger -t "qos_gargoyle" "错误: 无法确定 WAN 接口"
        return 1
    fi
    
    if [ -z "$IFB_DEVICE" ]; then
        logger -t "qos_gargoyle" "错误: IFB 设备名称未设置"
        return 1
    fi   
    
    logger -t "qos_gargoyle" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    logger -t "qos_gargoyle" "网络接口: $qos_interface, IFB设备: $IFB_DEVICE"
    
    # 在WAN接口上创建ingress队列
    logger -t "qos_gargoyle" "在 $qos_interface 上创建入口队列..."
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        logger -t "qos_gargoyle" "错误: 无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    # 清除现有的入口过滤器
    logger -t "qos_gargoyle" "清理现有入口过滤器..."
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null
    
    # 重定向所有IPv4流量到IFB设备
    logger -t "qos_gargoyle" "设置IPv4入口重定向规则..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv4入口重定向规则添加失败"
    else
        logger -t "qos_gargoyle" "IPv4入口重定向规则添加成功"
    fi
    
    # 重定向所有IPv6流量到IFB设备
    logger -t "qos_gargoyle" "设置IPv6入口重定向规则..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark pipe \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv6入口重定向规则添加失败"
    else
        logger -t "qos_gargoyle" "IPv6入口重定向规则添加成功"
    fi
    
    # 验证入口重定向配置
    logger -t "qos_gargoyle" "验证入口重定向配置..."
    local ingress_rules=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | wc -l)
    
    if [ "$ingress_rules" -ge 2 ]; then
        logger -t "qos_gargoyle" "入口重定向已成功设置: $qos_interface -> $IFB_DEVICE ($ingress_rules 条规则)"
        logger -t "qos_gargoyle" "入口重定向设置完成"
        
        # 记录当前入口过滤器配置
        local filter_config=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null)
        if [ -n "$filter_config" ]; then
            logger -t "qos_gargoyle" "当前入口过滤器配置: $filter_config"
        else
            logger -t "qos_gargoyle" "当前入口过滤器配置: 无入口过滤器"
        fi
    else
        logger -t "qos_gargoyle" "错误: 入口重定向规则数量不足 ($ingress_rules 条)"
        logger -t "qos_gargoyle" "警告: 入口重定向规则可能未完全设置"
        return 1
    fi
    
    return 0
}

check_ingress_redirect() {
    local iface="$1"
    local ifb_dev="${IFB_DEVICE:-ifb0}"
    echo "检查入口重定向 (接口: $iface, IFB设备: $ifb_dev)"
    
    # 分别检查IPv4和IPv6规则
    echo "  IPv4入口规则:"
    local ipv4_rules=$(tc filter show dev "$iface" parent ffff: protocol ip 2>/dev/null)
    if [ -n "$ipv4_rules" ]; then
        echo "$ipv4_rules" | sed 's/^/    /'
        
        # 检查mirred动作
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
        
        # 检查mirred动作
        if echo "$ipv6_rules" | grep -q "mirred.*Redirect to device $ifb_dev"; then
            echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效"
        else
            # 尝试其他可能的匹配
            if echo "$ipv6_rules" | grep -q "mirred.*Egress Redirect to device $ifb_dev"; then
                echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效 (完整格式)"
            else
                echo "    ✗ IPv6 重定向: mirred动作未找到"
            fi
        fi
    else
        echo "    无IPv6入口规则"
    fi
}

# ========== 上传方向初始化 ==========

initialize_htb_upload() {
    logger -t "qos_gargoyle" "初始化上传方向HTB"
    
    # 加载上传类别配置
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到上传类别配置，使用默认类别"
        create_default_upload_class
        return 0
    fi
    
    logger -t "qos_gargoyle" "找到上传类别：$upload_class_list"
    
    # 创建根队列
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        create_htb_upload_class "$class_name" "$class_index"
        if [ $? -eq 0 ]; then
            # 获取标记值
            local class_mark_hex=""
            class_mark_hex=$(read_mark_from_file "$class_name" "upload")
            
            if [ -z "$class_mark_hex" ]; then
                # 使用自动计算的值
                local mark_value=$((class_index << upload_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                logger -t "qos_gargoyle" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            # 添加标记到列表
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                tc filter add dev "$qos_interface" parent 1:0 protocol ip \
                    prio 1 handle ${class_mark_hex}/$UPLOAD_MASK fw flowid 1:$class_index
                    
                tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
                    prio 2 handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index
            fi
        fi
        class_index=$((class_index + 1))
    done
    
    # 设置默认类别
    set_default_upload_class
    
    # 创建上传链
    create_upload_chain
    
    logger -t "qos_gargoyle" "上传方向HTB初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========

initialize_htb_download() {
    logger -t "qos_gargoyle" "初始化下载方向HTB"
    
    # 加载下载类别配置
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到下载类别配置，使用默认类别"
        create_default_download_class
        return 0
    fi
    
    logger -t "qos_gargoyle" "找到下载类别：$download_class_list"
    
    # 确保IFB设备已启动
    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        logger -t "qos_gargoyle" "错误: IFB设备 $IFB_DEVICE 不存在"
        return 1
    fi
    
    if ! ip link set dev "$IFB_DEVICE" up; then
        logger -t "qos_gargoyle" "错误: 无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    
    # 创建根队列（在IFB设备上）
    if ! create_htb_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    local priority=3  # 为高优先级类别预留1-2
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        create_htb_download_class "$class_name" "$class_index" "$priority"
        if [ $? -eq 0 ]; then
            # 获取标记值
            local class_mark_hex=""
            class_mark_hex=$(read_mark_from_file "$class_name" "download")
            
            if [ -z "$class_mark_hex" ]; then
                # 使用自动计算的值
                local mark_value=$((class_index << download_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                logger -t "qos_gargoyle" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            # 添加标记到列表
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器到IFB设备
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                # IPv4过滤器
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
                    prio $priority handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv4过滤器添加成功: 标记=$class_mark_hex, 类别ID=1:$class_index"
                fi
                
                # IPv6过滤器
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
                    prio $((priority + 1)) handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv6过滤器添加成功: 标记=$class_mark_hex, 类别ID=1:$class_index"
                fi
                
                # 处理IPv4-mapped IPv6地址的过滤器
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
                    u32 match ip6 dst ::ffff:0:0/96 \
                    action connmark set $class_mark_hex \
                    flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加IPv4-mapped IPv6过滤器失败 (类别: $class_name)"
                fi
            fi
        fi
        class_index=$((class_index + 1))
        priority=$((priority + 2))
    done
    
    # 设置默认类别
    set_default_download_class
    
    # 创建下载链和入口重定向
    create_download_chain
    setup_ingress_redirect
    
    logger -t "qos_gargoyle" "下载方向HTB初始化完成"
    return 0
}

#================默认配置分类==========
# 从配置读取默认类别，并动态映射到对应的TC类ID
create_upload_chain() {
    logger -t "qos_gargoyle" "创建上传链（空函数，已由initialize_htb_upload处理）"
    return 0
}

# 从配置读取默认类别，并动态映射到对应的TC类ID
set_default_upload_class() {
    logger -t "qos_gargoyle" "设置上传默认类别"
    
    # 1. 从配置获取用户选择的默认类别名称
    local default_class_name=$(uci -q get qos_gargoyle.upload.default_class 2>/dev/null)
    default_class_name="${default_class_name:-Normal}"
    
    logger -t "qos_gargoyle" "用户配置的上传默认类别名称: $default_class_name"
    
    # 2. 查找这个类别在upload_class_list中的索引位置
    local class_index=2  # TC类ID从1:2开始
    local found_index=2  # 默认值
    local found=0
    
    for class_name in $upload_class_list; do
        if [ "$class_name" = "$default_class_name" ]; then
            found_index=$class_index
            found=1
            logger -t "qos_gargoyle" "找到上传默认类别 '$default_class_name' 在索引位置 $found_index"
            break
        fi
        class_index=$((class_index + 1))
    done
    
    if [ $found -eq 0 ]; then
        logger -t "qos_gargoyle" "警告: 未找到上传默认类别 '$default_class_name'，使用第一个类别"
    fi
    
    # 3. 设置TC默认类别
    tc qdisc change dev "$qos_interface" root handle 1:0 htb default $found_index
    logger -t "qos_gargoyle" "上传默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

set_default_download_class() {
    logger -t "qos_gargoyle" "设置下载默认类别"
    
    # 1. 从配置获取用户选择的默认类别名称
    local default_class_name=$(uci -q get qos_gargoyle.download.default_class 2>/dev/null)
    default_class_name="${default_class_name:-Normal}"
    
    logger -t "qos_gargoyle" "用户配置的下载默认类别名称: $default_class_name"
    
    # 2. 查找这个类别在download_class_list中的索引位置
    local class_index=2  # TC类ID从1:2开始
    local found_index=2  # 默认值
    local found=0
    
    for class_name in $download_class_list; do
        if [ "$class_name" = "$default_class_name" ]; then
            found_index=$class_index
            found=1
            logger -t "qos_gargoyle" "找到下载默认类别 '$default_class_name' 在索引位置 $found_index"
            break
        fi
        class_index=$((class_index + 1))
    done
    
    if [ $found -eq 0 ]; then
        logger -t "qos_gargoyle" "警告: 未找到下载默认类别 '$default_class_name'，使用第一个类别"
    fi
    
    # 3. 设置TC默认类别
    tc qdisc change dev "$IFB_DEVICE" root handle 1:0 htb default $found_index
    logger -t "qos_gargoyle" "下载默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

create_download_chain() {
    logger -t "qos_gargoyle" "创建下载链（包括入口重定向）"
    setup_ingress_redirect
}

# ========== HTB特定功能函数 ==========

# 应用HTB优先级映射规则
apply_htb_priomap_rules() {
    if [ "$HTB_PRIOMAP_ENABLED" != "1" ]; then
        logger -t "qos_gargoyle" "HTB优先级映射已禁用"
        return 0
    fi
    
    logger -t "qos_gargoyle" "应用HTB优先级映射规则"
    
    # 添加基于DSCP/TOS的优先级映射
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv4 ip dscp cs6 counter meta mark set 0x7F meta priority set bulk
    
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv4 ip dscp cs7 counter meta mark set 0x7F meta priority set bulk
    
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 dscp cs6 counter meta mark set 0x7F meta priority set bulk
    
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 dscp cs7 counter meta mark set 0x7F meta priority set bulk
    
    logger -t "qos_gargoyle" "HTB优先级映射规则应用完成"
}

# 应用HTB特定增强规则
apply_htb_specific_rules() {
    logger -t "qos_gargoyle" "应用HTB特定增强规则"
    
    # 应用优先级映射
    apply_htb_priomap_rules
    
    # 添加HTB特定的标记规则
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        meta mark and 0x007f != 0 counter meta priority set "bulk"
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        meta mark and 0x7f00 != 0 counter meta priority set "bulk"
    
    # 连接跟踪优化
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        ct state established,related counter meta mark set ct mark
    
    # HTB特定的TCP优化规则
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        tcp flags syn tcp option maxseg size set rt mtu counter meta mark set 0x3F
    
    logger -t "qos_gargoyle" "HTB特定增强规则应用完成"
}

# 保留这些函数，但重命名以明确其用途
apply_htb_tc_filters() {
    logger -t "qos_gargoyle" "应用HTB TC过滤器"
    
    # 这些是HTB特有的TC过滤器，不是nftables规则
    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        apply_upload_tc_filters
    fi
    
    if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        apply_download_tc_filters
    fi
}

# 添加上傳 TC 過濾器
apply_upload_tc_filters() {
    logger -t "qos_gargoyle" "應用上傳 TC 過濾器（空實現）"
    # 此處留空，因為在 HTB 初始化時已經設置了過濾器
    return 0
}

# 添加下載 TC 過濾器
apply_download_tc_filters() {
    logger -t "qos_gargoyle" "應用下載 TC 過濾器（空實現）"
    # 此處留空，因為在 HTB 初始化時已經設置了過濾器
    return 0
}

# ========== 主初始化函数 ==========

# 主入口：初始化HTB QoS
initialize_htb_qos() {
    logger -t "qos_gargoyle" "开始初始化HTB QoS系统"
    
    # 1. 加载HTB专属配置
    load_htb_config
    
    # 2. 设置IPv6特定规则
    setup_ipv6_specific_rules
    
    # 3. 初始化上传方向
    if [ "$total_upload_bandwidth" -ge 0 ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        initialize_htb_upload
    else
        logger -t "qos_gargoyle" "上传带宽未配置，跳过上传方向初始化"
    fi
    
    # 4. 初始化下载方向
    if [ "$total_download_bandwidth" -ge 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        initialize_htb_download
    else
        logger -t "qos_gargoyle" "下载带宽未配置，跳过下载方向初始化"
    fi
    
    # 5. 应用HTB特有的TC过滤器规则
    apply_htb_tc_filters
    
    # 6. 应用HTB特定的增强规则
    apply_htb_specific_rules
	
	# 7. 生成qosdba配置文件
    generate_qosdba_for_htb
    
    logger -t "qos_gargoyle" "HTB QoS初始化完成"
}

# ========== 新增函数：为HTB生成qosdba配置 ==========
generate_qosdba_for_htb() {
    logger -t "qos_gargoyle" "为HTB生成qosdba配置文件"
    
    # 检查dba_conf.sh是否已加载
    if type quick_generate_config >/dev/null 2>&1; then
        # 获取必要的参数
        local upload_device="${qos_interface:-pppoe-wan}"
        local download_device="${IFB_DEVICE:-ifb0}"
        
        # 获取带宽配置
        local upload_bw="${total_upload_bandwidth:-40000}"
        local download_bw="${total_download_bandwidth:-95000}"
        
        # 获取分类列表
        local upload_classes="$upload_class_list"
        local download_classes="$download_class_list"
        
        logger -t "qos_gargoyle" "调用dba_conf生成HTB配置: 上传设备=$upload_device, 下载设备=$download_device"
        
        # 调用dba_conf.sh生成配置
        if quick_generate_config "htb"; then
            logger -t "qos_gargoyle" "HTB的qosdba配置生成成功"
        else
            logger -t "qos_gargoyle" "警告: HTB的qosdba配置生成失败"
        fi
    else
        logger -t "qos_gargoyle" "错误: dba_conf.sh模块未正确加载，无法生成qosdba配置"
    fi
}

# ========== 停止和清理函数 ==========

stop_htb_qos() {
    logger -t "qos_gargoyle" "停止HTB QoS"
    
    # 清理上传方向
    if tc qdisc show dev "$qos_interface" | grep -q "htb"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        logger -t "qos_gargoyle" "清理上传方向HTB队列"
    fi
    
    # 清理下载方向
    if tc qdisc show dev "$IFB_DEVICE" | grep -q "htb"; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
        logger -t "qos_gargoyle" "清理下载方向HTB队列"
    fi
    
    # 清理NFTables规则
    nft delete chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null
    nft delete chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null
    
    # 清理入口队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    
    # 停用IFB设备
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        logger -t "qos_gargoyle" "停用IFB设备: $IFB_DEVICE"
    fi
    
    # 清理连接标记
    conntrack -U --mark 0 2>/dev/null
    
    logger -t "qos_gargoyle" "HTB QoS停止完成"
}

# ========== 状态查询函数 ==========

show_htb_status() {
    # 确保必要的变量已设置
    local qos_ifb="${IFB_DEVICE:-ifb0}"
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
    
    echo -e "\n===== HTB-FQ_CODEL 状态报告结束 ====="
    
    return 0
}

# ========== 主程序入口 ==========

# 主调度函数
main_htb_qos() {
    local action="$1"
    
    case "$action" in
        start)
            logger -t "qos_gargoyle" "启动HTB QoS"
            initialize_htb_qos
            ;;
        stop)
            logger -t "qos_gargoyle" "停止HTB QoS"
            stop_htb_qos
            ;;
        restart)
            logger -t "qos_gargoyle" "重启HTB QoS"
            stop_htb_qos
            sleep 2
            initialize_htb_qos
            ;;
        status)
            show_htb_status
            ;;
        config)
            # 新增命令：仅生成qosdba配置
            logger -t "qos_gargoyle" "生成HTB的qosdba配置"
            generate_qosdba_for_htb
            ;;
        show-config)
            # 显示qosdba配置
            if type show_qosdba_config >/dev/null 2>&1; then
                show_qosdba_config
            else
                echo "错误: dba_conf.sh模块未加载"
            fi
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|config|show-config}"
            echo ""
            echo "命令:"
            echo "  start        启动HTB QoS"
            echo "  stop         停止HTB QoS"
            echo "  restart      重启HTB QoS"
            echo "  status       显示状态"
            echo "  config       生成qosdba配置文件"
            echo "  show-config  显示qosdba配置"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "htb-fqcodel.sh" ]; then
    main_htb_qos "$1"
fi

logger -t "qos_gargoyle" "HTB + fq_codel助手模块加载完成"