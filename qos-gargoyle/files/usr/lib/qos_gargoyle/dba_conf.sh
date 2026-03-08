#!/bin/sh
# ============================================================================
# dba_conf.sh - QoS动态带宽分配器配置模块
# 功能：为qosdba生成配置文件，支持不同QoS算法
# 版本: 1.0
# 作者: ilxp
# ============================================================================

# qosdba配置文件路径
QOSDBA_CONFIG_FILE="/etc/qosdba.conf"

# 全局变量
UPLOAD_MASK="0x007F"
DOWNLOAD_MASK="0x7F00"

# 加载配置库
. /lib/functions.sh
. /lib/functions/network.sh 2>/dev/null || true

# ==================== 辅助函数 ====================

# 从UCI配置加载类别配置
load_class_config_from_uci() {
    local class_name="$1"
    local config_section="$2"
    
    # 清空变量
    unset percent_bandwidth per_min_bandwidth per_max_bandwidth priority name minRTT
    
    # 从UCI读取配置
    config_get percent_bandwidth "$config_section" percent_bandwidth
    config_get per_min_bandwidth "$config_section" per_min_bandwidth
    config_get per_max_bandwidth "$config_section" per_max_bandwidth
    config_get priority "$config_section" priority
    config_get name "$config_section" name
    config_get minRTT "$config_section" minRTT
    
    return 0
}

