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
local KLD = LibStub:GetLibrary("KoreLoot")
local L = konfer.L
local KUI = konfer.KUI
local MakeFrame = KUI.MakeFrame

local _G = _G
local tinsert = table.insert
local tsort = table.sort
local strfmt = string.format
local strlen = string.len
local strrep = string.rep
local strupper = string.upper
local strlower = string.lower
local max = math.max
local tostring = tostring
local pairs, ipairs, type = pairs, ipairs, type
local pcall = pcall
local SlashCmdList = SlashCmdList
local IsShiftKeyDown = IsShiftKeyDown

local white = konfer.white
local shortaclass = konfer.shortaclass

--
-- The foyer -- the room you arrive in before choosing a door. This is Konfer as a whole rather than any one distribution
-- system: every policy the mod knows about as a card down the left, the configs that use the selected one at the top right,
-- and whatever that policy wants to say about the selected config underneath.
--
-- It is deliberately not a tabbed dialog and has no pages or tabs. Pages and tabs belong to the policy window, which is a
-- different thing reached by a policy's own slash command. It is never called a page for that reason.
--
-- Nothing here is a distribution system talking. The platform owns the list of policies, the list of configs, and every
-- button along the bottom; a policy contributes exactly two things, its title card and the contents of the lower right panel.
--

--
-- The card is a policy's artwork scaled down, drawn whole so that the band along its bottom shows, with the command plaque on
-- it. A card is wider than it is tall by a long way, so the list item is the card plus a small gap.
--
local CARD_WIDTH  = 250
local CARD_HEIGHT = 125
local CARD_GAP    = 6
local CARD_ITEM   = CARD_HEIGHT + CARD_GAP

--
-- The selection rim is drawn outside the card, so the card cannot sit in the corner of its row or the rim falls outside the
-- list and is clipped away. This is KUI:CreateImageButton's default rim width.
--
local CARD_OUTLINE = 2

--
-- The mark on the active policy's card: how far its centre sits inside the card's right edge, and how wide it is drawn.
--
-- The tick is wider than it is tall, so the width is what is given and the height follows its own shape.
--
local TICK_INSET = 14
local TICK_WIDTH = 14

--
-- How tall the stamp over a card in beta is drawn, its width following the stamp's own 3:2, and how far left of the card's
-- centre it sits, over the picture rather than the policy's name.
--
local BETA_HEIGHT = 72
local BETA_LEFT   = 60

--
-- The configs panel is as tall as CONFIG_ROWS configs of two lines and scrolls beyond that. Nobody has more than two or three
-- configs, while what is said below it can run on, so the column is biased that way: the configs take what they need and
-- the Overview takes everything else, including all of the room a taller window brings.
--
-- A config is a card on a canvas that scrolls, each as tall as it needs. On its first line its name, with how many lists and
-- users it has against the right hand end, and under them its admin, and its co-admins against the right hand end, running
-- on to as many lines as they take and never reaching further left than CONFIG_GAP past the end of the admin's name.
-- CONFIG_PAD is how far its words stand in from its edges, CONFIG_EDGE from its top and bottom.
--
local CONFIG_ROWS = 5
local CONFIG_LINE = 14
local CONFIG_PAD  = 8
local CONFIG_EDGE = 2
local CONFIG_GAP  = 8
local CONFIG_ITEM = 2 * CONFIG_LINE + 2 * CONFIG_EDGE
local CONFIG_FONT = "GameFontNormalSmall"

--
-- The Overview opens with the selected policy's description, OVERVIEW_PAD in from the canvas. Under it, for a policy that
-- does not draw its own, is a box for each of the selected config's lists, in the order the Lists page shows them, the list's
-- name set into its top line, and each as tall as what is in it, OVERVIEW_GAP apart. In a box is how many are on the list
-- and under that, indented, its members: the whole of a list of OVERVIEW_WHOLE or fewer, and of a longer one the top
-- OVERVIEW_ENDS, this character and the bottom OVERVIEW_ENDS, with a row of dots wherever some are passed over,
-- OVERVIEW_ROWS rows at most.
--
local OVERVIEW_LINE     = 14
local OVERVIEW_ENDS     = 3
local OVERVIEW_WHOLE    = 2 * OVERVIEW_ENDS
local OVERVIEW_ROWS     = 2 * OVERVIEW_ENDS + 3
local OVERVIEW_INDENT   = 24
local OVERVIEW_NAME_GAP = 5
local OVERVIEW_GAP      = 6
local OVERVIEW_PAD      = 4
local OVERVIEW_FONT     = "GameFontNormalSmall"

--
-- A card, its selection rim on either side, the strip the scroll list keeps on its right for the bar, what the panel's own
-- padding takes at each end, and clearance so that the cards do not run up against the bar. A card that does not fit is
-- drawn over the bar rather than shrunk, so this is measured rather than guessed at: 250 + (2 x 2) + 21 + (2 x 6) + 16.
--
local LEFT_WIDTH   = 303
local BUTTON_BAR   = 30

--
-- The window may be dragged out to any size that fits on the screen. Without a maximum given, KoreUI takes the starting size
-- for one, and a window whose whole point is that its cards grow could then only ever shrink.
--
local WIN_MINWIDTH  = 725
local WIN_MINHEIGHT = 470
local WIN_MAXWIDTH  = 2048
local WIN_MAXHEIGHT = 1536

--
-- The window opens tall enough to show the card of every policy in the box, those registered by the time this file loads,
-- CARDS_CHROME being what it takes beyond its cards.
--
local CARDS_CHROME  = 95
local WIN_WIDTH     = 725
local WIN_HEIGHT    = math.max(WIN_MINHEIGHT, CARDS_CHROME + konfer.npolicies * CARD_ITEM)

--
-- How far below the top of the screen the window opens. It is a tall window and centring one leaves it hanging off the
-- bottom on a short screen, so it hangs from the top instead.
--
local WIN_TOP       = -16

--
-- The left hand button row is laid out left to right at refresh time rather than at fixed positions, because Broadcast comes
-- and goes: it belongs only to an admin, and a fixed position would leave a hole where it used to be.
--
local BUTTON_X    = 8
local BUTTON_W    = 90
local BUTTON_STEP = 95

--
-- The settings button sits in the corner itself, as wide as its word needs, and the users button stands SETTINGS_GAP clear
-- of it rather than being placed in its own right, so the two never meet however wide each ends up.
--
local SETTINGS_GAP = 8

--
-- How far down the artwork behind the lower right panel is multiplied. A background has to lose an argument with whatever
-- the policy draws in front of it, and this is where that argument is settled, not in the texture.
--
-- Darkening is a multiply and SetVertexColor is that same multiply, so the file ships at full brightness and this number is
-- free to change without one being rebuilt. Doing it after compression also bands far less: DXT1 carries a few levels of
-- error whatever it is handed, and multiplying afterwards scales that error down with the signal instead of leaving it
-- sitting on an image that had almost no range left to hide it in.
--
local INFO_BG_SHADE = 0.11

