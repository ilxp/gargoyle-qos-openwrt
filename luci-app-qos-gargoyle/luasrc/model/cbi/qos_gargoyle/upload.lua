-- 基于原始版本修复的 upload.lua
local wa   = require "luci.tools.webadmin"
local uci  = require "luci.model.uci".cursor()
local dsp  = require "luci.dispatcher"
local http = require "luci.http"
local qos  = require "luci.model.qos_gargoyle"
local sys  = require "luci.sys"

local m, s, o
local upload_classes = {}
local qos_config = "qos_gargoyle"

-- 获取上传分类
uci:foreach(qos_config, "upload_class", function(s)
    if s.name then
        upload_classes[#upload_classes + 1] = {name = s[".name"], alias = s.name}
    end
end)

m = Map(qos_config, translate("Upload Settings"))
m.template = "qos_gargoyle/list_view"

-- 修复1: 使用最简单的创建函数
local function create_class()
    local class_count = 0
    local max_id = 0
    
    -- 获取最大ID
    uci:foreach(qos_config, "upload_class", function(s)
        class_count = class_count + 1
        local name = s[".name"]
        if name then
            local id = name:match("uclass_(%d+)")
            if id then
                id = tonumber(id)
                if id > max_id then
                    max_id = id
                end
            end
        end
    end)
    
    local new_id = max_id + 1
    local new_sname = "uclass_" .. new_id
    
    -- 创建新分类但不提交
    uci:section(qos_config, "upload_class", new_sname, {
        name = "Class " .. new_id,
        priority = new_id,
        percent_bandwidth = "10",
        min_bandwidth = "0",
        max_bandwidth = "",
        description = ""
    })
    
    uci:save(qos_config)
    -- 注意：移除了 uci:commit(qos_config)，只在用户保存时才提交
    
    return new_sname
end

local function create_rule()
    local rule_count = 0
    local max_id = 0
    
    -- 获取最大ID
    uci:foreach(qos_config, "upload_rule", function(s)
        rule_count = rule_count + 1
        local name = s[".name"]
        if name then
            local id = name:match("upload_rule_(%d+)")
            if id then
                id = tonumber(id)
                if id > max_id then
                    max_id = id
                end
            end
        end
    end)
    
    local new_id = max_id + 1
    local new_sname = "upload_rule_" .. new_id
    
    -- 修复2: 从*5开始而不是*100
    local new_order
    if rule_count == 0 then
        new_order = 5
    else
        -- 计算新的排序值，确保是5的倍数
        new_order = math.floor((max_id + 1) * 5)
    end
    
    -- 获取第一个可用的分类
    local first_class = nil
    uci:foreach(qos_config, "upload_class", function(s)
        if not first_class then
            first_class = s[".name"]
        end
    end)
    
    -- 创建新规则但不提交
    uci:section(qos_config, "upload_rule", new_sname, {
        test_order = new_order,
        family = "inet",
        class = first_class or ""
    })
    
    uci:save(qos_config)
    -- 注意：移除了 uci:commit(qos_config)，只在用户保存时才提交
    
    return new_sname
end

-- 1. 服务分类部分
s = m:section(TypedSection, "upload_class", translate("Service Classes"),
    translate("Each upload service class is specified by three parameters: percent bandwidth at "
    .. "capacity, minimum bandwidth and maximum bandwidth."))
s.anonymous = true
s.template = "cbi/tblsection"
s.addremove = true
s.extedit = dsp.build_url("admin/qos/qos_gargoyle/upload/class/%s")

-- 修复2: 使用简单的创建和删除函数
s.create = function(self, section)
    local new_sname = create_class()
    http.redirect(self.extedit % new_sname)
    return new_sname
end

s.remove = function(self, section)
    -- 不立即删除，让用户点击"保存&应用"时才生效
    TypedSection.remove(self, section)
    
    -- 删除关联的规则
    m.uci:foreach(qos_config, "upload_rule", function(rule)
        if rule.class == section then
            m.uci:delete(qos_config, rule[".name"])
        end
    end)
    
    return true
end

-- 分类表格列
o = s:option(DummyValue, "name", translate("Class Name"))
o.cfgvalue = function(self, section)
    return Value.cfgvalue(self, section) or translate("None")
end

o = s:option(DummyValue, "priority", translate("Priority"))
o.cfgvalue = function(self, section)
    local v = tonumber(Value.cfgvalue(self, section)) or 1
    return v
end

o = s:option(DummyValue, "percent_bandwidth", translate("Percent"))
o.cfgvalue = function(self, section)
    local v = tonumber(Value.cfgvalue(self, section))
    return v and ("%d%%" % v) or "-"
end

o = s:option(DummyValue, "min_bandwidth", translate("Min (kbps)"))
o.cfgvalue = function(self, section)
    local v = tonumber(Value.cfgvalue(self, section))
    return v or "0"
end

o = s:option(DummyValue, "max_bandwidth", translate("Max (kbps)"))
o.cfgvalue = function(self, section)
    local v = tonumber(Value.cfgvalue(self, section))
    if v and v > 0 then
        return v
    end
    return translate("Unlimited")
end

-- 负载显示
o = s:option(DummyValue, "description", translate("Description"))
o.cfgvalue = function(self, section)
    return Value.cfgvalue(self, section) or "-"
end

o = s:option(DummyValue, "_ld", "%s (kbps)" % translate("Load"))
o.rawhtml = true
o.value   = "0 kbps"

-- 2. 分类规则部分
local r = m:section(TypedSection, "upload_rule", translate("Classification Rules"),
    translate("Packets are tested against the rules in the order specified -- rules toward the top "
    .. "have priority. As soon as a packet matches a rule it is classified, and the rest of the rules "
    .. "are ignored. The order of the rules can be altered using the arrow controls."))

r.addremove = true
r.template  = "cbi/tblsection"
r.sortable  = true
r.anonymous = true
r.extedit   = dsp.build_url("admin/qos/qos_gargoyle/upload/rule/%s")

r.create = function(self, section)
    local new_sname = create_rule()
    http.redirect(self.extedit % new_sname)
    return new_sname
end

r.remove = function(self, section)
    TypedSection.remove(self, section)
    return true
end

-- 规则表格列
o = r:option(ListValue, "class", translate("Service Class"))
for _, cls in ipairs(upload_classes) do 
    o:value(cls.name, cls.alias) 
end

o = r:option(Value, "proto", translate("Protocol"))
o:value("", translate("All"))
o:value("tcp", "TCP")
o:value("udp", "UDP")
o:value("icmp", "ICMP")
o:value("gre", "GRE")
o.size = 10
o.cfgvalue = function(self, section)
    local v = Value.cfgvalue(self, section)
    return v and v:upper() or ""
end
o.write = function(self, section, value)
    Value.write(self, section, value:lower())
end

o = r:option(Value, "source", translate("Source IP"))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

o = r:option(Value, "srcport", translate("Source Port"))
o:value("", translate("All"))
o.datatype = "string"

o = r:option(Value, "destination", translate("Dest IP"))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

o = r:option(Value, "dstport", translate("Dest Port"))
o:value("", translate("All"))
o.datatype = "string"

o = r:option(DummyValue, "min_pkt_size", translate("Min Packet"))
o.cfgvalue = function(self, section)
    local v = tonumber(Value.cfgvalue(self, section))
    return v and wa.byte_format(v) or "-"
end

o = r:option(DummyValue, "max_pkt_size", translate("Max Packet"))
o.cfgvalue = function(self, section)
    local v = tonumber(Value.cfgvalue(self, section))
    return v and wa.byte_format(v) or "-"
end

o = r:option(DummyValue, "connbytes_kb", translate("Conn Bytes"))
o.cfgvalue = function(self, section)
    local v = Value.cfgvalue(self, section)
    return v or "-"
end

if qos.has_ndpi() then
    o = r:option(DummyValue, "ndpi", translate("DPI"))
    o.cfgvalue = function(self, section)
        local v = Value.cfgvalue(self, section)
        return v and v:upper() or translate("All")
    end
end

o = r:option(DummyValue, "description", translate("Description"))
o.cfgvalue = function(self, section)
    local v = Value.cfgvalue(self, section)
    return v or "-"
end

-- 3. 修复排序和保存
function m.on_before_commit(self)
    -- 自动排序分类
    local classes = {}
    m.uci:foreach(qos_config, "upload_class", function(s)
        table.insert(classes, s[".name"])
    end)
    
    for i, class in ipairs(classes) do
        m.uci:set(qos_config, class, "priority", i)
    end
    
    -- 自动排序规则，从5开始
    local rules = {}
    m.uci:foreach(qos_config, "upload_rule", function(s)
        table.insert(rules, s[".name"])
    end)
    
    -- 按当前顺序排序
    for i, rule in ipairs(rules) do
        -- 修复3: 从*5开始排序
        m.uci:set(qos_config, rule, "test_order", i * 5)
    end
    
    return true
end

-- 修复4: 添加页面渲染前的处理
function m.on_before_render(self)
    -- 确保页面加载时保存临时数据
    m.uci:save(qos_config)
    return true
end

-- 修复5: 添加取消处理
function m.on_cancel(self)
    -- 当用户取消时，回滚未保存的更改
    m.uci:revert(qos_config)
    http.redirect(dsp.build_url("admin/qos/qos_gargoyle"))
    return false
end

return m