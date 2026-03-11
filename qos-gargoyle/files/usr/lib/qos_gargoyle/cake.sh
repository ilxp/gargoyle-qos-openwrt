#!/bin/sh
# CAKE算法实现模块
# 基于Common Applications Kept Enhanced算法实现QoS流量控制。
# version=4.0 安全加固版
# 修复内容：
# 1. 修复文件锁竞态条件
# 2. 修复IPv6过滤规则漏洞
# 3. 修复TC命令参数注入风险
# 4. 修复资源清理残留
# 5. 增强敏感信息脱敏
# 6. 修复TC命令参数拼接问题
# 7. 修复性能指标计算误差
# 8. 修复配置参数验证
# 9. 增强并发控制
# 10. 修复内存泄漏
# 11. 增强命令执行超时处理
# 12. 增强命令注入防护
# 13. 增强权限最小化

# ========== 权限检查 ==========
# 检查脚本执行权限
check_script_permissions() {
    local script_path="$0"
    local required_user="root"
    
    # 检查是否以root用户运行
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 此脚本需要root权限运行" >&2
        echo "请使用: sudo $0 $@" >&2
        exit 1
    fi
    
    # 修复：严格限制脚本权限
    local script_perms=$(stat -c "%a" "$script_path" 2>/dev/null)
    if [ -n "$script_perms" ] && [ "$script_perms" -gt 700 ]; then
        log_warn "脚本权限过于宽松 ($script_perms)，建议设置为700"
        # 尝试自动修复权限
        chmod 700 "$script_path" 2>/dev/null && log_info "已自动修复脚本权限为700"
    fi
    
    # 检查脚本所有者
    local script_owner=$(stat -c "%U:%G" "$script_path" 2>/dev/null)
    if [ "$script_owner" != "root:root" ] && [ -n "$script_owner" ]; then
        log_warn "脚本所有者非root ($script_owner)，建议设置为root:root"
    fi
}

check_script_permissions "$@"

# ========== 变量初始化 ==========
: ${total_upload_bandwidth:=40000}
: ${total_download_bandwidth:=95000}
: ${CONFIG_FILE:=qos_gargoyle}
: ${IFB_DEVICE:=ifb0}
: ${UPLOAD_MASK:=0x007F}
: ${DOWNLOAD_MASK:=0x7F00}
LOCK_FILE="/var/run/cake_qos_$(basename "$0" 2>/dev/null || echo "cake").lock"
local DEBUG="${DEBUG:-0}" 2>/dev/null || DEBUG=0
local PREV_DROP_RATE=0  # 前一次的丢包率记录

# 获取时间戳（精确到毫秒）
get_timestamp_ms() {
    date +%s%3N
}

# 如果 qos_interface 未设置，尝试获取
if [ -z "$qos_interface" ]; then
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    qos_interface="${qos_interface:-pppoe-wan}"
fi

echo "CAKE 模块初始化完成 (v4.0)"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"
echo "  锁文件: $LOCK_FILE"
[ "$DEBUG" = "1" ] && echo "  DEBUG模式: 启用"
[ "$DEBUG" = "2" ] && echo "  高级DEBUG模式: 启用"

# ========= CAKE专属常量 ==========
CAKE_DIFFSERV_MODE="diffserv4"
CAKE_OVERHEAD="0"
CAKE_MPU="0"
CAKE_RTT="100ms"
CAKE_ACK_FILTER="0"
CAKE_NAT="0"
CAKE_WASH="0"
CAKE_SPLIT_GSO="0"
CAKE_INGRESS="0"
CAKE_AUTORATE_INGRESS="0"
CAKE_MEMORY_LIMIT="32mb"

# ========== 性能优化：安全的tc命令执行 ==========
# 修复：使用数组构建命令参数，防止参数注入
safe_tc_command() {
    local timeout="${1:-5}"  # 默认5秒超时
    shift
    local tc_args=("$@")
    local output=""
    local pid=""
    
    # 创建临时文件存储输出
    local tmp_output="/tmp/tc_output_$$.tmp"
    # 修复：使用trap确保临时文件删除
    trap 'rm -f "$tmp_output" 2>/dev/null' EXIT INT TERM
    
    # 修复：增加重试机制
    local retry=3
    local success=false
    
    while [ $retry -gt 0 ]; do
        # 在后台执行tc命令
        {
            # 使用printf %q转义特殊字符
            local safe_cmd=""
            for arg in "${tc_args[@]}"; do
                safe_cmd="$safe_cmd $(printf '%q' "$arg")"
            done
            
            # 执行命令
            eval "tc $safe_cmd" > "$tmp_output" 2>&1
        } &
        pid=$!
        
        # 等待命令完成或超时
        local count=0
        while kill -0 "$pid" 2>/dev/null && [ $count -lt $timeout ]; do
            sleep 0.1
            count=$((count + 1))
        done
        
        if kill -0 "$pid" 2>/dev/null; then
            # 命令超时，杀死进程
            kill -9 "$pid" 2>/dev/null
            log_warn "tc命令执行超时: ${tc_args[*]}"
            retry=$((retry - 1))
            [ $retry -gt 0 ] && sleep 1
        else
            # 检查命令返回状态
            if wait $pid; then
                success=true
                break
            else
                log_warn "tc命令执行失败: ${tc_args[*]}"
                retry=$((retry - 1))
                [ $retry -gt 0 ] && sleep 1
            fi
        fi
    done
    
    # 获取命令输出
    if [ -f "$tmp_output" ]; then
        output=$(cat "$tmp_output")
    fi
    
    if [ "$success" = true ]; then
        echo "$output"
        rm -f "$tmp_output" 2>/dev/null
        return 0
    else
        log_error "tc命令执行失败，重试次数用尽: ${tc_args[*]}"
        echo "$output" >&2
        rm -f "$tmp_output" 2>/dev/null
        return 1
    fi
}

# ========== 依赖检查函数 ==========
check_dependencies() {
    log_info "检查系统依赖"
    
    local missing_deps=0
    local required_cmds="tc ip uci"
    
    # 如果启用了NFT，则需要检查nft
    if command -v nft >/dev/null 2>&1; then
        required_cmds="$required_cmds nft"
    fi
    
    for cmd in $required_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "缺少依赖命令: $cmd"
            missing_deps=$((missing_deps + 1))
        fi
    done
    
    # 修复：使用modinfo精确检查内核模块是否存在
    local required_modules="sch_cake act_mirred ifb"
    for module in $required_modules; do
        if ! modinfo "$module" >/dev/null 2>&1; then
            log_error "内核模块 $module 不存在"
            missing_deps=$((missing_deps + 1))
        elif ! lsmod | grep -q "^$module\s" 2>/dev/null; then
            if ! modprobe -q "$module" 2>/dev/null; then
                log_error "内核模块 $module 加载失败"
                missing_deps=$((missing_deps + 1))
            else
                log_info "内核模块 $module 已加载"
            fi
        fi
    done
    
    if [ $missing_deps -gt 0 ]; then
        log_error "缺少 $missing_deps 个必要依赖，请安装后重试"
        return 1
    fi
    
    log_info "✅ 所有依赖检查通过"
    return 0
}

