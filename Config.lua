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
local L = konfer.L
local KUI = konfer.KUI
local KRP = konfer.KRP
local KC = konfer.KC
local MakeFrame = KUI.MakeFrame
local cfgm = konfer.configmethods

-- Local aliases for global or LUA library functions
local _G = _G
local tinsert = table.insert
local tconcat = table.concat
local tsort = table.sort
local strlower = string.lower
local strfmt = string.format
local strfind = string.find
local strsub = string.sub
local strrep = string.rep
local floor = math.floor
local min, max = math.min, math.max
local pairs, ipairs, next = pairs, ipairs, next
local assert = assert

local white = konfer.white
local aclass = konfer.aclass
local err = konfer.err
local debug = konfer.debug

local CHANNEL_GUILD = konfer.CHANNEL_GUILD
local CHANNEL_OTHER = konfer.CHANNEL_OTHER

--[[
This file implements the configuration UI and provides functions for manipulating various config options and refreshing the
data. Most of this code can only be run by an administrator although anyone can switch active configurations.

The main UI creation function is konfer:InitialiseConfigUI(). The config page has two tabs. Loot is a static pane of general
options over a growing pane of roll options, and everything in both of them is the platform's: they say what happens to an
item once a policy has decided who gets it, which is the same question whichever policy decided. Admin is the column of
configuration panels with the active policy's own panel beside it, and the About plate across the bottom.

The main data refresh function is konfer:RefreshConfigUI(). However, there are a number of sub refresh functions which reset
only portions of the UI or stored data, all of which are called by konfer:RefreshConfigUI().

konfer:RefreshConfigLootUI(reset)
  Refreshes the general options pane of the loot tab.

konfer:RefreshConfigRollUI(reset)
  Refreshes the roll options pane of the loot tab.

konfer:RefreshConfigAdminUI(reset)
  Refreshes the config admin tab, the active policy's own panel on it included.
]]

--
-- The dialogs this page puts up are kept on the widget table rather than in file locals because each is built once, with
-- callbacks closed over the window that raised it, and is then reopened rather than remade.
--
-- There is one window and it shows the active policy, so these are the mod's and are named as the mod's, without a policy
-- prefix. A policy's own frames are the prefixed ones and hang off the policy. What that costs is that a callback built
-- here outlives whichever policy happened to be active when it was built, so every one of them reads konfer.apol when it
-- runs rather than capturing a policy.
--
local silent_delete = nil

--
-- This page's widget handles. There is one window and it shows the active policy, so there is one of these.
--
-- What the Admin tab has selected is kept here too. qf.admincfg is the config picked in its Configurations list and
-- qf.sortedconfigs the configs that list shows, in its order; qf.coadmin_selected is the co-admin picked in its Co-admins
-- list and qf.sortedadmins the co-admins that list shows. The config picked there is the one in the title bar: picking one
-- in the list makes it current, and the list follows the title bar when that changes, qf.adminfollows being which config
-- it last followed. The only way the two differ is nothing being picked in the list, when the Admin tab and the policy's own
-- tabs (ConfigTabs), which are about the config picked here, have nothing to be about.
--
local qf = {}

--
-- We have a finite number of admins, in order to ensure that unique user ID's will be created by each admin, so there is no
-- clash when syncing. This is the list of admin "prefixes" for the admins. Everything else is in lower case in the system so
-- we preserve that, using lower case letters and numbers, making the total possible number of admins 36. This is the
-- numbering sequence for the admin ID.
--
local adminidseq = "0123456789abcdefghijklmnopqrstuvwxyz"

--
-- This file contains all of the UI handling code for the config panel, as well as all config space manipulation functions.
-- Since this code deals with config spaces themselves, its data model is slightly different. All of the main config options
-- etc use the standard data model but the admin screen has a different notion of the "current" configuration. For that
-- screen and that screen only, the configuration it works with is dictated by the window's qf.admincfg, which is set when a
-- configuration space is selected in the left hand panel.
--

local function refresh_coadmins(self)
  if (not qf.admincfg) then
    qf.coadminscroll.itemcount = 0
    qf.coadminscroll:UpdateList()
    return
  end

  local newadmins = {}
  local ownerlist = {}
  local tc = self:Config(qf.admincfg)

  qf.coadmin_selected = nil

  for k,v in pairs(tc.admins) do
    tinsert(newadmins, k)
  end
  tsort(newadmins, function(a, b)
    return (tc:UserName(a) or a) < (tc:UserName(b) or b)
  end)

  for k,v in pairs(newadmins) do
    tinsert(ownerlist, { text = aclass(tc:UserNameClass(v)), value = v })
  end

  qf.sortedadmins = newadmins

  qf.coadminscroll.itemcount = #qf.sortedadmins
  qf.coadminscroll:UpdateList()
  qf.coadminscroll:SetSelected(nil)

  -- UpdateItems in case we are now a co-admin and the color of the config dropdown line item changes.
  qf.cfgownerdd:UpdateItems(ownerlist)

  -- The owner on screen, an unsaved change of owner included, set without throwing, putting it back being no choice.
  qf.cfgownerdd:SetValue(qf.adminpending:Value("owner"), true)
end

--
-- The panels on the Admin tab that are about the selected configuration read as disabled, their titles dimmed, while no
-- configuration is selected: Settings, Co-admins and the policy's own. A panel dims only its title, so the policy is told as
-- well, to enable the options it built there. Called wherever the selection changes.
--
local function sync_admin_panels()
  local pp = konfer.apol
  local hascfg = qf.admincfg ~= nil

  if (qf.adminsettingspanel) then
    qf.adminsettingspanel:SetEnabled(hascfg)
    qf.admincoadminspanel:SetEnabled(hascfg)
    qf.adminoptspanel:SetEnabled(hascfg)
    qf.adminpolicypanel:SetEnabled(hascfg)
    qf.adminextrapanel:SetEnabled(hascfg)
  end

  --
  -- The policy's options are about the selected config, as the Settings and Co-admins panels beside them are, so the policy
  -- is told which config that is and puts its options back from it.
  --
  if (pp and pp.EnableConfigUI) then
    konfer:PolicyHook(pp, "EnableConfigUI", nil, pp.EnableConfigUI, pp, hascfg, qf.admincfg)
  end

  if (hascfg and pp and pp.RefreshConfigUI) then
    konfer:PolicyHook(pp, "RefreshConfigUI", nil, pp.RefreshConfigUI, pp, qf.admincfg)
  end

  -- The policy's own tabs are about the same config, or none.
  konfer:RefreshConfigPolicyTabs()
end

--
--
-- This is a helper function for when a configuration is selected from the list of possible configurations in the admin
-- screen. It updates and populates the admin options on the right side panel.
--
--
-- A scroll list hands its callbacks a fixed set of arguments and none of them says which policy's list was clicked, so the
-- widget table is bound in by whoever built the list rather than looked up here.
--
local function config_selectitem(objp, idx, slot, btn, onoff)
  local pp = konfer.apol
  local onoff = onoff or false
  local en = false
  local aps = qf.adminpending

  -- The tab's unsaved changes are to the config picked in the list. See PS.Pick.
  local picked = onoff and qf.sortedconfigs[idx] and qf.sortedconfigs[idx].id or nil

  aps:Pick(picked)

  qf.cfgopts.cfgowner:SetEnabled(onoff)
  qf.cfgopts.cfgchannel:SetEnabled(onoff)
  qf.cfgdelbutton:SetEnabled(onoff)
  qf.cfgrenbutton:SetEnabled(onoff)
  qf.cfgcopybutton:SetEnabled(onoff)
  qf.coadadd:SetEnabled(onoff)
  qf.admindeflist:SetEnabled(onoff)
  qf.adminrankfilter:SetEnabled(onoff)
  qf.adminrankorder:SetEnabled(onoff)

  if (onoff) then
    qf.admincfg = qf.sortedconfigs[idx].id
    local lcf = konfer:Config(qf.admincfg)

    -- Showing what is on screen is not choosing it, so none of these throws.
    qf.cfgopts.cfgowner:SetValue(aps:Value("owner"), true)
    qf.cfgopts.cfgchannel:SetValue(aps:Value("channel"), true)
    qf.adminrankfilter:SetChecked(aps:Value("rank_filter"), true)

    -- The lists on offer are the selected config's, which is not necessarily the one the window has in hand.
    qf.admindeflist:UpdateItems(lcf:ListChoices())
    qf.admindeflist:SetValue(aps:Value("def_list") or "0", true)

    --
    -- Everything in Options is a setting like the ones on the Loot tab, so any admin of the config may change it, where the
    -- owner and the channel below are the owner's alone. Guild rank filtering means nothing to a character with no guild,
    -- and there is nothing for an order to put in order until it is switched on.
    --
    local isadm = lcf:MyStatus() and true or false
    local adm = isadm and K.player.is_guilded

    qf.admindeflist:SetEnabled(isadm)
    qf.adminrankfilter:SetEnabled(adm and true or false)
    qf.adminrankorder:SetEnabled((adm and aps:Value("rank_filter")) and true or false)

    en = lcf:MyStatus() == 2 and true or false

    if (lcf.nadmins > 1) then
      qf.cfgopts.cfgowner:SetEnabled(en)
    else
      qf.cfgopts.cfgowner:SetEnabled(false)
    end

    --
    -- The channel a config talks on is a config-wide structural choice, so it follows the same rule as renaming: the
    -- config's owner sets it, co-admins do not. Nobody does where the policy says where all its configs talk (PUG's always
    -- over the raid), the box only showing it.
    --
    local fixed = konfer.policies[lcf.policy] and konfer.policies[lcf.policy].channel

    qf.cfgopts.cfgchannel:SetEnabled((en and not fixed) and true or false)

    qf.coadadd:SetEnabled(en and lcf.nadmins < 36)
    qf.cfgrenbutton:SetEnabled(en)

    -- A policy's last config may go too, the window moving on to the next policy that has one.
    qf.cfgdelbutton:SetEnabled(true)
  else
    qf.admincfg = nil
  end

  refresh_coadmins(konfer)
  sync_admin_panels()

  --
  -- Picking a config in the list makes it the current one, exactly as picking it in the title bar does, so that the list,
  -- the title bar and every page are always about the same config. Last, the pick being settled, because making a config
  -- current refreshes this page and this list with it. A new config turns the window back to its opening pages, which is
  -- right for one chosen in the title bar and not for one chosen here, so the window comes back to where the pick was made.
  --
  if (onoff and pp and qf.admincfg and qf.admincfg ~= pp.currentid) then
    konfer.mainwin.cfgselector:SetValue(qf.admincfg)
    konfer.mainwin:SetPage(konfer.CONFIG_PAGE, konfer.CONFIG_ADMIN_TAB)
  end
end

--
-- Helper function for dealing with the selected item in the coadmin scroll list.
--
local function coadmin_list_selectitem(objp, idx, slot, btn, onoff)
  local en = false
  local onoff = onoff or false

  if (onoff and qf.admincfg) then
    local lcf = konfer:Config(qf.admincfg)

    qf.coadmin_selected = qf.sortedadmins[idx]

    if (qf.coadmin_selected ~= lcf.owner) then
      en = lcf:MyStatus() == 2 and true or false
    end
  else
    qf.coadmin_selected = nil
  end

  qf.coaddel:SetEnabled(en)
end

-- Low level helper function to add a new co-admin
local function add_coadmin(this, uid, cfg)
  if (not cfg or cfg.admins[uid]) then
    return
  end

  --
  -- An admin id is the first character of every uid its admin creates, so two admins must never hold one at the same time.
  -- Used means held by an admin now, or the first character of a user we hold, which covers an admin who has gone while
  -- their users are still here.
  --
  -- Once their last user has gone too the id is free again, and handing it to somebody new is harmless. The owner is the
  -- only client that ever allocates one, through the owner-only MKADM, and it holds the whole config while doing it, so
  -- there is never a second allocator to collide with. All a recycled id leaves behind is a stale creator in the first
  -- character of some old uid, which nothing reads.
  --
  local used = {}

  for k, v in pairs(cfg.admins) do
    used[v.id] = true
  end

  for k, v in pairs(cfg.uids) do
    used[strsub(k, 1, 1)] = true
  end

  local newid
  for i = 1, 36 do
    local id = strsub(adminidseq, i, i)
    if (not used[id]) then
      newid = id
      break
    end
  end

  if (not newid) then
    cfg:GetPolicy():err(L["no more administrators can be added to this configuration."])
    return
  end

  --
  -- Must add the event BEFORE we add the admin. It is for everybody, the new admin not being one yet when it arrives, and a
  -- raider taking events only from the admins it knows of.
  --
  cfg:AddEvent("MKADM", uid, newid)
  cfg.nadmins = cfg.nadmins + 1
  cfg.admins[uid] = { id = newid, lastevent = 0 }
end

local function new_space_button(this)
  local box

  if (not qf.newcfgdlg) then
    qf.newcfgdlg, box = K.SingleStringInputDialog(this, "KonferSetupNewSpace",
      { text = L["Create configuration"], owner = konfer.apol }, L["NEWMSG"], 400, 165)

    --
    -- CreateNewConfig says for itself why a name it refuses is no good, too short among them, so nothing is checked here.
    --
    local function verify_with_create(objp, val)
      local pp = konfer.apol
      local err = this:CreateNewConfig(val, false, nil, nil, pp.handle)
      if (err) then
        objp:Show()
        objp.ebox:SetFocus()
        return true
      end
      qf.newcfgdlg:Hide()
      return false
    end

    qf.newcfgdlg:Catch("OnAccept", function(t, evt)
      return verify_with_create(qf.newcfgdlg, t.ebox:GetText())
    end)

    qf.newcfgdlg:Catch("OnCancel", function(t, evt)
      qf.newcfgdlg:Hide()
      return false
    end)

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    qf.newcfgdlg:Catch("OnHide", function(t, evt)
      qf.mainwin:Show()
    end)

    box:Catch("OnEnterPressed", function(t, evt, val)
      return verify_with_create(qf.newcfgdlg, val)
    end)
  else
    box = qf.newcfgdlg.ebox
  end

  qf.newcfgdlg:SetTitleText(konfer.apol:WindowTitle(L["Create configuration"]))
  box:SetText("")

  qf.mainwin:Hide()
  qf.newcfgdlg:Show()
  box:SetFocus()
end

local function rename_space_button(this, cfgid)
  local function rename_helper(newname, old)
    local rv = this:Config(old):Rename(newname)
    if (rv) then
      return true
    end

    return false
  end

  K.RenameDialog(this, { text = L["Rename configuration"], owner = konfer.apol },
    { L["Current configuration: %s"], this:Config(cfgid).name }, L["New name"], 32, rename_helper, cfgid, qf.mainwin)
end

