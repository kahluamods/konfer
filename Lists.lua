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
local JSON = LibStub:GetLibrary("LibJsonLua")

if (not K) then
  return
end

local konfer = K:GetAddon("Konfer")
local cfgm = konfer.configmethods
local KU = K.Users
local L = konfer.L
local KUI = konfer.KUI
local KRP = konfer.KRP
local KC = konfer.KC
local MakeFrame = KUI.MakeFrame

-- Local aliases for global or Lua library functions
local _G = _G
local tinsert = table.insert
local tremove = table.remove
local tconcat = table.concat
local tsort = table.sort
local tostring, tonumber = tostring, tonumber
local strfmt = string.format
local strgsub = string.gsub
local strlen = string.len
local strsub = string.sub
local strfind = string.find
local strsplit = strsplit
local pairs, ipairs = pairs, ipairs
local assert = assert
local strlower = string.lower
local strupper = string.upper
local strmatch = string.match
local rand = math.random
local max = math.max

local white = konfer.white
local class = konfer.class
local shortclass = konfer.shortclass
local aclass = konfer.aclass
local shortaclass = konfer.shortaclass
local debug = konfer.debug

--
-- The dialogs this page puts up are kept on the widget table rather than in file locals because each is built once, with
-- callbacks closed over the window that raised it, and is then reopened rather than remade.
--
-- There is one window and it shows the active policy, so these are the mod's and are named as the mod's, without a policy
-- prefix. A policy's own frames are the prefixed ones and hang off the policy. What that costs is that a callback built
-- here outlives whichever policy happened to be active when it was built, so every one of them reads konfer.apol when it
-- runs rather than capturing a policy.
--

--
-- Every widget this page builds. There is one window and it shows the active policy, so there is one of these.
--
local qf = {}

--
-- The least the active policy's panel on the Config tab is given. Its height is what the policy built in it, which for a
-- policy that builds nothing there is nothing, and what is wanted then is a panel deep enough to hold the one line that says so.
--
-- This is the USABLE height, what goes inside the panel, and a titled panel draws about thirty pixels more than it: the
-- whole title plate comes out of the top ring although half of it hangs above the line, and the bottom ring takes its
-- twelve. So the box you see is this plus roughly thirty.
--
-- Deeper than the line strictly needs, and deliberately. The title plate hangs half its height down into the box, and a
-- line of words sitting close under it reads as pushed down however exactly halfway between the two rules it is. Room is
-- what fixes that; moving the words is not, and was tried.
--
local POLICYCFG_MIN = 28

--
-- Who of the config on screen is in the raid, as konfer.raid.uidmap has it, or nil. The raid is worked out against the config it
-- is being run against, which is the active policy's, and that is the config this page is showing, so the map always means the users listed here.
--
local function raid_uids()
  return konfer.raid.uidmap
end

-- Pointer to the enclosing tab structure in the main dialog.
local thistab = nil

-- Tab content frame for thistab (list manager global content frame)
local tcontent = nil

--
-- This file contains all of the UI handling code for the lists panel, as well as all list manipulation functions.
--

local function hide_popup()
  if (konfer.popupwindow) then
    konfer.popupwindow:Hide()
    konfer.popupwindow = nil
  end
end

--
-- The fields of a list's options, which are the keys the Config tab's unsaved changes are kept under. The yes-or-no ones
-- are told apart from the rest, a list that never had one set holding nil where the box shows false, and the two have to
-- read as the same or an untouched list would show as changed.
--
local LIST_FIELDS = { "sortorder", "def_rank", "strictcfilter", "strictrfilter", "extralist", "tethered", "altdisp" }
local LIST_FLAGS = { strictcfilter = true, strictrfilter = true, tethered = true, altdisp = true }

local function list_value(key, v)
  if (LIST_FLAGS[key]) then
    return v and true or false
  elseif (key == "def_rank") then
    return tonumber(v) or 0
  elseif (key == "extralist") then
    return v or "0"
  elseif (key == "sortorder") then
    return max(tonumber(v) or 1, 1)
  end

  return v
end

--
-- What is stored for field KEY of the list the tab's changes are to, which is the list selected when they were made. The
-- policy's own options are held as "p." and the option's name, and are read out of its block on the list.
--
local function list_saved(key)
  local pp = konfer.apol
  local id = qf.listpending and qf.listpending.picked
  local cl = id and pp and pp.cfg and pp.cfg.lists[id]

  if (not cl) then
    return nil
  end

  local pk = key:match("^p%.(.+)$")

  if (pk) then
    return pp:ListOption(pp.cfg.id, id, pk)
  end

  return list_value(key, cl[key])
end

--
-- The list's own options as they stand on screen, unsaved changes included. The platform's widgets edit this table and tell
-- the tab through changed that they have. The policy's options are not in it, being held in the tab's changes directly.
--
local function setup_linfo()
  qf.linfo = {}

  for _, f in ipairs(LIST_FIELDS) do
    qf.linfo[f] = qf.listpending:Value(f)
  end
end

--
-- Something in the buffer was changed by the user. Every field is handed to the tab's unsaved changes, which keep only what
-- differs from what is stored.
--
local function changed()
  if (not qf.current_listid or not qf.linfo) then
    return
  end

  for _, f in ipairs(LIST_FIELDS) do
    qf.listpending:Set(f, list_value(f, qf.linfo[f]))
  end
end

--
-- Whether anything shown under FRAME can be used. A control is anything that can say whether it is enabled, a button with
-- IsEnabled or a KoreUI widget that keeps its own enabled flag, and what is inside a control is part of it rather than a
-- control of its own. Anything hidden counts for nothing, and so does a frame that is hidden itself.
--
local function any_enabled(frame)
  if (not frame or not frame:IsShown()) then
    return false
  end

  for _, c in ipairs({ frame:GetChildren() }) do
    if (c:IsShown()) then
      if (c.IsEnabled) then
        if (c:IsEnabled()) then
          return true
        end
      elseif (c.enabled ~= nil) then
        if (c.enabled) then
          return true
        end
      elseif (any_enabled(c)) then
        return true
      end
    end
  end

  return false
end

--
-- The panels on the page read as disabled, their titles dimmed, while there is nothing in them to use. The Members panel,
-- and on the Config tab List Configuration and the policy's own options, are that way while no list is selected, and the
-- panels under the lists while none of their controls is enabled. Called wherever the page switches the selection or those
-- controls, and the policy's own panel on the Members tab is judged the same way from what the policy enabled in it.
--
local function sync_panels()
  local haslist = qf.current_listid ~= nil

  if (qf.memberspanel) then
    qf.memberspanel:SetEnabled(haslist)
  end

  --
  -- With no list there are no members to show or search, so the member list and the search box go too, the search box
  -- giving up what was typed in it.
  --
  if (qf.memberlist) then
    qf.memberlist:SetEnabled(haslist)
  end

  if (qf.findmember) then
    if (not haslist) then
      qf.findmember:SetText("")
      qf.findmember:ClearFocus()
    end
    qf.findmember:SetEnabled(haslist)
  end

  if (qf.listconfpanel) then
    qf.listconfpanel:SetEnabled(haslist)
  end

  if (qf.policycfgpanel) then
    qf.policycfgpanel:SetEnabled(haslist)
  end

  if (qf.memberpanel) then
    qf.memberpanel:SetEnabled(any_enabled(qf.memberctl))
  end

  if (qf.announcepanel) then
    qf.announcepanel:SetEnabled(any_enabled(qf.listctl))
  end

  if (qf.policypanel) then
    local pframe = konfer.apol and konfer.apol.listsframe

    qf.policypanel:SetEnabled(pframe and any_enabled(pframe) or false)
  end
end

--
-- The member list's columns: where each member stands, under each policy's own word for it (MEMBERS_STANDING), as wide as
-- that policy's standing column (konfer:StandingColumn) and shown only while it is the active policy, and the raider, which
-- takes the rest and carries an alt's connector under its main's name. A policy that shows no standing has no column of its
-- own. Neither sorts, the list being in the policy's own order. The list is built once with every policy's column, so each
-- is declared here and the active one's shown (mlist_policy_columns).
--
local function standing_key(pol)
  return pol.prefix .. "standing"
end

local function mlist_columns()
  local cols = {}
  local handles = {}

  for handle in pairs(konfer.policies) do
    tinsert(handles, handle)
  end

  tsort(handles)

  for _, handle in ipairs(handles) do
    local pol = konfer.policies[handle]
    local w = konfer:StandingColumn(pol)

    if (w > 0) then
      tinsert(cols, { key = standing_key(pol), text = pol:Str("MEMBERS_STANDING"), width = w })
    end
  end

  tinsert(cols, { key = "name", text = L["Raider"], width = "fill", tree = true })
  return cols
end

-- The active policy's standing column shown and every other hidden, once each time the active policy changes.
local function mlist_policy_columns()
  local pp = konfer.apol

  if (qf.memberpol == pp) then
    return
  end

  qf.memberpol = pp

  for _, pol in pairs(konfer.policies) do
    if (konfer:StandingColumn(pol) > 0) then
      qf.memberlist:SetColumnShown(standing_key(pol), pol == pp)
    end
  end
end

