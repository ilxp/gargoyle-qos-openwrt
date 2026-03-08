-- Licensed to the public under the Apache License 2.0.
-- Copyright 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local nixio = require "nixio"

local m, s, o

-- 检查qosdba是否安装
local qosdba_installed = fs.access("/usr/sbin/qosdba")

-- 检查dba_conf.sh是否存在
local dba_conf_installed = fs.access("/usr/lib/qos_gargoyle/dba_conf.sh")

-- 获取当前QoS算法
local function get_current_algorithm()
    local algo = uci:get("qos_gargoyle", "global", "qos_algorithm")
    if not algo or algo == "" then
        -- 默认使用htb
        algo = "htb"
    end
    return algo
end

-- 获取DBA服务状态
local function get_dba_status()
    local status = {
        enabled = false,
        running = false,
        pid = nil,
        config_exists = false
    }
    
    -- 检查qosdba是否真的存在
    if not qosdba_installed then
        return status
    end
    
    -- 检查DBA服务是否启用
    local enabled = uci:get("qos_gargoyle", "dba", "enabled")
    if enabled == "1" then
        status.enabled = true
    end
    
    -- 检查配置文件是否存在
    if fs.access("/etc/qosdba.conf") then
        status.config_exists = true
    end
    
    -- 检查进程是否运行
    local pid = sys.exec("pidof qosdba 2>/dev/null")
    if pid and pid:match("^%s*(%d+)%s*$") then
        local pid_num = tonumber(pid:match("^%s*(%d+)%s*$"))
        if pid_num then
            status.running = true
            status.pid = pid_num
        end
    end
    
    return status
end

-- 解析带宽字符串
local function parse_bandwidth(value)
    if not value or value == "" then return 0 end
    
    local num = tonumber(value)
    if not num then
        -- 尝试提取数字
        num = tonumber(value:match("(%d+)")) or 0
    end
    
    return num
end

-- 格式化带宽显示
local function format_bandwidth(kbps)
    if not kbps or kbps == 0 then return "0" end
    if kbps >= 1000 then
        return string.format("%.1f Mbps", kbps / 1000)
    else
        return string.format("%d Kbps", kbps)
    end
end

-- 获取总带宽
local function get_total_bandwidth()
    local upload_bandwidth = uci:get("qos_gargoyle", "upload", "total_bandwidth")
    local download_bandwidth = uci:get("qos_gargoyle", "download", "total_bandwidth")
    
    -- 从配置中读取，单位是kbps
    local up_kbps = parse_bandwidth(upload_bandwidth) or 40000
    local down_kbps = parse_bandwidth(download_bandwidth) or 95000
    
    return {
        upload = up_kbps,
        download = down_kbps,
        upload_str = format_bandwidth(up_kbps),
        download_str = format_bandwidth(down_kbps)
    }
end

-- 创建Map
m = Map("qos_gargoyle", translate("QoS 动态带宽分配 (DBA)"), 
    translate("动态调整QoS分类的带宽分配，根据实际使用情况自动调整带宽，优化网络体验。"))

-- 确保dba配置存在
local dba_config = uci:get_all("qos_gargoyle", "dba")
if not dba_config then
    uci:set("qos_gargoyle", "dba", "dba")
    uci:set("qos_gargoyle", "dba", "enabled", "0")
    uci:set("qos_gargoyle", "dba", "interval", "5")
    uci:set("qos_gargoyle", "dba", "high_usage_threshold", "85")
    uci:set("qos_gargoyle", "dba", "high_usage_duration", "5")
    uci:set("qos_gargoyle", "dba", "low_usage_threshold", "40")
    uci:set("qos_gargoyle", "dba", "low_usage_duration", "5")
    uci:set("qos_gargoyle", "dba", "borrow_ratio", "0.2")
    uci:set("qos_gargoyle", "dba", "min_borrow_kbps", "128")
    uci:set("qos_gargoyle", "dba", "min_change_kbps", "128")
    uci:set("qos_gargoyle", "dba", "cooldown_time", "8")
    uci:set("qos_gargoyle", "dba", "auto_return_enable", "1")
    uci:set("qos_gargoyle", "dba", "return_threshold", "50")
    uci:set("qos_gargoyle", "dba", "return_speed", "0.1")
    uci:commit("qos_gargoyle")
