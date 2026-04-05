-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

module("luci.controller.qos_gargoyle", package.seeall)

local util = require "luci.util"
local http = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local _ = require "luci.i18n".translate

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
		
	-- 添加自定义规则页面
    entry({"admin", "qos", "qos_gargoyle", "custom_rules"}, 
		call("action_custom_rules"), _("Custom Rules"), 50)
    
	entry({"admin", "qos", "qos_gargoyle", "ruleset_edit"},
        call("action_ruleset_edit"), _("Ruleset Management"), 60)
		
	-- IP限速页面
	entry({"admin", "qos", "qos_gargoyle", "ratelimit"}, 
		call("action_ratelimit"), _("Rate Limit"), 70)
		
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

function action_custom_rules()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local util = require "luci.util"
    local http = require "luci.http"
    local template = require "luci.template"

    -- 定义文件路径
    local egress_file = "/etc/qos_gargoyle/egress_custom.nft"
    local ingress_file = "/etc/qos_gargoyle/ingress_custom.nft"
    local full_table_file = "/etc/qos_gargoyle/custom_rules.nft"

    -- 确保目录存在
    os.execute("mkdir -p /etc/qos_gargoyle")

    -- 读取现有内容
    local egress_content = fs.readfile(egress_file) or ""
    local ingress_content = fs.readfile(ingress_file) or ""
    local full_table_content = fs.readfile(full_table_file) or ""

    -- 设置响应头为 UTF-8
    http.prepare_content("text/html; charset=utf-8")

    -- 处理表单提交（保存或保存并应用）
    local save = http.formvalue("cbi.save")
    local apply = http.formvalue("cbi.apply")
    if save or apply then
        local new_egress = http.formvalue("egress_rules") or ""
        local new_ingress = http.formvalue("ingress_rules") or ""
        local new_full_table = http.formvalue("full_table_rules") or ""

        -- 写入文件
        fs.writefile(egress_file, new_egress)
        fs.writefile(ingress_file, new_ingress)
        fs.writefile(full_table_file, new_full_table)

        if apply then
            -- 保存并应用：重启服务
            sys.call("/etc/init.d/qos_gargoyle restart >/dev/null 2>&1")
            local message = _("Custom rules saved and QoS restarted.")
            luci.template.render("qos_gargoyle/custom_rules_result", {
                success = true,
                message = message
            })
        else
            -- 仅保存：不重启
            local message = _("Custom rules saved. QoS not restarted.")
            luci.template.render("qos_gargoyle/custom_rules_result", {
                success = true,
                message = message
            })
        end
        return
    end

    -- 正常显示表单
    local data = {
        egress = egress_content,
        ingress = ingress_content,
        full_table = full_table_content,
    }
	local sections = {} 
    luci.template.render("qos_gargoyle/custom_rules", data)
end

