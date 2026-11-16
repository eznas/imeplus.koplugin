---------------------------------
-- Generic input method engine --
---------------------------------
-- imeplus.koplugin: patched copy of stock generic_ime.lua (KOReader v2025.10, md5 3b85fda9).
-- Additions are gated by isPinyin() (zh_CN layout sets switch_char to "→"); all other
-- layouts (vi, stroke) keep stock behavior. Keep in sync with the system file (main.lua
-- checks size + markers before taking over).
local logger = require("logger")
local util = require("util")
local Utf8Proc = require("ffi/utf8proc")

-- imeplus: candidates per page (1 stage char + 8 numbered)
local PAGE = 9

-- imeplus: only the zh_CN pinyin layout drives the new behavior
local function isPinyin(ime)
    return ime.switch_char == "→"
end

-- imeplus: selectable fuzzy pinyin rules. Only the three retroflex/flat pairs
-- are on by default; the rest are opt-in from the plugin menu. Exported on the
-- IME table so main.lua builds the menu from the same list (single source).
local FUZZY_PRESETS = {
    { id = "zh_z",   from = "zh",  to = "z",   label = "zh / z",   default = true },
    { id = "ch_c",   from = "ch",  to = "c",   label = "ch / c",   default = true },
    { id = "sh_s",   from = "sh",  to = "s",   label = "sh / s",   default = true },
    { id = "n_l",    from = "n",   to = "l",   label = "n / l" },
    { id = "l_r",    from = "l",   to = "r",   label = "l / r" },
    { id = "an_ang", from = "an",  to = "ang", label = "an / ang" },
    { id = "en_eng", from = "en",  to = "eng", label = "en / eng" },
    { id = "in_ing", from = "in",  to = "ing", label = "in / ing" },
    { id = "f_h",    from = "f",   to = "h",   label = "f / h" },
}
-- ponytail: these three are pinyin facts (flat vs retroflex initials), used by
-- the abbreviation gate regardless of which fuzzy rules the user enabled.
local RETROFLEX = { z = "zh", c = "ch", s = "sh" }
local FUZZY_MAX_VARIANTS = 16

local function fuzzy_enabled()
    if G_reader_settings then
        return G_reader_settings:readSetting("imeplus_fuzzy", true)
    end
    return true
end

