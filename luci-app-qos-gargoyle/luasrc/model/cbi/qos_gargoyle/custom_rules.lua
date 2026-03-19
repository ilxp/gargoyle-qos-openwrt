-- /usr/lib/lua/luci/model/cbi/qos_gargoyle/custom_rules.lua
local m = Map("qos_gargoyle", translate("Custom Rule Management"),
              translate("Edit and create custom rule files. Changes in the editor are temporary; use 'Save As' to create a new file."))

local ruleset_dir = "/etc/qos_gargoyle/rulesets"
os.execute("mkdir -p " .. ruleset_dir)

local current_ruleset = m:get("global", "ruleset") or "default.conf"

-- 获取所有自定义规则文件
local ruleset_files = {}
if nixio.fs.access(ruleset_dir) then
    for f in nixio.fs.dir(ruleset_dir) do
        if f:match("%.conf$") then
            table.insert(ruleset_files, f)
        end
    end
else
    table.insert(ruleset_files, "default.conf")
end
table.sort(ruleset_files)

-- 自定义规则选择下拉框
local select_section = m:section(SimpleSection, translate("Select Custom Rule"))
local select_list = select_section:option(ListValue, "_ruleset_select", translate("Custom Rule"))
for _, f in ipairs(ruleset_files) do
    select_list:value(f, f)
end
select_list.default = current_ruleset

-- 重新加载按钮（从选中文件加载内容到文本框）
local reload_btn = select_section:option(Button, "_reload")
reload_btn.inputtitle = translate("Reload")
reload_btn.inputstyle = "reload"
reload_btn.write = function()
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_gargoyle/custom_rules"))
end

-- 文本编辑区（无自动保存，仅显示当前选中文件内容）
local edit_section = m:section(SimpleSection, translate("Edit Custom Rule"))
local content = edit_section:option(TextValue, "_content", translate("Rule Content"))
content.rows = 30
content.wrap = "off"
content.cfgvalue = function(self, section)
    local selected = select_list:formvalue("_ruleset_select") or select_list.default
    local file = ruleset_dir .. "/" .. selected
    if nixio.fs.access(file) then
        return nixio.fs.readfile(file) or ""
    else
        return ""
    end
end
-- 不定义 write 函数，防止自动保存覆盖原文件

-- 另存为新自定义规则
local save_section = m:section(SimpleSection, translate("Save As New Custom Rule"))
local new_name = save_section:option(Value, "_new_name", translate("New filename"))
new_name.default = ""
new_name.description = translate("Enter a new filename (e.g., myrules.conf).")

local save_btn = save_section:option(Button, "_save_as")
save_btn.inputtitle = translate("Save As")
save_btn.inputstyle = "apply"
save_btn.write = function()
    local new = new_name:formvalue("_new_name")
    if not new or #new == 0 then
        m.message = translate("Please enter a filename.")
        return
    end
    if not new:match("%.conf$") then new = new .. ".conf" end
    -- 清理文件名，只允许安全字符
    new = new:gsub("[^a-zA-Z0-9_%-%.]", "")
    local target = ruleset_dir .. "/" .. new
    if nixio.fs.access(target) then
        m.message = translate("File already exists!")
        return
    end
    local content = luci.http.formvalue("_content")
    if not content or #content == 0 then
        m.message = translate("Content is empty.")
        return
    end
    if nixio.fs.writefile(target, content) then
        m.message = translate("Saved as ") .. new
        -- 重定向以刷新下拉列表
        luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_gargoyle/custom_rules"))
    else
        m.message = translate("Failed to save file.")
    end
end

return m