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

local MAJOR= "Konfer"
local MINOR = tonumber("@revision@")
local MINOR = 0 -- @debug-delete@

-- The name of the folder this mod is installed in, which the game hands every file. The only thing here that cares is where
-- the artwork lives, and taking it from this rather than writing it down makes renaming the folder a rename and nothing more.
local addonName = ...
local K,KM = LibStub:GetLibrary("Kore")
local H = LibStub:GetLibrary("KoreHash")
local KUI = LibStub:GetLibrary("KoreUI")
local KRP = LibStub:GetLibrary("KoreParty")
local KLD = LibStub:GetLibrary("KoreLoot")
local KC = LibStub:GetLibrary("KoreComms")
local DB = LibStub:GetLibrary("AceDB-3.0")
local ZL = LibStub:GetLibrary("LibDeflate")
local LS = LibStub:GetLibrary("LibSerialize")

if (not K) then
  error("Konfer: could not find Kore.", 2)
end

if (tonumber(KM) < 1) then
  error("Konfer: outdated Kore. Please update Kore and every addon that uses it.")
end

if (not H) then
  error("Konfer: could not find Kore Hash library.", 2)
end

if (not DB) then
  error("Konfer: could not find Kore Database library.", 2)
end

if (not KUI) then
  error("Konfer: could not find Kore UI library.", 2)
end

if (not KRP) then
  error("Konfer: could not find Kore Raid/Party library.", 2)
end

if (not KC) then
  error("Konfer: could not find Kore Konfer library.", 2)
end

if (not KLD) then
  error("Konfer: could not find Kore Loot Distribution library.", 2)
end

if (not ZL) then
  error("Konfer: could not find LibDeflate library.", 2)
end

if (not LS) then
  error("Konfer: could not find LibSerialize library.", 2)
end

local L = LibStub("AceLocale-3.0"):GetLocale(MAJOR, false)

-- Local aliases for global or Lua library functions
local _G = _G
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local tonumber = tonumber
local strfmt = string.format
local strsub = string.sub
local strfind = string.find
local strlen = string.len
local strlower = string.lower
local match = string.match
local pairs, ipairs, type = pairs, ipairs, type
local min, max = math.min, math.max
local printf = K.printf

local konfer = K:NewAddon(nil, MAJOR, MINOR, L["Loot distribution system."], L["MODNAME"], L["CMDNAME"] )
if (not konfer) then
  error("Konfer: addon creation failed.", 2)
end

--
-- Konfer as a system, rather than Konfer the Lua file. This is the published name: it is what people reach for in a /run
-- macro, and it is what the loot distribution policies (Suicide Kings, EP/GP, DKP, Loot Council, PUG) register themselves
-- with, through konfer:RegisterPolicy() in Policy.lua. They register with Konfer, not with Kore -- Kore only supplies the
-- policy-agnostic looting mechanics that Konfer is built on, and knows nothing about any particular distribution system.
--
-- Note that this name has to stay clear of the frames Konfer creates, since CreateFrame() publishes a named frame into _G
-- under that same name. The window is "KonferMainWin" and everything the platform builds in it is named from that. The
-- frames a policy builds into it are named from the policy's prefix, so that two policies contributing a panel to the same
-- page cannot take each other's names in _G.
--
_G["Konfer"] = konfer

--
-- The libraries, put on the namespace so that every other file takes its locals from here rather than asking LibStub again.
-- Each is what the handle for it says everywhere in the tree: KUI is KoreUI, KRP KoreParty, KLD KoreLoot, KC KoreComms, H
-- KoreHash, DB AceDB, ZL LibDeflate and LS LibSerialize. Kore itself is K and is fetched directly, being the one that has to
-- be there before any of this can run. These are aliases rather than state, which is why they are not in the block of global variables further down.
--
konfer.KUI = KUI
konfer.L   = L
konfer.KRP = KRP
konfer.KLD = KLD
konfer.H   = H
konfer.DB  = DB
konfer.KC  = KC
konfer.ZL  = ZL
konfer.LS  = LS

-- The people, which are Kore's. Every file that touches a character's facts declares this local the same way.
local KU = K.Users

--
-- What this mod is called on the wire and in Kore's registries. The one prefix carries the whole mod, every policy's
-- messages included, and which endpoint a message is for is the first field of its command. The handle is what this mod
-- registered with KoreParty, KoreLoot, KoreComms and K:RegisterMod, and is what another client names it by in a character
-- info check.
--
-- A prefix is scarce, and the scarcity is the player's rather than this mod's. The server filters addon messages by prefix
-- and stops filtering for a client at all once sixty four are registered across every addon it runs, so a prefix for each
-- policy would spend six of somebody's sixty four on one mod. It would buy nothing either: every policy ships inside Konfer
-- and registers at load, so a client that hears one hears them all whatever they are addressed to. Naming the endpoint in
-- the command costs a few bytes a message and leaves the filtering to do its job.
--
konfer.CHAT_MSG_PREFIX = "KONFER"
konfer.addon_handle = "konfer"

local MakeFrame = KUI.MakeFrame

-- We will be using both KoreParty and KoreLoot.
KRP:RegisterAddon(konfer.addon_handle)
KLD:RegisterAddon(konfer.addon_handle)
KC:RegisterAddon(konfer.addon_handle)

-- And Kore itself, which wants none of that and only wants to know that this mod is here and which copy of it is, so that a
-- character info check can say so. MINOR rather than konfer.version because that is not set until further down.
K:RegisterMod(konfer.addon_handle, L["MODTITLE"], MINOR)

--
-- The people are Kore's, and Kore knows nothing about configs or policies, so where something it does means this mod has
-- work to do it asks rather than reaching in. Each of these is the Konfer half of a change Kore has just made to a person.
--
KU:RegisterConsumer(konfer.addon_handle, {
  --
  -- Every config of every policy that still holds KUID, which is what stops Kore deleting somebody who is still in use. A
  -- config is a policy's and only that policy can look inside its own, so each is asked in turn.
  --
  UserConfigs = function(self, kuid)
    local used = {}

    for k, pol in pairs(konfer.policies) do
      for kk, cfg in ipairs(pol:UserConfigs(kuid)) do
        tinsert(used, { name = cfg.name, owner = pol.name })
      end
    end

    return used
  end,

  --
  -- Who Kore knows, or what is true of them, changed, a rename among them. Every window of this mod's that shows a person is
  -- redrawn. A config's entries point at people by KUID, so a rename leaves them nothing to put right.
  --
  UsersChanged = function(self)
    if (not konfer.initialised) then
      return
    end

    konfer:RefreshUsers()
    konfer:RefreshAllMemberLists()
  end,

  --
  -- The player set whose alt KUID is, in Kore's own editor, where there is no config in hand. The link is one fact that every
  -- config reads, so every config this player administers that holds them carries it to the rest of the raid.
  --
  UserMainChanged = function(self, kuid)
    if (not konfer.initialised) then
      return
    end

    konfer:SendUserEverywhere(kuid)
  end,

  --
  -- One of Kore's windows is opening, WHO saying which. The user editor stands in for the foyer rather than sitting over it,
  -- so the foyer goes away while it is up, and the policy window is left alone, being a different room and not the one the
  -- editor replaces. What another client would change about the people we know interrupts whichever of the two is up.
  -- Whatever went away for WHO is kept on this table and put back when that window closes, and saying so is what gets it
  -- put back. Kore has no idea this mod has windows and never needs to.
  --
  StandAside = function(self, who)
    local wins = (who == "offers") and { konfer.foyerwin, konfer.mainwin } or { konfer.foyerwin }
    local away = {}

    for _, win in ipairs(wins) do
      if (win and win:IsShown()) then
        win:Hide()
        tinsert(away, win)
      end
    end

    self.away = self.away or {}
    self.away[who] = away

    return #away > 0
  end,

  ComeBack = function(self, who)
    local away = self.away and self.away[who] or {}

    for _, win in ipairs(away) do
      win:Show()
    end

    if (self.away) then
      self.away[who] = nil
    end
  end,
})

--
-- Konfer "global" variables. All variables, whether they can be nil or not, that can possibly be set in the konfer
-- namespace, must be listed here, along with their default value. A description of what the variable controls and which user
-- interface element is affected by the variable must accompany each such global variable. This includes variables used in
-- other files. They must all be declared and described here.
--

--
-- The version number of this release of Konfer. This is set by the prep script when it sets MINOR above. For debug /
-- development releases this is always set to 1. This is used in the version check code as well as the mod info display and
-- mod registration.
--
konfer.version = MINOR

--
-- The Konfer "protocol" version number. This versions the *events* Konfer sends and understands, and their arguments. It
-- says nothing about the wire format. The framing, checksum and serialisation belong to Kore and are versioned separately by
-- KC.WIRE_VERSION. A change to one must never require a change of the other.
--
-- A message from a protocol higher than ours is refused, and tells us this copy of the mod is the stale one. Anything at or
-- below ours is accepted, so a newer mod goes on understanding an older one. There is no conditional decoding anywhere yet
-- because there has only ever been one version; the version check itself is always sent at protocol 1 so that the two ends
-- can always tell each other what they are running.
--
konfer.protocol = 1

--
-- A Kore message is a version letter, a checksum and a payload Kore never looks into. Nothing in it is this mod's, so
-- everything this mod needs said about a message it says inside that payload, in the four values every one of them starts
-- with: this protocol version, the endpoint that sent it, the command, and the config it is about or false for none.
--
-- CMD_MOD is what stands in the endpoint slot for the mod itself, which has no handle of its own to give. A policy uses its
-- handle, so no policy may take this one.
--
konfer.CMD_MOD = "*"

--
-- The shape of a config broadcast, which is a whole config in one message rather than an event, and is therefore versioned
-- separately from the events above. A receiver reads this to decide whether it understands the message at all. It never
-- decodes one shape as though it were another.
--
konfer.BCAST_VERSION = 1

--
-- The format and "shape" of the Konfer stored variables database. As various new features are added or bugs fixed, this
-- changes. The code in the file Utility.lua (konfer:UpdateDatabaseVersion()) brings older databases up to the current
-- version. Once a database has been upgraded it cannot be reverted. There is only one format so far, so that function has
-- nothing to convert yet.
--
konfer.dbversion = 1

--
-- Whether or not Konfer has been fully initialised. This can take a while as certain bits of information are not immediately
-- available on login. None of the event handlers or callback functions except those participating in actual initialisation
-- should execute if this is false.
--
konfer.initialised = false

-- Maximum number of disenchanters that can be defined in a config
konfer.MAX_DENCHERS = 3

--
-- The highest place a guild rank may be given in a config's rank order, edited in the Rank Order dialog on the Config page's
-- Admin tab. A guild has at most ten ranks, so a place and a rank index cover the same ground and every rank can be given a
-- place of its own where that is wanted. A rank the order says nothing about stands at 1, so an order nobody has touched
-- puts the whole guild level and a filter run against it admits every member of it. See cfg:RankOrder.
--
konfer.MAX_RANK_ORDER = 10

--
-- The shortest a config or roll list may be named, checked by konfer:NameTooShort wherever the player types one. Anything
-- else about a name still goes.
--
-- A name is how a list or config is told apart on screen, in an announcement and in an export, and one or two characters
-- says too little to do that. A name arriving from another admin is taken as it stands whatever its length. A config we
-- disagree with the spelling of is still that config, and refusing it would leave the two sides holding different lists.
--
konfer.MIN_NAME_LEN = 3

--
-- What a whisper to an admin must start with to be a command, "!ms" rather than "ms". A plain word is somebody talking,
-- and is neither answered nor hidden. Anything that tells a player what to whisper builds it with konfer:WhisperCommand.
--
konfer.WHISPER_PREFIX = "!"

--
-- Who an item goes to without any bid or roll, kept in an item's autoassign. An item given to nobody that way has no
-- autoassign at all, and AUTOASSIGN_NOBODY is what stands for that in the item editor and on the wire. An item for the
-- enchanter goes to the master looter when no enchanter can take it. Either is offered like any item, and picking it asks
-- the master looter whether to hand it over (put_autoassign in Loot.lua).
--
konfer.AUTOASSIGN_NOBODY    = 0
konfer.AUTOASSIGN_ENCHANTER = 1
konfer.AUTOASSIGN_ML        = 2

--
-- The names of the main window's pages and tabs. A PAGE is one of the buttons along the bottom of the window and is a whole
-- screen. A TAB is one of the buttons along the top of a page. KoreUI addresses both by name and never by position, so that
-- a page or tab can be shown, hidden, added or removed without disturbing any other. These constants exist only so that a
-- typo is a nil rather than a silently wrong page.
--
-- The names must match the keys used in the page tree in Init.lua.
--
konfer.LISTS_PAGE = "lists"
 konfer.LISTS_MEMBERS_TAB = "members"
 konfer.LISTS_CONFIG_TAB  = "config"
konfer.RAID_PAGE = "raid"
 konfer.RAID_RAIDERS_TAB = "raiders"
konfer.LOOT_PAGE = "loot"
 konfer.LOOT_ASSIGN_TAB  = "assign"
 konfer.LOOT_ITEMS_TAB   = "itemedit"
 konfer.LOOT_HISTORY_TAB = "history"
 konfer.LOOT_TRADES_TAB  = "trades"
konfer.USERS_PAGE = "users"
konfer.SYNC_PAGE = "sync"
konfer.CONFIG_PAGE = "config"
 konfer.CONFIG_LOOT_TAB  = "loot"
 konfer.CONFIG_ADMIN_TAB = "admin"
konfer.OPTIONS_PAGE = "options"

--
-- Constants used to define the index into each table element for the loot history.
--
-- HOW says whose entry it is. Upper case is the platform's, the ways an item leaves that mean the same in every policy (a
-- roll, disenchanting, a BoE to the master looter, an undo), and lower case is the policy's own, an award that means
-- something only to it. LIST is the list the item was given out on, in every row whoever owns it, and false for an item
-- given out with no list at all. PDATA is whatever the owner of HOW keeps beside it, which the other never looks inside:
-- nothing yet for the platform, and for a policy whatever its HistoryEntry returned, drawn back by its HistoryText (see
-- Policy.lua).
--
konfer.HIST_WHEN   = 1
konfer.HIST_WHAT   = 2
konfer.HIST_WHO    = 3
konfer.HIST_HOW    = 4
konfer.HIST_LIST   = 5
konfer.HIST_PDATA  = 6

-- The least time, in seconds, between two broadcasts of a config's loot history by the master looter (LHBCS, cfg.histsent).
-- A development copy, its revision 0, has none, so that a broadcast can be tried again at once.
konfer.HISTORY_BCAST_GAP = (MINOR == 0) and 0 or 300

-- The time, in seconds, every Broadcast button stays dark after a config is broadcast, a whole config being a lot to send.
konfer.BCAST_GAP = 30

--
-- Everything that is about the raid going on now, under the one active policy and its one config. Reservations, the undo
-- stack, who has been warned about what, which loot has been announced or opened, who of the config is here, who of the
-- raid the config has never heard of, which disenchanters are online, and what is on the corpse.
--
-- One table rather than a scattering of variables, so that ending a raid or changing the active policy or its config is
--
--   konfer:EmptyRaid()
--
-- and is complete by construction. A field missed out of a dozen separate resets is yesterday leaking into today; a field
-- missed out of this one does not exist. **It is emptied, never set to nil**, because every member is read as
-- konfer.raid.something and half the mod asks whether one of them is there at all.
--
-- Some of these are remembered and some are counted afresh on every walk of the group, and that difference decides nothing
-- about where they live: both are about this raid and both go when it does. Each member is documented where it is first
-- set below.
--
-- It is the record of one group, the one whose id Kore keeps (KRP.group_id), and is saved as konfer.chardb.raid, so that a
-- reload in the same group, or a login back into it after the connection dropped, starts from where it was. A record kept
-- for any other group, or for none, is thrown away at startup, and so is what was on the corpse, a reload closing the loot
-- window. It is only ever a starting point. Everything the game says about the group is read from the game, never from
-- here; whatever is counted from the group is counted again on the next walk of it; and what the raid has agreed is asked
-- for again (REQRS), the answer replacing what was kept.
--
-- Anything that differs per policy does not belong here. That lives on the policy, in konfer.policies[handle]. Anything
-- that outlives a raid does not belong here either, and a uid is the one thing that looks like it might: the uids in here
-- are the active config's, and mean nothing outside it, which is exactly why they are cleared with the raid rather than
-- kept at mod level.
--
konfer.raid = {}

--
-- The id of the group this record is for, Kore's KRP.group_id, nil while there is no group or the game has not said which.
-- A record with none is never saved. See konfer:EmptyRaid and krp_group_id_changed.
--
konfer.raid.group = nil

--
-- Maps Konfer uid to full player name for the members of the current group, and holds nothing else -- it is an index, not a
-- user list. KRP keeps the raid itself, keyed by name, and Kore knows nothing about Konfer uids, so this is the reverse
-- direction. A uid answers "is that user in the raid?" in one lookup, and the name it yields indexes KRP.players for the
-- detail. The forward direction needs no table, because player.konfer_uid is stamped onto the KRP record as the group is scanned.
--
-- Only raiders who have a uid in the config appear here; the rest are in konfer.raid.missing. The uid is the one for the
-- character actually in the raid, so for an alt it is the alt's uid, and any code that cares must check.
--
-- Those uids belong to the active policy's config, since a uid means nothing outside the config that issued it. This still
-- lives at mod level rather than on the policy because there is exactly one raid and exactly one active config, so there is
-- only ever one such map to hold.
--
konfer.raid.uidmap = nil

--
-- Tonight's disenchanters, konfer.MAX_DENCHERS of them and never more. They start as the config's, in cfg.settings.denchers,
-- and stay the config's until somebody with the standing to says otherwise, which is what konfer:SetRaidDencher is for.
-- Pointing one of the three at somebody else is a decision about this raid and changes nothing in the config: who a config's
-- enchanters are is a config admin's to say, and the person handing loot out is frequently neither.
--
-- Shared with the rest of the raid, so it is one of konfer.raidshared.
--
konfer.raid.denchers = nil

--
-- Which of tonight's three are actually here and online, in the order they were named, which is the order they are offered
-- in. Counted afresh by konfer:UpdateDenchers on every walk of the group rather than decided, so it travels nowhere. Empty
-- rather than nil when there is no raid, so that counting it needs no guard.
--
konfer.raid.denchersonline = {}

--
-- Collecting the group's loot where the game has no master loot (GroupLoot.lua). COLLECTING is true on the leader's client
-- once they have pressed Consent, and it collects while they lead. COLLECTOR is who asked this client to consent, which on
-- the leader's own is themselves. CONSENT is the collector this client consented to, by name. CONSENTS is every answer
-- heard, by name, "yes", "guild" or "no", and ASKED, on the leader's client, everybody asked. All of it is this group's and
-- goes with it, a reload in the same group keeping it with the rest of the record.
--
konfer.raid.collecting = nil
konfer.raid.collector = nil
konfer.raid.consent = nil
konfer.raid.consents = nil
konfer.raid.asked = nil

--
-- Where somebody stands in the raid's chain of authority, 1 being the highest, as konfer:RaidRank answers it.
--
-- The people who set a raid up did it for whoever ends up running loot, and are frequently not in the raid at all, so the
-- master looter is on this list to answer for the raid when nobody above them is in it and is deliberately below everybody
-- who may change anything. konfer:MaySetRaidSetting draws that line, at RAIDRANK_LEADER.
--
konfer.RAIDRANK_GM     = 1
konfer.RAIDRANK_OWNER  = 2
konfer.RAIDRANK_LEADER = 3
konfer.RAIDRANK_ML     = 4

--
-- Which of konfer.raid the whole raid agrees on rather than works out for itself. These are decisions about tonight, and
-- they travel: REQRS asks for them on joining, and again when the config loot runs against changes, and ACKRS carries the lot.
--
-- Everything else in konfer.raid is derived from this client's own view of the group, and sending one client's view to
-- another that can see the group perfectly well itself would be worse than useless. Add a key here only when it is
-- something somebody decided, never something counted.
--
konfer.raidshared = { "reserved", "denchers" }