--
-- Refresh the local members list used in this panel. This just refreshes the user interface used here. If the members list
-- changes (users are added, deleted or moved) then this is only one of the functions that needs to be called. The item
-- editor and the loot rolling stuff also need to be refreshed but it is the responsibility of the functions that actually
-- change the data to call those, we don't do that here. This is only for refreshing the data that THIS code is responsible
-- for. The function below (RefreshAllMemberLists) refreshes everything (and calls this).
--
-- This updates qf.current_memberid and qf.sortedmembers.
local function refresh_member_list(this, listid)
  local pp = konfer.apol
  local oldmember = qf.current_memberid or nil
  local oldidx = nil

  if (listid and qf.current_listid and listid ~= qf.current_listid) then
    return
  end

  qf.current_memberid = nil
  qf.sortedmembers = nil

  if (not pp.currentid) then
    qf.current_listid = nil
    qf.current_list = nil
  end

  if (qf.current_listid and #qf.current_list.users > 0) then
    -- In the policy's order, a member's place in it being the position the row shows.
    local _, clu = pp.cfg:PolicyCall("Order", qf.current_list.users, qf.current_listid, qf.current_list.users)
    qf.sortedmembers = {}

    for k,v in ipairs(clu) do
      local ti = {id = v, idx = k, pos = k }
      tinsert(qf.sortedmembers, ti)
    end

    if (qf.current_list.tethered and qf.current_list.altdisp) then
      for i = #qf.sortedmembers, 1, -1 do
        local main = qf.sortedmembers[i].id
        local alts = pp.cfg:UserAlts(main)
        if (alts) then
          qf.sortedmembers[i].hasalts = true
          local pos = qf.sortedmembers[i].pos
          for j = 1, #alts do
            local ti = { id = alts[j], isalt = true, pos = pos, main = main, idx = qf.sortedmembers[i].idx,
              tree = (j == #alts) and "end" or "branch" }
            tinsert(qf.sortedmembers, i+j, ti)
          end
        end
      end
    end

    for k,v in ipairs(qf.sortedmembers) do
      if (v.id == oldmember) then
        oldidx = k
        break
      end
    end
  end

  mlist_policy_columns()
  qf.memberlist:UpdateList(qf.sortedmembers and #qf.sortedmembers or 0)

  -- This will update qf.current_memberid
  qf.memberlist:SetSelected(oldidx, true, true)

  local en = true
  if (not this:PolicyAdmin(pp) or qf.offmembers) then
    en = false
  end

  if ((qf.memberlist.itemcount < 1) or not qf.current_memberid) then
    en = false
  end

  qf.delete:SetEnabled(en)
  qf.resunres:SetEnabled(en)
  sync_panels()
end

local function mlist_newrow(cl, rf, num)
  local nfn = "GameFontNormalSmall"

  -- Who the row is, spelled out, the row saying which of the config's users it is as it is drawn (mlist_setitem), and what
  -- the policy says about them on the list shown.
  rf:HookScript("OnEnter", function(this)
    local pp = konfer.apol

    if (this.uid and pp and pp.cfg) then
      konfer:ShowUserTooltip(this, pp.cfg, this.uid, true, nil, qf.current_listid)
    end
  end)
  rf:HookScript("OnLeave", function(this)
    GameTooltip:Hide()
  end)

  --
  -- The roles of their main spec and off spec and the markers, packed against the row's right edge as the row is drawn, as
  -- every list of people has them (konfer:PackRowRight). The name is a font string of its own rather than the Raider cell,
  -- starting where the cell does, past an alt's connector, and having everything between that and whatever is last.
  --
  rf.osrole = KUI:CreateRoleIcon(rf, 12)
  rf.msrole = KUI:CreateRoleIcon(rf, 12)

  local si = rf:CreateFontString(nil, "ARTWORK", nfn)
  si:SetHeight(12)
  si:SetJustifyH("RIGHT")
  si:SetJustifyV("MIDDLE")
  rf.indicators = si

  local nm = rf:CreateFontString(nil, "ARTWORK", nfn)
  nm:ClearAllPoints()
  nm:SetPoint("TOPLEFT", rf.cells.name, "TOPLEFT", 0, 0)
  nm:SetJustifyH("LEFT")
  nm:SetJustifyV("MIDDLE")
  -- One line, a name too long for it ending in an ellipsis rather than running on over the icons.
  nm:SetWordWrap(false)
  rf.name = nm

  -- Only an admin picks a member, and Delete is never for an alt, whose place is their main's.
  rf:SetScript("OnClick", function(this)
    --
    -- The row is built once and clicked long afterwards, so the policy is read now rather than captured then.
    --
    local ia = konfer:PolicyAdmin(konfer.apol) and true or false

    if (not ia) then
      return
    end
    local idx = this:GetID()
    this:GetParent():GetParent():SetSelected(idx)
    qf.findmember:SetText("")
    qf.findmember:ClearFocus()
    if (this.isalt) then
      qf.delete:SetEnabled(false)
    else
      qf.delete:SetEnabled(ia)
    end
    sync_panels()
  end)
end

local function mlist_setitem(cl, idx, slot, btn)
  local pp = konfer.apol
  local cfg = pp.cfg
  local uid = qf.sortedmembers[idx].id
  local nm = shortclass(cfg:UserNameClass(uid))
  local pos = qf.sortedmembers[idx].pos
  local ench = cfg:IsEnchanter(uid)
  local frozen = cfg:IsFrozen(uid)
  local res = cfg:IsReserved(uid)
  local tree = qf.sortedmembers[idx].tree

  --
  -- What a member's place in the list is called is the policy's business, not ours. Suicide Kings shows the raw position
  -- because for it the position is the standing; a points based policy will want to show its own number. The stored order is
  -- unaffected either way -- this is display only.
  --
  local _, postext = cfg:PolicyCall("PositionText", tostring(pos), qf.current_listid, uid, pos)

  -- An alt stands where their main does, so their own standing cell is empty, the connector saying whose they are.
  local key = standing_key(pp)
  local _, font = konfer:StandingColumn(pp)

  btn.uid = uid
  btn.standing = postext
  btn.isalt = tree and true or nil
  btn:SetTree(tree, 0)

  if (btn.cells[key]) then
    btn.cells[key]:SetFontObject(font)
    btn:SetCell(key, tree and "" or ("[" .. tostring(postext) .. "]"))
  end

  btn.name:SetText(nm)
  btn.indicators:SetText(konfer:UserMarkers(ench, frozen, res))
  konfer:SetRoleIcons(btn.msrole, btn.osrole, cfg, uid)

  -- The name stops a gap short of whatever is last at the right, or the row's own inset with nothing there.
  local at, gap = konfer:PackRowRight(btn, btn.osrole, btn.msrole, btn.indicators)

  if (at == btn) then
    btn.name:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", gap, 0)
  else
    btn.name:SetPoint("BOTTOMRIGHT", at, "BOTTOMLEFT", gap, -2)
  end
end

--
-- Tell the policy's own panel on this page what is selected, if it has a panel and wants to know. It is handed the frame it
-- built into, so that it can find its own widgets on it.
--
local function list_selection()
  local pp = konfer.apol
  local lp = pp.ListsPage
  local pframe = pp.listsframe

  if (lp and lp.ListSelection and pframe) then
    konfer:PolicyHook(pp, "ListsPage.ListSelection", nil, lp.ListSelection, pframe, pp.currentid, qf.current_listid)
  end

  -- And the policy's own tabs on this page, which are about the selected list too.
  for _, rec in pairs(pp.liststabs or {}) do
    if (rec.def.ListSelection) then
      konfer:PolicyHook(pp, "ListsTabs.ListSelection", nil, rec.def.ListSelection, rec.client, pp.currentid, qf.current_listid)
    end
  end
end

--
-- The member controls, Member admin's and the policy's own, act on the member selected on the Members tab, so on any other
-- tab they are shown but disabled. QF.offmembers says another tab is up, and the policy is told no member is selected.
--
local function member_selection(uid, pos)
  local pp = konfer.apol
  local lp = pp.ListsPage
  local pframe = pp.listsframe

  if (qf.offmembers) then
    uid, pos = nil, nil
  end

  if (lp and lp.MemberSelection and pframe) then
    konfer:PolicyHook(pp, "ListsPage.MemberSelection", nil, lp.MemberSelection, pframe, pp.currentid, qf.current_listid, uid, pos)
  end
end

--
-- The same for the policy's own panel on the Config tab, whose options are held in the tab's unsaved changes as "p." and
-- the option's name, and which sets its widgets from those.
--
local function config_list_selection()
  local pp = konfer.apol
  local lp = pp.ListsPage
  local pcfgframe = pp.listscfgframe

  if (lp and lp.ConfigListSelection and pcfgframe) then
    konfer:PolicyHook(pp, "ListsPage.ConfigListSelection", nil, lp.ConfigListSelection, pcfgframe, pp.currentid,
      qf.current_listid)
  end
end

local function mlist_selectitem(objp, idx, slot, btn, onoff)
  local pp = konfer.apol
  local onoff = onoff or false

  --
  -- A popup that stays open while things are picked from it, the insert popup, is left alone: every insert refreshes the
  -- member list and reselects in it, which would otherwise take the popup away in the middle of being used. It closes
  -- itself once the pointer leaves it.
  --
  if (not (konfer.popupwindow and konfer.popupwindow.keep)) then
    hide_popup()
  end

  if (onoff) then
    qf.current_memberid = qf.sortedmembers[idx].id
    local ridx = idx
    if (qf.current_list.tethered) then
      ridx = qf.sortedmembers[idx].idx
      if (qf.sortedmembers[idx].isalt) then
        qf.current_memberid = qf.sortedmembers[idx].main
      end
    end

    qf.resunres:SetText(L["Reserve"])
    if (konfer:PolicyAdmin(pp) and pp.cfg:IsReserved(qf.current_memberid)) then
      qf.resunres:SetText(L["Unreserve"])
    end
    local en = konfer:PolicyAdmin(pp) and not qf.offmembers

    qf.resunres:SetEnabled(en)
    qf.delete:SetEnabled(en)
    member_selection(qf.current_memberid, ridx)
  else
    qf.resunres:SetEnabled(false)
    qf.delete:SetEnabled(false)
    qf.resunres:SetText(L["Reserve"])
    qf.current_memberid = nil
    member_selection(nil, nil)
  end

  sync_panels()
end

--
-- Handling the members list is a bit tricky if the configuration has tethered alts. Without tethered alts, the display is a
-- direct 1-1 mapping from the members list to what is displayed. However, if there are tethered alts, it is more useful to
-- display the alts of the user underneath their main, and have things like "Move Up" and "Move Down" move all those users as
-- a block. This is purely a visual thing, as in the actual member list database there is only one entry, for the user's main
-- character. The easiest way to deal with this is to do all manipulations such as suiciding, moving users up and down etc on
-- the raw members list data, and then to create a for-display array that is refreshed from that raw data each time a change is made.
--

--
-- With no list selected, the list's options say nothing rather than go on showing the last list's. show_list puts them
-- back when one is selected.
--
local function rlist_setenabled(onoff)
  local pp = konfer.apol
  local onoff = onoff or false
  local lc = qf.listconf

  lc.sortorder:SetEnabled(onoff)
  lc.defrank:SetEnabled(onoff and pp and pp.cfg:RankFiltering())
  lc.cfilter:SetEnabled(onoff)
  lc.rfilter:SetEnabled(onoff)
  lc.tethered:SetEnabled(onoff)
  lc.altdisp:SetEnabled(onoff)
  lc.extralist:SetEnabled(onoff)
  qf.insert:SetEnabled(onoff and not qf.offmembers)

  if (not onoff) then
    lc.sortorder:SetText("")
    lc.defrank:SetValue(nil, true)
    lc.cfilter:SetChecked(false, true)
    lc.rfilter:SetChecked(false, true)
    lc.tethered:SetChecked(false, true)
    lc.altdisp:SetChecked(false, true)
    lc.extralist:SetValue(nil, true)
  end

  onoff = onoff and konfer:PolicyAdmin(pp)
  qf.listcfgbuttons.createbutton:SetEnabled(onoff)
  qf.listcfgbuttons.deletebutton:SetEnabled(onoff)
  qf.listcfgbuttons.renamebutton:SetEnabled(onoff)
  qf.listcfgbuttons.copybutton:SetEnabled(onoff)
  qf.listcfgbuttons.exportbutton:SetEnabled(onoff)

  -- Importing and adding the missing are the policy's to offer, and one that offers neither has neither button. There is
  -- nobody missing from a list to add out of a group.
  qf.listcfgbuttons.importbutton:SetEnabled((onoff and pp and pp.ImportList) and true or false)
  qf.listcfgbuttons.addmissingbutton:SetEnabled((onoff and pp and pp.AddMissing and KRP.in_party) and true or false)
end

--
-- Put the selected list's options on screen, unsaved changes included, the policy's panel with them. Nothing here is an
-- edit, so no widget throws, and whether alts can be shown follows whether they are tethered, as ticking it does.
--
-- The extra list is offered every list but this one, a list being its own extra list meaning an award lands on it twice.
--
local function show_list()
  local pp = konfer.apol

  setup_linfo()

  local lc = qf.listconf
  local others = {}

  for _, v in ipairs(pp.cfg:ListChoices()) do
    if (v.value ~= qf.current_listid) then
      tinsert(others, v)
    end
  end

  lc.sortorder:SetText(tostring(qf.linfo.sortorder or 1))
  lc.defrank:SetValue(qf.linfo.def_rank or 0, true)
  lc.cfilter:SetChecked(qf.linfo.strictcfilter, true)
  lc.rfilter:SetChecked(qf.linfo.strictrfilter, true)
  lc.tethered:SetChecked(qf.linfo.tethered, true)
  lc.altdisp:SetChecked(qf.linfo.altdisp, true)
  lc.altdisp:SetEnabled(qf.linfo.tethered and true or false)
  lc.extralist.label:SetText(pp:Str("AWARD_EXTRALIST"))
  lc.extralist:UpdateItems(others)
  lc.extralist:SetValue(qf.linfo.extralist or "0", true)
end

local function rlist_selectitem(objp, idx, slot, btn, onoff)
  local pp = konfer.apol
  local onoff = onoff or false

  hide_popup()
  rlist_setenabled(onoff)
  qf.listcfgbuttons.createbutton:SetEnabled(konfer:PolicyAdmin(pp))

  -- The tab's unsaved changes are to the list selected. See PS.Pick.
  qf.listpending:Pick(onoff and pp.sortedlists[idx] and pp.sortedlists[idx].id or nil)

  if (onoff) then
    qf.current_listid = pp.sortedlists[idx].id
    qf.current_list = pp.cfg.lists[qf.current_listid]
    show_list()
    qf.listctl.announcebutton:SetEnabled((konfer:PolicyAdmin(pp) and raid_uids()) and true or false)
    -- As RefreshListsUIForRaid has it, which deselecting a list turned off.
    qf.listctl.announceallbutton:SetEnabled((konfer:PolicyAdmin(pp) and konfer.raid.uidmap and qf.lists.itemcount > 0) and true or false)
  else
    qf.current_listid = nil
    qf.current_list = nil
    qf.listctl.announcebutton:SetEnabled(false)
    qf.listctl.announceallbutton:SetEnabled(false)
  end

  list_selection()
  config_list_selection()

  -- Updates qf.current_memberid, qf.sortedmembers
  refresh_member_list(konfer, qf.current_listid)
  sync_panels()
end

local function create_list_button(this)
  local box

  if (not qf.newlistdlg) then
    qf.newlistdlg, box = K.SingleStringInputDialog(this, "KonferSetupNewList",
      { text = L["Create roll list"], owner = konfer.apol }, L["NEWLIST"], 400, 185)

    --
    -- CreateNewList says for itself why a name it refuses is no good, too short among them, so nothing is checked here.
    --
    local function verify_with_create(objp, val)
      local pp = konfer.apol
      if (pp.cfg:CreateNewList(val)) then
        objp:Show()
        objp.ebox:SetFocus()
        return true
      end
      qf.newlistdlg:Hide()
      return false
    end

    qf.newlistdlg:Catch("OnAccept", function(t, evt)
      return verify_with_create(qf.newlistdlg, t.ebox:GetText())
    end)

    qf.newlistdlg:Catch("OnCancel", function(t, evt)
      qf.newlistdlg:Hide()
      return false
    end)

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    qf.newlistdlg:Catch("OnHide", function(t, evt)
      qf.mainwin:Show()
    end)

    box:Catch("OnEnterPressed", function(t, evt, val)
      return verify_with_create(qf.newlistdlg, val)
    end)
  else
    box = qf.newlistdlg.ebox
  end

  box:SetText("")
  qf.mainwin:Hide()
  qf.newlistdlg:Show()
  box:SetFocus()
end

local function delete_list_button(this, lid)
  local pp = konfer.apol
  pp.cfg:DeleteListCmd(lid)
end

local function rename_list_button(this, lid)
  local pp = konfer.apol

  hide_popup()

  local function rename_helper(newname, old)
    local pp = konfer.apol
    local found = false
    local lname = strlower(newname)

    for k,v in pairs(pp.cfg.lists) do
      if (strlower(pp.cfg.lists[k].name) == lname) then
        found = true
      end
    end

    if (found) then
      pp:err(L["roll list %q already exists. Try again."], white(newname))
      return true
    end

    local rv = pp.cfg:RenameList(old, newname)
    if (rv) then
      return true
    end

    return false
  end

  K.RenameDialog(this, { text = L["Rename roll list"], owner = pp }, { L["Current list: %s"], pp.cfg.lists[lid].name }, L["New name"], 32,
    rename_helper, lid,
    qf.mainwin)
end

local function copy_list_button(this, lid)
  local pp = konfer.apol

  hide_popup()

  local function copy_helper(newname, old)
    local pp = konfer.apol
    local found = false
    local lname = strlower(newname)

    for k,v in pairs(pp.cfg.lists) do
      if (strlower(pp.cfg.lists[k].name) == lname) then
        found = true
      end
    end

    if (found) then
      pp:err(L["roll list %q already exists. Try again."], white(newname))
      return true
    end

    local rv = pp.cfg:CopyList(old, newname)
    if (rv) then
      return true
    end

    return false
  end

  K.RenameDialog(this, { text = L["Copy roll list"], owner = pp }, { L["Current list: %s"], pp.cfg.lists[lid].name },
    L["Destination list"], 32, copy_helper, lid, qf.mainwin)
end

--
-- WHERE AN INSERT LANDS IS THE POLICY'S
--
-- Four dialogs put people onto a list, the insert popup, both halves of the import and add missing, and every one of them
-- used to ask the same SK question with a checkbox of its own: at the bottom, or somewhere at random. A position is only a
-- standing in this one policy, so each of the four now reserves a row and lets the policy fill it.
--
-- WHERE names which of the four it is, so a policy can keep the answer apart per dialog. Importing a whole guild rank and
-- adding one person to a list are not the same question and have never had the same default.
--
-- The strip is built per policy and the others are hidden, because these dialogs are built once and the window outlives
-- any policy. A policy with no InsertUI gets an empty row, which costs one row and keeps every dialog the same height
-- whichever policy is up.
--
local INSERT_STRIP_H = 20

local function insert_strip(parent, owner, where, inset)
  local pp = konfer.apol

  parent.kstrips = parent.kstrips or {}

  for handle, f in pairs(parent.kstrips) do
    f:SetShown(handle == pp.handle)
  end

  if (parent.kstrips[pp.handle] or not pp.InsertUI or not pp.InsertUI.Construct) then
    return
  end

  local f = KUI.MakeFrame("Frame", nil, parent)

  f:SetPoint("TOPLEFT", parent, "TOPLEFT", inset or 0, 0)
  f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0 - (inset or 0), 0)

  parent.kstrips[pp.handle] = f
  konfer:PolicyHook(pp, "InsertUI.Construct", nil, pp.InsertUI.Construct, pp, f, owner, where)
end

--
-- What the next insert into LISTID should carry, from whatever the policy put in that row. Nothing given means nothing to
-- say, and the platform puts them on the bottom.
--
local function insert_info(listid, where)
  local _, pdata = konfer.apol.cfg:PolicyCall("InsertInfo", nil, listid, where)

  return pdata
end

--
-- Everyone who can be inserted into the selected list: every user not already on it, and on a tethered list only mains, with
-- their alts shown under them. Raid members first when in a raid, then by name.
--
local function insert_choices(this)
  local pp = konfer.apol
  local ulist = {}
  local cfg = pp.cfg

  for k,v in pairs(pp.cfg.uids) do
    if (not cfg:IsInList(k, qf.current_listid)) then
      local doit = false
      local ti = nil
      if (qf.current_list.tethered) then
        if (not cfg:IsAlt(k)) then
          doit = true
        end
      else
        doit = true
      end
      if (doit) then
        ti = { value = k, text = class(cfg:UserNameClass(k)), }
        tinsert(ulist, ti)
      end
    end
  end

  tsort(ulist, function(a,b)
    -- Sort so that if we are in a raid, that current raid members appear first and then all of the offline members. Makes it
    -- a lot easier to find a user if you need to add them in the middle of a raid.
    local anm = cfg:UserName(a.value)
    local bnm = cfg:UserName(b.value)

    if (KRP.in_party) then
      local air = KRP.players[anm] and true or false
      local bir = KRP.players[bnm] and true or false
      if (air and not bir) then
        return true
      end
      if (bir and not air) then
        return false
      end
    end
    return strlower(anm) < strlower(bnm)
  end)

  if (qf.current_list.tethered) then
    for i = #ulist, 1, -1 do
      for k,v in ipairs(cfg:UserAlts(ulist[i].value) or {}) do
        -- The row inserts the main, whose id it carries, and is found by the alt's own name.
        local ti = { value = ulist[i].value, text = "  - "..class(cfg:UserNameClass(v)), name = cfg:UserName(v) }
        tinsert(ulist, i+1, ti)
      end
    end
  end

  return ulist
end

--
-- The popup stays open after each pick, so that a whole raid can be added in one go, and whoever was just inserted is taken out of it.
--
local function insert_member(this, btn)
  hide_popup()

  local pp = konfer.apol
  local ulist = insert_choices(this)

  local function pop_func(puid)
    if (qf.current_list.tethered) then
      local ia, mui = pp.cfg:IsAlt(puid)
      if (ia) then
        puid = mui
      end
    end

    --
    -- Where they land is the policy's, read from whatever it put at the top of this popup. A policy with nothing there
    -- says nothing and they go on the bottom.
    --
    local rlist = pp.cfg.lists[qf.current_listid]

    pp.cfg:InsertMember(puid, qf.current_listid, insert_info(qf.current_listid, "insert"))

    pp:info(L["added %s to list %q."], shortaclass(pp.cfg:UserNameClass(puid)), white(rlist.name))

    --
    -- On a tethered list an alt's row carries its main's id, which is what was inserted, so this takes the main and every
    -- one of their alts' rows out together.
    --
    if (qf.insert_popup) then
      qf.insert_popup:RemoveValue(puid)
    end
  end

  if (not qf.insert_popup) then
    --
    -- The strip along the top is the policy's. Who may be inserted, and the search box under it, are the same question in
    -- every policy and stay here; how they arrive is the policy's own, so it says how tall it wants that strip and fills
    -- it, and pop_func above asks it what the next insert should carry. Suicide Kings puts Insert randomly there.
    --
    qf.insert_popup = K.PopupSelectionList(this, "KonferInsertMemberPopup",
      ulist, nil, 205, 300, qf.mainwin:GetPage(this.LISTS_PAGE).content, 16, pop_func, INSERT_STRIP_H, 20, { keep = true })

    local arg = {
      x = 0, y = 2, len = 16, font = "ChatFontSmall",
      tooltip = { title = L["User search"], text = L["TIP099"] },
      parent = qf.insert_popup.footer,
    }
    qf.insert_popup.usearch = KUI:CreateEditBox(arg, qf.insert_popup.footer)
    --
    -- The footer runs to the popup's edges. The box stands the standard gap in from the left, and ends the same gap short
    -- of the scroll bar above it, which is the rightmost SCROLLBAR_WIDTH of the popup.
    --
    qf.insert_popup.usearch:ClearAllPoints()
    qf.insert_popup.usearch:SetPoint("TOPLEFT", qf.insert_popup.footer, "TOPLEFT", KUI.WIDGET_GAP, 2)
    qf.insert_popup.usearch:SetPoint("TOPRIGHT", qf.insert_popup.footer, "TOPRIGHT",
      0 - KUI.SCROLLBAR_WIDTH - KUI.WIDGET_GAP, 2)
    qf.insert_popup.usearch.toplevel = qf.insert_popup
    qf.inssearch = qf.insert_popup.usearch
    qf.insert_popup.usearch:Catch("OnEnterPressed", function(t)
      t:SetText("")
    end)
    qf.insert_popup.usearch:HookScript("OnEnter", function(t)
      t.toplevel:StopTimeoutCounter()
    end)
    qf.insert_popup.usearch:HookScript("OnLeave", function(t)
      t.toplevel:StartTimeoutCounter()
    end)
    qf.insert_popup.usearch:Catch("OnValueChanged", function(t, evt, newv, user)
      local pp = konfer.apol
      if (not pp.cfg.uids or not t.toplevel.selectionlist or t.toplevel.slist.itemcount < 1) then
        return
      end
      if (user and newv and newv ~= "") then
        local lnv = strlower(newv)
        local tln
        -- The first row in the order shown whose name holds what was typed, an alt's row by the alt's own name.
        for k,v in ipairs(t.toplevel.selectionlist) do
          tln = strlower(v.name or pp.cfg:UserName(v.value) or "")
          if (strfind(tln, lnv, 1, true)) then
            t.toplevel.slist:SetSelected(k, true)
            return
          end
        end
      end
    end)
  else
    qf.insert_popup:UpdateList(ulist)
  end

  -- The popup's header runs to its edges, where a dialog's row already stands clear of them.
  insert_strip(qf.insert_popup.header, qf.insert_popup, "insert", KUI.WIDGET_GAP)

  qf.insert_popup:ClearAllPoints()
  qf.insert_popup:SetPoint("TOPLEFT", btn, "TOPRIGHT", 0, 0)
  qf.insert_popup:Show()
  this.popupwindow = qf.insert_popup
end

local function resunres_member(this, btn)
  local pp = konfer.apol
  hide_popup()

  local ir = pp.cfg:IsReserved(qf.current_memberid) or false
  pp.cfg:ReserveUser(qf.current_memberid, not ir)
end

local function insert_list_member(cfp, uid, listid, pdata, nocmd)
  local rl = cfp.lists[listid]

  if (not rl) then
    return true
  end

  --
  -- Somebody this config does not have. A list holds uids and every reader of one looks the uid up to find a name, a class
  -- and a standing, so an entry naming nobody is not a cosmetic fault: in a list where the index is the standing it takes a
  -- position, and everybody under it is one place lower than they should be for as long as it sits there.
  --
  -- It arrives when an event about a user reaches us before the user does, which a raider taking events from any admin can
  -- see, and it is refused here rather than repaired afterwards. The two clients then disagree about the list, which is what
  -- syncing is for and is a great deal better than agreeing about a member who does not exist.
  --
  if (not cfp.uids[uid] or cfp:IsInList(uid, listid)) then
    return true
  end

  --
  -- Membership is the platform's and where they stand on it is the policy's, so the placing is handed over. PDATA is
  -- whatever that policy says about somebody on a list, a position for Suicide Kings and a pair of numbers for EP/GP, and
  -- nothing here ever looks inside it. What comes back is what was actually done, which is what the event then carries, so
  -- two clients place them the same way rather than each resolving the same request for itself.
  --
  -- A policy with nothing to say about it, and one whose hook failed or did not put them on, gets the bottom of the list.
  --
  local ok, used = cfp:PolicyCall("SetMemberInfo", nil, listid, uid, pdata)

  if (not ok or not cfp:IsInList(uid, listid)) then
    tinsert(rl.users, uid)
    used = nil
  end

  if (not nocmd) then
    cfp:AddEvent("IMLST", uid, listid, used)
  end

  return false
end

local function delete_member(this)
  local pp = konfer.apol
  hide_popup()

  local c = qf.memberlist:GetSelected()
  if (not c) then
    return
  end

  local uid = qf.sortedmembers[c].id
  if (qf.current_list.tethered and qf.sortedmembers[c].isalt) then
    uid = qf.sortedmembers[c].main
  end

  pp.cfg:DeleteMember(uid, qf.current_listid, false)
end

--
-- The line at the top of every dialog that acts on the current list, naming it as every confirmation names what it is about
-- (K.ConfirmationDialog). Centred and only as wide as its words, which the label keeps true itself each time it is given new
-- ones.
--
local function current_list_box(dlg, ypos)
  return KUI:CreateStringLabel({ x = "CENTER", y = ypos, font = "GameFontNormal", text = "" }, dlg)
end

local function show_current_list(box)
  box:SetText(strfmt(L["Current list: %s"], white(qf.current_list.name)))
end

--
-- The same box, for a policy's own list dialogs, so that every dialog about a list says which one the same way.
--
function konfer:CurrentListBox(dlg, ypos)
  return current_list_box(dlg, ypos)
end

function konfer:ShowCurrentList(box, cfgid, listid)
  local rl = self:Config(cfgid).lists[listid]

  box:SetText(strfmt(L["Current list: %s"], white(rl and rl.name or "")))
end

--
-- GETTING PEOPLE ONTO A LIST FROM OUTSIDE
--
-- Importing members and adding the missing ones are a policy's to offer, through the descriptor's ImportList and AddMissing,
-- because what doing so means, where people land and what they arrive with, is the policy's. Neither button does anything
-- for a policy that offers neither. What the platform keeps is the part that is the same in every policy: turning names into
-- the config's uids, a guild rank into users, and saying who is missing from a list.
--

--
-- Whether UID goes onto LISTID in an import, SEEN being the uids already taken for it. Everybody goes on once, and a
-- tethered list holds mains only, so an alt stands for their main. The uid to put on, or nil.
--
function cfgm:ImportCandidate(listid, uid, seen)
  local rl = self.lists[listid]

  if (rl and rl.tethered) then
    local ia, main = self:IsAlt(uid)

    if (ia) then
      uid = main
    end
  end

  if (seen[uid]) then
    return nil
  end

  seen[uid] = true
  return uid
end

--
-- The names in TEXT, in the order given. A JSON array of strings, where the order is the point, or names separated by
-- commas, spaces ignored. An empty entry, such as a trailing comma leaves, is nobody. Nil and why when TEXT is a JSON array
-- that does not parse or holds something other than names.
--
function konfer:ParseNames(text)
  local s = strgsub(text or "", "^%s+", "")
  local names = {}

  if (strsub(s, 1, 1) == "[") then
    local ok, arr = pcall(JSON.decode, s)

    if (not ok or type(arr) ~= "table") then
      return nil, L["that is not a JSON array of names."]
    end

    for i = 1, #arr do
      if (type(arr[i]) ~= "string") then
        return nil, L["that is not a JSON array of names."]
      end

      local nm = strgsub(arr[i], "^%s*(.-)%s*$", "%1")

      if (nm ~= "") then
        tinsert(names, nm)
      end
    end

    return names
  end

  -- Bracketed, gsub's count of what it replaced being strsplit's limit on how many pieces to make.
  for _, v in ipairs({ strsplit(",", (strgsub(s, " ", ""))) }) do
    if (v ~= "") then
      tinsert(names, v)
    end
  end

  return names
end

-- Whether TEXT is meant as another addon's export rather than names, a JSON object where names are an array or a list.
function konfer:IsExportText(text)
  return strmatch(text or "", "^%s*{") and true or false
end

--
-- The lists in TEXT, a list export in JSON from this mod or from the old Konfer Suicide Kings, the two being one shape, in
-- the export's order: each { name, members }, MEMBERS being { name, class } in the list's order, CLASS a K.ClassIndex
-- value or nil. Each export says which class its ids stand for, so they are read through its own table. Nil and why when
-- TEXT is not one or holds no list.
--
function konfer:ParseListExport(text)
  local ok, t = pcall(JSON.decode, text)
  local ex = ok and type(t) == "table" and (t.konfer or t.ksk)

  if (type(ex) ~= "table" or type(ex.lists) ~= "table") then
    return nil, L["that is not a Konfer list export."]
  end

  local classes, users, out = {}, {}, {}

  for _, c in ipairs(type(ex.classes) == "table" and ex.classes or {}) do
    if (type(c) == "table" and type(c.v) == "string") then
      classes[tostring(c.id)] = K.ClassIndex[strupper(c.v)]
    end
  end

  for _, u in ipairs(type(ex.users) == "table" and ex.users or {}) do
    if (type(u) == "table" and type(u.n) == "string") then
      users[tostring(u.id)] = { name = u.n, class = classes[tostring(u.c)] }
    end
  end

  for _, l in ipairs(ex.lists) do
    if (type(l) == "table" and type(l.users) == "table") then
      local members = {}

      for _, id in ipairs(l.users) do
        if (users[tostring(id)]) then
          tinsert(members, users[tostring(id)])
        end
      end

      tinsert(out, { name = tostring(l.n or l.id), members = members })
    end
  end

  if (#out == 0) then
    return nil, L["that export has no lists."]
  end

  return out
end

--
-- The uid of the user TYPED names in this config, TYPED having come from outside: typed into a box or read from another
-- addon's export, bare or with a realm. It is looked up the way it is given, the realm left as it is, and failing that
-- without regard to case, since this client cannot know how another realm is spelled. Nil for nobody.
--
function cfgm:FindImported(typed)
  local uid = self:FindUser(typed)

  if (uid) then
    return uid
  end

  local low = strlower(typed)
  local lowname = strlower(K.CanonicalName(typed) or typed)

  for k, v in pairs(self.uids) do
    local vl = strlower(self:UserName(k) or "")

    if (vl == low or vl == lowname) then
      return k
    end
  end
end

--
-- The uids NAMES stand for in this config (FindImported), in their order and each once (ImportCandidate), for LISTID, and
-- the names it holds nobody for.
--
function cfgm:ImportNames(listid, names)
  local uids, missing, seen = {}, {}, {}

  for _, typed in ipairs(names) do
    local uid = self:FindImported(typed)

    if (not uid) then
      tinsert(missing, typed)
    else
      uid = self:ImportCandidate(listid, uid, seen)

      if (uid) then
        tinsert(uids, uid)
      end
    end
  end

  return uids, missing
end

--
-- The uids MEMBERS stand for in this config, each { name, class } read from another addon's export, in their order and each
-- once (ImportCandidate), for LISTID. Somebody it does not hold is made a user with the class the export gives, as a guild
-- import makes them. Then BYINDEX, the uid each member was taken as, nil for one who was not.
--
function cfgm:ImportMembers(listid, members)
  local uids, byindex, seen = {}, {}, {}

  for i, m in ipairs(members) do
    local uid = self:FindImported(m.name) or self:CreateNewUser(m.name, m.class, true, true)

    uid = uid and self:ImportCandidate(listid, uid, seen)

    if (uid) then
      tinsert(uids, uid)
      byindex[i] = uid
    end
  end

  konfer:RefreshUsers()

  return uids, byindex
end

--
-- The guild members at rank RANK as this config's uids, each once, for LISTID. One who is not yet a user of it is made
-- one, a guild import being one of the ways somebody arrives in a config.
--
function cfgm:ImportGuildRank(listid, rank)
  local uids, seen = {}, {}

  for i = 1, K.guild.numroster do
    local gm = K.guild.roster.id[i]

    if (gm.rank == rank) then
      local uid = self:FindUser(gm.name) or self:CreateNewUser(gm.name, gm.class, false, true)

      uid = uid and self:ImportCandidate(listid, uid, seen)

      if (uid) then
        tinsert(uids, uid)
      end
    end
  end

  konfer:RefreshUsers()

  return uids
end

--
-- Who could be on LISTID and is not: everybody the config holds, or with RAIDONLY those of them in the raid. A tethered list
-- takes mains only, an alt standing for their main.
--
function cfgm:MissingFromList(listid, raidonly)
  local from = raidonly and (raid_uids() or {}) or self.uids
  local uids, seen = {}, {}

  for uid in pairs(from) do
    uid = self:ImportCandidate(listid, uid, seen)

    if (uid and not self:IsInList(uid, listid)) then
      tinsert(uids, uid)
    end
  end

  return uids
end

local EXP_CUR_CSV = 1
local EXP_CUR_JSON = 2
local EXP_ALL_JSON = 3

--
-- THESTRING is what the dialog shows and the user copies. A JSON export is gathered as Lua tables first, LISTS being one
-- entry per list exported and UV one per user any of them holds, each user named once however many lists they are on, with
-- UU the set of those already named. LibJsonLua does all the quoting and escaping at the end.
--
local thestring
local lists, uu, uv

local function do_json_list(this, listid)
  local pp = konfer.apol
  local ll = pp.cfg.lists[listid]
  local lul = {}

  for k,v in ipairs(ll.users) do
    local uname, uclass = pp.cfg:UserNameClass(v)
    if (not uu[v]) then
      uu[v] = true
      tinsert(uv, { id = v, n = uname, c = strfmt("%02d", uclass or 0) })
    end
    tinsert(lul, tostring(v))
  end

  tinsert(lists, { id = listid, n = ll.name, users = lul })
end

local function final_json_string(this)
  local classes = {}

  for k,v in pairs(K.IndexClass) do
    if (v.u) then
      tinsert(classes, { id = strfmt("%02d", k), v = strlower(tostring(v.u)) })
    end
  end

  thestring = JSON.encode({ konfer = {
    date = K.YMDStamp(), time = K.HMStamp(), classes = classes, users = uv, lists = lists,
  } })
end

local function export_list_button(this)
  local selwhat = nil

  thestring = ""
  lists = {}
  uu = {}
  uv = {}

  if (not qf.explistdlg) then
    local ypos = 0
    local arg = {
      x = "CENTER", y = "MIDDLE",
      name = "KonferExportListDialog",
      title = konfer.apol:WindowTitle(L["Export list members"]),
      border = true,
      width = 400,
      height = 175,
      canmove = true,
      canresize = false,
      escclose = true,
      blackbg = true,
      okbutton = true,
      cancelbutton = true,
    }
    local ret = KUI:CreateDialogFrame(arg)

    ret.clistmsg = current_list_box(ret, ypos)
    ypos = ypos - ret.clistmsg:GetHeight() - KUI.WIDGET_GAP

    local items = {
      { text = L["Nothing"], value = 0 },
      { text = L["Export current list as CSV"], value = EXP_CUR_CSV },
      { text = L["Export current list as JSON"], value = EXP_CUR_JSON },
      { text = L["Export all lists as JSON"], value = EXP_ALL_JSON },
    }
    local texts = {}
    for _, it in ipairs(items) do
      tinsert(texts, it.text)
    end

    arg = {
      label = { text = L["Select"], pos = "LEFT" },
      name = "KonferWhatToExport", mode = "SINGLE",
      x = 5, y = ypos, dwidth = KUI:DropDownWidth(texts), items = items, initialvalue = 0, itemheight = 16,
    }
    ret.what = KUI:CreateDropDown(arg, ret)
    ret.what:Catch("OnValueChanged", function(t, evt, newv)
      local pp = konfer.apol
      selwhat = newv
      if (selwhat == EXP_CUR_CSV and qf.current_listid) then
        local tt = {}
        for k,v in ipairs(qf.current_list.users) do
          tinsert(tt, pp.cfg:UserName(v))
        end
        thestring = tconcat(tt, ",")
      elseif (selwhat == EXP_CUR_JSON and qf.current_listid) then
        uu = {}
        uv = {}
        lists = {}
        do_json_list(this, qf.current_listid)
        final_json_string(this)
      elseif (selwhat == EXP_ALL_JSON) then
        uu = {}
        uv = {}
        lists = {}
        for k,v in ipairs(pp.sortedlists) do
          do_json_list(this, v.id)
        end
        final_json_string(this)
      else
        thestring = ""
      end
      local eb = qf.explistdlg.expstr
      eb:SetText(thestring)
      if (thestring ~= "") then
        eb:SetFocus()
        eb:HighlightText()
        eb:SetCursorPosition(0)
      else
        eb:ClearFocus()
      end
    end)
    ypos = ypos - ret.what:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    -- No limit on its length, 0 being none.
    arg = {
      x = 5, y = ypos, len = 0,
      label = { text = L["Export string"], pos = "LEFT" },
    }
    ret.expstr = KUI:CreateEditBox(arg, ret)
    --
    -- Focus is given where a new string is put in, never here: Escape puts the text back through SetText, which lands here,
    -- and taking focus again would stop a second Escape ever reaching the dialog.
    --
    ret.expstr:Catch("OnValueChanged", function(t, evt, newv, user)
      qf.explistdlg.copymsg:SetShown(newv ~= "")
    end)
    ypos = ypos - ret.expstr:GetHeight() - KUI.WIDGET_GAP

    arg = {
      x = 16, y = ypos, width = 300,
      text = L["Press Ctrl+C to copy the export string"],
    }
    ret.copymsg = KUI:CreateStringLabel(arg, ret)
    ypos = ypos - ret.copymsg:GetHeight() - KUI.WIDGET_GAP


    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    ret:Catch("OnHide", function(t, evt)
      qf.mainwin:Show()
    end)

    qf.explistdlg = ret
  end

  qf.explistdlg.what:SetValue(0)
  qf.explistdlg.expstr:SetText("")
  show_current_list(qf.explistdlg.clistmsg)

  qf.mainwin:Hide()
  qf.explistdlg:SetTitleText(konfer.apol:WindowTitle(L["Export list members"]))
  qf.explistdlg:Show()
end

local function announce_list_button(this, isall, shifted)
  local pp = konfer.apol
  local inraid = raid_uids()

  if (not qf.current_list or not qf.sortedmembers or (not shifted and not inraid)) then
    return
  end

  -- Headed in the policy's words (Strings in Policy.lua), which say what the numbers after each name are.
  local nick = L["MODTITLE"]
  local ts = strfmt("%s: %s", nick, strfmt(pp:Str(isall and "ANNOUNCE_ALL" or "ANNOUNCE_RAIDERS"), qf.current_list.name))

  local sendfn = this.SendText

  if (shifted and K.player.is_guilded) then
    sendfn = this.SendGuildText
  end

  local as, al
  local np = 0
  local len = strlen(ts)

  --
  -- Who counts as here is who an award on the list would count: the members in the raid, reserved, or with an alt in the raid
  -- on a tethered list. The list itself is walked rather than the rows on screen, which show alts as rows of their own.
  --
  local present = {}

  if (not isall and inraid) then
    for k, v in ipairs(pp.cfg:CreateRaidList(qf.current_listid)) do
      present[v] = true
    end
  end

  -- In the policy's order, each with the policy's word for where they stand.
  local _, ordered = pp.cfg:PolicyCall("Order", qf.current_list.users, qf.current_listid, qf.current_list.users)

  for i, uid in ipairs(ordered) do
    as = nil
    if (isall) then
      np = np + 1
      as = K.ShortName(pp.cfg:UserNameClass(uid)) .. " "
    elseif (present[uid]) then
      local _, standing = pp.cfg:PolicyCall("PositionText", tostring(i), qf.current_listid, uid, i)

      np = np + 1
      as = strfmt("%s(%s) ", K.ShortName(pp.cfg:UserNameClass(uid)), tostring(standing))
    end
    if (as) then
      al = strlen(as)
      if (len + al > 240) then
        sendfn(this, ts)
        ts = strfmt("%s: ", nick)
        len = strlen(ts)
      end
      ts = ts .. as
      len = len + al
    end
  end
  if (np > 0) then
    sendfn(this, ts)
  end
end

function konfer:InitialiseListsUI()
  local arg
  local mainwin = self.mainwin
  local kmt = mainwin:GetPage(self.LISTS_PAGE)

  qf.mainwin = mainwin

  --
  -- The Config tab's unsaved changes, to the selected list's options, the policy's own among them as "p." and the option's
  -- name. Saving writes the list and tells the other admins with one CHLST carrying every option, the policy's whole block
  -- included, however many were changed. It exists from the moment the page does, because a widget handler writes into it
  -- and a widget can be set before any list has been selected.
  --
  qf.linfo = {}
  qf.listpending = self.mainwin:NewPending({
    page = self.LISTS_PAGE, tab = self.LISTS_CONFIG_TAB,
    saved = list_saved,
    save = function(changes)
      local pp = konfer.apol
      local listid = qf.listpending.picked
      local cl = listid and pp and pp.cfg and pp.cfg.lists[listid]

      if (not cl) then
        return
      end

      local function now(key)
        if (changes[key] ~= nil) then
          return changes[key]
        end

        return list_saved(key)
      end

      for _, f in ipairs(LIST_FIELDS) do
        cl[f] = now(f)
      end

      local block = K.CopyTable(pp.cfg:ListOptions(listid, pp.handle), {})

      for key, val in pairs(changes) do
        local pk = key:match("^p%.(.+)$")

        if (pk) then
          block[pk] = val
        end
      end

      pp.cfg:SetListOptions(listid, pp.handle, block)

      -- The order of these is the event's, and ehandlers.CHLST in Comms.lua reads them in it.
      pp.cfg:AdminEvent("CHLST", listid, now("sortorder"), now("def_rank"), now("strictcfilter"), now("strictrfilter"),
        now("extralist"), now("tethered"), now("altdisp"), pp.cfg:ListOptions(listid, pp.handle))
      pp.cfg:FixupLists()
      konfer:RefreshAllLists(false)
      konfer:RefreshListsUI(false)
    end,
    reload = function()
      konfer:RefreshAllLists(false)
    end,
  })

  kmt.onclick = function(this, main, sub)
    local pp = konfer.apol
    local admin = self:PolicyAdmin(pp) and true or false
    local en = main == self.LISTS_PAGE and sub == self.LISTS_MEMBERS_TAB and admin

    --
    -- Member admin and the policy's panel act on the selected member, which is chosen on the Members tab. On any other tab
    -- they stay where they are, disabled, their titles dimming with them. Their contents are for admins only.
    --
    qf.offmembers = sub ~= self.LISTS_MEMBERS_TAB
    qf.memberctl:SetShown(admin)
    if (pp.listsframe) then
      pp.listsframe:SetShown(admin)
    end
    qf.insert:SetEnabled(not qf.offmembers and qf.current_listid ~= nil)

    local sel = qf.memberlist and qf.memberlist:GetSelected()
    mlist_selectitem(qf.memberlist, sel, nil, nil, sel ~= nil)

    qf.findmember:SetShown(en)

    -- Announcing is about the list, not its members, so it stays whichever tab is up. It is still for admins only.
    qf.listctl:SetShown(self:PolicyAdmin(pp) and true or false)
    sync_panels()
  end

  -- First set up the quick access frames we will be using.
  qf.members = kmt.tabsbyname[self.LISTS_MEMBERS_TAB].content
  qf.cfgopts = kmt.tabsbyname[self.LISTS_CONFIG_TAB].content

  local cf = kmt.content
  local ls = cf.vsplit.leftframe
  local rs = cf.vsplit.rightframe

  --
  -- The left-hand side panel remains invariant regardless of which top tab is selected. It contains the list of lists, and
  -- the buttons for the member selected in the right panel, if any. To make better use of the screen space since there are
  -- likely to be many users but few lists, the right hand column now just contains the members and we split the left side
  -- horizontally and have the member control buttons there instead of along the right side of the member scroll list. So
  -- that it doesn't cause any confusion when the config tab is selected at the top, this left middle panel with the member
  -- control buttons is hidden when the list config screen is active, and shown when the actual members list is active.
  --
  -- The Lists panel is four rows, the same size and in the same place as the one on the Loot page, so that flipping between
  -- the two does not make it jump. Under it Member admin, Announce and the policy's own panel are each exactly the size of
  -- what they hold, one under another, and what is left below them is empty and unbordered.
  --
  -- How tall the policy's own panel is, the policy says, because only it knows what goes there. A policy without a
  -- ListsPage gets no panel at all.
  --
  local LISTS_H = 4 * 16 + 4
  local MEMBERADMIN_H = 52  -- two 24 high buttons and the gap between them
  local ANNOUNCE_H = 52     -- the same

  KUI:UseAsContainer(ls)

  local lspanel = KUI:CreateInset({ title = L["Lists"] }, ls)
  lspanel:ClearAllPoints()
  lspanel:SetPoint("TOPLEFT", ls, "TOPLEFT", 0, 0)
  lspanel:SetPoint("TOPRIGHT", ls, "TOPRIGHT", 0, 0)
  lspanel:SetHeight(LISTS_H + lspanel.rings.top + lspanel.rings.bottom)

  local lower = MakeFrame("Frame", nil, ls)
  lower:ClearAllPoints()
  lower:SetPoint("TOPLEFT", lspanel, "BOTTOMLEFT", 0, 0)
  lower:SetPoint("TOPRIGHT", lspanel, "BOTTOMRIGHT", 0, 0)
  lower:SetPoint("BOTTOM", ls, "BOTTOM", 0, 0)

  arg = {
    inset = 0, height = MEMBERADMIN_H, topanchor = true,
    name = "KonferListsMemberAdminSplit",
    toptitle = L["Member admin"],
    bottomborder = false, bottompadding = 0,
  }
  lower.hsplit = KUI:CreateHSplit(arg, lower)

  local blt = lower.hsplit.topframe
  local lower2 = lower.hsplit.bottomframe

  arg = {
    inset = 0, height = ANNOUNCE_H, topanchor = true,
    name = "KonferListsAnnounceSplit",
    toptitle = L["Announce"],
    bottomborder = false, bottompadding = 0,
  }
  lower2.hsplit = KUI:CreateHSplit(arg, lower2)

  local tlt = lspanel.content
  local bl = lower2.hsplit.topframe
  local lower3 = lower2.hsplit.bottomframe

  qf.listctl = bl
  qf.memberpanel = lower.hsplit.topinset
  qf.announcepanel = lower2.hsplit.topinset

  --
  -- The slot the active policy's own panel goes in -- see ListsPage in Policy.lua. Suicide Kings orders a list by position
  -- and puts its buttons for that here; another system may not, and what the panel is called is its business.
  --
  -- The split is the page's and is built once. What goes in it is a frame per policy, made by konfer:BuildListsPolicyUI, of
  -- which exactly one is ever shown. It starts hidden and one pixel tall because how tall it should be, and what it should
  -- be called, are both the policy's and there is no policy yet. A policy with no ListsPage leaves it hidden and the empty
  -- space under it, which is what grows when the window does, takes the room back.
  --
  arg = {
    inset = 0, height = 1, topanchor = true,
    name = "KonferListsPolicySplit",
    toptitle = "",
    bottomborder = false,
  }
  lower3.hsplit = KUI:CreateHSplit(arg, lower3)
  qf.policysplit = lower3.hsplit
  qf.policypanel = lower3.hsplit.topinset
  qf.policyslot = lower3.hsplit.topframe
  lower3.hsplit:Hide()

  local ypos = 0
  arg = {
    x = "CENTER", y = ypos, width = 165, height = 24, text = L["Announce"],
    tooltip = { title = "$$", text = L["TIP029"], },
  }
  bl.announcebutton = KUI:CreateButton(arg, bl)
  bl.announcebutton:Catch("OnClick", function(this, evt)
    announce_list_button(self, false, IsShiftKeyDown())
  end)
  ypos = ypos - bl.announcebutton:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = "CENTER", y = ypos, width = 165, height = 24, text = L["Announce all"],
    tooltip = { title = "$$", text = L["TIP094"], },
  }
  bl.announceallbutton = KUI:CreateButton(arg, bl)
  bl.announceallbutton:Catch("OnClick", function(this, evt)
    announce_list_button(self, true, IsShiftKeyDown())
  end)
  ypos = ypos - bl.announceallbutton:GetHeight() - KUI.WIDGET_GAP

  cf.cframe = MakeFrame("Frame", nil, blt)
  cf.cframe:ClearAllPoints()
  cf.cframe:SetPoint("TOPLEFT", blt, "TOPLEFT", 0, 0)
  cf.cframe:SetPoint("BOTTOMRIGHT", blt, "BOTTOMRIGHT", 0, 0)
  qf.memberctl = cf.cframe

  local mcf = cf.cframe

  ypos = 0
  arg = { x = 0, y = ypos, width = 98, height = 24,
    text = L["Insert"],
    tooltip = { title = "$$", text = L["TIP030"], },
  }
  mcf.insertbutton = KUI:CreateButton(arg, mcf)
  mcf.insertbutton:Catch("OnClick", function(this, evt)
    insert_member(self, this)
  end)
  qf.insert = mcf.insertbutton

  arg.x = 100
  arg.text = L["Delete"]
  arg.tooltip = { title = "$$", text = L["TIP031"], }
  mcf.deletebutton = KUI:CreateButton(arg, mcf)
  mcf.deletebutton:Catch("OnClick", function(this, evt)
    delete_member(self)
  end)
  qf.delete = mcf.deletebutton

  -- On a row of its own, centred under the two above it.
  ypos = ypos - mcf.deletebutton:GetHeight() - KUI.WIDGET_GAP
  arg.x = "CENTER"
  arg.y = ypos
  arg.text = L["Reserve"]
  arg.tooltip = { title = "$$", text = L["TIP036"], }
  mcf.reservebutton = KUI:CreateButton(arg, mcf)
  mcf.reservebutton:Catch("OnClick", function(this, evt)
    resunres_member(self, this)
  end)
  qf.resunres = mcf.reservebutton

  -- Now for the actual scroll list of roll lists in the left top frame.
  local function rlist_och(this)
    local idx = this:GetID()
    if (qf.memberlist) then
      qf.memberlist:UpdateList(0)
    end
    this:GetParent():GetParent():SetSelected(idx, false, true)
    return true
  end

  arg = {
    name = "KonferRollListScrollList",
    itemheight = 16,
    newitem = function(objp, num)
      return KUI.NewItemHelper(objp, num, "KonferRListButton", 170, 16, nil, rlist_och, nil, nil)
      end,
    setitem = function(objp, idx, slot, btn)
      return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
          local pp = konfer.apol
          return pp.cfg.lists[pp.sortedlists[ix].id].name
        end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return rlist_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  tlt.slist = KUI:CreateScrollList(arg, tlt)
  qf.lists = tlt.slist

  --
  -- Lists panel, Members tab
  --
  -- The right hand column is only a container, and each tab puts its own panels in it. This one's is the member list, on the
  -- page's own ground with no rim, title or ground of its own round it, its columns headed instead (mlist_columns).
  --
  local mpanel = KUI:CreateInset({ inset_art = false }, qf.members)
  mpanel:ClearAllPoints()
  mpanel:SetPoint("TOPLEFT", qf.members, "TOPLEFT", 0, 0)
  mpanel:SetPoint("BOTTOMRIGHT", qf.members, "BOTTOMRIGHT", 0, 0)
  qf.memberspanel = mpanel

  local cf = mpanel.content

  --
  -- We need to create a frame anchored to the left side of the split, that will contain the scrolling list of users. The
  -- buttons appear to the right of the list. The scrolling list code requires a complete frame to take over so we create that first.
  --
  cf.sframe = MakeFrame("Frame", nil, cf)
  cf.sframe:ClearAllPoints()
  cf.sframe:SetPoint("TOPLEFT", cf, "TOPLEFT", 0, 0)
  cf.sframe:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 0, 25)

  arg = {
    x = 0, y = 2, len = 16, font = "ChatFontSmall",
    width = 190, tooltip = { title = L["User search"], text = L["TIP099"] },
  }
  cf.searchbox = KUI:CreateEditBox(arg, cf)
  cf.searchbox:ClearAllPoints()
  cf.searchbox:SetPoint("BOTTOM", cf, "BOTTOM", 0, 0)
  cf.searchbox:SetWidth(225)
  cf.searchbox:SetHeight(20)
  qf.findmember = cf.searchbox
  cf.searchbox:Catch("OnEnterPressed", function(this, evt, newv, user)
    this:SetText("")
  end)
  cf.searchbox:Catch("OnValueChanged", function(this, evt, newv, user)
    local pp = konfer.apol
    if (not qf.sortedmembers) then
      return
    end
    if (user and newv and newv ~= "") then
      local lnv = strlower(newv)
      for k,v in pairs(qf.sortedmembers) do
        local tln = strlower(pp.cfg:UserName(v.id) or "")
        if (strfind(tln, lnv, 1, true)) then
          local its = v.id
          if (v.isalt) then
            its = v.main
          end
          for kk,vv in ipairs(qf.sortedmembers) do
            if (vv.id == its) then
              qf.memberlist:SetSelected(kk, true)
              break
            end
          end
          return
        end
      end
    end
  end)

  arg = {
    name = "KonferMembersList",
    itemheight = 16,
    columns = mlist_columns(),
    newrow = mlist_newrow,
    setitem = mlist_setitem,
    selectitem = mlist_selectitem,
  }
  cf.slist = KUI:CreateColumnList(arg, cf.sframe)
  qf.memberlist = cf.slist

  --
  -- Lists panel, Config tab
  --
  -- List Admin across the top holds the buttons that make, remove and move whole lists, and is exactly their size. List
  -- Configuration under it holds the selected list's own options and takes whatever the window grows by.
  --
  local cf = qf.cfgopts
  local LISTADMIN_H = 80  -- three rows of 24 high buttons and the gaps between them

  arg = {
    inset = 0, height = LISTADMIN_H, topanchor = true,
    name = "KonferListCfgRSplit",
    toptitle = L["List Admin"],
    bottomborder = false, bottompadding = 0,
  }
  cf.hsplit = KUI:CreateHSplit(arg, cf)
  local admin = cf.hsplit.topframe
  local cfglower = cf.hsplit.bottomframe

  --
  -- Under List Admin, List Configuration holds the options every policy's lists have and is exactly their size. Under that
  -- is the slot for the active policy's own options, titled with its name -- see ConfigConstruct under ListsPage in
  -- Policy.lua -- and exactly the size of what the policy built there. What is left below them is empty and unbordered and
  -- is what grows when the window does.
  --
  -- Every policy gets that panel and it is always titled, because a panel named after the policy with nothing in it yet says
  -- what it is, where an untitled one says nothing at all. A policy with nothing to put there gets POLICYCFG_MIN, its
  -- contents being no height whatsoever.
  --
  -- How tall List Configuration is depends on what goes in it, so it is made with no height here and given one once its options have been built.
  --
  arg = {
    inset = 0, height = 0, topanchor = true,
    name = "KonferListCfgOptsSplit",
    toptitle = L["List Configuration"],
    bottomborder = false, bottompadding = 0,
  }
  cfglower.hsplit = KUI:CreateHSplit(arg, cfglower)
  local opts = cfglower.hsplit.topframe
  local cfglower2 = cfglower.hsplit.bottomframe
  qf.listconfpanel = cfglower.hsplit.topinset

  --
  -- The policy's panel and, under it, the empty space. It is given a title here rather than left without one, because a
  -- plate is made only for a title that exists at all, and this one's words are not known until there is an active policy.
  -- ShowListsPolicyUI puts the name in it, and does so before the window is ever shown.
  --
  arg = {
    inset = 0, height = POLICYCFG_MIN, topanchor = true,
    name = "KonferListCfgPolicySplit",
    toptitle = "",
    bottomborder = false,
  }
  cfglower2.hsplit = KUI:CreateHSplit(arg, cfglower2)
  qf.policycfgsplit = cfglower2.hsplit
  qf.policycfgslot = cfglower2.hsplit.topframe
  qf.policycfgpanel = cfglower2.hsplit.topinset

  --
  -- What the panel says instead, for a policy with no options of its own to put in it. It is the panel describing itself
  -- rather than anything the user can act on, so it is drawn as the panel's own title is, in the same font and the same gold.
  --
  -- The whole panel wide, less the gap every widget in one keeps from its sides. Sized to the panel rather than to the
  -- words, because the words are translated and the German and the French are half as long again as the English.
  --
  -- Lifted by KUI:PanelMiddle, because a title takes its room out of the top of a panel and nothing out of the bottom, so
  -- the middle of the content frame is not the middle of the panel as you see it.
  --
  local lift = KUI:PanelMiddle(qf.policycfgslot)

  qf.policycfgnone = KUI:CreateStringLabel({
    x = 0, y = 0, text = L["POLICY_NO_LISTCONFIG"], autosize = false,
    justifyh = "CENTER", justifyv = "MIDDLE", font = "GameFontNormal", color = KUI.DEFAULT_ARTWORK_COLOR,
  }, qf.policycfgslot)
  qf.policycfgnone:ClearAllPoints()
  qf.policycfgnone:SetPoint("TOPLEFT", qf.policycfgslot, "TOPLEFT", KUI.WIDGET_GAP, lift)
  qf.policycfgnone:SetPoint("BOTTOMRIGHT", qf.policycfgslot, "BOTTOMRIGHT", 0 - KUI.WIDGET_GAP, lift)
  qf.policycfgnone:Hide()

  qf.listconf = opts
  qf.listcfgbuttons = admin

  --
  -- Where the list stands among the others, two digits typed in. An emptied box, or a 0, is 1, the first place there is,
  -- lists being sorted by comparing it.
  --
  ypos = 0
  arg = {
    x = 0, y = ypos, numeric = true, len = 2, charwidth = 2, label = { text = L["Sort order"], pos = "LEFT" },
    tooltip = { title = "$$", text = L["TIP037"] },
  }
  opts.sortorder = KUI:CreateEditBox(arg, opts)
  opts.sortorder:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user) then
      qf.linfo.sortorder = max(tonumber(newv) or 1, 1)
      changed()
    end
  end)
  ypos = ypos - opts.sortorder:GetHeight() - KUI.WIDGET_GAP

  --
  -- The guild rank a roll on this list starts out filtered to, stored on the list like the options round it and edited in
  -- the list's edit buffer so that Update writes it with the rest. It is offered only where the config says to filter by
  -- guild rank at all and this character has a guild to be ranked in, which is what cfg:RankFiltering asks.
  --
  arg = {
    x = 0, y = ypos, name = "KonferListDefRankDropdown", itemheight = 16,
    dwidth = 175, items = KUI.emptydropdown, mode = "SINGLE", enabled = false,
    label = { text = L["Initial guild rank filter"] },
    tooltip = { title = "$$", text = strfmt(L["TIP038"], K.NONE_STR) },
  }
  opts.defrank = KUI:CreateDropDown(arg, opts)
  -- Published because the guild rank list is refilled from Konfer.lua.
  konfer.qf.listrank = opts.defrank
  opts.defrank:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.linfo) then
      qf.linfo.def_rank = tonumber(newv)
      changed()
    end
  end)
  ypos = ypos - opts.defrank:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Strict class armor filtering"] },
    tooltip = { title = "$$", text = L["TIP039"] },
  }
  opts.cfilter = KUI:CreateCheckBox(arg, opts)
  opts.cfilter:Catch("OnValueChanged", function(this, evt, val, user)
    if (user) then
      qf.linfo.strictcfilter = val
      changed()
    end
  end)
  ypos = ypos - opts.cfilter:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Strict role filtering"] },
    tooltip = { title = "$$", text = L["TIP040"] },
  }
  opts.rfilter = KUI:CreateCheckBox(arg, opts)
  opts.rfilter:Catch("OnValueChanged", function(this, evt, val, user)
    if (user) then
      qf.linfo.strictrfilter = val
      changed()
    end
  end)
  ypos = ypos - opts.rfilter:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Alts tethered to mains"] },
    tooltip = { title = "$$", text = L["TIP024"] },
  }
  opts.tethered = KUI:CreateCheckBox(arg, opts)
  -- Alts can be shown under their mains only while they are tethered to them.
  opts.tethered:Catch("OnValueChanged", function(this, evt, val, user)
    if (not user) then
      return
    end

    if (not val) then
      qf.linfo.altdisp = false
    end

    qf.linfo.tethered = val
    qf.altdisp:SetEnabled(val)
    qf.altdisp:SetChecked(qf.linfo.altdisp, true)
    changed()
  end)
  ypos = ypos - opts.tethered:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Display alts in member list"] },
    tooltip = { title = "$$", text = L["TIP101"] },
  }
  opts.altdisp = KUI:CreateCheckBox(arg, opts)
  qf.altdisp = opts.altdisp
  opts.altdisp:Catch("OnValueChanged", function(this, evt, val, user)
    if (user) then
      qf.linfo.altdisp = val
      changed()
    end
  end)
  ypos = ypos - opts.altdisp:GetHeight() - KUI.WIDGET_GAP

  --
  -- The list an award on this one also lands on, which is how a guild runs a list for tier tokens and still charges the main
  -- list. What that award does is the policy's, so the label is the policy's word for it, put there by show_list, and the
  -- choice is refilled there too, the lists coming and going.
  --
  arg = {
    x = 0, y = ypos, name = "KonferListExtraListDropdown", itemheight = 16,
    dwidth = 175, items = KUI.emptydropdown, mode = "SINGLE", enabled = false,
    label = { text = L["POLICY_AWARD_EXTRALIST"] },
    tooltip = { title = "$$", text = L["TIP041"] },
  }
  opts.extralist = KUI:CreateDropDown(arg, opts)
  opts.extralist:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.linfo) then
      qf.linfo.extralist = newv
      changed()
    end
  end)
  ypos = ypos - opts.extralist:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  --
  -- List Configuration is the options above and no more: what they used, less the gap left after the last of them, plus the rings round the panel.
  --
  local lcp = cfglower.hsplit.topinset
  lcp:SetHeight(0 - ypos - KUI.WIDGET_GAP + lcp.rings.top + lcp.rings.bottom)

  -- Which widget shows which field, for the changed colour. The policy's own options say so for themselves.
  qf.listpending:Watch(opts.sortorder, "sortorder")
  qf.listpending:Watch(opts.defrank, "def_rank")
  qf.listpending:Watch(opts.cfilter, "strictcfilter")
  qf.listpending:Watch(opts.rfilter, "strictrfilter")
  qf.listpending:Watch(opts.tethered, "tethered")
  qf.listpending:Watch(opts.altdisp, "altdisp")
  qf.listpending:Watch(opts.extralist, "extralist")

  --
  -- The List Admin buttons. The two rows of three are one frame, centred at the top of the panel, with the standard gap
  -- between its buttons both ways, and Add missing is centred a gap under it.
  --
  local ADMIN_W, ADMIN_H = 90, 24
  local ADMIN_COL = ADMIN_W + KUI.WIDGET_GAP
  local ADMIN_ROW = 0 - ADMIN_H - KUI.WIDGET_GAP

  admin.grid = MakeFrame("Frame", nil, admin)
  admin.grid:SetWidth(3 * ADMIN_W + 2 * KUI.WIDGET_GAP)
  admin.grid:SetHeight(2 * ADMIN_H + KUI.WIDGET_GAP)
  admin.grid:SetPoint("TOP", admin, "TOP", 0, 0)

  ypos = 0
  arg = {
    x = 0, y = 0, width = ADMIN_W, height = ADMIN_H, text = L["Create"],
    tooltip = { title = "$$", text = L["TIP043"] },
  }
  admin.createbutton = KUI:CreateButton(arg, admin.grid)
  admin.createbutton:Catch("OnClick", function(this, evt)
    create_list_button(self)
  end)

  arg = {
    x = ADMIN_COL, y = 0, width = ADMIN_W, height = ADMIN_H, text = L["Delete"],
    tooltip = { title = "$$", text = L["TIP044"] },
  }
  admin.deletebutton = KUI:CreateButton(arg, admin.grid)
  admin.deletebutton:Catch("OnClick", function(this, evt)
    delete_list_button(self, qf.current_listid)
  end)

  arg = {
    x = 2 * ADMIN_COL, y = 0, width = ADMIN_W, height = ADMIN_H, text = L["Rename"],
    tooltip = { title = "$$", text = L["TIP045"] },
  }
  admin.renamebutton = KUI:CreateButton(arg, admin.grid)
  admin.renamebutton:Catch("OnClick", function(this, evt)
    rename_list_button(self, qf.current_listid)
  end)

  arg = {
    x = 0, y = ADMIN_ROW, width = ADMIN_W, height = ADMIN_H, text = L["Copy"],
    tooltip = { title = "$$", text = L["TIP046"] },
  }
  admin.copybutton = KUI:CreateButton(arg, admin.grid)
  admin.copybutton:Catch("OnClick", function(this, evt)
    copy_list_button(self, qf.current_listid)
  end)

  arg = {
    x = ADMIN_COL, y = ADMIN_ROW, width = ADMIN_W, height = ADMIN_H, text = L["Import"],
    tooltip = { title = "$$", text = L["TIP047"] },
  }
  admin.importbutton = KUI:CreateButton(arg, admin.grid)
  admin.importbutton:Catch("OnClick", function(this, evt)
    local pp = konfer.apol

    if (pp.ImportList and qf.current_listid) then
      pp.cfg:PolicyCall("ImportList", nil, qf.current_listid)
    end
  end)

  arg = {
    x = 2 * ADMIN_COL, y = ADMIN_ROW, width = ADMIN_W, height = ADMIN_H, text = L["Export"],
    tooltip = { title = "$$", text = L["TIP048"] },
  }
  admin.exportbutton = KUI:CreateButton(arg, admin.grid)
  admin.exportbutton:Catch("OnClick", function(this, evt)
    export_list_button(self)
  end)
  ypos = 0 - admin.grid:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = "CENTER", y = ypos, width = 120, height = ADMIN_H, text = L["Add missing"],
    tooltip = { title = "$$", text = L["TIP049"] },
  }
  admin.addmissingbutton = KUI:CreateButton(arg, admin)
  admin.addmissingbutton:Catch("OnClick", function(this, evt)
    local pp = konfer.apol

    if (pp.AddMissing and qf.current_listid) then
      pp.cfg:PolicyCall("AddMissing", nil, qf.current_listid)
    end
  end)

