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
local KU = K.Users

local tinsert = table.insert
local tconcat = table.concat
local tsort = table.sort
local strlower = string.lower
local strfmt = string.format
local pairs, ipairs, type = pairs, ipairs, type
local tostring = tostring
local max, min, ceil = math.max, math.min, math.ceil

--
-- THE RAID PAGE
--
-- Everybody in the group, on the page between Lists and Loot, whichever policy is active. It is up while the player is in a
-- party or a raid and gone otherwise, unless the active policy keeps it up (RaidPage.solo in Policy.lua). Its first tab,
-- Raiders, is the platform's. Each raider is drawn as the raid frames and the mod know them, and after the name come the
-- active policy's own columns, what it counts about each of them (RaidPage.columns). Under the list are Rate, Ready check,
-- Broadcast and an admin's Selected, and a second row of the policy's own buttons with Remove among them. A right click on
-- a raider puts up what can be done to them in the group. The policy's own tabs follow Raiders (RaidTabs), PUG's Reserves.
--
-- A pickup raid is strangers from every realm, so each raider is named as the game names them, the realm only for another
-- realm's, in class colour, with the roles they raid in where those are known and the markers. Every column sorts from its
-- heading, and the list starts sorted the way the policy says, by name unless it says otherwise. The list stands centred on
-- the page, as wide as its columns, over a separator and room for two rows of buttons.
--
local RAID_BTN_H = 24
local RAID_BTN_W = 100
local RAID_BUTTONS_H = RAID_BTN_H + KUI.WIDGET_GAP + RAID_BTN_H + KUI.WIDGET_GAP

-- The separator stands a gap above the buttons, the list keeping its gap above the separator.
local RAID_SEP_Y = RAID_BUTTONS_H + KUI.WIDGET_GAP
local RAID_FONT = "GameFontNormalSmallLeft"
local RAID_ROW_H = 16

-- A policy's columns are headed in the tiny font, so that each is no wider than its numbers need.
local RAID_HEAD_FONT = "GameFontNormalTiny2"

-- The room a column list leaves at either end of a cell.
local CELL_PAD = 8

-- Everybody in the group as the page has them (raid_rows), and those its role filter lets through, which its list shows.
local grouprows = {}
local raidrows = {}

-- The Raiders tab's content, which keeps everything the page builds.
local raidclient = nil

--
-- The raid frames' own marks beside each name, in the three places those frames give them: leader or assistant, main tank or
-- main assist, and master looter.
--
local RANK_ICONS = {
  [2] = "Interface\\GroupFrame\\UI-Group-LeaderIcon",
  [1] = "Interface\\GroupFrame\\UI-Group-AssistantIcon",
}

local ROLE_ICONS = {
  [KRP.GROUP_ROLE_TANK] = "Interface\\GroupFrame\\UI-Group-MainTankIcon",
  [KRP.GROUP_ROLE_ASSIST] = "Interface\\GroupFrame\\UI-Group-MainAssistIcon",
}

local LOOT_ICON = "Interface\\GroupFrame\\UI-Group-MasterLooter"

-- The role each has taken in the group, drawn as the raid frames draw it, and kept apart from the roles the mod records.
local ASSIGNED_ATLASES = {
  [KRP.ASSIGNED_TANK] = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder",
  [KRP.ASSIGNED_HEALER] = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder",
  [KRP.ASSIGNED_DAMAGE] = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder",
}

local function show_icon(tex, path)
  if (path) then
    tex:SetTexture(path)
  end

  tex:SetShown(path ~= nil)
end

-- The list's column for KEY among POL's own, named with the policy's prefix so that no two policies' columns meet.
local function policy_key(pol, key)
  return pol.prefix .. key
end

--
-- The answers to the group's ready check, KRP.ready, while it runs and for READY_SHOWN seconds after it ends, and nil the
-- rest of the time. The page is drawn again when they go (konfer:RefreshRaidUI).
--
local READY_SHOWN = 30

local function ready_answers()
  if (KRP.ready and (KRP.ready_checking or (KRP.ready_ended and GetTime() - KRP.ready_ended < READY_SHOWN))) then
    return KRP.ready
  end

  return nil
end

--
-- Everybody in the group, each with what the active policy shows of them in its columns (RaidPage.Row), keyed by the list's
-- column. The markers are the config's, a raid enchanter, frozen and reserved, and one for a raider who has not consented to
-- the leader collecting the group's loot.
--
local function raid_rows()
  local pp = konfer.apol
  local cfg = pp and pp.cfg
  local rp = pp and pp.RaidPage
  local answers = ready_answers()
  local rows = {}

  if (not KRP.in_party or not KRP.players) then
    return rows
  end

  for name, p in pairs(KRP.players) do
    local uid = cfg and cfg:FindUser(name)
    local r = { name = name, class = p.class, kuid = KU:Find(name), uid = uid }

    r.markers = konfer:UserMarkers(uid and cfg:IsEnchanter(uid), uid and cfg:IsFrozen(uid), uid and cfg:IsReserved(uid),
      konfer:NotConsented(name))

    -- Leader is 2 and assistant 1, a party's leader being its only rank.
    r.rank = (p.is_rl or (not KRP.in_raid and p.is_pl)) and 2 or (p.is_aorl and 1) or 0
    r.mrole = p.group_role
    r.assigned = p.assigned
    r.ml = p.is_ml
    r.mark = p.mark
    r.online = p.online ~= false
    r.ready = answers and answers[name] or nil

    if (cfg and rp and rp.Row) then
      local _, cells = konfer:PolicyHook(pp, "RaidPage.Row", nil, rp.Row, cfg.id, r)

      for _, c in ipairs(rp.columns or {}) do
        r[policy_key(pp, c.key)] = (type(cells) == "table") and cells[c.key] or nil
      end
    end

    tinsert(rows, r)
  end

  return rows
end

