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
local epgp = konfer.policies.epgp

local tonumber = tonumber

--
-- The events EP/GP answers that no other policy has heard of, added to its own copy of the standard set.
--
-- Awarding EP, setting a member's numbers by hand, decaying and timed EP are the shared half's, answered under EP/GP's own
-- names for them (KEGEP, EGSET, EGDEC, EGTIM and EGTRQ) by konfer.points. Charging GP is EP/GP's alone.
--
konfer.points:Events(epgp)

--
-- Command: KEGGP listid uid gp
-- Purpose: UID charged GP on LISTID, for an item won, or given it back, negative, when that award is undone.
--
epgp.ehandlers.KEGGP = function(self, live, sender, proto, pol, cmd, cfg, ...)
  local listid, uid, gp = ...

  if (cfg.lists[listid]) then
    epgp:ApplyGP(cfg, listid, uid, tonumber(gp) or 0, not live)
  end
end