end

--
-- A POLICY'S OWN TABS
--
-- The Lists page's tabs of the active policy's own (ListsTabs in Policy.lua), after Members and Config while it is the
-- active one and taken away when it stops being, as the Config page's are. Each is named with the policy's prefix, and a tab
-- taken away is retired rather than destroyed, so adding it again brings back what was built. Nothing on one is held for
-- saving, so each runs down into the save bar's room.
--
local function lists_tab(pp, i, t)
  return {
    name = pp.prefix .. t.name, text = t.text, order = t.order or (10 + i), savebar = false, adminonly = t.adminonly,
    owneronly = t.owneronly, wholepage = t.wholepage,
  }
end

local function show_lists_tabs(self, pp, onoff)
  for i, t in ipairs(pp.ListsTabs or {}) do
    if (onoff) then
      self.mainwin:AddTab(self.LISTS_PAGE, lists_tab(pp, i, t))
    else
      self.mainwin:RemoveTab(self.LISTS_PAGE, pp.prefix .. t.name)
    end
  end
end

--
-- Build PP's tabs, once each, and take them away again until PP is the active policy.
--
local function build_lists_tabs(self, pp)
  local kmt = self.mainwin:GetPage(self.LISTS_PAGE)

  pp.liststabs = {}

  for i, t in ipairs(pp.ListsTabs or {}) do
    local tab = lists_tab(pp, i, t)

    self.mainwin:AddTab(self.LISTS_PAGE, tab)

    local rec = { def = t, client = kmt.tabsbyname[tab.name].content }

    pp.liststabs[t.name] = rec
    konfer:PolicyHook(pp, "ListsTabs.Construct", nil, t.Construct, rec.client)
  end

  show_lists_tabs(self, pp, false)