end

-- 状态显示
local dba_status = get_dba_status()
local total_bw = get_total_bandwidth()

s = m:section(SimpleSection, nil, translate("DBA 服务状态"))
s.anonymous = true

-- DBA服务状态
local status_dv = s:option(DummyValue, "_dba_status", translate("DBA 服务状态"))
status_dv.rawhtml = true

if qosdba_installed then
    if dba_status.running then
        status_dv.value = string.format('<span style="color: green; font-weight: bold;">运行中 (PID: %d)</span>', dba_status.pid or 0)
    elseif dba_status.enabled then
        status_dv.value = '<span style="color: orange; font-weight: bold;">已启用但未运行</span>'
    else
        status_dv.value = '<span style="color: red; font-weight: bold;">已禁用</span>'
    end
else
    status_dv.value = '<span style="color: red; font-weight: bold;">qosdba 未安装</span>'
end

-- 配置文件状态
local config_dv = s:option(DummyValue, "_config_status", translate("配置文件状态"))
config_dv.rawhtml = true
if dba_status.config_exists then
    config_dv.value = '<span style="color: green;">✓ 配置文件存在</span>'
else
    config_dv.value = '<span style="color: orange;">⚠ 配置文件不存在</span>'
end

-- 总带宽
local total_bw_dv = s:option(DummyValue, "_total_bw", translate("总带宽"))
total_bw_dv.value = string.format("上传: %s, 下载: %s", 
    total_bw.upload_str, total_bw.download_str)

-- 当前算法
local algo = get_current_algorithm()
local algo_dv = s:option(DummyValue, "_algorithm", translate("当前算法"))
algo_dv.value = string.upper(algo)

-- 服务控制按钮
local ctl_btn = s:option(Button, "_control", translate("服务控制"))
ctl_btn.inputtitle = translate("立即控制")
ctl_btn.inputstyle = "apply"

function ctl_btn.write(self, section, value)
    if not qosdba_installed then
        m.message = translate("qosdba 未安装，请先安装qosdba")
        return
    end
    
    local enabled = uci:get("qos_gargoyle", "dba", "enabled")
    
    if enabled == "1" then
        -- 启动服务
        sys.call("/etc/init.d/qosdba start 2>&1")
        m.message = translate("qosdba 服务已启动")
    else
        -- 停止服务
        sys.call("/etc/init.d/qosdba stop 2>&1")
        m.message = translate("qosdba 服务已停止")
    end
end

-- 生成配置按钮
if dba_conf_installed then
    local gen_btn = s:option(Button, "_generate", translate("配置生成"))
    gen_btn.inputtitle = translate("重新生成配置")
    gen_btn.inputstyle = "apply"
    
    function gen_btn.write(self, section, value)
        -- 获取当前算法
        local current_algo = get_current_algorithm()
        
        -- 生成配置
        local cmd = string.format("/usr/lib/qos_gargoyle/dba_conf.sh quick-generate %s", current_algo)
        local result = sys.call(cmd)
        
        if result == 0 then
            m.message = translate("配置生成成功")
        else
            m.message = translate("配置生成失败，请检查日志")
        end
    end
end

-- 基本设置
s = m:section(TypedSection, "dba", translate("基本设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用动态带宽分配"),
    translate("启用后，系统会根据网络使用情况动态调整各分类的带宽分配。"))
o.default = "0"

o = s:option(Value, "interval", translate("检查间隔（秒）"), 
    translate("检查带宽使用情况的间隔时间。"))
o.datatype = "uinteger"
o.default = "5"
o:depends("enabled", "1")

