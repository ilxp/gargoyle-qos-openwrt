-- QoS 动态带宽分配 (DBA) 配置页面
-- 适用于Gargoyle/OpenWrt的Luci界面

local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci".cursor()
local json = require "luci.jsonc"

local m, s, o

-- 检查qosdba是否安装
local qosdba_installed = fs.access("/usr/sbin/qosdba")

-- 获取DBA服务状态
local function get_dba_status()
    local status = {
        enabled = false,
        running = false,
        pid = nil,
        upload_classes = {},
        download_classes = {}
    }
    
    -- 检查配置文件
    if uci:get_first("qos_gargoyle", "dba", "enabled") == "1" then
        status.enabled = true
    end
    
    -- 检查进程是否运行
    local pid = sys.exec("pgrep -f qosdba 2>/dev/null | head -1")
    if pid and #pid > 0 then
        status.running = true
        status.pid = tonumber(pid:match("^%s*(.-)%s*$"))
    end
    
    -- 从状态文件读取实时带宽
    local status_file = "/var/run/qosdba.status"
    if fs.access(status_file) then
        local content = fs.readfile(status_file)
        if content then
            local ok, data = pcall(json.parse, content)
            if ok and data then
                status.upload_classes = data.upload_classes or {}
                status.download_classes = data.download_classes or {}
            end
        end
    end
    
    return status
end

-- 解析带宽字符串
local function parse_bandwidth(str)
    if not str then return 0 end
    str = tostring(str)
    
    local num = str:match("^(%d+)")
    if not num then return 0 end
    
    num = tonumber(num)
    local unit = str:match("%D+$")
    
    if unit then
        unit = unit:lower()
        if unit:find("g") then
            return num * 1000000
        elseif unit:find("m") then
            return num * 1000
        elseif unit:find("k") then
            return num
        end
    end
    
    return num
end

-- 格式化带宽显示
local function format_bandwidth(kbps)
    if kbps >= 1000000 then
        return string.format("%.1f G", kbps / 1000000)
    elseif kbps >= 1000 then
        return string.format("%.1f M", kbps / 1000)
    else
        return string.format("%d k", kbps)
    end
end

-- 获取总带宽
local function get_total_bandwidth()
    local upload = uci:get_first("qos_gargoyle", "upload", "bandwidth")
    local download = uci:get_first("qos_gargoyle", "download", "bandwidth")
    
    if upload and download then
        local up_kbps = parse_bandwidth(upload)
        local down_kbps = parse_bandwidth(download)
        return {
            upload = up_kbps,
            download = down_kbps,
            upload_str = upload,
            download_str = download
        }
    end
    
    -- 默认100M
    return {
        upload = 100000,
        download = 100000,
        upload_str = "100M",
        download_str = "100M"
    }
end

-- 获取分类配置
local function get_classes(direction)
    local classes = {}
    local prefix = direction .. "_class"
    
    uci:foreach("qos_gargoyle", prefix, function(section)
        local class = {
            name = section[".name"],
            display_name = section.name or section[".name"],
            classid = section.classid or "",
            percent = tonumber(section.percent) or 0,
            min_kbps = tonumber(section.min) or 0,
            max_kbps = tonumber(section.max) or 0,
            priority = tonumber(section.priority) or 0,
            rtt = section.rtt or "0"
        }
        
        -- 计算带宽
        local total_bw = get_total_bandwidth()
        local total_kbps = direction == "upload" and total_bw.upload or total_bw.download
        class.calc_kbps = math.floor(total_kbps * class.percent / 100)
        
        -- 设置默认最小/最大
        if class.min_kbps == 0 then
            class.min_kbps = math.floor(class.calc_kbps * 0.5)
        end
        if class.max_kbps == 0 then
            class.max_kbps = math.floor(class.calc_kbps * 2)
        end
        
        table.insert(classes, class)
    end)
    
    -- 按优先级排序
    table.sort(classes, function(a, b)
        return a.priority < b.priority
    end)
    
    return classes
end

