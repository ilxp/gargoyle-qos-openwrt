-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

local uci  = require "luci.model.uci".cursor()
local dsp  = require "luci.dispatcher"
local util = require "luci.util"
local sys  = require "luci.sys"
local ip   = require "luci.ip"

m = Map("qos_gargoyle", translate("主动拥塞控制"),
    translate("主动拥塞控制系统基于实时网络延迟动态调整带宽限制，以保持低延迟的网络连接。<br><br><strong style='color: red;'>注意：开启ACC或许要降低总带宽。</strong>"))

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

-- 检查qosacc进程是否在运行（更可靠的方法）
function is_qosacc_running()
    -- 方法1：使用pidof检查（最可靠）
    local pid = util.exec("pidof qosacc 2>/dev/null | awk '{print $1}'")
    if pid and pid:gsub("%s+", "") ~= "" then
        return true, pid:gsub("%s+", "")
    end
    
    -- 方法2：使用ps检查（精确匹配）
    local output = util.exec("ps | grep -w qosacc | grep -v grep | grep -v '/bin/sh' | head -1 | awk '{print $1}'")
    if output and output:gsub("%s+", "") ~= "" then
        return true, output:gsub("%s+", "")
    end
    
    -- 方法3：检查PID文件
    local pid_file = "/var/run/qosacc.pid"
    if nixio.fs.access(pid_file) then
        local f = io.open(pid_file, "r")
        if f then
            local pid = f:read("*all"):gsub("%s+", "")
            f:close()
            if pid and pid ~= "" then
                -- 检查该PID是否还存活
                local ret = util.exec("kill -0 " .. pid .. " 2>/dev/null && echo 1 || echo 0")
                if ret and ret:match("1") then
                    return true, pid
                end
            end
        end
    end
    
    return false, nil
end

-- 获取当前qosacc进程参数
function get_qosacc_args()
    local args = ""
    local ps_output = util.exec("ps | grep -v grep | grep -w qosacc | head -1")
    if ps_output and ps_output ~= "" then
        -- 提取qosacc后面的参数
        local cmd_match = ps_output:match("qosacc%s+(.+)")
        if cmd_match then
            args = cmd_match:gsub("%s+$", "")
        end
    end
    return args
end

-- 生成qosacc启动参数（适配优化后的qosacc.c）
function generate_qosacc_args()
    local config = uci:get_all("qos_gargoyle", "qosacc") or {}
    local bandwidth = get_bandwidth_settings()
    
    local args = ""
    
    -- 1. 添加基本选项
    -- 注意：qosacc可能不需要 -b 参数，后台运行由init脚本处理
    -- 但我们保留它以防qosacc需要
    if config.enabled == "1" then
        args = args .. "-b "  -- 后台运行
    end
    
    -- 2. 启用ACTIVE/MINRTT自动切换（如果有-a选项）
    if config.enable_active_minrtt and config.enable_active_minrtt == "1" then
        args = args .. "-a "
    end
    
    -- 3. 跳过初始测量（如果需要）
    if config.skip_initial_measurement and config.skip_initial_measurement == "1" then
        args = args .. "-s "
    end
    
    -- 4. 详细模式
    if config.verbose == "1" then
        args = args .. "-v "
    end
    
    -- 5. 必需参数：ping间隔 (100-2000ms)
    local ping_interval = config.ping_interval or "800"
    if tonumber(ping_interval) >= 100 and tonumber(ping_interval) <= 2000 then
        args = args .. ping_interval .. " "
    else
        args = args .. "800 "  -- 默认800ms
    end
    
    -- 6. 必需参数：ping目标
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
            -- 如果仍然没有目标，使用Google DNS
            target_ip = (use_ipv6 == "1") and "2001:4860:4860::8888" or "8.8.8.8"
        end
    end
    
    args = args .. target_ip .. " "
    
    -- 7. 必需参数：带宽 (kbps)
    local dl_kbps = tonumber(bandwidth.download_bandwidth) or 100000
    args = args .. tostring(dl_kbps) .. " "
    
    -- 8. 可选参数：初始ping时间(ms) 与-s一起使用
    if config.skip_initial_measurement and config.skip_initial_measurement == "1" then
        if config.initial_ping_time and tonumber(config.initial_ping_time) > 0 then
            args = args .. "-t " .. config.initial_ping_time .. " "
        end
    end
    
    -- 9. 可选参数：初始链路限制(kbps) 与-s一起使用
    if config.skip_initial_measurement and config.skip_initial_measurement == "1" then
        if config.initial_link_limit and tonumber(config.initial_link_limit) > 0 then
            args = args .. "-l " .. config.initial_link_limit .. " "
        end
    end
    
    -- 10. 可选参数：自定义ping限制(ms) - 这是第四个参数
    if config.ping_limit and config.ping_limit ~= "" and tonumber(config.ping_limit) > 0 then
        args = args .. config.ping_limit .. " "
    end
    
    -- 清理多余的空白字符
    args = args:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    
    return args
