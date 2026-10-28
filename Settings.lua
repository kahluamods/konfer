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
local white = konfer.white

local tinsert = table.insert
local tconcat = table.concat
local strfmt = string.format
local tostring = tostring
local pairs, ipairs = pairs, ipairs
local max, ceil = math.max, math.ceil
local UIParent = UIParent

--
-- The mod's own voice rather than a policy's, which is what this window is: it is about the set of policies rather than about anything inside one.
--
local err = konfer.err

--
-- The settings window: the mod's own settings, which belong to no policy and no config. It is reached by the cog in the
-- corner of the foyer, and it takes the foyer's place on screen rather than sitting over it, because the two say
-- contradictory things -- the foyer shows what there is, this decides what there is to show.
--
-- Down its left is a list of sections, any of which may have entries of its own under it, one level deep, and on its right
-- the panel of whichever is picked. Policies switches each policy on or off and Foyer sets the order they are shown in.
--

-- The list of sections, a line a row.
local SECTION_WIDTH  = 160
local SECTION_HEIGHT = 20

-- How wide a section's panel is inside its rims. Its words wrap to this.
local PANEL_WIDTH    = 300

--
-- A policy is shown in both panels by its card from the foyer, scaled down with the band at its foot trimmed away. The
-- artwork is twice as wide as it is tall, so without its bottom eighth the card is 7/16 as tall as it is wide. A row is the
-- card and CARD_GAP.
--
local CARD_WIDTH     = 144
local CARD_HEIGHT    = CARD_WIDTH * 7 / 16
local CARD_GAP       = 5
local ITEM_HEIGHT    = CARD_HEIGHT + CARD_GAP

-- What a switched off policy's card is multiplied by, on top of losing its colour.
local OFF_SHADE      = 0.6

--
-- The arrow art is mostly padding -- the arrow itself is a good deal smaller than the texture it sits in -- so it has to be
-- drawn large to read at all.
--
local ARROW_SIZE     = 30
local ARROW_GAP      = 2

-- The strip under the panel that About stands in.
local BUTTON_BAR     = 30

konfer.settingswin = KUI:CreateDialogFrame({
  x = "CENTER", y = "MIDDLE",
  name = "KonferSettingsWin",
  title = konfer:WindowTitle(L["SETTINGS_TITLE"]),
  canmove = true,
  canresize = false,
  escclose = true,
  xbutton = true,
  blackbg = true,
  width = 620,
  height = 420,
})

local qf = {}

--
-- The policies in display order, disabled ones included: this is the one window that shows a policy that has been switched
-- off, because it is where it gets switched back on.
--
local sortedpolicies = {}

-- Those of them switched on, in the same order, which are all the Foyer panel shows.
local enabledpolicies = {}

-- The key of the section whose panel is showing.
local selsection = "policies"

-- The rows of the list of sections, each { sec = a section, kind = its tree connector }, rebuilt by RefreshSettingsUI.
local sectionrows = {}

local disabledlg = nil

--
-- Set while the settings window is standing aside for a dialog of its own rather than being closed. Closing it puts the
-- foyer back, and that must not happen when it is only getting out of the way for a moment.
--
local dialog_open = false

--
-- How many policies are still switched on. Disabling the last one would leave the mod with nothing to distribute loot by and
-- no way back except this window, so it is not allowed.
--
local function enabled_count()
  local n = 0

  for k, v in ipairs(sortedpolicies) do
    if (not v.disabled) then
      n = n + 1
    end
  end

  return n
end

