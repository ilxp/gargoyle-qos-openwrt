-- Copyright 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>
-- Licensed to the public under the Apache License 2.0.

local dsp  = require "luci.dispatcher"
local uci  = require "luci.model.uci".cursor()
local http = require "luci.http"

local m = Map("qos_gargoyle", translate("QoS Algorithm Configuration"),
	translate("Modify the QoS algorithm parameters. After completing the modification, you need to save/apply them again in the global settings for them to take effect."))

-- 获取当前活动的算法（从全局配置读取）
local function get_active_algorithm()
	local global_algo = uci:get("qos_gargoyle", "global", "algorithm")
	if global_algo then return global_algo end
	return "hfsc_cake" -- 默认
end

local current_algo = get_active_algorithm()

-- 定义算法映射表（用于参考，暂未使用）
local algo_map = {
	["hfsc_cake"]    = {config = "hfsc", display = "HFSC + CAKE", leaf_qdisc = "cake"},
	["htb_cake"]     = {config = "htb",  display = "HTB + CAKE", leaf_qdisc = "cake"},
	["hfsc_fqcodel"] = {config = "hfsc", display = "HFSC + FQ-CoDel", leaf_qdisc = "fq_codel"},
	["htb_fqcodel"]  = {config = "htb",  display = "HTB + FQ-CoDel", leaf_qdisc = "fq_codel"},
	["cake"]         = {config = "cake", display = "CAKE", leaf_qdisc = nil}
}

-- ========== 根据当前算法动态生成配置界面 ==========

if current_algo == "hfsc_cake" or current_algo == "htb_cake" then
	-- 调度器部分：HFSC 或 HTB
	if current_algo == "hfsc_cake" then
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

		local minrtt_delay = s_hfsc:option(Value, "minrtt_delay", translate("minRTT Delay"))
		minrtt_delay.default = "1000us"
		minrtt_delay:value("1000us", "1000us")
		minrtt_delay:value("2000us", "2000us")
		minrtt_delay:value("5000us", "5000us")
		minrtt_delay:value("10ms", "10ms")
		minrtt_delay:value("20ms", "20ms")
		minrtt_delay.rmempty = false
		minrtt_delay.description = translate("Delay parameter for minRTT mode (e.g., 1000us, 10ms)")
	end

	if current_algo == "htb_cake" then
		local s_htb = m:section(TypedSection, "htb", translate("HTB Parameters"))
		s_htb.anonymous = true
		s_htb.addremove = false

		local r2q = s_htb:option(Value, "r2q", translate("R2Q"))
		r2q.default = "10"
		r2q.datatype = "uinteger"
		r2q.rmempty = false
		r2q.description = translate("Rate to quantum ratio (recommended: 10)")

		local drr_quantum = s_htb:option(Value, "drr_quantum", translate("DRR Quantum"))
		drr_quantum:value("auto", "Auto")
		drr_quantum:value("100", "100")
		drr_quantum:value("300", "300")
		drr_quantum:value("500", "500")
		drr_quantum:value("1000", "1000")
		drr_quantum:value("1514", "1514 (MTU)")
		drr_quantum.default = "auto"
		drr_quantum.rmempty = false
	end

	-- CAKE 叶队列参数（共用）
	local s_cake = m:section(TypedSection, "cake", translate("CAKE Parameters (Leaf Queue)"))
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

	local flowmode = s_cake:option(ListValue, "flowmode", translate("Flow Mode"))
	flowmode:value("srchost", "Source Host (srchost)")
	flowmode:value("dsthost", "Destination Host (dsthost)")
	flowmode:value("hosts", "Both Hosts (hosts)")
	flowmode:value("flows", "Flows (flows)")
	flowmode:value("dual-srchost", "Dual Source Host (dual-srchost)")
	flowmode:value("dual-dsthost", "Dual Destination Host (dual-dsthost)")
	flowmode.default = "srchost"
	flowmode.rmempty = false
	flowmode.description = translate("Flow isolation mode")

	local limit = s_cake:option(Value, "limit", translate("Queue Limit (packets)"))
	limit.default = "10240"
	limit.datatype = "uinteger"
	limit.rmempty = false
	limit.description = translate("Maximum number of packets in the queue")

	local ecn = s_cake:option(ListValue, "ecn", translate("ECN"))
	ecn:value("1", translate("Enable"))
	ecn:value("0", translate("Disable"))
	ecn.default = "1"
	ecn.rmempty = false
	ecn.description = translate("Explicit Congestion Notification")

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
	memlimit:value("8Mb", "8MB")
	memlimit:value("16Mb", "16MB")
	memlimit:value("32Mb", "32MB")
	memlimit:value("64Mb", "64MB")
	memlimit:value("128Mb", "128MB")
	memlimit.default = "64Mb"
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
	rtt:value("5ms", "5ms")
	rtt:value("10ms", "10ms")
	rtt:value("20ms", "20ms")
	rtt:value("50ms", "50ms")
	rtt:value("100ms", "100ms")
	rtt:value("150ms", "150ms")
	rtt:value("200ms", "200ms")
	rtt.default = "50ms"
	rtt.rmempty = false

	local overhead = s_cake:option(Value, "overhead", translate("Overhead (bytes)"))
	overhead.default = "0"
	overhead.datatype = "integer"
	overhead.rmempty = false

	local mpu = s_cake:option(Value, "mpu", translate("MPU (bytes)"))
	mpu.default = "0"
	mpu.datatype = "uinteger"
	mpu.rmempty = false

