-- Copyright 2026 ilxp <lixp@live.com>
-- Licensed to the public under the Apache License 2.0.

local uci  = require "luci.model.uci".cursor()
local dsp  = require "luci.dispatcher"
local util = require "luci.util"
local sys  = require "luci.sys"
local ip   = require "luci.ip"

m = Map("qos_gargoyle", translate("Active Congestion Control"),
    translate("Active Congestion Control dynamically adjusts bandwidth limits based on real-time network latency to maintain low-latency network connections.<br><br><strong style='color: red;'>Note: Enabling ACC may require reducing total bandwidth.</strong>"))

m.redirect = dsp.build_url("admin/qos/qos_gargoyle")
m.submit = translate("Save & Apply")
m.reset = false

-- 获取带宽设置
function get_bandwidth_settings()
    local dl_config = uci:get_all("qos_gargoyle", "download") or {}
    local ul_config = uci:get_all("qos_gargoyle", "upload") or {}
    
    return {
        download_bandwidth = dl_config.total_bandwidth or "100000",  -- 单位：Kbps
        upload_bandwidth = ul_config.total_bandwidth or "50000"     -- 单位：Kbps
    }
end

-- IP地址验证函数
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

-- 自动检测网关函数（仅用于Ping目标）
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

-- 生成qosacc启动参数（适配优化后的qosacc.c，使用选项式参数）
function generate_qosacc_args()
    local config = uci:get_all("qos_gargoyle", "qosacc") or {}
    local bandwidth = get_bandwidth_settings()
    local args = {}

    -- 获取WAN接口：从global节的wan_interface读取（必须存在）
    local wan_iface = uci:get("qos_gargoyle", "global", "wan_interface")
    if not wan_iface or wan_iface == "" then
        -- 如果配置中没有，则使用默认值（回退）
        wan_iface = "pppoe-wan"
    end
    table.insert(args, "-d " .. wan_iface)

    -- Ping 目标
    local use_ipv6 = config.use_ipv6 or "0"
    local target_ip = ""
    if use_ipv6 == "1" and config.ping_target_v6 and config.ping_target_v6 ~= "" then
        if is_valid_ip(config.ping_target_v6, true) then
            target_ip = config.ping_target_v6
        end
    else
        if config.ping_target and config.ping_target ~= "" then
            if is_valid_ip(config.ping_target, false) then
                target_ip = config.ping_target
            end
        end
    end
    if target_ip == "" then
        -- 用户未设置Ping目标，自动检测网关
        local gateway = detect_gateway(use_ipv6 == "1")
        target_ip = gateway or (use_ipv6 == "1" and "2400:3200::1" or "223.5.5.5")
    end
    table.insert(args, "-t " .. target_ip)

    -- Ping 间隔
    local ping_interval = config.ping_interval or "800"
    if tonumber(ping_interval) < 100 then ping_interval = "100" end
    if tonumber(ping_interval) > 2000 then ping_interval = "2000" end
    table.insert(args, "-p " .. ping_interval)

    -- 最大带宽（下载带宽）
    local dl_kbps = tonumber(bandwidth.download_bandwidth) or 100000
    table.insert(args, "-m " .. tostring(dl_kbps))

    -- Ping 限制（可选）
    if config.ping_limit and config.ping_limit ~= "" and tonumber(config.ping_limit) > 0 then
        local limit = tonumber(config.ping_limit)
        if limit < 10 then limit = 10 end
        if limit > 1000 then limit = 1000 end
        table.insert(args, "-P " .. tostring(limit))
    end

    -- 后台运行：由脚本通过 & 管理，不再传递 -b
    -- if config.enabled == "1" then
    --     table.insert(args, "-b")
    -- end

    -- 自动切换模式（原 enable_active_minrtt 对应 -A）
    if config.enable_active_minrtt == "1" then
        table.insert(args, "-A")
    end

    -- 跳过初始测量
    if config.skip_initial_measurement == "1" then
        table.insert(args, "-I")
    end

    -- 详细日志
    if config.verbose == "1" then
        table.insert(args, "-v")
    end

    return table.concat(args, " ")
