-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.

module("luci.model.qos_gargoyle", package.seeall)
local sys = require "luci.sys"

function has_ndpi()
	return luci.sys.call("lsmod | cut -d ' ' -f1 | grep -q 'xt_ndpi'") == 0
end

function cbi_add_dpi_protocols(field)
	local util = require "luci.util"

	local dpi_protocols = {}

	for line in util.execi("iptables -m ndpi --help 2>/dev/null | grep '^--'") do
		local _, _, protocol, name = line:find("%-%-([^%s]+) Match for ([^%s]+)")

		if protocol and name then
			dpi_protocols[protocol] = name
		end
	end

	for p, n in util.kspairs(dpi_protocols) do
		field:value(p, n)
	end
end

function get_wan()
    local net = require "luci.model.network"
    
    -- 尝试初始化网络模型
    local network = net.init()
    if not network then
        return nil
    end
    
    -- 获取所有WAN接口
    local wan_nets = network:get_wan_networks()
    if not wan_nets or #wan_nets == 0 then
        return nil
    end
    
    -- 选择第一个可用的WAN接口
    for _, wan in ipairs(wan_nets) do
        local ifname = wan:ifname()
        if ifname and ifname ~= "" then
            -- 检查接口是否存在
            local handle = io.popen("ip link show " .. ifname .. " 2>/dev/null")
            if handle then
                local result = handle:read("*a")
                handle:close()
                if result and result ~= "" then
                    return wan
                end
            end
        end
    end
    
    -- 如果没有找到可用的接口，返回第一个
    return wan_nets[1]
end