end

-- 生成启动脚本
function generate_startup_script()
    local args = generate_qosacc_args()
    
    local script_content = string.format([[
#!/bin/sh
# qosacc 控制脚本
# 生成时间: %s
# 启动参数: %s

qosacc_BIN="/usr/sbin/qosacc"
PID_FILE="/var/run/qosacc.pid"
START_ARGS="%s"
LOG_FILE="/tmp/qosacc_debug.log"

# 检查qosacc程序是否存在
check_binary() {
    if [ ! -x "$qosacc_BIN" ]; then
        echo "错误: qosacc程序不存在: $qosacc_BIN" >> "$LOG_FILE"
        echo "请确保已正确安装qosacc程序" >> "$LOG_FILE"
        return 1
    fi
    return 0
}

# 获取 qosacc 进程的 PID
get_qosacc_pid() {
    pidof qosacc 2>/dev/null | awk '{print $1}'
}

# 解析启动参数
parse_args() {
    local args="$START_ARGS"
    echo "=== qosacc启动参数分析 ===" >> "$LOG_FILE"
    echo "完整参数: $args" >> "$LOG_FILE"
    
    # 显示解析后的参数
    echo "原始参数: $args" >> "$LOG_FILE"
    
    return 0
}

start() {
    echo "启动 qosacc 服务..." > "$LOG_FILE"
    echo "启动时间: $(date)" >> "$LOG_FILE"
    echo "启动参数: $qosacc_BIN $START_ARGS" >> "$LOG_FILE"
    
    # 检查二进制文件
    if ! check_binary; then
        echo "qosacc二进制文件检查失败" >&2
        return 1
    fi
    
    # 检查是否已在运行
    local qosacc_pid=$(get_qosacc_pid)
    if [ -n "$qosacc_pid" ]; then
        echo "qosacc 已在运行 (PID: $qosacc_pid)" >> "$LOG_FILE"
        echo "$qosacc_pid" > "$PID_FILE" 2>/dev/null
        return 0
    fi
    
    # 清理可能存在的旧 PID 文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 显示启动参数详情
    parse_args
    
    # 启动 qosacc - 使用直接调用，不加后台符号
    echo "正在启动 qosacc..." >> "$LOG_FILE"
    echo "执行命令: $qosacc_BIN $START_ARGS" >> "$LOG_FILE"
    
    # 先测试命令是否能运行
    echo "测试命令输出:" >> "$LOG_FILE"
    $qosacc_BIN --help 2>&1 | head -5 >> "$LOG_FILE"
    
    # 启动qosacc
    $qosacc_BIN $START_ARGS >> "$LOG_FILE" 2>&1 &
    local pid=$!
    
    # 写入PID到文件
    echo $pid > "$PID_FILE" 2>/dev/null
    
    # 等待进程启动
    sleep 2
    
    # 检查是否启动成功
    if kill -0 $pid 2>/dev/null; then
        echo "✓ qosacc 启动成功 (PID: $pid)" >> "$LOG_FILE"
        echo "PID: $pid 已写入 $PID_FILE" >> "$LOG_FILE"
        echo "启动参数: $START_ARGS" >> "$LOG_FILE"
        return 0
    else
        echo "✗ qosacc 启动失败" >> "$LOG_FILE"
        echo "最后10行日志输出:" >> "$LOG_FILE"
        tail -10 "$LOG_FILE" >> "$LOG_FILE"
        echo "检查命令是否存在: $(ls -la $qosacc_BIN 2>&1)" >> "$LOG_FILE"
        return 1
    fi
}

stop() {
    echo "停止 qosacc 服务..." > "$LOG_FILE"
    
    # 停止所有qosacc进程
    local all_pids=$(get_qosacc_pid)
    if [ -n "$all_pids" ]; then
        echo "找到进程: $all_pids" >> "$LOG_FILE"
        for pid in $all_pids; do
            if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; then
                echo "停止进程 (PID: $pid)" >> "$LOG_FILE"
                kill $pid 2>/dev/null
                sleep 1
                if kill -0 $pid 2>/dev/null; then
                    echo "强制停止进程 (PID: $pid)" >> "$LOG_FILE"
                    kill -9 $pid 2>/dev/null
                fi
            fi
        done
    fi
    
    # 从 PID 文件获取 PID
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
            echo "停止进程 (PID: $pid)" >> "$LOG_FILE"
            kill "$pid" 2>/dev/null
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                echo "强制停止进程 (PID: $pid)" >> "$LOG_FILE"
                kill -9 "$pid" 2>/dev/null
            fi
        fi
    fi
    
    # 清理 PID 文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 最终检查
    sleep 1
    if [ -z "$(get_qosacc_pid)" ]; then
        echo "✓ qosacc 已停止" >> "$LOG_FILE"
        return 0
    else
        echo "⚠ 可能有残留进程" >> "$LOG_FILE"
        return 1
    fi
}

restart() {
    echo "重启 qosacc 服务..." >> "$LOG_FILE"
    stop
    sleep 1
    start
}

status() {
    echo "qosacc 状态:"
    
    # 检查二进制文件
    if ! check_binary; then
        echo "✗ qosacc 程序不存在"
        return 1
    fi
    
    # 检查实际进程
    local qosacc_pid=$(get_qosacc_pid)
    if [ -n "$qosacc_pid" ]; then
        echo "✓ 正在运行 (PID: $qosacc_pid)"
        echo "  启动参数: $qosacc_BIN $START_ARGS"
        return 0
    else
        echo "✗ 未运行"
        return 1
    fi
}

enable() {
    echo "启用开机自启动..."
    ln -sf /etc/init.d/qosacc /etc/rc.d/S99qosacc 2>/dev/null
    ln -sf /etc/init.d/qosacc /etc/rc.d/K10qosacc 2>/dev/null
    echo "✓ 已启用开机自启动"
    return 0
}

disable() {
    echo "禁用开机自启动..."
    rm -f /etc/rc.d/S??qosacc 2>/dev/null
    rm -f /etc/rc.d/K??qosacc 2>/dev/null
    echo "✓ 已禁用开机自启动"
    return 0
}

case "$1" in
    start)   start   ;;
    stop)    stop    ;;
    restart) restart ;;
    status)  status  ;;
    enable)  enable  ;;
    disable) disable ;;
    *)
        echo "qosacc 服务控制脚本"
        echo "版本: 1.0"
        echo "当前启动参数: $START_ARGS"
        echo ""
        echo "用法: $0 {start|stop|restart|status|enable|disable}"
        exit 1
        ;;