-- 创建Map
m = Map("qos_gargoyle", translate("QoS 动态带宽分配 (DBA)"), 
    translate("动态调整QoS分类的带宽分配，根据实际使用情况自动调整带宽，优化网络体验。"))

-- 基本设置
s = m:section(TypedSection, "dba", translate("基本设置"))
s.anonymous = true
s.addremove = false

-- 启用DBA
o = s:option(Flag, "enabled", translate("启用动态带宽分配"),
    translate("启用后，系统会根据网络使用情况动态调整各分类的带宽分配。"))
o.default = "0"
o.rmempty = false

-- 检查间隔
o = s:option(Value, "interval", translate("检查间隔"), 
    translate("检查带宽使用情况的间隔时间（秒）。"))
o.datatype = "uinteger"
o.default = "5"
o.rmempty = false

-- 高使用阈值
o = s:option(Value, "high_usage_threshold", translate("高使用阈值"), 
    translate("当分类使用率达到此百分比时，被认为是高使用状态（0-100）。"))
o.datatype = "range(0,100)"
o.default = "85"
o.rmempty = false

-- 高使用持续时间
o = s:option(Value, "high_usage_duration", translate("高使用持续时间"), 
    translate("维持高使用状态多少秒后触发带宽调整。"))
o.datatype = "uinteger"
o.default = "5"
o.rmempty = false

-- 低使用阈值
o = s:option(Value, "low_usage_threshold", translate("低使用阈值"), 
    translate("当分类使用率低于此百分比时，被认为是低使用状态（0-100）。"))
o.datatype = "range(0,100)"
o.default = "30"
o.rmempty = false

-- 低使用持续时间
o = s:option(Value, "low_usage_duration", translate("低使用持续时间"), 
    translate("维持低使用状态多少秒后触发带宽调整。"))
o.datatype = "uinteger"
o.default = "10"
o.rmempty = false

-- 借用比例
o = s:option(Value, "borrow_ratio", translate("借用比例"), 
    translate("从低使用分类借用的带宽比例（0.0-1.0）。"))
o.datatype = "float"
o.default = "0.5"
o.rmempty = false

-- 最小借用带宽
o = s:option(Value, "min_borrow_kbps", translate("最小借用带宽"), 
    translate("每次调整的最小带宽（kbps）。"))
o.datatype = "uinteger"
o.default = "64"
o.rmempty = false

-- 最小调整带宽
o = s:option(Value, "min_change_kbps", translate("最小调整带宽"), 
    translate("带宽调整的最小变化量（kbps）。"))
o.datatype = "uinteger"
o.default = "32"
o.rmempty = false

-- 冷却时间
o = s:option(Value, "cooldown_time", translate("冷却时间"), 
    translate("两次调整之间的最小间隔时间（秒）。"))
o.datatype = "uinteger"
o.default = "10"
o.rmempty = false

-- 自动归还设置
s:tab("auto_return", translate("自动归还"))

o = s:taboption("auto_return", Flag, "auto_return_enable", 
    translate("启用自动归还"),
    translate("当分类使用率降低时，自动归还借用的带宽。"))
o.default = "1"

o = s:taboption("auto_return", Value, "return_threshold", 
    translate("归还阈值"),
    translate("当分类使用率低于此百分比时，开始归还带宽（0-100）。"))
o.datatype = "range(0,100)"
o.default = "50"
o:depends("auto_return_enable", "1")

o = s:taboption("auto_return", Value, "return_speed", 
    translate("归还速度"),
    translate("每次调整归还的带宽比例（0.0-1.0）。"))
o.datatype = "float"
o.default = "0.1"
o:depends("auto_return_enable", "1")

-- 状态显示
s = m:section(TypedSection, "dba_status", translate("DBA 状态"))
s.anonymous = true
s.addremove = false

-- 获取当前状态
local dba_status = get_dba_status()
local total_bw = get_total_bandwidth()

-- 状态行
o = s:option(DummyValue, "_status", translate("当前状态"))
if dba_status.running then
    o.value = translatef("<span style='color: green; font-weight: bold;'>● 运行中 (PID: %d)</span>", dba_status.pid or 0)
