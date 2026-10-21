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
local dkp = konfer.policies.dkp

local tonumber = tonumber

--
-- The events DKP answers that no other policy has heard of, added to its own copy of the standard set.
--
-- Awarding DKP, setting a balance by hand, decaying and timed DKP are the shared half's, answered under DKP's own names for
-- them (DKAWD, DKSET, DKDEC, DKTIM and DKTRQ) by konfer.points. Charging a winner and sharing what they spent are DKP's
-- alone, and like every change to a balance each travels as the numbers it came to.
--
konfer.points:Events(dkp)

--
-- Command: DKCHG listid uid delta
-- Purpose: DELTA added to UID's balance on LISTID: negative for an item won, and positive when that award is undone.
--
dkp.ehandlers.DKCHG = function(self, live, sender, proto, pol, cmd, cfg, ...)
  local listid, uid, delta = ...

  if (cfg.lists[listid]) then
    dkp:ApplyCharge(cfg, listid, uid, tonumber(delta) or 0, not live)
  end
end

--
-- Command: DKZSM listid when shares ilink by
-- Purpose: A zero-sum share of what was spent on ILINK: SHARES, a table of uid to DKP, added to their balances on LISTID at
--          WHEN, by BY, the uid of the admin who made the award. Every amount negative where the award was undone.
--
dkp.ehandlers.DKZSM = function(self, live, sender, proto, pol, cmd, cfg, ...)
  local listid, when, shares, ilink, by = ...

  dkp:ApplyShares(cfg, listid, tonumber(when) or 0, shares, ilink, by, not live)
end