function action_ratelimit()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local util = require "luci.util"
    local http = require "luci.http"
    local template = require "luci.template"
    local uci = require "luci.model.uci".cursor()
    local _ = require "luci.i18n".translate

    http.prepare_content("text/html; charset=utf-8")

    local save = http.formvalue("cbi.save")
    local apply = http.formvalue("cbi.apply")
    if save or apply then
        -- 获取所有节 ID，可能为字符串或表
        local sections = http.formvalue("cbi.sections")
        if type(sections) ~= "table" then
            sections = sections and { sections } or {}
        end

        for _, sid in ipairs(sections) do
            local name = http.formvalue("cbi.name." .. sid)
            local enabled = http.formvalue("cbi.enabled." .. sid)
            local download_limit = http.formvalue("cbi.download_limit." .. sid)
            local upload_limit = http.formvalue("cbi.upload_limit." .. sid)
            local burst_factor = http.formvalue("cbi.burst_factor." .. sid)
            local target = http.formvalue("cbi.target." .. sid)

            if target then
                if type(target) ~= "table" then
                    target = { target }
                end
                for i, v in ipairs(target) do
                    target[i] = v:gsub("^%s*(.-)%s*$", "%1")
                end
            else
                target = {}
            end

            if sid == "new" then
                local new_sid = uci:add("qos_gargoyle", "ratelimit")
                sid = new_sid
            end

            uci:set("qos_gargoyle", sid, "name", name)
            uci:set("qos_gargoyle", sid, "enabled", enabled == "1" and "1" or "0")
            uci:set("qos_gargoyle", sid, "download_limit", download_limit)
            uci:set("qos_gargoyle", sid, "upload_limit", upload_limit)
            uci:set("qos_gargoyle", sid, "burst_factor", burst_factor)
            uci:set("qos_gargoyle", sid, "target", target)
        end

        -- 处理删除
        local deletes = http.formvalue("cbi.delete")
        if type(deletes) ~= "table" then
            deletes = deletes and { deletes } or {}
        end
        for _, sid in ipairs(deletes) do
            uci:delete("qos_gargoyle", sid)
        end

        uci:commit("qos_gargoyle")

        if apply then
            sys.call("/etc/init.d/qos_gargoyle restart >/dev/null 2>&1")
            local message = _("Rate limit rules saved and QoS restarted.")
            luci.template.render("qos_gargoyle/ratelimit_result", { success = true, message = message })
        else
            local message = _("Rate limit rules saved. QoS not restarted.")
            luci.template.render("qos_gargoyle/ratelimit_result", { success = true, message = message })
        end
        return
    end

    -- 正常显示表单
    local sections = {}
    uci:foreach("qos_gargoyle", "ratelimit", function(s)
        local name = s.name or ""
        local enabled = s.enabled or "1"
        local download_limit = s.download_limit or ""
        local upload_limit = s.upload_limit or ""
        local burst_factor = s.burst_factor or ""
        local target = s.target or {}
        if type(target) == "table" then
            target = table.concat(target, ",")
        end
        sections[#sections+1] = {
            sid = s[".name"],
            name = name,
            enabled = enabled,
            download_limit = download_limit,
            upload_limit = upload_limit,
            burst_factor = burst_factor,
            target = target,
        }
    end)

    luci.template.render("qos_gargoyle/ratelimit", { sections = sections })
end