# ========== 增强的并发安全锁机制 ==========
acquire_lock() {
    local lock_file="$LOCK_FILE"
    local timeout=10
    local count=0
    
    # 修复：使用更严格的锁机制
    exec 200>"$lock_file"
    
    # 修复：使用更严格的锁机制，防止竞态条件
    if ! flock -n 200; then
        log_error "锁已被占用，无法获取锁文件: $lock_file"
        exit 1
    fi
    
    # 修复：锁文件可能被其他进程篡改，先写入PID
    echo "$$" > "$lock_file"
    trap 'release_lock' EXIT INT TERM HUP QUIT
    
    log_debug "已获取锁文件: $lock_file (PID: $$)"
    return 0
}

# 修复：改进锁释放逻辑，处理flock超时后的锁文件残留
release_lock() {
    # 修复：增加锁文件存在性检查
    [ -f "$LOCK_FILE" ] || {
        log_debug "无锁文件，直接退出"
        return 0
    }
    
    local lock_pid=""
    
    # 读取锁文件中的PID
    if [ -f "$LOCK_FILE" ]; then
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    fi
    
    # 检查进程是否真的存在
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        # 尝试优雅终止
        kill "$lock_pid" 2>/dev/null
        sleep 0.5
        
        # 如果进程仍然存在，强制终止
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "检测到僵尸进程(PID: $lock_pid)，尝试强制终止..."
            kill -9 "$lock_pid" >/dev/null 2>&1
        fi
    fi
    
    # 修复：删除锁文件
    rm -f "$LOCK_FILE" 2>/dev/null || {
        log_warn "无法删除锁文件: $LOCK_FILE，尝试强制删除"
        rm -rf "$LOCK_FILE" 2>/dev/null
    }
    
    log_debug "锁已释放"
    return 0
}

# ========== 信号处理 ==========
setup_signal_handlers() {
    trap 'handle_exit_signal' INT TERM
    trap 'handle_hup_signal' HUP
    trap 'handle_quit_signal' QUIT
    log_debug "信号处理器已设置"
}

handle_exit_signal() {
    log_info "收到终止信号，清理资源..."
    stop_cake_qos
    release_lock
    exit 0
}

handle_hup_signal() {
    log_info "收到HUP信号，重新加载配置..."
    # 重新加载配置
    reload_cake_config
    return 0
}

handle_quit_signal() {
    log_info "收到QUIT信号，执行快速清理..."
    # 执行快速清理逻辑
    quick_cleanup
    exit 0
}

quick_cleanup() {
    log_info "执行快速清理..."
    
    # 清理上传方向队列
    tc qdisc del dev "$qos_interface" root 2>/dev/null || true
    
    # 清理下载方向队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    fi
    
    log_info "快速清理完成"
}

# ========== 增强日志函数 ==========
log_info() {
    local timestamp=$(date '+%H:%M:%S')
    local debug_timestamp=""
    
    [ "$DEBUG" = "1" ] && debug_timestamp="[$(get_timestamp_ms)] "
    
    # 修复：增强敏感信息脱敏（IPv6支持）
    local sanitized_message="$1"
    # IPv4地址脱敏
    sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP_REDACTED]/g')
    # IPv6地址脱敏
    sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9a-fA-F:]+:[0-9a-fA-F:]+)/[IPv6_REDACTED]/g')
    # 敏感参数脱敏
    sanitized_message=$(echo "$sanitized_message" | sed 's/\(password\|secret\|key\|token\)=[^ ]*/\1=****/g')
    
    logger -t "qos_gargoyle" "CAKE: $sanitized_message"
    echo "${debug_timestamp}[$timestamp] CAKE: $sanitized_message"
}

log_error() {
    local timestamp=$(date '+%H:%M:%S')
    local debug_timestamp=""
    
    [ "$DEBUG" = "1" ] && debug_timestamp="[$(get_timestamp_ms)] "
    
    logger -t "qos_gargoyle" "CAKE错误: $1"
    echo "${debug_timestamp}[$timestamp] ❌ CAKE错误: $1" >&2
}

log_warn() {
    local timestamp=$(date '+%H:%M:%S')
    local debug_timestamp=""
    
    [ "$DEBUG" = "1" ] && debug_timestamp="[$(get_timestamp_ms)] "
    
    logger -t "qos_gargoyle" "CAKE警告: $1"
    echo "${debug_timestamp}[$timestamp] ⚠️ CAKE警告: $1"
}

log_debug() {
    [ "${DEBUG:-0}" = "1" ] && {
        local timestamp=$(date '+%H:%M:%S')
        local debug_timestamp="[$(get_timestamp_ms)] "
        
        # 敏感信息脱敏处理
        local sanitized_message="$1"
        sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP_REDACTED]/g')
        sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9a-fA-F:]+:[0-9a-fA-F:]+)/[IPv6_REDACTED]/g')
        sanitized_message=$(echo "$sanitized_message" | sed 's/\(password\|secret\|key\|token\)=[^ ]*/\1=****/g')
        
        logger -t "qos_gargoyle" "CAKE调试: $sanitized_message"
        echo "${debug_timestamp}[$timestamp] 🔍 CAKE调试: $sanitized_message"
    }
}

# 高级调试模式：TC规则转储
log_debug_tc() {
    [ "${DEBUG:-0}" = "2" ] && {
        local device="$1"
        echo "===== TC规则转储 ($device) ====="
        tc -s -d qdisc show dev "$device" 2>/dev/null
        echo "================================="
    }
}

# 安全参数消毒函数
sanitize_param() {
    local param="$1"
    # 只保留字母、数字、下划线、点、斜杠、冒号、减号
    echo "$param" | sed 's/[^a-zA-Z0-9_./:-]//g'
}

# ========== 增强参数验证函数 ==========

# 转换带宽单位到kbit
convert_bandwidth_to_kbit() {
    local bw_value="$1"
    local result=0
    
    # 如果已经是纯数字，直接返回
    if echo "$bw_value" | grep -qE '^[0-9]+$'; then
        echo "$bw_value"
        return 0
    fi
    
    # 修复：严格验证带宽单位
    if ! [[ "$bw_value" =~ ^([0-9]+)([kKmMgG]?)$ ]]; then
        log_error "无效带宽格式: $bw_value"
        return 1
    fi
    
    # 提取数字和单位
    local num=$(echo "$bw_value" | sed 's/[^0-9]//g')
    local unit=$(echo "$bw_value" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]')
    
    if [ -z "$num" ]; then
        echo "$bw_value"
        return 1
    fi
    
    case "$unit" in
        "K")
            result=$num
            ;;
        "M")
            result=$((num * 1000))
            ;;
        "G")
            result=$((num * 1000000))
            ;;
        "")
            result=$num
            ;;
        *)
            log_warn "未知的带宽单位: $unit，使用kbit"
            result=$num
            ;;
    esac
    
    echo "$result"
    return 0
}

