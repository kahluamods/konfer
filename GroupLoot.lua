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
local KLD = konfer.KLD

local tinsert = table.insert
local tsort = table.sort
local tconcat = table.concat
local strfmt = string.format
local strmatch = string.match
local strlower = string.lower

local white = konfer.white

--
-- THE GROUP'S LOOT WITHOUT A MASTER LOOTER
--
-- Where the game has no master loot every item is rolled for, and goes to whoever wins it. Konfer takes those rolls over, as
-- RCLootCouncil does: every raider's client passes, the raid leader's asks for every item (KLD.SetGroupLoot), and so all the
-- raid wins comes to the leader, who hands it out by trade as the active policy decides, which is what a master looter does
-- with the game's own window. Collecting, the leader runs the raid's loot as a master looter would (konfer:AmIML,
-- konfer:LootRunner), and what they win in a roll goes on the loot list.
--
-- Nobody's rolls are answered without their say. The leader, an admin of the config loot runs against, presses Consent on
-- the Raid page, which starts their client collecting and asks the group (GLASK). A raider in the leader's guild has consented
-- by being in it, and their client says so for them; anybody else is asked in turn with any other question, and consents or
-- leaves the raid. Whoever joins later is asked as they arrive, and Consent pressed again asks whoever has not answered. The
-- answers go to the whole group (GLANS), so that every admin's Raid page marks those who have not consented. Consent is to
-- that leader for this group, kept in the group's record across a reload and asked again in another, and is never taken
-- back short of leaving. konfer.raid holds it all (collecting, collector, consent, consents and asked, in Konfer.lua).
--

-- Who leads the group, by name.
local function leader()
  for name, p in pairs(KRP.players or {}) do
    if (p.is_rl or (not KRP.in_raid and p.is_pl)) then
      return name
    end
  end
end

local function i_lead()
  return (KRP.is_rl or (not KRP.in_raid and KRP.is_pl)) and true or false
end

-- Whether this character may start collecting: leading a group, an admin of the active config, on a client with no master loot.
function konfer:MayCollect()
  return (not K.HAS_MASTER_LOOT and KRP.in_party and not KRP.in_bg and i_lead() and self:PolicyAdmin(self.apol)) and true
    or false
end

-- Whether this client is collecting the group's loot now, which it does only while it leads the group.
function konfer:Collecting()
  return (not K.HAS_MASTER_LOOT and self.raid.collecting and KRP.in_party and i_lead()) and true or false
end

--
-- Who runs the group's loot: its master looter where the game has master loot, and otherwise whoever is collecting it, for
-- as long as they lead the group. Nil for nobody.
--
function konfer:LootRunner()
  if (K.HAS_MASTER_LOOT) then
    return KRP.master_looter
  end

  local c = self.raid.collector

  return (c and c == leader()) and c or nil
end

-- Answer the game's rolls as things stand: ask for everything while collecting, pass while consenting to whoever is.
function konfer:ApplyGroupLoot()
  local how = nil

  if (not K.HAS_MASTER_LOOT and KRP.in_party and not self:IsSuspended()) then
    if (self:Collecting()) then
      how = "need"
    elseif (self.raid.consent and self.raid.consent == self:LootRunner()) then
      how = "pass"
    end
  end

  KLD.SetGroupLoot(how)
end

-- Whether the answer heard from NAME is consent.
local function consented(name)
  local a = konfer.raid.consents and konfer.raid.consents[name]

  return a == "yes" or a == "guild"
end

--
-- Consent, pressed by the leader: collect the group's loot and ask the group to let it. Pressed again, it asks again of
-- whoever has not answered.
--
function konfer:AskConsent()
  if (not self:MayCollect()) then
    return
  end

  local raid = self.raid
  local again = raid.collecting and true or false

  raid.collecting = true
  raid.collector = K.player.name
  raid.consents = raid.consents or {}
  raid.consents[K.player.name] = "yes"
  raid.asked = raid.asked or {}

  if (again) then
    for name in pairs(KRP.players or {}) do
      if (name ~= K.player.name and not consented(name)) then
        raid.asked[name] = true
        self:SendWhisperAM(name, "GLASK", "ALERT")
      end
    end
  else
    for name in pairs(KRP.players or {}) do
      raid.asked[name] = true
    end

    self:SendAM("GLASK", "ALERT")
  end

  self:ApplyGroupLoot()
  self:LootRunnerChanged()
  self:RefreshPolicyPages()
