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
local cfgm = konfer.configmethods
local KU = K.Users
local L = konfer.L
local KUI = konfer.KUI
local KRP = konfer.KRP
local KC = konfer.KC

local printf = K.printf
local ecolor = K.ecolor
local icolor = K.icolor

local tinsert = table.insert
local tsort = table.sort
local strfmt = string.format
local strfind = string.find
local strlen = string.len
local strlower = string.lower
local strrep = string.rep
local tostring = tostring
local pcall = pcall
local pairs, ipairs, type = pairs, ipairs, type
local error = error

local CFGUSER_KUID = konfer.CFGUSER_KUID

--
-- The loot distribution policy plugin API.
--
-- A policy is Suicide Kings, EP/GP, DKP, Loot Council or the PUG tool. They are not addons and they do not register with
-- Kore: they register here, with the Konfer addon, because Konfer is the layer that knows about distribution policy at all.
-- Kore supplies only the policy-agnostic looting mechanics that Konfer is built on.
--
-- The division of labour is the important thing, and it is not the obvious one. All of the *data* belongs to Konfer, not to
-- the policy. Config spaces, the user list and its alts, the roll lists themselves -- their roster, class and role filters,
-- rank restrictions, alt tethering and extra list -- the item editor, loot history, sync and the comms envelope are all
-- platform property. A policy owns presentation and ordering semantics: which tabs it contributes, how a list is ordered and
-- shown, how a bid or roll resolves, and what winning an item does to the standings. It gets no private database namespace
-- and no wire protocol of its own.
--
-- Put another way, Suicide Kings, EP/GP and DKP are all views over one shared model. They differ in how the guild is asked
-- to think about list order, not in what is stored.
--
-- Two consequences fall out of that and are settled for this API:
--
-- Standings are per list, never per config. In Suicide Kings a player's standing is inherently per list -- fourth on one
-- list and eleventh on another -- and making that the single storage shape keeps one code path for every policy. A guild
-- running a single shared pool simply keeps one list.
--
-- The ordered array stays canonical. A list's "users" member remains the ordered roster it is today, so for Suicide Kings
-- the array index *is* the standing and nothing about the existing sync events, checksum or export paths has to change.
-- Policies that need numbers keep them in the list's "standings" table instead, which is platform-owned storage keyed by uid:
--
--   rl.users     = { "0001", "0007", "0003" }   -- ordered; SK standing = index
--   rl.standings = { ["0001"] = { ep = 1200, gp = 450 }, ... }
--
-- Each policy declares which of the two drives its display order. The standings table is created on demand rather than by a
-- database upgrade, because a config checksum is a running XOR over its event stream and not a hash of its contents: adding
-- storage disturbs nothing, so long as every mutation is recorded as an event in the usual way.
--

--
-- A policy is chosen per config space and recorded as cfg.policy, so a guild can run Suicide Kings in one config with a PUG
-- config alongside it. Configs written before policies existed carry no cfg.policy and are treated as konfer.DEFAULT_POLICY,
-- which is Suicide Kings both because it is what every existing database contains and because it is the only policy whose
-- ordering needs no stored numbers.
--
-- konfer.policies, konfer.npolicies and konfer.DEFAULT_POLICY are declared and documented with the rest of the konfer namespace in Konfer.lua.
--
local policies = konfer.policies