--
-- How that artwork meets a pane which is not the square the artwork is.
--
--   "cover"    Fill the pane and crop the overflow. No empty ground, but at a
--              tall pane the crop takes the outer arms of the star with it.
--   "contain"  Fit the whole image inside the pane, leaving the pane's own
--              ground as a band along the longer axis. Everything stays
--              visible, at the price of that band.
--
-- Neither stretches the artwork. The choice is only ever between losing part of the picture and leaving ground showing.
--
local INFO_BG_FIT = "contain"

konfer.foyerwin = KUI:CreateDialogFrame({
  x = "CENTER", y = WIN_TOP,
  name = "KonferFoyerWin",
  title = konfer:WindowTitle(L["FOYER_TITLE"]),
  -- One of the mod's two windows, at a window's strata rather than a dialog's.
  strata = "HIGH",
  canmove = true,
  canresize = "HEIGHT",
  escclose = true,
  xbutton = true,
  blackbg = true,
  width = WIN_WIDTH,
  height = WIN_HEIGHT,
  minwidth = WIN_MINWIDTH,
  minheight = WIN_MINHEIGHT,
  maxwidth = WIN_MAXWIDTH,
  maxheight = WIN_MAXHEIGHT,
})

local qf = {}

--
-- Which policy and which config the user has selected, as handles and ids rather than list positions, because the lists are
-- rebuilt underneath them whenever a policy is switched off or a config is created.
--
local selpolicy = nil
local selcfg = nil

local sortedpolicies = {}
local sortedconfigs = {}

-- The configs' cards, one a config, made as a policy with more configs than any before it needs them and kept.
local cfgcards = {}

--
-- The Overview's boxes, one a list, made as a config with more lists than any before it needs them and kept, since WoW
-- never lets a frame go. And the policy and config they were last drawn for, so that a different one is shown from its top.
--
local overviewboxes = {}
local overviewcfg = nil

--
-- True while konfer:RefreshFoyerUI rebuilds the policies' list, which deselects and reselects on the way. The Overview is
-- drawn once at the end of that rather than for every step of it, a step with nothing selected emptying it and losing where
-- the player had scrolled it to.
--
local refreshing = false

local newcfgdlg = nil

-- The policies to draw, in display order: every one switched on.
local function rebuild_policies()
  sortedpolicies = {}

  for k, v in ipairs(konfer:SortedPolicies()) do
    tinsert(sortedpolicies, v.handle)
  end

  if (selpolicy and not konfer.policies[selpolicy]) then
    selpolicy = nil
  end
end

--
-- The configs governed by the current policy. A config that names no policy belongs to the default one, which is what
-- GetPolicy already decides, so ask it rather than reading cfg.policy directly.
--
local function rebuild_configs()
  sortedconfigs = {}

  if (selpolicy) then
    for k, v in pairs(konfer:PolicyConfigs(konfer.policies[selpolicy])) do
      tinsert(sortedconfigs, { id = k, name = v.name })
    end
  end

  -- Without regard to case, the order every other list of configs is in.
  tsort(sortedconfigs, function(a, b)
    return strlower(a.name) < strlower(b.name)
  end)
end

--
-- The config the mod comes back to when it is loaded, and the policy that governs it. This is the one thing on this window
-- that is true of the mod as a whole rather than of whatever the user is looking at, so the foyer opens pointed at it and
-- says so wherever it comes up.
--
local function default_config()
  --
  -- Whatever the active policy has in hand, that being the config the mod is actually running.
  --
  local cfgid = konfer.apol and konfer.apol.currentid
  local cfg = cfgid and konfer:Config(cfgid)

  if (not cfg) then
    return nil, nil
  end

  return cfgid, cfg:GetPolicy().handle
end

--
-- Where a config sits in the list as it is drawn now. This takes the id it is looking for rather than reading the selection,
-- because the selection is not to be trusted around a list rebuild: UpdateList deselects, and a deselection clears it.
--
local function config_index(cfgid)
  if (not cfgid) then
    return nil
  end

  for k, v in ipairs(sortedconfigs) do
    if (v.id == cfgid) then
      return k
    end
  end

  return nil
end