end

-- NAME is in the group, the collecting leader's client asking them the moment they arrive.
function konfer:GroupLootJoined(name)
  local raid = self.raid

  if (self:Collecting() and name ~= K.player.name and not (raid.asked and raid.asked[name])) then
    raid.asked = raid.asked or {}
    raid.asked[name] = true
    self:SendWhisperAM(name, "GLASK", "ALERT")
  end
end

-- This client's answer to the leader, ANSWER being "yes", "guild" or "no", for the group and for itself.
local function answer(ans)
  konfer.raid.consents = konfer.raid.consents or {}
  konfer.raid.consents[K.player.name] = ans
  konfer:SendAM("GLANS", "ALERT", ans)
end

--
-- THE QUESTION
--
-- Put to a raider outside the leader's guild, in the leader's own words (GROUPLOOT_CONSENT). Yes consents. No asks first
-- whether to leave the raid, which is what declining is (GROUPLOOT_EXIT): Yes there leaves it, and No asks again. Neither
-- dialog can be put away unanswered. Konfer's own windows go away while it is asked, so that nothing of the mod's stands
-- behind the question, and come back once it is answered either way.
--
local CONSENT_W = 520
local EXIT_W = 420

local consentdlg = nil
local exitdlg = nil
local asking = nil
local away = nil

local function stand_aside()
  away = away or konfer:WindowsAway()
end

local function come_back()
  konfer:WindowsBack(away)
  away = nil
end

local function sized(dlg, text)
  dlg.text:SetText(text)

  local th = dlg.text.label:GetStringHeight()

  dlg.text:SetHeight(th)
  dlg:SetHeight(dlg.rings.top + th + dlg.rings.bottom)
end

local function question(name, title, width, justify)
  local dlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = name, title = konfer:WindowTitle(title), border = true, width = width,
    height = 200, canmove = true, canresize = false, escclose = false, blackbg = true, padding = KUI.WIDGET_GAP,
    okbutton = { text = K.YES_STR }, cancelbutton = { text = K.NO_STR }, buttons = "CENTER",
  })

  dlg.text = KUI:CreateStringLabel({
    x = 0, y = 0, width = width - dlg.rings.left - dlg.rings.right, autosize = false, font = "GameFontNormal",
    justifyh = justify, justifyv = "TOP", text = "",
  }, dlg)

  dlg:Catch("OnHide", function(this)
    local after = this.after

    this.after = nil

    if (after) then
      after()
    end
  end)

  return dlg
end

local show_consent

local function show_exit(collector)
  konfer:InTurn(function(after)
    if (not exitdlg) then
      exitdlg = question("KonferGroupLootExit", L["Confirm raid exit"], EXIT_W, "CENTER")

      exitdlg:Catch("OnAccept", function(this)
        answer("no")
        asking = nil
        come_back()
        konfer.apol:info(L["you have declined, and leave the raid."])

        -- The answer goes before the group is left, a message sent to a group already left reaching nobody.
        C_Timer.After(1, function()
          KRP:LeaveGroup()
        end)
      end)

      exitdlg:Catch("OnCancel", function(this)
        show_consent(this.collector, true)
      end)
    end

    exitdlg.collector = collector
    exitdlg.after = after
    sized(exitdlg, strfmt(L["GROUPLOOT_EXIT"], white(K.YES_STR)))
    stand_aside()
    exitdlg:Show()

    return true
  end, true)
end