local function copy_space_button(this, cfgid, newname, newid, shown)
  if (not qf.copycfgdlg) then
    local ypos = 0
    local arg = {
      x = "CENTER", y = "MIDDLE",
      name = "KonferCopyConfigDialog",
      title = konfer.apol:WindowTitle(L["Copy configuration"]),
      border = true,
      width = 450,
      height = 245,
      canmove = true,
      canresize = false,
      escclose = true,
      blackbg = true,
      okbutton = true,
      cancelbutton = true,
    }
    local ret = KUI:CreateDialogFrame(arg)

    arg = {
      x = 0, y = ypos, width = 200, height = 20, autosize = false,
      justifyh = "RIGHT", font = "GameFontNormal",
      text = L["Source configuration"],
    }
    ret.str1 = KUI:CreateStringLabel(arg, ret)

    arg.justifyh = "LEFT"
    arg.text = ""
    arg.color = {r = 1, g = 1, b = 1, a = 1 }
    ret.str2 = KUI:CreateStringLabel(arg, ret)
    ret.str2:ClearAllPoints()
    ret.str2:SetPoint("TOPLEFT", ret.str1, "TOPRIGHT", 12, 0)
    ypos = ypos - ret.str2:GetHeight() - KUI.WIDGET_GAP

    arg = {
      x = 0, y = ypos, width = 200, height = 20, autosize = false,
      justifyh = "RIGHT", font = "GameFontNormal",
      text = L["Destination configuration"],
    }
    ret.str3 = KUI:CreateStringLabel(arg, ret)

    arg.justifyh = "LEFT"
    arg.text = ""
    arg.color = {r = 1, g = 1, b = 1, a = 1 }
    ret.str4 = KUI:CreateStringLabel(arg, ret)
    ret.str4:ClearAllPoints()
    ret.str4:SetPoint("TOPLEFT", ret.str3, "TOPRIGHT", 12, 0)

    arg = {
      x = 0, y = ypos, width = 200, height = 20, len = konfer.CONFIG_NAME_MAX,
    }
    ret.dest = KUI:CreateEditBox(arg, ret)
    ret.dest:ClearAllPoints()
    ret.dest:SetPoint("TOPLEFT", ret.str3, "TOPRIGHT", 12, 0)
    ret.dest:Catch("OnValueChanged", function(t, evt, newv)
      qf.copycfgdlg.newname = newv
    end)
    ypos = ypos - ret.dest:GetHeight() - KUI.WIDGET_GAP

    local xpos = 90
    arg = {
      x = xpos, y = ypos, name = "KonferCopyListDD", border = "THICK",
      dwidth = 175, items = KUI.emptydropdown, itemheight = 16,
      title = { text = L["Roll lists to copy"] }, mode = "MULTI",
    }
    ret.ltocopy = KUI:CreateDropDown(arg, ret)
    ypos = ypos - ret.ltocopy:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    arg = {
      x = xpos, y = ypos, label =  { text = L["Copy co-admins"] },
    }
    ret.copyadm = KUI:CreateCheckBox(arg, ret)
    ret.copyadm:Catch("OnValueChanged", function(t, evt, val)
      qf.copycfgdlg.do_copyadm = val
    end)
    ypos = ypos - ret.copyadm:GetHeight() - KUI.WIDGET_GAP

    arg = {
      x = xpos, y = ypos, label = { text = L["Copy all user flags"] },
    }
    ret.copyflags = KUI:CreateCheckBox(arg, ret)
    ret.copyflags:Catch("OnValueChanged", function(t, evt, val)
      qf.copycfgdlg.do_copyflags = val
    end)
    ypos = ypos - ret.copyflags:GetHeight() - KUI.WIDGET_GAP

    arg = {
      x = xpos, y = ypos, label = { text = L["Copy configuration options"] },
    }
    ret.copycfg = KUI:CreateCheckBox(arg, ret)
    ret.copycfg:Catch("OnValueChanged", function(t, evt, val)
      qf.copycfgdlg.do_copycfg = val
    end)
    ypos = ypos - ret.copycfg:GetHeight() - KUI.WIDGET_GAP

    arg = {
      x = xpos, y = ypos, label = { text = L["Copy item options"] },
    }
    ret.copyitem = KUI:CreateCheckBox(arg, ret)
    ret.copyitem:Catch("OnValueChanged", function(t, evt, val)
      qf.copycfgdlg.do_copyitems = val
    end)
    ypos = ypos - ret.copyitem:GetHeight() - KUI.WIDGET_GAP

    qf.copycfgdlg = ret

    ret.OnAccept = function(t)
      local pp = konfer.apol
      --
      -- First things first, see if we need to create the new configuration or if we are copying into it.
      --
      --
      -- Checked here as well as in CreateNewConfig, because copying into a config that exists already never reaches it.
      --
      if (this:NameTooShort(pp, qf.copycfgdlg.newname)) then
        return
      end
      if (qf.copycfgdlg.newid == 0) then
        qf.copycfgdlg.newid = this:FindConfig(pp, qf.copycfgdlg.newname) or 0
      end

      -- Copying into a config that exists already is changing it, which only its admins may do.
      if (qf.copycfgdlg.newid ~= 0 and konfer:Config(qf.copycfgdlg.newid):IsDenied()) then
        return
      end

      if (qf.copycfgdlg.newid == 0) then
        --
        -- A copy runs the policy its source runs. Copying an SK config into a new one that turned out to be EP/GP would
        -- carry across lists and standings the destination has no way to read.
        --
        local srccfg = this:Config(qf.copycfgdlg.cfgid)
        local rv, ni = this:CreateNewConfig(qf.copycfgdlg.newname, false, nil, nil, srccfg and srccfg.policy)
        if (rv) then
          return
        end
        qf.copycfgdlg.newid = ni
      end

      local newid = qf.copycfgdlg.newid
      local cfgid = qf.copycfgdlg.cfgid

      local dc = this:Config(newid)
      local sc = this:Config(cfgid)

      --
      -- Copy the users. We cannot do a blind copy of the user ID's as the user may already exist in the configuration with a
      -- different ID, so we have to search the new configuration for each user. For the various user flags, we have to do
      -- them individually, as we may need to send out events for each change to the new user.
      --
      -- Two configs are two uid spaces, so every uid the rest of the copy carries has to be translated. NEWUID is that
      -- translation, built here because this is the one pass that visits every user, and read by the lists, the items, the
      -- disenchanters and the co-admins below. They used to find each other by name a member at a time, which asked the same
      -- question once per appearance rather than once per person.
      --
      local newuid = {}

      for k,v in pairs(sc.uids) do
        local name, cls = sc:UserNameClass(k)
        local du = dc:FindKuid(v[konfer.CFGUSER_KUID])
        if (not du) then
          --
          -- Created quietly, one line of chat each being too many for a whole config, but not silently: every event that
          -- follows names these users, so the other admins are told about them first.
          --
          du = dc:CreateNewUser(name, cls, true, true, nil, true)
          if (du) then
            dc:AddEvent("MKUSR", du, name, cls, true)
            dc:JoinOneList(du)
          end
        end
        newuid[k] = du

        --
        -- And with the flags what the policy keeps about them, a copy running the policy its source runs. It goes out in
        -- the MDUSR that carries the whole entry, only where either side has anything to say.
        --
        if (du and qf.copycfgdlg.do_copyflags) then
          dc:SetUserEnchanter(du, sc:IsEnchanter(k))
          dc:SetUserFrozen(du, sc:IsFrozen(k))

          if (sc:UserPData(k) ~= nil or dc:UserPData(du) ~= nil) then
            dc:SetUserPData(du, sc:UserPData(k))
          end
        end
      end

      --
      -- Whose alt somebody is is nothing the copy has to carry. It is a fact about the human, held once by the mod, so the
      -- new config reads the same links the old one did the moment it holds the same people.
      --
      -- Now copy the roll lists (if any) we have been asked to copy.
      --
      for k,v in pairs(qf.copycfgdlg.copylist) do
        if (v) then
          --
          -- We can use the handy SMLST event to set the member list. That event was originally intended for the CSV import
          -- function but it serves our purposes perfectly as we can set the entire member list with one event. No need to
          -- recreate lists or anything like that.
          --
          local sl = sc.lists[k]
          local dlid = dc:FindList(sl.name)
          if (not dlid) then
            --
            -- Need to create the list
            --
            -- The source list's own name, reproduced, so a short one made before there was a minimum still comes across.
            local rv, ri = dc:CreateNewList(sl.name, nil, nil, true)
            assert(not rv)
            dlid = ri
          end
          local dul = {}
          for kk,vv in ipairs(sl.users) do
            assert(newuid[vv])
            tinsert(dul, newuid[vv])
          end
          local dus = tconcat(dul, "")

          --
          -- A copy keeps what the policy said about the source's list as well as who was on it. The uids differ between
          -- the two configs, which is the policy's to reconcile inside its own block, the platform having no way to know
          -- what is in one.
          --
          local _, pdata = sc:PolicyCall("ListInfo", nil, k)

          dc:SetMemberList(dus, dlid, pdata)
        end
      end

      --
      -- Copy the list options with a CHLST event each. This is a second pass because a list's extra list is found by name
      -- in the destination, and the first pass creates lists in no particular order.
      --
      if (qf.copycfgdlg.do_copycfg) then
        local lpol = dc:GetPolicy()

        for k,v in pairs(qf.copycfgdlg.copylist) do
          if (v) then
            local sl = sc.lists[k]
            local dlid = dc:FindList(sl.name)
            local dl = dc.lists[dlid]
            dl.sortorder = sl.sortorder
            dl.def_rank = sl.def_rank
            dl.strictcfilter = sl.strictcfilter
            dl.strictrfilter = sl.strictrfilter
            -- The source's extra list is the destination's list of that name, if it has one.
            if (sl.extralist and sl.extralist ~= "0" and sc.lists[sl.extralist]) then
              dl.extralist = dc:FindList(sc.lists[sl.extralist].name) or "0"
            end
            dl.tethered = sl.tethered
            dl.altdisp = sl.altdisp
            -- The policy's own options come across as its settings do, a copy running the policy it was made for.
            dc:SetListOptions(dlid, lpol.handle, sc:ListOptions(k, lpol.handle))
            dc:SendListOptions(dlid)
          end
        end
      end

      --
      -- Next up are the item options, if we have been asked to copy them. We only copy items that do not exist. If the item
      -- exists in the new config we leave it completely untouched.
      --
      if (qf.copycfgdlg.do_copyitems) then
        local sil = sc.items
        local dil = dc.items

        for k,v in pairs(sil) do
          if (not dil[k]) then
            dc:AddItem(k, v.ilink)
            K.CopyTable(v, dil[k])
            --
            -- Obviously the UID for assign to next user will be different, so we adjust for that.
            --
            if (v.user) then
              dil[k].user = newuid[v.user]
              assert(dil[k].user)
            end
            dc:SendCHITM(k, dil[k])
          end
        end
      end

      --
      -- If we have been asked to preserve all of the config options then copy them over now, but we will have to adjust the
      -- disenchanter UIDs. Who owns the copy, and which policy it runs, are not options: the copy belongs to whoever made
      -- it, and runs the policy it was made for.
      --
      if (qf.copycfgdlg.do_copycfg) then
        --
        -- The settings are the two strings, cfg.settings being only a way of reading them by name, so the strings are what
        -- is copied. The disenchanters name the source's uids, and are put back as the copy's own for the same people.
        --
        dc.opts, dc.vals = sc.opts, sc.vals

        local denchers = {}

        for k, v in pairs(sc.settings.denchers) do
          denchers[k] = newuid[v]
        end

        dc.settings.denchers = denchers

        --
        -- The policy's own settings are copied along with the platform's. A copy runs the policy it was made for, so both
        -- blocks belong to that one policy and nothing is being carried across from another.
        --
        local pol = this:GetPolicy(newid)

        if (pol) then
          K.CopyTable(sc:PolicySettings(pol.handle), dc:PolicySettings(pol.handle))

          -- Its data replaces the new config's rather than joining it, an entry the source had deleted staying gone.
          dc.pdata = dc.pdata or {}
          dc.pdata[pol.handle] = K.CopyTable(sc:PolicyData(pol.handle), {})
        end

        --
        -- The one setting that names a list names one of the source's, which the destination holds under an id of its own
        -- if at all. A second such setting joins the list this walks.
        --
        for _, which in ipairs({ "def_list" }) do
          local slid = sc.settings[which]

          if (slid and slid ~= "0") then
            dc.settings[which] = (sc.lists[slid] and dc:FindList(sc.lists[slid].name)) or "0"
          end
        end

        dc.channel = sc.channel or CHANNEL_OTHER
      end

      --
      -- If they want to copy co-admins do so now.
      --
      if (qf.copycfgdlg.do_copyadm) then
        for k,v in pairs(sc.admins) do
          local uid = newuid[k]

          if (uid and not dc.admins[uid]) then
            add_coadmin(this, uid, dc)
          end
        end
      end

      this:FullRefresh(true)

      qf.copycfgdlg:Hide()
    end

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    ret:Catch("OnHide", function(t, evt)
      if (qf.copycfgdlg.isshown) then
        qf.copycfgdlg.isshown = nil
        qf.mainwin:Show()
      end
    end)
  end

  qf.copycfgdlg.do_copyadm = false
  qf.copycfgdlg.do_copyflags = true
  qf.copycfgdlg.do_copycfg = true
  qf.copycfgdlg.do_copyraid = false
  qf.copycfgdlg.do_copyitems = false
  qf.copycfgdlg.copylist = {}
  qf.copycfgdlg.newname = newname or ""
  qf.copycfgdlg.newid = newid or 0
  qf.copycfgdlg.cfgid = cfgid

  -- The one this is a copy of. The dialog holds its id rather than the config itself, a config being able to go while it is up.
  local src = this:Config(cfgid)

  --
  -- Each time we are called we need to populate the dropdown list so that it has the correct list of lists.
  --
  local function set_list(btn)
    qf.copycfgdlg.copylist[btn.value] = btn.checked
  end

  --
  -- A policy that runs every config on one list of its own (onelist) has nothing to offer here, the copy being made with its
  -- own list and everybody it copies going onto it.
  --
  local items = {}
  for k,v in pairs(src:GetPolicy().onelist and {} or src.lists) do
    local ti = { text = v.name, value = k, keep = true, func = set_list }
    ti.checked = function()
      return qf.copycfgdlg.copylist[k]
    end
    tinsert(items, ti)
  end
  tsort(items, function(a,b)
    return strlower(a.text) < strlower(b.text)
  end)
  qf.copycfgdlg.ltocopy:UpdateItems(items)
  qf.copycfgdlg.ltocopy:SetEnabled(#items > 0)

  qf.copycfgdlg.copyadm:SetChecked(qf.copycfgdlg.do_copyadm)
  qf.copycfgdlg.copyflags:SetChecked(qf.copycfgdlg.do_copyflags)
  qf.copycfgdlg.copycfg:SetChecked(qf.copycfgdlg.do_copycfg)
  qf.copycfgdlg.copyitem:SetChecked(qf.copycfgdlg.do_copyitems)

  if (not qf.copycfgdlg.newid or qf.copycfgdlg.newid == 0) then
    qf.copycfgdlg.str4:Hide()
    qf.copycfgdlg.dest:Show()
    qf.copycfgdlg.dest:SetText(qf.copycfgdlg.newname)
  else
    qf.copycfgdlg.dest:Hide()
    qf.copycfgdlg.str4:Show()
    qf.copycfgdlg.str4:SetText(qf.copycfgdlg.newname)
  end
  qf.copycfgdlg.str2:SetText(src.name)

  qf.copycfgdlg.isshown = shown
  qf.mainwin:Hide()
  qf.copycfgdlg:SetTitleText(konfer.apol:WindowTitle(L["Copy configuration"]))
  qf.copycfgdlg:Show()
end

--
-- Copy config CFGID, which the command does and the Admin tab's Copy button does. There is one window and one widget table,
-- so the dialog is raised in front of whichever page the user is on, and a config of a policy the window is not showing is
-- copied just the same: a copy is an operation on stored data rather than on anything on screen.
--
function cfgm:Copy(newname, newid)
  if (not self or not qf.mainwin) then
    return
  end

  copy_space_button(konfer, self.id, newname, newid, qf.mainwin:IsShown())
end

--
-- Whether two values of a setting are the same, a table of them, the disenchanters, being the same when every entry is.
--
local function same_setting(a, b)
  if (type(a) ~= "table" or type(b) ~= "table") then
    return a == b
  end

  for k, v in pairs(a) do
    if (b[k] ~= v) then
      return false
    end
  end

  for k, v in pairs(b) do
    if (a[k] ~= v) then
      return false
    end
  end

  return true
end

--
-- Set one of config CFGID's settings to VAL, a plain value or, for the disenchanters, the whole table of them. Exported
-- because a policy builds its own options into the panel and has to be able to write them, and the settings table is the
-- platform's. A config that is not there takes nothing, rather than the setting landing in some other config.
--
-- A setting is the config's, so a change reaches the other admins as a CHSET event, and NOCMD is set when applying one of
-- theirs. Setting what is there already is no change and sends nothing, which is what every widget being set from the
-- config on a refresh amounts to.
--
function cfgm:ChangeSetting(which, val, nocmd)
  local cfg = self.id and self

  if (not cfg or not cfg.settings or same_setting(cfg.settings[which], val)) then
    return
  end

  -- A table of the caller's is copied, so that changing it afterwards is not changing the setting behind the event's back.
  if (type(val) == "table") then
    val = K.CopyTable(val, {})
  end

  cfg.settings[which] = val

  --
  -- The event carries the whole of both strings rather than the one setting that moved. They are small, an admin who missed
  -- an earlier one still ends up holding exactly what the sender holds, and there is no name on the wire to look up and
  -- nothing per setting to validate: what arrives either is two strings of the right shape or is not.
  --
  if (not nocmd) then
    self:AdminEvent("CHSET", cfg.opts, cfg.vals)
  end

  -- The raid's disenchanters are the active config's, and change with it.
  if (which == "denchers" and self:IsActive()) then
    konfer:UpdateDenchers()
  end
end

--
-- How a config's settings are stored, and how they go on reading by name.
--
-- The owner of a config decides its settings and they travel with it, so they have to be small: a whole config goes out in
-- one broadcast and a change goes out on the event stream. They are kept as two strings on the config, cfg.opts holding one
-- character per yes-or-no setting and cfg.vals the rest with a colon between them, in the order konfer.copts and
-- konfer.cvals declare. That order is the format; see the warning over those two lists.
--
-- Nothing outside this block knows that. cfg.settings is a table with no contents of its own and a metatable that reads a
-- character out of one string and writes it back, so every caller goes on saying cfg.settings.auto_bid.
--
-- **A metatable is not saved.** WoW writes the raw contents of a table to the saved variables, which is why the two strings
-- are real fields and cfg.settings is empty, and it is also why a config read back at login arrives with a bare table and
-- no proxy on it. konfer:MakeConfig puts it back, and every path that produces a config calls it -- startup, creation, a
-- config arriving from anybody, and a copy. Miss one and a real setting reads nil, which is the quietest possible way to be
-- wrong, so konfer:MakeAllConfigs walks the lot at startup rather than trusting the paths.
--

--
-- Where each setting stands, by name, and which of the two strings it is in. Built once from the declared order.
--
local opt_slot, val_slot = {}, {}

for i, v in ipairs(konfer.copts) do
  opt_slot[v[1]] = i
end

for i, v in ipairs(konfer.cvals) do
  val_slot[v[1]] = i
end

--
-- One field of cfg.vals, as the string it is stored as. A table is written in fixed width slots so that an empty one in the
-- middle keeps the ones after it where they are.
--
local function encode_val(how, v)
  if (how == "uids") then
    local out = {}

    for i = 1, konfer.MAX_DENCHERS do
      out[i] = (v and v[i]) or "----"
    end

    return tconcat(out)
  end

  if (how == "places") then
    local out = {}

    for i = 1, konfer.MAX_RANK_ORDER do
      local p = (v and tonumber(v[i])) or 1

      out[i] = tostring(max(0, min(konfer.MAX_RANK_ORDER, p) - 1))
    end

    return tconcat(out)
  end

  return tostring(v)
end

local function decode_val(how, s, dflt)
  if (how == "uids") then
    local out = {}

    for i = 1, konfer.MAX_DENCHERS do
      local u = strsub(s, i * 4 - 3, i * 4)

      out[i] = (u ~= "----" and u ~= "") and u or nil
    end

    return out
  end

  if (how == "places") then
    local out = {}

    for i = 1, konfer.MAX_RANK_ORDER do
      local c = tonumber(strsub(s, i, i))

      out[i] = c and (c + 1) or 1
    end

    return out
  end

  if (type(dflt) == "number") then
    return tonumber(s) or dflt
  end

  return s
end

--
-- Function: konfer:DefaultOpts()
-- Function: konfer:DefaultVals()
-- Purpose : The two strings a config with nothing set yet holds, built from the declared defaults.
--
function konfer:DefaultOpts()
  local out = {}

  for i, v in ipairs(self.copts) do
    out[i] = v[2] and "Y" or "N"
  end

  return tconcat(out)
end

function konfer:DefaultVals()
  local out = {}

  for i, v in ipairs(self.cvals) do
    out[i] = encode_val(v[3], v[2])
  end

  return tconcat(out, ":")
end

--
-- Reading and writing one setting by name. The strings are the only copy, so there is nothing to keep in step. A proxy holds
-- its config weakly (__mode), so that a config deleted is not kept alive by its own proxy.
--
local settings_meta = {
  __mode = "v",

  __index = function(t, name)
    local cfg = rawget(t, "cfg")
    local slot = opt_slot[name]

    --
    -- A string saved before a setting was appended ends short of it, and a setting it does not reach is its default.
    --
    if (slot) then
      local c = strsub(cfg.opts or "", slot, slot)

      if (c == "") then
        return konfer.copts[slot][2] and true or false
      end

      return c == "Y"
    end

    slot = val_slot[name]

    if (not slot) then
      return nil
    end

    local spec = konfer.cvals[slot]
    local fields = { strsplit(":", cfg.vals or "") }

    -- As above, a field the string does not reach is the setting's default.
    if (fields[slot] == nil) then
      fields = { strsplit(":", konfer:DefaultVals()) }
    end

    return decode_val(spec[3], fields[slot], spec[2])
  end,

  __newindex = function(t, name, v)
    local cfg = rawget(t, "cfg")
    local slot = opt_slot[name]

    if (slot) then
      local s = cfg.opts or ""
      local defs = konfer:DefaultOpts()

      -- Whatever a short string does not reach is filled with its defaults, so every setting keeps its own place.
      if (#s < #defs) then
        s = s .. strsub(defs, #s + 1)
      end

      cfg.opts = strsub(s, 1, slot - 1) .. (v and "Y" or "N") .. strsub(s, slot + 1)
      return
    end

    slot = val_slot[name]

    if (not slot) then
      return
    end

    local fields = { strsplit(":", cfg.vals or "") }
    local defs = { strsplit(":", konfer:DefaultVals()) }

    for i = #fields + 1, #defs do
      fields[i] = defs[i]
    end

    fields[slot] = encode_val(konfer.cvals[slot][3], v)
    cfg.vals = tconcat(fields, ":")
  end,
}

--
-- A CONFIG IS AN OBJECT
--
-- Its fields are the data the database saves and everything that acts on one is a method in konfer.configmethods, reached
-- through the metatable below. Nothing is written onto the config itself, so what the saved variables hold and what a
-- broadcast reads are still the data and nothing else.
--
-- cfg.settings is the one name that is not a method: the proxy over the two settings strings, made the first time a config
-- is asked for it and kept here, off the config, for the same reason.
--
local proxies = setmetatable({}, { __mode = "k" })

local cfg_meta = {
  __index = function(cfg, key)
    if (key ~= "settings") then
      return cfgm[key]
    end

    local p = proxies[cfg]

    if (not p) then
      p = setmetatable({ cfg = cfg }, settings_meta)
      proxies[cfg] = p
    end

    return p
  end,
}

--
-- What a config works out rather than stores, kept off the config for exactly that reason, since every raw field of one is
-- written to the saved variables. Keyed by the config itself rather than by its id, so a config that is deleted takes its
-- session data with it and there is nothing left to go stale against the filing.
--
--   myuid   Which user in this config this character is, or nil. See cfg:MyUid.
--   bykuid  The config's uids indexed by the KUID each one stands for, or nil when it wants rebuilding. Built on demand by
--           cfg:FindKuid and cfg:FindUser and dropped by cfg:ForgetUidIndex wherever the user list changes. See ForgetUidIndex
--           for why it is thrown away rather than kept in step.
--
local session = setmetatable({}, { __mode = "k" })

function cfgm:Session()
  local cs = session[self]

  if (not cs) then
    cs = {}
    session[self] = cs
  end

  return cs
end

--
-- Function: konfer:MakeConfig(cfgid, cfg)
-- Purpose : Turn the plain table CFG into a config object filed under CFGID: its id, the two settings strings if it has
--           none, the settings proxy and the methods. Safe to call on one that is already an object, which is what lets
--           every path that produces a config call it without checking.
--
-- A metatable is not saved, so this has to run again on every config at every login, and on every config that arrives from
-- another client. konfer:SetConfig and konfer:MakeAllConfigs are the two places that do it.
--
function konfer:MakeConfig(cfgid, cfg)
  if (type(cfg) ~= "table") then
    return cfg
  end

  --
  -- A config knows which id it is filed under. Nothing here needs it, every method having the config itself in hand, but
  -- the filing does, and so do the wire, the event stream and everything else that names a config rather than holding one.
  --
  cfg.id = cfgid

  cfg.opts = cfg.opts or self:DefaultOpts()
  cfg.vals = cfg.vals or self:DefaultVals()

  --
  -- The settings proxy comes from the metatable and is never on the config, so nothing of it is saved. A config saved while
  -- it was written there still carries an empty one, which would hide the proxy, and it goes.
  --
  rawset(cfg, "settings", nil)

  return setmetatable(cfg, cfg_meta)
end

--
-- Function: konfer:MakeAllConfigs()
-- Purpose : Put the methods and the settings proxy back on every config of every policy. Run at startup, because neither
--           survives being saved and a config that missed this would error on its first method call.
--
--
-- Every config of every policy, keyed by id. For the handful of things that genuinely span them, which ask each policy in
-- turn rather than reaching into a pile they share.
--
function konfer:AllConfigs()
  local out = {}

  for _, pol in pairs(self.policies) do
    for cfgid, cfp in pairs(self:PolicyConfigs(pol)) do
      out[cfgid] = cfp
    end
  end

  return out
end

function konfer:MakeAllConfigs()
  for _, pol in pairs(self.policies) do
    for cfgid, cfg in pairs(self:PolicyConfigs(pol)) do
      self:MakeConfig(cfgid, cfg)
    end
  end
end

--
-- A policy's own settings for a config, which are not the platform's.
--
-- cfg.settings is the platform's, one flat table of the things every policy has, and cfg:ChangeSetting carries a change
-- to it as CHSET. cfg.psettings is a block per policy, made from what that policy declares in its descriptor's defaults,
-- and a change to one travels as PSSET. Two tables and two commands rather than one of each, so that neither side has to
-- know what is in the other's and a policy can name a setting whatever it likes without checking the platform first.
--
-- Keyed by handle although a config belongs to exactly one policy, so that a config which has changed hands, or one a
-- policy is asked about that was never its own, keeps each policy's answers apart rather than reading the other's.
--

--
-- Function: cfg:PolicySettings(handle)
-- Purpose : The settings block policy HANDLE keeps in config CFGID, made from that policy's declared defaults the first
--           time it is asked for. On demand rather than when the config is made, because a policy registered later -- one
--           an addon loads on demand -- would otherwise have no block in any config that already existed.
-- Returns : Table, or nil for a config or a policy there is no such thing as.
--
function cfgm:PolicySettings(handle)
  local cfg = self.id and self
  local pol = handle and konfer.policies[handle]

  if (not cfg or not pol) then
    return nil
  end

  cfg.psettings = cfg.psettings or {}
  cfg.psettings[handle] = cfg.psettings[handle] or {}

  --
  -- Anything the policy declares and the block does not have yet takes its default. That covers a block that has never
  -- existed, one from a client whose build declared fewer settings than this one, and a setting added since this config was
  -- last touched, so a declared setting is never nil for having arrived late.
  --
  local ps = cfg.psettings[handle]

  for k, v in pairs(pol.defaults or {}) do
    if (ps[k] == nil) then
      ps[k] = (type(v) == "table") and K.CopyTable(v, {}) or v
    end
  end

  return ps
end

--
-- Function: cfg:ChangePolicySetting(handle, which, val, nocmd)
-- Purpose : Set one of policy HANDLE's own settings in CFGID. The platform's twin of this is cfg:ChangeSetting, and
--           everything said there applies here: setting what is there already is no change and sends nothing, a table is
--           copied so that changing it afterwards is not changing the setting behind the event's back, and NOCMD is set
--           when applying an event that arrived rather than one this client is making.
--
--           A policy reaches this through pol:ChangeSetting rather than by name, which is what Policy.lua injects it as.
--
function cfgm:ChangePolicySetting(handle, which, val, nocmd)
  local ps = self:PolicySettings(handle)

  if (not ps or same_setting(ps[which], val)) then
    return
  end

  if (type(val) == "table") then
    val = K.CopyTable(val, {})
  end

  ps[which] = val

  --
  -- The whole block rather than the setting that moved, which is what CHSET does for the platform's and for the same
  -- reason: an admin who missed an earlier one still ends up holding exactly what the sender holds. A policy's block is a
  -- handful of named values, so it is left named rather than packed into a string the way the platform's is. The order of
  -- a positional format would be a contract an external policy had to keep, and reordering their own list would silently
  -- reinterpret every config they had ever saved.
  --
  if (not nocmd) then
    self:AdminEvent("PSSET", handle, ps)
  end
end

--
-- Function: cfg:ChangeSettings(changes)
-- Purpose : Set several of the platform's settings at once, CHANGES being a table of name to value, and send one CHSET for
--           the lot. This is what a page's save is: everything the user changed on it going out as one event, however many
--           there were. What is already set to the same is no change, and nothing at all changing sends nothing.
-- Returns : True when anything changed.
--
function cfgm:ChangeSettings(changes)
  local moved = false

  for which, val in pairs(changes) do
    if (not same_setting(self.settings[which], val)) then
      self:ChangeSetting(which, val, true)
      moved = true
    end
  end

  if (moved) then
    self:AdminEvent("CHSET", self.opts, self.vals)
  end

  return moved
end

--
-- Function: cfg:ChangePolicySettings(handle, changes)
-- Purpose : The same for policy HANDLE's own settings, one PSSET carrying the whole block.
-- Returns : True when anything changed.
--
function cfgm:ChangePolicySettings(handle, changes)
  local ps = self:PolicySettings(handle)
  local moved = false

  if (not ps) then
    return false
  end

  for which, val in pairs(changes) do
    if (not same_setting(ps[which], val)) then
      self:ChangePolicySetting(handle, which, val, true)
      moved = true
    end
  end

  if (moved) then
    self:AdminEvent("PSSET", handle, ps)
  end

  return moved
end

--
-- Function: konfer:CleanPolicySettings(handle, block)
-- Purpose : BLOCK with everything taken out that policy HANDLE does not declare, and everything whose value is not the kind
--           it declared. What arrives from another client is that client's word for what a setting is, and the only thing
--           that makes one ours is this policy saying it has one by that name.
-- Returns : Table, and an empty one for a policy this client does not run.
--
local function clean_declared(declared, block)
  local out = {}

  if (not declared or type(block) ~= "table") then
    return out
  end

  for k, v in pairs(block) do
    if (declared[k] ~= nil and type(v) == type(declared[k])) then
      out[k] = (type(v) == "table") and K.CopyTable(v, {}) or v
    end
  end

  return out
end

function konfer:CleanPolicySettings(handle, block)
  local pol = handle and self.policies[handle]

  return clean_declared(pol and pol.defaults, block)
end

--
-- Function: cfg:SetPolicySettings(handle, block)
-- Purpose : Take another client's whole block for policy HANDLE in CFGID. Built from that policy's declared defaults and
--           then written over with what arrived, so a setting the sender never mentioned lands on its default rather than
--           keeping whatever this client happened to have. That is what makes the whole block worth sending: what two
--           admins hold afterwards depends on the message and not on what either had before it.
--
function cfgm:SetPolicySettings(handle, block)
  local ps = self:PolicySettings(handle)

  if (not ps) then
    return
  end

  local clean = konfer:CleanPolicySettings(handle, block)
  local defaults = konfer.policies[handle].defaults or {}

  for k, v in pairs(defaults) do
    if (clean[k] ~= nil) then
      ps[k] = clean[k]
    else
      ps[k] = (type(v) == "table") and K.CopyTable(v, {}) or v
    end
  end
end

--
-- A policy's own data on a config, declared in its descriptor's configdata, is what it keeps there that is not a setting:
-- a collection edited an entry at a time, EP/GP's and DKP's awards. The platform keeps it in cfg.pdata, a block per policy
-- by handle as cfg.psettings is, carries it whole when a config travels whole (a broadcast, a full sync, a recovery and a
-- config copy), checks what arrives against what the policy declares, and never looks inside. Nothing of the platform's
-- changes it or sends it between admins: the policy's own events do, each through AddEvent, so an entry changed is the one
-- entry sent and a setting changed beside it cannot carry an older copy of the rest.
--

--
-- Function: cfg:PolicyData(handle)
-- Purpose : The data block policy HANDLE keeps on the config, made from its declared configdata the first time it is asked
--           for, and with any declared entry it lacks filled in, for the reasons cfg:PolicySettings gives.
-- Returns : Table, or nil for a config or a policy there is no such thing as.
--
function cfgm:PolicyData(handle)
  local cfg = self.id and self
  local pol = handle and konfer.policies[handle]

  if (not cfg or not pol) then
    return nil
  end

  cfg.pdata = cfg.pdata or {}
  cfg.pdata[handle] = cfg.pdata[handle] or {}

  local pd = cfg.pdata[handle]

  for k, v in pairs(pol.configdata or {}) do
    if (pd[k] == nil) then
      pd[k] = (type(v) == "table") and K.CopyTable(v, {}) or v
    end
  end

  return pd
end

--
-- Function: konfer:CleanPolicyData(handle, block)
-- Purpose : BLOCK with everything taken out that policy HANDLE does not declare in its configdata, and everything whose
--           value is not the kind declared, as konfer:CleanPolicySettings does for its settings.
-- Returns : Table, and an empty one for a policy this client does not run.
--
function konfer:CleanPolicyData(handle, block)
  local pol = handle and self.policies[handle]

  return clean_declared(pol and pol.configdata, block)
end

--
-- A policy's own options on a list, declared in its descriptor's listoptions, are the same thing one level down: the
-- platform keeps them on the list as rl.poptions, a block per policy by handle as cfg.psettings is, checks whatever arrives
-- against what the policy declares, and never looks inside. They are edited on the Lists page's Config tab beside the
-- list's own options, and travel with those: after the platform's fields in CHLST, in the list's row when a config travels
-- whole, and in a config copy. A copied list has them because a copy is the whole list. A policy reads one with
-- pol:ListOption(cfgid, listid, name).
--

--
-- Function: cfg:ListOptions(listid, handle)
-- Purpose : The options block policy HANDLE keeps on list LISTID, made from its declared listoptions the first time it is
--           asked for, and with any declared option it lacks filled in, for the reasons cfg:PolicySettings gives.
-- Returns : Table, or nil for a list or a policy there is no such thing as.
--
function cfgm:ListOptions(listid, handle)
  local rl = listid and self.lists[listid]
  local pol = handle and konfer.policies[handle]

  if (not rl or not pol) then
    return nil
  end

  rl.poptions = rl.poptions or {}
  rl.poptions[handle] = rl.poptions[handle] or {}

  local lo = rl.poptions[handle]

  for k, v in pairs(pol.listoptions or {}) do
    if (lo[k] == nil) then
      lo[k] = (type(v) == "table") and K.CopyTable(v, {}) or v
    end
  end

  return lo
end

--
-- Function: konfer:CleanListOptions(handle, block)
-- Purpose : BLOCK with everything taken out that policy HANDLE does not declare as a list option, and everything whose value
--           is not the kind it declared, as konfer:CleanPolicySettings does for its settings.
-- Returns : Table, and an empty one for a policy this client does not run.
--
function konfer:CleanListOptions(handle, block)
  local pol = handle and self.policies[handle]

  return clean_declared(pol and pol.listoptions, block)
end

--
-- Function: cfg:SetListOptions(listid, handle, block)
-- Purpose : Take BLOCK as the whole of policy HANDLE's options on list LISTID, an option it leaves out landing on its
--           default, so that what two admins hold afterwards depends on the message and not on what either had before it.
--           Writes the list and sends nothing. Saving the Config tab, CHLST and a config arriving whole all come here.
--
function cfgm:SetListOptions(listid, handle, block)
  local lo = self:ListOptions(listid, handle)

  if (not lo) then
    return
  end

  local clean = konfer:CleanListOptions(handle, block)

  for k, v in pairs(konfer.policies[handle].listoptions or {}) do
    if (clean[k] ~= nil) then
      lo[k] = clean[k]
    else
      lo[k] = (type(v) == "table") and K.CopyTable(v, {}) or v
    end
  end
end


--
-- Guild rank filtering. A config's rank order says where each of the guild's ranks stands, a number from 1 to
-- konfer.MAX_RANK_ORDER, and ranks sharing a place are equivalent: with the guild master, their alt, the officers and theirs
-- all standing at 1, a filter set to any of the four admits all four. That is what the order is for, a guild's rank list
-- being an ordering of people by office where a raid cares about an ordering by standing, and the two agreeing only by luck.
--
-- Places are compared rather than rank indices everywhere a filter is applied, so the four helpers below are the only code
-- that knows the order exists. Filtering is offered only while cfg.settings.rank_filter is set and only to a character with
-- a guild, but the helpers answer whatever it says: a caller holding a filter has already been through those gates, and
-- somewhere further down the line is the wrong place to discover the answer is meaningless.
--

--
-- Function: cfg:RankOrder(rank)
-- Purpose : Where guild rank RANK stands in CFGID's rank order, the number its owner gave it in the Rank Order dialog. A
--           rank the order says nothing about stands at 1, so an order nobody has touched puts the whole guild level and a
--           filter run against it admits every member of it. The order says which ranks outrank which, and until somebody
--           says so the mod does not guess: a guild's rank list is an ordering of people by office, and reading it as an
--           ordering by standing is exactly the assumption the order exists to replace.
-- Returns : A number from 1 to konfer.MAX_RANK_ORDER, or nil for a rank there is no such thing as.
--
function cfgm:RankOrder(rank)
  local rank = tonumber(rank)

  if (not rank or rank < 1 or rank > K.guild.numranks) then
    return nil
  end

  local cfg = self.id and self
  local order = cfg and cfg.settings and cfg.settings.rank_order

  return (order and order[rank]) or 1
end

--
-- Function: cfg:RankPermits(rank, filter)
-- Purpose : Whether a character of guild rank RANK passes a filter set to guild rank FILTER in CFGID. A filter of 0, or of
--           nothing at all, is no filter and admits everybody, which is what -None- in a rank dropdown means.
-- Returns : True if they may bid or roll, false if the filter shuts them out.
--
function cfgm:RankPermits(rank, filter)
  local filter = tonumber(filter)

  if (not filter or filter == 0) then
    return true
  end

  local fplace = self:RankOrder(filter)
  local rplace = self:RankOrder(rank)

  --
  -- A filter naming a rank this guild no longer has is a filter nobody can be measured against, so it is treated as none at
  -- all rather than as one that shuts the whole raid out. Somebody with no rank is not in the guild and never passes one.
  --
  if (not fplace) then
    return true
  end

  return rplace ~= nil and rplace <= fplace
end

--
-- Function: cfg:NextRank(rank)
-- Purpose : The guild rank a filter set to RANK widens to in CFGID, which is the first rank standing strictly lower in the
--           order than RANK does. Ranks sharing RANK's place are already admitted, so stepping onto one of those would widen
--           the filter to nobody new and read as a button that does nothing.
-- Returns : A guild rank index, or nil where there is nobody further down to let in.
--
function cfgm:NextRank(rank)
  local place = self:RankOrder(rank)

  if (not place) then
    return nil
  end

  --
  -- The nearest place below the current one, and the first rank standing at it. Ranks are walked in index order and the
  -- guild's own order is the tie-break, so widening twice from the same rank always takes the same two steps.
  --
  local best, bestrank = nil, nil

  for i = 1, K.guild.numranks do
    local ip = self:RankOrder(i)

    if (ip and ip > place and (not best or ip < best)) then
      best, bestrank = ip, i
    end
  end

  return bestrank
end

--
-- Function: cfg:RankFiltering()
-- Purpose : Whether guild rank filtering is on offer in CFGID: switched on there, and this character in a guild to be ranked
--           in. Every rank widget is enabled through this, so the two halves are asked in one place.
-- Returns : True or false.
--
function cfgm:RankFiltering()
  local cfg = self.id and self

  return (K.player.is_guilded and cfg and cfg.settings and cfg.settings.rank_filter) and true or false
end

--
-- Function: cfg:Channel()
-- Purpose : Where this config's traffic goes, CHANNEL_GUILD or CHANNEL_OTHER. A policy whose configs all talk one way says so
--           in its descriptor's channel, PUG's always over the raid, and that is the answer whatever the config holds.
--           Otherwise it is the config's own, the group where it holds nothing.
--
function cfgm:Channel()
  local pol = konfer.policies[self.policy]

  return (pol and pol.channel) or self.channel or CHANNEL_OTHER
end

--
-- A box holding TEXT, already selected, for the user to copy with Ctrl+C, titled TITLE and saying MSG over it. WoW gives
-- an addon no way to open a browser or a mail program, so this is what clicking a web or email address does: it puts the
-- address where the user can take it. One box serves every window, and anything typed into it puts the text straight
-- back, there being nothing in it to edit.
--
local copybox = nil

local function show_copy_box(title, msg, text)
  if (not copybox) then
    copybox = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE", name = "KonferCopyTextDialog", title = konfer:WindowTitle(title),
      border = true, width = 380, height = 120, level = 64, canmove = true, canresize = false, escclose = true,
      blackbg = true, okbutton = true,
    })

    copybox.msg = KUI:CreateStringLabel({ x = 5, y = 0, width = 340, font = "GameFontNormal", text = msg }, copybox)

    copybox.ebox = KUI:CreateEditBox({ x = "CENTER", y = 0 - copybox.msg:GetHeight() - KUI.WIDGET_GAP, width = 330, len = 256 },
      copybox)
    copybox.ebox:Catch("OnValueChanged", function(this, evt, newv, user)
      if (user) then
        this:SetText(copybox.text)
        this:HighlightText()
      end
    end)
  end

  copybox.text = text
  copybox:SetTitleText(konfer:WindowTitle(title))
  copybox.msg:SetText(msg)
  copybox:Show()
  copybox.ebox:SetText(text)
  copybox.ebox:HighlightText()
  copybox.ebox:SetFocus()
end

--
-- The Rank Order dialog, opened by the Rank Order button in the Options panel on the Admin tab. It is one row per guild
-- rank, the rank's own name and a box holding the place it stands at, and it edits the rank order of the config the tab has
-- selected. See cfg:RankOrder for what a place means.
--
-- konfer.MAX_RANK_ORDER rows are built the first time it opens and then kept, WoW having no way to destroy a frame, and the
-- ones past this guild's rank count are hidden. A guild has at most that many ranks, so what is built is always enough. The
-- rows are filled and the dialog sized to them every time it opens rather than once, because the guild's ranks may have been
-- renamed, added to or cut away since the last time, and because a different config may be selected with a different order in it.
--
-- How far a rank's box stands from the name beside it, the pair being one block whatever width the dialog turns out to be.
local RANKORDER_GAP = 4 * KUI.WIDGET_GAP

--
-- How wide the dialog is. Fixed rather than measured, because what it has to hold is not the rows: it is the title plate,
-- which carries the policy's name in front of this dialog's, and a plate fitted exactly to its own words leaves the rows
-- huddled under a frame that is all title. A guild whose rank names need more than this gets more.
--
local RANKORDER_WIDTH = 400

--
-- How far right the Order heading stands of the column it titles. The boxes under it are anchored by their frames, and the
-- kit draws the text field wider than the frame it is given, so a heading whose right edge is square with theirs reads as
-- sitting left of them. This is the word's own offset and nothing else moves with it.
--
local RANKORDER_HEADING_NUDGE = 6

local rankorderdlg = nil

local function rank_order_dialog(self, cfgid)
  local cfg = self:Config(cfgid)

  if (not cfg or not K.player.is_guilded) then
    return
  end

  --
  -- The guild's own words are what the rows are named with, so they are asked for afresh rather than taken from whenever
  -- this character last happened to hear about them. Nothing is told, the dialog being about to read them itself.
  --
  K.UpdatePlayerAndGuild(true)

  if (not rankorderdlg) then
    local ret = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE", name = "KonferRankOrderDialog", title = konfer.apol:WindowTitle(L["Rank order"]),
      border = true, width = 300, height = 200, canmove = true, canresize = false, escclose = true, blackbg = true,
      buttons = "CENTER",
      okbutton = true, cancelbutton = true,
    })

    ret.header = KUI:CreateStringLabel({ x = 0, y = 0, text = L["Guild rank"], font = "GameFontNormal" }, ret)
    ret.orderheader = KUI:CreateStringLabel({ x = 0, y = 0, text = L["Order"], font = "GameFontNormal" }, ret)

    --
    -- The rows are anchored where they are filled rather than here, the name against the dialog's left hand edge and the box
    -- against its right, so that the two columns stand at the ends of whatever width this guild's rank names ask for.
    --
    ret.rows = {}

    for i = 1, konfer.MAX_RANK_ORDER do
      local row = {}

      row.name = KUI:CreateStringLabel({ x = 0, y = 0, text = "" }, ret)
      row.order = KUI:CreateEditBox({ x = 0, y = 0, numeric = true, len = 2, charwidth = 2 }, ret)

      row.name:Hide()
      row.order:Hide()
      ret.rows[i] = row
    end

    ret.OnAccept = function(t)
      local cfg = t.cfgid and self:Config(t.cfgid)

      t:Hide()

      --
      -- The config can have gone while the dialog was up, another admin's event being able to take it away at any moment.
      --
      if (not cfg) then
        return
      end

      --
      -- Built from nothing rather than written over, so that ranks the guild has since done away with leave with them rather
      -- than sitting in the order forever. A box is read as the place it says, an empty one as 1, which is where an order
      -- that says nothing puts a rank, and anything outside the range is pulled back into it: the box takes two digits so
      -- 99 can be typed, and refusing the whole dialog over one box would throw away every other change in it.
      --
      local order = {}

      for i = 1, K.guild.numranks do
        local place = tonumber(t.rows[i].order:GetText()) or 1

        order[i] = max(1, min(konfer.MAX_RANK_ORDER, place))
      end

      cfg:ChangeSetting("rank_order", order)
    end

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    ret:Catch("OnHide", function(t, evt)
      qf.mainwin:Show()
    end)

    rankorderdlg = ret
  end

  local rp = rankorderdlg

  rp.cfgid = cfgid

  --
  -- The title carries the policy's name as well as this dialog's and is set before anything is measured, because the plate
  -- is one of the three things the dialog has to be wide enough for and it measures itself against its own words.
  --
  rp:SetTitleText(konfer.apol:WindowTitle(L["Rank order"]))

  --
  -- How wide the rank name column has to be, which is the widest of this guild's own words and the word over them.
  --
  -- KUI:WidestString hands back the widest string along with its width, so each is taken on its own rather than passed
  -- straight on to something taking more than one argument.
  --
  local names = { L["Guild rank"] }

  for i = 1, K.guild.numranks do
    tinsert(names, K.guild.ranks[i])
  end

  local NAME_W = KUI:WidestString(names)
  local HDR_W = KUI:WidestString({ L["Order"] })
  local BOX_W = rp.rows[1].order:GetWidth()
  local ORDER_W = max(BOX_W, HDR_W)

  --
  -- The names and the boxes are one block, as wide as the longest rank name and the box beside it, and the block stands in
  -- the middle of the dialog. The dialog is wider than the block, so this is the inset that keeps the two columns together
  -- instead of letting that extra width push them onto opposite walls.
  --
  local ROWS_W = NAME_W + RANKORDER_GAP + ORDER_W
  local inner = max(ROWS_W, RANKORDER_WIDTH - rp.rings.left - rp.rings.right)
  local side = (inner - ROWS_W) / 2

  rp:SetWidth(inner + rp.rings.left + rp.rings.right)

  local ypos = 0 - rp.header:GetHeight() - KUI.WIDGET_GAP

  for i = 1, konfer.MAX_RANK_ORDER do
    local row = rp.rows[i]

    if (i <= K.guild.numranks) then
      row.name:SetText(K.guild.ranks[i])
      row.order:SetText(tostring(cfg:RankOrder(i) or 1))

      --
      -- The name sits on the middle of the box beside it rather than on its top, a line of text being shorter than the box
      -- the kit draws, so that a row reads across.
      --
      row.name:ClearAllPoints()
      row.name:SetPoint("TOPLEFT", rp.content, "TOPLEFT", side, ypos - (row.order:GetHeight() - row.name:GetHeight()) / 2)

      row.order:ClearAllPoints()
      row.order:SetPoint("TOPRIGHT", rp.content, "TOPRIGHT", 0 - side, ypos)

      row.name:Show()
      row.order:Show()

      ypos = ypos - row.order:GetHeight() - KUI.WIDGET_GAP
    else
      row.name:Hide()
      row.order:Hide()
    end
  end

  -- Each heading stands over its own column, so the two take the same insets the rows below them do.
  rp.header:ClearAllPoints()
  rp.header:SetPoint("TOPLEFT", rp.content, "TOPLEFT", side, 0)

  rp.orderheader:ClearAllPoints()
  rp.orderheader:SetPoint("TOPRIGHT", rp.content, "TOPRIGHT", RANKORDER_HEADING_NUDGE - side, 0)

  rp:SetHeight(0 - ypos - KUI.WIDGET_GAP + rp.rings.top + rp.rings.bottom)

  qf.mainwin:Hide()
  rp:Show()
