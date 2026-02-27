-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local net = require "luci.model.network".init()
local qos = require "luci.model.qos_gargoyle"
local http = require "luci.http"
local json = require "luci.jsonc"

local m, s, o
local upload_classes = {}
local download_classes = {}
local qos_gargoyle = "qos_gargoyle"

local function qos_enabled()
    local enabled = uci:get(qos_gargoyle, "global", "enabled")
    return enabled == "1"
end

uci:foreach(qos_gargoyle, "upload_class", function(s)
    local class_alias = s.name
    if class_alias then
        upload_classes[#upload_classes + 1] = {name = s[".name"], alias = class_alias}
    end
end)

uci:foreach(qos_gargoyle, "download_class", function(s)
    local class_alias = s.name
    if class_alias then
        download_classes[#download_classes + 1] = {name = s[".name"], alias = class_alias}
    end
end)

m = Map(qos_gargoyle, translate("Gargoyle QoS"),
    translate("Quality of Service (QoS) provides a way to control how available bandwidth is allocated."))

s = m:section(NamedSection, "global", "global", translate("Global Settings"))
s.anonymous = true

-- QoS 启用/禁用开关 (使用Flag替代Button)
o = s:option(Flag, "enabled", translate("Enable QoS"), translate("Enable or disable the QoS service"))
o.default = "0"
o.rmempty = false
o.enabled = "1"
o.disabled = "0"

-- 网络接口设置
o = s:option(Value, "wan_interface", translate("Network Interface"), translate("Select the network interface"))
local interfaces = sys.exec("ls -l /sys/class/net/ | grep virtual 2>/dev/null |awk '{print $9}' 2>/dev/null")
for interface in string.gmatch(interfaces, "%S+") do
   o:value(interface)
end
local wan = qos.get_wan()
if wan then o.default = wan:ifname() end
o.rmempty = false

-- QoS算法选择
o = s:option(ListValue, "algorithm", translate("QoS Algorithm"), 
    translate("HFSC for complex service curve shaping, CAKE for automated shaping, FQ_CoDel for low-latency fair queuing, and HTB for hierarchical bandwidth allocation."))
o:value("hfsc", "HFSC (Hierarchical Fair Service Curve)")
o:value("cake", "CAKE (Common Applications Kept Enhanced)")
o:value("fq_codel", "FQ_CoDel (Fair Queuing Controlled Delay)")
o:value("htb", "HTB (Hierarchical Token Bucket)")
-- o:value("hybrid", "Hybrid (CAKE +HFSCc +FQ_CoDel)")
o.default = "hfsc"

-- 链路类型
o = s:option(ListValue, "linklayer", translate("Linklayer Type"), translate("Select linkelayer type"))
o:value("ethernet", translate("Ethernet"))
o:value("atm", "ATM")
o:value("adsl", "ADSL")
o.default = "atm"

-- 链路开销
o = s:option(Value, "overhead", translate("Linklayer Overhead"), translate("Set linklayer overhead"))
o.datatype = "uinteger"
o.default="32"

s = m:section(NamedSection, "upload", "upload", translate("Upload Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifie how packets that do not match any rule should be classified."))
for _, s in ipairs(upload_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Upload Bandwidth"),
    translate("Should be set to around 98% of your available upload bandwidth. Entering a number "
    .. "which is too high will result in QoS not meeting its class requirements. Entering a number "
    .. "which is too low will needlessly penalize your upload speed. You should use a speed test "
    .. "program (with QoS off) to determine available upload bandwidth. Note that bandwidth is "
    .. "specified in kbps, leave blank to disable update QoS. There are 8 kilobits per kilobyte."))
o.datatype = "uinteger"

s = m:section(NamedSection, "download", "download", translate("Download Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifie how packets that do not match any rule should be classified."))
for _, s in ipairs(download_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Download Bandwidth"),
    translate("Specifying correctly is crucial to making QoS work. Note that bandwidth is specified "
    .. "in kbps, leave blank to disable download QoS. There are 8 kilobits per kilobyte."))
o.datatype = "uinteger"

--o = s:option(Flag, "qos_monenabled", translate("Enable Active Congestion Control"),
    --translate("<p>The active congestion control (ACC) observes your download activity and "
    --.. "automatically adjusts your download link limit to maintain proper QoS performance. ACC "
    --.. "automatically compensates for changes in your ISP's download speed and the demand from your "
    --.. "network adjusting the link speed to the highest speed possible which will maintain proper QoS "
    --.. "function. The effective range of this control is between 15% and 100% of the total download "
    --.. "bandwidth you entered above.</p>") ..
    --translate("<p>While ACC does not adjust your upload link speed you must enable and properly "
    --.. "configure your upload QoS for it to function properly.</p>")
    --)
--o.enabled  = "true"
--o.disabled = "false"

--o = s:option(Value, "ptarget_ip", translate("Use Non-standard Ping Target"),
    --translate("The segment of network between your router and the ping target is where congestion is "
    --.. "controlled. By monitoring the round trip ping times to the target congestion is detected. By "
    --.. "default ACC uses your WAN gateway as the ping target. If you know that congestion on your "
    --.. "link will occur in a different segment then you can enter an alternate ping target. Leave "
    --.. "empty to use the default settings."))
--o:depends("qos_monenabled", "true")
--local wan = qos.get_wan()
--if wan then o:value(wan:gwaddr()) end
--o.datatype = "ipaddr"

--o = s:option(Value, "pinglimit", translate("Manual Ping Limit"),
    --translate("Round trip ping times are compared against the ping limits. ACC controls the link "
    --.. "limit to maintain ping times under the appropriate limit. By default ACC attempts to "
    --.. "automatically select appropriate target ping limits for you based on the link speeds you "
    --.. "entered and the performance of your link it measures during initialization. You cannot change "
    --.. "the target ping time for the minRTT mode but by entering a manual time you can control the "
    --.. "target ping time of the active mode. The time you enter becomes the increase in the target "
    --.. "ping time between minRTT and active mode. Leave empty to use the default settings."))
--o:depends("qos_monenabled", "true")
--o:value("Auto", translate("Auto"))
--o.datatype = "or('Auto', range(10, 250))")

-- 保存配置后的服务控制函数
local function handle_service_control()
    -- 创建新的uci游标，获取最新的配置值
    local cursor = uci.cursor()
    local enabled = cursor:get(qos_gargoyle, "global", "enabled") or "0"
    
    -- 调试信息
    sys.call("logger -t qos_gargoyle_debug '服务控制函数被调用，enabled 值: " .. tostring(enabled) .. "'")
    
    if enabled == "1" then
        sys.call("logger -t qos_gargoyle '启用 QoS 服务'")
        -- 启用并启动服务
        os.execute("/etc/init.d/qos_gargoyle enable >/dev/null 2>&1")
        os.execute("/etc/init.d/qos_gargoyle start >/dev/null 2>&1")
    else
        sys.call("logger -t qos_gargoyle '禁用 QoS 服务'")
        -- 停止并禁用服务
        os.execute("/etc/init.d/qos_gargoyle stop >/dev/null 2>&1")
        os.execute("/etc/init.d/qos_gargoyle disable >/dev/null 2>&1")
    end
    
    return true
end

-- 保存配置后的服务控制函数
local function handle_service_control()
    -- 创建新的uci游标，获取最新的配置值
    local cursor = uci.cursor()
    local enabled = cursor:get(qos_gargoyle, "global", "enabled") or "0"
    
    -- 调试信息
    sys.call("logger -t qos_gargoyle_debug '服务控制函数被调用，enabled 值: " .. tostring(enabled) .. "'")
    
    if enabled == "1" then
        sys.call("logger -t qos_gargoyle '启用 QoS 服务'")
        -- 启用并启动服务
        os.execute("/etc/init.d/qos_gargoyle enable >/dev/null 2>&1")
        os.execute("/etc/init.d/qos_gargoyle start >/dev/null 2>&1")
    else
        sys.call("logger -t qos_gargoyle '禁用 QoS 服务'")
        -- 停止并禁用服务
        os.execute("/etc/init.d/qos_gargoyle stop >/dev/null 2>&1")
        os.execute("/etc/init.d/qos_gargoyle disable >/dev/null 2>&1")
    end
    
    return true
end

-- 保存配置前的钩子函数
local function before_apply(self)
    sys.call("logger -t qos_gargoyle '配置即将应用'")
    return true
end

-- 保存配置后的钩子函数
local function after_apply(self)
    sys.call("logger -t qos_gargoyle '配置已应用，正在处理服务启停'")
    
    -- 等待一小段时间，确保配置已保存
    os.execute("sleep 0.5")
    
    -- 处理服务控制
    handle_service_control()
    
    return true
end

-- 重写 Map 的 parse 方法
local parse_original = m.parse
function m.parse(self, ...)
    local result = parse_original(self, ...)
    
    -- 检查是否点击了保存/应用按钮
    local apply = luci.http.formvalue("cbi.apply")
    local save = luci.http.formvalue("cbi.cbid.qos_gargoyle.global.enabled")
    
    sys.call("logger -t qos_gargoyle_debug 'parse 函数被调用，apply: " .. tostring(apply) .. ", save: " .. tostring(save) .. "'")
    
    if apply then
        sys.call("logger -t qos_gargoyle '检测到应用按钮点击'")
        after_apply(self)
    end
    
    return result
end

-- 重写 Map 的 write 方法
local write_original = m.write
function m.write(self, section, value)
    sys.call("logger -t qos_gargoyle_debug 'write 函数被调用，section: ' .. tostring(section) .. ', value: ' .. tostring(value)")
    
    local result = write_original(self, section, value)
    
    -- 保存配置后立即提交
    uci:commit(qos_gargoyle)
    
    return result
end

-- 设置自动应用
m.apply_on_parse = true

return m