end

--
-- Build PP's own panels on this page, into the two slots the page keeps for them, and its own tabs. Once per policy, from
-- konfer:BuildPolicyUI, which is also what makes sure the page itself already exists: a policy reaching out of its Construct
-- for something the page built finds it there.
--
-- Both frames start hidden. Only the active policy's are shown, and a policy becomes the active one only after this has run for it.
--
function konfer:BuildListsPolicyUI(pp)
  local lp = pp.ListsPage

  build_lists_tabs(self, pp)

  if (not lp) then
    return
  end

  --
  -- Sized before the policy fills it, so that anything it builds against the bottom of the frame it is handed lands where it will finally sit.
  --
  if (lp.Construct) then
    qf.policysplit:SetSplitSize(lp.height)

    pp.listsframe = MakeFrame("Frame", nil, qf.policyslot)
    pp.listsframe:ClearAllPoints()
    pp.listsframe:SetPoint("TOPLEFT", qf.policyslot, "TOPLEFT", 0, 0)
    pp.listsframe:SetPoint("BOTTOMRIGHT", qf.policyslot, "BOTTOMRIGHT", 0, 0)
    pp.listsframe:Hide()

    konfer:PolicyHook(pp, "ListsPage.Construct", nil, lp.Construct, pp.listsframe)
  end

  -- The policy's options on the Config tab, held in konfer:ListsPending() as "p." and the option's name.
  if (lp.ConfigConstruct) then
    pp.listscfgframe = MakeFrame("Frame", nil, qf.policycfgslot)
    pp.listscfgframe:ClearAllPoints()
    pp.listscfgframe:SetPoint("TOPLEFT", qf.policycfgslot, "TOPLEFT", 0, 0)
    pp.listscfgframe:SetPoint("BOTTOMRIGHT", qf.policycfgslot, "BOTTOMRIGHT", 0, 0)
    pp.listscfgframe:Hide()

    --
    -- What the policy answers is how tall what it built is, which is what the panel is made to hold exactly. A policy that
    -- answers nothing gets the minimum, as one that builds nothing at all does.
    --
    local _, h = konfer:PolicyHook(pp, "ListsPage.ConfigConstruct", nil, lp.ConfigConstruct, pp.listscfgframe)

    pp.listscfgheight = h
  end
