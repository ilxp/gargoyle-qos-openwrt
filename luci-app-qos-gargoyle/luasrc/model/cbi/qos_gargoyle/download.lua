-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modded by ErickG <erickguo999@gmail.com>

local wa   = require "luci.tools.webadmin"
local uci  = require "luci.model.uci".cursor()
local dsp  = require "luci.dispatcher"
local http = require "luci.http"
local qos  = require "luci.model.qos_gargoyle"
local sys = require "luci.sys"

local m, class_s, rule_s, o
local download_classes = {}
-- 改, 改成配置后缀
local qos_config = "qos_gargoyle"
-- 在保存的时候查看是从创建来的还是自己保存的
local mes_class_remove = false
local mes_rule_remove = false
local mes_rule_sort = true

local apply = http.formvalue("cbi.apply")

uci:foreach(qos_config, "download_class", function(s)
	local class_alias = s.name
	if class_alias then
		download_classes[#download_classes + 1] = {name = s[".name"], alias = class_alias}
	end
end)

m = Map(qos_config, translate("Download Settings"))
m.template = "qos_gargoyle/list_view"


-- 类别排序
local function sort_class_sname()
	local check_idx = 0
	local check_sname = ""
	-- 存放有问题的section
	local section_list = {}
	-- 存放新section的名称
	local section_sname = {}
	m.uci:foreach(qos_config, "download_class", function(s)
		check_idx = check_idx + 1
		check_sname = "dclass_" .. check_idx
		if s[".name"] ~= nil and s[".name"] ~= check_sname then
			-- 有问题的section先添加到集合里
			table.insert(section_list, s)
			-- 存放对应顺序
			table.insert(section_sname, check_sname)
		end
	end)

	-- 删除旧的section, section[".name"]包有的
	for _, section in ipairs(section_list) do
		m.uci:delete(qos_config, section[".name"])
	end
	-- 添加新的section
	for idx, section in ipairs(section_list) do
		check_sname = section_sname[idx]
		m.uci:set(qos_config, check_sname, "download_class")
		for key, value in pairs(section) do
			m.uci:set(qos_config, check_sname, key, value)
		end
	end
	-- 为什么不用排序？
	-- 因为删除操作只删除一个,后面不对的排序只需要按照新的顺序添加即可
	-- 不像处理优先级规则那样复杂
end

-- 规则排序
-- 只要创建了新规则或者删除或者被排序
-- 都要用这个方法处理
local function sort_rule_sname()
	local check_idx = 0
	local check_sname = ""
	local section_list = {}
	local section_sname = {}
	local section_order = {}
	-- 设置乱序检测, 如果乱序就打开开关执行重新排序操作
	local is_unorder = false
	-- 停止排序, 避免重复保存执行这个方法
	mes_rule_sort = false
	-- 寻找错误部分
	m.uci:foreach(qos_config, "download_rule", function(s)
		-- 记录sname不对的部分
		check_idx = check_idx + 1
		check_sname= "download_rule_" .. (check_idx * 100)
		if s[".name"] ~= nil and s[".name"] ~= check_sname then
			-- 添加乱序的section
			table.insert(section_list, s)
			table.insert(section_sname, check_sname)
			table.insert(section_order, check_idx)
			is_unorder = true
		end
	end)
	-- 删除旧的section
	if is_unorder == true then
		for _, section in ipairs(section_list) do
			m.uci:delete(qos_config, section[".name"])
		end
		-- 添加新的section
		for idx, section in ipairs(section_list) do
			check_sname = section_sname[idx]
			m.uci:set(qos_config, check_sname, "download_rule")
			for key, value in pairs(section) do
				if key == "test_order" then
					m.uci:set(qos_config, check_sname, "test_order", section_order[idx] * 100)
				else
					m.uci:set(qos_config, check_sname, key, value)
				end
			end
		end
		-- 删除的时候不用排序
		-- 重新排序
		if mes_rule_remove ~= true then
			for idx, _ in ipairs(section_list) do
				check_sname = section_sname[idx]
				m.uci:reorder(qos_config, check_sname, (section_order[idx] - 1))
			end
			-- 撤销删除标识
			mes_rule_remove = false
		end
	end
	-- 恢复排序标识
	-- 用于排序保存后进行保存
	mes_rule_sort = true
end

-- 只能通过这个来判断是谁了
-- 没想到section其实是个字符串
function TypedSection.remove(self, section)
	-- 匹配section名称是否含有规则关键词
	if string.find(section, "download_rule_") then
		-- 通知修改排序
		mes_rule_sort = true
		-- 通知是删除
		mes_rule_remove = true
	end
	-- 删除section的源码
	m.proceed = true
	local err_or_not = m:del(section)

	return err_or_not
end

-- 尝试一下用on_after_save重新排序
-- 只有不是从创建保存来的才进行检测
-- 如果是从添加规则来的, 跳过检测并去除标识
-- 如果不是, 就进行规则排序
function m.on_after_save(self)
	-- 因为有排序的问题, 所以只能全局调用排序了
	if mes_rule_sort then
		sort_rule_sname()
	end

	-- 限速类别删除后进行排序
	if mes_class_remove then
		sort_class_sname()
		mes_class_remove = false
	end
end

if apply then
	-- 只有在qos启动之后才能应用这段代码
	local qos_enable = sys.init.enabled(qos_config)
	if qos_enable then
		sys.init.stop(qos_config)
		sys.init.disable(qos_config)
		sys.init.enable(qos_config)
		sys.init.start(qos_config)
	end
end

class_s = m:section(TypedSection, "download_class", translate("Service Classes"),
	translate("Each service class is specified by four parameters: percent bandwidth at capacity, "
	.. "realtime bandwidth and maximum bandwidth and the minimimze round trip time flag."))
-- 不显示section名称
class_s.anonymous = true
-- 添加删除按钮
class_s.addremove = true
class_s.template  = "cbi/tblsection"
class_s.extedit   = dsp.build_url("admin/qos/qos_gargoyle/download/class/%s")

-- 又来了,又开始瞎几把随机sid了
--	local sid = TypedSection.create(...)
-- class_s.create = function(self, section)
function class_s.create(self, section)
	local class_idx = 0
	local class_sname = ""
	-- 取消规则排序方法,避免不必要的调用
	mes_rule_sort = false
	-- 计算class总数
	m.uci:foreach(qos_config, "download_class", function(_)
		class_idx = class_idx + 1
	end)
	-- 不管有没有都要+1,这个+1是给创建新的规则条用的
	class_idx = class_idx + 1
	class_sname = "dclass_%d" % class_idx
	m.uci:set(qos_config, class_sname, "download_class")

	-- 恢复规则条排序方法,让规则条经过排序后能够重新排序
	mes_rule_sort = true
	-- 重定向
	http.redirect(class_s.extedit % class_sname)
	return section
end

o = class_s:option(DummyValue, "name", translate("Class Name"))
o.cfgvalue = function(...)
	return Value.cfgvalue(...) or translate("None")
end

o = class_s:option(DummyValue, "percent_bandwidth", translate("Percent Bandwidth At Capacity"))
o.cfgvalue = function(...)
	local v = tonumber(Value.cfgvalue(...))
	if v and v > 0 then
		return "%d %%" % v
	end
	return translate("Not set")
end

o = class_s:option(DummyValue, "min_bandwidth", "%s (kbps)" % translate("Minimum Bandwidth"))
o.cfgvalue = function(...)
	local v = tonumber(Value.cfgvalue(...))
	return v or translate("Zero")
end

o = class_s:option(DummyValue, "max_bandwidth", "%s (kbps)" % translate("Maximum Bandwidth"))
o.cfgvalue = function(...)
	local v = tonumber(Value.cfgvalue(...))
	return v or translate("Unlimited")
end

o = class_s:option(DummyValue, "minRTT", translate("Minimize RTT"))
o.cfgvalue = function(...)
	local v = Value.cfgvalue(...)
	return v and translate(v) or translate("No")
end

-- 负载显示
o = class_s:option(DummyValue, "_ld", "%s (kbps)" % translate("Load"))
o.rawhtml = true
o.value   = "<em class=\"ld-download\">*</em>"

-- 添加规则部分
-- 这部分不知道怎么给表格添加id
rule_s = m:section(TypedSection, "download_rule", translate("Classification Rules"),
	translate("Packets are tested against the rules in the order specified -- rules toward the top "
	.. "have priority. As soon as a packet matches a rule it is classified, and the rest of the rules "
	.. "are ignored. The order of the rules can be altered using the arrow controls."))

-- 不显示qos规则条名字
rule_s.anonymous = true
rule_s.addremove = true
rule_s.template  = "cbi/tblsection"
rule_s.sortable  = true

rule_s.extedit = dsp.build_url("admin/qos/qos_gargoyle/download/rule/%s")

-- 这个是随机id来的, 没屌用
-- local sid = TypedSection.create(self, section)

-- 目前只能用这种蠢办法来设置section, name
-- 添加的时候顺带查看section名称有没有乱
-- 如果乱了顺带修改一下顺序
function rule_s.create(self, section)
	local rule_idx = 0
	local rule_name = ""
	local rule_order = ""

	-- 感觉创建不需要排序
	-- 创建之前的一切操作都是已经排序好了
	mes_rule_sort = false
	-- 计算section总个数
	m.uci:foreach(qos_config, "download_rule", function(_)
		rule_idx = rule_idx + 1
	end)
	-- 不管有没有都要+1
	rule_idx = rule_idx + 1
	rule_order = "%d" % (rule_idx * 100)
	rule_name = "download_rule_" .. (rule_idx * 100)
	m.uci:set(qos_config, rule_name, "download_rule")
	m.uci:set(qos_config, rule_name, "test_order", rule_order)
	mes_rule_sort = true
	m.uci:set(qos_config, rule_name, "family", "inet")
	-- 重定向
	http.redirect(rule_s.extedit % rule_name)

	return section
end

-- 规则条部分, 设置各个选项
-- 服务类型
o = rule_s:option(ListValue, "class", translate("Service Class"))
for _, s in ipairs(download_classes) do o:value(s.name, s.alias) end

-- 新添加,地址族
-- 这个地址族放在高级设置里算了
-- o = rule_s:option(ListValue, "family", translate("IP family"))
-- o.datatype="string"
-- o.default="ip"
-- o.rmempty = false
-- o:value("ip", "IPV4")
-- o:value("inet", translate("IPV6 and IPV4"))
-- o:value("ip6", "IPV6")


-- 端口协议
o = rule_s:option(Value, "proto", translate("Transport Protocol"))
o:value("", translate("All"))
o:value("tcp", "TCP")
o:value("udp", "UDP")
o:value("icmp", "ICMP")
o:value("gre", "GRE")
o.size = "10"
o.cfgvalue = function(...)
	local v = Value.cfgvalue(...)
	return v and v:upper() or ""
end
o.write = function(self, section, value)
	Value.write(self, section, value:lower())
end


o = rule_s:option(Value, "source", translate("Source IP(s)"))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

o = rule_s:option(Value, "srcport", translate("Source Port(s)"))
o:value("", translate("All"))
-- 使用字符串
-- o.datatype  = "or(port, portrange)"
o.datatype  = "string"

o = rule_s:option(Value, "destination", translate("Destination IP(s)"))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

o = rule_s:option(Value, "dstport", translate("Destination Port(s)"))
o:value("", translate("All"))
-- 使用字符串
-- o.datatype = "or(port, portrange)"
o.datatype  = "string"

local od1, od2, od3
od1 = rule_s:option(DummyValue, "min_pkt_size", translate("Minimum Packet Length"))
od1.cfgvalue = function(...)
	local v = tonumber(Value.cfgvalue(...))
	if v and v > 0 then
		return wa.byte_format(v)
	end
	return translate("Not set")
end

od2 = rule_s:option(DummyValue, "max_pkt_size", translate("Maximum Packet Length"))
od2.cfgvalue = function(...)
	local v = tonumber(Value.cfgvalue(...))
	if v and v > 0 then
		return wa.byte_format(v)
	end
	return translate("Not set")
end

-- 连接流量
od3 = rule_s:option(DummyValue, "connbytes_kb", translate("Connection Bytes Reach (eg. 800:900 or 80: or :90)."))
od3.cfgvalue = function(...)
	-- local v = tonumber(Value.cfgvalue(...))
	local str_v = tostring(Value.cfgvalue(...))
	local num1, num2
	if str_v then
		-- 检查字符串, 先检查-, 再检查大于小于号
		if string.find(str_v, ":") then
			num1, num2 = str_v:match("^(%d+)%:(%d+)$")
			if num1 then
				if tonumber(num1) > 0 then
					num1 = wa.byte_format(tonumber(num1) * 1024)
				end
			else
				num1 = ""
			end
			if num2 then
				if tonumber(num2) > 0 then
			 		num2 = wa.byte_format(tonumber(num2) * 1024)
				end
			else
				num2 = ""
			end
			return num1 .. " :" .. num2
		end
	end

	-- if v and v > 0 then
	--	return wa.byte_format(v * 1024)
	-- end
	return translate("Not set")
end

-- ndpi
 if qos.has_ndpi() then
 	o = rule_s:option(DummyValue, "ndpi", translate("DPI Protocol"))
 	o.cfgvalue = function(...)
 		local v = Value.cfgvalue(...)
 		return v and v:upper() or translate("All")
 	end
 end

return m