-- imeplus: build the bidirectional rule list from the settings map.
-- nil map = defaults (3 retroflex pairs on); an existing map is authoritative,
-- so rules absent from it are OFF (the menu writes every toggle explicitly).
local function activeFuzzyRules()
    local saved = G_reader_settings and G_reader_settings:readSetting("imeplus_fuzzy_rules")
    local rules = {}
    for _, p in ipairs(FUZZY_PRESETS) do
        local on
        if saved then on = saved[p.id] == true
        else on = p.default == true end
        if on then
            rules[#rules+1] = { p.from, p.to }
            rules[#rules+1] = { p.to, p.from }
        end
    end
    return rules
end

-- imeplus: self-learned words. A word committed once (typed fully or selected)
-- afterwards surfaces under its initials/loose code ("jiazai" once -> "jz" finds
-- 加载). Stored in G_reader_settings("imeplus_user_words"), persisted at exit.
local USER_WORDS_MAX = 200
local USER_CANDI_MAX = 8

local function learn_enabled()
    if G_reader_settings then
        return G_reader_settings:readSetting("imeplus_learn", true)
    end
    return false
end

-- Abbreviation match: the typed code is a first-letter-anchored subsequence of
-- the learned full pinyin ("jz" ~ "jiazai", "zhch" ~ "zhichi"). Three guards
-- keep partial/misspelled full pinyin out of the abbreviation pool:
--   * a plain prefix ("zh" for "zhichi") is only an abbreviation once it has
--     crossed the first syllable ("shenm"/"huoz" yes, "zh"/"gong" no);
--   * the second letter must be a consonant (either the next syllable's initial
--     or the "h" of zh/ch/sh) — a vowel there means the first syllable carries
--     rhyme, i.e. a broken full pinyin ("xuxi" for "xuexi"), not initials;
--   * the last match must land at position >= 3 (letters all inside the first
--     syllable, incl. words learned from a fuzzy typo "zichi" -> 支持).
-- imeplus: does a pure-prefix code reach PAST the first syllable? A stock table
-- key strictly shorter than the code marks a syllable boundary ("shen" in
-- "shenm", "huo" in "huoz", "zhi" in "zhic"); codes still inside syllable 1
-- ("zh", "gong", "bei") are partial spellings, not abbreviations. No new data:
-- the stock pinyin table already contains every full syllable as a key.
-- ponytail: zero-initial syllables ("ayi") can't be abbreviated this way.
local function crossedFirstSyllable(code, code_map)
    for i = 2, #code - 1 do
        if code_map[code:sub(1, i)] then return true end
    end
    return false
end

local function looseMatch(code, learned, code_map)
    if #code < 2 or #code > #learned then return false end
    if code:byte(1) ~= learned:byte(1) then return false end
    local is_prefix = learned:sub(1, #code) == code
    if is_prefix then
        -- a pure prefix is a valid abbreviation only past syllable 1
        return crossedFirstSyllable(code, code_map)
    end
    local second = code:byte(2)
    if second == 97 or second == 101 or second == 105 or second == 111
        or second == 117 or second == 118 then return false end -- a/e/i/o/u/v
    local i, last_pos = 2, 1
    for j = 2, #learned do
        if code:byte(i) == learned:byte(j) then
            last_pos = j
            i = i + 1
            if i > #code then return last_pos >= 3 end
        end
    end
    return false
end

-- imeplus: expand code into fuzzy variants (BFS over rule applications, capped & deduped)
local function fuzzy_variants(code, rules)
    rules = rules or activeFuzzyRules()
    local variants = {}
    local seen = { [code] = true }
    local queue = { code }
    while #queue > 0 and #variants < FUZZY_MAX_VARIANTS do
        local s = table.remove(queue)
        for _, rule in ipairs(rules) do
            local from, to = rule[1], rule[2]
            local pos = 1
            while true do
                local start = s:find(from, pos, true)
                if not start then break end
                local v = s:sub(1, start-1) .. to .. s:sub(start + #from)
                if not seen[v] then
                    seen[v] = true
                    variants[#variants+1] = v
                    if #variants >= FUZZY_MAX_VARIANTS then return variants end
                    queue[#queue+1] = v
                end
                pos = start + 1
            end
        end
    end
    return variants
end

-- imeplus: display width of a string in CJK-char units (CJK=1, ASCII=0.5)
local function textUnits(s)
    local w = 0
    for _, ch in ipairs(util.splitToChars(s)) do
        w = w + (ch:byte(1) >= 0xE0 and 1 or 0.5)
    end
    return w
end

-- imeplus: how many candidates fit in one page (incl. the stage char) given the
-- input field width, so wide word candidates never push the front of the line
-- out of view; falls back to PAGE when geometry is unknown.
local function visiblePageSize(imex, inputbox)
    local face_size = inputbox and inputbox.face and inputbox.face.size
    local box_w = inputbox and inputbox.width
    if not face_size or not box_w or box_w <= 0 then return PAGE end
    local pad = (inputbox.margin or 0) + (inputbox.bordersize or 0) + (inputbox.padding or 0)
    local avail = math.max(0, box_w - 2 * pad) / face_size - 2 -- cursor + rounding safety
    local units = textUnits(imex.char or "") + 1 -- stage chars + "[" "]"
    local last = math.min(imex.index + PAGE - 1, #imex.candi)
    local n = 0
    for i = imex.index + 1, last do
        local cand_units = 0.5 + textUnits(imex.candi[i])
        local truncated = i < last or last < #imex.candi
        local need = cand_units + (truncated and 0.5 or 0) -- room for the trailing "…"
        if units + need <= avail then
            units = units + cand_units
            n = n + 1
        else
            break
        end
    end
    return n + 1 -- the stage char counts as the first candidate of the page
end

local function binarysearch( tbl, value, fcompval, reversed )
    if not fcompval then return end
    local iStart,iEnd = 1,#tbl
    local iMid
    while iStart <= iEnd do
        iMid = math.floor( (iStart+iEnd)/2 )
        local value2 = fcompval( tbl[iMid] )
        if value == value2 then
            if iMid == 1 or fcompval( tbl[iMid-1] ) ~= value then
                return iMid
            end
            iEnd = iMid - 1
            while iStart <= iEnd do
                iMid = math.floor( (iStart+iEnd)/2 )
                value2 = fcompval( tbl[iMid] )
                if value2 == value then
                    if fcompval( tbl[iMid-1] ) ~= value then
                        return iMid
                    else
                        iEnd = iMid - 1
                    end
                else
                    if fcompval( tbl[iMid+1] ) == value then
                        return iMid + 1
                    else
                        iStart = iMid + 2
                    end
                end
            end
            return iMid
        elseif ( reversed and value2 < value ) or ( not reversed and value2 > value ) then
            iEnd = iMid - 1
        else
            iStart = iMid + 1
        end
    end
end

local function stringReplaceAt(str, pos, r)
    return str:sub(1, pos-1) .. r .. str:sub(pos+1)
end

local _stack
local IME = {
    code_map = nil, -- hash, mandatory
    key_map = nil, -- input key to code map
    keys_string = "abcdefghijklmnopqrstuvwxyz",
    iter_map = nil, -- next code when using wildcard
    iter_map_last_key = nil,
    show_candi_callback = function() end,
    switch_char = "SWITCH",
    separator = "SEPARATOR",
    partial_separators = { " " }, -- when in state act as separator, otherwise input itself
    auto_separate_callback = function() return false end,
    local_del = "",  -- default
    has_case = false,
    exact_match = false,
    W = nil, -- default no wildcard
    -- imeplus: exported for main.lua to build the fuzzy-rule submenu
    fuzzy_presets = FUZZY_PRESETS,
}

function IME:new(new_o)
    local o = new_o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function IME:init()
    self:clear_stack()

    -- imeplus: self-learned words (shared store, loaded per keyboard session).
    -- Scrub broken multi-frame learning artifacts ("没有钱没有钱" = X..X).
    local raw = (G_reader_settings and G_reader_settings:readSetting("imeplus_user_words")) or {}
    local had_junk = false
    self.user_words = {}
    for _, e in ipairs(raw) do
        local n_chars = #util.splitToChars(e.w or "")
        local half = n_chars % 2 == 0
        if half then
            local chars = util.splitToChars(e.w)
            half = true
            for i = 1, n_chars / 2 do
                if chars[i] ~= chars[i + n_chars / 2] then half = false break end
            end
        end
        if half then
            had_junk = true -- doubled word: drop it from the store entirely
        else
            self.user_words[#self.user_words+1] = e
        end
    end
    if had_junk then self:saveUserWords() end

    self:loadCustomWords()

    self.sorted_codes = {}
    for k,_ in pairs(self.code_map) do
        table.insert(self.sorted_codes, k)
    end
    table.sort(self.sorted_codes)

    if not self.key_map and self.keys_string then
        self.key_map = {}
        for i=0, #self.keys_string do
            self.key_map[self.keys_string:sub(i, i)] = self.keys_string:sub(i, i)
        end
    end

    if not self.iter_map and self.W then
        self.iter_map = {}
        local keys = util.splitToChars(self.keys_string)
        for i=1, #keys-1 do
            self.iter_map[keys[i]] = keys[i+1]
        end
        if #keys > 1 then
            self.iter_map[keys[#keys]] = keys[1]
        end
    end

    self:loadCustomWords()
end

-- imeplus: custom phrase table (plugins/imeplus.koplugin/custom_words.lua).
-- Each entry is either a word string (its full pinyin is looked up character by
-- character in the stock table) or a { word, code } pair giving the word's own
-- input code ("一闪一闪亮晶晶 ysys"). An explicit code is matched verbatim
-- (getExactLearned/promotion), so it need not be a valid pinyin spelling. When
-- the code is omitted, the word's INITIALS are generated automatically (first
-- letters of each syllable: zh/ch/sh keep both letters). Custom words are NOT
-- ranked apart: they inherit the usage count of the same word in the learned
-- store (or start at 0), so all candidates are ordered by real usage frequency.
-- Missing/ill-formed file is simply ignored.
function IME:loadCustomWords()
    if not isPinyin(self) then return end
    local ok, entries = pcall(dofile, "plugins/imeplus.koplugin/custom_words.lua")
    if not ok or type(entries) ~= "table" then return end

    -- single char -> its shortest pinyin code from the stock table
    local char_code = {}
    for code, list in pairs(self.code_map) do
        if #code > 0 then
            local words = type(list) == "string" and { list } or list
            for _, w in ipairs(words) do
                if util.splitToChars(w) and #util.splitToChars(w) == 1 and not char_code[w] then
                    char_code[w] = code
                end
            end
        end
    end

        -- initials of the word's syllables ("一闪一闪亮晶晶" -> "ysysljj")
    local function lookupInitials(w)
        local out = {}
        for _, ch in ipairs(util.splitToChars(w)) do
            local c = char_code[ch]
            if not c or not c:match("^[a-z]+$") then return nil end
            if c:sub(1, 2) == "zh" or c:sub(1, 2) == "ch" or c:sub(1, 2) == "sh" then
                out[#out+1] = c:sub(1, 2)
            else
                out[#out+1] = c:sub(1, 1)
            end
        end
        return table.concat(out)
    end

    -- explicit codes are matched verbatim, so they bypass the abbreviation
    -- guards (a code like "ysys" is not a prefix of a real pinyin spelling)
    if not self.custom_codes then self.custom_codes = {} end

    local by_word = {}
    for _, e in ipairs(self.user_words) do
        by_word[e.w] = e
        -- persisted entries that carry an explicit code rebuild the verbatim map
        if e.explicit then
            if not self.custom_codes then self.custom_codes = {} end
            self.custom_codes[e.c] = e
        end
    end
    for _, e in ipairs(entries) do
        local w, explicit
        if type(e) == "string" then
            -- tolerate "word code" written as one string (hand-edited files)
            w = e:match("^(%S+)$") or e:match("^(%S+)%s+%S+$")
            explicit = e:match("^%S+%s+(%S+)$")
        elseif type(e) == "table" and type(e[1]) == "string" then
            w, explicit = e[1], e[2]
        end
        if w and not by_word[w] then
            local has_cjk = w:match("[\xE4-\xE9\xEA-\xEF]") ~= nil
            local n_chars = #util.splitToChars(w)
            -- Pure CJK words need >=2 chars and can auto-generate initials.
            -- ASCII words and MIXED words (K8手机壳, iPhone13手机) contain
            -- non-pinyin characters, so they REQUIRE an explicit code.
            local pure_cjk = has_cjk
            if pure_cjk then
                for i = 1, #w do
                    if w:byte(i) < 0x80 then pure_cjk = false break end
                end
            end
            local ok_len = (pure_cjk and n_chars >= 2)
                or (not pure_cjk and #w >= 2 and explicit)
            if ok_len then
                local c = explicit
                if not c and pure_cjk then
                    c = lookupInitials(w)
                end
                -- codes may contain digits ("K8手机壳 k8sjk"); digit keys inside a
                -- custom-code prefix are swallowed into the composition (see
                -- wrappedAddChars), so they never trigger candidate selection
                if c and c:match("^[a-z0-9]+$") then
                    local entry = { w = w, c = c, n = 0, explicit = explicit ~= nil }
                    self.user_words[#self.user_words+1] = entry
                    by_word[w] = entry
                    self.custom_codes[c] = entry
                end
            end
        end
    end
end

function IME:clear_stack()
    _stack = { {code="", char="", index=1, candi={} } }
    self.last_key = ""
    self.last_index = 0
    self.hint_char_count = 0
    self.on_stage_char_count = 0
    self.v_text = nil -- imeplus: "v" english passthrough buffer
end

function IME:reset_status()
    self.last_key = ""
    self.last_index = 0
end

function IME:uniqueMap(code)
    -- Here we find out if given code has only one candidate and no other code
    -- starts with the given one, so that auto separation can take place.
    if not code then return true end
    if self.W and code:find(self.W) then
        return false -- with wildcard, we just return false even if its unique
    else
        if type(self.code_map[code]) == "table" then
            return false
        end
        local idx = binarysearch(self.sorted_codes, code, function(v) return v end)
        if idx == #self.sorted_codes then
            return true
        elseif not idx then
            idx = binarysearch(self.sorted_codes, code, function(v) return string.sub(v or "", 1, #code) end )
            if not idx or idx == #self.sorted_codes then
                return true
            end
        end
        local next_code = self.sorted_codes[idx+1]
        local unique = next_code:sub(1, #code) ~= code
        return unique
    end
end

function IME:searchStartWith(code)
    if self.exact_match then return end
    local result = binarysearch(self.sorted_codes, code, function(v) return string.sub(v or "", 1, #code) end)
    if result then
        local candi = self.code_map[self.sorted_codes[result]]
        if candi then
            logger.dbg("zh_kbd: got search result starting with", code, ":", candi)
        end
        if type(candi) == "string" then
            return { candi }
        end
        return candi
    end
end

function IME:getCandiFromMap(code)
    local candi = self.code_map[code]
    if candi then
        logger.dbg("zh_kbd: got candi from map with", code, ":", candi)
    end
    if type(candi) == "string" then
        return { candi }
    end
    return candi
end

function IME:getCandi(code)
    return self:getCandiFromMap(code) or self:searchStartWith(code) or {}
end

function IME:getCandiWithWildcard(code, from_reset)
    logger.dbg("zh_kdb: getCandiWithWildcard:", code, "lastKey:", self.last_key)
    for i=#code, 1, -1 do
        if code:sub(i, i) == self.W then
            if self.last_key:sub(i, i) == self.iter_map_last_key then
                local next = self.iter_map[self.iter_map_last_key]
                self.last_key = stringReplaceAt(self.last_key, i, next)
            else
                self.last_key = stringReplaceAt(self.last_key, i, self.iter_map[self.last_key:sub(i, i)])
                self.last_candi = self:getCandi(self.last_key)
                if #self.last_candi > 0 then
                    logger.dbg("zh_kbd: got candi with wildchard for key", self.last_key, ":", self.last_candi)
                    return self.last_candi
                end
                return self:getCandiWithWildcard(code, from_reset)
            end
        end
    end
    -- all wildcard reset
    self.last_candi = self:getCandi(self.last_key)
    if #self.last_candi > 0 then
        logger.dbg("zh_kbd: got candi with wildchard for key", self.last_key, ":", self.last_candi)
        return self.last_candi
    elseif not from_reset then
        return self:getCandiWithWildcard(code, true)
    end
end

function IME:getCandidates(code)
    logger.dbg("zh_kbd: getCandidates", code)
    if self.W then
        local wildcard_count = select(2, string.gsub(code, self.W, ""))
        if wildcard_count > 5 then
            -- we limit the wildcard count to 5 due to performance conserns
            return
        elseif wildcard_count ~= 0 then
            if #code == #self.last_key then -- only index change, no new stroke
                local last_candi = _stack[#_stack].candi
                return self:getCandiWithWildcard(code), last_candi
            else
                self:reset_status()
                self.last_key = code:gsub(self.W, self.iter_map_last_key)
                return self:getCandiWithWildcard(code)
            end
        end
    end
    -- no wildcard
    if isPinyin(self) then
        -- explicit custom codes ("一闪一闪亮晶晶 ysys") are typed letter by letter;
        -- a typed prefix of one must keep the composition alive (an intermediate
        -- prefix without stock candidates would otherwise break the stack). BUT a
        -- short prefix may also be a valid pinyin code ("ai" for 爱 while "ai1"
        -- is being typed): query normally first, and only return the empty
        -- keep-alive table when the stock/memory pools have nothing to show.
        local keep_composition = self:isCustomCodePrefix(code) and not self.custom_codes[code]
        if fuzzy_enabled() then
            local merged = self:getMergedCandidates(code)
            if #merged > 0 then return merged end
            if keep_composition then return {} end
            return
        end
        -- fuzzy off: learned habit first, then stock exact hits, then abbreviations
        local promoted = self:getExactLearned(code)
        local exact = self:getCandiFromMap(code)
        local user = self:getUserCandi(code)
        if promoted or exact or user then
            local merged, seen = {}, {}
            local function add(list)
                if type(list) == "string" then list = { list } end
                if list then
                    for _, v in ipairs(list) do
                        if not seen[v] then
                            seen[v] = true
                            merged[#merged+1] = v
                        end
                    end
                end
            end
            add(promoted)
            add(exact)
            add(user)
            return merged
        end
        if keep_composition then return {} end
    end
    return self:getCandiFromMap(code) or self:searchStartWith(code)
end

-- imeplus: merge candidates of the typed code and its fuzzy variants,
-- exact hits first, then prefix matches; original code always ranks first.
function IME:getMergedCandidates(code)
    local merged, seen = {}, {}
    local function addCandi(candi)
        if type(candi) == "string" then candi = { candi } end
        if candi then
            for _, v in ipairs(candi) do
                if not seen[v] then
                    seen[v] = true
                    merged[#merged+1] = v
                end
            end
        end
    end
    addCandi(self:getExactLearned(code)) -- habit wins over the stock table order
    addCandi(self:getCandiFromMap(code))
    local user, user_matched = self:getUserCandi(code)
    addCandi(user) -- learned words rank after exact hits, before variants
    local variants = fuzzy_variants(code)
    for _, v in ipairs(variants) do
        addCandi(self:getCandiFromMap(v))
    end
    if #merged > 0 then
        -- learned/abbreviation hits lead the pool, but the stock prefix search
        -- still fills the tail: "meiy" (learned 没有钱 under meiyouq) must keep
        -- 没有 reachable. searchStartWith only returns the FIRST matching code's
        -- candidates (meiym hides meiyou=没有), so walk every meiy* code; the
        -- top learned word's own code seeds a targeted walk (meiyouq -> the
        -- meiyous* range) so 没有 surfaces without wading through every meiy*.
        addCandi(self:getAllStartsWith(code, 12))
        if user_matched and user_matched[1] and #user_matched[1].c > #code then
            addCandi(self:getAllStartsWith(user_matched[1].c:sub(1, #code + 1), 12))
        end
        for _, v in ipairs(variants) do
            addCandi(self:getAllStartsWith(v, 12))
        end
        return merged
    end
    addCandi(self:getAllStartsWith(code, 12))
    for _, v in ipairs(variants) do
        addCandi(self:getAllStartsWith(v, 12))
    end
    return merged
end

-- imeplus: collect candidates from EVERY stock code starting with `prefix`.
-- The stock searchStartWith only returns the first matching code's candidates
-- (binary search stops at meiym, so meiyou=没有 stays hidden behind it); the
-- sorted index makes the linear walk cheap and we stop after enough candidates.
function IME:getAllStartsWith(prefix, want)
    if not prefix or #prefix == 0 then return nil end
    local out = {}
    local codes = self.sorted_codes
    -- binary-search the first code >= prefix
    local lo, hi = 1, #codes
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if codes[mid] < prefix then lo = mid + 1 else hi = mid - 1 end
    end
    for i = lo, #codes do
        local code = codes[i]
        if code:sub(1, #prefix) ~= prefix then break end
        local candi = self.code_map[code]
        if candi then
            if type(candi) == "string" then candi = { candi } end
            for _, v in ipairs(candi) do
                out[#out+1] = v
                if #out >= want then return out end
            end
        end
    end
    return #out > 0 and out or nil
end

-- imeplus: words whose full pinyin IS the typed code, promoted above the stock
-- table order. A word typed often ("chengdu" -> 成都) should outrank the stock
-- first candidate (程度), not sit behind it. Ranked by usage count; custom
-- phrases (n=0) come after words the user actually committed.
function IME:getExactLearned(code)
    if #code < 2 or #self.user_words == 0 then return nil end
    -- explicit custom codes ("一闪一闪亮晶晶 ysys") match verbatim
    local hit = self.custom_codes and self.custom_codes[code]
    if hit then return { hit.w } end
    local matched = {}
    for _, e in ipairs(self.user_words) do
        if e.c == code then matched[#matched+1] = e end
    end
    if #matched == 0 then return nil end
    table.sort(matched, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, math.min(#matched, USER_CANDI_MAX) do
        out[i] = matched[i].w
    end
    return out
end

-- imeplus: learned-word candidates for a typed code, ranked by usage count.
-- ponytail: no fuzzy-variant scan here — the abbreviation spellings users type
-- ("zhch"/"zc"/"zhc"/"zch" for "zhichi") already are subsequences of the learned
-- code, while fuzzy elongation variants ("zh" -> "zhh") would wrongly resurrect
-- plain first-syllable prefixes as abbreviations.
-- imeplus: is the typed code a strict prefix of (or equal to) any explicit
-- custom code? Used to keep digit keys and empty-candidate compositions alive.
function IME:isCustomCodePrefix(code)
    if not self.custom_codes or #code == 0 then return false end
    for c in pairs(self.custom_codes) do
        if #code <= #c and c:sub(1, #code) == code then return true end
    end
    return false
end

function IME:getUserCandi(code)
    if #code < 2 or #self.user_words == 0 then return nil end
    local matched = {}
    for _, e in ipairs(self.user_words) do
        -- ponytail: with fuzzy off, a flat initial ("s" in "sm") must not stand
        -- in for a learned retroflex initial ("sh" in "shenme") — that is a
        -- fuzzy spelling, not a real abbreviation. With fuzzy on, both pass.
        local allowed = true
        if not fuzzy_enabled() then
            local flat = code:sub(1, 1)
            local retro = RETROFLEX[flat]
            if retro and code:sub(2, 2) ~= "h" and e.c:sub(1, #retro) == retro then
                allowed = false
            end
        end
        if allowed and (e.c == code -- the full code typed exactly (auto initials)
            or (not e.explicit and looseMatch(code, e.c, self.code_map))) then
            matched[#matched+1] = e
        end
    end
    if #matched == 0 then return nil, nil end
    table.sort(matched, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, math.min(#matched, USER_CANDI_MAX) do
        out[i] = matched[i].w
    end
    return out, matched
end

function IME:saveUserWords()
    if not G_reader_settings then return end
    -- custom phrases (n=0) are reloaded from the file each session; never persist them
    local learned = {}
    for _, e in ipairs(self.user_words) do
        if e.n > 0 then learned[#learned+1] = e end
    end
    G_reader_settings:saveSetting("imeplus_user_words", learned)
end

-- imeplus: record a committed word together with the code it was typed under
-- (called from separate(), i.e. on space commit / digit selection / flush).
-- CJK, ASCII and mixed words (K8手机壳) all learn; the code must be letters/digits.
function IME:learnWord(word, code)
    if not isPinyin(self) or not learn_enabled() then return end
    if not code:match("^[a-z0-9]+$") then return end -- letter/digit codes only
    local chars = util.splitToChars(word)
    if #chars < 2 then return end -- single chars (CJK or ASCII) don't learn
    for _, ch in ipairs(chars) do
        local b = ch:byte(1)
        -- reject chars outside CJK + printable ASCII (Cyrillic, kana...)
        if not ((b >= 0xE4 and b <= 0xEF) or (b >= 0x20 and b <= 0x7E)) then return end
    end
    if word:match("[\xE4-\xE9\xEA-\xEF]") then
        -- word contains CJK: cap the code at a plausible full-pinyin length
        if #code > 6 * #chars then return end
    end
    for _, e in ipairs(self.user_words) do
        if e.w == word then
            e.n = e.n + 1
            if #code > #e.c then e.c = code end -- keep the most complete code seen
            self:saveUserWords()
            return
        end
    end
    self.user_words[#self.user_words+1] = { w = word, c = code, n = 1 }
    if #self.user_words > USER_WORDS_MAX then
        table.sort(self.user_words, function(a, b) return a.n > b.n end)
        for i = USER_WORDS_MAX + 1, #self.user_words do
            self.user_words[i] = nil
        end
    end
    self:saveUserWords()
end


--- inputbox operation
function IME:delHintChars(inputbox)
    logger.dbg("zh_kbd: delete hint chars of count", self.hint_char_count)
    for i=1, self.hint_char_count do
        inputbox.delChar:raw_method_call()
    end
end

function IME:delOnStageAndHintChars(inputbox)
    self:delHintChars(inputbox)
    for i=1, self.on_stage_char_count do
        inputbox.delChar:raw_method_call()
    end
end

function IME:getHintChars(inputbox)
    self.hint_char_count = 0
    self.on_stage_char_count = 0
    local hint_chars = ""
    for i=1, #_stack do
        local ch = _stack[i].char or "" -- 兜底: 任何路径漏守卫也不得 concat-nil 闪退
        hint_chars = hint_chars .. ch
        if ch ~= "" then
            self.on_stage_char_count = self.on_stage_char_count + #util.splitToChars(ch)
        end
    end
    local imex = _stack[#_stack]
    local has_wildcard = self.W and imex.code:find(self.W)
    if isPinyin(self) then
        -- imeplus: numbered candidate window, page starts at imex.index.
        -- Stage char (candi[index], what space commits) stays outside the brackets;
        -- the brackets show the rest of the page with digit prefixes 2..S, where
        -- S is capped by the input field width so multi-char word candidates
        -- never push the front of the line out of view.
        local page_size = visiblePageSize(imex, inputbox)
        if self:show_candi_callback() and #imex.candi > 1 and #imex.code > 0 and page_size >= 2 then
            hint_chars = hint_chars .. "["
            local last = math.min(imex.index + page_size - 1, #imex.candi)
            for i = imex.index + 1, last do
                hint_chars = hint_chars .. (i - imex.index + 1) .. imex.candi[i]
                self.hint_char_count = self.hint_char_count + 1 + #util.splitToChars(imex.candi[i])
            end
            if last < #imex.candi then
                hint_chars = hint_chars .. "…"
                self.hint_char_count = self.hint_char_count + 1
            end
            hint_chars = hint_chars .. "]"
            self.hint_char_count = self.hint_char_count + 2
        end
        logger.dbg("zh_kbd: got hint chars:", hint_chars, "with count", self.hint_char_count)
        return hint_chars
    end
    if self:show_candi_callback() and -- shows candidates
        #imex.candi ~= 0 and -- has candidates
        ( #imex.code > 1 or imex.index > 1 ) and -- more than one key
        ( #imex.candi > 1 or has_wildcard and imex.candi[1] ~= (imex.last_candi or {})[1] ) then -- one candidate but use wildcard, or more candidates
        hint_chars = hint_chars .. "["
        if #imex.candi > 1 then
            local remainder
            if not has_wildcard then
                remainder = (imex.index+1) % #imex.candi
            else
                remainder = (imex.index-self.last_index+1) % #imex.candi
            end
            local pos = remainder == 0 and #imex.candi or remainder
            if not (has_wildcard and pos == 1) then
                for i=1, math.min(#imex.candi-1, 5) do
                    hint_chars = hint_chars .. imex.candi[pos]
                    self.hint_char_count = self.hint_char_count + #util.splitToChars(imex.candi[pos])
                    pos = pos == #imex.candi and 1 or pos+1
                    if has_wildcard and pos == 1 then
                        break
                    end
                end
            end
        end
        if #imex.candi > 6 or has_wildcard then
            hint_chars = hint_chars .. "…"
            self.hint_char_count = self.hint_char_count + 1
        end
        hint_chars = hint_chars .. "]"
        self.hint_char_count = self.hint_char_count + 2
    end
    logger.dbg("zh_kbd: got hint chars:", hint_chars, "with count", self.hint_char_count)
    return hint_chars
end

function IME:refreshHintChars(inpuxbox)
    self:delOnStageAndHintChars(inpuxbox)
    inpuxbox.addChars:raw_method_call(self:getHintChars(inpuxbox))
end

-- imeplus: "v" mode — typing v then letters emits half-width ASCII verbatim.
-- The field shows the literal buffer ("vbing"); committing (space / separator /
-- non-letter) drops the leading "v" and leaves "bing". No candidate stack is
-- involved, so vterm and stock pinyin behavior are untouched outside v mode.
function IME:vCommit(inputbox, keep_letters)
    if not self.v_text then return end
    local text = self.v_text
    self.v_text = nil
    for _ = 1, #text do inputbox.delChar:raw_method_call() end
    if keep_letters and #text > 1 then
        inputbox.addChars:raw_method_call(text:sub(2))
    end
end

-- imeplus: replace the displayed v-buffer with the new value. The caller must
-- pass the OLD text length, since the field still shows the previous content.
function IME:vRefresh(inputbox, old_len)
    for _ = 1, old_len or 0 do inputbox.delChar:raw_method_call() end
    inputbox.addChars:raw_method_call(self.v_text or "")
end

function IME:separate(inputbox)
    -- imeplus: v-mode commit takes precedence over the candidate stack
    if self.v_text then
        self:vCommit(inputbox, true)
        self:clear_stack()
        return
    end
    if self.hint_char_count then
        self:delHintChars(inputbox)
    end
    -- imeplus: commit point — learn the staged word with the code typed for it.
    -- Only a SINGLE-frame composition is learned: in the pinyin layout the whole
    -- syllable sequence lives in one frame, so extra frames mean the composition
    -- broke mid-word and restarting glued unrelated stage chars together — that
    -- is how "没有钱没有钱" got learned from a broken two-frame flush.
    if isPinyin(self) and #_stack == 1 then
        self:learnWord(_stack[1].char, _stack[1].code)
    end
    self:clear_stack()
end

function IME:tweak_case(new_candi, old_imex, new_stroke_upper)
    if self.has_case then
        local old_chars = util.splitToChars(old_imex.char)
        logger.dbg("zh_ime: tweak_case old chars", old_chars, "new_candi", new_candi)
        for i=1, #new_candi do
            local new_chars = util.splitToChars(new_candi[i])
            for j=1, math.max(#new_chars, #old_chars) do
                local old_char = old_chars[j]
                local new_char = new_chars[j]
                if new_char ~= old_char then
                    if not old_char and new_stroke_upper then
                        -- tweak new_char
                        new_chars[j] = Utf8Proc.uppercase_dumb(new_char)
                    elseif old_char and new_char and old_char == Utf8Proc.uppercase_dumb(old_char) then
                        -- tweak new_char when corresponding old char is uppercase
                        new_chars[j] = Utf8Proc.uppercase_dumb(new_char)
                    end
                end
            end
            new_candi[i] = table.concat(new_chars)
        end
    end
end

function IME:hasCandidates()
    return #(_stack[#_stack].candi) > 0
end

function IME:wrappedDelChar(inputbox)
    -- imeplus: v-mode backspace removes one buffered letter; emptying cancels
    if self.v_text then
        local old_len = #self.v_text
        self.v_text = self.v_text:sub(1, -2)
        if self.v_text == "" then self.v_text = nil end
        self:vRefresh(inputbox, old_len)
        return
    end
    local imex = _stack[#_stack]
    -- stepped deletion
    if #imex.code > 1 then
        -- last char has over one input strokes
        imex.code = string.sub(imex.code, 1, -2)
        imex.index = 1
        local new_candi, last_candi = self:getCandidates(imex.code)
        self:tweak_case(new_candi, imex)
        imex.candi, imex.last_candi = new_candi or {}, last_candi
        -- 自定义词组/自定义编码会让"空候选组词"成为常态(见下方 wrappedAddChars
        -- 的空结果分支), 回退一步同样可能空: char 必须保持字符串, 否则
        -- getHintChars 拼 nil → 整个 KOReader 闪退(真机 crash.log 实证)
        imex.char = imex.candi[1] or ""
        self:refreshHintChars(inputbox)
    elseif #_stack > 1 then
        -- over one chars, last char has only one stroke
        _stack[#_stack] = nil
        self:refreshHintChars(inputbox)
    elseif #imex.code == 1 then
        -- one char with one stroke
        self:delOnStageAndHintChars(inputbox)
        self:clear_stack()
    else
        inputbox.delChar:raw_method_call()
    end
end

function IME:wrappedAddChars(inputbox, char, orig_char)
    -- imeplus: v-mode passthrough (pinyin layout only, idle stack)
    if isPinyin(self) then
        if self.v_text then
            if #char == 1 and char:match("^%a$") then
                local old_len = #self.v_text
                self.v_text = self.v_text .. char
                self:vRefresh(inputbox, old_len)
                return
            end
            -- space / separator / punctuation / digits commit the letters.
            -- The space only COMMITS — it is not inserted; word gaps are typed
            -- afterwards (out of v-mode, a plain space lands literally).
            self:vCommit(inputbox, true)
            self:clear_stack()
            if not (char == " " or char == self.separator) then
                inputbox.addChars:raw_method_call(orig_char or char)
            end
            return
        elseif #char == 1 and char == "v" and #_stack == 1 and _stack[1].code == "" then
            self.v_text = "v"
            self:vRefresh(inputbox, 0)
            return
        end
    end

    local imex = _stack[#_stack]
    if char == self.switch_char then
        if isPinyin(self) then
            -- imeplus: page forward by the visible page size, wraps back to the first page
            local page_size = visiblePageSize(imex, inputbox)
            if #imex.candi > 1 and page_size >= 2 then
                imex.index = imex.index + page_size
                if imex.index > #imex.candi then imex.index = 1 end
                imex.char = imex.candi[imex.index]
                self:refreshHintChars(inputbox)
            end
            return
        end
        imex.index = imex.index + 1
        if self.W and imex.code:find(self.W) then
            if #imex.candi == 0 then
                return
            elseif imex.index - self.last_index > #imex.candi then
                self.last_index = self.last_index + #imex.candi
                imex.candi,imex.last_candi = self:getCandidates(imex.code)
                imex.char = imex.candi[1]
            else
                imex.char = imex.candi[imex.index - self.last_index]
            end
        elseif #imex.candi > 1 then
            local remainder = imex.index % #imex.candi
            imex.char = imex.candi[remainder==0 and #imex.candi or remainder]
        else
            return
        end
        self:refreshHintChars(inputbox)
    elseif char == self.switch_char_prev then
        if isPinyin(self) then
            -- imeplus: page backward, first page wraps to the last page start
            local page_size = visiblePageSize(imex, inputbox)
            if #imex.candi > 1 and page_size >= 2 then
                if imex.index == 1 then
                    imex.index = #imex.candi - ((#imex.candi - 1) % page_size)
                else
                    imex.index = math.max(imex.index - page_size, 1)
                end
                imex.char = imex.candi[imex.index]
                self:refreshHintChars(inputbox)
            end
            return
        end
        if self.W and imex.code:find(self.W) then
            if #imex.candi == 0 then
                return
            elseif imex.index <= self.last_index + 1 then
                return
            else
                imex.index = imex.index - 1
                imex.char = imex.candi[imex.index - self.last_index]
            end
        elseif #imex.candi > 1 then
            imex.index = math.max(imex.index-1, 1)
            local remainder = imex.index % #imex.candi
            imex.char = imex.candi[remainder==0 and #imex.candi or remainder]
        else
            return
        end
        self:refreshHintChars(inputbox)
    elseif char == self.separator or
        _stack[1].code ~= "" and self.partial_separators and util.arrayContains(self.partial_separators, char) then
            self:separate(inputbox)
            return
    elseif char == self.local_del then
        if #imex.code > 0 then
            imex.candi = {}
            imex.char = ""
            local previous_imex = _stack[#_stack-1]
            if previous_imex then
                previous_imex.candi = {}
                previous_imex.char = ""
            end
            self:refreshHintChars(inputbox)
            self:clear_stack()
        else
            inputbox.delChar:raw_method_call()
        end
    elseif isPinyin(self) and #char == 1 and char >= "1" and char <= "9"
        and #imex.code > 0 and self:isCustomCodePrefix(imex.code .. char) then
        -- imeplus: a digit that extends a custom-code prefix ("k8sjk" after "k")
        -- is swallowed into the composition instead of selecting a candidate
        imex.index = 1
        local new_candi = self:getCandidates(imex.code .. char)
        imex.code = imex.code .. char
        imex.char = new_candi and new_candi[1] or ""
        imex.candi = new_candi or {}
        self:refreshHintChars(inputbox)
    elseif isPinyin(self) and #char == 1 and char >= "1" and char <= "9" and #imex.code > 0 then
        -- imeplus: digit key selects the n-th candidate on the current page;
        -- digits beyond the visible page size commit literally (never a hidden
        -- candidate). A digit that extends a custom-code prefix ("k8sjk" after
        -- "k") is swallowed into the composition instead.
        local nd = tonumber(char)
        local page_size = visiblePageSize(imex, inputbox)
        local target = imex.index + nd - 1
        if nd <= page_size and imex.candi[target] then
            imex.char = imex.candi[target]
            self:refreshHintChars(inputbox)
            self:separate(inputbox)
        else
            -- no candidate at that position: literal digit, composition flushed
            -- (same path as stock for unmapped chars)
            self:separate(inputbox)
            inputbox.addChars:raw_method_call(char)
        end
    else
        local key = self.key_map[char]
        if key then
            imex.index = 1
            self:reset_status()
            local new_candi
            new_candi,imex.last_candi = self:getCandidates(imex.code..key)
            if new_candi and #new_candi > 0 then
                imex.code = imex.code .. key

                self:tweak_case(new_candi, imex, orig_char and orig_char ~= char)

                imex.char = new_candi[1]
                imex.candi = new_candi
                self:refreshHintChars(inputbox)
                if self.auto_separate_callback() and self:uniqueMap(imex.code) then
                    self:separate(inputbox)
                end
            elseif new_candi and #new_candi == 0 and #_stack == 1 then
                -- imeplus: empty result (custom-code prefix like "ysy") — keep the
                -- composition alive instead of restarting from the single letter
                imex.code = imex.code .. key
                imex.char = ""
                imex.candi = {}
                self:refreshHintChars(inputbox)
            else
                if self.auto_separate_callback() then -- flush current stack
                    self:separate(inputbox)
                end
                new_candi,imex.last_candi = self:getCandidates(key) or {orig_char or char},nil -- single stroke

                self:tweak_case(new_candi, {}, orig_char and orig_char ~= char)

                if self.auto_separate_callback() then
                    _stack[1] = { code=key, index=1, char=new_candi[1] or "", candi=new_candi }
                else
                    table.insert(_stack, {code=key, index=1, char=new_candi[1] or "", candi=new_candi} )
                end
                self:refreshHintChars(inputbox)
            end
        else
            self:separate(inputbox)
            inputbox.addChars:raw_method_call(orig_char or char)
        end
    end
end

return IME