show_consent = function(collector, first)
  asking = collector

  konfer:InTurn(function(after)
    if (asking ~= collector or konfer.raid.consent == collector) then
      return false
    end

    if (not consentdlg) then
      consentdlg = question("KonferGroupLootConsent", L["Loot consent"], CONSENT_W, "LEFT")

      consentdlg:Catch("OnAccept", function(this)
        konfer.raid.consent = this.collector
        asking = nil
        come_back()
        answer("yes")
        konfer:ApplyGroupLoot()
        konfer:RefreshPolicyPages()
      end)

      consentdlg:Catch("OnCancel", function(this)
        show_exit(this.collector)
      end)
    end

    local lp = KRP.players and KRP.players[collector]

    consentdlg.collector = collector
    consentdlg.after = after
    sized(consentdlg, strfmt(L["GROUPLOOT_CONSENT"], "|cffff0000<KahLua>|r " .. L["MODTITLE"],
      konfer.aclass(collector, lp and lp.class)))
    stand_aside()
    consentdlg:Show()

    return true
  end, first)
end

--
-- The leader SENDER asks this client to let them collect. Asked again by the one consented to, the answer is given again;
-- in the leader's guild it is given without asking; and otherwise the player is asked, once, however often it arrives.
--
function konfer:ConsentAsked(sender)
  if (K.HAS_MASTER_LOOT or sender == K.player.name or sender ~= leader()) then
    return
  end

  local raid = self.raid

  raid.collector = sender

  if (raid.consent == sender) then
    answer("yes")
  elseif (K.player.is_guilded and K.guild.roster and K.guild.roster.name[sender]) then
    raid.consent = sender
    answer("guild")
  elseif (asking ~= sender) then
    show_consent(sender)
  end

  self:ApplyGroupLoot()
  self:RefreshPolicyPages()
end

-- SENDER answered the leader, ANS being "yes", "guild" or "no".
function konfer:ConsentAnswered(sender, ans)
  if (ans ~= "yes" and ans ~= "guild" and ans ~= "no") then
    return
  end

  self.raid.consents = self.raid.consents or {}
  self.raid.consents[sender] = ans
  self:RefreshPolicyPages()
end

--
-- Whether NAME, in the group, stands outside the takeover: while somebody collects, anybody but the collector who has not
-- consented, who may then roll for an item and win it. Nobody while nobody collects.
--
function konfer:NotConsented(name)
  local runner = not K.HAS_MASTER_LOOT and self:LootRunner()

  return (runner and name ~= runner and not consented(name)) and true or false
end

--
-- A roll answered while collecting with somebody in the group who has not consented is a roll they may win. The leader is
-- told who, no more than once a minute.
--
local WARN_GAP = 60
local warned_at = nil

