local uci  = require "luci.model.uci".cursor()
local dsp  = require "luci.dispatcher"
local util = require "luci.util"
local sys  = require "luci.sys"
local ip   = require "luci.ip"

m = Map("qos_gargoyle", translate("主动拥塞控制"),
    translate("主动拥塞控制系统基于实时网络延迟动态调整带宽限制，以保持低延迟的网络连接。<br><br><strong style='color: red;'>注意：ACC和QoS不能同时运行，启用ACC将自动禁用QoS。</strong>"))

m.redirect = dsp.build_url("admin/qos/qos_gargoyle")
m.submit = translate("保存并应用")
m.reset = false

-- 获取带宽设置
function get_bandwidth_settings()
    local dl_config = uci:get_all("qos_gargoyle", "download") or {}
    local ul_config = uci:get_all("qos_gargoyle", "upload") or {}
    
    return {
        download_bandwidth = dl_config.total_bandwidth or "100000",  -- 单位是Kbps
        upload_bandwidth = ul_config.total_bandwidth or "50000"     -- 单位是Kbps
    }
end

-- 验证IP地址函数
function is_valid_ip(ipstr, ipv6)
    if not ipstr or ipstr == "" then
        return false
    end
    
    if ipv6 then
        return pcall(ip.IPv6, ipstr)
    else
        return pcall(ip.IPv4, ipstr)
    end
end

-- 自动检测网关函数
function detect_gateway(ipv6)
    if ipv6 then
        local cmd = "ip -6 route show default 2>/dev/null | awk '/default/ {print $3}' | head -1"
        local result = util.trim(util.exec(cmd))
        if result and result ~= "" and is_valid_ip(result, true) then
            return result
        end
    else
        local cmd = "ip -4 route show default 2>/dev/null | awk '/default/ {print $3}' | head -1"
        local result = util.trim(util.exec(cmd))
        if result and result ~= "" and is_valid_ip(result, false) then
            return result
        end
    end
    return nil
end

-- 检查qosmon进程是否在运行
function is_qosmon_running()
    local output = util.exec("ps | grep -v grep | grep -v 'status\\|start\\|stop\\|restart\\|enable\\|disable\\|enabled' | grep -v '/bin/sh' | grep qosmon")
    if output and output:match("qosmon") then
        return true
    end
    
    -- 也尝试用pgrep检查
    local pid = util.exec("pgrep -x qosmon 2>/dev/null")
    if pid and pid:gsub("%s+", "") ~= "" then
        return true
    end
    
    return false
end

-- 获取当前qosmon进程参数
function get_qosmon_args()
    local args = ""
    local ps_output = util.exec("ps | grep -v grep | grep 'qosmon' | grep -v '/bin/sh' | grep -v 'status\\|start\\|stop\\|restart\\|enable\\|disable\\|enabled' | head -1")
    if ps_output and ps_output ~= "" then
        -- 提取qosmon后面的参数
        local cmd_match = ps_output:match("qosmon%s+(.+)")
        if cmd_match then
            args = cmd_match:gsub("%s+$", "")
        end
    end
    return args
end