end

--
-- A POLICY'S OWN TABS
--
-- The Config page's tabs of the active policy's own (ConfigTabs in Policy.lua), added after the platform's while it is the
-- active one and taken away when it stops being. Each is named with the policy's prefix, so no two policies' tabs share a
-- name, and a tab taken away is retired rather than destroyed, so that adding it again brings back what was built.
--
-- Each has its own unsaved changes, the policy's settings as "p." and the setting's name, for the window's current config as
-- the Loot tab's are, going out as one PSSET when its save bar is pressed.
--
local function policy_tab_name(pp, t)
  return pp.prefix .. t.name
end

local function policy_tab_pending(self, pp, tname)
  return self.mainwin:NewPending({
    page = self.CONFIG_PAGE, tab = tname,
    saved = function(key)
      local pk = key:match("^p%.(.+)$")
      local lcf = qf.admincfg and konfer:PolicyConfig(pp, qf.admincfg)

      if (not lcf or not pk) then
        return nil
      end

      return pp:Setting(pk, lcf.id)
    end,
    save = function(changes)
      local pol = {}
      local lcf = qf.admincfg and konfer:PolicyConfig(pp, qf.admincfg)

      if (not lcf) then
        return
      end

      for key, val in pairs(changes) do
        local pk = key:match("^p%.(.+)$")

        if (pk) then
          pol[pk] = val
        end
      end

      lcf:ChangePolicySettings(pp.handle, pol)
    end,
    reload = function()
      konfer:RefreshConfigPolicyTabs()
    end,
  })
