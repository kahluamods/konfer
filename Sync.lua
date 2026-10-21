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
local cfgm = konfer.configmethods
local KU = K.Users
local L = konfer.L
local KUI = konfer.KUI
local KRP = konfer.KRP
local MakeFrame = KUI.MakeFrame

-- Local aliases for global or Lua library functions
local _G = _G
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local tostring, tonumber = tostring, tonumber
local strfmt = string.format
local pairs = pairs
local assert = assert

local white = konfer.white
local red = konfer.red
local green = konfer.green
local aclass = konfer.aclass
local shortaclass = konfer.shortaclass

-- How long a sync partner has to send what was asked for, in seconds, before the sync is given up on.
local SYNC_TIMEOUT = 120

--
-- This page's widget handles. There is one window and it shows the active policy, so there is one of these and everything in
-- this file reads it directly. What it holds is about the page rather than about any policy: the partners listed, the
-- replies in hand, the sync in flight. All of it is put back from the active policy's config whenever that config changes,
-- which is what refresh_sync is for.
--
local qf = {}

--
-- The Sync panel reads as disabled, its title dimmed, while no sync partner is selected, and Sync responses while there are
-- no replies in it. Called wherever the selection or the replies change.
--
local function sync_page_panels()
  if (qf.syncpanel) then
    qf.syncpanel:SetEnabled(qf.selsyncer ~= nil)
    qf.responsespanel:SetEnabled((qf.repliers and #qf.repliers > 0) and true or false)
  end
end

local function clear_syncers_list()
  qf.syncers.itemcount = 0
  qf.syncers:UpdateList()
  qf.syncers:SetSelected(nil)
  qf.repliers = nil
  sync_page_panels()
end

--
-- This file contains all of the code for syncing lists between users. It also has all of the code for broadcasting lists to
-- raids / guilds and most other sync related functions, as well as all of the UI handling code for the sync tab.
--

--
-- A scroll list row is built once and scrolls past whatever the list holds now, and the window goes on standing while the
-- policy changes under it, so anything a row does reads the active policy at the moment it runs. A policy captured when the
-- row was made is the policy that happened to be active then, which is a different thing and eventually a wrong one.
--
local function slist_selectitem(objp, idx, slot, btn, onoff)
  local pp = konfer.apol
  local onoff = onoff or false
  local mask = true

  if (konfer:PolicyAdmin(pp) == 2 and not pp.cfg.syncing) then
    mask = false
  end

  if (onoff) then
    local en = true
    qf.reqsyncbutton:SetEnabled(en and mask)
    if (konfer:PolicyAdmin(pp) == 2) then
      en = true
    else
      en = false
    end
    qf.recoverbutton:SetEnabled(en)
  else
    qf.reqsyncallbutton:SetEnabled(mask)
    qf.reqsyncbutton:SetEnabled(false)
    qf.recoverbutton:SetEnabled(false)
  end

  sync_page_panels()
end

local function rlist_newitem(objp, num)
  local bname = "KonferSyncRepButton" .. tostring(num)
  local rf = MakeFrame("Button", bname, objp.content)
  local nfn = "GameFontNormalSmallLeft"

  rf:SetWidth(260)
  rf:SetHeight(48)
  KUI:RowHighlight(rf)

  local sb = KUI:CreateButton({ name = bname .. "SB", width = 95, height = 20, text = L["Sync"] }, rf)
  sb:ClearAllPoints()
  sb:SetPoint("TOPLEFT", rf, "TOPLEFT", 165, 0)
  sb:Disable()
  sb:SetScript("OnClick", function(this)
    local pp = konfer.apol
    local idx = this:GetParent():GetID()
    if (qf.busy_with_sync) then
      pp:info(L["busy syncing with %q. Please try again when complete."], qf.busy_with_sync)
      return
    end
    local rp = qf.repliers[idx]
    local busy = shortaclass(pp.cfg:UserNameClass(rp.theiruid))
    local attempt = {}

    qf.busy_with_sync = busy
    qf.sync_attempt = attempt

    pp:CSendWhisperAM(pp.currentid, pp.cfg:UserName(rp.theiruid), "GSYNC", "ALERT", rp.mylast, false,
      pp.cfg.lastevent, pp.cfg.cksum)
    this:Disable()
    rp.synced = true

    --
    -- A partner who never answers, having gone offline or out of reach, would otherwise leave every other sync refused for
    -- the rest of the session. Once SYNC_TIMEOUT has passed with this still the sync under way, it is given up on and the
    -- partner can be asked again.
    --
    K:ScheduleTimer(function()
      if (qf.busy_with_sync and qf.sync_attempt == attempt) then
        qf.busy_with_sync = nil
        rp.synced = nil
        pp:info(L["no sync reply from %q. Please try again."], busy)
        qf.syncers:UpdateList()
      end
    end, SYNC_TIMEOUT)
  end)
  rf.syncbutton = sb

  local user = rf:CreateFontString(nil, "ARTWORK", nfn)
  user:ClearAllPoints()
  user:SetPoint("TOPLEFT", rf, "TOPLEFT", 8, -2)
  user:SetPoint("BOTTOMRIGHT", rf, "TOPLEFT", 152, -14)
  user:SetJustifyH("LEFT")
  user:SetJustifyV("TOP")
  rf.user = user

  local cks = rf:CreateFontString(nil, "ARTWORK", nfn)
  cks:ClearAllPoints()
  cks:SetPoint("TOPLEFT", user, "BOTTOMLEFT", 0, -2)
  cks:SetPoint("BOTTOMRIGHT", user, "BOTTOMRIGHT", 0, -14)
  cks:SetJustifyH("LEFT")
  cks:SetJustifyV("TOP")
  rf.cks = cks

  local tss = rf:CreateFontString(nil, "ARTWORK", nfn)
  tss:ClearAllPoints()
  tss:SetPoint("TOPLEFT", cks, "BOTTOMLEFT", 0, -2)
  tss:SetPoint("BOTTOMRIGHT", cks, "BOTTOMRIGHT", 100, -14)
  tss:SetJustifyH("LEFT")
  tss:SetJustifyV("TOP")
  rf.tss = tss

  rf.SetText = function(self, idx)
    local pp = konfer.apol
    local rp = qf.repliers[idx]
    self.user:SetText(rp.name)
    local fn = green
    if (not rp.active) then
      self.cks:SetText(red(L["Not active!"]))
    else
      -- Theirs against ours as of the same moment (cfgm:ProcessSyncAck).
      if (rp.cksum ~= rp.mine) then
        fn = red
      end
      self.cks:SetText(fn(strfmt(L["Checksum: 0x%s"], K.hexstr(rp.cksum))))
    end
    if (rp.mylast ~= rp.last) then
      fn = red
      self.syncbutton:Enable()
    else
      fn = green
      self.syncbutton:Disable()
    end
    if (rp.synced) then
      self.syncbutton:Disable()
    end
    self.tss:SetText(fn(strfmt("%014.0f / %014.0f", rp.mylast, rp.last)))
  end

  rf:SetScript("OnClick", function(this)
  end)

  return rf
end

local function rlist_setitem(objp, idx, slot, btn)
  btn:SetText(idx)
  btn:SetID(idx)
  btn:Show()
end

local function rlist_selectitem(objp, idx, slot, btn, onoff)
end

--
-- This function will prepare the table to be broadcast for a specified
-- config.
-- a table suitable for transmission with the following values:
--   v=konfer.BCAST_VERSION
--   c={ cfgid, name, ownerid, crc, policy, channel, opts, vals }
--     POLICY is the handle of the policy the config belongs to, which a receiver that has never seen the config cannot work
--     out any other way, and CHANNEL is where its traffic goes. OPTS and VALS are the config's settings, the two strings
--     konfer:MakeConfig reads by name: what a config does is its owner's to decide, so they travel with it and replace
--     whatever the receiver had. Append to this list, never insert into it.
--   u={userlist} - keyed by uid
--     Each element in userlist is { name, enchanter, frozen, mainname, facts }: this config's entry for the user, then whose
--     alt they are, then what we know of the character as KU:WireRow packs it. The facts are only ever offered to the
--     receiver (see konfer:UserFactChanges) and the link is taken as it stands.
--     MAINNAME is the whole of the link and is a character name, not a uid. The link is the mod's rather than this
--     config's, so it is the same answer wherever that person appears, and somebody can perfectly well be an alt of a main
--     this config has never held. A uid could not say that, having no way to name anybody outside the config, and a KUID
--     is this client's own and never travels. Every name here becomes the receiver's KUID as the config is accepted.
--   p={policy settings} - keyed by policy handle
--     That policy's own block, its descriptor's defaults written over with whatever the owner set. The platform's settings
--     ride in c above; these are the ones the policy named for itself, and a receiver keeps only the names that policy
--     declares. What a config does is its owner's to decide, whichever half of it a setting belongs to.
--   o={policy data} - keyed by policy handle
--     That policy's own data on the config (cfg:PolicyData), PUG's raid and EP/GP's and DKP's awards, which travels only
--     with the whole config and by the policy's own events. A receiver keeps only what that policy declares in configdata.
--   m={mains} - keyed by character name
--     The wire row for every main named above whom this config does not itself hold. A link can only be written between two
--     characters the receiver knows about, so these travel as people and nothing more. They get no uid and join no config.
--   a={adminlist} - keyed by uid
--     Each element in adminlist is the admin id of the uid that keys it, the single character every uid that admin mints
--     begins with. Which ids have ever been used does not travel and does not need to: only the owner ever hands one out,
--     through MKADM, and the owner holds the whole config while doing it.
--   l={listinfo} - keyed by listid
--     Each element in listinfo is
--       { name, order, defrank, strictc, strictr, xlist, tethered, altdisp, ulist }
--     ULIST is the whole membership in order, the uids run together, and is the only thing that says who is on the list or
--     how many. How many used to travel beside it and was two answers to one question, the receiver splitting ULIST anyway.
--   s=syncers data (for FSYNC)
--   i=item database (for FSYNC)
--   e=last event ID (for FSYNC)
--   d=my userid (for FSYNC)
--
local function prepare_broadcast(self, cfg)
  assert(cfg, "no configuration given.")
  local ci = {}
  local tc = self:Config(cfg)

  ci.v = konfer.BCAST_VERSION
  --
  -- The two settings strings travel with the config. What a config does is its owner's to decide rather than each client's,
  -- which is why they are kept small enough to ride along in here.
  --
  ci.c = { cfg, tc.name, tc.owner, K.hexstr(tc.cksum), tc.policy or konfer.DEFAULT_POLICY, tc.channel, tc.opts, tc.vals }

  --
  -- The link sent is the one the mod holds, KU:Main, and not cfg:IsAlt. IsAlt answers the question this config can
  -- act on, which is whether there is somebody here to tether to, and so says nothing at all about an alt whose main this
  -- config does not hold. That is still a fact about the two characters, and a receiver that is told it can hold it against
  -- the character the way every other config does.
  --
  local mains = {}

  ci.u = {}
  for k,v in pairs(tc.uids) do
    local kuid = v[konfer.CFGUSER_KUID]
    local name = KU.kuids[kuid]
    local mkuid = KU:Main(kuid)

    ci.u[k] = { name, v[konfer.CFGUSER_ENCHANTER] and true or false, v[konfer.CFGUSER_FROZEN] and true or false,
      (mkuid and KU.kuids[mkuid]) or "", KU:WireRow(kuid) or { name }, v[konfer.CFGUSER_PDATA] }

    if (mkuid) then
      mains[mkuid] = true
    end
  end

  --
  -- The mains named above that this config does not hold. Their own row said who they are for the rest, so only these are
  -- left, and without them a receiver meeting one for the first time would have a link naming somebody it has never heard of.
  --
  --
  -- The policy's own settings, keyed by its handle, beside the platform's in ci.c. A config runs one policy so there is one
  -- block in practice, and a receiver keeps only what a policy it actually runs declares.
  --
  ci.p = tc.psettings or {}

  -- And its own data on the config, which travels only with the whole config and by the policy's own events.
  ci.o = tc.pdata or {}

  ci.m = {}
  for mkuid in pairs(mains) do
    if (not tc:FindKuid(mkuid)) then
      local mname = KU.kuids[mkuid]

      ci.m[mname] = KU:WireRow(mkuid) or { mname }
    end
  end

  ci.a = {}
  for k,v in pairs(tc.admins) do
    if (v.id) then
      ci.a[k] = v.id
    end
  end

  ci.l = {}
  for k,v in pairs(tc.lists) do
    local ulist = ""
    for kk,vv in ipairs(v.users) do
      ulist = ulist .. vv
    end
    --
    -- The policy's own word on this list, last so that anything older simply does not read it. Without it a list travels
    -- as a column of names with every number on it thrown away, which is not the list that was sent.
    --
    local _, info = tc:PolicyCall("ListInfo", nil, k)

    -- The policy's own options on the list, keyed by its handle as ci.p is (cfg:ListOptions).
    ci.l[k] = { v.name, tonumber(v.sortorder or 0), tonumber(v.def_rank or 0), v.strictcfilter and true or false,
      v.strictrfilter and true or false, tostring(v.extralist), v.tethered and true or false,
      v.altdisp and true or false, ulist, info, v.poptions or {} }
  end

  return ci
end

--
-- Broadcast config CFGID to the group, or to the guild if ISSHIFTED. Which config is always said, never inferred: the sync
-- page names the one the window has in hand and the foyer names the one selected beside the card, which it can do without
-- first switching to that policy. There is nothing sensible to default to, a broadcast of the wrong config being worse than
-- none at all, so prepare_broadcast asserts rather than guessing.
--
-- A whole config is a lot to send, so every Broadcast button is dark for konfer.BCAST_GAP seconds after the last broadcast,
-- whichever config that was. konfer.bcastwait is the timer that lights them again.
--
function cfgm:Broadcast(isshifted)
  local ci = prepare_broadcast(konfer, self.id)

  if (not ci) then
    return
  end

  if (isshifted and K.player.is_guilded) then
    konfer:SendGuildAM("BCAST", "ALERT", ci)
  else
    konfer:SendAM("BCAST", "ALERT", ci)
  end

  if (konfer.bcastwait) then
    K:CancelTimer(konfer.bcastwait)
  end

  konfer.bcastwait = K:ScheduleTimer(function()
    konfer.bcastwait = nil
    konfer:RefreshBroadcastButtons()
  end, konfer.BCAST_GAP)
  konfer:RefreshBroadcastButtons()
end

function konfer:RecoverConfig(sender, cfg, cfgid, rdata, people, links)
  --
  -- A recovery is asked for on the Sync page, which shows one config at a time, so there is one outstanding and it records
  -- which config it was asked for. Both of the checks below are about that: the wrong sender, or the right sender answering
  -- about some other config, is not the reply being waited for.
  --
  local pol = self.policies[cfg.policy]
  local recovery = qf.recovery

  if (not recovery) then
    return
  end

  --
  -- Who answered is asked as a uid, the way identity is asked everywhere, so a sender the config has renamed since the
  -- request went out is still the one we asked.
  --
  if (konfer:Config(recovery.cfg):FindUser(sender) ~= recovery.uid) then
    return
  end

  --
  -- The name in the reply is matched against the configs this policy holds, and a name that matches none of them is not the
  -- reply being waited for. It is nothing worse than that, so it is dropped like any other answer to a question we did not
  -- ask. The test below cannot make that judgement on its own, nil never being equal to the id we asked about.
  --
  local current_cfgid = pol and self:FindConfig(pol, cfg.name)

  if (not current_cfgid or current_cfgid ~= recovery.cfg) then
    return
  end

  --
  -- We need to make some slight adjustments to the recovery data and do some simple checks. Since this is such a drastic
  -- action it is very important we get everything exactly right.
  --
  -- The settings and history are the ones this client held for the config, under whichever id it held it.
  self:KeepLocalConfigState(cfg, current_cfgid)

  --
  -- rdata.s is keyed by admin uid, with that admin's last event ID as the value (see SendFullSync). It is not a "uid:eventid" string.
  --
  -- The owner's entry is made here, since a recovery is the owner rebuilding their own config and their place in it is the
  -- one thing they can be sure of. Everybody else's has to have arrived in the same message. A position for an admin that
  -- message did not name is a message that disagrees with itself, and there is nothing to attach it to.
  --
  for k,v in pairs(rdata.s) do
    local adm, le = k, v
    if (adm == cfg.owner) then
      cfg.lastevent = tonumber(le)
      cfg.admins[adm] = { id = "0" }
    elseif (cfg.admins[adm]) then
      if (adm == rdata.d) then
        cfg.admins[adm].lastevent = rdata.e
      else
        cfg.admins[adm].lastevent = tonumber(le)
      end
      cfg.admins[adm].sync = {}
      cfg.admins[adm].active = true
    end
  end

  --
  -- Recovery can hand back a config under a different id, so the policy's default follows it across rather than being left
  -- naming the one that has just gone.
  --
  local pdb = self:PolicyDB(pol)

  cfg.syncing = true
  self:AdoptPeople(sender, cfg, people)
  self:SetConfig(cfgid, cfg, pol)
  cfg:AdoptListInfo()
  self:AcceptAltLinks(links)

  if (current_cfgid ~= cfgid) then
    self:SetConfig(current_cfgid, nil)
    if (pdb.defconfig == current_cfgid) then
      pdb.defconfig = cfgid
    end
  end

  if (pdb.defconfig == cfgid) then
    cfg:SetDefault(true, true)
  end
  self:FullRefresh(true)
  cfg:SyncUpdateReplier()
  self:RefreshSyncUI(true)
  pol:info(L["recovery from user %s complete."], shortaclass(cfg:UserNameClass(rdata.d)))
  qf.recovery = nil
  cfg:PolicyCall("ConfigSynced", nil, "recovered")

  --
  -- The recovered config is worth looking at, and the recovery was asked for from this window in the first place, so it is
  -- put back up. Recovery can only have been asked for while its policy was the active one, so this is still that policy.
  --
  if (self.mainwin) then
    self.mainwin:Show()
  end
end

local function recover_config(self)
  local pp = konfer.apol

  local function real_recover(kmod, arg)
    --
    -- All we need to do to start the recovery process is to record which user and config we have requested the recovery
    -- from, and send them the request. If we get back any reply that does not match we silently ignore it.
    --
    -- The window stays away until the recovery completes, which puts it back. Cancelling the dialog puts it back at once.
    --
    qf.mainwin:Hide()
    local from = konfer:Config(arg.cfg)

    qf.recovery = { cfg = arg.cfg, uid = arg.uid }
    pp:SendWhisperAM(from:UserName(arg.uid), "RCOVR", "ALERT", pp.cfg.name)
    pp:info(L["waiting for recovery reply from %s. Do not use %s until recovery is complete."],
      shortaclass(from:UserNameClass(arg.uid)), pp.name)
  end

  local au = aclass(pp.cfg:UserNameClass(qf.selsyncer))

  K.ConfirmationDialog(self, { text = L["Recover configuration"], owner = konfer.apol }, strfmt(L["RECOVERMSG"], au, au),
    { L["Configuration: %s"], pp.cfg.name }, real_recover, { cfg = pp.currentid, uid = qf.selsyncer }, qf.mainwin, 250)
  return
end

function konfer:InitialiseSyncUI()
  local arg
  local mainwin = self.mainwin

  qf.mainwin = mainwin

  --
  -- What this page is showing and doing. It is about the config on screen rather than about any policy, and changing which
  -- config that is puts all of it back through refresh_sync.
  --
  --   sortedsyncers   The config's other admins, in the order listed.
  --   selsyncer       The one selected, or nil.
  --   repliers        Replies to the last sync request, or nil before one.
  --   replycfg        The config those replies are about.
  --   busy_with_sync  Who a sync is under way with, or nil.
  --   sync_attempt    A table standing for the sync last asked for, so that its timeout can tell whether it is still the one.
  --   recovery        The recovery asked for and not yet answered, or nil.
  --
  qf.sortedsyncers = {}
  qf.selsyncer = nil
  qf.repliers = nil
  qf.replycfg = nil
  qf.busy_with_sync = nil
  qf.recovery = nil

  --
  -- Sync tab
  --

  local cf = mainwin:GetPage(self.SYNC_PAGE).content
  local tbf = mainwin:GetPage(self.SYNC_PAGE).topbar

  arg = {
    x = 0, y = self.TOPBAR_TEXT_Y, text = "", autosize = false, width = 250,
    font = "GameFontNormalSmall",
  }
  tbf.mycksum = KUI:CreateStringLabel(arg, tbf)

  --
  -- Published because the checksum plate is redrawn from several other files, none of which see this page. With no active
  -- policy, or one with no config, there is no checksum to show and it says nothing rather than making its callers ask first.
  --
  konfer.qf.synctopbar = tbf
  tbf.SetCurrentCRC = function()
    local pp = konfer.apol

    if (not pp or not pp.cfg) then
      tbf.mycksum:SetText("")
      return
    end

    tbf.mycksum:SetText(strfmt(L["My checksum: %s"], white(strfmt("0x%s", K.hexstr(pp.cfg.cksum)))))
  end

  --
  -- The page is two halves. The top one is exactly as tall as the left column needs and does not change, and the bottom one
  -- is empty and unbordered and takes whatever the window grows by. The top half is a container for the two columns, which
  -- are the panels that draw.
  --
  -- How tall the top half is depends on the rings round the panels in the left column, which are known only once those have
  -- been built, so it is made with no height here and given one below.
  --
  arg = {
    height = 0, topanchor = true, topborder = false, toppadding = 0, bottomborder = false,
    name = "KonferSyncPageSplit",
  }
  cf.hsplit = KUI:CreateHSplit(arg, cf)

  --
  -- The left column is three panels, one under another, each exactly the size of what it holds. Sync partners is sized for
  -- five rows and scrolls for a config with more. Under it the Sync panel holds the buttons that act on the partners, and
  -- under that a panel of its own holds Broadcast, which acts on the config rather than on anybody in the list. The column
  -- itself is only a container for them.
  --
  local COL_W = 180
  local PARTNER_ITEM_H = 16
  local PARTNER_ROWS = 5
  local PARTNERS_H = PARTNER_ROWS * PARTNER_ITEM_H

  -- Two buttons fill a row of the column, with the standard gap between them.
  local BTN_H = 24
  local BTN_W = (COL_W - KUI.WIDGET_GAP) / 2
  local BTN_COL = BTN_W + KUI.WIDGET_GAP
  local BTN_ROW = 0 - BTN_H - KUI.WIDGET_GAP
  local ACTIONS_H = BTN_H + KUI.WIDGET_GAP + BTN_H

  arg = {
    width = COL_W,
    name = "KonferSyncTopSplit",
    righttitle = L["Sync responses"],
  }
  cf.vsplit = KUI:CreateVSplit(arg, cf.hsplit.topframe)

  local ls = cf.vsplit.leftframe
  local rs = cf.vsplit.rightframe

  arg = {
    height = PARTNERS_H, topanchor = true,
    name = "KonferSyncPartnersSplit",
    toptitle = L["Sync partners"],
  }
  ls.hsplit = KUI:CreateHSplit(arg, ls)
  local partners = ls.hsplit.topframe

  --
  -- Broadcast has what is left under the Sync panel, which the top half is sized to make exactly its height.
  --
  arg = {
    height = ACTIONS_H, topanchor = true,
    name = "KonferSyncActionsSplit",
    toptitle = L["Sync"],
  }
  ls.actsplit = KUI:CreateHSplit(arg, ls.hsplit.bottomframe)
  local actions = ls.actsplit.topframe
  local bcast = ls.actsplit.bottomframe

  qf.syncpanel = ls.actsplit.topinset
  qf.responsespanel = cf.vsplit.rightinset

  --
  -- A panel is what it holds plus the rings round it, and the top half is the three of them stacked. The right column is
  -- that tall as well, and shows as many replies as fit before it scrolls.
  --
  local function outer(inset, usable)
    return usable + inset.rings.top + inset.rings.bottom
  end

  cf.hsplit.topinset:SetHeight(outer(ls.hsplit.topinset, PARTNERS_H) + outer(ls.actsplit.topinset, ACTIONS_H)
    + outer(ls.actsplit.bottominset, BTN_H))

  --
  -- A row fills the column. The list frame is inset one on the left and gives up SCROLLBAR_COMPENSATE on the right for its
  -- bar, and a row wider than what is left is clipped by the frame around it.
  --
  local PARTNER_ITEM_W = COL_W - 1 - KUI.SCROLLBAR_COMPENSATE

  arg = {
    name = "KonferAdminSyncScrollList",
    itemheight = PARTNER_ITEM_H,
    newitem = function(objp, num)
      return KUI.NewItemHelper(objp, num, "KonferSyncOwnerButton", PARTNER_ITEM_W, PARTNER_ITEM_H,
        nil, nil, function(this, idx) qf.selsyncer = qf.sortedsyncers[idx] end, nil)
      end,
    setitem = function(objp, idx, slot, btn)
      return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
          return shortaclass(konfer.apol.cfg:UserNameClass(qf.sortedsyncers[ix]))
        end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return KUI.SelectItemHelper(objp, idx, slot, btn, onoff, function()
          if (not qf.selsyncer) then return nil end
          if (qf.selsyncer ~= qf.sortedsyncers[idx]) then return false end
          return true
        end, slist_selectitem, nil, slist_selectitem)
      end,
    highlightitem = KUI.HighlightItemHelper,
  }
  partners.slist = KUI:CreateScrollList(arg, partners)
  qf.syncerslist = partners.slist

  arg = {
    x = 0, y = 0, width = BTN_W, height = BTN_H, text = L["Request"],
    enabled = false,
    tooltip = { title = "$$", text = L["TIP087"] },
  }
  actions.rsync = KUI:CreateButton(arg, actions)
  actions.rsync:Catch("OnClick", function(this, evt)
    local pp = konfer.apol

    clear_syncers_list()
    pp:CSendWhisperAM(pp.currentid, pp.cfg:UserName(qf.selsyncer), "RSYNC", "ALERT")
  end)
  qf.reqsyncbutton = actions.rsync

  arg.x = BTN_COL
  arg.text = L["Request (all)"]
  arg.tooltip = { title = "$$", text = L["TIP088"] }
  actions.rsyncall = KUI:CreateButton(arg, actions)
  actions.rsyncall:Catch("OnClick", function(this, evt)
    local pp = konfer.apol

    clear_syncers_list()
    pp:CSendChannelAM(pp.currentid, "RSYNC", "ALERT")
  end)
  qf.reqsyncallbutton = actions.rsyncall

  -- On a row of its own, centred under the two above it.
  arg.x = 0
  arg.text = L["Recover"]
  arg.tooltip = { title = "$$", text = L["TIP090"] }
  actions.recover = KUI:CreateButton(arg, actions)
  actions.recover:ClearAllPoints()
  actions.recover:SetPoint("TOP", actions, "TOP", 0, BTN_ROW)
  actions.recover:Catch("OnClick", function(this, evt)
    if (self:PolicyAdmin(konfer.apol) == 2) then
      recover_config(self)
    end
  end)
  qf.recoverbutton = actions.recover

  -- Centred in a panel exactly its own height.
  arg.text = L["Broadcast"]
  arg.tooltip = { title = "$$", text = L["TIP089"] }
  bcast.button = KUI:CreateButton(arg, bcast)
  bcast.button:ClearAllPoints()
  bcast.button:SetPoint("TOP", bcast, "TOP", 0, 0)
  bcast.button:Catch("OnClick", function(this, evt)
    local pp = konfer.apol

    -- Only the config this window has, and that this player administers, is theirs to push at anybody.
    if (not pp or not pp.currentid or not pp.cfg:MyStatus()) then
      return
    end

    pp.cfg:Broadcast(IsShiftKeyDown())
    pp:info(L["Broadcast sent! Please do not broadcast again for at least 30 seconds."])
  end)
  -- Published because Konfer.lua enables and disables it.
  konfer.qf.bcastbutton = bcast.button

  --
  -- The right column is the replies to a sync request and nothing else, so the list is the whole of it.
  --
  arg = {
    name = "KonferSyncReplyScrollList",
    itemheight = 48,
    newitem = function(objp, num)
      return rlist_newitem(objp, num)
    end,
    setitem = rlist_setitem,
    selectitem = rlist_selectitem,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return nil
    end,
  }
  rs.rlist = KUI:CreateScrollList(arg, rs)
  qf.syncers = rs.rlist

  sync_page_panels()
end

--
-- Put the sync tab back for the config PP has in hand.
--
local function refresh_sync(self, pp, reset)
  qf.sortedsyncers = {}
  qf.selsyncer = nil

  local ia, maid = pp.cfg:IsAdmin(pp.cfg:MyUid())

  for k,v in pairs(pp.cfg.admins) do
    if (k ~= maid) then
      tinsert(qf.sortedsyncers, k)
    end
  end
  tsort(qf.sortedsyncers, function(a,b)
    return (pp.cfg:UserName(a) or a) < (pp.cfg:UserName(b) or b)
  end)

  qf.syncerslist.itemcount = #qf.sortedsyncers
  qf.syncerslist:UpdateList()
  qf.syncerslist:SetSelected(nil)

  --
  -- The replies are to a request about one config. A reset for that same config, which is what a sync finishing asks for,
  -- keeps the replies from everybody not yet synced with; only a different config makes them nobody's.
  --
  if (reset and qf.replycfg ~= pp.currentid) then
    qf.repliers = nil
    qf.syncers.itemcount = 0
    qf.syncers:UpdateList()
    qf.syncers:SetSelected(nil)
    sync_page_panels()
    return
  end

  --
  -- Rather than clearing out the entire replies list, simply make sure that any repliers that are currently extant are still syncers.
  --
  local repliers = qf.repliers

  if (repliers) then
    local i = 1
    while (i <= #repliers) do
      local v = repliers[i]
      if (not pp.cfg.admins[v.cktheiruid]) then
        tremove(repliers, i)
      else
        i = i + 1
      end
    end
    qf.syncers.itemcount = #repliers
    qf.syncers:UpdateList()
    qf.syncers:SetSelected(nil)
  end

  sync_page_panels()
end

--
-- The sync tab shows the active policy's config, so that is the only one there is to put back. With no active policy, or one
-- with no config, there is nothing on the page to put back either.
--
function konfer:RefreshSyncUI(reset)
  if (qf.syncerslist and self.apol and self.apol.cfg) then
    refresh_sync(self, self.apol, reset)
  end
end

--
-- This is called from the MSYNC handler to update a replier now that we are done processing a sync. Simply give us the new
-- EID for the syncer so we can colorise and set the text correctly. We also mark that we are no longer busy syncing so that
-- other sync buttons become active again.
--
-- CFG is the config the sync was for. The page shows one config, so a sync about any other one has nothing on screen to
-- update; the sync itself has already been dealt with by the time this is called.
--
function cfgm:SyncUpdateReplier(theiruid, theireid)
  if (not self:IsActive()) then
    return
  end

  qf.busy_with_sync = nil
  if (not theiruid or not qf.repliers) then
    return
  end
  -- Ours is now what theirs was when they replied, if the events they sent were all of them.
  for k,v in pairs(qf.repliers) do
    if (v.theiruid == theiruid) then
      v.mylast = theireid
      v.mine = self.cksum
    end
  end
end

--
-- An event from the admin CKTHEIRUID has just been taken as it happened, which is only done when both copies agreed before
-- it, so both now stand at NEWSUM with EID the last of theirs on either side. Their row says so, rather than setting what
-- they replied before the event against what this copy holds after it. The rows of everybody else stay as they replied.
--
function cfgm:SyncReplierEvent(cktheiruid, eid, newsum)
  if (not self:IsActive() or not qf.repliers or qf.replycfg ~= self.id) then
    return
  end

  for _, v in pairs(qf.repliers) do
    if (v.cktheiruid == cktheiruid) then
      v.last, v.mylast, v.cksum, v.mine = eid, eid, newsum, newsum
    end
  end

  if (qf.syncers) then
    qf.syncers:UpdateList()
  end
end

--
-- This function is called when a user responds to a request for sync data. They respond with their highest event number and
-- checksum. We only use the event number currently. If we already have a sync relationship with this user, and they have
-- events higher than our last recorded event from them, we request all events after the latest one we have. If we have never
-- synced with them before we obviously request all info from them. We have a corner case we need to cover here though. If we
-- are a newly-appointed admin and we have never synced with anyone before we will request a "full sync" where they simply
-- send us their entire config, as well as who they are synced up with and to what point. Note that this function actually
-- just sets up all of the info for the syncer display in the right hand panel. If there is data to sync, an active sync
-- button will be displayed that when pressed, does the actual sync request.
--
function cfgm:ProcessSyncAck(myuid, theiruid, cktheiruid, lastevt, cksum)
  if (not self.syncing) then
    --
    -- If we are not syncing with anyone yet, then we only accept replies from the config owner, played on whichever of their
    -- characters. Others who respond are ignored for now. If it is the owner responding, the reply is not displayed and a
    -- full sync is asked of the owner at once. Once that has arrived we are syncing, and syncing with the other admins is a
    -- request to everybody like any other, which the user makes from the Sync page.
    --
    if (cktheiruid ~= self.owner) then
      return
    end
    self:RequestFullSync(self:UserName(theiruid))
    return
  end

  --
  -- The replies list is the page's, and the page shows one config. A reply about any other one has nowhere on screen to be
  -- listed and nowhere to be kept, the list being emptied and refilled every time the config changes.
  --
  if (not self:IsActive()) then
    return
  end

  local mylast = self.admins[cktheiruid].lastevent
  if (not mylast) then
    mylast = 0
  end

  local active = self.admins[cktheiruid].active or false

  -- Replies about another config than the one they are gathered for start a fresh list.
  if (qf.replycfg ~= self.id) then
    qf.repliers = nil
  end

  qf.replycfg = self.id
  qf.repliers = qf.repliers or {}

  --
  -- MINE is this copy's checksum as the reply came in, which is what theirs is held up against. Anything either side does
  -- afterwards moves one of the two and not the other, so this copy's checksum as it is now would make a row disagree that
  -- was never out of step. A row is brought up to date where the page knows exactly how (SyncReplierEvent,
  -- SyncUpdateReplier) and otherwise says what the reply said.
  --
  tinsert(qf.repliers, { name = shortaclass(self:UserNameClass(theiruid)),
    theiruid = theiruid, myuid = myuid, mylast = mylast,
    last = lastevt, cksum = cksum, mine = self.cksum, active = active, cktheiruid = cktheiruid,
  })

  qf.syncers.itemcount = #qf.repliers
  qf.syncers:UpdateList()
  qf.syncers:SetSelected(nil)
  sync_page_panels()
end

function cfgm:SendFullSync(dest, isrecover)
  if (not self.id or not self) then
    return
  end

  local ci = prepare_broadcast(konfer, self.id)

  --
  -- Add in the syncer information and the item database.
  --
  local cf = self
  -- DEST is a whisper target and so is a name. Which admin that is, is asked once here and compared as a uid below.
  local destuid = self:FindUser(dest)

  ci.s = {}
  for k,v in pairs(cf.admins) do
    if (k ~= destuid or isrecover) then
      ci.s[k] = v.lastevent or 0
    elseif (not isrecover) then
      --
      -- We are now in an active syncing relationship with this user. Mark it as such. We can also clear out any events we
      -- may have stored for this user, because they have them all, as of this very moment.
      --
      v.active = true
      v.sync = {}
      v.lastevent = 0
    end
  end

  ci.i = { cf.nitems, cf.items }
  ci.e = self.lastevent or 0

  --
  -- I may be on an alt. We need to set this to the real main ID not the alt ID.
  --
  local ia,aid = self:IsAdmin(self:MyUid())
  ci.d = aid

  if (not isrecover) then
    self.syncing = true

    -- Only the config on screen has a button to put back, and only once the page has been built.
    if (qf.reqsyncallbutton and self:IsActive()) then
      qf.reqsyncallbutton:SetEnabled(true)
    end
    konfer:GetPolicy(self.id):CSendWhisperAM(self.id, dest, "FSYNC", "ALERT", ci)
  else
    -- Named by its policy like everything else, but naming no config, the owner not holding it under this id. See RCOVR.
    konfer:GetPolicy(self.id):SendWhisperAM(dest, "RCACK", "ALERT", ci)
  end
end

--
-- This function is called when the mod very first starts up. The assumption (which is as close to correct as we're ever
-- going to get) is that the saved variables files are saved and flushed to disk, and therefore, the data we currently have
-- is "safe". Therefore, any events that we have already processed from a given user need no longer be stored. We send this
-- out to the guild for all guild lists, and to the raid (if we are in one) for all PUG lists. The recipient checks to see if
-- they are admins in any of those configs, and whether or not they have sync data stored for the sender. If they do, they
-- can safely remove any events that are <= the event ID that we have. This helps keep memory usage down to the barest minimum.
--
--
-- The group part can only go out once there is a group, which at login there seldom is, so it is sent again, alone, on
-- joining one. GROUPONLY says so.
--
function konfer:SyncCleanup(grouponly)
  local gsend = {}
  local psend = {}

  --
  -- Syncing is per config and a config belongs to one policy, so this asks each policy for its own rather than walking a
  -- shared pile. Which policy is active does not come into it: an inactive policy still syncs.
  --
  for kp, pol in pairs(self.policies) do
  for k,v in pairs(self:PolicyConfigs(pol)) do
    if (v.syncing) then
      local sps = ""
      local ntc = 0
      for ak,av in pairs(v.admins) do
        if (av.active) then
          local aps = strfmt("%s%014.0f", ak, av.lastevent or 0)
          sps = sps .. aps
          ntc = ntc + 1
        end
      end
      if (ntc > 0) then
        local entry = strfmt("%s:%d:%s", k, ntc, sps)

        --
        -- Where a config's sync traffic goes is the config's own to say, which is the rule CSendChannelAM applies. The guild
        -- takes a guild config from a guilded player and the group takes the rest. Sending every config both ways would put
        -- its id and its admins in front of people who are not in it, and send each entry twice.
        --
        if (v:Channel() == self.CHANNEL_GUILD and K.player.is_guilded) then
          if (not grouponly) then
            tinsert(gsend, entry)
          end
        elseif (KRP.in_party) then
          tinsert(psend, entry)
        end
      end
    end
  end
  end

  if (#gsend > 0) then
    self:SendGuildAM("CSYNC", "ALERT", gsend)
  end

  if (#psend > 0) then
    self:SendAM("CSYNC", "ALERT", psend)
  end
end