-- 生成qosmon启动参数
function generate_qosmon_args()
    local config = uci:get_all("qos_gargoyle", "qosmon") or {}
    local bandwidth = get_bandwidth_settings()
    
    -- 修复：使用正确的参数格式
    local args = ""
    
    -- 添加基本参数
    args = args .. "-s -t "
    
    -- 延迟阈值
    local latency_val = config.latency_threshold
    if latency_val and latency_val ~= "" and tonumber(latency_val) > 0 then
        args = args .. latency_val .. " "
    else
        args = args .. "200 "  -- 默认200ms
    end
    
    -- ping间隔 (毫秒)
    if config.ping_interval and tonumber(config.ping_interval) > 0 then
        args = args .. config.ping_interval .. " "
    else
        args = args .. "1000 "  -- 默认1000ms
    end
    
    -- ping目标
    local ping_target = config.ping_target or ""
    local ping_target_v6 = config.ping_target_v6 or ""
    local use_ipv6 = config.use_ipv6 or "0"
    
    local target_ip = ""
    if use_ipv6 == "1" and ping_target_v6 and ping_target_v6 ~= "" then
        if is_valid_ip(ping_target_v6, true) then
            target_ip = ping_target_v6
        end
    else
        if ping_target and ping_target ~= "" then
            if is_valid_ip(ping_target, false) then
                target_ip = ping_target
            end
        end
    end
    
    -- 如果没有指定ping目标，则自动检测网关
    if target_ip == "" then
        local gateway = detect_gateway(use_ipv6 == "1")
        if gateway then
            target_ip = gateway
        else
            target_ip = "8.8.8.8"  -- 默认目标
        end
    end
    
    args = args .. target_ip .. " "
    
    -- 带宽（单位kbps，不要转换为Mbps！）
    if bandwidth.download_bandwidth and tonumber(bandwidth.download_bandwidth) > 0 then
        local dl_kbps = tonumber(bandwidth.download_bandwidth)
        args = args .. tostring(dl_kbps)
    else
        args = args .. "100000"  -- 默认100Mbps (100000kbps)
    end
    
    -- 添加其他可选参数
    local advanced_args = ""
    
    -- 最大ping值 (-m)
    local maxping_val = config.max_ping
    if maxping_val and maxping_val ~= "" and tonumber(maxping_val) > 0 then
        advanced_args = advanced_args .. " -m " .. maxping_val
    end
    
    -- 带宽增加步进 (-i)
    local inc_val = config.bw_increase_step
    if inc_val and inc_val ~= "" and tonumber(inc_val) > 0 then
        advanced_args = advanced_args .. " -i " .. inc_val
    end
    
    -- 带宽减少步进 (-d)
    local dec_val = config.bw_decrease_step
    if dec_val and dec_val ~= "" and tonumber(dec_val) > 0 then
        advanced_args = advanced_args .. " -d " .. dec_val
    end
    
    -- 采样间隔 (-s) 注意：这里-s和前面的-s冲突，需要确认qosmon的参数
    -- 根据您手动测试的命令，-s 在 -t 之前表示采样间隔
    -- 但参数中又出现了一个-s，可能是其他含义，暂时保留
    local sample_val = config.sample_interval
    if sample_val and sample_val ~= "" and tonumber(sample_val) > 0 then
        -- 注意：这里-s可能被错误使用，需要确认qosmon的参数含义
        -- advanced_args = advanced_args .. " -s " .. sample_val
    end
    
    -- PID参数
    local kp_val = config.pid_kp
    if kp_val and kp_val ~= "" and tonumber(kp_val) >= 0 then
        advanced_args = advanced_args .. " -p " .. kp_val
    end
    
    local ki_val = config.pid_ki
    if ki_val and ki_val ~= "" and tonumber(ki_val) >= 0 then
        advanced_args = advanced_args .. " -k " .. ki_val
    end
    
    local kd_val = config.pid_kd
    if kd_val and kd_val ~= "" and tonumber(kd_val) >= 0 then
        advanced_args = advanced_args .. " -x " .. kd_val
    end
    
    -- 详细级别
    if config.verbose == "1" then
        advanced_args = advanced_args .. " -v 1"
    end
    
    -- 组合所有参数
    if advanced_args ~= "" then
        args = args .. advanced_args
    end
    
    return args
end