end

-- Put PP's tabs on the Config page, or take them off.
local function show_policy_tabs(self, pp, onoff)
  for i, t in ipairs(pp.ConfigTabs or {}) do
    local tname = policy_tab_name(pp, t)

    if (onoff) then
      self.mainwin:AddTab(self.CONFIG_PAGE, {
        name = tname, text = t.text, order = t.order or (10 + i), adminonly = t.adminonly, owneronly = t.owneronly,
      })
    else
      self.mainwin:RemoveTab(self.CONFIG_PAGE, tname)
    end
  end
end

--
-- Build PP's tabs, once each: add the tab, build into it and give it its unsaved changes, and take it away again until PP is
-- the active policy. Built here, with the rest of the policy's panels, so that a fault in one shows when they are.
--
local function build_policy_tabs(self, pp)
  local kmt = self.mainwin:GetPage(self.CONFIG_PAGE)

  pp.configtabs = {}

  for i, t in ipairs(pp.ConfigTabs or {}) do
    local tname = policy_tab_name(pp, t)

    self.mainwin:AddTab(self.CONFIG_PAGE, {
      name = tname, text = t.text, order = t.order or (10 + i), adminonly = t.adminonly, owneronly = t.owneronly,
    })

    local rec = { def = t, client = kmt.tabsbyname[tname].content, pending = policy_tab_pending(self, pp, tname) }

    pp.configtabs[t.name] = rec
    konfer:PolicyHook(pp, "ConfigTabs.Construct", nil, t.Construct, rec.client, rec.pending)
  end

  show_policy_tabs(self, pp, false)
end

