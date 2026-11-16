--[[
imeplus.koplugin — 拼音输入增强：数字选字 / ←/→ 翻页 / 模糊拼音 / 记忆常用词（简拼）

接管方式：启动时把 require("ui/data/keyboardlayouts/generic_ime") 重定向到插件自带的
引擎副本 ime_engine.lua（stock v2025.10 快照 + 功能补丁），系统文件零改动。
系统引擎版本不符时自动放弃接管，回退原生输入法。

新增行为只对拼音布局生效（switch_char == "→"；越南语/笔画布局不受影响）。
与其它拼音增强插件（pinyin_enhancement / pinyinplus / pinyinime）不可同时启用。
]]

local logger = require("logger")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local Screen = Device.screen

local ENGINE_MODULE = "ui/data/keyboardlayouts/generic_ime"
local STOCK_FILE = "frontend/ui/data/keyboardlayouts/generic_ime.lua"
local STOCK_SIZE = 15741 -- bytes, KOReader v2025.10

-- Only take over when the system engine matches the version the patched copy was made from.
local function systemEngineCompatible()
    local f = io.open(STOCK_FILE, "rb")
    if not f then
        return false, "cannot open " .. STOCK_FILE
    end
    local size = f:seek("end")
    f:close()
    if size ~= STOCK_SIZE then
        return false, string.format("size mismatch: got %d, want %d", size, STOCK_SIZE)
    end
    local g = io.open(STOCK_FILE, "rb")
    local data = g:read("*a")
    g:close()
    if not data:find("function IME:wrappedDelChar", 1, true)
        or not data:find("function IME:getCandidates", 1, true) then
        return false, "marker mismatch"
    end
    return true
end

local took_over = false
local takeover_reason

local ok, err = pcall(function()
    local compatible, why = systemEngineCompatible()
    if compatible then
        package.preload[ENGINE_MODULE] = function()
            return dofile("plugins/imeplus.koplugin/ime_engine.lua")
        end
        took_over = true
    else
        takeover_reason = why
    end
end)
if not ok then
    takeover_reason = err
end
if not took_over then
    logger.warn("imeplus: engine takeover skipped (" .. tostring(takeover_reason) .. "), stock IME stays")
else
    -- insert_menu is KOReader's official singleton for non-core plugins to join the
    -- more_tools order tables (both reader and filemanager) without touching system files.
    pcall(function() require("ui/plugin/insert_menu").add("imeplus") end)
end

local ImePlus = WidgetContainer:extend{
    name = "imeplus",
}

local CUSTOM_WORDS_FILE = "plugins/imeplus.koplugin/custom_words.lua"