function konfer:GroupLootRolled()
  if (not self:Collecting() or (warned_at and GetTime() - warned_at < WARN_GAP)) then
    return
  end

  local names = {}

  for name in pairs(KRP.players or {}) do
    if (self:NotConsented(name)) then
      tinsert(names, K.DisplayName(name))
    end
  end

  if (#names > 0) then
    tsort(names)
    warned_at = GetTime()
    self.apol:warn(L["%s may roll for the loot, not having consented."], tconcat(names, ", "))
  end
end

--
-- An item the collecting leader won in a roll goes on the loot list, as an item the corpse offers would: not one the config
-- ignores, nor one below its quality threshold unless the config's own instructions for it say otherwise.
--
function konfer:CollectedLoot(ilink)
  if (not self:Collecting() or not self:AmIML() or not self:IsUsableHere()) then
    return
  end

  local itemid = strmatch(ilink, "item:(%d+)")
  local ii = itemid and self.apol.cfg.items[itemid]

  if ((ii and ii.ignore) or (itemid and self.iitems[itemid] and self.iitems[itemid].ignore)) then
    return
  end

  local _, _, quality = C_Item.GetItemInfo(ilink)
  local thresh = tonumber(self.apol:Setting("bid_threshold", self.apol.currentid) or 0) or 0

  if (quality and thresh ~= 0 and quality < thresh and not (ii and ii.ignorequal)) then
    return
  end

  self:AddLoot(ilink, false)
end

--
-- OWED TRADES
--
-- An item handed out while collecting is in the leader's bags, and anybody else it goes to is owed it, which Kore delivers
-- when the two trade (KLD.OweTrade). The Loot page's Trades tab lists what is owed. A trade that never happens is undone
-- from the History tab as any award is.
--
function konfer:OweTrade(ilink, name)
  local owe = self:Collecting() and ilink and name and name ~= K.player.name

  owe = owe and not self.testloot -- @debug-delete@

  if (owe) then
    KLD.OweTrade(ilink, name)
    self:RefreshTrades()
  end
end

function konfer:TradeDelivered(id, ilink, to)
  if (self.apol) then
    self.apol:info(L["%s has %s."], K.DisplayName(to), ilink)
  end

  self:RefreshTrades()
end

--
-- THE TRADES TAB
--
-- On the Loot page where the game has no master loot, the admins'. Every item owed, who to and how long ago it was won,
-- longest owed first, one past the time the game allows a trade marked as such. Under it Trade, which opens a trade with
-- the winner picked, whom what they are owed is put in the window for, and Forget, for an item handed over some other way.
--
local TRADES_BTN_W = 90
local TRADES_BTN_H = 24

local tr = nil

local function owed_rows()
  local rows = {}

  for _, t in ipairs(KLD.trades) do
    tinsert(rows, t)
  end

  tsort(rows, function(a, b) return a.at < b.at end)

  return rows
end

function konfer:RefreshTrades()
  if (not tr or tr.refreshing) then
    return
  end

  tr.rows = owed_rows()

  local sel = nil

  for i, t in ipairs(tr.rows) do
    if (t.id == tr.picked) then
      sel = i
    end
  end

  tr.picked = sel and tr.picked or nil
  tr.refreshing = true
  tr.list:UpdateList(#tr.rows)
  tr.list:SetSelected(sel, false, true)
  tr.refreshing = false

  local t = sel and tr.rows[sel]

  tr.trade:SetEnabled((t and KRP.players and KRP.players[t.to]) and true or false)
  tr.forget:SetEnabled(t ~= nil)
end

function konfer:InitialiseTradesUI()
  local page = self.mainwin:GetPage(self.LOOT_PAGE)
  local client = page.tabsbyname[self.LOOT_TRADES_TAB].content

  tr = { client = client }

  tr.list = KUI:CreateColumnList({
    name = "KonferTradesList",
    columns = {
      { key = "item", text = L["Item"], width = "fill" },
      { key = "to", text = L["Winner"], width = 130 },
      { key = "owed", text = L["Owed"], width = 80, align = "RIGHT" },
    },
    setitem = function(cl, idx, slot, row)
      local t = tr.rows[idx]
      local mins = math.floor((K.time() - t.at) / 60)

      row:SetCell("item", t.ilink)
      row:SetCell("to", konfer.aclass(t.to, KRP.players and KRP.players[t.to] and KRP.players[t.to].class))
      row:SetCell("owed", (mins >= KLD.TRADE_HOURS * 60) and konfer.red(L["Too late"]) or strfmt(L["%d min"], mins))
    end,
    selectitem = function(cl, idx, slot, row, onoff)
      if (tr.refreshing) then
        return
      end

      tr.picked = (onoff and tr.rows[idx]) and tr.rows[idx].id or nil
      konfer:RefreshTrades()
    end,
  }, client.hsplit.topframe)

  local bf = client.hsplit.bottomframe

  tr.trade = KUI:CreateButton({ x = 0, y = 0, width = TRADES_BTN_W, height = TRADES_BTN_H, text = L["Trade"],
    tooltip = { title = "$$", text = L["TIP_TRADES_TRADE"] }, enabled = false }, bf)
  tr.trade:Catch("OnClick", function()
    for _, t in ipairs(tr.rows) do
      if (t.id == tr.picked) then
        KLD.OpenTrade(t.to)
      end
    end
  end)

  tr.forget = KUI:CreateButton({ x = TRADES_BTN_W + KUI.WIDGET_GAP, y = 0, width = TRADES_BTN_W, height = TRADES_BTN_H,
    text = L["Forget"], tooltip = { title = "$$", text = L["TIP_TRADES_FORGET"] }, enabled = false }, bf)
  tr.forget:Catch("OnClick", function()
    if (tr.picked) then
      KLD.ForgetTrade(tr.picked)
      tr.picked = nil
      konfer:RefreshTrades()
    end
  end)

  self:RefreshTrades()
end