-- 生成启动脚本
function generate_startup_script()
    local args = generate_qosmon_args()
    
    local script_content = string.format([[
#!/bin/sh
# qosmon 控制脚本
# 生成时间: %s
# 启动参数: %s

QOSMON_BIN="/usr/sbin/qosmon"
PID_FILE="/var/run/qosmon.pid"
START_ARGS="%s"
LOG_FILE="/tmp/qosmon_debug.log"

# 检查qosmon程序是否存在
check_binary() {
    if [ ! -x "$QOSMON_BIN" ]; then
        echo "错误: qosmon程序不存在: $QOSMON_BIN" >> "$LOG_FILE"
        return 1
    fi
    return 0
}

# 获取 qosmon 进程的 PID
get_qosmon_pid() {
    ps | grep -v grep | grep -v "status\|start\|stop\|restart\|enable\|disable\|enabled" | grep "qosmon" | grep -v "/bin/sh" | head -1 | awk '{print $1}'
}

start() {
    echo "启动 qosmon 服务..." > "$LOG_FILE"
    echo "启动时间: $(date)" >> "$LOG_FILE"
    echo "启动参数: $QOSMON_BIN $START_ARGS" >> "$LOG_FILE"
    
    # 检查二进制文件
    if ! check_binary; then
        echo "qosmon二进制文件检查失败" >&2
        return 1
    fi
    
    # 检查是否已在运行
    local qosmon_pid=$(get_qosmon_pid)
    if [ -n "$qosmon_pid" ]; then
        echo "qosmon 已在运行 (PID: $qosmon_pid)" >> "$LOG_FILE"
        echo "$qosmon_pid" > "$PID_FILE" 2>/dev/null
        return 0
    fi
    
    # 清理可能存在的旧 PID 文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 显示启动参数详情
    echo "参数详情:" >> "$LOG_FILE"
    echo "  - 参数格式: $START_ARGS" >> "$LOG_FILE"
    echo "  - 延迟阈值: $(echo "$START_ARGS" | grep -oE "\-t [0-9]+" | cut -d' ' -f2 || echo "默认200") ms" >> "$LOG_FILE"
    echo "  - Ping间隔: $(echo "$START_ARGS" | grep -oE "^-t [0-9]+ [0-9]+" | cut -d' ' -f3 || echo "默认1000") ms" >> "$LOG_FILE"
    echo "  - Ping目标: $(echo "$START_ARGS" | grep -oE "^-t [0-9]+ [0-9]+ [^ ]+" | cut -d' ' -f4 || echo "未设置")" >> "$LOG_FILE"
    echo "  - 带宽限制: $(echo "$START_ARGS" | grep -oE "[0-9]+$" || echo "100000") kbps" >> "$LOG_FILE"
    
    # 启动 qosmon
    echo "正在启动 qosmon..." >> "$LOG_FILE"
    echo "执行命令: $QOSMON_BIN $START_ARGS" >> "$LOG_FILE"
    $QOSMON_BIN $START_ARGS 2>>"$LOG_FILE" &
    local pid=$!
    
    # 等待进程启动
    sleep 3
    
    # 检查是否启动成功
    if kill -0 $pid 2>/dev/null; then
        echo "$pid" > "$PID_FILE"
        echo "✓ qosmon 启动成功 (PID: $pid)" >> "$LOG_FILE"
        echo "启动参数详情已保存到 $LOG_FILE"
        return 0
    else
        echo "✗ qosmon 启动失败" >> "$LOG_FILE"
        echo "启动参数详情已保存到 $LOG_FILE"
        echo "查看日志: cat $LOG_FILE"
        return 1
    fi
}

stop() {
    echo "停止 qosmon 服务..."
    
    # 从 PID 文件获取 PID
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
            echo "停止进程 (PID: $pid)"
            kill "$pid" 2>/dev/null
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                echo "强制停止进程 (PID: $pid)"
                kill -9 "$pid" 2>/dev/null
            fi
        fi
    fi
    
    # 停止所有qosmon进程
    local all_pids=$(get_qosmon_pid)
    for pid in $all_pids; do
        if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; then
            echo "停止进程 (PID: $pid)"
            kill -9 "$pid" 2>/dev/null
        fi
    done
    
    # 清理 PID 文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 最终检查
    if [ -z "$(get_qosmon_pid)" ]; then
        echo "✓ qosmon 已停止"
    else
        echo "⚠ 可能有残留进程"
    fi
}

restart() {
    echo "重启 qosmon 服务..."
    stop
    sleep 1
    start
}

status() {
    echo "qosmon 状态:"
    
    # 检查二进制文件
    if ! check_binary; then
        echo "✗ qosmon 程序不存在"
        return 1
    fi
    
    # 检查实际进程
    local qosmon_pid=$(get_qosmon_pid)
    if [ -n "$qosmon_pid" ]; then
        echo "✓ 正在运行 (PID: $qosmon_pid)"
        echo "  启动参数: $QOSMON_BIN $START_ARGS"
        return 0
    else
        echo "✗ 未运行"
        return 1
    fi
}

enable() {
    echo "启用开机自启动..."
    ln -sf /etc/init.d/qosmon /etc/rc.d/S99qosmon 2>/dev/null
    ln -sf /etc/init.d/qosmon /etc/rc.d/K10qosmon 2>/dev/null
    echo "✓ 已启用开机自启动"
}

disable() {
    echo "禁用开机自启动..."
    rm -f /etc/rc.d/S??qosmon 2>/dev/null
    rm -f /etc/rc.d/K??qosmon 2>/dev/null
    echo "✓ 已禁用开机自启动"
}

enabled() {
    if [ -L /etc/rc.d/S??qosmon ] 2>/dev/null; then
        echo "✓ 已启用开机自启动"
        return 0
    else
        echo "✗ 未启用开机自启动"
        return 1
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart|reload) restart ;;
    status) status ;;
    enable) enable ;;
    disable) disable ;;
    enabled) enabled ;;
    *)
        echo "qosmon 服务控制脚本"
        echo "版本: 8.1 (调试版)"
        echo "当前启动参数: $START_ARGS"
        echo ""
        echo "参数解析:"
        echo "  - 延迟阈值: $(echo "$START_ARGS" | grep -oE "\-l [0-9]+" | cut -d' ' -f2 || echo "未设置") ms"
        echo "  - 最大ping值: $(echo "$START_ARGS" | grep -oE "\-m [0-9]+" | cut -d' ' -f2 || echo "未设置") ms"
        echo "  - 增加步进: $(echo "$START_ARGS" | grep -oE "\-i [0-9]+" | cut -d' ' -f2 || echo "未设置") %%"
        echo "  - 减少步进: $(echo "$START_ARGS" | grep -oE "\-d [0-9]+" | cut -d' ' -f2 || echo "未设置") %%"
        echo ""
        echo "用法: $0 {start|stop|restart|status|enable|disable|enabled}"
        exit 1
        ;;