elseif dba_status.enabled then
    o.value = translate("<span style='color: orange; font-weight: bold;'>● 已启用但未运行</span>")
else
    o.value = translate("<span style='color: red; font-weight: bold;'>● 已禁用</span>")
end

-- 总带宽显示
o = s:option(DummyValue, "_total_bw", translate("总带宽"))
o.value = translatef("上传: %s, 下载: %s", 
    total_bw.upload_str, total_bw.download_str)

-- 创建表格显示上传分类
s = m:section(Table, {}, translate("上传分类状态"))
s.anonymous = true
s.template = "admin_status"
s.width = "100%"

-- 表头
s:option(DummyValue, "class_name", translate("分类名称"))
s:option(DummyValue, "class_id", translate("TC ClassID"))
s:option(DummyValue, "config_percent", translate("配置比例"))
s:option(DummyValue, "min_bw", translate("最小带宽"))
s:option(DummyValue, "max_bw", translate("最大带宽"))
s:option(DummyValue, "current_bw", translate("当前带宽"))
s:option(DummyValue, "used_bw", translate("使用带宽"))
s:option(DummyValue, "usage_rate", translate("使用率"))
s:option(DummyValue, "status", translate("状态"))
s:option(DummyValue, "borrowed", translate("借用"))

-- 添加上传分类数据
local upload_classes = get_classes("upload")
local upload_status = dba_status.upload_classes

for _, class in ipairs(upload_classes) do
    local status_info = upload_status[class.name] or {}
    local current_kbps = status_info.current or class.calc_kbps
    local used_kbps = status_info.used or 0
    local usage_rate = used_kbps / current_kbps
    local status_text = status_info.status or "normal"
    local borrowed = status_info.borrowed or 0
    
    local status_display
    if status_text == "high" then
        status_display = translate("<span style='color: red;'>高负荷</span>")
    elseif status_text == "low" then
        status_display = translate("<span style='color: blue;'>低负荷</span>")
    else
        status_display = translate("<span style='color: green;'>正常</span>")
    end
    
    local borrowed_display
    if borrowed > 0 then
        borrowed_display = string.format("<span style='color: orange;'>+%s</span>", 
            format_bandwidth(borrowed))
    elseif borrowed < 0 then
        borrowed_display = string.format("<span style='color: green;'>%s</span>", 
            format_bandwidth(borrowed))
    else
        borrowed_display = "0"
    end
    
    s:option(DummyValue, "upload_" .. class.name, class.display_name)
    .value = string.format([[
        <div style='padding: 5px; border: 1px solid #eee;'>
            <div>%s</div>
            <div><small>%s</small></div>
            <div><small>%d%%</small></div>
            <div><small>%s</small></div>
            <div><small>%s</small></div>
            <div><strong>%s</strong></div>
            <div>%s</div>
            <div>%.1f%%</div>
            <div>%s</div>
            <div>%s</div>
        </div>
    ]], 
    class.display_name,
    class.classid,
    class.percent,
    format_bandwidth(class.min_kbps),
    format_bandwidth(class.max_kbps),
    format_bandwidth(current_kbps),
    format_bandwidth(used_kbps),
    usage_rate * 100,
    status_display,
    borrowed_display)
end

-- 创建表格显示下载分类
s = m:section(Table, {}, translate("下载分类状态"))
s.anonymous = true
s.template = "admin_status"
s.width = "100%"

-- 表头
s:option(DummyValue, "class_name", translate("分类名称"))
s:option(DummyValue, "class_id", translate("TC ClassID"))
s:option(DummyValue, "config_percent", translate("配置比例"))
s:option(DummyValue, "min_bw", translate("最小带宽"))
s:option(DummyValue, "max_bw", translate("最大带宽"))
s:option(DummyValue, "current_bw", translate("当前带宽"))
s:option(DummyValue, "used_bw", translate("使用带宽"))
s:option(DummyValue, "usage_rate", translate("使用率"))
s:option(DummyValue, "status", translate("状态"))
s:option(DummyValue, "borrowed", translate("借用"))