esac

exit 0
]], os.date("%Y-%m-%d %H:%M:%S"), args, args)
    
    return script_content
end

-- 创建ACC配置节
s = m:section(NamedSection, "qosacc", "qosacc", translate("基本设置"))

-- 启用/禁用开关
enabled = s:option(Flag, "enabled", translate("启用主动拥塞控制"),
    translate("动态调整带宽限制以保持网络延迟在可接受范围内。"))
enabled.rmempty = false
enabled.default = "0"

-- 状态显示 - 修复状态显示逻辑
local status_display = s:option(DummyValue, "_status", translate("当前状态"))
function status_display.cfgvalue()
    -- 首先检查进程是否在运行
    local running, pid = is_qosacc_running()
    
    -- 然后获取配置中的enabled状态
    local config_enabled = uci:get("qos_gargoyle", "qosacc", "enabled") or "0"
    
    -- 判断实际状态
    if running then
        local info = '<span style="color: green; font-weight: bold;">✓ ACC运行中</span>'
        if pid then
            info = info .. '<br><span style="color: blue;">PID: ' .. pid .. '</span>'
        end
        
        -- 获取运行参数
        local args = get_qosacc_args()
        if args and args ~= "" then
            -- 提取关键参数显示
            local ping_interval = args:match("^(%-[a-z]%s+)*([0-9]+)")
            if ping_interval then
                ping_interval = ping_interval:match("([0-9]+)$")
            end
            if not ping_interval then
                ping_interval = args:match("(%d+)%s+[^%s]+%s+%d+")
            end
            
            local ping_target = args:match("[0-9]+%s+([^%s]+)")
            local bandwidth = args:match("[0-9]+%s+[^%s]+%s+([0-9]+)")
            
            if ping_interval then
                info = info .. '<br><span style="color: blue;">Ping间隔: ' .. ping_interval .. 'ms</span>'
            end
            if ping_target then
                info = info .. '<br><span style="color: blue;">Ping目标: ' .. ping_target .. '</span>'
            end
            if bandwidth then
                local bandwidth_mbps = math.floor(tonumber(bandwidth) / 1000)
                info = info .. '<br><span style="color: blue;">带宽限制: ' .. bandwidth .. 'kbps (' .. bandwidth_mbps .. 'Mbps)</span>'
            end
        end
        
        return info
    else
        -- 进程没有运行
        if config_enabled == "1" then
            -- 配置启用但进程未运行
            return '<span style="color: orange; font-weight: bold;">⏸ 已启用但未运行</span><br><small>请点击"保存并应用"启动ACC</small>'
        else
            -- 配置禁用且进程未运行
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
    translate("Ping测量之间的时间间隔。数值越低响应越快，但开销越大。范围: 100-2000ms"))
