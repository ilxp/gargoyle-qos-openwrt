#!/bin/sh
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
if [ -f "/usr/lib/qos_gargoyle/rule-helper.sh" ]; then
    . /usr/lib/qos_gargoyle/rule-helper.sh
    logger -t "qos_gargoyle" "已加载规则辅助模块"
else
    logger -t "qos_gargoyle" "警告: 规则辅助模块未找到"
fi

# ========= HTB专属常量 ==========
HTB_SFQ_DEPTH=""
HTB_PRIOMAP_ENABLED="1"
HTB_DRR_QUANTUM="auto"

# ========== 配置加载函数 ==========

# 加载HTB专属配置
load_htb_config() {
    logger -t "qos_gargoyle" "加载HTB配置"
    
    # 从UCI配置读取HTB特定参数
    local sfq_depth_config=$(uci -q get qos_gargoyle.htb.sfq_depth 2>/dev/null)
    HTB_SFQ_DEPTH="${sfq_depth_config:-}"
    
    HTB_PRIOMAP_ENABLED=$(uci -q get qos_gargoyle.htb.priomap_enabled 2>/dev/null)
    HTB_PRIOMAP_ENABLED="${HTB_PRIOMAP_ENABLED:-1}"
    
    HTB_DRR_QUANTUM=$(uci -q get qos_gargoyle.htb.drr_quantum 2>/dev/null)
    HTB_DRR_QUANTUM="${HTB_DRR_QUANTUM:-auto}"
    
    # 处理SFQ深度参数
    if [ "$HTB_SFQ_DEPTH" = "auto" ] || [ -z "$HTB_SFQ_DEPTH" ]; then
        # 根据系统内存自动设置SFQ深度
        local total_mem=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [ -z "$total_mem" ]; then
            total_mem=0
        fi
        
        if [ "$total_mem" -lt 64000 ]; then
            HTB_SFQ_DEPTH="depth 32"
        elif [ "$total_mem" -lt 128000 ]; then
            HTB_SFQ_DEPTH="depth 64"
        else
            HTB_SFQ_DEPTH="depth 128"
        fi
    elif [ -n "$HTB_SFQ_DEPTH" ]; then
        # 用户指定了具体的深度值
        HTB_SFQ_DEPTH="depth $HTB_SFQ_DEPTH"
    fi
    
    # 处理DRR quantum参数
    if [ "$HTB_DRR_QUANTUM" = "auto" ]; then
        # 根据MTU自动计算quantum
        local mtu=$(cat /sys/class/net/pppoe-wan/mtu 2>/dev/null || echo 1500)
        HTB_DRR_QUANTUM=$((mtu + 100))
    fi
    
    logger -t "qos_gargoyle" "HTB配置: SFQ深度设置=${HTB_SFQ_DEPTH:-未设置}, 优先级映射=${HTB_PRIOMAP_ENABLED}, DRR quantum=${HTB_DRR_QUANTUM}"
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

#读取标记文件
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
    local percent_bandwidth="$1"
    local min_bandwidth="$2"
    local max_bandwidth="$3"
    local direction="$4"
    local class_name="$5"
    
    local total_bandwidth=0
    if [ "$direction" = "upload" ]; then
        total_bandwidth=$total_upload_bandwidth
    else
        total_bandwidth=$total_download_bandwidth
    fi
    
    local rate=""
    local ceil=""
    local burst=""
    local cburst=""
    
    # 计算rate（保证带宽）
    if [ -n "$min_bandwidth" ] && [ "$min_bandwidth" -gt 0 ] 2>/dev/null; then
        rate="${min_bandwidth}kbit"
    elif [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        local calculated_rate=$((total_bandwidth * percent_bandwidth / 100))
        rate="${calculated_rate}kbit"
    else
        # 默认使用total_bandwidth的1/类别数量
        rate="$((total_bandwidth / 10))kbit"
    fi
    
    # 计算ceil（最大带宽）
    if [ -n "$max_bandwidth" ] && [ "$max_bandwidth" -gt 0 ] 2>/dev/null; then
        ceil="${max_bandwidth}kbit"
    else
        ceil="${total_bandwidth}kbit"
    fi
    
    # 计算burst和cburst
    # burst通常为rate * latency，这里使用固定公式
    local rate_num=$(echo "$rate" | sed 's/kbit//')
    burst="$((rate_num * 1000 / 8 / 100))"
    burst="${burst}b"
    cburst="$((rate_num * 1000 / 8 / 50))"
    cburst="${cburst}b"
    
    # 调整burst大小，避免过小
    if [ "$burst" = "0b" ]; then
        burst="1kb"
    fi
    if [ "$cburst" = "0b" ]; then
        cburst="2kb"
    fi
    
    echo "$rate $ceil $burst $cburst"
}

# 创建HTB上传类别
create_htb_upload_class() {
    local class_name="$1"
    local class_index="$2"
    
    logger -t "qos_gargoyle" "创建上传类别: $class_name, ID: 1:$class_index"
    
    # 加载类别配置
    load_all_config_options "$CONFIG_FILE" "$class_name"
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "upload")
    
    if [ -z "$class_mark" ]; then
        # 备用方案：基于类别索引计算
        local class_num=$(echo "$class_name" | sed -E 's/^upload_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            class_mark=$(printf "0x%X" $((0x1 << (class_num - 1))))
        else
            # 基于class_index计算
            class_mark=$(printf "0x%X" $((0x1 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取上传标记: $class_mark"
    fi
    
    # 计算HTB参数
    local htb_params=$(calculate_htb_parameters "$percent_bandwidth" "$min_bandwidth" "$max_bandwidth" "upload" "$class_name")
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
    fi
    
    # 创建HTB类别
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        logger -t "qos_gargoyle" "错误: 创建上传类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建SFQ队列
    if [ -n "$HTB_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 $HTB_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
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
    
    logger -t "qos_gargoyle" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, rate=$rate, ceil=$ceil)"
    return 0
}

# 创建HTB下载类别
create_htb_download_class() {
    local class_name="$1"
    local class_index="$2"
    local priority="$3"
    
    logger -t "qos_gargoyle" "创建下载类别: $class_name, ID: 1:$class_index, 优先级: $priority"
    
    # 加载类别配置
    load_all_config_options "$CONFIG_FILE" "$class_name"
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "download")
    
    if [ -z "$class_mark" ]; then
        # 备用方案：基于类别索引计算
        local class_num=$(echo "$class_name" | sed -E 's/^download_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            class_mark=$(printf "0x%X" $((0x100 << (class_num - 1))))
        else
            # 基于class_index计算
            class_mark=$(printf "0x%X" $((0x100 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取下载标记: $class_mark"
    fi
    
    # 计算HTB参数
    local htb_params=$(calculate_htb_parameters "$percent_bandwidth" "$min_bandwidth" "$max_bandwidth" "download" "$class_name")
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
    fi
    
    # 创建HTB类别
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        logger -t "qos_gargoyle" "错误: 创建下载类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建SFQ队列
    if [ -n "$HTB_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 $HTB_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
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
    
    logger -t "qos_gargoyle" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, rate=$rate, ceil=$ceil)"
    return 0
}

# 创建默认上传类别
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
    
    # 添加SFQ队列
    if [ -n "$HTB_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$qos_interface" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 $HTB_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$qos_interface" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
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

# 创建默认下载类别
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
    
    # 添加SFQ队列
    if [ -n "$HTB_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 $HTB_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
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
    
    # 再次调试输出
    echo "DEBUG: qos_interface = $qos_interface"
    echo "DEBUG: IFB_DEVICE = $IFB_DEVICE"
    
    # 检查变量是否有效
    if [ -z "$qos_interface" ]; then
        echo "错误: 无法确定 WAN 接口"
        return 1
    fi
    
    if [ -z "$IFB_DEVICE" ]; then
        echo "错误: IFB 设备名称未设置"
        return 1
    fi   
    logger -t "qos_gargoyle" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    
    # 在WAN接口上创建ingress队列
    echo "在 $qos_interface 上创建入口队列..."
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        logger -t "qos_gargoyle" "错误: 无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    # 清除现有的入口过滤器
    echo "清理现有入口过滤器..."
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null
    
    # 重定向所有IPv4流量到IFB设备
    echo "设置IPv4入口重定向规则..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv4入口重定向规则添加失败"
    else
        echo "IPv4入口重定向规则添加成功"
    fi
    
    # 重定向所有IPv6流量到IFB设备
    echo "设置IPv6入口重定向规则..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark pipe \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv6入口重定向规则添加失败"
    else
        echo "IPv6入口重定向规则添加成功"
    fi
    
    # 验证入口重定向配置
    echo "验证入口重定向配置..."
    local ingress_rules=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | wc -l)
    
    if [ "$ingress_rules" -ge 2 ]; then
        logger -t "qos_gargoyle" "入口重定向已成功设置: $qos_interface -> $IFB_DEVICE"
        echo "入口重定向设置完成"
        
        # 显示当前入口过滤器配置
        echo "当前入口过滤器配置:"
        tc filter show dev "$qos_interface" parent ffff: 2>/dev/null || echo "  无入口过滤器"
    else
        logger -t "qos_gargoyle" "错误: 入口重定向规则数量不足 ($ingress_rules 条)"
        echo "警告: 入口重定向规则可能未完全设置"
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
            # 尝试从配置获取标记值
            local class_mark_hex=""
            
            # 加载类别配置
            load_all_config_options "$CONFIG_FILE" "$class_name"
            
            # 如果配置中有 class_mark，使用配置的值
            if [ -n "$class_mark" ] && [ "$class_mark" != "0x0" ]; then
                class_mark_hex="$class_mark"
                logger -t "qos_gargoyle" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                # 否则使用自动计算的值
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
            # 尝试从配置获取标记值
            local class_mark_hex=""
            
            # 加载类别配置
            load_all_config_options "$CONFIG_FILE" "$class_name"
            
            # 如果配置中有 class_mark，使用配置的值
            if [ -n "$class_mark" ] && [ "$class_mark" != "0x0" ]; then
                class_mark_hex="$class_mark"
                logger -t "qos_gargoyle" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                # 否则使用自动计算的值
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
    
    logger -t "qos_gargoyle" "HTB QoS初始化完成"
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
    
    # 如果IP地址未定义，尝试获取
    if [ -z "$wan_ip" ] && [ -f "/lib/functions/network.sh" ]; then
        . /lib/functions/network.sh
        network_find_wan wan_interface
        network_get_ipaddr wan_ip "$wan_interface" 2>/dev/null || wan_ip=""
        network_get_ipaddr6 wan_ip6 "$wan_interface" 2>/dev/null || wan_ip6=""
        network_get_ipaddr local_ip lan 2>/dev/null || local_ip=""
        network_get_ipaddr6 local_ip6 lan 2>/dev/null || local_ip6=""
    fi
    
    echo "===== QoS状态报告 ====="
    echo "时间: $(date)"
    echo "系统运行时间: $(uptime | sed 's/.*up //; s/,.*//')"
    echo "WAN接口: ${qos_interface:-未知}"
    echo "WAN IPv4: ${wan_ip:-未检测到}"
    echo "WAN IPv6: ${wan_ip6:-未检测到}"
    echo "LAN IPv4: ${local_ip:-未检测到}"
    echo "LAN IPv6: ${local_ip6:-未检测到}"
    
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
    
    # 检查QoS是否实际运行
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q htb; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    # 显示出口配置
    echo -e "\n======== 出口QoS ($qos_interface) ========"
    echo "NFT规则:"
    nft list chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || echo "  无NFT规则"
    
    echo -e "\nTC统计:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null || echo "  无TC队列"
    
    if tc class show dev "$qos_interface" >/dev/null 2>&1; then
        echo "TC类别:"
        tc -s class show dev "$qos_interface" 2>/dev/null
    fi
    
    echo "TC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null || echo "  无过滤器"
    
    # 显示入口配置
    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    echo "NFT规则:"
    nft list chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || echo "  无NFT规则"
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC统计:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null || echo "  无TC队列"
        
        if tc class show dev "$qos_ifb" >/dev/null 2>&1; then
            echo "TC类别:"
            tc -s class show dev "$qos_ifb" 2>/dev/null
        fi
        
        echo "TC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null || echo "  无过滤器"
        
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
    
    # 显示连接标记
    echo -e "\n======== 活动连接标记 ========"
    local has_marked_connections=0
    
    # IPv4连接标记
    if [ -n "$wan_ip" ]; then
        echo "IPv4连接 (目标: $wan_ip):"
        conntrack -L -d "$wan_ip" 2>/dev/null | grep -E "mark=[0-9]+" | head -5 | while read -r line; do
            echo "  $line"
            has_marked_connections=1
        done
    fi
    
    # IPv6连接标记
    if [ -n "$wan_ip6" ]; then
        echo "IPv6连接 (目标: $wan_ip6):"
        conntrack -L -d "$wan_ip6" 2>/dev/null | grep -E "mark=[0-9]+" | head -5 | while read -r line; do
            echo "  $line"
            has_marked_connections=1
        done
    fi
    
    if [ "$has_marked_connections" -eq 0 ]; then
        echo "  未找到已标记的连接"
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
    
    # 系统资源
    echo -e "\n===== 系统资源 ====="
    
    # 简化内存显示
    if [ -f /proc/meminfo ]; then
        mem_total=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
        
        if [ -n "$mem_total" ] && [ -n "$mem_available" ]; then
            mem_used=$((mem_total - mem_available))
            mem_total_mb=$((mem_total / 1024))
            mem_used_mb=$((mem_used / 1024))
            echo "内存: ${mem_used_mb}MB 已用/${mem_total_mb}MB 总计"
        else
            echo "内存: 无法获取详细信息"
        fi
    else
        echo "内存: 无法获取"
    fi
        
        # CPU负载
        if [ -f /proc/loadavg ]; then
            load=$(cat /proc/loadavg)
            cpu_count=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo 1)
            echo "CPU负载: $load (核心数: $cpu_count)"
        else
            echo "CPU负载: 无法获取"
        fi
        
        # 网络接口统计
        echo -e "\n===== 网络接口统计 ====="
        echo "WAN接口 ($qos_interface) 统计:"
        ifconfig "$qos_interface" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /'
        
        if ip link show "$qos_ifb" >/dev/null 2>&1; then
            echo -e "\nIFB接口 ($qos_ifb) 统计:"
            ifconfig "$qos_ifb" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /'
        fi
        
        # 连接跟踪统计
        if [ -f /proc/net/nf_conntrack ] || [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
            echo -e "\n===== 连接跟踪 ====="
            if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
                conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "未知")
                conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "未知")
                echo "活动连接: $conntrack_count / $conntrack_max"
            elif [ -f /proc/net/nf_conntrack ]; then
                conntrack_count=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo "0")
                conntrack_max=$(sysctl -n net.nf_conntrack_max 2>/dev/null || echo "未知")
                echo "活动连接: $conntrack_count / $conntrack_max"
            fi
        fi
        
        # QoS运行状态摘要
        echo -e "\n===== QoS运行状态 ====="
        local upload_active=0
        local download_active=0
        
        # 检查上传QoS
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "htb"; then
            upload_active=1
            echo "上传QoS: 已启用 (HTB)"
            
            # 显示上传带宽使用
            tc -s class show dev "$qos_interface" 2>/dev/null | grep "rate" | while read -r line; do
                echo "  $line"
            done
        else
            echo "上传QoS: 未启用"
        fi
        
        # 检查下载QoS
        if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "htb"; then
            download_active=1
            echo -e "\n下载QoS: 已启用 (HTB)"
            
            # 显示下载带宽使用
            tc -s class show dev "$qos_ifb" 2>/dev/null | grep "rate" | while read -r line; do
                echo "  $line"
            done
        else
            echo -e "\n下载QoS: 未启用"
        fi
        
        # 总体状态
        if [ "$upload_active" -eq 1 ] && [ "$download_active" -eq 1 ]; then
            echo -e "\n✓ QoS双向流量整形已启用"
        elif [ "$upload_active" -eq 1 ]; then
            echo -e "\n⚠ 仅上传QoS已启用"
        elif [ "$download_active" -eq 1 ]; then
            echo -e "\n⚠ 仅下载QoS已启用"
        else
            echo -e "\n✗ QoS未运行"
        fi
        
        # 显示HTB特定配置
        echo -e "\n===== HTB专用配置 ====="
        echo "SFQ深度: ${HTB_SFQ_DEPTH:-使用系统默认}"
        echo "优先级映射: ${HTB_PRIOMAP_ENABLED:-未启用}"
        echo "DRR Quantum: ${HTB_DRR_QUANTUM:-自动计算}"
        
        # 显示带宽配置
        echo -e "\n带宽限制:"
        echo "  上传: ${total_upload_bandwidth:-未设置}kbit/s"
        echo "  下载: ${total_download_bandwidth:-未设置}kbit/s"
        
        # 显示当前连接数
        echo -e "\n===== 当前连接统计 ====="
        if command -v conntrack >/dev/null 2>&1; then
            local total_conn=$(conntrack -L 2>/dev/null | wc -l)
            local tcp_conn=$(conntrack -L -p tcp 2>/dev/null | wc -l)
            local udp_conn=$(conntrack -L -p udp 2>/dev/null | wc -l)
            local icmp_conn=$(conntrack -L -p icmp 2>/dev/null | wc -l)
            
            echo "总连接数: $total_conn"
            echo "  TCP: $tcp_conn"
            echo "  UDP: $udp_conn"
            echo "  ICMP: $icmp_conn"
        else
            echo "无法获取连接统计 (conntrack工具不可用)"
        fi
        
        # 显示最后配置时间
        if [ -f "/tmp/qos_gargoyle_last_config" ]; then
            local last_config=$(cat /tmp/qos_gargoyle_last_config 2>/dev/null)
            echo -e "\n最后配置时间: ${last_config:-未知}"
        fi
        
        echo -e "\n===== 状态报告结束 ====="
        
    } 2>/dev/null || {
        echo "状态查询失败"
        return 1
    }
    
    return 0
}

 ========== 主函数 ==========

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
        *)
            echo "用法: $0 {start|stop|restart|status|debug}"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "htb-helper.sh" ]; then
    main_htb_qos "$1"
fi

logger -t "qos_gargoyle" "HTB助手模块加载完成"