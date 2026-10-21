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

local _G = _G
local pairs = pairs
local tinsert = table.insert
local strfmt = string.format
local IsShiftKeyDown = IsShiftKeyDown
local UIParent = UIParent

--
-- This file contains all of the UI initialisation code for Konfer.
--

--
-- Every policy Konfer ships with has registered by the time this file is loaded, because this file is last in the TOC.
-- Anything that registers from here on is somebody else's addon, which had to name Konfer as a dependency to reach
-- RegisterPolicy at all and therefore loads after all of this.
--
konfer.builtins_registered = true

--
-- Local state variable to record the name of the last configuration we selected from the config dropdown. This is used to
-- prevent a loop where the button is changed when a new config is selected, which makes a call to refresh the UI, which
-- makes a call to set the conf, which makes a call to refresh the UI ..... ad infinitum. Note that this doesn't REALLY
-- happen because the UI detects whether or not there has been an actual change but that means that this code is dependent on
-- that exact behaviour which isn't a guaranteed contract between the UI code and this. So this errs on the side of caution
-- and prevents what would otherwise be an infinite loop.
--
local last_cfg_selected = nil

--
-- What each page is called, under the name of whichever policy the window is showing. Kept here rather than in the tree
-- below because the tree is built once, with no policy in hand, and konfer:SetWindowPolicy sets these again every time the active policy changes.
--
local PAGE_TITLES = {
  [konfer.LISTS_PAGE] = L["List manager"],
  [konfer.RAID_PAGE] = L["Raid manager"],
  [konfer.LOOT_PAGE] = L["Loot manager"],
  [konfer.USERS_PAGE] = L["User list manager"],
  [konfer.SYNC_PAGE] = L["Sync manager"],
  [konfer.CONFIG_PAGE] = L["Config manager"],
  [konfer.OPTIONS_PAGE] = L["Options"],
}