elseif current_algo == "hfsc_fqcodel" or current_algo == "htb_fqcodel" then
	-- 调度器部分：HFSC 或 HTB
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

		local minrtt_delay = s_hfsc:option(Value, "minrtt_delay", translate("minRTT Delay"))
		minrtt_delay.default = "1000us"
		minrtt_delay:value("1000us", "1000us")
		minrtt_delay:value("2000us", "2000us")
		minrtt_delay:value("5000us", "5000us")
		minrtt_delay:value("10ms", "10ms")
		minrtt_delay:value("20ms", "20ms")
		minrtt_delay.rmempty = false
		minrtt_delay.description = translate("Delay parameter for minRTT mode (e.g., 1000us, 10ms)")
	end

	if current_algo == "htb_fqcodel" then
		local s_htb = m:section(TypedSection, "htb", translate("HTB Parameters"))
		s_htb.anonymous = true
		s_htb.addremove = false

		local r2q = s_htb:option(Value, "r2q", translate("R2Q"))
		r2q.default = "10"
		r2q.datatype = "uinteger"
		r2q.rmempty = false
		r2q.description = translate("Rate to quantum ratio (recommended: 10)")

		local drr_quantum = s_htb:option(Value, "drr_quantum", translate("DRR Quantum"))
		drr_quantum:value("auto", "Auto")
		drr_quantum:value("100", "100")
		drr_quantum:value("300", "300")
		drr_quantum:value("500", "500")
		drr_quantum:value("1000", "1000")
		drr_quantum:value("1514", "1514 (MTU)")
		drr_quantum.default = "auto"
		drr_quantum.rmempty = false
	end

	-- FQ-CoDel 叶队列参数
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

	local quantum = s_fq_codel:option(Value, "quantum", translate("Quantum (bytes)"))
	quantum.default = "1514"
	quantum.datatype = "uinteger"
	quantum.rmempty = false

	local flows = s_fq_codel:option(Value, "flows", translate("Number of Flows"))
	flows.default = "1024"
	flows.datatype = "uinteger"
	flows.rmempty = false

	local interval = s_fq_codel:option(Value, "interval", translate("Interval (microseconds)"))
	interval.default = "100000"
	interval.datatype = "uinteger"
	interval.rmempty = false

	local memory_limit = s_fq_codel:option(Value, "memory_limit", translate("Memory Limit"))
	memory_limit.default = "auto"
	memory_limit:value("auto", "Auto")
	memory_limit:value("4Mb", "4MB")
	memory_limit:value("8Mb", "8MB")
	memory_limit:value("16Mb", "16MB")
	memory_limit:value("32Mb", "32MB")
	memory_limit.rmempty = false

	local ce_threshold = s_fq_codel:option(Value, "ce_threshold", translate("CE Threshold"))
	ce_threshold.default = "0"
	ce_threshold.datatype = "string"
	ce_threshold.rmempty = false
	ce_threshold.description = translate("Threshold for CE marking (e.g., 1ms)")

	local ecn = s_fq_codel:option(ListValue, "ecn", translate("ECN"))
	ecn:value("1", translate("Enable"))
	ecn:value("0", translate("Disable"))
	ecn.default = "1"
	ecn.rmempty = false
	ecn.description = translate("Explicit Congestion Notification")

