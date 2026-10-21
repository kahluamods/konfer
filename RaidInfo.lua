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
local max = math.max
local strfmt = string.format
local strlower = string.lower
local pairs, ipairs = pairs, ipairs
local tonumber, tostring = tonumber, tostring

local err = konfer.err
local shortaclass = konfer.shortaclass

--
-- WHAT THIS CHARACTER REPORTS, AND ASKING EVERYBODY ELSE
--
-- A player's specs and professions are both what they choose to report. A spec is the role they raid in, main and off, and
-- only they can say it: talents say only what a character is playing right now. Somebody whose second profession is a
-- gathering one may rather be asked about the one that makes things, so the professions start from what the game says
-- until the player accepts them. Both are asked at login, in one dialog, and "/konfer specs" opens it again.
--
-- The dialog is Konfer's because when to put a question to the player is Konfer's business, and one of its startup dialogs
-- besides. What it writes is Kore's, because which role a character plays is a fact about that character and not about any
-- one mod, so it is stored once and every KahLua mod on the client reads the same answer. K.MyRoles and K.MyProfessions
-- read it, K.SetMyRoles and K.SetMyProfessions write it, and konfer.chardb keeps only whether this character has been asked.
--
-- Asking everybody else what they play is the character info check. "/konfer raidinfo" and "/konfer vc" ask it the same
-- question and differ only in how the window shows the answer, and Konfer's part is the CINFO prefix it travels under and
-- taking the facts that come back (see konfer:AckCFacts).
--

--
-- The specs dialog. Its words say why a raid leader wants to know, and under them are the four things the player reports
-- about themselves, each labelled down one column: their main spec and off spec, offering only the roles their own class can
-- play, and their two professions. It opens on what the player reports now. Accept stores what it shows and is what answers the question,
-- so a player who cancels or closes it is asked again at the next login. What they choose goes on their own user record
-- too, where they have one, so that every window showing them agrees with what they report.
--
local SPECDLG_WIDTH = 440
local SPECDLG_GAP = 20
local SPECDLG_PARA_GAP = KUI.WIDGET_GAP * 2

-- A clear step between the last dropdown and the buttons, so Accept does not sit immediately under a control it applies to.
local SPECDLG_BUTTON_GAP = KUI.WIDGET_GAP * 4

-- Between the two rows. Each row is titled above itself, so its words need clearance from the dropdowns of the row above.
local SPECDLG_ROW_GAP = KUI.WIDGET_GAP * 2

--
-- What the game fires as the player's professions become known at login, or as one is learned or its skill changes. The
-- union of every client's, each client having only some of them (see K:AceKore).
--
-- These are taken on a frame of the dialog's own rather than on the mod. AceEvent keeps one handler per object per event, so
-- registering them on the mod would replace any handler the mod has for the same event while the dialog is up and take it
-- away entirely when the dialog closes, and PLAYER_ENTERING_WORLD is not an event to be borrowing. A frame that nothing
-- else uses cannot take anything from anybody.
--
local PROF_EVENTS = { "PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB", "TRADE_SKILL_UPDATE" }

local specsdlg