--
-- The window. There is one, it is the mod's, and it shows the active policy: exactly one policy is active at a time, so a
-- second window could only ever show what this one already does. Five of these was five copies of every page in the mod, and
-- only one of them was ever the one being used.
--
-- What a policy contributes is panels within these pages, built into the same window as everything else and shown only while
-- that policy is the active one. See konfer:BuildPolicyUI.
--
-- The window wears the mod's tint and the kit's sapphire in its gems, with the active policy's accent on its header and that
-- policy's icon as its portrait. Those three, and the title, are what the window puts on as the policy changes under it,
-- and none of them is known here.
--
local function main_window()
  return {
  x = "CENTER", y = "MIDDLE",
  name = "KonferMainWin",
  title = konfer:WindowTitle(),
  canresize = false,
  canmove = true,
  escclose = true,
  xbutton = true,
  width = 600,
  height = 600,
  level = 8,
  tint = konfer.COLOR_UI_TINT,
  tintflat = konfer.COLOR_UI_TINT_FLAT,
  accent = konfer.COLOR_UI_TINT,
  defpage = konfer.LISTS_PAGE,
  --
  -- The window is one size, and the room the save bar takes when a page has unsaved changes is kept at its foot from the
  -- start, every page being laid out in what is left. Nothing moves when the bar comes and goes.
  --
  savebarlocation = "BOTTOM",
  savebarreserved = true,
  --
  -- The page tree. Each page and tab is keyed by the name it is addressed by everywhere else; "order" says only where in its
  -- strip it is drawn. A page marked adminonly is shown only to a config's admins, one marked owneronly only to its owner,
  -- and one marked notadmin only to those who are not its admins; the same applies to tabs. A page marked ingroup is shown
  -- only in a party or a raid, unless the active policy keeps it up (RaidPage.solo in Policy.lua), and one marked
  -- nomasterloot only where the game has no master loot. KoreUI knows nothing about any of it -- Konfer applies them in
  -- apply_page_security, which FullRefresh and a change of group call.
  --
  pages = {
    --
    -- The right hand column is where the tabs change, and it is a container rather than a panel, so that each tab can put in
    -- it whichever titled panels it needs. Lists.lua builds them.
    --
    lists = {
      text = L["Lists"],
      order = 1,
      title = PAGE_TITLES[konfer.LISTS_PAGE],
      vsplit = { width = 200, rightborder = false, rightpadding = 0 }, tabframe = "RIGHT",
      deftab = konfer.LISTS_MEMBERS_TAB,
      tabs = {
        -- Nothing on Members is held for saving, so its member list runs down into the save bar's room.
        members = { text = L["Members"], order = 1, savebar = false, },
        config = { text = L["Config"], order = 2, adminonly = true },
      },
    },
    --
    -- Everybody in the group (Raid.lua), whose first tab is the platform's, the active policy adding tabs of its own after
    -- it while it is active (RaidTabs in Policy.lua). Nothing on it is held for saving.
    --
    raid = {
      text = L["Raid"],
      order = 2, ingroup = true, savebar = false,
      title = PAGE_TITLES[konfer.RAID_PAGE],
      deftab = konfer.RAID_RAIDERS_TAB,
      tabs = {
        raiders = { text = L["Raiders"], order = 1, savebar = false, },
      },
    },
    loot = {
      text = L["Loot"],
      order = 3,
      title = PAGE_TITLES[konfer.LOOT_PAGE],
      deftab = konfer.LOOT_ASSIGN_TAB,
      tabs = {
        -- Nothing on Assign loot is held for saving, so Candidates and Bids / rolls run down into the save bar's room.
        assign = { text = L["Assign loot"], order = 1, savebar = false,
          vsplit = { width = 234 }, },
        --
        -- The item editor lays itself out in InitialiseLootUI, because its top half is as tall as what it holds and
        -- that is known only once it is built.
        --
        itemedit = { text = L["Item editor"], order = 2, adminonly = true, },
        --
        -- The history's button panel is sized to its two rows of buttons in InitialiseLootUI, where they are built. Nothing
        -- on it is ever unsaved, so it has the save bar's room as well. It is everybody's, each keeping a history of their own.
        --
        history = { text = L["History"], order = 3, savebar = false,
          hsplit = { height = 48, topborder = false }, },
        -- What the collecting leader owes by trade (GroupLoot.lua), above a row of buttons.
        trades = { text = L["Trades"], order = 4, savebar = false, adminonly = true, nomasterloot = true,
          hsplit = { height = 24, topborder = false }, },
      },
    },
    --
    -- The right hand column is as wide as what it holds and the User list has the rest, so the split reserves the right
    -- pane, which InitialiseUsersUI sizes once what goes in it has been built.
    --
    users = {
      text = L["Users"],
      order = 4, vsplit = { rightanchor = true }, adminonly = true,
      title = PAGE_TITLES[konfer.USERS_PAGE],
    },
    --
    -- The sync page lays itself out in InitialiseSyncUI, because its top half
    -- is as tall as what it holds and that is known only once it is built.
    --
    -- Nothing on Sync is held for saving, so it has the save bar's room as well.
    sync = {
      text = L["Sync"],
      order = 5, adminonly = true, savebar = false,
      title = PAGE_TITLES[konfer.SYNC_PAGE],
    },
    config = {
      text = L["Config"],
      order = 6, adminonly = true,
      title = PAGE_TITLES[konfer.CONFIG_PAGE],
      deftab = konfer.CONFIG_LOOT_TAB,
      tabs = {
        --
        -- Both tabs lay themselves out in InitialiseConfigUI, because their panels are as tall as what they hold and that
        -- is known only once they are built.
        --
        loot = { text = L["Loot"], order = 1, },
        --
        -- The Admin tab keeps its About panel at the foot of the window, and the save bar goes up just above it. How far
        -- above is the About panel's height, which InitialiseConfigUI sets once it has built it. Every admin of the config
        -- has it, the page being theirs; within it, the owner and co-admin controls enable only for the owner.
        --
        admin = { text = L["Admin"], order = 2, savebaroffset = 0, },
        --
        -- The active policy adds tabs of its own after these while it is active (ConfigTabs in Policy.lua).
        --
      },
    },
    --
    -- What a raider who is no admin of the config decides for themselves (Options.lua), the admins having Config instead.
    -- Each option takes effect as it is ticked, so there is no save bar.
    --
    options = {
      text = L["Options"],
      order = 7, notadmin = true, savebar = false,
      title = PAGE_TITLES[konfer.OPTIONS_PAGE],
    },
  }
  }
end

--
-- POL's title card at the logo's own size, a cell of PolicyLogos, put up as a splash (konfer:MakeSplash) by Shift-clicking
-- the badge or by the policy's "about". It has no command plaque, and what a splash says is squeezed into the band at its foot.
--
local SPLASH_WIDTH = 512
local SPLASH_HEIGHT = 256
local splash = nil

