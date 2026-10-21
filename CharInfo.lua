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
local KRP = konfer.KRP

local tinsert = table.insert
local tsort = table.sort
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs
local pairs = pairs
local type = type
local strfmt = string.format
local strlower = string.lower
local max = math.max

--
-- THE CHARACTER INFO CHECK
--
-- One round trip that answers everything a raid leader wants to know about the people around them before a raid starts.
-- konfer:AskCharacterInfo(mods, extras) asks the group, or the guild, and everybody answers about themselves.
--
-- It is this mod's, not Kore's. A map mod has no use for it, and Kore is a transport and a set of shared facts and nothing
-- more. What it asks after is deliberately wider than this mod, though. The mods named may be any KahLua mod on the
-- answering client, because the question "what is everybody running" is asked once and answered for the whole suite.
--
--   MODS    An array of KahLua mod handles to report the version of, "konfer" or "kartographer", exactly as each registered
--           with K:RegisterMod. A mod that is not running on the answering client is simply not in the reply, which is the
--           truth wanted, a mod that is switched off being a mod that is not there. The single entry "*" asks for every
--           KahLua mod the answering client is running, however many that turns out to be, which is why the window builds
--           its rows as a tree and not a column per mod.
--
--   EXTRAS  What else to report, keyed by name because an extra may carry arguments of its own. "specs" and "profs" are
--           flags. An extra this client has never heard of is ignored rather than refused, because the set grows and an
--           older copy meeting a newer one is not a protocol mismatch, unlike a command it does not know.
--
-- Everybody's class, race and level always travel. They are one number each, the game always knows them for the character
-- answering, and there is nothing about them to decide.
--
-- A reply names which extras it actually answered, so that a caller can tell "no professions" apart from "did not
-- understand professions" and leave the cell empty rather than say the wrong thing.
--
-- What a character reports about itself stays in Kore, in K.MyRoles, K.MyProfessions and K.MyFacts, because it is a fact
-- about the player's own character that any KahLua mod may want and it is kept in Kore's own database. Only the asking, the
-- answering and the window are here.
--
-- The check travels under this mod's own comms prefix, so a check reaches the mod that asked and not every KahLua mod on
-- the client at once. konfer:AnswerCharacterInfo and konfer:AckCInfo are what the CINFO and CIACK handlers in
-- Comms.lua call, and konfer:AskCharacterInfo is what "/konfer raidinfo" and "/konfer versioncheck" run.
--

local CIWIN_WIDTH  = 620
local CIWIN_HEIGHT = 400
local CI_SPEC_W    = 110

-- Where a player gets this mod, for the reminder sent to a group.
local CI_URL = "https://www.curseforge.com/wow/addons/konfer"

--
-- How far a child row's words are set in from its parent's.
--
local CI_TREE_LEAD = 12

--
-- THE EXTRAS
--
-- One entry per defined extra, answering it into the reply. An extra not in here is one this client has never heard of and
-- is passed over in silence. A later extra taking arguments, a list of spell ids to look for, reads them from its value.
--
local extras = {
  -- A player's specs are the roles they raid in, so that is what this answers.
  specs = function(ans, val)
    local msrole, osrole = K.MyRoles()

    ans.specs = { msrole, osrole }
  end,

  profs = function(ans, val)
    local pprof, sprof = K.MyProfessions()

    ans.profs = { pprof, sprof }
  end,
}

--
-- The columns an extra puts on the window, in the order they are drawn. They are added to the list the first time a check
-- asks for that extra and hidden again when one does not, so a window reused for a different question does not keep the
-- columns of the last one. Professions are asked after for the user records and put nothing here.
--
local extra_columns = {
  specs = {
    { key = "msspec", text = L["CI_COL_MSSPEC"], width = CI_SPEC_W, sort = true },
    { key = "osspec", text = L["CI_COL_OSSPEC"], width = CI_SPEC_W, sort = true },
  },
}

--
-- Level always travels, but a caller asking only after versions does not want a column about people's characters in the
-- answer, so it is shown only when the check asked for anything about a character at all. Race travels too, for the user
-- records, and is not worth a column.
--
local fact_columns = {
  { key = "level", text = L["CI_COL_LEVEL"], width = 50, sort = function(a, b)
    return (tonumber(a.level) or 0) < (tonumber(b.level) or 0)
  end },
}