--
-- Move the switched on policy at IDX in enabledpolicies one place up or down among those, and write the whole order down as
-- it now stands. The two trade places in the whole order, so every policy switched off keeps its own place for when it is
-- switched on again. The lists are rebuilt from the database afterwards rather than being trusted in place, so what is on
-- screen is always what was stored.
--
local function move_policy(idx, delta)
  local a, b = enabledpolicies[idx], enabledpolicies[idx + delta]

  if (not a or not b) then
    return
  end

  local ia, ib

  for k, v in ipairs(sortedpolicies) do
    if (v.handle == a.handle) then
      ia = k
    elseif (v.handle == b.handle) then
      ib = k
    end
  end

  sortedpolicies[ia], sortedpolicies[ib] = sortedpolicies[ib], sortedpolicies[ia]

  konfer:SetPolicyOrder(sortedpolicies)
  konfer:RefreshSettingsUI()
  konfer:RefreshFoyerUI()
end

--
-- A row of either panel: a policy's card at its left hand end, centred on its height. The card is a picture here rather
-- than the foyer's button, so it takes no clicks and lights up for nothing.
--
local function card_row(objp, num, name)
  local rf = KUI.MakeFrame("Frame", nil, objp.content)

  rf:SetWidth(objp:GetWidth())
  rf:SetHeight(ITEM_HEIGHT)

  local card = konfer:CreateTitleCard({
    name = name .. tostring(num), width = CARD_WIDTH, height = CARD_HEIGHT, band = false, command = false,
    outline = false, highlight = false, push = false,
  }, rf)

  card:ClearAllPoints()
  card:SetPoint("LEFT", rf, "LEFT", 0, 0)
  card:EnableMouse(false)
  rf.card = card

  return rf
end

-- Point a row's card at POL, an entry of sortedpolicies, greyed and dimmed while it is switched off.
local function set_card(rf, pol)
  local off = (pol and pol.disabled) and true or false
  local shade = off and OFF_SHADE or 1

  rf.card:SetPolicy(pol and pol.handle)
  rf.card.image:SetDesaturated(off)
  rf.card.image:SetVertexColor(shade, shade, shade, 1)
end

-- The panels' lists select nothing. A row is a policy to be switched on or off, or moved, by its own controls.
local function select_nothing()
end

--
-- A row of the Foyer panel, its arrows beside its card. They are children of the row, so a click on one is a move and
-- nothing else.
--
local function order_newitem(objp, num)
  local rf = card_row(objp, num, "KonferSettingsOrderCard")

  local up = KUI:CreateImageButton({
    name = "KonferSettingsMoveUp" .. tostring(num),
    width = ARROW_SIZE, height = ARROW_SIZE, piece = "ScrollButtonUp",
    tooltip = { title = L["SETTINGS_MOVEUP"], text = L["TIP_SETTINGS_MOVE"] },
  }, rf)
  up:ClearAllPoints()
  up:SetPoint("LEFT", rf.card, "RIGHT", KUI.WIDGET_GAP, 0)
  up:Catch("OnClick", function(this, evt)
    move_policy(rf:GetID(), -1)
  end)
  rf.moveup = up

  local down = KUI:CreateImageButton({
    name = "KonferSettingsMoveDown" .. tostring(num),
    width = ARROW_SIZE, height = ARROW_SIZE, piece = "ScrollButtonDown",
    tooltip = { title = L["SETTINGS_MOVEDOWN"], text = L["TIP_SETTINGS_MOVE"] },
  }, rf)
  down:ClearAllPoints()
  down:SetPoint("LEFT", up, "RIGHT", ARROW_GAP, 0)
  down:Catch("OnClick", function(this, evt)
    move_policy(rf:GetID(), 1)
  end)
  rf.movedown = down

  return rf
end