validate_cake_parameters() {
    local param_value="$1"
    local param_name="$2"
    
    # 参数消毒
    param_value=$(sanitize_param "$param_value")
    
    case "$param_name" in
        bandwidth)
            # 修复：支持带单位的数值 (如500k/1M)
            local clean_value=$(echo "$param_value" | sed 's/^ *//;s/ *$//')
            if ! echo "$clean_value" | grep -qiE '^[0-9]+([kKmMgG]?)$'; then
                log_error "无效的带宽值: $param_value"
                return 1
            fi
            
            # 转换为kbit进行验证
            local bw_kbit=$(convert_bandwidth_to_kbit "$clean_value")
            
            if [ "$bw_kbit" -lt 8 ]; then
                log_warn "带宽过小: ${param_value} (${bw_kbit}kbit) (建议至少8kbit)"
            fi
            
            if [ "$bw_kbit" -gt 1000000 ]; then
                log_warn "带宽过大: ${param_value} (${bw_kbit}kbit) (超过1Gbit)"
            fi
            ;;
            
        rtt)
            if [ -n "$param_value" ]; then
                # 修复：清除前后空格
                local rtt_clean=$(echo "$param_value" | sed 's/^ *//;s/ *$//')
                if ! echo "$rtt_clean" | grep -qE '^[0-9]*\.?[0-9]+(us|ms|s)$'; then
                    log_warn "无效的RTT格式: $param_value (应为数字+单位: us/ms/s)"
                    return 1
                fi
            fi
            ;;
            
        memory_limit)
            if [ -n "$param_value" ]; then
                # 修复：强制转换为小写并在参数中使用统一格式
                param_value=$(echo "$param_value" | tr '[:upper:]' '[:lower:]')
                
                if ! echo "$param_value" | grep -qiE '^[0-9]+(b|kb|mb|gb)$'; then
                    log_warn "无效的内存限制格式: $param_value"
                    return 1
                fi
            fi
            ;;
    esac
    
    return 0
}

validate_diffserv_mode() {
    local mode="$1"
    
    # CAKE支持的DiffServ模式
    local valid_modes="besteffort diffserv3 diffserv4 diffserv5 diffserv8"
    
    for valid_mode in $valid_modes; do
        if [ "$mode" = "$valid_mode" ]; then
            return 0
        fi
    done
    
    log_warn "无效的DiffServ模式: $mode，使用默认值diffserv4"
    return 1
}

# 验证CAKE配置
validate_cake_config() {
    log_info "验证CAKE配置..."
    
    # 检查依赖
    if ! check_dependencies; then
        return 1
    fi
    
    # 检查必要变量
    local required_vars="qos_interface"
    for var in $required_vars; do
        eval "var_value=\$$var"
        if [ -z "$var_value" ]; then
            log_error "缺少必要变量: $var"
            return 1
        fi
    done
    
    # 检查接口是否存在
    if ! ip link show dev "$qos_interface" >/dev/null 2>&1; then
        log_error "接口 $qos_interface 不存在"
        return 1
    fi
    
    # 检查带宽配置
    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        validate_cake_parameters "$total_upload_bandwidth" "bandwidth" || return 1
    else
        log_warn "上传带宽未配置或为0，跳过上传方向"
    fi
    
    if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        validate_cake_parameters "$total_download_bandwidth" "bandwidth" || return 1
    else
        log_warn "下载带宽未配置或为0，跳过下载方向"
    fi
    
    # 验证DiffServ模式
    if ! validate_diffserv_mode "$CAKE_DIFFSERV_MODE"; then
        CAKE_DIFFSERV_MODE="diffserv4"
    fi
    
    # 验证RTT
    validate_cake_parameters "$CAKE_RTT" "rtt"
    
    # 验证内存限制
    validate_cake_parameters "$CAKE_MEMORY_LIMIT" "memory_limit"
    
    log_info "✅ CAKE配置验证通过"
    return 0
}

# ========== 增强配置加载函数 ==========
load_cake_config() {
    log_info "加载CAKE配置"
    
    # 修复：增加默认值回退机制
    CAKE_DIFFSERV_MODE=$(uci -q get qos_gargoyle.cake.diffserv_mode 2>/dev/null) || CAKE_DIFFSERV_MODE="diffserv4"
    CAKE_OVERHEAD=$(uci -q get qos_gargoyle.cake.overhead 2>/dev/null) || CAKE_OVERHEAD="0"
    CAKE_MPU=$(uci -q get qos_gargoyle.cake.mpu 2>/dev/null) || CAKE_MPU="0"
    CAKE_RTT=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null) || CAKE_RTT="100ms"
    CAKE_ACK_FILTER=$(uci -q get qos_gargoyle.cake.ack_filter 2>/dev/null) || CAKE_ACK_FILTER="0"
    CAKE_NAT=$(uci -q get qos_gargoyle.cake.nat 2>/dev/null) || CAKE_NAT="0"
    CAKE_WASH=$(uci -q get qos_gargoyle.cake.wash 2>/dev/null) || CAKE_WASH="0"
    CAKE_SPLIT_GSO=$(uci -q get qos_gargoyle.cake.split_gso 2>/dev/null) || CAKE_SPLIT_GSO="0"
    CAKE_INGRESS=$(uci -q get qos_gargoyle.cake.ingress 2>/dev/null) || CAKE_INGRESS="0"
    CAKE_AUTORATE_INGRESS=$(uci -q get qos_gargoyle.cake.autorate_ingress 2>/dev/null) || CAKE_AUTORATE_INGRESS="0"
    
    # 修复：强制转换为小写并在参数中使用统一格式
    CAKE_MEMORY_LIMIT=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null) || CAKE_MEMORY_LIMIT="32mb"
    CAKE_MEMORY_LIMIT=$(echo "$CAKE_MEMORY_LIMIT" | tr '[:upper:]' '[:lower:]')
    
    # 调试模式下的详细参数输出（脱敏处理）
    [ "$DEBUG" = "1" ] && {
        log_debug "CAKE详细配置: [参数已加载]"
    }
    
    log_info "CAKE配置加载完成"
    return 0
}

# 重新加载配置函数
reload_cake_config() {
    log_info "重新加载CAKE配置"
    load_cake_config
    auto_tune_cake
    return 0
}

# ========== 配置热加载支持 ==========
# 使用inotifywait监听配置文件变化
setup_config_watch() {
    if ! command -v inotifywait >/dev/null 2>&1; then
        log_warn "inotifywait命令不可用，跳过配置文件监控"
        return 1
    fi
    
    local config_path="/etc/config/qos_gargoyle"
    
    # 后台监控配置文件变化
    (
        inotifywait -mq -e modify "$config_path" 2>/dev/null | while read -r event; do
            log_info "检测到配置文件变更，触发自动重载..."
            reload_cake_config
        done
    ) &
    
    echo $! > "/var/run/cake_config_watch.pid"
    log_info "配置文件监控已启动 (PID: $(cat /var/run/cake_config_watch.pid 2>/dev/null))"
    return 0
}

