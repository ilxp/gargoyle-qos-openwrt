#!/bin/sh
# qosacc_conf.sh - 生成qosacc配置文件
# 版本: 1.0

qosacc_CONF="/etc/qosacc.conf"

# 从UCI配置读取参数
get_uci_value() {
    local section="$1"
    local option="$2"
    local default="$3"
    
    local value=$(uci -q get qos_gargoyle.$section.$option 2>/dev/null)
    if [ -z "$value" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# 获取网络接口
get_wan_interface() {
    local iface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    if [ -z "$iface" ]; then
        if [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan iface
        fi
    fi
    echo "${iface:-pppoe-wan}"
}

# 生成配置文件
generate_config() {
    logger -t "qosacc" "正在生成qosacc配置文件..."
    
    # 创建目录
    mkdir -p /etc/qosacc 2>/dev/null
    
    # 从UCI获取参数
    local ping_interval=$(get_uci_value "qosacc" "ping_interval" "200")
    local target=$(get_uci_value "qosacc" "target" "8.8.8.8")
    local max_bandwidth_kbps=$(get_uci_value "qosacc" "max_bandwidth_kbps" "10000")
    local ping_limit_ms=$(get_uci_value "qosacc" "ping_limit_ms" "20")
    local device=$(get_uci_value "qosacc" "device" "ifb0")
    
    local safe_mode=$(get_uci_value "qosacc" "safe_mode" "0")
    local verbose=$(get_uci_value "qosacc" "verbose" "0")
    local auto_switch_mode=$(get_uci_value "qosacc" "auto_switch_mode" "0")
    local background_mode=$(get_uci_value "qosacc" "background_mode" "1")
    local skip_initial=$(get_uci_value "qosacc" "skip_initial" "0")
    
    local min_bw_change_kbps=$(get_uci_value "qosacc" "min_bw_change_kbps" "10")
    local min_bw_ratio=$(get_uci_value "qosacc" "min_bw_ratio" "0.1")
    local max_bw_ratio=$(get_uci_value "qosacc" "max_bw_ratio" "1.0")
    local smoothing_factor=$(get_uci_value "qosacc" "smoothing_factor" "0.3")
    local active_threshold=$(get_uci_value "qosacc" "active_threshold" "0.7")
    local idle_threshold=$(get_uci_value "qosacc" "idle_threshold" "0.3")
    local safe_start_ratio=$(get_uci_value "qosacc" "safe_start_ratio" "0.5")
    
    # 生成配置文件
    cat > "$qosacc_CONF" << EOF
# qosacc.conf - QoS监控器配置文件
# 自动生成于: $(date)
# 生成脚本: qos_gargoyle

# 基本配置
[basic]
ping_interval = $ping_interval
target = $target
max_bandwidth_kbps = $max_bandwidth_kbps
ping_limit_ms = $ping_limit_ms
device = $device
classid = 0x101

# 控制参数
[control]
safe_mode = $safe_mode
verbose = $verbose
auto_switch_mode = $auto_switch_mode
background_mode = $background_mode
skip_initial = $skip_initial

# 算法参数
[algorithm]
min_bw_change_kbps = $min_bw_change_kbps
min_bw_ratio = $min_bw_ratio
max_bw_ratio = $max_bw_ratio
smoothing_factor = $smoothing_factor
active_threshold = $active_threshold
idle_threshold = $idle_threshold
safe_start_ratio = $safe_start_ratio

# 文件路径
[paths]
debug_log = /var/log/qosacc.log
status_file = /tmp/qosacc.status
config_file = /etc/qosacc.conf

# 高级选项
[advanced]
ping_history_size = 10
min_ping_time_ms = 1
max_ping_time_ms = 5000
stats_interval_ms = 1000
control_interval_ms = 1000
realtime_detect_ms = 1000
heartbeat_interval_ms = 10000
EOF
    
    logger -t "qosacc" "qosacc配置文件已生成: $qosacc_CONF"
    
    # 显示配置
    echo "=== qosacc配置生成完成 ==="
    echo "配置文件: $qosacc_CONF"
    echo "基本参数:"
    echo "  ping间隔: ${ping_interval}ms"
    echo "  目标地址: ${target}"
    echo "  最大带宽: ${max_bandwidth_kbps}kbps"
    echo "  ping限制: ${ping_limit_ms}ms"
    echo "  网络设备: ${device}"
    echo ""
    
    return 0
}

# 显示配置
show_config() {
    if [ -f "$qosacc_CONF" ]; then
        echo "当前qosacc配置:"
        echo "=================="
        cat "$qosacc_CONF"
    else
        echo "配置文件不存在: $qosacc_CONF"
    fi
}

# 主函数
main() {
    case "$1" in
        generate)
            generate_config
            ;;
        show)
            show_config
            ;;
        help|*)
            echo "用法: $0 {generate|show}"
            echo "  generate - 生成qosacc配置文件"
            echo "  show     - 显示当前配置"
            ;;
    esac
}

# 执行
main "$1"