local function order_setitem(objp, idx, slot, rf)
  set_card(rf, enabledpolicies[idx])

  --
  -- A policy at one end of the list has nowhere to go in that direction, so the arrow is not there at all rather than there and inert.
  --
  rf.moveup:SetShown(idx > 1)
  rf.movedown:SetShown(idx < #enabledpolicies)
end

--
-- Everything that a policy being switched off means. The policy itself is untouched -- it is loaded and cannot be unloaded
-- -- so this is entirely a matter of the mod agreeing not to offer it.
--
local function disable_policy(handle, wipe)
  local pol = konfer.policies[handle]

  konfer.frdb.policydisabled[handle] = true

  --
  -- The window goes away whether or not it was showing this policy. Switching one off reorders what is offered everywhere
  -- and may hand the active policy to somebody else below, and a window left standing through that would be showing the
  -- answer to a question the user has just changed.
  --
  if (konfer.mainwin) then
    konfer.mainwin:Hide()
  end

  if (wipe) then
    --
    -- Collected first and deleted afterwards, because deleting a config while walking the table it is in is how you miss half of them.
    --
    local doomed = {}

    for cfgid, cfp in pairs(konfer:PolicyConfigs(pol)) do
      tinsert(doomed, cfgid)
    end

    for k, cfgid in ipairs(doomed) do
      konfer:Config(cfgid):Delete(false, true)
    end
  end

  --
  -- The active policy is the one that arms for loot, so it cannot be one the user has just said does not exist. The first one
  -- still standing takes over, through the same activation as any other, so the raid state goes, every policy is told and
  -- the choice is remembered. There is always at least one, because disabling the last is refused.
  --
  if (konfer.apol == pol) then
    local live = konfer:SortedPolicies()

    if (live[1]) then
      konfer:ActivatePolicy(konfer.policies[live[1].handle])
    end
  end

  konfer:RefreshSettingsUI()
  konfer:RefreshFoyerUI()
end

--
-- Switching a policy off is two decisions, not one: whether to switch it off, and whether its configs go with it. The second
-- is the destructive one, so it is asked here rather than assumed, and nothing happens at all until this is accepted.
--
local function confirm_disable(handle)
  local pol = konfer.policies[handle]

  if (not pol) then
    return
  end

  if (not disabledlg) then
    local ret = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE",
      name = "KonferDisablePolicyDialog",
      title = konfer:WindowTitle(L["SETTINGS_DISABLE_TITLE"]),
      padding = { left = 10, right = 10, top = 5, bottom = 5 },
      width = 460,
      height = 269,
      canmove = true,
      canresize = false,
      escclose = true,
      blackbg = true,
      okbutton = true,
      cancelbutton = true,
    })

    ret.msg = KUI:CreateStringLabel({
      x = 0, y = 0, width = 400, height = 134, autosize = false,
      font = "GameFontNormal", justifyv = "TOP", text = "",
    }, ret)

    --
    -- Indented a little from the text above them, so that the two read as a choice belonging to that question rather than as two more sentences.
    --
    ret.keep = KUI:CreateRadioButton({
      x = 8, y = -142, width = 390, group = "KonferDisablePolicy",
      value = "keep", checked = true,
      label = { text = L["SETTINGS_DISABLE_KEEP"] },
    }, ret)

    ret.wipe = KUI:CreateRadioButton({
      x = 8, y = -166, width = 390, group = "KonferDisablePolicy",
      value = "wipe",
      label = { text = L["SETTINGS_DISABLE_WIPE"],
        color = { r = 1, g = 0.3, b = 0.3, a = 1 } },
    }, ret)

    ret.wipeval = false

    ret.keep:Catch("OnValueChanged", function(this, evt, val)
      if (val) then
        ret.wipeval = false
      end
    end)

    ret.wipe:Catch("OnValueChanged", function(this, evt, val)
      if (val) then
        ret.wipeval = true
      end
    end)

    ret:Catch("OnCancel", function(this, evt)
      this:Hide()
    end)

    ret:Catch("OnAccept", function(this, evt)
      disable_policy(this.handle, this.wipeval)
      this:Hide()
    end)

    --
    -- Cancel, Escape and anything else that hides this all mean the same thing: the question is over and the settings window
    -- comes back. Putting it here rather than in the Cancel handler is what makes Escape behave, since nothing calls OnCancel for it.
    --
    ret:Catch("OnHide", function(this, evt)
      dialog_open = false
      konfer.settingswin:Show()
    end)

    disabledlg = ret
  end

  disabledlg.handle = handle
  disabledlg.wipeval = false
  disabledlg.keep:SetChecked()
  disabledlg.msg:SetText(strfmt(L["SETTINGS_DISABLE_MSG"], white(pol.name)))

  --
  -- The settings window stands aside rather than sitting behind. This is a question that has to be answered before anything
  -- else happens, and a window still on screen underneath invites the user to go and do something else instead.
  --
  dialog_open = true
  konfer.settingswin:Hide()
  disabledlg:Show()
