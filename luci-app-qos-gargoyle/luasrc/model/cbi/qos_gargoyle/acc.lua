-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

local uci  = require "luci.model.uci".cursor()
local dsp  = require "luci.dispatcher"
local util = require "luci.util"
local sys  = require "luci.sys"
local ip   = require "luci.ip"
local nixio = require "nixio"

m = Map("qos_gargoyle", translate("主动拥塞控制 (ACC)"),
    translate("主动拥塞控制系统基于实时网络延迟动态调整带宽限制，以保持低延迟的网络连接。<br><br><strong style='color: red;'>注意：开启ACC时会使用配置文件管理，请确保配置文件正确。</strong>"))

m.redirect = dsp.build_url("admin/qos/qos_gargoyle")
m.submit = translate("保存并应用")
m.reset = false

-- 检查qosacc是否存在
local qosacc_exists = nixio.fs.access("/usr/sbin/qosacc")

-- 检查配置生成脚本是否存在
local config_script_exists = nixio.fs.access("/usr/lib/qos_gargoyle/acc_conf.sh")

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

-- 检查qosacc进程是否在运行
function is_qosacc_running()
    -- 使用pidof检查
    local pid = util.exec("pidof qosacc 2>/dev/null | awk '{print $1}'")
    if pid and pid:gsub("%s+", "") ~= "" then
        return true, pid:gsub("%s+", "")
    end
    
    -- 检查PID文件
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

-- 检查配置文件是否存在
function is_config_file_exists()
    return nixio.fs.access("/etc/qosacc.conf")
end

-- 调用外部配置生成脚本
function generate_config_via_script()
    if not config_script_exists then
        return false, "配置生成脚本不存在: /usr/lib/qos_gargoyle/acc_conf.sh"
    end
    
    local ret = os.execute("/usr/lib/qos_gargoyle/acc_conf.sh generate 2>&1")
    if ret == 0 or ret == true then
        return true, "配置生成成功"
    else
        return false, "配置生成脚本执行失败"
    end
end

-- 手动生成配置文件（当外部脚本不存在时的备用方案）
function generate_config_manual()
    local config = uci:get_all("qos_gargoyle", "qosacc") or {}
    local bandwidth = get_bandwidth_settings()
    
    local use_ipv6 = config.use_ipv6 or "0"
    local ping_target = config.ping_target or ""
    local ping_target_v6 = config.ping_target_v6 or ""
    
    -- 确定目标IP
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
    
    -- 构建配置文件内容
    local conf_content = [[# qosacc.conf - QoS监控器配置文件
# 生成时间: ]] .. os.date("%Y-%m-%d %H:%M:%S") .. [[
# 生成来源: qos_gargoyle Web界面 (手动生成)

# 基本配置
[basic]
ping_interval = ]] .. (config.ping_interval or "800") .. [[
target = ]] .. target_ip .. [[
max_bandwidth_kbps = ]] .. (bandwidth.download_bandwidth or "100000") .. [[
ping_limit_ms = ]] .. (config.ping_limit or "20") .. [[
device = ifb0
classid = 0x101

# 控制参数
[control]
safe_mode = 0
verbose = ]] .. (config.verbose or "0") .. [[
auto_switch_mode = ]] .. (config.enable_active_minrtt or "1") .. [[
background_mode = 1
skip_initial = ]] .. (config.skip_initial_measurement or "0") .. [[

# 算法参数
[algorithm]
min_bw_change_kbps = ]] .. (config.min_bw_change or "10") .. [[
min_bw_ratio = ]] .. (tostring(tonumber(config.min_bandwidth_ratio or "15") / 100)) .. [[
max_bw_ratio = ]] .. (tostring(tonumber(config.max_bandwidth_ratio or "95") / 100)) .. [[
smoothing_factor = 0.3
active_threshold = 0.7
idle_threshold = 0.3
safe_start_ratio = 0.5

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
stats_interval_ms = ]] .. (config.control_interval or "2000") .. [[
control_interval_ms = ]] .. (config.control_interval or "2000") .. [[
realtime_detect_ms = 1000
heartbeat_interval_ms = 10000
]]
    
    -- 如果设置了初始ping时间和链路限制，添加到配置
    if config.skip_initial_measurement and config.skip_initial_measurement == "1" then
        local initial_ping_time = config.initial_ping_time or "30"
        local initial_link_limit = config.initial_link_limit or "90000"
        conf_content = conf_content .. [[
# 跳过初始测量参数
[skip_initial]
initial_ping_time = ]] .. initial_ping_time .. [[
initial_link_limit = ]] .. initial_link_limit .. [[
]]
    end
    
    -- 保存配置文件
    local f = io.open("/etc/qosacc.conf", "w")
    if f then
        f:write(conf_content)
        f:close()
        return true, "配置文件已生成"
    else
        return false, "无法写入配置文件"
    end