--
-- Handle to the return value from database initialisation. This is set early on in the initialisation process. No code other
-- than that initialisation code should ever touch this.
--
konfer.db = nil

--
-- The faction and realm database. This is the root of all stored configuration variables and is set during initialisation.
-- This is a convenience alias for konfer.db.factionrealm.
--
-- Several of its fields are about the policies rather than about any config, and are shared by every character on the realm.
-- These are statements about the mod.
--
--   policyorder     Display order the user has set, as handle -> position. Either empty or complete: see konfer:SetPolicyOrder.
--   policydisabled  Set of policy handles switched off, keyed by handle with a value of true. A disabled policy is offered nowhere.
--                   See konfer:IsPolicyDisabled.
--   activepolicy    Handle of the active policy, restored at startup. See konfer:ActivatePolicy.
--   suspended       True while the whole mod is suspended with /konfer suspend.
--   dbversion       The shape of this database. See konfer.dbversion.
--   <handle>        Each policy's own tables, under its handle. Its configs and the config it last had in hand. See
--                   konfer:PolicyDB. Which is why a policy's handle may not be any of the names above, which
--                   konfer.FRDB_RESERVED lists.
--
-- The people are not here. A character's class, race, level, specs and professions are facts about the game's own
-- characters rather than about this mod, so they live once, in Kore's own database, as K.frdb.users and read through
-- KU.users.
--
konfer.frdb = nil

--
-- The names at the top of frdb that are the mod's own, and so can never be a policy's handle. A new one goes in here as well
-- as in the list above.
--
konfer.FRDB_RESERVED = {
  policyorder = true,
  policydisabled = true,
  activepolicy = true,
  suspended = true,
  dbversion = true,
  users = true,
  blockedsenders = true,
}

--
-- Storage for the whole account, every faction, realm and character alike. A convenience alias for konfer.db.global, which
-- AceDB keeps inside KonferDB. Nothing in it is about any config or any policy, and nothing is kept in it at present.
--
konfer.globaldb = nil

--
-- Per-character storage. A convenience alias for konfer.db.char. AceDB creates this scope on demand and keys it by
-- character, inside KonferDB, so nothing here needs a SavedVariable of its own. Everything in it is a local preference of
-- this one character and is never sent to anybody, but for the raid record, which is this character's own copy.
--
--   raid            The record of the group this character is in, konfer.raid itself, there only while it has a group id to
--                   be kept against. See konfer.raid.
--   winpos          Where each of the mod's windows was last put and how big it was, keyed by the window's frame
--                   name, as { point, relpoint, x, y, width, height } relative to UIParent. See konfer:KeepWindowPlace.
--   specsasked      True once the player has accepted the dialog asking which specs, the roles they raid in, and which
--                   professions this character reports (see RaidInfo.lua), which is asked at every login until they do. Only
--                   *whether they were asked* is here. What they answered is a fact about the character rather than about
--                   this mod, so it is Kore's and lives in K.chardb, read with K.MyRoles and K.MyProfessions and written with
--                   K.SetMyRoles and K.SetMyProfessions.
--   noautoopen      True once the player has said on the Options page not to have the loot window open by itself when the
--                   master looter opens a corpse, in a config they are no admin of. Unset, it opens.
--   nolootips       True once the player has said on the Options page not to be shown an item's tooltip in the loot list,
--                   in a config they are no admin of. Unset, it is shown.
--   recordhistory   True once the player has asked, on the Options page, to keep the loot history of a config they are no
--                   admin of as loot is handed out (LHADD). Off unless they do, it being a great deal to keep unasked.
--   ignorehistory   True once the player has answered Never to a loot history an admin broadcast (konfer:OfferLootHistory),
--                   or ticked the same on the Options page: such broadcasts are then ignored without asking.
--   untestednotice  True once this character has been warned that Konfer is untested on retail. See
--                   konfer:ShowUntestedNotice.
--
konfer.chardb = nil

--
-- A config's map of the people it holds, cfg.uids, keyed by the uid. The uid is the config's own, four hex characters minted
-- by CreateNewUser, and means nothing outside that config. The same character can have a different uid in every config they
-- are in, and the width is fixed because a whole list travels the wire as its uids run together, split back apart four at a
-- time by konfer:SplitRaidList.
--
-- The uid is the config's name for a person: every copy of the config shares it, and every event inside the config names
-- people by it. Kore's name for the same person is their KUID, which is this client's own and never travels, so each copy
-- of a config maps its uids to its own client's KUIDs, and the Name, which is the only thing two clients share outside a
-- config, appears only where something insists on one: the game's own APIs, a whisper, a chat announcement, a line on
-- screen, and the wire wherever a person is spoken of with no config in common. Each of those converts at the doorway.
--
-- Each entry is a positional array indexed by the CFGUSER_ constants.
--
--   CFGUSER_KUID       This client's KUID for the person, which is how the entry reaches everything Kore knows of them,
--                      their Name included (KU.kuids). It never leaves this client: a copy of the config elsewhere holds
--                      its own client's KUID for the same uid.
--   CFGUSER_ENCHANTER  True when they are a raid enchanter in this config, nil otherwise.
--   CFGUSER_FROZEN     True when their place on this config's lists is frozen, nil otherwise.
--   CFGUSER_PDATA      What the config's policy keeps about them, any value it likes, or nil for nothing. The platform
--                      stores it, sends it in MDUSR, a broadcast and a sync, and never looks inside it (cfg:UserPData).
--
-- Everything after the KUID is this config's own view of the user.
--
konfer.CFGUSER_KUID      = 1
konfer.CFGUSER_ENCHANTER = 2
konfer.CFGUSER_FROZEN    = 3
konfer.CFGUSER_PDATA     = 4

--
-- The number of raiders currently in the raid group that are missing from the users list, and the actual list of such
-- missing players. Each entry in the missing table is itself a table with the members "name" and "class", where "name" is
-- the full player-realm name of the player and class is the Kore class number (for example K.CLASS_DRUID) of the missing
-- player. These are set to 0 and nil respectively when not in a raid.
--
-- This is the one table in the mod keyed by character name rather than by uid, because it holds exactly the people the
-- config has issued no uid for. Adding one of them is what moves them into konfer.raid.uidmap, where the key is the uid.
--
-- Like konfer.raid.uidmap these are not remembered but counted, against the active policy's config, on every walk of the group,
-- so they are outside konfer.raid and come back right for another config with the group walk every FullRefresh makes.
--
konfer.raid.nmissing = 0
konfer.raid.missing = {}

--
-- The items on offer in the loot window the master looter has open, or nil when there is none, in the order they are shown.
-- Each is a table: itemid and ilink, the loot slot (0 on a raider's client, where the item is only described), quant and the
-- rest that Loot.lua keeps alongside, documented there with the selected item. It belongs to the loot session, which ends
-- when the loot is closed, the group is left or the session's config stops being the active one.
--
konfer.raid.bossloot = nil

--
-- True once becoming master looter in this group has offered what it offers, to suspend Konfer for another loot addon and
-- to open the foyer (konfer:BecameMasterLooter), so that master loot handed away and back asks nothing more, and nor does a
-- reload. It goes with the group, and is kept through a change of config, which is so often the answer to it.
--
konfer.raid.mlasked = nil

--
-- Items Konfer knows how to treat before any config says anything, keyed by item id. Currencies and the like to ignore. Filled
-- in by Items.lua and never changed.
--
konfer.iitems = {}

--
-- The mod's settings window, built by Settings.lua.
--
konfer.settingswin = nil

--
-- What a config can do. A config is an object: its data is the table the database saves, and everything that acts on one is
-- a method here, reached through the metatable konfer:MakeConfig puts on it. Every file that has methods to contribute
-- takes `local cfgm = konfer.configmethods` at the top and writes into it, the way each file writes into konfer itself.
--
-- A metatable is not saved, so a config coming back out of the database is a plain table until MakeConfig has been over it.
-- konfer:SetConfig is the one choke point every config is filed through and konfer:MakeAllConfigs walks the lot at startup,
-- so the only way to hold one without methods is to build a table and never file it.
--
konfer.configmethods = {}

local cfgm = konfer.configmethods

--
-- Set to true if the main Konfer window was automatically opened.
--
konfer.autoshown = nil

--
-- For konfer.BCAST_GAP seconds after this client broadcast a config, whichever it was, the timer that ends the wait, every
-- Broadcast button dark meanwhile (cfg:Broadcast). This session's alone and never saved.
--
konfer.bcastwait = nil

-- @debug-start@
--
-- True while /konfer testloot has made up some loot to look at the Assign loot tab with. This client plays master looter
-- for it, nothing it would say about the loot leaves the machine, and nothing is handed out. See konfer:TestLoot. A
-- development copy's alone: a packaged one has no testloot, and what asks after it finds it nil.
--
konfer.testloot = nil
-- @debug-end@

--
-- The character info check's window (CharInfo.lua), built the first time a check is asked for and kept afterwards, because
-- WoW cannot destroy a frame and one window is all a check ever needs. It holds the answers to the check it is showing, so a
-- reply that arrives for an older one is put in it and a reply from somebody nobody asked is not.
--
konfer.cidlg = nil

--
-- Every registered loot distribution policy, keyed by policy handle, and the number of them. Policies are Suicide Kings,
-- EP/GP, DKP, Loot Council and the PUG tool. They are not addons. They register with Konfer itself, via
-- konfer:RegisterPolicy() in Policy.lua, because Konfer is the layer that knows about distribution policy. A policy owns
-- presentation and ordering semantics only. All of the data belongs to Konfer.
--
-- Each is also its own endpoint on the wire, registered with KoreComms, which neither knows nor cares that it is a policy.
-- They share the mod's one prefix, and the envelope names each by its handle, which is what this table is keyed by, so the
-- dispatcher in Comms.lua looks a message's policy up here and a policy's messages reach that policy and nothing else.
--
konfer.policies = {}
konfer.npolicies = 0

--
-- What EP/GP and DKP share, filled in by Policies/Points.lua: earning points, decaying them, the journal of both, and the
-- price of an item. Neither policy is a special case of the other; each hands points:Setup its own words and event names
-- and gets the shared half built onto it. See that file.
--
konfer.points = {}

--
-- What PUG and Loot Council share, filled in by Policies/Tally.lua: what tonight's wins have cost each raider, the +1s and
-- decay of a roll, kept on the config's raid. Each hands tally:Setup its own event names and gets the shared half built onto
-- it, as the points policies do. See that file.
--
konfer.tally = {}

--
-- The standard event set: the immediate and recorded handlers a policy answers unless its own Comms.lua says otherwise.
-- Filled in by Comms.lua and copied onto every policy by konfer:RegisterPolicy(), so that each policy has tables of its own
-- to add to, replace in or remove from. Which events a policy accepts is the policy's own, and so is the name the envelope
-- carries them under. konfer.protocol stays one flat number for all of them.
--
-- The handful of messages that are the mod's rather than any policy's are not here. Comms.lua keeps them to itself.
--
konfer.std_ihandlers = nil
konfer.std_ehandlers = nil

--
-- Where Konfer's own artwork lives. The policy logos, icons and command plaques and the foyer's background. WoW
-- takes a texture path without its extension, so this is prepended to a bare name.
--
konfer.TEXTURE_PATH = "Interface\\Addons\\" .. addonName .. "\\Textures\\"

--
-- The accent the foyer wears, its gold being the one colour in the mod that belongs to no policy. A policy's own is its
-- descriptor's accent. The kit's yellow gold, which stands clear of PUG's amber, and fully saturated, since the kit
-- multiplies by it and multiplying can only darken.
--
konfer.COLOR_FOYER_ACCENT = KUI.DEFAULT_ARTWORK_COLOR

--
-- The tint every window in the mod wears, the same whatever policy it is showing. The kit's yellow gold, drawn over the
-- metal the usual way, which is what an untinted dialog wears. Only the window's header wears the policy's accent against
-- it, its portrait frame and its title plaque with the plaque's gem, and every other gem is the kit's sapphire.
-- COLOR_UI_TINT_FLAT set true draws the tint multiplied over the metal instead, which a dark tint such as charcoal needs to look
-- dark rather than like light steel.
--
-- This is the mod's main tint and nothing writes a gold of its own: anything that wants it says so by name, here or through
-- the kit's KUI.DEFAULT_ARTWORK_COLOR, so that changing it is changing one number.
--
konfer.COLOR_UI_TINT = KUI.DEFAULT_ARTWORK_COLOR
konfer.COLOR_UI_TINT_FLAT = false

--
-- Where in a page's top bar a line of text sits, such as the Users page's selected user and the Sync page's checksum: in the
-- middle of the bar, which is where the config selector's middle is, so the two line up. Every page puts its text there.
--
konfer.TOPBAR_TEXT_Y = "MIDDLE"

--
-- The longest a config space's name may be. Every box that names a config is bounded by this, so that a name always fits
-- where it is shown. The foyer's config list, the window's config selector, the sync panels. Rather than each of them
-- having to cope with a name of any length at all.
--
konfer.CONFIG_NAME_MAX = 32

--
-- Where a config's traffic goes, which is what cfg.channel holds. The guild's addon channel, or the group the player is in.
-- Absent or unrecognised means CHANNEL_OTHER, and so does GUILD for a player who is not in one. A policy's own CSendAM and
-- CSendChannelAM are the only things that read it -- see RegisterPolicy.
--
konfer.CHANNEL_GUILD = 1
konfer.CHANNEL_OTHER = 2

--
-- The policy a config space falls back to when it names none, which is the case for every config written before policies existed.
--
konfer.DEFAULT_POLICY = "sk"

--
-- Added to the sort order of every policy that did not ship with Konfer, so that the ones in the box keep the order they
-- were designed in and an addon cannot put itself above them by asking for zero. See RegisterPolicy.
--
konfer.POLICY_EXTERNAL_BASE = 100

--
-- True once every policy Konfer ships with has registered, which is what makes the next one to register an external policy.
-- Set at the top of Init.lua, the last file in the TOC. An addon that registers a policy had to name Konfer as a dependency
-- to reach RegisterPolicy at all, so it loads after that point.
--
konfer.builtins_registered = false

--
-- The active policy, the one that arms for loot. Exactly one policy is active at a time and no policy has any say in which
-- one it is. Abbreviated because almost everything in Konfer reaches its config through this, so the full word would be
-- several hundred repetitions of noise.
--
-- There is deliberately no mod-wide current config. A current config is meaningful only inside a policy, and an inactive
-- policy goes on holding the one it last had so that switching back to it lands where it was left. The config the platform
-- is working on is therefore always the active policy's, reached as konfer.apol.cfg with its id in konfer.apol.currentid.
--
-- Only konfer:ActivatePolicy changes this once the mod is running, and the choice is remembered in frdb.activepolicy.
--
konfer.apol = nil

--
-- The one window. Every page in it is the mod's and is built once. What a policy contributes is panels within those pages,
-- and only the active policy's are shown. See konfer:InitialiseMainWindow and konfer:BuildPolicyUI.
--
-- It is nil until the UI is built, and on a client where every policy is switched off it is built and never has a policy to show.
--
konfer.mainwin = nil

--
-- The handful of that window's widgets the platform reaches from files other than the page that built them. The sync CRC
-- plate, the broadcast button, the guild rank dropdowns, the config selector. Each page publishes its own here as it builds
-- them, and everything a page only needs for itself stays private to that page. Nil until the window is built.
--
konfer.qf = nil

--
-- Whether a policy's own panels are built for every policy when the window is, or only for a policy when it first becomes active.
--
-- Lazy is what ships. A user who only ever runs Suicide Kings should not pay for four sets of panels they will never see,
-- and the panels are unreachable until their policy is the active one, so there is nothing to build them for.
--
-- Eager is for development. Lua finds an error in a function only when it runs it, so a fault in a policy's Construct sits
-- undiscovered until somebody switches to that policy, which may be weeks. Building all of them at startup puts every one of
-- those faults on screen at login instead.
--
konfer.EAGER_POLICY_UI = false
konfer.EAGER_POLICY_UI = true -- @debug-delete@

--
-- The default values for a new configuration, and the whole list of the settings that are the platform's. A policy's own
-- are its descriptor's defaults and live in cfg.psettings rather than here, so nothing a policy invents can collide with
-- anything in this table and neither side has to read the other's. See cfg:PolicySettings.
--
-- A setting is read and written by its name, cfg.settings.auto_bid, and is stored as a character in one of two strings.
-- konfer:MakeConfig in Config.lua is what puts those two things together. The order below IS the storage format.
--
-- **Only ever append to these two lists.** A position is what a stored string means, so inserting or reordering one
-- silently reinterprets every config already saved and every one in flight. A setting that goes away keeps its slot, which
-- costs one character. If the format has to change in some way appending cannot cover, that is a dbversion convert in
-- Utility.lua and Kean's word before the number moves.
--
-- Every setting that is a yes or no, in the order they stand in cfg.opts, one character each, Y or N.
--
konfer.copts = {
  -- General
  { "auto_bid", true },
  { "silent_bid", false },
  { "tooltips", true },
  { "chat_filter", true },      -- Enable chat message filter
  { "history", true },          -- Record loot history
  { "hide_absent", false },     -- Read by nothing, its slot kept: the loot page shows only who is in the raid
  { "auto_loot", true },
  { "boe_to_ml", true },        -- Assign BoE items to Master-Looter
  { "disenchant", true },       -- Assign to disenchanter

  -- What is said out loud
  { "ann_bidchanges", true },
  { "ann_winners_raid", true },
  { "ann_winners_guild", true },
  { "ann_bid_progress", true },
  { "ann_bid_usage", true },
  { "ann_roll_usage", true },
  { "ann_countdown", true },
  { "ann_roll_ties", true },
  { "ann_cancel", true },
  { "ann_no_bids", true },
  { "ann_missing", true },

  -- Rolls
  { "offspec_rolls", true },
  { "vanity_rolls", false },
  { "transmog_rolls", false },

  -- Guild ranks
  { "rank_filter", false },     -- Whether guild rank filtering is offered at all

  -- Bids: the kinds taken beside main spec, and which kind outranks which. A policy reads the second four as it sees fit.
  { "offspec_bids", true },
  { "transmog_bids", true },
  { "vanity_bids", true },
  { "main_over_offspec", true },
  { "offspec_over_transmog", true },
  { "offspec_over_vanity", true },
  { "transmog_over_vanity", false },

  -- Whether bids are timed, closing bid_timeout seconds after they open as a roll does. Off, they close when the master
  -- looter says so.
  { "bid_timer", false },
}

--
-- Everything else, in the order they stand in cfg.vals, which is one field per entry with a colon between them. Neither a
-- list id nor a uid can hold a colon: KC.CreateNewID answers hex and a uid is one character of the admin alphabet and three
-- hex digits, so the separator is safe against every value that goes in here.
--
-- The third column says how one is written. "number" and "string" are themselves; "uids" is konfer.MAX_DENCHERS slots of
-- four characters each, an empty slot being four hyphens, which no uid can be; "places" is konfer.MAX_RANK_ORDER slots of
-- one digit each, a rank's place written as place - 1 so that ten fits in a single character.
--
konfer.cvals = {
  { "announce_where", 0, "number" },
  { "roll_timeout", 10, "number" },
  { "roll_extend", 5, "number" },
  { "def_list", "0", "string" },  -- The roll list a drop is bid on when nothing names another
  { "denchers", {}, "uids" },
  { "rank_order", {}, "places" },  -- Guild rank index to its place in the order, 1 to konfer.MAX_RANK_ORDER
  { "bid_timeout", 15, "number" }, -- How long bids stay open where bid_timer says they are timed
  { "bid_extend", 5, "number" },   -- A bid with less than this left puts the close back to this far off
}

--
-- The default value of every setting, by name, built from the two lists above so that there is one place a default is
-- written down. What a new config starts from, and what tells a caller whether a name is a setting at all.
--
konfer.defaults = {}

for _, v in ipairs(konfer.copts) do
  konfer.defaults[v[1]] = v[2]
end

for _, v in ipairs(konfer.cvals) do
  konfer.defaults[v[1]] = v[2]
end

--
-- The foyer window handle, which is a KUI dialog frame. This is the mod as a whole. It is never called a page. A page is a
-- button along the bottom of the policy window, which is a different thing entirely, reached by a policy's own slash command.
--
konfer.foyerwin = nil

--
-- The global popup window. There can only be one popup window active at a time and if that window is currently up, this will
-- be the frame for it. Otherwise it is nil.
--
konfer.popupwindow = nil

--
-- This mod's descriptor for KoreComms: who we are and which kinds of group our own messages may reach. KC.RegisterComms
-- reads it and injects the comms methods. It is set at the foot of this file rather than here because it reads the version
-- and the localised names above, and because it is the last thing built before the mod registers. Each policy has one of
-- its own, described from its own raid, party and bg by konfer:RegisterPolicy.
--
konfer.comms = nil

-------------------------------------------------------------------------------

local admin_hooks_registered = nil
local ml_hooks_registered = nil
local chat_filters_installed = nil
local sentoloot = nil

local ucolor = K.ucolor
local ecolor = K.ecolor
local icolor = K.icolor

local function debug(lvl,...)
  K.debug(L["MODNAME"], lvl, ...)
end

--
-- The mod's own voice, for the things that genuinely belong to the mod rather than to one of the policies living inside it:
-- the foyer, the settings window, suspend and resume, the version banner. Anything about a config, a list, a user or an item
-- is a policy's business and is reported by that policy under its abbreviation. See pol:err() and pol:info() in Policy.lua.
--
--
-- The plate at the top of one of this mod's windows, "<KahLua> Konfer Suicide Kings". K.WindowTitle builds it and documents
-- the shape; this only says whose window it is. WHAT is optional, and without it the window is naming nothing but the mod,
-- which is what one has before it knows which policy it is showing.
--
function konfer:WindowTitle(what)
  return K.WindowTitle(nil, L["MODTITLE"], what)
end

--
-- A splash is a picture put up in place of whichever of the mod's windows is up, a policy's title card (ShowPolicySplash) or
-- the mod's own artwork (ShowAbout). MakeSplash readies FRAME, a button its caller built and named, once: on a strip STRIP
-- tall along its foot a title centred and under it the version at the left in white and who wrote it at the right in the
-- smallest gold, the two lines together in the middle of the strip and each end as far in as the strip is half tall. A
-- click or Escape puts it away and brings back the window it stood in for. It is centred on that window, or with TOP its top
-- that far below the top of the screen. One is up at a time, SPLASHUP.
--
local SPLASH_GAP = 2
local splashup = nil

function konfer:MakeSplash(frame, strip, top)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  local version = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  local by = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalTiny2")

  title:SetText(L["MODTITLE"])
  version:SetText(strfmt("%s %s", L["Version"], K.VersionString(self.version)))
  by:SetText(strfmt(L["by %s"], "Cruciformer"))

  local foot = (strip - title:GetStringHeight() - SPLASH_GAP - version:GetStringHeight()) / 2
  local half = strip / 2

  version:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", half, foot)
  by:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0 - half, foot)
  title:SetPoint("BOTTOM", frame, "BOTTOM", 0, foot + version:GetStringHeight() + SPLASH_GAP)
  frame.splashtitle = title
  frame.splashtop = top

  -- At the windows' strata, standing in for one of them.
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:Hide()
  tinsert(UISpecialFrames, frame:GetName())

  frame:HookScript("OnClick", function(this)
    this:Hide()
  end)
  frame:HookScript("OnHide", function(this)
    local win = this.splashover

    this.splashover = nil
    if (splashup == this) then
      splashup = nil
    end
    if (win) then
      win:Show()
    end
  end)