end

--
-- A policy's box on the Policies panel ticked or unticked by the player. Switching one back on is nothing to think about,
-- so it is done here and now. Switching one off asks first, and the box goes on showing the truth until that is answered,
-- since it shows whether the policy is on rather than what was clicked.
--
local function policy_checked(this, evt, idx, checked, user)
  local pol = sortedpolicies[idx]

  if (not user or not pol) then
    return
  end

  local handle = pol.handle

  if (checked) then
    konfer.frdb.policydisabled[handle] = nil

    --
    -- Its own panels wait until it is the active policy, which a policy just switched on is not. Development builds them
    -- all up front, and this is where one switched on after that gets its share.
    --
    if (konfer.EAGER_POLICY_UI) then
      konfer:BuildPolicyUI(konfer.policies[handle])
    end

    konfer:FullRefresh(false)
    konfer:RefreshSettingsUI()
    konfer:RefreshFoyerUI()
    return
  end

  if (enabled_count() < 2) then
    err(L["SETTINGS_LASTPOLICY"], pol.name)
    return
  end

  confirm_disable(handle)
end

--
-- The settings window standing aside for a splash as it does for a dialog of its own, so that the splash going puts it back
-- rather than the foyer. Its showing again ends that.
--
function konfer:SettingsStandAside()
  dialog_open = true
end

--
-- The foyer's artwork whole and at full brightness, put up as a splash (konfer:MakeSplash) by About and by "/konfer about",
-- with a black strip under it for what a splash says.
--
local ABOUT_SIDE = 512
local ABOUT_STRIP = 48
local ABOUT_TOP = 75
local about = nil

function konfer:ShowAbout()
  if (not about) then
    about = KUI.MakeFrame("Button", "KonferAbout", UIParent)
    about:SetSize(ABOUT_SIDE, ABOUT_SIDE + ABOUT_STRIP)
    about:RegisterForClicks("AnyUp")

    local art = about:CreateTexture(nil, "ARTWORK")

    art:SetTexture(konfer.TEXTURE_PATH .. "Konfer")
    art:SetPoint("TOPLEFT", about, "TOPLEFT", 0, 0)
    art:SetSize(ABOUT_SIDE, ABOUT_SIDE)

    local strip = about:CreateTexture(nil, "BACKGROUND")

    strip:SetColorTexture(0, 0, 0, 1)
    strip:SetPoint("TOPLEFT", art, "BOTTOMLEFT", 0, 0)
    strip:SetPoint("BOTTOMRIGHT", about, "BOTTOMRIGHT", 0, 0)

    self:MakeSplash(about, ABOUT_STRIP, ABOUT_TOP)
  end

  self:ShowSplash(about)
end

--
-- THE SECTIONS
--
-- The sections down the left, in order. A section is { key, label, frame }, FRAME being its panel, and may have entries of
-- its own under it in children, each a section in the same shape. Every panel is made with the window, fills its right hand
-- side, and is shown only while its section is the one picked.
--
local policies_section = { key = "policies", label = L["Policies"] }
local foyer_section = { key = "foyer", label = L["Foyer"] }
local sections = { policies_section, foyer_section }