end

--
-- Show or hide PP's panels on this page.
--
-- The panel on the Members tab is as tall as this policy says and wears the title the policy gave it, and is hidden
-- altogether for a policy with nothing to put in it, the empty space below taking the room back. That panel is for acting on
-- a list or a member, and a policy that does neither should not be offered somewhere to do it.
--
-- The panel on the Config tab is always there and is always named after the policy, because it is where that policy's
-- options live and saying so is worth a line even while there are none yet. It is the height of what the policy built, or
-- POLICYCFG_MIN when that is nothing.
--
function konfer:ShowListsPolicyUI(pp, onoff)
  local lp = pp.ListsPage

  show_lists_tabs(self, pp, onoff)

  if (pp.listsframe) then
    pp.listsframe:SetShown(onoff and true or false)
  end

  if (pp.listscfgframe) then
    pp.listscfgframe:SetShown(onoff and true or false)
  end

  if (not onoff) then
    return
  end

  if (lp and lp.Construct) then
    qf.policysplit:SetSplitSize(lp.height)
    qf.policypanel:SetTitleText(lp.title or pp.name)
    qf.policysplit:Show()
  else
    qf.policysplit:Hide()
  end

  local hascfg = (lp and lp.ConfigConstruct) and true or false
  local h = pp.listscfgheight or 0

  qf.policycfgsplit:SetSplitSize((h > POLICYCFG_MIN) and h or POLICYCFG_MIN)
  qf.policycfgpanel:SetTitleText(pp.name)
  qf.policycfgnone:SetShown(not hascfg)
