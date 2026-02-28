-- QoS 动态带宽分配 (DBA) 配置页面
-- 适用于Gargoyle/OpenWrt的Luci界面

local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local nixio = require "nixio"

local m, s, o

-- 检查qosdba是否安装
local qosdba_installed = fs.access("/usr/sbin/qosdba") and fs.access("/etc/config/qosdba")

-- 获取DBA服务状态
local function get_dba_status()
    local status = {
        enabled = false,
        running = false,
        pid = nil
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
        return string.format("%.1fM", kbps / 1000)
    else
        return string.format("%dK", kbps)
    end
end

-- 获取总带宽
local function get_total_bandwidth()
    local upload_bandwidth = uci:get("qos_gargoyle", "upload", "total_bandwidth")
    local download_bandwidth = uci:get("qos_gargoyle", "download", "total_bandwidth")
    
    -- 从配置中读取，单位是kbps
    local up_kbps = parse_bandwidth(upload_bandwidth) or 50000
    local down_kbps = parse_bandwidth(download_bandwidth) or 100000
    
    return {
        upload = up_kbps,
        download = down_kbps,
        upload_str = format_bandwidth(up_kbps),
        download_str = format_bandwidth(down_kbps)
    }
end

-- 从qos_gargoyle配置中读取分类
local function get_classes(direction)
    local classes = {}
    
    -- 遍历所有分类
    uci:foreach("qos_gargoyle", direction .. "_class", function(section)
        local class_name = section[".name"]
        if class_name then
            local class_data = uci:get_all("qos_gargoyle", class_name) or {}
            
            local class = {
                name = class_name,
                display_name = class_data.name or class_name:gsub("^[ud]class_", ""),
                percent = tonumber(class_data.percent_bandwidth) or 0
            }
            
            table.insert(classes, class)
        end
    end)
    
    return classes
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
    uci:set("qos_gargoyle", "dba", "low_usage_threshold", "30")
    uci:set("qos_gargoyle", "dba", "low_usage_duration", "10")
    uci:set("qos_gargoyle", "dba", "borrow_ratio", "0.5")
    uci:set("qos_gargoyle", "dba", "min_borrow_kbps", "64")
    uci:set("qos_gargoyle", "dba", "min_change_kbps", "32")
    uci:set("qos_gargoyle", "dba", "cooldown_time", "10")
    uci:set("qos_gargoyle", "dba", "auto_return_enable", "1")
    uci:set("qos_gargoyle", "dba", "return_threshold", "60")
    uci:set("qos_gargoyle", "dba", "return_speed", "0.1")
    uci:commit("qos_gargoyle")
end

-- 状态显示 - 放在最前面
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

-- 总带宽
local total_bw_dv = s:option(DummyValue, "_total_bw", translate("总带宽"))
total_bw_dv.value = string.format("上传: %s, 下载: %s", 
    total_bw.upload_str, total_bw.download_str)

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

o = s:option(Value, "high_usage_threshold", translate("高使用阈值（%）"), 
    translate("当分类使用率达到此百分比时，被认为是高使用状态。"))
o.datatype = "range(0,100)"
o.default = "85"

o = s:option(Value, "high_usage_duration", translate("高使用持续时间（秒）"), 
    translate("维持高使用状态多少秒后触发带宽调整。"))
o.datatype = "uinteger"
o.default = "5"

o = s:option(Value, "low_usage_threshold", translate("低使用阈值（%）"), 
    translate("当分类使用率低于此百分比时，被认为是低使用状态。"))
o.datatype = "range(0,100)"
o.default = "30"

o = s:option(Value, "low_usage_duration", translate("低使用持续时间（秒）"), 
    translate("维持低使用状态多少秒后触发带宽调整。"))
o.datatype = "uinteger"
o.default = "10"

o = s:option(Value, "borrow_ratio", translate("借用比例"), 
    translate("从低使用分类借用的带宽比例（0.0-1.0）。"))
o.datatype = "float"
o.default = "0.5"

o = s:option(Value, "min_borrow_kbps", translate("最小借用带宽（kbps）"), 
    translate("每次调整的最小带宽。"))
o.datatype = "uinteger"
o.default = "64"

o = s:option(Value, "min_change_kbps", translate("最小调整带宽（kbps）"), 
    translate("带宽调整的最小变化量。"))
o.datatype = "uinteger"
o.default = "32"

o = s:option(Value, "cooldown_time", translate("冷却时间（秒）"), 
    translate("两次调整之间的最小间隔时间。"))
o.datatype = "uinteger"
o.default = "10"

-- 自动归还设置
s = m:section(TypedSection, "dba", translate("自动归还设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "auto_return_enable", translate("启用自动归还"),
    translate("当分类使用率降低时，自动归还借用的带宽。"))
o.default = "1"

o = s:option(Value, "return_threshold", translate("归还阈值（%）"),
    translate("当分类使用率低于此百分比时，开始归还带宽。"))
o.datatype = "range(0,100)"
o.default = "60"

o = s:option(Value, "return_speed", translate("归还速度"),
    translate("每次调整归还的带宽比例（0.0-1.0）。"))
o.datatype = "float"
o.default = "0.1"

-- 添加上传分类状态
local upload_classes = get_classes("upload")
if upload_classes and #upload_classes > 0 then
    s = m:section(SimpleSection, nil, translate("上传分类状态"))
    s.anonymous = true
    
    local html = [[
    <table class="table" style="width: 100%; text-align: left; border-collapse: collapse; border: 1px solid #ddd;">
    <thead>
    <tr style="background-color: #f5f5f5;">
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">分类名称</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">配置比例</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">使用率</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">实时带宽</th>
    </tr>
    </thead>
    <tbody>
    ]]
    
    for _, class in ipairs(upload_classes) do
        html = html .. string.format([[
    <tr>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left;">%s</td>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left;">%d%%</td>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left; color: gray;">%s</td>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left; color: gray;">%s</td>
    </tr>
    ]], 
        class.display_name or class.name,
        class.percent or 0,
        "--",  -- 使用率，暂不显示
        "--")  -- 实时带宽，暂不显示
    end
    
    html = html .. "</tbody></table>"
    
    local note_html = [[
    <div style="margin-top: 10px; padding: 10px; background-color: #f0f0f0; border: 1px solid #ccc; border-radius: 3px;">
    <p style="color: #666; font-size: 12px; margin: 0;">
    注：使用率和实时带宽需要安装并启动 qosdba 服务后才会显示实时数据。
    </p>
    </div>
    ]]
    
    local upload_table = s:option(DummyValue, "_upload_table")
    upload_table.rawhtml = true
    upload_table.value = html .. note_html
end

-- 添加下载分类状态
local download_classes = get_classes("download")
if download_classes and #download_classes > 0 then
    s = m:section(SimpleSection, nil, translate("下载分类状态"))
    s.anonymous = true
    
    local html = [[
    <table class="table" style="width: 100%; text-align: left; border-collapse: collapse; border: 1px solid #ddd;">
    <thead>
    <tr style="background-color: #f5f5f5;">
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">分类名称</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">配置比例</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">使用率</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: left; width: 25%">实时带宽</th>
    </tr>
    </thead>
    <tbody>
    ]]
    
    for _, class in ipairs(download_classes) do
        html = html .. string.format([[
    <tr>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left;">%s</td>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left;">%d%%</td>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left; color: gray;">%s</td>
        <td style="padding: 8px; border: 1px solid #ddd; text-align: left; color: gray;">%s</td>
    </tr>
    ]], 
        class.display_name or class.name,
        class.percent or 0,
        "--",  -- 使用率，暂不显示
        "--")  -- 实时带宽，暂不显示
    end
    
    html = html .. "</tbody></table>"
    
    local note_html = [[
    <div style="margin-top: 10px; padding: 10px; background-color: #f0f0f0; border: 1px solid #ccc; border-radius: 3px;">
    <p style="color: #666; font-size: 12px; margin: 0;">
    注：使用率和实时带宽需要安装并启动 qosdba 服务后才会显示实时数据。
    </p>
    </div>
    ]]
    
    local download_table = s:option(DummyValue, "_download_table")
    download_table.rawhtml = true
    download_table.value = html .. note_html
end

-- 处理动作请求
local action = luci.http.formvalue("action")
if action then
    if action == "install" then
        m.message = translate("请通过SSH运行: opkg update && opkg install qosdba")
    end
end

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
    
    -- 同步配置到qosdba
    local enabled = uci:get("qos_gargoyle", "dba", "enabled")
    
    if qosdba_installed and enabled == "1" then
        -- 复制配置
        local dba_opts = uci:get_all("qos_gargoyle", "dba") or {}
        
        -- 确保qosdba配置存在
        if not uci:get("qosdba", "dba") then
            uci:set("qosdba", "dba", "dba")
        end
        
        for k, v in pairs(dba_opts) do
            if k ~= ".name" and k ~= ".type" then
                uci:set("qosdba", "dba", k, v)
            end
        end
        
        uci:save("qosdba")
        uci:commit("qosdba")
        
        -- 启用并启动服务
        sys.call("/etc/init.d/qosdba enable 2>/dev/null")
        sys.call("/etc/init.d/qosdba restart 2>&1")
    elseif qosdba_installed then
        sys.call("/etc/init.d/qosdba stop 2>&1")
        sys.call("/etc/init.d/qosdba disable 2>/dev/null")
    end
end

return m