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
local KU = K.Users
local KRP = konfer.KRP
local L = konfer.L
local KUI = konfer.KUI
local MakeFrame = KUI.MakeFrame
local cfgm = konfer.configmethods

-- Local aliases for global or Lua library functions
local _G = _G
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local tostring, tonumber = tostring, tonumber
local strfmt = string.format
local strfind = string.find
local strlower = string.lower
local max = math.max
local pairs, ipairs, next = pairs, ipairs, next
local assert = assert
local wipe = wipe

local white = konfer.white
local green = konfer.green
local red = konfer.red
local class = konfer.class
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
-- This page's widget handles. There is one window and it shows the active policy, so there is one of these. What it holds is
-- about the page rather than about any policy, and is put back from the active policy's config whenever that config changes.
--
local qf = { shownusers = {}, checkedusers = {} }

local HIST_WHEN = konfer.HIST_WHEN
local HIST_WHAT = konfer.HIST_WHAT
local HIST_WHO = konfer.HIST_WHO
local HIST_HOW = konfer.HIST_HOW

local USER_CLASS = KU.USER_CLASS
local USER_PPROF = KU.USER_PPROF
local USER_SPROF = KU.USER_SPROF
local USER_MSROLE = KU.USER_MSROLE
local USER_OSROLE = KU.USER_OSROLE
local USER_RACE = KU.USER_RACE
local USER_LEVEL = KU.USER_LEVEL

local CU_KUID      = konfer.CFGUSER_KUID
local CU_ENCHANTER = konfer.CFGUSER_ENCHANTER
local CU_FROZEN    = konfer.CFGUSER_FROZEN
local CU_PDATA     = konfer.CFGUSER_PDATA

--
-- This file contains all of the UI handling code for the users panel, as well as all user manipulation functions.
--

--
-- The fields of the user info panel, which are the keys the page's unsaved changes are kept under: this config's two flags,
-- and the character's own specs, professions and main from Kore's shared block. The policy's own section keeps its one
-- field, pdata, under the same changes.
--
local SHARED_FIELDS = { "msspec", "osspec", "pprof", "sprof", "main" }

--
-- What is stored for field KEY of the user the page's changes are to, which is the user selected when they were made.
--
local function user_saved(key)
  local pp = konfer.apol
  local uid = qf.userpending and qf.userpending.picked

  if (not uid or not pp or not pp.cfg) then
    return nil
  end

  local ent = pp.cfg.uids[uid]
  local kuid = ent and ent[CU_KUID]

  if (key == "enchanter") then
    return pp.cfg:IsEnchanter(uid) or false
  elseif (key == "frozen") then
    return pp.cfg:IsFrozen(uid) or false
  elseif (key == "pdata") then
    return pp.cfg:UserPData(uid)
  elseif (key == "msspec" or key == "osspec") then
    local ms, os = KU:Roles(kuid)

    return (key == "msspec") and ms or os
  elseif (key == "pprof" or key == "sprof") then
    local pr, sc = KU:Professions(kuid)

    return (key == "pprof") and pr or sc
  elseif (key == "main") then
    --
    -- The main is the mod's one link rather than this config's, so it is what is held about the character whether or not
    -- this config has them, as the main's KUID. Whether there is a uid here to tether to is cfg:IsAlt, and that is what the
    -- lists and the loot ask.
    --
    return KU:Main(kuid) or ""
  end

  return nil
end

--
-- The shared block's fields as they stand on screen, unsaved changes included, which is the form qf.shared:SetValues takes.
--
local function shared_values()
  local vals = {}

  for _, f in ipairs(SHARED_FIELDS) do
    vals[f] = qf.userpending:Value(f)
  end

  return vals
end

--
-- Put the selected user's fields on screen, unsaved changes included, without any of the widgets throwing.
--
local function show_user()
  local ups = qf.userpending

  qf.useropts.enchanter:SetChecked(ups:Value("enchanter"), true)
  qf.useropts.frozen:SetChecked(ups:Value("frozen"), true)
  qf.shared:SetValues(shared_values())
end

local function hide_popup()
  if (konfer.popupwindow) then
    konfer.popupwindow:Hide()
    konfer.popupwindow = nil
  end
end