--
-- The raiders the page's role filter lets through, the filter being the config's admins' alone: those who have taken the
-- role picked in the group (KRP's roles taken), damage of every kind or of one. Everybody for anybody else.
--
local RAID_FILTERS = {
  tank = KRP.IsTank, healer = KRP.IsHealer, damage = KRP.IsDPS, melee = KRP.IsMelee, ranged = KRP.IsRanged,
  caster = KRP.IsCaster,
}

local function filtered_rows(client)
  local cfg = konfer.apol and konfer.apol.cfg
  local test = (cfg and cfg:MyStatus() and client.rolefilter) and RAID_FILTERS[client.rolefilter:GetValue()]
  local rows = {}

  if (not test) then
    return grouprows
  end

  for _, r in ipairs(grouprows) do
    if (test(KRP, r.name)) then
      tinsert(rows, r)
    end
  end

  return rows
end

-- By name without regard to case, the name as it is spelled breaking a tie.
local function by_name(a, b)
  local la, lb = strlower(a.name), strlower(b.name)

  if (la ~= lb) then
    return la < lb
  end

  return a.name < b.name
end

-- By the value in the column KEY, a raider with none below everybody with one, and then by name.
local function by_value(key)
  return function(a, b)
    local va, vb = a[key], b[key]

    if (va ~= vb) then
      if (va == nil or vb == nil) then
        return vb ~= nil
      end

      return va < vb
    end

    return by_name(a, b)
  end
end

--
-- Whether this character may start a ready check, as the game allows one: the group's leader or a raid's assistant, while
-- no check is running. When not, why, which a policy's ready check command says and the page's button says by being dark.
--
local function may_ready_check()
  if (not (KRP.is_rl or (not KRP.in_raid and KRP.is_pl) or KRP.is_aorl)) then
    return false, L["only the leader or an assistant can start a ready check."]
  end

  if (KRP.ready_checking) then
    return false, L["a ready check is already running."]
  end

  return true
end

-- Start a ready check, the page's Ready check by another road, or tell POL's player why not.
function konfer:ReadyCheck(pol)
  local ok, why = may_ready_check()

  if (not ok) then
    pol:err(why)
    return
  end

  KRP:StartReadyCheck()
end

-- The row of the raider picked in the list, or nil.
local function selected_raider(client)
  for _, r in ipairs(raidrows) do
    if (r.name == client.selected) then
      return r
    end
  end
end

--
-- The menu a right click on a raider puts up at the pointer, headed by who it is for: making them the group's leader, and
-- whether they are one of its assistants, its main tank, its main assist and its master looter, and under a spacer two
-- flyouts, of the mark they wear as a raid target, skull first and none last as the game's own menu has them, and of the
-- role they have taken as one of Kore's, damage told apart as melee, ranged and caster (KRP's .assignedrole), none last.
-- Each is lit only where the game lets this character make that change: the leader any of it, an assistant the main tank,
-- main assist, marks and roles, in a party anybody the marks, and anybody their own role (KRP:CanAssign). Kore asks the
-- game for the change (KRP:SetAssistant and the rest), and the page follows as the group comes in again. The main tank
-- and main assist are the game's alone to set, so those two items are secure ones, carrying what KRP:GroupRoleAction
-- says, and a made up raid, which no secure button reaches, is changed by a func instead. Made once and handed its items
-- each time.
--
local MARK_ORDER = { 8, 7, 6, 5, 4, 3, 2, 1 }
local raidmenu = nil

-- A menu item's func that runs FN when the item is clicked, and not when it is made.
local function act(fn)
  return function(item, created)
    if (not created) then
      fn()
    end
  end
end

local function raid_menu(client)
  local r = selected_raider(client)
  local p = r and KRP.players and KRP.players[r.name]

  if (not p) then
    return
  end

  local lead = KRP.is_rl or (not KRP.in_raid and KRP.is_pl)
  local assist = KRP.in_raid and KRP.is_aorl
  local other = r.name ~= K.player.name

  -- Everything on it is a leader's or an assistant's to do, so nobody else is offered it.
  if (not lead and not assist) then
    return
  end

  -- A pretend raid keeps this character its leader and master looter whatever is asked.
  local fixed = false
  fixed = KRP.pretend and true or false -- @debug-delete@

  local function role_item(text, role)
    local on = r.mrole ~= role
    local item = { text = text, checked = not on, keep = false, secure = KRP:GroupRoleAction(r.name, role, on) }

    -- @debug-start@
    if (KRP.pretend) then
      item.func = act(function() KRP:PretendGroupRole(r.name, role, on) end)
    end
    -- @debug-end@

    item.enabled = (KRP.in_raid and (lead or assist) and (item.secure or item.func)) and true or false
    return item
  end

  local items = {
    { text = (K.ClassColorsEsc[r.class] or "|cffffffff") .. K.DisplayName(r.name) .. "|r", title = true },
    { text = L["Promote to leader"], checkable = false, keep = false, enabled = lead and other and not fixed,
      func = act(function() KRP:PromoteToLeader(r.name) end) },
    { text = L["Assistant"], checked = r.rank == 1, keep = false, enabled = KRP.in_raid and lead and other,
      func = act(function() KRP:SetAssistant(r.name, r.rank ~= 1) end) },
    role_item(L["Main tank"], KRP.GROUP_ROLE_TANK),
    role_item(L["Main assist"], KRP.GROUP_ROLE_ASSIST),
  }

  -- Only where the game has master loot is there anybody to make master looter.
  if (K.HAS_MASTER_LOOT) then
    tinsert(items, { text = L["Master looter"], checked = r.ml and true or false, keep = false,
      enabled = lead and not r.ml and not fixed, func = act(function() KRP:SetMasterLooter(r.name) end) })
  end

  tinsert(items, { text = "-" })

  local marking = ((not KRP.in_raid) or lead or assist) and true or false
  local marks = {}

  -- A mark is put on by a secure button, the game refusing it to an addon, as it does the main tank (KRP:MarkAction).
  local function mark_item(item, mark)
    item.keep = false
    item.secure = KRP:MarkAction(r.name, mark)

    -- @debug-start@
    if (KRP.pretend) then
      item.func = act(function() KRP:PretendMark(r.name, mark) end)
    end
    -- @debug-end@

    item.enabled = (marking and item.enabled ~= false and (item.secure or item.func)) and true or false
    return item
  end

  for _, mark in ipairs(MARK_ORDER) do
    local name, colour, coords = KRP.MarkInfo(mark)

    tinsert(marks, mark_item({ text = name, color = colour, icon = KRP.MARK_TEXTURE, iconcoord = coords,
      checked = p.mark == mark }, (p.mark == mark) and 0 or mark))
  end

  -- No mark at all, which takes off whatever they wear.
  tinsert(marks, mark_item({ text = K.NONE_STR, checked = p.mark == nil, enabled = p.mark ~= nil }, 0))

  tinsert(items, { text = L["Raid icon"], checkable = false, clickable = false, enabled = marking,
    submenu = { name = "KonferRaidMarkMenu", itemheight = 16, items = marks } })

  local assigning = KRP:CanAssign(r.name)
  local roles = {}

  for _, role in ipairs(K.ROLES) do
    tinsert(roles, { text = K.RoleName(role), icon = KUI.ROLE_ICON_TEXTURE,
      iconcoord = KUI:RoleIconCoord(KUI:RoleIconKind(role)), checked = p.assignedrole == role, keep = false,
      enabled = assigning, func = act(function() KRP:SetAssigned(r.name, (p.assignedrole ~= role) and role or nil) end) })
  end

  -- No role at all, which takes away whatever they have taken.
  local unassigned = (p.assigned or KRP.ASSIGNED_NONE) == KRP.ASSIGNED_NONE

  tinsert(roles, { text = L["No role"], checked = unassigned, keep = false,
    enabled = (assigning and not unassigned) and true or false,
    func = act(function() KRP:SetAssigned(r.name, nil) end) })

  tinsert(items, { text = L["Raid role"], checkable = false, clickable = false, enabled = assigning,
    submenu = { name = "KonferRaidRoleMenu", itemheight = 16, items = roles } })

  if (not raidmenu) then
    raidmenu = KUI:CreatePopupMenu({ name = "KonferRaidMenu", itemheight = 16, escclose = true, items = items },
      konfer.mainwin)
  else
    raidmenu:UpdateItems(items)
  end

  local x, y = GetCursorPosition()
  local scale = raidmenu:GetEffectiveScale()

  raidmenu:ClearAllPoints()
  -- Just clear of the pointer, so that the menu's corner is not under it for the second click of a double click.
  raidmenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 4, y / scale)
  raidmenu:Show()