elseif current_algo == "cake" then
	-- 纯 CAKE 算法
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

	local flowmode = s_cake:option(ListValue, "flowmode", translate("Flow Mode"))
	flowmode:value("srchost", "Source Host (srchost)")
	flowmode:value("dsthost", "Destination Host (dsthost)")
	flowmode:value("hosts", "Both Hosts (hosts)")
	flowmode:value("flows", "Flows (flows)")
	flowmode:value("dual-srchost", "Dual Source Host (dual-srchost)")
	flowmode:value("dual-dsthost", "Dual Destination Host (dual-dsthost)")
	flowmode.default = "srchost"
	flowmode.rmempty = false

	local limit = s_cake:option(Value, "limit", translate("Queue Limit (packets)"))
	limit.default = "10240"
	limit.datatype = "uinteger"
	limit.rmempty = false

	local ecn = s_cake:option(ListValue, "ecn", translate("ECN"))
	ecn:value("1", translate("Enable"))
	ecn:value("0", translate("Disable"))
	ecn.default = "1"
	ecn.rmempty = false

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
	memlimit:value("8Mb", "8MB")
	memlimit:value("16Mb", "16MB")
	memlimit:value("32Mb", "32MB")
	memlimit:value("64Mb", "64MB")
	memlimit:value("128Mb", "128MB")
	memlimit.default = "64Mb"
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
	rtt:value("5ms", "5ms")
	rtt:value("10ms", "10ms")
	rtt:value("20ms", "20ms")
	rtt:value("50ms", "50ms")
	rtt:value("100ms", "100ms")
	rtt:value("150ms", "150ms")
	rtt:value("200ms", "200ms")
	rtt.default = "50ms"
	rtt.rmempty = false

	local overhead = s_cake:option(Value, "overhead", translate("Overhead (bytes)"))
	overhead.default = "0"
	overhead.datatype = "integer"
	overhead.rmempty = false

	local mpu = s_cake:option(Value, "mpu", translate("MPU (bytes)"))
	mpu.default = "0"
	mpu.datatype = "uinteger"
	mpu.rmempty = false

	-- 多队列 CAKE-MQ 开关
	local enable_mq = s_cake:option(ListValue, "enable_mq", translate("Enable Multi-Queue"))
	enable_mq:value("1", translate("Enable"))
	enable_mq:value("0", translate("Disable"))
	enable_mq.default = "1"
	enable_mq.rmempty = false
	enable_mq.description = translate("Enable CAKE-MQ for multi-queue devices")
end

-- 保存后重启服务
function m.on_after_apply(self)
	uci:save("qos_gargoyle")
	uci:commit("qos_gargoyle")
	os.execute("/etc/init.d/qos_gargoyle restart 2>/dev/null")
	http.redirect(dsp.build_url("admin/qos/qos_gargoyle/algorithm"))
end

return m