local function rebuild_sections()
  sectionrows = {}

  for _, sec in ipairs(sections) do
    tinsert(sectionrows, { sec = sec })

    local kids = sec.children or {}

    for i, kid in ipairs(kids) do
      tinsert(sectionrows, { sec = kid, kind = (i < #kids) and "branch" or "end" })
    end
  end
end

local function section_index(key)
  for i, row in ipairs(sectionrows) do
    if (row.sec.key == key) then
      return i
    end
  end

  return nil
end

local function show_section(key)
  selsection = key

  for _, row in ipairs(sectionrows) do
    if (row.sec.frame) then
      row.sec.frame:SetShown(row.sec.key == key)
    end
  end
end

local function section_newitem(objp, num)
  return KUI.NewItemHelper(objp, num, "KonferSettingsSection", objp:GetWidth(), SECTION_HEIGHT)
end

local function section_setitem(objp, idx, slot, btn)
  local row = sectionrows[idx]

  btn:SetText(row and row.sec.label or "")

  -- An entry under a section is in a smaller hand, and stands in past the connector to it.
  btn.text:SetFontObject((row and row.kind) and "GameFontNormalSmallLeft" or "GameFontNormalLeft")
  btn:SetTree(row and row.kind)
end

-- Picking a row shows its panel. The list deselecting as it is filled again leaves the panel showing.
local function section_selectitem(objp, idx, slot, btn, onoff)
  if (onoff and sectionrows[idx]) then
    show_section(sectionrows[idx].sec.key)
  end
end

function konfer:RefreshSettingsUI()
  if (not qf.sectionlist) then
    return
  end

  sortedpolicies = self:SortedPolicies(true)
  enabledpolicies = {}

  for _, pol in ipairs(sortedpolicies) do
    if (not pol.disabled) then
      tinsert(enabledpolicies, pol)
    end
  end

  qf.policylist.itemcount = #sortedpolicies
  qf.policylist:UpdateList()
  qf.orderlist.itemcount = #enabledpolicies
  qf.orderlist:UpdateList()

  rebuild_sections()

  qf.sectionlist.itemcount = #sectionrows
  qf.sectionlist:UpdateList()
  qf.sectionlist:SetSelected(section_index(selsection) or 1, true, true)
end

function konfer:InitialiseSettingsUI()
  local win = self.settingswin
  local cf = win.content

  local left = KUI:CreateInset(nil, cf)
  left:ClearAllPoints()
  left:SetPoint("TOPLEFT", cf, "TOPLEFT", 0, 0)
  left:SetPoint("BOTTOMLEFT", cf, "BOTTOMLEFT", 0, 0)
  left:SetWidth(SECTION_WIDTH)

  qf.sectionlist = KUI:CreateScrollList({
    name = "KonferSettingsSectionList",
    itemheight = SECTION_HEIGHT,
    newitem = section_newitem,
    setitem = section_setitem,
    selectitem = section_selectitem,
    highlightitem = function(objp, idx, slot, btn, onoff)
      return KUI.HighlightItemHelper(objp, idx, slot, btn, onoff)
    end,
  }, left.content)

  -- The panel stops BUTTON_BAR short of the window's foot, for About.
  local right = KUI:CreateInset(nil, cf)
  right:ClearAllPoints()
  right:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
  right:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 0, BUTTON_BAR)

  --
  -- A section's panel, the whole of the right hand side, saying what it is for along its top. Answers the frame under the
  -- words that its list fills.
  --
  local function panel(sec, text)
    local f = KUI.MakeFrame("Frame", nil, right.content)

    f:SetAllPoints(right.content)
    f:Hide()

    local desc = KUI:CreateStringLabel({
      x = 0, y = 0, width = PANEL_WIDTH, autosize = false, justifyv = "TOP", font = "GameFontNormalSmall", text = text,
    }, f)
    desc.label:SetWordWrap(true)
    desc:SetHeight(ceil(desc.label:GetStringHeight()) + desc.xtraheight)
    f.desc = desc

    local under = KUI.MakeFrame("Frame", nil, f)

    under:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, 0 - KUI.WIDGET_GAP)
    under:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    sec.frame = f

    return under
  end

  qf.policylist = KUI:CreateScrollList({
    name = "KonferSettingsPolicyList",
    itemheight = ITEM_HEIGHT,
    itemcheck = "NORMAL",
    ischecked = function(objp, idx)
      return sortedpolicies[idx] ~= nil and not sortedpolicies[idx].disabled
    end,
    newitem = function(objp, num)
      return card_row(objp, num, "KonferSettingsPolicyCard")
    end,
    setitem = function(objp, idx, slot, rf)
      set_card(rf, sortedpolicies[idx])
    end,
    selectitem = select_nothing,
    highlightitem = select_nothing,
  }, panel(policies_section, L["SETTINGS_POLICIES_DESC"]))

  qf.policylist:Catch("OnItemChecked", policy_checked)

  qf.orderlist = KUI:CreateScrollList({
    name = "KonferSettingsOrderList",
    itemheight = ITEM_HEIGHT,
    newitem = order_newitem,
    setitem = order_setitem,
    selectitem = select_nothing,
    highlightitem = select_nothing,
  }, panel(foyer_section, L["SETTINGS_FOYER_DESC"]))

  --
  -- As wide as the two panels side by side, and as tall as the most any panel says along its top, a row for every policy
  -- under that, and the strip for About.
  --
  local words = 0

  for _, sec in ipairs(sections) do
    words = max(words, sec.frame.desc:GetHeight())
  end

  local listheight = #self:SortedPolicies(true) * ITEM_HEIGHT

  win:SetSize(win.rings.left + SECTION_WIDTH + right.rings.left + PANEL_WIDTH + right.rings.right + win.rings.right,
    win.rings.top + right.rings.top + words + KUI.WIDGET_GAP + listheight + right.rings.bottom + BUTTON_BAR
    + win.rings.bottom)

  -- In the bottom right corner, its foot and its right hand end level with the panels' rims.
  qf.aboutbutton = KUI:CreateButton({
    name = "KonferSettingsAboutButton",
    width = KUI:WidestString({ L["About"] }) + 24, height = 22, text = L["About"],
    tooltip = { title = L["About"], text = L["TIP_SETTINGS_ABOUT"] },
  }, cf)
  qf.aboutbutton:ClearAllPoints()
  qf.aboutbutton:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 0 - KUI.INSET_PADDING, KUI.INSET_PADDING)
  qf.aboutbutton:Catch("OnClick", function(this, evt)
    self:ShowAbout()
  end)

  self.settingswin:Catch("OnShow", function(this, evt)
    dialog_open = false
    self:HideSplash()
    self:RefreshSettingsUI()
  end)

  --
  -- The settings window stands in for the foyer rather than covering it, so closing it puts the foyer back however it was
  -- closed -- the X, Escape, or anything else that hides it.
  --
  self.settingswin:Catch("OnHide", function(this, evt)
    if (dialog_open) then
      return
    end

    if (self.foyerwin and not self.foyerwin:IsShown()) then
      self.foyerwin:Show()
    end
  end)
