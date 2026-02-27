-- Copyright 2025 QOS Gargoyle
-- Licensed to the public under the Apache License 2.0.

local dsp  = require "luci.dispatcher"
local uci  = require "luci.model.uci".cursor()
local http = require "luci.http"

local m = Map("qos_gargoyle", translate("QoS Algorithm Configuration"),
    translate("Configure QoS algorithm parameters here. Select different algorithms and set their corresponding parameters."))

-- 获取当前URL参数
local query_string = http.getenv("QUERY_STRING") or ""
local algo_param = "hfsc"

if query_string:find("algo=") then
    for k, v in query_string:gmatch("([^&=]+)=([^&=]+)") do
        if k == "algo" then
            algo_param = v
            break
        end
    end
end

-- 获取当前算法
local current_algo = uci:get("qos_gargoyle", "global", "algorithm") or "hfsc"

-- 算法选择部分
local s_global = m:section(NamedSection, "global", "global", translate("Algorithm Selection"))
s_global.anonymous = true
s_global.addremove = false

local algo = s_global:option(ListValue, "algorithm", translate("Current Algorithm"))
algo:value("hfsc", "HFSC")
algo:value("htb", "HTB")
algo:value("cake", "CAKE")
algo:value("fq_codel", "FQ-CoDel")
-- algo:value("hybrid", "Hybrid Mode")
algo.default = current_algo
algo.rmempty = false

local apply_button = s_global:option(Button, "_apply", translate("Switch Algorithm"))
apply_button.inputtitle = translate("Apply")
apply_button.inputstyle = "apply"

function apply_button.write()
    local selected_algo = http.formvalue("cbid.qos_gargoyle.global.algorithm")
    if selected_algo and selected_algo ~= current_algo then
        uci:set("qos_gargoyle", "global", "algorithm", selected_algo)
        uci:save("qos_gargoyle")
        uci:commit("qos_gargoyle")
    end
    http.redirect(dsp.build_url("admin/qos/qos_gargoyle/algorithm") .. "?algo=" .. (selected_algo or "hfsc"))
end

-- 根据当前算法显示对应的配置
if current_algo == "hfsc" then
    local s_hfsc = m:section(TypedSection, "hfsc", translate("HFSC Parameters"))
    s_hfsc.anonymous = true
    s_hfsc.addremove = false
    
    local latency_mode = s_hfsc:option(ListValue, "latency_mode", translate("Latency Mode"))
    latency_mode:value("normal", translate("Normal"))
    latency_mode:value("priority", translate("Priority"))
    latency_mode:value("dynamic", translate("Dynamic"))
    latency_mode.default = "dynamic"
    latency_mode.rmempty = false
    
    local sfq_depth = s_hfsc:option(ListValue, "sfq_depth", translate("SFQ Queue Depth"))
    sfq_depth:value("auto", translate("Auto"))
    sfq_depth:value("32", "32")
    sfq_depth:value("64", "64")
    sfq_depth:value("128", "128")
    sfq_depth:value("256", "256")
    sfq_depth:value("512", "512")
    sfq_depth:value("1024", "1024")
    sfq_depth.default = "auto"
    sfq_depth.rmempty = false
    
    local m1 = s_hfsc:option(Value, "m1", translate("M1 Parameter"))
    m1.default = "0"
    m1.datatype = "uinteger"
    m1.rmempty = false
    
    local m2 = s_hfsc:option(Value, "m2", translate("M2 Parameter"))
    m2.default = "0"
    m2.datatype = "uinteger"
    m2.rmempty = false
    
    local d = s_hfsc:option(Value, "d", translate("D Parameter"))
    d.default = "0"
    d.datatype = "uinteger"
    d.rmempty = false
    