o = s:option(Value, "high_usage_threshold", translate("高使用阈值（%）"), 
    translate("当分类使用率达到此百分比时，被认为是高使用状态。"))
o.datatype = "range(0,100)"
o.default = "85"
o:depends("enabled", "1")

o = s:option(Value, "high_usage_duration", translate("高使用持续时间（秒）"), 
    translate("维持高使用状态多少秒后触发带宽调整。"))
o.datatype = "uinteger"
o.default = "5"
o:depends("enabled", "1")

o = s:option(Value, "low_usage_threshold", translate("低使用阈值（%）"), 
    translate("当分类使用率低于此百分比时，被认为是低使用状态。"))
o.datatype = "range(0,100)"
o.default = "40"
o:depends("enabled", "1")

o = s:option(Value, "low_usage_duration", translate("低使用持续时间（秒）"), 
    translate("维持低使用状态多少秒后触发带宽调整。"))
o.datatype = "uinteger"
o.default = "5"
o:depends("enabled", "1")

o = s:option(Value, "borrow_ratio", translate("借用比例"), 
    translate("从低使用分类借用的带宽比例（0.0-1.0）。"))
o.datatype = "float"
o.default = "0.2"
o:depends("enabled", "1")

o = s:option(Value, "min_borrow_kbps", translate("最小借用带宽（Kbps）"), 
    translate("每次调整的最小带宽。"))
o.datatype = "uinteger"
o.default = "128"
o:depends("enabled", "1")

o = s:option(Value, "min_change_kbps", translate("最小调整带宽（Kbps）"), 
    translate("带宽调整的最小变化量。"))
o.datatype = "uinteger"
o.default = "128"
o:depends("enabled", "1")

o = s:option(Value, "cooldown_time", translate("冷却时间（秒）"), 
    translate("两次调整之间的最小间隔时间。"))
o.datatype = "uinteger"
o.default = "8"
o:depends("enabled", "1")