# 从文件读取类别标记
read_class_mark_from_file() {
    local class_name="$1"
    local direction="$2"  # upload 或 download
    local mark_file=""
    
    if [ "$direction" = "upload" ]; then
        mark_file="/etc/qos_gargoyle/upload_class_marks"
    elif [ "$direction" = "download" ]; then
        mark_file="/etc/qos_gargoyle/download_class_marks"
    else
        echo ""
        return 1
    fi
    
    if [ ! -f "$mark_file" ]; then
        echo ""
        return 1
    fi
    
    # 尝试查找标记
    local mark=$(grep -E "^${direction}:${class_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    
    if [ -n "$mark" ] && echo "$mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
        echo "$mark"
        return 0
    fi
    
    echo ""
    return 1
}

# 计算实际带宽值（kbps）
calculate_actual_bandwidth() {
    local class_name="$1"
    local direction="$2"  # upload 或 download
    local total_bandwidth="$3"  # 方向总带宽
    local percent_bandwidth="$4"  # 类别占总带宽的百分比
    local per_min_bandwidth="$5"  # 类别内最小带宽百分比
    local per_max_bandwidth="$6"  # 类别内最大带宽百分比
    
    # 计算类别总带宽（基于总带宽的百分比）
    local class_total_bw=0
    if [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        if [ -n "$total_bandwidth" ] && [ "$total_bandwidth" -gt 0 ] 2>/dev/null; then
            class_total_bw=$((total_bandwidth * percent_bandwidth / 100))
        else
            class_total_bw=$total_bandwidth
        fi
    else
        class_total_bw=$total_bandwidth
    fi
    
    # 计算min_bw_kbps（最小保证带宽）
    local min_bw_kbps=0
    if [ -n "$per_min_bandwidth" ] && [ "$per_min_bandwidth" -ge 0 ] 2>/dev/null; then
        if [ "$per_min_bandwidth" -eq 0 ]; then
            min_bw_kbps=1  # 最小保证带宽，不能为0
        else
            min_bw_kbps=$((class_total_bw * per_min_bandwidth / 100))
        fi
    else
        # 默认保证带宽为类别总带宽的50%
        min_bw_kbps=$((class_total_bw * 50 / 100))
    fi
    
    # 计算max_bw_kbps（最大允许带宽）
    local max_bw_kbps=0
    if [ -n "$per_max_bandwidth" ] && [ "$per_max_bandwidth" -gt 0 ] 2>/dev/null; then
        max_bw_kbps=$((class_total_bw * per_max_bandwidth / 100))
    else
        max_bw_kbps=$class_total_bw
    fi
    
    # 验证和调整
    if [ $min_bw_kbps -gt $max_bw_kbps ]; then
        min_bw_kbps=$max_bw_kbps
    fi
    
    if [ $min_bw_kbps -lt 1 ]; then
        min_bw_kbps=1
    fi
    
    if [ $max_bw_kbps -lt $min_bw_kbps ]; then
        max_bw_kbps=$min_bw_kbps
    fi
    
    # 返回结果
    echo "$class_total_bw $min_bw_kbps $max_bw_kbps"
}

# 生成TC参数配置
generate_tc_class_config() {
    local direction="$1"           # upload 或 download
    local class_list="$2"          # 类别名称列表
    local total_bandwidth="$3"     # 方向总带宽
    local device_name="$4"         # 设备名称
    local config_section="$5"      # 配置节类型
    
    local output=""
    local class_index=2
    
    logger -t "dba_conf" "为$direction生成TC类别配置, 总带宽=${total_bandwidth}kbps, 类别列表: $class_list"
    
    for class_name in $class_list; do
        logger -t "dba_conf" "处理$direction类别: $class_name"
        
        # 从UCI加载类别配置
        local percent_bandwidth="" per_min_bandwidth="" per_max_bandwidth="" priority="" name="" minRTT=""
        
        # 尝试从UCI读取配置
        config_load qos_gargoyle
        
        # 获取类别显示名称
        name=$(uci -q get "qos_gargoyle.$class_name.name" 2>/dev/null)
        [ -z "$name" ] && name="$class_name"
        
        # 获取带宽百分比
        percent_bandwidth=$(uci -q get "qos_gargoyle.$class_name.percent_bandwidth" 2>/dev/null)
        per_min_bandwidth=$(uci -q get "qos_gargoyle.$class_name.per_min_bandwidth" 2>/dev/null)
        per_max_bandwidth=$(uci -q get "qos_gargoyle.$class_name.per_max_bandwidth" 2>/dev/null)
        priority=$(uci -q get "qos_gargoyle.$class_name.priority" 2>/dev/null)
        minRTT=$(uci -q get "qos_gargoyle.$class_name.minRTT" 2>/dev/null)
        
        # 使用默认值
        [ -z "$priority" ] && priority="$class_index"
        [ -z "$percent_bandwidth" ] && percent_bandwidth="0"  # 默认0%，表示不使用百分比
        [ -z "$per_min_bandwidth" ] && per_min_bandwidth="0"  # 默认0%
        [ -z "$per_max_bandwidth" ] && per_max_bandwidth="0"  # 默认0%
        
        # 如果百分比为0，则使用公平分配
        if [ "$percent_bandwidth" = "0" ] || [ -z "$percent_bandwidth" ]; then
            # 计算平均分配
            local class_count=$(echo "$class_list" | wc -w)
            if [ "$class_count" -gt 0 ]; then
                percent_bandwidth=$((100 / class_count))
                logger -t "dba_conf" "类别 $name 使用公平分配: ${percent_bandwidth}%"
            fi
        fi
        
        # 计算实际带宽
        local bandwidth_values=$(calculate_actual_bandwidth "$class_name" "$direction" "$total_bandwidth" \
            "$percent_bandwidth" "$per_min_bandwidth" "$per_max_bandwidth")
        
        local class_total_bw=$(echo "$bandwidth_values" | awk '{print $1}')
        local min_bw_kbps=$(echo "$bandwidth_values" | awk '{print $2}')
        local max_bw_kbps=$(echo "$bandwidth_values" | awk '{print $3}')
        
        # 计算classid
        local classid_hex=""
        if [ "$direction" = "upload" ]; then
            classid_hex=$(printf "0x%x" $((0x100 + class_index)))
        else
            classid_hex=$(printf "0x%x" $((0x200 + class_index)))
        fi
        
        # 添加到输出
        output="${output}${classid_hex},${name},${priority},${class_total_bw},${min_bw_kbps},${max_bw_kbps}"$'\n'
        
        logger -t "dba_conf" "  $direction分类: $name (ID=$classid_hex) -> 总带宽=${class_total_bw}kbps, 最小=${min_bw_kbps}kbps, 最大=${max_bw_kbps}kbps, 优先级=$priority"
        
        class_index=$((class_index + 1))
    done
    
    # 移除最后的换行符
    output="${output%$'\n'}"
    
    echo "$output"
}

# ==================== 主配置生成函数 ====================

# 生成qosdba配置文件
generate_qosdba_config() {
    local upload_device="$1"       # 上传设备名
    local download_device="$2"     # 下载设备名
    local total_upload="$3"        # 上传总带宽(kbps)
    local total_download="$4"      # 下载总带宽(kbps)
    local upload_classes="$5"      # 上传类别列表
    local download_classes="$6"    # 下载类别列表
    local config_section="$7"      # 配置节类型
    
    logger -t "dba_conf" "正在生成qosdba配置文件..."
    
    # 开始生成配置文件
    cat > "$QOSDBA_CONFIG_FILE" << EOF
# ============================================================================
# qosdba 动态带宽分配器配置文件
# 自动生成于: $(date)
# 生成模块: dba_conf.sh
# 算法类型: ${config_section:-htb}
# ============================================================================

# 全局配置
[global]
enabled=1
debug_mode=0
safe_mode=0
interval=1
config_path=/etc/qosdba.conf
status_file=/tmp/qosdba.status
log_file=/var/log/qosdba.log

# 下载设备配置 ($download_device)
[device=$download_device]
enabled=1
total_bandwidth_kbps=$total_download
high_util_threshold=85
high_util_duration=5
low_util_threshold=40
low_util_duration=5
borrow_ratio=0.2
min_borrow_kbps=128
min_change_kbps=128
cooldown_time=8
auto_return_enable=1
return_threshold=50
return_speed=0.1
cache_interval=5

# 下载分类定义
# 格式: classid,name,priority,total_bw_kbps,min_bw_kbps,max_bw_kbps
EOF
    
    # 【修复】生成下载分类配置
    if [ -n "$download_classes" ]; then
        local download_config=$(generate_tc_class_config "download" "$download_classes" "$total_download" "$download_device" "$config_section")
        if [ -n "$download_config" ]; then
            echo "$download_config" >> "$QOSDBA_CONFIG_FILE"
        else
            echo "# 错误: 无法生成下载分类配置" >> "$QOSDBA_CONFIG_FILE"
        fi
    else
        # 【修复】不生成默认分类，只添加注释
        echo "# 注意: 系统中未配置下载类别" >> "$QOSDBA_CONFIG_FILE"
        echo "# 请先在qos_gargoyle配置中设置下载分类" >> "$QOSDBA_CONFIG_FILE"
    fi
    
    # 上传设备配置
    cat >> "$QOSDBA_CONFIG_FILE" << EOF

# 上传设备配置 ($upload_device)
[device=$upload_device]
enabled=1
total_bandwidth_kbps=$total_upload
high_util_threshold=85
high_util_duration=5
low_util_threshold=40
low_util_duration=5
borrow_ratio=0.2
min_borrow_kbps=128
min_change_kbps=128
cooldown_time=8
auto_return_enable=1
return_threshold=50
return_speed=0.1
cache_interval=5

# 上传分类定义
# 格式: classid,name,priority,total_bw_kbps,min_bw_kbps,max_bw_kbps
EOF
    
    # 【修复】生成上传分类配置
    if [ -n "$upload_classes" ]; then
        local upload_config=$(generate_tc_class_config "upload" "$upload_classes" "$total_upload" "$upload_device" "$config_section")
        if [ -n "$upload_config" ]; then
            echo "$upload_config" >> "$QOSDBA_CONFIG_FILE"
        else
            echo "# 错误: 无法生成上传分类配置" >> "$QOSDBA_CONFIG_FILE"
        fi
    else
        # 【修复】不生成默认分类，只添加注释
        echo "# 注意: 系统中未配置上传类别" >> "$QOSDBA_CONFIG_FILE"
        echo "# 请先在qos_gargoyle配置中设置上传分类" >> "$QOSDBA_CONFIG_FILE"
    fi
    
    # 添加动态带宽分配参数
    cat >> "$QOSDBA_CONFIG_FILE" << EOF

# ============================================================================
# qosdba 动态带宽分配参数
# ============================================================================
[dynamic_bandwidth]
# 高使用率阈值 (%)
high_util_threshold=85
# 高使用率持续时间 (秒)
high_util_duration=5
# 低使用率阈值 (%)
low_util_threshold=40
# 低使用率持续时间 (秒)
low_util_duration=5
# 借用比例 (0.0-1.0)
borrow_ratio=0.2
# 最小借用带宽 (kbps)
min_borrow_kbps=128
# 最小调整带宽 (kbps)
min_change_kbps=128
# 冷却时间 (秒)
cooldown_time=8
# 自动归还启用
auto_return_enable=1
# 归还阈值 (%)
return_threshold=50
# 归还速度 (每秒归还比例)
return_speed=0.1
EOF
    
    logger -t "dba_conf" "qosdba配置文件已生成: $QOSDBA_CONFIG_FILE"
    
    # 显示配置摘要
    show_config_summary "$upload_device" "$download_device" "$total_upload" "$total_download" \
        "$upload_classes" "$download_classes" "$config_section"
    
    return 0
}

# 显示配置摘要
show_config_summary() {
    local upload_device="$1"
    local download_device="$2"
    local total_upload="$3"
    local total_download="$4"
    local upload_classes="$5"
    local download_classes="$6"
    local config_section="$7"
    
    echo ""
    echo "=== qosdba配置生成完成 ==="
    echo "配置文件: $QOSDBA_CONFIG_FILE"
    echo "算法类型: ${config_section:-htb}"
    echo "下载设备: $download_device (带宽: ${total_download}kbps)"
    echo "上传设备: $upload_device (带宽: ${total_upload}kbps)"
    echo ""
    
    if [ -n "$download_classes" ]; then
        echo "下载分类 ($download_classes):"
        local class_index=2
        for class_name in $download_classes; do
            load_class_config_from_uci "$class_name" "$config_section"
            local bandwidth_values=$(calculate_actual_bandwidth "$class_name" "download" "$total_download" \
                "$percent_bandwidth" "$per_min_bandwidth" "$per_max_bandwidth")
            local class_total_bw=$(echo "$bandwidth_values" | awk '{print $1}')
            local min_bw_kbps=$(echo "$bandwidth_values" | awk '{print $2}')
            local max_bw_kbps=$(echo "$bandwidth_values" | awk '{print $3}')
            
            local class_display_name="${name:-$class_name}"
            local class_priority="${priority:-$class_index}"
            local classid_hex=$(printf "0x%x" $((0x200 + class_index)))
            
            echo "  $classid_hex,$class_display_name,$class_priority,$class_total_bw,$min_bw_kbps,$max_bw_kbps"
            
            class_index=$((class_index + 1))
        done
    fi
    
    if [ -n "$upload_classes" ]; then
        echo ""
        echo "上传分类 ($upload_classes):"
        local class_index=2
        for class_name in $upload_classes; do
            load_class_config_from_uci "$class_name" "$config_section"
            local bandwidth_values=$(calculate_actual_bandwidth "$class_name" "upload" "$total_upload" \
                "$percent_bandwidth" "$per_min_bandwidth" "$per_max_bandwidth")
            local class_total_bw=$(echo "$bandwidth_values" | awk '{print $1}')
            local min_bw_kbps=$(echo "$bandwidth_values" | awk '{print $2}')
            local max_bw_kbps=$(echo "$bandwidth_values" | awk '{print $3}')
            
            local class_display_name="${name:-$class_name}"
            local class_priority="${priority:-$class_index}"
            local classid_hex=$(printf "0x%x" $((0x100 + class_index)))
            
            echo "  $classid_hex,$class_display_name,$class_priority,$class_total_bw,$min_bw_kbps,$max_bw_kbps"
            
            class_index=$((class_index + 1))
        done
    fi
    
    echo ""
}

# 显示当前qosdba配置
show_qosdba_config() {
    echo "=== 当前qosdba配置 ==="
    if [ -f "$QOSDBA_CONFIG_FILE" ]; then
        # 显示分类定义部分
        echo "分类定义:"
        grep -E "^0x[0-9A-Fa-f]+," "$QOSDBA_CONFIG_FILE" | while read -r line; do
            echo "  $line"
        done
    else
        echo "配置文件不存在: $QOSDBA_CONFIG_FILE"
    fi
}

# 检查qosdba配置文件
check_qosdba_config() {
    if [ ! -f "$QOSDBA_CONFIG_FILE" ]; then
        echo "错误: qosdba配置文件不存在: $QOSDBA_CONFIG_FILE"
        return 1
    fi
    
    # 检查配置格式
    local class_count=$(grep -cE "^0x[0-9A-Fa-f]+," "$QOSDBA_CONFIG_FILE")
    local device_count=$(grep -c "^\[device=" "$QOSDBA_CONFIG_FILE")
    
    echo "配置文件检查:"
    echo "  - 配置文件: $QOSDBA_CONFIG_FILE (存在)"
    echo "  - 分类数量: $class_count"
    echo "  - 设备数量: $device_count"
    
    if [ $class_count -eq 0 ]; then
        echo "警告: 配置文件中没有分类定义"
    fi
    
    if [ $device_count -eq 0 ]; then
        echo "警告: 配置文件中没有设备定义"
    fi
    
    return 0
}

# 快速生成配置（简化接口）
# 快速生成配置（简化接口）
quick_generate_config() {
    local algorithm="$1"  # htb 或 hfsc
    
    logger -t "dba_conf" "正在为算法 $algorithm 生成qosdba配置..."
    
    # 获取网络接口
    local qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    qos_interface="${qos_interface:-pppoe-wan}"
    
    # 获取带宽配置
    local total_upload=$(uci -q get qos_gargoyle.upload.total_bandwidth 2>/dev/null)
    total_upload="${total_upload:-40000}"
    
    local total_download=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    total_download="${total_download:-95000}"
    
    logger -t "dba_conf" "网络接口: WAN=$qos_interface, 上传=${total_upload}kbps, 下载=${total_download}kbps"
    
    # 根据算法类型获取分类列表
    local upload_classes=""
    local download_classes=""
    
    if [ "$algorithm" = "htb" ]; then
        logger -t "dba_conf" "使用HTB配置模式"
        
        # 从UCI获取上传类别
        upload_classes=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "qos_gargoyle\..+\.type=upload_class" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
        
        # 从UCI获取下载类别
        download_classes=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "qos_gargoyle\..+\.type=download_class" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
        
    elif [ "$algorithm" = "hfsc" ]; then
        logger -t "dba_conf" "使用HFSC配置模式"
        
        # 从UCI获取HFSC上传类别
        upload_classes=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "qos_gargoyle\..+\.type=hfsc_upload_class" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
        
        # 从UCI获取HFSC下载类别
        download_classes=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "qos_gargoyle\..+\.type=hfsc_download_class" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
    else
        logger -t "dba_conf" "错误: 未知的算法类型: $algorithm"
        return 1
    fi
    
    # 【修复】删除自动添加默认分类的逻辑
    # 只使用从系统读取的实际分类
    if [ -n "$upload_classes" ]; then
        logger -t "dba_conf" "从系统读取上传类别: $upload_classes"
    else
        logger -t "dba_conf" "警告: 未找到上传类别配置，将生成空的上传分类定义"
    fi
    
    if [ -n "$download_classes" ]; then
        logger -t "dba_conf" "从系统读取下载类别: $download_classes"
    else
        logger -t "dba_conf" "警告: 未找到下载类别配置，将生成空的下载分类定义"
    fi
    
    # 清理空白字符
    upload_classes=$(echo "$upload_classes" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
    download_classes=$(echo "$download_classes" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
    
    # 生成配置
    generate_qosdba_config "$qos_interface" "ifb0" "$total_upload" "$total_download" \
        "$upload_classes" "$download_classes" "$algorithm"
    
    return $?
}

# ==================== 模块自检 ====================

# 模块自检函数
module_self_test() {
    echo "=== dba_conf.sh 模块自检 ==="
    echo "模块版本: 1.0"
    echo "配置文件: $QOSDBA_CONFIG_FILE"
    echo ""
    
    # 测试calculate_actual_bandwidth函数
    echo "测试带宽计算:"
    local test_result=$(calculate_actual_bandwidth "test_class" "download" "100000" "50" "30" "80")
    local total_bw=$(echo "$test_result" | awk '{print $1}')
    local min_bw=$(echo "$test_result" | awk '{print $2}')
    local max_bw=$(echo "$test_result" | awk '{print $3}')
    
    echo "  输入: 总带宽=100000kbps, 类别占比=50%, 最小=30%, 最大=80%"
    echo "  输出: 总带宽=${total_bw}kbps, 最小=${min_bw}kbps, 最大=${max_bw}kbps"
    
    # 检查依赖
    echo ""
    echo "检查依赖:"
    if command -v uci >/dev/null 2>&1; then
        echo "  ✓ UCI工具: 已安装"
    else
        echo "  ✗ UCI工具: 未安装"
    fi
    
    if [ -f "/lib/functions.sh" ]; then
        echo "  ✓ OpenWrt函数库: 存在"
    else
        echo "  ✗ OpenWrt函数库: 不存在"
    fi
    
    echo ""
    echo "模块自检完成"
    return 0
}

# ==================== 主程序入口 ====================

# 如果脚本被直接调用
if [ "$(basename "$0")" = "dba_conf.sh" ]; then
    action="${1:-help}"
    
    case "$action" in
        generate)
            shift
            if [ $# -ge 6 ]; then
                generate_qosdba_config "$1" "$2" "$3" "$4" "$5" "$6" "${7:-htb}"
            else
                echo "用法: $0 generate <上传设备> <下载设备> <上传带宽> <下载带宽> <上传分类列表> <下载分类列表> [算法类型]"
                echo "示例: $0 generate pppoe-wan ifb0 40000 95000 'upload_class_1 upload_class_2' 'download_class_1 download_class_2' htb"
            fi
            ;;
        quick-generate)
            shift
            algorithm="${1:-htb}"
            quick_generate_config "$algorithm"
            ;;
        show)
            show_qosdba_config
            ;;
        check)
            check_qosdba_config
            ;;
        test)
            module_self_test
            ;;
        help|*)
            echo "dba_conf.sh - qosdba配置生成模块"
            echo ""
            echo "用法: $0 {generate|quick-generate|show|check|test|help}"
            echo ""
            echo "命令:"
            echo "  generate          生成完整配置（需提供所有参数）"
            echo "  quick-generate    快速生成配置（自动从UCI读取）"
            echo "  show              显示当前配置"
            echo "  check             检查配置文件"
            echo "  test              模块自检"
            echo "  help              显示此帮助"
            echo ""
            echo "示例:"
            echo "  $0 quick-generate htb    # 快速生成HTB配置"
            echo "  $0 quick-generate hfsc   # 快速生成HFSC配置"
            echo "  $0 show                   # 显示当前配置"
            echo "  $0 test                   # 运行模块自检"
            ;;
    esac
fi

echo "dba_conf.sh 模块加载完成" 2>/dev/null