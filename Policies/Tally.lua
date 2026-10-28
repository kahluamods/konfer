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

local tinsert = table.insert
local tconcat = table.concat
local strfmt = string.format

--
-- THE TALLY
--
-- What tonight's wins have cost each raider, for a policy whose loot is rolled for: PUG, and Loot Council for whatever the
-- council leaves to a roll. What a config does with it is the kind of raid it runs. In a simple raid nothing, every roll
-- standing on its own. A +1 raid counts each raider's wins, the fewest winning, and a decay raid lowers the most each
-- winner may roll.
--
-- A policy hands tally:Setup its SPEC before it registers and tally:Events the registered policy, as points:Setup and
-- points:Events are handed theirs, and is given the raid itself, the settings, the hooks that make a roll cost, the Raid
-- page's columns and buttons, the question at login about a raid never ended, and the standing whisper. SPEC is:
--
--   tag       what the frames built here are named with, "Konfer" .. TAG .. "ResumeRaid"
--   events    the policy's names for the four events sent here: pen, del, grp and fin
--   priority  (cfg, uid, ilink) -> number, where UID stands in any roll on ILINK ahead of the +1s, lower first, the policy's
--             own reason for putting somebody ahead whatever their count: PUG's soft reserves. Nil for none
--   solo      whether the Raid page stays up out of a group (RaidPage.solo in Policy.lua)
--
-- Every method built onto the policy is one it has none of already, so a policy may answer any of the hooks its own way.
--
local tally = konfer.tally

local TYPE_SIMPLE = "simple"
local TYPE_PLUSONE = "plusone"
local TYPE_DECAY = "decay"

tally.TYPE_SIMPLE = TYPE_SIMPLE
tally.TYPE_PLUSONE = TYPE_PLUSONE
tally.TYPE_DECAY = TYPE_DECAY

-- What each is called, wherever it is chosen or shown.
local TYPE_NAMES = {
  [TYPE_SIMPLE] = L["Simple"],
  [TYPE_PLUSONE] = L["+1"],
  [TYPE_DECAY] = L["Decay"],
}

--
-- What a +1 or a decay raid counts its wins by: the raider, one count for each, or the category of roll, a count for each
-- category a box is ticked for, main spec, off spec, transmog and vanity.
--
local COUNT_RAIDER = "raider"
local COUNT_CATEGORY = "category"

--
-- The most a raider's penalties can come to and what each win adds to them. A +1 raid counts wins and a decay raid takes
-- points off a roll, so the two start differently, and picking either type puts its own pair in.
--
local TYPE_SCALES = {
  [TYPE_PLUSONE] = { max = 4, step = 1 },
  [TYPE_DECAY] = { max = 40, step = 10 },
}

-- The settings the tally keeps, each policy's own, a +1 raid counting by the raider unless told otherwise.
local DEFAULTS = {
  raid_type = TYPE_PLUSONE,
  count_by = COUNT_RAIDER,
  count_main = true,
  count_offspec = true,
  count_transmog = true,
  count_vanity = true,
  max_penalties = TYPE_SCALES[TYPE_PLUSONE].max,
  increase_by = TYPE_SCALES[TYPE_PLUSONE].step,
}