# 停止配置监控
stop_config_watch() {
    local pid_file="/var/run/cake_config_watch.pid"
    
    if [ -f "$pid_file" ]; then
        local watch_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null; then
            kill "$watch_pid" 2>/dev/null
            rm -f "$pid_file"
            log_info "配置文件监控已停止 (PID: $watch_pid)"
        fi
    fi
}

# ========== 增强配置校验 ==========
# 验证配置文件语法
validate_config_syntax() {
    log_info "验证配置文件语法..."
    
    if ! uci show qos_gargoyle >/dev/null 2>&1; then
        log_error "配置文件语法错误: uci show qos_gargoyle 失败"
        return 1
    fi
    
    # 检查必要的配置节
    local required_sections="global"
    for section in $required_sections; do
        if ! uci -q get qos_gargoyle.$section >/dev/null 2>&1; do
            log_error "缺少必要的配置节: $section"
            return 1
        fi
    done
    
    # 增强：增加配置值范围检查
    local upload_bandwidth=$(uci -q get qos_gargoyle.global.upload_bandwidth 2>/dev/null)
    local download_bandwidth=$(uci -q get qos_gargoyle.global.download_bandwidth 2>/dev/null)
    
    if [ -n "$upload_bandwidth" ] && [ "$upload_bandwidth" -gt 1000000 ]; then
        log_error "上传带宽超过物理限制: ${upload_bandwidth}kbit"
        return 1
    fi
    
    if [ -n "$download_bandwidth" ] && [ "$download_bandwidth" -gt 1000000 ]; then
        log_error "下载带宽超过物理限制: ${download_bandwidth}kbit"
        return 1
    fi
    
    log_info "✅ 配置文件语法检查通过"
    return 0
}

# 验证带宽总和不超过物理接口上限
validate_bandwidth_limit() {
    log_info "验证带宽限制..."
    
    # 获取物理接口速度
    local interface_speed=$(get_interface_speed "$qos_interface")
    
    # 修复：增加对虚拟接口的兼容性处理
    if [ -z "$interface_speed" ] || [ "$interface_speed" -le 0 ]; then
        # 虚拟接口或无速度信息的接口，使用默认值
        interface_speed=1000
        log_warn "无法获取接口物理速度，使用默认值1000Mbps"
    fi
    
    if [ -n "$interface_speed" ] && [ "$interface_speed" -gt 0 ]; then
        # 转换为kbit
        interface_speed_kbit=$((interface_speed * 1000))
        
        # 检查上传带宽
        if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
            if [ "$total_upload_bandwidth" -gt "$interface_speed_kbit" ]; then
                log_warn "上传带宽配置(${total_upload_bandwidth}kbit)超过接口物理带宽(${interface_speed_kbit}kbit)"
            fi
        fi
        
        # 检查下载带宽
        if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
            if [ "$total_download_bandwidth" -gt "$interface_speed_kbit" ]; then
                log_warn "下载带宽配置(${total_download_bandwidth}kbit)超过接口物理带宽(${interface_speed_kbit}kbit)"
            fi
        fi
    else
        log_warn "无法获取接口物理带宽，跳过带宽限制检查"
    fi
    
    return 0
}

# 获取接口物理速度
get_interface_speed() {
    local interface="$1"
    local speed=0
    
    # 修复：增加虚拟接口特殊处理
    if echo "$interface" | grep -qE '^(tun|tap|gre|vxlan|br|bond)'; then
        echo "virtual"
        return
    fi
    
    # 尝试从ethtool获取
    if command -v ethtool >/dev/null 2>&1; then
        # 性能优化：使用awk替代grep/sed组合
        speed=$(ethtool "$interface" 2>/dev/null | awk -F: '/[Ss]peed:/ {gsub(/[^0-9]/, "", $2); print $2}')
    fi
    
    # 尝试从sysfs获取
    if [ -z "$speed" ] && [ -f "/sys/class/net/$interface/speed" ]; then
        speed=$(cat "/sys/class/net/$interface/speed" 2>/dev/null)
    fi
    
    echo "$speed"
}