--
-- WHO MAY ASK
--
-- The gate is about the ask and never about the answer. A check makes everybody it reaches whisper back, so the question is
-- whether this player may make a whole guild do that, and the size of the reply has nothing to do with it. That is why a
-- plain version check is gated exactly as one asking after specs is.
--

local function where_to_ask()
  if (KRP.in_party and (KRP.is_pl or KRP.is_aorl)) then
    return "GROUP"
  end

  if (K.player.is_guilded and K.UserIsRanked(K.player.name)) then
    return "GUILD"
  end

  if (KRP.in_party) then
    return nil, L["CI_NOT_LEADER"]
  end

  if (K.player.is_guilded) then
    return nil, L["CI_NOT_OFFICER"]
  end

  return nil, L["CI_NOBODY"]
end

--
-- "YOU ARE THE ONE WHO IS BEHIND"
--
-- The window's colouring answers who needs nagging, which is a question about other people. It cannot also answer whether
-- the player is themselves out of date, so that is said separately and plainly, to everybody who hears a check answered and
-- not only to whoever asked. Anybody can claim any version, so one person claiming a later one is not enough: it takes two
-- different people, and the version named is the newest that two of them run. 0 is a development copy, at either end. Ours
-- is never behind anything, being newer than every release by construction, and theirs is not a release to go and get.
--
-- Said once a session for each mod, so that every check after the first, before there has been a chance to update, says
-- nothing. What has been heard is kept for the session alone and goes with it.
--
local ci_later = {}
local ci_warned = {}
local update_dlg

local function update_notice(title, version, running)
  konfer:InTurn(function(after)
    if (not update_dlg) then
      update_dlg = KUI:CreateDialogFrame({
        name = konfer.comms.handle .. "UpdateDialog",
        x = "CENTER", y = "MIDDLE", border = true, blackbg = true,
        okbutton = true, canmove = true, canresize = false,
        escclose = true, width = 450, height = 100, title = "",
      })

      update_dlg.str1 = KUI:CreateStringLabel({
        x = 8, y = -10, width = 410, height = 64, autosize = false,
        color = { r = 1, g = 0, b = 0, a = 1 }, text = "", font = "GameFontNormal", justifyv = "TOP",
      }, update_dlg)

      update_dlg:Catch("OnHide", function(this)
        local done = this.after

        this.after = nil

        if (done) then
          done()
        end
      end)
    end

    update_dlg.after = after
    update_dlg:SetTitleText(K.WindowTitle(nil, title))
    update_dlg.str1:SetText(strfmt(L["CI_UPDATE_AVAILABLE"], title, K.VersionString(version), K.VersionString(running)))
    update_dlg:Show()
    return true
  end)
end

