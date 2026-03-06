#!/bin/sh
# cake_autorate 动态带宽调整模块
# 通过测量延迟自动调整CAKE带宽参数
# version=1.0

# 加载必要的库
. /lib/functions.sh
. /lib/functions/network.sh

# 加载CAKE配置
[ -f "/usr/lib/qos_gargoyle/cake.sh" ] && . /usr/lib/qos_gargoyle/cake.sh

# ========== 全局变量 ==========
AUTORATE_RUNNING=0
AUTORATE_PID=""
LAST_UPLOAD_BANDWIDTH=0
LAST_DOWNLOAD_BANDWIDTH=0
MEASUREMENT_HISTORY=""  # 用于存储延迟测量历史
MONITORING_INTERVAL=10  # 每10次循环执行一次性能监控
# 必要的路径变量
SHARED_CONFIG_DIR="/tmp/qos_gargoyle"
AUTORATE_STATUS_FILE="$SHARED_CONFIG_DIR/cake_autorate.status"
CONFIG_LOCK="$SHARED_CONFIG_DIR/autorate.lock"

# ========== 延迟测量函数 ==========
measure_latency() {
    local target_host="$1"
    local result=""
    
    # 使用ping测量延迟
    if command -v ping >/dev/null 2>&1; then
        # 使用更严格的参数
        result=$(ping -c 1 -W 2 "$target_host" 2>/dev/null | \
            grep -o "time=[0-9.]*" | \
            cut -d= -f2 2>/dev/null)
        
        # 如果没有结果，尝试多次测量
        if [ -z "$result" ]; then
            result=$(ping -c 3 -i 0.2 -W 1 "$target_host" 2>/dev/null | \
                grep -E "min/avg/max" | \
                awk -F'/' '{print $5}' 2>/dev/null)
        fi
    fi
    
    # 如果还是没有结果，返回空
    if [ -z "$result" ]; then
        echo ""
    else
        # 清理结果，只返回数字
        echo "$result" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
    fi
}