end

-- 生成配置文件（优先使用外部脚本）
function generate_config_file()
    if config_script_exists then
        return generate_config_via_script()
    else
        return generate_config_manual()
    end
end

-- 创建ACC配置节
s = m:section(NamedSection, "qosacc", "qosacc", translate("基本设置"))

-- 状态显示
local status_display = s:option(DummyValue, "_status", translate("当前状态"))
function status_display.cfgvalue()
    -- 检查进程是否在运行
    local running, pid = is_qosacc_running()
    
    -- 检查配置文件是否存在
    local config_exists = is_config_file_exists()
    
    -- 获取配置中的enabled状态
    local config_enabled = uci:get("qos_gargoyle", "qosacc", "enabled") or "0"
    
    local status_html = ""
    
    if running then
        status_html = '<span style="color: green; font-weight: bold;">✓ ACC运行中</span>'
        if pid then
            status_html = status_html .. '<br><span style="color: blue;">PID: ' .. pid .. '</span>'
        end
        
        -- 显示启动方式
        status_html = status_html .. '<br><span style="color: #666;">通过配置文件: /etc/qosacc.conf</span>'
    else
        if config_enabled == "1" then
            status_html = '<span style="color: orange; font-weight: bold;">⏸ 已启用但未运行</span>'
            if not config_exists then
                status_html = status_html .. '<br><span style="color: red;">配置文件不存在</span>'
            end
        else
            status_html = '<span style="color: gray;">已禁用</span>'
        end
    end
    
    -- 配置文件状态
    status_html = status_html .. '<br>'
    if config_exists then
        status_html = status_html .. '<span style="color: green;">✓ 配置文件: 存在</span>'
    else
        status_html = status_html .. '<span style="color: orange;">⚠ 配置文件: 不存在</span>'
    end
    
    -- 显示配置生成脚本状态
    status_html = status_html .. '<br>'
    if config_script_exists then
        status_html = status_html .. '<span style="color: green;">✓ 配置脚本: 已安装</span>'
    else
        status_html = status_html .. '<span style="color: orange;">⚠ 配置脚本: 未安装</span>'
    end
    
    return status_html
end
status_display.rawhtml = true

-- 只有qosacc存在时才显示配置选项
if qosacc_exists then
    -- 启用/禁用开关
    enabled = s:option(Flag, "enabled", translate("启用主动拥塞控制"),
        translate("动态调整带宽限制以保持网络延迟在可接受范围内。使用配置文件 /etc/qosacc.conf"))
    enabled.rmempty = false
    enabled.default = "0"
    
    -- IPv4/IPv6选择
    use_ipv6 = s:option(ListValue, "use_ipv6", translate("IP协议版本"),
        translate("选择使用的IP协议版本。"))
    use_ipv6:value("0", translate("IPv4"))
    use_ipv6:value("1", translate("IPv6"))
    use_ipv6.default = "0"
    use_ipv6:depends("enabled", "1")
    
    -- Ping目标设置
    ping_target = s:option(Value, "ping_target", translate("Ping目标 (IPv4)"),
        translate("用于监控延迟的IPv4地址。留空则自动检测网关。"))
    ping_target.datatype = "ip4addr"
    ping_target:depends("enabled", "1")
    ping_target.placeholder = "自动检测 (网关)"
    
    ping_target_v6 = s:option(Value, "ping_target_v6", translate("Ping目标 (IPv6)"),
        translate("用于监控延迟的IPv6地址。留空则自动检测网关。"))
    ping_target_v6.datatype = "ip6addr"
    ping_target_v6:depends({"enabled", "use_ipv6"}, {"1", "1"})
    ping_target_v6.placeholder = "自动检测 (网关)"
    
    -- Ping间隔
    ping_interval = s:option(Value, "ping_interval", translate("Ping间隔 (毫秒)"),
        translate("Ping测量之间的时间间隔。数值越低响应越快，但开销越大。范围: 100-2000ms"))
    ping_interval.datatype = "range(100, 2000)"
    ping_interval.default = "800"
    ping_interval:depends("enabled", "1")