function action_ruleset_edit()
    local fs = require "nixio.fs"
    local util = require "luci.util"
    local http = require "luci.http"
    local template = require "luci.template"
    local dispatcher = require "luci.dispatcher"
    local _ = require "luci.i18n".translate

    local ruleset_dir = "/etc/qos_gargoyle/rulesets"
    local default_file = "default.ru"
    local default_content = [[
# Default rule set
# Add your classification rules here
# Format: config upload_rule 'rule_name' ...
]]

    -- 确保目录存在且可写
    if not fs.access(ruleset_dir) then
        fs.mkdir(ruleset_dir)
    end
    if not fs.access(ruleset_dir, "w") then
        luci.template.render("qos_gargoyle/ruleset_edit_result", {
            success = false,
            message = _("Directory is not writable: ") .. ruleset_dir
        })
        return
    end

    -- 确保 default.ru 存在
    local default_path = ruleset_dir .. "/" .. default_file
    if not fs.access(default_path) then
        fs.writefile(default_path, default_content)
    end

    -- 获取所有 .ru 文件列表
    local files = {}
    for f in fs.dir(ruleset_dir) do
        if f:match("%.ru$") then
            files[#files+1] = f
        end
    end
    table.sort(files)

    -- 安全文件名验证函数（允许字母数字、点、下划线、短横线，禁止路径分隔符和双点）
    local function safe_filename(name)
        if not name or name == "" then return false end
        -- 去除首尾空白和换行
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name:find("[\\/]") or name:find("%.%.") or name:find("%z") then
            return false
        end
        if name:match("^[a-zA-Z0-9_.-]+$") then
            return true
        end
        return false
    end

    -- 获取当前编辑的文件名
    local cur_file = http.formvalue("file")
    if not cur_file or cur_file == "" then
        cur_file = luci.http.getcookie("qos_gargoyle_ruleset_file") or default_file
    end
    if not safe_filename(cur_file) then
        cur_file = default_file
    end
    local cur_path = ruleset_dir .. "/" .. cur_file
    if not fs.access(cur_path) then
        cur_file = default_file
        cur_path = ruleset_dir .. "/" .. cur_file
    end

    -- 清理旧备份
    local function clean_old_backups(base_name)
        local keep = 5
        local backups = {}
        local pattern = "^" .. base_name:gsub("%.", "%%.") .. "%.bak%.[0-9]+$"
        for f in fs.dir(ruleset_dir) do
            if f:match(pattern) then
                backups[#backups+1] = f
            end
        end
        table.sort(backups)
        while #backups > keep do
            fs.unlink(ruleset_dir .. "/" .. backups[1])
            table.remove(backups, 1)
        end
    end

    -- 安全写入文件函数（使用 io.open 捕获错误，并验证写入结果）
    local function safe_write_file(path, content)
        -- 记录调试信息
        os.execute("logger -t qos_gargoyle 'DEBUG: Writing to " .. path .. "'")
        local fd, err = io.open(path, "w")
        if not fd then
            os.execute("logger -t qos_gargoyle 'ERROR: Failed to open file: " .. (err or "unknown") .. "'")
            return false, err
        end
        fd:write(content)
        fd:close()
        -- 验证文件是否真的被创建
        if fs.access(path) then
            os.execute("logger -t qos_gargoyle 'DEBUG: File successfully created: " .. path .. "'")
            return true, nil
        else
            os.execute("logger -t qos_gargoyle 'ERROR: File not found after write: " .. path .. "'")
            return false, "File not found after write"
        end
    end

    -- 处理保存或另存为
    local save = http.formvalue("cbi.save")
    local saveas = http.formvalue("cbi.saveas")
    if save or saveas then
        local content = http.formvalue("ruleset_content") or ""
        local target_path = cur_path
        local new_filename = nil

        if saveas then
            new_filename = http.formvalue("new_filename")
            if not new_filename or new_filename == "" then
                luci.template.render("qos_gargoyle/ruleset_edit_result", {
                    success = false,
                    message = _("New filename cannot be empty.")
                })
                return
            end
            -- 去除空白并验证
            new_filename = new_filename:gsub("^%s+", ""):gsub("%s+$", "")
            if not safe_filename(new_filename) then
                luci.template.render("qos_gargoyle/ruleset_edit_result", {
                    success = false,
                    message = _("Invalid filename. Use only letters, digits, dot, underscore, hyphen.")
                })
                return
            end
            if not new_filename:match("%.ru$") then
                new_filename = new_filename .. ".ru"
            end
            target_path = ruleset_dir .. "/" .. new_filename
            os.execute("logger -t qos_gargoyle 'DEBUG: SaveAs target_path = " .. target_path .. "'")
        end

        -- 备份目标文件（如果存在且内容不同）
        if fs.access(target_path) then
            local old_content = fs.readfile(target_path)
            if old_content and old_content ~= content then
                local timestamp = os.date("%Y%m%d%H%M%S")
                local backup_path = target_path .. ".bak." .. timestamp
                local ok, err = safe_write_file(backup_path, old_content)
                if not ok then
                    luci.template.render("qos_gargoyle/ruleset_edit_result", {
                        success = false,
                        message = _("Failed to create backup: ") .. err
                    })
                    return
                end
                if saveas then
                    clean_old_backups(new_filename)
                else
                    clean_old_backups(cur_file)
                end
            end
        end

        -- 写入新内容
        local ok, err = safe_write_file(target_path, content)
        if ok then
            if saveas then
                cur_file = new_filename
                cur_path = target_path
                http.header("Set-Cookie", "qos_gargoyle_ruleset_file=" .. cur_file .. "; path=/")
            end
            local back_url = dispatcher.build_url("admin", "qos", "qos_gargoyle", "ruleset_edit") .. "?file=" .. cur_file
            local msg = saveas and _("Ruleset saved as %s") % new_filename or _("Ruleset saved.")
            luci.template.render("qos_gargoyle/ruleset_edit_result", {
                success = true,
                message = msg,
                back_url = back_url
            })
        else
            os.execute("logger -t qos_gargoyle 'ERROR: Failed to write ruleset file: " .. target_path .. " - " .. (err or "unknown") .. "'")
            luci.template.render("qos_gargoyle/ruleset_edit_result", {
                success = false,
                message = _("Failed to write file: ") .. (err or _("unknown error"))
            })
        end
        return
    end

    -- 读取当前文件内容
    local content = fs.readfile(cur_path) or ""

    -- 渲染模板
    luci.template.render("qos_gargoyle/ruleset_edit", {
        files = files,
        current_file = cur_file,
        content = content
    })
end