# 测量多个目标，取最佳延迟
measure_best_latency() {
    local best_rtt=""
    local valid_measurements=0
    
    for host in $CAKE_AUTORATE_PING_HOSTS; do
        local rtt=$(measure_latency "$host")
        
        # 调试：记录原始测量结果
        log_debug "测量 $host: 原始结果='$rtt'"
        
        # 清理结果：只保留数字和小数点
        if [ -n "$rtt" ]; then
            # 提取纯数字（包括小数点）
            rtt=$(echo "$rtt" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
            
            if [ -n "$rtt" ] && [ "$rtt" != "0" ] && [ "$rtt" != "0.0" ]; then
                if [ -z "$best_rtt" ] || [ "$(echo "$rtt < $best_rtt" | bc 2>/dev/null || echo 0)" = "1" ]; then
                    best_rtt="$rtt"
                    valid_measurements=$((valid_measurements + 1))
                fi
            fi
        fi
    done
    
    # 如果没有测量到有效延迟
    if [ "$valid_measurements" -eq 0 ]; then
        # 只记录日志，不返回任何信息
        log_warn "所有ping目标均无响应，延迟测量失败"
        echo ""  # 返回空字符串
    else
        # 再次清理确保只有数字
        echo "$best_rtt" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
    fi
}

# ========== 带宽计算函数 ==========
calculate_new_bandwidth() {
    local current_bw="$1"
    local current_rtt="$2"
    local direction="$3"
    
    # 检查是否测量失败（RTT为0或空）
    if [ -z "$current_rtt" ] || [ "$current_rtt" = "0" ]; then
        # 延迟测量失败，不调整带宽
        log_debug "${direction}方向延迟测量失败，保持当前带宽: ${current_bw}kbit"
        echo "$current_bw"
        return
    fi
    
    # 检查RTT是否为有效数字
    if ! echo "$current_rtt" | grep -qE '^[0-9]+(\.[0-9]+)?(ms|s)?$'; then
        log_warn "${direction}方向延迟测量值无效: '$current_rtt'，保持当前带宽"
        echo "$current_bw"
        return
    fi
    
    # 将RTT转换为毫秒数值
    local rtt_ms=0
    if echo "$current_rtt" | grep -q "ms"; then
        rtt_ms=$(echo "$current_rtt" | sed 's/ms//' | awk '{print int($1)}')
    elif echo "$current_rtt" | grep -q "s"; then
        rtt_ms=$(echo "$current_rtt" | sed 's/s//' | awk '{print int($1 * 1000)}')
    else
        rtt_ms=$(echo "$current_rtt" | awk '{print int($1)}')
    fi
    
    # 检查RTT值是否合理（0-1000ms之间）
    if [ "$rtt_ms" -lt 0 ] || [ "$rtt_ms" -gt 1000 ]; then
        log_warn "${direction}方向延迟值异常: ${rtt_ms}ms，保持当前带宽"
        echo "$current_bw"
        return
    fi
    
    # 获取配置的RTT阈值
    local min_rtt_ms=$(echo "$CAKE_AUTORATE_MIN_RTT" | sed 's/ms//' | awk '{print int($1)}')
    local max_rtt_ms=$(echo "$CAKE_AUTORATE_MAX_RTT" | sed 's/ms//' | awk '{print int($1)}')
    
    # 修复：正确获取基础带宽
    local base_bw=0
    if [ "$direction" = "upload" ]; then
        # 尝试从共享变量读取
        base_bw=$(get_shared_variable "total_upload_bandwidth")
        [ -z "$base_bw" ] && base_bw="$total_upload_bandwidth"
    else
        # 尝试从共享变量读取
        base_bw=$(get_shared_variable "total_download_bandwidth")
        [ -z "$base_bw" ] && base_bw="$total_download_bandwidth"
    fi
    
    # 获取带宽限制范围
    local min_bw=$((base_bw * CAKE_AUTORATE_MIN_BW_PERCENT / 100))
    local max_bw=$((base_bw * CAKE_AUTORATE_MAX_BW_PERCENT / 100))
    
    local new_bw="$current_bw"
    
    if [ "$rtt_ms" -gt "$max_rtt_ms" ]; then
        # 延迟过高，降低带宽（每次降低10%）
        new_bw=$((current_bw * 90 / 100))
        [ "$new_bw" -lt "$min_bw" ] && new_bw="$min_bw"
        log_info "🚨 高延迟 (${rtt_ms}ms > ${max_rtt_ms}ms)，降低${direction}带宽: ${current_bw} -> ${new_bw}kbit"
        
    elif [ "$rtt_ms" -lt "$min_rtt_ms" ]; then
        # 延迟很低，尝试增加带宽（每次增加5%）
        new_bw=$((current_bw * 105 / 100))
        [ "$new_bw" -gt "$max_bw" ] && new_bw="$max_bw"
        log_info "✅ 低延迟 (${rtt_ms}ms < ${min_rtt_ms}ms)，增加${direction}带宽: ${current_bw} -> ${new_bw}kbit"
        
    else
        # 延迟在正常范围内，微调（±2%）
        local random_adj=$((RANDOM % 5 - 2))  # -2% 到 +2%
        new_bw=$((current_bw * (100 + random_adj) / 100))
        [ "$new_bw" -lt "$min_bw" ] && new_bw="$min_bw"
        [ "$new_bw" -gt "$max_bw" ] && new_bw="$max_bw"
    fi
    
    echo "$new_bw"
}

# ========== 性能监控函数 ==========
monitor_autorate_performance() {
    local monitor_file="$SHARED_CONFIG_DIR/autorate_monitor"
    local current_time=$(date +%s)
    
    # 收集性能指标
    local cpu_usage=0
    local memory_usage=0
    local load_avg=0
    
    # 获取CPU使用率
	if command -v top >/dev/null 2>&1; then
		cpu_usage=$(top -bn1 2>/dev/null | grep "CPU:" | awk '{print $2}' | tr -d '%' 2>/dev/null || echo "0")
	elif [ -f /proc/stat ]; then
		# 备选方案：从/proc/stat计算
		local cpu_line=$(head -n 1 /proc/stat 2>/dev/null)
		local user=$(echo "$cpu_line" | awk '{print $2}')
		local nice=$(echo "$cpu_line" | awk '{print $3}')
		local system=$(echo "$cpu_line" | awk '{print $4}')
		local idle=$(echo "$cpu_line" | awk '{print $5}')
		local total=$((user + nice + system + idle))
    
		# 有效性检查
		if [ "$total" -gt 1000 ]; then  # 确保有足够的数据
			cpu_usage=$((100 - (idle * 100 / total)))
		else
			cpu_usage=0
			log_debug "系统运行时间较短，跳过CPU使用率计算"
		fi
	fi
    
    # 获取内存使用率
    if [ -f /proc/meminfo ]; then
        local mem_total=$(grep "MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}')
        local mem_available=$(grep "MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [ -n "$mem_total" ] && [ -n "$mem_available" ] && [ "$mem_total" -gt 0 ]; then
            memory_usage=$(echo "scale=1; ($mem_total - $mem_available) * 100 / $mem_total" | bc 2>/dev/null || echo "0")
        fi
    fi
    
    # 获取系统负载
    if [ -f /proc/loadavg ]; then
        load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' 2>/dev/null || echo "0")
    fi
    
    # 记录到监控文件
    echo "$current_time:$cpu_usage:$memory_usage:$load_avg" >> "$monitor_file" 2>/dev/null
    
    # 保持最近1000条记录
    tail -n 1000 "$monitor_file" 2>/dev/null > "$monitor_file.tmp" 2>/dev/null && \
        mv "$monitor_file.tmp" "$monitor_file" 2>/dev/null
    
    log_debug "性能监控: CPU=${cpu_usage}%, 内存=${memory_usage}%, 负载=${load_avg}"
}

# ========== 自适应调整策略 ==========
analyze_network_stability() {
    # 分析网络稳定性得分（0-100，越高越稳定）
    local score=50  # 默认分数
    
    if [ -n "$MEASUREMENT_HISTORY" ] && [ "$MEASUREMENT_HISTORY" != "0" ] && [ "$MEASUREMENT_HISTORY" != "" ]; then
        # 计算最近10次测量的平均值
        local recent_measurements=$(echo "$MEASUREMENT_HISTORY" | tr ',' '\n' | tail -10 | grep -v '^$' | grep -E '^[0-9]+(\.[0-9]+)?$')
        local count=$(echo "$recent_measurements" | wc -l)
        
        if [ "$count" -ge 5 ]; then
            # 计算平均值
            local sum=0
            local values=0
            for rtt in $recent_measurements; do
                # 使用bc进行浮点计算
                sum=$(echo "$sum + $rtt" | bc 2>/dev/null || echo "$sum")
                values=$((values + 1))
            done
            
            if [ "$values" -gt 0 ]; then
                local avg=$(echo "scale=2; $sum / $values" | bc 2>/dev/null || echo "0")
                
                # 计算稳定性：延迟越低、波动越小，分数越高
                if [ "$avg" != "0" ] && [ "$(echo "$avg < 50" | bc 2>/dev/null || echo 0)" = "1" ]; then
                    score=85
                elif [ "$(echo "$avg < 100" | bc 2>/dev/null || echo 0)" = "1" ]; then
                    score=70
                elif [ "$(echo "$avg < 200" | bc 2>/dev/null || echo 0)" = "1" ]; then
                    score=60
                else
                    score=40
                fi
            fi
        fi
    fi
    
    echo "$score"
}

adaptive_autorate_tuning() {
    local adaptive_file="$SHARED_CONFIG_DIR/adaptive_tuning"
    local current_time=$(date +%s)
    
    # 读取历史调整数据
    if [ -f "$adaptive_file" ]; then
        local last_time=$(tail -n 1 "$adaptive_file" 2>/dev/null | cut -d: -f1 2>/dev/null || echo 0)
        local time_diff=$((current_time - last_time))
        
        # 如果距离上次调整超过1小时，重新评估参数
        if [ "$time_diff" -gt 3600 ]; then
            # 分析网络稳定性
            local stability_score=$(analyze_network_stability)
            
            # 根据稳定性调整参数
            if [ "$stability_score" -lt 50 ]; then
                # 网络不稳定，增加间隔，减小调整幅度
                local new_interval=$((CAKE_AUTORATE_INTERVAL + 5))
                [ "$new_interval" -gt 60 ] && new_interval=60
                if [ "$new_interval" -ne "$CAKE_AUTORATE_INTERVAL" ]; then
                    CAKE_AUTORATE_INTERVAL="$new_interval"
                    log_info "网络不稳定(分数:${stability_score})，增加调整间隔到 ${CAKE_AUTORATE_INTERVAL}s"
                fi
            elif [ "$stability_score" -gt 80 ]; then
                # 网络稳定，减小间隔
                local new_interval=$((CAKE_AUTORATE_INTERVAL - 2))
                [ "$new_interval" -lt 5 ] && new_interval=5
                if [ "$new_interval" -ne "$CAKE_AUTORATE_INTERVAL" ]; then
                    CAKE_AUTORATE_INTERVAL="$new_interval"
                    log_info "网络稳定(分数:${stability_score})，减少调整间隔到 ${CAKE_AUTORATE_INTERVAL}s"
                fi
            fi
            
            # 记录调整
            echo "$current_time:$stability_score:$CAKE_AUTORATE_INTERVAL" >> "$adaptive_file" 2>/dev/null
        fi
    else
        # 初始化文件
        echo "$current_time:0:$CAKE_AUTORATE_INTERVAL" > "$adaptive_file" 2>/dev/null
    fi
}

# ========== 监控参数调整函数 ==========
check_and_adjust_monitoring_interval() {
    # 根据系统负载调整监控间隔
    local load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' 2>/dev/null || echo "0")
    local cpu_count=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo 1)
    
    if [ -n "$load_avg" ] && [ -n "$cpu_count" ]; then
        # 计算负载百分比
        local load_percent=$(echo "scale=2; $load_avg * 100 / $cpu_count" | bc 2>/dev/null || echo "0")
        
        if [ "$(echo "$load_percent > 80" | bc 2>/dev/null || echo 0)" = "1" ]; then
            # 高负载，增加监控间隔
            if [ "$MONITORING_INTERVAL" -lt 30 ]; then
                MONITORING_INTERVAL=$((MONITORING_INTERVAL + 5))
                log_info "系统负载高(${load_percent}%)，增加性能监控间隔到每${MONITORING_INTERVAL}次循环"
            fi
        elif [ "$(echo "$load_percent < 30" | bc 2>/dev/null || echo 0)" = "1" ]; then
            # 低负载，减少监控间隔
            if [ "$MONITORING_INTERVAL" -gt 5 ]; then
                MONITORING_INTERVAL=$((MONITORING_INTERVAL - 2))
                [ "$MONITORING_INTERVAL" -lt 5 ] && MONITORING_INTERVAL=5
                log_info "系统负载低(${load_percent}%)，减少性能监控间隔到每${MONITORING_INTERVAL}次循环"
            fi
        fi
    fi
}

# ========== 配置持久化函数 ==========
save_bandwidth_to_config() {
    if [ "$CAKE_AUTORATE_PERSIST" = "1" ]; then
        log_info "保存带宽配置到UCI配置 [上次保存: ${last_config_save_time}, 间隔: ${config_save_interval}s]"
        uci set qos_gargoyle.upload.total_bandwidth="$total_upload_bandwidth"
        uci set qos_gargoyle.download.total_bandwidth="$total_download_bandwidth"
        uci commit qos_gargoyle
        log_info "配置已保存: 上传=${total_upload_bandwidth}kbit, 下载=${total_download_bandwidth}kbit"
    else
        log_debug "配置持久化未启用，跳过保存"
    fi
}

#自动调整
autorate_adjustment_loop() {
    # 错误处理：捕获所有异常
    set -e
    trap 'echo "cake_autorate异常退出，错误码: $?"; exit 1' ERR
    trap 'echo "收到信号，清理退出"; rm -f /var/run/cake_autorate.pid /tmp/run/cake_autorate.pid; exit 0' INT TERM EXIT
    
    # 创建PID文件
    echo $$ > /var/run/cake_autorate.pid
    echo "cake_autorate进程启动: $$"
    
    # 检查网络连通性
    echo "检查网络连通性..."
    for host in 223.5.5.5 119.29.29.29; do
        if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
            echo "主机 $host 可达"
            break
        fi
    done
    
    AUTORATE_RUNNING=1
    local cycle_count=0
    local consecutive_failures=0
    local max_failures=5
    local performance_counter=0
    local last_adaptive_tuning_time=$(date +%s)
    local adaptive_tuning_interval=3600  # 1小时
    local last_rtt=0
    local rtt_trend=""
	# 配置持久化节流变量
    local last_config_save_time=0
    local config_save_interval=300  # 5分钟
    
    # 创建性能监控文件
    local monitor_file="$SHARED_CONFIG_DIR/autorate_monitor"
    local adaptive_file="$SHARED_CONFIG_DIR/adaptive_tuning"
    mkdir -p "$SHARED_CONFIG_DIR" 2>/dev/null
    
    while [ "$AUTORATE_RUNNING" -eq 1 ]; do
		# 获取当前的监控间隔
        local current_monitoring_interval="$MONITORING_INTERVAL"
        local loop_start_time=$(date +%s)
        cycle_count=$((cycle_count + 1))
        
        # 记录循环开始
        log_debug "第 ${cycle_count} 次调整循环开始"
        
        # 1. 测量当前延迟
        local current_rtt=$(measure_best_latency)
		log_debug "测量结果: '$current_rtt'"
        
        if [ "$current_rtt" = "0" ] || [ -z "$current_rtt" ]; then
			log_warn "延迟测量失败，所有测量目标均无响应"
			consecutive_failures=$((consecutive_failures + 1))
    
			if [ "$consecutive_failures" -ge "$max_failures" ]; then
				log_error "连续 ${max_failures} 次测量失败，暂停调整循环30秒"
				sleep 30
				consecutive_failures=0
				continue
			fi
    
			sleep "$CAKE_AUTORATE_INTERVAL"
			continue
		fi
        
        # 重置连续失败计数
        consecutive_failures=0
        
        # 分析RTT趋势
        if [ -n "$last_rtt" ] && [ "$last_rtt" != "0" ]; then
			if [ "$(echo "$current_rtt > $last_rtt" | bc 2>/dev/null || echo 0)" = "1" ]; then
				rtt_trend="上升"
			elif [ "$(echo "$current_rtt < $last_rtt" | bc 2>/dev/null || echo 0)" = "1" ]; then
				rtt_trend="下降"
			else
			rtt_trend="稳定"
			fi
		else
			rtt_trend="首次测量"
		fi
		
        last_rtt="$current_rtt"
        
        log_info "当前最佳延迟: ${current_rtt}ms (趋势: $rtt_trend)"
        
        # 记录测量历史
        MEASUREMENT_HISTORY="${MEASUREMENT_HISTORY}${current_rtt},"
        MEASUREMENT_HISTORY=$(echo "$MEASUREMENT_HISTORY" | sed 's/^[^,]*,//' | tr -cd '0-9.,' | tail -c 200)
        
        # 2. 获取当前带宽（使用原子读取）
        local current_upload_bw=$(get_shared_variable "total_upload_bandwidth")
        local current_download_bw=$(get_shared_variable "total_download_bandwidth")
        
        # 如果没有从共享文件读取到值，使用本地变量
        [ -z "$current_upload_bw" ] && current_upload_bw="$total_upload_bandwidth"
        [ -z "$current_download_bw" ] && current_download_bw="$total_download_bandwidth"
        
        # 3. 计算新带宽
        local upload_updated=0
        local download_updated=0
        
        if [ "$current_upload_bw" -gt 0 ] 2>/dev/null; then
            local new_upload_bw=$(calculate_new_bandwidth "$current_upload_bw" "${current_rtt}ms" "upload")
            
            if [ -n "$new_upload_bw" ] && [ "$new_upload_bw" -gt 0 ] 2>/dev/null && [ "$new_upload_bw" -ne "$current_upload_bw" ] 2>/dev/null; then
                # 获取锁
                if acquire_lock "$CONFIG_LOCK" 5; then
                    # 更新上传带宽
                    if update_cake_bandwidth "$qos_interface" "upload" "$new_upload_bw"; then
                        # 原子写入共享变量
                        set_shared_variable "total_upload_bandwidth" "$new_upload_bw"
                        LAST_UPLOAD_BANDWIDTH="$new_upload_bw"
                        
                        # 同时更新本地变量
                        total_upload_bandwidth="$new_upload_bw"
                        upload_updated=1
                        
                        # 记录带宽调整历史
                        local bw_history_file="$SHARED_CONFIG_DIR/upload_bandwidth_history"
                        echo "$(date +%s):$new_upload_bw" >> "$bw_history_file" 2>/dev/null
                        # 保留最近100条记录
                        tail -n 100 "$bw_history_file" 2>/dev/null > "$bw_history_file.tmp" 2>/dev/null && \
                            mv "$bw_history_file.tmp" "$bw_history_file" 2>/dev/null
                    fi
                    release_lock "$CONFIG_LOCK"
                fi
            fi
        fi
        
        if [ "$current_download_bw" -gt 0 ] 2>/dev/null; then
            local new_download_bw=$(calculate_new_bandwidth "$current_download_bw" "${current_rtt}ms" "download")
            
            if [ -n "$new_download_bw" ] && [ "$new_download_bw" -gt 0 ] 2>/dev/null && [ "$new_download_bw" -ne "$current_download_bw" ] 2>/dev/null; then
                # 获取锁
                if acquire_lock "$CONFIG_LOCK" 5; then
                    # 更新下载带宽
                    local target_device="$IFB_DEVICE"
                    [ "$CAKE_INGRESS" = "1" ] && target_device="$qos_interface"
                    
                    if update_cake_bandwidth "$target_device" "download" "$new_download_bw"; then
                        # 原子写入共享变量
                        set_shared_variable "total_download_bandwidth" "$new_download_bw"
                        LAST_DOWNLOAD_BANDWIDTH="$new_download_bw"
                        
                        # 同时更新本地变量
                        total_download_bandwidth="$new_download_bw"
                        download_updated=1
                        
                        # 记录带宽调整历史
                        local bw_history_file="$SHARED_CONFIG_DIR/download_bandwidth_history"
                        echo "$(date +%s):$new_download_bw" >> "$bw_history_file" 2>/dev/null
                        # 保留最近100条记录
                        tail -n 100 "$bw_history_file" 2>/dev/null > "$bw_history_file.tmp" 2>/dev/null && \
                            mv "$bw_history_file.tmp" "$bw_history_file" 2>/dev/null
                    fi
                    release_lock "$CONFIG_LOCK"
                fi
            fi
        fi
        
		# 4. 性能监控（每10次循环执行一次）
        performance_counter=$((performance_counter + 1))
        # 使用局部变量
        if [ $performance_counter -ge $current_monitoring_interval ]; then
            monitor_autorate_performance
            performance_counter=0
        fi
        
        # 5. 自适应调整策略（每小时执行一次）
        local current_time=$(date +%s)
        if [ $((current_time - last_adaptive_tuning_time)) -ge $adaptive_tuning_interval ]; then
            adaptive_autorate_tuning
            last_adaptive_tuning_time=$current_time
        fi
        
        # 6. 将当前状态写入状态文件（原子操作）
        local status_temp_file="$AUTORATE_STATUS_FILE.tmp.$$"
        {
            echo "upload:$total_upload_bandwidth"
            echo "download:$total_download_bandwidth"
            echo "rtt:$current_rtt"
            echo "cycle:$cycle_count"
            echo "timestamp:$(date +%s)"
            echo "history:$MEASUREMENT_HISTORY"
            echo "trend:$rtt_trend"
            echo "last_upload_change:$LAST_UPLOAD_BANDWIDTH"
            echo "last_download_change:$LAST_DOWNLOAD_BANDWIDTH"
            echo "upload_updated:$upload_updated"
            echo "download_updated:$download_updated"
            echo "performance_counter:$performance_counter"
            echo "adaptive_next:$((last_adaptive_tuning_time + adaptive_tuning_interval))"
        } > "$status_temp_file" 2>/dev/null
        
        if [ -f "$status_temp_file" ]; then
            mv "$status_temp_file" "$AUTORATE_STATUS_FILE" 2>/dev/null
        fi
        
		# 保存配置到UCI（如果启用），使用节流机制
		local current_time=$(date +%s)
		if [ "$CAKE_AUTORATE_PERSIST" = "1" ] && 
			[ $((current_time - last_config_save_time)) -ge $config_save_interval ] &&
			([ "$upload_updated" -eq 1 ] || [ "$download_updated" -eq 1 ]); then
			save_bandwidth_to_config
			last_config_save_time=$current_time
		fi

        # 7. 记录日志
        local update_status=""
        [ "$upload_updated" -eq 1 ] && update_status="${update_status}上传已更新 "
        [ "$download_updated" -eq 1 ] && update_status="${update_status}下载已更新 "
        [ -z "$update_status" ] && update_status="无变化"
        
        log_info "调整完成 - 上传: ${total_upload_bandwidth}kbit, 下载: ${total_download_bandwidth}kbit, 延迟: ${current_rtt}ms ($rtt_trend) [$update_status]"
        
        # 8. 等待下一个周期，考虑循环执行时间
        local loop_end_time=$(date +%s)
        local loop_duration=$((loop_end_time - loop_start_time))
        local sleep_time=$((CAKE_AUTORATE_INTERVAL - loop_duration))
        
        if [ "$sleep_time" -gt 0 ]; then
            # 计算精确的睡眠时间，考虑循环执行时间
            if [ "$loop_duration" -gt "$CAKE_AUTORATE_INTERVAL" ]; then
                log_warn "调整循环执行时间 ${loop_duration}s 超过间隔 ${CAKE_AUTORATE_INTERVAL}s，立即开始下一轮"
            else
                sleep "$sleep_time"
            fi
        else
            log_warn "调整循环执行时间 ${loop_duration}s 超过间隔 ${CAKE_AUTORATE_INTERVAL}s，立即开始下一轮"
        fi
        
        # 9. 检查是否需要调整监控参数（基于系统负载）
        if [ $cycle_count -ge 100 ]; then
            check_and_adjust_monitoring_interval
        fi
    done
}

# ========== 控制函数 ==========
start_cake_autorate() {
    # 强化的单实例检查
    local lock_file="/var/run/cake_autorate.lock"
    local pid_file="/var/run/cake_autorate.pid"
    
    # 检查锁文件
    if [ -f "$lock_file" ]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null 2>&1; then
            echo "cake_autorate已经在运行中 (PID: $lock_pid)，跳过启动"
            return 0
        else
            # 锁文件存在但进程不存在，清理
            rm -f "$lock_file"
        fi
    fi
    
    # 检查PID文件
    if [ -f "$pid_file" ]; then
        local existing_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null 2>&1; then
            echo "cake_autorate已经在运行中 (PID: $existing_pid)，跳过启动"
            return 0
        else
            # PID文件存在但进程不存在，清理
            rm -f "$pid_file"
        fi
    fi
    
    # 检查进程
    if pgrep -f "cake_autorate.sh start" | grep -v "^$$$" >/dev/null; then
        local running_pid=$(pgrep -f "cake_autorate.sh start" | grep -v "^$$$" | head -1)
        echo "cake_autorate已经在运行中 (PID: $running_pid)，跳过启动"
        return 0
    fi
    
    # 创建锁文件
    echo "$$$" > "$lock_file"
    trap 'rm -f "$lock_file" 2>/dev/null' EXIT INT TERM
    
    # 原有的启动代码...
    if [ "$CAKE_AUTORATE_ENABLED" != "1" ]; then
        log_info "cake_autorate未启用，跳过启动"
        return 1
    fi
    
    if [ "$AUTORATE_RUNNING" -eq 1 ]; then
        log_info "cake_autorate已经在运行中"
        return 0
    fi
    
    log_info "启动cake_autorate服务"
    
    # 在后台启动调整循环
    autorate_adjustment_loop &
    AUTORATE_PID=$!
    
    log_info "cake_autorate服务已启动 (PID: $AUTORATE_PID)"
    return 0
}

stop_cake_autorate() {
    log_info "停止cake_autorate服务"
    
    # 清理PID文件
    rm -f /var/run/cake_autorate.pid
	rm -f /tmp/run/cake_autorate.pid
    
    # 停止所有相关进程
    killall "cake_autorate.sh start" 2>/dev/null || true
    
    # 设置运行标志
    AUTORATE_RUNNING=0
    AUTORATE_PID=""

    
	# 清理所有临时文件，但排除正在使用的
    if [ -d "/proc" ]; then
        # 查找所有可能属于本脚本的临时文件
        for tmpfile in "$AUTORATE_STATUS_FILE.tmp."*; do
            # 检查文件是否被使用
            if [ -f "$tmpfile" ]; then
                # 尝试删除，忽略错误
                rm -f "$tmpfile" 2>/dev/null || true
            fi
        done
    else
        rm -f "$AUTORATE_STATUS_FILE.tmp."* 2>/dev/null
    fi
	
    # 清理锁和状态文件
    rm -f "$CONFIG_LOCK" 2>/dev/null
    rm -f "$AUTORATE_STATUS_FILE" 2>/dev/null
    rm -f "$SHARED_CONFIG_DIR/autorate_monitor" 2>/dev/null
    rm -f "$SHARED_CONFIG_DIR/adaptive_tuning" 2>/dev/null
    rm -f "$SHARED_CONFIG_DIR/upload_bandwidth_history" 2>/dev/null
    rm -f "$SHARED_CONFIG_DIR/download_bandwidth_history" 2>/dev/null
    
    # 清理所有 .lock 文件
    [ -d "$SHARED_CONFIG_DIR" ] && find "$SHARED_CONFIG_DIR" -name "*.lock" -delete 2>/dev/null
    
    log_info "cake_autorate服务已停止"
    return 0
}

# ========== 状态查询函数 ==========
show_autorate_status() {
    echo "===== cake_autorate 状态报告 ====="
	
    # 检查PID文件
    local pid_file="/var/run/cake_autorate.pid"
    local pid=""
    local status="❌ 已停止"
    
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            status="✅ 运行中"
        else
            # PID文件存在但进程已停止，清理无效PID文件
            rm -f "$pid_file"
            pid=""
        fi
    fi
    
    # 如果没有PID文件，尝试通过进程名查找
    if [ -z "$pid" ]; then
        pid=$(ps w | grep "cake_autorate.sh start" | grep -v grep | awk '{print $1}' | head -1)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            status="✅ 运行中"
            # 修复丢失的PID文件
            echo "$pid" > "$pid_file"
        fi
    fi
    
    echo "运行状态: $status"
    echo "进程PID: ${pid:-无}"
    echo "测量间隔: ${CAKE_AUTORATE_INTERVAL}s"
    echo "测量目标: $CAKE_AUTORATE_PING_HOSTS"
    echo "RTT目标范围: ${CAKE_AUTORATE_MIN_RTT} - ${CAKE_AUTORATE_MAX_RTT}"
    
    # 从状态文件读取调整次数
    local cycle_count=0
    if [ -f "$AUTORATE_STATUS_FILE" ]; then
        if acquire_lock "$CONFIG_LOCK" 2; then
            cycle_count=$(grep "^cycle:" "$AUTORATE_STATUS_FILE" 2>/dev/null | cut -d: -f2)
            release_lock "$CONFIG_LOCK"
        fi
    fi
    echo "调整次数: ${cycle_count:-0}"
    echo ""
    
    if [ -f "$AUTORATE_STATUS_FILE" ]; then
		echo "当前实时状态:"
    
		if acquire_lock "$CONFIG_LOCK" 2; then
			if [ -f "$AUTORATE_STATUS_FILE" ]; then
				# 使用临时变量存储文件内容，避免读取过程中文件被修改
				local status_content=$(cat "$AUTORATE_STATUS_FILE" 2>/dev/null)
				if [ -n "$status_content" ]; then
					# 使用管道而不是here-string，确保shell兼容性
					echo "$status_content" | while IFS=':' read -r key value; do
						case "$key" in
							upload)
								echo "  上传带宽: ${value}kbit/s"
								;;
							download)
								echo "  下载带宽: ${value}kbit/s"
								;;
							rtt)
								echo "  当前延迟: ${value}ms"
								;;
							cycle)
								echo "  调整周期: 第${value}次"
								;;
							timestamp)
								local age=$(($(date +%s) - value))
								echo "  最后更新: ${age}秒前"
								;;
						esac
					done
				fi  
			fi  
			release_lock "$CONFIG_LOCK"  # 添加释放锁
		fi 
	fi
    
    if [ "$AUTORATE_RUNNING" -eq 1 ]; then
        echo "当前带宽设置:"
        echo "  上传: ${LAST_UPLOAD_BANDWIDTH:-$total_upload_bandwidth}kbit"
        echo "  下载: ${LAST_DOWNLOAD_BANDWIDTH:-$total_download_bandwidth}kbit"
        echo ""
        echo "最近延迟测量历史:"
        local history_count=$(echo "$MEASUREMENT_HISTORY" | tr ',' '\n' | wc -l)
        echo "  ${history_count} 次测量: $(echo "$MEASUREMENT_HISTORY" | sed 's/,$//')"
    fi
    
    # 显示带宽调整历史
    if [ -f "$SHARED_CONFIG_DIR/upload_bandwidth_history" ]; then
        echo ""
        echo "上传带宽调整历史 (最近10次):"
        tail -n 10 "$SHARED_CONFIG_DIR/upload_bandwidth_history" 2>/dev/null | while read -r line; do
            local timestamp=$(echo "$line" | cut -d: -f1)
            local bandwidth=$(echo "$line" | cut -d: -f2)
            local time_str=$(date -d "@$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
            echo "  $time_str: ${bandwidth}kbit/s"
        done
    fi
    
    # 新增：性能监控数据显示
    local monitor_file="$SHARED_CONFIG_DIR/autorate_monitor"
    if [ -f "$monitor_file" ]; then
        echo ""
        echo "性能监控数据 (最近5次):"
        tail -n 5 "$monitor_file" 2>/dev/null | while read -r line; do
            local timestamp=$(echo "$line" | cut -d: -f1)
            local cpu=$(echo "$line" | cut -d: -f2)
            local mem=$(echo "$line" | cut -d: -f3)
            local load=$(echo "$line" | cut -d: -f4)
            local time_str=$(date -d "@$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
            echo "  $time_str: CPU=${cpu}%, 内存=${mem}%, 负载=${load}"
        done
    fi
    
    # 新增：自适应调整数据显示
    local adaptive_file="$SHARED_CONFIG_DIR/adaptive_tuning"
    if [ -f "$adaptive_file" ]; then
        echo ""
        echo "自适应调整历史:"
        tail -n 5 "$adaptive_file" 2>/dev/null | while read -r line; do
            local timestamp=$(echo "$line" | cut -d: -f1)
            local score=$(echo "$line" | cut -d: -f2)
            local interval=$(echo "$line" | cut -d: -f3)
            local time_str=$(date -d "@$timestamp" "+%H:%M:%S" 2>/dev/null || echo "$timestamp")
            echo "  $time_str: 稳定度=${score}, 间隔=${interval}s"
        done
    fi
    
    echo "===== 状态报告结束 ====="
}

# ========== 主函数 ==========
main_cake_autorate() {
    local action="$1"
    
    # 加载配置
    load_cake_config
    
    case "$action" in
        start)
            start_cake_autorate
            ;;
        stop)
            stop_cake_autorate
            ;;
        restart)
            stop_cake_autorate
            sleep 2
            start_cake_autorate
            ;;
        status)
            show_autorate_status
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status}"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "cake_autorate.sh" ]; then
    main_cake_autorate "$@"
fi