else
    -- 如果qosacc不存在，显示安装提示
    local install_note = s:option(DummyValue, "_install_note", translate("安装提示"))
    install_note.rawhtml = true
    install_note.value = [[
    <div style="padding: 10px; background-color: #fff3cd; border: 1px solid #ffeaa7; border-radius: 5px;">
    <strong>qosacc 未安装</strong><br>
    要使用主动拥塞控制功能，请先安装 qosacc 包：<br>
    <code>opkg update && opkg install qosacc</code>
    </div>
    ]]
end

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
    
    -- 获取配置文件生成预览
    local config_preview = ""
    if nixio.fs.access("/etc/qosacc.conf") then
        local f = io.open("/etc/qosacc.conf", "r")
        if f then
            local lines = {}
            for i = 1, 10 do
                local line = f:read("*l")
                if line then
                    table.insert(lines, line)
                else
                    break
                end
            end
            f:close()
            if #lines > 0 then
                config_preview = table.concat(lines, "<br>")
            end
        end
    end
    
    return string.format("下载: %d Kbps (%d Mbps) | 上传: %d Kbps (%d Mbps)<br><br><strong>配置文件预览:</strong><br><small><code>%s</code></small>", 
        dl_kbps, dl_mbps, ul_kbps, ul_mbps, config_preview)
end
bandwidth_info.rawhtml = true

-- 高级设置（只有在qosacc存在时才显示）
if qosacc_exists then
    adv_s = m:section(NamedSection, "qosacc", "qosacc", translate("高级设置"))
    adv_s:depends("enabled", "1")
    
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
    ping_limit.placeholder = "20 (默认)"
    ping_limit.default = "20"
    
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
end

-- 配置验证
function m.on_before_commit(self)
    if not qosacc_exists then
        m.message = translate("qosacc程序未安装，请先安装qosacc包")
        return false
    end
    
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
    end
    
    return true
end

-- 配置保存后的处理
function m.on_after_save(self)
    local config = uci:get_all("qos_gargoyle", "qosacc") or {}
    
    if not qosacc_exists then
        m.message = translate("错误: qosacc程序未安装")
        return false
    end
    
    -- 生成配置文件
    local success, message = generate_config_file()
    if not success then
        m.message = translate("配置文件生成失败: ") .. message
        return false
    end
    
    m.message = translate("配置文件已生成: /etc/qosacc.conf")
    
    -- 控制服务
    if config.enabled == "1" then
        m.message = m.message .. "<br>" .. translate("正在启动ACC服务...")
        
        -- 通过init脚本启动服务
        local ret = os.execute("/etc/init.d/qosacc restart 2>&1")
        
        -- 等待进程启动
        os.execute("sleep 2")
        
        -- 检查是否启动成功
        local running, pid = is_qosacc_running()
        if running then
            local bw = get_bandwidth_settings()
            local dl_mbps = math.floor(tonumber(bw.download_bandwidth) / 1000)
            local ul_mbps = math.floor(tonumber(bw.upload_bandwidth) / 1000)
            
            m.message = string.format(translate("✓ ACC服务已启动 (PID: %s)<br>下载: %d Mbps, 上传: %d Mbps<br>配置文件: /etc/qosacc.conf"), 
                pid, dl_mbps, ul_mbps)
        else
            -- 尝试获取错误信息
            local error_msg = util.exec("/etc/init.d/qosacc status 2>&1")
            m.message = translate("✗ ACC服务启动失败")
            if error_msg and error_msg ~= "" then
                m.message = m.message .. "<br><small>" .. error_msg .. "</small>"
            end
        end
    else
        -- 禁用服务
        m.message = m.message .. "<br>" .. translate("正在停止ACC服务...")
        
        -- 通过init脚本停止服务
        os.execute("/etc/init.d/qosacc stop 2>&1")
        
        -- 检查是否停止成功
        os.execute("sleep 1")
        local running, _ = is_qosacc_running()
        if running then
            m.message = m.message .. "<br>" .. translate("⚠ ACC服务停止失败，请手动执行: /etc/init.d/qosacc stop")
        else
            m.message = m.message .. "<br>" .. translate("✓ ACC服务已停止")
        end
    end
    
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
            ping_limit = "20",
            min_bandwidth_ratio = "15",
            max_bandwidth_ratio = "95",
            min_bw_change = "50",
            control_interval = "2000"
        })
        uci:save("qos_gargoyle")
        uci:commit("qos_gargoyle")
    end
    
    -- 检查qosacc程序是否存在
    if not qosacc_exists then
        m.message = translate("警告: qosacc程序不存在于/usr/sbin/，请确保已正确安装")
    end
    
    -- 检查init脚本是否存在
    if not nixio.fs.access("/etc/init.d/qosacc") then
        m.message = (m.message or "") .. "<br>" .. translate("警告: qosacc init脚本不存在，请运行安装脚本")
    end
    
    -- 检查配置生成脚本
    if not config_script_exists then
        m.message = (m.message or "") .. "<br>" .. translate("警告: 配置生成脚本不存在，将使用内置生成功能")
    end
