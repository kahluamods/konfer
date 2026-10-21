--[[
   KahLua Konfer - a loot distribution addon.
     Git: https://github.com/kahluamods/konfer
     E-mail: me@cruciformer.com
   Please refer to the file LICENSE.txt for the Apache License, Version 2.0.

   Copyright 2008-2026 Kean Johnston. All rights reserved.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
]]

local K = LibStub:GetLibrary("Kore")

if (not K) then
  return
end

local konfer = K:GetAddon("Konfer")
local L = konfer.L
local KUI = konfer.KUI
local KRP = LibStub:GetLibrary("KoreParty")
local KU = K.Users -- @debug-delete@
local LibDeflate = LibStub:GetLibrary("LibDeflate")
local MakeFrame = KUI.MakeFrame
local pug = konfer.policies.pug

local aclass = konfer.aclass
local tinsert = table.insert
local tsort = table.sort
local tconcat = table.concat
local strfmt = string.format
local strlower = string.lower
local strupper = string.upper
local strsub = string.sub
local strbyte = string.byte
local strchar = string.char
local strfind = string.find
local strmatch = string.match
local strgsub = string.gsub
local floor = math.floor
local min = math.min
local max = math.max

--
-- RESERVES
--
-- A pickup raid's reserves are made on softres.it before the raid and brought in by an admin, who pastes the site's Gargul
-- export into the Reserves tab once everybody is in the group. A soft reserve is a raider's claim to roll on an item: where
-- the config says so (reserves_only, on unless turned off) its reservers who are here have a roll of their own first, from
-- the Assign loot tab's Reserves, and it is everybody's only if none of them rolls; otherwise the reservers' rolls come
-- first among rolls of the same kind. Where none of them is here it is an open roll like any other. A hard reserve is the
-- master looter's: one made for somebody in the group is put to them as an item's own instructions are and is never rolled
-- on, and one for somebody not here, or for nobody, is theirs to hand out however they see fit, a roll included (ItemClaim).
--
-- They are tonight's, so they are kept on the config's raid with everything else tonight has counted (THE RAID in PUG.lua),
-- outliving a reload and going when the raid ends. Importing begins the raid if nothing else has. RAID.res is
--
--   id    softres.it's own id for the raid the reserves were made in.
--   at    when they were imported.
--   names each name reserved under on softres.it, as typed: uid, the raider it was taken to be where that is somebody the
--         config holds, and items, the ids of the items reserved, one id for each reserve, so that reserving an item twice
--         lists it twice. What travels, soft and away being made from it by every client (clean_reserves).
--   soft  each reserver the config holds, by uid, and the items they reserved, under whichever names they reserved.
--   away  the same for the names taken to be nobody, by the name.
--   hard  each hard reserved item, by id: uid, who it is for where that is somebody the config holds, who, what softres.it
--         says it is for, and note.
--
-- RAID.resfix is who an admin said a name is, by the name in lower case: a uid, or false for nobody. A name is taken to be
-- whoever it says before anything is matched (match_plan), so a raider put right once stays right through every import
-- tonight, a Clear included.
--
-- An admin imports them, the owner or the co-admins the raid's leader has made for the night, and every client holding the
-- config is told in one event, PGRSV, carrying the whole of them and RAID.resfix, an import replacing whatever was there.
--

local function reserves_of(cfg)
  local pd = cfg and cfg:PolicyData(pug.handle)

  return pd and pd.raid and pd.raid.res
end

local function link_id(ilink)
  return tonumber(strmatch(ilink or "", "item:(%d+)"))
end

local function has_item(items, id)
  for _, v in ipairs(items or {}) do
    if (v == id) then
      return true
    end
  end

  return false
end

-- Whether the character UID names in CFG is in the group.
local function here(cfg, uid)
  local name = uid and cfg:UserName(uid)

  return (name and KRP.players and KRP.players[name]) and true or false
end

-- Those CFG holds who soft reserved ITEMID, by uid, sorted by name, and how many times each.
local function soft_reservers(cfg, itemid)
  local res = reserves_of(cfg)
  local out = {}

  for uid, items in pairs((res and res.soft) or {}) do
    local n = 0

    for _, v in ipairs(items) do
      if (v == itemid) then
        n = n + 1
      end
    end

    if (n > 0) then
      tinsert(out, { uid = uid, n = n, name = cfg:UserName(uid) or uid })
    end
  end

  tsort(out, function(a, b) return a.name < b.name end)

  return out
end

-- Those who reserved ITEMID under a name nobody here answers to, sorted.
local function away_reservers(cfg, itemid)
  local res = reserves_of(cfg)
  local out = {}

  for name, items in pairs((res and res.away) or {}) do
    if (has_item(items, itemid)) then
      tinsert(out, name)
    end
  end

  tsort(out)

  return out
end