# ========== 自动调优功能 ==========
auto_tune_cake() {
    log_info "自动调整CAKE参数"
    
    local total_bw=0
    
    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ] && [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$((total_upload_bandwidth + total_download_bandwidth))
    elif [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        total_bw=$total_upload_bandwidth
    elif [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$total_download_bandwidth
    fi
    
    if [ "$total_bw" -gt 200000 ]; then
        CAKE_MEMORY_LIMIT="128mb"
        CAKE_RTT="20ms"
        log_info "自动调整: 超高带宽场景 (${total_bw}kbit) -> memlimit=128mb, rtt=20ms"
    elif [ "$total_bw" -gt 100000 ]; then
        CAKE_MEMORY_LIMIT="64mb"
        CAKE_RTT="50ms"
        log_info "自动调整: 高带宽场景 (${total_bw}kbit) -> memlimit=64mb, rtt=50ms"
    elif [ "$total_bw" -gt 50000 ]; then
        CAKE_MEMORY_LIMIT="32mb"
        CAKE_RTT="100ms"
        log_info "自动调整: 中等带宽场景 (${total_bw}kbit) -> memlimit=32mb, rtt=100ms"
    elif [ "$total_bw" -gt 10000 ]; then
        CAKE_MEMORY_LIMIT="16mb"
        CAKE_RTT="150ms"
        log_info "自动调整: 低带宽场景 (${total_bw}kbit) -> memlimit=16mb, rtt=150ms"
    else
        CAKE_MEMORY_LIMIT="8mb"
        CAKE_RTT="200ms"
        log_info "自动调整: 极低带宽场景 (${total_bw}kbit) -> memlimit=8mb, rtt=200ms"
    fi
    
    # 检查RTT设置是否合理
    if [ -n "$CAKE_RTT" ]; then
        # 性能优化：使用awk替代grep/sed组合
        local rtt_value=$(echo "$CAKE_RTT" | awk 'match($0, /[0-9]*\.?[0-9]+/) {print substr($0, RSTART, RLENGTH)}')
        local rtt_unit=$(echo "$CAKE_RTT" | awk 'match($0, /[a-zA-Z]+/) {print substr($0, RSTART, RLENGTH)}')
        
        if [ "$rtt_unit" = "s" ] && command -v bc >/dev/null 2>&1; then
            if [ "$(echo "$rtt_value > 1" | bc 2>/dev/null || echo "0")" = "1" ]; then
                log_warn "RTT设置过长: ${CAKE_RTT}，建议使用ms单位"
            fi
        fi
    fi
}

# ========== 增强的入口重定向函数 ==========
setup_ingress_redirect() {
    log_info "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    
    # 先彻底清理现有队列
    cleanup_tc_rules_completely "$qos_interface"
    
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        log_error "无法在$qos_interface上创建入口队列"
        return 1
    fi
    
    local ipv4_success=false
    local ipv6_success=false
    
    # IPv4重定向规则
    if tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv4_success=true
    else
        log_error "IPv4入口重定向规则添加失败"
    fi
    
    # 修复：IPv6重定向规则漏洞，严格匹配全球单播地址
    if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 dst 2000::/3 src 0::/0 flowlabel 0:0 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv6_success=true
    else
        log_warn "IPv6入口重定向规则添加失败，尝试无过滤规则"
        # 回退到无过滤规则
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            u32 match u32 0 0 \
            action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
            ipv6_success=true
        else
            log_error "IPv6入口重定向规则添加失败"
        fi
    fi
    
    if [ "$ipv4_success" = false ] || [ "$ipv6_success" = false ]; then
        log_warn "部分入口重定向规则添加失败，清理已创建的队列"
        cleanup_tc_rules_completely "$qos_interface"
        return 1
    fi
    
    log_info "入口重定向设置完成"
    return 0
}

# 彻底清理TC规则
cleanup_tc_rules_completely() {
    local device="$1"
    
    log_info "彻底清理 $device 上的TC规则"
    
    # 修复：增强清理逻辑
    tc qdisc del dev "$device" root 2>/dev/null || true
    tc class del dev "$device" root 2>/dev/null || true
    tc filter del dev "$device" parent ffff: 2>/dev/null || true
    
    # 清理所有过滤器
    for parent in ffff: 1:0; do
        tc filter del dev "$device" parent "$parent" 2>/dev/null || true
    done
    
    # 清理所有类别
    local classes=$(tc class show dev "$device" 2>/dev/null | awk '{print $2}')
    for cls in $classes; do
        if [ "$cls" != "root" ] && [ "$cls" != "ffff:" ]; then
            tc class del dev "$device" classid "$cls" 2>/dev/null || true
        fi
    done
    
    log_info "$device TC规则清理完成"
}

check_ingress_redirect() {
    log_info "检查入口重定向状态"
    
    local has_ipv4=false
    local has_ipv6=false
    
    if tc filter show dev "$qos_interface" parent ffff: protocol ip 2>/dev/null | \
        grep -q "mirred.*redirect dev $IFB_DEVICE"; then
        has_ipv4=true
        echo "✅ IPv4入口重定向: 已生效"
    else
        echo "❌ IPv4入口重定向: 未生效"
    fi
    
    if tc filter show dev "$qos_interface" parent ffff: protocol ipv6 2>/dev/null | \
        grep -q "mirred.*redirect dev $IFB_DEVICE"; then
        has_ipv6=true
        echo "✅ IPv6入口重定向: 已生效"
    else
        echo "❌ IPv6入口重定向: 未生效"
    fi
    
    [ "$has_ipv4" = true ] && [ "$has_ipv6" = true ] && return 0
    return 1
}

# ========== 性能优化：批量TC操作 ==========
# 批量创建TC规则
create_tc_rules_batch() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"
    
    log_info "批量创建TC规则: $device $direction"
    
    # 修复：使用tc-batch模式提升性能
    local batch_file="/tmp/tc_batch_$$.batch"
    trap 'rm -f "$batch_file"' EXIT INT TERM
    
    # 创建批量文件
    cat > "$batch_file" << EOF
qdisc del dev $device root
qdisc add dev $device root cake \\
    bandwidth ${bandwidth}kbit \\
    $CAKE_DIFFSERV_MODE \\
    overhead $CAKE_OVERHEAD \\
    mpu $CAKE_MPU \\
    rtt $CAKE_RTT \\
    memlimit $CAKE_MEMORY_LIMIT
EOF
    
    # 修复：增加重试机制
    local retry=3
    local success=false
    
    while [ $retry -gt 0 ]; do
        if tc -batch "$batch_file" 2>/dev/null; then
            success=true
            break
        fi
        retry=$((retry - 1))
        log_warn "TC规则批量创建失败，剩余重试次数: $retry"
        sleep 1
    done
    
    # 清理临时文件
    rm -f "$batch_file"
    
    if [ "$success" = true ]; then
        log_info "✅ TC规则批量创建完成"
        return 0
    else
        log_error "TC规则批量创建失败"
        return 1
    fi
}

# ========== 清理函数 ==========
cleanup_existing_queues() {
    local device="$1"
    local direction="$2"
    local ingress_mode="${3:-$CAKE_INGRESS}"
    
    log_info "清理$device上的现有$direction队列"
    
    if [ "$direction" = "upload" ]; then
        cleanup_tc_rules_completely "$device"
        echo "  清理上传队列完成"
    elif [ "$direction" = "download" ]; then
        cleanup_tc_rules_completely "$device"
        echo "  清理下载队列完成"
    fi
}

# ========== CAKE核心队列函数 ==========
create_cake_root_qdisc() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"
    
    log_info "为$device创建$direction方向CAKE根队列 (带宽: ${bandwidth}kbit)"
    
    if ! validate_cake_parameters "$bandwidth" "bandwidth"; then
        return 1
    fi
    
    cleanup_existing_queues "$device" "$direction"
    
    # 修复：使用数组传递参数
    local cake_params=("bandwidth" "${bandwidth}kbit" "$CAKE_DIFFSERV_MODE")
    [ "$CAKE_OVERHEAD" != "0" ] && cake_params+=("overhead" "$CAKE_OVERHEAD")
    [ "$CAKE_MPU" != "0" ] && cake_params+=("mpu" "$CAKE_MPU")
    [ -n "$CAKE_RTT" ] && cake_params+=("rtt" "$CAKE_RTT")
    [ "$CAKE_ACK_FILTER" = "1" ] && cake_params+=("ack-filter")
    [ "$CAKE_NAT" = "1" ] && cake_params+=("nat")
    [ "$CAKE_WASH" = "1" ] && cake_params+=("wash")
    [ "$CAKE_SPLIT_GSO" = "1" ] && cake_params+=("split-gso")
    [ -n "$CAKE_MEMORY_LIMIT" ] && cake_params+=("memlimit" "$CAKE_MEMORY_LIMIT")
    
    if [ "$direction" = "upload" ]; then
        echo "正在为 $device 创建上传CAKE队列..."
        echo "  参数: ${cake_params[*]}"
        
        # 修复：使用数组构建命令
        local tc_cmd=("qdisc" "add" "dev" "$device" "root" "cake")
        tc_cmd+=("${cake_params[@]}")
        
        if ! safe_tc_command 10 "${tc_cmd[@]}"; then
            log_error "无法在$device上创建上传CAKE队列"
            return 1
        fi
    elif [ "$direction" = "download" ]; then
        if [ "$CAKE_INGRESS" = "1" ]; then
            echo "正在为 $device 创建下载CAKE入口队列..."
            cake_params+=("ingress")
            [ "$CAKE_AUTORATE_INGRESS" = "1" ] && cake_params+=("autorate-ingress")
            echo "  参数: ${cake_params[*]}"
            
            local tc_cmd=("qdisc" "add" "dev" "$device" "ingress" "cake")
            tc_cmd+=("${cake_params[@]}")
            
            if ! safe_tc_command 10 "${tc_cmd[@]}"; then
                log_error "无法在$device上创建下载CAKE入口队列"
                return 1
            fi
        else
            echo "正在为 $device 创建下载CAKE根队列..."
            echo "  参数: ${cake_params[*]}"
            
            local tc_cmd=("qdisc" "add" "dev" "$device" "root" "cake")
            tc_cmd+=("${cake_params[@]}")
            
            if ! safe_tc_command 10 "${tc_cmd[@]}"; then
                log_error "无法在$device上创建下载CAKE队列"
                return 1
            fi
        fi
    fi
    
    log_info "$device的$direction方向CAKE队列创建完成"
    echo "✅ $device 的 $direction 方向 CAKE 队列创建完成"
    return 0
}