-- Read the custom-words file and render it as editable text: one word per line,
-- optionally "word code" giving the word's own input code (any lowercase letters,
-- e.g. "一闪一闪亮晶晶 ysys"). Non-parseable entries are kept as-is so a
-- hand-written Lua file is not silently destroyed.
local function loadCustomWordsAsText()
    local ok, entries = pcall(dofile, CUSTOM_WORDS_FILE)
    if not ok or type(entries) ~= "table" then return "" end
    local lines = {}
    for _, e in ipairs(entries) do
        if type(e) == "string" then
            lines[#lines+1] = e
        elseif type(e) == "table" and type(e[1]) == "string" then
            lines[#lines+1] = e[2] and (e[1] .. " " .. e[2]) or e[1]
        end
    end
    return table.concat(lines, "\n")
end

-- Parse edited text back into the Lua table format and write the file.
-- Line forms: "word" or "word code"; comment (#) and empty lines ignored.
local function saveCustomWordsFromText(text)
    local lines = { "return {" }
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local word, pinyin = line:match("^(%S+)%s+(%S+)$")
            if not word then word = line:match("^(%S+)$") end
            if word then
                if pinyin then
                    lines[#lines+1] = string.format('    { %q, %q },', word, pinyin)
                else
                    lines[#lines+1] = string.format('    %q,', word)
                end
            end
        end
    end
    lines[#lines+1] = "}"
    local f = io.open(CUSTOM_WORDS_FILE, "w")
    if not f then return false end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    return true
end

function ImePlus:editCustomWords()
    local InputDialog = require("ui/widget/inputdialog")
    -- search state: last query + index, so tapping 查找 again cycles matches
    local search_query, search_from = nil, 0
    local dialog
    -- move the editor cursor to the next match of search_query (cycling); the
    -- TextBoxWidget scrolls to the caret automatically. Returns match count used.
    local function jumpToMatch(from)
        local text = dialog:getInputText()
        local pos = nil
        local start = from or 1
        while true do
            local s, e = text:find(search_query, start, true)
            if not s then break end
            pos = s
            break
        end
        if not pos then return false end
        -- the cursor is a charlist index: count UTF-8 chars before the match
        local charpos = 1
        local i = 1
        while i < pos do
            local b = text:byte(i)
            local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
            charpos = charpos + 1
            i = i + len
        end
        local input_widget = dialog._input_widget
        if input_widget and input_widget.text_widget then
            input_widget.charpos = charpos
            input_widget.text_widget:moveCursorToCharPos(charpos)
            input_widget:resyncPos()
        end
        return true
    end
    dialog = InputDialog:new{
        title = _("自定义词组表"),
        description = _("每行一个词：纯中文词省略输入码时自动生成简拼（各字声母）；也可自己指定输入码，如「一闪一闪亮晶晶 ysys」。英文词组/网址/混合词必须给码，如「http://www.baidu.com bd」「K8手机壳 k8sjk」。# 开头的行是注释。保存后，下次打开键盘生效。"),
        input = loadCustomWordsAsText(),
        input_type = "text",
        multiline = true,
        allow_newline = true, -- Enter inserts "\n" instead of confirming the dialog
        text_height = math.floor(Screen:getHeight() * 0.4),
        buttons = {
            {
                {
                    text = _("查找"),
                    callback = function()
                        local SearchDialog = require("ui/widget/inputdialog")
                        local search_dialog
                        search_dialog = SearchDialog:new{
                            title = _("查找词组"),
                            input = search_query or "",
                            input_type = "text",
                            buttons = {
                                {
                                    {
                                        text = _("取消"),
                                        callback = function()
                                            UIManager:close(search_dialog)
                                        end,
                                    },
                                    {
                                        text = _("查找下一个"),
                                        callback = function()
                                            search_query = search_dialog:getInputText()
                                            if not search_query or search_query == "" then
                                                UIManager:close(search_dialog)
                                                return
                                            end
                                            -- search from just after the caret, wrap around
                                            local input_widget = dialog._input_widget
                                            local text = dialog:getInputText()
                                            local caret_byte = 1
                                            if input_widget and input_widget.charpos then
                                                -- convert charpos back to a byte offset
                                                local n = input_widget.charpos - 1
                                                local i = 1
                                                while n > 0 and i <= #text do
                                                    local b = text:byte(i)
                                                    local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
                                                    i = i + len
                                                    n = n - 1
                                                end
                                                caret_byte = i
                                            end
                                            UIManager:close(search_dialog)
                                            local from = (search_from or 0) >= 1 and caret_byte or 1
                                            local ok = jumpToMatch(from)
                                            if not ok then
                                                ok = jumpToMatch(1) -- wrap around
                                            end
                                            if not ok then
                                                UIManager:show(InfoMessage:new{
                                                    text = _("未找到：") .. search_query,
                                                    timeout = 2,
                                                })
                                            else
                                                search_from = 1
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(search_dialog)
                        search_dialog:onShowKeyboard()
                    end,
                    keep_menu_open = true,
                },
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    callback = function()
                        local text = dialog:getInputText()
                        if saveCustomWordsFromText(text) then
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{
                                text = _("已保存自定义词组表。下次打开键盘生效。"),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("保存失败：无法写入 custom_words.lua。"),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ImePlus:init()
    -- v2026.07: a plugin instance must register itself into the menu's widget list,
    -- otherwise addToMainMenu is never called and the menu item never appears.
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function ImePlus:addToMainMenu(menu_items)
    if not took_over then return end

    -- Fuzzy rules submenu built from the engine's single source of truth.
    local ok_engine, engine = pcall(require, ENGINE_MODULE)
    local presets = ok_engine and engine.fuzzy_presets or {}
    local rule_items = {}
    for _, p in ipairs(presets) do
        local id, label, default = p.id, p.label, p.default == true
        rule_items[#rule_items+1] = {
            text = label,
            checked_func = function()
                local saved = G_reader_settings:readSetting("imeplus_fuzzy_rules")
                if saved then return saved[id] == true end
                return default
            end,
            callback = function()
                -- materialize the full map on first toggle so absent = off
                local saved = G_reader_settings:readSetting("imeplus_fuzzy_rules")
                if not saved then
                    saved = {}
                    for _, q in ipairs(presets) do saved[q.id] = q.default == true end
                end
                saved[id] = not (saved[id] == true)
                G_reader_settings:saveSetting("imeplus_fuzzy_rules", saved)
            end,
            keep_menu_open = true,
        }
    end

    menu_items.imeplus = {
        text = _("拼音输入增强"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("模糊拼音"),
                checked_func = function()
                    return G_reader_settings:readSetting("imeplus_fuzzy", true)
                end,
                callback = function()
                    local new_value = not G_reader_settings:readSetting("imeplus_fuzzy", true)
                    G_reader_settings:saveSetting("imeplus_fuzzy", new_value)
                end,
                keep_menu_open = true,
            },
            {
                text = _("模糊规则"),
                sub_item_table = rule_items,
            },
            {
                text = _("记忆常用词"),
                checked_func = function()
                    return G_reader_settings:readSetting("imeplus_learn", true)
                end,
                callback = function()
                    local new_value = not G_reader_settings:readSetting("imeplus_learn", true)
                    G_reader_settings:saveSetting("imeplus_learn", new_value)
                end,
                keep_menu_open = true,
            },
            {
                text = _("自定义词组表"),
                callback = function()
                    self:editCustomWords()
                end,
                keep_menu_open = true,
            },
            {
                text = _("清空记忆词"),
                callback = function()
                    G_reader_settings:saveSetting("imeplus_user_words", {})
                    UIManager:show(InfoMessage:new{
                        text = _("已清空记忆词。上屏过的词不再参与简拼候选。"),
                        timeout = 3,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("关于"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("拼音输入增强：候选带数字编号、数字键选字、←/→ 翻页、模糊拼音（规则可自定义）、记忆词简拼、自定义词组表、v 模式（输入 v 后直接输出半角英文，如 vbing 出 bing）。不修改系统文件。"),
                        timeout = 10,
                    })
                end,
            },
        },
    }
end

return ImePlus