-- 添加下载分类数据
local download_classes = get_classes("download")
local download_status = dba_status.download_classes

for _, class in ipairs(download_classes) do
    local status_info = download_status[class.name] or {}
    local current_kbps = status_info.current or class.calc_kbps
    local used_kbps = status_info.used or 0
    local usage_rate = used_kbps / current_kbps
    local status_text = status_info.status or "normal"
    local borrowed = status_info.borrowed or 0
    
    local status_display
    if status_text == "high" then
        status_display = translate("<span style='color: red;'>高负荷</span>")
    elseif status_text == "low" then
        status_display = translate("<span style='color: blue;'>低负荷</span>")
    else
        status_display = translate("<span style='color: green;'>正常</span>")
    end
    
    local borrowed_display
    if borrowed > 0 then
        borrowed_display = string.format("<span style='color: orange;'>+%s</span>", 
            format_bandwidth(borrowed))
    elseif borrowed < 0 then
        borrowed_display = string.format("<span style='color: green;'>%s</span>", 
            format_bandwidth(borrowed))
    else
        borrowed_display = "0"
    end
    
    s:option(DummyValue, "download_" .. class.name, class.display_name)
    .value = string.format([[
        <div style='padding: 5px; border: 1px solid #eee;'>
            <div>%s</div>
            <div><small>%s</small></div>
            <div><small>%d%%</small></div>
            <div><small>%s</small></div>
            <div><small>%s</small></div>
            <div><strong>%s</strong></div>
            <div>%s</div>
            <div>%.1f%%</div>
            <div>%s</div>
            <div>%s</div>
        </div>
    ]], 
    class.display_name,
    class.classid,
    class.percent,
    format_bandwidth(class.min_kbps),
    format_bandwidth(class.max_kbps),
    format_bandwidth(current_kbps),
    format_bandwidth(used_kbps),
    usage_rate * 100,
    status_display,
    borrowed_display)
end

-- 服务控制
s = m:section(TypedSection, "service_control", translate("服务控制"))
s.anonymous = true
s.addremove = false

-- 控制按钮
o = s:option(Button, "_start", translate("启动服务"))
o.inputstyle = "apply"
o.write = function()
    if not qosdba_installed then
        m.message = translate("错误: qosdba 未安装")
        return
    end
    
    local result = sys.exec("/etc/init.d/qosdba start 2>&1")
    if result:find("started") or result:find("already running") then
        m.message = translate("DBA服务已启动")
    else
        m.message = translatef("启动失败: %s", result)
    end
    
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_dba"))
end

o = s:option(Button, "_stop", translate("停止服务"))
o.inputstyle = "reset"
o.write = function()
    if not qosdba_installed then
        m.message = translate("错误: qosdba 未安装")
        return
    end
    
    local result = sys.exec("/etc/init.d/qosdba stop 2>&1")
    if result:find("stopped") or result:find("not running") then
        m.message = translate("DBA服务已停止")
    else
        m.message = translatef("停止失败: %s", result)
    end
    
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_dba"))
end

o = s:option(Button, "_restart", translate("重启服务"))
o.inputstyle = "reload"
o.write = function()
    if not qosdba_installed then
        m.message = translate("错误: qosdba 未安装")
        return
    end
    
    local result = sys.exec("/etc/init.d/qosdba restart 2>&1")
    if result:find("restarted") or result:find("started") then
        m.message = translate("DBA服务已重启")
    else
        m.message = translatef("重启失败: %s", result)
    end
    
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_dba"))
end

o = s:option(Button, "_reload", translate("重新加载配置"))
o.inputstyle = "save"
o.write = function()
    if not qosdba_installed then
        m.message = translate("错误: qosdba 未安装")
        return
    end
    
    local result = sys.exec("/usr/sbin/qosdba -r 2>&1")
    if result:find("成功") or result:find("reload") then
        m.message = translate("配置已重新加载")
    else
        m.message = translatef("重新加载失败: %s", result)
    end
    
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_dba"))
end