-- 自动归还设置
s = m:section(TypedSection, "dba", translate("自动归还设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "auto_return_enable", translate("启用自动归还"),
    translate("当分类使用率降低时，自动归还借用的带宽。"))
o.default = "1"
o:depends("enabled", "1")

o = s:option(Value, "return_threshold", translate("归还阈值（%）"),
    translate("当分类使用率低于此百分比时，开始归还带宽。"))
o.datatype = "range(0,100)"
o.default = "50"
o:depends({"enabled", "auto_return_enable"}, {"1", "1"})

o = s:option(Value, "return_speed", translate("归还速度"),
    translate("每次调整归还的带宽比例（0.0-1.0）。"))
o.datatype = "float"
o.default = "0.1"
o:depends({"enabled", "auto_return_enable"}, {"1", "1"})

-- 高级设置
s = m:section(TypedSection, "dba", translate("高级设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "debug_mode", translate("调试模式"),
    translate("启用调试模式，输出详细日志。"))
o.default = "0"
o:depends("enabled", "1")

o = s:option(Flag, "safe_mode", translate("安全模式"),
    translate("安全模式下不实际修改TC配置，只记录操作。"))
o.default = "0"
o:depends("enabled", "1")

o = s:option(Value, "cache_interval", translate("缓存间隔（秒）"),
    translate("TC统计信息缓存时间。"))
o.datatype = "uinteger"
o.default = "5"
o:depends("enabled", "1")

-- 安装提示
if not qosdba_installed then
    s = m:section(SimpleSection, nil, translate("安装提示"))
    s.anonymous = true
    
    local install_html = [[
    <div style="margin: 20px 0; padding: 15px; background-color: #f9f9f9; border: 1px solid #e0e0e0; border-radius: 5px;">
    <h4 style="margin-top: 0; color: #d32f2f;">qosdba 未安装</h4>
    <p style="margin-bottom: 10px;">要启用动态带宽分配功能，请先安装 qosdba 服务。</p>
    <p style="font-family: monospace; background-color: #f5f5f5; padding: 10px; border-radius: 3px; color: #333;">
    opkg update && opkg install qosdba
    </p>
    <p style="font-size: 12px; color: #666; margin-top: 10px;">安装完成后，重新加载此页面即可配置和使用DBA功能。</p>
    </div>
    ]]
    
    local install_opt = s:option(DummyValue, "_install")
    install_opt.rawhtml = true
    install_opt.value = install_html
end

-- 保存配置的处理
function m.on_after_apply(self)
    -- 保存qos_gargoyle配置
    uci:save("qos_gargoyle")
    uci:commit("qos_gargoyle")
    
    -- 获取DBA配置
    local dba_enabled = uci:get("qos_gargoyle", "dba", "enabled")
    
    if qosdba_installed then
        if dba_enabled == "1" then
            -- 启用DBA功能
            
            -- 1. 生成qosdba配置文件
            if dba_conf_installed then
                local current_algo = get_current_algorithm()
                local cmd = string.format("/usr/lib/qos_gargoyle/dba_conf.sh quick-generate %s", current_algo)
                sys.call(cmd)
            else
                -- 如果dba_conf.sh不存在，生成基本的qosdba.conf
                local dba_opts = uci:get_all("qos_gargoyle", "dba") or {}
                
                -- 创建基本配置文件
                local conf_content = [[# qosdba配置
# 自动生成

[global]
enabled=1
debug_mode=]] .. (dba_opts.debug_mode or "0") .. [[
safe_mode=]] .. (dba_opts.safe_mode or "0") .. [[
interval=]] .. (dba_opts.interval or "5") .. [[
config_path=/etc/qosdba.conf
status_file=/tmp/qosdba.status
log_file=/var/log/qosdba.log

[device=ifb0]
enabled=1
total_bandwidth_kbps=]] .. (total_bw.download or 95000) .. [[
high_util_threshold=]] .. (dba_opts.high_usage_threshold or "85") .. [[
high_util_duration=]] .. (dba_opts.high_usage_duration or "5") .. [[
low_util_threshold=]] .. (dba_opts.low_usage_threshold or "40") .. [[
low_util_duration=]] .. (dba_opts.low_usage_duration or "5") .. [[
borrow_ratio=]] .. (dba_opts.borrow_ratio or "0.2") .. [[
min_borrow_kbps=]] .. (dba_opts.min_borrow_kbps or "128") .. [[
min_change_kbps=]] .. (dba_opts.min_change_kbps or "128") .. [[
cooldown_time=]] .. (dba_opts.cooldown_time or "8") .. [[
auto_return_enable=]] .. (dba_opts.auto_return_enable or "1") .. [[
return_threshold=]] .. (dba_opts.return_threshold or "50") .. [[
return_speed=]] .. (dba_opts.return_speed or "0.1") .. [[
cache_interval=]] .. (dba_opts.cache_interval or "5")
                
                -- 写入配置文件
                local file = io.open("/etc/qosdba.conf", "w")
                if file then
                    file:write(conf_content)
                    file:close()
                end
            end
            
            -- 2. 启用并启动qosdba服务
            sys.call("/etc/init.d/qosdba enable 2>/dev/null")
            sys.call("/etc/init.d/qosdba restart 2>&1")
            
            -- 3. 记录日志
            sys.call("logger -t 'qos_gargoyle' 'DBA已启用并启动'")
        else
            -- 禁用DBA功能
            sys.call("/etc/init.d/qosdba stop 2>&1")
            sys.call("/etc/init.d/qosdba disable 2>/dev/null")
            sys.call("logger -t 'qos_gargoyle' 'DBA已禁用'")
        end
    else
        m.message = translate("qosdba 未安装，请先安装 qosdba 包")
    end
end

-- 处理动作请求
local action = luci.http.formvalue("action")
if action then
    if action == "install" then
        m.message = translate("请通过SSH运行: opkg update && opkg install qosdba")
    end
end

return m