ping_interval.datatype = "range(100, 2000)"
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
    local args = generate_qosacc_args()
    
    return string.format("下载: %d Kbps (%d Mbps) | 上传: %d Kbps (%d Mbps)<br>qosacc启动参数: <code>%s</code>", 
        dl_kbps, dl_mbps, ul_kbps, ul_mbps, args)
end
bandwidth_info.rawhtml = true

-- 高级设置
adv_s = m:section(NamedSection, "qosacc", "qosacc", translate("高级设置"))

-- 详细日志
verbose = adv_s:option(Flag, "verbose", translate("详细日志"),
    translate("启用详细日志记录以进行调试。"))
verbose.default = "0"

-- 拥塞控制参数
adv_s:tab("congestion", translate("基本控制参数"))

-- 启用ACTIVE/MINRTT切换
enable_active_minrtt = adv_s:taboption("congestion", Flag, "enable_active_minrtt", translate("启用ACTIVE/MINRTT切换"),
    translate("根据检测到的实时类自动切换ACTIVE和REALTIME模式。"))
enable_active_minrtt.default = "1"

-- 跳过初始测量
skip_initial_measurement = adv_s:taboption("congestion", Flag, "skip_initial_measurement", translate("跳过初始测量"),
    translate("跳过15秒的初始链路测量，使用指定的初始值。"))
skip_initial_measurement.default = "0"

-- 初始ping时间
initial_ping_time = adv_s:taboption("congestion", Value, "initial_ping_time", translate("初始Ping时间 (ms)"),
    translate("与-s选项一起使用，设置初始ping时间。默认: 30ms"))
initial_ping_time.datatype = "range(5, 200)"
initial_ping_time.default = "30"
initial_ping_time:depends("skip_initial_measurement", "1")
initial_ping_time.placeholder = "30"

-- 初始链路限制
initial_link_limit = adv_s:taboption("congestion", Value, "initial_link_limit", translate("初始链路限制 (kbps)"),
    translate("与-s选项一起使用，设置初始链路限制。默认: 90000"))
initial_link_limit.datatype = "range(1000, 1000000)"
initial_link_limit.default = "90000"
initial_link_limit:depends("skip_initial_measurement", "1")
initial_link_limit.placeholder = "90000"

-- Ping限制
ping_limit = adv_s:taboption("congestion", Value, "ping_limit", translate("自定义Ping限制 (ms)"),
    translate("自定义ping时间限制。如果指定，qosacc将使用此值作为延迟阈值，否则自动测量。"))
ping_limit.datatype = "range(10, 1000)"
ping_limit.placeholder = "自动测量"
ping_limit.default = ""

-- 算法参数说明
local algo_desc = adv_s:taboption("congestion", DummyValue, "_algo_desc")
algo_desc.rawhtml = true
algo_desc.template = "cbi/dvalue"
algo_desc.cfgvalue = function()
    return [[<div style="padding: 10px; background: #f5f5f5; border-radius: 5px; margin-top: 10px;">
    <strong>优化版算法说明：</strong>
    <ul style="margin: 5px 0; padding-left: 20px;">
        <li><b>自适应控制：</b>根据延迟自动调整带宽，Ping低于限制时增加带宽，超过限制时减少带宽</li>
        <li><b>实时类检测：</b>自动检测TC中的实时类/MinRTT类，并相应调整策略</li>
        <li><b>状态机：</b>包含CHECK、INIT、ACTIVE、REALTIME、IDLE五种状态，根据网络状况自动切换</li>
        <li><b>滤波器：</b>使用指数平滑滤波处理Ping时间和带宽数据，避免抖动</li>
    </ul>
    <small style="color: #666;">默认参数已针对大多数网络优化，无需调整</small>
    </div>]]