end

--
-- Put the roll lists back on the page, with OLDIDX selected again if it still exists.
--
local function refresh_lists_widgets(self, pp, oldidx)
  qf.lists.itemcount = #pp.sortedlists
  qf.lists:UpdateList()

  --
  -- This has side-effects. Since we force the setting, it will always run the selection callback (rlist_selectitem). This
  -- will set qf.current_listid and qf.current_list. It also calls refresh_member_list() so we don't need to call that explicitly ourselves.
  --
  qf.lists:SetSelected(oldidx, true, true)

  --
  -- The lists themselves may have changed as well as which is selected, and the policy's options on the Config tab can offer a choice of them.
  --
  config_list_selection()
end

--
-- This config's roll lists as { { id }, ... } in the order they are shown in everywhere: by the sort order the lists carry,
-- then by name.
--
function cfgm:SortedLists()
  local lists = self.lists
  local sorted = {}

  for k,v in pairs(lists) do
    tinsert(sorted, { id = k })
  end

  tsort(sorted, function(a,b)
    if (lists[a.id].sortorder ~= lists[b.id].sortorder) then
      return lists[a.id].sortorder < lists[b.id].sortorder
    end
    return strlower(lists[a.id].name) < strlower(lists[b.id].name)
  end)

  return sorted
end