function konfer:ShowPolicySplash(pol)
  if (not splash) then
    splash = self:CreateTitleCard({
      name = "KonferSplash", width = SPLASH_WIDTH, height = SPLASH_HEIGHT, command = false, outline = false,
      highlight = false, push = false,
    }, UIParent)
    self:MakeSplash(splash, SPLASH_HEIGHT / 8)
  end

  splash:SetPolicy(pol)
  self:ShowSplash(splash, pol.splashwords or strfmt(L["using %s"], pol.name))
end

--
-- Build the window and every page in it. Safe to call as often as you like; one that is already built is handed back as it is.
--
-- Nothing here is a policy's. The pages are the mod's and are built once, and what a policy adds to them is built separately by konfer:BuildPolicyUI.
--
function konfer:InitialiseMainWindow()
  if (self.mainwin) then
    return self.mainwin
  end

  self.mainwin = KUI:CreateTabbedDialog(main_window())
  self:KeepWindowPlace(self.mainwin)

  --
  -- The foyer and this window are two views of the same mod and only one of them is ever up: showing either puts the other
  -- away. Said here, on the window itself, rather than at each of the several places that opens it -- the slash commands,
  -- the foyer's cards, the badge below -- so that every route in obeys it and a new one cannot forget to.
  --
  self.mainwin:Catch("OnShow", function(this, evt)
    konfer.foyerwin:Hide()
    konfer:HideSplash()
  end)

  --
  -- Double-clicking the badge in the top left corner puts the window away and goes back to the foyer. The badge is the
  -- active policy's logo and this is the one gesture on it that is about the mod rather than about that policy. Shift-clicking
  -- it puts up the policy's title card in the window's place (ShowPolicySplash).
  --
  if (self.mainwin.portraitbutton) then
    self.mainwin.portraitbutton:Catch("OnDoubleClick", function(this, evt)
      konfer:OpenFoyer()
    end)
    self.mainwin.portraitbutton:Catch("OnClick", function(this, evt)
      if (IsShiftKeyDown()) then
        konfer:ShowPolicySplash(konfer.apol)
      end
    end)
  end

  --
  -- Every panel and every sub-panel needs to display the current config and the config selector drop-down. Thus, the most
  -- convenient place to put this is in the outer frame's topbar. It is the responsibility of the panels and subtabs to not overwrite this.
  --
  -- The config it selects among is the active policy's, because that is the policy the window is showing. This selector is
  -- the whole of how the user chooses which config loot runs against.
  --
  local tbf = self.mainwin.topbar
  local arg = {
    x = 250, y = 0, name = "KonferConfigSpacesDropdown", itemheight = 16,
    dwidth = 150, items = KUI.emptydropdown, level = 12,
    tooltip = { title = L["TIP028.0"], text = L["TIP028.1"] },
  }
  self.mainwin.cfgselector = KUI:CreateDropDown(arg, tbf)
  self.mainwin.cfgselector:ClearAllPoints()
  self.mainwin.cfgselector:SetPoint("TOPRIGHT", tbf, "TOPRIGHT", -16, -2)
  self.mainwin.cfgselector:Catch("OnValueChanged", function(this, evt, nv)
    if (self.apol and not self:IsTempCfg(self.apol)) then
      if (last_cfg_selected ~= nv) then
        last_cfg_selected = nv
        self:Config(nv):SetDefault()
        if (self.qf.synctopbar) then
          self.qf.synctopbar:SetCurrentCRC()
        end
      end
    end
  end)

  --
  -- A handful of this window's widgets are wanted from files that never see the page that built them -- the sync CRC plate,
  -- the broadcast button, the guild rank dropdowns. Each page publishes those here as it builds them. Everything a page only
  -- needs for itself stays private to that page.
  --
  self.qf = {}

  self:InitialiseListsUI()
  self:InitialiseRaidUI()
  self:InitialiseLootUI()
  self:InitialiseTradesUI()
  self:InitialiseUsersUI()
  self:InitialiseSyncUI()
  self:InitialiseConfigUI()
  self:InitialiseOptionsUI()

  return self.mainwin
end