elseif current_algo == "htb" then
    local s_htb = m:section(TypedSection, "htb", translate("HTB Parameters"))
    s_htb.anonymous = true
    s_htb.addremove = false
    
    local burst_htb = s_htb:option(ListValue, "burst", translate("Burst Size"))
    burst_htb.default = "20k"
    burst_htb:value("5k", "5KB")
    burst_htb:value("10k", "10KB")
    burst_htb:value("20k", "20KB")
    burst_htb:value("30k", "30KB")
    burst_htb:value("50k", "50KB")
    burst_htb.rmempty = false
    
    local cburst_htb = s_htb:option(ListValue, "cburst", translate("CBurst Size"))
    cburst_htb.default = "20k"
    cburst_htb:value("5k", "5KB")
    cburst_htb:value("10k", "10KB")
    cburst_htb:value("20k", "20KB")
    cburst_htb:value("30k", "30KB")
    cburst_htb:value("50k", "50KB")
    cburst_htb.rmempty = false
    
    local rate_htb = s_htb:option(ListValue, "rate", translate("Base Rate"))
    rate_htb.default = "1000kbit"
    rate_htb:value("500kbit", "500Kbps")
    rate_htb:value("1000kbit", "1Mbps")
    rate_htb:value("2000kbit", "2Mbps")
    rate_htb:value("5000kbit", "5Mbps")
    rate_htb:value("10000kbit", "10Mbps")
    rate_htb.rmempty = false
    
    local ceil = s_htb:option(ListValue, "ceil", translate("Ceil Rate"))
    ceil.default = "1100kbit"
    ceil:value("1000kbit", "1Mbps")
    ceil:value("1100kbit", "1.1Mbps")
    ceil:value("1200kbit", "1.2Mbps")
    ceil:value("1500kbit", "1.5Mbps")
    ceil:value("2000kbit", "2Mbps")
    ceil.rmempty = false
    
    local rtt_htb = s_htb:option(Value, "rtt", translate("RTT (ms)"))
    rtt_htb.default = "10"
    rtt_htb.datatype = "uinteger"
    rtt_htb.rmempty = false
    
    local default_class = s_htb:option(Value, "default_class", translate("Default Class"))
    default_class.default = "1:2"
    default_class.rmempty = false
    
    local ceil_multiplier = s_htb:option(Value, "ceil_multiplier", translate("Ceil Multiplier"))
    ceil_multiplier.default = "1.1"
    ceil_multiplier.datatype = "float"
    ceil_multiplier.rmempty = false
    
    local quantum_htb = s_htb:option(Value, "quantum", translate("Quantum (bytes)"))
    quantum_htb.default = "1514"
    quantum_htb.datatype = "uinteger"
    quantum_htb.rmempty = false
    
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
    nat:value("yes", translate("Enable"))
    nat:value("no", translate("Disable"))
    nat.default = "yes"
    nat.rmempty = false
    
    local ack_filter = s_cake:option(ListValue, "ack_filter", translate("ACK Filter"))
    ack_filter:value("yes", translate("Enable"))
    ack_filter:value("no", translate("Disable"))
    ack_filter.default = "yes"
    ack_filter.rmempty = false
    
    local memlimit = s_cake:option(ListValue, "memlimit", translate("Memory Limit"))
    memlimit.default = "32Mb"
    memlimit:value("8Mb", "8MB")
    memlimit:value("16Mb", "16MB")
    memlimit:value("32Mb", "32MB")
    memlimit:value("64Mb", "64MB")
    memlimit:value("128Mb", "128MB")
    memlimit.rmempty = false
    
    local wash = s_cake:option(ListValue, "wash", translate("Wash Traffic"))
    wash:value("yes", translate("Enable"))
    wash:value("no", translate("Disable"))
    wash.default = "no"
    wash.rmempty = false
    
    local split_gso = s_cake:option(ListValue, "split_gso", translate("Split GSO"))
    split_gso:value("yes", translate("Enable"))
    split_gso:value("no", translate("Disable"))
    split_gso.default = "yes"
    split_gso.rmempty = false
    
    local rtt = s_cake:option(ListValue, "rtt", translate("Target RTT"))
    rtt.default = "100ms"
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
    