--
-- The config the list points at when a policy is selected, so that the Overview always has one to show: the config that
-- policy already runs, which for the active policy is the one the mod comes back to, and failing that the first. Nil only
-- for a policy with no configs at all.
--
local function chosen_index()
  local pol = selpolicy and konfer.policies[selpolicy]

  return config_index(pol and pol.currentid) or ((#sortedconfigs > 0) and 1 or nil)
end

--
-- Whether this character administers the given config. The foyer shows the Broadcast button only to an admin, because only
-- an admin has anything to broadcast.
--
local function is_admin(cfg)
  return cfg:MyStatus() and true or false
end

--
-- N of something, in the words for one of them or for several.
--
local function counted(n, one, many)
  return strfmt((n == 1) and one or many, n)
end

--
-- What the right hand end of a config's row says: how many lists it has and how many users. A policy whose every config runs
-- on one list nobody sees has no lists worth counting, so its rows give the users alone.
--
local function config_counts(cfg)
  local users = counted(cfg.nusers or 0, L["FOYER_USER"], L["FOYER_USERS"])

  if (cfg:GetPolicy().onelist) then
    return users
  end

  local nlists = 0

  for k in pairs(cfg.lists) do
    nlists = nlists + 1
  end

  return strfmt(L["FOYER_COUNTS"], counted(nlists, L["FOYER_LIST"], L["FOYER_LISTS"]), users)
end

--
-- The second line of a config's card and those under it: who owns it, and its other admins in name order, a space between
-- each, as many to a line as fit in what WIDTH leaves past the owner's name and CONFIG_GAP, the first line headed. No lines
-- where there are no co-admins.
--
local function config_admins(cfg, width)
  if (not cfg.owner) then
    return "", {}
  end

  local oname, ocls = cfg:UserNameClass(cfg.owner)
  local room = width - KUI:MeasureStrWidth(strfmt(L["FOYER_ADMIN"], K.DisplayName(oname)), CONFIG_FONT) - CONFIG_GAP
  local uids = {}

  for uid in pairs(cfg.admins or {}) do
    if (uid ~= cfg.owner) then
      tinsert(uids, uid)
    end
  end

  tsort(uids, function(a, b)
    return strlower(cfg:UserName(a) or a) < strlower(cfg:UserName(b) or b)
  end)

  local lines = {}
  local line, plain = "", ""

  for k, uid in ipairs(uids) do
    local name, cls = cfg:UserNameClass(uid)
    local comma = (k < #uids) and "," or ""
    local word, wplain = shortaclass(name, cls) .. comma, K.DisplayName(name) .. comma
    local more = (plain == "") and wplain or (plain .. " " .. wplain)
    local measured = (#lines == 0) and strfmt(L["FOYER_COADMINS"], more) or more

    if (plain ~= "" and KUI:MeasureStrWidth(measured, CONFIG_FONT) > room) then
      tinsert(lines, line)
      line, plain = word, wplain
    else
      line = (line == "") and word or (line .. " " .. word)
      plain = more
    end
  end

  if (line ~= "") then
    tinsert(lines, line)
  end

  if (lines[1]) then
    lines[1] = strfmt(L["FOYER_COADMINS"], lines[1])
  end

  return strfmt(L["FOYER_ADMIN"], shortaclass(oname, ocls)), lines
end

--
-- Place the visible buttons in a row from the left edge, skipping any that are hidden so the row never has a gap in it.
--
local function layout_buttons()
  local x = BUTTON_X

  for k, btn in ipairs(qf.buttonrow) do
    if (btn:IsShown()) then
      btn:ClearAllPoints()
      btn:SetPoint("TOPLEFT", qf.buttonbar, "TOPLEFT", x, 0)
      x = x + BUTTON_STEP
    end
  end
end

--
-- Enable and show the buttons along the bottom for whatever is selected. The rules are: Create needs a policy, the rest need
-- a config, and Broadcast needs the config to be one this character administers.
--
local function update_buttons()
  if (not qf.buttonrow) then
    return
  end

  local haspol = selpolicy ~= nil
  local cfg = selcfg and konfer:Config(selcfg)
  local hascfg = cfg and true or false
  local admin = hascfg and is_admin(cfg)

  --
  -- Activate lights up whenever pressing it would change something, and says so by being dead rather than by doing nothing when it would not.
  --
  -- A policy that is not the active one always would: it becomes the active one and takes the current one's place, whether
  -- or not the user has picked one of its configs as well. Picking one is how you say which config it should run, and not
  -- picking one leaves it on whichever it already had.
  --
  -- For the policy that is already active only a different config of its own is a change, and selecting the one it is already running is not.
  --
  local selpol = selpolicy and konfer.policies[selpolicy] or nil
  local canactivate = false

  if (selpol and selpol ~= konfer.apol) then
    canactivate = true
  elseif (hascfg and selcfg ~= default_config()) then
    canactivate = true
  end

  qf.createbutton:SetEnabled(haspol)
  qf.activatebutton:SetEnabled(canactivate)
  qf.deletebutton:SetEnabled(hascfg)

  --
  -- With no config selected Broadcast is there but dead, like the buttons beside it. It goes only for a config this player
  -- cannot broadcast, not being one of its admins. It is dark too while the last broadcast's wait runs (konfer.bcastwait).
  --
  qf.bcastbutton:SetShown(admin or not hascfg)
  qf.bcastbutton:SetEnabled((admin and not konfer.bcastwait) and true or false)

  layout_buttons()
end

function konfer:RefreshFoyerButtons()
  update_buttons()
end

--
-- Which of a list of N the Overview shows, as positions in order with 0 wherever some are passed over: the whole of a short
-- list, and of a longer one the top and bottom OVERVIEW_ENDS and ME, this character's own position, if they are on it.
--
local function overview_positions(n, me)
  local shown = {}
  local last = 0

  for pos = 1, n do
    if (n <= OVERVIEW_WHOLE or pos <= OVERVIEW_ENDS or pos > n - OVERVIEW_ENDS or pos == me) then
      if (pos > last + 1) then
        tinsert(shown, 0)
      end

      tinsert(shown, pos)
      last = pos
    end
  end

  return shown
end

--
-- The Overview's Nth box, made the first time a config has that many lists. It holds a line for the count and a row for each
-- member it can show, a member's position in a column of its own so that the names line up past it. A box has the rings of
-- a titled one only if it is made with a title, so it is made with the name of the list it is first drawn for.
--
local function overview_box(n, title)
  if (overviewboxes[n]) then
    return overviewboxes[n]
  end

  local box = KUI:CreateGroupBox({ title = title }, qf.overview.canvas)
  local cf = box.content
  local header = cf:CreateFontString(nil, "ARTWORK", OVERVIEW_FONT)

  header:SetPoint("TOPLEFT", cf, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", cf, "TOPRIGHT", 0, 0)
  header:SetHeight(OVERVIEW_LINE)
  header:SetJustifyH("LEFT")
  box.header = header

  box.rows = {}

  for i = 1, OVERVIEW_ROWS do
    local y = 0 - i * OVERVIEW_LINE
    local pos = cf:CreateFontString(nil, "ARTWORK", OVERVIEW_FONT)
    local name = cf:CreateFontString(nil, "ARTWORK", OVERVIEW_FONT)

    pos:SetPoint("TOPLEFT", cf, "TOPLEFT", OVERVIEW_INDENT, y)
    pos:SetHeight(OVERVIEW_LINE)
    pos:SetJustifyH("LEFT")

    name:SetPoint("TOPLEFT", pos, "TOPRIGHT", OVERVIEW_NAME_GAP, 0)
    name:SetPoint("TOPRIGHT", cf, "TOPRIGHT", 0, y)
    name:SetHeight(OVERVIEW_LINE)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)

    box.rows[i] = { pos = pos, name = name }
  end

  overviewboxes[n] = box
  return box
end

--
-- Fill BOX with list LISTID of CFG and size it to what it shows. Positions are counted in the policy's own order, through
-- Order, so that each says what a place on the list means to that policy, and a member is followed by whatever ValueText
-- says they are worth. This character on a tethered list stands where their main does (cfg:ListPosition).
--
local function overview_fill(box, cfg, listid)
  local rl = cfg.lists[listid]
  local users = rl.users or {}
  local n = #users
  local myuid = cfg:MyUid()
  local _, order = cfg:PolicyCall("Order", users, listid, users)
  local shown = overview_positions(n, myuid and cfg:ListPosition(myuid, listid))
  local colw = KUI:MeasureStrWidth("[" .. strrep("0", max(2, strlen(tostring(n)))) .. "]", OVERVIEW_FONT)

  box:SetTitleText(rl.name)
  box.header:SetText(counted(n, L["FOYER_USER"], L["FOYER_USERS"]))

  for i, row in ipairs(box.rows) do
    local pos = shown[i]

    row.pos:SetWidth(colw)

    if (not pos) then
      row.pos:SetText("")
      row.name:SetText("")
    elseif (pos == 0) then
      row.pos:SetText("")
      row.name:SetText("...")
    else
      local uid = order[pos]
      local name = shortaclass(cfg:UserNameClass(uid))
      local _, value = cfg:PolicyCall("ValueText", nil, listid, uid)

      row.pos:SetText("[" .. tostring(pos) .. "]")
      row.name:SetText(value and strfmt("%s (%s)", name, value) or name)
    end
  end

  box:SetHeight(box.rings.top + (#shown + 1) * OVERVIEW_LINE + box.rings.bottom)
end

--
-- The lower right panel, the Overview, top to bottom on a canvas that scrolls: the selected policy's description, as many
-- lines as it takes, and under it what there is to say about the selected config. That is the config's lists, a box each,
-- unless the policy gives PopulateBannerInfo, which draws what it would rather on a frame of its own under the description
-- and answers how tall it made it, nothing at all for a policy whose description says all there is. That frame is made the
-- first time it is needed and shown only while its policy is selected, since sharing one between policies would have them
-- overwriting each other's widgets. Where there is nothing to show, a line says why. A policy or config other than the one
-- last drawn is shown from the top.
--
local function update_info_panel()
  if (not qf.overview or refreshing) then
    return
  end

  local ov = qf.overview
  local canvas = ov.canvas
  local pol = selpolicy and konfer.policies[selpolicy]
  local own = pol and pol.PopulateBannerInfo
  local cfg = (pol and selcfg) and konfer:Config(selcfg) or nil
  local lists = (cfg and not own) and cfg:SortedLists() or {}
  local note = nil
  local y = 0

  for k, v in pairs(konfer.policies) do
    if (v.foyerinfo) then
      v.foyerinfo:Hide()
    end
  end

  ov.desc:SetWidth(max(ov:GetWidth() - 2 * OVERVIEW_PAD, 1))
  ov.desc:SetText(pol and pol.desc or "")

  if (pol) then
    y = y - OVERVIEW_PAD - ov.desc:GetStringHeight() - OVERVIEW_GAP
  end

  if (not pol) then
    note = L["FOYER_NOPOLICY"]
  elseif (own) then
    if (not pol.foyerinfo) then
      pol.foyerinfo = MakeFrame("Frame", nil, canvas)
    end

    local fr = pol.foyerinfo

    fr:ClearAllPoints()
    fr:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, y)
    fr:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", 0, y)
    fr:SetHeight(1)
    fr:Show()

    --
    -- This calls the *selected* policy, which is not necessarily the active one, so it cannot go through PolicyCall -- that
    -- resolves a policy from a config id and would answer with the wrong one whenever no config is selected. The pcall is
    -- kept for the same reason PolicyCall has one: a broken policy must not take the foyer down with it.
    --
    local ok, tall = pcall(own, pol, selcfg)

    if (not ok) then
      konfer.debug(1, "policy %q PopulateBannerInfo failed: %s", pol.handle, tostring(tall))
    end

    tall = ok and tonumber(tall) or 0
    fr:SetHeight(max(tall, 1))

    if (tall > 0) then
      y = y - tall - OVERVIEW_GAP
    end
  elseif (not cfg or #lists == 0) then
    note = cfg and L["FOYER_NOLISTS"] or L["FOYER_NOCFG"]
  end

  for i, ent in ipairs(lists) do
    local box = overview_box(i, cfg.lists[ent.id].name)

    overview_fill(box, cfg, ent.id)
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, y)
    box:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", 0, y)
    box:Show()
    y = y - box:GetHeight() - OVERVIEW_GAP
  end

  for i = #lists + 1, #overviewboxes do
    overviewboxes[i]:Hide()
  end

  ov.note:ClearAllPoints()
  ov.note:SetPoint("TOPLEFT", canvas, "TOPLEFT", OVERVIEW_PAD, y - OVERVIEW_PAD)
  ov.note:SetText(note or "")

  if (note) then
    y = y - OVERVIEW_PAD - OVERVIEW_LINE - OVERVIEW_GAP
  end

  ov:SetCanvasHeight(max(0 - y - OVERVIEW_GAP, 0))

  local shown = tostring(selpolicy) .. ":" .. tostring(cfg and cfg.id)

  if (shown ~= overviewcfg) then
    overviewcfg = shown
    ov:ScrollTo(0)
  end
end

--
-- Go through the door: open the window on this policy and get the foyer out of the way. The foyer is the room a policy is
-- chosen in, and once one has been it has nothing further to say; leaving it sitting behind the window it just opened would only be clutter.
--
-- The opening itself is konfer:OpenPolicy, which is what that policy's own slash command lands on too. A card and a "/ksk"
-- typed into the chat box are the same intention arriving by different roads, and they go through one door or they will
-- drift apart. That door is also where a card for a policy that is not the active one asks whether to make it so.
--
local function open_policy(handle)
  if (not handle or not konfer.policies[handle]) then
    return
  end

  konfer:OpenPolicy(handle)
end

--
-- A list item is a policy's title card and the gap under it. The card is the platform's -- konfer:CreateTitleCard knows how
-- a policy is drawn -- so what belongs here is the mark saying which policy is the active one, which is the foyer's own
-- business and nobody else's.
--
local function policy_newitem(objp, num)
  local rf = MakeFrame("Frame", nil, objp.content)

  rf:SetWidth(CARD_WIDTH)
  rf:SetHeight(CARD_ITEM)

  local card = konfer:CreateTitleCard({
    name = "KonferFoyerPolicyCard" .. tostring(num),
    width = CARD_WIDTH, height = CARD_HEIGHT, doubleclick = true,
  }, rf)

  card:ClearAllPoints()
  card:SetPoint("TOPLEFT", rf, "TOPLEFT", CARD_OUTLINE, 0 - CARD_OUTLINE)
  card:Catch("OnClick", function(this, evt)
    objp:SetSelected(rf:GetID(), false)
  end)

  --
  -- A card is a door. One click picks it, so that the configs and the policy's own panel beside it are about that policy; a second goes through.
  --
  card:Catch("OnDoubleClick", function(this, evt)
    objp:SetSelected(rf:GetID(), false)
    open_policy(card.handle)
  end)
  rf.card = card

  --
  -- The mark on the active policy's card, inside its right edge and centred on its height. It is the tick a check button
  -- draws, which is what the rest of the mod already means "this one" by, and it keeps its own green rather than taking the window's colours.
  --
  -- Drawn on the card rather than on the row, because the card is a frame of its own above the row and anything on the row
  -- would be behind the artwork. The card's command plaque is on the same layer for the same reason.
  --
  local tick = KUI:CreatePiece(card, "CheckBoxTick", { layer = "OVERLAY", part = "mark" })
  local tw, th = tick:natural()
  local box = tick:Box()

  box:SetSize(TICK_WIDTH, TICK_WIDTH * th / tw)
  box:SetPoint("CENTER", card, "RIGHT", 0 - TICK_INSET, 0)
  tick:Layout()
  tick:Hide()
  rf.activetick = tick

  --
  -- Kore's Beta stamp, on the card of a policy still in beta (beta in Policy.lua). It is centred on the artwork's height above
  -- the band, over the picture and under the hover glow, and anchored to the picture so that it moves with it when pressed.
  -- The texture's coordinates are the stamp without the margins its texture carries.
  --
  local stamp = card:CreateTexture(nil, "ARTWORK", nil, 1)

  stamp:SetTexture(KUI.TEXTURE_PATH .. "Beta")
  stamp:SetTexCoord(0.125, 0.875, 0, 1)
  stamp:SetSize(BETA_HEIGHT * 3 / 2, BETA_HEIGHT)
  stamp:SetPoint("CENTER", card.image, "CENTER", 0 - BETA_LEFT, CARD_HEIGHT / 16)
  stamp:Hide()
  rf.betastamp = stamp

  return rf
end

local function policy_setitem(objp, idx, slot, rf)
  local handle = sortedpolicies[idx]

  rf.card:SetPolicy(handle)

  --
  -- Which policy is the active one, said on the card rather than anywhere else, because the card is what the user is
  -- choosing between. A row is pointed at one policy after another as the list scrolls, so this is set every time rather
  -- than only when the active policy changes.
  --
  rf.activetick:SetShown(konfer.apol ~= nil and konfer.apol.handle == handle)

  local pol = konfer.policies[handle]

  rf.betastamp:SetShown(pol and pol.beta)
end

--
-- THE CONFIGS' CARDS
--
-- Each of the selected policy's configs is a card on qf.cfgframe's canvas, one under another, made the first time a policy
-- has that many. A card marks the pointer and the selection as a list row does, a click selects its config and a double
-- click is config_doubleclick. card.index is the place in sortedconfigs it is showing, card.top how far down the canvas it
-- starts and card.selected whether its config is selcfg.
--
local config_doubleclick

-- A line of words on CARD in FONT, CONFIG_LINE tall, justified to JUSTIFY and ending in an ellipsis rather than running on.
local function card_words(card, font, justify)
  local fs = card:CreateFontString(nil, "ARTWORK", font)

  fs:SetHeight(CONFIG_LINE)
  fs:SetJustifyH(justify)
  fs:SetWordWrap(false)

  return fs
end

--
-- Select the config at IDX in sortedconfigs, or none for nil, marking its card, and with DISPLAY bring the card into view if
-- it is not wholly in it already. Redrawing the Overview and the buttons is the caller's.
--
local function mark_config(idx, display)
  selcfg = idx and sortedconfigs[idx] and sortedconfigs[idx].id or nil

  for i, card in ipairs(cfgcards) do
    card.selected = (card:IsShown() and selcfg ~= nil and sortedconfigs[i] ~= nil and sortedconfigs[i].id == selcfg) and true
      or false
    KUI:RowSelected(card, card.selected)
  end

  local card = idx and cfgcards[idx]
  local view = qf.cfgframe
  local at = view.scrollbar:GetValue() or 0

  if (display and card and card:IsShown() and (card.top < at or card.top + card:GetHeight() > at + view:GetHeight())) then
    view:ScrollTo(card.top)
  end
end

local function config_card(i)
  if (cfgcards[i]) then
    return cfgcards[i]
  end

  local card = MakeFrame("Button", "KonferFoyerConfigCard" .. i, qf.cfgframe.canvas)

  card:SetHeight(CONFIG_ITEM)

  card.counts = card_words(card, CONFIG_FONT, "RIGHT")
  card.counts:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0 - CONFIG_PAD, 0 - CONFIG_EDGE)

  card.text = card_words(card, CONFIG_FONT, "LEFT")
  card.text:SetPoint("TOPLEFT", card, "TOPLEFT", CONFIG_PAD, 0 - CONFIG_EDGE)
  card.text:SetPoint("TOPRIGHT", card.counts, "TOPLEFT", 0 - KUI.WIDGET_GAP, 0)

  card.admin = card_words(card, CONFIG_FONT, "LEFT")
  card.admin:SetPoint("TOPLEFT", card.text, "BOTTOMLEFT", 0, 0)
  card.coadmins = {}

  KUI:RowHighlight(card)

  card:SetScript("OnClick", function(this)
    mark_config(this.index, false)
    update_info_panel()
    update_buttons()
  end)

  card:SetScript("OnDoubleClick", function(this)
    config_doubleclick(this)
  end)

  cfgcards[i] = card
  return card
end

-- Fill CARD with config CFG, called NAME, its co-admins on as many lines as they take, and make it as tall as that.
local function fill_card(card, cfg, name)
  local admin, lines = config_admins(cfg, qf.cfgframe:GetWidth() - 2 * CONFIG_PAD)

  card.text:SetText(cfg:NameColoured(name))
  card.counts:SetText(config_counts(cfg))
  card.admin:SetText(admin)

  for k = 1, max(#lines, #card.coadmins) do
    if (not card.coadmins[k]) then
      local fs = card_words(card, CONFIG_FONT, "RIGHT")

      fs:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0 - CONFIG_PAD, 0 - CONFIG_EDGE - k * CONFIG_LINE)
      card.coadmins[k] = fs
    end

    card.coadmins[k]:SetText(lines[k] or "")
  end

  card:SetHeight(CONFIG_ITEM + max(#lines - 1, 0) * CONFIG_LINE)
end

--
-- Draw the selected policy's configs, a card each one under another, as sortedconfigs has them. A policy other than the one
-- last drawn is shown from the top.
--
local cfgpolicy = nil

local function draw_configs()
  local canvas = qf.cfgframe.canvas
  local y = 0

  for i, ent in ipairs(sortedconfigs) do
    local card = config_card(i)

    card.index = i
    card.top = 0 - y
    fill_card(card, konfer:Config(ent.id), ent.name)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, y)
    card:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", 0, y)
    card:Show()
    y = y - card:GetHeight()
  end

  for i = #sortedconfigs + 1, #cfgcards do
    cfgcards[i]:Hide()
  end

  qf.cfgframe:SetCanvasHeight(0 - y)

  if (selpolicy ~= cfgpolicy) then
    cfgpolicy = selpolicy
    qf.cfgframe:ScrollTo(0)
  end
end

local function policy_selectitem(objp, idx, slot, btn, onoff)
  if (onoff) then
    selpolicy = sortedpolicies[idx]
    selcfg = nil
  elseif (onoff == nil) then
    selpolicy = nil
    selcfg = nil
  end

  rebuild_configs()

  --
  -- Selecting a policy points the configs at one of its own (chosen_index), so that the Overview has something to show and
  -- the policy that owns the default config shows which one the mod would come back to without having to remember. A
  -- refresh draws them once at its end instead.
  --
  if (qf.cfgframe and not refreshing) then
    draw_configs()
    mark_config(chosen_index(), true)
  end

  update_info_panel()
  update_buttons()
end

local function policy_highlightitem(objp, idx, slot, btn, onoff)
  btn.card:SetSelected(onoff)
end

--
-- Activate the policy selected and the config selected with it, both in one action. A config selected says which config the
-- policy should run, and is set first so that the policy comes up on it rather than on whatever it had before. A card clicked
-- and nothing else has selected the config the policy already runs, so it comes up on that. With none selected, a policy
-- with no configs at all, it is activated with none.
-- SILENT keeps the change of config out of chat, for a caller that says what happened itself. Answers the policy, or nil
-- for none selected.
--
local function activate_selection(silent)
  local pol = selpolicy and konfer.policies[selpolicy]

  if (not pol) then
    return nil
  end

  local cfg = selcfg and konfer:Config(selcfg)

  if (cfg) then
    cfg:SetDefault(silent, true)
  end

  konfer:ActivatePolicy(pol)
  konfer:RefreshFoyerUI()

  return pol
end

--
-- A config double-clicked is the Activate button and a door at once: its policy and it become the ones running loot, asking
-- nothing first as Activate does not, and the policy's window opens on it, chat saying which config of which policy that
-- is. The game gives the second click of the pair to this rather than to the card's OnClick, so the card is selected here
-- as well. A switch refused, loot being handed out, leaves the foyer where it was.
--
config_doubleclick = function(this)
  mark_config(this.index, false)

  local cfg = selcfg and konfer:Config(selcfg)
  local pol = activate_selection(true)

  if (pol and pol == konfer.apol) then
    if (cfg) then
      konfer.info(L["FOYER_ACTIVATED"], white(cfg.name), pol.name)
    end

    konfer:OpenPolicy(pol.handle)
  end
end

--
-- Creating a config from here is the same act as creating one from the config page, except that the policy is already
-- chosen: it is whichever card is selected. That is the whole reason this button lives in the foyer.
--
local function create_config_button()
  local box

  if (not selpolicy) then
    return
  end

  if (not newcfgdlg) then
    newcfgdlg, box = K.SingleStringInputDialog(konfer, "KonferFoyerNewConfig",
      { text = L["Create configuration"], owner = konfer.policies[selpolicy] }, L["NEWMSG"], 400, 165)

    --
    -- The name is verified and the config created in one place, because both the OK button and Enter in the edit box have to do the same thing.
    --
    --
    -- CreateNewConfig says for itself why a name it refuses is no good, too short among them, so nothing is checked here.
    --
    local function verify_with_create(objp, val)
      if (konfer:CreateNewConfig(val, false, nil, nil, selpolicy)) then
        objp:Show()
        objp.ebox:SetFocus()
        return true
      end

      local cfgid = konfer:FindConfig(konfer.policies[selpolicy], val)

      if (cfgid) then
        selcfg = cfgid
      end

      objp:Hide()
      konfer:RefreshFoyerUI()
      return false
    end

    newcfgdlg:Catch("OnAccept", function(t, evt)
      return verify_with_create(t, t.ebox:GetText())
    end)

    newcfgdlg:Catch("OnCancel", function(t, evt)
      t:Hide()
      return false
    end)

    -- However the dialog is closed, Escape included, which hides it without throwing OnCancel.
    newcfgdlg:Catch("OnHide", function(t, evt)
      konfer.foyerwin:Show()
    end)

    box:Catch("OnEnterPressed", function(t, evt, val)
      return verify_with_create(newcfgdlg, val)
    end)

    --
    -- The dialog is Kore's and bounds its box to a length of its own choosing, which is nothing to do with what a config may be called.
    --
    box:SetMaxLetters(konfer.CONFIG_NAME_MAX)
  else
    box = newcfgdlg.ebox
  end

  -- Built once, and the selected card may be a different policy every time it comes up.
  newcfgdlg:SetTitleText(konfer.policies[selpolicy]:WindowTitle(L["Create configuration"]))
  box:SetText("")

  konfer.foyerwin:Hide()
  newcfgdlg:Show()
  box:SetFocus()
end

--
-- Deleting from the foyer asks what the policy window asks, and the foyer stands aside while it does.
--
local function delete_config_button()
  local cfgid = selcfg
  local cfg = cfgid and konfer:Config(cfgid)

  if (not cfg) then
    return
  end

  local win = konfer.foyerwin:IsShown() and konfer.foyerwin or nil

  cfg:ConfirmDelete(win, function()
    selcfg = nil
    konfer:RefreshFoyerUI()
  end)
end

function konfer:RefreshFoyerUI()
  if (not qf.policylist) then
    return
  end

  rebuild_policies()
  rebuild_configs()

  --
  -- What is selected has to be remembered across the rebuild below, because UpdateList deselects the list it is given -- and
  -- a deselection runs the deselect handler, which is what clears these in the first place. Without this, a refresh always
  -- ends up with nothing selected, and picking a policy would also throw away the config, which is right when the user picks
  -- one and wrong when a card is hidden or a config created.
  --
  local wantpol = selpolicy
  local wantcfg = selcfg

  refreshing = true
  qf.policylist.itemcount = #sortedpolicies
  qf.policylist:UpdateList()

  local pidx = nil

  for k, v in ipairs(sortedpolicies) do
    if (v == wantpol) then
      pidx = k
      break
    end
  end

  if (pidx) then
    qf.policylist:SetSelected(pidx, true, true)
  else
    selpolicy = nil
    selcfg = nil
    qf.policylist:SetSelected(nil)
  end

  draw_configs()
  qf.cfgempty:SetShown(selpolicy ~= nil and #sortedconfigs == 0)

  --
  -- Whatever was selected, if it is still there; failing that the one a policy selected points at. Both are resolved from
  -- ids rather than from the selection, which the rebuild above has just thrown away.
  --
  mark_config(config_index(wantcfg) or chosen_index(), true)

  refreshing = false
  update_info_panel()
  update_buttons()
end

function konfer:InitialiseFoyerUI()
  local cf = self.foyerwin.content

  --
  -- The window is three regions: policies on the left, and the right half cut again into the configs that use the selected
  -- policy and whatever that policy wants to say about the selected config.
  --
  -- They are recessed panels rather than a flat surface scored by KoreUI splits, because that is the idiom Blizzard's own
  -- art is drawn for -- the Guild pane of the Social window is exactly this. Each panel stands its own padding clear of its
  -- outside, so they are anchored edge to edge and the space between any two of them is those two paddings.
  --
  local btns = MakeFrame("Frame", nil, cf)
  btns:SetPoint("BOTTOMLEFT", cf, "BOTTOMLEFT", 0, 0)
  btns:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 0, 0)
  btns:SetHeight(BUTTON_BAR)

  --
  -- The cards are artwork of their own and are the only thing in the left hand column, so it draws nothing: a recessed panel
  -- around them would be a frame around a column of frames. The two on the right are ordinary content and keep theirs.
  --
  local left = KUI:CreateInset({ inset_art = false }, cf)
  left:ClearAllPoints()
  left:SetPoint("TOPLEFT", cf, "TOPLEFT", 0, 0)
  left:SetPoint("BOTTOMLEFT", btns, "TOPLEFT", 0, 0)
  left:SetWidth(LEFT_WIDTH)

  local rtop = KUI:CreateInset({ title = L["Configurations"] }, cf)
  rtop:ClearAllPoints()
  rtop:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
  rtop:SetPoint("TOPRIGHT", cf, "TOPRIGHT", 0, 0)

  --
  -- Sized for its rows and nothing else, so it never grows: the panel below it is anchored to its bottom and takes everything that is left.
  --
  rtop:SetHeight((CONFIG_ROWS * CONFIG_ITEM) + rtop.rings.top +
    rtop.rings.bottom)

  local rbot = KUI:CreateInset({ title = L["FOYER_OVERVIEW"] }, cf)
  rbot:ClearAllPoints()
  rbot:SetPoint("TOPLEFT", rtop, "BOTTOMLEFT", 0, 0)
  rbot:SetPoint("TOPRIGHT", rtop, "BOTTOMRIGHT", 0, 0)
  rbot:SetPoint("BOTTOM", btns, "TOP", 0, 0)

  --
  -- An inset's own frame is its border, so widgets go in its content area or they sit on top of the artwork.
  --
  qf.infopane = rbot.content

  --
  -- The mod's own artwork behind whatever the policy puts in this panel, so that the foyer still feels like the foyer under
  -- it. It is on the content area at BACKGROUND, which puts it above the inset's border art and below pol.foyerinfo, that
  -- being a child of this same pane.
  --
  local infobg = rbot.content:CreateTexture(nil, "BACKGROUND")
  infobg:SetTexture(konfer.TEXTURE_PATH .. "Konfer")
  infobg:SetVertexColor(INFO_BG_SHADE, INFO_BG_SHADE, INFO_BG_SHADE)
  qf.infobg = infobg

  --
  -- The artwork is square and this pane is not, so one of the two has to give. INFO_BG_FIT says which. Contain sizes the
  -- texture to the shorter side and centres it, so the whole composite is on screen with ground showing along the other
  -- axis. Cover pins it to the pane and takes the largest centred rectangle of the pane's own shape out of the texture instead.
  --
  -- Either way the crop or the fit is recomputed from the pane, so it follows the window rather than being decided once at the default size.
  --
  local function fit_infobg(this)
    local w, h = this:GetWidth(), this:GetHeight()

    if (not w or not h or w <= 0 or h <= 0) then
      return
    end

    infobg:ClearAllPoints()

    if (INFO_BG_FIT == "contain") then
      local side = (w < h) and w or h

      infobg:SetPoint("CENTER", this, "CENTER", 0, 0)
      infobg:SetSize(side, side)
      infobg:SetTexCoord(0, 1, 0, 1)
      return
    end

    local uh, vh = 0.5, 0.5

    if (w > h) then
      vh = h / w / 2
    else
      uh = w / h / 2
    end

    infobg:SetAllPoints(this)
    infobg:SetTexCoord(0.5 - uh, 0.5 + uh, 0.5 - vh, 0.5 + vh)
  end

  rbot.content:SetScript("OnSizeChanged", fit_infobg)
  fit_infobg(rbot.content)

  --
  -- A card is a hundred pixels tall, so scrolling by whole items would throw one clean past you at a time.
  --
  qf.policylist = KUI:CreateScrollList({
    name = "KonferFoyerPolicyList",
    itemheight = CARD_ITEM,
    scrollstyle = "smooth",
    newitem = policy_newitem,
    setitem = policy_setitem,
    selectitem = policy_selectitem,
    highlightitem = policy_highlightitem,
  }, left.content)

  --
  -- The configs are cards each as tall as what they say, on a canvas that scrolls (THE CONFIGS' CARDS). Where the co-admins'
  -- lines break depends on how wide it is, so they are drawn again whenever that changes.
  --
  qf.cfgframe = KUI:CreateScrollFrame({ name = "KonferFoyerConfigs" }, rtop.content)
  qf.cfgframe:HookScript("OnSizeChanged", function()
    if (selpolicy and not refreshing) then
      draw_configs()
      mark_config(config_index(selcfg), false)
    end
  end)

  --
  -- The Overview's description and boxes are each as tall as what is in them, which the rows of a scroll list cannot be, so
  -- they are drawn on a canvas that scrolls, ov.desc the description at its top and ov.note the line saying why there is
  -- nothing more. Where the description's lines break depends on how wide it is, so it is drawn again whenever that changes.
  --
  local ov = KUI:CreateScrollFrame({ name = "KonferFoyerOverview" }, qf.infopane)

  ov.desc = ov.canvas:CreateFontString(nil, "ARTWORK", OVERVIEW_FONT)
  ov.desc:SetPoint("TOPLEFT", ov.canvas, "TOPLEFT", OVERVIEW_PAD, 0 - OVERVIEW_PAD)
  ov.desc:SetJustifyH("LEFT")
  ov.desc:SetJustifyV("TOP")
  ov.desc:SetWordWrap(true)

  ov.note = ov.canvas:CreateFontString(nil, "ARTWORK", OVERVIEW_FONT)
  ov.note:SetJustifyH("LEFT")

  ov:HookScript("OnSizeChanged", function()
    update_info_panel()
  end)

  qf.overview = ov

  --
  -- What the Configurations panel says when the selected policy has none, in place of an empty list. Shown by the refresh.
  --
  qf.cfgempty = KUI:CreateStringLabel({
    x = 10, y = -10, text = L["FOYER_NOCONFIGS"], autosize = false,
    width = 600, font = "GameFontNormalSmall",
  }, rtop.content)
  qf.cfgempty:Hide()

  --
  -- The buttons that act on the selection are in the bottom left corner and light up as a policy and then a config are
  -- selected. The reveal toggle is on its own in the opposite corner, because it acts on the cards rather than on anything selected.
  --
  qf.createbutton = KUI:CreateButton({
    x = BUTTON_X, y = 0, width = BUTTON_W, height = 22, text = L["Create"],
    enabled = false,
    tooltip = { title = "$$", text = L["TIP_FOYER_CREATE"] },
  }, btns)
  qf.createbutton:Catch("OnClick", function(this, evt)
    create_config_button()
  end)

  qf.activatebutton = KUI:CreateButton({
    x = BUTTON_X, y = 0, width = BUTTON_W, height = 22, text = L["Activate"],
    enabled = false,
    tooltip = { title = "$$", text = L["TIP_FOYER_ACTIVATE"] },
  }, btns)
  --
  -- Activate this policy and config, both in one action. One of the two places the user chooses the active policy on
  -- purpose, a config double-clicked being the other, and neither asks anything first: pressing a button labelled Activate
  -- is already the answer the switch dialog would be asking for.
  --
  qf.activatebutton:Catch("OnClick", function(this, evt)
    activate_selection()
  end)

  qf.deletebutton = KUI:CreateButton({
    x = BUTTON_X, y = 0, width = BUTTON_W, height = 22, text = L["Delete"],
    enabled = false,
    tooltip = { title = "$$", text = L["TIP_FOYER_DELETE"] },
  }, btns)
  qf.deletebutton:Catch("OnClick", function(this, evt)
    delete_config_button()
  end)

  qf.bcastbutton = KUI:CreateButton({
    x = BUTTON_X, y = 0, width = BUTTON_W, height = 22, text = L["Broadcast"],
    enabled = false,
    tooltip = { title = "$$", text = L["TIP_FOYER_BROADCAST"] },
  }, btns)
  qf.bcastbutton:Catch("OnClick", function(this, evt)
    local cfg = selcfg and konfer:Config(selcfg)

    if (cfg and is_admin(cfg)) then
      cfg:Broadcast(IsShiftKeyDown())
      cfg:GetPolicy():info(L["configuration %q broadcast."], white(cfg.name))
    end
  end)

  --
  -- The mod's own settings, which have nothing to do with any policy or any config and so belong to the foyer rather than to a page.
  --
  qf.settingsbutton = KUI:CreateButton({
    name = "KonferFoyerSettingsButton",
    width = KUI:WidestString({ L["Settings"] }) + 24, height = 22, text = L["Settings"],
    tooltip = { title = L["Settings"], text = L["TIP_FOYER_SETTINGS"] },
  }, btns)
  qf.settingsbutton:ClearAllPoints()
  qf.settingsbutton:SetPoint("TOPRIGHT", btns, "TOPRIGHT", 0 - BUTTON_X, 0)
  qf.settingsbutton:Catch("OnClick", function(this, evt)
    self:OpenSettings()
  end)

  --
  -- The mod's users, which like its settings belong to no policy and no config, so they sit beside the settings.
  --
  qf.usersbutton = KUI:CreateButton({
    name = "KonferFoyerUsersButton",
    width = KUI:WidestString({ L["Users"] }) + 24, height = 22, text = L["Users"],
    tooltip = { title = L["Users"], text = L["TIP_FOYER_USERS"] },
  }, btns)
  qf.usersbutton:ClearAllPoints()
  qf.usersbutton:SetPoint("TOPRIGHT", qf.settingsbutton, "TOPLEFT", 0 - SETTINGS_GAP, 0)
  qf.usersbutton:Catch("OnClick", function(this, evt)
    konfer:OpenUserEditor()
  end)

  --
  -- The left hand row in the order it is drawn. layout_buttons walks this and places whichever of them are currently shown.
  --
  qf.buttonbar = btns
  qf.buttonrow = {
    qf.createbutton, qf.activatebutton, qf.deletebutton, qf.bcastbutton,
  }

  self.foyerwin:Catch("OnShow", function(this, evt)
    --
    -- The foyer and the policy window are two views of the same mod and only one of them is ever up. The foyer is the one you arrive back at.
    --
    if (konfer.mainwin) then
      konfer.mainwin:Hide()
    end

    self:RefreshFoyerUI()
  end)
end

--
-- Whether this client is handing loot out right now, which is the one thing that stops the active policy being changed: a
-- roll or bids open on an item, or a loot window open on a corpse or a chest. An award half made is worth more than the
-- convenience of switching without finishing it. Items merely on the loot list, waiting, are not being handed out, loot
-- added by hand having no window to close, and a switch puts them away with the rest of the policy's loot session
-- (konfer:ActivatePolicy). A raider shown the master looter's loot is handing nothing out, so it stops nothing for them.
--
function konfer:LootInProgress()
  return self:AmIML() and (self:RollOrBidOpen() or KLD:IsLootOpen()) and true or false
end

--
-- Ask whether POL should become the active policy, and do it if the answer is yes. AFTER is run once it is, which is how the
-- thing the user was actually trying to do gets done.
--
-- Only one policy is active at a time, so reaching for a second one is a choice between them rather than a way of having
-- both. The dialog says so in as many words, because "no data or functionality is lost" is the part a user needs to hear
-- before they will answer it.
--
function konfer:AskSwitchPolicy(pol, after)
  --
  -- With no active policy there is nothing to choose between, so the switch is simply made. That is a mod with every policy
  -- switched off, which is not a state a user can reach, but it is one startup passes through.
  --
  if (not pol or pol == self.apol) then
    return
  end

  if (not self.apol) then
    self:ActivatePolicy(pol)

    if (after) then
      after()
    end

    return
  end

  --
  -- Refused rather than asked while loot is open. There is no wording that makes abandoning a distribution halfway a
  -- reasonable thing to click through, so the user closes the loot first and comes back.
  --
  if (self:LootInProgress()) then
    self.err(L["POLICY_SWITCH_LOOTING"], self.apol.name, pol.name)
    return
  end

  -- Whichever of the two windows is up stands aside for the question and comes back after it.
  local win = (self.foyerwin:IsShown() and self.foyerwin) or (self.mainwin and self.mainwin:IsShown() and self.mainwin) or nil

  K.ConfirmationDialog(self, L["Change active policy"],
    strfmt(L["POLICY_SWITCH"], white(self.apol.name), white(pol.name), white(pol.name)),
    { L["Loot policy: %s"], pol.name }, function(kmod, arg)
      kmod:ActivatePolicy(arg.pol)

      if (arg.after) then
        arg.after()
      end
    end, { pol = pol, after = after }, win, 240)
end

--
-- Open the window on the config POL currently has, making POL the active policy first if it is not already, since the window
-- shows that policy and nothing else.
--
-- The window is a view of a config, so with no config there is nothing for it to be a view of and it is not opened. The
-- foyer is exempt from this and this is not: bare "/konfer" is how you get out of having no config, whereas this window is
-- only useful once you have one.
--
-- The no-config message comes before the switch dialog on purpose. Being asked to change policy and then being told the
-- policy you changed to has nothing to show is a worse answer than being told so straight away, and it is the message that
-- names the command for putting it right.
--
function konfer:OpenPolicy(handle)
  local pol = self.policies[handle]

  --
  -- A bare policy command comes straight here rather than through OnSlashCommand, so this is where it learns the mod is switched off.
  --
  if (self:IsSuspended()) then
    self:SaySuspended()
    return
  end

  if (not pol) then
    return
  end

  if (self:IsTempCfg(pol) or not pol.currentid) then
    pol:info(L["no active configuration. Either create one with %s or wait for a guild admin to broadcast the guild list."],
      white(strfmt("/%s %s", pol.command or L["CMDNAME"], L["CMD_CREATECONFIG"])))
    return
  end

  if (pol ~= self.apol and self.apol) then
    self:AskSwitchPolicy(pol, function()
      konfer:ShowMainWindow()
    end)
    return
  end

  self:ShowMainWindow(pol)
end

function konfer:OpenFoyer()
  if (self:IsSuspended()) then
    self:SaySuspended()
    return
  end

  --
  -- Opened, the foyer starts on wherever the mod actually is: the default config, and the policy that governs it. Only
  -- opening it does. When it merely comes back from standing aside for a dialog of its own, it is shown as it was left, the
  -- card picked still picked, because that dialog may yet be acting on that card.
  --
  local cfgid, handle = default_config()

  if (handle and not self:IsPolicyDisabled(handle)) then
    selpolicy = handle
    selcfg = cfgid
  end

  if (self.foyerwin:IsShown()) then
    self:RefreshFoyerUI()
  else
    self.foyerwin:Show()
  end
end

--
-- The user editor, which is Kore's. Putting the foyer away for it and getting it back is arranged through the StandAside and
-- ComeBack this mod registered with Kore.Users, so it happens however the editor is reached, this button or "/kuser" typed
-- at the chat bar. Nothing is needed here beyond refusing while the mod is suspended, which is this mod's own business.
--
function konfer:OpenUserEditor()
  if (self:IsSuspended()) then
    self:SaySuspended()
    return
  end

  KU:OpenUserEditor()
end

--
-- A policy may name a slash command that opens its own window. Kore builds its slash table when the addon is created, which
-- is long before any policy has registered, so these are added straight to the game's own dispatcher rather than through Kore.
--
function konfer:RegisterPolicyCommands()
  for handle, pol in pairs(self.policies) do
    if (type(pol.command) == "string" and strlen(pol.command) > 0) then
      local sn = "KONFER_POLICY_" .. strupper(handle)

      --
      -- Bare "/ksk" opens the window on this policy. Anything after it is the policy command set, run with this policy in
      -- hand, so that "/ksk createconfig" makes an SK config however the mod is set up. That set is a policy's own and is
      -- not the one "/konfer" takes: the mod has no current config to lend a command, so a configuration, a list, a user
      -- entry or an item is only ever named at the command of the policy it belongs to.
      --
      -- There is one window and it shows the active policy, so a command of a policy that is not the active one asks to
      -- switch first, and does what was asked once the user has said yes. The two exceptions are in konfer:CommandNeedsPolicy.
      --
      -- A policy that is switched off cannot be the active one, so none of its commands runs and the user is told where to switch it back on.
      --
      SlashCmdList[sn] = function(input)
        if (konfer:IsPolicyDisabled(handle)) then
          konfer.err(L["POLICY_SWITCHED_OFF"], pol.name)
        elseif (not input or input == "") then
          konfer:OpenPolicy(handle)
        elseif (pol ~= konfer.apol and konfer.apol and konfer:CommandNeedsPolicy(input)) then
          konfer:AskSwitchPolicy(pol, function()
            konfer:OnPolicyCommand(input, pol)
          end)
        else
          konfer:OnPolicyCommand(input, pol)
        end
      end

      _G["SLASH_" .. sn .. "1"] = "/" .. pol.command
    end
  end
end