local function create_specs_dialog()
  local dlg = KUI:CreateDialogFrame({
    x = "CENTER", y = "MIDDLE", name = "KonferSpecsDlg", title = konfer:WindowTitle(L["SPECS_TITLE"]), border = true, width = SPECDLG_WIDTH,
    height = 200, canmove = true, canresize = false, escclose = true, padding = KUI.WIDGET_GAP,
    okbutton = true, cancelbutton = true,
  })

  --
  -- Two rows of two, the specs on one line and the professions on the next, each titled above itself, so all four are
  -- measured before anything is drawn. Every dropdown is as wide as the longest thing any of them offers, so the two rows
  -- line up as a grid rather than as four boxes that happen to be near each other.
  --
  local names = { K.NOTSET_STR }

  for _, role in ipairs(K.ClassRoles[K.player.class] or {}) do
    tinsert(names, K.RoleName(role))
  end

  for _, prof in ipairs(KU:ProfessionNames()) do
    tinsert(names, prof)
  end

  local dw = KUI:DropDownWidth(names)
  local grid = dw + SPECDLG_GAP + dw

  --
  -- SPECDLG_WIDTH is what the words want and the grid is what the widgets need, so the dialog is the wider of the two. A
  -- locale with longer words for a profession or a role gets a wider dialog rather than a truncated dropdown.
  --
  -- The words then wrap to whichever that turned out to be and are as tall as that makes them, which is measured, so the
  -- dialog is built the first time it opens, when there is a screen to measure on.
  --
  local inner = max(SPECDLG_WIDTH - dlg.rings.left - dlg.rings.right, grid)

  dlg:SetWidth(inner + dlg.rings.left + dlg.rings.right)

  local ypos = 0

  dlg.text = KUI:CreateStringLabel({
    x = 0, y = ypos, width = inner, autosize = false, font = "GameFontNormal", justifyh = "LEFT", justifyv = "TOP",
    text = L["SPECS_TEXT"],
  }, dlg)

  local th = dlg.text.label:GetStringHeight()

  dlg.text:SetHeight(th)
  ypos = ypos - th - SPECDLG_PARA_GAP

  --
  -- A paragraph of its own under that, saying the question is not asked again and how to answer it again anyway, with the command in white.
  --
  dlg.note = KUI:CreateStringLabel({
    x = 0, y = ypos, width = inner, autosize = false, font = "GameFontNormal", justifyh = "LEFT", justifyv = "TOP",
    text = strfmt(L["SPECS_ONCE"], K.white("/" .. L["CMDNAME"]), K.white(L["CMD_SPECS"])),
  }, dlg)

  th = dlg.note.label:GetStringHeight()
  dlg.note:SetHeight(th)
  ypos = ypos - th - SPECDLG_GAP

  local ddx = (inner - grid) / 2
  local col2 = ddx + dw + SPECDLG_GAP

  dlg.msspec = KU:CreateSpecDropdown("KonferSpecsDlgMainDD", ddx, ypos, dlg, false, dw, nil, "TOP")
  dlg.osspec = KU:CreateSpecDropdown("KonferSpecsDlgOffDD", col2, ypos, dlg, true, dw, nil, "TOP")
  dlg.msspec:SetClass(K.player.class)
  dlg.osspec:SetClass(K.player.class)
  ypos = ypos - dlg.msspec:GetHeight() - SPECDLG_ROW_GAP

  dlg.pprof = KU:CreateProfessionDropdown("KonferSpecsDlgProf1DD", ddx, ypos, dlg, false, dw, nil, "TOP", L["Profession 1"])
  dlg.sprof = KU:CreateProfessionDropdown("KonferSpecsDlgProf2DD", col2, ypos, dlg, true, dw, nil, "TOP", L["Profession 2"])
  ypos = ypos - dlg.pprof:GetHeight() - SPECDLG_BUTTON_GAP

  dlg:SetHeight(dlg.rings.top - ypos + dlg.rings.bottom)

  --
  -- The professions follow the game while the dialog is open, as they become known at login or change, until the player has
  -- chosen them, here or before. The specs are the player's alone and nothing fills them in.
  --
  local function follow_game()
    if (not dlg.profchosen and K.chardb.pprof == nil) then
      local pprof, sprof = K.PlayerProfessions()

      dlg.pprof:SetValue(pprof, true)
      dlg.sprof:SetValue(sprof, true)
    end
  end

  for _, dd in ipairs({ dlg.pprof, dlg.sprof }) do
    dd:Catch("OnValueChanged", function(this, evt, newv, user)
      if (user) then
        dlg.profchosen = true
      end
    end)
  end

  --
  -- The frame the profession events arrive on, which is the dialog's own and nothing else's. An event this client does not
  -- have is skipped rather than handed to the game, which would raise an error, exactly as K:AceKore does for everything else.
  --
  dlg.watcher = KUI.MakeFrame("Frame", nil, dlg)
  dlg.watcher:SetScript("OnEvent", function(this, evt, ...)
    follow_game()
  end)

  dlg:Catch("OnShow", function(this, evt)
    for _, event in ipairs(PROF_EVENTS) do
      if (K.EventExists(event)) then
        this.watcher:RegisterEvent(event)
      end
    end

    follow_game()
  end)

  dlg:Catch("OnHide", function(this, evt)
    this.watcher:UnregisterAllEvents()
  end)

  dlg.OnAccept = function(this)
    local msrole = tonumber(this.msspec:GetValue()) or K.ROLE_UNSET
    local osrole = tonumber(this.osspec:GetValue()) or K.ROLE_UNSET
    local pprof = tonumber(this.pprof:GetValue()) or K.PROF_UNSET
    local sprof = tonumber(this.sprof:GetValue()) or K.PROF_UNSET

    --
    -- What was chosen is the character's and goes to Kore. That this character has now been asked is Konfer's, being about a dialog Konfer puts up.
    --
    konfer.chardb.specsasked = true
    K.SetMyRoles(msrole, osrole)
    K.SetMyProfessions(pprof, sprof)

    local changed = KU:SetRoles(K.player.kuid, msrole, osrole)

    if (KU:SetProfessions(K.player.kuid, pprof, sprof) or changed) then
      KU:UserLinksChanged()
    end

    this:Hide()
  end

  -- Whatever was waiting for the dialog to close, the startup dialog after it, is told once.
  dlg:Catch("OnHide", function(this)
    local after = this.onclose

    this.onclose = nil

    if (after) then
      after()
    end
  end)

  return dlg