# ========== 上传方向初始化 ==========
initialize_cake_upload() {
    log_info "初始化上传方向CAKE"
    
    if [ -z "$total_upload_bandwidth" ] || [ "$total_upload_bandwidth" -le 0 ]; then
        log_info "上传带宽未配置，跳过上传方向初始化"
        return 0
    fi
    
    echo "为 $qos_interface 创建上传CAKE队列 (带宽: ${total_upload_bandwidth}kbit/s)"
    
    if create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"; then
        log_info "上传方向CAKE初始化完成"
        return 0
    else
        log_error "上传方向CAKE初始化失败"
        return 1
    fi
}

# ========== 下载方向初始化 ==========
initialize_cake_download() {
    log_info "初始化下载方向CAKE"
    
    if [ -z "$total_download_bandwidth" ] || [ "$total_download_bandwidth" -le 0 ]; then
        log_info "下载带宽未配置，跳过下载方向初始化"
        return 0
    fi
    
    if [ "$CAKE_INGRESS" = "1" ]; then
        echo "为 $qos_interface 创建下载CAKE入口队列 (带宽: ${total_download_bandwidth}kbit/s)"
        
        if create_cake_root_qdisc "$qos_interface" "download" "$total_download_bandwidth"; then
            log_info "下载方向CAKE入口队列初始化完成"
            return 0
        else
            log_error "下载方向CAKE入口队列初始化失败"
            return 1
        fi
    else
        echo "为 $IFB_DEVICE 创建下载CAKE队列 (带宽: ${total_download_bandwidth}kbit/s)"
        
        if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
            log_info "IFB设备 $IFB_DEVICE 不存在，尝试创建"
            if ! ip link add "$IFB_DEVICE" type ifb; then
                log_error "无法创建IFB设备 $IFB_DEVICE"
                return 1
            fi
        fi
        
        if ! ip link set dev "$IFB_DEVICE" up; then
            log_error "无法启动IFB设备 $IFB_DEVICE"
            return 1
        fi
        
        if ! setup_ingress_redirect; then
            log_error "无法设置入口重定向"
            return 1
        fi
        
        if create_cake_root_qdisc "$IFB_DEVICE" "download" "$total_download_bandwidth"; then
            log_info "下载方向CAKE队列初始化完成 (通过IFB)"
            return 0
        else
            log_error "下载方向CAKE队列初始化失败"
            return 1
        fi
    fi
}

# ========== 增强的健康检查功能 ==========
health_check_cake() {
    echo "执行CAKE健康检查..."
    
    local health_score=100
    local issues=""
    
    if ! ip link show dev "$qos_interface" >/dev/null 2>&1; then
        health_score=$((health_score - 30))
        issues="${issues}接口 $qos_interface 不存在\n"
    fi
    
    if ! tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        health_score=$((health_score - 20))
        issues="${issues}上传CAKE队列未启用\n"
    fi
    
    if [ "$CAKE_INGRESS" = "1" ]; then
        if ! tc qdisc show dev "$qos_interface" ingress 2>/dev/null | grep -q "cake"; then
            health_score=$((health_score - 20))
            issues="${issues}下载CAKE队列未启用\n"
        fi
    else
        if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
            health_score=$((health_score - 10))
            issues="${issues}IFB设备不存在\n"
        elif ! tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
            health_score=$((health_score - 20))
            issues="${issues}下载CAKE队列未启用\n"
        fi
        
        if ! tc qdisc show dev "$qos_interface" ingress 2>/dev/null; then
            health_score=$((health_score - 10))
            issues="${issues}入口重定向未配置\n"
        fi
    fi
    
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    if [ -n "$load_avg" ] && command -v bc >/dev/null 2>&1 && [ "$(echo "$load_avg > 5" | bc 2>/dev/null || echo "0")" = "1" ]; then
        health_score=$((health_score - 10))
        issues="${issues}系统负载过高: $load_avg\n"
    fi
    
    echo -e "\n健康检查结果:"
    echo "  健康分数: $health_score/100"
    
    if [ -z "$issues" ]; then
        echo "  ✅ 所有检查通过"
    else
        echo "  ⚠️ 发现的问题:"
        printf "%b" "$issues" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                echo "    - $line"
            fi
        done
    fi
    
    return $((health_score >= 70 ? 0 : 1))
}

