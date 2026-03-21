-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

module("luci.controller.qos_gargoyle", package.seeall)

local util = require "luci.util"
local http = require "luci.http"
local uci = require "luci.model.uci"
local sys = require "luci.sys"

function index()
    if not nixio.fs.access("/etc/config/qos_gargoyle") then
        return
    end

    entry({"admin","qos"}, firstchild(), "QOS", 85).dependent = false
    entry({"admin", "qos", "qos_gargoyle"},
        firstchild(), _("Gargoyle QoS"), 60)

    entry({"admin", "qos", "qos_gargoyle", "global"},
        cbi("qos_gargoyle/global"), _("Global Settings"), 10)
	
	entry({"admin", "qos", "qos_gargoyle", "algorithm"}, 
	    cbi("qos_gargoyle/algorithm"), _("Algorithm Settings"), 20)

    entry({"admin", "qos", "qos_gargoyle", "upload"},
        cbi("qos_gargoyle/upload"), _("Upload Settings"), 30)

    entry({"admin", "qos", "qos_gargoyle", "upload", "class"},
        cbi("qos_gargoyle/upload_class")).leaf = true

    entry({"admin", "qos", "qos_gargoyle", "upload", "rule"},
        cbi("qos_gargoyle/upload_rule")).leaf = true

    entry({"admin", "qos", "qos_gargoyle", "download"},
        cbi("qos_gargoyle/download"), _("Download Settings"), 40)

    entry({"admin", "qos", "qos_gargoyle", "download", "class"},
        cbi("qos_gargoyle/download_class")).leaf = true

    entry({"admin", "qos", "qos_gargoyle", "download", "rule"},
        cbi("qos_gargoyle/download_rule")).leaf = true

    entry({"admin", "network", "qos_gargoyle", "ruleset_manager"}, 
	    cbi("qos_gargoyle/ruleset_manager"), _("Ruleset Manager"), 50)
		
	    entry({"admin", "network", "qos_gargoyle", "custom_nftrule"}, 
	    cbi("qos_gargoyle/custom_nftrule"), _("Custom Nftrule"), 60)
		
	entry({"admin", "network", "qos_gargoyle", "ratelimit"}, 
	    cbi("qos_gargoyle/ratelimit"), _("Rate Limit"), 70)
		
	entry({"admin", "qos", "qos_gargoyle", "acc"},
        cbi("qos_gargoyle/acc"), _("Active Congestion Control"), 80)

    entry({"admin", "qos", "qos_gargoyle", "show_status"},
        template("qos_gargoyle/show_status"), _("Show Status"), 90)

    entry({"admin", "qos", "qos_gargoyle", "show_status", "data"},
        call("action_show_status_data"))

    entry({"admin", "qos", "qos_gargoyle", "load_data"},
        call("action_load_data")).leaf = true
    
    -- 状态检查
    entry({"admin", "qos", "qos_gargoyle", "status"},
        call("action_status"), nil).leaf = true
end

-- 状态检查
function action_status()
    local cursor = uci.cursor()
    local enabled = cursor:get("qos_gargoyle", "global", "enabled") or "0"
    local running = sys.call("/etc/init.d/qos_gargoyle enabled 2>/dev/null") == 0
    
    http.prepare_content("application/json")
    http.write_json({
        enabled = enabled,
        running = running,
        config_enabled = enabled
    })
end

function action_show_status_data()
    local cursor = uci.cursor()
    local i18n = require "luci.i18n"

    local data = {}

    local accenabled = cursor:get("qos_gargoyle", "qosacc", "enabled") or "0"
	
    local show_data = util.trim(util.exec("/etc/init.d/qos_gargoyle show 2>/dev/null"))
    if show_data == "" then
        show_data = i18n.translate("No data found")
    end

    data.show = show_data

    local acc_data
	if accenabled == "1" then
        acc_data = util.trim(util.exec("cat /tmp/qosacc.status 2>/dev/null"))

        if acc_data == "" then
            acc_data = i18n.translate("No data found")
        end
    else
        acc_data = i18n.translate("\"Active Congestion Control\" not enabled")
    end

    data.acc = acc_data

    http.prepare_content("application/json")
    http.write_json(data)
end

-- 负载显示
function action_load_data(type)
    local device
    if type == "download" then
        device = "ifb0"
    elseif type == "upload" then
        local qos = require "luci.model.qos_gargoyle"
        local wan = qos.get_wan()
       device = wan and wan:ifname() or ""
    end

    if device and device ~= "" then
        local data = util.exec("tc -s class show dev " .. device .. " 2>/dev/null")
        http.prepare_content("text/plain")
        http.write(data or "")
    else
        http.prepare_content("text/plain")
        http.write("")
    end
end