end

-- 添加操作按钮
local action_section = m:section(SimpleSection, nil, translate("操作"))
action_section.anonymous = true

-- 查看配置文件按钮
local view_config_btn = action_section:option(Button, "_view_config", translate("查看配置文件"))
view_config_btn.inputtitle = translate("查看 /etc/qosacc.conf")
view_config_btn.inputstyle = "apply"

function view_config_btn.write(self, section, value)
    if nixio.fs.access("/etc/qosacc.conf") then
        local f = io.open("/etc/qosacc.conf", "r")
        if f then
            local content = f:read("*all")
            f:close()
            m.message = "<pre style='background: #f5f5f5; padding: 10px; border-radius: 5px; overflow: auto; max-height: 300px;'>" .. 
                       content .. "</pre>"
        else
            m.message = translate("无法读取配置文件")
        end
    else
        m.message = translate("配置文件不存在，请先保存配置")
    end
end

-- 重新生成配置文件按钮
local regen_config_btn = action_section:option(Button, "_regen_config", translate("重新生成配置文件"))
regen_config_btn.inputtitle = translate("重新生成")
regen_config_btn.inputstyle = "apply"

function regen_config_btn.write(self, section, value)
    local success, message = generate_config_file()
    if success then
        m.message = translate("配置文件已重新生成: /etc/qosacc.conf")
    else
        m.message = translate("配置文件重新生成失败: ") .. message
    end
end

-- 重启服务按钮
local restart_btn = action_section:option(Button, "_restart_service", translate("重启服务"))
restart_btn.inputtitle = translate("重启")
restart_btn.inputstyle = "apply"

function restart_btn.write(self, section, value)
    os.execute("/etc/init.d/qosacc restart 2>&1")
    os.execute("sleep 1")
    
    local running, pid = is_qosacc_running()
    if running then
        m.message = translate("✓ ACC服务已重启 (PID: " .. pid .. ")")
    else
        m.message = translate("✗ ACC服务重启失败")
    end
end

-- 调用配置生成脚本按钮
local generate_script_btn = action_section:option(Button, "_generate_script", translate("调用配置生成脚本"))
generate_script_btn.inputtitle = translate("执行脚本")
generate_script_btn.inputstyle = "apply"

function generate_script_btn.write(self, section, value)
    if config_script_exists then
        local output = util.exec("/usr/lib/qos_gargoyle/acc_conf.sh generate 2>&1")
        m.message = translate("配置生成脚本输出:") .. "<br><pre style='background: #f5f5f5; padding: 10px; border-radius: 5px; overflow: auto; max-height: 200px;'>" .. 
                   output .. "</pre>"
    else
        m.message = translate("配置生成脚本不存在: /usr/lib/qos_gargoyle/acc_conf.sh")
    end
end

-- 查看脚本内容按钮
local view_script_btn = action_section:option(Button, "_view_script", translate("查看配置脚本"))
view_script_btn.inputtitle = translate("查看脚本")
view_script_btn.inputstyle = "apply"

function view_script_btn.write(self, section, value)
    if config_script_exists then
        local f = io.open("/usr/lib/qos_gargoyle/acc_conf.sh", "r")
        if f then
            local content = f:read("*all")
            f:close()
            m.message = "<pre style='background: #f5f5f5; padding: 10px; border-radius: 5px; overflow: auto; max-height: 300px;'>" .. 
                       content .. "</pre>"
        else
            m.message = translate("无法读取脚本文件")
        end
    else
        m.message = translate("配置生成脚本不存在")
    end
end

return m