--
-- THE RAID
--
-- What tonight's raid has cost each raider is kept on the config, the policy's own data, rather than in the raid's memory,
-- so that it outlives a reload or a crash in a raid where nobody else may be keeping it. RAID.started is when it began, and
-- RAID.pen each raider's penalties by uid and then by what is counted, "all" counting by the raider and main, off, xmog and
-- vanity by category, each the points it comes to, +1s or the points taken off a roll. A raid begins with the first penalty,
-- reward or roll won (WINNING) and ends with End raid, or when an admin asked at login deletes it. A raider an admin takes
-- out of the group with Remove takes everything counted against them along. RAID.group is the id of the group it is being
-- run in (Kore's KRP.group_id), which is how a login back into that group knows to carry on without asking. Every change is
-- one event, pen for one raider's one count, del for a raider forgotten, grp for the raid carried on in another group and
-- fin for the end, so that every client holding the config keeps the same. A policy may keep more of tonight beside them,
-- PUG its reserves, and it all goes when the raid ends.
--
local PENALTY_KEYS = { all = true, main = true, off = true, xmog = true, vanity = true }

local T = {}

local function raid_of(pol, cfg)
  return cfg and cfg:PolicyData(pol.handle).raid
end

-- CFG's raid, the policy's own data on it.
function T:Raid(cfg)
  return raid_of(self, cfg)
end

-- The points UID's penalty under KEY comes to in CFG's raid, 0 for none.
function T:RaidPenalty(cfg, uid, key)
  local raid = raid_of(self, cfg)
  local pen = raid and raid.pen and raid.pen[uid]

  return pen and tonumber(pen[key]) or 0
end

function T:ApplyPenalty(cfg, started, uid, key, value, group)
  local raid = raid_of(self, cfg)

  if (not raid or type(uid) ~= "string" or not PENALTY_KEYS[key]) then
    return
  end

  raid.started = raid.started or started
  raid.group = group or raid.group
  raid.pen = raid.pen or {}
  raid.pen[uid] = raid.pen[uid] or {}
  raid.pen[uid][key] = (value > 0) and value or nil

  if (next(raid.pen[uid]) == nil) then
    raid.pen[uid] = nil
  end

  if (cfg:IsActive()) then
    konfer:RefreshPolicyPages()
  end
end

-- Set UID's penalty under KEY in CFG to VALUE points, beginning the raid if this is its first, and tell every client.
function T:SetPenalty(cfg, uid, key, value)
  local started = raid_of(self, cfg).started or K.time()

  self:ApplyPenalty(cfg, started, uid, key, value, KRP.group_id)
  cfg:AddEvent(self.tallyspec.events.pen, started, uid, key, value, KRP.group_id)
end

function T:ApplyRaidGroup(cfg, group)
  local raid = raid_of(self, cfg)

  if (raid and raid.started) then
    raid.group = group
  end
end

-- Continue CFG's raid in the group the player is in now, and tell every client.
function T:ContinueRaid(cfg)
  self:ApplyRaidGroup(cfg, KRP.group_id)
  cfg:AddEvent(self.tallyspec.events.grp, KRP.group_id or false)
end

function T:ApplyForgetRaider(cfg, uid)
  local raid = raid_of(self, cfg)

  if (raid and raid.pen and raid.pen[uid]) then
    raid.pen[uid] = nil

    if (cfg:IsActive()) then
      konfer:RefreshPolicyPages()
    end
  end
end

-- Forget everything CFG's raid has counted against UID, and tell every client. Only an admin's copy is the config's to change.
function T:ForgetRaider(cfg, uid)
  local raid = raid_of(self, cfg)

  if (cfg:MyStatus() and raid and raid.pen and raid.pen[uid]) then
    self:ApplyForgetRaider(cfg, uid)
    cfg:AddEvent(self.tallyspec.events.del, uid)
  end
end

function T:ApplyEndRaid(cfg)
  local pd = cfg and cfg:PolicyData(self.handle)

  if (pd) then
    pd.raid = {}

    if (cfg:IsActive()) then
      konfer:RefreshPolicyPages()
    end
  end
end

function T:EndRaid(cfg)
  self:ApplyEndRaid(cfg)
  cfg:AddEvent(self.tallyspec.events.fin)
end

--
-- THE RAID PAGE
--
-- The policy's part of the platform's Raid page (Raid.lua). After each raider's name comes what tonight's wins have cost
-- them, a column of its own for each thing the config counts: one for the raider, headed with the kind of raid, or one for
-- each category it counts by whose rolls the Loot tab takes. A simple raid counts nothing and has none. The list starts
-- sorted the way the raid wants seeing, by name in a simple raid, and otherwise the least penalised first. Under it Penalty
-- and Reward are about what tonight has cost those ticked, or else the raider picked, and End raid ends the raid, the
-- platform's Remove standing between them. Its title names the kind of raid the config runs, a simple raid's being plain.
--

--
-- The columns counted, each with the setting that says it is counted and the kind of roll the Loot tab has to take for it.
-- TEXT is the category's short name wherever one is shown, and HEADING the Raid page's column heading where that differs.
--
local RAID_CATS = {
  { key = "main", text = L["Main"], setting = "count_main", code = "M", phrase = L["main spec"] },
  { key = "off", text = L["Off"], setting = "count_offspec", kind = "offspec_rolls", code = "O", phrase = L["off spec"] },
  { key = "xmog", text = L["Mog"], setting = "count_transmog", kind = "transmog_rolls", code = "T", phrase = L["transmog"] },
  { key = "vanity", text = L["Van"], heading = L["Vanity"], setting = "count_vanity", kind = "vanity_rolls", code = "V",
    phrase = L["vanity"] },
}

--
-- What a raider's penalties under COLUMN come to, a count of +1s or the most they may roll in a hundred under decay. The one
-- column counting by the raider reads their one count. Anybody the config does not hold has none.
--
local function raid_penalty(pol, cfg, uid, column)
  local key = (column == TYPE_PLUSONE or column == TYPE_DECAY) and "all" or column
  local points = (cfg and uid) and pol:RaidPenalty(cfg, uid, key) or 0

  return (cfg and pol:Setting("raid_type", cfg.id) == TYPE_DECAY) and (100 - points) or points
end

-- What Penalty and Reward change for a raider: their one count counting by the raider, their main spec counting by category.
local function penalty_key(pol, cfg)
  return (pol:Setting("count_by", cfg.id) == COUNT_CATEGORY) and "main" or "all"
end

--
-- WINNING
--
-- In a +1 or decay raid every roll carries an award (RollAwards), and winning one is what costs a raider: their +1s go up, or
-- their range comes down, by the config's Increase by and no further than its Maximum. Counting by the raider every roll won
-- counts against their one count, and counting by category against the count of the kind won, a kind the config does not
-- count costing nothing. An item handed out by its own instructions, or claimed by the policy, is not a roll won and costs
-- nothing either. The same count decides their rolls: under +1 the fewest +1s win, the roll deciding only between raiders
-- level (RollPriority), and under decay nobody rolls higher than their range (RollCeiling). Undo gives a win back. A
-- Shift-opened roll carries no award and is a plain roll for everybody, and a simple raid counts nothing.
--

-- Which count winning a roll of KIND (its code) costs in CFG, nil where it costs nothing.
local function counted_key(pol, cfg, kind)
  if (not cfg or not kind or pol:Setting("raid_type", cfg.id) == TYPE_SIMPLE) then
    return nil
  end

  if (pol:Setting("count_by", cfg.id) ~= COUNT_CATEGORY) then
    return "all"
  end

  for _, c in ipairs(RAID_CATS) do
    if (c.code == kind) then
      return pol:Setting(c.setting, cfg.id) and c.key or nil
    end
  end

  return nil
end

-- What UID winning a roll of KIND costs in CFG: the count, what it comes to after and what it was before, nil for nothing.
local function win_cost(pol, cfg, uid, kind)
  local key = counted_key(pol, cfg, kind)

  if (not key) then
    return nil
  end

  local was = pol:RaidPenalty(cfg, uid, key)

  return key, math.min(was + pol:Setting("increase_by", cfg.id), pol:Setting("max_penalties", cfg.id)), was
end

function T:RollAwards(cfgid, listid, ilink)
  return self:Setting("raid_type", cfgid) ~= TYPE_SIMPLE
end

function T:RollCeiling(cfgid, uid, kind)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local key = counted_key(self, cfg, kind)

  if (not key or self:Setting("raid_type", cfgid) ~= TYPE_DECAY) then
    return nil
  end

  return 100 - self:RaidPenalty(cfg, uid, key)
end

--
-- The policy's own reason for putting somebody ahead comes before the +1s, in any roll (SPEC.priority, PUG's soft reserves):
-- each step of it outweighs any count of +1s. The +1s count only in a roll that carries an award.
--
local PRIORITY_STEP = 1000