end

-- 高级功能
adv_s:tab("advanced", translate("内部参数"))

-- 最小带宽比例
min_bandwidth_ratio = adv_s:taboption("advanced", Value, "min_bandwidth_ratio", translate("最小带宽比例 (%)"),
    translate("带宽调整的最小百分比，防止过度限速。默认: 15%"))
min_bandwidth_ratio.datatype = "range(5, 50)"
min_bandwidth_ratio.default = "15"
min_bandwidth_ratio.placeholder = "15"

-- 最大带宽比例
max_bandwidth_ratio = adv_s:taboption("advanced", Value, "max_bandwidth_ratio", translate("最大带宽比例 (%)"),
    translate("带宽调整的最大百分比，防止过度占用带宽。默认: 95%"))
max_bandwidth_ratio.datatype = "range(50, 100)"
max_bandwidth_ratio.default = "95"
max_bandwidth_ratio.placeholder = "95"

-- 带宽变化最小阈值
min_bw_change = adv_s:taboption("advanced", Value, "min_bw_change", translate("带宽变化最小阈值 (kbps)"),
    translate("只有当带宽变化超过此阈值时才更新TC规则，避免频繁调整。默认: 50kbps"))
min_bw_change.datatype = "range(10, 500)"
min_bw_change.default = "50"
min_bw_change.placeholder = "50"

-- 控制间隔
control_interval = adv_s:taboption("advanced", Value, "control_interval", translate("控制间隔 (ms)"),
    translate("TC带宽更新的时间间隔。默认: 2000ms"))
control_interval.datatype = "range(500, 10000)"
control_interval.default = "2000"
control_interval.placeholder = "2000"

-- 高级选项描述
adv_desc = adv_s:taboption("advanced", DummyValue, "_adv_desc")
adv_desc.rawhtml = true
adv_desc.template = "cbi/dvalue"
adv_desc.cfgvalue = function()
    return [[<div style="padding: 10px; background: #f5f5f5; border-radius: 5px; margin-top: 10px;">
    <strong>内部参数说明：</strong>
    <ul style="margin: 5px 0; padding-left: 20px;">
        <li>这些参数影响算法的内部行为，通常无需修改</li>
        <li>修改内部参数需要重新启动qosacc服务才能生效</li>
        <li>建议有经验的用户根据具体网络环境调整</li>
    </ul>
    </div>]]
end

-- 配置验证
function m.on_before_commit(self)
    local enabled_val = enabled:formvalue("qosacc")
    
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
        
        -- 检查qosacc程序是否存在
        if not nixio.fs.access("/usr/sbin/qosacc") then
            m.message = translate("错误: qosacc程序不存在，请确保已正确安装")
            return false
        end
    end
    
    return true
end