end

-- 创建ACC配置节
s = m:section(NamedSection, "qosacc", "qosacc", translate("Basic Settings"))

-- 启用/禁用开关
enabled = s:option(Flag, "enabled", translate("Enable Active Congestion Control"),
    translate("Dynamically adjust bandwidth limits to keep network latency within acceptable range."))
enabled.rmempty = false
enabled.default = "0"

-- 状态显示 - 修复状态显示逻辑
local status_display = s:option(DummyValue, "_status", translate("Current Status"))
function status_display.cfgvalue()
    -- 首先检查进程是否在运行
    local running, pid = is_qosacc_running()
    
    -- 然后获取配置中的enabled状态
    local config_enabled = uci:get("qos_gargoyle", "qosacc", "enabled") or "0"
    
    -- 判断实际状态
    if running then
        local info = '<span style="color: green; font-weight: bold;">✓ ACC Running</span>'
        if pid then
            info = info .. '<br><span style="color: blue;">PID: ' .. pid .. '</span>'
        end
        
        -- 获取运行参数
        local args = get_qosacc_args()
        if args and args ~= "" then
            -- 提取关键参数显示
            local ping_interval = args:match("%-p%s+(%d+)")
            local ping_target = args:match("%-t%s+([^%s]+)")
            local bandwidth = args:match("%-m%s+(%d+)")
            
            if ping_interval then
                info = info .. '<br><span style="color: blue;">Ping Interval: ' .. ping_interval .. 'ms</span>'
            end
            if ping_target then
                info = info .. '<br><span style="color: blue;">Ping Target: ' .. ping_target .. '</span>'
            end
            if bandwidth then
                local bandwidth_mbps = math.floor(tonumber(bandwidth) / 1000)
                info = info .. '<br><span style="color: blue;">Bandwidth Limit: ' .. bandwidth .. 'kbps (' .. bandwidth_mbps .. 'Mbps)</span>'
            end
        end
        
        return info
    else
        -- 进程没有运行
        if config_enabled == "1" then
            -- 配置启用但进程未运行
            return '<span style="color: orange; font-weight: bold;">⏸ Enabled but not running</span><br><small>Click "Save & Apply" to start ACC</small>'
        else
            -- 配置禁用且进程未运行
            return '<span style="color: gray;">Disabled</span>'
        end
    end
end
status_display.rawhtml = true

-- IPv4/IPv6选择
use_ipv6 = s:option(ListValue, "use_ipv6", translate("IP Protocol Version"),
    translate("Select the IP protocol version to use."))
use_ipv6:value("0", translate("IPv4"))
use_ipv6:value("1", translate("IPv6"))
use_ipv6.default = "0"

-- Ping目标设置
ping_target = s:option(Value, "ping_target", translate("Ping Target (IPv4)"),
    translate("IPv4 address used for latency monitoring. Leave empty to auto-detect gateway."))
ping_target.datatype = "ip4addr"
ping_target:depends("use_ipv6", "0")
ping_target.placeholder = "Auto-detect (gateway)"

ping_target_v6 = s:option(Value, "ping_target_v6", translate("Ping Target (IPv6)"),
    translate("IPv6 address used for latency monitoring. Leave empty to auto-detect gateway."))
ping_target_v6.datatype = "ip6addr"
ping_target_v6:depends("use_ipv6", "1")
ping_target_v6.placeholder = "Auto-detect (gateway)"

-- Ping间隔
ping_interval = s:option(Value, "ping_interval", translate("Ping Interval (ms)"),
    translate("Time interval between ping measurements. Lower values respond faster but incur more overhead. Range: 100-2000ms"))
ping_interval.datatype = "range(100, 2000)"
ping_interval.default = "800"