end

--
-- Puts FRAME up, the words EXTRA after the mod's name if there are any. A splash already up stands down for it without
-- bringing its window back, the new one standing in for that window instead.
--
function konfer:ShowSplash(frame, extra)
  local win = nil

  if (splashup) then
    win = splashup.splashover
    splashup.splashover = nil
    splashup:Hide()
  else
    for _, w in ipairs({ self.mainwin, self.settingswin, self.foyerwin }) do
      if (w and w:IsShown()) then
        win = w
        break
      end
    end
  end

  local title = strfmt("|cffff2222<%s>|r %s - %s", K.KAHLUA, L["MODTITLE"], L["Loot Distribution"])

  frame.splashtitle:SetText(extra and strfmt("%s %s", title, extra) or title)
  frame:ClearAllPoints()
  if (frame.splashtop) then
    frame:SetPoint("TOP", UIParent, "TOP", 0, 0 - frame.splashtop)
  else
    frame:SetPoint("CENTER", win or UIParent, "CENTER", 0, 0)
  end

  if (win == self.settingswin) then
    self:SettingsStandAside()
  end
  if (win) then
    win:Hide()
  end

  frame.splashover = win
  splashup = frame
  frame:Show()
  frame:Raise()
end

-- One of the mod's windows shown some other way while a splash is up: the splash goes, without bringing its own back.
function konfer:HideSplash()
  if (splashup) then
    splashup.splashover = nil
    splashup:Hide()
  end
end

--
-- What this mod says to the player, signed with the mod, "Konfer: ...", so that a line in the chat frame says where it came
-- from. Kore's own messages sign with KahLua (K.err), belonging to no mod in particular, and a policy signs with its
-- abbreviation, "KSK: ...".
--
local function err(msg, ...)
  local str = L["MODTITLE"] .. " " .. L["error: "] .. strfmt(msg, ...)
  printf(ecolor, "%s", str)
end

local function info(msg, ...)
  local str = L["MODTITLE"] .. ": " .. strfmt(msg, ...)
  printf(icolor, "%s", str)
end

--
-- The reporting and colouring helpers, on the namespace so that every other file takes its locals from here. Like the
-- libraries above these are aliases rather than state, which is why they are not in the block of global variables.
--
-- debug, err and info are this file's own, described above. The colours are Kore's, each wrapping a string in one, and the
-- class helpers are KoreParty's: class colours a name for the class given, aclass colours it whether or not the class is
-- known, and the short forms leave the realm off. A policy signs its own messages with pol:err and pol:info instead.
--
konfer.debug = debug
konfer.err = err
konfer.info = info

konfer.white = K.white
konfer.red = K.red
konfer.green = K.green
konfer.yellow = K.yellow

konfer.class = KRP.ClassString
konfer.shortclass = KRP.ShortClassString
konfer.aclass = KRP.AlwaysClassString
konfer.shortaclass = KRP.ShortAlwaysClassString

local white = K.white
local class = KRP.ClassString

-- Forward declaration; defined further down, used by chat_msg_whisper below.

-- cfg is known to be valid before this is called
local function get_my_ids(cfg)
  local uid = cfg:FindUser(K.player.name)
  if (not uid) then
    return nil, nil
  end

  local ia, main = cfg:IsAlt(uid)
  if (ia) then
    return uid, main
  else
    return uid, uid
  end
end

--
-- The whisper command KEY names, as a player types it: the prefix and whichever word answers to it. KEY is one of the
-- standard set, "bidM" or "standing", never a word: which word that is belongs to whichever policy is running, so anything
-- telling a player what to whisper asks here rather than reaching for a string of its own.
--
-- POL defaults to the active policy, whispers being answered by whichever policy is running the raid.
--
function konfer:WhisperCommand(key, pol)
  local pol = pol or self.apol
  local words = pol and pol.whisperwords and pol.whisperwords[key]

  return self.WHISPER_PREFIX .. ((words and words[1]) or "")
end

--
-- The word MSG asks for, without the prefix, and whatever follows it, or nil for a whisper that is not asking for anything.
-- Whether it is a word anybody answers to is not decided here: that is the running policy's vocabulary and is looked up
-- where it is answered. The argument is the handler's to make sense of: "!os 200" is an off spec bid, and 200 what was bid.
--
local function extract_cmd(msg)
  local lm = strlower(msg)
  lm = lm:gsub("^%s*", "")
  lm = lm:gsub("%s*$", "")

  local plen = strlen(konfer.WHISPER_PREFIX)

  if (strsub(lm, 1, plen) ~= konfer.WHISPER_PREFIX) then
    return nil
  end

  return match(strsub(lm, plen + 1), "^(%S*)%s*(.-)$")
end

--
-- A whisper that is one of ours is answered rather than shown, so it is taken out of the chat frame. One that is not is
-- somebody talking and is left alone, which is why this asks the policy's vocabulary rather than assuming any word.
--
local function whisper_filter(self, evt, msg, ...)
  if (not K.CanAccess(msg)) then
    return
  end

  local pol = konfer.apol
  local cmd = extract_cmd(msg)

  if (cmd and pol and pol.whisperword and pol.whisperword[cmd]) then
    return true
  end
end

--
-- Whether MSG is something we said. Everything the mod sends to another player is signed with the mod's name, and that
-- signature is what identifies one of ours coming back. Compared literally rather than as a pattern.
--
local function ours(msg, sig)
  return strfind(msg, sig .. ": ", 1, true) == 1
end

local function is_our_message(msg)
  return ours(msg, L["MODTITLE"]) or ours(msg, L["MODABBREV"])
end

local function reply_filter(self, evt, msg, snd, ...)
  if (not K.CanAccess(msg) or not K.CanAccess(snd) or not is_our_message(msg)) then
    return
  end

  if (evt == "CHAT_MSG_WHISPER_INFORM") then
    return true
  end

  if (K.CanonicalName(snd, nil) == K.player.name) then
    return true
  end
end

--
-- A Konfer line said in group chat by somebody else in the group, the master looter's announcements chief among them, is
-- for raiders without the mod. One running it is shown the line as one of Konfer's own instead, signed with the policy
-- running, with no raid chat copy and no raid warning across the screen. A chat filter runs once for every chat frame
-- showing the line, so the line is printed once, by its line id. A suspended Konfer leaves raid chat alone.
--
local relayed_line = nil

local function group_line(msg, snd)
  if (not K.CanAccess(msg) or not K.CanAccess(snd) or not msg or not snd or konfer:IsSuspended()
    or not is_our_message(msg)) then
    return false
  end

  local who = K.CanonicalName(snd, nil)

  return who ~= K.player.name and KRP.players and KRP.players[who] ~= nil and true or false
end

--
-- Lines kept from a raider running the mod and not shown to them again, as patterns: each format's words taken literally,
-- what it fills in left to match anything. BID_LINES are the master looter telling the raid of a bid made or retracted,
-- which a raider following the bid is shown as the master looter is (BIDAN). USAGE_LINES tell a raider without the mod how
-- to bid or roll, which one with it has buttons for.
--
local BID_LINES = { "%s: %s has bid %d (the highest bid is %d, by %s).", "%s: %s (%s) has bid (highest bidder is %s).",
  "%s: %s has retracted (highest bidder is %s).", "%s: %s has retracted (no other bidders)." }
local USAGE_LINES = { "%s: to bid on %s, whisper %s %s. For general help using %s, whisper an admin %s.", "%s: type %s." }
local line_patterns = {}

local function matches(msg, keys)
  local pats = line_patterns[keys]

  if (not pats) then
    pats = {}
    line_patterns[keys] = pats

    for _, key in ipairs(keys) do
      local p = string.gsub(L[key], "[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%0")

      p = string.gsub(p, "%%%%s", ".-")
      p = string.gsub(p, "%%%%d", "%%d+")
      tinsert(pats, "^" .. p .. "$")
    end
  end

  for _, p in ipairs(pats) do
    if (strfind(msg, p)) then
      return true
    end
  end

  return false
end

local function group_filter(self, evt, msg, snd, _, _, _, _, _, _, _, _, lineid)
  if (not group_line(msg, snd)) then
    return
  end

  if ((konfer:BidOpen() and matches(msg, BID_LINES)) or matches(msg, USAGE_LINES)) then
    return true
  end

  if (lineid == nil or lineid ~= relayed_line) then
    relayed_line = lineid

    local sig = ours(msg, L["MODTITLE"]) and L["MODTITLE"] or L["MODABBREV"]
    local pp = konfer.apol

    printf(icolor, "%s", ((pp and pp.shortnick) or L["MODTITLE"]) .. ": " .. strsub(msg, strlen(sig) + 3))
  end

  return true
end

--
-- Shown to a raider without the mod and kept from one running it, whose chat has the line already (group_filter). The
-- game's own raid warning frame is handed everything else as it always was, but for an admin's own lines while the chat
-- message filter is on, which it keeps off the screen as it keeps them out of chat (reply_filter).
--
local function relay_group_lines()
  local cf = ChatFrameUtil.AddMessageEventFilter

  for _, evt in ipairs({ "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" }) do
    cf(evt, group_filter)
  end

  local rwf = RaidWarningFrame
  local blizzard = rwf and rwf.GetScript and rwf:GetScript("OnEvent")

  if (blizzard) then
    rwf:SetScript("OnEvent", function(frame, event, message, sender, ...)
      if (event == "CHAT_MSG_RAID_WARNING" and (group_line(message, sender)
        or (chat_filters_installed and reply_filter(frame, event, message, sender)))) then
        return
      end

      return blizzard(frame, event, message, sender, ...)
    end)
  end
end

--
-- The whisper commands a raider can send, as the standard set every policy starts with.
--
-- What each one does is the platform's, because every policy has bidding, retracting, standing somewhere and being counted
-- as present. What each one is called is the policy's: Suicide Kings has asked people to whisper "suicide" for twenty years
-- and EP/GP would no more use that word than it would put it on a button. So the handlers are here and the vocabulary is in
-- konfer.std_whisperwords, which a policy overrides through its descriptor's Whispers.
--
-- Copied onto every policy at registration, exactly as the comms handler sets are, so a policy replaces the one it wants
-- done differently and removes the one it has no use for without touching what any other policy answers.
--
-- Each takes the policy, the sender's uid, their name, what the reply is signed with, the mod's name, and whatever followed
-- the command's word. The uid is there for everything but help, the dispatcher having already turned anybody it could not
-- find away.
--
-- A bid is not one of these. Each kind of bid is a whisper of its own, "!ms" or "!os", and Loot.lua adds them to both
-- tables from the table of kinds, which is where every kind is declared.
--
local function whisper_retract(pol, uid, sender, nick)
  return konfer:RetractBidder(uid)
end