--
-- The descriptor a policy passes to konfer:RegisterPolicy(). Identity fields are required and validated at registration. The
-- behaviour methods are optional, and a policy that omits one gets the platform default described against it below.
--
-- Identity
--
--   handle    Short unique string naming the policy, stored in the database and sent on the wire. May not be empty and may
--             not contain ":", which is the wire format field separator.
--
--             It is also the prefix on every frame name built for this policy: Suicide Kings owns "sk_" and every frame of
--             its own is named from it. That is why it has to be unique and why it is the handle rather than the command --
--             a command is what a user types, and is translated.
--
--             And it is the policy's name on the wire, the endpoint every message it sends begins with. It travels as a
--             value of its own under the mod's one prefix, so any length will do, and only konfer.CMD_MOD is refused.
--   name      Localised display name, shown wherever a policy is chosen. Must be unique: it is what the user sees, and two
--             of anything with the same name is a bug rather than a choice.
--   nickname  Another name for the policy, "Konfer SK" for Suicide Kings. **It is never shown.** Must be unique.
--   shortnick The policy's abbreviation, "KSK", and what err(), info() and warn() sign this player's own chat lines with.
--             What goes to the raid, the guild or another player is signed with the mod's name instead, "Konfer", which
--             policy is running meaning nothing to them. Must be unique for the same reason the name is.
--   desc      Localised description of the policy, of how it distributes and what it offers, as many lines as it takes. The
--             platform draws it at the top of the foyer's Overview whenever the policy's card is selected.
--   splashwords The words after the mod's name on the policy's splash (konfer:ShowPolicySplash), whole and localised so that
--             each language says them its own way, plural included: "for PUGs". Optional, and without them the splash says
--             L["using %s"] with the policy's name, "Loot Distribution using Suicide Kings".
--   command   Slash command that opens the window on this policy, without the leading slash: Suicide Kings takes "ksk".
--             Optional, but a policy without one can only be reached through the foyer. The five that ship with Konfer have
--             their command drawn as a plaque on the title card, CommandPlate below.
--   accent    { r, g, b }, the policy's colour in its window's header: the portrait's frame and the plaque the title sits
--             in, with that plaque's gem, against the gold every policy window shares in konfer.COLOR_UI_TINT and the sapphire of
--             every other gem. The kit multiplies by it, so it wants to be fully saturated, its brightest channel at one.
--             Optional, and a policy without one wears the kit's own gold.
--   raid      Which kinds of group this policy can be used in. All three are optional, and a policy that says nothing is
--   party     usable in a raid and a party but not a battleground. Being usable somewhere is not the same as distributing
--   bg        loot there -- a battleground has no master looter -- so a policy with something else to offer says so. PUG
--             says bg = true for its knowledge of people. See konfer:IsUsableHere. Raid and party are also the policy's
--             reach on the wire, the groups it may send to at all.
--   order     Where the policy sorts among the others by default, lowest first, with ties broken alphabetically by name. A
--             policy that ships with Konfer says what it means; one that does not has POLICY_EXTERNAL_BASE added to whatever
--             it asks for, so the ones in the box keep the order they were designed in and an addon cannot put itself at the
--             top by asking for zero. The user's own order, set in the settings window, overrides all of this -- see
--             konfer.frdb.policyorder.
--   costing   True for a policy whose awards carry a price the master looter may discount. Every win is then put to them in
--             the costing box first, the price filled in for them to type over and the list it is charged on, and whichever
--             of Full price, 25%, 50% or 75% off and Free they press is the charge (Loot.lua, THE WIN). The box is shown even
--             where the price is 0. Optional, false by default; EP/GP and DKP say true.
--   setprice  True for a policy whose master looter may give an item its price as bids open on it, holding Shift and
--             pressing Open bids, then typing it in the amount box and pressing Enter (konfer:StartBids). It is the price as
--             main spec, in place of what the policy would make it, for as long as the item is on the loot list, which the
--             policy asks for with konfer:BidPrice. Optional; DKP says true.
--   channel   Where every config of the policy talks, konfer.CHANNEL_GUILD or CHANNEL_OTHER, whatever the config holds
--             (cfg:Channel). A new config is made with it, and the Admin tab's Sync via shows it and cannot change it.
--             Optional, each config choosing its own without it; PUG says CHANNEL_OTHER, a pickup raid having no guild.
--   onelist   True for a policy whose every config runs on one list of its own, made with the config and never shown.
--             Everybody the config holds is on it, every character standing alone, and it is the config's default list, so
--             every item is given out on it. A copy is made with its own and offers none of the source's (cfg:MakeOneList,
--             cfg:JoinOneList). Such a policy hides the Lists page. Optional; PUG says true.
--
--   rollorder True for a policy whose rolls follow the config's kind order, main spec over off spec, off spec over transmog
--             and transmog over vanity, as every policy's bids do: two kinds the config has standing level are decided by the
--             roll within its hundred, an off spec 150 against a main spec 50 being a tie. The three are edited beside the
--             kinds on the Loot tab's Roll options. Without it a roll's kinds stand in the strict order. Optional; PUG, which
--             has no bids, says true.
--
-- The foyer
--
-- The foyer is the mod as a whole: every policy as a card down the left, in a scroll list, the configs that use the selected
-- one top right, and bottom right whatever the policy wants to say about the selected config. A policy supplies its card and
-- that lower right panel; everything else on that window is the platform's.
--
-- Art, for each of the three below, is a texture path, or a table of
-- { texture = path, coords = { left, right, top, bottom } } for part of one. A path is the whole of its texture. The
-- policies Konfer ships take theirs from its strips through konfer:PolicyArt, and a policy of anyone else's ships its own.
--
--   TitleCard        The card artwork, twice as wide as it is tall with its bottom eighth a band, or a function
--                    (pol, button, width, height) for a policy that would rather draw its own card into BUTTON. Without one
--                    the card is plain, with the policy's name on it.
--   Icon             The square in the top left corner of the policy's window, behind the portrait frame. Without one the corner is dark.
--   CommandPlate     The plaque on the card's band naming the command, four times as wide as it is tall. The command is
--                    baked into the picture and a picture cannot be translated, so a policy gives one only while its command
--                    is the one drawn, and a locale that changes the command goes without.
--   beta             True for a policy still in beta, whose card in the foyer wears Kore's Beta stamp over its artwork.
--                    Optional. Loot Council says true.
--   PopulateBannerInfo
--                    (cfgid) -> height. Draw what the foyer's Overview says about the config selected beside it, under the
--                    policy's desc, in place of the platform's, which is a box for each of the config's lists, its count,
--                    and the top and bottom of it with this character between. Draw on pol.foyerinfo, a frame as wide as the
--                    panel set under the description, made the first time the policy is selected, and answer how tall what
--                    was drawn is, nothing for nothing. Called again whenever the selection changes, and with nil when no
--                    config is selected. For a policy whose lists say little: PUG's one list is nobody's to see and a
--                    council decides rather than ranks, so theirs draw nothing and the description stands alone. Optional.
--
--   StartupDialog (after) -> shown. Something the policy has to ask at login, asked after the platform's own startup dialogs
--                 and one at a time with every other policy's, in the foyer's order. Answer whether a dialog was put up, and
--                 call AFTER once it has closed so that the next can come; answer false, never calling it, with nothing to
--                 ask. A policy switched off is not asked. Optional. PUG's asks an admin whether to resume or delete the raid
--                 a config still holds.
--
-- Activation
--
-- Exactly one policy is active. It is the one the window is showing and the one that arms for loot, and which policy it is
-- is the mod's decision and never a policy's. konfer:ActivatePolicy is the only thing that changes it, and it always puts
-- the outgoing policy away before it sets the incoming one up, so that the two never have their panels on screen together.
--
--   OnActivate  (onoff) this policy became the active one, or stopped being it. Optional, and a policy that does nothing but
--               contribute panels wants none of it, because the platform hides and shows those itself. It is for the state a
--               policy keeps outside its panels: a cache to drop, a timer to cancel, something to recompute on the way in.
--
--               This policy's own panels are up whenever it is called. Going out it runs before they are hidden, coming in
--               after they have been built and shown, so it may always read and write its own widgets.
--
--               Deactivation is not suspension and is not being switched off. An inactive policy stays registered on the
--               wire, still takes broadcasts and sync, and still owns its configs and its standings. It is simply not on
--               screen and does not arm for loot, so OnActivate(false) must not throw away anything a switch back needs.
--               A policy switched off in the settings window is konfer:IsPolicyDisabled, which is a different thing and
--               never comes through here.
--   ConfigSynced (cfgid, how) this policy's config CFGID has just been brought up to date by another admin: HOW is "full"
--               for a full sync, "events" for the events it was missing, and "recovered" for its owner's recovery of it.
--               Called whether or not this is the active policy, once the platform has done its own part, which redraws the
--               window only for the active policy. It is for what a policy shows or keeps of its own. Optional.
--
-- Presentation
--
-- A policy's panels are built into the one window rather than into a window of its own, and the platform shows only the
-- active policy's. Which of these hooks fire at that moment, and when a policy's panels are built at all, is konfer:BuildPolicyUI.
--
--   The window is built from the one tree in Init.lua and every policy takes part through the page hooks below, and on the
--   Lists, Raid and Config pages through tabs of its own as well (ListsTabs, RaidTabs, ConfigTabs).
--
--   PositionText  (cfgid, listid, uid, idx) -> string. What a member row shows as the player's standing. Defaults to the
--                 index, which is what Suicide Kings wants.
--
--   standingfont  The font object PositionText is drawn in, or its name, on the Lists page's members and the Loot page's
--                 candidates alike, "GameFontNormalSmall" if the policy names none. A standing wider than a position, a
--                 priority with two places, can take a smaller one to fit the column.
--
--   standingwidth How many characters the widest standing PositionText gives has, 2 if the policy names none. Those rows
--                 show a standing in brackets, never padded out, in a column wide enough for that many and the brackets,
--                 and every main's name lines up past it. See konfer:StandingColumn. 0 is a policy with no standing to
--                 show, whose PositionText answers "": the column takes no room. PUG says 0.
--
--   ValueText     (cfgid, listid, uid) -> string, or nil. What UID is worth on LISTID, in the policy's own words, put in
--                 brackets after their name in the foyer's Overview, where their place on the list is already shown before
--                 it. Optional, and a policy whose standing is its place gives none. EP/GP says "PR 1.71" and DKP "3121 DKP".
--
--   UserTooltip   (cfgid, listid, uid) -> array of { left, right }, or nil. What the policy says about UID on LISTID, which
--                 a member's tooltip on the Lists page and among the Loot page's candidates shows under a blank line after
--                 everything the platform says. A tooltip about no list, the Users page's, asks nothing. Optional. EP/GP
--                 and DKP give a member's numbers and their lifetime totals.
--
--   ItemTooltip   (cfgid, ilink) -> { title, lines = array of { left, right } }, or nil. What the active policy says about
--                 ILINK on the config it has in hand, which every item tooltip the game draws shows under a blank line,
--                 the title above the lines where there is one: another addon's loot browser's, and a raider's as much as
--                 an admin's, from whatever copy of the config they hold. Called for the active policy only, and often, so
--                 it must be cheap. Optional. EP/GP and DKP give what the item costs as each kind of bid the config takes,
--                 or at auction the least each may bid. PUG names who reserved it, its lines saying so without a title.
--
--   BroadcastArriving
--                 (cfgid) -> anything, or nil. A broadcast of CFGID is about to replace the copy this client holds. What
--                 it answers is kept and handed to BroadcastArrived. Not asked for a config this client is seeing for the
--                 first time. Optional.
--
--   BroadcastArrived
--                 (cfgid, before) the broadcast is in place, BEFORE being what BroadcastArriving answered. For telling the
--                 player what the broadcast changed for them, which is what EP/GP and DKP do with their numbers on each
--                 list. Optional.
--
--                 WHAT A POLICY SAYS ABOUT SOMEBODY ON A LIST
--
--                 Who is on a list is the platform's and what they are worth on it is the policy's, so the five hooks below
--                 are how the second half travels. The platform carries a block it never looks inside, PDATA here, and
--                 hands it back on the other side. For Suicide Kings that block is one number, the position; for EP/GP it
--                 is the two numbers; for anything later it is whatever that policy decides, and nothing on the platform
--                 side changes to allow it.
--
--                 That is why IMLST and SMLST stay one event apiece rather than one per policy. Adding somebody to a list
--                 is the same act everywhere and only the standing they arrive with differs, so the common half is written
--                 once and the policy is asked for the rest.
--
--   MemberInfo    (cfgid, listid, uid) -> pdata. What this policy says about UID on that list, packed however it likes, to
--                 travel in IMLST. Nil for a policy with nothing to say. Optional.
--   SetMemberInfo (cfgid, listid, uid, pdata) -> pdata. Take it: put UID on the list where PDATA says and record whatever
--                 is kept beside it. **The policy does the placing**, this being the one decision the array's order is.
--                 Answer with what was actually done, which is what the event then carries, so two clients place somebody
--                 alike rather than each resolving the same request for itself. A policy that implements neither this nor
--                 nothing at all gets the platform's answer, which is the bottom of the list. Optional.
--   MemberRemoved (cfgid, listid, uid) they are off that list, so forget whatever was kept about them on it. The platform
--                 clears rl.standings itself; this is for anything else the policy keeps. Optional.
--   InsertUI      The row the Lists page's insert popup reserves for the policy, where it puts whatever says how the next
--                 insert should land. Who may be inserted is the same question in every policy and stays with the
--                 platform. A table of:
--
--                   Construct  (parent, owner, where) builds into PARENT, one standard row tall. OWNER is the insert
--                              popup when the row is on that, for a control that has to hold off its timeout while it is
--                              being used, and nil in a dialog, which stays open until it is answered.
--                              WHERE names the place, "insert" for the popup, and whatever the policy passes when it puts
--                              the same row in dialogs of its own, so that it can keep its answer apart per place.
--
--                 Suicide Kings puts Insert randomly there, and in its own import and add missing dialogs, with a default
--                 per place: importing a whole guild rank wants shuffling and putting one more person on an established
--                 list does not.
--
--                 Built per policy and swapped as the active one changes, the popup being built once and outliving any
--                 policy. A policy with none gets an empty row, so the popup is the same height whichever is up.
--   InsertInfo    (cfgid, listid, where) -> pdata for the next insert, read from those controls when somebody is picked
--                 rather than when a control is touched, the popup staying open so a whole raid goes in at once. Optional.
--   ImportList    (cfgid, listid) puts up the policy's own dialog for importing members into LISTID of CFGID, what an
--                 import means and where the people land being the policy's. The platform keeps only what is the same
--                 in every policy: konfer:ParseNames reads names typed in, commas or a JSON array,
--                 konfer:IsExportText tells another addon's JSON export from names, konfer:ParseListExport reads a list
--                 export of this mod's or the old Konfer Suicide Kings', cfg:FindImported finds the user a name from
--                 outside means, bare or with a realm, cfg:ImportNames turns names into the config's uids,
--                 cfg:ImportMembers an export's names and classes into users and cfg:ImportGuildRank a guild rank, each
--                 taking each person once and an alt for their main on a tethered list (cfg:ImportCandidate), and
--                 konfer:CurrentListBox and konfer:ShowCurrentList say which list a dialog is about as every list dialog
--                 does. A policy without one has the Lists page's Import button disabled. Optional.
--   AddMissing    (cfgid, listid) the same for putting onto LISTID those who could be on it and are not, whom
--                 cfg:MissingFromList(listid, raidonly) names. Its button is disabled without one, and out of a group
--                 whatever the policy. Optional.
--   ListInfo      (cfgid, listid) -> pdata. The same for the whole list at once, for SMLST and for a config travelling in
--                 a broadcast, a full sync or a recovery, where the lists are replaced wholesale and no event describes
--                 it. Without this a list arrives as a column of names with every number on it thrown away. Optional.
--   SetListInfo   (cfgid, listid, pdata) take a whole list's worth. Called by SMLST and, for a config arriving whole, by
--                 konfer:Config(cfgid):AdoptListInfo once the config is in place. Optional.
--   Strings       Table of vocabulary overrides keyed by the names listed against policy_words below, so a policy can call
--                 an award a suicide, a charge or a deduction in its own UI. Values are already localised. A policy names
--                 only the words it wants to change and pol:Str() falls back to the platform's neutral wording for the rest.
--   ListsPage     A panel of the policy's own on the Lists page, under Announce, for whatever the policy does to a list or
--                 to a member of one. Suicide Kings puts its moves there. A policy without one gets no panel. A table of:
--
--                   title            What the panel is titled.
--                   height           How tall the panel's usable area is, which the policy sizes to what it builds there.
--                                    Required: only the policy knows.
--                   Construct        (client) builds the panel into CLIENT, which is HEIGHT tall and the column wide. Called
--                                    once, after everything else on the page has been built, so that anything the policy
--                                    wants to reach from CLIENT already exists.
--                   ListSelection    (client, cfgid, listid) the selected list changed. LISTID is nil when there is none,
--                                    and CFGID when the policy has no config. Optional.
--                   MemberSelection  (client, cfgid, listid, uid, pos) the selected member changed. UID is nil when there is
--                                    none. POS is their place in the list, and on a tethered list UID and POS are the
--                                    main's. Optional.
--
--                 A change of list calls ListSelection before MemberSelection.
--
--                 The Config tab of the same page has room for the policy too, under List Configuration, titled with the
--                 policy's name and taking whatever the window grows by. It is for the options on a list that only this
--                 policy cares about.
--
--                   ConfigConstruct      (client) -> height. Builds the policy's list options, those it declares in
--                                        listoptions, into CLIENT, on the Config tab of the same page, and answers how tall
--                                        they are, from the top of CLIENT to the bottom of the lowest, which the panel is
--                                        made to hold exactly. Nothing is written when one is changed. The tab holds every
--                                        change until its save bar is pressed, and konfer:ListsPending() is where it holds
--                                        them: an option calls Set("p." .. option, value) on it when the user changes it,
--                                        Watch(widget, "p." .. option) once so the widget shows the changed colour, and
--                                        reads Value("p." .. option) to show it. Saving sends the policy's whole block of
--                                        options on the list in the tab's one CHLST. Called once, along with Construct.
--
--                                        The panel is there and is titled with the policy's name whether or not the policy
--                                        builds anything in it, because it is where that policy's list options live and
--                                        saying so is worth a line even while there are none. Answering nothing, or having
--                                        no ConfigConstruct at all, leaves it at its minimum height rather than at none,
--                                        a panel of no height being a title plate hanging in mid air.
--                   ConfigListSelection  (client, cfgid, listid) the selected list changed, or the lists were refreshed.
--                                        LISTID is nil when no list is selected. The policy sets its widgets from
--                                        ListsPending's Value, so that an unsaved change still shows, without throwing when
--                                        there is no list. Also the place to refill any choice that depends on the lists.
--
--   ListsTabs     Tabs of the policy's own on the Lists page, after Members and Config, there while it is the active
--                 policy and gone when it is not, as ConfigTabs are on the Config page. Each is about the list selected in
--                 the column beside it. Nothing on one is held for saving, so it has no save bar and runs down into the
--                 bar's room. An array, in the order they stand, each a table of:
--
--                   name           Unique among this policy's tabs, and named with the policy's prefix in front of it.
--                   text           What the tab says.
--                   adminonly      As a tab in Init.lua's tree takes them: shown only to the config's admins, or its owner.
--                   owneronly
--                   wholepage      The tab covers the whole page, the column of lists hidden while it is up, rather than
--                                  the side beside that column. Such a tab chooses its list for itself, starting from the
--                                  one ListSelection hands it (KoreUI's tab.wholepage).
--                   Construct      (client) builds the tab into CLIENT, its content frame, once, when the policy's panels
--                                  are built.
--                   ListSelection  (client, cfgid, listid) the selected list changed, or the lists were refreshed. LISTID
--                                  is nil when no list is selected. Called with the ListsPage hook of the same name, after
--                                  it. Optional.
--
--                 EP/GP's journal is one.
--
--   RaidPage      What the policy shows and does on the Raid page (Raid.lua), everybody in the group, between Lists and Loot.
--                 Each raider's row up to the end of the name is the platform's, and what follows it is the policy's. The
--                 hooks are only called with a config in hand. A table of:
--
--                   solo       True to keep the page up out of a group as well, where it is otherwise gone, for a policy
--                              whose tabs there are of use before the group forms. PUG's, for Reserves. Optional.
--                   title      (cfgid) -> what the page's plaque says, the platform's "Raid manager" where it answers nil.
--                              PUG's names the kind of raid. Optional.
--                   columns    Every column the policy may ever show after the name, declared at registration because the
--                              page's one list is built once with every policy's: an array in the order they stand, each a
--                              table of key (unique among the policy's columns), text (its heading), widest (the widest
--                              anything in its cells will be, which it is made room for, as narrow as its heading if none),
--                              format (a string.format pattern a value is shown through, as tostring would if none) and
--                              align. Each sorts by its value, a raider with none below everybody, and then by name.
--                              Optional, and a policy without any shows the platform's part of each row alone.
--                   Columns    (cfgid) -> shown, sortkey, upward. Which of COLUMNS show, as a set of keys, the one the list
--                              starts sorted on, nil for by name, and whether it runs upward. Asked whenever the page is
--                              drawn, and the list starts again sorted that way only when what it answers changes or the
--                              column sorted on goes, so that whatever the player sorted it by otherwise stands.
--                   Row        (cfgid, raider) -> { key = value }, a number in each of the columns for RAIDER, a key left
--                              out leaving the cell empty. RAIDER is the platform's row and is not to be changed: name,
--                              kuid, and uid, nil for somebody the config does not hold.
--                   buttons    The policy's own buttons on the page's second row, in the order they stand, the platform's
--                              Remove among them where the string "remove" is and last where it is not. Each a table of
--                              name, text and tip, Enabled (cfgid, raider, admin) -> whether it is lit for RAIDER, the
--                              raider picked or nil, ADMIN being whether this character is one of the config's, and Click
--                              (cfgid, raider). Each is built once and kept as pol.raidbuttons[name]. PUG's Penalty, Reward
--                              and End raid. Optional.
--                   Removed    (cfgid, uid) the raider UID, whom the config holds, was taken out of the group with Remove.
--                              PUG forgets what tonight counted against them. Optional.
--
--                 Its words on Broadcast's tooltip and in Remove's question are the policy's to change (Strings). EP/GP shows
--                 EP, GP and PR and DKP the balance, on the list being worked on, and PUG what tonight has cost each raider.
--
--   RaidTabs      Tabs of the policy's own on the Raid page, after Raiders, there while it is the active policy and gone
--                 when it is not, as ListsTabs are on the Lists page. Nothing on one is held for saving. An array, in the
--                 order they stand, each a table of name (named with the policy's prefix in front of it), text, hsplit,
--                 adminonly and owneronly as a tab in Init.lua's tree takes them, Construct (client), which builds the tab
--                 into CLIENT, its content frame, once, and Refresh (client), called whenever the page is drawn. PUG's
--                 Reserves.
--
--   AssignPage    What the policy changes about the Loot page's Assign loot tab. A table of:
--
--                   hide           What on the tab the policy has no use for, as a set. "rank" is Constraints' guild rank
--                                  filter and its - button, the strict filters under it moving up into its room. "lists"
--                                  is the Lists panel and "forcebid" the panel of Force bid and Force retract under
--                                  Candidates, which takes whatever room they leave, and the Force bids a right click on a
--                                  candidate offers. "bids" is bidding itself, for a policy that only ever rolls: Open bids
--                                  stays dark and nobody has Bid on item or Retract bid. PUG hides all four. Optional.
--                   firstroll      { text, tooltip }, for a policy that hides bids: the bids button under that name
--                                  opens the item's first roll while one is owed (FirstRoll), and is dark otherwise.
--                                  PUG's is Reserves. Optional. Three functions may go with them:
--
--                                    Label  (cfgid, ilink) -> text, tooltip, what the button is called for the item
--                                           selected, nil for either leaving the one above. Asked whenever the button is
--                                           put right with nothing open, so it must be cheap.
--                                    Open   (cfgid, ilink) -> opened. Pressing the button asks this first, and an answer
--                                           of true is the policy having opened something of its own in place of the
--                                           roll, which is then not opened. Loot Council's council vote.
--                                    Offers (cfgid, ilink) -> boolean, whether the button is lit for the item selected
--                                           though no first roll is owed, Open roll lit beside it. Pressed, it opens
--                                           only what Open does. Asked as Label is, so it must be cheap. Loot Council's
--                                           while the council could vote on the item.
--
--   ItemsPage     A panel of the policy's own on the Loot page's item editor, in the left column under the Delete button,
--                 titled with the policy's name. It is for what only this policy does with an item; who an item goes to,
--                 next drop and award list included, is Item instructions', the platform's. A policy without a Construct
--                 has no panel there at all. A table of:
--
--                   hide           The rows of Item instructions the policy has no use for, as a set of the item fields
--                                  they set: "rank" the initial guild rank filter, "list" the list rolled on, "nextuser"
--                                  who the next drop goes to, "autodel" removing it once assigned, "awardlist" the list
--                                  the award is made on. Those under a hidden row move up into its room. PUG hides rank,
--                                  list and awardlist. Optional.
--                   Construct      (client, changed) -> height. Builds the policy's options into CLIENT and answers how tall
--                                  they are, from the top of CLIENT to the foot of the lowest, which the panel is made to hold
--                                  exactly, the Items list above it taking the rest of the column. Their values are edited in the
--                                  item's edit buffer, as the platform's own are, and CHANGED is what a widget calls when
--                                  the user has written an edit into it, which puts it among the editor's unsaved changes.
--                                  A widget is watched with konfer:ItemsPending():Watch(widget, field, ...), so that it shows
--                                  the changed colour while any of its fields is unsaved. Called once, last of everything
--                                  on the page.
--                   ItemSelection  (client, cfgid, itemid, iinfo) called whenever the selected item changes, or anything in
--                                  its buffer that the policy's options may depend on: Ignore item and the two auto-assign
--                                  options, which reset everything the policy shows, and the lists being refreshed. IINFO is
--                                  the item's edit buffer, or nil with no item selected, holding what is on screen, unsaved
--                                  changes included. The policy sets and enables its widgets from it alone, without
--                                  throwing, writes edits into it, and saving the editor writes the item's fixed set of
--                                  fields from it. One of them, IINFO.pdata, is the policy's own: any value it likes, or
--                                  nil for none, stored on the item as it stands, sent to the other admins with it and never
--                                  read by the platform. EP/GP keeps an item's custom GP there.
--
--   UsersPage     What the policy adds to its own Users page. A table of:
--
--                   title            What the policy's section is titled. Defaults to the policy's name.
--                   compact          True to give the section the room the page can spare: the page's buttons go under the
--                                    user list, two rows of two without Guild import, and User info has no separator
--                                    between the config's view of a user and the character's. PUG's, for its notes.
--                   Construct        (client, changed, width) -> height. Builds the policy's own section into CLIENT, a
--                                    panel under the page's buttons, or under User info and the lists on a compact page,
--                                    the column wide, WIDTH inside the panel's rings, and answers how tall what it built
--                                    is, from the top of CLIENT to the bottom of the lowest, which the panel is made to
--                                    hold exactly.
--                                    Answering nothing, the section runs down to the foot of the page, for one holding
--                                    something that takes whatever room there is. Called once, after everything else on the
--                                    page has been built. Optional, and a policy without one has no panel there at all. The
--                                    panel's title dims while no user is selected, as the page's own do.
--
--                                    What the policy keeps about a user is PDATA, one value of any kind it likes that the
--                                    config's entry for them holds, the platform storing it and sending it with the entry
--                                    and never looking inside (cfg:UserPData). The section edits it among the page's unsaved
--                                    changes: CHANGED(pdata) says what it now is, the page's save bar writes it with the rest,
--                                    and a widget is watched with konfer:UsersPending():Watch(widget, "pdata").
--                   UserSelection    (client, cfgid, uid, pdata) the selected user changed, or the section has just come up.
--                                    UID is nil when there is none. PDATA is what is kept about them as it stands on
--                                    screen, unsaved changes included, a copy the policy may change as it likes. Optional.
--                   CreateConstruct  (dlg, ypos) -> ypos. Adds the policy's own fields to the create user dialog, under the
--                                    standard ones and the platform's raid enchanter box, at DLG.x from YPOS down, and
--                                    answers where the next would go. Each resets itself when the dialog opens, by catching
--                                    the dialog's OnShow, and puts what it holds in DLG.entry.pdata, which the new user's
--                                    entry keeps as their PDATA. Optional.
--
--   Whispers      what this policy calls each of the whisper commands a raider can send, keyed by the platform's name for
--                 it and holding the words it answers to, first the one the help text tells people to use. Anything left
--                 out keeps the platform's word. The kinds of bid, "bidM" to "bidV", are whispers too, "!ms" and "!os",
--                 but a kind is the platform's and so are its words: a policy leaves those alone.
--
--                 What each command does is the platform's and is not overridable here: every policy has bidding, has
--                 somewhere a person stands, and has people who are available but not in the group. All that differs is
--                 what they are called, and a policy that says nothing answers to the platform's words. Suicide Kings
--                 declares only "standing", which it answers to as "suicide" and "position".
--
--                 A policy that wants one done differently replaces its handler in pol.whispers after registration, the
--                 same way it would replace one of the comms handlers it is given. PUG replaces standing, a roll having no
--                 standing, with what tonight's wins have cost the asker, and says so in its HELP_STANDING.
--
--                 A key that is none of the platform's is a whisper of the policy's own, answered to by the words given and
--                 by the handler the policy puts in pol.whispers under that key after registration, which is handed what
--                 the platform's are. PUG's "reserves" is one, "!sr" telling a raider what they reserved. Optional.
--
--   Commands      Words of the policy's own after its slash command, beside the platform's that every policy has. An
--                 array, each a table of:
--
--                   word   What is typed after the command, localised.
--                   args   What the help shows after the word, if it takes anything. Optional.
--                   help   The help's line for it, localised.
--                   Run    (input, pol) does it, INPUT being whatever was typed after the word. Only ever run with a
--                          config in hand, the policy being the active one.
--
--                 A word the platform already answers stays the platform's. EP/GP's "journal" opens its Journal tab.
--
--                 Optional.
--
--   defaults      the policy's own settings and the value each starts at, its private twin of konfer.defaults. A config
--                 keeps a block per policy in cfg.psettings, made from this the first time it is asked for, and the policy
--                 reads and writes it with pol:Setting(which, cfgid) and pol:ChangeSetting(which, val, cfgid). The block is
--                 the owner's and travels with the config, in the p field of a broadcast. A change reaches the config's
--                 other admins as PSSET, which carries the whole block, and anything in one that is not declared here, or
--                 is not of the kind declared here, is dropped on arrival while the rest is still taken.
--
--                 Nothing about it is the platform's business: a policy may name a setting whatever it likes without
--                 checking what the platform already calls something, which is why the two tables are apart. Optional, and
--                 a policy without one has no settings of its own.
--
--   configdefaults  the platform's settings a new config of this policy starts at, by name, where the policy wants them
--                 other than konfer.defaults has them. Only a config made here takes them: one arriving from another admin,
--                 or copied, brings its own. A name that is not one of the platform's settings is refused at registration.
--                 PUG's start with every kind of roll taken. Optional.
--
--   listoptions   the policy's own options on a roll list and the value each starts at, the same thing one level down. A
--                 list keeps a block per policy in rl.poptions, made from this the first time it is asked for, and the policy
--                 reads one with pol:ListOption(cfgid, listid, name). They are edited on the Lists page's Config tab (see
--                 ListsPage.ConfigConstruct) and travel with the list's own options: in CHLST, in the list's row when a config
--                 travels whole, and in a config copy. What arrives is checked against what is declared here, as a setting
--                 is. Optional, and a policy without one has no options of its own on a list.
--
--   configdata    the policy's own data on a config and what each entry starts as: what it keeps there that is not a
--                 setting, a collection edited an entry at a time. A config keeps a block per policy in cfg.pdata, made from
--                 this the first time it is asked for, and the policy reads it with cfg:PolicyData(handle). It travels
--                 whole only when the config does, in a broadcast, a full sync, a recovery and a config copy, checked
--                 against what is declared here on arrival. Between admins it changes only by the policy's own events, each
--                 through AddEvent, so a change is the entry changed and never the whole block: nothing of the platform's,
--                 PSSET included, sends it. EP/GP's and DKP's awards are one. Optional.
--
--                 Some of these are edited on platform pages rather than in the policy's own panel, because the question is
--                 one every policy has to answer even though the answer is the policy's. The Config page's Loot tab sets
--                 Suicide Kings' bid_threshold and try_roll that way.
--
--   ConfigTabs    Tabs of the policy's own on the Config page, after the platform's, there while it is the active policy and
--                 gone when it is not. An array, in the order they stand, each a table of:
--
--                   name       Unique among this policy's tabs. The tab is named with the policy's prefix in front of it.
--                   text       What the tab says.
--                   adminonly  As a tab in Init.lua's tree takes them: shown only to the config's admins, or its owner.
--                   owneronly
--                   Construct  (client, pending) builds the tab into CLIENT, its content frame, once, when the policy's
--                              panels are built. PENDING is the tab's unsaved changes, the same object
--                              konfer:PolicyTabPending(pol, name) answers.
--                   Refresh    (client, cfgid) puts CFGID's values back, from the tab's unsaved changes so that an unsaved
--                              change still shows. CFGID is the config picked in the Admin tab's list, or nil with none
--                              picked, when the tab disables what it holds. Called whenever that pick changes. Optional.
--
--                 What a tab edits is the policy's own settings, for the config picked in the Admin tab's list as that
--                 tab's own options are, held in konfer:PolicyTabPending(pol, name) as "p." and the setting's name until
--                 the tab's save bar is pressed, and going out as one PSSET. EP/GP's Advanced tab holds the price of gear.
--
--   Pages         Pages of the policy's own, there while it is the active policy and gone when it is not. An array, each a
--                 table of name (unique among this policy's pages, the page named with the policy's prefix in front of it),
--                 text (what its button says), title (what its plaque says, text if none), order (where its button stands
--                 among the platform's, whose orders run from 1 for Lists to 7 for Options, after them all and in the
--                 array's order if none), adminonly and owneronly as a page in Init.lua's tree takes them, Construct
--                 (client, topbar), which builds the page into CLIENT, its content frame, and whatever it says along the top
--                 into TOPBAR, the page's own top bar, once, when the policy's panels are built, and Refresh (client), which
--                 redraws it, called while the policy is the active one whenever who is in the group, the config's people or
--                 the config itself may have changed. Refresh is optional.
--
--                 A page that is not always there has Shown () -> whether it is now, asked whenever the window's pages are.
--                 When what it answers changes, the policy calls konfer:PolicyPagesChanged(pol, raise), naming the page as
--                 RAISE to have the window raised on it. Loot Council's Vote page is there while a vote is open.
--
--                 A page may have tabs, as tabs, an array in the order they stand, the page opening on the first, each a
--                 table of name (unique on its page), text, hsplit, adminonly and owneronly as a tab in Init.lua's tree takes
--                 them, Construct (client), which builds the tab into CLIENT, its content frame, once, and Refresh (client),
--                 called with the page's. Their strip runs along the page's top bar from the left, so a page with tabs puts
--                 anything of its own there at the right, and its Construct, optional then, builds nothing but that.
--
--                 Optional.
--
--   hidepages     The platform's pages the policy has no use for, a set of page names: hidden while it is the active policy,
--                 whoever is looking, and back when it is not. PUG takes no bids, so it hides lists. Optional.
--
--   CreateConfigUI (parent) -> height. Builds the policy's own options into PARENT, the panel titled with the policy's name
--                 on the Config page's Admin tab, and answers how tall they are, from the top of PARENT to the bottom of the
--                 lowest, which the panel is made to hold exactly. The platform never looks inside it again. Answering nil
--                 leaves the panel as tall as the column of panels beside it. Optional, and a policy without one gets that
--                 empty panel.
--                 Nothing on the tab is written when it is changed. The tab holds every change until its save bar is pressed,
--                 and konfer:AdminPending() is where it holds them: an option calls Set("p." .. setting, value) on it when the
--                 user changes it, Watch(widget, "p." .. setting) once so the widget shows the changed colour, and reads
--                 Value("p." .. setting) to show it. Saving sends the tab's policy settings as one PSSET.
--   RefreshConfigUI (cfgid) puts CFGID's values back into those options, from AdminPending's Value so that an unsaved change
--                 still shows. CFGID is the config the Admin tab has selected, which is not necessarily the one the window
--                 has in hand. Called when the selection changes and when the roll lists do. Optional.
--   EnableConfigUI (onoff, cfgid) the Admin tab gained or lost a selected configuration, CFGID or nil. The panel dims only its
--                 title, so the policy enables or disables its own options here. Optional.
--   ConfigLootPage  What the policy changes about the Config page's Loot tab. A table of:
--
--                   hide           What on the tab the policy has no use for, as a set. "bids" is everything about bidding:
--                                  Bid options, after which Roll options says what becomes of an item nobody rolls for, the
--                                  heading and the enchanters to assign it to, which Bid options says for everybody else,
--                                  and Enable silent bidding in General options. PUG hides it. Any announcement on the
--                                  Announcements menu may be named by its setting as well, "ann_winners_guild" for
--                                  Winners in guild chat, and it is then off the menu and never made, whatever the config
--                                  says (cfg:Announces). PUG hides that one and "ann_missing". "announce_guild" is In
--                                  guild chat under Announce loot, loot the config says to announce there then being
--                                  announced nowhere (konfer:LootAnnouncedTo). PUG hides it. Optional.
--
--   AdminPage    What the policy changes about the Config page's Admin tab. A table of:
--
--                   hide           The platform's panels on the tab the policy has no use for, as a set. "options" is
--                                  Options, the default list, guild rank filtering and rank order, and without it the
--                                  policy's own panel starts at the top of the right hand column. PUG hides it. Optional.
--
--   AdminPanel    A second panel of the policy's own on the Admin tab, under the one CreateConfigUI fills and running down
--                 to the foot of Co-admins, for more than a few options will hold: EP/GP's and DKP's awards. There only under
--                 a first panel that answered its height. A table of:
--
--                   title      What the panel is titled. Defaults to the policy's name.
--                   Construct  (client) builds the panel into CLIENT, once, straight after CreateConfigUI.
--
--                 Whether what it edits waits for the tab's save bar, held in konfer:AdminPending() as the first panel's
--                 options are, or is saved as it is made, is the policy's: EP/GP's and DKP's awards are saved as they are
--                 made. RefreshConfigUI and EnableConfigUI are its as much as the first's. Optional.
--
--   GuildRanksChanged
--                 (ranks) the guild's ranks changed, or this character's guild did. RANKS is the choice of them the platform
--                 offers in its own rank dropdowns, None first, and this is for a policy that offers the same choice
--                 somewhere of its own. The policy refills and enables its own widgets; the platform never touches them. Optional.
--   MasterLooterChanged
--                 (isml) this character became master looter, ISML true, or stopped being it, false: the loot method or the
--                 master looter changed, or a group joined or left changed it, a raid made up by /konfer testraid included.
--                 For whatever a policy keeps that is the master looter's to run, EP/GP's timed EP among them. Called for
--                 every registered policy, active or not. Optional.
--   EncounterEnded
--                 (enc) a boss fight ended, won or lost, as KoreLoot's encounter_ended hands it on: ENC is { id, name,
--                 difficulty, size, killed, when }, the game's encounter id, the fight's name, its difficulty id, the size
--                 of the group, whether the boss died and when, in UTC seconds. Every client in the fight hears it, so a
--                 policy that acts on one checks who it is for itself. EP/GP and DKP offer the master looter the boss's award
--                 on a kill. Called for the active policy only. Optional.
--   StatusChanged
--                 (name, status, onoff) NAME, somebody in the group, gained one of the marks the raid frames show, ONOFF
--                 true, or lost it, false, as KoreParty's status_changed hands it on: STATUS is one of KRP's STATUS_
--                 constants. Joining a group gains everybody's. PUG warns of a main tank its player rated a terrible tank.
--                 Called for the active policy only. Optional.
--
-- Ordering and resolution
--
--   Order         (cfgid, listid, uids, loot) -> array of uid. Given the list members, return them in display and priority
--                 order. Defaults to the order given, which is the stored array order.
--                 cfg:ListPosition walks it, so it is what every position the platform shows or announces is counted in.
--                 LOOT is true when the order is for the Loot page's candidates, who are being chosen between for an item
--                 and may be ordered differently from the list itself: EP/GP breaks a tie on PR by EP there alone.
--   BidAmounts    (cfgid) -> boolean. Whether a bid in CFGID names an amount as well as a kind, "!ms 150" rather than "!ms".
--                 The raid is told as bids open, which puts a box to type it in beside Bid on item, and a bid without one
--                 is refused. Where it is false an amount whispered after the word is ignored. A policy without it bids a
--                 kind alone. DKP says yes for a config that auctions its items.
--   PriceText     (cfgid, ilink) -> text. A few characters put before ILINK on the Loot page's loot list and where bids
--                 open on it are announced, "125" or "75+". Only the master looter asks, and raiders are sent its answer
--                 with the loot and again as bids open. A policy without it, or nil, puts nothing there. DKP gives the
--                 price as main spec, or at auction the least that may be bid.
--   RankBidders   (cfgid, listid, bidders, ilink) -> array of bidders, winner first. BIDDERS arrive by .tier, the place the
--                 config's Bid options give their kind of bid (lower is better, and kinds on one tier stand level), within a
--                 tier highest .amount first where bids take one, and then in Order's order, each a table with .uid, .kind
--                 (its code), .tier, .amount (what they bid, nil where bids name none), .idx (their position) and .standing
--                 (PositionText's), and are what the default returns. A policy ranking by numbers of its own keeps .tier
--                 first, the config having said which kind outranks which.
--                 Return the same tables, reordered or thinned. Only the master looter calls it, afresh on every bid and
--                 retraction and whenever the list moves, and the first bidder wins. The raid is sent the result whole.
--
--                 Bidders the policy cannot tell apart are given the same .tie, any value. When bids close with the first
--                 two sharing one, nobody has won yet: every bidder with that .tie rolls off, main spec, and the winner has
--                 the bid they made, of the kind they made it (Award and HistoryEntry see VIA "bid").
--   MayBid        (cfgid, listid, uid, kind, amount, ilink) -> allowed, why. Whether UID may bid KIND on LISTID for ILINK
--                 at all, for AMOUNT where bids name one, WHY being the reason whispered back when not. Asked after the
--                 platform's own checks, and again when a bid is changed. A policy without it takes every bid those let
--                 through. EP/GP refuses somebody below its minimum EP when the config says so, and DKP a bid for more than
--                 the bidder has.
--   RollAwards    (cfgid, listid, ilink) -> boolean. Whether an open roll on ILINK, on LISTID, carries an award for its winner
--                 as a bid would, which is then the policy's (HistoryEntry with VIA "roll", and AWARD_ROLL to announce it).
--                 The master looter holding Shift when opening the roll asks for the other. A policy without it opens a roll
--                 that awards nothing, the winner simply getting the item.
--   RollCeiling   (cfgid, uid, kind) -> top. In a roll that carries an award, the most UID may roll of KIND (its code), out of
--                 its hundred: 90 has them roll 1-90 for main spec and 101-190 for off spec. A roll over the whole hundred
--                 from somebody whose range is shorter is refused and they are whispered theirs, their own roll buttons
--                 roll it, a tie is rolled off over each raider's range of the kind they tied in, and a roll moved to
--                 another kind keeps its place in its range. Nil or 100 is the whole hundred. PUG's decay answers it.
--   RollPriority  (cfgid, uid, kind, ilink, awards) -> number. Where UID stands among the rollers of their kind's tier in
--                 the roll open on ILINK, ahead of what they rolled, lower standing better: the roll decides only between
--                 rollers standing level, and only they can tie. AWARDS says whether the roll carries an award. Nil is 0
--                 for everybody. PUG answers it with its soft reserves in any roll, reservers first, and in a roll that
--                 carries an award with its +1s, fewest first.
--
--                 A roll that carries no award, a Shift-opened one where the policy would award, is a plain roll that
--                 RollCeiling is not asked about.
--   MayRoll       (cfgid, uid, kind, ilink) -> allowed, why. Whether UID may roll on ILINK at all, asked when their first
--                 roll in it arrives, after the platform's own checks, WHY being the reason whispered back when not, and
--                 of every candidate with KIND nil, the Candidates being only those it allows and who meet the item's
--                 Constraints. A policy without it takes every roll those let through. PUG keeps everybody but its
--                 reservers out of an item's first roll.
--   FirstRoll     (cfgid, ilink) -> boolean. Whether ILINK is owed a roll among a few before anybody else, those MayRoll
--                 lets in. While it is, the bids button opens it under AssignPage.firstroll's name and Open roll is dark.
--                 Only a policy that takes no bids has one. Optional. PUG's are its soft reserves, where they keep others
--                 out, and Loot Council's its roll-offs and the item its council is voting on.
--   FirstRollUnanswered
--                 (cfgid, ilink) nobody rolled in ILINK's first roll, which is back on offer, never going where an item
--                 nobody rolls for goes. Told on every client, the master looter as the roll ends and everybody else by
--                 EROLL, so that the Candidates follow. PUG lets everybody in. Optional.
--   RollNotice    (cfgid, ilink) -> text, or nil. Said to the raid when a roll opens on ILINK, after the line opening it,
--                 for whatever the policy has to say about who may roll. Optional. PUG names the item's reservers.
--   ItemClaim     (cfgid, ilink) -> claimed, uid, award. Whether ILINK is spoken for, never to be rolled or bid on, and
--                 who for, UID being somebody the config holds. Selected by the master looter, a claimed item naming
--                 somebody who can have it is put to them as an item's own instructions are, the claim winning it for them
--                 where they say yes, and otherwise Open roll and Open bids stay dark, the item being theirs to hand out
--                 however they see fit. AWARD says the win is an award on the list the item is given out on, made and
--                 written by the policy (Award and HistoryEntry with VIA "assign"), and without it the win is the platform's
--                 A row. Asked before the item's own instructions. Optional. PUG's hard reserves answer it, each claiming
--                 its item while whoever it is for is in the group, and Loot Council's decisions, with an award.
--
--                 A policy whose claim has just been decided offers the item again with konfer:OfferLoot, which asks this
--                 as picking the item does.
--
-- Award
--
-- A win is somebody winning a bid or a roll, or an item's own instructions naming somebody and the master looter going
-- through with them, which is the same thing. It is decided once (Loot.lua, THE WIN): the award, its history row and the
-- raid's announcement. A policy with costing (see the descriptor) puts it to the master looter in the costing box first,
-- and the award is made at the price they choose there. Nobody winning an item is no award at all.
--
--   Cost          (cfgid, listid, uid, ilink, kind, bids) -> number. What UID winning ILINK on LISTID costs, which the
--                 costing box fills in beside the policy's COST word, for the master looter to type over and discount.
--                 Whichever button they press reaches Award and HistoryEntry as COST. BIDS, for an item won by bidding, is
--                 every bid as it stood when bids closed, ranked winner first, each { uid, kind, tier, amount }, which is
--                 what a price that comes from the bidding is worked out from; nil for a roll or an item's own instructions.
--                 EP/GP answers its price in GP, and DKP its price or what the auction came to. Only a policy with costing is
--                 asked, and nil is a price of 0.
--   Award         (cfgid, listid, uid, ilink, rlist, chain, nocmd, norefresh, kind, cost) -> undo token. Apply winning ILINK to
--                 the standing of UID. RLIST is the raid-present subset of the list, in list order, because Suicide Kings
--                 moves a winner only past players who were actually eligible. CHAIN says the award also applies to whatever
--                 extra list the primary names, which a loot award does and a hand correction of the list does not. NOCMD and
--                 NOREFRESH are the platform's own convention for a mutator: an award another admin already decided and sent
--                 us records no event, and a caller replaying a batch of them refreshes once at the end rather than per award.
--                 KIND is the kind of bid or roll that won it, as its code, for a policy whose award depends on it (EP/GP
--                 charging less for an off spec win); nil where there was none, a hand correction or the item's own orders.
--                 COST is what the master looter charged in the costing box, and nil where the policy's own price stands, a
--                 hand correction or a policy with no costing.
--
--                 Returns one entry per list it actually moved, each a table of { listid, token }. The token is opaque to
--                 the platform, which puts the whole award on the undo stack as one record and, when it is undone, hands
--                 each token back to UndoAward with the list it came from, newest first. An empty array means nothing happened.
--   UndoAward     (cfgid, listid, uid, ilink, token, nocmd) reverses the award on one list. Putting the item back on the loot
--                 list and recording the reversal in the history are the platform's, done once per award where the undo is made.
--
-- Neither is called directly. cfg:AwardItem and cfg:UndoAward are the platform's side of this pair and are what the loot engine uses.
--
-- Loot history
--
--   An award is the policy's, so its row in the loot history is too. A row's HOW is upper case for the platform's own ways
--   an item leaves (a plain roll, disenchanting, a BoE to the master looter, an undo) and lower case for the policy's. Every
--   row names the list the item was given out on, the platform's to keep, false for one given out on none. Beside it is
--   PDATA, kept by whoever owns HOW and never looked inside by the other. It travels in LHADD, a broadcast and a sync exactly
--   as it was returned, so it must be something LibSerialize carries: numbers, strings, booleans and tables of them.
--
--   HistoryEntry  (cfgid, via, listid, uid, ilink, kind, cost) -> how, pdata. The row for UID winning ILINK with an award on
--                 LISTID. VIA is how it was decided: "bid", "roll" (a roll that carries an award) or "assign" (handed out by
--                 the item's own instructions), and KIND and COST as Award has them. Called before the award, so what the
--                 policy records is how things stood when it was won.
--                 HOW must start with a lower case letter; anything else is refused and the award goes unrecorded.
--   HistoryText   (cfgid, how, listid, pdata, colour) -> howtext, whattext. What the History tab draws for one of the
--                 policy's rows, in the How and What columns. An empty string leaves that column to the platform, the item
--                 for What. With COLOUR it is what the list draws, and without it plain words, which is what the list sorts
--                 by and what an export carries.
--   HistoryUndo   (cfgid, listid, uid, ilink, token) -> how, pdata. The row for UID's award of ILINK on LISTID being undone,
--                 TOKEN what Award handed back for that list, so the row can say what was given back. HOW must start with a
--                 lower case letter, and HistoryText draws it. Without it, or answering nothing, the undo is the platform's
--                 own "U" row. DKP's reads "Undo: 125, Main".
--
--   WinText      (cfgid, how, listid, pdata, who, ilink) -> text. How the raid and the guild are told WHO won ILINK with an
--                 award on LISTID, from the history row the award made. WHO is the winner's name. Without the mod's name in
--                 front, which the platform adds. Nil or an empty string gives the platform's plain "WHO won ILINK. Grats!".
--                 SK says "Oswald[3] won ... on the "Main Raid" list. Grats!".
--
--   A policy that awards anything needs the first two. Without HistoryEntry an award writes no history at all, and without
--   HistoryText its rows are drawn as their HOW.
--
-- Standings
--
--   rl.journal      An array on each list, the policy's record of what it did to the list that is not in the loot history:
--                   EP/GP's awards of effort points and its decays. The platform never reads it, and a copied list has
--                   it because a copy is the whole list under another name. It is the policy's to fill, from its own
--                   events so that every admin's copy is filled alike, and to send in its ListInfo so that a config
--                   arriving whole brings it too. Anything else a policy keeps on a list goes the same way, as EP/GP's
--                   rl.lastdecay, when the list was last decayed, does.
--
--   StandingFields  Array of numeric field names the policy keeps per member in rl.standings[uid], each starting at 0 in
--                   the record pol:Standings makes. The platform does nothing else with them: a member's numbers travel in
--                   the policy's own MemberInfo and ListInfo. Empty for Suicide Kings, which stores no numbers.
--
-- State the platform keeps on the policy
--
-- A current config is meaningful only inside a policy, so there is one such pair per policy and none at mod level, and they
-- are the platform's to write -- a policy reads them and never assigns them. Only the active policy is ever on screen, but
-- an inactive one goes on holding the config it last had in hand, so that switching back to it lands where it was left.
--
--   currentid    Id of the config this policy is currently looking at, or nil.
--   cfg          That config's table, or nil. The two are one fact in two fields and are written only by
--                konfer:SetPolicyCurrent(), which is what keeps them from disagreeing.
--   sortedlists  That config's roll lists in the order they are displayed in, or nil before the lists UI has built it.
--                Rebuilt by konfer:RefreshListsUI().
--   prefix       The handle and an underscore. It names the frames of the panels this policy builds into the window. Set at
--                registration.
--   built        True once this policy's own panels have been built. See konfer:BuildPolicyUI.
--   foyerinfo    The frame under the description in the foyer's Overview that the policy fills in PopulateBannerInfo, made the
--                first time it is needed.
--
-- There is one window and it is the mod's, not a policy's: konfer.mainwin, with the handful of its widgets that other files
-- reach in konfer.qf. Both are documented with the rest of the namespace in Konfer.lua.
--
-- Users
--
-- What is true of a character is Kore's, in KU.users, and the same in every config. What a config thinks of them is that
-- config's entry, cfg.uids[uid], which names the character by its KUID, and the entry is the policy's own view. Konfer.lua
-- documents both records. A uid means something only inside the config that minted it. A policy finds somebody through the
-- config itself: cfg:FindUser for a name, cfg.uids for the entry, and KU:Record for the character behind it.
--
-- The mod asks a policy about a character by KUID alone, never reaching into its configs, and this answers for all of them:
--
--   UserConfigs       (kuid) -> array of { id, name } for each of this policy's configs that has an entry for KUID.
--
-- A character renamed in Kore needs nothing from a policy, every entry naming them by a KUID the rename does not change.
--
-- The wire
--
-- Every policy is an endpoint of its own, registered with KoreComms and sending its own messages. What they all share is the
-- mod's one prefix, so the envelope names the endpoint a message came from and Konfer's dispatcher routes on that field. A
-- policy still only ever sees its own messages; it is told which they are rather than being handed only those.
--
--   endpoint         This policy's handle, which is what the envelope names it by. Kore reads it off the policy as it
--                    sends, so every send says whose it is without anything standing in front of it.
--   CHAT_MSG_PREFIX  konfer.CHAT_MSG_PREFIX, the mod's, because there is only the one.
--   protocol         konfer.protocol. One flat number for the whole mod, because policies ship inside Konfer and both ends
--                    of a conversation update together.
--   comms            The descriptor KoreComms reads. Its reach is the policy's own raid, party and bg.
--   CSendAM          (cfgid, cmd, prio, ...) sends about CFGID to the group the player is in, and out of one to wherever
--                    that config's traffic goes, the guild or the group, as cfg.channel says. Konfer's rather than Kore's.
--   CSendChannelAM   (cfgid, cmd, prio, ...) sends about CFGID as cfg.channel says, in a group or not. With CSendAM, the
--                    only thing that reads cfg.channel.
--   CSendGroupAM     (cfgid, cmd, prio, ...) sends about CFGID to the group whatever its channel, for what is the group's
--                    business alone, EP/GP's timed EP among it. CSendGuildAM is the same to the guild.
--   SendAM, CSendGuildAM, CSendWhisperAM and the rest
--                    Konfer's, put by konfer:MakeSends in front of the three KC.RegisterComms gives every endpoint. The
--                    non-C variants carry no config at all.
--
local required_fields = { "handle", "name", "nickname", "shortnick", "desc" }

--
-- The identity fields that no two policies may share. The name is what the user picks a policy by and the abbreviation is
-- what a policy signs this player's chat lines with, so a duplicate of any of them leaves somebody unable to tell which
-- policy they are looking at or being spoken to by.
--
local unique_fields = { "name", "nickname", "shortnick" }

--
-- Methods copied onto every policy at registration. These are the platform services a policy needs in order to do its job
-- without reaching into Konfer internals directly. Its comms methods come from KC.RegisterComms itself, as they do for any endpoint on the wire.
--

--
-- The words the platform puts on screen that a policy may want to be its own.
--
-- These are the platform's neutral wording, which is what a policy that overrides nothing gets. Suicide Kings calls an award
-- a suicide and says so in its Strings table; EP/GP will call it something else. The point is that the pages themselves say
-- none of it, so a page reads the same whichever policy is looking at it.
--
-- Anything here is presentation. Nothing keyed off these ever reaches the wire or the database.
--
local policy_words = {
  --
  -- The button on a list's member panel that applies an award to the selected member by hand, and the label on the list
  -- option naming a second list the award also applies to.
  --
  AWARD_BUTTON    = L["POLICY_AWARD_BUTTON"],
  AWARD_EXTRALIST = L["POLICY_AWARD_EXTRALIST"],

  --
  -- The item editor's option naming the list an auto-assigned item's award is applied on.
  --
  AWARD_ITEMLIST  = L["POLICY_AWARD_ITEMLIST"],

  --
  -- The raid warning opening a roll that carries an award with it, taking the list name, the item and the number of seconds.
  -- A plain roll that awards nothing is announced by the platform and is not here.
  --
  AWARD_ROLL      = L["POLICY_AWARD_ROLL"],

  -- The question the undo dialog asks before putting an award back.
  AWARD_UNDO      = L["POLICY_AWARD_UNDO"],

  --
  -- What the master looter is told, when asked whether to go through with an item's instructions, that the award will do,
  -- taking the list the award lands on. The question before it has already named the winner.
  --
  AWARD_AUTO      = L["POLICY_AWARD_AUTO"],

  -- The caption of what a win costs in the costing box, saying what it is counted in: "Cost (GP)" for EP/GP.
  COST            = L["POLICY_COST"],

  -- Where a bidder stands, in the raid announcement of their bid, taking what PositionText said.
  BID_STANDING    = L["POLICY_BID_STANDING"],

  --
  -- The headings of what the Lists page's Announce and Announce all say to the raid, each taking the list's name. The mod's
  -- name goes in front of them and the members after, Announce's each with what PositionText said.
  --
  ANNOUNCE_RAIDERS = L["POLICY_ANNOUNCE_RAIDERS"],
  ANNOUNCE_ALL     = L["POLICY_ANNOUNCE_ALL"],

  -- What the master looter is told before the raiders not on the list loot is being given out on, taking the list's name.
  NOT_ON_LIST      = L["POLICY_NOT_ON_LIST"],

  -- The help whisper's line for the standing whisper, taking the asker's name and the word to whisper.
  HELP_STANDING    = L["HELPMSG4"],

  -- The heading over where each member stands in the Lists page's member list, PositionText's column.
  MEMBERS_STANDING = L["Pos"],

  -- The Raid page's Broadcast tooltip, what a broadcast takes to the raid, and Remove's question before a raider goes.
  RAID_BROADCAST   = L["TIP_RAID_BROADCAST"],
  RAID_REMOVE      = L["RAID_REMOVE"],
}

--
-- What this policy calls WORD. Every policy-flavoured word the platform draws comes through here so that no page has to know
-- which policy it is drawing for.
--
-- An unknown word returns the key itself rather than nil, so a typo shows up on screen as the typo instead of blanking the
-- control it was going into.
--
local function policy_str(self, word)
  return (self.Strings and self.Strings[word]) or policy_words[word] or word
end

--
-- Reporting, from the policy rather than from the mod.
--
-- "Konfer: that configuration already exists" tells a user running three of these nothing at all, and nearly every message
-- the mod prints is about one policy's configs, lists, users or loot. So a policy signs its own, and konfer.err() and
-- konfer.info() are left for the handful of things that genuinely are the mod's: the foyer, the settings window, suspend and
-- resume, the version banner.
--
-- Signed with the policy's abbreviation, "KSK: ...". These go to this player's own chat frame, where being told which
-- policy is speaking is the point and the abbreviation is enough to say it. What goes out to the raid or to another player
-- is signed with the mod's name instead. A warning is something to act on now, and leads with three skulls to be seen.
--
local SKULLS = strrep("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t", 3)

local function policy_err(self, msg, ...)
  printf(ecolor, "%s", self.shortnick .. " " .. L["error: "] .. strfmt(msg, ...))
end

local function policy_info(self, msg, ...)
  printf(icolor, "%s", self.shortnick .. ": " .. strfmt(msg, ...))
end

local function policy_warn(self, msg, ...)
  printf(ecolor, "%s", SKULLS .. " " .. self.shortnick .. ": " .. strfmt(msg, ...))
end

--
-- A policy's own settings for a config, declared in its descriptor's defaults and kept apart from the platform's.
--
-- konfer.defaults and cfg.settings are the platform's, the things every policy has, and they travel as CHSET. These are the
-- policy's own, they live in cfg.psettings under its handle, and they travel as PSSET. A policy may name a setting whatever
-- it likes without asking what the platform already calls something, which is the whole point of the two being apart.
--
-- Reading one asks for the block, which makes it from the defaults the first time, so a setting is never nil for having
-- been declared after the config was made.
--
local function policy_setting(self, which, cfgid)
  local cfp = konfer:PolicyConfig(self, cfgid)
  local ps = cfp and cfp:PolicySettings(self.handle)

  return ps and ps[which]
end

local function policy_change_setting(self, which, val, cfgid, nocmd)
  local cfp = konfer:PolicyConfig(self, cfgid)

  if (cfp) then
    cfp:ChangePolicySetting(self.handle, which, val, nocmd)
  end
end

-- One of the policy's own options on list LISTID of a config, declared in its descriptor's listoptions. See cfg:ListOptions.
local function policy_list_option(self, cfgid, listid, which)
  local cfp = konfer:PolicyConfig(self, cfgid)
  local lo = cfp and cfp:ListOptions(listid, self.handle)

  return lo and lo[which]
end

--
-- Fetch the standings record for UID on the given list, creating both the standings table for the list and the record for
-- the member if they do not yet exist. Fields the policy declared in StandingFields start at 0.
--
-- Every one of these services looks the config up within the policy it was called on rather than across all of them. A
-- policy handed some other policy's config id has been handed a caller's mistake, and answering it would file numbers,
-- members and events in a config that cannot read them.
--
local function policy_standings(self, cfgid, listid, uid)
  local cfp = konfer:PolicyConfig(self, cfgid)

  if (not cfp or not cfp.lists[listid]) then
    return nil
  end

  local rl = cfp.lists[listid]

  if (not rl.standings) then
    rl.standings = {}
  end

  if (not rl.standings[uid]) then
    local rec = {}
    for k, v in ipairs(self.StandingFields) do
      rec[v] = 0
    end
    rl.standings[uid] = rec
  end

  return rl.standings[uid]
end

--
-- Record a change the policy made, so that it reaches the other admins and moves the config checksum. Everything a policy
-- changes travels this way, as an event on its own wire under the one flat konfer.protocol.
--
local function policy_add_event(self, cfgid, ...)
  local cfp = konfer:PolicyConfig(self, cfgid)

  if (not cfp) then
    return
  end

  return cfp:AddEvent(...)
end

--
-- The members the policy should consider, in stored order. This is the roster as the platform holds it, before any policy ordering is applied.
--
local function policy_members(self, cfgid, listid)
  local cfp = konfer:PolicyConfig(self, cfgid)

  if (not cfp or not cfp.lists[listid]) then
    return {}
  end

  return cfp.lists[listid].users
end

local function policy_user_configs(self, kuid)
  local found = {}

  for cfgid, cfp in pairs(konfer:PolicyConfigs(self)) do
    for uid, ent in pairs(cfp.uids) do
      if (ent[CFGUSER_KUID] == kuid) then
        tinsert(found, { id = cfgid, name = cfp.name })
        break
      end
    end
  end

  return found
end

--
-- Everything this mod sends goes out through one of these. Kore's message is a version letter, a checksum and a payload it
-- never looks into, so everything about a message that is this mod's is said in that payload, in a fixed preamble of four
-- values that every message carries and konfer:OnCommReceived takes off again:
--
--   konfer.protocol   this mod's own protocol version, compared by the receiver before it reads anything else.
--   endpoint          which of this mod's endpoints sent it, a policy's handle or konfer.CMD_MOD for the mod itself.
--   cmd               the command.
--   cfgid             the config it is about, or false for none, so the slot is there whether or not it is filled.
--
-- Kore's three sends are kept as they were given, the same three functions for every endpoint, so the copy the first one is
-- given serves all of them. The endpoint is read from the table at the moment of sending rather than closed over, so one
-- set of these serves the mod and every policy however many are registered.
--
-- Each also tells Kore whether the message is worth holding while the game refuses addon messages, which it works out from
-- the command, since Kore cannot see one any more. See konfer:HeldMessage.
--
local kore_sends = {}

local NO_CFG = false

--
-- While /konfer testloot has made up loot, or /konfer testraid a raid (KRP.pretend), a policy says nothing about either:
-- what the loot engine and the raid send is the policy's immediate traffic, and none of it is true. Its events still go, so
-- an admin's other edits meanwhile reach the others. What is held back is shown at the debug level Kore shows what it sends
-- at, so that it can still be watched. A packaged copy has neither and is never pretending.
--
local function pretending(self, cmd, ...)
  -- @debug-start@
  if ((konfer.testloot or KRP.pretend) and self ~= konfer and not (self.ehandlers and self.ehandlers[cmd])) then
    if (K.DebugWanted(9)) then
      konfer.debug(9, "not sent, made up loot: %s %s", cmd, K.Describe(...))
    end

    return true
  end
  -- @debug-end@

  return false
end

local function held(self, cmd)
  return (self.ehandlers and self.ehandlers[cmd] ~= nil) or konfer:HeldMessage(cmd)
end

local function whoami(self)
  return self.endpoint or konfer.CMD_MOD
end

--
-- Whether this endpoint should be talking to the group it finds itself in. Kore picks the channel a group is on and asks no
-- further, that being the medium's business and not the sender's, so a policy that does not work in a battleground says so
-- here rather than there. Only PUG does, which is what pol.bg means, and konfer:IsUsableHere reads the same flag to decide
-- whether a policy's windows are worth opening at all.
--
-- The mod's own messages go wherever the player is. They serve whichever policy is usable, and in a battleground that is
-- PUG, so refusing them there would leave PUG talking to itself.
--
local function may_talk(self)
  return (self == konfer) or (not KRP.in_bg) or (self.bg and true or false)
end

local sends = {}

sends.SendAM = function(self, cmd, prio, ...)
  if (not may_talk(self) or pretending(self, cmd, ...)) then
    return
  end

  return kore_sends.SendAM(self, prio, held(self, cmd), konfer.protocol, whoami(self), cmd, NO_CFG, ...)
end

sends.SendGuildAM = function(self, cmd, prio, ...)
  if (pretending(self, cmd, ...)) then
    return
  end

  return kore_sends.SendGuildAM(self, prio, held(self, cmd), konfer.protocol, whoami(self), cmd, NO_CFG, ...)
end

sends.SendWhisperAM = function(self, target, cmd, prio, ...)
  if (pretending(self, cmd, ...)) then
    return
  end

  return kore_sends.SendWhisperAM(self, target, prio, held(self, cmd), konfer.protocol, whoami(self), cmd, NO_CFG, ...)
end

sends.CSendGuildAM = function(self, cfgid, cmd, prio, ...)
  if (pretending(self, cmd, ...)) then
    return
  end

  return kore_sends.SendGuildAM(self, prio, held(self, cmd), konfer.protocol, whoami(self), cmd, cfgid or NO_CFG, ...)
end

sends.CSendWhisperAM = function(self, cfgid, target, cmd, prio, ...)
  if (pretending(self, cmd, ...)) then
    return
  end

  return kore_sends.SendWhisperAM(self, target, prio, held(self, cmd), konfer.protocol, whoami(self), cmd,
    cfgid or NO_CFG, ...)
end

-- About CFGID, to the group, whatever the config's channel says.
sends.CSendGroupAM = function(self, cfgid, cmd, prio, ...)
  if (not may_talk(self) or pretending(self, cmd, ...)) then
    return
  end

  return kore_sends.SendAM(self, prio, held(self, cmd), konfer.protocol, whoami(self), cmd, cfgid or NO_CFG, ...)
end

--
-- About CFGID to wherever the config's channel says, in a group or not. Where a config's traffic goes is the config's to say,
-- in cfg:Channel(), and Kore has no business reading configs. So this is where it is read: the guild for a guild config and
-- a guilded player, and the group for everything else. The sync request, the users refresh and the loot history broadcast
-- go this way even in a group.
--
sends.CSendChannelAM = function(self, cfgid, cmd, prio, ...)
  local cfp = konfer:PolicyConfig(self, cfgid)

  if (cfp and cfp:Channel() == konfer.CHANNEL_GUILD and K.player.is_guilded) then
    return sends.CSendGuildAM(self, cfgid, cmd, prio, ...)
  end

  return sends.CSendGroupAM(self, cfgid, cmd, prio, ...)
end

--
-- A policy's CSendAM. In a group the player may talk to it goes to that group, which is everybody raiding with them whatever
-- their guild and nobody in another raid of the same guild. Out of one it goes where the config's channel says.
--
sends.CSendAM = function(self, cfgid, cmd, prio, ...)
  if (KRP.in_party and may_talk(self)) then
    return sends.CSendGroupAM(self, cfgid, cmd, prio, ...)
  end

  return sends.CSendChannelAM(self, cfgid, cmd, prio, ...)
end

--
-- Give EP, which has just registered with KoreComms, the sends above in place of Kore's. The five that name a config are a
-- policy's alone: a config belongs to one policy and the mod has no current config of its own, so the mod is given only the
-- three that name none.
--
function konfer:MakeSends(ep)
  for k, v in ipairs({ "SendAM", "SendGuildAM", "SendWhisperAM" }) do
    kore_sends[v] = kore_sends[v] or ep[v]
    ep[v] = sends[v]
  end

  if (ep ~= konfer) then
    ep.CSendAM = sends.CSendAM
    ep.CSendChannelAM = sends.CSendChannelAM
    ep.CSendGroupAM = sends.CSendGroupAM
    ep.CSendGuildAM = sends.CSendGuildAM
    ep.CSendWhisperAM = sends.CSendWhisperAM
    return
  end

  -- @debug-start@
  --
  -- Everything the mod says in chat, announcements and the whispers answering bids alike, goes through these four. While
  -- /konfer testloot has made up loot, or /konfer testraid a raid, none of it is true, so it is shown here instead of said,
  -- the guild included.
  --
  for _, v in ipairs({ "SendText", "SendGuildText", "SendWhisper", "SendWarning" }) do
    local said = ep[v]

    ep[v] = function(self, text, ...)
      if (konfer.testloot or KRP.pretend) then
        K.printf(K.dcolor, konfer.L["not sent: %s"], text)
        return
      end

      return said(self, text, ...)
    end
  end
  -- @debug-end@
end

--
-- Register a loot distribution policy with Konfer. Validates the descriptor, fills in the platform defaults for anything the
-- policy did not supply and injects the platform services listed above. Returns the policy table.
--
function konfer:RegisterPolicy(pol)
  if (not pol or type(pol) ~= "table") then
    error("Invalid call to RegisterPolicy.", 2)
  end

  for k, v in ipairs(required_fields) do
    if (not pol[v] or type(pol[v]) ~= "string" or strlen(pol[v]) < 1) then
      error("RegisterPolicy: missing or invalid " .. v .. ".", 2)
    end
  end

  --
  -- The handle names this policy in every message it sends. It travels as a serialised value of its own, so it may say
  -- anything at all except what the mod itself is named by.
  --
  if (pol.handle == konfer.CMD_MOD) then
    error(strfmt("RegisterPolicy: handle %q is what the mod itself is named by on the wire.", konfer.CMD_MOD), 2)
  end

  --
  -- The handle is a namespace, not just a key: every frame built for this policy is named from it, so two policies sharing
  -- one would silently hand each other's frames back. Fail at registration, where whoever wrote it will see it, rather than
  -- in a window that half belongs to somebody else.
  --
  if (policies[pol.handle]) then
    error(strfmt("RegisterPolicy: handle %q is already registered.", pol.handle), 2)
  end

  -- A policy's saved tables sit at the top of the database under its handle, beside the mod's own.
  if (konfer.FRDB_RESERVED[pol.handle]) then
    error(strfmt("RegisterPolicy: handle %q is a name the mod keeps for itself.", pol.handle), 2)
  end

  --
  -- Derived rather than declared, so a policy cannot ship a prefix that disagrees with its handle or forget one. Every frame
  -- this policy owns is named from it.
  --
  pol.prefix = pol.handle .. "_"

  for k, v in pairs(policies) do
    for kk, vv in ipairs(unique_fields) do
      if (v[vv] == pol[vv]) then
        error(strfmt("RegisterPolicy: %s %s %q is already taken by %s.", pol.handle, vv, pol[vv], k), 2)
      end
    end
  end

  -- A misspelt setting would otherwise be written into nothing, and every new config would quietly start at the platform's.
  for k in pairs(pol.configdefaults or {}) do
    if (konfer.defaults[k] == nil) then
      error(strfmt("RegisterPolicy: %s configdefaults names %q, which is not one of the platform's settings.", pol.handle, k), 2)
    end
  end

  --
  -- A command is optional, and one already answered, by another policy or by any slash command the game already knows of,
  -- would be quietly taken over by whichever registered last. The policies are asked as well as the game, because the
  -- policies in the box give the game their commands only once they have all registered.
  --
  if (pol.command ~= nil) then
    if (type(pol.command) ~= "string" or strlen(pol.command) < 1) then
      error(strfmt("RegisterPolicy: %s command is not a command.", pol.handle), 2)
    end

    local lcmd = strlower(pol.command)

    for k, v in pairs(policies) do
      if (type(v.command) == "string" and strlower(v.command) == lcmd) then
        error(strfmt("RegisterPolicy: %s command %q is already taken by %s.", pol.handle, pol.command, k), 2)
      end
    end

    for key in pairs(SlashCmdList) do
      local i = 1
      local slash = _G["SLASH_" .. key .. i]

      while (type(slash) == "string") do
        if (strlower(slash) == "/" .. lcmd) then
          error(strfmt("RegisterPolicy: %s command %q is already taken by %s.", pol.handle, pol.command, key), 2)
        end

        i = i + 1
        slash = _G["SLASH_" .. key .. i]
      end
    end
  end

  --
  -- Art is held in the one shape whichever of the two it was given in, so nothing that draws it has to ask. A card may also be a function.
  --
  for _, field in ipairs({ "TitleCard", "Icon", "CommandPlate" }) do
    local art = pol[field]

    if (type(art) == "string") then
      pol[field] = { texture = art, coords = { 0, 1, 0, 1 } }
    elseif (type(art) == "table") then
      if (type(art.texture) ~= "string") then
        error(strfmt("RegisterPolicy: %s %s has no texture.", pol.handle, field), 2)
      end
      art.coords = art.coords or { 0, 1, 0, 1 }
    elseif (art ~= nil and not (field == "TitleCard" and type(art) == "function")) then
      error(strfmt("RegisterPolicy: %s %s is not art.", pol.handle, field), 2)
    end
  end

  if (pol.accent ~= nil) then
    local ac = pol.accent

    if (type(ac) ~= "table" or type(ac.r) ~= "number" or type(ac.g) ~= "number" or type(ac.b) ~= "number") then
      error(strfmt("RegisterPolicy: %s accent must be { r, g, b }.", pol.handle), 2)
    end
  end

  if (not pol.StandingFields) then
    pol.StandingFields = {}
  end

  --
  -- A panel on the Lists page is as tall as the policy says, and without that the page would have to guess.
  --
  if (pol.ListsPage) then
    assert(type(pol.ListsPage.height) == "number" and pol.ListsPage.height > 0, "ListsPage must give a height.")
  end

  --
  -- A policy that names OnActivate and gives something that cannot be called would be found out only on the first switch,
  -- which may be a raid night away, so it is checked here where whoever wrote it is looking.
  --
  if (pol.OnActivate ~= nil and type(pol.OnActivate) ~= "function") then
    error(strfmt("RegisterPolicy: %s OnActivate is not a function.", pol.handle), 2)
  end

  --
  -- Where the policy can be used, defaulted rather than required so that the ordinary case costs a policy nothing to
  -- declare. Only a nil is replaced; a policy that says false means it.
  --
  if (pol.raid == nil) then
    pol.raid = true
  end

  if (pol.party == nil) then
    pol.party = true
  end

  if (pol.bg == nil) then
    pol.bg = false
  end

  if (pol.costing == nil) then
    pol.costing = false
  end

  --
  -- Everything registered before Init.lua runs came out of Konfer's own TOC, and anything else is an addon that had to
  -- declare Konfer as a dependency to reach this function at all, so it loaded afterwards. That is what separates the
  -- policies in the box from the ones that are not.
  --
  pol.external = konfer.builtins_registered and true or false
  pol.order = (tonumber(pol.order) or 0) +
    (pol.external and konfer.POLICY_EXTERNAL_BASE or 0)

  --
  -- The events this policy answers, its own copy of the standard set. A policy's own Comms.lua then adds what only it
  -- understands, replaces a standard handler it wants to do differently, or removes one it has no use for -- all without
  -- touching what any other policy answers.
  --
  -- Copied rather than shared, and copied here rather than left for the policy to do, because a policy that forgot would
  -- silently answer nothing at all. The standard set is what a policy gets for turning up.
  --
  pol.ihandlers = {}
  pol.ehandlers = {}

  for k, v in pairs(konfer.std_ihandlers) do
    pol.ihandlers[k] = v
  end

  for k, v in pairs(konfer.std_ehandlers) do
    pol.ehandlers[k] = v
  end

  --
  -- The whisper commands a raider can send, copied the same way and for the same reason. What each does is the platform's,
  -- every policy having bidding and standings and people who are available but not here. What each is called is the
  -- policy's, which is what the descriptor's Whispers replaces, a key at a time: Suicide Kings answers "suicide" where the
  -- platform would have said "standing". A key of its own is a whisper only it answers, its handler put in pol.whispers
  -- after this.
  --
  -- whisperword is the map the dispatcher actually reads, every word of every key pointing back at its key, built here so
  -- that answering a whisper is one lookup rather than a walk.
  --
  pol.whispers = {}
  pol.whisperwords = {}
  pol.whisperword = {}

  for k, v in pairs(konfer.std_whispers) do
    pol.whispers[k] = v
  end

  for k, v in pairs(konfer.std_whisperwords) do
    pol.whisperwords[k] = v
  end

  for k, v in pairs(pol.Whispers or {}) do
    pol.whisperwords[k] = v
  end

  for k, words in pairs(pol.whisperwords) do
    for _, w in ipairs(words) do
      pol.whisperword[strlower(w)] = k
    end
  end

  --
  -- The policy's own endpoint on the wire -- see "The wire" above. Its frames are named from the handle Kore is given, so
  -- that is built the same way as every other frame name this policy owns. The prefix is the mod's, every endpoint sharing
  -- the one, and every command this policy sends goes out with its handle in front so the far end knows whose it is.
  --
  pol.endpoint = pol.handle
  pol.CHAT_MSG_PREFIX = konfer.CHAT_MSG_PREFIX
  pol.protocol = konfer.protocol
  pol.comms = {
    handle = pol.prefix .. konfer.addon_handle,
    title  = L["MODTITLE"],
  }

  --
  -- A policy's window says the mod in its brackets and the policy after them, "<Konfer> Suicide Kings - Roll lists", one
  -- level down from the mod's own "<KahLua> Konfer - ...": what is in the brackets is always what owns what follows them,
  -- and what owns a policy is this mod rather than the suite. Set before registering, because RegisterComms puts a default
  -- on anything that has none and that default would say KahLua.
  --
  pol.WindowTitle = function(self, what)
    return K.WindowTitle(L["MODTITLE"], self.name, what)
  end

  --
  -- Registered so that it can send, and given this mod's own sends in place of Kore's three. It never subscribes and so has
  -- no OnCommReceived: only the mod listens, and its dispatcher hands a policy the messages that named it.
  --
  KC.RegisterComms(pol)
  konfer:MakeSends(pol)

  pol.Standings = policy_standings
  pol.AddEvent = policy_add_event
  pol.Members = policy_members
  pol.UserConfigs = policy_user_configs
  pol.Setting = policy_setting
  pol.ChangeSetting = policy_change_setting
  pol.ListOption = policy_list_option
  pol.debug = konfer.debug
  pol.err = policy_err
  pol.info = policy_info
  pol.warn = policy_warn
  pol.Str = policy_str

  policies[pol.handle] = pol
  konfer.npolicies = konfer.npolicies + 1

  --
  -- A policy an addon registers once the mod is running, a load on demand one, has missed everything startup does for the
  -- policies that were already here, so it is given all of it now: back on the config it last had, its command, and a card
  -- in the foyer and the settings window. It hears its own messages from the moment it is registered, the mod's
  -- subscription being the only one and already up.
  --
  -- Its own panels are built only if development is building them all up front. Otherwise it gets them when it first
  -- becomes the active policy, exactly as every other policy does.
  --
  if (konfer.initialised) then
    konfer:RestorePolicyConfig(pol)
    konfer:RefreshCSData()

    if (konfer.EAGER_POLICY_UI) then
      konfer:BuildPolicyUI(pol)
    end

    konfer:RegisterPolicyCommands()
    konfer:RefreshFoyerUI()
    konfer:RefreshSettingsUI()
    konfer:FullRefresh(false)
  end

  return pol
end

--
-- The policy governing config CFGID. Falls back to DEFAULT_POLICY for a config that names no policy, and returns nil only
-- when that fallback is itself not registered, which means no policy has loaded at all.
--
-- Called with no CFGID this answers with the active policy, and must never reach through it for a config to look up: this is
-- what MakeAliases calls to decide what the active policy is in the first place, before there is one.
--
function konfer:GetPolicy(cfgid)
  if (not cfgid) then
    return self.apol or policies[self.DEFAULT_POLICY]
  end

  local cfp = self:Config(cfgid)

  --
  -- A config we do not have has no policy, and saying so is the point. The default used to be returned here, which reads
  -- exactly like a real answer and files things in the wrong drawer without complaining: a config being stored for the first
  -- time cannot be looked up, so every creation path silently became a Suicide Kings config.
  --
  -- Naming no policy is different and still means the default. That is a config that exists and simply predates the field.
  --
  if (not cfp) then
    return nil
  end

  return cfp:GetPolicy()
end

--
-- The policy this config runs. Every config names one, so this is a lookup rather than a search, and it is the form every
-- config method uses. konfer:GetPolicy above is for code holding nothing but an id.
--
function cfgm:GetPolicy()
  return policies[self.policy or konfer.DEFAULT_POLICY]
end

--
-- What this character is in the config POL currently has: 2 for its owner, 1 for a co-admin, false for everybody else and
-- for a policy that has no config at all. That last case is the reason this exists. Every page asks the question to decide
-- what to enable, and a policy waiting for its first config has to answer rather than fail, where asking the config itself
-- would mean asking a config that is not there.
--
--
-- Every platform call that works on a config is told which one, and asserts when it is not. There used to be a fallback --
-- "cfg or self.apol.currentid", meaning whichever config the active policy had in hand -- and it was wrong in the one case
-- it existed for. A policy window is not the active policy: with EP/GP active, a roll list created from SK's window went into
-- EP/GP's config and looked exactly like it had worked.
--
-- The loot engine is the exception and keeps the fallback, because there the active policy is the whole point: it is the one
-- running the raid. Those five are marked where they stand.
--

--
-- Point POL at config CFGID, or at nothing when CFGID is nil. Returns the id that took, which is nil in either of the cases where nothing did.
--
-- This is the only thing that writes currentid or cfg, because they are one fact in two fields -- the id, and the table it
-- names -- and nothing in the mod is written to survive them disagreeing. Every page reads pol.cfg on the strength of
-- pol.currentid being set, so a policy carrying an id whose table was never fetched is a nil dereference waiting for whichever page draws first.
--
-- A policy's current config is one of its own or there is none. Being handed another policy's is a caller bug rather than a
-- state to carry, so it clears the pair and says so by returning nil, rather than leaving an id pointing at a config this policy cannot reach.
--
function konfer:SetPolicyCurrent(pol, cfgid)
  if (not pol) then
    return nil
  end

  local cfp = self:PolicyConfig(pol, cfgid)

  if (not cfp) then
    pol.currentid = nil
    pol.cfg = nil
    return nil
  end

  pol.currentid = cfgid
  pol.cfg = cfp

  return cfgid
end

--
-- Put POL back on the config it had in hand when the user last logged out, on another of its own when that one has gone, or on
-- none for a policy with no configs. Both halves of the pair are set, because what runs next reads pol.cfg on the strength of
-- pol.currentid being set.
--
function konfer:RestorePolicyConfig(pol)
  local pdb = self:PolicyDB(pol)

  if (pdb.defconfig and not self:PolicyConfig(pol, pdb.defconfig)) then
    pdb.defconfig = next(pdb.configs)
  end

  self:SetPolicyCurrent(pol, pdb.defconfig)
end

function konfer:PolicyAdmin(pol)
  return (pol and pol.cfg and pol.cfg:MyStatus()) or false
end

--
-- A policy's own corner of the saved variables, made on first use.
--
-- Every policy is its own mod as far as its data goes. They share an addon and a database file the way five mods share an
-- apartment block, and nothing but the foyer has any business looking past its own front door. So the configs live here, and
-- so does which of them this policy had in hand when the user last logged out.
--
-- What stays at the top of frdb is what genuinely belongs to nobody: the database version, whether the whole mod is
-- suspended, and the order and disabled state of the policies themselves.
--
function konfer:PolicyDB(pol)
  if (not pol or not self.frdb) then
    return nil
  end

  local pdb = self.frdb[pol.handle]

  if (not pdb) then
    pdb = { configs = {} }
    self.frdb[pol.handle] = pdb
  end

  return pdb
end

--
-- The configs belonging to POL, which is the table to walk when a question is about one policy. There is deliberately no way
-- to ask for all of them: a question that spans policies belongs to the foyer, and the foyer asks each policy in turn rather
-- than reaching into a shared pile.
--
function konfer:PolicyConfigs(pol)
  local pdb = self:PolicyDB(pol)

  return (pdb and pdb.configs) or {}
end

--
-- Whether POL has no configs at all -- a policy the user has never set up, or one whose last config was deleted. Derived
-- rather than stored: a flag saying what an empty table already says is a second copy of the same fact and the two drift.
--
function konfer:IsTempCfg(pol)
  return next(self:PolicyConfigs(pol)) == nil
end

--
-- How many configs POL has. Counted rather than kept for the same reason.
--
function konfer:NumConfigs(pol)
  local n = 0

  for k, v in pairs(self:PolicyConfigs(pol)) do
    n = n + 1
  end

  return n
end

--
-- Being the active policy is told to the two policies it changes for, through the descriptor's OnActivate, and to nobody
-- else. Telling all five, which is what walking the registry would be, says the same fact five times and makes four
-- policies work out from an argument that nothing about them has changed.
--
-- konfer:EnterPolicy and konfer:LeavePolicy are the two halves and konfer:ActivatePolicy orders them.
--

--
-- Whether the mod is switched off. Suspended means as close to never having loaded as an addon already in memory can get, so
-- nothing asks this to decide how to behave: the things that would have behaved are not listening.
--
-- What still asks is the handful of entry points a suspended mod cannot stop being handed -- a slash command, a window
-- someone tries to open -- and they ask so they can say no.
--
function konfer:IsSuspended()
  return (self.frdb and self.frdb.suspended) and true or false
end

--
-- Whether POL can be used in the group this character is in, the active policy when none is named.
--
-- Each policy says for itself, through the raid, party and bg fields on its descriptor. Every policy shipped is usable in a
-- raid and a party; only PUG is usable in a battleground, and not for loot but for what it knows about people.
--
-- Usable is not the same as distributing loot. The loot path asks this and also asks whether this character is the master
-- looter, and a battleground has none, so loot stays inert there whatever this answers. Anything a policy does that is not loot asks this alone.
--
-- A battleground is asked about first because a battleground group is also a raid as far as the game is concerned, and it is
-- the battleground that decides.
--
-- Solo counts as usable. Nothing is being distributed, but the windows are still worth opening to edit lists and users in.
--
function konfer:IsUsableHere(pol)
  local pol = pol or self.apol

  if (KRP.in_bg) then
    return pol.bg and true or false
  end

  if (KRP.in_raid) then
    return pol.raid and true or false
  end

  if (KRP.in_party) then
    return pol.party and true or false
  end

  return true
end

--
-- Whether CFGID is the active policy's current config. Exactly one config in the whole mod answers true, and often none does.
--
-- That one config is both the config on display and the config loot is running against, there being one window showing the
-- active policy and one policy arming for loot, so this is the only question either has to ask. A data change asks it
-- before refreshing, because a change to a config nobody is looking at needs no redraw, and the loot engine asks it because
-- a message reaching a loot handler at all already means it is this policy's, dispatch having routed it there, and what is
-- left to establish is whether this is the config the raid is being run with.
--
-- A policy that is not the active one may perfectly well have a current config. Nothing is showing it and nothing is
-- looting from it, which is what this answering false means.
--
-- With every policy switched off there is no active policy and no config answers true, which is why the policy is tested rather than reached through.
--
function cfgm:IsActive()
  return (self.id and konfer.apol and self.id == konfer.apol.currentid) and true or false
end

--
-- Whether the user has switched a policy off. A disabled policy is still loaded and still registered -- an addon cannot be
-- unloaded and a file cannot be un-run -- but it is not offered anywhere, which is as close to not existing as the mod can
-- get it. The settings window is the one place that lists it, because that is where it is switched back on.
--
-- Configs that already name a disabled policy keep naming it, and GetPolicy still resolves them: forgetting which policy
-- governs a config would lose the data rather than shelve it, which is the opposite of what disabling means.
--
function konfer:IsPolicyDisabled(handle)
  local off = self.frdb and self.frdb.policydisabled

  return (off and off[handle]) and true or false
end

--
-- Whether POL has lists at all, which a policy that hides the Lists page (hidepages) does not. Nothing about somebody's place
-- on a list means anything under one that has none, so the Users page shows neither the lists a user is on nor Frozen.
--
function konfer:PolicyHasLists(pol)
  return not (pol and pol.hidepages and pol.hidepages.lists)
end

--
-- Where a policy sorts. The user's own order wins wherever they have set one; otherwise it is what the policy asked for at
-- registration, which for an external one already has POLICY_EXTERNAL_BASE in it. Ties are broken by name, which every
-- policy has and no two share.
--
local function policy_order(handle, pol)
  local uo = konfer.frdb and konfer.frdb.policyorder

  return (uo and uo[handle]) or pol.order or 0
end

local function policy_sorter(a, b)
  if (a.order ~= b.order) then
    return a.order < b.order
  end

  return a.name < b.name
end

--
-- Every policy that can be offered, in display order. ALL includes the disabled ones, and only the settings window wants that.
--
function konfer:SortedPolicies(all)
  local ret = {}

  for k, v in pairs(policies) do
    if (all or not self:IsPolicyDisabled(k)) then
      tinsert(ret, { handle = k, name = v.name, order = policy_order(k, v),
        disabled = self:IsPolicyDisabled(k) })
    end
  end

  tsort(ret, policy_sorter)

  return ret
end

--
-- Write the display order down. The list handed in is the whole of it, in the order it is to be shown, and every policy in
-- it gets an explicit place -- there is no half-ordered state where some policies are placed and the rest fall back on what
-- they asked for, because that reads as the list jumping about when one of them moves.
--
function konfer:SetPolicyOrder(list)
  local uo = {}

  for k, v in ipairs(list) do
    uo[v.handle or v] = k
  end

  self.frdb.policyorder = uo
end

--
-- Which policy methods have failed this session and been reported, so that one called for every row of a list says so once
-- rather than once a row.
--
local reported_failures = {}

--
-- Call METHOD on the policy governing CFGID. Every platform call into a policy goes through here, so that an incomplete or
-- broken policy degrades to the platform default instead of breaking loot distribution for everybody. This is the
-- discipline Kore applies to addon callbacks with safecall().
--
-- The first value says whether the call went through, false only when the method raised an error, and everything the
-- method answered follows it. A policy that does not implement METHOD has failed at nothing and answers DEFVAL, and so does
-- one that failed. A failure is reported to the player, under the policy's name, because a caller that carried on as though
-- it had worked would be recording an award that never happened. It is raised through the game's error handler as well,
-- as any Lua error is, so that it is a fault wherever faults are counted and not a line of chat that scrolls away. The
-- caller still gets DEFVAL back rather than being unwound, the error being the policy's and the page around it the platform's.
--
-- CFGID both names the config the method works on and decides which policy is asked, so it is required rather than
-- defaulted. A policy method may assume it was handed a real config id belonging to the policy it was called on.
--
local function policy_answered(pol, method, defval, ok, ...)
  if (ok) then
    return true, ...
  end

  local why = ...
  local key = pol.handle .. ":" .. method

  konfer.debug(1, "policy %q method %q failed: %s", pol.handle, method, tostring(why))

  if (not reported_failures[key]) then
    reported_failures[key] = true
    pol:err(L["%s failed: %s"], method, tostring(why))
    geterrorhandler()(strfmt("%s %s failed: %s", pol.handle, method, tostring(why)))
  end

  return false, defval
end

function cfgm:PolicyCall(method, defval, ...)
  local pol = konfer:GetPolicy(self.id)

  if (not pol or not pol[method]) then
    return true, defval
  end

  return policy_answered(pol, method, defval, pcall(pol[method], pol, self.id, ...))
end

--
-- Call FN, one of POL's hooks that is handed no config and so cannot go through cfg:PolicyCall: a page's Construct, a
-- selection changing, OnActivate, one of its commands. Answers as cfg:PolicyCall does, whether the call went through and
-- then what FN answered, or DEFVAL when it raised. NAME is what a failure is reported as.
--
function konfer:PolicyHook(pol, name, defval, fn, ...)
  return policy_answered(pol, name, defval, pcall(fn, ...))
end

--
-- A policy's title card: its artwork as a button, which is how a policy is shown anywhere the mod offers a choice between
-- them. The foyer draws one per policy down its left hand side; a policy window draws its own as a header.
--
-- The artwork's bottom eighth is a band, there to be drawn behind whatever controls sit at the foot of the card. Draw the
-- whole of it to get the band, or pass band = false to trim it away and leave only the picture, which is what a header wants.
--
-- The card knows nothing about what is put on that band. The foyer's Hide button belongs to the foyer, not to every card everywhere.
--
--   cfg.policy   the policy, as a table or a handle. May be nil, and may be changed later through ret:SetPolicy, because a
--                card in a scroll list is made once and pointed at each policy in turn.
--   cfg.band     draw the band along the bottom. Defaults to true.
--   cfg.command  show the policy's command plaque at the right hand end of that band. Defaults to true, and means nothing
--                without a band, which is the only place there is room for it.
--   cfg.outline  colour of the rim shown by ret:SetSelected. Defaults to the gold Blizzard selects with; pass false for a
--                card that is never selected.
--
-- Everything else is passed through to KUI:CreateImageButton.
--
local COLOR_CARD_RIM = KUI.DEFAULT_ARTWORK_COLOR

--
-- How far the plaque is held off the right hand edge of the card. The artwork tapers into that corner and a plaque pushed
-- hard against it looks wedged.
--
local CARD_CMD_INSET = 23

--
-- How tall the plaque is against the band. A plaque exactly as tall as the band reads small on a foyer card.
--
local CARD_CMD_SCALE = 1.25

--
-- The art of the policies Konfer ships. Each strip is one column of eight equal cells, a policy in each in the order the
-- policies sort in, so a policy's art is its order counted down the strip: order N is the Nth cell, from (N - 1) / 8 to
-- N / 8. STRIP names the strip, PolicyLogos, PolicyIcons or PolicyCommands. Returns art in the shape a descriptor takes it.
--
function konfer:PolicyArt(strip, order)
  local top = (order - 1) / 8

  return { texture = konfer.TEXTURE_PATH .. strip, coords = { 0, 1, top, top + 1 / 8 } }
end

--
-- Part of a piece of art, as texture coordinates: the rows from A to B of it, as fractions of its height.
--
local function art_rows(art, a, b)
  local c = art.coords
  local h = c[4] - c[3]

  return { c[1], c[2], c[3] + h * a, c[3] + h * b }
end

--
-- What a policy that ships no artwork gets: a plain dark card with its name written on it. This is also what a third party
-- sees before they have drawn anything of their own.
--
local COLOR_CARD_BLANK = { r = 0.08, g = 0.08, b = 0.08, a = 0.9 }

local function card_SetPolicy(this, policy)
  local pol = policy

  if (type(pol) == "string") then
    pol = konfer.policies[pol]
  end

  this.policy = pol
  this.handle = pol and pol.handle or nil

  --
  -- Done before anything below returns, because a card in a scroll list is pointed at one policy after another and every one
  -- of them must either put its own plaque there or take the last one away.
  --
  if (this.command) then
    local plate = pol and pol.CommandPlate

    if (plate) then
      local c = plate.coords

      this.command:SetTexture(plate.texture)
      this.command:SetTexCoord(c[1], c[2], c[3], c[4])
      this.command:Show()
    else
      this.command:Hide()
    end
  end

  if (not pol) then
    this.image:SetColorTexture(0, 0, 0, 0)
    this:SetText("")
    return
  end

  --
  -- A policy may supply a function rather than a texture, to draw its own card into the button. It is called once: the
  -- drawing belongs to the policy from then on, and pointing the card at something else does not undo it.
  --
  if (type(pol.TitleCard) == "function") then
    if (not this.drawn) then
      this.drawn = true
      local ok, e = pcall(pol.TitleCard, pol, this, this:GetWidth(), this:GetHeight())

      if (not ok) then
        konfer.debug(1, "policy %q TitleCard failed: %s", pol.handle, tostring(e))
      end
    end

    return
  end

  if (type(pol.TitleCard) == "table") then
    this:SetTexture(pol.TitleCard.texture, art_rows(pol.TitleCard, 0, this.trimband and 7 / 8 or 1))
    this.image:SetVertexColor(1, 1, 1, 1)
    this:SetText("")
    return
  end

  this.image:SetColorTexture(COLOR_CARD_BLANK.r, COLOR_CARD_BLANK.g, COLOR_CARD_BLANK.b, COLOR_CARD_BLANK.a)
  this:SetText(pol.name or "")
end

function konfer:CreateTitleCard(cfg, parent)
  local cfg = cfg or {}
  local arg = {}

  for k, v in pairs(cfg) do
    arg[k] = v
  end

  arg.policy = nil
  arg.band = nil
  arg.command = nil
  arg.outline = (cfg.outline == nil) and COLOR_CARD_RIM or cfg.outline or nil

  local card = KUI:CreateImageButton(arg, parent)

  --
  -- Trimming the band off is a texture coordinate rather than a smaller frame, so a card without one is the same picture
  -- with its bottom eighth cut away and keeps the shape the caller asked for.
  --
  local band = (cfg.band == nil) or cfg.band
  local command = (cfg.command == nil) or cfg.command

  card.trimband = not band

  --
  -- The plaque naming the policy's command, at the right hand end of the band, CARD_CMD_SCALE times as tall as the band and
  -- centred on the hairline dividing the artwork from it, so the points at each end of the plaque sit on that line. It reads
  -- as a fitting laid across the join rather than a label dropped into the band.
  --
  -- Anchored to the picture rather than to the button so that it moves with the picture when the card is pressed. It is part
  -- of the face, not something sitting on top of it.
  --
  if (band and command) then
    local band = card:GetHeight() / 8
    local h = band * CARD_CMD_SCALE
    local ct = card:CreateTexture(nil, "OVERLAY")

    ct:SetWidth(h * 4)
    ct:SetHeight(h)
    ct:SetPoint("RIGHT", card.image, "BOTTOMRIGHT", 0 - CARD_CMD_INSET, band)
    ct:Hide()
    card.command = ct
  end

  card.SetPolicy = card_SetPolicy
  card:SetPolicy(cfg.policy)

  return card
end