end

function konfer:OpenSettings()
  if (self:IsSuspended()) then
    self:SaySuspended()
    return
  end

  if (self.foyerwin) then
    self.foyerwin:Hide()
  end

  self.settingswin:Show()
end

--
-- What a player on retail is told, once for each character: that Konfer has never been tried there, under a heading of
-- Warning. chardb.untestednotice records that it has been shown, as it is shown, so a reload with it open does not bring it
-- back. ONCLOSE is called when it closes however that happens, and is how the startup dialog after it waits its turn.
-- Answers whether it was shown.
--
local NOTICE_WIDTH = 460

local noticedlg

local function create_notice()
  local dlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = "KonferUntestedNotice", title = konfer:WindowTitle(), border = true,
    width = NOTICE_WIDTH, height = 200, canmove = true, canresize = false, escclose = true, okbutton = true,
    padding = KUI.WIDGET_GAP,
  })

  local inner = NOTICE_WIDTH - dlg.rings.left - dlg.rings.right

  dlg.heading = KUI:CreateStringLabel({
    x = 0, y = 0, width = inner, autosize = false, font = "GameFontNormalLarge", justifyh = "CENTER", justifyv = "TOP",
    text = L["Warning"],
  }, dlg)

  local hh = dlg.heading.label:GetStringHeight()
  local ypos = 0 - hh - KUI.WIDGET_GAP

  dlg.heading:SetHeight(hh)

  dlg.text = KUI:CreateStringLabel({
    x = 0, y = ypos, width = inner, autosize = false, font = "GameFontNormal", justifyh = "LEFT", justifyv = "TOP",
    text = strfmt(L["UNTESTED_NOTICE"], K.red(L["MODTITLE"])),
  }, dlg)

  --
  -- As tall as the words wrap to, which is measured, so the dialog is made the first time it is shown.
  --
  local th = dlg.text.label:GetStringHeight()

  dlg.text:SetHeight(th)
  dlg:SetHeight(dlg.rings.top - ypos + th + dlg.rings.bottom)

  dlg:Catch("OnHide", function(this, evt)
    local onclose = this.onclose

    this.onclose = nil

    if (onclose) then
      onclose()
    end
  end)

  return dlg