-- "A", "A and B", "A, B and C".
local function joined(names)
  if (#names <= 1) then
    return names[1] or ""
  end

  return strfmt(L["%s and %s"], tconcat(names, ", ", 1, #names - 1), names[#names])
end

-- "2 soft reserves from 1 raider, 1 hard reserve.", each count singular or plural as it needs.
local function counts_text(nsoft, nraiders, nhard)
  local function counted(n, one, many)
    return strfmt((n == 1) and one or many, n)
  end

  return strfmt(L["PUG_RES_COUNTS"], counted(nsoft, L["PUG_RES_SOFT"], L["PUG_RES_SOFTS"]),
    counted(nraiders, L["PUG_RES_RAIDER"], L["PUG_RES_RAIDERS"]), counted(nhard, L["PUG_RES_HARD"], L["PUG_RES_HARDS"]))
end

-- The item ITEMID as a link where the client has it, and by its number until then.
local function item_text(id)
  local _, link = C_Item.GetItemInfo(id)

  return link or ("item:" .. id)
end

-- Ask the server for every item RES names that the client has not seen yet, so that its name is there when it is drawn.
local function request_items(res)
  local function want(id)
    if (not C_Item.IsItemDataCachedByID(id)) then
      C_Item.RequestLoadItemDataByID(id)
    end
  end

  for _, items in pairs(res.soft) do
    for _, id in ipairs(items) do
      want(id)
    end
  end

  for _, items in pairs(res.away) do
    for _, id in ipairs(items) do
      want(id)
    end
  end

  for id in pairs(res.hard) do
    want(id)
  end
end

--
-- RES as it is kept, from whatever arrived: only what makes sense is taken, a name's uid and a hard reserve's only where CFG
-- holds it, and soft and away made from the names.
--
local function clean_reserves(cfg, res)
  if (type(res) ~= "table") then
    return nil
  end

  local out = { id = (type(res.id) == "string") and res.id or nil, at = tonumber(res.at), names = {}, soft = {}, away = {},
    hard = {} }

  local function ids(list)
    local got = {}

    for _, v in ipairs((type(list) == "table") and list or {}) do
      local n = tonumber(v)

      if (n and n > 0) then
        tinsert(got, floor(n))
      end
    end

    return got
  end

  for name, e in pairs((type(res.names) == "table") and res.names or {}) do
    local got = (type(name) == "string" and name ~= "" and type(e) == "table") and ids(e.items) or {}

    if (#got > 0) then
      local uid = (type(e.uid) == "string" and cfg.uids[e.uid]) and e.uid or nil
      local into = uid and out.soft or out.away
      local key = uid or name

      out.names[name] = { uid = uid, items = got }
      into[key] = into[key] or {}

      for _, id in ipairs(got) do
        tinsert(into[key], id)
      end
    end
  end

  for id, h in pairs((type(res.hard) == "table") and res.hard or {}) do
    local n = tonumber(id)

    if (n and n > 0 and type(h) == "table") then
      out.hard[floor(n)] = {
        uid = (type(h.uid) == "string" and cfg.uids[h.uid]) and h.uid or nil,
        who = (type(h.who) == "string" and h.who ~= "") and h.who or nil,
        note = (type(h.note) == "string" and h.note ~= "") and h.note or nil,
      }
    end
  end

  return out
end

-- FIXES as they are kept: a name's uid only where CFG holds it, or false for nobody.
local function clean_fixes(cfg, fixes)
  local out = {}

  for name, uid in pairs((type(fixes) == "table") and fixes or {}) do
    if (type(name) == "string" and name ~= "" and (uid == false or (type(uid) == "string" and cfg.uids[uid]))) then
      out[strlower(name)] = uid
    end
  end

  return out
end

-- Reserved items whose first roll nobody answered, by config and then item id (FirstRollUnanswered). Gone with new reserves.
local tried = {}

-- RES and FIXES as CFG's reserves and who its names have been said to be, FIXES leaving those there as they are where nil.
function pug:ApplyReserves(cfg, started, res, group, fixes)
  local pd = cfg and cfg:PolicyData(self.handle)
  local raid = pd and pd.raid

  if (not raid) then
    return
  end

  raid.res = clean_reserves(cfg, res)

  if (fixes ~= nil) then
    raid.resfix = clean_fixes(cfg, fixes)
  end

  if (raid.res) then
    raid.started = raid.started or started
    raid.group = group or raid.group
    request_items(raid.res)
  end

  -- New reserves owe every item they name its first roll again.
  tried[cfg.id] = nil

  if (cfg:IsActive()) then
    konfer:RefreshPolicyPages()
    konfer:RefreshLootMembers()
  end
end

--
-- Make RES CFG's reserves, beginning the raid if they are the first thing it holds, or clear them with nil, and FIXES who
-- its names are, or leave those as they are with nil, and tell every client. The names and the hard reserves travel, soft
-- and away being made from them at the other end.
--
function pug:SetReserves(cfg, res, fixes)
  local raid = cfg:PolicyData(self.handle).raid
  local started = raid.started or K.time()

  self:ApplyReserves(cfg, started, res, KRP.group_id, fixes)

  local sent = raid.res and { id = raid.res.id, at = raid.res.at, names = raid.res.names, hard = raid.res.hard } or false

  cfg:AddEvent("PGRSV", started, sent, KRP.group_id, raid.resfix or {})
end

--
-- PGRSV started reserves group fixes
--   The config's reserves are now RESERVES, false for none, the raid having begun at STARTED in the group whose id is GROUP,
--   and who an admin said its names are FIXES (RAID.resfix).
--
pug.ehandlers.PGRSV = function(self, live, sender, proto, pol, cmd, cfg, started, res, group, fixes)
  pol:ApplyReserves(cfg, tonumber(started) or K.time(), res or nil, group, (type(fixes) == "table") and fixes or nil)
end

--
-- What the reserves do to a roll and to an item. Where the config says a soft reserve keeps everybody else out
-- (reserves_only), an item is owed a first roll among its reservers who are here and meet its Constraints, opened from the
-- Assign loot tab's Reserves (FirstRoll): the Candidates are those reservers, Open roll waits, and nobody else may roll.
-- Should none of them roll it is everybody's, for this session (FirstRollUnanswered). Otherwise there is no first roll and
-- in an open roll the reservers here come first.
--

-- Those who reserved item ID that the first roll is owed to, here and meeting the item's Constraints.
local function owed_to(cfg, id)
  local out = {}

  if (not cfg or not id or not pug:Setting("reserves_only", cfg.id) or (tried[cfg.id] and tried[cfg.id][id])) then
    return out
  end

  for _, r in ipairs(soft_reservers(cfg, id)) do
    if (here(cfg, r.uid) and konfer:MeetsConstraints(r.uid)) then
      tinsert(out, r)
    end
  end

  return out
end

function pug:FirstRoll(cfgid, ilink)
  return #owed_to(konfer:PolicyConfig(pug, cfgid), link_id(ilink)) > 0
end

function pug:FirstRollUnanswered(cfgid, ilink)
  local id = link_id(ilink)

  if (id) then
    tried[cfgid] = tried[cfgid] or {}
    tried[cfgid][id] = true
  end
end

-- 0 for somebody who reserved ILINK or where no reserver of it is here, and 1 for everybody else, only where a soft reserve
-- does not keep the rest out (RollPriority in PUG.lua). Where it does, their first roll was theirs alone.
function pug:ReserveStanding(cfg, uid, ilink)
  local id = link_id(ilink)

  if (not cfg or not uid or not id or pug:Setting("reserves_only", cfg.id)) then
    return 0
  end

  local mine, present = false, false

  for _, r in ipairs(soft_reservers(cfg, id)) do
    mine = mine or r.uid == uid
    present = present or here(cfg, r.uid)
  end

  return (present and not mine) and 1 or 0
end

-- While an item's first roll is owed, only those it is owed to may roll, and only they are its Candidates.
function pug:MayRoll(cfgid, uid, kind, ilink)
  local owed = owed_to(konfer:PolicyConfig(pug, cfgid), link_id(ilink))

  if (#owed == 0) then
    return true
  end

  for _, r in ipairs(owed) do
    if (r.uid == uid) then
      return true
    end
  end

  return false, L["PUG_RES_ONLY"]
end

function pug:RollNotice(cfgid, ilink)
  local cfg = konfer:PolicyConfig(pug, cfgid)
  local id = link_id(ilink)
  local names = {}
  local first = owed_to(cfg, id)

  if (#first > 0) then
    for _, r in ipairs(first) do
      tinsert(names, K.DisplayName(r.name))
    end

    return strfmt(L["PUG_RES_NOTICE_ONLY"], joined(names))
  end

  if (not cfg or not id or pug:Setting("reserves_only", cfgid)) then
    return nil
  end

  for _, r in ipairs(soft_reservers(cfg, id)) do
    if (here(cfg, r.uid)) then
      tinsert(names, K.DisplayName(r.name))
    end
  end

  return (#names > 0) and strfmt(L["PUG_RES_NOTICE_FIRST"], joined(names)) or nil
end

pug.AssignPage.firstroll = { text = L["Reserves"], tooltip = L["TIP_PUG_RES_ROLL"] }

--
-- A hard reserve claims its item only while whoever it is for is here. For somebody who is not, or for nobody in particular,
-- it is the master looter's to hand out however they see fit, a roll included.
--
function pug:ItemClaim(cfgid, ilink)
  local cfg = konfer:PolicyConfig(pug, cfgid)
  local res = reserves_of(cfg)
  local id = link_id(ilink)
  local hr = res and id and res.hard[id]

  if (not hr or not here(cfg, hr.uid)) then
    return false
  end

  return true, hr.uid
end

-- A raider's name for the tab and the tooltip: in class colour where they are here, and grey where they are not.
local function raider_text(cfg, uid, n)
  local name, cls = cfg:UserNameClass(uid)
  local text

  if (name and here(cfg, uid)) then
    text = aclass(name, cls)
  else
    text = "|cff808080" .. (name and K.DisplayName(name) or uid) .. "|r"
  end

  return (n and n > 1) and strfmt(L["%s (%dx)"], text, n) or text
end

local function hard_text(cfg, hr)
  if (hr.uid) then
    return strfmt(L["Hard reserved for %s"], raider_text(cfg, hr.uid))
  elseif (hr.who) then
    return strfmt(L["Hard reserved for %s"], hr.who)
  end

  return L["Hard reserved"]
end

-- Every item tooltip names who reserved it, a raider's from their own copy of the config as much as the master looter's.
function pug:ItemTooltip(cfgid, ilink)
  local cfg = konfer:PolicyConfig(pug, cfgid)
  local res = reserves_of(cfg)
  local id = link_id(ilink)

  if (not res or not id) then
    return nil
  end

  local lines = {}

  if (res.hard[id]) then
    tinsert(lines, { hard_text(cfg, res.hard[id]), "" })
  end

  local label = L["Soft reserved by"]

  for _, r in ipairs(soft_reservers(cfg, id)) do
    tinsert(lines, { label, raider_text(cfg, r.uid, r.n) })
    label = " "
  end

  for _, name in ipairs(away_reservers(cfg, id)) do
    tinsert(lines, { label, "|cff808080" .. name .. "|r" })
    label = " "
  end

  return { lines = lines }
end

--
-- "!sr": what the asker reserved, and anything hard reserved for them.
--
pug.whispers.reserves = function(pol, uid, sender, nick)
  local cfg = pol.cfg
  local res = reserves_of(cfg)
  local soft, counts = {}, {}

  for _, id in ipairs((res and res.soft[uid]) or {}) do
    if (not counts[id]) then
      tinsert(soft, id)
    end

    counts[id] = (counts[id] or 0) + 1
  end

  local texts = {}

  for _, id in ipairs(soft) do
    tinsert(texts, (counts[id] > 1) and strfmt(L["%s (%dx)"], item_text(id), counts[id]) or item_text(id))
  end

  local hard = {}

  for id, hr in pairs((res and res.hard) or {}) do
    if (hr.uid == uid) then
      tinsert(hard, id)
    end
  end

  tsort(hard)

  if (#texts == 0 and #hard == 0) then
    konfer:SendWhisper(strfmt(L["PUG_RES_NONE"], nick), sender)
    return
  end

  if (#texts > 0) then
    konfer:SendWhisper(strfmt(L["PUG_RES_MINE"], nick, tconcat(texts, ", ")), sender)
  end

  for _, id in ipairs(hard) do
    konfer:SendWhisper(strfmt(L["PUG_RES_HARD_MINE"], nick, item_text(id)), sender)
  end
end

-- The help says how to ask, after everything the platform's says.
local platform_help = pug.whispers.help

pug.whispers.help = function(pol, uid, sender, nick, arg)
  platform_help(pol, uid, sender, nick, arg)
  konfer:SendWhisper(strfmt(L["PUG_HELP_RESERVES"], nick, konfer:WhisperCommand("reserves", pol)), sender)
end

--
-- READING AN EXPORT
--
-- softres.it's Gargul export is JSON, compressed with zlib and written out in base64. The game decodes the base64 and Kore's
-- LibDeflate the zlib. The JSON is read here: the game's own reader is proven on retail alone.
--

local json_value

local function json_skip(s, i)
  return strfind(s, "[^ \t\r\n]", i) or (#s + 1)
end

local JSON_ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8_char(cp)
  if (cp < 0x80) then
    return strchar(cp)
  elseif (cp < 0x800) then
    return strchar(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif (cp < 0x10000) then
    return strchar(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end

  return strchar(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40, 0x80 + floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40)
end

-- The string whose opening quote is at I, and where reading goes on after it.
local function json_string(s, i)
  local out = {}
  local j = i + 1

  while (true) do
    local c = strsub(s, j, j)

    if (c == "") then
      error("unterminated string")
    elseif (c == '"') then
      return tconcat(out), j + 1
    elseif (c == "\\") then
      local e = strsub(s, j + 1, j + 1)

      if (e == "u") then
        local cp = tonumber(strsub(s, j + 2, j + 5), 16)

        if (not cp) then
          error("bad escape")
        end

        j = j + 6

        -- A character outside the first plane comes as a pair of halves.
        if (cp >= 0xD800 and cp <= 0xDBFF and strsub(s, j, j + 1) == "\\u") then
          local lo = tonumber(strsub(s, j + 2, j + 5), 16)

          if (lo and lo >= 0xDC00 and lo <= 0xDFFF) then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + lo - 0xDC00
            j = j + 6
          end
        end

        tinsert(out, utf8_char(cp))
      elseif (JSON_ESCAPES[e]) then
        tinsert(out, JSON_ESCAPES[e])
        j = j + 2
      else
        error("bad escape")
      end
    else
      local k = strfind(s, '["\\]', j) or (#s + 1)

      tinsert(out, strsub(s, j, k - 1))
      j = k
    end
  end
end

json_value = function(s, i)
  i = json_skip(s, i)

  local c = strsub(s, i, i)

  if (c == "{") then
    local obj = {}

    i = json_skip(s, i + 1)

    if (strsub(s, i, i) == "}") then
      return obj, i + 1
    end

    while (true) do
      if (strsub(s, i, i) ~= '"') then
        error("expected a name")
      end

      local k, v

      k, i = json_string(s, i)
      i = json_skip(s, i)

      if (strsub(s, i, i) ~= ":") then
        error("expected a colon")
      end

      v, i = json_value(s, i + 1)
      obj[k] = v
      i = json_skip(s, i)
      c = strsub(s, i, i)

      if (c == "}") then
        return obj, i + 1
      elseif (c ~= ",") then
        error("expected a comma")
      end

      i = json_skip(s, i + 1)
    end
  elseif (c == "[") then
    local arr, n = {}, 0

    i = json_skip(s, i + 1)

    if (strsub(s, i, i) == "]") then
      return arr, i + 1
    end

    while (true) do
      local v

      v, i = json_value(s, i)
      n = n + 1
      arr[n] = v
      i = json_skip(s, i)
      c = strsub(s, i, i)

      if (c == "]") then
        return arr, i + 1
      elseif (c ~= ",") then
        error("expected a comma")
      end

      i = i + 1
    end
  elseif (c == '"') then
    return json_string(s, i)
  elseif (strsub(s, i, i + 3) == "true") then
    return true, i + 4
  elseif (strsub(s, i, i + 4) == "false") then
    return false, i + 5
  elseif (strsub(s, i, i + 3) == "null") then
    return nil, i + 4
  end

  local num = strmatch(s, "^-?[%d%.eE%+%-]+", i)
  local v = num and tonumber(num)

  if (not v) then
    error("unexpected character")
  end

  return v, i + #num
end

local function json_decode(s)
  local v, i = json_value(s, 1)

  if (json_skip(s, i) <= #s) then
    error("trailing characters")
  end

  return v
end

-- The game's class index for a class as softres.it writes it, "warrior" or "deathknight", nil where it means nothing.
local function softres_class(cls)
  return (type(cls) == "string") and K.ClassIndex[strupper(strgsub(cls, "[%s_]", ""))] or nil
end

--
-- What TEXT, a pasted export, holds: { id, soft, hard }, SOFT each reserver once, { name, class, items }, and HARD each hard
-- reserve, { id, who, note }. Nil and why, where it holds nothing that can be read as one.
--
local function read_export(text)
  text = strgsub(text or "", "%s+", "")

  if (text == "" or not C_EncodingUtil or not C_EncodingUtil.DecodeBase64) then
    return nil, L["PUG_RES_BAD"]
  end

  local ok, raw = pcall(C_EncodingUtil.DecodeBase64, text)
  local inflated = (ok and type(raw) == "string" and raw ~= "") and LibDeflate:DecompressZlib(raw) or nil
  local data

  if (type(inflated) == "string") then
    ok, data = pcall(json_decode, inflated)
  end

  if (not ok or type(data) ~= "table" or type(data.softreserves) ~= "table") then
    return nil, L["PUG_RES_BAD"]
  end

  local plan = { id = (type(data.metadata) == "table" and data.metadata.id) and tostring(data.metadata.id) or nil, soft = {},
    hard = {} }
  local byname = {}

  for _, e in ipairs(data.softreserves) do
    if (type(e) == "table" and type(e.name) == "string" and e.name ~= "" and type(e.items) == "table") then
      local who = byname[e.name]

      if (not who) then
        who = { name = e.name, class = softres_class(e.class), items = {} }
        byname[e.name] = who
        tinsert(plan.soft, who)
      end

      for _, it in ipairs(e.items) do
        local id = tonumber((type(it) == "table") and it.id or it)

        if (id and id > 0) then
          tinsert(who.items, floor(id))
        end
      end
    end
  end

  for _, e in ipairs((type(data.hardreserves) == "table") and data.hardreserves or {}) do
    local id = (type(e) == "table") and tonumber(e.id)

    if (id and id > 0) then
      tinsert(plan.hard, {
        id = floor(id),
        who = (type(e["for"]) == "string" and e["for"] ~= "") and e["for"] or nil,
        note = (type(e.note) == "string" and e.note ~= "") and e.note or nil,
      })
    end
  end

  return plan
end

--
-- WHO RESERVED
--
-- softres.it knows a raider by whatever they typed, which is often not quite the character's name. Each name is matched to
-- somebody, the people in the group first and then those the config already holds, three ways in turn, each taking only
-- what is left by the one before: the name as it is, ignoring case and realm; the name folded, accents and case and
-- everything that is not a letter taken away, so that Sorina with an accent is Sorina; and, for the group alone, a spelling
-- near enough, the same first letter and at most a quarter of the letters wrong, only one where the two classes are known
-- and differ. Nobody is matched to two names nor any name to two people, and where two pairings are as good as each other
-- neither is made. The master looter sees every match before anything is taken.
--

local FOLD_C0 = "aaaaaa*ceeeeiiiidnooooo-ouuuuy**"
local FOLD_E0 = "aaaaaa*ceeeeiiiidnooooo-ouuuuy*y"
local FOLD_MANY = { [0xC6] = "ae", [0xDE] = "th", [0xDF] = "ss", [0xE6] = "ae", [0xFE] = "th" }

local function fold(name)
  local s = strgsub(strlower(name), "\195([\128-\191])", function(b)
    local cp = 0xC0 + strbyte(b) - 0x80
    local map = (cp < 0xE0) and FOLD_C0 or FOLD_E0
    local ch = FOLD_MANY[cp] or strsub(map, (cp % 0x20) + 1, (cp % 0x20) + 1)

    return (ch == "-" or ch == "*") and "" or ch
  end)

  return (strgsub(s, "[^a-z]", ""))
end

-- The name without its realm, whichever realm that is, in lower case, for matching what was typed on softres.it.
local function bare(name)
  return strlower(K.ShortName(name))
end

-- Optimal string alignment distance between A and B: letters added, taken away, changed or two of them swapped.
local function distance(a, b)
  local la, lb = #a, #b
  local d = {}

  for i = 0, la do
    d[i] = { [0] = i }
  end

  for j = 0, lb do
    d[0][j] = j
  end

  for i = 1, la do
    for j = 1, lb do
      local cost = (strbyte(a, i) == strbyte(b, j)) and 0 or 1
      local v = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)

      if (i > 1 and j > 1 and strbyte(a, i) == strbyte(b, j - 1) and strbyte(a, i - 1) == strbyte(b, j)) then
        v = min(v, d[i - 2][j - 2] + 1)
      end

      d[i][j] = v
    end
  end

  return d[la][lb]
end

-- Everybody a name may be matched to: the group, and everybody CFG holds, each once.
local function candidates(cfg)
  local out, seen = {}, {}

  local function add(name, cls, group)
    if (not name) then
      return
    end

    if (seen[name]) then
      seen[name].group = seen[name].group or group
      return
    end

    local c = { name = name, class = cls, group = group, bare = bare(name) }

    c.fold = fold(c.bare)
    seen[name] = c
    tinsert(out, c)
  end

  for name, p in pairs(KRP.players or {}) do
    add(name, p.class, true)
  end

  for uid in pairs(cfg.uids) do
    add(cfg:UserNameClass(uid))
  end

  tsort(out, function(a, b) return a.name < b.name end)

  return out
end

--
-- Match each of NAMES, as typed on softres.it with the class there where it said one (CLASSES), to one of CANDS, other than
-- those already TAKEN: an array the same length, each { cand, near } or false, NEAR where it was only a spelling near enough.
--
local function match_names(names, classes, cands, taken)
  local result = {}

  taken = taken or {}

  -- One untaken candidate passing TEST, a group member before anybody else, or nil where there is none or more than one.
  local function only(test)
    local found, ngroup, nother = nil, 0, 0

    for _, c in ipairs(cands) do
      if (not taken[c] and test(c)) then
        if (c.group) then
          ngroup = ngroup + 1
          found = (ngroup == 1) and c or found
        elseif (ngroup == 0) then
          nother = nother + 1
          found = (nother == 1) and c or found
        end
      end
    end

    if (ngroup == 1 or (ngroup == 0 and nother == 1)) then
      return found
    end
  end

  local function claim(i, c, near)
    result[i] = { cand = c, near = near }
    taken[c] = true
  end

  for i, name in ipairs(names) do
    result[i] = false

    local full = strfind(name, "-", 1, true) and K.CanonicalName(name, nil)
    local c = only(function(c) return (full and c.name == full) or (not full and c.bare == bare(name)) end)

    if (c) then
      claim(i, c, false)
    end
  end

  local folds = {}

  for i, name in ipairs(names) do
    if (not result[i]) then
      local f = fold(bare(name))

      folds[f] = (folds[f] or 0) + 1
    end
  end

  for i, name in ipairs(names) do
    local f = fold(bare(name))

    if (not result[i] and f ~= "" and folds[f] == 1) then
      local c = only(function(c) return c.fold == f end)

      if (c) then
        claim(i, c, false)
      end
    end
  end

  -- Near spellings, for names written only in letters the fold knows.
  local pairs_ = {}

  for i, name in ipairs(names) do
    local b = bare(name)
    local f = fold(b)

    if (not result[i] and #f >= 2 and not strfind(b, "[\196-\244]")) then
      for _, c in ipairs(cands) do
        local len = max(#f, #c.fold)

        if (c.group and not taken[c] and #c.fold >= 2 and strsub(c.fold, 1, 1) == strsub(f, 1, 1) and len >= 4) then
          local allow = max(1, floor(len / 4))

          if (classes[i] and c.class and classes[i] ~= c.class) then
            allow = 1
          end

          local dist = distance(f, c.fold)

          if (dist <= allow) then
            tinsert(pairs_, { i = i, c = c, dist = dist })
          end
        end
      end
    end
  end

  tsort(pairs_, function(a, b)
    if (a.dist ~= b.dist) then
      return a.dist < b.dist
    elseif (a.i ~= b.i) then
      return a.i < b.i
    end

    return a.c.name < b.c.name
  end)

  local done = {}

  for _, p in ipairs(pairs_) do
    if (not done[p.i] and not taken[p.c]) then
      local rival = false

      for _, q in ipairs(pairs_) do
        if (q ~= p and q.dist == p.dist and not done[q.i] and not taken[q.c] and (q.i == p.i or q.c == p.c)) then
          rival = true
        end
      end

      done[p.i] = true

      if (rival) then
        taken[p.c] = true
      else
        claim(p.i, p.c, true)
      end
    end
  end

  return result
end

-- Who an admin has said each of CFG's names is (RAID.resfix).
local function fixes_of(cfg)
  local raid = cfg:PolicyData(pug.handle).raid

  return (raid and raid.resfix) or {}
end

-- The one of CANDS who is the uid UID in CFG, nil for nobody.
local function cand_of(cfg, cands, uid)
  local name = uid and cfg:UserName(uid)

  for _, c in ipairs(cands) do
    if (c.name == name) then
      return c
    end
  end
end

--
-- Each row of what the master looter is shown for PLAN, every name reserved under and then every hard reserve, each with
-- the entry of PLAN it is about, SRC, whose match is the raider shown and is what picking another raider for it changes.
--
local function plan_rows(plan)
  plan.rows = {}

  for _, s in ipairs(plan.soft) do
    tinsert(plan.rows, { typed = s.name, src = s })
  end

  for _, h in ipairs(plan.hard) do
    tinsert(plan.rows, { item = h.id, typed = h.who, src = h })
  end
end

--
-- The reserves PLAN holds, for CFG: every name reserved under and the person a hard reserve is for taken to be whoever an
-- admin has said it is tonight, FIXED, and otherwise matched (match_names), and each row of what the master looter is shown.
--
local function match_plan(cfg, plan)
  local cands = candidates(cfg)
  local fixes = fixes_of(cfg)
  local names, classes, which, taken = {}, {}, {}, {}

  plan.cands = cands

  local function fixed(src, typed)
    local fix = typed and fixes[strlower(typed)]

    if (fix == nil) then
      return false
    end

    src.match = fix and cand_of(cfg, cands, fix) or nil
    src.fixed = true

    if (src.match) then
      taken[src.match] = true
    end

    return true
  end

  for _, s in ipairs(plan.soft) do
    if (not fixed(s, s.name)) then
      tinsert(names, s.name)
      tinsert(which, s)
      classes[#names] = s.class
    end
  end

  local found = match_names(names, classes, cands, taken)
  local bytyped = {}

  for i, s in ipairs(which) do
    local m = found[i]

    s.match = m and m.cand or nil
    s.near = m and m.near or false
  end

  for _, s in ipairs(plan.soft) do
    bytyped[strlower(s.name)] = s.match
  end

  --
  -- Whom a hard reserve is for is free text on softres.it: a raider's name, or anything else at all. A name one of the soft
  -- reservers typed is whoever they were taken to be, and otherwise only the name as it is, or folded, is taken.
  --
  for _, h in ipairs(plan.hard) do
    if (h.who and not fixed(h, h.who)) then
      h.match = bytyped[strlower(h.who)]

      if (not h.match) then
        local f = fold(bare(h.who))

        for _, c in ipairs(cands) do
          if (not h.match and (c.bare == bare(h.who) or (f ~= "" and c.fold == f))) then
            h.match = c
          end
        end
      end
    end
  end

  plan_rows(plan)
end

--
-- CFG's reserves as a plan, for an admin to change who their names are: each taken to be whoever it is now, FIXED where that
-- is what an admin said.
--
local function current_plan(cfg)
  local res = reserves_of(cfg)
  local cands = candidates(cfg)
  local fixes = fixes_of(cfg)
  local plan = { id = res.id, at = res.at, soft = {}, hard = {}, cands = cands }

  for name, e in pairs(res.names or {}) do
    tinsert(plan.soft, { name = name, items = e.items, match = cand_of(cfg, cands, e.uid), fixed = fixes[strlower(name)] ~= nil })
  end

  tsort(plan.soft, function(a, b) return strlower(a.name) < strlower(b.name) end)

  for id, h in pairs(res.hard) do
    tinsert(plan.hard, { id = id, who = h.who, note = h.note, match = cand_of(cfg, cands, h.uid),
      fixed = (h.who and fixes[strlower(h.who)] ~= nil) and true or false })
  end

  tsort(plan.hard, function(a, b) return a.id < b.id end)
  plan_rows(plan)

  return plan
end

--
-- Take PLAN as CFG's reserves: everybody taken to be somebody in the group made a user where they are not one, then the
-- reserves themselves, and who an admin said a name is remembered for the rest of the raid.
--
local function take_plan(cfg, plan)
  local added = false

  local function add(c)
    if (c and c.group and not cfg:FindUser(c.name) and cfg:CreateNewUser(c.name, c.class, true, true)) then
      added = true
    end
  end

  for _, s in ipairs(plan.soft) do
    add(s.match)
  end

  for _, h in ipairs(plan.hard) do
    add(h.match)
  end

  if (added) then
    konfer:RefreshUsers()
    konfer:RefreshRaid()
    pug:CSendChannelAM(cfg.id, "RFUSR", "ALERT")
  end

  local fixes = K.CopyTable(fixes_of(cfg), {})
  local res = { id = plan.id, at = plan.at or K.time(), names = {}, hard = {} }

  for _, s in ipairs(plan.soft) do
    local uid = s.match and cfg:FindUser(s.match.name)

    res.names[s.name] = { uid = uid, items = s.items }

    if (s.handset) then
      fixes[strlower(s.name)] = uid or false
    end
  end

  for _, h in ipairs(plan.hard) do
    local uid = h.match and cfg:FindUser(h.match.name)

    res.hard[h.id] = { uid = uid, who = h.who, note = h.note }

    if (h.handset and h.who) then
      fixes[strlower(h.who)] = uid or false
    end
  end

  pug:SetReserves(cfg, res, fixes)
end

--
-- THE DIALOGS
--
-- Import asks for the export, and the second dialog shows what came of it, every name reserved under and the raider it was
-- taken to be, a near spelling marked as one, a name an admin has said who it is marked as set, somebody who will be made a
-- user marked as that, and anybody taken to be nobody. Picking a row and a raider in Raider under the list says who that name
-- is, and Accept takes it. Reassign on the tab puts up the same dialog over the reserves as they stand.
--

local IMPORT_W = 460
local IMPORT_H = 300
local MATCH_W = 600
local MATCH_H = 420
local LABEL_H = 16

local importdlg = nil
local matchdlg = nil

-- The policy window stands aside while either dialog is up, and comes back once neither is, Import handing over to the
-- matches without it showing in between.
local stood_aside = false

local function stand_aside()
  if (konfer.mainwin and konfer.mainwin:IsShown()) then
    konfer.mainwin:Hide()
    stood_aside = true
  end
end

local function come_back()
  if (stood_aside and not (importdlg and importdlg:IsShown()) and not (matchdlg and matchdlg:IsShown())) then
    stood_aside = false
    konfer.mainwin:Show()
  end
end

-- The choices in Raider for the row picked: nobody, everybody in the group, and whoever the row is now if that is somebody
-- else, each in class colour.
-- The box is as wide as the longest of them needs, the choices changing with the group.
local function fill_who(row)
  local items = { { value = 0, text = K.NOBODY_STR } }
  local words = { K.NOBODY_STR }
  local cur = row and row.src.match

  for _, c in ipairs(matchdlg.plan.cands) do
    if (c.group or c == cur) then
      tinsert(items, { value = c.name, text = aclass(c.name, c.class) })
      tinsert(words, K.DisplayName(c.name))
    end
  end

  matchdlg.who:SetWidth(KUI:DropDownWidth(words))
  matchdlg.who:UpdateItems(items)
  matchdlg.who:SetValue(cur and cur.name or 0, true)
  matchdlg.who:SetEnabled(row ~= nil)
end

local function show_match(cfg, plan)
  if (not matchdlg) then
    matchdlg = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE", name = "KonferPUGReserveMatches", title = pug:WindowTitle(L["Reserves"]), border = true,
      width = MATCH_W, height = MATCH_H, canmove = true, canresize = false, escclose = true, padding = KUI.WIDGET_GAP,
      okbutton = { text = L["Accept"] }, cancelbutton = true,
    })

    matchdlg.summary = KUI:CreateStringLabel({
      x = 0, y = 0, width = MATCH_W - matchdlg.rings.left - matchdlg.rings.right, height = LABEL_H, autosize = false,
      font = "GameFontNormal", justifyh = "LEFT", text = "",
    }, matchdlg)

    local foot = MakeFrame("Frame", nil, matchdlg.content)

    foot:SetPoint("BOTTOMLEFT", matchdlg.content, "BOTTOMLEFT", 0, 0)
    foot:SetPoint("BOTTOMRIGHT", matchdlg.content, "BOTTOMRIGHT", 0, 0)
    foot:SetHeight(KUI.DROPDOWN_HEIGHT)

    local holder = MakeFrame("Frame", nil, matchdlg.content)

    holder:SetPoint("TOPLEFT", matchdlg.content, "TOPLEFT", 0, 0 - matchdlg.summary:GetHeight() - KUI.WIDGET_GAP)
    holder:SetPoint("BOTTOMRIGHT", matchdlg.content, "BOTTOMRIGHT", 0, KUI.DROPDOWN_HEIGHT + KUI.WIDGET_GAP)

    matchdlg.list = KUI:CreateColumnList({
      name = "KonferPUGReserveMatchList",
      columns = {
        { key = "typed", text = L["Reserved as"], width = "fill" },
        { key = "raider", text = L["Raider"], width = "fill" },
        { key = "note", text = "", width = 140 },
      },
      setitem = function(cl, idx, slot, row)
        local r = matchdlg.plan.rows[idx]
        local c = r.src.match
        local notes = {}

        if (r.item) then
          tinsert(notes, L["Hard reserved"])
        elseif (not c) then
          tinsert(notes, "|cff808080" .. L["PUG_RES_ABSENT"] .. "|r")
        end

        if (r.src.fixed) then
          tinsert(notes, L["PUG_RES_FIXED"])
        elseif (r.src.near) then
          tinsert(notes, "|cffffff00" .. L["PUG_RES_NEAR"] .. "|r")
        end

        if (c and c.group and not konfer:PolicyConfig(pug, matchdlg.cfgid):FindUser(c.name)) then
          tinsert(notes, L["PUG_RES_NEW"])
        end

        row:SetCell("typed", r.item and item_text(r.item) or r.typed or "")
        row:SetCell("raider", c and aclass(c.name, c.class) or ((r.item and r.typed) or ""))
        row:SetCell("note", tconcat(notes, ", "))
      end,
      selectitem = function(cl, idx, slot, row, onoff)
        if (onoff) then
          matchdlg.picked = matchdlg.plan.rows[idx]
        elseif (onoff == nil) then
          matchdlg.picked = nil
        end

        fill_who(matchdlg.picked)
      end,
    }, holder)

    --
    -- Who the row picked is. Every other row about the same name follows it, a hard reserve for somebody being for whoever
    -- their name is, unless an admin has said otherwise for that row here.
    --
    matchdlg.who = KUI:CreateDropDown({
      x = 0, y = 0, name = "KonferPUGReserveWhoDD", itemheight = 16, dwidth = KUI:DropDownWidth({ K.NOBODY_STR }), mode = "SINGLE",
      items = KUI.emptydropdown, label = { text = L["Raider"], pos = "LEFT" },
      tooltip = { title = "$$", text = L["TIP_PUG_RES_WHO"] },
    }, foot)
    matchdlg.who:Catch("OnValueChanged", function(this, evt, value, user)
      local r = matchdlg.picked

      if (not user or not r) then
        return
      end

      local cand = nil

      for _, c in ipairs(matchdlg.plan.cands) do
        if (c.name == value) then
          cand = c
        end
      end

      local key = r.typed and strlower(r.typed)

      r.src.own = true

      for _, o in ipairs(matchdlg.plan.rows) do
        if (o == r or (key and o.typed and strlower(o.typed) == key and not o.src.own)) then
          o.src.match = cand
          o.src.near = false
          o.src.fixed = true
          o.src.handset = true
        end
      end

      matchdlg.list:UpdateList(#matchdlg.plan.rows)
    end)

    matchdlg.OnAccept = function(this)
      local cfg = konfer:PolicyConfig(pug, this.cfgid)

      if (cfg and konfer:PolicyAdmin(pug)) then
        take_plan(cfg, this.plan)
      end

      this:Hide()
    end

    matchdlg.OnCancel = function(this)
      this:Hide()
    end

    matchdlg:Catch("OnHide", function()
      come_back()
    end)
  end

  local nsoft = 0

  for _, s in ipairs(plan.soft) do
    nsoft = nsoft + #s.items
  end

  matchdlg.cfgid = cfg.id
  matchdlg.plan = plan
  matchdlg.picked = nil
  matchdlg.summary:SetText(counts_text(nsoft, #plan.soft, #plan.hard))
  matchdlg.list:UpdateList(#plan.rows)
  matchdlg.list:SetSelected(nil, false, true)
  fill_who(nil)
  stand_aside()
  matchdlg:Show()
end

local function show_import(cfg)
  if (not importdlg) then
    importdlg = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE", name = "KonferPUGImportReserves", title = pug:WindowTitle(L["Import reserves"]),
      border = true, width = IMPORT_W, height = IMPORT_H, canmove = true, canresize = false, escclose = true,
      padding = KUI.WIDGET_GAP, okbutton = { text = L["Import"] }, cancelbutton = true,
    })

    local w = IMPORT_W - importdlg.rings.left - importdlg.rings.right

    importdlg.prompt = KUI:CreateStringLabel({
      x = 0, y = 0, width = w, height = LABEL_H, autosize = false, font = "GameFontNormal", justifyh = "LEFT",
      text = L["PUG_RES_PASTE"],
    }, importdlg)

    importdlg.error = KUI:CreateStringLabel({
      x = 0, y = 0, width = w, height = LABEL_H, autosize = false, font = "GameFontNormal", justifyh = "LEFT", text = "",
      color = { r = 1, g = 0.2, b = 0.2 },
    }, importdlg)
    importdlg.error:ClearAllPoints()
    importdlg.error:SetPoint("BOTTOMLEFT", importdlg.content, "BOTTOMLEFT", 0, 0)

    importdlg.text = KUI:CreateTextArea({ name = "KonferPUGImportText", font = "GameFontHighlightSmall" }, importdlg.content)
    importdlg.text:ClearAllPoints()
    importdlg.text:SetPoint("TOPLEFT", importdlg.content, "TOPLEFT", 0, 0 - importdlg.prompt:GetHeight() - KUI.WIDGET_GAP)
    importdlg.text:SetPoint("BOTTOMRIGHT", importdlg.content, "BOTTOMRIGHT", 0, importdlg.error:GetHeight() + KUI.WIDGET_GAP)

    importdlg.OnAccept = function(this)
      local cfg = konfer:PolicyConfig(pug, this.cfgid)
      local plan, why = read_export(this.text:GetText())

      if (not plan) then
        this.error:SetText(why)
        return
      end

      if (cfg) then
        match_plan(cfg, plan)
        show_match(cfg, plan)
      end

      this:Hide()
    end

    importdlg.OnCancel = function(this)
      this:Hide()
    end

    importdlg:Catch("OnHide", function()
      come_back()
    end)
  end

  importdlg.cfgid = cfg.id
  importdlg.error:SetText("")
  importdlg.text:SetText("")
  stand_aside()
  importdlg:Show()
  importdlg.text:SetFocus()
end

--
-- THE RESERVES TAB
--
-- On the Raid page beside Raiders, and everybody's: each reserved item, hard reserves first, with who reserved it, in class
-- colour where they are here and grey where not, or whom a hard reserve is for. Pointing at a row shows the item, which ends
-- with the same. Under it the admins' Import, Reassign and Clear, and how much is reserved. Names are as the game shows them,
-- K.DisplayName. A cell is one line, so a long list of reservers ends in an ellipsis there, and the row's tooltip, the
-- item's, names every one.
--

local RES_BTN_H = 24
local RES_BTN_W = 100

local restab = nil
local resrows = {}

-- Listens for the names of items the client had not seen when the tab was drawn, while any are still missing.
local waiter = CreateFrame("Frame")

local function reserve_rows(cfg)
  local res = reserves_of(cfg)
  local rows, ids = {}, {}

  if (not res) then
    return rows, false
  end


  for _, items in pairs(res.soft) do
    for _, id in ipairs(items) do
      ids[id] = true
    end
  end

  for _, items in pairs(res.away) do
    for _, id in ipairs(items) do
      ids[id] = true
    end
  end

  for id in pairs(res.hard) do
    ids[id] = true
  end

  local missing = false

  for id in pairs(ids) do
    local name, link = C_Item.GetItemInfo(id)
    local who = {}

    if (not name) then
      missing = true
    end

    if (res.hard[id]) then
      tinsert(who, hard_text(cfg, res.hard[id]))
    end

    for _, r in ipairs(soft_reservers(cfg, id)) do
      tinsert(who, raider_text(cfg, r.uid, r.n))
    end

    for _, n in ipairs(away_reservers(cfg, id)) do
      tinsert(who, "|cff808080" .. n .. "|r")
    end

    tinsert(rows, {
      id = id, link = link, item = link or ("item:" .. id), sortitem = strlower(name or ""), who = tconcat(who, ", "),
      sortwho = strlower(strgsub(tconcat(who, ", "), "|c%x%x%x%x%x%x%x%x", "")), hard = res.hard[id] and 0 or 1,
    })
  end

  return rows, missing
end

local function refresh_reserves_tab(client)
  local pp = konfer.apol
  local cfg = (pp == pug) and pug.cfg or nil
  local res = reserves_of(cfg)
  local missing

  resrows, missing = reserve_rows(cfg)
  restab.list:Sort(resrows)
  restab.list:UpdateList(#resrows)

  if (missing) then
    waiter:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  else
    waiter:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
  end

  local admin = cfg and konfer:PolicyAdmin(pug) and true or false

  restab.import:SetEnabled(admin)
  restab.reassign:SetEnabled(admin and res ~= nil)
  restab.clear:SetEnabled(admin and res ~= nil)

  if (not res) then
    restab.status:SetText(L["Nothing reserved."])
    return
  end

  local nsoft, nraiders, nhard = 0, 0, 0

  for _, items in pairs(res.soft) do
    nsoft = nsoft + #items
    nraiders = nraiders + 1
  end

  for _, items in pairs(res.away) do
    nsoft = nsoft + #items
    nraiders = nraiders + 1
  end

  for _ in pairs(res.hard) do
    nhard = nhard + 1
  end

  restab.status:SetText(counts_text(nsoft, nraiders, nhard))
end

waiter:SetScript("OnEvent", function()
  if (restab) then
    refresh_reserves_tab(restab.client)
  end
end)

local function build_reserves_tab(client)
  local tf = client.hsplit.topframe
  local bf = client.hsplit.bottomframe

  restab = { client = client }

  -- Hard reserves first, the master looter's, then by the column chosen.
  local function by(field)
    return function(a, b)
      if (a.hard ~= b.hard) then
        return a.hard < b.hard
      end

      return a[field] < b[field]
    end
  end

  restab.list = KUI:CreateColumnList({
    name = "KonferPUGReservesList", sortkey = "item",
    columns = {
      { key = "item", text = L["Item"], width = "fill", sort = by("sortitem") },
      { key = "who", text = L["Reserved by"], width = "fill", sort = by("sortwho") },
    },
    setitem = function(cl, idx, slot, row)
      local r = resrows[idx]

      row.link = r.link
      row:SetCell("item", r.item)
      row:SetCell("who", r.who)
    end,
    newrow = function(cl, row)
      row:HookScript("OnEnter", function(this)
        if (this.link) then
          GameTooltip:SetOwner(this, "ANCHOR_BOTTOMLEFT", 0, 18)
          GameTooltip:SetHyperlink(this.link)
          GameTooltip:Show()
        end
      end)

      row:HookScript("OnLeave", function()
        GameTooltip:Hide()
      end)

      row:SetScript("OnClick", function(this)
        if (this.link and IsModifiedClick("CHATLINK")) then
          ChatFrameUtil.InsertLink(this.link)
        end
      end)
    end,
  }, tf)
  restab.list:Catch("OnSort", function()
    refresh_reserves_tab(client)
  end)

  restab.import = KUI:CreateButton({
    x = 0, y = 0, width = RES_BTN_W, height = RES_BTN_H, text = L["Import"],
    tooltip = { title = "$$", text = L["TIP_PUG_RES_IMPORT"] },
  }, bf)
  restab.import:Catch("OnClick", function()
    if (pug.cfg and konfer:PolicyAdmin(pug)) then
      show_import(pug.cfg)
    end
  end)

  restab.reassign = KUI:CreateButton({
    x = RES_BTN_W + KUI.WIDGET_GAP, y = 0, width = RES_BTN_W, height = RES_BTN_H, text = L["Reassign"],
    tooltip = { title = "$$", text = L["TIP_PUG_RES_REASSIGN"] },
  }, bf)
  restab.reassign:Catch("OnClick", function()
    local cfg = pug.cfg

    if (cfg and konfer:PolicyAdmin(pug) and reserves_of(cfg)) then
      show_match(cfg, current_plan(cfg))
    end
  end)

  restab.clear = KUI:CreateButton({
    x = 2 * (RES_BTN_W + KUI.WIDGET_GAP), y = 0, width = RES_BTN_W, height = RES_BTN_H, text = L["Clear"],
    tooltip = { title = "$$", text = L["TIP_PUG_RES_CLEAR"] },
  }, bf)
  restab.clear:Catch("OnClick", function()
    local cfg = pug.cfg

    if (not cfg or not konfer:PolicyAdmin(pug)) then
      return
    end

    K.ConfirmationDialog(konfer, { text = L["Clear"], owner = pug }, L["PUG_RES_CLEARMSG"],
      { L["Configuration: %s"], cfg.name }, function(kmod, cfgid)
        local cfp = konfer:PolicyConfig(pug, cfgid)

        if (cfp) then
          pug:SetReserves(cfp, nil)
        end
      end, cfg.id)
  end)

  restab.status = KUI:CreateStringLabel({
    x = 3 * (RES_BTN_W + KUI.WIDGET_GAP), y = 0, height = RES_BTN_H, autosize = false, font = "GameFontNormalSmall",
    justifyh = "RIGHT", text = "",
  }, bf)
  restab.status:ClearAllPoints()
  restab.status:SetPoint("TOPLEFT", bf, "TOPLEFT", 3 * (RES_BTN_W + KUI.WIDGET_GAP), 0)
  restab.status:SetPoint("BOTTOMRIGHT", bf, "BOTTOMRIGHT", 0, 0)

  refresh_reserves_tab(client)
end

tinsert(pug.RaidTabs, { name = "reserves", text = L["Reserves"], hsplit = { height = RES_BTN_H, topborder = false },
  Construct = build_reserves_tab, Refresh = refresh_reserves_tab })

-- @debug-start@
--
-- /kpug testreserves ITEM [N] makes up soft reserves on ITEM, a link or an id, from N people, 11 unless said: the config's
-- users who have not reserved it, those in the group first, then people Kore knows whom the config does not hold, reserving
-- as nobody here. They join whatever is reserved, on this client alone and without telling anybody, so that a long list of
-- reservers can be seen on the tab and in the tooltip. Clear or an import puts them away.
--
tinsert(pug.Commands, { word = "testreserves", args = L["item [count]"], help = L["TESTRES_HELP"], Run = function(input, p)
  local cfg = p.cfg
  local rest = strgsub(input or "", "|c.-|r", "")
  local id = tonumber(strmatch(input or "", "item:(%d+)"))
  local count

  if (id) then
    count = tonumber(strmatch(rest, "(%d+)"))
  else
    id, count = strmatch(rest, "^%s*(%d+)%s*(%d*)")
    id, count = tonumber(id), tonumber(count)
  end

  if (not id) then
    p:err(L["name an item to make up reserves on."])
    return
  end

  if (not konfer:PolicyAdmin(p)) then
    p:err(L["only an admin of the active configuration can make up reserves."])
    return
  end

  count = count or 11

  local raid = cfg:PolicyData(pug.handle).raid
  local cur = raid.res or {}
  local res = { id = cur.id, at = cur.at or K.time(), names = K.CopyTable(cur.names or {}, {}),
    hard = K.CopyTable(cur.hard or {}, {}) }
  local made = 0
  local uids = {}

  for uid in pairs(cfg.uids) do
    if (not has_item(cur.soft and cur.soft[uid], id)) then
      tinsert(uids, uid)
    end
  end

  tsort(uids, function(a, b)
    if (here(cfg, a) ~= here(cfg, b)) then
      return here(cfg, a)
    end

    return cfg:UserName(a) < cfg:UserName(b)
  end)

  for _, uid in ipairs(uids) do
    if (made < count) then
      local name = cfg:UserName(uid)

      res.names[name] = res.names[name] or { uid = uid, items = {} }
      tinsert(res.names[name].items, id)
      made = made + 1
    end
  end

  local strangers = {}

  for kuid, name in pairs(KU.kuids) do
    if (not cfg:FindKuid(kuid)) then
      tinsert(strangers, K.ShortName(name))
    end
  end

  tsort(strangers)

  for _, name in ipairs(strangers) do
    if (made < count and not res.names[name]) then
      res.names[name] = { items = { id } }
      made = made + 1
    end
  end

  pug:ApplyReserves(cfg, raid.started or K.time(), res, KRP.group_id)
  p:info(L["made up %d reserves on %s."], made, item_text(id))
end })
-- @debug-end@