-- 网关检测结果显示
local gateway_info = s:option(DummyValue, "_gateway_info", translate("Gateway Detection"))
function gateway_info.cfgvalue()
    local ipv4_gateway = detect_gateway(false)
    local ipv6_gateway = detect_gateway(true)
    
    local result = ""
    if ipv4_gateway then
        result = result .. "✓ IPv4 Gateway: " .. ipv4_gateway .. "<br>"
    else
        result = result .. "✗ IPv4 Gateway: Not detected<br>"
    end
    
    if ipv6_gateway then
        result = result .. "✓ IPv6 Gateway: " .. ipv6_gateway
    else
        result = result .. "✗ IPv6 Gateway: Not detected"
    end
    
    return result
end
gateway_info.rawhtml = true

-- 添加带宽信息显示
bandwidth_info = s:option(DummyValue, "_bandwidth_info", translate("Bandwidth Configuration Info"))
function bandwidth_info.cfgvalue(self, section)
    local bw = get_bandwidth_settings()
    local dl_kbps = tonumber(bw.download_bandwidth) or 0
    local ul_kbps = tonumber(bw.upload_bandwidth) or 0
    local dl_mbps = math.floor(dl_kbps / 1000)
    local ul_mbps = math.floor(ul_kbps / 1000)
    
    -- 获取生成的参数用于显示
    local args = generate_qosacc_args()
    
    return string.format("Download: %d Kbps (%d Mbps) | Upload: %d Kbps (%d Mbps)<br>qosacc startup arguments: <code>%s</code>", 
        dl_kbps, dl_mbps, ul_kbps, ul_mbps, args)
end
bandwidth_info.rawhtml = true

-- 高级设置
adv_s = m:section(NamedSection, "qosacc", "qosacc", translate("Advanced Settings"))

-- 详细日志
verbose = adv_s:option(Flag, "verbose", translate("Verbose Logging"),
    translate("Enable detailed logging for debugging."))
verbose.default = "0"

-- 拥塞控制参数
adv_s:tab("congestion", translate("Basic Control Parameters"))

-- 启用ACTIVE/REALTIME切换
enable_active_minrtt = adv_s:taboption("congestion", Flag, "enable_active_minrtt", translate("Enable ACTIVE/REALTIME Switching"),
    translate("Automatically switch between ACTIVE and REALTIME modes based on detected real-time classes."))
enable_active_minrtt.default = "1"

-- 跳过初始测量
skip_initial_measurement = adv_s:taboption("congestion", Flag, "skip_initial_measurement", translate("Skip Initial Measurement"),
    translate("Skip the 15-second initial link measurement and use specified initial values."))
skip_initial_measurement.default = "0"

-- 初始ping时间
initial_ping_time = adv_s:taboption("congestion", Value, "initial_ping_time", translate("Initial Ping Time (ms)"),
    translate("Used with -I option to set initial ping time. Default: 30ms"))
initial_ping_time.datatype = "range(5, 200)"
initial_ping_time.default = "30"
initial_ping_time:depends("skip_initial_measurement", "1")
initial_ping_time.placeholder = "30"

-- 初始链路限制
initial_link_limit = adv_s:taboption("congestion", Value, "initial_link_limit", translate("Initial Link Limit (kbps)"),
    translate("Used with -I option to set initial link limit. Default: 90000"))
initial_link_limit.datatype = "range(1000, 1000000)"
initial_link_limit.default = "90000"
initial_link_limit:depends("skip_initial_measurement", "1")
initial_link_limit.placeholder = "90000"

-- Ping限制
ping_limit = adv_s:taboption("congestion", Value, "ping_limit", translate("Custom Ping Limit (ms)"),
    translate("Custom ping time limit. If specified, qosacc uses this value as latency threshold; otherwise auto-measured."))
ping_limit.datatype = "range(10, 1000)"
ping_limit.placeholder = "Auto-measured"
ping_limit.default = ""

