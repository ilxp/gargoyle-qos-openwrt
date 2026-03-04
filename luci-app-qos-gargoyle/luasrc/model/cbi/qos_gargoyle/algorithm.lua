-- Copyright 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>
-- Licensed to the public under the Apache License 2.0.

local dsp  = require "luci.dispatcher"
local uci  = require "luci.model.uci".cursor()
local http = require "luci.http"

local m = Map("qos_gargoyle", translate("QoS Algorithm Configuration"),
    translate("Modify the QoS algorithm parameters. After completing the modification, you need to save/apply them again in the global settings for them to take effect."))

-- 获取当前URL参数
local query_string = http.getenv("QUERY_STRING") or ""
local algo_param = "hfsc_fqcodel"

if query_string:find("algo=") then
    for k, v in query_string:gmatch("([^&=]+)=([^&=]+)") do
        if k == "algo" then
            algo_param = v
            break
        end
    end
end

-- 定义算法映射表 - 只有3个算法
local algo_map = {
    ["hfsc_fqcodel"] = {config = "hfsc", display = "HFSC + FQ-CoDel", leaf_qdisc = "fq_codel"},
    ["htb_fqcodel"]  = {config = "htb", display = "HTB + FQ-CoDel", leaf_qdisc = "fq_codel"},
    ["cake"]         = {config = "cake", display = "CAKE", leaf_qdisc = nil}
}

-- 获取当前活动的算法（从全局配置获取）
local function get_active_algorithm()
    -- 从全局配置获取当前激活的算法
    local global_algo = uci:get("qos_gargoyle", "global", "algorithm")
    
    -- 验证算法是否有效
    if global_algo and algo_map[global_algo] then
        return global_algo
    end
    
    -- 如果全局配置没有设置，默认返回第一个算法
    return "hfsc_fqcodel"
end

-- 获取当前算法（用于显示对应的参数配置）
local current_algo = get_active_algorithm()

-- 算法专属配置部分
if current_algo == "hfsc_fqcodel" then
    local s_hfsc = m:section(TypedSection, "hfsc", translate("HFSC Parameters"))
    s_hfsc.anonymous = true
    s_hfsc.addremove = false
    
    local latency_mode = s_hfsc:option(ListValue, "latency_mode", translate("Latency Mode"))
    latency_mode:value("normal", translate("Normal"))
    latency_mode:value("priority", translate("Priority"))
    latency_mode:value("dynamic", translate("Dynamic"))
    latency_mode.default = "dynamic"
    latency_mode.rmempty = false
    
    local minrtt_enabled = s_hfsc:option(ListValue, "minrtt_enabled", translate("minRTT Enabled"))
    minrtt_enabled:value("0", translate("Disable"))
    minrtt_enabled:value("1", translate("Enable"))
    minrtt_enabled.default = "0"
    minrtt_enabled.rmempty = false
    
    -- 显示FQ-CoDel参数（叶队列）
    local s_fq_codel = m:section(TypedSection, "fq_codel", translate("FQ-CoDel Parameters (Leaf Queue)"))
    s_fq_codel.anonymous = true
    s_fq_codel.addremove = false
    
    local target = s_fq_codel:option(Value, "target", translate("Target Delay (microseconds)"))
    target.default = "5000"
    target.datatype = "uinteger"
    target.rmempty = false
    
    local limit = s_fq_codel:option(Value, "limit", translate("Queue Length Limit"))
    limit.default = "10240"
    limit.datatype = "uinteger"
    limit.rmempty = false
    
    local quantum_fq = s_fq_codel:option(Value, "quantum", translate("Quantum (bytes)"))
    quantum_fq.default = "1514"
    quantum_fq.datatype = "uinteger"
    quantum_fq.rmempty = false
    
    local flows = s_fq_codel:option(Value, "flows", translate("Number of Flows"))
    flows.default = "1024"
    flows.datatype = "uinteger"
    flows.rmempty = false
    
    local interval = s_fq_codel:option(Value, "interval", translate("Interval (microseconds)"))
    interval.default = "100000"
    interval.datatype = "uinteger"
    interval.rmempty = false
    
    local ecn = s_fq_codel:option(ListValue, "ecn", translate("ECN"))
    ecn:value("", translate("Not Set (Default)"))
    ecn:value("ecn", translate("Enable ECN"))
    ecn:value("noecn", translate("Disable ECN"))
    ecn.default = "ecn"  -- 允许为空，因为"Not Set (Default)"是有效选项
    ecn.rmempty = true  
    