esac
]], os.date("%Y-%m-%d %H:%M:%S"), args, args)
    
    return script_content
end

-- 创建ACC配置节
s = m:section(NamedSection, "qosmon", "qosmon", translate("基本设置"))

-- 启用/禁用开关
enabled = s:option(Flag, "enabled", translate("启用主动拥塞控制"),
    translate("动态调整带宽限制以保持网络延迟在可接受范围内。"))
enabled.rmempty = false
enabled.default = "0"

-- 状态显示
local status_display = s:option(DummyValue, "_status", translate("当前状态"))
function status_display.cfgvalue()
    if is_qosmon_running() then
        -- 获取运行参数
        local args = get_qosmon_args()
        local latency_val = args:match("-l (%d+)")
        local max_ping_val = args:match("-m (%d+)")
        
        local info = '<span style="color: green; font-weight: bold;">✓ 运行中</span>'
        if latency_val then
            info = info .. '<br><span style="color: blue;">延迟阈值: ' .. latency_val .. 'ms</span>'
        end
        if max_ping_val then
            info = info .. '<br><span style="color: blue;">最大Ping: ' .. max_ping_val .. 'ms</span>'
        end
        return info
    else
        local enabled_val = uci:get("qos_gargoyle", "qosmon", "enabled")
        if enabled_val == "1" then
            return '<span style="color: red; font-weight: bold;">✗ 已停止 (已启用但未运行)</span><br><small>请检查配置后保存应用</small>'
        else
            return '<span style="color: gray;">已禁用</span>'
        end
    end