function konfer:InitialiseConfigUI()
  local arg
  local mainwin = self.mainwin
  local kmt = mainwin:GetPage(self.CONFIG_PAGE)

  qf.mainwin = mainwin

  --
  -- The loot tab is General options above Bid options above Roll options, each exactly as tall as what it holds, and blank
  -- space under them that takes whatever the window grows by. How tall the two panels are is known only once their options have been
  -- built, so they are made with no height here and given one at the end of each.
  --
  -- The tab is the platform's and has no room for a policy's section. A policy with loot options of its own puts them on a
  -- tab of its own on this page, through its descriptor's ConfigTabs, as EP/GP does its prices.
  --
  local loottab = kmt.tabsbyname[self.CONFIG_LOOT_TAB].content

  arg = {
    inset = 0, height = 0, topanchor = true, name = "KonferCfgLootSplit", toptitle = L["General options"],
    bottomborder = false, bottompadding = 0,
  }
  loottab.hsplit = KUI:CreateHSplit(arg, loottab)

  arg = {
    inset = 0, height = 0, topanchor = true, name = "KonferCfgBidSplit", toptitle = L["Bid options"],
    bottomborder = false, bottompadding = 0,
  }
  loottab.bidsplit = KUI:CreateHSplit(arg, loottab.hsplit.bottomframe)

  arg = {
    inset = 0, height = 0, topanchor = true, name = "KonferCfgRollSplit", toptitle = L["Roll options"],
    bottomborder = false,
  }
  loottab.rollsplit = KUI:CreateHSplit(arg, loottab.bidsplit.bottomframe)

  qf.lootopts = loottab.hsplit.topframe
  qf.bidopts = loottab.bidsplit.topframe
  qf.rollopts = loottab.rollsplit.topframe
  qf.cfgadmin = kmt.tabsbyname[self.CONFIG_ADMIN_TAB].content

  --
  -- The tab's unsaved changes, for the active policy's current config. A key is a platform setting by its own name, or one of
  -- the active policy's own settings as "p." and its name. Saving sends one CHSET for the platform's and one PSSET for the
  -- policy's, however many were changed.
  --
  -- The tab edits two of the policy's: the quality threshold under which an item is not offered at all, and what happens
  -- when nobody bids. Both are questions every policy has to answer, which is why the widgets are on a platform page, and both
  -- are answered by the policy, which is why the answers are kept in its own block.
  --
  local function lootkey(key)
    return key:match("^p%.(.+)$")
  end

  qf.lootpending = self.mainwin:NewPending({
    page = self.CONFIG_PAGE, tab = self.CONFIG_LOOT_TAB,
    saved = function(key)
      local pp = konfer.apol

      if (not pp or not pp.cfg) then
        return nil
      end

      local pk = lootkey(key)

      if (pk) then
        return pp:Setting(pk, pp.currentid)
      end

      return pp.cfg.settings[key]
    end,
    save = function(changes)
      local pp = konfer.apol
      local plat, pol = {}, {}

      if (not pp or not pp.cfg) then
        return
      end

      for key, val in pairs(changes) do
        local pk = lootkey(key)

        if (pk) then
          pol[pk] = val
        else
          plat[key] = val
        end
      end

      pp.cfg:ChangeSettings(plat)
      pp.cfg:ChangePolicySettings(pp.handle, pol)

      -- The chat filters are set up afresh from the setting.
      if (plat.chat_filter ~= nil) then
        pp.cfg:UpdateUserSecurity()
      end

      -- A timing typed out of its range was saved as the nearest it may be, which is what its box then shows.
      if (plat.roll_timeout ~= nil or plat.roll_extend ~= nil) then
        konfer:RefreshConfigRollUI()
      end

      if (plat.bid_timeout ~= nil or plat.bid_extend ~= nil) then
        konfer:RefreshConfigLootUI()
      end

      -- The Admin tab is put back as another admin's change would put it, a policy's options there reading these too, and so
      -- is a policy's own page.
      konfer:RefreshConfigAdminUI(false)
      konfer:RefreshPolicyPages()
    end,
    reload = function()
      konfer:RefreshConfigLootUI()
      konfer:RefreshConfigRollUI()
    end,
  })

  local lps = qf.lootpending

  --
  -- A widget's handler hands the edit to the tab only when the user made it. A refresh setting the widget from what is saved
  -- throws the same event with USER false, and that is no edit.
  --
  local function edit(key)
    return function(this, evt, val, user)
      if (user) then
        lps:Set(key, val)
      end
    end
  end

  --
  -- Config panel, loot tab, general options. Everything in this pane is the platform's: it says what happens to an item once
  -- a policy has decided who gets it, which is the same question whichever policy did the deciding.
  --
  local ypos = 0

  local cf = qf.lootopts

  --
  -- Two columns, the left one at 0 and the right one at RIGHT_COL. A checkbox is placed by its box and a dropdown labelled
  -- on its left by where the label starts, so the same number puts both against the same edge and the two columns line up whatever is in them.
  --
  local RIGHT_COL = 250

  --
  -- The space a section heading stands off whatever is above it. Both headings in this pane use it, and it is deliberately
  -- one number rather than a widget gap with a correction added: what has to match is the distance the eye sees above each
  -- heading, and that is the same distance whether a dropdown or a checkbox happens to be the thing above it.
  --
  local HEADING_GAP = 10

  arg = {
    x = 0, y = ypos, label = { text = L["Auto-open loot panel"] },
    tooltip = { title = "$$", text = L["TIP001"] },
  }
  cf.autobid = KUI:CreateCheckBox(arg, cf)
  cf.autobid:Catch("OnValueChanged", edit("auto_bid"))

  arg = {
    x = RIGHT_COL, y = ypos, label = { text = L["Enable chat message filter"] },
    tooltip = { title = "$$", text = L["TIP004"] },
  }
  cf.chatfilter = KUI:CreateCheckBox(arg, cf)
  -- Saved, the chat filters are set up afresh from it.
  cf.chatfilter:Catch("OnValueChanged", edit("chat_filter"))
  ypos = ypos - cf.chatfilter:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Display tooltips in loot list"] },
    tooltip = { title = "$$", text = L["TIP003"] },
  }
  cf.tooltips = KUI:CreateCheckBox(arg, cf)
  cf.tooltips:Catch("OnValueChanged", edit("tooltips"))

  arg = {
    x = RIGHT_COL, y = ypos, label = { text = L["Record loot assignment history"] },
    tooltip = { title = "$$", text = L["TIP005"] },
  }
  cf.history = KUI:CreateCheckBox(arg, cf)
  -- Unticked, nothing more is recorded and what was recorded stays. The History tab's clear buttons are how it is deleted.
  cf.history:Catch("OnValueChanged", edit("history"))
  ypos = ypos - cf.history:GetHeight() - KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, label = { text = L["Enable silent bidding"] },
    tooltip = { title = "$$", text = L["TIP002"] },
  }
  cf.silentbid = KUI:CreateCheckBox(arg, cf)
  cf.silentbid:Catch("OnValueChanged", edit("silent_bid"))
  -- The row it has to itself, which closes up for a policy that hides it (konfer:ShowConfigPolicyUI).
  cf.silentrowh = cf.silentbid:GetHeight() + KUI.WIDGET_GAP
  ypos = ypos - cf.silentrowh

  --
  -- Both of these need a master looter to assign the item, which not every client has: retail drops loot into somebody's
  -- bags and leaves them to trade it. They share a row so that a client without one takes the whole row away rather than
  -- leaving a hole in the middle of a column.
  --
  arg = {
    x = 0, y = ypos, label = { text = L["Auto-assign loot when bids close"] },
  }
  cf.autoloot = KUI:CreateCheckBox(arg, cf)
  cf.autoloot:Catch("OnValueChanged", edit("auto_loot"))

  arg = {
    x = RIGHT_COL, y = ypos, label = { text = L["Assign BoE items to master looter"] },
    tooltip = { title = "$$", text = L["TIP015"] },
  }
  cf.boetoml = KUI:CreateCheckBox(arg, cf)
  cf.boetoml:Catch("OnValueChanged", edit("boe_to_ml"))
  ypos = ypos - cf.boetoml:GetHeight() - KUI.WIDGET_GAP

  --
  -- The two dropdowns on this row read as what they are for rather than as what is currently set. COMPACT keeps the title in
  -- the box and checks the chosen item inside the menu, which is what the MULTI one beside it does with its own, so the pair
  -- match and neither box changes width as its value changes.
  --
  --
  -- The qualities in their colours. Retail makes ITEM_QUALITY_COLORS afresh whenever the player's colour overrides change, so
  -- the choices are built again from it each time the menu opens rather than once.
  --
  local function threshold_items()
    return {
      { text = K.NONE_STR, value = 0 },
      { text = ITEM_QUALITY2_DESC, value = 2, color = ITEM_QUALITY_COLORS[2] },
      { text = ITEM_QUALITY3_DESC, value = 3, color = ITEM_QUALITY_COLORS[3] },
      { text = ITEM_QUALITY4_DESC, value = 4, color = ITEM_QUALITY_COLORS[4] },
    }
  end

  arg = {
    x = 0, y = ypos, name = "KonferBidThresholdDropDown",
    title = { text = L["Bid / roll threshold"] },
    itemheight = 16, mode = "COMPACT", dwidth = 175, items = threshold_items(),
    tooltip = { title = "$$", text = L["TIP095"] },
  }
  cf.threshold = KUI:CreateDropDown(arg, cf)
  cf.threshold:Catch("OnValueChanged", edit("p.bid_threshold"))
  cf.threshold:Catch("OnClick", function(this, evt, _, shown)
    if (shown) then
      this:UpdateItems(threshold_items())
    end
  end)

  --
  -- Every announcement the mod can make, gathered into one menu. Most of the items stand for a setting of their own and are
  -- independent of each other, so the menu's own is_checked reads each one by name. Where the loot is announced is a choice
  -- of exactly one of three rather than a set of independent switches, so it is a submenu of one radio group whose items
  -- carry their own checked test.
  --
  -- The menu shows what is on screen, an unsaved change included. The heading over the submenu stands for no setting.
  local function is_oaf_checked(this)
    return (this.value ~= nil) and lps:Value(this.value) and true or false
  end

  local function announce_where_is(which)
    return function()
      return konfer:LootAnnouncedTo(konfer.apol, lps:Value("announce_where")) == which
    end
  end

  -- Guild chat means nothing to a character with no guild, so neither guild item is on offer to one.
  local function guilded()
    return K.player.is_guilded and true or false
  end

  arg = {
    x = RIGHT_COL, y = ypos, name = "KonferAnnouncementsDropDown", itemheight = 16, dwidth = 175, mode = "MULTI",
    title = { text = L["Announcements"],}, is_checked = is_oaf_checked,
    tooltip = { title = "$$", text = L["TIP007"] },
    items = {
      { text = L["Announce loot"], checkable = false, clickable = false, tooltip = { title = "$$", text = L["TIP006"] },
        submenu = {
          name = "KonferAnnounceWhereDropDown", itemheight = 16,
          items = {
            { text = L["Nowhere"], value = 0, group = "announce_where", checked = announce_where_is(0),
              tooltip = { title = "$$", text = L["TIP006.1"] }, },
            { text = L["In guild chat"], value = 1, group = "announce_where", checked = announce_where_is(1), hidekey = "announce_guild",
              enabled = guilded, tooltip = { title = "$$", text = L["TIP006.2"] }, },
            { text = L["In raid chat"], value = 2, group = "announce_where", checked = announce_where_is(2),
              tooltip = { title = "$$", text = L["TIP006.3"] }, },
          },
        },
      },
      { text = L["Loot list changes"], value = "ann_bidchanges", tooltip = { title = "$$", text = L["TIP007.1"] }, },
      { text = L["Winners in raid"], value = "ann_winners_raid", tooltip = { title = "$$", text = L["TIP007.2"] }, },
      { text = L["Winners in guild chat"], value = "ann_winners_guild", enabled = guilded,
        tooltip = { title = "$$", text = L["TIP007.3"] }, },
      { text = L["Bid progression"], value = "ann_bid_progress", tooltip = { title = "$$", text = L["TIP007.4"] }, },
      { text = L["Usage message when bids open"], value = "ann_bid_usage", tooltip = { title = "$$", text = L["TIP007.5"] }, },
      { text = L["Bid / roll cancelation"], value = "ann_cancel", tooltip = { title = "$$", text = L["TIP007.9"] }, },
      { text = L["When no successful bids"], value = "ann_no_bids", tooltip = { title = "$$", text = L["TIP007.10"] }, },
      { text = L["Raiders not on current list"], value = "ann_missing", tooltip = { title = "$$", text = L["TIP007.11"] }, },
    },
  }
  cf.otherannounce = KUI:CreateDropDown(arg, cf)
  -- Every item, kept here because the menu itself holds only what the active policy offers (ShowConfigPolicyUI).
  cf.announceitems = arg.items
  cf.announceshown = arg.items
  cf.otherannounce:Catch("OnItemChecked", function(this, e, b, v, checked)
    --
    -- The submenu's values are the numbers nought to two and every other item's is the name of the setting it stands for, so
    -- the value that came back says which of the two kinds of item was clicked. Choosing one of the submenu's radio group
    -- also unchecks the one chosen before, and only the one now checked says where the loot is announced. Every one of these
    -- is thrown by a click.
    --
    if (type(v) == "number") then
      if (checked) then
        lps:Set("announce_where", v)
      end
    else
      lps:Set(v, checked and true or false)
    end
  end)
  ypos = ypos - cf.otherannounce:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  --
  -- General options is the options above and no more: what they used, less the gap left after the last of them, plus the rings round the panel.
  --
  local gop = loottab.hsplit.topinset
  cf.gop = gop
  cf.goph = 0 - ypos - KUI.WIDGET_GAP + gop.rings.top + gop.rings.bottom
  gop:SetHeight(cf.goph)

  --
  -- Everything under Enable silent bidding, by where its top was put, so that a policy hiding that row can have the rest move
  -- up into its room (konfer:ShowConfigPolicyUI).
  --
  cf.belowsilent = {}

  for _, w in ipairs({ cf.autoloot, cf.boetoml, cf.threshold, cf.otherannounce }) do
    for i = 1, w:GetNumPoints() do
      local pt, rel, _, x, y = w:GetPoint(i)

      if (pt == "TOP") then
        tinsert(cf.belowsilent, { w = w, rel = rel, x = x, y = y })
      end
    end
  end

  --
  -- Config panel, loot tab, bid options. Main spec is always taken, so there is a row for each of the three kinds beside it:
  -- whether it is taken, then what it stands below, so a row is one kind's whole story. A choice about a kind nobody may bid
  -- is dark. Whether a policy ranks by any of the four is its own affair. Under them, whether bids are timed, and then what
  -- becomes of an item nobody bid on.
  --
  local cf = qf.bidopts
  local BID_COL = 180
  ypos = 0

  local function bid_row(defs, y)
    local h = 0

    for _, d in ipairs(defs) do
      arg = {
        x = d[1] * BID_COL, y = y, label = { text = d[3] },
        tooltip = { title = "$$", text = d[4] },
      }
      cf[d[2]] = KUI:CreateCheckBox(arg, cf)
      cf[d[2]]:Catch("OnValueChanged", function(this, evt, val, user)
        if (user) then
          lps:Set(d[5], val)
          cf.syncbids()
        end
      end)
      h = cf[d[2]]:GetHeight()
    end

    return y - h - KUI.WIDGET_GAP
  end

  ypos = bid_row({
    { 0, "offspec", L["Off spec"], L["TIP111"], "offspec_bids" },
    { 1, "mainoveros", L["Main spec > off spec"], L["TIP114"], "main_over_offspec" },
  }, ypos)

  ypos = bid_row({
    { 0, "transmog", L["Transmog"], L["TIP112"], "transmog_bids" },
    { 1, "osovertmog", L["Off spec > transmog"], L["TIP115"], "offspec_over_transmog" },
  }, ypos)

  ypos = bid_row({
    { 0, "vanity", L["Vanity"], L["TIP113"], "vanity_bids" },
    { 1, "osovervanity", L["Off spec > vanity"], L["TIP116"], "offspec_over_vanity" },
    { 2, "tmogovervanity", L["Transmog > vanity"], L["TIP117"], "transmog_over_vanity" },
  }, ypos)

  --
  -- Whether bids are timed, and how: how long they stay open, and how far off a bid near the end puts the close back to.
  -- The two timings are seconds typed into a box of three digits, held within their range as a roll's are, and are lit
  -- only while bids are timed.
  --
  local timery = ypos

  ypos = bid_row({
    { 0, "bidtimer", L["Timed bids"], L["TIP119"], "bid_timer" },
  }, timery)

  local function bid_seconds(key, minv, maxv)
    return function(this, evt, newv, user)
      if (user) then
        lps:Set(key, min(max(tonumber(newv) or minv, minv), maxv))
      end
    end
  end

  arg = {
    x = BID_COL, y = timery, numeric = true, len = 3, charwidth = 3, label = { text = L["Bid timeout"], pos = "LEFT" },
    tooltip = { title = "$$", text = L["TIP120"] },
  }
  cf.bidtimeout = KUI:CreateEditBox(arg, cf)
  cf.bidtimeout:Catch("OnValueChanged", bid_seconds("bid_timeout", 10, 300))

  arg = {
    x = 2 * BID_COL, y = timery, numeric = true, len = 3, charwidth = 3,
    label = { text = L["Bid timeout extension"], pos = "LEFT" }, tooltip = { title = "$$", text = L["TIP121"] },
  }
  cf.bidextend = KUI:CreateEditBox(arg, cf)
  cf.bidextend:Catch("OnValueChanged", bid_seconds("bid_extend", 5, 60))

  --
  -- What becomes of an item nobody won, in the order it is tried: put it to an open roll where TRYROLL offers that, and
  -- failing that give it to an enchanter. Built into CF from YPOS down under HEADING, a heading's gap clear of the rows
  -- above it, answering where the next row would go. CF.NOWINNER is everything it built, for showing it or not. PREFIX
  -- begins the names of its dropdowns, which are frames the game names globally and so must differ between the two.
  --
  -- Bid options has it, with Try open roll. Roll options has a second, for a policy with no Bid options at all
  -- (ConfigLootPage.hide), whose roll has nothing left to try but an enchanter. The two edit the same two settings.
  --
  local function build_nowinner(cf, ypos, heading, tryroll, prefix)
    ypos = ypos + KUI.WIDGET_GAP - HEADING_GAP

    arg = {
      x = 0, y = ypos, width = 300, font = "GameFontNormal", text = heading,
    }
    cf.nobidlbl = KUI:CreateStringLabel(arg, cf)
    ypos = ypos - cf.nobidlbl:GetHeight() - KUI.WIDGET_GAP

    if (tryroll) then
      arg = {
        x = 0, y = ypos, label = { text = L["Try open roll"] },
        tooltip = { title = "$$", text = L["TIP016"] },
      }
      cf.tryroll = KUI:CreateCheckBox(arg, cf)
      cf.tryroll:Catch("OnValueChanged", edit("p.try_roll"))
      ypos = ypos - cf.tryroll:GetHeight() - KUI.WIDGET_GAP
    end

    --
    -- The checkbox and the three enchanters read as one sentence, assign to this one or this one or this one, so they share a
    -- row. The dropdowns are the tallest thing on it and set its height; the checkbox and the two ors are dropped half the
    -- difference so that all six sit on one centre line. Where the first dropdown starts is measured off the words beside the
    -- checkbox rather than guessed, those words being translated, and the box the frame reserves is what they stand clear of.
    --
    local DENCH_LIFT = (KUI.DROPDOWN_HEIGHT - KUI.CHECKBOX_SIZE) / 2

    --
    -- Wide enough for the twelve characters a WoW name can be, less what the inset and the arrow take out of it. Twelve of the
    -- widest letters still run past that, but a name of twelve W's is not a name anybody has.
    --
    local DENCH_W = 115
    local OR_W = KUI:WidestString({ L["or"] }, "GameFontHighlight")

    --
    -- A ceiling on the checkbox rather than its size. It is as wide as the words in it need in whatever language is loaded,
    -- and stops growing here; past this the words are cut off instead, which is the lesser of the two evils against a row that
    -- walks its last box off the edge of the panel.
    --
    local DENCH_CB_MAX = 135

    --
    -- Where the "or" sits in the space between one box and the next. It is not the middle of that space, the word belonging to
    -- the box that follows it, so it stands a little further from the box it comes after.
    --
    local OR_LEAD = KUI.WIDGET_GAP + 3

    --
    -- What the checkbox stands off the first box. Wider than a plain widget gap because what it follows is a fixed width
    -- rather than the words in it, so the eye measures the space from where the words stop and not from where the widget does.
    --
    local DENCH_BOX_GAP = KUI.WIDGET_GAP + 2

    local DENCH_STEP = DENCH_W + KUI.WIDGET_GAP + OR_W + KUI.WIDGET_GAP

    arg = {
      x = 0, y = ypos - DENCH_LIFT, label = { text = L["Assign to"] },
      maxwidth = DENCH_CB_MAX,
      tooltip = { title = "$$", text = L["TIP017"] },
    }
    cf.dench = KUI:CreateCheckBox(arg, cf)

    --
    -- The disenchanters as they stand on screen, pending changes included, which is also what the menus offer from.
    --
    local function shown_denchers()
      return lps:Value("denchers") or {}
    end

    --
    -- Put the three boxes and the words between them right for whether anything is disenchanted, and the names in the boxes
    -- for who is. The words joining the boxes are part of the same sentence and grey out with it.
    --
    cf.showdenchers = function()
      local pp = konfer.apol
      local on = lps:Value("disenchant") and true or false
      local denchers = shown_denchers()

      for i = 1, self.MAX_DENCHERS do
        local uid = on and denchers[i] or nil

        cf["dencher" .. i]:SetEnabled(on)
        cf["dencher" .. i]:SetText(uid and aclass(pp.cfg:UserNameClass(uid)) or K.NOBODY_STR)
      end

      for i = 1, self.MAX_DENCHERS - 1 do
        cf["dencheror" .. i]:SetEnabled(on)
      end
    end

    cf.dench:Catch("OnValueChanged", function(this, evt, val, user)
      if (not user) then
        return
      end

      lps:Set("disenchant", val and true or false)

      -- Nothing is disenchanted, so nobody is a disenchanter.
      if (not val) then
        lps:Set("denchers", {})
      end

      cf.showdenchers()
    end)

    --
    -- Asked of the checkbox rather than declared, because how wide it came out is a question about the locale: it is as wide
    -- as its own words up to the ceiling above, and the boxes start from wherever that leaves off.
    --
    local DENCH_X = cf.dench:GetWidth() + DENCH_BOX_GAP

    --
    -- Disenchanter number WHICH is to be UID, or nobody for 0. The disenchanters are one setting, so it is the whole table of
    -- them that is changed.
    --
    local function dencher_ovc(this, uid, which)
      local pp = konfer.apol
      local denchers = K.CopyTable(shown_denchers(), {})

      this:SetText((uid ~= 0) and aclass(pp.cfg:UserNameClass(uid)) or K.NOBODY_STR)
      denchers[which] = (uid ~= 0) and uid or nil
      lps:Set("denchers", denchers)
    end

    local function dencher_onclick(this, is_dropped, dnum)
      local pp = konfer.apol
      if (not is_dropped) then
        return
      end

      local elist = {}
      local denchers = shown_denchers()
      local cval = denchers[dnum]

      tinsert(elist, { value = 0, text = K.NOBODY_STR })
      if (cval) then
        tinsert(elist, { value = cval, text = aclass(pp.cfg:UserNameClass(cval)), checked = true, enabled = false } )
      end

      for k,v in ipairs(pp.sortedusers) do
        local ok = true
        for i = 1, self.MAX_DENCHERS do
          if (denchers[i] == v.id) then
            ok = false
          end
        end
        if (ok and pp.cfg:IsEnchanter(v.id)) then
          local ti = { value = v.id, text = aclass(pp.cfg:UserNameClass(v.id)), checked = false }
          tinsert(elist, ti)
        end
      end
      this:UpdateItems(elist)
      this:SetValue(cval or 0, true)
    end

    arg = {
      x = DENCH_X, y = ypos, name = prefix .. "Dencher1DD", itemheight = 16, dwidth = DENCH_W, mode = "SINGLE",
      items = KUI.emptydropdown, title = { text = "" },
    }
    cf.dencher1 = KUI:CreateDropDown(arg, cf)
    cf.dencher1:Catch("OnClick", function(this, evt, dd, is_dropped)
      dencher_onclick(this, is_dropped, 1)
    end)
    cf.dencher1:Catch("OnValueChanged", function(this, evt, newv, user)
      if (user) then
        dencher_ovc(this, newv or 0, 1)
      end
    end)

    arg.x = DENCH_X + DENCH_STEP
    arg.name = prefix .. "Dencher2DD"
    cf.dencher2 = KUI:CreateDropDown(arg, cf)
    cf.dencher2:Catch("OnClick", function(this, evt, dd,  is_dropped)
      dencher_onclick(this, is_dropped, 2)
    end)
    cf.dencher2:Catch("OnValueChanged", function(this, evt, newv, user)
      if (user) then
        dencher_ovc(this, newv or 0, 2)
      end
    end)

    arg.x = DENCH_X + 2 * DENCH_STEP
    arg.name = prefix .. "Dencher3DD"
    cf.dencher3 = KUI:CreateDropDown(arg, cf)
    cf.dencher3:Catch("OnClick", function(this, evt, dd,  is_dropped)
      dencher_onclick(this, is_dropped, 3)
    end)
    cf.dencher3:Catch("OnValueChanged", function(this, evt, newv, user)
      if (user) then
        dencher_ovc(this, newv or 0, 3)
      end
    end)

    --
    -- The two joins in the sentence. They sit in the gap between one dropdown and the next, which is why the step above reserves room for them.
    --
    arg = {
      x = DENCH_X + DENCH_W + OR_LEAD, y = ypos - DENCH_LIFT,
      width = OR_W, autosize = false, font = "GameFontHighlight", text = L["or"],
    }
    cf.dencheror1 = KUI:CreateStringLabel(arg, cf)

    arg.x = DENCH_X + DENCH_STEP + DENCH_W + OR_LEAD
    cf.dencheror2 = KUI:CreateStringLabel(arg, cf)
    ypos = ypos - cf.dencher1:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

    --
    -- The boxes share out the whole of the row the checkbox and the two ors leave them, so they are as wide as the panel lets
    -- them be, and share it out again whenever the panel changes width. DENCH_W is only what they start at, until the panel
    -- knows how wide it is.
    --
    local function fit_denchers()
      local joins = self.MAX_DENCHERS - 1
      local room = cf:GetWidth() - DENCH_X - joins * (KUI.WIDGET_GAP + OR_W + KUI.WIDGET_GAP)
      local w = floor(room / self.MAX_DENCHERS)

      if (w < DENCH_W) then
        w = DENCH_W
      end

      local step = w + KUI.WIDGET_GAP + OR_W + KUI.WIDGET_GAP

      for i = 1, self.MAX_DENCHERS do
        local dd = cf["dencher" .. i]
        dd:SetWidth(w)
        dd:SetPoint("LEFT", dd:GetParent(), "LEFT", DENCH_X + (i - 1) * step, 0)
      end

      for i = 1, joins do
        local join = cf["dencheror" .. i]
        join:SetPoint("LEFT", join:GetParent(), "LEFT", DENCH_X + (i - 1) * step + w + OR_LEAD, 0)
      end
    end

    cf:HookScript("OnSizeChanged", fit_denchers)
    fit_denchers()

    cf.nowinner = { cf.nobidlbl, cf.dench, cf.dencheror1, cf.dencheror2 }

    for i = 1, self.MAX_DENCHERS do
      tinsert(cf.nowinner, cf["dencher" .. i])
    end

    if (cf.tryroll) then
      tinsert(cf.nowinner, cf.tryroll)
    end

    return ypos
  end

  ypos = build_nowinner(cf, ypos, L["When there are no successful bids ..."], true, "Konfer")

  --
  -- A choice between two kinds is lit only while both of them may be bid.
  --
  cf.syncbids = function()
    local off = lps:Value("offspec_bids") and true or false
    local tmog = lps:Value("transmog_bids") and true or false
    local van = lps:Value("vanity_bids") and true or false
    local timed = lps:Value("bid_timer") and true or false

    cf.mainoveros:SetEnabled(off)
    cf.osovertmog:SetEnabled(off and tmog)
    cf.osovervanity:SetEnabled(off and van)
    cf.tmogovervanity:SetEnabled(tmog and van)
    cf.bidtimeout:SetEnabled(timed)
    cf.bidextend:SetEnabled(timed)
  end

  -- Exactly as tall as what it holds.
  local bop = loottab.bidsplit.topinset
  bop:SetHeight(0 - ypos - KUI.WIDGET_GAP + bop.rings.top + bop.rings.bottom)

  --
  -- Config panel, loot tab, roll options. An open roll is how a tie, or a list with nobody left on it, gets settled whatever
  -- policy drew that list up, so the timings and the announcements belong beside the general options rather than in a policy's own tab.
  --
  local cf = qf.rollopts
  ypos = 0

  --
  -- The two timings are seconds typed into a box of three digits. What is typed is held within MINV and MAXV, and a box
  -- emptied or holding nothing that reads as a number is MINV.
  --
  local function seconds(key, minv, maxv)
    return function(this, evt, newv, user)
      if (user) then
        lps:Set(key, min(max(tonumber(newv) or minv, minv), maxv))
      end
    end
  end

  arg = {
    x = 0, y = ypos, numeric = true, len = 3, charwidth = 3, label = { text = L["Open roll timeout"], pos = "LEFT" },
    tooltip = { title = "$$", text = L["TIP008"] },
  }
  cf.rolltimeout = KUI:CreateEditBox(arg, cf)
  cf.rolltimeout:Catch("OnValueChanged", seconds("roll_timeout", 10, 120))

  arg = {
    x = RIGHT_COL, y = ypos, numeric = true, len = 3, charwidth = 3, label = { text = L["Roll timeout extension"], pos = "LEFT" },
    tooltip = { title = "$$", text = L["TIP009"] },
  }
  cf.rollextend = KUI:CreateEditBox(arg, cf)
  cf.rollextend:Catch("OnValueChanged", seconds("roll_extend", 5, 30))
  ypos = ypos - cf.rollextend:GetHeight() - KUI.WIDGET_GAP

  -- Whether a kind may be rolled decides whether the kind order has anything to say about it.
  local function kindedit(key)
    return function(this, evt, val, user)
      if (user) then
        lps:Set(key, val)
        cf.syncrolls()
      end
    end
  end

  -- Where the rows of the three kinds stand, for the kind order beside them.
  local kindy = { ypos }

  arg = {
    x = 0, y = ypos, label = {text = L["Enable off-spec (101-200) rolls"] },
    tooltip = { title = "$$", text = L["TIP092"] },
  }
  cf.enableoffspec = KUI:CreateCheckBox(arg, cf)
  cf.enableoffspec:Catch("OnValueChanged", kindedit("offspec_rolls"))

  arg = {
    x = RIGHT_COL, y = ypos, label = {text = L["Usage message when rolls open"] },
    tooltip = { title = "$$", text = L["TIP007.6"] },
  }
  cf.rollusage = KUI:CreateCheckBox(arg, cf)
  cf.rollusage:Catch("OnValueChanged", edit("ann_roll_usage"))
  ypos = ypos - cf.rollusage:GetHeight() - KUI.WIDGET_GAP
  kindy[2] = ypos

  arg = {
    x = 0, y = ypos, label = {text = L["Enable transmog (201-300) rolls"] },
    tooltip = { title = "$$", text = L["TIP107"] },
  }
  cf.enabletransmog = KUI:CreateCheckBox(arg, cf)
  cf.enabletransmog:Catch("OnValueChanged", kindedit("transmog_rolls"))

  arg = {
    x = RIGHT_COL, y = ypos, label = {text = L["Announce open roll countdown"] },
    tooltip = { title = "$$", text = L["TIP007.7"] },
  }
  cf.countdown = KUI:CreateCheckBox(arg, cf)
  cf.countdown:Catch("OnValueChanged", edit("ann_countdown"))
  ypos = ypos - cf.countdown:GetHeight() - KUI.WIDGET_GAP
  kindy[3] = ypos

  arg = {
    x = 0, y = ypos, label = {text = L["Enable vanity (301-400) rolls"] },
    tooltip = { title = "$$", text = L["TIP106"] },
  }
  cf.enablevanity = KUI:CreateCheckBox(arg, cf)
  cf.enablevanity:Catch("OnValueChanged", kindedit("vanity_rolls"))

  arg = {
    x = RIGHT_COL, y = ypos, label = {text = L["Announce open roll ties"] },
    tooltip = { title = "$$", text = L["TIP007.8"] },
  }
  cf.ties = KUI:CreateCheckBox(arg, cf)
  cf.ties:Catch("OnValueChanged", edit("ann_roll_ties"))
  ypos = ypos - cf.ties:GetHeight() - KUI.WIDGET_GAP

  --
  -- The kind order, for a policy whose rolls follow it (rollorder in Policy.lua), PUG having no Bid options to hold it: beside
  -- each kind of roll what it stands below, the same settings Bid options has beside each kind of bid. The announcements move
  -- down under the kinds to make room, the first two side by side and ties under them, and everything under them moves down
  -- with them (konfer:ShowConfigPolicyUI). A choice between two kinds that cannot both be rolled is dark.
  --
  local function order_box(key, y, text, tip, setting)
    arg = { x = RIGHT_COL, y = y, label = { text = text }, tooltip = { title = "$$", text = tip } }
    cf[key] = KUI:CreateCheckBox(arg, cf)
    cf[key]:Catch("OnValueChanged", edit(setting))
    cf[key]:Hide()
  end

  order_box("mainoveros", kindy[1], L["Main spec > off spec"], L["TIP_ROLL_MS_OS"], "main_over_offspec")
  order_box("osovertmog", kindy[2], L["Off spec > transmog"], L["TIP_ROLL_OS_TM"], "offspec_over_transmog")
  order_box("tmogovervanity", kindy[3], L["Transmog > vanity"], L["TIP_ROLL_TM_V"], "transmog_over_vanity")

  cf.syncrolls = function()
    local off = lps:Value("offspec_rolls") and true or false
    local tmog = lps:Value("transmog_rolls") and true or false
    local van = lps:Value("vanity_rolls") and true or false

    cf.mainoveros:SetEnabled(off)
    cf.osovertmog:SetEnabled(off and tmog)
    cf.tmogovervanity:SetEnabled(tmog and van)
  end

  --
  -- What moves to make room, and by how much: each widget's anchors to the panel as they were built, LEFT saying where it
  -- stands across and TOP where it stands down, as every KoreUI widget placed by x and y is anchored.
  --
  local rowh = kindy[1] - kindy[2]

  cf.ordermoves = {}
  cf.orderextra = 2 * rowh

  local function moves(w, dx, dy)
    local m = { w = w, dx = dx, dy = dy, points = {} }

    for i = 1, w:GetNumPoints() do
      local pt, rel, rpt, x, y = w:GetPoint(i)

      if (rel == cf) then
        tinsert(m.points, { pt = pt, rel = rel, rpt = rpt, x = x, y = y })
      end
    end

    tinsert(cf.ordermoves, m)
  end

  moves(cf.rollusage, 0 - RIGHT_COL, 0 - 3 * rowh)
  moves(cf.countdown, 0, 0 - 2 * rowh)
  moves(cf.ties, 0 - RIGHT_COL, 0 - 2 * rowh)

  --
  -- Roll options likewise, as tall as the rows above or, where they are shown, the rows under them too, which say what becomes
  -- of an item nobody rolls for under a policy with no Bid options (konfer:ShowConfigPolicyUI).
  --
  local rop = loottab.rollsplit.topinset

  qf.rolloptspane = rop
  qf.rolloptsh = 0 - ypos - KUI.WIDGET_GAP + rop.rings.top + rop.rings.bottom
  ypos = build_nowinner(cf, ypos, L["When there are no successful rolls ..."], false, "KonferRoll")
  qf.rolloptsnowinnerh = 0 - ypos - KUI.WIDGET_GAP + rop.rings.top + rop.rings.bottom

  for _, w in ipairs(cf.nowinner) do
    moves(w, 0, 0 - cf.orderextra)
  end
  qf.lootbidsplit = loottab.bidsplit

  for _, w in ipairs(cf.nowinner) do
    w:Hide()
  end

  rop:SetHeight(qf.rolloptsh)

  --
  -- Which widget shows which setting, so that it is drawn in the changed colour while that setting has an unsaved change.
  --
  local go, ro = qf.lootopts, qf.rollopts

  lps:Watch(go.autobid, "auto_bid")
  lps:Watch(go.chatfilter, "chat_filter")
  lps:Watch(go.tooltips, "tooltips")
  lps:Watch(go.history, "history")
  lps:Watch(go.silentbid, "silent_bid")
  lps:Watch(go.autoloot, "auto_loot")
  lps:Watch(go.boetoml, "boe_to_ml")
  lps:Watch(go.threshold, "p.bid_threshold")
  lps:Watch(go.otherannounce, "announce_where", "ann_bidchanges", "ann_winners_raid", "ann_winners_guild",
    "ann_bid_progress", "ann_bid_usage", "ann_cancel", "ann_no_bids", "ann_missing")

  local bo = qf.bidopts

  lps:Watch(bo.tryroll, "p.try_roll")

  -- What becomes of an item nobody won is in both, and the one on screen shows the change.
  for _, nw in ipairs({ bo, ro }) do
    lps:Watch(nw.dench, "disenchant")

    for i = 1, self.MAX_DENCHERS do
      lps:Watch(nw["dencher" .. i], "denchers")
    end
  end

  lps:Watch(bo.offspec, "offspec_bids")
  lps:Watch(bo.transmog, "transmog_bids")
  lps:Watch(bo.vanity, "vanity_bids")
  lps:Watch(bo.mainoveros, "main_over_offspec")
  lps:Watch(bo.osovertmog, "offspec_over_transmog")
  lps:Watch(bo.osovervanity, "offspec_over_vanity")
  lps:Watch(bo.tmogovervanity, "transmog_over_vanity")
  lps:Watch(bo.bidtimer, "bid_timer")
  lps:Watch(bo.bidtimeout, "bid_timeout")
  lps:Watch(bo.bidextend, "bid_extend")

  lps:Watch(ro.rolltimeout, "roll_timeout")
  lps:Watch(ro.rollextend, "roll_extend")
  lps:Watch(ro.enableoffspec, "offspec_rolls")
  lps:Watch(ro.rollusage, "ann_roll_usage")
  lps:Watch(ro.enablevanity, "vanity_rolls")
  lps:Watch(ro.countdown, "ann_countdown")
  lps:Watch(ro.enabletransmog, "transmog_rolls")
  lps:Watch(ro.ties, "ann_roll_ties")
  lps:Watch(ro.mainoveros, "main_over_offspec")
  lps:Watch(ro.osovertmog, "offspec_over_transmog")
  lps:Watch(ro.tmogovervanity, "transmog_over_vanity")

  --
  -- Config panel, admin tab
  --
  local cf = qf.cfgadmin

  --
  -- The tab's unsaved changes, to the config picked in its list, which need not be the one in use. The owner and the channel
  -- are the config's own fields and are written here and nowhere else, reaching the other admins with the config's next
  -- broadcast as they always have. The rest are settings, the platform's by name and the config's policy's as "p." and its
  -- name, and go out as one CHSET and one PSSET.
  --
  local function admin_config()
    local id = qf.adminpending and qf.adminpending.picked

    return id and konfer:Config(id)
  end

  qf.adminpending = self.mainwin:NewPending({
    page = self.CONFIG_PAGE, tab = self.CONFIG_ADMIN_TAB,
    saved = function(key)
      local lcf = admin_config()

      if (not lcf) then
        return nil
      end

      if (key == "owner") then
        return lcf.owner
      elseif (key == "channel") then
        return lcf:Channel()
      end

      local pk = key:match("^p%.(.+)$")

      if (pk) then
        local lpol = konfer:GetPolicy(lcf.id)

        return lpol and lpol:Setting(pk, lcf.id)
      end

      return lcf.settings[key]
    end,
    save = function(changes)
      local lcf = admin_config()
      local lpol = lcf and konfer:GetPolicy(lcf.id)
      local plat, pol = {}, {}

      if (not lcf) then
        return
      end

      for key, val in pairs(changes) do
        local pk = key:match("^p%.(.+)$")

        if (key == "owner") then
          lcf.owner = val
        elseif (key == "channel") then
          lcf.channel = val
        elseif (pk) then
          pol[pk] = val
        else
          plat[key] = val
        end
      end

      lcf:ChangeSettings(plat)

      if (lpol) then
        lcf:ChangePolicySettings(lpol.handle, pol)
      end

      --
      -- A new owner changes who may do what everywhere in the window, and every rank widget on every page is gated on rank
      -- filtering, so either puts the whole window back. The window is built once and lives as long as the mod does.
      --
      if (changes.owner ~= nil) then
        konfer:FullRefresh(true)
      elseif (changes.rank_filter ~= nil) then
        konfer:FullRefresh(false)
      end

      -- The Raid page may show what these settings say, PUG's columns there among it.
      konfer:RefreshPolicyPages()
    end,
    reload = function()
      konfer:RefreshConfigAdminUI(false)
    end,
  })

  --
  -- The tab is the About panel across the foot of the window, the width of the tab and exactly as tall as its two lines of
  -- GameFontNormalSmall, and above everything else. The tab has the save bar's room as well as its own, and the bar goes up
  -- in the space between the two, straight above About (see the admin tab in Init.lua). Above that, a container split into the
  -- column of configuration panels on the left and the policy's own panel on the right.
  --
  local _, ABOUT_LINE = KUI:MeasureStrWidth("Ag", "GameFontNormalSmall")
  local ABOUT_H = ceil(2 * ABOUT_LINE)

  local aboutpanel = KUI:CreateInset({ name = "KonferCfgAdminAbout" }, cf)
  local abouth = ABOUT_H + aboutpanel.rings.top + aboutpanel.rings.bottom

  aboutpanel:ClearAllPoints()
  aboutpanel:SetPoint("BOTTOMLEFT", cf, "BOTTOMLEFT", 0, 0)
  aboutpanel:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 0, 0)
  aboutpanel:SetHeight(abouth)
  kmt.tabsbyname[self.CONFIG_ADMIN_TAB].savebaroffset = abouth

  local upper = MakeFrame("Frame", nil, cf)

  upper:SetPoint("TOPLEFT", cf, "TOPLEFT", 0, 0)
  upper:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 0, abouth + (mainwin.savebarheight or 0))

  local about = aboutpanel.content

  --
  -- The right hand side is a container holding two panels, one above the other: Options, which is the platform's and is the
  -- config's own settings whatever runs it, and under it the active policy's, titled with its name, which is not known here.
  -- ShowConfigPolicyUI puts that there as the policy changes under the page.
  --
  arg = {
    width = 200,
    name = "KonferCfgAdminVSplit",
  }
  cf.vsplit = KUI:CreateVSplit(arg, upper)

  local ls = cf.vsplit.leftframe

  --
  -- The configurations panel holds the list and the four buttons that act on it, because a button that makes a
  -- configuration belongs among the ones it would be made alongside. Five rows is what the list is given: it scrolls, so this
  -- is a question of how much of the column to spend on it rather than of how many configurations there can be.
  --
  local CONFIG_ITEM_H = 16
  local CONFIG_ROWS = 5
  local CONFIGS_LIST_H = CONFIG_ROWS * CONFIG_ITEM_H

  --
  -- Two buttons across and two more under them, in a frame of their own centred under the list. The gaps between them,
  -- along and down, are the standard one.
  --
  local BTN_W = 80
  local BTN_H = 24
  local BTN_COL = BTN_W + KUI.WIDGET_GAP
  local BTN_ROW = 0 - BTN_H - KUI.WIDGET_GAP

  local CFGBTN_H = BTN_H + KUI.WIDGET_GAP + BTN_H
  local CONFIGS_H = CONFIGS_LIST_H + KUI.WIDGET_GAP + CFGBTN_H

  -- Where the first row of buttons starts, under the list and a gap.
  local CFGBTN_Y = 0 - CONFIGS_LIST_H - KUI.WIDGET_GAP

  KUI:UseAsContainer(ls)

  local cfgpanel = KUI:CreateInset({ title = L["Configurations"] }, ls)
  cfgpanel:ClearAllPoints()
  cfgpanel:SetPoint("TOPLEFT", ls, "TOPLEFT", 0, 0)
  cfgpanel:SetPoint("TOPRIGHT", ls, "TOPRIGHT", 0, 0)
  cfgpanel:SetHeight(CONFIGS_H + cfgpanel.rings.top + cfgpanel.rings.bottom)

  local tl = cfgpanel.content

  --
  -- The list gets a frame of its own inside the panel, because a scroll list fills whatever it is given and would otherwise
  -- take the buttons' room along with its own.
  --
  local listarea = MakeFrame("Frame", nil, tl)
  listarea:ClearAllPoints()
  listarea:SetPoint("TOPLEFT", tl, "TOPLEFT", 0, 0)
  listarea:SetPoint("TOPRIGHT", tl, "TOPRIGHT", 0, 0)
  listarea:SetHeight(CONFIGS_LIST_H)

  --
  -- A plain frame rather than a pane of a split, so that what is built in it lines up with the panel above rather than being
  -- inset by that pane's own padding a second time.
  --
  local lower = MakeFrame("Frame", nil, ls)
  lower:ClearAllPoints()
  lower:SetPoint("TOPLEFT", cfgpanel, "BOTTOMLEFT", 0, 0)
  lower:SetPoint("TOPRIGHT", cfgpanel, "BOTTOMRIGHT", 0, 0)
  lower:SetPoint("BOTTOM", ls, "BOTTOM", 0, 0)

  --
  -- What the selected configuration is, as opposed to what it contains: who owns it and where its admins sync. There is
  -- deliberately no policy chooser among them -- a config's policy is decided by the container it was created in, so you
  -- make an EP/GP config from inside EP/GP and cfg.policy is never offered as a choice afterwards.
  --
  local SETTINGS_H = 54

  --
  -- Co-admins takes what is left of the column under Settings, down to the save bar's room. Its buttons stand on its foot and
  -- the list above them fills the rest and scrolls.
  --
  local COADMIN_ITEM_H = 16

  arg = {
    inset = 0, height = SETTINGS_H, topanchor = true,
    name = "KonferCfgAdminSettingsSplit",
    toptitle = L["Settings"],
    bottomtitle = L["Co-admins"],
  }
  lower.hsplit = KUI:CreateHSplit(arg, lower)
  qf.adminsettingspanel = lower.hsplit.topinset
  qf.admincoadminspanel = lower.hsplit.bottominset

  local settings = lower.hsplit.topframe
  local coadmins = lower.hsplit.bottomframe

  ypos = 0

  --
  -- One width for both labels so that the two boxes beside them start at the same edge, and measured rather than declared
  -- because which of the two words is longer is a question about the locale.
  --
  local SLBL_W = KUI:WidestString({ L["Owner"], L["Sync via"] })

  arg = {
    x = 0, y = ypos, name = "KonferConfigOwnerDD", itemheight = 16,
    dwidth = 125, mode = "SINGLE", items = KUI.emptydropdown,
    label = { text = L["Owner"], pos = "LEFT", width = SLBL_W },
    tooltip = { title = "$$", text = L["TIP023"] },
  }
  settings.cfgowner = KUI:CreateDropDown(arg, settings)
  qf.cfgownerdd = settings.cfgowner
  settings.cfgowner:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.admincfg) then
      qf.adminpending:Set("owner", newv)
    end
  end)
  ypos = ypos - settings.cfgowner:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  --
  -- Where this config's traffic goes when the player is in no group, and its sync always, read by nothing but a policy's own
  -- CSendAM and CSendChannelAM. Guild means every admin is a guildmate and hears it; otherwise it goes to the group, and an
  -- admin who is not in that group sees nothing until they are.
  --
  -- Its box is measured rather than declared: as wide as the longer of the two things it can say, and which of them is
  -- longer is a question about the locale.
  --
  local CHANNEL_W = KUI:WidestString({ L["Guild"], L["Raid / Party"] }, "GameFontHighlightSmall")
    + KUI.DROPDOWN_CHROME

  arg = {
    name = "KonferCfgChannelDropDown", enabled = false, itemheight = 16,
    x = 0, y = ypos, label = { text = L["Sync via"], pos = "LEFT", width = SLBL_W },
    dwidth = CHANNEL_W + 25, mode = "SINGLE",
    tooltip = { title = "$$", text = L["TIP103"] },
    items = {
      -- A character with no guild has nobody to sync with there.
      { text = L["Guild"], value = CHANNEL_GUILD, enabled = function() return K.player.is_guilded and true or false end },
      { text = L["Raid / Party"], value = CHANNEL_OTHER },
    },
  }
  settings.cfgchannel = KUI:CreateDropDown(arg, settings)
  -- Putting the box back from the config is not the user choosing a channel, the same rule the owner box above follows.
  settings.cfgchannel:Catch("OnValueChanged", function(this, evt, newv, user)
    if (user and qf.admincfg) then
      qf.adminpending:Set("channel", newv)
    end
  end)
  qf.cfgchannel = settings.cfgchannel
  ypos = ypos - settings.cfgchannel:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  qf.cfgopts = settings

  --
  -- Options across the top of the right hand side, exactly as tall as what it holds, and the policy's own panel under it
  -- taking everything the window grows by. How tall Options is depends on what goes in it, so it is made with no height here
  -- and given one once its widgets have been built.
  --
  arg = {
    inset = 0, height = 0, topanchor = true,
    name = "KonferCfgAdminOptsSplit",
    toptitle = L["Options"],
    bottomtitle = "",
  }
  cf.optsplit = KUI:CreateHSplit(arg, cf.vsplit.rightframe)

  local opts = cf.optsplit.topframe
  qf.adminoptsplit = cf.optsplit
  qf.adminoptspanel = cf.optsplit.topinset

  --
  -- The pane under it is the active policy's to fill, and is titled for it. It is the first part of the config panel that
  -- belongs to the policy rather than to the platform: it is handed a frame and what goes in it is entirely its own
  -- business, down to the name over the top of it.
  --
  -- The pane is the page's and is made once. What goes in it is a frame per policy, built by
  -- konfer:BuildConfigPolicyUI, of which one is shown at a time, and how tall the pane is is settled per policy in
  -- konfer:ShowConfigPolicyUI, because only the policy knows what it built.
  --
  qf.adminpolicypanel = cf.optsplit.bottominset
  qf.adminpolicyslot = cf.optsplit.bottomframe

  --
  -- A second pane of the policy's own under that one, running down to the foot of Co-admins, for a policy with more to show
  -- than a few options (AdminPanel in Policy.lua). It too is the page's and is made once, titled and shown per policy, and
  -- hidden for a policy with none.
  --
  qf.adminextrapanel = KUI:CreateInset({ title = "" }, cf.optsplit)
  qf.adminextraslot = qf.adminextrapanel.content
  qf.adminextrapanel:Hide()

  --
  -- Guild rank filtering. The checkbox says whether this config filters by guild rank at all, and every rank widget in the
  -- mod is enabled through cfg:RankFiltering, which asks it. Rank Order beside it opens the dialog that says where each
  -- of the guild's ranks stands, and is reachable only while filtering is on, there being nothing for an order to order.
  --
  -- Neither means anything to a character with no guild, so neither is offered to one. The config still keeps whatever it
  -- was told, this character simply having no guild to read it against, and an admin who is in one sees it as it stands.
  --
  ypos = 0

  --
  -- The roll list a drop is bid on when neither the item nor anything else names one. It is the platform's: roll lists are,
  -- and which of them is the fallback is a fact about that config's lists rather than about how any policy hands things out.
  -- Its choices are the selected config's own lists, refilled whenever those change.
  --
  arg = {
    x = 0, y = ypos, name = "KonferCfgDefListDropdown", mode = "SINGLE", dwidth = 200, items = KUI.emptydropdown,
    itemheight = 16, enabled = false, label = { text = L["Default list"], pos = "LEFT" },
    tooltip = { title = "$$", text = L["TIP010"] },
  }
  opts.deflist = KUI:CreateDropDown(arg, opts)
  qf.admindeflist = opts.deflist
  opts.deflist:Catch("OnValueChanged", function(this, evt, nv, user)
    if (user and qf.admincfg) then
      qf.adminpending:Set("def_list", nv)
    end
  end)
  ypos = ypos - opts.deflist:GetHeight() - KUI.WIDGET_GAP - KUI.DROPDOWN_ADD_GAP

  -- The row is as tall as the Rank Order button, which is centred on the checkbox, so the checkbox is centred in the row.
  local RANKBTN_H = 24

  arg = {
    x = 0, y = ypos - (RANKBTN_H - KUI.CHECKBOX_SIZE) / 2, label = { text = L["Guild rank filtering"] }, enabled = false,
    tooltip = { title = "$$", text = L["TIP108"] },
  }
  opts.rankfilter = KUI:CreateCheckBox(arg, opts)
  qf.adminrankfilter = opts.rankfilter
  --
  -- Rank Order beside it follows what is on screen, so it can be reached as soon as filtering is ticked. Every other rank
  -- widget in the window follows what is saved, and is put right when the change is.
  --
  opts.rankfilter:Catch("OnValueChanged", function(this, evt, val, user)
    if (not user or not qf.admincfg) then
      return
    end

    qf.adminpending:Set("rank_filter", val and true or false)
    qf.adminrankorder:SetEnabled((K.player.is_guilded and val) and true or false)
  end)

  --
  -- Beside the checkbox and clear of its words, a checkbox being exactly as wide as the box and the words it carries. As
  -- wide as its own word with room either side, never narrower than the kit's own button, because which of the three
  -- translations is longest is a question about the locale.
  --
  local RANKBTN_W = max(100, KUI:WidestString({ L["Rank order"] }) + 4 * KUI.WIDGET_GAP)
  local RANKBTN_GAP = 4 * KUI.WIDGET_GAP

  arg = {
    x = 0, y = ypos, width = RANKBTN_W, height = RANKBTN_H, text = L["Rank order"], enabled = false,
    tooltip = { title = "$$", text = L["TIP109"] },
  }
  opts.rankorder = KUI:CreateButton(arg, opts)
  qf.adminrankorder = opts.rankorder
  opts.rankorder:ClearAllPoints()
  opts.rankorder:SetPoint("LEFT", opts.rankfilter, "RIGHT", RANKBTN_GAP, 0)
  opts.rankorder:Catch("OnClick", function(this, evt)
    rank_order_dialog(self, qf.admincfg)
  end)

  ypos = ypos - opts.rankorder:GetHeight() - KUI.WIDGET_GAP

  --
  -- Options is the widgets above and no more: what they used, less the gap left after the last of them, plus the rings round the panel.
  --
  local aop = cf.optsplit.topinset
  aop:SetHeight(0 - ypos - KUI.WIDGET_GAP + aop.rings.top + aop.rings.bottom)

  -- Which widget shows which of the tab's values, for the changed colour.
  qf.adminpending:Watch(qf.cfgopts.cfgowner, "owner")
  qf.adminpending:Watch(qf.cfgopts.cfgchannel, "channel")
  qf.adminpending:Watch(opts.deflist, "def_list")
  qf.adminpending:Watch(opts.rankfilter, "rank_filter")

  tl.buttons = MakeFrame("Frame", nil, tl)
  tl.buttons:SetWidth(BTN_COL + BTN_W)
  tl.buttons:SetHeight(CFGBTN_H)
  tl.buttons:SetPoint("TOP", tl, "TOP", 0, CFGBTN_Y)

  arg = {
    x = 0, y = 0, width = BTN_W, height = BTN_H, text = L["Create"],
    tooltip = { title = "$$", text = L["TIP019"] },
  }
  tl.createbutton = KUI:CreateButton(arg, tl.buttons)
  tl.createbutton:Catch("OnClick", function(this, evt)
    new_space_button(self)
  end)

  arg = {
    x = BTN_COL, y = 0, width = BTN_W, height = BTN_H, text = L["Delete"],
    tooltip = { title = "$$", text = L["TIP020"] },
  }
  tl.deletebutton = KUI:CreateButton(arg, tl.buttons)
  tl.deletebutton:Catch("OnClick", function(this, evt)
    konfer:Config(qf.admincfg):Delete(true)
  end)
  qf.cfgdelbutton = tl.deletebutton

  arg = {
    x = 0, y = BTN_ROW, width = BTN_W, height = BTN_H, text = L["Rename"],
    tooltip = { title = "$$", text = L["TIP021"] },
  }
  tl.renamebutton = KUI:CreateButton(arg, tl.buttons)
  tl.renamebutton:Catch("OnClick", function(this, evt)
    rename_space_button(self, qf.admincfg)
  end)
  qf.cfgrenbutton = tl.renamebutton

  arg = {
    x = BTN_COL, y = BTN_ROW, width = BTN_W, height = BTN_H, text = L["Copy"],
    tooltip = { title = "$$", text = L["TIP022"] },
  }
  tl.copybutton = KUI:CreateButton(arg, tl.buttons)
  tl.copybutton:Catch("OnClick", function(this, evt)
    copy_space_button(self, qf.admincfg, nil, nil, true)
  end)
  qf.cfgcopybutton = tl.copybutton

  --
  -- We make the config space panel a scrolling list in case they have lots of configs (unlikely but hey, you never know).
  --
  arg = {
    name = "KonferConfigScrollList",
    itemheight = CONFIG_ITEM_H,
    newitem = function(objp, num)
      return KUI.NewItemHelper(objp, num, "KonferConfigButton", 160, CONFIG_ITEM_H, nil, nil, nil, nil)
      end,
    setitem = function(objp, idx, slot, btn)
      return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
          return self:Config(qf.sortedconfigs[ix].id).name
        end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return config_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  tl.slist = KUI:CreateScrollList(arg, listarea)
  qf.cfglist = tl.slist

  --
  -- The email address and the website are links, as near as WoW lets an addon come to one: they are coloured as links, and
  -- clicking one puts its address in a box to be copied, since nothing an addon does can open a mail program or a browser.
  --
  local KONFER_EMAIL = "me@cruciformer.com"
  local KONFER_URL = "https://kahluamods.com/konfer"

  arg = {
    x = 0, y = 0, font = "GameFontNormalSmall", autosize = false, justifyv = "TOP", justifyh = "CENTER",
    text = strfmt(L["ABOUT"], K.Link("email", KONFER_EMAIL), K.Link("url", KONFER_URL)),
    onlink = function(this, kind, data)
      if (kind == "url") then
        show_copy_box(L["Website"], L["Press Ctrl+C to copy, then paste it into your browser."], data)
      elseif (kind == "email") then
        show_copy_box(L["Email"], L["Press Ctrl+C to copy, then paste it into your email."], data)
      end
    end,
  }
  about.str = KUI:CreateStringLabel(arg, about)
  about.str:ClearAllPoints()
  about.str:SetPoint("TOPLEFT", about, "TOPLEFT", 0, 0)
  about.str:SetPoint("BOTTOMRIGHT", about, "BOTTOMRIGHT", 0, 0)

  --
  -- The buttons that add and remove co-admins sit under the list, in a frame of their own centred on the bottom of the
  -- panel, the standard gap apart.
  --
  coadmins.buttons = MakeFrame("Frame", nil, coadmins)
  coadmins.buttons:SetWidth(BTN_COL + BTN_W)
  coadmins.buttons:SetHeight(BTN_H)
  coadmins.buttons:SetPoint("BOTTOM", coadmins, "BOTTOM", 0, 0)

  arg = {
    x = 0, y = 0, text = L["Add"], width = BTN_W, height = BTN_H,
    tooltip = { title = "$$", text = L["TIP026"] },
  }
  coadmins.add = KUI:CreateButton(arg, coadmins.buttons)
  coadmins.add:Catch("OnClick", function(this, evt, ...)
    local pp = konfer.apol
    local ulist = {}
    local cc = self:Config(qf.admincfg)
    local cul = cc.uids

    if (cc.nadmins == 36) then
      pp:err(L["maximum number of co-admins (36) reached"])
      return
    end

    if (self.popupwindow) then
      self.popupwindow:Hide()
      self.popupwindow = nil
    end

    for k,v in pairs(cul) do
      if (not cc:IsCoadmin(k) and not cc:IsAlt(k)) then
        tinsert(ulist, { value = k, text = aclass(cc:UserNameClass(k)) })
      end
    end
    tsort(ulist, function(a, b)
      return (cc:UserName(a.value) or "") < (cc:UserName(b.value) or "")
    end)
    if (#ulist == 0) then
      return
    end

    local function pop_func(cauid)
      add_coadmin(self, cauid, self:Config(qf.admincfg))
      self.popupwindow:Hide()
      self.popupwindow = nil
      self:RefreshConfigAdminUI(false)
    end

    if (not qf.coadmin_popup) then
      qf.coadmin_popup = K.PopupSelectionList(self, "KonferCoadminAddPopup",
        ulist, L["Select co-admin"], 200, 400, this, 16, pop_func)
    else
      qf.coadmin_popup:UpdateList(ulist)
    end
    qf.coadmin_popup:ClearAllPoints()
    qf.coadmin_popup:SetPoint("TOPLEFT", this, "TOPRIGHT", 0, qf.coadmin_popup:GetHeight() / 2)
    self.popupwindow = qf.coadmin_popup
    qf.coadmin_popup:Show()
  end)
  qf.coadadd = coadmins.add

  arg = {
    x = BTN_COL, y = 0, text = L["Delete"], width = BTN_W, height = BTN_H,
    tooltip = { title = "$$", text = L["TIP027"] },
    enabled = false,
  }
  coadmins.del = KUI:CreateButton(arg, coadmins.buttons)
  coadmins.del:Catch("OnClick", function(this, evt, ...)
    if (not qf.coadmin_selected or not qf.admincfg) then
      return
    end
    konfer:Config(qf.admincfg):DeleteAdmin(qf.coadmin_selected)
  end)
  qf.coaddel = coadmins.del

  --
  -- A row fills the column. The list frame is inset one on the left and gives up SCROLLBAR_COMPENSATE on the right for its
  -- bar, and a row wider than what is left is clipped by the frame around it.
  --
  local COAD_ITEM_W = 200 - 1 - KUI.SCROLLBAR_COMPENSATE

  --
  -- A frame of its own for the list, because a scroll list fills whatever it
  -- is given and would otherwise take the buttons' row along with its own.
  --
  local coadlist = MakeFrame("Frame", nil, coadmins)
  coadlist:ClearAllPoints()
  coadlist:SetPoint("TOPLEFT", coadmins, "TOPLEFT", 0, 0)
  coadlist:SetPoint("BOTTOMRIGHT", coadmins, "BOTTOMRIGHT", 0, BTN_H + KUI.WIDGET_GAP)

  arg = {
    name = "KonferCoadminScrollList",
    itemheight = COADMIN_ITEM_H,
    newitem = function(objp, num)
      return KUI.NewItemHelper(objp, num, "KonferCoadminButton", COAD_ITEM_W, COADMIN_ITEM_H, nil, nil, nil, nil)
      end,
    setitem = function(objp, idx, slot, btn)
      return KUI.SetItemHelper(objp, btn, idx, function(op, ix)
          return aclass(konfer:Config(qf.admincfg):UserNameClass(qf.sortedadmins[ix]))
        end)
      end,
    selectitem = function(objp, idx, slot, btn, onoff)
      return coadmin_list_selectitem(objp, idx, slot, btn, onoff)
    end,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }
  coadmins.slist = KUI:CreateScrollList(arg, coadlist)
  qf.coadminscroll = coadmins.slist
end

--
-- Build PP's own options on the Admin tab, into the pane the page keeps for them, and remember how tall the policy says they
-- are. Once per policy, from konfer:BuildPolicyUI. A policy without CreateConfigUI builds nothing and is given the empty pane.
--
function konfer:BuildConfigPolicyUI(pp)
  build_policy_tabs(self, pp)

  if (not pp.CreateConfigUI) then
    return
  end

  pp.adminframe = MakeFrame("Frame", nil, qf.adminpolicyslot)
  pp.adminframe:ClearAllPoints()
  pp.adminframe:SetPoint("TOPLEFT", qf.adminpolicyslot, "TOPLEFT", 0, 0)
  pp.adminframe:SetPoint("BOTTOMRIGHT", qf.adminpolicyslot, "BOTTOMRIGHT", 0, 0)
  pp.adminframe:Hide()

  --
  -- What the policy answers is the distance from the top of the frame to the bottom of the lowest thing in it, which is what
  -- the pane is made to hold exactly. A policy that answers nothing gets the pane ending level with Co-admins instead.
  --
  local _, h = self:PolicyHook(pp, "CreateConfigUI", nil, pp.CreateConfigUI, pp, pp.adminframe)

  pp.adminheight = h

  -- The policy's second pane, which has room only under a first that says how tall it is.
  local ap = pp.AdminPanel

  if (ap and ap.Construct and h) then
    pp.adminextraframe = MakeFrame("Frame", nil, qf.adminextraslot)
    pp.adminextraframe:ClearAllPoints()
    pp.adminextraframe:SetPoint("TOPLEFT", qf.adminextraslot, "TOPLEFT", 0, 0)
    pp.adminextraframe:SetPoint("BOTTOMRIGHT", qf.adminextraslot, "BOTTOMRIGHT", 0, 0)
    pp.adminextraframe:Hide()

    self:PolicyHook(pp, "AdminPanel.Construct", nil, ap.Construct, pp.adminextraframe)
  end
end

--
-- Show or hide PP's options on the Admin tab, and size the pane around them, and lay the Loot tab out for PP.
--
-- The pane hangs under Options, as wide as the column and as tall as what the policy built in it. A policy that says
-- nothing, or one with no options at all, ends it level with Co-admins rather than running on down into the empty space
-- under the column. A policy with a second pane has it under the first, taking the rest of the way down to Co-admins' foot.
-- A policy that hides Options (AdminPage.hide) has its pane start at the top of the column instead.
--
-- Both of its top corners are put back exactly where the split hung them, because the split holds that pane by its top and
-- its bottom both, and a height cannot be given to a frame that is anchored at both ends.
--
function konfer:ShowConfigPolicyUI(pp, onoff)
  local xp = qf.adminextrapanel

  if (pp.adminframe) then
    pp.adminframe:SetShown(onoff and true or false)
  end

  if (pp.adminextraframe) then
    pp.adminextraframe:SetShown(onoff and true or false)
  end

  show_policy_tabs(self, pp, onoff)

  if (not onoff) then
    xp:Hide()
    return
  end

  --
  -- The Loot tab without Bid options for a policy that hides them, Roll options moving up under General options and saying
  -- what becomes of an item nobody rolls for, which Bid options says for everybody else. General options loses Enable silent
  -- bidding too, its row closing up and everything under it moving up into the room.
  --
  local nobids = pp.ConfigLootPage and pp.ConfigLootPage.hide and pp.ConfigLootPage.hide.bids
  local lo = qf.lootopts
  local lift = nobids and lo.silentrowh or 0

  lo.silentbid:SetShown(not nobids)

  for _, b in ipairs(lo.belowsilent) do
    b.w:SetPoint("TOP", b.rel, "TOP", b.x, b.y + lift)
  end

  lo.gop:SetHeight(lo.goph - lift)
  qf.lootbidsplit:SetStaticShown(not nobids)

  --
  -- The Announcements menu without what the policy never announces, named in the same set by its setting or, for In guild
  -- chat under Announce loot, by the item's hidekey. A submenu is copied without its own, its frame being found again by name.
  --
  local lhide = (pp.ConfigLootPage and pp.ConfigLootPage.hide) or {}

  local function offered(items)
    local out = {}

    for _, it in ipairs(items) do
      local key = it.hidekey or it.value

      if (not (key and lhide[key])) then
        if (it.submenu) then
          local copy, sub = {}, {}

          for k, v in pairs(it) do
            copy[k] = v
          end

          for k, v in pairs(it.submenu) do
            sub[k] = v
          end

          sub.items = offered(it.submenu.items)
          copy.submenu = sub
          it = copy
        end

        tinsert(out, it)
      end
    end

    return out
  end

  lo.announceshown = offered(lo.announceitems)
  lo.otherannounce:UpdateItems(lo.announceshown)

  local ro = qf.rollopts

  for _, w in ipairs(ro.nowinner) do
    w:SetShown(nobids and true or false)
  end

  --
  -- Roll options for a policy whose rolls follow the kind order (rollorder): what each kind of roll stands below beside it,
  -- and the announcements moved down under the kinds, everything under them with them. Only an anchor that moves is touched.
  --
  local ordered = pp.rollorder and true or false

  for _, key in ipairs({ "mainoveros", "osovertmog", "tmogovervanity" }) do
    ro[key]:SetShown(ordered)
  end

  for _, m in ipairs(ro.ordermoves) do
    for _, p in ipairs(m.points) do
      if (p.pt == "LEFT" and m.dx ~= 0) then
        m.w:SetPoint(p.pt, p.rel, p.rpt, p.x + (ordered and m.dx or 0), p.y)
      elseif (p.pt == "TOP" and m.dy ~= 0) then
        m.w:SetPoint(p.pt, p.rel, p.rpt, p.x, p.y + (ordered and m.dy or 0))
      end
    end
  end

  qf.rolloptspane:SetHeight((nobids and qf.rolloptsnowinnerh or qf.rolloptsh) + (ordered and ro.orderextra or 0))

  local rp = qf.adminpolicypanel
  local nooptions = pp.AdminPage and pp.AdminPage.hide and pp.AdminPage.hide.options

  qf.adminoptsplit:SetStaticShown(not nooptions)

  rp:SetTitleText(pp.name)
  rp:ClearAllPoints()

  if (nooptions) then
    rp:SetPoint("TOPLEFT", qf.adminoptsplit, "TOPLEFT", 0, 0)
    rp:SetPoint("TOPRIGHT", qf.adminoptsplit, "TOPRIGHT", 0, 0)
  else
    rp:SetPoint("TOPLEFT", qf.adminoptspanel, "BOTTOMLEFT", 0, 0)
    rp:SetPoint("TOPRIGHT", qf.adminoptspanel, "BOTTOMRIGHT", 0, 0)
  end

  if (pp.adminheight) then
    rp:SetHeight(pp.adminheight + rp.rings.top + rp.rings.bottom)
  else
    rp:SetPoint("BOTTOM", qf.admincoadminspanel, "BOTTOM", 0, 0)
  end

  if (pp.adminextraframe) then
    xp:SetTitleText(pp.AdminPanel.title or pp.name)
    xp:ClearAllPoints()
    xp:SetPoint("TOPLEFT", rp, "BOTTOMLEFT", 0, 0)
    xp:SetPoint("TOPRIGHT", rp, "BOTTOMRIGHT", 0, 0)
    xp:SetPoint("BOTTOM", qf.admincoadminspanel, "BOTTOM", 0, 0)
    xp:Show()
  else
    xp:Hide()
  end
end

--
-- Everything scoped to one raid under one config goes when that changes. Reservations, the undo stack, who has been warned
-- about what, who in the group is missing from the config: all of it was about a raid being run against that config, whose
-- uids and list ids mean somebody and something else in any other, and none of it survives being run a different way. One
-- fresh record rather than a dozen resets, so that nothing can be forgotten. It is still the same group's.
--
local function reset_raid_state(self)
  self:EmptyRaid(true)
end

local function real_delete_config(this, cfgid)
  --
  -- Whatever this policy has left takes over as its default, and the search for a successor is inside that policy: handing
  -- SK's slot to an EP/GP config would activate the wrong mod at the next login.
  --
  local pol = this:GetPolicy(cfgid)

  if (not silent_delete and pol) then
    pol:info(L["configuration %q deleted."], white(this:Config(cfgid).name))
  end

  local pdb = pol and this:PolicyDB(pol)
  local wasdef = (pdb and pdb.defconfig == cfgid)

  this:SetConfig(cfgid, nil)

  --
  -- The policy's current config is always one it has, so deleting it moves the policy to another, or to none when this was
  -- its last. With none, the next config it gets becomes current.
  --
  if (wasdef or (pol and pol.currentid == cfgid)) then
    local nid = next(this:PolicyConfigs(pol))

    if (nid) then
      this:Config(nid):SetDefault(false, true)
    else
      pdb.defconfig = nil
      this:SetPolicyCurrent(pol, nil)
      pol.sortedlists = nil

      if (pol == this.apol) then
        reset_raid_state(this)
      end

      this:MakeAliases()
    end
  end

  -- The Admin tab's list comes back on the config in the title bar, whichever config was picked in it before.
  if (qf) then
    qf.admincfg = nil
  end
  this:FullRefresh(true)
end

--
-- The config with id CFGID, or nil if there is no such config.
--
-- Everything that is handed a config id comes through here rather than indexing a table, so that where configs are kept is
-- this function's business and nobody else's. That matters because they are moving: a config belongs to one policy and the
-- policies are growing their own storage, at which point this is where the search for the right one lives and every caller carries on unchanged.
--
function konfer:Config(cfgid)
  if (not cfgid) then
    return nil
  end

  --
  -- Asked without a policy in hand, so every policy is asked in turn. A config id is unique across all of them, the policy
  -- taking part in the hash that mints one, so at most one can answer and there are five policies rather than five hundred.
  --
  -- Code that knows whose config it means should say so and use PolicyConfig. This is for the paths handed a bare id and nothing else.
  --
  for k, pol in pairs(self.policies) do
    local cfg = self:PolicyConfigs(pol)[cfgid]

    if (cfg) then
      return cfg
    end
  end

  return nil
end

--
-- The config CFGID within POL, nil if that policy does not have it even when
-- another policy does. The narrow form, for code that knows whose it is.
--
function konfer:PolicyConfig(pol, cfgid)
  return (cfgid and self:PolicyConfigs(pol)[cfgid]) or nil
end

--
-- File CFG under CFGID, or remove it when CFG is nil. The counterpart to Config, and the only other thing that knows where configs are kept.
--
-- It does no bookkeeping: how many configs there are and which one is current are the caller's business, because a config
-- arriving from a broadcast and a config the user just made need different answers to both.
--
function konfer:SetConfig(cfgid, cfg, pol)
  --
  -- Removing one needs no policy named: the config is already filed and only one policy can be holding it. Storing one that
  -- is not filed yet does, and the config itself is asked before GetPolicy is, because GetPolicy answers by looking the
  -- config up and a config being stored for the first time is not there to be found.
  --
  local pol = pol or (cfg and cfg.policy and self.policies[cfg.policy])
    or self:GetPolicy(cfgid)

  --
  -- Nothing else in here can tell us, and filing it under a guess is how a config ends up belonging to a policy that never
  -- asked for it. Without this the write would land in the empty table PolicyConfigs hands back for a policy that is not
  -- there, and simply be gone.
  --
  assert(pol, "SetConfig: cannot tell which policy owns config " .. tostring(cfgid))

  --
  -- Every config that is filed goes through here, whoever made it, so this is where the settings proxy goes on. A config
  -- arriving from another client is a plain table with two strings in it and no metatable, and would read every setting as
  -- nil until the reader is attached.
  --
  self:PolicyConfigs(pol)[cfgid] = cfg and self:MakeConfig(cfgid, cfg) or nil
end

function cfgm:Delete(show, private)
  local pol = konfer:GetPolicy(self.id)

  if (private) then
    local oldsilent = silent_delete
    silent_delete = true
    real_delete_config(konfer, self.id)
    silent_delete = oldsilent
    return
  end

  --
  -- The dialog stands in for the window, hiding it and putting it back, but only when the window is what the user is
  -- deleting this from. That is any config of the policy the window shows, not only the one in use, the Admin tab listing
  -- them all. A config of some other policy is being deleted from the foyer, which has a window of its own.
  --
  local win = (konfer.mainwin and (show or konfer.mainwin:IsShown()) and pol == konfer.apol) and konfer.mainwin or nil

  --
  -- Deleted from the window, another of the policy's configs has already taken over, and the window comes back at
  -- Config:Admin whatever page it was asked from. With none left, the policy has nothing to show and the foyer comes up.
  --
  self:ConfirmDelete(win, function()
    if (not win) then
      return
    end

    if (konfer:NumConfigs(pol) > 0) then
      win:Show()
      win:SetPage(konfer.CONFIG_PAGE, konfer.CONFIG_ADMIN_TAB)
    else
      win:Hide()
      konfer:OpenFoyer()
    end
  end)

  return false
end

--
-- The one dialog that asks before a config is deleted, wherever the delete was asked for. It is plated with the config's
-- own policy, which need not be the active one when the foyer asks. WIN is the window it stands in for, and DONE is run
-- after the config has gone, for a caller with something of its own to put right.
--
function cfgm:ConfirmDelete(win, done)
  K.ConfirmationDialog(konfer, { text = L["Delete configuration"], owner = konfer:GetPolicy(self.id) }, L["DELMSG"],
    { L["Configuration: %s"], self.name }, function(kmod, arg)
      real_delete_config(kmod, arg.cfgid)
      if (arg.done) then
        arg.done()
      end
    end, { cfgid = self.id, done = done }, win)
end

function konfer:CreateNewConfig(name, initial, nouser, mykey, policy)
  local lname = strlower(name)
  local newpol = self.policies[policy or self.DEFAULT_POLICY]

  --
  -- A config has to know whose it is before anything else happens, because everything below files it under that policy. A
  -- handle nobody registered reaches us from another admin running a policy we do not have, and there is nothing useful to
  -- do with it: stored under a guess it belongs to a policy that never asked for it, and stored under nothing it lands in
  -- the throwaway table PolicyConfigs hands back and is simply gone.
  --
  if (not newpol) then
    err(L["configuration %q uses a distribution system this installation does not have."], white(name))
    return true
  end

  --
  -- A config has to be called something long enough to be told from a history code. MYKEY is set only where the config
  -- comes with an id already, which is another admin's broadcast or a restore, and such a name is taken as it stands.
  --
  if (not mykey and self:NameTooShort(newpol, name)) then
    return true
  end

  --
  -- Names have to be unique within a policy and nowhere wider. Two policies each having a config called "Tuesday" is not a
  -- collision, it is two mods that happen to share a database file.
  --
  for k,v in pairs(self:PolicyConfigs(newpol)) do
    if (strlower(v.name) == lname) then
      newpol:err(L["configuration %q already exists. Try again."], white(name))
      return true
    end
  end

  --
  -- The policy participates in the id. It is fixed at creation and never changes, so two policies handed the same clock,
  -- counter and player name still draw from separate spaces. The same local sets cfg.policy below, so what went into the
  -- hash and what the config says cannot disagree.
  --
  local policy = policy or self.DEFAULT_POLICY
  local newkey = mykey or KC.CreateNewID(policy)

  --
  -- The policy has to be named here rather than left to be worked out. A config is filed under the policy it belongs to and
  -- this one does not say who that is yet, sp.policy being set a few lines further down.
  --
  local sp = {}

  self:SetConfig(newkey, sp, newpol)
  sp.name = name
  --
  -- Where this config's traffic goes when the player is in no group, and its sync always, read only by its policy's own
  -- CSendAM and CSendChannelAM; Kore never reads a config. Guild means every admin is a guildmate and hears it; otherwise it
  -- goes to the group, and an admin who is not in that group sees nothing until they are. A policy that says where all its
  -- configs talk (its descriptor's channel) says it for this one too.
  --
  sp.channel = newpol.channel or CHANNEL_OTHER
  --
  -- The loot distribution policy this config runs. Every config names one, chosen by whichever policy it was created from and never changed after.
  --
  sp.policy = policy
  sp.history = {}
  sp.uids = {}
  sp.nusers = 0
  sp.lists = {}
  sp.nlists = 0
  sp.items = {}
  sp.nitems = 0
  sp.admins = {}
  sp.nadmins = 0
  sp.cksum = 0xa49b37d3
  sp.lastevent = 0
  sp.syncing = false

  -- The platform's settings this policy's new configs start at (configdefaults). One arriving brings its own.
  if (not mykey) then
    for k, v in pairs(newpol.configdefaults or {}) do
      sp.settings[k] = v
    end
  end

  if (not nouser) then
    sp.nusers = 1
    sp.uids["0001"] = { K.player.kuid }
    sp.owner = "0001"
    sp:Session().myuid = "0001"
    newpol:info(L["configuration %q created."], white(name))
    sp.nadmins = 1
    sp.admins["0001"] = { id = "0" }
  end

  --
  -- The guild master's first config syncs over the guild, that being the one case where we can be sure every admin will be a
  -- guildmate. Anything after it, or anyone else's, takes the group and can be changed immediately if that is wrong. A
  -- config arriving from somebody else, with its id, carries its own channel and is not this player's to choose for.
  --
  if (K.player.is_gm and not mykey and not newpol.channel) then
    local ng = 0
    for k,v in pairs(self:PolicyConfigs(newpol)) do
      if (v.channel == CHANNEL_GUILD) then
        ng = ng + 1
      end
    end
    if (ng == 0) then
      sp.channel = CHANNEL_GUILD
    end
  end

  -- A policy that runs every config on one list of its own makes it now, with the owner on it. One arriving brings its own.
  if (newpol.onelist and not mykey and not nouser) then
    sp:MakeOneList()
  end

  --
  -- A policy's first config becomes the one it has in hand, there being nothing else it could be. After that the user's own
  -- selection stands and a new config does not steal the window out from under them.
  --
  if (initial or not newpol.currentid) then
    sp:SetDefault(true, true)
    return false, newkey
  end

  self:FullRefresh(true)
  return false, newkey
end

function cfgm:Rename(newname)
  if (self:IsDenied()) then
    return true
  end

  if (not self) then
    return true
  end

  local found = false
  local lname = strlower(newname)
  local pol = konfer:GetPolicy(self.id)

  -- What a config is called is its owner's to say, as its channel is, and a co-admin cannot rename it.
  if (self:MyStatus() ~= 2) then
    pol:err(L["only the owner of a configuration can rename it."])
    return true
  end

  -- A config has to be called something long enough to be told from a history code. Anything else goes, a name travelling inside a message's payload.
  if (konfer:NameTooShort(pol, newname)) then
    return true
  end

  -- Another config of the same name is a clash, and this one differing only in case is a rename.
  for k,v in pairs(konfer:PolicyConfigs(pol)) do
    if (k ~= self.id and strlower(v.name) == lname) then
      found = true
    end
  end

  if (found) then
    pol:err(L["configuration %q already exists. Try again."], white(newname))
    return true
  end

  local oldname = self.name
  pol:info(L["Configuration %q renamed to %q."], white(oldname), white(newname))
  self.name = newname
  konfer:FullRefresh()

  return false
end

--
-- The id of POL's config called NAME, or nil. A policy has to be named because names are only unique within one, so
-- "Tuesday" is a question that has no answer until you say whose Tuesday you mean.
--
function konfer:FindConfig(pol, name)
  local lname = strlower(name)
  for k,v in pairs(self:PolicyConfigs(pol)) do
    if (strlower(v.name) == lname) then
      return k
    end
  end
  return nil
end

function cfgm:DeleteAdmin(uid, nocmd)
  local cp = self

  if (not cp) then
    return
  end

  if (not cp.admins[uid]) then
    return
  end

  -- Must send the event BEFORE removing the admin. It is for everybody, so no raider goes on taking events from them.
  if (not nocmd) then
    self:AddEvent("RMADM", uid)
  end

  cp.nadmins = cp.nadmins - 1
  cp.admins[uid] = nil
  if (cp.nadmins == 1) then
    cp.syncing = false
    cp.lastevent = 0
    cp.admins[cp.owner].lastevent = nil
    cp.admins[cp.owner].sync = nil

    if (qf.cfgopts) then
      qf.cfgopts.cfgowner:SetEnabled(false)
    end
  end

  if (qf.coadminscroll) then
    refresh_coadmins(konfer)
  end
  konfer:RefreshSyncUI(true)
end

--
-- Make POL the active policy: the one the window shows and the one that arms for loot against whichever config it has in
-- hand. Which policy that is is the mod's decision and never a policy's. The foyer's Activate and the dialog a second
-- policy's command puts up are the two deliberate ways here, and startup restores the one remembered. Looking at a config,
-- or choosing one, never changes it, with the one exception SetDefault describes.
--
-- NOREFRESH is for a caller that is about to refresh everything anyway.
--
-- Every route to a policy switch comes through here. The dialog in front of one of them is a question asked before this is
-- called, never a second way of doing it. Which is why the refusal while loot is being handed out is here rather than at
-- those routes: one of them deliberately asks nothing first, and a switch nobody was asked about is still a switch.
--
function konfer:ActivatePolicy(pol, norefresh)
  if (not pol or pol == self.apol or self:IsPolicyDisabled(pol.handle)) then
    return
  end

  --
  -- Refused outright while loot is being handed out (konfer:LootInProgress). There is no wording that makes abandoning a
  -- distribution halfway a reasonable thing to click through, so the user finishes it and comes back. A caller that puts a
  -- dialog up asks this for itself as well, so that it says no instead of asking a question whose answer it would then refuse.
  --
  if (self:LootInProgress()) then
    err(L["POLICY_SWITCH_LOOTING"], self.apol.name, pol.name)
    return
  end

  -- Items still waiting on the loot list are the outgoing policy's loot session, and go with it.
  if (self.raid.bossloot) then
    self:ResetBossLoot()
  end

  --
  -- The outgoing policy is put away before the incoming one is set up, so the two never have their panels on screen
  -- together. The incoming one is built here if it never has been, which is where lazy building happens: a policy nobody
  -- ever switches to costs nothing at all.
  --
  self:LeavePolicy(self.apol)

  self.apol = pol

  --
  -- Remembered, so that a raid night picks up where the last one left off instead of falling back to the default.
  --
  self.frdb.activepolicy = pol.handle

  self:EnterPolicy(pol)

  reset_raid_state(self)
  self:MakeAliases()

  if (pol.currentid) then
    pol.cfg:UpdateUserSecurity()
  end

  -- What the raid agreed is about the config loot runs against, and that is now another policy's.
  self:AskRaidSettings()

  if (self.initialised and not norefresh) then
    self:FullRefresh(true)
  end

  --
  -- A new policy is a fresh start, so the window goes back to its opening pages rather than leaving the user on a page of
  -- the policy they have just left. Only a window already up: activating from the foyer is not a reason to open one.
  --
  if (self.mainwin and self.mainwin:IsShown()) then
    if (self.raid.bossloot) then
      self.mainwin:SetPage(self.LOOT_PAGE, self.LOOT_ASSIGN_TAB)
    else
      self.mainwin:SetPage(self:FirstPage(), self.LISTS_MEMBERS_TAB)
    end
  end
end

--
-- Function: cfg:SetDefault(silent, force)
-- Purpose : Make CFGID the config its policy has in hand. For the active policy that is what the window shows and what
--           loot runs against; for any other it is what will be waiting when it is next switched to. Do nothing if it
--           already is, unless FORCE is set. Unless SILENT is set, say so.
-- Returns : Nothing
--
function cfgm:SetDefault(silent, force)
  local newpol = self:GetPolicy()
  local pdb = konfer:PolicyDB(newpol)

  if (pdb.defconfig ~= self.id or force) then
    --
    -- Which config a policy has in hand is that policy's own business and is remembered across sessions, so that a user
    -- juggling several finds each window where they left it. currentid is the live copy and defconfig the saved one, written
    -- together here because this is the only place either of them changes.
    --
    pdb.defconfig = self.id

    local oldcfgid = newpol.currentid

    konfer:SetPolicyCurrent(newpol, self.id)

    if (newpol == konfer.apol and oldcfgid ~= self.id) then
      reset_raid_state(konfer)
    end

    --
    -- An active policy with no config at all has nothing to run and no raid state to lose, so a policy that gains or picks a
    -- config while that is so becomes the active one. In every other case choosing a config leaves the active policy alone.
    --
    if (newpol ~= konfer.apol and konfer:IsTempCfg(konfer.apol)) then
      konfer:ActivatePolicy(newpol, true)
    end

    konfer:MakeAliases()

    if (konfer.initialised) then
      -- If we're not initialised yet then this will just have been called.
      konfer:RefreshCSData()
    end

    if (konfer.initialised and konfer.qf.synctopbar) then
      konfer.qf.synctopbar:SetCurrentCRC()
    end

    newpol.sortedlists = nil

    self:UpdateUserSecurity()

    -- A new config in hand for the active policy is a new config for the raid to say what it agreed about.
    konfer:AskRaidSettings()

    if (konfer.initialised) then
      konfer:FullRefresh(true)

      --
      -- The window is turned back to its opening pages, but only when what it is showing has actually changed. A config
      -- picked in some other policy's name is that policy's to remember for when it is next the active one, and is no reason
      -- to move the page under the user now.
      --
      if (konfer.mainwin and self:IsActive()) then
        konfer.mainwin:SetPage(konfer.LOOT_PAGE, konfer.LOOT_ASSIGN_TAB)
        konfer.mainwin:SetPage(konfer:FirstPage(), konfer.LISTS_MEMBERS_TAB)
      end

      if (not silent) then
        local pol = konfer:GetPolicy(self.id)

        if (pol) then
          pol:info(L["Default changed to configuration %q."], white(self.name))
          if (not self:MyStatus()) then
            pol:info(L["you are not an administrator of this configuration. Your access to it is read-only."])
          end
        end
      end
    end
  end
end

--
-- The list of roll lists has changed. The active policy's options on the Admin tab may offer a choice of them, and what they
-- offer is the policy's own business, so it is simply told to put them back for the config the tab has selected.
--
function konfer:RefreshConfigLists()
  local pp = self.apol

  if (not qf.admincfg) then
    return
  end

  --
  -- The platform's own choice of lists, the default one, is put back first. Naming a list that has just gone would leave the
  -- box showing a name for something there is no longer, a dropdown only being able to show a value it offers.
  --
  local cfp = self:Config(qf.admincfg)

  if (qf.admindeflist) then
    qf.admindeflist:UpdateItems(cfp:ListChoices())
    qf.admindeflist:SetValue(cfp.settings.def_list or "0", true)
  end

  if (pp and pp.RefreshConfigUI) then
    self:PolicyHook(pp, "RefreshConfigUI", nil, pp.RefreshConfigUI, pp, qf.admincfg)
  end
end

function konfer:RefreshConfigUsers()
end

--
-- Put the loot tab back for the config PP has in hand.
--
--
-- The tab's unsaved changes are for one config. When the active config is another than the one they were made to, they are
-- thrown away, the same as picking another config does. Otherwise what is saved may have moved under them, another admin's
-- change arriving, and theirs replaces any of these it touches.
--
local function loot_pending_for(pp)
  local lps = qf.lootpending

  if (lps.cfgid ~= pp.currentid) then
    lps.cfgid = pp.currentid
    lps:Discard()
  else
    lps:Reconcile()
  end

  return lps
end

--
-- Put the loot tab back for the config PP has in hand, showing any change not yet saved. Nothing here is an edit, so every
-- widget is set without throwing.
--
local function refresh_config_loot(self, pp, reset)
  local lps = loot_pending_for(pp)
  local cf = qf.lootopts

  cf.autobid:SetChecked(lps:Value("auto_bid"), true)
  cf.silentbid:SetChecked(lps:Value("silent_bid"), true)
  cf.tooltips:SetChecked(lps:Value("tooltips"), true)
  cf.chatfilter:SetChecked(lps:Value("chat_filter"), true)
  cf.history:SetChecked(lps:Value("history"), true)
  cf.autoloot:SetChecked(lps:Value("auto_loot"), true)
  cf.threshold:SetValue(lps:Value("p.bid_threshold"), true)
  cf.boetoml:SetChecked(lps:Value("boe_to_ml"), true)
  cf.otherannounce:UpdateItems(cf.announceshown)

  local bo = qf.bidopts

  bo.tryroll:SetChecked(lps:Value("p.try_roll"), true)

  for _, nw in ipairs({ bo, qf.rollopts }) do
    nw.dench:SetChecked(lps:Value("disenchant"), true)
    nw.showdenchers()
  end

  bo.offspec:SetChecked(lps:Value("offspec_bids"), true)
  bo.transmog:SetChecked(lps:Value("transmog_bids"), true)
  bo.vanity:SetChecked(lps:Value("vanity_bids"), true)
  bo.mainoveros:SetChecked(lps:Value("main_over_offspec"), true)
  bo.osovertmog:SetChecked(lps:Value("offspec_over_transmog"), true)
  bo.osovervanity:SetChecked(lps:Value("offspec_over_vanity"), true)
  bo.tmogovervanity:SetChecked(lps:Value("transmog_over_vanity"), true)
  bo.bidtimer:SetChecked(lps:Value("bid_timer"), true)
  -- An edit box throws whenever its text is set, with USER false, which the tab takes as no edit.
  bo.bidtimeout:SetText(tostring(lps:Value("bid_timeout")))
  bo.bidextend:SetText(tostring(lps:Value("bid_extend")))
  bo.syncbids()
end

function konfer:RefreshConfigLootUI(reset)
  if (qf.lootopts and self.apol and self.apol.cfg) then
    refresh_config_loot(self, self.apol, reset)
  end
end

local function refresh_config_roll(self, pp, reset)
  local lps = loot_pending_for(pp)
  local cf = qf.rollopts

  -- An edit box throws whenever its text is set, with USER false, which the tab takes as no edit.
  cf.rolltimeout:SetText(tostring(lps:Value("roll_timeout")))
  cf.rollextend:SetText(tostring(lps:Value("roll_extend")))
  cf.enableoffspec:SetChecked(lps:Value("offspec_rolls"), true)
  cf.enablevanity:SetChecked(lps:Value("vanity_rolls"), true)
  cf.enabletransmog:SetChecked(lps:Value("transmog_rolls"), true)
  cf.rollusage:SetChecked(lps:Value("ann_roll_usage"), true)
  cf.countdown:SetChecked(lps:Value("ann_countdown"), true)
  cf.ties:SetChecked(lps:Value("ann_roll_ties"), true)
  cf.mainoveros:SetChecked(lps:Value("main_over_offspec"), true)
  cf.osovertmog:SetChecked(lps:Value("offspec_over_transmog"), true)
  cf.tmogovervanity:SetChecked(lps:Value("transmog_over_vanity"), true)
  cf.syncrolls()
end

function konfer:RefreshConfigRollUI(reset)
  if (qf.rollopts and self.apol and self.apol.cfg) then
    refresh_config_roll(self, self.apol, reset)
  end
end

--
-- What a config's name is worth saying in colour about: whether this character owns it, merely helps administer it, or is
-- simply a member of it. Green and cyan are the two ranks of authority and the plain name is everybody else, which is most
-- configs for most people -- the point is that the handful you can actually change stand out of a list of the ones you cannot.
--
local COLOR_CONFIG_OWNER = KUI.COLOR_GREEN
local COLOR_CONFIG_ADMIN = KUI.COLOR_CYAN

--
-- Function: cfg:NameColour()
-- Purpose : The colour CFGID's name is drawn in, as an { r, g, b } table, or nil for a config this character has no say in.
--           Widgets that take a colour rather than a string use this; anything drawing text wants NameColoured instead.
-- Returns : Table or nil.
--
function cfgm:NameColour()
  local adm = self:MyStatus()

  if (adm == 2) then
    return COLOR_CONFIG_OWNER
  elseif (adm == 1) then
    return COLOR_CONFIG_ADMIN
  end

  return nil
end

--
-- Function: cfg:NameColoured(name)
-- Purpose : CFGID's name wrapped in the colour escape for what this character is to it. NAME overrides the name looked up,
--           for a caller that already has it or is showing one that has not been stored yet. A config this character neither
--           owns nor administers comes back with no escape codes at all rather than an explicit white, so that it inherits
--           whatever colour the widget drawing it uses.
-- Returns : String, possibly empty, never nil.
--
function cfgm:NameColoured(name)
  local cfg = self
  local str = name or (cfg and cfg.name) or ""
  local color = self:NameColour()

  if (not color) then
    return str
  end

  return strfmt("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, str)
end

local function refresh_config_admin(self, pp, reset)
  if (self:IsTempCfg(pp)) then
    qf.cfglist.itemcount = 0
    qf.cfglist:UpdateList()
    sync_admin_panels()
    return
  end

  local vt = {}
  local newconfs = {}
  --
  -- A refresh keeps whatever was selected. What is selected to begin with is the config in the title bar, and the selection
  -- follows it when that changes, so that the tab is about the config in hand until somebody picks another in the list.
  --
  local oldid = qf.admincfg
  local oldidx = nil

  if (not oldid or qf.adminfollows ~= pp.currentid) then
    oldid = pp.currentid
  end

  qf.adminfollows = pp.currentid

  qf.admincfg = nil

  --
  -- The active policy's configs and nobody else's. The window shows one policy, so the list of configs to switch between is
  -- that policy's, and a config of any other policy is reached by switching to it.
  --
  local mine = self:PolicyConfigs(pp)

  for k,v in pairs(mine) do
    local ent = {id = k }
    tinsert(newconfs, ent)
  end
  tsort(newconfs, function(a, b)
    return strlower(mine[a.id].name) < strlower(mine[b.id].name)
  end)

  for k,v in ipairs(newconfs) do
    local cfp = self:Config(v.id)

    vt[k] = { text = cfp.name, value = v.id }

    --
    -- A dropdown item takes a colour rather than a coloured string, so this asks for the colour itself. White stands in for
    -- the plain name here because an item must be given one.
    --
    vt[k].color = cfp:NameColour() or KUI.COLOR_WHITE
    if (v.id == oldid) then
      oldidx = k
    end
  end

  qf.sortedconfigs = newconfs

  konfer.mainwin.cfgselector:UpdateItems(vt)
  -- Don't fire an OnValueChanged event when we set this.
  konfer.mainwin.cfgselector:SetValue(pp.currentid, true)

  --
  -- Rebuilding the list deselects it, which would throw the tab's unsaved changes away on the way past. They are held from
  -- here until the same config has been picked again (see PS.Hold).
  --
  qf.adminpending:Hold()
  qf.cfglist.itemcount = #newconfs
  qf.cfglist:UpdateList()

  --
  -- There is some magic happening here. By forcing the selection (3rd arg true) we force the widget's selectitem function to
  -- run. This results in config_selectitem() being called. This has a few side effects. The first and foremost is, it sets
  -- the window's qf.admincfg to the selected configuration (if any). Secondly, it forces a refresh of the data on the right
  -- hand panel that is related to the selected config. This includes updating the list of coadmins. That leaves us with a
  -- choice on how we want to deal with the co-admin list when we have sync events or other things changing the coadmin list.
  -- We can either have a special refresh and reset function just for co-admins, or we can leave it up to this code to result
  -- in the refresh. It provides better data protection and encapsulate usage if we go with the latter, so we no longer have
  -- a special co-admin update function. Instead, if anything changes the list of co-admins it should call this function (RefreshConfigAdminUI).
  --
  --
  -- Let go once the same config has been picked again. What another admin has replaced is gone then, so the row is picked
  -- once more to put what is left on screen.
  --
  qf.cfglist:SetSelected(oldidx, true, true)
  qf.adminpending:Release()

  if (oldidx) then
    qf.cfglist:SetSelected(oldidx, true, true)
  end
end

--
-- The Admin tab's unsaved changes, for a policy's own options on the tab. See CreateConfigUI in Policy.lua.
--
function konfer:AdminPending()
  return qf.adminpending
end

--
-- The unsaved changes of POL's own Config tab NAME (ConfigTabs in Policy.lua). Bound to the config picked in the Admin tab's
-- list, as that tab's own are: another config picked there throws away what was held for the last.
--
function konfer:PolicyTabPending(pol, name)
  local rec = pol and pol.configtabs and pol.configtabs[name]
  local ps = rec and rec.pending

  if (ps and ps.cfgid ~= qf.admincfg) then
    ps.cfgid = qf.admincfg
    ps:Discard()
  end

  return ps
end

--
-- Put the active policy's own Config tabs back for the config picked in the Admin tab's list, or tell them there is none,
-- CFGID nil, so that they disable what they hold.
--
function konfer:RefreshConfigPolicyTabs()
  local pp = self.apol

  if (not pp or not pp.configtabs) then
    return
  end

  for name, rec in pairs(pp.configtabs) do
    self:PolicyTabPending(pp, name):Reconcile()

    if (rec.def.Refresh) then
      self:PolicyHook(pp, "ConfigTabs.Refresh", nil, rec.def.Refresh, rec.client, qf.admincfg)
    end
  end
end

function konfer:RefreshConfigAdminUI(reset)
  if (qf.cfglist and self.apol and self.apol.cfg) then
    refresh_config_admin(self, self.apol, reset)
  end

  self:RefreshSyncUI(true)
end

--
-- Refresh the config tab UI elements, optionally resetting all state variables. This will only ever really impact admins as
-- they are the only ones that can see the tab. However, we do this for everybody to simplify the overall logic of the mod.
-- For non-admins this will just be a little bit of busy work that will happen so quickly they won't even notice it.
--
function konfer:RefreshConfigUI(reset)
  -- The selector offers the active policy's configs, that being the policy the window is showing.
  if (self.mainwin and self.apol and self.apol.currentid) then
    self.mainwin.cfgselector:SetValue(self.apol.currentid)
  end

  self:RefreshConfigLootUI(reset)
  self:RefreshConfigRollUI(reset)
  self:RefreshConfigAdminUI(reset)
  self:RefreshConfigPolicyTabs()

  -- What another admin's change of settings says shows on the Raid page as well, PUG's columns there among it.
  self:RefreshPolicyPages()
end