-- 配置保存后的处理 - 修复关键问题
function m.on_after_save(self)
    local config = uci:get_all("qos_gargoyle", "qosacc") or {}
    local script_path = "/etc/init.d/qosacc"
    
    -- 生成启动脚本
    local script_content = generate_startup_script()
    
    -- 保存启动脚本
    local f = io.open(script_path, "w")
    if f then
        f:write(script_content)
        f:close()
        sys.call("chmod 755 " .. script_path .. " 2>/dev/null")
    else
        m.message = translate("错误: 无法写入启动脚本")
        return false
    end
    
    -- 控制服务
    if config.enabled == "1" then
        -- 生成启动参数用于调试
        local args = generate_qosacc_args()
        
        -- 先停止任何可能存在的qosacc进程
        sys.call("killall -9 qosacc 2>/dev/null")
        sys.call("rm -f /var/run/qosacc.pid 2>/dev/null")
        
        -- 等待确保进程完全停止
        os.execute("sleep 1")
        
        -- 启用开机启动
        sys.call("rm -f /etc/rc.d/S??qosacc 2>/dev/null")
        sys.call("ln -sf /etc/init.d/qosacc /etc/rc.d/S99qosacc 2>/dev/null")
        
        -- 直接使用qosacc命令启动，而不是通过init脚本
        local output_file = "/tmp/qosacc_start.log"
        local error_file = "/tmp/qosacc_error.log"
        
        -- 清理旧日志
        sys.call("> " .. output_file .. " 2>/dev/null")
        sys.call("> " .. error_file .. " 2>/dev/null")
        
        -- 构建启动命令
        local start_cmd = "/usr/sbin/qosacc " .. args .. " > " .. output_file .. " 2>" .. error_file .. " &"
        
        m.message = translate("正在启动ACC服务...")
        
        -- 执行启动命令
        local ret = os.execute(start_cmd)
        
        -- 等待进程启动
        os.execute("sleep 2")
        
        -- 检查是否启动成功
        local running, pid = is_qosacc_running()
        if running then
            local bw = get_bandwidth_settings()
            local dl_mbps = math.floor(tonumber(bw.download_bandwidth) / 1000)
            local ul_mbps = math.floor(tonumber(bw.upload_bandwidth) / 1000)
            
            m.message = string.format(translate("✓ ACC服务已启动 (PID: %s)<br>下载: %d Mbps, 上传: %d Mbps"), 
                pid, dl_mbps, ul_mbps)
            
            -- 显示启动日志
            local log_content = util.exec("tail -5 " .. output_file .. " 2>/dev/null")
            if log_content and log_content ~= "" then
                m.message = m.message .. "<br><small>启动日志: " .. log_content:gsub("\n", "<br>") .. "</small>"
            end
        else
            -- 读取错误日志
            local error_msg = "未知错误"
            local f = io.open(error_file, "r")
            if f then
                error_msg = f:read("*all") or "未知错误"
                f:close()
            end
            
            -- 如果没有错误日志，尝试读取输出日志
            if error_msg == "未知错误" then
                local f2 = io.open(output_file, "r")
                if f2 then
                    error_msg = f2:read("*all") or "未知错误"
                    f2:close()
                end
            end
            
            m.message = translate("✗ ACC服务启动失败")
            if error_msg ~= "未知错误" then
                -- 提取错误信息
                local lines = {}
                for line in error_msg:gmatch("[^\n]+") do
                    table.insert(lines, line)
                end
                if #lines > 0 then
                    m.message = m.message .. "<br><small>" .. lines[1] .. "</small>"
                end
            else
                m.message = m.message .. "<br><small>请检查/usr/sbin/qosacc是否存在且有执行权限</small>"
            end
        end
    else
        -- 禁用服务
        m.message = translate("正在停止ACC服务...")
        
        -- 停止所有qosacc进程
        sys.call("killall -9 qosacc 2>/dev/null")
        sys.call("rm -f /var/run/qosacc.pid 2>/dev/null")
        
        -- 禁用开机启动
        sys.call("rm -f /etc/rc.d/S??qosacc 2>/dev/null")
        sys.call("rm -f /etc/rc.d/K??qosacc 2>/dev/null")
        
        -- 检查是否停止成功
        os.execute("sleep 1")
        local running, _ = is_qosacc_running()
        if running then
            m.message = translate("⚠ ACC服务停止失败，请手动执行: killall -9 qosacc")
        else
            m.message = translate("✓ ACC服务已停止")
        end
    end
    
    -- 短暂延迟，让状态更新
    os.execute("sleep 0.5")
    
    return true
end

-- 页面加载时检查服务状态
function m.on_init(self)
    -- 确保qosacc节存在
    if not uci:get("qos_gargoyle", "qosacc") then
        uci:section("qos_gargoyle", "qosacc", "qosacc", {
            enabled = "0",
            use_ipv6 = "0",
            ping_target = "",
            ping_target_v6 = "",
            ping_interval = "800",
            verbose = "0",
            enable_active_minrtt = "1",
            skip_initial_measurement = "0",
            initial_ping_time = "30",
            initial_link_limit = "90000",
            ping_limit = "",
            min_bandwidth_ratio = "15",
            max_bandwidth_ratio = "95",
            min_bw_change = "50",
            control_interval = "2000"
        })
        uci:save("qos_gargoyle")
        uci:commit("qos_gargoyle")
    end
    
    -- 检查qosacc程序是否存在
    if not nixio.fs.access("/usr/sbin/qosacc") then
        m.message = translate("警告: qosacc程序不存在于/usr/sbin/，请确保已正确安装")
    end
    
    -- 生成启动脚本（如果需要）
    if not nixio.fs.access("/etc/init.d/qosacc") then
        local script_content = generate_startup_script()
        local f = io.open("/etc/init.d/qosacc", "w")
        if f then
            f:write(script_content)
            f:close()
            sys.call("chmod 755 /etc/init.d/qosacc 2>/dev/null")
        end
    end
end

return m