end

function konfer:ShowUntestedNotice(onclose)
  if (K.GAME ~= K.GAME_RETAIL or self.chardb.untestednotice) then
    return false
  end

  noticedlg = noticedlg or create_notice()
  self.chardb.untestednotice = true
  noticedlg.onclose = onclose
  noticedlg:Show()

  return true
end

--
-- BECOMING MASTER LOOTER
--
-- Which policy runs loot is the player's to choose and never the mod's, so becoming master looter in a group does no more
-- than say how things stand and offer the way to change them. Where the active policy has no config to run, there is
-- nothing standing yet, and the offer is the foyer, where the choice is made: OK opens it and Cancel does not. Where it has
-- one and it is the only policy switched on, there is no choice to make and nothing is asked. Where it has one among
-- others, the player is told which policy is set to hand loot out: OK opens its window, its config there to be checked,
-- and Foyer opens the foyer to choose another.
--
-- Before any of that, where an addon that also hands out loot is running, Konfer offers to suspend itself, two of them
-- answering one corpse being a muddle nobody wants: Yes suspends it and asks nothing more, and No goes on to the rest. All
-- of it is asked once a group (konfer.raid.mlasked) and nothing is asked of a suspended Konfer. The foyer and the policy
-- set to hand out loot are not offered while either of Konfer's windows is already up; the offer to suspend is, and puts
-- them away while it is asked. It is asked in turn (konfer:InTurn), so a startup question up at the time is answered
-- first, and whether there is anything to ask is decided when its turn comes.
--
-- LOOT_ADDONS are those addons by folder name. LootReserve is not among them, taking reserves and handing nothing out.
--
local LOOT_ADDONS = { "Gargul", "RCLootCouncil", "RCLootCouncil_Classic", "ClassicLootManager", "CEPGP", "BigDumbLootCouncil" }

local questions = {}