local function sort_policy_lists(pp)
  pp.sortedlists = pp.cfg:SortedLists()
end

--
-- The choice of this config's roll lists a dropdown offers, None first. The config, loot and users pages each offer that
-- choice and all three are filled from here, as is the Admin tab, which shows some config other than the one the window
-- has in hand. It only offers: a setting naming a list that has gone is put right where the list goes, in DeleteList, and
-- a list order being redrawn is no reason to change one.
--
function cfgm:ListChoices()
  local llist = { { text = K.NONE_STR, value = "0" } }

  for k, v in ipairs(self:SortedLists()) do
    tinsert(llist, { text = self.lists[v.id].name, value = v.id })
  end

  return llist
end

--
-- The Lists page's Config tab's unsaved changes, for a policy's own list options. See ListsPage.ConfigConstruct in Policy.lua.
--
function konfer:ListsPending()
  return qf.listpending
end

function konfer:RefreshAllLists(reset)
  local pp = self.apol

  if (qf.lists and pp and pp.cfg) then
    local oldlist = qf.current_listid
    local oldidx = nil

    qf.current_listid = nil
    sort_policy_lists(pp)

    for kk,v in ipairs(pp.sortedlists) do
      if (v.id == oldlist) then
        oldidx = kk
        break
      end
    end

    -- With no list selected, or the one that was gone, the config's default list (def_list) is selected where it has one.
    if (not oldidx) then
      for kk, v in ipairs(pp.sortedlists) do
        if (v.id == pp.cfg.settings.def_list) then
          oldidx = kk
          break
        end
      end
    end

    --
    -- The Config tab's unsaved changes are held across the rebuild, which deselects the list and selects it again (see
    -- PS.Hold). Let go, what another admin has since replaced is gone, and what is left is put back on screen.
    --
    qf.listpending:Hold()
    refresh_lists_widgets(self, pp, oldidx)
    qf.listpending:Release()

    if (qf.current_listid) then
      show_list()
      config_list_selection()
    end
  end

  -- Update any lists in the config UI.
  self:RefreshConfigLists(reset)

  -- Update any lists in the loot / items UI.
  self:RefreshLootLists()

  -- Update any lists in the users UI.
  self:RefreshUsersLists()
end

function konfer:RefreshListsUIForRaid(inraid)
  local pp = self.apol

  if (qf.listctl and pp and pp.currentid) then
    local en = true

    if (not qf.current_listid or not self:PolicyAdmin(pp) or not inraid or not raid_uids()) then
      en = false
    end
    qf.listctl.announcebutton:SetEnabled(en)

    en = true
    if (qf.lists.itemcount < 1 or not self:PolicyAdmin(pp) or not inraid) then
      en = false
    end
    qf.listctl.announceallbutton:SetEnabled(en)

    en = (qf.current_listid and self:PolicyAdmin(pp) and pp.AddMissing and inraid) and true or false
    qf.listcfgbuttons.addmissingbutton:SetEnabled(en)
    sync_panels()
  end
end

function konfer:RefreshListsUI(reset)
  local pp = self.apol

  --
  -- The page is emptied rather than filled while there is no config to show, which is a policy with none selected, or no active policy at all.
  --
  if (qf.lists) then
    if (not pp or not pp.currentid) then
      if (pp) then
        pp.sortedlists = nil
      end

      qf.current_listid = nil
      qf.current_list = nil
      qf.sortedmembers = nil
      qf.current_memberid = nil

      qf.lists.itemcount = 0
      qf.lists:UpdateList()
      qf.lists:SetSelected(nil, false, true)
      qf.memberlist:UpdateList(0)
      qf.memberlist:SetSelected(nil, false, true)
    elseif (reset) then
      qf.current_listid = nil
    end
  end

  self:RefreshAllLists(reset)
  self:RefreshListsUIForRaid(self.raid.uidmap ~= nil)
  self:RefreshAllMemberLists()
end

function cfgm:FindList(name)
  local lowname = strlower(name)

  for k,v in pairs(self.lists) do
    if (strlower(v.name) == lowname) then
      return k
    end
  end
  return nil
end

--
-- REPRODUCED says NAME is one already in use, being copied rather than invented, and so is not held to the minimum length.
-- Copying a config remakes each of its lists here, and a list named before there was a minimum, or by an admin running a
-- build without one, must still come across or the copy is not a copy.
--
function cfgm:CreateNewList(name, myid, nocmd, reproduced)
  local pol = self:GetPolicy()

  -- A list has to be called something long enough to be told from a history code. Anything else goes, a name travelling
  -- inside a message's payload. A list another admin made is taken under the name they gave it, however short.
  if (not nocmd and not reproduced and konfer:NameTooShort(pol, name)) then
    return true
  end

  -- A list id we hold already, arriving again, is that list, and making it again would empty it and count it twice.
  if (myid and self.lists[myid]) then
    return false, myid
  end

  --
  -- Names are kept unique where a list is made here. One another admin made and sent us, with its id, is made whatever else
  -- is called that, so that later events for the id still find it.
  --
  local cid = self:FindList(name)
  if (cid and not (myid and nocmd)) then
    if (not nocmd) then
      pol:err(L["roll list %q already exists. Try again."], white(name))
    end
    return true
  end

  local newkey = myid or KC.CreateNewID()
  self.lists[newkey] = {}
  local rl = self.lists[newkey]

  rl.name = name
  rl.sortorder = 1
  rl.def_rank = 0
  rl.strictcfilter = false
  rl.strictrfilter = false
  rl.extralist = "0"
  rl.tethered = true
  rl.altdisp = false
  rl.users = {}

  self.nlists = self.nlists + 1

  if (not myid and not nocmd) then
    pol:info(L["roll list %q created."], white(name))
  end

  if (not nocmd) then
    self:AddEvent("MKLST", newkey, name)
  end

  if (self:IsActive()) then
    konfer:RefreshAllLists()
  end

  return false, newkey
end

--
-- Tell the other admins every option of LISTID as it now stands, the policy's own included, in one CHLST.
--
function cfgm:SendListOptions(listid)
  local rl = self.lists[listid]

  -- If this changes MUST change in Comms.lua(CHLST)
  self:AdminEvent("CHLST", listid, tonumber(rl.sortorder), tonumber(rl.def_rank), rl.strictcfilter and true or false,
    rl.strictrfilter and true or false, rl.extralist, rl.tethered and true or false, rl.altdisp and true or false,
    self:ListOptions(listid, self:GetPolicy().handle))
end