end

--
-- The Selected dropdown's items, what can be done to every raider ticked at once. Each item is ticked when all of them have
-- it, and clicked takes it from them all then, or otherwise gives it to those without. Assistant is the leader's, for all
-- but this character and the leader. Main tank and main assist are a leader's or an assistant's, secure items as on a
-- raider's own menu, set to change only those who need it (KRP:GroupRolesAction). Under a spacer Clear raid icon, lit while
-- any of them wears a mark, and the role flyout, lit where every one of them may be given a role (KRP:CanAssign).
--
local function selected_items(client)
  local lead = KRP.is_rl or (not KRP.in_raid and KRP.is_pl)
  local assist = KRP.in_raid and KRP.is_aorl
  local ticked, others = {}, {}

  for _, r in ipairs(raidrows) do
    if (client.ticked[r.name]) then
      tinsert(ticked, r)

      if (r.name ~= K.player.name and r.rank ~= 2) then
        tinsert(others, r)
      end
    end
  end

  -- Whether HAS is true of every one of RAIDERS, of whom there must be some.
  local function all(raiders, has)
    for _, r in ipairs(raiders) do
      if (not has(r)) then
        return false
      end
    end

    return #raiders > 0
  end

  local assistants = all(others, function(r) return r.rank == 1 end)

  local items = {
    { text = L["Assistant"], checked = assistants, keep = false,
      enabled = (KRP.in_raid and lead and #others > 0) and true or false, func = act(function()
        for _, r in ipairs(others) do
          if ((r.rank == 1) == assistants) then
            KRP:SetAssistant(r.name, not assistants)
          end
        end
      end) },
  }

  local function group_role_item(text, role)
    local on = not all(ticked, function(r) return r.mrole == role end)
    local names = {}

    for _, r in ipairs(ticked) do
      if ((r.mrole == role) ~= on) then
        tinsert(names, r.name)
      end
    end

    local item = { text = text, checked = not on, keep = false,
      secure = (#names > 0) and KRP:GroupRolesAction(names, role, on) or nil }

    -- @debug-start@
    if (KRP.pretend) then
      item.func = act(function()
        for _, name in ipairs(names) do
          KRP:PretendGroupRole(name, role, on)
        end
      end)
    end
    -- @debug-end@

    item.enabled = (KRP.in_raid and (lead or assist) and (item.secure or item.func)) and true or false
    return item
  end

  tinsert(items, group_role_item(L["Main tank"], KRP.GROUP_ROLE_TANK))
  tinsert(items, group_role_item(L["Main assist"], KRP.GROUP_ROLE_ASSIST))
  tinsert(items, { text = "-" })

  local function player(r)
    return (KRP.players and KRP.players[r.name]) or {}
  end

  local assigning = all(ticked, function(r) return KRP:CanAssign(r.name) end)
  local roles = {}

  for _, role in ipairs(K.ROLES) do
    local have = all(ticked, function(r) return player(r).assignedrole == role end)

    tinsert(roles, { text = K.RoleName(role), icon = KUI.ROLE_ICON_TEXTURE,
      iconcoord = KUI:RoleIconCoord(KUI:RoleIconKind(role)), checked = have, keep = false, enabled = assigning,
      func = act(function()
        for _, r in ipairs(ticked) do
          KRP:SetAssigned(r.name, (not have) and role or nil)
        end
      end) })
  end

  local unassigned = all(ticked, function(r) return (player(r).assigned or KRP.ASSIGNED_NONE) == KRP.ASSIGNED_NONE end)

  tinsert(roles, { text = L["No role"], checked = unassigned, keep = false,
    enabled = (assigning and not unassigned) and true or false, func = act(function()
      for _, r in ipairs(ticked) do
        KRP:SetAssigned(r.name, nil)
      end
    end) })

  -- Clear raid icon takes the marks off those ticked who wear one, a secure item as marking is (KRP:ClearMarksAction).
  local marked = {}

  for _, r in ipairs(ticked) do
    if (player(r).mark ~= nil) then
      tinsert(marked, r.name)
    end
  end

  local clear = { text = L["Clear raid icon"], checkable = false, keep = false,
    secure = (#marked > 0) and KRP:ClearMarksAction(marked) or nil }

  -- @debug-start@
  if (KRP.pretend) then
    clear.func = act(function()
      for _, name in ipairs(marked) do
        KRP:PretendMark(name, 0)
      end
    end)
  end
  -- @debug-end@

  clear.enabled = (((not KRP.in_raid) or lead or assist) and #marked > 0 and (clear.secure or clear.func)) and true or false
  tinsert(items, clear)

  tinsert(items, { text = L["Raid role"], checkable = false, clickable = false, enabled = assigning,
    submenu = { name = "KonferRaidSelectedRoleMenu", itemheight = 16, items = roles } })

  return items
end

--
-- The Selected dropdown is given its items again whenever the page is drawn, and as it closes, but never while it is open:
-- a menu holding secure items made again from under itself has hung the game.
--
local function refill_selected(client)
  local menu = client.selectedmenu

  if (not menu.dropdown:IsShown()) then
    menu:UpdateItems(selected_items(client))
  end
end

--
-- The raiders ticked on the page are one selection, shared by the config's admins in the group. Each tick and untick an
-- admin makes is told to the rest as RTICK, by the config's uids for whoever was ticked and whoever unticked, gathered over
-- TICK_WAIT so that a click on the header box goes as one message. A raider the config does not hold has no uid, and a tick
-- of theirs stays this admin's own, who is warned of everybody ticked so, once a batch, to add them as users. Told as
-- changes rather than as the whole selection, two admins ticking different raiders at once both have their way. An admin
-- who was not there for a change has not heard it.
--
local TICK_WAIT = 0.3

local function tell_tick(client, r, checked)
  client.told = client.told or {}
  client.unknown = client.unknown or {}

  if (r.uid) then
    client.told[r.uid] = checked and true or false
  else
    client.unknown[r.name] = checked or nil
  end

  if (client.telling) then
    return
  end

  client.telling = true
  C_Timer.After(TICK_WAIT, function()
    local pp = konfer.apol
    local cfg = pp and pp.cfg
    local on, off, unknown = {}, {}, {}

    for who, ticked in pairs(client.told) do
      tinsert(ticked and on or off, who)
    end

    for name in pairs(client.unknown) do
      tinsert(unknown, K.DisplayName(name))
    end

    client.told = {}
    client.unknown = {}
    client.telling = nil

    if (not cfg or not cfg:MyStatus()) then
      return
    end

    if (#on > 0 or #off > 0) then
      pp:CSendGroupAM(cfg.id, "RTICK", "ALERT", on, off)
    end

    if (#unknown > 0) then
      tsort(unknown)
      pp:warn((#unknown == 1) and L["%s is not a user of this configuration."]
        or L["%s are not users of this configuration."], tconcat(unknown, ", "))
    end
  end)
end

--
-- Another admin of CFG, SENDER, ticked ON on the page and unticked OFF, each a list of the config's uids (RTICK). Taken by
-- an admin of the config the page is showing, and applied to the raiders still in the group, whether or not this admin's
-- role filter shows them.
--
function konfer:ApplyRaidTicks(sender, cfg, on, off)
  local client = raidclient
  local pp = self.apol
  local suid = cfg:FindUser(sender)
  local names = {}

  if (not client or not pp.cfg or cfg.id ~= pp.cfg.id or not cfg:MyStatus() or sender == K.player.name) then
    return
  end

  if (not suid or not cfg:IsAdmin(suid) or type(on) ~= "table" or type(off) ~= "table") then
    return
  end

  for _, r in ipairs(grouprows) do
    if (r.uid) then
      names[r.uid] = r.name
    end
  end

  for _, uid in ipairs(off) do
    if (names[uid]) then
      client.ticked[names[uid]] = nil
    end
  end

  for _, uid in ipairs(on) do
    if (names[uid]) then
      client.ticked[names[uid]] = true
    end
  end

  client.raiders:RefreshChecks()
  client.sync()
end

--
-- Show the rows in the order the list is sorted, the raider picked before still picked wherever they now stand, and nobody
-- once they have gone, and the buttons lit for whoever that is.
--
local function show_raid_rows(client)
  local list = client.raiders
  local keep = client.selected
  local idx = nil
  local here = {}

  -- A tick goes with a raider who has left, rather than waiting to come back with them, and stays with one filtered out.
  for _, r in ipairs(grouprows) do
    here[r.name] = true
  end

  for name in pairs(client.ticked) do
    if (not here[name]) then
      client.ticked[name] = nil
    end
  end

  list:Sort(raidrows)
  list:UpdateList(#raidrows)

  for i, r in ipairs(raidrows) do
    if (r.name == keep) then
      idx = i
    end
  end

  -- Redrawing the list unpicks its row on the way, so the pick is put back from what was kept before it.
  client.selected = idx and keep or nil
  list:SetSelected(idx, true, true)
  client.sync()
end

--
-- The buttons are all RAID_BTN_W wide, and Selected as wide as it needs for a full raid, never narrower than they are. A row
-- is the widths of what is in it with a gap between each two.
--
local function row_width(client, btns)
  local w = 0

  for i, b in ipairs(btns) do
    w = w + ((b == client.selectedmenu) and client.selw or client.btnw) + ((i > 1) and KUI.WIDGET_GAP or 0)
  end

  return w
end

-- POL's own buttons on the second row, in the order they stand, and the platform's Remove among them (RaidPage.buttons).
local function second_row(client, pol)
  local out = {}
  local placed = false

  for _, b in ipairs((pol and pol.RaidPage and pol.RaidPage.buttons) or {}) do
    if (b == "remove") then
      tinsert(out, client.removebtn)
      placed = true
    elseif (pol.raidbuttons and pol.raidbuttons[b.name]) then
      tinsert(out, pol.raidbuttons[b.name])
    end
  end

  if (not placed) then
    tinsert(out, client.removebtn)
  end

  return out
end

-- Lay the second row out for POL, its buttons and Remove centred across the foot of the page.
local function lay_second_row(client, pol)
  local row = client.bottomrow
  local btns = second_row(client, pol)

  for i, b in ipairs(btns) do
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (client.btnw + KUI.WIDGET_GAP), 0)
  end

  row:SetWidth(row_width(client, btns))
end

--
-- The top row: Rate, Ready check and Broadcast for anybody, then for the config's admins Consent where the game has no
-- master loot (GroupLoot.lua) and Selected, which is last, so that only the row's end moves for being wider.
--
local function lay_top_row(client, admin)
  local btns = { client.ratebtn, client.readybtn, client.bcastbtn }
  local consent = admin and not K.HAS_MASTER_LOOT

  if (consent) then
    tinsert(btns, client.consentbtn)
  end
  if (admin) then
    tinsert(btns, client.selectedmenu)
  end

  client.consentbtn:SetShown(consent)
  client.selectedmenu:SetShown(admin)

  for i, b in ipairs(btns) do
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", client.toprow, "TOPLEFT", (i - 1) * (client.btnw + KUI.WIDGET_GAP), 0)
  end

  client.toprow:SetWidth(row_width(client, btns))
end

--
-- Build the page's Raiders tab, once, with the window. Every policy's columns go into the one list here, hidden until that
-- policy is the active one and says it shows them (konfer:RefreshRaidUI).
--
function konfer:InitialiseRaidUI()
  local page = self.mainwin:GetPage(self.RAID_PAGE)
  local client = page.tabsbyname[self.RAID_RAIDERS_TAB].content

  --
  -- The buttons' room across the foot of the page, two rows of RAID_BTN_H with a gap between them and under the second, the
  -- separator across the page a gap above it, and above that, up to the top of the page or for an admin up to the role
  -- filter (client.rolefilter), the list, in a frame of its own centred on the page and as wide as its columns, the strip for
  -- its boxes and the scroll bar's past them (konfer:RefreshRaidUI), a scroll list filling whatever it is given. It is a check
  -- list, a box at the right of every raider and one in the header over them for them all, the ticks kept by name in
  -- CLIENT.ticked for the session. The boxes are shown to the config's admins alone, their strip kept for anybody else
  -- (client.sync).
  --
  raidclient = client
  client.buttons = KUI.MakeFrame("Frame", nil, client)
  client.buttons:SetPoint("BOTTOMLEFT", client, "BOTTOMLEFT", 0, 0)
  client.buttons:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", 0, 0)
  client.buttons:SetHeight(RAID_BUTTONS_H)

  client.separator = KUI:CreateSeparator({ x = 0, y = 0 }, client)
  client.separator:ClearAllPoints()
  client.separator:SetPoint("BOTTOMLEFT", client, "BOTTOMLEFT", 0, RAID_SEP_Y)
  client.separator:SetPoint("BOTTOMRIGHT", client, "BOTTOMRIGHT", 0, RAID_SEP_Y)

  local lframe = KUI.MakeFrame("Frame", nil, client)

  lframe:SetPoint("TOP", client, "TOP", 0, 0 - KUI.WIDGET_GAP)
  lframe:SetPoint("BOTTOM", client, "BOTTOM", 0, RAID_SEP_Y + client.separator:GetHeight() + KUI.WIDGET_GAP)
  client.listframe = lframe

  --
  -- The Name column is the role the raider has taken in the group, as the raid frames draw it, its room kept where they have
  -- taken none so that the names line up, then the name, and realm where shown, in a box of their own, as wide as a twelve
  -- letter name on a long realm and ending in an ellipsis past that. The raid target mark a raider wears follows their name
  -- inside the box, a gap after its last letter, and a name too long to leave it room ends sooner. Packed against the far end
  -- of the column, as every list of people packs its rows, are the roles they raid in and the markers
  -- (konfer:PackRowRight), with room for every marker at once. The raid frames' marks stand outside the list, at the left of
  -- each row (newrow). A raider who is offline is named in grey. Their answer to the group's last ready check (KRP.ready)
  -- stands outside the list at the right of the row as the marks do at its left, past the box and the scroll bar, so that
  -- the list is no wider for it: the kit's medallion for the answer READY_SIZE tall, a question mark while they have not
  -- answered, ready, not ready, and AFK once the check ran out without them.
  --
  -- Every policy's own columns follow it, each as narrow as its heading or as its widest value, and hidden but for the
  -- active policy's.
  --
  local NAME_W = KUI:MeasureStrWidth("Demagenemois-Thunderstrike", RAID_FONT)
  local TARGET_SIZE = 12
  local ASSIGNED_SIZE = 12
  local READY_SIZE = 12
  local READY_PIECES = {
    [KRP.RC_WAITING] = "ReadyCheckWaiting",
    [KRP.RC_AWAY] = "ReadyCheckAway",
    [KRP.RC_READY] = "ReadyCheckReady",
    [KRP.RC_NOTREADY] = "ReadyCheckNotReady",
  }
  local ROLES_W = 12 + 2 + 12

  -- [?] is only ever shown where the game has no master loot (konfer:NotConsented), so only there is room kept for it.
  local MARKS_W = KUI:WidestString({ konfer:UserMarkers(true, true, true, not K.HAS_MASTER_LOOT) }, RAID_FONT)
  local columns = {
    { key = "name", text = L["Name"], sort = by_name,
      width = CELL_PAD + ASSIGNED_SIZE + KUI.INTERNAL_GAP + NAME_W + KUI.WIDGET_GAP + MARKS_W + KUI.WIDGET_GAP + ROLES_W
        + CELL_PAD },
  }
  local handles = {}

  for handle in pairs(self.policies) do
    tinsert(handles, handle)
  end

  tsort(handles)

  for _, handle in ipairs(handles) do
    local pol = self.policies[handle]

    for _, c in ipairs((pol.RaidPage and pol.RaidPage.columns) or {}) do
      local key = policy_key(pol, c.key)
      local w = c.widest and (ceil(KUI:MeasureStrWidth(c.widest, RAID_FONT)) + CELL_PAD + CELL_PAD) or 1

      tinsert(columns, { key = key, text = { text = c.text, font = RAID_HEAD_FONT }, width = w, align = c.align,
        sort = by_value(key), format = c.format })
    end
  end

  local list

  client.ticked = {}

  list = KUI:CreateColumnList({
    name = "KonferRaidList", columns = columns, sortkey = "name", font = RAID_FONT, itemheight = RAID_ROW_H,
    itemcheck = "TINY", checkpos = "RIGHT", checkall = true,
    ischecked = function(objp, idx)
      return raidrows[idx] and client.ticked[raidrows[idx].name]
    end,
    --
    -- A click picks the raider the buttons under the list act on. The name's cell is left empty, and the role taken, the
    -- box, the roles and the markers stand where its words would start.
    --
    -- The raid frames' marks stand just outside the list to the left of the row, each 10 along from the last, their art
    -- leaving room round it, so the list stays centred on the names. The master looter's is last, and neither it nor its
    -- room is there where the game has no master loot. A list clips whatever is drawn outside it, so they are on a frame of
    -- their own hung on the list's holder rather than on the row, anchored to the row and shown and hidden with it, the
    -- list scrolling a whole row at a time.
    --
    newrow = function(ret, row, num)
      local marks = KUI.MakeFrame("Frame", nil, lframe)

      marks:SetSize(12 + 10 + (K.HAS_MASTER_LOOT and 10 or 0), RAID_ROW_H)
      marks:SetPoint("RIGHT", row, "LEFT", -2, 0)
      marks:SetShown(row:IsShown())
      row:HookScript("OnShow", function()
        marks:Show()
      end)
      row:HookScript("OnHide", function()
        marks:Hide()
      end)
      row.raidmarks = marks

      local function icon(x)
        local tex = marks:CreateTexture(nil, "ARTWORK")

        tex:SetSize(12, 12)
        tex:SetPoint("LEFT", marks, "LEFT", x, 0)
        tex:Hide()

        return tex
      end

      row.rankicon = icon(0)
      row.mroleicon = icon(10)
      row.looticon = K.HAS_MASTER_LOOT and icon(20) or nil

      row.assignedicon = row:CreateTexture(nil, "ARTWORK")
      row.assignedicon:SetSize(ASSIGNED_SIZE, ASSIGNED_SIZE)
      row.assignedicon:SetPoint("LEFT", row.cells.name, "LEFT", 0, 0)
      row.assignedicon:Hide()

      row.namebox = KUI.MakeFrame("Frame", nil, row)
      row.namebox:SetPoint("LEFT", row.assignedicon, "RIGHT", KUI.INTERNAL_GAP, 0)
      row.namebox:SetSize(NAME_W, RAID_ROW_H)
      row.nametext = row.namebox:CreateFontString(nil, "ARTWORK", RAID_FONT)
      row.nametext:SetPoint("LEFT", row.namebox, "LEFT", 0, 0)
      row.nametext:SetHeight(RAID_ROW_H)
      row.nametext:SetJustifyH("LEFT")
      row.nametext:SetWordWrap(false)
      row.targeticon = row.namebox:CreateTexture(nil, "ARTWORK")
      row.targeticon:SetSize(TARGET_SIZE, TARGET_SIZE)
      row.targeticon:SetPoint("LEFT", row.nametext, "RIGHT", KUI.INTERNAL_GAP, 0)
      row.targeticon:SetTexture(KRP.MARK_TEXTURE)
      row.targeticon:Hide()

      -- Placed by konfer:PackRowRight as the row is drawn, the markers as wide as their words.
      row.osrole = KUI:CreateRoleIcon(row, 12)
      row.msrole = KUI:CreateRoleIcon(row, 12)
      row.marks = row:CreateFontString(nil, "ARTWORK", RAID_FONT)
      row.marks:SetJustifyH("RIGHT")

      -- The ready check's answer, at the right of the row past its box and the bar, on a frame of its own as the marks are.
      local ready = KUI.MakeFrame("Frame", nil, lframe)

      ready:SetSize(READY_SIZE, RAID_ROW_H)
      ready:SetPoint("LEFT", row, "RIGHT", ret:CheckStrip() + KUI.SCROLLBAR_COMPENSATE + 2, 0)
      ready:SetShown(row:IsShown())
      row:HookScript("OnShow", function()
        ready:Show()
      end)
      row:HookScript("OnHide", function()
        ready:Hide()
      end)
      row.readymarks = ready
      row.readyanswers = {}

      for rc, piece in pairs(READY_PIECES) do
        local mark = KUI:CreatePiece(ready, piece, { layer = "OVERLAY", part = "mark" })
        local mw, mh = mark:natural()
        local box = mark:Box()

        box:SetSize(READY_SIZE * mw / mh, READY_SIZE)
        box:SetPoint("CENTER", ready, "CENTER", 0, 0)
        mark:Layout()
        mark:Hide()
        row.readyanswers[rc] = mark
      end

      row:HookScript("OnEnter", function(this)
        local cfg = konfer.apol and konfer.apol.cfg

        if (this.uid and cfg) then
          konfer:ShowUserTooltip(this, cfg, this.uid, true, "ANCHOR_LEFT")
        end
      end)
      row:HookScript("OnLeave", function(this)
        GameTooltip:Hide()
      end)

      -- A right click picks the raider as a left one does, and for a leader or an assistant puts up what can be done to them.
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      row:HookScript("OnClick", function(this, button)
        if (button == "RightButton") then
          raid_menu(client)
        end
      end)
    end,
    setitem = function(ret, idx, slot, row)
      local r = raidrows[idx]

      local shown = K.DisplayName(r.name)

      row.uid = r.uid
      row.nametext:SetText(((not r.online and "|cff808080") or K.ClassColorsEsc[r.class] or "|cffffffff") .. shown .. "|r")

      --
      -- The name as wide as its letters, or as wide as leaves the mark its room. Its letters are measured as this row draws
      -- them: KUI's measuring string stands outside the UI's scale, and at a scale under one a name drawn here is a pixel or
      -- two wider than it says, which cut the last letters of every name off.
      --
      local room = r.mark and (NAME_W - KUI.INTERNAL_GAP - TARGET_SIZE) or NAME_W

      row.nametext:SetWidth(min(ceil(row.nametext:GetUnboundedStringWidth()), room))

      -- Drawn by Kore, which can show a mark retail will not let it read (.mark 0).
      KRP:DrawMark(row.targeticon, r.name)

      if (ASSIGNED_ATLASES[r.assigned]) then
        row.assignedicon:SetAtlas(ASSIGNED_ATLASES[r.assigned])
      end

      row.assignedicon:SetShown(ASSIGNED_ATLASES[r.assigned] ~= nil)
      row.marks:SetText(r.markers)
      konfer:SetPersonRoleIcons(row.msrole, row.osrole, r.kuid)
      konfer:PackRowRight(row.cells.name, row.osrole, row.msrole, row.marks)
      show_icon(row.rankicon, RANK_ICONS[r.rank])
      show_icon(row.mroleicon, ROLE_ICONS[r.mrole])

      if (row.looticon) then
        show_icon(row.looticon, r.ml and LOOT_ICON or nil)
      end

      for _, c in ipairs(columns) do
        if (c.key ~= "name" and not c.hidden) then
          local v = r[c.key]

          row:SetCell(c.key, (v == nil) and "" or (c.format and strfmt(c.format, v)) or tostring(v))
        end
      end

      for rc, mark in pairs(row.readyanswers) do
        mark:SetShown(r.ready == rc)
      end
    end,
    selectitem = function(ret, idx, slot, row, onoff)
      if (onoff and raidrows[idx]) then
        client.selected = raidrows[idx].name
      elseif (onoff == nil) then
        client.selected = nil
      end

      client.sync()
    end,
  }, lframe)

  list:Catch("OnSort", function()
    show_raid_rows(client)
  end)
  list:Catch("OnItemChecked", function(this, evt, idx, checked)
    if (raidrows[idx]) then
      client.ticked[raidrows[idx].name] = checked or nil
      tell_tick(client, raidrows[idx], checked)
      client.sync()
    end
  end)

  client.raiders = list
  client.columns = columns

  --
  -- The role filter, centred at the top of the page over the list, and only for the config's admins (filtered_rows), the
  -- list starting at the top of the page for anybody else (client.sync).
  --
  client.rolefilter = KUI:CreateRadioGroup({
    x = 0, y = 0, spacing = KUI.INTERNAL_GAP, initialvalue = "all", font = "GameFontWhiteTiny2",
    items = {
      { text = L["All"], value = "all" },
      { text = L["Tank"], value = "tank" },
      { text = L["Healer"], value = "healer" },
      { text = L["DPS"], value = "damage" },
      { text = L["Melee"], value = "melee" },
      { text = L["Ranged"], value = "ranged" },
      { text = L["Caster"], value = "caster" },
    },
  }, client)
  client.rolefilter:ClearAllPoints()
  client.rolefilter:SetPoint("TOP", client, "TOP", 0, 0 - KUI.WIDGET_GAP)
  client.rolefilter:Hide()
  client.rolefilter:Catch("OnValueChanged", function()
    raidrows = filtered_rows(client)
    show_raid_rows(client)
  end)

  --
  -- The buttons, two rows centred across the foot of the page. Rate is about the raider picked, Ready check and Broadcast
  -- about the whole group, and Selected, a dropdown of what can be done to every raider ticked (selected_items), counts them.
  -- Selected is the config's admins' alone, always there for them and lit only while there are any ticked, and so is Consent,
  -- there where the game has no master loot (lay_top_row). For anybody else the row is the other three, centred. The second
  -- row is the active policy's own buttons with Remove among them, which takes the raider picked out of the group, asking
  -- first (lay_second_row). Broadcast sends the config to the raid, for whoever missed what it holds as it happened. Each is
  -- lit only while it can do something (client.sync).
  --
  client.btnw = RAID_BTN_W
  client.selw = max(RAID_BTN_W, KUI:DropDownWidth({ strfmt(L["Selected (%d)"], 40) }, "GameFontNormalSmallLeft"))

  local function button(row, x, text, tip, click)
    local b = KUI:CreateButton({ x = x, y = 0, width = client.btnw, height = RAID_BTN_H, text = text,
      tooltip = { title = "$$", text = tip }, enabled = false }, row)

    b:Catch("OnClick", click)
    return b
  end

  local top = KUI.MakeFrame("Frame", nil, client.buttons)

  top:SetSize(client.btnw, RAID_BTN_H)
  top:SetPoint("TOP", client.buttons, "TOP", 0, 0)
  client.toprow = top

  client.ratebtn = button(top, 0, L["Rate"], L["TIP_USER_RATE"], function()
    local r = selected_raider(client)

    if (r) then
      konfer:RateUser(r.kuid)
    end
  end)

  client.readybtn = button(top, client.btnw + KUI.WIDGET_GAP, L["Ready check"], L["TIP_RAID_READYCHECK"], function()
    KRP:StartReadyCheck()
  end)

  -- Its tooltip is the active policy's word for what a broadcast takes to the raid (RAID_BROADCAST).
  client.bcastbtn = button(top, 2 * (client.btnw + KUI.WIDGET_GAP), L["Broadcast"], L["TIP_RAID_BROADCAST"], function()
    local pp = konfer.apol
    local cfg = pp and pp.cfg

    if (konfer:MayBroadcast(cfg)) then
      cfg:Broadcast(false)
      pp:info(L["Broadcast sent! Please do not broadcast again for at least 30 seconds."])
    end
  end)

  -- The collecting leader's, starting the takeover of the group's rolls and asking again of whoever has not consented.
  client.consentbtn = button(top, 0, L["Consent"], L["TIP_RAID_CONSENT"], function()
    konfer:AskConsent()
  end)
  client.consentbtn:Hide()

  client.selectedmenu = KUI:CreateDropDown({ x = 0, y = 0, name = "KonferRaidSelectedMenu",
    mode = "MULTI", dwidth = client.selw, itemheight = 16, items = KUI.emptydropdown,
    title = { text = strfmt(L["Selected (%d)"], 0) }, tooltip = { title = L["Selected"], text = L["TIP_RAID_SELECTED"] } },
    top)
  client.selectedmenu:Hide()
  client.selectedmenu.dropdown:HookScript("OnHide", function()
    C_Timer.After(0, function()
      refill_selected(client)
    end)
  end)

  local bottom = KUI.MakeFrame("Frame", nil, client.buttons)

  bottom:SetSize(client.btnw, RAID_BTN_H)
  bottom:SetPoint("TOP", client.buttons, "TOP", 0, 0 - RAID_BTN_H - KUI.WIDGET_GAP)
  client.bottomrow = bottom

  --
  -- Remove asks first, in the active policy's words for what taking somebody out of the raid loses (RAID_REMOVE), and the
  -- policy is told of a raider the config holds once they are gone (RaidPage.Removed).
  --
  client.removebtn = button(bottom, 0, L["Remove"], L["TIP_RAID_REMOVE"], function()
    local pp = konfer.apol
    local r = selected_raider(client)

    if (not r) then
      return
    end

    K.ConfirmationDialog(konfer, { text = L["Remove"], owner = pp }, pp:Str("RAID_REMOVE"),
      { L["Raider: %s"], K.DisplayName(r.name) }, function(_, name)
        local pol = konfer.apol
        local rp = pol.RaidPage
        local uid = pol.cfg and pol.cfg:FindUser(name)

        if (uid and rp and rp.Removed) then
          konfer:PolicyHook(pol, "RaidPage.Removed", nil, rp.Removed, pol.cfg.id, uid)
        end

        KRP:RemoveFromGroup(name)
      end, r.name, konfer.mainwin, 140)
  end)

  lay_second_row(client, nil)

  --
  -- Rate wants somebody Kore knows. Ready check is a leader's or an assistant's, while no check is running. Broadcast is the
  -- Sync page's, an admin's whom the raid will take it from and not while the last broadcast's wait runs. Remove wants
  -- somebody else whom this character may take out, which for a leader is anybody and for an assistant anybody holding no
  -- rank. Consent wants the leader (konfer:MayCollect). Selected wants a tick, and its items say for themselves what each
  -- can do. Each of the policy's own buttons is lit as it says (RaidPage.buttons), and dark without a config.
  --
  client.sync = function()
    local pp = konfer.apol
    local r = selected_raider(client)
    local cfg = pp and pp.cfg
    local admin = (cfg and cfg:MyStatus()) and true or false
    local lead = KRP.is_rl or (not KRP.in_raid and KRP.is_pl)
    local ticked = 0

    -- The boxes and the role filter are an admin's, and the ticks go when this character stops being one.
    if (admin ~= client.checking) then
      client.checking = admin
      client.rolefilter:SetShown(admin)

      if (admin) then
        client.raiders:ShowItemCheck(nil)
        client.listframe:SetPoint("TOP", client.rolefilter, "BOTTOM", 0, 0 - KUI.WIDGET_GAP)
      else
        client.ticked = {}
        client.raiders:HideItemCheck(nil)
        client.listframe:SetPoint("TOP", client, "TOP", 0, 0 - KUI.WIDGET_GAP)
      end
    end

    -- Selected counts those ticked whom the filter shows, and acts on them alone.
    for _, row in ipairs(raidrows) do
      if (client.ticked[row.name]) then
        ticked = ticked + 1
      end
    end

    client.ratebtn:SetEnabled((r and r.kuid and KU:Record(r.kuid)) and true or false)
    client.readybtn:SetEnabled((may_ready_check()) and true or false)
    client.bcastbtn:SetEnabled(konfer:MayBroadcast(cfg))
    client.consentbtn:SetEnabled(konfer:MayCollect())
    lay_top_row(client, admin)
    client.selectedmenu:SetText(strfmt(L["Selected (%d)"], ticked))
    client.selectedmenu:SetEnabled(ticked > 0)
    refill_selected(client)
    client.removebtn:SetEnabled((r and r.name ~= K.player.name and (lead or (KRP.is_aorl and r.rank == 0))) and true
      or false)

    for _, b in ipairs((pp and pp.RaidPage and pp.RaidPage.buttons) or {}) do
      local btn = (b ~= "remove") and pp.raidbuttons and pp.raidbuttons[b.name]

      if (btn) then
        local lit = false

        if (cfg and b.Enabled) then
          local _, on = konfer:PolicyHook(pp, "RaidPage.buttons.Enabled", false, b.Enabled, cfg.id, r, admin)

          lit = on
        end

        btn:SetEnabled(lit and true or false)
      end
    end
  end
end

--
-- A POLICY'S OWN PART
--
-- The active policy's own buttons on the second row (RaidPage.buttons) and its own tabs after Raiders (RaidTabs), there
-- while it is the active one and gone when it stops being, as the Lists and Config pages' tabs are. Each tab is named with
-- the policy's prefix, and one taken away is retired rather than destroyed, so that adding it again brings back what was
-- built. Nothing on one is held for saving.
--
local function raid_tab(pp, i, t)
  return {
    name = pp.prefix .. t.name, text = t.text, order = t.order or (10 + i), savebar = false, hsplit = t.hsplit,
    adminonly = t.adminonly, owneronly = t.owneronly,
  }
end

function konfer:ShowRaidPolicyUI(pp, onoff)
  local client = raidclient

  for i, t in ipairs(pp.RaidTabs or {}) do
    if (onoff) then
      self.mainwin:AddTab(self.RAID_PAGE, raid_tab(pp, i, t))
    else
      self.mainwin:RemoveTab(self.RAID_PAGE, pp.prefix .. t.name)
    end
  end

  for _, b in pairs(pp.raidbuttons or {}) do
    b:SetShown(onoff)
  end

  if (onoff) then
    client.bcastbtn.tiptext = pp:Str("RAID_BROADCAST")
    lay_second_row(client, pp)
  end
end

--
-- Build PP's buttons and tabs, once, from konfer:BuildPolicyUI, and take them away again until PP is the active policy.
-- Each button is kept in pp.raidbuttons by its name, and each tab's content frame in pp.raidtabs by the tab's, for its
-- Refresh.
--
function konfer:BuildRaidPolicyUI(pp)
  local client = raidclient
  local rp = pp.RaidPage
  local kmt = self.mainwin:GetPage(self.RAID_PAGE)

  pp.raidbuttons = {}
  pp.raidtabs = {}

  for _, b in ipairs((rp and rp.buttons) or {}) do
    if (b ~= "remove") then
      local btn = KUI:CreateButton({ x = 0, y = 0, width = client.btnw, height = RAID_BTN_H, text = b.text,
        tooltip = { title = "$$", text = b.tip }, enabled = false }, client.bottomrow)

      btn:Catch("OnClick", function()
        local pol = konfer.apol

        if (pol.cfg and b.Click) then
          konfer:PolicyHook(pol, "RaidPage.buttons.Click", nil, b.Click, pol.cfg.id, selected_raider(client))
        end
      end)
      pp.raidbuttons[b.name] = btn
    end
  end

  for i, t in ipairs(pp.RaidTabs or {}) do
    local tab = raid_tab(pp, i, t)

    self.mainwin:AddTab(self.RAID_PAGE, tab)

    local rec = { def = t, client = kmt.tabsbyname[tab.name].content }

    pp.raidtabs[t.name] = rec
    self:PolicyHook(pp, "RaidTabs.Construct", nil, t.Construct, rec.client)
  end

  self:ShowRaidPolicyUI(pp, false)
end

--
-- Draw the page again for the active policy: its title, the columns it shows, the list sorted as it says where that has
-- changed, everybody in the group, and its own tabs that have a Refresh.
--
-- The policy's columns are shown and the rest hidden, and the list's frame is made as wide as the Name column and those,
-- the gaps between them, the strip for the boxes and the scroll bar's strip past it.
-- When what the policy shows has changed, or the column the list was sorted on has gone, the list starts again sorted the
-- way it says; otherwise whatever the player sorted it by stands.
--
function konfer:RefreshRaidUI()
  local client = raidclient
  local pp = self.apol

  if (not client or not pp) then
    return
  end

  local rp = pp.RaidPage
  local cfg = pp.cfg
  local list = client.raiders
  local title = nil
  local shown, first, upward = {}, nil, true

  if (cfg and rp and rp.title) then
    local _, t = self:PolicyHook(pp, "RaidPage.title", nil, rp.title, cfg.id)

    title = t
  end

  self.mainwin:SetPageTitle(self.RAID_PAGE, pp:WindowTitle(title or L["Raid manager"]))

  if (cfg and rp and rp.Columns) then
    local _, s, f, u = self:PolicyHook(pp, "RaidPage.Columns", nil, rp.Columns, cfg.id)

    shown, first, upward = (type(s) == "table") and s or {}, f, u and true or false
  end

  -- A finished ready check's answers go READY_SHOWN seconds after it ended, and the page is drawn again then, once a check.
  if (KRP.ready_ended and not KRP.ready_checking and client.readyended ~= KRP.ready_ended) then
    local left = KRP.ready_ended + READY_SHOWN - GetTime()

    client.readyended = KRP.ready_ended

    if (left > 0) then
      K:ScheduleTimer(function()
        konfer:RefreshPolicyPages()
      end, left)
    end
  end

  local mine = {}

  for _, c in ipairs((rp and rp.columns) or {}) do
    mine[policy_key(pp, c.key)] = shown[c.key] and true or false
  end

  for _, c in ipairs(client.columns) do
    if (c.key ~= "name") then
      c.hidden = not mine[c.key]
      list:SetColumnShown(c.key, mine[c.key])
    end
  end

  local width, ncols = list:CheckStrip() + KUI.SCROLLBAR_COMPENSATE, 0

  for _, col in ipairs(list.columns) do
    if (not col.hidden) then
      width = width + col.w
      ncols = ncols + 1
    end
  end

  client.listframe:SetWidth(width + (ncols - 1) * KUI.COLUMN_GAP)

  local key = list:GetSort()
  local sortkey = first and policy_key(pp, first)
  local shape = pp.handle .. ":" .. tostring(first) .. ":" .. tostring(upward)

  if (client.shape ~= shape or (key ~= "name" and not mine[key])) then
    client.shape = shape
    list:SetSort(sortkey or "name", sortkey == nil or upward, false)
  end

  grouprows = raid_rows()
  raidrows = filtered_rows(client)
  show_raid_rows(client)

  for _, t in ipairs(pp.RaidTabs or {}) do
    local rec = pp.raidtabs and pp.raidtabs[t.name]

    if (rec and t.Refresh) then
      self:PolicyHook(pp, "RaidTabs.Refresh", nil, t.Refresh, rec.client)
    end
  end
end