--
-- A POLICY'S OWN PAGES
--
-- Pages of the active policy's own (Pages in Policy.lua), after the platform's while it is the active one and taken away when
-- it stops being, as its tabs are on the Lists and Config pages. Each is named with the policy's prefix, so no two policies'
-- pages share a name, and one taken away is retired rather than destroyed, so that adding it again brings back what was built.
-- A page may have tabs, in the order given and opening on the first, named plainly, the page they are on being the policy's.
--
local function policy_page(pp, i, p)
  local spec = {
    name = pp.prefix .. p.name, text = p.text, title = pp:WindowTitle(p.title or p.text), order = p.order or (10 + i),
    adminonly = p.adminonly, owneronly = p.owneronly, savebar = false,
  }

  if (p.tabs) then
    spec.tabs = {}
    spec.deftab = p.tabs[1] and p.tabs[1].name

    for j, t in ipairs(p.tabs) do
      spec.tabs[t.name] = {
        text = t.text, order = j, savebar = false, hsplit = t.hsplit, adminonly = t.adminonly, owneronly = t.owneronly,
      }
    end
  end

  return spec
end

local function show_policy_pages(self, pp, onoff)
  for i, p in ipairs(pp.Pages or {}) do
    if (onoff) then
      self.mainwin:AddPage(policy_page(pp, i, p))
    else
      self.mainwin:RemovePage(pp.prefix .. p.name)
    end
  end
end

--
-- Build PP's pages, once each: add the page, build into it and its tabs, and take it away again until PP is the active
-- policy. Each page's content frame is kept in pp.pageclients by the page's name, and each of its tabs' in pp.pagetabs by
-- the page's name and the tab's, for their Refresh.
--
local function build_policy_pages(self, pp)
  pp.pageclients = {}
  pp.pagetabs = {}

  for i, p in ipairs(pp.Pages or {}) do
    local page = self.mainwin:AddPage(policy_page(pp, i, p))

    pp.pageclients[p.name] = page.content
    pp.pagetabs[p.name] = {}

    if (p.Construct) then
      self:PolicyHook(pp, "Pages.Construct", nil, p.Construct, page.content, page.topbar)
    end

    for _, t in ipairs(p.tabs or {}) do
      local client = page.tabsbyname[t.name].content

      pp.pagetabs[p.name][t.name] = client
      self:PolicyHook(pp, "Pages.tabs.Construct", nil, t.Construct, client)
    end
  end

  show_policy_pages(self, pp, false)
end

--
-- Redraw the Raid page, whose columns are the active policy's, and the active policy's own pages and their tabs, those that
-- have a Refresh, once they are built.
--
function konfer:RefreshPolicyPages()
  local pp = self.apol

  self:RefreshRaidUI()

  if (not pp or not pp.pageclients) then
    return
  end

  for _, p in ipairs(pp.Pages or {}) do
    local client = pp.pageclients[p.name]

    if (client and p.Refresh) then
      self:PolicyHook(pp, "Pages.Refresh", nil, p.Refresh, client)
    end

    for _, t in ipairs(p.tabs or {}) do
      local tclient = pp.pagetabs[p.name] and pp.pagetabs[p.name][t.name]

      if (tclient and t.Refresh) then
        self:PolicyHook(pp, "Pages.tabs.Refresh", nil, t.Refresh, tclient)
      end
    end
  end
end

--
-- Build PP's own panels into the window. Once per policy and never again: the frames stay for the session, because WoW
-- cannot destroy one, and are hidden rather than freed while some other policy is the active one.
--
-- A policy that is switched off builds nothing. It is still registered and still resolves configs; it simply has no frames
-- until the user turns it on, and cannot be the active policy meanwhile.
--
function konfer:BuildPolicyUI(pp)
  if (not pp or pp.built or self:IsPolicyDisabled(pp.handle)) then
    return
  end

  if (not self.mainwin) then
    return
  end

  --
  -- Set before rather than after, so that a policy whose Construct reaches back through here cannot start a second build of itself.
  --
  pp.built = true

  self:BuildListsPolicyUI(pp)
  self:BuildRaidPolicyUI(pp)
  self:BuildLootPolicyUI(pp)
  self:BuildUsersPolicyUI(pp)
  self:BuildConfigPolicyUI(pp)
  build_policy_pages(self, pp)
end

--
-- Show or hide PP's own panels, and with them whatever the pages around those panels have to move to make room. A policy
-- that has never been built has nothing to show, which is what makes building lazily safe: nothing asks for a policy's
-- panels until it is the active one, and activating it builds them first.
--
function konfer:ShowPolicyUI(pp, onoff)
  if (not pp or not pp.built) then
    return
  end

  self:ShowListsPolicyUI(pp, onoff)
  self:ShowRaidPolicyUI(pp, onoff)
  self:ShowLootPolicyUI(pp, onoff)
  self:ShowUsersPolicyUI(pp, onoff)
  self:ShowConfigPolicyUI(pp, onoff)
  show_policy_pages(self, pp, onoff)
