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
local sk = konfer.policies.sk

--
-- The events Suicide Kings answers that no other policy has heard of.
--
-- RegisterPolicy has already given this policy its own copy of the standard event set, so what happens here is additions to
-- that copy. Nothing another policy answers is disturbed, and a config running EP/GP will never reach these because a message
-- arrives only at the endpoint of the policy that sent it, under that policy's own prefix, and is dispatched through that
-- policy's own tables.
--
-- Both of these are still ordinary Konfer events under the single flat konfer.protocol. Policies ship inside Konfer, so both
-- ends of a conversation update together and there is nothing here to version separately. What is the policy's is which
-- events it answers, not the wire it answers them on.
--
-- The names stay Suicide Kings' own rather than being neutralised to AWARD and UNAWD. An award means something different in
-- every policy and carries different arguments, so a shared name would be a collision waiting for the second policy that needed one.
--

--
-- Command: SULST listid uid raidlist
-- Purpose: Sent to the raid / guild when a member is suicided, for either receiving loot or being suicided by hand during a
--          raid. LISTID is the list to move them on, RAIDLIST is every user in the raid or on reserve, and UID is the one
--          being moved. RAIDLIST arrives as a single string of user IDs and is split before use.
--
sk.ehandlers.SULST = function(self, live, sender, proto, pol, cmd, cfg, ...)
  local listid, uid, raidlist = ...
  local raiders = self:SplitRaidList(raidlist)

  --
  -- A batched replay refreshes once when it finishes, so only an event that arrived live rebuilds the member lists.
  --
  local norefresh = not live

  --
  -- The sender already decided this and already chained to the extra list if there was one, sending a second event for it,
  -- so this applies the one move it was told about and sends nothing back.
  --
  cfg:AwardItem(listid, uid, nil, raiders, false, true, norefresh)
end

--
-- Command: SUNDO listid movers uid itemlink
-- Purpose: Sent to the raid / guild when the master looter puts an award back, one for each list the award moved. LISTID is
--          the list the undo happens on, MOVERS is every user the original move affected in the order they were in
--          beforehand, UID is the one who received the item (the first of MOVERS, or an alt whose main that is on a tethered
--          list), and ITEMLINK is what was won. The item going back on the loot list and the history's undo row reach us as
--          events of their own, so this puts back the list and nothing else.
--
sk.ehandlers.SUNDO = function(self, live, sender, proto, pol, cmd, cfg, ...)
  local listid, movers, uid, ilink = ...

  --
  -- MOVERS arrives in the shape this policy's Award hands a token back in, which is the only reason the platform can pass it straight through.
  --
  local movelist = self:SplitRaidList(movers)

  cfg:UndoAward(uid, ilink, { { listid = listid, token = movelist } }, true)
end

--
-- Command: SUMOV uid listid dir
-- Purpose: Sent to the raid / guild when a member is moved on a list by hand. UID is the member, LISTID is the list, and
--          DIR is 1 for down one, 2 for up one, 0 for the extreme bottom and 3 for the top.
--
--          This is Suicide Kings' own event and not the platform's, because a hand move here is a place in the array and
--          the array is the standing. Every other policy moves somebody by changing a number and would carry that number
--          instead, under a name of its own. It used to be MMLST in the standard set, which made this policy's idea of a
--          move something every policy had to answer.
--
--          Direction 0 is only sent while the list is being managed outside a raid. Inside one that is a suicide, and a
--          suicide is SULST above, the extreme bottom not being the bottom of the raid list.
--
sk.ehandlers.SUMOV = function(self, live, sender, proto, pol, cmd, cfg, ...)
  local uid, listid, dir = ...

  sk:MoveMember(cfg.id, uid, listid, tonumber(dir))
end
