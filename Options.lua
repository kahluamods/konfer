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

--
-- The Options page: what a raider who is no admin of the config decides for themselves, the admins having the Config page
-- instead (notadmin in Init.lua). Each option is this character's own, kept in konfer.chardb whichever config is on screen,
-- and takes effect the moment it is ticked, so the page has no save bar.
--
--   noautoopen      The loot window is not opened when the master looter opens a corpse (OLOOT). An admin goes by the
--                   config's auto_bid instead. Unset, it opens.
--   nolootips       The loot list shows no item tooltip as the pointer rests on a row, Shift turning that round as it does
--                   for the master looter. Unset, it shows.
--   recordhistory   The rows written as loot is handed out (LHADD) are kept. Off unless the raider turns it on, it being a
--                   great deal to keep unasked.
--   ignorehistory   A history an admin broadcasts (LHBCS) is ignored rather than asked about. Never on that question ticks it.
--
local qf = {}

-- The boxes put back to what this character has said, Never answering one of them from elsewhere.
function konfer:RefreshOptionsUI()
  if (not qf.record) then
    return
  end

  qf.autoopen:SetChecked(not self.chardb.noautoopen, true)
  qf.loottips:SetChecked(not self.chardb.nolootips, true)
  qf.record:SetChecked(self.chardb.recordhistory and true or false, true)
  qf.ignore:SetChecked(self.chardb.ignorehistory and true or false, true)
end

function konfer:InitialiseOptionsUI()
  local cf = self.mainwin:GetPage(self.OPTIONS_PAGE).content

  --
  -- One panel across the page, the options in it in two columns, and the panel exactly as tall as its rows.
  --
  local panel = KUI:CreateInset({ title = L["Loot"], padding = 0 }, cf)
  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", cf, "TOPLEFT", 0, 0)
  panel:SetPoint("TOPRIGHT", cf, "TOPRIGHT", 0, 0)

  local pc = panel.content

  -- A box in column COL (1 or 2) at Y, saying TEXT and TIP, ticked or not by CHANGED.
  local function option(col, y, text, tip, changed)
    local box = KUI:CreateCheckBox({ x = 0, y = 0, label = { text = text }, tooltip = { title = "$$", text = tip } }, pc)

    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", pc, (col == 1) and "TOPLEFT" or "TOP", 0, y)
    box:Catch("OnValueChanged", function(this, evt, val)
      changed(val)
    end)
    return box
  end

  qf.autoopen = option(1, 0, L["Auto-open loot panel"], L["TIP_OPTIONS_AUTOOPEN"], function(val)
    konfer.chardb.noautoopen = (not val) or nil
  end)
  qf.loottips = option(2, 0, L["Display tooltips in loot list"], L["TIP003"], function(val)
    konfer.chardb.nolootips = (not val) or nil
  end)

  local row2 = 0 - qf.autoopen:GetHeight() - KUI.WIDGET_GAP

  qf.record = option(1, row2, L["Record loot history during raids"], L["TIP_OPTIONS_RECORDHISTORY"], function(val)
    konfer.chardb.recordhistory = val or nil
  end)
  qf.ignore = option(2, row2, L["Ignore loot history broadcasts"], L["TIP_OPTIONS_IGNOREHISTORY"], function(val)
    konfer.chardb.ignorehistory = val or nil
  end)

  panel:SetHeight(panel.rings.top + qf.autoopen:GetHeight() + KUI.WIDGET_GAP + qf.record:GetHeight() + panel.rings.bottom)

  cf:HookScript("OnShow", function()
    konfer:RefreshOptionsUI()
  end)

  self:RefreshOptionsUI()
end