function T:RollPriority(cfgid, uid, kind, ilink, awards)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local key = counted_key(self, cfg, kind)
  local extra = self.tallyspec.priority
  local prio = extra and (tonumber(extra(cfg, uid, ilink)) or 0) * PRIORITY_STEP or 0

  if (awards and key and self:Setting("raid_type", cfgid) == TYPE_PLUSONE) then
    prio = prio + self:RaidPenalty(cfg, uid, key)
  end

  return prio
end

-- The win costs the raider, beginning the raid if it is the first thing counted, and the undo token is what they had before.
function T:Award(cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local key, value, was = win_cost(self, cfg, uid, kind)

  if (not key or value == was) then
    return {}
  end

  if (nocmd) then
    self:ApplyPenalty(cfg, raid_of(self, cfg).started or K.time(), uid, key, value, KRP.group_id)
  else
    self:SetPenalty(cfg, uid, key, value)
  end

  return { { listid = listid, token = { key, was } } }
end

function T:UndoAward(cfgid, listid, uid, ilink, token, nocmd)
  local cfg = konfer:PolicyConfig(self, cfgid)

  if (not cfg or type(token) ~= "table" or not PENALTY_KEYS[token[1]]) then
    return
  end

  if (nocmd) then
    self:ApplyPenalty(cfg, raid_of(self, cfg).started or K.time(), uid, token[1], tonumber(token[2]) or 0)
  else
    self:SetPenalty(cfg, uid, token[1], tonumber(token[2]) or 0)
  end
end

--
-- A win's row says what it brought the winner to, "plusone" or "decay" with PDATA { count, value }, the value being the +1s
-- or the points off a roll after the win, and false for a win that cost nothing.
--
function T:HistoryEntry(cfgid, via, listid, uid, ilink, kind, cost)
  local cfg = konfer:PolicyConfig(self, cfgid)
  local key, value = win_cost(self, cfg, uid, kind)

  return (self:Setting("raid_type", cfgid) == TYPE_DECAY) and "decay" or "plusone", { key or false, value or false }
end

local function cat_of(key)
  for _, c in ipairs(RAID_CATS) do
    if (c.key == key) then
      return c
    end
  end
end

function T:HistoryText(cfgid, how, listid, pdata, colour)
  local key = type(pdata) == "table" and pdata[1]
  local value = type(pdata) == "table" and tonumber(pdata[2])

  if (not key or not value) then
    return L["Roll"], ""
  end

  local text = (how == "decay") and strfmt(L["Up to %d"], 100 - value) or strfmt("+%d", value)
  local cat = cat_of(key)

  if (cat) then
    text = text .. " " .. cat.text
  end

  return colour and konfer.white(text) or text, ""
end

function T:WinText(cfgid, how, listid, pdata, who, ilink)
  local key = type(pdata) == "table" and pdata[1]
  local value = type(pdata) == "table" and tonumber(pdata[2])
  local cat = key and cat_of(key)

  if (not key or not value) then
    return nil
  end

  if (how == "decay") then
    return cat and strfmt(L["TALLY_WIN_DECAY_CAT"], who, ilink, 100 - value, cat.phrase)
      or strfmt(L["TALLY_WIN_DECAY"], who, ilink, 100 - value)
  end

  return cat and strfmt(L["TALLY_WIN_PLUSONE_CAT"], who, ilink, value, cat.phrase)
    or strfmt(L["TALLY_WIN_PLUSONE"], who, ilink, value)
end

-- Which penalty columns CFG shows, as a set of keys, and the one the list starts sorted on with its way, nil for by name.
local function raid_columns(pol, cfg)
  local shown = {}
  local rtype = cfg and pol:Setting("raid_type", cfg.id)

  if (not cfg or rtype == TYPE_SIMPLE) then
    return shown, nil
  end

  if (pol:Setting("count_by", cfg.id) == COUNT_CATEGORY) then
    for _, c in ipairs(RAID_CATS) do
      if (pol:Setting(c.setting, cfg.id) and (not c.kind or cfg.settings[c.kind])) then
        shown[c.key] = true
      end
    end
  else
    shown[rtype] = true
  end

  local first = shown[rtype] and rtype

  for _, c in ipairs(RAID_CATS) do
    first = first or (shown[c.key] and c.key)
  end

  -- The least penalised first: the fewest +1s, or the highest a raider may still roll.
  return shown, first, rtype ~= TYPE_DECAY
end

--
-- What Penalty and Reward can move for raider R in CFG, their penalties as they stand, and nil where neither can do anything:
-- for an admin, in a raid that counts, about somebody the config holds.
--
local function raider_points(pol, cfg, r, admin)
  if (not cfg or not admin or not r or not r.uid or pol:Setting("raid_type", cfg.id) == TYPE_SIMPLE) then
    return nil
  end

  return pol:RaidPenalty(cfg, r.uid, penalty_key(pol, cfg))
end

-- Move raider R's penalty a step, DIR 1 for a penalty and -1 for a reward, never below none or past the maximum.
local function step_penalty(pol, cfg, r, dir)
  if (not r or not r.uid or not cfg) then
    return
  end

  local key = penalty_key(pol, cfg)
  local points = pol:RaidPenalty(cfg, r.uid, key)
  local step = pol:Setting("increase_by", cfg.id)
  local new = math.min(math.max(points + dir * step, 0), pol:Setting("max_penalties", cfg.id))

  if (new ~= points) then
    pol:SetPenalty(cfg, r.uid, key, new)

    -- The raid is warned where the raider now stands: their +1s, or the most they may roll, on main spec counting by category.
    local decay = pol:Setting("raid_type", cfg.id) == TYPE_DECAY
    local value = decay and (100 - new) or new

    local shown = K.DisplayName(r.name)

    if (key == "main") then
      konfer:SendWarning(strfmt(decay and L["TALLY_ANN_DECAY_CAT"] or L["TALLY_ANN_PLUSONE_CAT"], L["MODTITLE"], shown,
        value, L["main spec"]))
    else
      konfer:SendWarning(strfmt(decay and L["TALLY_ANN_DECAY"] or L["TALLY_ANN_PLUSONE"], L["MODTITLE"], shown, value))
    end
  end
end

local RAID_TITLES = {
  [TYPE_PLUSONE] = L["+1 Raid manager"],
  [TYPE_DECAY] = L["Decay Raid manager"],
}

--
-- Penalty and Reward want an admin and, among the raiders they act on, somebody the config holds in a raid that counts, with
-- room to go up or down, and move everybody who has. End raid is the config's admins', while there is a raid to end, and
-- asks first. Removing somebody forgets what tonight counted against them.
--
local function any_raider(pol, cfgid, raiders, admin, test)
  local cfg = konfer:PolicyConfig(pol, cfgid)

  for _, r in ipairs(raiders) do
    local points = raider_points(pol, cfg, r, admin)

    if (points and test(points)) then
      return true
    end
  end

  return false
end

local function step_raiders(pol, cfgid, raiders, dir)
  local cfg = konfer:PolicyConfig(pol, cfgid)

  for _, r in ipairs(raiders) do
    step_penalty(pol, cfg, r, dir)
  end
end

local function raid_page(pol, solo)
  local page = {
    solo = solo or nil,

    title = function(cfgid)
      return RAID_TITLES[pol:Setting("raid_type", cfgid)]
    end,

    columns = {
      { key = TYPE_PLUSONE, text = L["+1"] },
      { key = TYPE_DECAY, text = L["Decay"] },
    },

    Columns = function(cfgid)
      return raid_columns(pol, konfer:PolicyConfig(pol, cfgid))
    end,

    buttons = {
      { name = "penaltybtn", text = L["Penalty"], tip = L["TIP_TALLY_PENALTY"],
        Enabled = function(cfgid, raiders, admin)
          local most = pol:Setting("max_penalties", cfgid)

          return any_raider(pol, cfgid, raiders, admin, function(points) return points < most end)
        end,
        Click = function(cfgid, raiders)
          step_raiders(pol, cfgid, raiders, 1)
        end },
      { name = "rewardbtn", text = L["Reward"], tip = L["TIP_TALLY_REWARD"],
        Enabled = function(cfgid, raiders, admin)
          return any_raider(pol, cfgid, raiders, admin, function(points) return points > 0 end)
        end,
        Click = function(cfgid, raiders)
          step_raiders(pol, cfgid, raiders, -1)
        end },
      "remove",
      { name = "endbtn", text = L["End raid"], tip = L["TIP_TALLY_ENDRAID"],
        Enabled = function(cfgid, raiders, admin)
          return admin and raid_of(pol, konfer:PolicyConfig(pol, cfgid)).started ~= nil
        end,
        Click = function(cfgid, raiders)
          local cfg = konfer:PolicyConfig(pol, cfgid)

          if (cfg) then
            local began = konfer.white(date("%d %b %H:%M", raid_of(pol, cfg).started))

            K.ConfirmationDialog(konfer, { text = L["End raid"], owner = pol }, strfmt(L["TALLY_END_RAID"], began),
              { L["Configuration: %s"], cfg.name }, function()
                pol:EndRaid(cfg)
              end, nil, konfer.mainwin, 170)
          end
        end },
    },

    Removed = function(cfgid, uid)
      local cfg = konfer:PolicyConfig(pol, cfgid)

      if (cfg) then
        pol:ForgetRaider(cfg, uid)
      end
    end,
  }

  page.Row = function(cfgid, raider)
    local cfg = konfer:PolicyConfig(pol, cfgid)
    local out = {}

    for _, c in ipairs(page.columns) do
      out[c.key] = raid_penalty(pol, cfg, raider.uid, c.key)
    end

    return out
  end

  for _, c in ipairs(RAID_CATS) do
    tinsert(page.columns, { key = c.key, text = c.heading or c.text })
  end

  return page
end

--
-- THE ADMIN TAB
--
-- The tally's options for the config the Admin tab has selected, each held with the rest of the tab's changes until the tab
-- is saved (konfer:AdminPending): what kind of raid it is, and then what a +1 or a decay raid counts by, the raider or the
-- category of roll, and under that, set in, a box for each category, then on one row the most a raider's penalties can come
-- to and what each win adds, which picking +1 or Decay sets to that type's own (TYPE_SCALES). Each row's choices stand as
-- close to each other as the first is to its label, and the labels are one width so that what follows them starts together,
-- LABELS naming any the policy puts beside them so that its rows line up too. The widgets are kept on the policy, as
-- pol.cfgui, where the policy's RefreshConfigUI and EnableConfigUI find them through tally:RefreshConfigUI and
-- tally:EnableConfigUI, and ui.extra, a function the policy may set, is called whenever they are enabled again so that
-- its own rows follow.
--
-- What is counted means nothing in a simple raid, so it is dark there, the categories are dark unless counting by them, and
-- a category is dark where the config's Loot tab takes no rolls of its kind, which saving that tab puts back here.
--
local CATEGORY_INDENT = 20

-- Maximum and Increase by are each typed into a box of two digits and held between these.
local PENALTY_LO = 1
local PENALTY_HI = 99

local CATEGORIES = {
  { key = "count_main", text = L["Main spec"], col = 1, row = 1 },
  { key = "count_offspec", text = L["Off spec"], col = 2, row = 1, kind = "offspec_rolls" },
  { key = "count_transmog", text = L["Transmog"], col = 1, row = 2, kind = "transmog_rolls" },
  { key = "count_vanity", text = L["Vanity"], col = 2, row = 2, kind = "vanity_rolls" },
}

-- The width the labels down the tally's rows take, wide enough for LABELS as well.
function tally:LabelWidth(labels)
  local all = { L["Type"], L["Count by"], L["Maximum"] }

  for _, v in ipairs(labels or {}) do
    tinsert(all, v)
  end

  return KUI:WidestString(all, "GameFontNormal")
end

--
-- Build the tally's rows into PARENT from YPOS down, their labels LW wide, and answer the y the next row would go at.
--
function tally:ConfigUI(pol, parent, ypos, lw)
  local ui = {}

  pol.cfgui = ui

  local function held(key)
    return function(this, evt, value, user)
      if (user and ui.cfgid) then
        konfer:AdminPending():Set("p." .. key, value)
        ui.sync()
      end
    end
  end

  ui.rtype = KUI:CreateRadioGroup({
    x = 0, y = ypos, spacing = KUI.INTERNAL_GAP, initialvalue = TYPE_PLUSONE,
    label = { text = L["Type"], pos = "LEFT", width = lw },
    items = {
      { text = TYPE_NAMES[TYPE_PLUSONE], value = TYPE_PLUSONE },
      { text = TYPE_NAMES[TYPE_DECAY], value = TYPE_DECAY },
      { text = TYPE_NAMES[TYPE_SIMPLE], value = TYPE_SIMPLE },
    },
  }, parent)
  ui.rtype:Catch("OnValueChanged", function(this, evt, value, user)
    if (user and ui.cfgid) then
      local ap = konfer:AdminPending()
      local scale = TYPE_SCALES[value]

      ap:Set("p.raid_type", value)

      if (scale) then
        ap:Set("p.max_penalties", scale.max)
        ap:Set("p.increase_by", scale.step)
        ui.maximum:SetText(tostring(scale.max))
        ui.increase:SetText(tostring(scale.step))
      end

      ui.sync()
    end
  end)
  konfer:AdminPending():Watch(ui.rtype, "p.raid_type")

  ypos = ypos - ui.rtype:GetHeight() - KUI.WIDGET_GAP

  ui.countby = KUI:CreateRadioGroup({
    x = 0, y = ypos, spacing = KUI.INTERNAL_GAP, initialvalue = COUNT_RAIDER,
    label = { text = L["Count by"], pos = "LEFT", width = lw },
    items = {
      { text = L["Raider"], value = COUNT_RAIDER, tooltip = { title = L["Count by"], text = L["TIP_TALLY_COUNTBY"] } },
      { text = L["Category"], value = COUNT_CATEGORY, tooltip = { title = L["Count by"], text = L["TIP_TALLY_COUNTBY"] } },
    },
  }, parent)
  ui.countby:Catch("OnValueChanged", held("count_by"))
  konfer:AdminPending():Watch(ui.countby, "p.count_by")
  ypos = ypos - ui.countby:GetHeight() - KUI.WIDGET_GAP

  --
  -- The first column's boxes are made first, so the second can stand clear of the wider of them.
  --
  local colx = { CATEGORY_INDENT }
  local rowh = KUI.CHECKBOX_SIZE + KUI.WIDGET_GAP

  ui.cats = {}

  for _, col in ipairs({ 1, 2 }) do
    local widest = 0

    for _, c in ipairs(CATEGORIES) do
      if (c.col == col) then
        local box = KUI:CreateCheckBox({ x = colx[col], y = ypos - (c.row - 1) * rowh, label = { text = c.text } }, parent)

        box:Catch("OnValueChanged", function(this, evt, val, user)
          if (user and ui.cfgid) then
            konfer:AdminPending():Set("p." .. c.key, val and true or false)
          end
        end)
        konfer:AdminPending():Watch(box, "p." .. c.key)
        tinsert(ui.cats, { box = box, key = c.key, kind = c.kind })
        widest = math.max(widest, box:GetWidth())
      end
    end

    colx[col + 1] = colx[col] + widest + KUI.INTERNAL_GAP
  end

  ypos = ypos - 2 * rowh

  -- A box of two digits at X on this row for the tally's setting KEY, what is typed held between the two ends.
  local function number_box(key, x, label, tip)
    local box = KUI:CreateEditBox({
      x = x, y = ypos, numeric = true, len = 2, charwidth = 2, label = label, tooltip = { title = "$$", text = tip },
    }, parent)

    box:Catch("OnValueChanged", function(this, evt, newv, user)
      if (user and ui.cfgid) then
        konfer:AdminPending():Set("p." .. key,
          math.min(math.max(tonumber(newv) or PENALTY_LO, PENALTY_LO), PENALTY_HI))
      end
    end)
    konfer:AdminPending():Watch(box, "p." .. key)

    return box
  end

  ui.maximum = number_box("max_penalties", 0, { text = L["Maximum"], pos = "LEFT", width = lw }, L["TIP_TALLY_MAXIMUM"])

  -- Increase by follows Maximum's box along the row, as far past it as DKP's two amounts on a row stand apart.
  ui.increase = number_box("increase_by", lw + KUI.INTERNAL_GAP + ui.maximum:GetWidth() + 12,
    { text = L["Increase by"], pos = "LEFT" }, L["TIP_TALLY_INCREASE"])
  ypos = ypos - ui.maximum:GetHeight() - KUI.WIDGET_GAP

  ui.sync = function()
    local cfp = ui.cfgid and konfer:PolicyConfig(pol, ui.cfgid)
    local ap = konfer:AdminPending()
    local on = (cfp and ui.enabled) and true or false
    local counted = on and ap:Value("p.raid_type") ~= TYPE_SIMPLE
    local bycat = counted and ap:Value("p.count_by") == COUNT_CATEGORY

    ui.rtype:SetEnabled(on)
    ui.countby:SetEnabled(counted)
    ui.maximum:SetEnabled(counted)
    ui.increase:SetEnabled(counted)

    for _, c in ipairs(ui.cats) do
      c.box:SetEnabled((bycat and (not c.kind or cfp.settings[c.kind])) and true or false)
    end

    if (ui.extra) then
      ui.extra(on, cfp)
    end
  end

  return ypos
end

-- Put CFGID's values back into the tally's rows, from AdminPending's Value so that an unsaved change still shows.
function tally:RefreshConfigUI(pol, cfgid)
  local ui = pol.cfgui

  if (not ui or not konfer:PolicyConfig(pol, cfgid)) then
    return false
  end

  local ap = konfer:AdminPending()

  ui.cfgid = cfgid
  ui.rtype:SetValue(ap:Value("p.raid_type"), true)
  ui.countby:SetValue(ap:Value("p.count_by"), true)
  -- An edit box throws whenever its text is set, with USER false, which the tab takes as no edit.
  ui.maximum:SetText(tostring(ap:Value("p.max_penalties")))
  ui.increase:SetText(tostring(ap:Value("p.increase_by")))

  for _, c in ipairs(ui.cats) do
    c.box:SetChecked(ap:Value("p." .. c.key), true)
  end

  return true
end

-- The options are about the config the tab has selected, so with none they are about nothing and cannot be used.
function tally:EnableConfigUI(pol, onoff, cfgid)
  local ui = pol.cfgui

  if (not ui) then
    return
  end

  if (not onoff) then
    ui.cfgid = nil
  end

  ui.enabled = onoff and true or false
  ui.sync()
end

--
-- An admin of a config still holding a raid at login is asked about it only when the player is not in the group it was
-- being run in, the group having broken up, or the player having been dropped from it while away, or reformed it as a new
-- one. Back in the same group, after a reload or a dropped connection, it simply carries on. Asked, the player may resume
-- it, every raider's penalties kept and the raid carried on in the group they are in now, or delete it, which ends it for
-- everybody holding the config and is how what was left from before is got rid of. One question for each such config, one
-- after another. Escape answers neither and leaves the raid for the next login to ask about.
--
local RESUME_W = 360

local function ask_resume(pol, cfg, after)
  local dlg = pol.resumedlg

  if (not dlg) then
    dlg = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE", name = "Konfer" .. pol.tallyspec.tag .. "ResumeRaid",
      title = pol:WindowTitle(L["Raid in progress"]), border = true, width = RESUME_W, height = 160, canmove = true,
      canresize = false, escclose = true, padding = KUI.WIDGET_GAP, okbutton = { text = L["Resume"] },
      cancelbutton = { text = L["Delete"] },
    })

    dlg.text = KUI:CreateStringLabel({
      x = 0, y = 0, width = RESUME_W - dlg.rings.left - dlg.rings.right, autosize = false, font = "GameFontNormal",
      justifyh = "LEFT", justifyv = "TOP", text = "",
    }, dlg)

    dlg.OnAccept = function(this)
      pol:ContinueRaid(this.cfg)
      this:Hide()
    end

    -- Delete ends the raid before the dialog goes, so that the question after it never meets this one's config.
    dlg.OnCancel = function(this)
      pol:EndRaid(this.cfg)
      this:Hide()
    end

    dlg:Catch("OnHide", function(this)
      local nextq = this.after

      this.after = nil

      if (nextq) then
        nextq()
      end
    end)

    pol.resumedlg = dlg
  end

  local raid = raid_of(pol, cfg)

  dlg.cfg = cfg
  dlg.after = after
  dlg.text:SetText(strfmt(L["TALLY_RESUME_RAID"], cfg.name, date("%d %b %H:%M", raid.started)))

  local th = dlg.text.label:GetStringHeight()

  dlg.text:SetHeight(th)
  dlg:SetHeight(dlg.rings.top + th + dlg.rings.bottom)
  dlg:Show()