--
-- A question with OK and Cancel, as wide as the untested notice and as tall as TEXT wraps to. YES is run on OK and NO on
-- Cancel. Escape puts it away answering neither. LABELS, { yes, no }, is what either button says instead, Yes and No for a
-- question put as one or a choice of its own in place of Cancel; it is fixed when the dialog called NAME is first made.
-- AFTER is run once it has gone, however it was answered, which is what lets it be a step for konfer:InTurn.
--
-- Konfer's own windows go away while it is up, so that nothing of the mod's stands behind it, and come back as it goes,
-- whatever the answer. The dialog is gone before its answer is run, and a yes that suspends the mod puts them away again.
--
local function ask(name, text, yes, no, labels, after)
  local dlg = questions[name]

  if (not dlg) then
    local yeslabel, nolabel = labels and labels.yes, labels and labels.no

    dlg = KUI:CreateDialogFrame({
      x = "CENTER", y = "MIDDLE", name = name, title = konfer:WindowTitle(), border = true, width = NOTICE_WIDTH, height = 200,
      canmove = true, canresize = false, escclose = true, okbutton = yeslabel and { text = yeslabel } or true,
      cancelbutton = nolabel and { text = nolabel } or true, padding = KUI.WIDGET_GAP,
    })

    dlg.text = KUI:CreateStringLabel({
      x = 0, y = 0, width = NOTICE_WIDTH - dlg.rings.left - dlg.rings.right, autosize = false, font = "GameFontNormal",
      justifyh = "LEFT", justifyv = "TOP", text = "",
    }, dlg)

    local function answer(this, which)
      local fn = this[which]

      this.yes, this.no = nil, nil

      if (fn) then
        fn()
      end
    end

    dlg:Catch("OnAccept", function(this)
      answer(this, "yes")
    end)
    dlg:Catch("OnCancel", function(this)
      answer(this, "no")
    end)
    dlg:Catch("OnHide", function(this)
      local nextq = this.after

      this.after = nil
      konfer:WindowsBack(this.away)
      this.away = nil

      if (nextq) then
        nextq()
      end
    end)

    questions[name] = dlg
  end

  dlg.text:SetText(text)

  local th = dlg.text.label:GetStringHeight()

  dlg.text:SetHeight(th)
  dlg:SetHeight(dlg.rings.top + th + dlg.rings.bottom)
  dlg.yes, dlg.no, dlg.after = yes, no, after
  dlg.away = dlg.away or konfer:WindowsAway()
  dlg:Show()
end

-- How many policies are switched on, each of which could be the one handing out loot.
local function policies_on()
  local n = 0

  for handle in pairs(konfer.policies) do
    if (not konfer:IsPolicyDisabled(handle)) then
      n = n + 1
    end
  end

  return n
end

-- The foyer offered, or the policy set to hand out loot named, as a step for konfer:InTurn.
local function offer_foyer(after)
  local up = (konfer.foyerwin and konfer.foyerwin:IsShown()) or (konfer.mainwin and konfer.mainwin:IsShown())

  if (konfer:IsSuspended() or up) then
    return false
  end

  local pol = konfer.apol

  if (not pol or not pol.currentid or konfer:IsTempCfg(pol)) then
    ask("KonferOpenFoyerQuestion", L["FOYER_OFFER"], function()
      konfer:OpenFoyer()
    end, nil, nil, after)
    return true
  end

  if (policies_on() < 2) then
    return false
  end

  local text = strfmt(L["POLICY_LOOT_OFFER"], white(pol.name), white(K.OK_STR), white(L["Foyer"]), konfer.red(L["MODTITLE"]))

  ask("KonferPolicyLootQuestion", text, function()
    konfer:OpenPolicy(pol.handle)
  end, function()
    konfer:OpenFoyer()
  end, { no = L["Foyer"] }, after)
  return true
end

function konfer:BecameMasterLooter()
  if (self:IsSuspended() or self.raid.mlasked) then
    return
  end

  self.raid.mlasked = true

  self:InTurn(function(after)
    if (self:IsSuspended()) then
      return false
    end

    local others = {}

    for _, name in ipairs(LOOT_ADDONS) do
      if (C_AddOns.IsAddOnLoaded(name)) then
        tinsert(others, name)
      end
    end

    if (#others == 0) then
      return offer_foyer(after)
    end

    -- No goes straight on to the foyer, next in turn once this question has gone.
    ask("KonferSuspendQuestion", strfmt(L["SUSPEND_OFFER"], tconcat(others, ", ")), function()
      konfer:Suspend()
    end, function()
      konfer:InTurn(offer_foyer, true)
    end, { yes = K.YES_STR, no = K.NO_STR }, after)
    return true
  end)
end