end
status_display.rawhtml = true

-- IPv4/IPv6选择
use_ipv6 = s:option(ListValue, "use_ipv6", translate("IP协议版本"),
    translate("选择使用的IP协议版本。"))
use_ipv6:value("0", translate("IPv4"))
use_ipv6:value("1", translate("IPv6"))
use_ipv6.default = "0"

-- Ping目标设置
ping_target = s:option(Value, "ping_target", translate("Ping目标 (IPv4)"),
    translate("用于监控延迟的IPv4地址。留空则自动检测网关。"))
ping_target.datatype = "ip4addr"
ping_target:depends("use_ipv6", "0")
ping_target.placeholder = "自动检测 (网关)"

ping_target_v6 = s:option(Value, "ping_target_v6", translate("Ping目标 (IPv6)"),
    translate("用于监控延迟的IPv6地址。留空则自动检测网关。"))
ping_target_v6.datatype = "ip6addr"
ping_target_v6:depends("use_ipv6", "1")
ping_target_v6.placeholder = "自动检测 (网关)"

-- Ping间隔
ping_interval = s:option(Value, "ping_interval", translate("Ping间隔 (毫秒)"),
    translate("Ping测量之间的时间间隔。数值越低响应越快，但开销越大。"))
ping_interval.datatype = "range(100, 5000)"
ping_interval.default = "800"

-- 网关检测结果显示
local gateway_info = s:option(DummyValue, "_gateway_info", translate("网关检测"))
function gateway_info.cfgvalue()
    local ipv4_gateway = detect_gateway(false)
    local ipv6_gateway = detect_gateway(true)
    
    local result = ""
    if ipv4_gateway then
        result = result .. "✓ IPv4网关: " .. ipv4_gateway .. "<br>"
    else
        result = result .. "✗ IPv4网关: 未检测到<br>"
    end
    
    if ipv6_gateway then
        result = result .. "✓ IPv6网关: " .. ipv6_gateway
    else
        result = result .. "✗ IPv6网关: 未检测到"
    end
    
    return result
end
gateway_info.rawhtml = true

-- 添加带宽信息显示
bandwidth_info = s:option(DummyValue, "_bandwidth_info", translate("带宽配置信息"))
function bandwidth_info.cfgvalue(self, section)
    local bw = get_bandwidth_settings()
    local dl_kbps = tonumber(bw.download_bandwidth) or 0
    local ul_kbps = tonumber(bw.upload_bandwidth) or 0
    local dl_mbps = math.floor(dl_kbps / 1000)
    local ul_mbps = math.floor(ul_kbps / 1000)
    
    -- 获取生成的参数用于显示
    local args = generate_qosmon_args()
    
    return string.format("下载: %d Kbps (%d Mbps) | 上传: %d Kbps (%d Mbps)<br>qosmon参数: %s", 
        dl_kbps, dl_mbps, ul_kbps, ul_mbps, args)
end
bandwidth_info.rawhtml = true

-- 高级设置
adv_s = m:section(NamedSection, "qosmon", "qosmon", translate("高级设置"))

-- 详细日志
verbose = adv_s:option(Flag, "verbose", translate("详细日志"),
    translate("启用详细日志记录以进行调试。"))
verbose.default = "0"

-- 拥塞控制参数
adv_s:tab("congestion", translate("拥塞控制参数"))

-- 延迟阈值
latency_threshold = adv_s:taboption("congestion", Value, "latency_threshold", translate("延迟阈值 (ms)"),
    translate("当延迟超过此阈值时触发带宽调整。默认: 30ms"))
latency_threshold.datatype = "range(5, 200)"
latency_threshold.default = "30"
latency_threshold.placeholder = "30"