end

function konfer:OpenSpecsDialog()
  specsdlg = specsdlg or create_specs_dialog()

  local msrole, osrole = K.MyRoles()
  local pprof, sprof = K.MyProfessions()

  specsdlg.profchosen = false
  specsdlg.msspec:SetValue(msrole, true)
  specsdlg.osspec:SetValue(osrole, true)
  specsdlg.pprof:SetValue(pprof, true)
  specsdlg.sprof:SetValue(sprof, true)
  specsdlg:Show()
end

--
-- Ask which specs to report, unless this character has been asked already. One of the startup dialogs, which come one at a
-- time (see startup_dialogs in Konfer.lua): it answers whether it asked, and ONCLOSE is called once it has been answered.
--
function konfer:AskSpecs(onclose)
  if (self.chardb.specsasked) then
    return false
  end

  self:OpenSpecsDialog()
  specsdlg.onclose = onclose

  return true
end

--
-- What this character reports, written onto their own record, which Kore made at login. Their own client is the one that
-- can see all of this for certain, so it is taken without anybody being asked.
--
function konfer:MyFacts()
  local kuid = K.player.kuid
  local class, race, level, msrole, osrole, pprof, sprof = K.MyFacts()

  if (kuid) then
    KU:SetClass(kuid, class)
    KU:SetProfessions(kuid, pprof, sprof)
    KU:SetRoles(kuid, msrole, osrole)
    KU:SetRace(kuid, race)
    KU:SetLevel(kuid, level)
  end

  return class, race, level, msrole, osrole, pprof, sprof
end

--
-- SENDER's answer to a character info check, taken into what this mod knows about them. The answer is about themselves, so
-- it is taken as it stands and every config we administer that holds them is told (see konfer:ApplyUserCheck).
--
-- Konfer always asks for both specs and professions, so a reply that answered neither came from a client whose Kore is too
-- old to know what was being asked. There is nothing to take from it and nothing is written, rather than the absence being
-- read as an answer and wiping what is already held.
--
function konfer:AckCFacts(sender, reply)
  if (type(reply) ~= "table") then
    return
  end

  local gave = reply.gave or {}

  if (not gave.specs and not gave.profs) then
    return
  end

  local msrole = gave.specs and reply.specs and tonumber(reply.specs[1]) or K.ROLE_UNSET
  local osrole = gave.specs and reply.specs and tonumber(reply.specs[2]) or K.ROLE_UNSET
  local pprof = gave.profs and reply.profs and tonumber(reply.profs[1]) or K.PROF_UNSET
  local sprof = gave.profs and reply.profs and tonumber(reply.profs[2]) or K.PROF_UNSET

  self:ApplyUserCheck(sender, tonumber(reply.class), pprof, sprof, msrole, osrole, tonumber(reply.race),
    tonumber(reply.level))
end

--
-- Ask everybody what they are running and who they are. Konfer wants the characters as much as the versions, so it asks for
-- both extras, and every mod, so that SHOWMODS can list them. Its own version decides who in the answer needs attention.
--
function konfer:CharacterInfoCheck(showmods)
  self:MyFacts()
  self:AskCharacterInfo({ "*" }, { specs = true, profs = true }, showmods)
end