elseif current_algo == "fq_codel" then
    local s_fq_codel = m:section(TypedSection, "fq_codel", translate("FQ-CoDel Parameters"))
    s_fq_codel.anonymous = true
    s_fq_codel.addremove = false
    
    local target = s_fq_codel:option(ListValue, "target", translate("Target Delay"))
    target.default = "10ms"
    target:value("1ms", "1ms")
    target:value("5ms", "5ms")
    target:value("10ms", "10ms")
    target:value("20ms", "20ms")
    target:value("50ms", "50ms")
    target:value("100ms", "100ms")
    target.rmempty = false
    
    local limit = s_fq_codel:option(ListValue, "limit", translate("Queue Length Limit"))
    limit.default = "1000"
    limit:value("100", "100")
    limit:value("500", "500")
    limit:value("1000", "1000")
    limit:value("1500", "1500")
    limit:value("2000", "2000")
    limit.rmempty = false
    
    local quantum_fq = s_fq_codel:option(Value, "quantum", translate("Quantum (bytes)"))
    quantum_fq.default = "1514"
    quantum_fq.datatype = "uinteger"
    quantum_fq.rmempty = false
    
    local flows = s_fq_codel:option(Value, "flows", translate("Number of Flows"))
    flows.default = "1024"
    flows.datatype = "uinteger"
    flows.rmempty = false
    
    local interval = s_fq_codel:option(ListValue, "interval", translate("Interval"))
    interval.default = "150ms"
    interval:value("50ms", "50ms")
    interval:value("100ms", "100ms")
    interval:value("150ms", "150ms")
    interval:value("200ms", "200ms")
    interval.rmempty = false
    
    local ecn = s_fq_codel:option(ListValue, "ecn", translate("ECN"))
    ecn:value("yes", translate("Enable"))
    ecn:value("no", translate("Disable"))
    ecn.default = "yes"
    ecn.rmempty = false
    
    local memory_limit = s_fq_codel:option(ListValue, "memory_limit", translate("Memory Limit"))
    memory_limit.default = "32Mb"
    memory_limit:value("8Mb", "8MB")
    memory_limit:value("16Mb", "16MB")
    memory_limit:value("32Mb", "32MB")
    memory_limit:value("64Mb", "64MB")
    memory_limit.rmempty = false
    
    local drop_batch = s_fq_codel:option(Value, "drop_batch", translate("Drop Batch"))
    drop_batch.default = "64"
    drop_batch.datatype = "uinteger"
    drop_batch.rmempty = false
    