end

local function startup_dialog(pol, after)
  local held = {}

  for _, cfg in pairs(konfer:PolicyConfigs(pol)) do
    local raid = raid_of(pol, cfg)

    if (cfg:MyStatus() and raid.started and not (raid.group and raid.group == KRP.group_id)) then
      tinsert(held, cfg)
    end
  end

  if (#held == 0) then
    return false
  end

  local n = 0

  local function nextq()
    n = n + 1

    if (held[n]) then
      ask_resume(pol, held[n], nextq)
    else
      after()
    end
  end

  nextq()

  return true
end

--
-- Build the tally onto POL, a policy's descriptor, before it registers. SPEC is as the top of this file has it. Every setting
-- the policy's defaults leave out is added to them and the raid to its configdata, and every method above, the Raid page and
-- the question at login go onto the policy wherever it has none of its own.
--
function tally:Setup(pol, spec)
  pol.tallyspec = spec

  for k, fn in pairs(T) do
    if (pol[k] == nil) then
      pol[k] = fn
    end
  end

  pol.defaults = pol.defaults or {}

  for k, v in pairs(DEFAULTS) do
    if (pol.defaults[k] == nil) then
      pol.defaults[k] = v
    end
  end

  pol.configdata = pol.configdata or {}

  if (pol.configdata.raid == nil) then
    pol.configdata.raid = {}
  end

  pol.RaidPage = pol.RaidPage or raid_page(pol, spec.solo)

  if (pol.StartupDialog == nil) then
    pol.StartupDialog = startup_dialog
  end
end

--
-- THE EVENTS
--
-- pen started uid key points group
--   UID's penalty under KEY in the config's raid now comes to POINTS, the raid having begun at STARTED and being run in the
--   group whose id is GROUP, nil where the sender's game had not said.
-- del uid
--   Everything the config's raid has counted against UID is forgotten, the raider having been taken out of the group.
-- grp group
--   The config's raid carries on in the group whose id is GROUP, false for none.
-- fin
--   The config's raid is over, and everything it counted goes with it.
--
-- Each goes into POL's own copy of the standard set under the policy's own name for it, from its spec. And the standing
-- whisper is answered with what tonight's wins have cost the asker, a roll having no standing: their +1s, or the most they
-- may now roll under decay, for each thing counted that has cost them anything, or that nothing has yet.
--
function tally:Events(pol)
  local ev = pol.tallyspec.events

  pol.ehandlers[ev.pen] = function(self, live, sender, proto, p, cmd, cfg, started, uid, key, points, group)
    p:ApplyPenalty(cfg, tonumber(started) or K.time(), uid, key, tonumber(points) or 0, group)
  end

  pol.ehandlers[ev.grp] = function(self, live, sender, proto, p, cmd, cfg, group)
    p:ApplyRaidGroup(cfg, group or nil)
  end

  pol.ehandlers[ev.del] = function(self, live, sender, proto, p, cmd, cfg, uid)
    p:ApplyForgetRaider(cfg, uid)
  end

  pol.ehandlers[ev.fin] = function(self, live, sender, proto, p, cmd, cfg)
    p:ApplyEndRaid(cfg)
  end

  pol.whispers.standing = function(p, uid, sender, nick)
    local cfg = p.cfg
    local rtype = cfg and p:Setting("raid_type", cfg.id)
    local decay = rtype == TYPE_DECAY
    local parts = {}

    local function said(points)
      return tostring(decay and (100 - points) or points)
    end

    if (cfg and uid and rtype ~= TYPE_SIMPLE) then
      if (p:Setting("count_by", cfg.id) == COUNT_CATEGORY) then
        for _, c in ipairs(RAID_CATS) do
          local points = p:RaidPenalty(cfg, uid, c.key)

          if (points > 0) then
            tinsert(parts, c.text .. " " .. said(points))
          end
        end
      elseif (p:RaidPenalty(cfg, uid, "all") > 0) then
        tinsert(parts, said(p:RaidPenalty(cfg, uid, "all")))
      end
    end

    if (#parts == 0) then
      konfer:SendWhisper(strfmt(L["TALLY_NO_COSTS"], nick), sender)
    else
      konfer:SendWhisper(strfmt(decay and L["TALLY_COST_DECAY"] or L["TALLY_COST_PLUSONE"], nick, tconcat(parts, ", ")),
        sender)
    end
  end
end