-- 最大ping值
max_ping = adv_s:taboption("congestion", Value, "max_ping", translate("最大Ping值 (ms)"),
    translate("允许的最大ping值，超过此值将触发更激进的调整。默认: 100ms"))
max_ping.datatype = "range(20, 1000)"
max_ping.default = "100"
max_ping.placeholder = "100"

-- 带宽增加步进
bw_increase_step = adv_s:taboption("congestion", Value, "bw_increase_step", translate("带宽增加步进 (%)"),
    translate("每次增加带宽的百分比。默认: 5%"))
bw_increase_step.datatype = "range(1, 50)"
bw_increase_step.default = "5"
bw_increase_step.placeholder = "5"

-- 带宽减少步进
bw_decrease_step = adv_s:taboption("congestion", Value, "bw_decrease_step", translate("带宽减少步进 (%)"),
    translate("每次减少带宽的百分比。默认: 10%"))
bw_decrease_step.datatype = "range(1, 50)"
bw_decrease_step.default = "10"
bw_decrease_step.placeholder = "10"

-- 采样间隔
sample_interval = adv_s:taboption("congestion", Value, "sample_interval", translate("采样间隔 (秒)"),
    translate("采样网络状况的时间间隔。默认: 5秒"))
sample_interval.datatype = "range(1, 30)"
sample_interval.default = "5"
sample_interval.placeholder = "5"

-- PID控制参数
adv_s:tab("pid", translate("PID控制参数"))

-- PID参数说明
pid_desc = adv_s:taboption("pid", DummyValue, "_pid_desc")
pid_desc.rawhtml = true
pid_desc.template = "cbi/dvalue"
pid_desc.cfgvalue = function()
    return [[<div style="padding: 10px; background: #f5f5f5; border-radius: 5px; margin-bottom: 10px;">
    <strong>PID参数说明：</strong>
    <ul style="margin: 5px 0; padding-left: 20px;">
        <li><b>比例系数(Kp)：</b>响应当前误差的比例</li>
        <li><b>积分系数(Ki)：</b>累积历史误差的调整</li>
        <li><b>微分系数(Kd)：</b>预测误差变化趋势</li>
    </ul>
    <small style="color: #666;">建议值: Kp=1.0, Ki=0.5, Kd=0.1</small>
    </div>]]
end

-- 比例系数(Kp)
pid_kp = adv_s:taboption("pid", Value, "pid_kp", translate("比例系数 (Kp)"),
    translate("PID控制器的比例系数。值越大响应越快，但可能不稳定。默认: 1.0"))
pid_kp.datatype = "float"
pid_kp.default = "1.0"
pid_kp.placeholder = "1.0"

-- 积分系数(Ki)
pid_ki = adv_s:taboption("pid", Value, "pid_ki", translate("积分系数 (Ki)"),
    translate("PID控制器的积分系数。消除稳态误差。默认: 0.5"))
pid_ki.datatype = "float"
pid_ki.default = "0.5"
pid_ki.placeholder = "0.5"

-- 微分系数(Kd)
pid_kd = adv_s:taboption("pid", Value, "pid_kd", translate("微分系数 (Kd)"),
    translate("PID控制器的微分系数。抑制超调和振荡。默认: 0.1"))
pid_kd.datatype = "float"
pid_kd.default = "0.1"
pid_kd.placeholder = "0.1"

-- 高级功能
adv_s:tab("advanced", translate("高级功能"))

-- 最小带宽限制
min_bandwidth = adv_s:taboption("advanced", Value, "min_bandwidth", translate("最小带宽限制 (%)"),
    translate("带宽调整的最小百分比，防止过度限速。默认: 20%"))
min_bandwidth.datatype = "range(5, 80)"
min_bandwidth.default = "20"
min_bandwidth.placeholder = "20"

-- 最大带宽限制
max_bandwidth = adv_s:taboption("advanced", Value, "max_bandwidth", translate("最大带宽限制 (%)"),
    translate("带宽调整的最大百分比，防止带宽浪费。默认: 100%"))