elseif current_algo == "hybrid" then
    local s_hybrid = m:section(TypedSection, "hybrid", translate("Hybrid Mode Parameters"))
    s_hybrid.anonymous = true
    s_hybrid.addremove = false
    
    local sfq_depth_hybrid = s_hybrid:option(ListValue, "sfq_depth", translate("SFQ Queue Depth"))
    sfq_depth_hybrid:value("512", "512")
    sfq_depth_hybrid:value("1024", "1024")
    sfq_depth_hybrid:value("2048", "2048")
    sfq_depth_hybrid:value("4096", "4096")
    sfq_depth_hybrid.default = "1024"
    sfq_depth_hybrid.rmempty = false
    
    local latency_mode_hybrid = s_hybrid:option(ListValue, "latency_mode", translate("Latency Mode"))
    latency_mode_hybrid:value("normal", translate("Normal"))
    latency_mode_hybrid:value("dynamic", translate("Dynamic"))
    latency_mode_hybrid.default = "dynamic"
    latency_mode_hybrid.rmempty = false
    
    local diffserv_mode_hybrid = s_hybrid:option(ListValue, "diffserv_mode", translate("CAKE DiffServ"))
    diffserv_mode_hybrid:value("diffserv3", "DiffServ3")
    diffserv_mode_hybrid:value("diffserv4", "DiffServ4")
    diffserv_mode_hybrid:value("diffserv5", "DiffServ5")
    diffserv_mode_hybrid:value("diffserv8", "DiffServ8")
    diffserv_mode_hybrid:value("besteffort", "Best Effort")
    diffserv_mode_hybrid.default = "diffserv4"
    diffserv_mode_hybrid.rmempty = false
    
    local overhead_hybrid = s_hybrid:option(Value, "overhead", translate("Overhead (bytes)"))
    overhead_hybrid.default = "32"
    overhead_hybrid.datatype = "integer"
    overhead_hybrid.rmempty = false
    
    local rtt_hybrid = s_hybrid:option(ListValue, "rtt", translate("Target RTT"))
    rtt_hybrid.default = "100ms"
    rtt_hybrid:value("5ms", "5ms")
    rtt_hybrid:value("10ms", "10ms")
    rtt_hybrid:value("20ms", "20ms")
    rtt_hybrid:value("50ms", "50ms")
    rtt_hybrid:value("100ms", "100ms")
    rtt_hybrid:value("150ms", "150ms")
    rtt_hybrid.rmempty = false
    
    local memlimit_hybrid = s_hybrid:option(ListValue, "memlimit", translate("Memory Limit"))
    memlimit_hybrid.default = "32Mb"
    memlimit_hybrid:value("8Mb", "8MB")
    memlimit_hybrid:value("16Mb", "16MB")
    memlimit_hybrid:value("32Mb", "32MB")
    memlimit_hybrid:value("64Mb", "64MB")
    memlimit_hybrid.rmempty = false
    
    local cake_quantum = s_hybrid:option(Value, "cake_quantum", translate("CAKE Quantum (bytes)"))
    cake_quantum.default = "300"
    cake_quantum.datatype = "uinteger"
    cake_quantum.rmempty = false
    
    local ack_filter_hybrid = s_hybrid:option(ListValue, "ack_filter", translate("ACK Filter"))
    ack_filter_hybrid:value("yes", translate("Enable"))
    ack_filter_hybrid:value("no", translate("Disable"))
    ack_filter_hybrid.default = "yes"
    ack_filter_hybrid.rmempty = false
    
    local nat_hybrid = s_hybrid:option(ListValue, "nat", translate("NAT Support"))
    nat_hybrid:value("yes", translate("Enable"))
    nat_hybrid:value("no", translate("Disable"))
    nat_hybrid.default = "yes"
    nat_hybrid.rmempty = false
    
    local wash_hybrid = s_hybrid:option(ListValue, "wash", translate("Wash Traffic"))
    wash_hybrid:value("yes", translate("Enable"))
    wash_hybrid:value("no", translate("Disable"))
    wash_hybrid.default = "no"
    wash_hybrid.rmempty = false
    
    local ingress_hybrid = s_hybrid:option(ListValue, "ingress", translate("Ingress"))
    ingress_hybrid:value("yes", translate("Enable"))
    ingress_hybrid:value("no", translate("Disable"))
    ingress_hybrid.default = "yes"
    ingress_hybrid.rmempty = false
    
    local egress_hybrid = s_hybrid:option(ListValue, "egress", translate("Egress"))
    egress_hybrid:value("yes", translate("Enable"))
    egress_hybrid:value("no", translate("Disable"))
    egress_hybrid.default = "yes"
    egress_hybrid.rmempty = false
    
    -- 使用简单的方法读取分类
    local upload_classes = {}
    local download_classes = {}
    
    -- 读取上传分类
    local index = 1
    while true do
        local section_name = "uclass_" .. index
        local class_name = uci:get("qos_gargoyle", section_name, "name")
        if not class_name then
            break
        end
        table.insert(upload_classes, {
            section = section_name,
            name = class_name
        })
        index = index + 1
    end
    
    -- 读取下载分类
    index = 1
    while true do
        local section_name = "dclass_" .. index
        local class_name = uci:get("qos_gargoyle", section_name, "name")
        if not class_name then
            break
        end
        table.insert(download_classes, {
            section = section_name,
            name = class_name
        })
        index = index + 1
    end
    
    -- 去重：只保留唯一的分类
    local upload_classes_unique = {}
    local seen_upload = {}
    for _, class in ipairs(upload_classes) do
        if not seen_upload[class.name] then
            seen_upload[class.name] = true
            table.insert(upload_classes_unique, class)
        end
    end
    
    local download_classes_unique = {}
    local seen_download = {}
    for _, class in ipairs(download_classes) do
        if not seen_download[class.name] then
            seen_download[class.name] = true
            table.insert(download_classes_unique, class)
        end
    end
    
    -- 按固定顺序排序
    local function sort_classes(classes)
        local order = {realtime = 1, normal = 2, bulk = 3}
        table.sort(classes, function(a, b)
            local order_a = order[a.name] or 99
            local order_b = order[b.name] or 99
            if order_a == order_b then
                return a.name < b.name
            end
            return order_a < order_b
        end)
        return classes
    end
    
    local sorted_uploads = sort_classes(upload_classes_unique)
    local sorted_downloads = sort_classes(download_classes_unique)
    
    -- 调试信息
    local debug_info = s_hybrid:option(DummyValue, "_debug", translate("Debug Info"))
    debug_info.template = "cbi/dvalue"
    debug_info.rawhtml = true
    debug_info.cfgvalue = function(self, section)
        local upload_names = {}
        for _, c in ipairs(sorted_uploads) do
            table.insert(upload_names, c.name .. " (" .. c.section .. ")")
        end
        local download_names = {}
        for _, c in ipairs(sorted_downloads) do
            table.insert(download_names, c.name .. " (" .. c.section .. ")")
        end
        return "<div style='background-color:#e3f2fd;padding:5px;border-radius:4px;margin:10px 0;font-size:12px;'>" ..
               "Found " .. #sorted_uploads .. " upload classes: " .. table.concat(upload_names, ", ") .. 
               "<br>Found " .. #sorted_downloads .. " download classes: " .. table.concat(download_names, ", ") ..
               "</div>"
    end
    
    -- 显示上传分类算法选择
    if #sorted_uploads > 0 then
        local s_upload_algo = m:section(SimpleSection, nil, translate("Upload Classification Algorithm"))
        s_upload_algo.anonymous = true
        
        -- 创建一个表格来显示
        for i, class in ipairs(sorted_uploads) do
            local queue_type_option = s_upload_algo:option(ListValue, 
                "upload_" .. i .. "_queue_type", 
                class.name)
            queue_type_option:value("hfsc", "HFSC")
            queue_type_option:value("cake", "CAKE")
            queue_type_option:value("fq_codel", "FQ-CoDel")
            
            -- 设置默认值
            local default_algo
            if class.name == "realtime" then
                default_algo = "hfsc"
            elseif class.name == "normal" then
                default_algo = "cake"
            elseif class.name == "bulk" then
                default_algo = "fq_codel"
            else
                default_algo = "cake"
            end
            
            queue_type_option.default = default_algo
            
            -- 动态生成cfgvalue函数
            queue_type_option.cfgvalue = function(self, section)
                return uci:get("qos_gargoyle", class.section, "queue_type") or default_algo
            end
            
            -- 动态生成write函数
            queue_type_option.write = function(self, section, value)
                uci:set("qos_gargoyle", class.section, "queue_type", value)
            end
        end
    end
    
    -- 显示下载分类算法选择
    if #sorted_downloads > 0 then
        local s_download_algo = m:section(SimpleSection, nil, translate("Download Classification Algorithm"))
        s_download_algo.anonymous = true
        
        -- 创建一个表格来显示
        for i, class in ipairs(sorted_downloads) do
            local queue_type_option = s_download_algo:option(ListValue, 
                "download_" .. i .. "_queue_type", 
                class.name)
            queue_type_option:value("hfsc", "HFSC")
            queue_type_option:value("cake", "CAKE")
            queue_type_option:value("fq_codel", "FQ-CoDel")
            
            -- 设置默认值
            local default_algo
            if class.name == "realtime" then
                default_algo = "hfsc"
            elseif class.name == "normal" then
                default_algo = "cake"
            elseif class.name == "bulk" then
                default_algo = "fq_codel"
            else
                default_algo = "cake"
            end
            
            queue_type_option.default = default_algo
            
            -- 动态生成cfgvalue函数
            queue_type_option.cfgvalue = function(self, section)
                return uci:get("qos_gargoyle", class.section, "queue_type") or default_algo
            end
            
            -- 动态生成write函数
            queue_type_option.write = function(self, section, value)
                uci:set("qos_gargoyle", class.section, "queue_type", value)
            end
        end
    end
    
    -- 显示算法推荐说明
    local tip = s_hybrid:option(DummyValue, "_tip", translate("Algorithm Recommendations"))
    tip.template = "cbi/dvalue"
    tip.rawhtml = true
    tip.cfgvalue = function(self, section)
        return "<div style='background-color:#fff3cd;padding:10px;border-radius:4px;margin:20px 0;border:1px solid #ffeaa7;'>" ..
               "<strong>" .. translate("Recommended Configuration:") .. "</strong><br>" ..
               "<strong>HFSC</strong> - " .. translate("Real-time traffic (gaming, VoIP)") .. "<br>" ..
               "<strong>CAKE</strong> - " .. translate("Normal traffic (web browsing, video)") .. "<br>" ..
               "<strong>FQ-CoDel</strong> - " .. translate("Background traffic (downloads, updates)") ..
               "</div>"
    end
end

return m