o = s:option(Button, "_status", translate("刷新状态"))
o.inputstyle = "refresh"
o.write = function()
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_dba"))
end

-- 手动调整测试
s = m:section(TypedSection, "manual_adjust", translate("手动调整测试"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "_test_class", translate("测试分类"))
for _, class in ipairs(upload_classes) do
    o:value("upload_" .. class.name, "上传: " .. class.display_name)
end
for _, class in ipairs(download_classes) do
    o:value("download_" .. class.name, "下载: " .. class.display_name)
end

o = s:option(Value, "_test_bw", translate("新带宽 (kbps)"))
o.datatype = "uinteger"
o.default = "1000"

o = s:option(Button, "_test", translate("测试调整"))
o.inputstyle = "apply"
o.write = function(self, section)
    local test_class = self.map:formvalue("cbid.manual_adjust._test_class")
    local test_bw = self.map:formvalue("cbid.manual_adjust._test_bw")
    
    if not test_class or not test_bw then
        m.message = translate("请选择分类和带宽")
        return
    end
    
    local bw = tonumber(test_bw)
    if not bw or bw < 1 then
        m.message = translate("请输入有效的带宽值")
        return
    end
    
    -- 执行调整
    local cmd
    if test_class:find("^upload_") then
        local class_name = test_class:gsub("^upload_", "")
        local class = nil
        for _, c in ipairs(upload_classes) do
            if c.name == class_name then
                class = c
                break
            end
        end
        
        if class and class.classid then
            cmd = string.format("tc class change dev eth0 parent 1: classid %s htb rate %dkbit ceil %dkbit 2>&1", 
                class.classid, bw, bw)
        end
    elseif test_class:find("^download_") then
        local class_name = test_class:gsub("^download_", "")
        local class = nil
        for _, c in ipairs(download_classes) do
            if c.name == class_name then
                class = c
                break
            end
        end
        
        if class and class.classid then
            cmd = string.format("tc class change dev imq0 parent 1: classid %s htb rate %dkbit ceil %dkbit 2>&1", 
                class.classid, bw, bw)
        end
    end
    
    if cmd then
        local result = sys.exec(cmd)
        if result:find("RTNETLINK") and not result:find("No such file") then
            m.message = translatef("调整成功: 设置带宽为 %d kbps", bw)
        else
            m.message = translatef("调整失败: %s", result)
        end
    else
        m.message = translate("未找到对应分类")
    end
    
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_dba"))
end

-- 显示日志
s = m:section(TypedSection, "logs", translate("系统日志"))
s.anonymous = true
s.addremove = false

o = s:option(TextValue, "_log")
o.rows = 10
o.readonly = true
o.cfgvalue = function()
    local log = sys.exec("tail -50 /var/log/qosdba.log 2>/dev/null")
    if #log == 0 then
        log = translate("暂无日志")
    end
    return log
end

o = s:option(Button, "_view_log", translate("查看完整日志"))
o.inputstyle = "view"
o.write = function()
    luci.http.redirect(luci.dispatcher.build_url("admin/system/viewfile?path=/var/log/qosdba.log"))
end

-- 安装检查
if not qosdba_installed then
    s = m:section(SimpleSection)
    s.template = "cbi/notice"
    s.notice = translate("警告: qosdba 未安装，请先安装 qosdba 软件包。")
    
    o = s:option(Button, "_install")
    o.title = translate("安装 qosdba")
    o.inputstyle = "apply"
    o.write = function()
        -- 这里可以添加安装脚本
        m.message = translate("请通过opkg安装qosdba软件包")
    end
end

-- 保存应用处理
function m.on_after_apply(self)
    -- 保存配置
    uci:save("qos_gargoyle")
    
    -- 如果启用了DBA，自动启动服务
    if uci:get_first("qos_gargoyle", "dba", "enabled") == "1" then
        sys.exec("/etc/init.d/qosdba enable")
        sys.exec("/etc/init.d/qosdba start 2>/dev/null")
    else
        sys.exec("/etc/init.d/qosdba stop 2>/dev/null")
        sys.exec("/etc/init.d/qosdba disable")
    end
end

return m