--
-- Refresh the lists the selected user is on, and where they stand on each, into qf.umemdata. Where somebody stands is the
-- policy's, so it is their place in the policy's order as the policy's PositionText words it, as the Lists page shows it.
--
local function refresh_user_membership(self)
  local pp = konfer.apol
  local uid = qf.selected_user

  if (uid) then
    local umemdata = {}

    if (pp.sortedlists and #pp.sortedlists > 0) then
      for k,v in ipairs(pp.sortedlists) do
        local list = pp.cfg.lists[v.id]
        local inlist, luid = pp.cfg:UserOrAltInList(uid, v.id)
        if (inlist) then
          local ts = green(list.name)

          if (luid ~= uid) then
            ts = ts .. " (" .. shortaclass(pp.cfg:UserNameClass(luid)) .. ")"
          end

          local pos = pp.cfg:ListPosition(luid, v.id)
          local _, standing = pp.cfg:PolicyCall("PositionText", tostring(pos), v.id, luid, pos)

          tinsert(umemdata, strfmt("%s [%s]", ts, tostring(standing)))
        else
          tinsert(umemdata, red(list.name))
        end
      end
    end
    qf.umemdata = umemdata
    qf.umemlist.itemcount = #umemdata
  else
    qf.umemdata = nil
    qf.umemlist.itemcount = 0
  end
  qf.umemlist:UpdateList()
end

--
-- User info and the lists a user is on read as disabled, their titles dimmed, while no user is selected. Called wherever the selection changes.
--
local function sync_user_panels()
  local hasuser = qf.selected_user ~= nil

  if (qf.userinfopanel) then
    qf.userinfopanel:SetEnabled(hasuser)
    qf.userlistspanel:SetEnabled(hasuser)
    qf.policypanel:SetEnabled(hasuser)
  end
end

--
-- Tell the policy's own section which user is selected, if it has a section and wants to know. It is handed the frame it
-- built into, so that it can find its own widgets on it, and what it keeps about them as it stands on screen, unsaved
-- changes included. That is a copy, so the policy changing it changes nothing until it says so.
--
local function user_selection()
  local pp = konfer.apol
  local up = pp and pp.UsersPage

  if (up and up.UserSelection and pp.usersframe) then
    local pdata = qf.selected_user and qf.userpending:Value("pdata")

    if (type(pdata) == "table") then
      pdata = K.CopyTable(pdata, {})
    end

    konfer:PolicyHook(pp, "UsersPage.UserSelection", nil, up.UserSelection, pp.usersframe, pp.currentid, qf.selected_user,
      pdata)
  end
end

local function enable_selected(en)
  qf.usertopbar.seluser:SetShown(en)
  qf.useropts.enchanter:SetEnabled(en)
  qf.useropts.frozen:SetEnabled(en)
  qf.shared:SetEnabled(en)
  qf.userbuttons.deletebutton:SetEnabled(en)
  qf.userbuttons.ratebutton:SetEnabled(en)
end

--
-- The users this page offers as a main, by KUID, which is the config's own mains. A main has to be somebody this config
-- holds, so offering anybody else would be offering a link that cannot be made. The one link itself is the mod's, and Kore's
-- user editor, which has no config in hand, offers every main there is.
--
-- The policy is read when the list is asked for rather than when this is built. The page is built once and the policy under
-- it changes, so a policy captured here would go on offering the mains of a config nobody is looking at.
--
local function config_mains()
  return function(exclude)
    local pp = konfer.apol
    local kuids = {}

    for k, v in ipairs((pp and pp.sortedusers) or {}) do
      local ent = pp.cfg.uids[v.id]
      local kuid = ent and ent[CU_KUID]

      if (kuid and not v.main and kuid ~= exclude) then
        tinsert(kuids, kuid)
      end
    end

    return kuids
  end
end

--
-- A scroll list hands its callbacks a fixed set of arguments and none of them says which policy's list was clicked, so the
-- widget table is bound in by whoever built the list rather than looked up here.
--
local function users_selectitem(objp, idx, slot, btn, onoff)
  local pp = konfer.apol
  local onoff = onoff or false

  local ups = qf.userpending

  hide_popup()
  enable_selected(onoff)

  -- The page's unsaved changes are to the one user selected. See PS.Pick.
  local picked = onoff and qf.shownusers[idx] and qf.shownusers[idx].id or nil

  ups:Pick(picked)

  if (onoff) then
    qf.selected_user = picked

    if (pp.cfg.owner == qf.selected_user) then
      qf.userbuttons.deletebutton:SetEnabled(false)
    end

    qf.usertopbar.SetCurrentUser(qf.selected_user)
    qf.shared:SetUser(pp.cfg.uids[qf.selected_user][CU_KUID])
    show_user()
  else
    qf.selected_user = nil
  end

  refresh_user_membership(konfer)
  sync_user_panels()
  user_selection()
end

--
-- What the platform adds to Kore's create user dialog under the standard fields: whether the new user is a raid enchanter,
-- which is this config's word on them in every policy, and under that whatever the policy adds of its own through its
-- UsersPage.CreateConstruct (see Policy.lua). Ticking the box fills enchanting into an empty profession slot, as the page's
-- own box does. The box is put back each time the dialog opens by create_user_button, leaving the dialog's OnShow to the policy.
--
local function create_user_extra(pp)
  return function(dlg, ypos)
    dlg.enchanter = KUI:CreateCheckBox({
      x = dlg.x, y = ypos, label = { text = L["Raid enchanter"] },
      tooltip = { title = "$$", text = L["TIP075"] },
    }, dlg)

    dlg.enchanter:Catch("OnValueChanged", function(this, evt, val, user)
      dlg.entry.enchanter = val and true or false

      if (not val or not user) then
        return
      end

      local pprof = dlg.shared.pprof:GetValue() or K.PROF_UNSET
      local sprof = dlg.shared.sprof:GetValue() or K.PROF_UNSET

      if (pprof ~= K.PROF_ENCHANTING and sprof ~= K.PROF_ENCHANTING) then
        if (pprof == K.PROF_UNSET) then
          dlg.shared.pprof:SetValue(K.PROF_ENCHANTING)
        elseif (sprof == K.PROF_UNSET) then
          dlg.shared.sprof:SetValue(K.PROF_ENCHANTING)
        end
      end
    end)

    ypos = ypos - dlg.enchanter:GetHeight() - KUI.WIDGET_GAP

    local cc = pp.UsersPage and pp.UsersPage.CreateConstruct

    if (cc) then
      local _, y = konfer:PolicyHook(pp, "UsersPage.CreateConstruct", nil, cc, dlg, ypos)

      ypos = y or ypos
    end

    return ypos
  end
end

--
-- The create user dialog belongs to the policy rather than to the page. What a policy adds to it is built into the dialog
-- itself and cannot be taken out again, WoW having no way to destroy a frame, so one dialog shared between policies would
-- carry one policy's fields into another's. Each policy gets its own, made the first time somebody creates a user under it
-- and never for a policy where nobody does.
--
local function create_user_button(self)
  local pp = konfer.apol

  if (not pp.createuserdlg) then
    pp.createuserdlg = KU:CreateUserDialog({
      name = pp.prefix .. "KonferCreateUserDlg",
      mains = config_mains(),
      owner = pp,
      err = function(...)
        pp:err(...)
      end,
      extra = create_user_extra(pp),
      accept = function(dlg, info)
        local cfg = pp.cfg
        local known = KU:Find(info.name)

        --
        -- Somebody the mod knows already is not created again, as the user editor refuses them too: the class chosen here
        -- would be thrown away for the one already known, and every other fact with it. It is said in chat and the dialog
        -- stays up to be put right.
        --
        if (known) then
          pp:err(L["user %q already exists. Try again."], KU:String(known))
          dlg.username:SetFocus()
          return true
        end

        local uid = cfg:CreateNewUser(info.name, info.class)

        if (not uid) then
          return true
        end

        local msspec, osspec = info.msspec, info.osspec
        local pprof, sprof = info.pprof, info.sprof
        local mainkuid = info.main or ""

        --
        -- The rest of the new user goes out as one MDUSR carrying every field, exactly as the Update button sends it. The
        -- specs and professions have no event of their own, and a new user is never frozen.
        --
        local kuid = cfg.uids[uid][CU_KUID]
        local ench = dlg.entry.enchanter and true or false
        local mainid = (mainkuid ~= "") and cfg:FindKuid(mainkuid) or ""

        cfg:SetUserEnchanter(uid, ench, true)
        cfg:SetUserPData(uid, dlg.entry.pdata, true)
        KU:SetRoles(kuid, msspec, osspec)
        KU:SetProfessions(kuid, pprof, sprof)
        -- Must be last! It does refreshes of its own.
        local linked, why = cfg:SetUserIsAlt(uid, mainid ~= "", mainid, true)

        if (not linked and why) then
          pp:err("%s", why)
        end

        cfg:SendUserModified(uid)
      end,
    })

    pp.createuserdlg:Catch("OnHide", function(this, evt)
      qf.mainwin:Show()
    end)
  end

  qf.mainwin:Hide()
  pp.createuserdlg.enchanter:SetChecked(false, true)
  pp.createuserdlg:Open()
end

local function delete_user_button(self, uid)
  local pp = konfer.apol

  pp.cfg:DeleteUserCmd(uid)
end

--
-- The player's own notes on the person KUID, the ratings and note Kore's user editor shows (KU:CreateNotesDialog), so that
-- rating somebody does not mean leaving for the editor. The notes are the player's on a person, whatever policy or page they
-- were reached from, so there is one dialog for all of them, plated with Konfer in its brackets and no policy's name. The
-- window stands aside while it is up, as it does for Create, and coming back shows the policy's own section on the Users page
-- the notes as they now are. Every policy's Users page opens it with Rate, and so does the Raid page.
--
function konfer:RateUser(kuid)
  if (not kuid or not KU:Record(kuid)) then
    return
  end

  if (not qf.notesdlg) then
    qf.notesdlg = KU:CreateNotesDialog({ name = "KonferNotesDlg", owner = L["MODTITLE"] })
    qf.notesdlg:Catch("OnHide", function(this, evt)
      qf.mainwin:Show()
      user_selection()
    end)
  end

  qf.mainwin:Hide()
  qf.notesdlg:Open(kuid)
end

local function rate_user_button(self, uid)
  local ent = uid and konfer.apol.cfg.uids[uid]

  if (ent) then
    konfer:RateUser(ent[CU_KUID])
  end
end

--
-- A policy's Users page imports into its own config: each member is added to it unless they are in it already, and once the
-- dialog closes having added anybody the raid is told to refresh its users. The window stands aside while the dialog is up.
--
local function guild_import_button(self, shown)
  local pp = konfer.apol

  local function onadd(kuid, class)
    local name = KU.kuids[kuid]

    if (pp.cfg:FindKuid(kuid)) then
      return false
    end

    if (not pp.cfg:CreateNewUser(name, class, true)) then
      pp:err(L["error adding user %q!"], white(K.DisplayName(name)))
      return false
    end

    return true
  end

  local function onclose(count)
    if (shown) then
      qf.mainwin:Show()
    end

    if (not count) then
      return
    end

    if (count > 0) then
      self:RefreshUsers()
      self:RefreshRaid()
      pp:CSendChannelAM(pp.currentid, "RFUSR", "ALERT")
    end

    pp:info(L["added %d user(s)."], count)
  end

  KU:OpenGuildImport(onadd, onclose, pp)
  qf.mainwin:Hide()
end

--
-- Raise the guild import dialog on the Users page. The users it imports go into the config the page is showing, which is the
-- active policy's, that being the only config the window ever has in hand.
--
-- SHOWN says whether the window was up when this was asked for, because the
-- dialog puts the window away and has to know whether to put it back.
--
function konfer:ImportGuildUsers(shown)
  guild_import_button(self, shown)
end

--
-- If we are in raid, add all of the current users who are missing to the users database.
--
local function add_missing_button(self)
  local pp = konfer.apol

  -- Who is missing is worked out against the active policy's config, so only its window has anybody to add.
  if (pp ~= self.apol or not self.raid.uidmap or not self:PolicyAdmin(pp) or not self.raid.nmissing or self.raid.nmissing == 0) then
    return
  end

  --
  -- Each missing member once, from a copy, since creating one takes them out of the table being walked. Somebody who has
  -- turned up in the config since the raid was last counted is simply no longer missing.
  --
  local todo = {}

  for k, v in pairs(self.raid.missing) do
    tinsert(todo, { name = v.name, class = v.class })
  end

  for k, v in ipairs(todo) do
    if (pp.cfg:FindUser(v.name)) then
      if (self.raid.missing[v.name]) then
        self.raid.missing[v.name] = nil
        self.raid.nmissing = self.raid.nmissing - 1
      end
    else
      pp.cfg:CreateNewUser(v.name, v.class, true, true)
    end
  end
  self:RefreshUsers()
  self:RefreshRaid()
  pp:CSendChannelAM(pp.currentid, "RFUSR", "ALERT")
end

--
-- THE FILTER
--
-- The page's list shows the users its filter lets through, in pp.sortedusers' order: everybody, or those who play one kind
-- of role, tank, healer or damage as KUI:RoleIconKind groups them, in their main spec alone or in either spec, and for
-- damage only the kinds of it ticked, melee, ranged or caster (qf.dpsfilter). An alt let through whose main is not stands
-- on his own. It is the page's for the session, saved nowhere, and pp.sortedusers stays everybody, for the dropdowns that
-- offer them. qf.shownusers is what the list shows, the same entries.
--
local function user_shown(cfg, uid)
  local kind = qf.rolefilter and qf.rolefilter:GetValue()

  if (not kind or kind == "all") then
    return true
  end

  local ent = cfg.uids[uid]
  local ms, os = KU:Roles(ent and ent[CU_KUID])

  local function counts(role)
    local box = qf.dpsfilter[role]

    return KUI:RoleIconKind(role) == kind and (not box or box:GetChecked()) and true or false
  end

  return counts(ms) or (not qf.specfilter:GetChecked() and counts(os))
end

local function filter_users(pp)
  local out = {}
  local main, lastalt

  for _, v in ipairs(pp.sortedusers) do
    if (not v.main) then
      if (lastalt) then
        lastalt.tree = "end"
        lastalt = nil
      end

      main = nil
    end

    if (user_shown(pp.cfg, v.id)) then
      local e = { id = v.id, main = v.main }

      if (not v.main) then
        main = v.id
      elseif (v.main == main) then
        e.tree = "branch"
        lastalt = e
      end

      tinsert(out, e)
    end
  end

  if (lastalt) then
    lastalt.tree = "end"
  end

  return out
end

--
-- THE TICKS
--
-- An admin of the config in a party or a raid can tick users in the list, which is a KUI check list with a box at the right
-- of every row, and while any are ticked the Invite button under the list asks the game to invite those of them who are not
-- in the group. The ticks are the page's for the session, saved nowhere, kept by uid through the filter, and forgotten
-- when the config changes or the boxes go. The list keeps the boxes' room always, the boxes coming and going with the group.
--
local CHECK_SIZE = 10

--
-- The users the list shows and has ticked who are not in the group, by name. A tick on somebody the filter hides is kept,
-- for when they are shown again, and invites nobody meanwhile.
--
local function ticked_outside()
  local cfg = konfer.apol and konfer.apol.cfg
  local out = {}

  for _, v in ipairs(qf.shownusers) do
    local name = qf.checkedusers[v.id] and cfg and cfg:UserName(v.id)

    if (name and not (KRP.players and KRP.players[name])) then
      tinsert(out, name)
    end
  end

  tsort(out)

  return out
end

--
-- The box over the others ticked only while everybody the list shows is, and Invite up while there is anybody to invite,
-- saying how many it would invite of how many the list shows ticked, and lit while this character may invite.
--
local function show_ticked()
  local all = #qf.shownusers > 0
  local out = #ticked_outside()
  local ticked = 0

  for _, v in ipairs(qf.shownusers) do
    if (qf.checkedusers[v.id]) then
      ticked = ticked + 1
    else
      all = false
    end
  end

  qf.tickall:SetChecked(all)
  qf.invitebutton:SetText(strfmt(L["Invite (%d/%d)"], out, ticked))
  qf.invitebutton:SetShown(out > 0)
  qf.invitebutton:SetEnabled(KRP:CanInvite() and true or false)
end

local function lay_out_ticks(pp)
  local on = (KRP.in_party and konfer:PolicyAdmin(pp)) and true or false
  local cfg = pp.cfg

  if (not on or cfg ~= qf.checkedcfg) then
    wipe(qf.checkedusers)
  end

  qf.checkedcfg = cfg

  for uid in pairs(qf.checkedusers) do
    if (not cfg.uids[uid]) then
      qf.checkedusers[uid] = nil
    end
  end

  if (on ~= qf.userchecks) then
    qf.userchecks = on

    if (on) then
      qf.userlist:ShowItemCheck(nil)
    else
      qf.userlist:HideItemCheck(nil)
    end

    qf.tickall:SetShown(on)
  end

  show_ticked()
end

--
-- Fill the list with what the filter lets through and select again whoever was selected. A user the filter now hides is
-- deselected, and their unsaved changes go as they do when another user is picked.
--
local function fill_user_list(pp)
  local olduser = qf.selected_user
  local oldidx = nil

  qf.selected_user = nil
  qf.shownusers = filter_users(pp)
  lay_out_ticks(pp)

  for kk, v in ipairs(qf.shownusers) do
    if (v.id == olduser) then
      oldidx = kk
      break
    end
  end

  --
  -- Selecting the same user again keeps the page's unsaved changes to them, less any another admin has since replaced.
  -- A user no longer there takes them away with it.
  --
  qf.userpending:Hold()
  qf.userlist.itemcount = #qf.shownusers
  qf.userlist:UpdateList()
  qf.userlist:SetSelected(oldidx)
  qf.userpending:Release()

  if (qf.selected_user) then
    show_user()
  end
end

function konfer:InitialiseUsersUI()
  local arg
  local mainwin = self.mainwin

  qf.mainwin = mainwin

  --
  -- The page's unsaved changes, to the selected user. Saving writes this config's two flags and the character's own facts,
  -- and tells the other admins with one MDUSR however many were changed. It exists from the moment the page does, because a
  -- widget handler writes into it and a widget can be set before any user has been selected.
  --
  qf.userpending = self.mainwin:NewPending({
    page = self.USERS_PAGE,
    saved = user_saved,
    save = function(changes)
      local pp = konfer.apol
      local ups = qf.userpending
      local uid = ups.picked
      local cfg = pp and pp.cfg

      if (not uid or not cfg) then
        return
      end

      --
      -- Every field is written as it now stands, changed or not, the setters leaving alone what is already so. The alt
      -- link is set last, because it does refreshes of its own.
      --
      local function now(key)
        if (changes[key] ~= nil) then
          return changes[key]
        end

        return user_saved(key)
      end

      local kuid = cfg.uids[uid][CU_KUID]

      cfg:SetUserEnchanter(uid, now("enchanter"), true)
      KU:SetRoles(kuid, now("msspec"), now("osspec"))
      KU:SetProfessions(kuid, now("pprof"), now("sprof"))
      cfg:SetUserFrozen(uid, now("frozen"), true)
      cfg:SetUserPData(uid, now("pdata"), true)

      local main = now("main")
      local mainid = (main ~= "") and cfg:FindKuid(main) or ""
      local linked, why = cfg:SetUserIsAlt(uid, mainid ~= "", mainid, true)

      if (not linked and why) then
        pp:err("%s", why)
      end

      --
      -- Everything here is the character's, shown in every policy's window and in the user editor, which are all redrawn
      -- whether or not the alt link moved. RefreshUsers does the user editor too.
      --
      konfer:RefreshUsers()
      konfer:RefreshAllMemberLists()

      cfg:SendUserModified(uid)
    end,
    reload = function()
      konfer:RefreshUsers()
    end,
  })

  --
  -- Users tab. We have no sub-tabs so there is only one set of things to do here.
  --
  local ypos = 0

  local cf = mainwin:GetPage(self.USERS_PAGE).content
  local tbf = mainwin:GetPage(self.USERS_PAGE).topbar
  local ls = cf.vsplit.leftframe
  local rs = cf.vsplit.rightframe

  arg = {
    x = 0, y = self.TOPBAR_TEXT_Y, text = "", autosize = false, width = 250,
    font = "GameFontNormalSmall",
  }
  tbf.seluser = KUI:CreateStringLabel(arg, tbf)

  qf.usertopbar = tbf
  tbf.SetCurrentUser = function(userid)
    local pp = konfer.apol

    if (userid) then
      tbf.seluser:SetText(L["Currently Selected: "]..aclass(pp.cfg:UserNameClass(userid)))
    else
      tbf.seluser:SetText("")
    end
  end

  --
  -- Down the right, one under another: User info, exactly as tall as what it holds, the lists the user is on, room for
  -- USERLISTS_ROWS of them, and the buttons, exactly as tall as their two rows. What is left under them is the policy's own
  -- section, and empty and unbordered for a policy with none. The first two are one pane, whose height is known once User
  -- info has been built.
  --
  -- A policy whose UsersPage is compact gives its own section more room than that: the buttons go under the user list
  -- instead, and User info loses its divider (lay_out_for).
  --
  local USERLISTS_ROWS = 5
  local USERBTNS_H = 52     -- two 24 high rows of buttons and the gap between them
  local BTN_W = 95          -- the page's buttons, and how tall they are, Invite under the user list as tall
  local BTN_H = 24

  arg = {
    inset = 0, height = 0, topanchor = true,
    name = "KonferUserAdminRHSplit",
  }
  rs.hsplit = KUI:CreateHSplit(arg, rs)
  local tr = rs.hsplit.topframe
  local rsb = rs.hsplit.bottomframe

  arg = {
    inset = 0, height = USERBTNS_H, topanchor = true,
    name = "KonferUserAdminButtonsSplit",
    bottomborder = false, bottompadding = 0,
  }
  rsb.hsplit = KUI:CreateHSplit(arg, rsb)
  qf.buttonsplit = rsb.hsplit

  local br = rsb.hsplit.topframe

  --
  -- Down the left, the User list, unbordered, and under it the compact page's buttons. In the User list the filter stands
  -- along the top (THE FILTER), its two lines, the list under it, and a gap under the list's last row a foot line holds the
  -- search box, under the names, and against the right Invite for the users ticked (THE TICKS), the list stopping short of
  -- the panel's bottom to leave it room.
  --
  arg = {
    inset = 0, height = USERBTNS_H,
    name = "KonferUserAdminLHSplit",
    topborder = false,
  }
  ls.hsplit = KUI:CreateHSplit(arg, ls)
  qf.listsplit = ls.hsplit

  local ulc = ls.hsplit.topframe
  local bl = ls.hsplit.bottomframe

  --
  -- That pane is split again, User info above and under it a scrolling list of every list, the user on it or not.
  --
  arg = {
    inset = 0, name = "KonferUserAdminRTSplit",
    topanchor = true,
    toptitle = L["User info"],
    bottomtitle = {
      text = strfmt(L["User %s / %s lists"], green(L["on"]), red(L["not on"])),
      width = 240,
    },
  }
  tr.hsplit = KUI:CreateHSplit(arg, tr)
  qf.useropts = tr.hsplit.topframe
  qf.userinfopanel = tr.hsplit.topinset
  qf.userlistspanel = tr.hsplit.bottominset

  local ttr = qf.useropts
  local tmr = tr.hsplit.bottomframe

  --
  -- The filter: which kind of role, and under it whether the main spec alone counts, the off spec too when it is unticked,
  -- greyed while the first shows everybody, and beside that, with DPS picked, the kinds of damage it lets through, all of
  -- them to start with. The second line is one group centred over the list, laid out again as the kinds come and go.
  --
  ulc.rolefilter = KUI:CreateRadioGroup({
    x = 0, y = 0, spacing = KUI.INTERNAL_GAP, initialvalue = "all", font = "GameFontWhiteTiny2",
    items = {
      { text = L["All"], value = "all" },
      { text = L["Tank"], value = "tank" },
      { text = L["Healer"], value = "healer" },
      { text = L["DPS"], value = "damage" },
    },
  }, ulc)
  qf.rolefilter = ulc.rolefilter

  local filtery = 0 - ulc.rolefilter:GetHeight() - KUI.WIDGET_GAP

  ulc.specfilter = KUI:CreateCheckBox({
    x = 0, y = filtery, height = CHECK_SIZE, checked = true, enabled = false,
    label = { text = L["Main only"], font = "GameFontWhiteTiny2" },
  }, ulc)
  qf.specfilter = ulc.specfilter
  filtery = filtery - ulc.specfilter:GetHeight() - KUI.WIDGET_GAP

  local function refilter()
    if (konfer.apol and konfer.apol.cfg) then
      fill_user_list(konfer.apol)
    end
  end

  local specline = { ulc.specfilter }

  qf.dpsfilter = {}

  for _, dk in ipairs({ { K.ROLE_MELEE, L["Melee"] }, { K.ROLE_RANGED, L["Ranged"] }, { K.ROLE_CASTER, L["Caster"] } }) do
    local box = KUI:CreateCheckBox({
      x = 0, y = 0, height = CHECK_SIZE, checked = true, label = { text = dk[2], font = "GameFontWhiteTiny2" },
    }, ulc)

    box:Hide()
    box:Catch("OnValueChanged", refilter)
    qf.dpsfilter[dk[1]] = box
    tinsert(specline, box)
  end

  ulc.specline = MakeFrame("Frame", nil, ulc)
  ulc.specline:SetHeight(ulc.specfilter:GetHeight())

  local function lay_out_spec_line()
    local dps = ulc.rolefilter:GetValue() == "damage"
    local x = 0

    for i, box in ipairs(specline) do
      local on = (i == 1) or dps

      box:SetShown(on)

      if (on) then
        box:ClearAllPoints()
        box:SetPoint("LEFT", ulc.specline, "LEFT", x, 0)
        x = x + box:GetWidth() + KUI.INTERNAL_GAP
      end
    end

    ulc.specline:SetWidth(x - KUI.INTERNAL_GAP)
  end

  ulc.rolefilter:Catch("OnValueChanged", function(this, evt, value, user)
    ulc.specfilter:SetEnabled(value ~= "all")
    lay_out_spec_line()
    refilter()
  end)
  ulc.specfilter:Catch("OnValueChanged", refilter)

  local SEARCH_H = 20
  local FOOT_H = max(SEARCH_H, BTN_H)

  -- The list's frame reaches LIST_DROP further down than the foot's own room leaves it, a row more of the list and the foot
  -- a row lower.
  local LIST_DROP = 16

  local tls = MakeFrame("Frame", nil, ulc)
  tls:ClearAllPoints()
  tls:SetPoint("TOPLEFT", ulc, "TOPLEFT", 0, filtery)
  tls:SetPoint("BOTTOMRIGHT", ulc, "BOTTOMRIGHT", 0, FOOT_H + KUI.WIDGET_GAP - LIST_DROP)

  --
  -- The main contents window on the left side needs to be a scrolling list to accomodate all of the users.
  --
  local function ulist_och(this)
    local idx = this:GetID()
    local nid = qf.shownusers[idx].id
    qf.usersearch:SetText("")
    qf.usersearch:ClearFocus()
    qf.selected_user = nid
    this:GetParent():GetParent():SetSelected(idx, false, true)
    return true
  end

  --
  -- What a row shows on its right is packed against the edge (konfer:PackRowRight), and the name stops a gap short of
  -- whatever is last.
  --
  local function pack_right(btn)
    local at, gap = konfer:PackRowRight(btn, btn.osrole, btn.msrole, btn.markers)

    if (at == btn) then
      btn.text:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -8, 0)
    else
      btn.text:SetPoint("BOTTOMRIGHT", at, "BOTTOMLEFT", gap, -2)
    end
  end

  --
  -- A check list, every row's box at its right (THE TICKS), the ticks the page's own by uid, and the scroll bar past the
  -- boxes in a strip of its own.
  --
  arg = {
    name = "KonferUsersScrollList",
    itemheight = 16, itemcheck = "TINY", checkpos = "RIGHT",
    ischecked = function(objp, idx)
      local v = qf.shownusers[idx]

      return v and qf.checkedusers[v.id]
    end,
    newitem = function(objp, num)
        local rf = KUI.NewItemHelper(objp, num, "KonferUsersButton", 155, 16, nil, ulist_och, nil, nil)

        -- The roles of the user's main spec and off spec and the markers, placed by pack_right as the row is drawn.
        rf.osrole = KUI:CreateRoleIcon(rf, 12)
        rf.msrole = KUI:CreateRoleIcon(rf, 12)
        rf.markers = rf:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        rf.markers:SetHeight(12)
        rf.markers:SetJustifyH("RIGHT")

        --
        -- Who the row is, spelled out, to the list's left, clear of the user's details beside it. Reserved is the raid's and
        -- belongs to the lists, so it is not among the markers here.
        --
        rf:HookScript("OnEnter", function(this)
          local pp = konfer.apol

          if (this.uid and pp and pp.cfg) then
            konfer:ShowUserTooltip(this, pp.cfg, this.uid, false, "ANCHOR_LEFT")
          end
        end)
        rf:HookScript("OnLeave", function(this)
          GameTooltip:Hide()
        end)

        return rf
      end,
    setitem = function(objp, idx, slot, btn)
        local pp = konfer.apol
        local uid = qf.shownusers[idx].id

        btn.uid = uid

        -- Enchanter and frozen are the config's word on the user. Reserved is tonight's raid, and belongs to the lists.
        local marks = konfer:UserMarkers(pp.cfg:IsEnchanter(uid), pp.cfg:IsFrozen(uid))

        btn.markers:SetText(marks)
        konfer:SetRoleIcons(btn.msrole, btn.osrole, pp.cfg, uid)
        pack_right(btn)
        btn:SetTree(qf.shownusers[idx].tree, KU.TREE_LEAD)
        return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
            return aclass(pp.cfg:UserNameClass(qf.shownusers[ix].id))
          end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return users_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = KUI.HighlightItemHelper,
  }
  tls.slist = KUI:CreateScrollList(arg, tls)
  qf.userlist = tls.slist
  qf.userlist:HideItemCheck(nil)
  qf.userlist:Catch("OnItemChecked", function(this, evt, idx, checked, user)
    local v = qf.shownusers[idx]

    if (v) then
      qf.checkedusers[v.id] = checked or nil
      show_ticked()
    end
  end)

  -- The filter's two rows stand each centred over the list itself.
  ulc.specline:SetPoint("BOTTOM", tls.slist, "TOP", 0, KUI.WIDGET_GAP)
  ulc.rolefilter:ClearAllPoints()
  ulc.rolefilter:SetPoint("BOTTOM", ulc.specline, "TOP", 0, KUI.WIDGET_GAP)
  lay_out_spec_line()

  -- Over the rows' boxes, on the filter's lower line, the box that ticks or unticks everybody the list shows.
  qf.tickall = KUI:CreateCheckBox({ x = 0, y = 0, height = CHECK_SIZE }, ulc)
  qf.tickall:ClearAllPoints()
  qf.tickall:SetPoint("RIGHT", tls.slist, "TOPRIGHT", 0, KUI.WIDGET_GAP + ulc.specfilter:GetHeight() / 2)
  qf.tickall:Hide()
  qf.tickall:Catch("OnValueChanged", function(this, evt, val, user)
    if (user) then
      qf.userlist:SetCheckedAll(val)
      show_ticked()
    end
  end)

  -- The foot line, as wide as the list, the search box's left edge under the names' own.
  local foot = MakeFrame("Frame", nil, ulc)
  foot:SetPoint("TOPLEFT", tls.slist, "BOTTOMLEFT", 0, 0 - KUI.WIDGET_GAP)
  foot:SetPoint("TOPRIGHT", tls.slist, "BOTTOMRIGHT", 0, 0 - KUI.WIDGET_GAP)
  foot:SetHeight(FOOT_H)

  arg = {
    x = 0, y = 2, len = 16, font = "ChatFontSmall",
    tooltip = { title = L["User search"], text = L["TIP099"] },
  }
  ls.searchbox = KUI:CreateEditBox(arg, ulc)
  ls.searchbox:ClearAllPoints()
  ls.searchbox:SetPoint("LEFT", foot, "LEFT", 8, 0)
  ls.searchbox:SetHeight(SEARCH_H)
  qf.usersearch = ls.searchbox
  ls.searchbox:Catch("OnEnterPressed", function(this, evt, newv, user)
    this:SetText("")
  end)
  ls.searchbox:Catch("OnValueChanged", function(this, evt, newv, user)
    local pp = konfer.apol

    if (not pp.cfg.uids) then
      return
    end
    if (user and newv and newv ~= "") then
      local lnv = strlower(newv)

      for kk, vv in ipairs(qf.shownusers) do
        if (strfind(strlower(pp.cfg:UserName(vv.id) or ""), lnv, 1, true)) then
          qf.userlist:SetSelected(kk, true)
          return
        end
      end
    end
  end)

  --
  -- Invite, up while there is anybody to invite (THE TICKS). Kore leaves out anybody already in the group, and makes a party
  -- a raid for those a party will not hold. It is as wide as the most it is likely to say, two figures to invite of three
  -- ticked, and the rounded ends of its shape, the search box giving it the room.
  --
  local invitew = KUI:WidestString({ strfmt(L["Invite (%d/%d)"], 99, 999) }, "GameFontNormal") + BTN_H

  qf.invitebutton = KUI:CreateButton({ width = invitew, height = BTN_H, tooltip = { title = L["Invite"], text = L["TIP122"] } }, foot)
  qf.invitebutton:ClearAllPoints()
  qf.invitebutton:SetPoint("RIGHT", foot, "RIGHT", 0, 0)
  qf.invitebutton:Hide()
  qf.invitebutton:Catch("OnClick", function(this, evt)
    KRP:Invite(ticked_outside())
  end)

  -- The search box stops a gap short of where the button stands, whether or not it is up.
  ls.searchbox:SetPoint("RIGHT", qf.invitebutton, "LEFT", 0 - KUI.WIDGET_GAP, 0)

  --
  -- This config's own two flags, both on one line. The second is put in the column the controls below it start in, once the
  -- user info block has measured that column, so the panel reads as one grid rather than two boxes pushed together.
  --
  arg = {
    x = 5, y = ypos, label = { text = L["Frozen"] },
    tooltip = { title = "$$", text = L["TIP078"] },
  }
  ttr.frozen = KUI:CreateCheckBox(arg, ttr)
  ttr.frozen:Catch("OnValueChanged", function(this, evt, val, user)
    if (user and qf.selected_user) then
      qf.userpending:Set("frozen", val and true or false)
    end
  end)

  arg = {
    x = 5, y = ypos, label = { text = L["Raid enchanter"] },
    tooltip = { title = "$$", text = L["TIP075"] },
  }
  ttr.enchanter = KUI:CreateCheckBox(arg, ttr)
  ttr.enchanter:Catch("OnValueChanged", function(this, evt, val, user)
    local ups = qf.userpending

    if (not user or not qf.selected_user) then
      return
    end

    ups:Set("enchanter", val and true or false)

    --
    -- Saying somebody enchants for the raid says they are an enchanter, so the professions follow where they have room to.
    -- A slot that is filled is somebody's word about the character and is left alone, so two full slots say nothing and the
    -- tick stands on its own. Only on ticking: unticking means they are not the raid's enchanter, not that they cannot enchant.
    --
    local pprof, sprof = ups:Value("pprof"), ups:Value("sprof")

    if (val and pprof ~= K.PROF_ENCHANTING and sprof ~= K.PROF_ENCHANTING) then
      if (pprof == K.PROF_UNSET) then
        ups:Set("pprof", K.PROF_ENCHANTING)
      elseif (sprof == K.PROF_UNSET) then
        ups:Set("sprof", K.PROF_ENCHANTING)
      end

      qf.shared:SetValues(shared_values())
    end
  end)
  ypos = ypos - ttr.frozen:GetHeight() - KUI.WIDGET_GAP

  --
  -- Everything above is this config's view of the user. Everything under the separator is what is true of the character, the
  -- same in every config, and an edit to it is an edit everywhere the character is.
  --
  -- A compact page has no separator, so what is true of the character is built into a frame of its own, which lay_out_for
  -- stands at QF.SHAREDY under the separator or at QF.SEPY in its place.
  --
  qf.sepy = ypos
  ttr.sharedsep = KUI:CreateSeparator({ x = 5, y = ypos, text = L["USER_SHARED_INFO"] }, ttr)
  ypos = ypos - ttr.sharedsep:GetHeight() - KUI.WIDGET_GAP
  qf.sharedy = ypos

  qf.sharedframe = MakeFrame("Frame", nil, ttr)
  qf.sharedframe:ClearAllPoints()
  qf.sharedframe:SetPoint("TOPLEFT", ttr, "TOPLEFT", 0, ypos)
  qf.sharedframe:SetPoint("TOPRIGHT", ttr, "TOPRIGHT", 0, ypos)

  qf.shared = KU:CreateSharedUserInfo({
    prefix = "KonferUsersPage", x = 5, y = 0, mains = config_mains(),
    changed = function(field, value)
      if (qf.selected_user) then
        qf.userpending:Set(field, value)
      end
    end,
  }, qf.sharedframe)
  qf.sharedframe:SetHeight(0 - qf.shared.ypos)
  ypos = ypos + qf.shared.ypos

  --
  -- The second column, now that there is a column to line it up with. Only the LEFT anchor moves, so the row it is on stands.
  -- Under a policy with no lists, Frozen is not there and Raid enchanter stands in the first column (lay_out_for).
  --
  qf.enchantercol = 5 + qf.shared.lw + KUI.INTERNAL_GAP
  ttr.enchanter:SetPoint("LEFT", ttr, "LEFT", qf.enchantercol, 0)

  -- Which widget shows which field, for the changed colour.
  qf.userpending:Watch(ttr.frozen, "frozen")
  qf.userpending:Watch(ttr.enchanter, "enchanter")

  for _, f in ipairs(SHARED_FIELDS) do
    qf.userpending:Watch(qf.shared[f], f)
  end

  --
  -- The panel is exactly as tall as what is in it, less the gap left after the last of it.
  --
  local infoh = 0 - ypos - KUI.WIDGET_GAP + qf.userinfopanel.rings.top + qf.userinfopanel.rings.bottom

  qf.userinfopanel:SetHeight(infoh)

  --
  -- And the pane holding it and the lists is that plus the lists' rows and the rings round them, so the buttons stand
  -- straight under the lists.
  --
  local lp = qf.userlistspanel

  qf.userinfoh = infoh
  qf.userlistsh = USERLISTS_ROWS * 16 + lp.rings.top + lp.rings.bottom
  qf.usertoppane = rs.hsplit.topinset
  qf.usertoppane:SetHeight(qf.userinfoh + qf.userlistsh)

  --
  -- The middle right frame displays all of the roll lists and what position the user occupies on each, if any. Its panel is
  -- titled with what the colours in it mean, so all this needs is a frame for the scrolling list.
  --
  local tm = MakeFrame("Frame", nil, tmr)
  tm:ClearAllPoints()
  tm:SetPoint("TOPLEFT", tmr, "TOPLEFT", 0, 0)
  tm:SetPoint("BOTTOMRIGHT", tmr, "BOTTOMRIGHT", 0, 0)

  arg = {
    name = "KonferUserInWhichScrollList",
    itemheight = 16,
    newitem = function(objp, num)
        return KUI.NewItemHelper(objp, num, "KonferUmemButton", 200, 16, nil, function() return end, nil, nil)
      end,
    setitem = function(objp, idx, slot, btn)
        return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
            return qf.umemdata[ix]
          end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
        return KUI.SelectItemHelper(objp, idx, slot, btn, onoff, function() return nil end)
      end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  tm.slist = KUI:CreateScrollList(arg, tm)
  qf.umemlist = tm.slist

  --
  -- The buttons that act on the users, in two sets of which only one is ever shown (lay_out_for). Under the lists, three
  -- across and then two. Under the user list, on a compact page, two rows of two and no Guild import, the import being the
  -- policy's command there as everywhere. Each row is a frame of its own centred in its pane. Anchoring the rows rather than
  -- the buttons is what lets rows of different lengths share a centre line: the buttons are placed once, in their row's own
  -- coordinates, and the row follows the pane.
  --
  -- The row of three is what sets how narrow its pane can be, so its buttons are narrower than the others.
  --
  local ROW1_W = BTN_W - 8
  local BTN_COL = BTN_W + KUI.WIDGET_GAP
  local ROW1_COL = ROW1_W + KUI.WIDGET_GAP
  local BTN_ROW = 0 - BTN_H - KUI.WIDGET_GAP

  -- How far the outer two of the three are drawn in from the ends of their row, so their ends clear the panel's rim.
  local BTN_INSET = 2

  local BUTTONS = {
    createbutton = { text = L["Create"], tip = L["TIP081"], click = function() create_user_button(self) end },
    deletebutton = { text = L["Delete"], tip = L["TIP082"], click = function() delete_user_button(self, qf.selected_user) end },
    ratebutton = { text = L["Rate"], tip = L["TIP_USER_RATE"], click = function() rate_user_button(self, qf.selected_user) end },
    guildimp = { text = L["Guild import"], tip = L["TIP084"], click = function() guild_import_button(self, true) end },
    addmissing = { text = L["Add missing"], tip = L["TIP086"], click = function() add_missing_button(self) end },
  }

  --
  -- One row of buttons into SET, in PANE, TOP down from its top: the buttons named by KEYS, each WIDTH wide and COL from the
  -- one before, the outer two drawn in by INSET.
  --
  local function button_row(set, pane, top, keys, width, col, inset)
    local row = MakeFrame("Frame", nil, pane)

    row:SetWidth(col * (#keys - 1) + width)
    row:SetHeight(BTN_H)
    row:SetPoint("TOP", pane, "TOP", 0, top)

    for i, key in ipairs(keys) do
      local x = col * (i - 1)

      if (i == 1) then
        x = x + inset
      elseif (i == #keys) then
        x = x - inset
      end

      local b = KUI:CreateButton({
        x = x, y = 0, width = width, height = BTN_H, text = BUTTONS[key].text,
        tooltip = { title = "$$", text = BUTTONS[key].tip },
      }, row)
      b:Catch("OnClick", function(this, evt)
        BUTTONS[key].click()
      end)
      set[key] = b
    end
  end

  local wide, compact = {}, {}

  button_row(wide, br, 0, { "createbutton", "deletebutton", "ratebutton" }, ROW1_W, ROW1_COL, BTN_INSET)
  button_row(wide, br, BTN_ROW, { "guildimp", "addmissing" }, BTN_W, BTN_COL, 0)
  button_row(compact, bl, 0, { "createbutton", "deletebutton" }, BTN_W, BTN_COL, 0)
  button_row(compact, bl, BTN_ROW, { "ratebutton", "addmissing" }, BTN_W, BTN_COL, 0)

  --
  -- Whatever enables one of the buttons enables both its copies, so nothing that does has to know which set is on screen.
  -- SetEnabled is all that is passed on, that being all anything asks of them.
  --
  qf.userbuttons = {}

  for key in pairs(BUTTONS) do
    local copies = { wide[key], compact[key] }

    qf.userbuttons[key] = {
      SetEnabled = function(this, onoff)
        for _, b in pairs(copies) do
          b:SetEnabled(onoff)
        end
      end,
    }
  end

  -- Published because Konfer.lua enables and disables it as the raid changes.
  konfer.qf.addmissing = qf.userbuttons.addmissing

  --
  -- Under the buttons, or under the lists on a compact page, the policy's own section about the selected user. The panel is
  -- the page's and is built once, and what goes in it is a frame per policy, made by konfer:BuildUsersPolicyUI, of which one
  -- is ever shown. How tall it is and what it is called are the policy's (size_policy_panel), so it starts hidden, and a
  -- policy with nothing to put there leaves it hidden, the empty space under it taking the room back.
  --
  qf.policyroom = rsb.hsplit.bottomframe
  qf.policypanel = KUI:CreateInset({ name = "KonferUsersPolicyPanel", title = "" }, qf.policyroom)
  qf.policyslot = qf.policypanel.content
  qf.policypanel:Hide()

  --
  -- The right hand column is RIGHT_ROOM wider than the wider of what goes in it, each one panel's rings in from its edges:
  -- the player's notes, which a policy may put in its section (KU:CreateUserNotes, as PUG does), and the facts in User info,
  -- which start 5 in. The policy's section is told how wide that leaves it (UsersPage.Construct), so the notes can fill it
  -- and stand only their panel's own gap from its sides. The User list has the rest. The panels inside the pane draw in
  -- place of the pane, and SetSplitSize adds the pane's own rings, so those come off what is asked for.
  --
  local RIGHT_ROOM = 30
  local pr, ir = qf.policypanel.rings, qf.userinfopanel.rings
  local rr = cf.vsplit.rightinset.rings
  local wide = max(KU:RatingGridWidth() + pr.left + pr.right, 5 + qf.shared.width + ir.left + ir.right) + RIGHT_ROOM

  qf.sectionwidth = wide - pr.left - pr.right
  cf.vsplit:SetSplitSize(wide - rr.left - rr.right)

  -- Until a policy comes up, the page is laid out as a page that is not compact, its buttons under the lists.
  qf.listsplit:SetStaticShown(false)
end

--
-- The page's unsaved changes, which a policy's section watches its widgets with, as Watch(widget, "pdata").
--
function konfer:UsersPending()
  return qf.userpending
end

--
-- The policy's section stands straight under User info and the lists. It is as tall as the policy's Construct answered, the
-- usable height inside it (pp.usersheight), or runs down to the foot of the page where it answered nothing, for a section
-- with something in it that takes whatever room there is.
--
local function size_policy_panel(pp)
  local panel = qf.policypanel
  local room = qf.policyroom

  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", room, "TOPLEFT", 0, 0)
  panel:SetPoint("TOPRIGHT", room, "TOPRIGHT", 0, 0)

  if (pp.usersheight) then
    panel:SetHeight(pp.usersheight + panel.rings.top + panel.rings.bottom)
  else
    panel:SetPoint("BOTTOM", room, "BOTTOM", 0, 0)
  end
end

--
-- Build PP's own section on this page, into the slot the page keeps for it. Once per policy, from konfer:BuildPolicyUI. It
-- starts hidden, only the active policy's being shown, and the panel is made as tall as the policy answers it built.
--
-- The section edits what the policy keeps about the selected user among the page's unsaved changes, as the pdata field, so
-- it is handed the one thing it needs to take part: a way to say what that now is.
--
function konfer:BuildUsersPolicyUI(pp)
  local up = pp.UsersPage

  if (not up or not up.Construct) then
    return
  end

  pp.usersframe = MakeFrame("Frame", nil, qf.policyslot)
  pp.usersframe:ClearAllPoints()
  pp.usersframe:SetPoint("TOPLEFT", qf.policyslot, "TOPLEFT", 0, 0)
  pp.usersframe:SetPoint("BOTTOMRIGHT", qf.policyslot, "BOTTOMRIGHT", 0, 0)
  pp.usersframe:Hide()

  local _, h = self:PolicyHook(pp, "UsersPage.Construct", nil, up.Construct, pp.usersframe, function(pdata)
    if (qf.selected_user) then
      qf.userpending:Set("pdata", pdata)
    end
  end, qf.sectionwidth)

  h = tonumber(h)
  pp.usersheight = (h and h > 0) and h or nil
end

--
-- What on this page changes with the policy.
--
-- What is about lists is shown for a policy that has them and not for one that has none (konfer:PolicyHasLists): the panel
-- of the lists a user is on, and Frozen beside Raid enchanter. Without them User info's pane is User info alone, and Raid
-- enchanter moves into the first column.
--
-- A policy whose UsersPage is compact gives its own section the room the page can spare: the buttons go under the user
-- list, two rows of two, and User info has no separator, what is true of the character moving up into its place.
--
local function lay_out_for(pp)
  local lists = konfer:PolicyHasLists(pp)
  local compact = (pp.UsersPage and pp.UsersPage.compact) and true or false
  local infoh = qf.userinfoh - (compact and (qf.sepy - qf.sharedy) or 0)
  local sharedy = compact and qf.sepy or qf.sharedy

  qf.useropts.frozen:SetShown(lists)
  qf.useropts.enchanter:SetPoint("LEFT", qf.useropts, "LEFT", lists and qf.enchantercol or 5, 0)
  qf.userlistspanel:SetShown(lists)

  qf.useropts.sharedsep:SetShown(not compact)
  qf.sharedframe:SetPoint("TOPLEFT", qf.useropts, "TOPLEFT", 0, sharedy)
  qf.sharedframe:SetPoint("TOPRIGHT", qf.useropts, "TOPRIGHT", 0, sharedy)
  qf.userinfopanel:SetHeight(infoh)
  qf.usertoppane:SetHeight(infoh + (lists and qf.userlistsh or 0))

  qf.listsplit:SetStaticShown(compact)
  qf.buttonsplit:SetStaticShown(not compact)
end

--
-- Show or hide PP's section on this page. It is as tall as the policy says and wears the title it gave, and is not there at
-- all for a policy with nothing to put in it. Coming up, it is told who is selected, and the page is laid out for whether
-- the policy has lists.
--
function konfer:ShowUsersPolicyUI(pp, onoff)
  local up = pp.UsersPage

  if (pp.usersframe) then
    pp.usersframe:SetShown(onoff and true or false)
  end

  if (not onoff) then
    return
  end

  lay_out_for(pp)

  if (pp.usersframe) then
    size_policy_panel(pp)
    qf.policypanel:SetTitleText(up.title or pp.name)
    qf.policypanel:Show()
    user_selection()
  else
    qf.policypanel:Hide()
  end
end

--
-- Sort one policy's users into the order its list draws them: mains by name, each with its alts folded in underneath as its
-- branches, the last of them its end. The order belongs to the policy because the users do, a config's user table being its own.
--
--
-- Every entry in the config exactly once: mains by name, each with its alts folded under it. Alts are found by name, so two
-- entries with one name, which two admins adding the same person while apart from each other can make, would otherwise put
-- one entry under its main twice and leave its twin nowhere. So an alt is placed only once, and an entry that has not been
-- placed by the end stands on its own.
--
local function sort_policy_users(self, pp)
  local sorted = {}
  local uids = pp.cfg.uids
  local placed = {}

  local function byname(a, b)
    local an, bn = KU.kuids[uids[a.id][CU_KUID]] or "", KU.kuids[uids[b.id][CU_KUID]] or ""

    if (an ~= bn) then
      return an < bn
    end

    return a.id < b.id
  end

  for k,v in pairs(uids) do
    if (not pp.cfg:IsAlt(k)) then
      tinsert(sorted, { id = k })
      placed[k] = true
    end
  end

  tsort(sorted, byname)

  for i = #sorted, 1, -1 do
    local alts = {}

    for j, auid in ipairs(pp.cfg:UserAlts(sorted[i].id) or {}) do
      if (not placed[auid]) then
        placed[auid] = true
        tinsert(alts, auid)
      end
    end

    if (#alts > 0) then
      sorted[i].hasalts = true
      for j = 1, #alts do
        tinsert(sorted, i+j, { id = alts[j], main = sorted[i].id, tree = (j == #alts) and "end" or "branch" })
      end
    end
  end

  local strays = {}

  for k,v in pairs(uids) do
    if (not placed[k]) then
      tinsert(strays, { id = k })
    end
  end

  tsort(strays, byname)

  for k, v in ipairs(strays) do
    tinsert(sorted, v)
  end

  pp.sortedusers = sorted
end

function konfer:RefreshUsers()
  --
  -- The page shows the active policy's config, so that is the only user list
  -- there is to put back, and before the page is built there is none at all.
  --
  local pp = self.apol

  if (qf.userlist and pp and pp.cfg) then
    sort_policy_users(self, pp)
    fill_user_list(pp)
  end

  self:RefreshCSData()
  self:RefreshConfigUsers()

  -- A user added to a config may be new to the mod as well.
  KU:RefreshUserEditor()
end

--
-- Forget the KUID to uid index, so that the next lookup builds it again.
--
-- Thrown away rather than kept in step. Adding and removing are the only things that change what is in it, they arrive in
-- bursts far more often than singly -- a guild import, a broadcast, a config copy -- and one pass over at most 4094 entries
-- after the burst costs less than being right about every step of it. Nothing can be half updated this way either, which is
-- the failure an index kept in step invites and the one nothing downstream could see. A rename changes nothing in it, the
-- entries pointing at people by KUID.
--
function cfgm:ForgetUidIndex()
  self:Session().bykuid = nil
end

--
-- The uid this config gives the person KUID, or nil.
--
-- Two entries for one person is not a thing any path here creates, CreateNewUser refusing somebody the config already has,
-- but it is a thing another admin's config can arrive holding. Either uid answers for them and which one is not defined.
--
local function find_kuid(cfp, kuid)
  local cs = cfp:Session()

  if (not cs.bykuid) then
    local idx = {}

    for k, v in pairs(cfp.uids) do
      idx[v[CU_KUID]] = k
    end

    cs.bykuid = idx
  end

  return cs.bykuid[kuid]
end

--
-- The uid the character NAME has in this config, or nil for somebody it does not hold. NAME may be given in any form
-- K.CanonicalName accepts, so a bare name means a character on this realm.
--
-- This is the doorway from a character's Name to a uid, through their KUID, and it is on every path where somebody arrives
-- named rather than identified: a whispered bid, a line of /roll in system chat, the sender of any message, a name typed into
-- a dialog. It is answered from an index rather than by walking the config, which is why cfg:ForgetUidIndex has to be called
-- wherever the user list changes.
--
function cfgm:FindUser(name)
  local kuid = KU:Find(name)

  return kuid and find_kuid(self, kuid) or nil
end

--
-- The uid this config gives the person KUID, or nil for somebody it does not hold.
--
function cfgm:FindKuid(kuid)
  return kuid and find_kuid(self, kuid) or nil
end

--
-- The Name of UID in this config, or nil for a uid the config does not have.
--
function cfgm:UserName(uid)
  local ent = uid and self.uids[uid]

  return ent and KU.kuids[ent[CU_KUID]] or nil
end

--
-- The name and class of UID in this config, in the two arguments every class string helper takes, so that a user is drawn
-- as aclass(cfg:UserNameClass(uid)). A uid the config does not have is drawn as the uid itself, which says what went wrong
-- better than an error in the middle of a redraw.
--
function cfgm:UserNameClass(uid)
  local ent = uid and self.uids[uid]
  local name = ent and KU.kuids[ent[CU_KUID]]

  if (not name) then
    return tostring(uid), nil
  end

  return name, KU:Class(ent[CU_KUID])
end

--
-- The two flags on a config's entry for a user. Being a raid enchanter or having a frozen place on the lists are both a
-- config's own view of somebody, which is why they are here rather than on the user.
--
local function entry_flag(cfp, uid, slot)
  local ent = uid and cfp.uids[uid]

  return (ent and ent[slot]) and true or false
end

--
-- Set one of those flags, announcing the whole of what UID now is unless NOCMD. Returns whether it changed.
--
local function set_entry_flag(cfp, uid, slot, onoff, nocmd)
  local ent = cfp.uids[uid]
  local onoff = onoff and true or false

  -- Setting a flag to what it already is changes nothing, and so is no event.
  if (not ent or (ent[slot] and true or false) == onoff) then
    return false
  end

  ent[slot] = onoff or nil

  if (not nocmd) then
    cfp:SendUserFlags(uid)
  end

  return true
end

--
-- What UID is in this config, as the letters that are set, and their main's uid when A is among them.
--
--   E  a raid enchanter        F  a frozen place on the lists        A  an alt of somebody this config holds
--
-- One string rather than a flag and an on-or-off, because a CHUSR carries the whole of what somebody is here and a letter
-- that is not in it is a letter that is not set. That is what lets one event say three things, and it is the same reason
-- CHSET carries both settings strings rather than the one that moved.
--
function cfgm:UserFlags(uid)
  local ent = self.uids[uid]

  if (not ent) then
    return nil
  end

  local isalt, mainid = self:IsAlt(uid)
  local flags = ""

  if (ent[CU_ENCHANTER]) then
    flags = flags .. "E"
  end

  if (ent[CU_FROZEN]) then
    flags = flags .. "F"
  end

  if (isalt) then
    flags = flags .. "A"
  end

  return flags, mainid
end

--
-- Tell the other admins the whole of what UID is here, as one CHUSR.
--
function cfgm:SendUserFlags(uid)
  local flags, mainid = self:UserFlags(uid)

  if (flags) then
    self:AddEvent("CHUSR", uid, flags, mainid or "")
  end
end

function cfgm:IsEnchanter(userid)
  return entry_flag(self, userid, CU_ENCHANTER)
end

function cfgm:IsFrozen(userid)
  return entry_flag(self, userid, CU_FROZEN)
end

--
-- What the config's policy keeps about UID, as it stored it, or nil. The platform never looks inside it.
--
function cfgm:UserPData(uid)
  local ent = self.uids[uid]

  return ent and ent[CU_PDATA]
end

--
-- Keep PDATA as what the config's policy says about UID, a table being copied so that the caller changing it afterwards is
-- not changing the entry behind the event's back. It reaches the other admins in the MDUSR that carries the whole entry,
-- which NOCMD leaves for the caller to send once it has changed everything else it is changing.
--
function cfgm:SetUserPData(uid, pdata, nocmd)
  local ent = self.uids[uid]

  if (not ent) then
    return false
  end

  ent[CU_PDATA] = (type(pdata) == "table") and K.CopyTable(pdata, {}) or pdata

  if (not nocmd) then
    self:SendUserModified(uid)
  end

  return true
end

function cfgm:IsCoadmin(uid)
  if (self.admins[uid] or self.owner == uid) then
    return true
  end

  return false
end

--
-- Whether USERID is an alt in config CFG, and if so the uid of their main in that config.
--
-- Whose alt somebody is is a fact about the human behind the two characters and is the mod's, in KU.users, the same answer
-- whichever config asks. What a config supplies is the uid, which is a name of its own for somebody it holds. A main this
-- config does not have is no uid here, so that alt stands in it as a main of their own, tethered lists included, and the
-- link itself is untouched and still there for every other config that does hold them both.
--
-- The main's KUID is KU:Main, for a caller wanting it. This answers the config's question alone, which is whether there is
-- somebody here to tether to.
--
function cfgm:IsAlt(userid)
  local ent = userid and self.uids[userid]
  local mid = ent and self:FindKuid(KU:Main(ent[CU_KUID]))

  if (not mid or not self.uids[mid]) then
    return false, nil
  end

  return true, mid
end

--
-- The uids of USERID's alts in config CFG, in name order, or nil when this config holds none of them. The counterpart of
-- IsAlt, and like it reading the one link the mod holds and answering in this config's uids.
--
function cfgm:UserAlts(userid)
  local ent = userid and self.uids[userid]
  local alts = nil

  for k, v in ipairs((ent and KU:Alts(ent[CU_KUID])) or {}) do
    local auid = self:FindKuid(v)

    if (auid) then
      alts = alts or {}
      tinsert(alts, auid)
    end
  end

  if (alts) then
    tsort(alts, function(a, b)
      return (self:UserName(a) or "") < (self:UserName(b) or "")
    end)
  end

  return alts
end

--
-- The Users page's row for UID shows the config's word on them, enchanter and frozen, so a change to either draws that row
-- again at once, and only that row: the rest of the list, and who is selected in it, stay as they are. A row scrolled out of
-- sight has nothing to draw and is drawn as it was when it comes back into view.
--
local function redraw_user_row(cfg, uid)
  local list = qf.userlist

  if (not list or not cfg:IsActive()) then
    return
  end

  for i = 1, list.visibleslots or 0 do
    local row = list.slots[i]

    if (row and row:IsShown() and row.uid == uid) then
      list:setitem(row:GetID(), i, row)
    end
  end
end

function cfgm:SetUserEnchanter(userid, onoff, nocmd)
  local ret = false
  local onoff = onoff or false

  if (set_entry_flag(self, userid, CU_ENCHANTER, onoff, nocmd)) then
    if (self:IsActive()) then
      konfer:RefreshAllMemberLists()
    end
    redraw_user_row(self, userid)
    ret = true
  end

  --
  -- If this user is no longer an enchanter, check the config to see if they are assigned as one of the target enchanters for
  -- loot distribution. If they are we need to remove them.
  --
  if (not onoff) then
    for i = 1, konfer.MAX_DENCHERS do
      if (self.settings.denchers[i] == userid) then
        self.settings.denchers[i] = nil
      end
    end

    if (self:IsActive()) then
      konfer:UpdateDenchers()
      konfer:RefreshConfigLootUI(false)
    end
  end

  return ret
end

function cfgm:SetUserFrozen(userid, onoff, nocmd)
  local onoff = onoff or false

  if (set_entry_flag(self, userid, CU_FROZEN, onoff, nocmd)) then
    if (self:IsActive()) then
      konfer:RefreshAllMemberLists()
    end
    redraw_user_row(self, userid)
    return true
  end

  return false
end

--
-- Make USERID an alt of MAIN in config CFG, both being uids in it, or a main of their own when ONOFF is false. Both are uids
-- because marking somebody an alt here is done with the people this config has. A main it does not hold is not somebody it
-- can point at, and that is a requirement rather than something to work round.
--
-- Whose alt somebody is is one fact about the human behind two characters, held once in KU.users, so this writes the mod's
-- own link and every other config holding either of them shows it too. This config's lists follow, a tethered list holding
-- mains. A config holding the alt but not the main reads that link and finds no uid, and shows that alt as a main of its own.
--
-- One level deep. Nobody is their own alt, nobody is an alt of an alt, and somebody who already has alts cannot become one.
-- Those rules live in KU:SetMain and are not restated here, there being one link for them to be rules about.
--
-- Returns whether the link is as asked, and when it cannot be, the message saying why. Unless NOCMD is set the event goes
-- out and the policy says what went wrong. A caller that sends an event of its own, and so passes NOCMD, is the one to show the message.
--
function cfgm:SetUserIsAlt(userid, onoff, main, nocmd)
  local ent = userid and self.uids[userid]
  local main = (onoff and main and main ~= "") and main or nil
  local ment = main and self.uids[main]

  if (not ent or (main and not ment)) then
    return false
  end

  local kuid = ent[CU_KUID]
  local mainkuid = ment and ment[CU_KUID] or ""

  --
  -- Setting the link to what it already is changes nothing about the link, and so is no event. The lists are still
  -- re-derived, because a client whose lists do not match a link it already holds has nothing that would ever put it right:
  -- every later message about this person reads exactly like this one and stops here too.
  --
  if ((KU:Main(kuid) or "") == mainkuid) then
    konfer:FixupAllLists()
    return true
  end

  local ok, why = KU:SetMain(kuid, mainkuid)

  if (not ok) then
    if (not nocmd) then
      self:GetPolicy():err("%s", why)
    end

    return false, why
  end

  if (not nocmd) then
    self:SendUserFlags(userid)
  end

  --
  -- Every config, not the one this was asked about. The link that has just been written is read by all of them, so a client
  -- that fixed up only this one would keep lists elsewhere that disagree with what it now holds, and nothing would say so.
  --
  konfer:FixupAllLists()

  return true
end

--
-- The people in a config that arrived whole, in a broadcast, a full sync or a recovery, taken as that config is accepted.
-- NCF is the config as it was unpacked, each entry still naming its character by the Name the sender used, that being all
-- two clients share, and PEOPLE the wire rows that came with it. Kore adds whoever it has never heard of and puts to the
-- player what it would change about the rest, and then every entry is turned to the KUID this client knows them by.
--
-- Done before the config is put anywhere, so that nothing ever reads an entry naming its character any other way, and only
-- once the config is being accepted, so that a config refused or never asked for adds nobody. Every name was checked when
-- the config was unpacked, so each one becomes a KUID.
--
function konfer:AdoptPeople(sender, ncf, people)
  KU:OfferPeople(sender, people)

  for uid, ent in pairs(ncf.uids) do
    ent[CU_KUID] = (KU:Add(ent[CU_KUID]))
  end
end

--
-- The alt links that arrived with a whole config, as { name, mainname } pairs, written now that the config has been taken.
-- Accepting a config is accepting what it says about who is whose alt, exactly as it is accepting the people in it, and a
-- link is not an opinion to be put to the player.
--
-- A link can only be written between two characters the mod knows, and the config's people were added a moment before this,
-- including any main the config does not itself hold, so one naming somebody from outside it is dropped. Quietly, with one
-- redraw at the end rather than one for every link.
--
-- Both halves are character Names, being what the sender and this client share, and each becomes this client's KUID here.
-- Every link is an assertion that somebody has a main. Nothing arriving says that somebody has none, so this only ever
-- writes a link and can never clear one, which is why a pair naming anybody this client does not know is dropped whole
-- rather than half written: an unknown main must not read as no main. That matters because the link is the mod's: clearing
-- one here would unlink that character in every config of every mod on the strength of one config's payload.
--
function konfer:AcceptAltLinks(links)
  if (not links or not next(links)) then
    return
  end

  for k, v in ipairs(links) do
    local kuid, mainkuid = KU:Find(v[1]), KU:Find(v[2])

    if (kuid and mainkuid) then
      KU:SetMain(kuid, mainkuid, true)
    end
  end

  KU:UserLinksChanged()
end

--
-- Tell every config this player administers that holds KUID what we now hold about them, which is how a link set in the mod's
-- own user editor reaches the rest of the raid. That editor has no config in hand and Kore knows of none, so it says which
-- character changed and this works out who needs telling. The same walk a character info check's corrections take.
--
function konfer:SendUserEverywhere(kuid)
  if (not kuid) then
    return
  end

  --
  -- Before a word of it goes out. The editor writes the link straight into Kore, so this is the only place that hears the
  -- change on the client that made it, and every client the message below reaches will derive its own lists from that link.
  -- A sender that announced a change it had not made itself would be the one left holding the odd list, with a checksum
  -- that agrees with everybody's, which is the one divergence nothing downstream can see or repair.
  --
  self:FixupAllLists()

  for k, pol in pairs(self.policies) do
    for cfgid, cfp in pairs(self:PolicyConfigs(pol)) do
      local uid = cfp:FindKuid(kuid)

      if (uid and cfp:MyStatus()) then
        cfp:SendUserModified(uid)
      end
    end
  end
end

--
-- Tell the other admins of CFGID everything we hold about UID, which is what one MDUSR carries: this config's own view of
-- them, whose alt they are, what is true of the character, where a raid info check's corrections travel, and last what the
-- policy keeps about them.
--
-- Every field is read back from what is stored rather than taken from whatever a caller meant to set, so what goes out is
-- what happened, a link the mod refused included. The main is this config's uid for them, which is what the receiver's copy
-- of this config knows them by too.
--
function cfgm:SendUserModified(uid)
  local ent = uid and self.uids[uid]
  local kuid = ent and ent[CU_KUID]

  if (not KU:Record(kuid)) then
    return
  end

  local isalt, mainid = self:IsAlt(uid)
  local pprof, sprof = KU:Professions(kuid)
  local msrole, osrole = KU:Roles(kuid)

  self:AddEvent("MDUSR", uid, self:IsEnchanter(uid), self:IsFrozen(uid), isalt and true or false,
    mainid or "", KU:Class(kuid), pprof, sprof, msrole, osrole, KU:Race(kuid), KU:Level(kuid), self:UserPData(uid))
end

--
-- What a character's own client says about them, answering a raid info check. Nobody is better placed to know what class,
-- race, level, professions and specs a character has than the character, so this is taken as it stands rather than put to the
-- player the way another admin's word is.
--
-- Where anything did change, every config we are an admin of that has them is told, which is how one check at the door puts a
-- whole guild's records straight. Nobody is added: a check answers for everybody in the raid, and being in the raid is not
-- how somebody becomes a user.
--
function konfer:ApplyUserCheck(name, class, pprof, sprof, msrole, osrole, race, level)
  local kuid = KU:Find(name)
  local rec = KU:Record(kuid)

  if (not rec) then
    return
  end

  local was = { rec[USER_CLASS], rec[USER_PPROF], rec[USER_SPROF], rec[USER_MSROLE], rec[USER_OSROLE], rec[USER_RACE],
    rec[USER_LEVEL] }

  KU:SetClass(kuid, class)
  KU:SetProfessions(kuid, pprof, sprof)
  KU:SetRoles(kuid, msrole, osrole)
  KU:SetRace(kuid, race)
  KU:SetLevel(kuid, level)

  local now = { rec[USER_CLASS], rec[USER_PPROF], rec[USER_SPROF], rec[USER_MSROLE], rec[USER_OSROLE], rec[USER_RACE],
    rec[USER_LEVEL] }
  local changed = false

  for i = 1, #now do
    if (was[i] ~= now[i]) then
      changed = true
    end
  end

  if (not changed) then
    return
  end

  self:SendUserEverywhere(kuid)

  KU:UserLinksChanged()
end

local function get_next_uid(cfp)
  local ia, am = cfp:IsAdmin(cfp:MyUid())

  if (cfp.nusers == 4094) then
    error("Terribly sorry but Konfer has a limit of 4094 users :(", 2)
    return nil
  end

  for i = 1, 4094 do
    local is = strfmt("%s%03x", cfp.admins[am].id, i)
    if (not cfp.uids[is]) then
      return is
    end
  end
end

function cfgm:CreateNewUser(name, cls, norefresh, bypass, myid, nocmd)
  local typed = name
  local name = K.CanonicalName(name, nil)

  if (not bypass and self:IsDenied()) then
    return nil
  end

  local pol = self:GetPolicy()
  local uid = self:FindUser(name)

  if (not name) then
    if (not nocmd) then
      pol:err(L["%q is not a valid character name."], tostring(typed or ""))
    end
    return nil
  end

  if (uid and not nocmd) then
    pol:err(L["user %q already exists. Try again."], aclass(self:UserNameClass(uid)))
    return nil
  end

  uid = myid or get_next_uid(self)
  if (not uid) then
    return
  end

  --
  -- Adding somebody to a config is adding them to the mod too, when the mod does not know them yet, since that is plainly what
  -- was asked for. Somebody it does know is who they already are, class included. Either way the entry points at them by this
  -- client's KUID for them.
  --
  local kuid = KU:Add(name, cls)

  -- A uid we hold already, arriving again from another admin, is the same entry and is not counted twice.
  if (not self.uids[uid]) then
    self.nusers = self.nusers + 1
  end
  --
  -- Nobody arrives as anybody's alt. The link is this config's and names a uid in it, and this uid is being minted now, so
  -- there is nothing that could already be pointing at it.
  --
  self.uids[uid] = { kuid }
  self:ForgetUidIndex()

  if (not nocmd) then
    pol:info(L["user %q created."], KU:String(kuid))
  end

  if (name == K.player.name) then
    self:Session().myuid = uid
  end

  if (not norefresh and self:IsActive()) then
    konfer:RefreshUsers()
  end

  --
  -- If the config we are adding this user to is the one the raid is being run against, and we are in a raid, we need to scan
  -- the list of missing members to see if this user was in that list, and if so, remove them from it. That table is keyed by
  -- name, being the people the config had no uid for, and this is the moment one of them got one.
  --
  if (konfer.raid.uidmap and self:IsActive()) then
    if (konfer.raid.missing[name]) then
      konfer.raid.nmissing = konfer.raid.nmissing - 1
      konfer.raid.missing[name] = nil
      -- Only the config on screen has a button to put back, and only once the page has been built.
      if (qf.userbuttons) then
        qf.userbuttons.addmissing:SetEnabled(konfer:PolicyAdmin(konfer.apol) and konfer.raid.nmissing > 0)
      end
      if (not norefresh) then
        konfer:RefreshRaid()
      end
    end
  end

  if (not nocmd) then
    self:AddEvent("MKUSR", uid, name, cls, norefresh and true or false)
    self:JoinOneList(uid)
  end

  return uid
end

--
-- Take UID out of config CFGID, and their alts in it too when ALTS is set. The alts are worked out here, from what this
-- config holds now, rather than trusted to arrive as events of their own: an admin who sent the delete while out of sync
-- with us may not have known about all of them.
--
-- This takes them out of the config and nowhere else. Who the character is stays with the mod, and so does whose alt they
-- are, that being a fact about the human rather than about this config. An alt left behind when their main goes still holds
-- the link, and stands as a main of its own in this config alone, which is exactly what any config missing a main does.
--
function cfgm:DeleteUser(uid, alts, nocmd)
  local lcp = self
  local refreshitems = false
  local refreshhistory = false

  local function each_delete(userid)
    if (not lcp.uids[userid]) then
      return
    end

    if (not nocmd and self:IsActive()) then
      self:GetPolicy():info(L["user %q deleted."], aclass(self:UserNameClass(userid)))
    end
    for i = 1, konfer.MAX_DENCHERS do
      if (lcp.settings.denchers[i] == userid) then
        lcp.settings.denchers[i] = nil
      end
    end

    --
    -- An item named to go to this user on its next drop names nobody now, so that instruction goes, along with the list its
    -- award was to land on and whether the item was to be forgotten afterwards. Those three are one instruction and are
    -- cleared together, which is also how cfg:SendCHITM packs them.
    --
    for lk,lv in pairs(lcp.items) do
      if (lv.user == userid) then
        lv.user = nil
        lv.awardlist = nil
        lv.del = nil
        refreshitems = true
      end
    end

    --
    -- Remove the user from all lists
    --
    for lk,lv in pairs(lcp.lists) do
      self:DeleteMember(userid, lk, true)
    end

    --
    -- If the user had receieved items and is in the item history database, we need to convert the userid portion of the
    -- string into the user name and class, so that it can still be displayed correctly.
    --
    local hname, hclass = self:UserNameClass(userid)
    local nwhostr = strfmt("%s/%02d", hname, hclass or 0)
    for k,v in ipairs(lcp.history) do
      if (v[HIST_WHO] == userid) then
        v[HIST_WHO] = nwhostr
        refreshhistory = true
      end
    end

    -- A deletion another admin sent us carries the admin's removal with it, so that sends nothing of its own either.
    if (lcp.admins[userid]) then
      self:DeleteAdmin(userid, nocmd)
    end

    --
    -- The page loses its selection if this is the user it was showing: they are about to stop existing.
    --
    if (self:IsActive() and userid == qf.selected_user) then
      qf.selected_user = nil
    end

    if (lcp.uids[userid]) then
      lcp.uids[userid] = nil
      lcp.nusers = lcp.nusers - 1
      self:ForgetUidIndex()
    end
  end

  if (alts) then
    for k, v in ipairs(self:UserAlts(uid) or {}) do
      each_delete(v)
    end
  end

  each_delete(uid)

  if (not nocmd) then
    self:AddEvent("RMUSR", uid, alts and true or false)
  end

  if (not self:IsActive()) then
    return
  end

  konfer:RefreshUsers()
  konfer:RefreshAllMemberLists()
  konfer:RefreshConfigAdminUI(false)

  if (refreshitems) then
    konfer:RefreshItemList()
  end

  if (refreshhistory) then
    konfer:RefreshHistory()
  end

  if (konfer.raid.uidmap) then
    konfer:RefreshRaid()
  end
end

local function confirm_delete_user(self, arg, alts)
  arg.cfg:DeleteUser(arg.uid, alts, false)
end

function cfgm:DeleteUserCmd(userid, show)
  local pol = self:GetPolicy()

  if (self.owner == userid) then
    pol:err(L["cannot delete user %q as they are the owner of the configuration."], aclass(self:UserNameClass(userid)))
    return true
  end

  --
  -- The dialog stands in for the window, hiding it and putting it back, but only when the user belongs to the config the
  -- window is showing. The same person in any other config is not being deleted from here.
  --
  local win = (konfer.mainwin and (show or konfer.mainwin:IsShown()) and self:IsActive()) and konfer.mainwin or nil

  local alts = nil
  if (self:UserAlts(userid)) then
    alts = L["Delete all alts of user"]
  end
  K.ConfirmationDialog(konfer, { text = L["Delete user"], owner = konfer.apol }, L["DELUSER"],
    { L["User: %s"], K.DisplayName(self:UserName(userid)) }, function(s, ag, al) confirm_delete_user(s, ag, al) end,
    { uid=userid, cfg=self }, win, 210, alts)

  return false
end

--
-- USERID in config CFG has changed their name to NEWNAME. A name change is something that happened to the character, so when
-- this player makes it, it is made to the mod's record of them and every config that has them follows.
--
-- A rename arriving from another admin does the same job here: a paid name change is a fact about the character rather than
-- an opinion of one config's, so there is nothing to ask and nothing to leave behind in any other config holding them.
--
-- One case touches this config's entry and nothing else. A NEWNAME the mod already knows as somebody else is not a rename at
-- all, it is the entry being pointed at the user it should have named all along, and two existing people are never merged.
--
-- Returns true when nothing was renamed and false when it was, which is what K.RenameDialog and the slash command expect.
--
function cfgm:RenameUser(userid, newname, nocmd)
  local ent = self.uids[userid]
  local kuid = ent and ent[CU_KUID]
  local oldname = kuid and KU.kuids[kuid]
  local typed = newname
  local newname = K.CanonicalName(newname, nil)

  if (oldname and not newname and not nocmd) then
    self:GetPolicy():err(L["%q is not a valid character name."], tostring(typed or ""))
  end

  if (not oldname or not newname or oldname == newname) then
    return true
  end

  local known = KU:Find(newname)

  if (known) then
    -- Somebody the mod already knows: the entry now points at them, and nobody is renamed.
    ent[CU_KUID] = known
    self:ForgetUidIndex()
    konfer:RefreshCSData()
    self:FixupLists()
  else
    local ok, msg = KU:Rename(kuid, newname)

    if (not ok) then
      self:GetPolicy():err("%s", msg)
      return true
    end
  end

  if (not nocmd) then
    self:GetPolicy():info(L["User %q renamed to %q."], K.DisplayName(oldname), KU:String(ent[CU_KUID]))
    self:AddEvent("MVUSR", userid, newname)
  end

  if (self:IsActive()) then
    konfer:RefreshUsers()
    konfer:RefreshAllMemberLists()
  end

  return false
end

--
-- Reserve a user, which is to say count them as present in this raid whether or not they are: they were asked to go and farm
-- something, or they had to step away. It says nothing about them beyond tonight.
--
-- This is never stored. It lives in konfer.raid because it belongs to the raid rather than to the config, and it goes when
-- the raid does. It is shared though: RSUSR carries each change to the other admins, and an admin arriving, reloading or
-- switching config or policy asks for the current picture with REQRS.
--
-- Loot runs against one config, so reserving somebody in a config that is not the one being looted has no meaning and is quietly ignored.
--
function cfgm:ReserveUser(uid, onoff, nocmd)
  local onoff = onoff or false

  if (not self:IsActive()) then
    return
  end

  konfer.raid.reserved = konfer.raid.reserved or {}
  konfer.raid.reserved[uid] = onoff or nil

  if (not nocmd) then
    self:GetPolicy():CSendAM(self.id, "RSUSR", "ALERT", uid, onoff)
  end

  konfer:RefreshUsers()
  konfer:RefreshAllMemberLists()
end

function cfgm:IsReserved(uid)
  if (not self:IsActive() or not konfer.raid.reserved) then
    return false
  end

  return konfer.raid.reserved[uid] or false
end

--
-- Which absentees this character has already been told about for LISTID, so that the same people are not repeated every time
-- the list is drawn. Made on demand, and thrown away with the rest of the raid.
--
-- Keyed by uid for somebody the config holds and by name for somebody it does not, there being no uid for them. The two
-- cannot collide, a uid being four hex characters and a name carrying its realm.
--
function konfer:ListWarnings(listid)
  self.raid.warns = self.raid.warns or {}
  self.raid.warns[listid] = self.raid.warns[listid] or {}

  return self.raid.warns[listid]
end

-- The users' tick boxes come and go with being in a group (THE TICKS), the list left as it is, and Invite follows the group.
function konfer:RefreshUserTicks()
  local pp = self.apol

  if (qf.userlist and pp and pp.cfg) then
    lay_out_ticks(pp)
    qf.userlist:RefreshChecks()
  end
end

function konfer:RefreshUsersLists()
  if (qf.userlist and self.apol and self.apol.cfg) then
    refresh_user_membership(self)
  end
end

function konfer:RefreshUsersUI(reset)
  if (reset) then
    qf.selected_user = nil
  end

  self:RefreshUsers()
  self:RefreshUsersLists()

  if (not qf.userbuttons) then
    return
  end

  sync_user_panels()

  --
  -- Being an admin is a fact about the config on screen. Whether anyone is missing is a fact about the raid, and the raid is
  -- run against this same config, there being only one policy active and one config under it.
  --
  local pp = self.apol

  if (pp and pp.currentid) then
    local inraid = self.raid.uidmap and self.raid.nmissing and self.raid.nmissing > 0
    local is_admin = self:PolicyAdmin(pp)

    qf.userbuttons.addmissing:SetEnabled((inraid and is_admin) and true or false)
    qf.userbuttons.guildimp:SetEnabled((K.player.is_guilded and is_admin) and true or false)
  end
end