-- 算法参数说明
local algo_desc = adv_s:taboption("congestion", DummyValue, "_algo_desc")
algo_desc.rawhtml = true
algo_desc.template = "cbi/dvalue"
algo_desc.cfgvalue = function()
    return [[<div style="padding: 10px; background: #f5f5f5; border-radius: 5px; margin-top: 10px;">
    <strong>Optimized Algorithm Description:</strong>
    <ul style="margin: 5px 0; padding-left: 20px;">
        <li><b>Adaptive Control:</b> Adjusts bandwidth based on latency; increases bandwidth when ping is below limit, decreases when above limit.</li>
        <li><b>Real-time Class Detection:</b> Automatically detects real-time/MinRTT classes in TC and adjusts strategy accordingly.</li>
        <li><b>State Machine:</b> Includes CHK, INIT, ACTIVE, REALTIME, IDLE states, automatically switching based on network conditions.</li>
        <li><b>Filter:</b> Uses exponential smoothing to filter ping times and bandwidth data, avoiding jitter.</li>
    </ul>
    <small style="color: #666;">Default parameters are optimized for most networks; no adjustment needed.</small>
    </div>]]
end

-- 高级功能
adv_s:tab("advanced", translate("Internal Parameters"))

-- 最小带宽比例
min_bandwidth_ratio = adv_s:taboption("advanced", Value, "min_bandwidth_ratio", translate("Minimum Bandwidth Ratio (%)"),
    translate("Minimum percentage of bandwidth adjustment to prevent excessive throttling. Default: 15%"))
min_bandwidth_ratio.datatype = "range(5, 50)"
min_bandwidth_ratio.default = "15"
min_bandwidth_ratio.placeholder = "15"

-- 最大带宽比例
max_bandwidth_ratio = adv_s:taboption("advanced", Value, "max_bandwidth_ratio", translate("Maximum Bandwidth Ratio (%)"),
    translate("Maximum percentage of bandwidth adjustment to prevent excessive bandwidth usage. Default: 95%"))
max_bandwidth_ratio.datatype = "range(50, 100)"
max_bandwidth_ratio.default = "95"
max_bandwidth_ratio.placeholder = "95"

-- 带宽变化最小阈值
min_bw_change = adv_s:taboption("advanced", Value, "min_bw_change", translate("Min Bandwidth Change (kbps)"),
    translate("Only update TC rules when bandwidth change exceeds this threshold to avoid frequent adjustments. Default: 50kbps"))
min_bw_change.datatype = "range(10, 500)"
min_bw_change.default = "50"
min_bw_change.placeholder = "50"

-- 控制间隔
control_interval = adv_s:taboption("advanced", Value, "control_interval", translate("Control Interval (ms)"),
    translate("Time interval for TC bandwidth updates. Default: 2000ms"))
control_interval.datatype = "range(500, 10000)"
control_interval.default = "2000"
control_interval.placeholder = "2000"