max_bandwidth.datatype = "range(50, 150)"
max_bandwidth.default = "100"
max_bandwidth.placeholder = "100"

-- 平滑因子
smooth_factor = adv_s:taboption("advanced", Value, "smooth_factor", translate("平滑因子"),
    translate("带宽变化的平滑系数，值越大变化越平缓。默认: 0.7"))
smooth_factor.datatype = "range(0.1, 1.0)"
smooth_factor.default = "0.7"
smooth_factor.placeholder = "0.7"

-- 高级选项描述
adv_desc = adv_s:taboption("advanced", DummyValue, "_adv_desc")
adv_desc.rawhtml = true
adv_desc.template = "cbi/dvalue"
adv_desc.cfgvalue = function()
    return [[<div style="padding: 10px; background: #f5f5f5; border-radius: 5px; margin-top: 10px;">
    <strong>注意：</strong>
    <ul style="margin: 5px 0; padding-left: 20px;">
        <li>高级参数修改需要重启qosmon服务生效</li>
        <li>建议先使用默认值，根据实际网络情况微调</li>
        <li>修改PID参数可能需要专业知识</li>
    </ul>
    </div>]]
end

-- 配置验证
function m.on_before_commit(self)
    local enabled_val = enabled:formvalue("qosmon")
    
    if enabled_val == "1" then
        -- 检查带宽配置是否存在
        local bw = get_bandwidth_settings()
        
        if not bw.download_bandwidth or tonumber(bw.download_bandwidth) == 0 then
            m.message = translate("启用ACC前请先在download配置节设置下载带宽")
            return false
        end
        
        if not bw.upload_bandwidth or tonumber(bw.upload_bandwidth) == 0 then
            m.message = translate("启用ACC前请先在upload配置节设置上传带宽")
            return false
        end
        
        -- 检查qosmon程序是否存在
        if not nixio.fs.access("/usr/sbin/qosmon") then
            m.message = translate("错误: qosmon程序不存在，请确保已正确安装")
            return false
        end
    end
    
    return true
end