--
-- The one list every config of a policy that runs on one (its descriptor's onelist) is made with: untethered, every character
-- standing alone, everybody the config holds on it, and the config's default list. The player never sees it, so it is made
-- without a word in chat, but by events like any other change to a config. It is named for the policy, the same in every
-- config of it, so a copy finds the new config's own by name where the settings it copies name the source's. Answers its id.
--
function cfgm:MakeOneList()
  local name = self:GetPolicy().handle
  local rv, listid = self:CreateNewList(name, nil, true, true)

  if (rv) then
    return nil
  end

  self:AddEvent("MKLST", listid, name)
  self.lists[listid].tethered = false
  self:SendListOptions(listid)

  local uids = {}

  for uid in pairs(self.uids) do
    tinsert(uids, uid)
  end

  tsort(uids)

  for _, uid in ipairs(uids) do
    self:InsertMember(uid, listid)
  end

  self:ChangeSetting("def_list", listid)

  return listid
end

--
-- Put UID, just added to the config, on its one list where its policy runs on one (onelist). Called wherever this client
-- sends the MKUSR that adds them, so that the IMLST follows it.
--
function cfgm:JoinOneList(uid)
  local listid = self.settings.def_list

  if (self:GetPolicy().onelist and self.lists[listid]) then
    self:InsertMember(uid, listid)
  end
end

function cfgm:DeleteList(listid, nocmd)
  --
  -- A list we do not have is not deleted and not announced. What names it is still put right below, a reference to a list
  -- that does not exist being no use to anybody.
  --
  local existed = self.lists[listid] ~= nil

  if (existed) then
    local name = self.lists[listid].name
    self.lists[listid] = nil
    self.nlists = self.nlists - 1
    if (not nocmd) then
      konfer:GetPolicy(self.id):info(L["roll list %q deleted."], white(name))
    end
  end

  --
  -- A default list that has just been deleted names nothing. It is put right without an event of its own, every admin
  -- doing the same fixup as they process the deletion.
  --
  if (self.settings.def_list == listid) then
    self.settings.def_list = "0"
  end

  for k,v in pairs(self.lists) do
    if (v.extralist == listid) then
      self.lists[k].extralist = "0"
    end
  end

  --
  -- An item that named this list, either to roll on or to apply its award on, names nothing now.
  --
  for k,v in pairs(self.items) do
    if (v.list and v.list == listid) then
      self.items[k].list = nil
    end
    if (v.awardlist and v.awardlist == listid) then
      self.items[k].awardlist = nil
    end
  end

  --
  -- The page loses its selection if this was the list it had: the list is about to stop existing.
  --
  if (self:IsActive() and qf.current_listid == listid) then
    qf.current_listid = nil
  end

  if (existed and not nocmd) then
    self:AddEvent("RMLST", listid)
  end

  if (self:IsActive()) then
    konfer:RefreshAllLists()
  end
end

local function real_delete_list(mod, arg)
  local cfg = arg.cfg or mod.apol.cfg

  cfg:DeleteList(arg.listid, false)
end

function cfgm:DeleteListCmd(listid, show)
  --
  -- The dialog stands in for the window, hiding it and putting it back, but only when the list belongs to the config the
  -- window is showing. A list of any other config is not being deleted from here.
  --
  local win = (konfer.mainwin and (show or konfer.mainwin:IsShown()) and self:IsActive()) and konfer.mainwin or nil

  if (not self or not self.lists[listid]) then
    return true
  end

  K.ConfirmationDialog(konfer, { text = L["Delete roll list"], owner = konfer.apol }, L["DELLIST"],
    { L["Current list: %s"], self.lists[listid].name },
    real_delete_list, { cfg = self, listid = listid }, win, 190)

  return false
end

function cfgm:RenameList(listid, newname, nocmd)
  local pol = konfer:GetPolicy(self.id)

  --
  -- Names are kept unique where a list is named here. A rename another admin made and sent us is applied to its id whatever
  -- else is called that, so that later events for the id still find it.
  --
  if (not nocmd and konfer:NameTooShort(pol, newname)) then
    return true
  end

  -- Another list of the same name is a clash, and this one differing only in case is a rename.
  local cid = self:FindList(newname)
  if (cid and cid ~= listid and not nocmd) then
    pol:err(L["roll list %q already exists. Try again."], white(newname))
    return true
  end

  local oldname = self.lists[listid].name
  if (not nocmd) then
    pol:info(L["Roll list %q renamed to %q."], white(oldname), white(newname))
  end
  self.lists[listid].name = newname

  if (not nocmd) then
    self:AddEvent("MVLST", listid, newname)
  end

  if (self:IsActive()) then
    konfer:RefreshAllLists()
  end

  return false
end

function cfgm:CopyList(listid, newname, myid, nocmd)
  --
  -- The destination is named by whoever asked for the copy, so it is held to the same minimum as any other list name. The
  -- CreateNewList below cannot do it for us, being told nocmd so that it sends no MKLST of its own.
  --
  if (not nocmd and konfer:NameTooShort(konfer:GetPolicy(self.id), newname)) then
    return true
  end

  -- A copy another admin made and sent us is made under its id whatever else is called that, as CreateNewList explains.
  local cid = self:FindList(newname)
  if (cid and not (myid and nocmd)) then
    if (not nocmd) then
      konfer:GetPolicy(self.id):err(L["roll list %q already exists. Try again."], white(newname))
    end
    return true
  end

  local src = self.lists[listid]

  if (not src) then
    return true
  end

  --
  -- The copy travels as one CPLST and nothing else. Creating the list here would otherwise send an MKLST ahead of it, and
  -- every other admin would make the empty list from that and then find the name taken when the copy arrived.
  --
  local rv
  rv, cid = self:CreateNewList(newname, myid, true)
  if (rv) then
    return true
  end

  --
  -- A copy is the original in everything but its name: its options, its members, and whatever a policy keeps on it, standings
  -- and all. Copied whole, so that nothing added to a list later is left behind. PDATA is only ever a block in transit while
  -- a config arriving whole is taken in, and is no part of the list.
  --
  local dst = K.CopyTable(src, {})

  dst.name = newname
  dst.pdata = nil
  self.lists[cid] = dst

  if (not nocmd) then
    self:AddEvent("CPLST", listid, cid, newname)
  end

  if (self:IsActive()) then
    konfer:RefreshAllLists()
  end

  return false
end

--
-- Select LISTID on the page. A list belongs to one config and the page shows one, so a list of any other config is not there
-- to be selected and this says so, which is what its answer means.
--
function konfer:SelectList(listid)
  local pp = self.apol

  if (qf.lists and pp and pp.sortedlists) then
    for kk,v in ipairs(pp.sortedlists) do
      if (v.id == listid) then
        qf.lists:SetSelected(kk, true, true)
        return false
      end
    end
  end

  return true
end

--
-- Function: cfg:ListPosition(uid, listid)
-- Purpose : Where UID stands on list LISTID, and where they stand among the members of it who are actually in the raid. A
--           tethered alt stands where their main does, the main being the one entry the list holds.
--
--           The order walked is the policy's, through Order, because what a position means is the policy's whole claim.
--           Suicide Kings says the stored array is the order and reads a place straight out of it; EP/GP would sort by
--           points and DKP by its own, and each would answer a different number for the same list. Walking that order and
--           counting who is here is the same work whichever it is, so it is the platform's.
-- Returns : The position and the position among those in the raid, or nil for somebody the list does not hold.
--
function cfgm:ListPosition(uid, listid)
  local cfp = self.id and self
  local lp = cfp and cfp.lists[listid]

  if (not lp) then
    return nil, nil
  end

  local cuid = uid

  if (lp.tethered) then
    local isalt, main = self:IsAlt(uid)

    if (isalt) then
      cuid = main
    end
  end

  local _, ulist = self:PolicyCall("Order", lp.users, listid, lp.users)
  local rpos = 0

  for k, v in ipairs(ulist) do
    if (konfer.raid.uidmap) then
      local here = konfer.raid.uidmap[v] and true or false

      if (not here and lp.tethered) then
        for _, alt in ipairs(self:UserAlts(v) or {}) do
          if (konfer.raid.uidmap[alt]) then
            here = true
            break
          end
        end
      end

      if (here) then
        rpos = rpos + 1
      end
    end

    if (v == cuid) then
      return k, rpos
    end
  end

  -- Not on the list at all, which is no position rather than position 0.
  return nil, nil
end

function cfgm:IsInList(uid, listid)
  if (not self or not self.lists[listid]) then
    return nil
  end

  local rlist = self.lists[listid]
  if (#rlist.users < 1) then
    return false
  end
  for k,v in ipairs(rlist.users) do
    if (uid == v) then
      return true, k
    end
  end
  return false
end

--
-- Whether UID is on list LISTID counting alts, and if so which record answered and where it sits. IsInList asks the plain
-- question; this one asks it of a user and everybody tethered to them.
--
-- The one predicate here not named IsSomething, deliberately. "Or alt" is the whole of what makes it different from IsInList
-- and burying that mid-name reads as a variant of nothing in particular.
--
function cfgm:UserOrAltInList(uid, listid)
  if (not self or not self.lists[listid]) then
    return nil
  end

  local usr = self.uids[uid]
  if (not usr) then
    return false
  end

  local rlist = self.lists[listid]
  if (#rlist.users < 1) then
    return false
  end

  -- Look for main in the list first
  for k,v in ipairs(rlist.users) do
    if (uid == v) then
      return true, uid, k
    end
  end

  --
  -- An alt is looked for through its main only on a tethered list, where the alt is never on the list itself and stands
  -- where its main does. On a list that is not tethered an alt is a member in its own right, found above or not at all. A
  -- match through the main returns the MAIN's uid, so a caller that gets back a uid other than the one it passed knows UID
  -- is an alt whose main is on the list.
  --
  if (rlist.tethered) then
    local isalt, main = self:IsAlt(uid)

    if (isalt) then
      for k,v in ipairs(rlist.users) do
        if (v == main) then
          return true, v, k
        end
      end
    end
  end

  return false
end

function cfgm:InsertMember(uid, listid, pdata, nocmd)
  local rv = insert_list_member(self, uid, listid, pdata, nocmd)

  if (not rv and self:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end

  return rv
end

--
-- Sets the member list to exactly the ulist string, which is a concatenated list of user IDs, all of which are assumed to
-- already exist. This is only actually used by the CSV import functionality.
--
function cfgm:SetMemberList(ulist, listid, pdata, nocmd)
  if (not self.lists[listid]) then
    return true
  end

  local ll = self.lists[listid]
  ll.users = konfer:SplitRaidList(ulist)

  --
  -- The membership arrived as a string of uids and what the policy says about them arrives beside it, because a list of
  -- names with every number on it thrown away is not the list that was sent. Nothing given means there was nothing to say.
  --
  if (pdata ~= nil) then
    self:PolicyCall("SetListInfo", nil, listid, pdata)
  end

  if (not nocmd) then
    local _, info = self:PolicyCall("ListInfo", nil, listid)

    self:AddEvent("SMLST", listid, ulist, info)
  end

  if (self:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end

  return false
end

--
-- Hand every list its policy's own data after a whole config has arrived, and forget the copy that travelled with it.
--
-- A broadcast, a full sync and a recovery all replace the lists wholesale, so there is no event for any of it and the
-- policy has to be told once the config is in place. Nothing here reads what is in the block.
--
function cfgm:AdoptListInfo()
  for listid, rl in pairs(self.lists or {}) do
    if (rl.pdata ~= nil) then
      self:PolicyCall("SetListInfo", nil, listid, rl.pdata)
      rl.pdata = nil
    end
  end
end

function cfgm:DeleteMember(uid, listid, nocmd)
  if (not self or not self.lists[listid]) then
    return true
  end

  local rl = self.lists[listid]
  local ul = rl.users
  local up = nil

  for k,v in ipairs(ul) do
    if (v == uid) then
      up = k
      break
    end
  end

  if (up == nil) then
    return true
  end

  tremove(ul, up)

  -- Somebody no longer on the list has no standing on it, and one who comes back starts afresh.
  if (rl.standings) then
    rl.standings[uid] = nil
  end

  -- Whatever else the policy was keeping about them here goes the same way, and only the policy knows what that is.
  self:PolicyCall("MemberRemoved", nil, listid, uid)

  if (not nocmd) then
    self:AddEvent("DMLST", uid, listid)
  end

  if (self:IsActive()) then
    konfer:RefreshAllMemberLists(listid)
  end

  return false
end

--
-- Whenever we change a user's Alt status, or whenever a member list has its "tethered alts" setting changed, we may need to
-- fix up entries in all of the lists. Say for example UserB is an alt of UserA. They are both members in List1. Now the
-- owner decides she wants to enable tethered alts. This means that UserB needs to be removed from List1, because that user
-- will now appear "underneath" UserA in the list. The same situation can occur if tethered alts were already enabled but a
-- user was not correctly marked as an alt. When that is corrected, we need to make sure that the alt is removed from all
-- lists, as it will now be tethered to the main. So we simply need to go through all lists in the configuration and remove
-- any alts. However, if only the alt is in the list, we need to replace that slot position with the main, as it will now be replaced by the main.
--
function cfgm:FixupLists(rec)
  local changed = false

  for k,v in pairs(self.lists) do
    if (v.tethered) then
      local il = 1
      while (il <= #v.users) do
        local inc = 1
        local vv = v.users[il]
        local ia, mid = self:IsAlt(vv)

        if (ia) then
          assert(mid)
          if (not self:IsInList(mid, k)) then
            --
            -- The user is marked as an alt but their main isn't in the list. This means we have to replace this alt (in the
            -- same position) with the alt's main.
            --
            v.users[il] = mid
            changed = true
          else
            --
            -- The alt's main is already in the list, so we can now safely remove this alt from the roll list.
            --
            tremove(v.users, il)
            changed = true
            inc = 0
          end
        end
        il = il + inc
      end
    end
  end

  if (changed) then
    self:FixupLists(true)
  end

  if (not rec and self:IsActive()) then
    konfer:RefreshAllLists()
    konfer:RefreshAllMemberLists()
  end

  return false
end

--
-- The same, over every config this client holds. An alt link lives once, in KU.users, so writing one changes what IsAlt
-- answers for every config holding either character, and the tethered lists that follow from it are every one of those
-- configs' lists rather than only the ones some message happened to name.
--
-- This is one of the few places entitled to look at all of them, for the same reason a database repair was: the thing that
-- changed is a fact about a person and belongs to no policy.
--
-- Whoever changes a link calls this, and so does whoever is told about one. What the two of them derive has to be the same,
-- because none of it is an event and nothing later would ever reconcile it: the checksums agree throughout, and every
-- message about that person afterwards reads as a link that is already correct.
--
function konfer:FixupAllLists()
  for kp, pol in pairs(self.policies) do
    for cfgid, cfp in pairs(self:PolicyConfigs(pol)) do
      cfp:FixupLists()
    end
  end
end

function konfer:RefreshAllMemberLists(listid)
  -- Refresh the list panel's member list (that's us).
  if (qf.memberlist) then
    refresh_member_list(self, listid)
  end

  -- Refresh the loot distribution's member list.
  self:RefreshLootMembers()

  -- Refresh potential user membership display
  self:RefreshUsersLists()

  -- And the Raid page, which shows the active policy's numbers beside everybody in the group, and its own pages.
  self:RefreshPolicyPages()
end