end

--
-- Everything that happens to a policy as it becomes, or stops being, the one the window shows. The two halves of a policy
-- switch, and konfer:ActivatePolicy is what calls them in the right order; startup calls the first of them for whichever
-- policy it restores, so that login and a switch leave the window in exactly the same state.
--
-- A policy's own panels are up whenever its OnActivate runs: on the way out before they are hidden, on the way in after they
-- have been built and shown. See OnActivate in Policy.lua.
--
function konfer:EnterPolicy(pp)
  if (not pp) then
    return
  end

  self:BuildPolicyUI(pp)
  self:ShowPolicyUI(pp, true)
  self:SetWindowPolicy(pp)

  if (pp.OnActivate) then
    self:PolicyHook(pp, "OnActivate", nil, pp.OnActivate, pp, true)
  end
end

function konfer:LeavePolicy(pp)
  if (not pp) then
    return
  end

  if (pp.OnActivate) then
    self:PolicyHook(pp, "OnActivate", nil, pp.OnActivate, pp, false)
  end

  self:ShowPolicyUI(pp, false)
end

--
-- Put PP's name, colour and badge on the window. The three that say which policy you are looking at, and the only things
-- about the window that are a policy's rather than the mod's.
--
-- A policy without an accent wears the kit's own gold and one without an icon gets the dark corner, which is what a window
-- with no logo wears anyway, so nothing here needs the policy to have supplied art.
--
function konfer:SetWindowPolicy(pp)
  if (not self.mainwin or not pp) then
    return
  end

  --
  -- The policy's own plate rather than the mod's, "<Konfer> Suicide Kings - Lists": this window is the policy's and what is
  -- in the brackets is what owns what follows them. The page names itself after that.
  --
  for name, text in pairs(PAGE_TITLES) do
    self.mainwin:SetPageTitle(name, pp:WindowTitle(text))
  end

  self.mainwin:SetAccent(pp.accent or konfer.COLOR_UI_TINT)
  self.mainwin:SetPortrait(pp.Icon and pp.Icon.texture, pp.Icon and pp.Icon.coords)
end

function konfer:InitialiseUI()
  if (self.initialised) then
    return
  end

  self:InitialiseMainWindow()

  --
  -- Which policies get their own panels built, and when. Lazily, when a policy first becomes active, is what ships, and
  -- konfer.EAGER_POLICY_UI says why development does it all at once instead.
  --
  if (self.EAGER_POLICY_UI) then
    for k, pp in pairs(self.policies) do
      self:BuildPolicyUI(pp)
    end
  end

  --
  -- Startup settled which policy is active before any of this existed, so the window is brought into line with it here,
  -- through the same code a switch uses. A policy restored at login and one switched to at midnight leave the window in the
  -- same state, because they are the same few lines.
  --
  self:EnterPolicy(self.apol)

  --
  -- The foyer is not part of this window at all, but it is built here because everything else is, and its slash commands can
  -- only be registered once every policy has had a chance to load.
  --
  -- The mod's own windows were made as their files loaded, before the character's database was open, so they are told to keep
  -- their places here, before anything is built inside them.
  --
  self:KeepWindowPlace(self.foyerwin)
  self:KeepWindowPlace(self.settingswin)
  self:KeepWindowPlace(KU.usereditwin)
  self:InitialiseFoyerUI()
  self.foyerwin:SetAccent(konfer.COLOR_FOYER_ACCENT)
  self:InitialiseSettingsUI()
  KU:InitialiseUserEditorUI()
  self:RegisterPolicyCommands()
  self:StackWindows()
end

--
-- Stack the mod's windows so that two on screen together lie one over the other rather than through each other: the foyer
-- lowest, then the settings and the user editor, then the window the policies share. That is only where they start. KoreUI
-- brings a window to the front whenever it is shown or clicked, and gives each a band of frame levels of its own however
-- deep it nests (see KUI:SetWindowOrder).
--
function konfer:StackWindows()
  local order = { self.foyerwin, self.settingswin, KU.usereditwin }

  if (self.mainwin) then
    tinsert(order, self.mainwin)
  end

  KUI:SetWindowOrder(order)
end