-- 高级选项描述
adv_desc = adv_s:taboption("advanced", DummyValue, "_adv_desc")
adv_desc.rawhtml = true
adv_desc.template = "cbi/dvalue"
adv_desc.cfgvalue = function()
    return [[<div style="padding: 10px; background: #f5f5f5; border-radius: 5px; margin-top: 10px;">
    <strong>Internal Parameters Description:</strong>
    <ul style="margin: 5px 0; padding-left: 20px;">
        <li>These parameters affect the internal behavior of the algorithm and usually do not need modification.</li>
        <li>Modifying internal parameters requires restarting the qosacc service to take effect.</li>
        <li>It is recommended for experienced users to adjust according to specific network environment.</li>
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
            m.message = translate("Please set download bandwidth in the download configuration section before enabling ACC.")
            return false
        end
        
        if not bw.upload_bandwidth or tonumber(bw.upload_bandwidth) == 0 then
            m.message = translate("Please set upload bandwidth in the upload configuration section before enabling ACC.")
            return false
        end
        
        -- 检查qosacc程序是否存在
        if not nixio.fs.access("/usr/sbin/qosacc") then
            m.message = translate("Error: qosacc binary not found. Please ensure it is installed correctly.")
            return false
        end
    end
    
    return true
end

-- 配置保存后的处理 - 直接启动/停止 qosacc，不再生成 init 脚本
function m.on_after_save(self)
    local config = uci:get_all("qos_gargoyle", "qosacc") or {}
    
    -- 控制服务
    if config.enabled == "1" then
        -- 生成启动参数用于调试
        local args = generate_qosacc_args()
        
        -- 先停止任何可能存在的qosacc进程
        sys.call("killall -9 qosacc 2>/dev/null")
        sys.call("rm -f /var/run/qosacc.pid 2>/dev/null")
        
        -- 等待确保进程完全停止
        os.execute("sleep 1")
        
        -- 启用开机启动（创建软链接，假设 init 脚本已存在）
        sys.call("rm -f /etc/rc.d/S??qosacc 2>/dev/null")
        sys.call("ln -sf /etc/init.d/qosacc /etc/rc.d/S99qosacc 2>/dev/null")
        sys.call("ln -sf /etc/init.d/qosacc /etc/rc.d/K10qosacc 2>/dev/null")
        
        -- 直接使用qosacc命令启动（由脚本管理后台，不加 -b）
        local output_file = "/tmp/qosacc_start.log"
        local error_file = "/tmp/qosacc_error.log"
        
        -- 清理旧日志
        sys.call("> " .. output_file .. " 2>/dev/null")
        sys.call("> " .. error_file .. " 2>/dev/null")
        
        -- 构建启动命令（使用 & 放入后台，因为 qosacc 自身不带 -b）
        local start_cmd = "/usr/sbin/qosacc " .. args .. " >> " .. output_file .. " 2>> " .. error_file .. " &"
        
        m.message = translate("Starting ACC service...")
        
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
            
            m.message = string.format(translate("✓ ACC service started (PID: %s)<br>Download: %d Mbps, Upload: %d Mbps"), 
                pid, dl_mbps, ul_mbps)
            
            -- 显示启动日志
            local log_content = util.exec("tail -5 " .. output_file .. " 2>/dev/null")
            if log_content and log_content ~= "" then
                m.message = m.message .. "<br><small>Startup log: " .. log_content:gsub("\n", "<br>") .. "</small>"
            end
        else
            -- 读取错误日志
            local error_msg = "Unknown error"
            local f = io.open(error_file, "r")
            if f then
                error_msg = f:read("*all") or "Unknown error"
                f:close()
            end
            
            -- 如果没有错误日志，尝试读取输出日志
            if error_msg == "Unknown error" then
                local f2 = io.open(output_file, "r")
                if f2 then
                    error_msg = f2:read("*all") or "Unknown error"
                    f2:close()
                end
            end
            
            m.message = translate("✗ ACC service failed to start")
            if error_msg ~= "Unknown error" then
                -- 提取错误信息
                local lines = {}
                for line in error_msg:gmatch("[^\n]+") do
                    table.insert(lines, line)
                end
                if #lines > 0 then
                    m.message = m.message .. "<br><small>" .. lines[1] .. "</small>"
                end
            else
                m.message = m.message .. "<br><small>Please check if /usr/sbin/qosacc exists and has execute permission</small>"
            end
        end
    else
        -- 禁用服务
        m.message = translate("Stopping ACC service...")
        
        -- 停止所有qosacc进程
        sys.call("killall -9 qosacc 2>/dev/null")
        sys.call("rm -f /var/run/qosacc.pid 2>/dev/null")
        
        -- 禁用开机启动（移除软链接）
        sys.call("rm -f /etc/rc.d/S??qosacc 2>/dev/null")
        sys.call("rm -f /etc/rc.d/K??qosacc 2>/dev/null")
        
        -- 检查是否停止成功
        os.execute("sleep 1")
        local running, _ = is_qosacc_running()
        if running then
            m.message = translate("⚠ ACC service stop failed, please manually execute: killall -9 qosacc")
        else
            m.message = translate("✓ ACC service stopped")
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
        m.message = translate("Warning: qosacc binary not found in /usr/sbin/. Please ensure it is installed correctly.")
    end
end

return m