elseif current_algo == "htb_fqcodel" then
    local s_htb = m:section(TypedSection, "htb", translate("HTB Parameters"))
    s_htb.anonymous = true
    s_htb.addremove = false
    
    local priomap_enabled = s_htb:option(ListValue, "priomap_enabled", translate("Priority Mapping Enabled"))
    priomap_enabled:value("0", translate("Disable"))
    priomap_enabled:value("1", translate("Enable"))
    priomap_enabled.default = "1"
    priomap_enabled.rmempty = false
    
    local drr_quantum = s_htb:option(Value, "drr_quantum", translate("DRR Quantum"))
    drr_quantum:value("auto", "Auto")
    drr_quantum:value("100", "100")
    drr_quantum:value("300", "300")
    drr_quantum:value("500", "500")
    drr_quantum:value("1000", "1000")
    drr_quantum:value("1514", "1514 (MTU)")
    drr_quantum.default = "auto"
    drr_quantum.rmempty = false
    
    -- 显示FQ-CoDel参数（叶队列）
    local s_fq_codel = m:section(TypedSection, "fq_codel", translate("FQ-CoDel Parameters (Leaf Queue)"))
    s_fq_codel.anonymous = true
    s_fq_codel.addremove = false
    
    local target = s_fq_codel:option(Value, "target", translate("Target Delay (microseconds)"))
    target.default = "5000"
    target.datatype = "uinteger"
    target.rmempty = false
    
    local limit = s_fq_codel:option(Value, "limit", translate("Queue Length Limit"))
    limit.default = "10240"
    limit.datatype = "uinteger"
    limit.rmempty = false
    
    local quantum_fq = s_fq_codel:option(Value, "quantum", translate("Quantum (bytes)"))
    quantum_fq.default = "1514"
    quantum_fq.datatype = "uinteger"
    quantum_fq.rmempty = false
    
    local flows = s_fq_codel:option(Value, "flows", translate("Number of Flows"))
    flows.default = "1024"
    flows.datatype = "uinteger"
    flows.rmempty = false
    
    local interval = s_fq_codel:option(Value, "interval", translate("Interval (microseconds)"))
    interval.default = "100000"
    interval.datatype = "uinteger"
    interval.rmempty = false
    
    local ecn = s_fq_codel:option(ListValue, "ecn", translate("ECN"))
    ecn:value("", translate("Not Set (Default)"))
    ecn:value("ecn", translate("Enable ECN"))
    ecn:value("noecn", translate("Disable ECN"))
    ecn.default = ""
    ecn.rmempty = true
    
elseif current_algo == "cake" then
    local s_cake = m:section(TypedSection, "cake", translate("CAKE Parameters"))
    s_cake.anonymous = true
    s_cake.addremove = false
    
    local diffserv_mode = s_cake:option(ListValue, "diffserv_mode", translate("DiffServ Mode"))
    diffserv_mode:value("diffserv3", "DiffServ3")
    diffserv_mode:value("diffserv4", "DiffServ4")
    diffserv_mode:value("diffserv5", "DiffServ5")
    diffserv_mode:value("diffserv8", "DiffServ8")
    diffserv_mode:value("besteffort", "Best Effort")
    diffserv_mode.default = "diffserv4"
    diffserv_mode.rmempty = false
    
    local nat = s_cake:option(ListValue, "nat", translate("NAT Support"))
    nat:value("1", translate("Enable"))
    nat:value("0", translate("Disable"))
    nat.default = "1"
    nat.rmempty = false
    
    local ack_filter = s_cake:option(ListValue, "ack_filter", translate("ACK Filter"))
    ack_filter:value("1", translate("Enable"))
    ack_filter:value("0", translate("Disable"))
    ack_filter.default = "1"
    ack_filter.rmempty = false
    
    local memlimit = s_cake:option(ListValue, "memlimit", translate("Memory Limit"))
    memlimit.default = "64Mb"
    memlimit:value("8Mb", "8MB")
    memlimit:value("16Mb", "16MB")
    memlimit:value("32Mb", "32MB")
    memlimit:value("64Mb", "64MB")
    memlimit:value("128Mb", "128MB")
    memlimit.rmempty = false
    
    local wash = s_cake:option(ListValue, "wash", translate("Wash Traffic"))
    wash:value("1", translate("Enable"))
    wash:value("0", translate("Disable"))
    wash.default = "0" 
    wash.rmempty = false
    
    local split_gso = s_cake:option(ListValue, "split_gso", translate("Split GSO"))
    split_gso:value("1", translate("Enable"))
    split_gso:value("0", translate("Disable"))
    split_gso.default = "1" 
    split_gso.rmempty = false
    
    local ingress = s_cake:option(ListValue, "ingress", translate("Ingress Mode"),
        translate("Ingress queueing method: 0=Use IFB (recommended), 1=Use ingress queue directly"))
    ingress:value("0", "Use IFB (0)")
    ingress:value("1", "Use ingress queue (1)")
    ingress.default = "0"
    ingress.rmempty = false
    
    local autorate_ingress = s_cake:option(ListValue, "autorate_ingress", translate("AutoRate Ingress"),
        translate("Automatically adjust ingress bandwidth based on measured throughput"))
    autorate_ingress:value("0", translate("Disable"))
    autorate_ingress:value("1", translate("Enable"))
    autorate_ingress.default = "0"
    autorate_ingress.rmempty = false
    
    local rtt = s_cake:option(ListValue, "rtt", translate("Target RTT"))
    rtt.default = "50ms"
    rtt:value("5ms", "5ms")
    rtt:value("10ms", "10ms")
    rtt:value("20ms", "20ms")
    rtt:value("50ms", "50ms")
    rtt:value("100ms", "100ms")
    rtt:value("150ms", "150ms")
    rtt:value("200ms", "200ms")
    rtt.rmempty = false
    
    local overhead = s_cake:option(Value, "overhead", translate("Overhead (bytes)"))
    overhead.default = "0"
    overhead.datatype = "integer"
    overhead.rmempty = false
    
    local mpu = s_cake:option(Value, "mpu", translate("MPU (bytes)"))
    mpu.default = "0"
    mpu.datatype = "uinteger"
    mpu.rmempty = false
    
    local quantum_cake = s_cake:option(Value, "quantum", translate("Quantum (bytes)"))
    quantum_cake.default = "300"
    quantum_cake.datatype = "uinteger"
    quantum_cake.rmempty = false
end

-- 系统会自动添加"保存并应用"和"重置"按钮
function m.on_after_apply(self)
    uci:save("qos_gargoyle")
    uci:commit("qos_gargoyle")
    
    -- 重定向回当前页面
    http.redirect(dsp.build_url("admin/qos/qos_gargoyle/algorithm"))
end

return m