local function later_version_seen(sender, handle, title, version)
  local mine = K.mods[handle]

  if (not mine or mine.version == 0 or version == 0 or version <= mine.version or ci_warned[handle]) then
    return
  end

  local seen = ci_later[handle] or {}
  local versions = {}

  ci_later[handle] = seen
  seen[sender] = version

  for _, v in pairs(seen) do
    tinsert(versions, v)
  end

  if (#versions < 2) then
    return
  end

  tsort(versions, function(a, b) return a > b end)
  ci_warned[handle] = true
  update_notice(title, versions[2], mine.version)
end

--
-- THE WINDOW
--
-- One per asking mod, named after it, built the first time that mod asks. It shows the same answer two ways. Without
-- SHOWMODS it is a row per person, whose version is that of the mod that asked. With it, each of the mods a person answered
-- with is a child of their row and carries its own version, and the person's row has none. That is what lets "*" answer
-- with however many mods a client happens to run without the window having to be as wide as the widest possible answer.
--

-- A spec, the role a player raids in, in words, or nothing for one not set.
local function spec_name(role)
  return (role and role ~= K.ROLE_UNSET and K.RoleName(role)) or ""
end

--
-- The flat list of rows the scroll list draws, built from the people. Where the window shows mods, each person is followed
-- by theirs, the last of them marked so that the tree connector closes off.
--
local function ci_flatten(cidlg)
  local rows = {}

  for _, who in ipairs(cidlg.people) do
    tinsert(rows, who)

    if (cidlg.showmods) then
      for i, mod in ipairs(who.mods) do
        mod.tree = (i == #who.mods) and "end" or "branch"
        tinsert(rows, mod)
      end
    end
  end

  cidlg.rows = rows
end

--
-- People first, then whatever the header is sorted on. A child never sorts: it belongs to its parent and follows it.
--
local function ci_refresh(cidlg)
  local key, ascending = cidlg.list:GetSort()
  local col

  for _, c in ipairs(cidlg.list.columns) do
    if (c.key == key) then
      col = c
    end
  end

  if (col and col.sort) then
    local less = (type(col.sort) == "function") and col.sort or function(a, b)
      local va, vb = a[key], b[key]

      if (type(va) == "number" and type(vb) == "number") then
        return va < vb
      end

      return strlower(tostring(va or "")) < strlower(tostring(vb or ""))
    end

    tsort(cidlg.people, function(a, b)
      if (ascending) then
        return less(a, b)
      end

      return less(b, a)
    end)
  end

  local selected = cidlg.selected

  ci_flatten(cidlg)
  cidlg.list:UpdateList(#cidlg.rows)

  -- Updating the list drops the selection, and a reply may have moved the person selected, so they are found again.
  for i, r in ipairs(cidlg.rows) do
    if (r == selected) then
      cidlg.list:SetSelected(i, false)
    end
  end
end

--
-- A version as it is drawn: red when it is behind the copy we run ourselves, green when it is not, and plain when it is
-- something we do not run at all and so have nothing to measure it against. Nothing at all for somebody who has not answered yet.
--
local function version_text(handle, version)
  if (not version) then
    return ""
  end

  --
  -- A development copy is not coloured either way, at either end: it is neither behind a release nor ahead of one in any
  -- sense worth painting, and K.VersionString writes it as a word rather than as the 0 it carries.
  --
  local mine = handle and K.mods[handle]

  if (version == 0 or not mine or mine.version == 0) then
    return K.VersionString(version)
  end

  return ((version < mine.version) and K.red or K.green)(K.VersionString(version))
end

-- Whether WHO is behind on the mod that asked and can be told so: a released copy at both ends, and theirs the older.
local function out_of_date(cidlg, who)
  local mine = K.mods[cidlg.deciding]
  local version = who and who.version

  return (mine and version and version ~= 0 and mine.version ~= 0 and version < mine.version) and true or false
end

local function create_ci_window()
  local cidlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = konfer.comms.handle .. "CharInfo",
    title = konfer:WindowTitle(L["CITITLE"]), border = true, width = CIWIN_WIDTH, height = CIWIN_HEIGHT,
    canmove = true, canresize = false, escclose = true, xbutton = true, okbutton = true,
  })

  local panel = KUI:CreateInset({}, cidlg)
  panel:ClearAllPoints()
  panel:SetAllPoints(cidlg.content)

  local numw = KUI:WidestString({ L["Version"], "000000" })
  local uw = L["Update whisper"]

  -- At the other end of the foot from OK, for the person selected when they are out of date.
  cidlg.update = KUI:CreateButton({ width = max(100, KUI:WidestString({ uw }) + 4 * KUI.WIDGET_GAP), text = uw }, cidlg)
  cidlg.update:ClearAllPoints()
  cidlg.update:SetPoint("TOPLEFT", cidlg.content, "BOTTOMLEFT", KUI.WIDGET_GAP, 0)
  cidlg.update:SetEnabled(false)
  cidlg.update:Catch("OnClick", function(this)
    local who = cidlg.selected
    local mine = K.mods[cidlg.deciding]

    if (out_of_date(cidlg, who)) then
      konfer:SendWhisper(strfmt(L["CI_UPDATE_AVAILABLE"], mine.title, K.VersionString(mine.version),
        K.VersionString(who.version)), who.key)
    end
  end)

  local rw = L["Remind everyone"]

  -- Beside it, for the whole group a check was asked of: a raid warning in a raid, and said plainly in a party.
  cidlg.remind = KUI:CreateButton({ width = max(100, KUI:WidestString({ rw }) + 4 * KUI.WIDGET_GAP), text = rw }, cidlg)
  cidlg.remind:ClearAllPoints()
  cidlg.remind:SetPoint("TOPLEFT", cidlg.update, "TOPRIGHT", KUI.WIDGET_GAP, 0)
  cidlg.remind:SetEnabled(false)
  cidlg.remind:Catch("OnClick", function(this)
    local text = strfmt(L["CI_REMIND"], K.mods[cidlg.deciding].title, CI_URL)

    if (KRP.in_raid) then
      konfer:SendWarning(text)
    else
      konfer:SendText(text)
    end
  end)

  --
  -- The version column decides the order the window opens in, and it sorts on more than the number. Somebody who is behind
  -- on the mod that asked, or who does not run it at all, comes first however new everything else they have is, because the
  -- whole reason for running a check is to find them.
  --
  cidlg.list = KUI:CreateColumnList({
    name = konfer.comms.handle .. "CharInfoList",
    sortkey = "version",
    columns = {
      { key = "who", text = L["Who"], width = "fill", sort = true },
      { key = "version", text = L["Version"], width = numw, sort = function(a, b)
        if (a.behind ~= b.behind) then
          return a.behind and true or false
        end

        return (a.version or 0) < (b.version or 0)
      end },
    },
    setitem = function(objp, idx, slot, row)
      local r = cidlg.rows[idx]

      -- Only a person can be selected. A mod's row is about them and has nothing of its own to do.
      row:EnableMouse(not r.tree)
      row:SetTree(r.tree, CI_TREE_LEAD)
      row:SetCell("who", r.who)
      row:SetCell("version", (cidlg.showmods and not r.tree) and "" or version_text(r.handle, r.version))

      for _, key in ipairs({ "level", "msspec", "osspec" }) do
        row:SetCell(key, r[key] or "")
      end
    end,
    selectitem = function(objp, idx, slot, row, onoff)
      cidlg.selected = onoff and cidlg.rows[idx] or nil
      cidlg.update:SetEnabled(out_of_date(cidlg, cidlg.selected))
    end,
  }, panel.content)

  cidlg.list:Catch("OnSort", function(this, evt)
    ci_refresh(cidlg)
  end)

  --
  -- Which of the columns that come and go the list has been given so far. A column cannot be taken off a list once it is on
  -- it, and does not need to be, so one that this check has no use for is simply hidden.
  --
  cidlg.hascol = {}

  return cidlg
end

--
-- Put the columns this check wants on the window and take the rest off the screen. FACTS says whether the check asked after
-- the characters themselves at all, which is what decides whether race and level are worth two columns.
--
local function ci_columns(cidlg, want, facts)
  local shown = {}

  for _, c in ipairs(fact_columns) do
    shown[c.key] = facts and true or false
  end

  for name, cols in pairs(extra_columns) do
    for _, c in ipairs(cols) do
      shown[c.key] = want[name] and true or false
    end
  end

  local function apply(c)
    if (shown[c.key] and not cidlg.hascol[c.key]) then
      cidlg.list:AddColumn(c)
      cidlg.hascol[c.key] = true
    end

    if (cidlg.hascol[c.key]) then
      cidlg.list:SetColumnShown(c.key, shown[c.key])
    end
  end

  for _, c in ipairs(fact_columns) do
    apply(c)
  end

  for _, cols in pairs(extra_columns) do
    for _, c in ipairs(cols) do
      apply(c)
    end
  end
end

--
-- The person SENDER's row, made if this is the first we have heard of them. CLASS is only for colouring their name, and a
-- guild member who logged on after the roster was read still gets a row when they answer.
--
local function ci_expect(cidlg, name, class)
  if (not name or cidlg.byname[name]) then
    return cidlg.byname[name]
  end

  local who = {
    key = name, class = class, who = KRP.ShortAlwaysClassString(name, class), mods = {}, behind = true,
  }

  cidlg.byname[name] = who
  tinsert(cidlg.people, who)

  return who
end

--
-- SENDER's answer written onto their row. DECIDING is the handle of the mod that asked, which is the one whose version says
-- whether this person needs attention and is the version their row carries. Somebody who does not run it at all is as much
-- in need of attention as somebody running a stale copy, so both count as behind.
--
local function ci_answer(cidlg, who, reply, deciding)
  local mine = K.mods[deciding]

  who.handle = deciding
  who.version = nil
  who.level = tonumber(reply.level) or ""
  who.mods = {}
  who.behind = true

  if (reply.class) then
    who.class = tonumber(reply.class) or who.class
    who.who = KRP.ShortAlwaysClassString(who.key, who.class)
  end

  if (reply.gave and reply.gave.specs and reply.specs) then
    who.msspec = spec_name(tonumber(reply.specs[1]))
    who.osspec = spec_name(tonumber(reply.specs[2]))
  end

  for _, m in ipairs(reply.mods or {}) do
    local handle, title, version = m[1], m[2], tonumber(m[3]) or 0

    tinsert(who.mods, { key = who.key .. ":" .. handle, handle = handle, who = title or handle, version = version })

    --
    -- Somebody running a development copy of the deciding mod is not behind, whatever number it carries, and neither is
    -- anybody when the copy being measured against is itself a development one.
    --
    if (handle == deciding) then
      who.version = version
      who.behind = (not mine) or (version ~= 0 and mine.version ~= 0 and version < mine.version)
    end
  end

  -- Kore first, being what every other mod runs on, and the rest by name.
  tsort(who.mods, function(a, b)
    if ((a.handle == "kore") ~= (b.handle == "kore")) then
      return a.handle == "kore"
    end

    return strlower(a.who) < strlower(b.who)
  end)
end

--
-- ASKING, ANSWERING AND ACKNOWLEDGING
--
-- All three are reached through the methods RegisterComms puts on a mod, so that a mod's own CINFO and CIACK handlers are
-- one line each and the mod never has to know any of this.
--

--
-- THE TOKEN
--
-- Every check sends one, and an answer must send the same one back or it is dropped unread, because acting on an answer
-- writes. konfer:AckCFacts takes the facts in an answer to our own check as they stand, and every config we administer that
-- holds the sender records the change (see konfer:ApplyUserCheck). Without a token, anybody already in our configs could
-- send their own level back and forth and put an event in our stream each time, having never been asked anything.
--
-- An answer goes to the whole group or guild the check was asked of, so most of the answers a client hears are to somebody
-- else's check. One of those must carry the token of a check this client answered itself, and counts only towards the
-- versions it has heard (see "YOU ARE THE ONE WHO IS BEHIND"), never towards its facts or its window.
--
-- A token is stored with the time it expires, and answering does not remove it, because one check is answered by everybody
-- who heard it and there is no knowing how many that will be. A client that answers after its token has expired counts as
-- one that did not answer, which is a case the check already handles.
--
local CI_TOKEN_LIFE = 15

local ci_tokens = {}
local ci_heard = {}

local function forget_stale_tokens(now)
  for _, tokens in ipairs({ ci_tokens, ci_heard }) do
    for token, expires in pairs(tokens) do
      if (expires <= now) then
        tokens[token] = nil
      end
    end
  end
end

--
-- Expired tokens are cleared out here, when a new one is made, rather than on a timer. Checks are rare, so the table is
-- almost always empty and never holds more than the few a player asked for in the last fifteen seconds.
--
local function new_ci_token()
  local now = K.time()

  forget_stale_tokens(now)

  local token = konfer.KC.CreateNewID(K.player.name)

  ci_tokens[token] = now + CI_TOKEN_LIFE

  return token
end

local function token_live(tokens, token)
  local expires = token and tokens[token]

  if (not expires) then
    return false
  end

  if (expires <= K.time()) then
    tokens[token] = nil
    return false
  end

  return true
end

--
-- Whether TOKEN names a check of ours that may still be answered, or one of somebody else's that we answered. Methods so
-- that the CIACK handler in Comms.lua can ask without this file having to hand its tables out.
--
function konfer:AwaitingCInfo(token)
  return token_live(ci_tokens, token)
end

function konfer:HeardCInfo(token)
  return token_live(ci_heard, token)
end

--
-- KMOD asks. MODS and EXTRAS are as described at the top of this file, and SHOWMODS is how the window shows the answer
-- (see THE WINDOW). Answers ourselves straight away so that the window is never empty and the player can see their own copy
-- beside everybody else's.
--
-- Defined further down, and called from AskCharacterInfo above it.
local character_info_reply

function konfer:AskCharacterInfo(mods, extras_wanted, showmods)
  local where, why = where_to_ask()

  if (not where) then
    K.err("%s", why)
    return
  end

  mods = mods or {}
  extras_wanted = extras_wanted or {}

  local cidlg = self.cidlg or create_ci_window()
  self.cidlg = cidlg

  local facts = false

  for _ in pairs(extras_wanted) do
    facts = true
  end

  ci_columns(cidlg, extras_wanted, facts)

  cidlg.people = {}
  cidlg.byname = {}
  cidlg.rows = {}
  cidlg.deciding = self.comms.handle
  cidlg.showmods = showmods and true or false
  cidlg:SetTitleText(self:WindowTitle(showmods and L["VCTITLE"] or L["CITITLE"]))
  cidlg.remind:SetEnabled(where == "GROUP")

  if (where == "GROUP") then
    for name, player in pairs(KRP.players or {}) do
      ci_expect(cidlg, name, player.class)
    end
  else
    for _, member in ipairs(K.guild.roster.id) do
      if (member.online) then
        ci_expect(cidlg, member.name, member.class)
      end
    end
  end

  local me = ci_expect(cidlg, K.player.name, K.player.class)

  ci_answer(cidlg, me, character_info_reply(mods, extras_wanted), cidlg.deciding)
  ci_refresh(cidlg)
  cidlg:Show()

  local token = new_ci_token()

  if (where == "GROUP") then
    self:SendAM("CINFO", "ALERT", mods, extras_wanted, token, where)
  else
    self:SendGuildAM("CINFO", "ALERT", mods, extras_wanted, token, where)
  end
end

--
-- What this client answers with, which is also what it puts in its own row. Everything about this character the game can be
-- asked for travels whatever was asked, because it is one number each and there is nothing to decide about any of it.
--
function character_info_reply(mods, extras_wanted)
  local reply = {
    class = K.player.class,
    race = K.player.race,
    level = K.player.level,
    mods = {},
    gave = {},
  }

  local all = false

  for _, handle in ipairs(mods or {}) do
    if (handle == "*") then
      all = true
    end
  end

  if (all) then
    for handle, mod in pairs(K.mods) do
      tinsert(reply.mods, { handle, mod.title, mod.version })
    end
  else
    for _, handle in ipairs(mods or {}) do
      local mod = K.mods[handle]

      if (mod) then
        tinsert(reply.mods, { handle, mod.title, mod.version })
      end
    end
  end

  --
  -- An extra we have never heard of is passed over. The set of them grows, so meeting one is an older Kore looking at a
  -- newer one and is nothing like meeting a command we do not know.
  --
  for name, val in pairs(extras_wanted or {}) do
    if (extras[name]) then
      extras[name](reply, val)
      reply.gave[name] = true
    end
  end

  return reply
end

--
-- SENDER asks KMOD for character info. What this character reports goes to the whole group or guild the check was asked of,
-- WHERE, so that everybody there hears everybody's versions, and only if SENDER is somebody who may make us answer at all.
--
-- TOKEN is theirs and not ours. It travels back exactly as it came, so that the asker can tell the answers to their own
-- check from anything else, and it is kept a while as one we heard, so that the answers everybody else gives to the same
-- check are taken for what they say about versions (see THE TOKEN).
--
function konfer:AnswerCharacterInfo(sender, mods, extras_wanted, token, where)
  if (not self:IsElevated(sender)) then
    return
  end

  local now = K.time()

  forget_stale_tokens(now)

  if (token) then
    ci_heard[token] = now + CI_TOKEN_LIFE
  end

  if (where == "GUILD") then
    self:SendGuildAM("CIACK", "ALERT", character_info_reply(mods, extras_wanted), token)
  else
    self:SendAM("CIACK", "ALERT", character_info_reply(mods, extras_wanted), token)
  end
end

--
-- SENDER answers a check, ours when OURS is true and somebody else's we heard otherwise. Every answer counts towards the
-- versions heard. Only an answer to our own goes in the window, which is only where it is shown, so one arriving after it
-- was closed still counts.
--
function konfer:AckCInfo(sender, reply, ours)
  if (type(reply) ~= "table") then
    return
  end

  for _, m in ipairs(reply.mods or {}) do
    later_version_seen(sender, m[1], m[2] or m[1], tonumber(m[3]) or 0)
  end

  local cidlg = self.cidlg

  if (ours and cidlg and cidlg:IsShown()) then
    local who = ci_expect(cidlg, sender, nil)

    ci_answer(cidlg, who, reply, cidlg.deciding)
    ci_refresh(cidlg)
  end

  return reply
end