-- 配置保存后的处理
function m.on_after_save(self)
    local config = uci:get_all("qos_gargoyle", "qosmon") or {}
    
    local script_path = "/etc/init.d/qosmon"
    
    -- 生成启动脚本
    local script_content = generate_startup_script()
    
	-- 停止QoS如果它正在运行
    if config.enabled == "1" then
        -- 检查QoS是否在运行
        local qos_running = util.exec("ps | grep -v grep | grep -E '(qos_gargoyle|qos)' | grep -v 'qosmon'")
        if qos_running and qos_running ~= "" then
            -- 停止QoS
            sys.call("/etc/init.d/qos_gargoyle stop >/dev/null 2>&1")
            sys.call("killall -9 qos_gargoyle 2>/dev/null")
            sys.call("killall -9 qos 2>/dev/null")
            
            -- 清理QoS的TC规则
            sys.call("tc qdisc del dev pppoe-wan root 2>/dev/null")
            sys.call("tc qdisc del dev pppoe-wan ingress 2>/dev/null")
            sys.call("tc qdisc del dev ifb0 root 2>/dev/null 2>/dev/null")
            
            m.message = translate("已停止QoS，启动ACC...")
        end
    end
	
    local f = io.open(script_path, "w")
    if f then
        f:write(script_content)
        f:close()
        sys.call("chmod 755 " .. script_path .. " 2>/dev/null")
    else
        m.message = translate("错误: 无法写入启动脚本: " .. script_path)
        return false
    end
    
    -- 控制服务
    if config.enabled == "1" then
        -- 停止现有服务
        sys.call("/etc/init.d/qosmon stop >/dev/null 2>&1")
        sys.call("killall -9 qosmon 2>/dev/null")
        os.execute("sleep 1")
        
        -- 启用并启动服务
        sys.call("/etc/init.d/qosmon enable >/dev/null 2>&1")
        
		-- 添加：确保uhttpd已经启动
        sys.call("/etc/init.d/uhttpd restart >/dev/null 2>&1")
        os.execute("sleep 3")  -- 等待uhttpd完全启动
	
        -- 使用更详细的方式启动服务
        local output_file = "/tmp/qosmon_start.log"
        local ret = sys.call("/etc/init.d/qosmon start 2>&1 | tee " .. output_file)
        
        -- 等待服务启动
        os.execute("sleep 3")
        
        -- 检查服务是否启动成功
        if is_qosmon_running() then
            local bw = get_bandwidth_settings()
            local dl_mbps = math.floor(tonumber(bw.download_bandwidth) / 1000)
            local ul_mbps = math.floor(tonumber(bw.upload_bandwidth) / 1000)
            
            -- 显示高级参数信息
            local advanced_info = ""
            if config.latency_threshold and config.latency_threshold ~= "30" then
                advanced_info = advanced_info .. " 延迟阈值: " .. config.latency_threshold .. "ms"
            end
            if config.bw_increase_step and config.bw_increase_step ~= "5" then
                advanced_info = advanced_info .. " 增加步进: " .. config.bw_increase_step .. "%"
            end
            
            m.message = string.format(translate("✓ ACC服务已启动 (下载: %d Mbps, 上传: %d Mbps)"), 
                dl_mbps, ul_mbps)
            if advanced_info ~= "" then
                m.message = m.message .. "<br>" .. translate("高级参数:") .. advanced_info
            end
            
            -- 显示调试信息
            m.message = m.message .. "<br><small>参数详情见 /tmp/qosmon_debug.log</small>"
        else
            -- 读取启动日志
            local error_msg = "未知错误"
            local f = io.open("/tmp/qosmon_debug.log", "r")
            if f then
                error_msg = f:read("*all") or "未知错误"
                f:close()
            end
            
            m.message = translate("✗ ACC服务启动失败")
            if error_msg ~= "未知错误" then
                m.message = m.message .. ": " .. error_msg:gsub("\n", " "):sub(1, 100) .. "..."
            end
        end
    else
        -- 停止服务
        sys.call("/etc/init.d/qosmon stop >/dev/null 2>&1")
        sys.call("/etc/init.d/qosmon disable >/dev/null 2>&1")
        sys.call("rm -f /var/run/qosmon.pid 2>/dev/null")
        m.message = translate("ACC服务已停止")
    end
    
    return true
end

-- 页面加载时检查服务状态
function m.on_init(self)
    -- 确保qosmon节存在
    if not uci:get("qos_gargoyle", "qosmon") then
        uci:section("qos_gargoyle", "qosmon", "qosmon", {
            enabled = "0",
            use_ipv6 = "0",
            ping_target = "",
            ping_target_v6 = "",
            ping_interval = "800",
            verbose = "0",
            latency_threshold = "30",
            max_ping = "100",
            bw_increase_step = "5",
            bw_decrease_step = "10",
            sample_interval = "5",
            pid_kp = "1.0",
            pid_ki = "0.5",
            pid_kd = "0.1",
            min_bandwidth = "20",
            max_bandwidth = "100",
            smooth_factor = "0.7"
        })
        uci:save("qos_gargoyle")
        uci:commit("qos_gargoyle")
    end
    
    -- 检查qosmon程序是否存在
    if not nixio.fs.access("/usr/sbin/qosmon") then
        m.message = translate("警告: qosmon程序不存在于/usr/sbin/，请确保已正确安装")
    end
    
    -- 生成启动脚本（如果需要）
    if not nixio.fs.access("/etc/init.d/qosmon") then
        local script_content = generate_startup_script()
        local f = io.open("/etc/init.d/qosmon", "w")
        if f then
            f:write(script_content)
            f:close()
            sys.call("chmod 755 /etc/init.d/qosmon 2>/dev/null")
        end
    end
end

return m