--
-- Where they stand on every list of this config that holds them. Suicide Kings calls asking this "suicide"; the platform
-- calls it standing, and where somebody stands on a given list is cfg:ListPosition's answer, which walks whatever order
-- that policy puts its members in. The standing is said in the policy's words, PositionText's answer put in its
-- BID_STANDING, "position 3" for Suicide Kings and "PR 1.73" for EP/GP.
--
-- For each list: what they have and their rank among everybody on it, and among the raiders where a raid is running; then,
-- unless they lead it, what the leader has, and what the best placed member of their class has and at what rank, or that
-- it is them. Nobody is named. Somebody running the mod can simply look at the list.
--
local function whisper_standing(pol, uid, sender, nick)
  local cfg = pol.cfg
  local _, mycls = cfg:UserNameClass(uid)
  local cname = K.IndexClass[mycls] and K.IndexClass[mycls].c
  local sentheader = false
  local ndone = 0

  local function standing(listid, u, pos)
    local _, ptext = cfg:PolicyCall("PositionText", tostring(pos), listid, u, pos)

    return strfmt(pol:Str("BID_STANDING"), tostring(ptext))
  end

  for k, v in pairs(pol.sortedlists or {}) do
    local lp = cfg.lists[v.id]
    local apos, rpos = cfg:ListPosition(uid, v.id)

    if (apos) then
      ndone = ndone + 1

      if (not sentheader) then
        konfer:SendWhisper(strfmt(L["LISTPOSMSG"], nick, cfg.name, L["MODTITLE"]), sender)
        sentheader = true
      end

      local _, order = cfg:PolicyCall("Order", lp.users, v.id, lp.users)
      local mine = standing(v.id, order[apos], apos)

      if (konfer.raid.uidmap) then
        konfer:SendWhisper(strfmt(L["%s: you have %s on %q, which makes you rank %d of %d (#%d in raid)."], nick, mine,
          lp.name, apos, #order, rpos), sender)
      else
        konfer:SendWhisper(strfmt(L["%s: you have %s on %q, which makes you rank %d of %d."], nick, mine, lp.name, apos,
          #order), sender)
      end

      if (apos > 1) then
        local leader = standing(v.id, order[1], 1)
        local bpos = nil

        for i, u in ipairs(order) do
          local _, c = cfg:UserNameClass(u)

          if (not bpos and c == mycls) then
            bpos = i
          end
        end

        if (not cname or not bpos) then
          konfer:SendWhisper(strfmt(L["%s: the leader has %s."], nick, leader), sender)
        elseif (bpos == apos) then
          konfer:SendWhisper(strfmt(L["%s: the leader has %s, and you are the highest %s."], nick, leader, cname), sender)
        else
          konfer:SendWhisper(strfmt(L["%s: the leader has %s, and the highest %s has %s, at rank %d."], nick, leader, cname,
            standing(v.id, order[bpos], bpos), bpos), sender)
        end
      end
    end
  end

  if (ndone > 0) then
    konfer:SendWhisper(strfmt(L["%s: (End of list)"], nick), sender)
  else
    konfer:SendWhisper(strfmt(L["%s: you are not on any roll lists (yet)."], nick), sender)
  end
end

--
-- Somebody available to raid who is not in the group is counted as though they were, which is what reserving them does.
-- Asking twice is harmless and gets the same answer.
--
local function whisper_standby(pol, uid, sender, nick)
  pol.cfg:ReserveUser(uid, true)
  konfer:SendWhisper(strfmt(L["%s: you are now on standby."], nick), sender)
end

--
-- The words this policy actually answers to, rather than the ones the platform would have used, so that somebody told to
-- whisper "suicide" is told "suicide".
--
local function whisper_help(pol, uid, sender, nick)
  konfer:SendWhisper(strfmt(L["HELPMSG1"], nick, nick, nick), sender)

  -- The word for each kind of bid the config takes, and where a bid names an amount, that it does.
  konfer:SendWhisper(strfmt(L["HELPMSG2"], nick, konfer:BidUsage()), sender)
  konfer:SendWhisper(strfmt(L["HELPMSG3"], nick, konfer:WhisperCommand("retract", pol)), sender)
  konfer:SendWhisper(strfmt(pol:Str("HELP_STANDING"), nick, konfer:WhisperCommand("standing", pol)), sender)
  konfer:SendWhisper(strfmt(L["HELPMSG5"], nick, konfer:WhisperCommand("standby", pol)), sender)
end

konfer.std_whispers = {
  retract = whisper_retract,
  standing = whisper_standing,
  standby = whisper_standby,
  help = whisper_help,
}

--
-- What each is called when the policy says nothing. The first word of each is the one the help text tells people to use and
-- the rest are aliases that are still answered. The kinds of bid, "bidM" to "bidV", are added by Loot.lua.
--
konfer.std_whisperwords = {
  retract = { L["WHISPERCMD_RETRACT"] },
  standing = { L["WHISPERCMD_STANDING"] },
  standby = { L["WHISPERCMD_STANDBY"] },
  help = { L["WHISPERCMD_HELP"] },
}

--
-- A whisper command is about the raid that is running, so it is answered by the active policy, and signed with the mod's
-- name: which policy is running means nothing to the raider who asked.
--
local function chat_msg_whisper(evt, msg, snd, ...)
  -- On retail a whisper that arrives during a boss fight is a secret value, and is gone unread, as anything said then is.
  if (not K.CanAccess(msg) or not K.CanAccess(snd)) then
    return
  end

  local sender = K.CanonicalName(snd, nil)
  local cmd, arg = extract_cmd(msg)
  local pol = konfer.apol
  local nick = L["MODTITLE"]

  --
  -- The hook outlives a change of active policy until security is next worked out, and a policy with no config in hand has
  -- no raid to answer about.
  --
  if (not pol.currentid) then
    return
  end

  --
  -- A whisper is one of the few places somebody arrives as a character name, so it becomes a uid here and is one for the
  -- rest of its life. Everything below takes a uid and none of it has to know a name was ever involved.
  --
  local senduid = pol.cfg:FindUser(sender)

  if (not cmd) then
    return
  end

  --
  -- Which of the standard set the word they typed means, in the vocabulary of the policy that is running. A word no policy
  -- claims is somebody talking rather than somebody asking, and gets no answer at all.
  --
  local key = pol.whisperword and pol.whisperword[cmd]
  local fn = key and pol.whispers and pol.whispers[key]

  if (not fn) then
    return
  end

  --
  -- Everything but help is about this person, so somebody the config has never issued a uid for is told so once, here,
  -- rather than in four handlers that each say it slightly differently.
  --
  if (not senduid and key ~= "help") then
    konfer:SendWhisper(strfmt(L["%s: you were not found in the user list. Contact an admin for help."], nick), sender)
    return
  end

  fn(pol, senduid, sender, nick, arg)
end

--
-- Fired whenever our admin status for the currently selected config changes, or when we refresh due to a config change or
-- other events. This registers messages that only an admin cares about.
--
local function config_admin(self)
  --
  -- A suspended mod is nobody's admin, which takes the whisper hook and the chat filters down through the same path that
  -- would have taken them down had the user simply stopped being an admin.
  --
  local onoff = (not self:IsSuspended() and self:PolicyAdmin(self.apol)) and true or false

  if (onoff and not admin_hooks_registered) then
    admin_hooks_registered = true
    self:RegisterEvent("CHAT_MSG_WHISPER", chat_msg_whisper)
  elseif (not onoff and admin_hooks_registered) then
    admin_hooks_registered = false
    self:UnregisterEvent("CHAT_MSG_WHISPER")
  end

  local ef = nil

  if (onoff) then
    if (not chat_filters_installed) then
      if (self.apol.cfg.settings.chat_filter) then
        chat_filters_installed = true
        ef = ChatFrameUtil.AddMessageEventFilter
      end
    end
  end

  if (not onoff or not self.apol.cfg.settings.chat_filter) then
    if (chat_filters_installed) then
      chat_filters_installed = nil
      ef = ChatFrameUtil.RemoveMessageEventFilter
    end
  end

  --
  -- The replies are echoed on every channel the mod sends to: whispers, the guild, and the group, which is a party, a raid
  -- with its warnings, or a battleground's instance chat.
  --
  if (ef) then
    ef("CHAT_MSG_WHISPER", whisper_filter)
    ef("CHAT_MSG_WHISPER_INFORM", reply_filter)
    ef("CHAT_MSG_GUILD", reply_filter)
    ef("CHAT_MSG_PARTY", reply_filter)
    ef("CHAT_MSG_PARTY_LEADER", reply_filter)
    ef("CHAT_MSG_RAID", reply_filter)
    ef("CHAT_MSG_RAID_LEADER", reply_filter)
    ef("CHAT_MSG_RAID_WARNING", reply_filter)
    ef("CHAT_MSG_INSTANCE_CHAT", reply_filter)
    ef("CHAT_MSG_INSTANCE_CHAT_LEADER", reply_filter)
  end
end

--
-- Which user in this config this character is, or nil for a config they are not in.
--
-- The one thing session data keeps rather than works out. Arriving at it means walking every user in the config comparing
-- names, and a scroll list asks it once a row.
--
function cfgm:MyUid()
  return self:Session().myuid
end

--
-- The main character of whoever this character is here, which is that same user unless they are an alt. Nil for a config
-- they are not in.
--
function cfgm:MyMainId()
  local uid = self:MyUid()

  if (not uid) then
    return nil
  end

  local isalt, main = self:IsAlt(uid)

  return (isalt and main) or uid
end

--
-- What this character is here. 2 for its owner, 1 for a co-admin, false for everyone else and for a config they are not in.
--
-- Being an admin is inherited from the main character, so someone who owns a config administers it from any of their alts.
--
function cfgm:MyStatus()
  local uid = self:MyUid()

  if (not uid) then
    return false
  end

  local main = self:MyMainId()

  if (self.owner == uid or self.owner == main) then
    return 2
  end

  if (self:IsCoadmin(uid) or self:IsCoadmin(main)) then
    return 1
  end

  return false
end

function cfgm:UpdateUserSecurity()
  --
  -- The uid is the one thing worth keeping, everything derived from it being cheap enough to answer on demand. This is what
  -- makes it current again after the config's user list has changed underneath it.
  --
  -- The name to uid index goes for the same reason and first, since working out which user we are is itself a lookup by
  -- name. Every bulk change to a user list already comes through here, a broadcast, a sync, a recovery and a rename across
  -- configs among them, so those need nothing of their own.
  --
  self:ForgetUidIndex()
  self:Session().myuid = get_my_ids(self)

  if (konfer.initialised and self.id == konfer.apol.currentid) then
    config_admin(konfer)
  end

  return true
end

--
-- Whether this character runs the group's loot: its master looter, or where the game has no master loot, the leader
-- collecting it (konfer:Collecting in GroupLoot.lua), and an admin of the config loot runs against either way.
--
function konfer:AmIML()
  local ml = KRP.is_ml or self:Collecting()

  ml = ml or self.testloot -- @debug-delete@

  if (ml and self:PolicyAdmin(self.apol)) then
    return true
  end
  return false
end

function cfgm:IsAdmin(uid)
  if (not self) then
    return nil, nil
  end

  local uid = uid or self:FindUser(K.player.name)

  if (not uid) then
    return nil, nil
  end

  if (self.owner == uid) then
    return 2, uid
  end
  if (self:IsCoadmin(uid)) then
    return 1, uid
  end

  local isalt, main = self:IsAlt(uid)
  if (isalt) then
    if (self.owner == main) then
      return 2, main
    end
    if (self:IsCoadmin(main)) then
      return 1, main
    end
  end
  return nil, nil
end

--
-- POL is the policy the command was typed at, if any, so that what the user is told to type next is the command they just
-- used. Told to create a config from "/POLICY" they are told "/POLICY createconfig".
--
local function check_config(pol)
  if (konfer:IsTempCfg(pol) or not pol.currentid) then
    local cmd = pol.command or L["CMDNAME"]

    pol:info(L["no active configuration. Either create one with %s or wait for a guild admin to broadcast the guild list."],
      white(strfmt("/%s %s", cmd, L["CMD_CREATECONFIG"])))
    return true
  end
  return false
end

local function konfer_version()
  printf(ucolor, L["%s<%s>%s %s (version %s) %s"], "|cffff2222", K.KAHLUA, "|r", L["MODTITLE"], K.VersionString(MINOR),
    L["Loot distribution system."])
end

--
-- The version check and the raid info check ask one question, the character info check, and show its answer two ways. The
-- version check lists each person's mods under them. See konfer:CharacterInfoCheck in RaidInfo.lua.
--
local function konfer_versioncheck()
  konfer:CharacterInfoCheck(true)
end

local function konfer_raidinfo()
  konfer:CharacterInfoCheck()
end

local function konfer_specs()
  konfer:OpenSpecsDialog()
end

--
-- The mod's commands and a policy's are two separate sets, and each command prints its own help. "/konfer" is the mod as a
-- whole, so its help is what the mod does about itself and about this character. A policy's help is what can be done to that
-- policy's configurations, lists, users and items.
--
-- Neither set holds the other's commands, so neither help may name them: "/konfer createconfig" would have to guess whose
-- configuration to make, and "/ksk suspend" would switch the whole mod off at a command that names one policy. The raid
-- info check and the version check are the exception, asking the group or the guild and being no policy's, so both helps
-- name them, each with its short form.
--
local function konfer_usage()
  local kcmd = L["CMDNAME"]

  konfer_version()
  printf(ucolor, L["Usage: "] .. white(strfmt(L["/%s [command [arg [arg...]]]"], kcmd)))

  printf(ucolor, white(strfmt("/%s", kcmd)))
  printf(ucolor, L["  Opens the foyer, where the loot system in use is chosen."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_USERS"])))
  printf(ucolor, strfmt(L["  Opens the user editor, which every %s mod shares."], K.KAHLUA))

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_SPECS"])))
  printf(ucolor, L["  Choose the main spec and off spec you report to a raid info check."])

  printf(ucolor, white(strfmt("/%s %s | %s", kcmd, L["CMD_RAIDINFO"], L["CMD_RAIDINFO_ALIAS"])))
  printf(ucolor, L["  Ask your group, or your guild, for everybody's specs and professions."])

  printf(ucolor, white(strfmt("/%s %s | %s", kcmd, L["CMD_VERSIONCHECK"], L["CMD_VERSIONCHECK_ALIAS"])))
  printf(ucolor, strfmt(L["  Ask your group, or your guild, which version of each %s mod everybody has."], K.KAHLUA))

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_VERSION"])))
  printf(ucolor, strfmt(L["  Print which version of %s you have."], L["MODTITLE"]))

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_ABOUT"])))
  printf(ucolor, strfmt(L["  Show which version of %s this is, and who wrote it."], L["MODTITLE"]))

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_RESETPOS"])))
  printf(ucolor, L["  Put every window back where it started, having lost one off the edge of the screen."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_SUSPEND"])))
  printf(ucolor, strfmt(L["  Switch %s off entirely until resumed, as if it had never loaded."], L["MODTITLE"]))

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_RESUME"])))
  printf(ucolor, strfmt(L["  Resume normal %s operations."], L["MODTITLE"]))

  local named = false

  for k, v in ipairs(konfer:SortedPolicies()) do
    local pol = konfer.policies[v.handle]

    if (pol and pol.command) then
      if (not named) then
        printf(ucolor, L["Each loot system has a command of its own, for its configurations, lists, users and items:"])
        named = true
      end

      printf(ucolor, "  " .. white(strfmt("/%s %s", pol.command, L["CMD_HELP"])) .. " - " .. pol.name)
    end
  end
end

--
-- A policy's own help, naming the command the user typed, so that "/ksk help" reads as instructions for /ksk and never for
-- /konfer. Help is the one thing a policy answers without asking to become the active one first, so the policy it is about
-- is named as well, this being readable while some other system is the one in use.
--
local function policy_usage(pol)
  local kcmd = pol.command or L["CMDNAME"]

  konfer_version()
  printf(ucolor, strfmt(L["Commands for %s, one of the loot systems %s knows."], white(pol.name), L["MODTITLE"]))
  printf(ucolor, L["Usage: "] .. white(strfmt(L["/%s [command [arg [arg...]]]"], kcmd)))

  printf(ucolor, white(strfmt("/%s [%s [%s]]", kcmd, L["CMD_LISTS"], L["CMD_CONFIG"])))
  printf(ucolor, L["  Open the list management window."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_USERS"])))
  printf(ucolor, L["  Opens the user list management window."])

  printf(ucolor, white(strfmt("/%s %s [%s | %s]", kcmd, L["CMD_LOOT"], L["SUBCMD_ASSIGN"], L["SUBCMD_ITEMS"])))
  printf(ucolor, L["  Opens the loot management window."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["SUBCMD_HISTORY"])))
  printf(ucolor, L["  Opens the loot history."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_OPTIONS"])))
  printf(ucolor, L["  Opens your options, where you are not an admin."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_SYNC"])))
  printf(ucolor, L["  Opens the sync manager window."])

  printf(ucolor, white(strfmt("/%s %s [%s | %s]", kcmd, L["CMD_CONFIG"], L["SUBCMD_LOOT"], L["SUBCMD_ADMIN"])))
  printf(ucolor, L["  Set up various options and manage configurations."])

  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_SELECTCONFIG"])))
  printf(ucolor, L["  Selects the specified configuration as the current one."])
  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_CREATECONFIG"])))
  printf(ucolor, L["  Create the specified configuration."])
  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_DELETECONFIG"])))
  printf(ucolor, L["  Delete the specified configuration."])
  printf(ucolor, white(strfmt(L["/%s %s oldname newname"], kcmd, L["CMD_COPYCONFIG"])))
  printf(ucolor, L["  Copies the specified configuration to a new one, with options."])
  printf(ucolor, white(strfmt(L["/%s %s oldname newname"], kcmd, L["CMD_RENAMECONFIG"])))
  printf(ucolor, L["  Renames the specified configuration."])

  -- Roll list management commands
  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_SELECTLIST"])))
  printf(ucolor, L["  Selects the specified roll list as the current one."])
  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_CREATELIST"])))
  printf(ucolor, L["  Create the specified roll list."])
  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_DELETELIST"])))
  printf(ucolor, L["  Delete the specified roll list."])
  printf(ucolor, white(strfmt(L["/%s %s oldname newname"], kcmd, L["CMD_COPYLIST"])))
  printf(ucolor, L["  Copies the specified roll list to a new one."])
  printf(ucolor, white(strfmt(L["/%s %s oldname newname"], kcmd, L["CMD_RENAMELIST"])))
  printf(ucolor, L["  Renames the specified roll list."])

  -- User list management commands
  printf(ucolor, white(strfmt(L["/%s %s name class"], kcmd, L["CMD_CREATEUSER"])))
  printf(ucolor, L["  Adds a new user to the users list."])
  printf(ucolor, white(strfmt(L["/%s %s name"], kcmd, L["CMD_DELETEUSER"])))
  printf(ucolor, L["  Removes a user from the users list."])
  printf(ucolor, white(strfmt(L["/%s %s oldname newname"], kcmd, L["CMD_RENAMEUSER"])))
  printf(ucolor, L["  Renames a user after a paid name change."])
  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_IMPORTGUILDUSERS"])))
  printf(ucolor, L["  Adds everybody in your guild who is not in the users list already."])

  printf(ucolor, white(strfmt(L["/%s %s [itemid | itemlink]"], kcmd, L["CMD_ADDITEM"])))
  printf(ucolor, L["  Adds a new item to the item list."])
  printf(ucolor, white(strfmt(L["/%s %s [itemid | itemlink]"], kcmd, L["CMD_ADDLOOT"])))
  printf(ucolor, L["  Adds a new item to the loot list."])

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_READYCHECK"])))
  printf(ucolor, "  " .. L["Starts a ready check."])

  printf(ucolor, white(strfmt("/%s %s | %s", kcmd, L["CMD_RAIDINFO"], L["CMD_RAIDINFO_ALIAS"])))
  printf(ucolor, L["  Ask your group, or your guild, for everybody's specs and professions."])

  printf(ucolor, white(strfmt("/%s %s | %s", kcmd, L["CMD_VERSIONCHECK"], L["CMD_VERSIONCHECK_ALIAS"])))
  printf(ucolor, strfmt(L["  Ask your group, or your guild, which version of each %s mod everybody has."], K.KAHLUA))

  for _, c in ipairs(pol.Commands or {}) do
    printf(ucolor, white(strfmt("/%s %s%s", kcmd, c.word, c.args and (" " .. c.args) or "")))
    printf(ucolor, "  " .. c.help)
  end

  printf(ucolor, white(strfmt("/%s %s", kcmd, L["CMD_ABOUT"])))
  printf(ucolor, strfmt(L["  Show which version of %s this is, and who wrote it."], L["MODTITLE"]))
end

--
-- POL is the policy the command was typed at, and it answers two questions at once: whose configs, lists and users the
-- argument is looked up in, and who is talking. A usage message names the command the user actually typed, so "/POLICY
-- createconfig" is corrected with "/POLICY", never with "/konfer".
--
local function common_verify_input(pol, input, cmd, exist, bypass, tbl, nexmsg, exmsg)
  if (not bypass and pol.cfg:IsDenied()) then
    return true
  end

  local found = false
  local nname, pos
  local retid = 0
  local kcmd = pol.command or L["CMDNAME"]

  if (not input or input == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name"], kcmd, cmd)))
    return true
  end

  nname, pos = K.GetArgs(input)
  if (not nname or nname == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name"], kcmd, cmd)))
    return true
  end

  if (pos ~= 1e9) then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name"], kcmd, cmd)))
    return true
  end

  if (type(tbl) == "string" and tbl == "special") then
    return false, nname
  end

  local low = strlower(nname)
  if (tbl) then
    for k,v in pairs(tbl) do
      if (strlower(v.name) == low) then
        found = true
        retid = k
      end
    end
  end

  if (exist) then
    if (not found) then
      pol:err(nexmsg, white(nname))
      return true
    end
  else
    if (found) then
      pol:err(exmsg, white(nname))
      return true
    end
  end

  return false, nname, found, retid
end

local function common_verify_input2(pol, input, cmd, exist, bypass, tbl, nexmsg, exmsg)
  if (not bypass and pol.cfg:IsDenied()) then
    return true
  end

  if (not tbl) then
    return true
  end

  local oldname, newname, pos
  local found = 0
  local retid = 0
  local kcmd = pol.command or L["CMDNAME"]

  if (not input or input == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s oldname newname"], kcmd, cmd)))
    return true
  end

  oldname, newname, pos = K.GetArgs(input, 2)
  if (not oldname or oldname == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s oldname newname"], kcmd, cmd)))
    return true
  end

  if (not newname or newname == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s oldname newname"], kcmd, cmd)))
    return true
  end

  if (pos ~= 1e9) then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s oldname newname"], kcmd, cmd)))
    return true
  end

  if (oldname == newname) then
    return true
  end

  if (type(tbl) == "string" and tbl == "special") then
    return false, oldname, newname
  end

  local lnew = strlower(newname)
  local lold = strlower(oldname)

  if (tbl) then
    for k,v in pairs(tbl) do
      if (strlower(v.name) == lnew) then
        found = k
      end
      if (strlower(v.name) == lold) then
        retid = k
      end
    end
  end

  if (retid == 0) then
    pol:err(nexmsg, white(oldname))
    return true
  end

  if (not exist) then
    if (found ~= 0) then
      pol:err(exmsg, white(newname))
      return true
    end
  end

  return false, oldname, newname, retid, found
end

--
-- POL is the policy the command was typed at, so "/POLICY createconfig" makes a config whatever policy happens to be active.
--
local function konfer_createconfig(input, pol)
  local cmd = L["CMD_CREATECONFIG"]
  local rv, nname, _, cfgid = common_verify_input(pol, input, cmd, false, true, konfer:PolicyConfigs(pol), nil,
    L["configuration %q already exists. Try again."])

  if (rv) then
    return true
  end

  return konfer:CreateNewConfig(nname, false, nil, nil, pol.handle)
end

--
-- Choosing which config a policy has in hand is looking at it, which anyone may do, read only where they are not an admin,
-- just as with a policy window's selector. So it asks for no admin right, and it works with no config in hand, being how one is put there.
--
local function konfer_selectconfig(input, pol)
  local cmd = L["CMD_SELECTCONFIG"]
  local rv, nname, _, cfgid = common_verify_input(pol, input, cmd, true, true, konfer:PolicyConfigs(pol),
    L["configuration %q does not exist. Try again."], nil)

  if (rv) then
    return true
  end

  konfer:Config(cfgid):SetDefault()
  return false
end

local function konfer_deleteconfig(input, pol)
  local cmd = L["CMD_DELETECONFIG"]
  local rv, nname, _, cfgid = common_verify_input(pol, input, cmd, true, true, konfer:PolicyConfigs(pol),
    L["configuration %q does not exist. Try again."], nil)

  if (rv) then
    return true
  end

  konfer:Config(cfgid):Delete()
  return false
end

local function konfer_renameconfig(input, pol)
  local cmd = L["CMD_RENAMECONFIG"]
  local rv, _, newname, cfgid, _ = common_verify_input2(pol, input, cmd, true, false, konfer:PolicyConfigs(pol),
    L["configuration %q does not exist. Try again."],
    L["configuration %q already exists. Try again."])

  if (rv) then
    return true
  end

  return konfer:Config(cfgid):Rename(newname)
end

local function konfer_copyconfig(input, pol)
  local cmd = L["CMD_COPYCONFIG"]
  local rv, _, newname, cfgid, newid = common_verify_input2(pol, input, cmd, true, false, konfer:PolicyConfigs(pol),
    L["configuration %q does not exist. Try again."],
    L["configuration %q already exists. Try again."])

  if (rv) then
    return true
  end

  return konfer:Config(cfgid):Copy(newname, newid)
end

local function konfer_createuser(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  local kcmd = pol.command or L["CMDNAME"]
  local cmd = L["CMD_CREATEUSER"]
  local nname, nclass, pos
  local classid = nil

  if (not input or input == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name class"], kcmd, cmd)))
    return true
  end

  nname, nclass, pos = K.GetArgs(input, 2)
  if (not nname or nname == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name class"], kcmd, cmd)))
    return true
  end

  if (not nclass or nclass == "") then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name class"], kcmd, cmd)))
    return true
  end

  if (pos ~= 1e9) then
    pol:err(L["Usage: "] .. white(strfmt(L["/%s %s name class"], kcmd, cmd)))
    return true
  end

  local lclass = strlower(nclass)
  for k,v in pairs(K.IndexClass) do
    if (v.l == lclass) then
      classid = k
    end
  end

  if (not classid) then
    pol:err(L["invalid class %q specified. Valid classes are:"], white(lclass))
    for k,v in pairs(K.IndexClass) do
      if (v.l) then
        printf("    |cffffffff%s|r", v.l)
      end
    end
    return true
  end

  if (not pol.cfg:CreateNewUser(nname, classid)) then
    return true
  end
  return false
end

--
-- A user is found by name the way everything else finds one, through FindUser, rather than by the name matching that
-- common_verify_input does for configs and lists: a config's entry for a user holds a canonical name, and a name typed
-- without its realm is a character on this realm.
--
local function konfer_deleteuser(input, pol)
  local cmd = L["CMD_DELETEUSER"]
  local rv, nname = common_verify_input(pol, input, cmd, true, false, "special")

  if (rv) then
    return true
  end

  local userid = pol.cfg:FindUser(nname)

  if (not userid) then
    pol:err(L["user %q does not exist. Try again."], white(nname))
    return true
  end

  if (not pol.cfg:DeleteUserCmd(userid)) then
    return true
  end
  return false
end

local function konfer_renameuser(input, pol)
  local cmd = L["CMD_RENAMEUSER"]
  local rv, oldname, newname = common_verify_input2(pol, input, cmd, true, false, "special")

  if (rv) then
    return true
  end

  local userid = pol.cfg:FindUser(oldname)

  if (not userid) then
    pol:err(L["user %q does not exist. Try again."], white(oldname))
    return true
  end

  if (pol.cfg:FindUser(newname)) then
    pol:err(L["user %q already exists. Try again."], white(newname))
    return true
  end

  return pol.cfg:RenameUser(userid, newname)
end

local function konfer_config(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end
  local page = konfer.CONFIG_PAGE

  local tab = konfer.CONFIG_LOOT_TAB

  if (input == L["SUBCMD_LOOT"] or input == "" or not input) then
    tab = konfer.CONFIG_LOOT_TAB
  elseif (input == L["SUBCMD_ADMIN"]) then
    tab = konfer.CONFIG_ADMIN_TAB
  elseif (input == L["CMD_LISTS"]) then
    page = konfer.LISTS_PAGE
    tab = konfer.LISTS_CONFIG_TAB
  else
    printf(ucolor, L["Usage: "] .. white(strfmt("/%s %s [%s | %s | %s]", L["CMDNAME"], L["CMD_CONFIG"],
      L["SUBCMD_LOOT"], L["SUBCMD_ADMIN"], L["CMD_LISTS"])))
    printf(ucolor,L["  %s - set up loot related options"], white(L["SUBCMD_LOOT"]))
    printf(ucolor,L["  %s - set up config spaces and permissions options"], white(L["SUBCMD_ADMIN"]))
    printf(ucolor,L["  %s - configure lists and list options"], white(L["CMD_LISTS"]))
    return
  end

  konfer.mainwin:Show()
  konfer.mainwin:SetPage(page, tab)
end

--
-- Raise the window on the page that is most use right now: the loot page while there is loot to hand out, and the lists otherwise.
--
-- It shows the active policy, so PP is a policy the caller wants shown and is made the active one first, through the one
-- code path that does that. Without one it is whichever policy is already active. Reached through konfer:OpenPolicy, which
-- is what settles the question of which that is.
--
function konfer:ShowMainWindow(pp)
  if (pp and pp ~= self.apol) then
    self:ActivatePolicy(pp)
  end

  if (not self.mainwin or not self.apol) then
    return
  end

  self.mainwin:Show()

  if (self.raid.bossloot) then
    self.mainwin:SetPage(self.LOOT_PAGE, self.LOOT_ASSIGN_TAB)
  else
    self.mainwin:SetPage(self:FirstPage(), self.LISTS_MEMBERS_TAB)
  end
end

--
-- The page the window opens on when there is no loot up: the first along the bottom of those shown, which is Lists for every
-- policy that shows it and the Raid page for PUG.
--
function konfer:FirstPage()
  for _, pg in ipairs(self.mainwin.pages) do
    if (not pg.hidden) then
      return pg.name
    end
  end
end

--
-- The two halves of "users". The people are Kore's and belong to no policy, so the mod's own command opens the shared editor
-- and needs no configuration to do it. A policy's command opens its Users page, which is the same record reached from the
-- context where a configuration's own view of it (enchanter, frozen) sits beside it.
--
local function konfer_useredit(input)
  konfer:OpenUserEditor()
end

--
-- The two halves of "config", the same shape as the two halves of "users" above. The mod's own opens the settings window,
-- which is the mod as a whole and belongs to no policy and no configuration. A policy's command opens its Config page,
-- which is one configuration's own settings and is a different thing entirely.
--
local function konfer_settings(input)
  konfer:OpenSettings()
end

local function konfer_users(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.USERS_PAGE)
end

local function konfer_importgusers(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  if (not K.player.is_guilded) then
    pol:err(L["you are not in a guild."])
    return true
  end

  konfer:ImportGuildUsers(konfer.mainwin:IsShown())
end

local function konfer_show(input, pol)
  konfer.mainwin:Show()
end

local function konfer_createlist(input, pol)
  local cmd = L["CMD_CREATELIST"]
  local rv, nname, _, listid = common_verify_input(pol, input, cmd, false, false, pol.cfg.lists, nil,
    L["roll list %q already exists. Try again."])

  if (rv) then
    return true
  end

  return pol.cfg:CreateNewList(nname)
end

local function konfer_selectlist(input, pol)
  local cmd = L["CMD_SELECTLIST"]
  local rv, nname, _, listid = common_verify_input(pol, input, cmd, true, false, pol.cfg.lists,
    L["roll list %q does not exist. Try again."], nil)

  if (rv) then
    return true
  end

  konfer:SelectList(listid)
  return false
end

local function konfer_deletelist(input, pol)
  local cmd = L["CMD_DELETELIST"]
  local rv, nname, _, listid = common_verify_input(pol, input, cmd, true, false, pol.cfg.lists,
    L["roll list %q does not exist. Try again."], nil)

  if (rv) then
    return true
  end

  pol.cfg:DeleteListCmd(listid)
  return false
end

local function konfer_renamelist(input, pol)
  local cmd = L["CMD_RENAMELIST"]
  local rv, _, newname, listid, _ = common_verify_input2(pol, input, cmd, true, false, pol.cfg.lists,
    L["roll list %q does not exist. Try again."], L["roll list %q already exists. Try again."])

  if (rv) then
    return true
  end

  return pol.cfg:RenameList(listid, newname)
end

local function konfer_copylist(input, pol)
  local cmd = L["CMD_COPYLIST"]
  local rv, _, newname, listid, _ = common_verify_input2(pol, input, cmd, true, false, pol.cfg.lists,
    L["roll list %q does not exist. Try again."], L["roll list %q already exists. Try again."])

  if (rv) then
    return true
  end

  return pol.cfg:CopyList(listid, newname)
end

local function konfer_loot(input, pol)
  local tab = konfer.LOOT_ASSIGN_TAB

  if (input == L["SUBCMD_ASSIGN"] or input == "" or not input) then
    tab = konfer.LOOT_ASSIGN_TAB
  elseif (input == L["SUBCMD_ITEMS"]) then
    if (pol.cfg:IsDenied()) then
      return true
    end
    tab = konfer.LOOT_ITEMS_TAB
  elseif (input == L["SUBCMD_HISTORY"]) then
    tab = konfer.LOOT_HISTORY_TAB
  else
    printf(ucolor, L["Usage: "] .. white(strfmt("/%s %s [%s | %s | %s]", L["CMDNAME"], L["CMD_LOOT"],
      L["SUBCMD_ASSIGN"], L["SUBCMD_ITEMS"], L["SUBCMD_HISTORY"])))
    printf(ucolor,L["  %s - open the loot assignment window"], white(L["SUBCMD_ASSIGN"]))
    printf(ucolor,L["  %s - open the item editor window"], white(L["SUBCMD_ITEMS"]))
    printf(ucolor,L["  %s - open the item history window"], white(L["SUBCMD_HISTORY"]))
    return
  end

  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.LOOT_PAGE, tab)
end

local function konfer_lists(input, pol)
  local tab = konfer.LISTS_MEMBERS_TAB

  if (input == L["CMD_CONFIG"]) then
    if (pol.cfg:IsDenied()) then
      return true
    end
    tab = konfer.LISTS_CONFIG_TAB
  elseif (input and input ~= "") then
    printf(ucolor, L["Usage: "] .. white(strfmt("/%s %s [%s]", pol.command or L["CMDNAME"], L["CMD_LISTS"], L["CMD_CONFIG"])))
    printf(ucolor, L["  %s - configure lists and list options"], white(L["CMD_CONFIG"]))
    return
  end

  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.LISTS_PAGE, tab)
end

local function konfer_sync(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.SYNC_PAGE)
end

local function konfer_items(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.LOOT_PAGE, konfer.LOOT_ITEMS_TAB)
end

-- The History tab is everybody's, each keeping a history of their own, so a raider may open it as an admin may.
local function konfer_history(input, pol)
  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.LOOT_PAGE, konfer.LOOT_HISTORY_TAB)
end

-- The Options page is for whoever is no admin of the config, and an admin, who has none, is shown the window as it stands.
local function konfer_options(input, pol)
  konfer.mainwin:Show()
  konfer.mainwin:SetPage(konfer.OPTIONS_PAGE)
end

local function konfer_additem(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  local kcmd = pol.command or L["CMDNAME"]

  if (not input or input == "" or input == L["CMD_HELP"]) then
    pol:err(L["Usage: "] ..  white(strfmt(L["/%s %s [itemid | itemlink]"], kcmd, L["CMD_ADDITEM"])))
    return true
  end

  local itemid, pos = K.GetArgs(input)
  if (itemid ~= "") then
    -- Convert to numeric itemid if an item link was specified
    local ii = tonumber(itemid)
    if (ii == nil) then
      itemid = match(itemid, "item:(%d+)")
    end
  end
  if ((not itemid) or (itemid == "") or (pos ~= 1e9) or (tonumber(itemid) == nil)) then
    pol:err(L["Usage: "] ..  white(strfmt(L["/%s %s [itemid | itemlink]"], kcmd, L["CMD_ADDITEM"])))
    return true
  end

  if (pol.cfg.items[itemid]) then
    pol:err(L["item %s already exists."], pol.cfg.items[itemid].ilink)
    return true
  end

  --
  -- GetItemInfoInstant tells us whether the id is real. GetItemInfo tells us whether we have the data yet. Asking prompts
  -- the fetch, so a second attempt succeeds.
  --
  if (not C_Item.GetItemInfoInstant(tonumber(itemid))) then
    pol:err(L["item %d is an invalid item."], itemid)
    return true
  end

  local iname, ilink = C_Item.GetItemInfo(tonumber(itemid))
  if (iname == nil or iname == "") then
    pol:err(L["still retrieving information for item %d. Please try again in a moment."], itemid)
    return true
  end

  pol.cfg:AddItem(itemid, ilink)
end

local function konfer_addloot(input, pol)
  if (pol.cfg:IsDenied()) then
    return true
  end

  local kcmd = pol.command or L["CMDNAME"]

  if (not konfer:AmIML()) then
    pol:err(L["can only add items when in a raid and you are the master looter."])
    return true
  end

  if (not input or input == "" or input == L["CMD_HELP"]) then
    pol:err(L["Usage: "] ..  white(strfmt(L["/%s %s [itemid | itemlink]"], kcmd, L["CMD_ADDLOOT"])))
    return true
  end

  local itemid, pos = K.GetArgs(input)
  if (itemid ~= "") then
    -- Convert to numeric itemid if an item link was specified
    local ii = tonumber(itemid)
    if (ii == nil) then
      itemid = match(itemid, "item:(%d+)")
    end
  end
  if ((not itemid) or (itemid == "") or (pos ~= 1e9) or (tonumber(itemid) == nil)) then
    pol:err(L["Usage: "] ..  white(strfmt(L["/%s %s [itemid | itemlink]"], kcmd, L["CMD_ADDLOOT"])))
    return true
  end

  -- See the note in the additem handler above about these two calls.
  if (not C_Item.GetItemInfoInstant(tonumber(itemid))) then
    pol:err(L["item %d is an invalid item."], itemid)
    return true
  end

  local iname, ilink = C_Item.GetItemInfo(tonumber(itemid))
  if (iname == nil or iname == "") then
    pol:err(L["still retrieving information for item %d. Please try again in a moment."], itemid)
    return true
  end

  konfer:AddLoot(ilink)
end

-- @debug-start@
local function konfer_test(input)
end
-- @debug-end@

local function konfer_debug(input)
  input = input or "1"
  if (input == "") then
    input = "1"
  end
  local dl = tonumber(input)
  if (dl == nil) then
    dl = 0
  end
  K.debugging[L["MODNAME"]] = dl
end

-- @debug-start@
local function konfer_status(input)
end
-- @debug-end@

--
-- Keep WIN where the user last put it, and at the size they left it, from one session to the next.
--
-- WoW does this itself for a window the user has moved, but only for one that already exists while addons are still loading,
-- which is when it puts the saved places back. The main window is built later than that and so would always forget, and when
-- a window happens to be created is no way to decide whether it remembers. So every window the mod owns keeps its own place,
-- per character, in konfer.chardb.winpos, saved whenever the user finishes moving or resizing it.
--
-- Called once the window exists and the character's database is open, and before anything is built inside the window, so
-- that its contents are laid out at the size they will be shown at.
--
-- A saved size is only ever what the window may be now. A window that cannot be resized keeps the size it was made at, and
-- one that can is held to its current bounds, so a window made a fixed width, or narrower, does not come back as it was.
--
function konfer:KeepWindowPlace(win)
  local name = win:GetName()
  local saved = self.chardb.winpos[name]

  if (saved) then
    local width, height = win:GetWidth(), win:GetHeight()

    if (win:IsResizable()) then
      local minw, minh, maxw, maxh = win:GetResizeBounds()

      width = max(saved.width, minw)
      height = max(saved.height, minh)
      width = (maxw and maxw > 0) and min(width, maxw) or width
      height = (maxh and maxh > 0) and min(height, maxh) or height
    end

    win:ClearAllPoints()
    win:SetPoint(saved.point, UIParent, saved.relpoint, saved.x, saved.y)
    win:SetWidth(width)
    win:SetHeight(height)
  end

  local function save(this)
    local point, _, relpoint, x, y = this:GetPoint(1)

    konfer.chardb.winpos[name] = {
      point = point, relpoint = relpoint, x = x, y = y, width = this:GetWidth(), height = this:GetHeight(),
    }
  end

  win:Catch("OnStopMoving", save)
  win:Catch("OnStopSizing", save)
end

--
-- Puts every window this mod owns back somewhere the user can reach, which is the whole point of the command: it exists for
-- a window that has been dragged off the screen, and the user cannot say which one that was if they cannot see it. Where
-- each was saved is forgotten too, or the next session would put it straight back off the screen.
--
local function konfer_resetpos(input)
  if (konfer.mainwin) then
    konfer.mainwin:ClearAllPoints()
    konfer.mainwin:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
  end

  if (konfer.foyerwin) then
    konfer.foyerwin:ClearAllPoints()
    konfer.foyerwin:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
  end

  if (konfer.settingswin) then
    konfer.settingswin:ClearAllPoints()
    konfer.settingswin:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
  end

  if (KU.usereditwin) then
    KU.usereditwin:ClearAllPoints()
    KU.usereditwin:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
  end

  konfer.chardb.winpos = {}
end

--
-- Put every window away. Suspending does this, and so does anything else that wants the mod off the screen in one call.
--
function konfer:CloseAllWindows()
  if (self.popupwindow) then
    self.popupwindow:Hide()
    self.popupwindow = nil
  end

  if (self.foyerwin) then
    self.foyerwin:Hide()
  end

  if (self.settingswin) then
    self.settingswin:Hide()
  end

  if (KU.usereditwin) then
    KU.usereditwin:Hide()
  end

  if (self.mainwin) then
    self.mainwin:Hide()
  end
end

--
-- Start or stop hearing anything at all. One prefix carries the whole mod, policies included, so this is one subscription
-- and giving it up takes every policy's traffic with it, which is what suspending the mod means.
--
local function listen(onoff)
  KC.Listen(konfer, onoff)
end

--
-- Whether this character was in a group when KRP last said. KRP's group refresh can be told to report a change that did
-- not happen, and startup forces several, so arriving in a group is this going from false to true rather than the report
-- (krp_in_group_changed). A suspended mod hears nothing, so suspending clears it and resuming in a group is arriving.
--
-- ASKED_CFG is the config the group was last asked about for its raid settings, cleared on arriving (konfer:AskRaidSettings).
--
local was_in_party = false
local asked_cfg = nil

--
-- Apply the suspended state. Called at login with the stored value, and by set_suspended() when the user asks for a change.
--
-- Suspended means as close to never having loaded as an addon already in memory can get: nothing on screen, nothing
-- listening, nothing answered. A user suspends Konfer because it is in the way of something else, so half measures are no
-- use. A mod that has stopped opening windows but still eats whispers and still filters chat is still in the way.
--
-- The comms prefixes are given up rather than ignored on arrival. An addon that is not registered for a prefix is never
-- handed the message at all, which is both cheaper and a stronger statement.
--
-- Two things survive on purpose. The slash commands stay, because /konfer resume has to have somewhere to arrive. And the
-- saved variables are left exactly as they are: suspending is not forgetting.
--
local function konfer_suspended(onoff)
  konfer.frdb.suspended = onoff

  if (onoff) then
    konfer:CloseAllWindows()
    konfer:EndOpenRoll()

    listen(false)
    was_in_party = false

    KRP:SuspendAddon(konfer.addon_handle)
    KLD:SuspendAddon(konfer.addon_handle)
    KC:SuspendAddon(konfer.addon_handle)
  else
    listen(true)

    KRP:ActivateAddon(konfer.addon_handle)
    KLD:ActivateAddon(konfer.addon_handle)
    KC:ActivateAddon(konfer.addon_handle)
  end

  --
  -- The whisper hook, the chat filters and the pending item watch are all decided by what this character is in the config it
  -- has in hand, and a suspended mod is nothing in any of them. Refreshing is therefore what takes them down and what puts
  -- them back, rather than a second list of registrations kept in step with the first by hand.
  --
  konfer:RefreshCSData()
  konfer:WatchPendingItems()
  konfer:ApplyGroupLoot()
end

--
-- What a suspended mod says when someone reaches for it. Every entry point that refuses says this rather than nothing,
-- because silence from a mod you had forgotten you switched off looks exactly like one that is broken.
--
function konfer:SaySuspended()
  info(L["suspended. Type %s to resume."], white(strfmt("/%s %s", L["CMDNAME"], L["CMD_RESUME"])))
end

--
-- Change the suspended state because the user asked for it, refresh the UI and say what happened. Does nothing if we are
-- already in the requested state, so that repeating the command is harmless.
--
local function set_suspended(onoff)
  local onoff = onoff or false

  if (konfer:IsSuspended() == onoff) then
    return
  end

  konfer_suspended(onoff)
  konfer:FullRefresh(true)

  local ds = L["active"]
  if (onoff) then
    ds = L["suspended"]
  end
  printf(K.icolor, "%s: |cffffffff%s|r.", L["MODTITLE"], ds)
end

local function konfer_suspend(input)
  set_suspended(true)
end

-- The same for anything that offers to suspend the mod rather than being typed, the offer on becoming master looter.
function konfer:Suspend()
  set_suspended(true)
end

local function konfer_resume(input)
  set_suspended(false)
end

local function konfer_refresh(input)
  KRP.UpdateGroup(true, true, false)
end

local ctl = _G.ChatThrottleLib

--
-- The floor Konfer asks ChatThrottleLib for, and what "normal" puts it back to. See the comment where it is applied for why it is a floor.
--
local KONFER_MIN_CPS = 1500

local function konfer_cps(input)
  if (input == "slow") then
    ctl.MAX_CPS = 800
  elseif (input == "normal") then
    ctl.MAX_CPS = KONFER_MIN_CPS
  else
    local n = tonumber(input) or 0
    if (n >= 100 and n <= 4000) then
      ctl.MAX_CPS = n
    end
  end

  info(L["throttle speed set to %d"], ctl.MAX_CPS)
end

K.debugging[L["MODNAME"]] = 9   -- @debug-delete@

--
-- The two command sets, and nothing is in both by accident. KCMDTAB is the mod's, reached through "/konfer" alone, and
-- everything in it is about the mod or about this character: which version is installed, what this character reports to a
-- raid info check, the people, and switching the whole thing off. Its handlers take an argument and nothing else, there
-- being no policy in the question they answer.
--
-- PCMDTAB is a policy's, reached through "/ksk" or "/keg", and everything in it works on one policy's configurations, lists,
-- users or items. Every handler in it takes that policy as its second argument, which is both whose configurations the
-- argument is looked up in and who reports the result.
--
-- The one word in both is "users", and it means the two different things it names: the mod's is the shared user editor and a
-- policy's is that policy's Users page, the same record reached from the context where it matters.
--
-- CHECKCMDTAB is the raid info check and the version check, which ask the group or the guild and are no policy's, so "/konfer"
-- answers them and so does every policy's command (konfer:OnPolicyCommand), needing no configuration and never a switch of
-- policy. Each answers to the locale's word and its short form, and to the English two whatever the locale.
--
local checkcmdtab = {}

for _, w in ipairs({ L["CMD_RAIDINFO"], L["CMD_RAIDINFO_ALIAS"], "raidinfo", "ri" }) do
  checkcmdtab[w] = konfer_raidinfo
end

for _, w in ipairs({ L["CMD_VERSIONCHECK"], L["CMD_VERSIONCHECK_ALIAS"], "versioncheck", "vc" }) do
  checkcmdtab[w] = konfer_versioncheck
end

local kcmdtab = {}
kcmdtab["debug"] = konfer_debug
kcmdtab["status"] = konfer_status -- @debug-delete@
kcmdtab["refresh"] = konfer_refresh
kcmdtab["cps"] = konfer_cps
kcmdtab["test"] = konfer_test -- @debug-delete@
kcmdtab["testloot"] = function(input) konfer:TestLoot(input) end -- @debug-delete@
kcmdtab["testraid"] = function(input) konfer:TestRaid(input) end -- @debug-delete@
kcmdtab[L["CMD_RESETPOS"]] = konfer_resetpos
kcmdtab[L["CMD_VERSION"]] = konfer_version
kcmdtab[L["CMD_ABOUT"]] = function(input) konfer:ShowAbout() end
kcmdtab[L["CMD_SPECS"]] = konfer_specs
kcmdtab[L["CMD_USERS"]] = konfer_useredit
kcmdtab[L["CMD_CONFIG"]] = konfer_settings
kcmdtab[L["CMD_SUSPEND"]] = konfer_suspend
kcmdtab[L["CMD_RESUME"]] = konfer_resume

for w, fn in pairs(checkcmdtab) do
  kcmdtab[w] = fn
end

local pcmdtab = {}
pcmdtab[L["CMD_SHOW"]] = konfer_show
pcmdtab[L["CMD_LISTS"]] = konfer_lists
pcmdtab[L["CMD_USERS"]] = konfer_users
pcmdtab[L["CMD_LOOT"]] = konfer_loot
pcmdtab[L["CMD_CONFIG"]] = konfer_config
pcmdtab[L["CMD_SYNC"]] = konfer_sync

pcmdtab[L["SUBCMD_ITEMS"]] = konfer_items
pcmdtab[L["SUBCMD_HISTORY"]] = konfer_history
-- In English whatever the locale as well, the page being where a raider who has never seen it in their own words is sent.
pcmdtab["options"] = konfer_options
pcmdtab[L["CMD_OPTIONS"]] = konfer_options
pcmdtab[L["CMD_ADDITEM"]] = konfer_additem
pcmdtab[L["CMD_ADDLOOT"]] = konfer_addloot

pcmdtab[L["CMD_SELECTCONFIG"]] = konfer_selectconfig
pcmdtab[L["CMD_CREATECONFIG"]] = konfer_createconfig
pcmdtab[L["CMD_DELETECONFIG"]] = konfer_deleteconfig
pcmdtab[L["CMD_RENAMECONFIG"]] = konfer_renameconfig
pcmdtab[L["CMD_COPYCONFIG"]] = konfer_copyconfig

pcmdtab[L["CMD_CREATEUSER"]] = konfer_createuser
pcmdtab[L["CMD_DELETEUSER"]] = konfer_deleteuser
pcmdtab[L["CMD_RENAMEUSER"]] = konfer_renameuser
pcmdtab[L["CMD_IMPORTGUILDUSERS"]] = konfer_importgusers

pcmdtab[L["CMD_SELECTLIST"]] = konfer_selectlist
pcmdtab[L["CMD_CREATELIST"]] = konfer_createlist
pcmdtab[L["CMD_DELETELIST"]] = konfer_deletelist
pcmdtab[L["CMD_RENAMELIST"]] = konfer_renamelist
pcmdtab[L["CMD_COPYLIST"]] = konfer_copylist

--
-- Whether INPUT, typed at some policy's own command, needs that policy to be the active one before it will do anything
-- useful. Everything does, with two exceptions.
--
-- Making a config is the bootstrap and must always run. A policy with no configs refuses to open at all and says to create
-- one, and if creating one asked to switch policy first there would be no way out of that: you would be switching to a
-- policy that still has nothing in it.
--
-- Help only prints, and asking somebody to change their whole loot system before they may read the help would be absurd.
-- About only shows the policy's splash, for the same reason, and a ready check, the raid info check and the version check
-- are the group's and no policy's at all.
--
-- Everything else either opens a page, and there is one window showing one policy, or puts up a dialog belonging to a
-- policy that is not on screen.
--
function konfer:CommandNeedsPolicy(input)
  local cmd = K.GetArgs(input or "")

  if (not cmd or cmd == "") then
    return true
  end

  cmd = strlower(cmd)

  if (cmd == L["CMD_CREATECONFIG"] or cmd == L["CMD_HELP"] or cmd == "?" or cmd == L["CMD_ABOUT"]
    or cmd == L["CMD_READYCHECK"] or checkcmdtab[cmd]) then
    return false
  end

  return true
end

--
-- The words after a command, as one string. POS is where K.GetArgs left off, and 1e9 is what it reports for a command that
-- had nothing after it at all.
--
local function command_args(input, pos)
  if (pos == 1e9) then
    return ""
  end

  return strsub(input, pos)
end

--
-- "/konfer", the mod as a whole. Nothing here names a configuration, a list, a user entry or an item, because every one of
-- those belongs to one policy and this command names none. Taking them against whichever policy happened to be active would
-- mean the user had to know that before they could know what they had just done, and mistyping one of them would be
-- answered by a policy they had not mentioned. They are typed at their policy's own command, in OnPolicyCommand below.
--
function konfer:OnSlashCommand(input)
  local cmd, pos = K.GetArgs(input or "")

  --
  -- Suspended, the only thing worth answering is the way back. Everything else says why nothing happened, because silence
  -- from a mod you had forgotten you switched off is indistinguishable from a mod that is broken.
  --
  if (self:IsSuspended() and cmd ~= L["CMD_RESUME"]) then
    self:SaySuspended()
    return
  end

  --
  -- Bare "/konfer" is the mod as a whole, so it opens the foyer rather than any one policy's window. It deliberately does
  -- not go through check_config(): having no usable config is exactly the situation the foyer exists to get you out of,
  -- since that is where a config is created. A bare policy command is a different question and is answered in OpenPolicy.
  --
  if (not cmd or cmd == "") then
    self:OpenFoyer()
    return
  end

  cmd = strlower(cmd)

  if (cmd == L["CMD_HELP"] or cmd == "?") then
    konfer_usage()
    return
  end

  --
  -- The mod is what did not understand this, so the mod says so and points at its own help. A mistyped word here is a
  -- mistyped mod command, and answering it with the usage for a loot system the user did not name reads as an accusation.
  --
  if (not kcmdtab[cmd]) then
    err(L["%q is not a valid command. Type %s for help."], white(cmd), white(strfmt("/%s %s", L["CMDNAME"], L["CMD_HELP"])))
    return
  end

  kcmdtab[cmd](command_args(input, pos))
end

--
-- "/ksk", "/keg" and the rest: one policy, named by the command the user typed. POL answers two questions at once, whose
-- configurations, lists and users the argument is looked up in and who reports the result, which is why every handler takes
-- it. Reached from konfer:RegisterPolicyCommands, either straight away or once the user has agreed to switch.
--
function konfer:OnPolicyCommand(input, pol)
  local cmd, pos = K.GetArgs(input or "")

  --
  -- Resuming is the mod's own command, so there is nothing a policy's command can usefully do while the mod is switched off.
  --
  if (self:IsSuspended()) then
    self:SaySuspended()
    return
  end

  if (not cmd or cmd == "") then
    self:OpenPolicy(pol.handle)
    return
  end

  local kcmd = pol.command or L["CMDNAME"]

  cmd = strlower(cmd)

  if (cmd == L["CMD_HELP"] or cmd == "?") then
    policy_usage(pol)
    return
  end

  -- A ready check is the group's, the Raid page's Ready check by another road, whichever policy is active.
  if (cmd == L["CMD_READYCHECK"]) then
    self:ReadyCheck(pol)
    return
  end

  -- And so are the raid info check and the version check, each the mod's own.
  if (checkcmdtab[cmd]) then
    checkcmdtab[cmd](command_args(input, pos))
    return
  end

  -- The policy's own splash, whichever is active, needing no configuration.
  if (cmd == L["CMD_ABOUT"]) then
    self:ShowPolicySplash(pol)
    return
  end

  -- Then the words the policy has of its own (Commands in Policy.lua), which every one of them needs a configuration for.
  local own = nil

  for _, c in ipairs(pol.Commands or {}) do
    if (strlower(c.word) == cmd) then
      own = c
    end
  end

  if (not pcmdtab[cmd] and own) then
    if (check_config(pol)) then
      return true
    end

    local _, rv = konfer:PolicyHook(pol, own.word, nil, own.Run, command_args(input, pos), pol)

    return rv
  end

  if (not pcmdtab[cmd]) then
    pol:err(L["%q is not a valid command. Type %s for help."], white(cmd), white(strfmt("/%s %s", kcmd, L["CMD_HELP"])))
    return
  end

  --
  -- The two that still work with no configuration in hand, one making the first one and the other choosing between them.
  -- Everything else works on a configuration and has nothing to say without one.
  --
  local nocfgok = cmd == L["CMD_CREATECONFIG"] or cmd == L["CMD_SELECTCONFIG"]

  if (not nocfgok and check_config(pol)) then
    return true
  end

  pcmdtab[cmd](command_args(input, pos), pol)
end

--
-- Function: konfer:RefreshCSData() Purpose : Re-calculate session temporary config values based on the current stored values
-- in each config. Returns : Nothing.
--
-- One of the few things that genuinely spans policies, and it does so by asking each in turn rather than by reaching into a
-- pile they share. What it computes is per config, so which policy a config came from does not matter here; that every
-- config gets looked at does.
--
function konfer:RefreshCSData()
  for kp, pol in pairs(self.policies) do
    for k, v in pairs(self:PolicyConfigs(pol)) do
      v:UpdateUserSecurity()
    end
  end

  if (self.apol.currentid) then
    config_admin(self)
  end
end

--
-- Whether this character may change config CFG, and the guard every path that edits one opens with. Named for the answer
-- that stops you rather than the act of asking, so that a call site reads as what it does:
--
--   if (cfg:IsDenied()) then return end
--
-- Says so on the way out, under the owning policy's name, because being told nothing happened is worse than being told why.
-- A config this character cannot see at all is denied silently: there is nothing there to explain.
--
function cfgm:IsDenied()
  if (not self:MyStatus()) then
    local pol = self:GetPolicy() or konfer.apol
    pol:err(L["you do not have permission to do that in this configuration."])
    return true
  end

  return false
end

--
-- You may push a config at other people if you administer it and the people on the other end will accept it from you, which
-- is the same test they will apply when it arrives: an officer of the guild, or whoever is running the group. Being the
-- master looter counts too, that being a statement about who is running this raid rather than about the guild.
--
-- Both buttons ask about the config on screen, which is the active policy's, and that is also the config the raid is run
-- against, so who is missing is always somebody this window has to add.
--
-- konfer:MayBroadcast is the first test, and dark too while the last broadcast's konfer.BCAST_GAP runs, for the Sync page's
-- Broadcast and the Raid page's.
--
function konfer:MayBroadcast(cfg)
  return (cfg and cfg:MyStatus() and not self.bcastwait and (self:AmIML() or self:IsElevated(K.player.name))) and true or false
end

local function refresh_window_buttons(self)
  local pp = self.apol

  if (not self.qf or not pp) then
    return
  end

  local admin = pp.currentid and pp.cfg:MyStatus()

  if (self.qf.bcastbutton) then
    self.qf.bcastbutton:SetEnabled(self:MayBroadcast(pp.currentid and pp.cfg))
  end

  if (self.qf.addmissing) then
    self.qf.addmissing:SetEnabled((admin and KRP.in_party and self.raid.nmissing > 0) and true or false)
  end
end

local function update_bcast_button(self)
  --
  -- A raider who has not yet accepted a broadcast has no config, and leadership and roles still change around them.
  --
  if (self.apol.currentid) then
    self.apol.cfg:UpdateUserSecurity()
  end

  refresh_window_buttons(self)
end

-- Every Broadcast button worked out again, as konfer.bcastwait starts and ends: the Sync page's, the foyer's, and a policy page's.
function konfer:RefreshBroadcastButtons()
  refresh_window_buttons(self)
  self:RefreshFoyerButtons()
  self:RefreshPolicyPages()
end

function konfer:MakeAliases()
  self.frdb = self.db.factionrealm
  self.chardb = self.db.char
  self.globaldb = self.db.global

  if (not self.chardb.winpos) then
    self.chardb.winpos = {}
  end

  if (not self.frdb.policyorder) then
    self.frdb.policyorder = {}
  end

  if (not self.frdb.policydisabled) then
    self.frdb.policydisabled = {}
  end

  --
  -- A policy is always active, so that the platform never has to test for one before reaching through it. With no config in
  -- hand yet that is whichever policy a config would default to.
  --
  if (not self.apol) then
    self.apol = self:GetPolicy(nil)
  end

  --
  -- Every policy, not just the active one. An inactive policy still holds the config it last had, still takes sync and
  -- broadcasts about it, and is still what the user will find waiting when they switch back, so its aliases have to be right
  -- whether or not anything is showing it.
  --
  for k, pol in pairs(self.policies) do
    self:SetPolicyCurrent(pol, pol.currentid)
  end
end

function konfer:FullRefreshUI(reset)
  self:RefreshConfigUI(reset)
  self:RefreshListsUI(reset)
  self:RefreshLootUI(reset)
  self:RefreshUsersUI(reset)
  self:RefreshSyncUI(reset)

  -- The foyer lists every policy's configs and what this player is in each, so anything that refreshes a page may change it.
  self:RefreshFoyerUI()
end

--
-- Show or hide every page and tab according to what this user is allowed to see in the current config. A page or tab
-- declares its own requirement in the page tree in Init.lua -- adminonly for any of the config's admins, owneronly for its
-- owner alone, notadmin for anybody who is neither, nomasterloot for a game without master loot -- and we simply walk the
-- tree and apply it. A policy's own tabs and pages declare theirs the same way (ConfigTabs, Pages). A platform page the
-- active policy has no use for (hidepages in Policy.lua) is hidden whoever is looking, one about the group (ingroup) is
-- hidden out of one unless the active policy keeps it up (RaidPage.solo), and a policy's own page with a Shown is hidden
-- while that answers false.
--
-- Nothing here knows where anything sits in its strip. KoreUI closes the strips up around whatever we hide, and moves off a
-- page or tab that this user may no longer see, so there is no bouncing to a safe page to do here.
--
local function apply_page_security(self)
  --
  -- What this player may see is a question about the config on screen, which is the active policy's.
  --
  local pp = self.apol

  if (not self.mainwin) then
    return
  end

  local is_admin = pp and pp.currentid and pp.cfg:MyStatus()
  local admin = is_admin and true or false
  local owner = (is_admin == 2)

  local function allowed(cfg)
    if (cfg.nomasterloot and K.HAS_MASTER_LOOT) then
      return false
    end

    if (cfg.notadmin) then
      return not admin
    end

    if (cfg.owneronly) then
      return owner
    end

    if (cfg.adminonly) then
      return admin
    end

    return true
  end

  local unused = (pp and pp.hidepages) or {}
  local grouped = KRP.in_party or (pp and pp.RaidPage and pp.RaidPage.solo)
  local gone = {}

  for _, p in ipairs((pp and pp.Pages) or {}) do
    if (p.Shown) then
      local _, shown = self:PolicyHook(pp, "Pages.Shown", false, p.Shown)

      gone[pp.prefix .. p.name] = not shown
    end
  end

  for k, pg in ipairs(self.mainwin.pages) do
    self.mainwin:SetPageShown(pg.name, allowed(pg.cfg) and not unused[pg.name] and (grouped or not pg.cfg.ingroup)
      and not gone[pg.name])

    for kk, tab in ipairs(pg.tabs) do
      self.mainwin:SetTabShown(pg.name, tab.name, allowed(tab.cfg))
    end
  end
end

--
-- RefreshCSData walks every config calling UpdateUserSecurity on each, so there is nothing for a bare call to add here. A
-- change in who this player is lands on all of them, not just whichever one is active.
--
function konfer:FullRefresh(reset)
  K.UpdatePlayerAndGuild(true)
  self:RefreshCSData()
  self:FullRefreshUI(reset)
  KRP.UpdateGroup(true, true, false)

  apply_page_security(self)
  refresh_window_buttons(self)
end

--
-- What the Shown of one of POL's own pages answers may have changed (Pages in Policy.lua), so the window's pages are asked
-- again. RAISE, the name of one of POL's pages, is then the page the window shows, the window raised with it, if it is
-- there. A page that has gone while it was on screen leaves the window on the page before it, as any hidden page does.
-- Nothing while POL is not the active policy, whose pages are the only ones up.
--
function konfer:PolicyPagesChanged(pol, raise)
  if (not self.mainwin or not pol or pol ~= self.apol) then
    return
  end

  apply_page_security(self)

  if (raise and self.mainwin:IsPageShown(pol.prefix .. raise)) then
    self.mainwin:Show()
    self.mainwin:SetPage(pol.prefix .. raise)
  end
end

local function player_info_updated(evt, ...)
  if (konfer.initialised) then
    konfer:RefreshCSData()
  end

  konfer:FullRefreshUI(false)
end

--
-- Whether this character had a guild when last told. Everything guild related in the window is lit by it (guild import, rank
-- filtering, guild announcements), so joining or leaving one redraws the window rather than waiting for something else to.
--
local was_guilded = nil

local function guild_info_updated(evt, ...)
  local iv = { text = K.NONE_STR, value = 0 }
  local rvals = {}
  tinsert (rvals, iv)

  if (was_guilded ~= nil and was_guilded ~= K.player.is_guilded and konfer.initialised) then
    konfer:FullRefreshUI(false)
  end
  was_guilded = K.player.is_guilded and true or false

  if (K.player.is_guilded) then
    for i = 1, K.guild.numranks do
      iv = {text = K.guild.ranks[i], value = i }
      tinsert (rvals, iv)
    end
  end

  --
  -- Every rank choice the mod itself offers: the live filter on the Loot page, a list's on the Lists page and an item's in
  -- the item editor. The window keeps whatever each had selected, and putting it back is not a user choosing it, so the
  -- event is suppressed. A dropdown's handler is where an edit in progress is recorded, and refilling a list of guild ranks
  -- must not look like an edit.
  --
  local ranked = { "lootrank", "listrank", "itemrank" }

  for _, w in ipairs(ranked) do
    local dd = konfer.qf and konfer.qf[w]

    if (dd) then
      local oldr = dd:GetValue() or 0

      dd:UpdateItems(rvals)
      dd:SetValue(oldr, true)
    end
  end

  --
  -- Any rank choice a policy offers of its own is its own to refill, and every policy is told rather than only the active
  -- one: a policy switched to later would otherwise be offering the ranks of whatever guild this character was in when its panels were built.
  --
  for k, pp in pairs(konfer.policies) do
    if (pp.GuildRanksChanged) then
      konfer:PolicyHook(pp, "GuildRanksChanged", nil, pp.GuildRanksChanged, pp, rvals)
    end
  end
end

function konfer:RefreshRaid()
  KRP.UpdateGroup(true, true, false)
end

--
-- Work out the strict and relaxed class filters and the BoE flag for an item, writing them into TI. Split out from
-- AddItemToBossLoot so it can be redone in place when GET_ITEM_INFO_RECEIVED fills in an item we did not have.
--
function konfer:SetBossLootFilters(ti)
  local ilink = ti.ilink
  local slot, icls, isubcls = K.GetItemClassInfo(ilink)
  local filt, boe, cached = K.GetItemClassFilter(ilink)

  ti.boe = boe
  ti.needsfilter = (not cached) or nil

  if (icls == K.classfilters.weapon) then
    if (filt == K.classfilters.allclasses) then
      ti.strict = K.classfilters.weapons[isubcls]
      ti.relaxed = ti.strict
    else
      ti.strict = filt
      ti.relaxed = filt
    end
  elseif (icls == K.classfilters.armor) then
    if (filt == K.classfilters.allclasses) then
      ti.strict = K.classfilters.strict[isubcls]
      ti.relaxed = K.classfilters.relaxed[isubcls]
      if (slot == "INVTYPE_CLOAK") then
        --
        -- Most cloaks are reported as type cloth, so we dont want to filter out other classes that can legitimately use
        -- the cloak. So we set cloaks to relaxed, even if we have strict class armour filtering on.
        --
        ti.strict = ti.relaxed
      end
    else
      ti.strict = filt
      ti.relaxed = filt
    end
  else
    ti.strict = filt
    ti.relaxed = filt
  end

  -- These are indexed character by character later on and must never be nil.
  ti.strict = ti.strict or K.classfilters.allclasses
  ti.relaxed = ti.relaxed or K.classfilters.allclasses

  return ti
end

-- ILINK goes on the loot list, QUANT of it, from LOOTSLOT, and with PRICE, what the master looter sent it costs, on a raider.
function konfer:AddItemToBossLoot(ilink, quant, lootslot, price)
  self.raid.bossloot = self.raid.bossloot or {}

  local ti = {
    itemid = match(ilink, "item:(%d+)"), ilink = ilink,
    slot = lootslot or 0, quant = quant, price = price,
  }

  self:SetBossLootFilters(ti)
  tinsert(self.raid.bossloot, ti)

  if (ti.needsfilter) then
    self:WatchPendingItems()
  end
end

--
-- Called by KRP whenever it is starting a round of updates for the group. We use this to reset the private data member
-- called users, which is a map of Konfer user ID's to player names. This is useful in many places in Konfer to determine
-- whether or not the given UID is in the raid, for example, as well as other uses. So when we start the round of updates we
-- null out that table as it is about to be re-populated.
--
-- Who is in the group, and who of them the config is missing, are counted afresh every time, so that somebody who has left is neither.
--
local function krp_update_group_start(_, _, pvt, ...)
  konfer.raid.uidmap = {}
  konfer.raid.missing = {}
  konfer.raid.nmissing = 0
end

--
-- This is called by KRP whenever it refreshes the raid groups and a new player is added to the players list. We are called
-- with the player info as it currently exists. For ease of use later we store the Konfer user ID if it exists in the player structure.
--
-- This must be called whenever we change configs as the info we add to each player is unique to the current config.
--
local function krp_new_player(_, _, pvt, player)
  -- Somebody arriving while the leader collects the group's loot is asked to consent, whatever config is in hand.
  konfer:GroupLootJoined(player.name)

  if (konfer:IsTempCfg(konfer.apol)) then
    return
  end

  local nm = player.name

  player["konfer_uid"] = nil
  player["konfer_missing"] = nil

  local uid = konfer.apol.cfg:FindUser(nm)

  --
  -- Somebody the config does not hold is keyed here by their name, that being the only name for them there is. It is the
  -- one table in the mod keyed that way and it is why: a uid is what a config has issued, and the whole point of this table
  -- is the people it has issued none for.
  --
  if (not uid) then
    local classid = player.class

    if (not konfer.raid.missing[nm]) then
      konfer.raid.nmissing = konfer.raid.nmissing + 1
      konfer.raid.missing[nm] = { name = nm, class = classid }

      -- The missing are counted afresh on every roster update, and each is told about once a raid.
      konfer.raid.missingwarned = konfer.raid.missingwarned or {}

      if (KRP.in_party and (KRP.is_ml or konfer:Collecting()) and konfer.apol.cfg:MyStatus()
        and not konfer.raid.missingwarned[nm]) then
        konfer.raid.missingwarned[nm] = true
        konfer.apol:info(L["User %q is in the raid but not in the user list."], class(nm, classid))
      end
    end
    player["konfer_missing"] = true
    refresh_window_buttons(konfer)
  else
    konfer.raid.uidmap[uid] = nm
    player["konfer_uid"] = uid
  end
end

--
-- The disenchanters the raid has, as the uids of those online, in the order the config names them, which is the order they
-- are offered in. Worked out from the config and the raid each time rather than remembered per player, so that choosing a
-- different disenchanter mid-raid counts at once. Called whenever either changes.
--
-- The config stores uids and this holds uids, so the raid map is asked only what it is for, which is whether that uid is
-- here at all. The name comes back out of the uid at the two places that need one, asking the game about them and handing
-- them the item.
--
function konfer:UpdateDenchers()
  self.raid.denchersonline = {}

  local settings = self.apol.cfg and self.apol.cfg.settings

  if (not self.raid.uidmap or not settings or not KRP.players) then
    return
  end

  --
  -- Tonight's three start as the config's. Seeded here rather than when the raid begins, so that a config becoming the
  -- active one part way through brings its own along with it.
  --
  if (not self.raid.denchers) then
    self.raid.denchers = {}

    for i = 1, self.MAX_DENCHERS do
      self.raid.denchers[i] = settings.denchers[i]
    end
  end

  for i = 1, self.MAX_DENCHERS do
    local uid = self.raid.denchers[i]
    local kp = uid and self.raid.uidmap[uid] and KRP.players and KRP.players[self.raid.uidmap[uid]]

    if (kp and kp.online) then
      tinsert(self.raid.denchersonline, uid)
    end
  end
end

--
-- Function: konfer:RaidRank(name, cfgid)
-- Purpose : Where NAME stands in the raid's chain of authority for CFGID, konfer.RAIDRANK_GM being the highest. The guild
--           master, then the config's owner, then whoever leads the raid or assists, then whoever is handing loot out.
-- Returns : One of the konfer.RAIDRANK_ constants, or nil for somebody who is none of those or is not in the group.
--
function konfer:RaidRank(name, cfgid)
  local kp = name and KRP.players and KRP.players[name]

  if (not kp) then
    return nil
  end

  if (kp.is_gm) then
    return self.RAIDRANK_GM
  end

  local cfg = self:Config(cfgid)
  local uid = cfg and cfg:FindUser(name)

  if (uid and cfg.owner == uid) then
    return self.RAIDRANK_OWNER
  end

  if (kp.is_aorl) then
    return self.RAIDRANK_LEADER
  end

  if (kp.is_ml) then
    return self.RAIDRANK_ML
  end

  return nil
end

--
-- Function: konfer:RaidSettingsAnswerer(cfgid, asker)
-- Purpose : Who answers when ASKER asks the raid what tonight's settings are. The highest ranked person in it other than the
--           one asking, and where two stand equal the one whose name sorts first, so that every client works out the same
--           answer without anybody having to agree it. One reply rather than one per admin, and the reply of whoever is most
--           likely to be right. The asker is never their own answerer: somebody asking has just arrived or reloaded and
--           holds nothing, and a client hears nothing it sends, so the highest ranked of all reloading would go unanswered.
--           With no ASKER, the highest ranked of everybody, who answers anybody else.
-- Returns : A character name, or nil where nobody else in the group has any standing at all.
--
function konfer:RaidSettingsAnswerer(cfgid, asker)
  local best, bestname = nil, nil

  for name in pairs(KRP.players or {}) do
    local rank = name ~= asker and self:RaidRank(name, cfgid)

    if (rank and (not best or rank < best or (rank == best and name < bestname))) then
      best, bestname = rank, name
    end
  end

  return bestname
end

--
-- Function: konfer:MaySetRaidSetting(cfgid)
-- Purpose : Whether this character may change something about tonight. Everybody down to whoever leads the raid, and not
--           the master looter for being the master looter: the people who set the raid up did it for them, and are often
--           not in the raid to be overruled.
-- Returns : True or false.
--
function konfer:MaySetRaidSetting(cfgid)
  local rank = self:RaidRank(K.player.name, cfgid)

  return (rank and rank <= self.RAIDRANK_LEADER) and true or false
end

--
-- Function: konfer:RaidSettings()
-- Purpose : Everything the raid agrees on, ready to be handed to somebody who asked. Exactly konfer.raidshared and nothing
--           counted, so that what goes out is the decisions and never this client's view of the group.
-- Returns : Table.
--
function konfer:RaidSettings()
  local out = {}

  for _, k in ipairs(self.raidshared) do
    out[k] = self.raid[k]
  end

  return out
end

--
-- Function: cfg:SetRaidSettings(tbl)
-- Purpose : Take somebody else's picture of tonight whole. A key TBL does not name is cleared rather than kept, because
--           this is one client's answer replacing ours rather than two half pictures being added together, and a stale
--           reservation kept because nobody mentioned it is exactly the bug that would cause.
--
function cfgm:SetRaidSettings(tbl)
  if (type(tbl) ~= "table" or not self:IsActive()) then
    return
  end

  for _, k in ipairs(konfer.raidshared) do
    konfer.raid[k] = tbl[k]
  end

  konfer:UpdateDenchers()
  konfer:RefreshUsers()
  konfer:RefreshAllMemberLists()
end

--
-- Function: cfg:SetRaidDencher(slot, uid, nocmd)
-- Purpose : Point one of tonight's three enchanter slots at UID, or at nobody with a nil. There are konfer.MAX_DENCHERS
--           slots and there is no way to ask for a fourth. The config is not touched: who its enchanters are is a config
--           admin's to say, and this is only who is doing it tonight.
--
function cfgm:SetRaidDencher(slot, uid, nocmd)
  local slot = tonumber(slot)

  if (not slot or slot < 1 or slot > konfer.MAX_DENCHERS or not self:IsActive()) then
    return
  end

  if (not nocmd and not konfer:MaySetRaidSetting(self.id)) then
    return
  end

  konfer.raid.denchers = konfer.raid.denchers or {}
  konfer.raid.denchers[slot] = uid

  konfer:UpdateDenchers()

  --
  -- The whole picture rather than the slot that moved, which is what ACKRS carries either way, so somebody who missed an
  -- earlier change still ends up holding what the sender holds.
  --
  if (not nocmd) then
    konfer:GetPolicy(self.id):CSendAM(self.id, "ACKRS", "ALERT", konfer:RaidSettings())
  end
end

--
-- Called by KRP when it is done updating all of the group info.
--
--
-- The end of a round of group updates, once krp_update_group_start has emptied what is counted and krp_new_player has
-- filled it in again. The enchanters are worked out here rather than per player because which of them are here can only be
-- known once the whole group has been walked.
--
-- A policy with no configuration at all is the same answer as no group, there being nothing for a raid to be run against,
-- so what was counted is torn down rather than left standing. krp_new_player is the one of the three that returns early on it,
-- having nothing to map somebody to; the other two have to run either way, or uidmap is left as an empty table that every
-- test of it reads as a raid going on with nobody in it, and nothing would ever clear it again.
--
-- KRP hands this whether we are in a raid and whether we are in a battleground as well, and neither is wanted. KRP.in_party is
-- already true for a party, a raid or a battleground, so the first of the three answers the only question here.
--
--
-- Whether this character was master looter when last looked. The game says when the loot method or the master looter changes,
-- but a group update works out who is master looter without saying so, a group joined or rejoined and a raid made up by
-- /konfer testraid among them, so both look, and every policy is told when it has changed (MasterLooterChanged in Policy.lua).
--
local was_ml = false

--
-- The leader collecting the group's loot where there is no master loot runs it as a master looter does, so policies hear of
-- them as one. Becoming master looter's questions are about the game's own loot method and are asked of a master looter alone.
--
local function master_looter_changed()
  local isml = (KRP.is_ml or konfer:Collecting()) and true or false

  if (isml == was_ml) then
    return
  end

  was_ml = isml

  for _, pp in pairs(konfer.policies) do
    if (pp.MasterLooterChanged) then
      konfer:PolicyHook(pp, "MasterLooterChanged", nil, pp.MasterLooterChanged, pp, isml)
    end
  end

  if (isml and KRP.in_party and KRP.is_ml) then
    konfer:BecameMasterLooter()
  end
end

-- Who runs the group's loot may just have changed, collecting having begun or ended.
function konfer:LootRunnerChanged()
  master_looter_changed()
end

local function krp_update_group_end(_, _, pvt, in_p, _, _)
  if (in_p and not konfer:IsTempCfg(konfer.apol)) then
    konfer:UpdateDenchers()
  else
    --
    -- Only what was counted from the group goes. What the raid agreed about tonight stays until the raid itself is over,
    -- because dropping group for a moment is not the same as the night ending.
    --
    konfer.raid.uidmap = nil
    konfer.raid.nmissing = 0
    konfer.raid.missing = {}
    konfer.raid.denchersonline = {}
    konfer:ResetBossLoot()
  end

  konfer:RefreshListsUIForRaid(in_p)
  konfer:RefreshAllMemberLists()
  konfer:RefreshUserTicks()
  update_bcast_button(konfer)
  master_looter_changed()

  -- Who leads may have changed, and with it who collects and whose collecting this client passes for.
  konfer:ApplyGroupLoot()
  konfer:RefreshTrades()
end

--
-- Fired when there has been a change in group leadership.
--
local function krp_leader_changed(_, _, pvt, _)
  update_bcast_button(konfer)
end

--
-- Somebody gained or lost one of the marks the raid frames show, leader, assistant, main tank, main assist or master looter,
-- or the raid target mark they wear or the role they have taken in the group moved. The Raid page shows them all beside
-- them, and the first says who may do what there. The active policy is told of the first (StatusChanged in Policy.lua).
--
local function krp_status_changed(_, _, pvt, name, status, onoff)
  local pol = konfer.apol

  if (pol and pol.StatusChanged) then
    konfer:PolicyHook(pol, "StatusChanged", nil, pol.StatusChanged, pol, name, status, onoff)
  end

  konfer:RefreshPolicyPages()
  konfer:RefreshUserTicks()
end

local function krp_shown_changed(_, _, pvt, name, now, old)
  konfer:RefreshPolicyPages()
  konfer:RefreshUserTicks()
end

-- A ready check started, was answered or ended, which the Raid page shows beside each raider.
local function krp_ready_check(_, _, pvt, ...)
  konfer:RefreshPolicyPages()
end

--
-- Fired when the loot method or the master looter changes. Everything the master looter alone may press is worked out again,
-- since this character may have just become the master looter or stopped being it.
--
local function krp_loot_method(_, _, pvt, _)
  update_bcast_button(konfer)
  konfer:RefreshLootUI(false)
  master_looter_changed()
end

--
-- This is fired when the state changes from in raid to out, or out to in.
--
--
-- Ask the group for its raid settings (REQRS), which are about the config loot runs against. Asked on arriving in a group
-- and whenever that config changes while in one, a switch of config or of policy, so it is called freely and asks only
-- when the config in hand is not the one last asked about. Only the config's admins ask.
--
-- In a group means one this mod has been told of, not KRP.in_party. Startup picks its config before it listens, while KRP
-- already knows the group, and a suspended mod hears nothing; both ask when they arrive.
--
function konfer:AskRaidSettings()
  local pp = self.apol

  if (not was_in_party or not pp or self:IsTempCfg(pp) or pp.currentid == asked_cfg) then
    return
  end

  if (pp.cfg:MyStatus()) then
    asked_cfg = pp.currentid
    pp:CSendAM(pp.currentid, "REQRS", "ALERT")
  end
end

--
-- A fresh record for the group the player is in now, saved where there is a group id to keep it against (konfer.raid).
-- SAMEGROUP is a change of config in the same group, which keeps what was asked once for the group (mlasked) and who
-- collects its loot with whose consent, and nothing else, everything else being about running this raid against the config
-- it is leaving.
--
local GROUP_KEPT = { "mlasked", "collecting", "collector", "consent", "consents", "asked" }

function konfer:EmptyRaid(samegroup)
  local was = self.raid

  self.raid = { group = KRP.group_id }

  if (samegroup and was and was.group == self.raid.group) then
    for _, k in ipairs(GROUP_KEPT) do
      self.raid[k] = was[k]
    end
  end

  if (self.chardb) then
    self.chardb.raid = self.raid.group and self.raid or nil
  end
end

--
-- The game has said which group the player is in, or that there is none. A record kept for another group is over. One kept
-- for no group yet is this group's from now on, so that anything set before the game said, raid settings that arrived first
-- among it, stays.
--
local function krp_group_id_changed(_, _, pvt, id, old)
  if (konfer.raid.group and konfer.raid.group ~= id) then
    konfer:EmptyRaid()
    konfer:FullRefreshUI(false)
  else
    konfer.raid.group = id
    konfer.chardb.raid = id and konfer.raid or nil
  end
end

local function krp_in_group_changed(_, _, pvt, in_party, _, _)
  local arrived = in_party and not was_in_party

  --
  -- Becoming master looter in the next group is asked about afresh, with a config in hand or not, which is why this is not
  -- left to the emptying of konfer.raid further down.
  --
  if (was_in_party and not in_party) then
    konfer.raid.mlasked = nil
  end

  was_in_party = in_party and true or false

  --
  -- The other admins in a group we have just joined can drop the events we already have, whichever policy is active, and
  -- the group is asked what it agreed. A switch of config or policy asks for itself.
  --
  if (arrived) then
    asked_cfg = nil
    konfer:SyncCleanup(true)
    konfer:AskRaidSettings()
  end

  -- The Raid page comes with the group and goes with it.
  apply_page_security(konfer)

  if (konfer:IsTempCfg(konfer.apol)) then
    return
  end

  if (in_party) then
    if (KRP.is_ml and not konfer.apol.cfg:MyStatus()) then
      if (not konfer.raid.admin_warned) then
        konfer.raid.admin_warned = true
        konfer.apol:info(
          L["you are the master looter but not an administrator of this configuration. You will be unable to loot effectively. Either change master looter or have the owner of the configuration assign you as an administrator."])
      end
    end
  else
    --
    -- The raid is over. Everything that was only true for the duration of it goes in one assignment, which is the whole
    -- reason konfer.raid is one table: reservations meant "count them as here tonight" and there is no tonight any more,
    -- and an undo stack for awards nobody can now make is worse than none.
    --
    konfer:EmptyRaid()
    konfer:FullRefreshUI(false)
  end
end

--
-- Whether Konfer runs this loot at all. Every step of the loot path asks, because each can act on its own: the item step
-- builds the boss loot table from nothing, so gating only the first step would still have Konfer offering items in a group
-- it was never meant to be in.
--
-- konfer.comms says where the mod belongs, so a raid-only setup opening a chest in a five man dungeon assigns nothing, opens
-- no window, sends no OLOOT and announces nothing.
--
--
-- Made up loot (/konfer testloot) plays master looter for itself alone. A real loot window opened while it is up, a herb
-- picked, is not this client's to hand out, and would throw the made up loot away besides.
--
-- A leader collecting the group's loot takes it from the rolls they win (konfer:CollectedLoot), never from a corpse, whose
-- items are still being rolled for and which would throw away what has been won and not yet handed out.
--
local function loot_applies()
  local ml = konfer:AmIML() and not konfer:Collecting()

  ml = ml and not konfer.testloot -- @debug-delete@

  return ml and konfer:IsUsableHere()
end

local function kld_start_loot_info(_, _, pvt)
  if (not loot_applies()) then
    return
  end

  konfer:ForgetDeliveries()
  konfer:ResetBossLoot()
end

--
-- An item the loot engine asked the game to hand out has gone, or the loot window closed without it going.
--
local function kld_loot_assigned(_, _, pvt, slot, target)
  konfer:LootAssigned(slot, target)
end

local function kld_loot_not_assigned(_, _, pvt, slot, target)
  konfer:LootNotAssigned(slot, target)
end

--
-- A boss fight ended, won or lost. Only the active policy is told, being the one that runs loot (EncounterEnded in Policy.lua).
--
local function kld_encounter_ended(_, _, pvt, enc)
  local pol = konfer.apol

  if (pol and pol.EncounterEnded) then
    konfer:PolicyHook(pol, "EncounterEnded", nil, pol.EncounterEnded, pol, enc)
  end
end

--
-- This is called by KLD whenever a new item is added to the loot table, and says whether the item is offered: not when it
-- is ignored, below the quality threshold, or unreadable.
--
local function kld_loot_item(_, _, pvt, item)
  if (not loot_applies()) then
    return
  end

  local skipit = false
  local itemid = nil
  local assigned = false

  if (item["itemid"]) then
    itemid = item["itemid"]
  end

  if (not item.ilink or item.ilink == "" or not itemid) then
    skipit = true
  end

  if (item.locked) then
    skipit = true
  end

  --
  -- Only what a master looter can hand out is offered. A herb, ore, a catch of fish or anything looted outside master loot has
  -- nobody the game will give it to. The game can also open a corpse before it knows who may have what is on it, so an item
  -- skipped for having nobody is looked at again when they arrive (kld_candidates_updated).
  --
  if (not next(item.candidates or {})) then
    skipit = true
    item.konfer_nobody = true
  end

  if (itemid and konfer.apol.cfg.items[itemid]) then
    if (konfer.apol.cfg.items[itemid].ignore) then
      skipit = true
    else
      local aa = konfer.apol.cfg.items[itemid].autoassign

      assigned = aa and aa ~= konfer.AUTOASSIGN_NOBODY and true or false
    end
  elseif (itemid and konfer.iitems[itemid]) then
    if (konfer.iitems[itemid].ignore) then
      skipit = true
    end
  end

  local bthresh = tonumber(konfer.apol:Setting("bid_threshold", konfer.apol.currentid) or "0") or 0
  local iqual = tonumber(item.quality or "0") or 0

  --
  -- An item marked to ignore the quality threshold is offered however low its quality, and so is one set to go to the
  -- enchanter or the master looter, which is offered so that picking it can ask whether to (see the loot page's instructions).
  --
  local ignorequal = itemid and konfer.apol.cfg.items[itemid] and konfer.apol.cfg.items[itemid].ignorequal

  if (not skipit and not assigned and not ignorequal) then
    if (bthresh ~= 0 and iqual < bthresh) then
      skipit = true
    end
  end

  item["konfer_skipit"] = skipit

  if (not skipit) then
    konfer:AddItemToBossLoot(item.ilink, item.quantity, item.lootslot)
  end
end

--
-- This is fired when a corpse has been looted and we have retrieved all of the lootable items. It can also be fired when we
-- have changed the various user lists and we want to refresh the loot so that the callbacks can access the new data.
--
local function kld_end_loot_info()
  if (not loot_applies()) then
    return
  end

  local nbossloot
  local ilist = {}

  if (not KLD.unit_name or not KLD.items or not konfer.raid.bossloot) then
    konfer.raid.bossloot = nil
    nbossloot = 0
  else
    nbossloot = #konfer.raid.bossloot
    for k, v in ipairs(konfer.raid.bossloot) do
      local ti = { v.ilink, v.quant, konfer:LootPrice(v.ilink) or false }
      tinsert(ilist, ti)
    end
  end

  if (nbossloot == 0) then
    konfer:ResetBossLoot()
  end

  konfer:RefreshBossLoot(nil)

  if (nbossloot > 0) then
    --
    -- The name is for the announcement below and goes no further. What dropped it is the master looter's own line of chat,
    -- and a receiver has never had anything to show it with, so only the identity travels.
    --
    local uname = KLD.unit_name
    local uguid = KLD.unit_guid
    local realguid = KLD.unit_realguid

    sentoloot = true
    konfer.apol:CSendAM(konfer.apol.currentid, "OLOOT", "ALERT", uguid, realguid, ilist)

    if (konfer.apol.cfg.settings.auto_bid) then
      local mainwin = konfer.mainwin

      if (not mainwin:IsVisible()) then
        konfer.autoshown = true
      end
      mainwin:Show()
      mainwin:SetPage(konfer.LOOT_PAGE, konfer.LOOT_ASSIGN_TAB)
    end

    local where = konfer:LootAnnouncedTo(konfer.apol, konfer.apol.cfg.settings.announce_where)

    if (where ~= 0) then
      local gs = konfer.raid
      gs.announcedloot = gs.announcedloot or {}
      local sendfn = konfer.SendGuildText
      if (where == 2) then
        sendfn = konfer.SendText
      end

      --
      -- Only a real GUID is an identity, so only a real GUID says a source has been announced already. A chest's is made
      -- out of what is inside it and an item added by hand has none at all, and two of either are two sources.
      --
      local dloot = true
      if (realguid) then
        if (gs.announcedloot[uguid]) then
          dloot = false
        end
        gs.announcedloot[uguid] = true
      else
        -- Loot with nothing to tell one source from another is announced unless something was, within the last minute.
        local last = gs.lastannouncetime
        if (last and difftime(time(), last) < 60) then
          dloot = false
        end
      end

      if (dloot) then
        sendfn(konfer, strfmt(L["Loot from %s: "], uname))
        for k,v in ipairs(konfer.raid.bossloot) do
          sendfn(konfer, v.ilink)
        end
        gs.lastannouncetime = time()
      end
    end
  end
end

--
-- The candidates for what is on the corpse arrived after it opened. An item skipped for having nobody that has somebody now
-- is offered by reading the corpse again, which is done only while nothing on it is offered yet, reading it again being the
-- end of any bid or roll on it.
--
local function kld_candidates_updated(_, _, pvt)
  if (not loot_applies() or konfer.raid.bossloot or not KLD.items) then
    return
  end

  for _, item in pairs(KLD.items) do
    if (item.konfer_nobody and next(item.candidates or {})) then
      KLD.RefreshLoot()
      return
    end
  end
end

local function kld_looting_ended(_, _, pvt)
  if (not loot_applies()) then
    return
  end

  konfer:CloseLoot()
  konfer:ResetBossLoot()

  if (konfer.autoshown) then
    konfer.autoshown = nil
    konfer.mainwin:Hide()
  end

  if (sentoloot) then
    konfer.apol:CSendAM(konfer.apol.currentid, "CLOOT", "ALERT")
  end
  sentoloot = nil
end

--
-- Any class filter worked out while the client did not yet have the item data is provisional. When the data turns up, redo
-- it: for the loot currently on offer, and for stored items in any config that recorded one as pending.
--
local function item_info_received(evt, itemid, success)
  if (not itemid or not success or not konfer.initialised) then
    return
  end

  local sitemid = tostring(itemid)
  local refreshloot = false

  if (konfer.raid.bossloot) then
    for k, v in ipairs(konfer.raid.bossloot) do
      if (v.needsfilter and tostring(v.itemid) == sitemid) then
        konfer:SetBossLootFilters(v)
        refreshloot = true
      end
    end
  end

  for cfgid, cfp in pairs(konfer:AllConfigs()) do
    local pend = cfp:Session().pendingitems
    if (pend and pend[sitemid]) then
      local ii = cfp.items and cfp.items[pend[sitemid]]
      if (ii) then
        local ifs, cached = konfer:DeriveItemClassFilter(ii.ilink)
        if (cached) then
          ii.cfilter = ifs
          pend[sitemid] = nil
          if (cfp:IsActive()) then
            konfer:RefreshItemList()
          end
        end
      else
        pend[sitemid] = nil
      end
    end
  end

  -- Learning about an item changes nothing about what is selected or being bid on.
  if (refreshloot) then
    konfer:RedrawBossLoot()
  end

  konfer:WatchPendingItems()
end

--
-- GET_ITEM_INFO_RECEIVED fires for every item the client resolves - bags, the auction house, tooltips, other addons' queries
-- so it is far too noisy to sit on permanently for something that comes up once or twice a raid. Listen only while a
-- provisional class filter is actually waiting on an item.
--
-- WatchPendingItems is called after anything that can create pending state, and from the handler itself, so a path that
-- clears the last pending item without saying so costs at most one more event before we unregister.
--
local item_watch = false

local function items_pending()
  if (konfer.raid.bossloot) then
    for k, v in ipairs(konfer.raid.bossloot) do
      if (v.needsfilter) then
        return true
      end
    end
  end

  for cfgid, cfp in pairs(konfer:AllConfigs()) do
    local pend = cfp:Session().pendingitems

    if (pend and next(pend)) then
      return true
    end
  end

  return false
end

function konfer:WatchPendingItems()
  --
  -- A suspended mod wants nothing from the game, however many items are still waiting on their names. They will still be waiting when it resumes.
  --
  local want = not self:IsSuspended() and items_pending()

  if (want == item_watch) then
    return
  end

  item_watch = want

  if (want) then
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", item_info_received)
  else
    self:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
  end
end

--
-- QUESTIONS IN TURN
--
-- Konfer asks the player things of its own accord, at startup and on becoming master looter, and never two at once: each
-- waits for the one before it to close. A question is a step, a function handed AFTER that shows a dialog and answers true,
-- calling AFTER once the dialog has closed, or shows nothing and answers false. Steps are asked in the order they are handed
-- in, and FIRST puts one at the head of the line instead, for a question that follows straight on from the one up now.
--
local turns = {}
local turning = false

local function next_turn()
  local step = tremove(turns, 1)

  turning = step ~= nil

  if (not step) then
    return
  end

  local done = false

  local function after()
    if (not done) then
      done = true
      next_turn()
    end
  end

  if (not step(after)) then
    after()
  end
end

function konfer:InTurn(step, first)
  tinsert(turns, first and 1 or (#turns + 1), step)

  if (not turning) then
    next_turn()
  end
end

--
-- The dialogs a player may be shown at startup, each a step for konfer:InTurn. On retail the warning that Konfer is untested
-- there, then, for a character not yet asked, which specs to report, and then whatever each policy switched on asks for
-- itself (StartupDialog in Policy.lua), in the order the foyer shows them. Each knows for itself whether it has anything to
-- ask, so this runs at every login, as soon as Konfer is ready, and never opens in the middle of a fight.
--
local function startup_steps(self)
  local steps = {
    function(after)
      return self:ShowUntestedNotice(after)
    end,
    function(after)
      return self:AskSpecs(after)
    end,
  }

  local pols = {}

  for handle, pol in pairs(self.policies) do
    if (pol.StartupDialog and not self:IsPolicyDisabled(handle)) then
      tinsert(pols, pol)
    end
  end

  tsort(pols, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)

  for _, pol in ipairs(pols) do
    tinsert(steps, function(after)
      local _, shown = self:PolicyHook(pol, "StartupDialog", false, pol.StartupDialog, pol, after)

      return shown and true or false
    end)
  end

  return steps
end

local function startup_dialogs(self)
  if (self:IsSuspended()) then
    return
  end

  if (InCombatLockdown()) then
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
      self:UnregisterEvent("PLAYER_REGEN_ENABLED")
      startup_dialogs(self)
    end)
    return
  end

  for _, step in ipairs(startup_steps(self)) do
    self:InTurn(step)
  end
end

local function konfer_initialised(self)
  if (self.initialised) then
    return
  end

  self.initialised = true

  --
  -- The raid record this character left the game with, while it is still in that group, and a fresh one otherwise. What
  -- was on the corpse is not kept, the reload having closed the loot window (konfer.raid).
  --
  local kept = self.chardb.raid

  if (kept and kept.group and kept.group == KRP.group_id) then
    kept.bossloot = nil
    self.raid = kept
  else
    self:EmptyRaid()
  end

  --
  -- On Konfer rather than on Kore. A message handler is kept per object and per message, so one registered on Kore would
  -- replace Kore's own, KoreParty's included.
  --
  self:RegisterMessage("PLAYER_INFO_UPDATED", player_info_updated)
  self:RegisterMessage("GUILD_INFO_UPDATED", guild_info_updated)

  --
  -- We prefer to use callbacks to messages because callbacks are not called if the mod isn't currently active.
  --
  local kh = self.addon_handle
  KLD:AddonCallback(kh, "start_loot_info", kld_start_loot_info)
  KLD:AddonCallback(kh, "loot_item", kld_loot_item)
  KLD:AddonCallback(kh, "end_loot_info", kld_end_loot_info)
  KLD:AddonCallback(kh, "candidates_updated", kld_candidates_updated)
  KLD:AddonCallback(kh, "looting_ended", kld_looting_ended)
  KLD:AddonCallback(kh, "loot_assigned", kld_loot_assigned)
  KLD:AddonCallback(kh, "loot_not_assigned", kld_loot_not_assigned)
  KLD:AddonCallback(kh, "encounter_ended", kld_encounter_ended)
  KLD:AddonCallback(kh, "group_loot_rolled", function() konfer:GroupLootRolled() end)
  KLD:AddonCallback(kh, "group_loot_won", function(_, _, _, ilink) konfer:CollectedLoot(ilink) end)
  KLD:AddonCallback(kh, "trade_delivered", function(_, _, _, id, ilink, to) konfer:TradeDelivered(id, ilink, to) end)
  KRP:AddonCallback(kh, "update_group_start", krp_update_group_start)
  KRP:AddonCallback(kh, "update_group_end", krp_update_group_end)
  KRP:AddonCallback(kh, "new_player", krp_new_player)
  KRP:AddonCallback(kh, "in_group_changed", krp_in_group_changed)
  KRP:AddonCallback(kh, "group_id_changed", krp_group_id_changed)
  KRP:AddonCallback(kh, "leader_changed", krp_leader_changed)
  KRP:AddonCallback(kh, "role_changed", krp_leader_changed)
  KRP:AddonCallback(kh, "status_changed", krp_status_changed)
  KRP:AddonCallback(kh, "mark_changed", krp_shown_changed)
  KRP:AddonCallback(kh, "assigned_changed", krp_shown_changed)
  KRP:AddonCallback(kh, "readycheck_start", krp_ready_check)
  KRP:AddonCallback(kh, "readycheck_reply", krp_ready_check)
  KRP:AddonCallback(kh, "readycheck_end", krp_ready_check)
  KRP:AddonCallback(kh, "loot_method", krp_loot_method)

  relay_group_lines()

  konfer_suspended(self.frdb.suspended)

  if (self.apol.cfg) then
    self.apol.cfg:SetDefault(true, true)
  end
  self:FullRefresh(true)
  config_admin(self)

  --
  -- Broadcasts a list of all configurations we have, and the latest events we have for each user. The recipients of the
  -- message use this to trim old events from their lists to save space.
  --
  self:SyncCleanup()

  startup_dialogs(self)
end

--
-- Konfer's descriptor for KoreComms: who we are, and nothing else. KC.RegisterComms() reads this and injects the sends.
--
-- This describes the mod's own endpoint, which carries only the mod's own messages: config broadcasts, sync and the like.
-- Each policy is an endpoint of its own, and they all share the one prefix this one names. Where a policy may talk is the
-- policy's own (pol.bg, read by konfer:MakeSends and konfer:IsUsableHere), and the mod's messages go wherever the player
-- is, since they serve whichever policy is usable there.
--
-- The rest of the fields here are this mod describing itself for its own windows and commands. Kore reads none of them.
--
konfer.comms = {
  handle     = konfer.addon_handle,
  name       = L["MODNAME"],
  title      = L["MODTITLE"],
  desc       = L["Loot distribution system."],
  cmd        = L["CMDNAME"],
  version    = konfer.version,
  suspendcmd = L["CMD_SUSPEND"],
  resumecmd  = L["CMD_RESUME"],
}

function konfer:OnLateInit()
  if (self.initialised) then
    return
  end

  self.db = DB:New("KonferDB", nil, "Default")

  --
  -- The aliases into the database, and the tables in it that have to exist, are made the moment it is open, whether or
  -- not there is a config to select yet. The windows built below read their saved places through konfer.chardb.
  --
  self:MakeAliases()

  --
  -- Everything from here down reaches the config it works on through the active policy, so one has to be active before any
  -- of it runs. This is the policy a config falls back to when it names none; SetDefault replaces it below with the
  -- policy governing the config it selects.
  --
  self.apol = self:GetPolicy(nil)

  --
  -- The database is brought up to date before anything reads it.
  --
  self:UpdateDatabaseVersion()

  --
  -- A config's settings are two strings with a metatable over them that reads them by name, and a metatable is not saved.
  -- So every config that just came back out of the saved variables has the strings and no way to read them until this runs,
  -- and it runs before anything asks one a question.
  --
  self:MakeAllConfigs()

  --
  -- Each policy picks up whichever of its own configs it had in hand when the user last logged out, and a policy that has
  -- never been set up simply has none. There is no placeholder standing in for one: a policy with nothing in it is an
  -- ordinary state that the rest of the mod is written to expect, and inventing a config named " " to avoid saying so put a
  -- lie in the saved variables and a special case in every file that read it.
  --
  for k, pol in pairs(self.policies) do
    self:RestorePolicyConfig(pol)
  end

  -- Which user each config holds this character as, which the SetDefault below reads. Worked out now rather than asked for later.
  self:RefreshCSData()

  --
  -- Which policy is active is the one decision here that is the mod's rather than any policy's, so it is the one thing about
  -- configs still kept at the top of the database.
  --
  -- A policy that is switched off cannot be the active one, having no window for the loot engine to reach, so where the one
  -- remembered, or the default, is switched off the first policy still on takes its place.
  --
  local active = self.frdb.activepolicy or self.DEFAULT_POLICY

  if (not self.policies[active] or self:IsPolicyDisabled(active)) then
    local live = self:SortedPolicies()

    active = live[1] and live[1].handle
  end

  self.apol = self.policies[active] or self:GetPolicy(nil)

  if (self.apol.cfg) then
    self.apol.cfg:SetDefault(true, true)
  end

  --
  -- ChatThrottleLib ships at 800 characters per second, which its own comment admits is a shrug rather than a measurement:
  -- "2000 seems to be safe if NOTHING ELSE is happening. let's call it 800." A config sync is a burst of small messages and 800 makes it crawl.
  --
  -- Raised rather than set, because ChatThrottleLib is one global table shared by every addon on the client and whichever
  -- copy loaded first is the one in effect. Only ever moving the floor up means an addon that has already asked for more
  -- keeps what it asked for, and it does not matter which copy won the load.
  --
  if (ctl.MAX_CPS < KONFER_MIN_CPS) then
    ctl.MAX_CPS = KONFER_MIN_CPS
  end

  KC.RegisterComms(self)
  self:MakeSends(self)

  self:InitialiseUI()

  --
  -- Listening starts in here, by way of applying the stored suspended state, so that there is only the one place that decides it.
  --
  konfer_initialised(self)
end