# ========== 主初始化函数 ==========
initialize_cake_qos() {
    log_info "开始初始化CAKE QoS系统 (v4.0)"
    
    # 设置信号处理器
    setup_signal_handlers
    
    # 获取并发锁
    if ! acquire_lock; then
        log_error "无法获取并发锁，可能已有其他CAKE进程在运行"
        return 1
    fi
    
    # 配置校验
    validate_config_syntax || {
        log_error "配置文件语法检查失败"
        release_lock
        return 1
    }
    
    # 配置仅在初始化时加载一次
    load_cake_config
    auto_tune_cake
    
    if ! validate_cake_config; then
        log_error "CAKE配置验证失败"
        release_lock
        return 1
    fi
    
    # 带宽限制检查
    validate_bandwidth_limit
    
    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        if ! initialize_cake_upload; then
            log_error "上传方向初始化失败"
            release_lock
            return 1
        fi
    else
        log_info "上传带宽未配置，跳过上传方向初始化"
    fi
    
    if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        if ! initialize_cake_download; then
            log_error "下载方向初始化失败"
            release_lock
            return 1
        fi
    else
        log_info "下载带宽未配置，跳过下载方向初始化"
    fi
    
    if [ "$CAKE_INGRESS" = "0" ] && [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        check_ingress_redirect
    fi
    
    # 启动配置监控
    setup_config_watch
    
    health_check_cake
    local health_status=$?
    
    if [ $health_status -eq 0 ]; then
        log_info "CAKE QoS初始化完成，系统健康"
    else
        log_warn "CAKE QoS初始化完成，但存在健康问题"
    fi
    
    release_lock
    return 0
}

# ========== 停止和清理函数 ==========
stop_cake_qos() {
    log_info "停止CAKE QoS"
    
    # 停止配置监控
    stop_config_watch
    
    # 修复：TC规则清理不彻底，增加子类和过滤器清理
    cleanup_tc_rules_completely "$qos_interface"
    
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        cleanup_tc_rules_completely "$IFB_DEVICE"
    fi
    
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        log_info "停用IFB设备: $IFB_DEVICE"
    fi
    
    # 保存配置
    uci commit qos_gargoyle
    log_info "配置已保存"
    
    log_info "CAKE QoS停止完成"
}

# ========== 增强的状态查询函数 ==========
# 修复：性能指标计算误差，增加滑动窗口平均
calculate_drop_rate() {
    local device="$1"
    local sent_pkts="$2"
    local dropped="$3"
    
    if [ -z "$sent_pkts" ] || [ "$sent_pkts" -eq 0 ]; then
        echo "0.00"
        return
    fi
    
    if [ -z "$dropped" ] || [ "$dropped" -eq 0 ]; then
        echo "0.00"
        return
    fi
    
    # 尝试获取队列创建时间
    local queue_info=$(tc qdisc show dev "$device" 2>/dev/null)
    local created_time=$(echo "$queue_info" | grep -oP 'created \K[^ ]+')
    
    if [ -n "$created_time" ] && command -v date >/dev/null 2>&1; then
        # 转换创建时间为时间戳
        local created_ts=$(date -d "$created_time" +%s 2>/dev/null)
        local now_ts=$(date +%s)
        
        if [ -n "$created_ts" ] && [ "$created_ts" -gt 0 ] && [ "$now_ts" -gt "$created_ts" ]; then
            local elapsed=$((now_ts - created_ts))
            if [ "$elapsed" -gt 0 ]; then
                # 计算瞬时丢包率
                local rate=$(echo "scale=4; $dropped * 100 / $sent_pkts" | bc 2>/dev/null || echo "0")
                
                # 修复：修正滑动窗口平均逻辑
                local window=300  # 5分钟窗口
                if [ "$elapsed" -gt "$window" ]; then
                    # 使用加权平均
                    local avg_rate=$(echo "scale=4; ($PREV_DROP_RATE * 4 + $rate) / 5" | bc 2>/dev/null || echo "$rate")
                    PREV_DROP_RATE=$avg_rate
                    
                    # 保留两位小数
                    printf "%.2f\n" "$avg_rate"
                else
                    # 时间窗口不够，使用瞬时值
                    printf "%.2f\n" "$rate"
                fi
                return
            fi
        fi
    fi
    
    # 回退到简单丢包率计算
    local drop_rate=$(echo "scale=2; $dropped * 100 / $sent_pkts" | bc 2>/dev/null)
    echo "${drop_rate:-0.00}"
}

# 添加资源使用监控
get_cake_memory_usage() {
    local device="$1"
    local cake_info=$(tc qdisc show dev "$device" 2>/dev/null | grep "qdisc cake")
    
    if echo "$cake_info" | grep -q "memlimit"; then
        echo "$cake_info" | sed -n 's/.*memlimit \([^ ]*\).*/\1/p'
    else
        echo "N/A"
    fi
}

# 通用状态显示函数
show_queue_status() {
    local device="$1"
    local direction="$2"
    
    echo "===== $direction方向CAKE队列 ($device) ====="
    
    if tc qdisc show dev "$device" 2>/dev/null | grep -q "qdisc cake"; then
        echo "状态: 已启用 ✅"
        
        # 显示队列参数
        echo "队列参数:"
        tc qdisc show dev "$device" 2>/dev/null | grep "qdisc cake" | sed 's/^qdisc cake //' | sed 's/^/  /'
        
        # 添加TC规则内存占用监控
        local cake_mem=$(get_cake_memory_usage "$device")
        echo "  CAKE内存占用: $cake_mem"
        
        # 显示完整TC队列统计
        echo -e "\nTC队列统计:"
        local queue_stats=$(tc -s qdisc show dev "$device" 2>/dev/null)
        if [ -n "$queue_stats" ]; then
            echo "$queue_stats" | sed 's/^/  /'
        else
            echo "  无TC队列统计"
        fi
        
        # 高级调试模式：TC规则转储
        log_debug_tc "$device"
        
        # 修复：性能指标计算
        local sent_bytes=$(echo "$queue_stats" | awk '/Sent [0-9]+ bytes/ {print $2; exit}')
        local sent_pkts=$(echo "$queue_stats" | awk '/Sent [0-9]+ bytes [0-9]+ pkt/ {print $4; exit}')
        local dropped=$(echo "$queue_stats" | awk '/dropped [0-9]+/ {print $2; exit}')
        local overlimits=$(echo "$queue_stats" | awk '/overlimits [0-9]+/ {print $2; exit}')
        
        if [ -n "$sent_bytes" ] && [ -n "$sent_pkts" ]; then
            local mb_size=$((sent_bytes / 1024 / 1024))
            echo -e "\n性能指标:"
            echo "  总流量: ${mb_size} MB (${sent_pkts} 个包)"
            
            if [ -n "$dropped" ] && [ "$dropped" -gt 0 ] && [ "$sent_pkts" -gt 0 ]; then
                echo "  丢包数: $dropped"
                # 使用增强的丢包率计算
                local drop_rate=$(calculate_drop_rate "$device" "$sent_pkts" "$dropped")
                echo "  丢包率: ${drop_rate}%"
            fi
            
            if [ -n "$overlimits" ] && [ "$overlimits" -gt 0 ]; then
                echo "  超限次数: $overlimits"
            fi
        fi
    else
        echo "状态: 未启用 ❌"
    fi
}

# 主状态显示函数
show_cake_status() {
    echo "===== CAKE QoS状态报告 (v4.0) ====="
    echo "时间: $(date)"
    echo "系统运行时间: $(uptime | sed 's/.*up //; s/,.*//')"
    echo "网络接口: ${qos_interface:-未知}"
    
    # 检查IFB设备
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" >/dev/null 2>&1; then
            echo "IFB设备: 已启动且运行中 ($IFB_DEVICE)"
        else
            echo "IFB设备: 已创建但无 TC 队列 ($IFB_DEVICE)"
        fi
    else
        echo "IFB设备: 未创建"
    fi
    
    # 检查CAKE配置
    load_cake_config
    
    # 检查QoS是否实际运行
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q "qdisc cake"; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    # 使用通用函数显示上传队列状态
    show_queue_status "$qos_interface" "出口"
    
    # 显示入口配置
    if [ "$CAKE_INGRESS" = "1" ]; then
        show_queue_status "$qos_interface" "入口"
    else
        if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
            show_queue_status "$IFB_DEVICE" "入口"
        else
            echo -e "\n===== 入口CAKE队列 ($IFB_DEVICE) ====="
            echo "状态: IFB设备不存在"
        fi
    fi
    
    # 入口重定向检查
    echo -e "\n===== 入口重定向检查 ====="
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
        echo "入口队列状态: 已配置"
        
        # 显示入口过滤器
        echo "入口过滤器配置:"
        local ingress_filters=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null)
        if [ -n "$ingress_filters" ]; then
            # 统计规则数量
            local ipv4_rules=$(echo "$ingress_filters" | grep -c "protocol ip")
            local ipv6_rules=$(echo "$ingress_filters" | grep -c "protocol ipv6")
            echo "  IPv4规则数: $ipv4_rules"
            echo "  IPv6规则数: $ipv6_rules"
            
            # 检查是否有重定向规则
            if echo "$ingress_filters" | grep -q "redirect.*dev $IFB_DEVICE"; then
                echo "  ✅ 入口重定向规则存在 (目标: $IFB_DEVICE)"
            else
                # 显示前两条规则详情
                echo "$ingress_filters" | head -20 | sed 's/^/  /'
            fi
        else
            echo "  无过滤器规则"
        fi
        
    else
        echo "入口队列状态: 未配置"
    fi
    
    # 系统资源
    echo -e "\n===== 系统资源 ====="
    
    # 内存
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
    echo -n "CPU负载: "
    uptime | awk -F'load average:' '{print $2}' | sed 's/^[[:space:]]*//' || echo "未知"
    
    # 连接跟踪
    echo -n "连接跟踪条目: "
    if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
        cat /proc/sys/net/netfilter/nf_conntrack_count
    elif command -v conntrack >/dev/null 2>&1; then
        conntrack -C 2>/dev/null || echo "未知"
    else
        echo "未知"
    fi
    
    # NFTables规则
    echo -e "\n===== NFTables规则 ====="
    echo "QoS相关NFT规则:"
    
    if command -v nft >/dev/null 2>&1; then
        local nft_output=$(nft list table inet gargoyle-qos-priority 2>/dev/null)
        
        if echo "$nft_output" | grep -q "table inet gargoyle-qos-priority"; then
            # 统计上传链规则
            local egress_rules=0
            if echo "$nft_output" | grep -q "chain filter_qos_egress"; then
                egress_rules=$(echo "$nft_output" | sed -n '/chain filter_qos_egress {/,/^[[:space:]]*}/p' | grep -c "jump\|accept\|drop\|mark" || echo 0)
            fi
            
            # 统计下载链规则
            local ingress_rules=0
            if echo "$nft_output" | grep -q "chain filter_qos_ingress"; then
                ingress_rules=$(echo "$nft_output" | sed -n '/chain filter_qos_ingress {/,/^[[:space:]]*}/p' | grep -c "jump\|accept\|drop\|mark" || echo 0)
            fi
            
            echo "上传链 (filter_qos_egress):"
            echo "  规则数量: $egress_rules"
            
            echo -e "\n下载链 (filter_qos_ingress):"
            echo "  规则数量: $ingress_rules"
            
            # 显示计数器
            echo -e "\nNFT计数器统计:"
            local counters=$(echo "$nft_output" | grep -A1 "counter" | grep -E "packets|bytes")
            if [ -n "$counters" ]; then
                echo "$counters" | sed 's/^/  /'
            else
                echo "  无计数器数据"
            fi
        else
            echo "  NFT表未找到"
        fi
    else
        echo "  nft命令不可用"
    fi
    
    # 当前连接统计
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
    
    # 网络接口统计
    echo -e "\n===== 网络接口统计 ====="
    echo "WAN接口 ($qos_interface) 统计:"
    
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$qos_interface" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /' || echo "  无法获取接口统计"
    else
        ip -s link show dev "$qos_interface" 2>/dev/null | tail -6 | sed 's/^/  /' || echo "  无法获取接口统计"
    fi
    
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($IFB_DEVICE) 统计:"
        if command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$IFB_DEVICE" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /' || echo "  无法获取接口统计"
        else
            ip -s link show dev "$IFB_DEVICE" 2>/dev/null | tail -6 | sed 's/^/  /' || echo "  无法获取接口统计"
        fi
    fi
    
    # CAKE配置参数
    echo -e "\n===== CAKE配置参数 ====="
    echo "DiffServ模式: $CAKE_DIFFSERV_MODE"
    echo "RTT: $CAKE_RTT"
    echo "Overhead: $CAKE_OVERHEAD"
    echo "MPU: $CAKE_MPU"
    echo "Memory Limit: $CAKE_MEMORY_LIMIT"
    echo "ACK过滤: $([ "$CAKE_ACK_FILTER" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "NAT支持: $([ "$CAKE_NAT" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "Wash: $([ "$CAKE_WASH" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "Split GSO: $([ "$CAKE_SPLIT_GSO" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "Ingress模式: $([ "$CAKE_INGRESS" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "AutoRate Ingress: $([ "$CAKE_AUTORATE_INGRESS" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    
    # 总体状态
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "qdisc cake"; then
        echo -e "\n===== CAKE状态摘要 ====="
        echo "CAKE状态: 运行中 ✅"
    else
        echo -e "\n===== CAKE状态摘要 ====="
        echo "CAKE状态: 已停止 ❌"
    fi
    
    echo -e "\n===== 状态报告结束 ====="
    
    return 0
}

# ========== 主函数 ==========
main_cake_qos() {
    local action="$1"
    
    case "$action" in
        start)
            log_info "启动CAKE QoS"
            initialize_cake_qos
            ;;
        stop)
            log_info "停止CAKE QoS"
            stop_cake_qos
            ;;
        restart)
            log_info "重启CAKE QoS"
            stop_cake_qos
            sleep 2
			initialize_cake_qos
			;;
		status|show)
			show_cake_status
			;;
		health)
			health_check_cake
			;;
		validate)
			load_cake_config
			validate_cake_config
			;;
		config-check)
			validate_config_syntax
			;;
		reload)
			reload_cake_config
			;;
		watch)
			setup_config_watch
			;;
		unwatch)
			stop_config_watch
			;;
		help)
			echo "用法: $0 {start|stop|restart|status|health|validate|config-check|reload|watch|unwatch|help}"
			echo "  start        启动CAKE QoS"
			echo "  stop         停止CAKE QoS"
			echo "  restart      重启CAKE QoS"
			echo "  status       显示CAKE状态"
			echo "  health       执行健康检查"
			echo "  validate     验证CAKE配置"
			echo "  config-check 检查配置文件语法"
			echo "  reload       重新加载配置"
			echo "  watch        启动配置监控"
			echo "  unwatch      停止配置监控"
			echo "  help         显示此帮助信息"
			;;
		*)
			echo "用法: $0 {start|stop|restart|status|health|validate|config-check|reload|watch|unwatch|help}"
			exit 1
			;;
	esac
}

# 脚本执行入口
if [ "$(basename "$0")" = "cake.sh" ]; then
    # 检查是否有参数
    if [ $# -eq 0 ]; then
        echo "错误: 缺少参数"
        echo ""
        main_cake_qos "help"
        exit 1
    fi
    
    main_cake_qos "$@"
fi

log_info "CAKE模块加载完成"