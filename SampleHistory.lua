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

local tinsert = table.insert
local random = math.random
local strfmt = string.format

--
-- Loot history that never happened, so that the History tab has something in it to look at and sort. Loaded only in a
-- development build, its line in the TOC being inside a debug block, and nothing else in the tree refers to it.
--
--   /run Konfer:SampleHistory(40)
--
-- adds forty entries to the history of the config SK has in hand, or of POLICY's, a handle, when one is named, spread over
-- the last thirty days. Each goes to a random user of the config, or to a made up name and class when it has none, and is
-- won in a random way or on a random list. Nothing is sent: the entries go straight into the config, as history is never
-- synced. The History tab's Clear all takes them away again.
--
local SAMPLE_ITEMS = {
  { 19019, "ff8000", "Thunderfury, Blessed Blade of the Windseeker" },
  { 17182, "ff8000", "Sulfuras, Hand of Ragnaros" },
  { 16922, "a335ee", "Leggings of Transcendence" },
  { 16916, "a335ee", "Netherwind Robes" },
  { 19364, "a335ee", "Ashkandi, Greatsword of the Brotherhood" },
  { 18814, "a335ee", "Choker of the Fire Lord" },
  { 17076, "a335ee", "Bonereaver's Edge" },
  { 18832, "a335ee", "Brutality Blade" },
  { 17063, "a335ee", "Band of Accuria" },
  { 18821, "a335ee", "Quick Strike Ring" },
  { 19375, "a335ee", "Mish'undare, Circlet of the Mind Flayer" },
  { 19347, "a335ee", "Claw of Chromaggus" },
  { 17102, "a335ee", "Cloak of the Shrouded Mists" },
  { 19138, "a335ee", "Band of Sulfuras" },
  { 16800, "a335ee", "Arcanist Boots" },
  { 16811, "a335ee", "Boots of Prophecy" },
}

local SAMPLE_NAMES = { "Aeloria", "Brannok", "Cyrielle", "Dunmore", "Elspeth", "Fenwick", "Grimwald", "Halvard" }

local SAMPLE_HOW = { "R", "M", "O", "D", "A", "B" }

function konfer:SampleHistory(count, policy)
  local pol = policy and self.policies[policy] or self.policies[self.DEFAULT_POLICY]
  local cfp = pol and pol.cfg

  if (not cfp) then
    K.printf(K.ecolor, "SampleHistory: that policy has no config in hand.")
    return
  end

  cfp.history = cfp.history or {}

  local uids, lists, classes = {}, {}, {}

  for uid in pairs(cfp.uids or {}) do
    tinsert(uids, uid)
  end
  for lid in pairs(cfp.lists or {}) do
    tinsert(lists, lid)
  end
  for cls, v in pairs(K.IndexClass) do
    if (v.c) then
      tinsert(classes, cls)
    end
  end

  local now = K.time()

  for i = 1, count or 30 do
    local item = SAMPLE_ITEMS[random(#SAMPLE_ITEMS)]
    local link = strfmt("|cff%s|Hitem:%d::::::::60:::::|h[%s]|h|r", item[2], item[1], item[3])
    local who

    if (#uids > 0) then
      who = uids[random(#uids)]
    else
      who = strfmt("%s/%02d", SAMPLE_NAMES[random(#SAMPLE_NAMES)], classes[random(#classes)])
    end

    local how, pdata = SAMPLE_HOW[random(#SAMPLE_HOW)], nil
    local listid = #lists > 0 and lists[random(#lists)] or false

    -- Half are one of the policy's own awards, which only the policy can write.
    if (listid and #uids > 0 and random(2) == 1) then
      local phow, pd = cfp:PolicyHistory("bid", listid, who, link)

      if (phow) then
        how, pdata = phow, pd
      end
    end

    tinsert(cfp.history, { now - random(0, 30 * 86400), link, who, how, listid, pdata })
  end

  self:RefreshHistory()
  K.printf(K.icolor, "SampleHistory: added %d entries to %s.", count or 30, cfp.name or "the config")
end
