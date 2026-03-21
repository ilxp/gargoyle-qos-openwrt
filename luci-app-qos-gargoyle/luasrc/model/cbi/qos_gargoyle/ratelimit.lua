local m, s, o
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"

-- 辅助验证函数
local function validate_target(value)
    if not value or value == "" then return true end
    local ipv4_cidr = "^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$"
    local ipv6_cidr = "^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?$"
    local set_ref = "^(!?@)[a-zA-Z0-9_]+$"
    local values = value:split("%s+")
    for _, v in ipairs(values) do
        if not v:match(ipv4_cidr) and not v:match(ipv6_cidr) and not v:match(set_ref) then
            return false, luci.i18n.translate("Invalid target format: %s (expected IP, CIDR, or @setname)").format(v)
        end
    end
    return true
end

m = Map("qos_gargoyle", luci.i18n.translate("QoS Gargoyle - Rate Limits"),
    luci.i18n.translate("Configure per-device bandwidth limits using nftables meters. Limits are applied based on the source IP of devices."))

s = m:section(TypedSection, "ratelimit", luci.i18n.translate("Rate Limits"))
s.addremove = true
s.anonymous = true
s.sortable = true

-- 名称
o = s:option(Value, "name", luci.i18n.translate("Name"))
o.rmempty = false
o.placeholder = "e.g., Guest Network Limit"

-- 目标设备
o = s:option(DynamicList, "target", luci.i18n.translate("Target Devices"))
o.rmempty = false
o.placeholder = "192.168.1.100, !=192.168.1.77, 2001:db8::1, @my_set"
o.validate = validate_target
o.description = luci.i18n.translate("IP/IPv6/CIDR addresses and subnets only. Exclusions: !=192.168.1.77, IP Sets: @vip_guests")

-- 启用
o = s:option(Flag, "enabled", luci.i18n.translate("Enabled"))
o.default = "1"

-- 下载限制 (Kbit/s)
o = s:option(Value, "download_limit", luci.i18n.translate("Download Limit (Kbit/s)"))
o.datatype = "uinteger"
o.placeholder = "10000"
o.default = "10000"
o.validate = function(self, value)
    local v = tonumber(value)
    if not v then return true end
    if v < 0 or v > 100000000 then
        return luci.i18n.translate("Must be between 0 and 100000000 Kbit/s")
    end
    return true
end
o.description = luci.i18n.translate("Traffic TO device. 0 = unlimited")

-- 上传限制 (Kbit/s)
o = s:option(Value, "upload_limit", luci.i18n.translate("Upload Limit (Kbit/s)"))
o.datatype = "uinteger"
o.placeholder = "10000"
o.default = "10000"
o.validate = function(self, value)
    local v = tonumber(value)
    if not v then return true end
    if v < 0 or v > 100000000 then
        return luci.i18n.translate("Must be between 0 and 100000000 Kbit/s")
    end
    return true
end
o.description = luci.i18n.translate("Traffic FROM device. 0 = unlimited")

-- 突发因子
o = s:option(Value, "burst_factor", luci.i18n.translate("Burst Factor"))
o.placeholder = "1.0"
o.default = "1.0"
o.validate = function(self, value)
    if not value or value == "" then return true end
    if not value:match("^[0-9,%.]+$") then
        return luci.i18n.translate("Only digits and decimal separators allowed")
    end
    local norm = value:gsub(",", ".")
    local num = tonumber(norm)
    if not num or num < 0 or num > 10 then
        return luci.i18n.translate("Must be between 0.0 and 10.0 (0 = no burst)")
    end
    return true
end
o.write = function(self, section, value)
    if value then
        value = value:gsub(",", ".")
    end
    return Value.write(self, section, value)
end
o.description = luci.i18n.translate("0 = no burst (strict), 1.0 = rate as burst, higher = more burst")

-- 模态框标题自定义
s.modaltitle = function(self, section)
    local name = uci:get("qos_gargoyle", section, "name")
    if name and name ~= "" then
        return luci.i18n.translate("Edit Rate Limit: %s").format(name)
    end
    return luci.i18n.translate("Add Rate Limit")
end

-- 保存后自动重启服务
function m.on_commit(self)
    -- 保存UCI配置后，重启QoS服务
    local ok, code = sys.call("/etc/init.d/qos_gargoyle restart")
    if code == 0 then
        luci.http.redirect(luci.dispatcher.build_url("admin", "network", "qos_gargoyle", "ratelimit"))
    else
        -- 如果重启失败，显示错误（可选）
    end
end

return m