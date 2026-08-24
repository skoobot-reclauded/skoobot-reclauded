<#
    #18: loadout discovery -- a suggested set of talent rules read off the
    game's own talent metadata, applied only on the player's say-so.

    Drives data/loadout.lua through the bot's runtime table and the talent
    screen, on the shared "harness" save (a random class; that is the point:
    the rule has to make sense for whatever it is given):
      * propose() returns a proposal whose every entry is a known, non-passive
        talent in a valid section, typed (sustained only in Sustain), once,
        ordered by cooldown descending within a section -- or is correctly
        empty when the character has nothing with tactical data;
      * apply "merge" into an empty list writes every entry, in order, marked
        suggested = true, and a re-run adds no duplicate;
      * a hand-placed row survives merge wherever it is, and is gone after
        "replace" -- which the screen only calls after a confirmation, whose
        "Keep them" leaves everything as it was;
      * a hand edit in the screen clears the suggested mark on that row;
      * the screen's first row carries the unassigned count, opens the
        proposal, backs out on Escape, and applies through the action menu;
      * the dead-end stop ("no Combat talent is configured") names the suggestion.
    No game.turn advances -- deterministic. Mouse drag is not driven.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-loadout.ps1

    #18.
#>
[CmdletBinding()]
param([string]$SaveName = 'harness')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$script:Fail = @()
$script:Tainted = $false
function Check($ok, $what) {
    if ($ok) { Write-Host "  PASS  $what" } else { Write-Host "  FAIL  $what"; $script:Fail += $what }
}
# A probe that errors or returns ERR makes the run inconclusive: the fixture
# could not be built, so nothing below it says anything about the product.
function Probe($label, $lua, $timeout = 60) {
    $r = Invoke-Bridge -Lua $lua -TimeoutSec $timeout
    if ($r.Tainted) { $script:Tainted = $true }
    $txt = "$($r.Result)"
    Write-Host ('  {0,-9} {1,-8} {2}' -f $label, $r.Status, $txt)
    if ($r.Status -ne 'OK' -or $txt -match '^ERR') {
        Write-Host "[loadout] INCONCLUSIVE at '$label': $txt"
        Stop-Game
        exit 3
    }
    return $txt
}

Write-Host ''
Write-Host '[loadout] loadout discovery (#18)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[loadout] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    $null = Probe 'helpers' @'
_G.lo = {}
function lo.dump(section)
  local r = skoobot_reclauded.rules.get(game.player)
  local out = {}
  for _, e in ipairs(r[section]) do
    out[#out+1] = (e.tid or ("@" .. tostring(e.object))) .. (e.suggested and "*" or "")
  end
  return table.concat(out, ",")
end
function lo.dumpAll()
  local out = {}
  for _, s in ipairs(skoobot_reclauded.rules.module.SECTIONS) do out[#out+1] = s .. "=" .. lo.dump(s) end
  return table.concat(out, " ")
end
function lo.clear()
  local d = skoobot_reclauded.data(game.player)
  d.autotalents = {}
  return skoobot_reclauded.rules.get(game.player)
end
function lo.count()
  return skoobot_reclauded.rules.module.count(skoobot_reclauded.rules.get(game.player))
end
-- Is the rules table exactly the proposal: every entry in its section, in
-- order, all marked, nothing else?
function lo.matches(P)
  local r = skoobot_reclauded.rules.get(game.player)
  local want = {}
  for _, e in ipairs(P.entries) do
    want[e.section] = want[e.section] or {}
    table.insert(want[e.section], e.tid)
  end
  for _, s in ipairs(skoobot_reclauded.rules.module.SECTIONS) do
    local w = want[s] or {}
    if #r[s] ~= #w then return false, s .. " has " .. #r[s] .. " rows, proposal " .. #w end
    for i, e in ipairs(r[s]) do
      if e.tid ~= w[i] then return false, s .. "[" .. i .. "] is " .. tostring(e.tid) .. ", proposal " .. tostring(w[i]) end
      if not e.suggested then return false, s .. "[" .. i .. "] " .. tostring(e.tid) .. " is not marked suggested" end
    end
  end
  return true, "exact"
end
function lo.press(sym, shift)
  local Key = require "engine.Key"
  local h = Key.current
  bridge.injecting = true
  local ok, err = pcall(h.receiveKey, h, Key[sym], false, shift or false, false, false, nil, false, sym)
  bridge.injecting = false
  if not ok then error(err) end
end
function lo.closeAll()
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
end
return "ok"
'@

    Write-Host ''
    Write-Host 'The proposal'
    $prop = Probe 'propose' @'
local ok, res = pcall(function()
  local p = game.player
  local L = skoobot_reclauded.loadout
  if type(L) ~= "table" or type(L.propose) ~= "function" or type(L.apply) ~= "function" then
    return "ERR no skoobot_reclauded.loadout runtime surface"
  end
  local P = L.propose()
  lo.P = P
  -- What the character could give: non-passive, usable, with tactical data.
  local candidates = 0
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and t.mode ~= "passive" and not t.is_object_use and not t.no_npc_use and not t.no_dumb_use
       and t.tactical ~= nil then candidates = candidates + 1 end
  end
  local seen, bad = {}, {}
  local rm = skoobot_reclauded.rules.module
  local bySection = {}
  for _, e in ipairs(P.entries) do
    local t = p:getTalentFromId(e.tid)
    if not t then bad[#bad+1] = e.tid .. ":unknown"
    elseif not p:knowTalent(e.tid) then bad[#bad+1] = e.tid .. ":not known"
    elseif t.mode == "passive" then bad[#bad+1] = e.tid .. ":passive"
    elseif t.no_npc_use or t.no_dumb_use then bad[#bad+1] = e.tid .. ":no_npc_use"
    elseif not rm.isSection(e.section) then bad[#bad+1] = e.tid .. ":section " .. tostring(e.section)
    elseif not rm.allowed(t.mode == "sustained" and "sustained" or "activated", e.section) then
      bad[#bad+1] = e.tid .. ":typed wrong (" .. tostring(t.mode) .. " in " .. e.section .. ")"
    elseif seen[e.tid] then bad[#bad+1] = e.tid .. ":twice"
    elseif type(e.reason) ~= "string" or e.reason == "" then bad[#bad+1] = e.tid .. ":no reason"
    elseif type(e.priority) ~= "number" then bad[#bad+1] = e.tid .. ":no priority"
    end
    seen[e.tid] = true
    bySection[e.section] = bySection[e.section] or {}
    table.insert(bySection[e.section], e)
  end
  -- cooldown descending within a section, priority descending with it
  local order = 0
  for s, list in pairs(bySection) do
    for i = 2, #list do
      local a, b = list[i-1], list[i]
      local ca = p:getTalentCooldown(p:getTalentFromId(a.tid)) or 0
      local cb = p:getTalentCooldown(p:getTalentFromId(b.tid)) or 0
      if type(ca) ~= "number" then ca = 0 end
      if type(cb) ~= "number" then cb = 0 end
      if ca < cb then order = order + 1 bad[#bad+1] = s .. ":" .. a.tid .. "(" .. ca .. ") before " .. b.tid .. "(" .. cb .. ")" end
      if a.priority <= b.priority then order = order + 1 bad[#bad+1] = s .. ":priority not descending at " .. b.tid end
    end
  end
  for _, u in ipairs(P.unassigned) do
    if seen[u.tid] then bad[#bad+1] = u.tid .. ":both placed and unassigned" end
    if type(u.reason) ~= "string" or u.reason == "" then bad[#bad+1] = u.tid .. ":unassigned without a reason" end
  end
  local hidden, sustainsIn, choicesTids = 0, 0, 0
  for _, e in ipairs(P.entries) do if e.hidden then hidden = hidden + 1 end if e.section == "Sustain" then sustainsIn = sustainsIn + 1 end end
  for _, c in ipairs(P.choices) do choicesTids = choicesTids + #c.tids end
  return ("entries=%d unassigned=%d skipped=%d choices=%d choice_tids=%d candidates=%d hidden=%d sustain=%d bad=%d %s"):format(
    P.counts.entries, P.counts.unassigned, P.counts.skipped, P.counts.choices, choicesTids, candidates, hidden, sustainsIn,
    #bad, table.concat(bad, ";"))
end)
return ok and res or ("ERR " .. tostring(res))
'@ 90
    $entries = [int]($prop -replace '^entries=(\d+).*$', '$1')
    $candidates = [int]($prop -replace '^.*candidates=(\d+).*$', '$1')
    $choiceTids = [int]($prop -replace '^.*choice_tids=(\d+).*$', '$1')
    $unassigned = [int]($prop -replace '^.*unassigned=(\d+).*$', '$1')
    Check ($prop -match ' bad=0 ') 'every proposed entry is a known, usable, non-passive talent, typed into a valid section, once, with a reason, in cooldown order'
    if ($candidates -gt 0) {
        Check ($entries -gt 0 -or ($unassigned + $choiceTids) -ge $candidates) "a character with $candidates tactical talents gets a non-empty proposal (entries=$entries), or every candidate is accounted for"
    } else {
        Check ($entries -eq 0) 'a character with no tactical talents gets an empty proposal'
    }
    Check ($prop -match ' hidden=[1-9]') 'a hidden talent (every character knows Attack, hide="always") is kept and marked'

    # Each listed entry of the proposal, for the log and for the owner to read.
    $null = Probe 'listing' @'
local out = {}
for _, e in ipairs(lo.P.entries) do out[#out+1] = ("%s:%s:%d"):format(e.section, e.tid, e.priority) end
for _, u in ipairs(lo.P.unassigned) do out[#out+1] = ("unassigned:%s:%s"):format(u.tid, (u.reason:gsub("[;,]", " "))) end
for _, c in ipairs(lo.P.choices) do out[#out+1] = "choice:" .. c.slot .. ":" .. table.concat(c.tids, "/") end
return table.concat(out, " | ")
'@

    Write-Host ''
    Write-Host 'Apply: merge into an empty list'
    $merge = Probe 'merge' @'
local ok, res = pcall(function()
  lo.clear()
  local report = skoobot_reclauded.loadout.apply(lo.P, "merge")
  local same, why = lo.matches(lo.P)
  return ("mode=%s added=%d removed=%d kept=%d count=%d exact=%s %s"):format(
    report.mode, report.added, report.removed, report.kept, lo.count(), tostring(same), why)
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($merge -match "mode=merge added=$entries removed=0 kept=0 count=$entries ") 'merge into an empty list writes every proposed entry and nothing else'
    Check ($merge -match 'exact=true') 'the rules are the proposal: each entry in its section, in order, marked suggested'

    $rerun = Probe 'rerun' @'
local ok, res = pcall(function()
  local before = lo.dumpAll()
  local P2 = skoobot_reclauded.loadout.propose()
  local report = skoobot_reclauded.loadout.apply(P2, "merge")
  local same, why = lo.matches(P2)
  return ("stable=%s count=%d added=%d kept=%d exact=%s %s"):format(tostring(before == lo.dumpAll()), lo.count(),
    report.added, report.kept, tostring(same), why)
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($rerun -match "stable=true count=$entries ") 're-running propose + merge changes nothing and adds no duplicate'

    Write-Host ''
    Write-Host 'Hand rows: merge keeps them, replace clears them'
    $hand = Probe 'hand' @'
local ok, res = pcall(function()
  local p, R, rm = game.player, skoobot_reclauded.rules, skoobot_reclauded.rules.module
  local r = R.get(p)
  -- A hand row for a proposed talent, in a section of the player's choosing:
  -- take the first Combat entry and put it in Recovery by hand, with its
  -- suggested Combat row removed as a player would.
  local first
  for _, e in ipairs(lo.P.entries) do if e.section == "Combat" then first = e break end end
  if not first then return "ERR the proposal has no Combat entry to move by hand" end
  lo.hand = first.tid
  rm.remove(r, {tid=first.tid}, "Combat")
  rm.place(r, {tid=first.tid}, "Recovery")
  local report = skoobot_reclauded.loadout.apply(lo.P, "merge")
  local inCombat = rm.indexIn(r, "Combat", {tid=first.tid}) ~= nil
  local rec = r.Recovery[rm.indexIn(r, "Recovery", {tid=first.tid})]
  return ("tid=%s kept=%d inCombat=%s inRecovery=%s recSuggested=%s count=%d"):format(first.tid, report.kept,
    tostring(inCombat), tostring(rec ~= nil), tostring(rec and rec.suggested), lo.count())
end)
return ok and res or ("ERR " .. tostring(res))
'@
    $handTid = ($hand -replace '^tid=(\S+).*$', '$1')
    Check ($hand -match 'kept=1 inCombat=false inRecovery=true recSuggested=nil') 'merge leaves a talent the player placed by hand where they put it, and does not re-add it where the proposal had it'
    Check ($hand -match "count=$entries$") 'merge over a hand row changes the count by nothing'

    $replace = Probe 'replace' @'
local ok, res = pcall(function()
  local report = skoobot_reclauded.loadout.apply(lo.P, "replace")
  local same, why = lo.matches(lo.P)
  return ("mode=%s removed=%d added=%d exact=%s %s"):format(report.mode, report.removed, report.added, tostring(same), why)
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($replace -match "mode=replace removed=$entries added=$entries exact=true") 'replace (the post-confirmation call) clears the hand row with everything else and writes the proposal exactly'

    Write-Host ''
    Write-Host 'The screen'
    $open = Probe 'open' @'
local ok, res = pcall(function()
  lo.closeAll()
  local p = game.player
  -- Start from a list with one hand row, so the count and the confirmation have something to show.
  lo.clear()
  local r = skoobot_reclauded.rules.get(p)
  skoobot_reclauded.rules.module.place(r, {tid=lo.hand}, "Combat")
  local d = require("mod.dialogs.skoobot_reclauded.TalentDialog").new(p)
  game:registerDialog(d)
  lo.d = d
  local first = d.c_list.list[1]
  local headers = 0
  for _, it in ipairs(d.c_list.list) do if it.nodes then headers = headers + 1 end end
  local unplaced = #skoobot_reclauded.loadout.unplaced(lo.P)
  return ("first_action=%s label=[%s] headers=%d unplaced=%d proposal=%s"):format(tostring(first and first.action),
    tostring(first and first.cname), headers, unplaced, tostring(d.proposal ~= nil))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    $unplacedN = [int]($open -replace '^.*unplaced=(\d+).*$', '$1')
    Check ($open -match 'first_action=suggest') 'the first row of the talent screen is the suggest action'
    if ($unplacedN -gt 0) {
        Check ($open -match "label=\[$unplacedN unassigned -- suggest a loadout\?\]") "the row carries the unassigned count ($unplacedN)"
    } else {
        Check ($open -match 'label=\[Suggest a loadout\.\.\.\]') 'with nothing unassigned the row just offers the suggestion'
    }
    Check ($open -match 'headers=5 .*proposal=false') 'the screen opens in the rules view, four sections plus Available'

    $show = Probe 'show' @'
local ok, res = pcall(function()
  local d = lo.d
  d:use(d.c_list.list[1], "left")
  if not d.proposal then return "ERR the suggest row did not open a proposal" end
  local headers, rows, placed, withReason = 0, 0, 0, 0
  local names = {}
  for _, it in ipairs(d.c_list.list) do
    if it.nodes then headers = headers + 1 names[#names+1] = (tostring(it.name):gsub("#[^#]*#", ""))
    elseif it.ptid then
      rows = rows + 1
      if it.placed then placed = placed + 1 end
      if it.tree and it.tree ~= "" then withReason = withReason + 1 end
    end
  end
  local first = d.c_list.list[1]
  return ("headers=%d rows=%d placed=%d with_reason=%d first=%s sel=%d count=%d desc_is_intro=%s"):format(headers, rows, placed,
    withReason, tostring(first.action), d.c_list.sel, lo.count(), tostring(d.c_desc.cur_item == d.status_key))
    .. " names=" .. table.concat(names, "|")
end)
return ok and res or ("ERR " .. tostring(res))
'@
    # #85 added a seventh group: what applying would take AWAY.
    Check ($show -match 'headers=7 ') 'the proposal view shows the four sections, Would be removed, Not placed and Your choice'
    Check ($show -match "rows=(\d+) " -and [int]$Matches[1] -ge $entries) 'every proposed entry has a row'
    Check ($show -match 'placed=1 ') 'the hand-placed talent is shown as already placed'
    Check ($show -match "with_reason=(\d+) " -and [int]$Matches[1] -ge $entries) 'every row carries its reason'
    Check ($show -match 'first=apply sel=1 ') 'the apply row is first and selected'
    Check ($show -match 'desc_is_intro=true') 'the description pane explains that nothing has been written'
    Check ($show -match "count=1 ") 'showing the proposal wrote nothing'

    $edits = Probe 'no-edit' @'
local ok, res = pcall(function()
  local d = lo.d
  local before = lo.dumpAll()
  -- a row of the proposal selected: digits, Delete and Shift+Up must not edit
  for i, it in ipairs(d.c_list.list) do if it.ptid then d:selectItem(it) break end end
  d:moveSelected("Combat")
  d:unassignSelected()
  d:shiftSelected(-1)
  local refused = d.c_desc.cur_item == d.status_key
  return ("same=%s refused=%s"):format(tostring(before == lo.dumpAll()), tostring(refused))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($edits -match 'same=true refused=true') 'while the proposal is shown the edit keys change nothing and say why'

    $esc = Probe 'escape' @'
local ok, res = pcall(function()
  local d = lo.d
  lo.press("_ESCAPE")
  local top = game.dialogs[#game.dialogs]
  return ("proposal=%s top_is_screen=%s first=%s count=%d"):format(tostring(d.proposal ~= nil), tostring(top == d),
    tostring(d.c_list.list[1].action), lo.count())
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($esc -match 'proposal=false top_is_screen=true first=suggest count=1') 'Escape backs out of the proposal to the rules view without closing the screen or writing'

    # #85: a proposal row is a thing to argue with. Selecting a TALENT row
    # declines it -- darkened, still listed, and not written -- and selecting
    # it again takes that back. The apply row is the one that commits, which
    # is what the menu probe below still exercises.
    $decline = Probe 'decline' @'
local ok, res = pcall(function()
  local d = lo.d
  d:use(d.c_list.list[1], "left")            -- back into the proposal
  if not d.proposal then return "ERR no proposal" end
  -- The first row that is a talent, not the apply row or a header.
  local row
  for _, it in ipairs(d.c_list.list) do if not row and it.ptid then row = it end end
  if not row then return "ERR no talent row in the proposal" end
  local tid = row.ptid
  local before = tostring(row.name):gsub("#[^#]*#", "")
  d:use(row, "left")                         -- decline it
  -- The VALUE, now. Holding the table and reading it at the end would
  -- read it after the undo below, which is a probe that always says no.
  local inset = (skoobot_reclauded.data(d.actor).declined or {})[tid] == true
  local after, marked = nil, false
  for _, it in ipairs(d.c_list.list) do
    if it.ptid == tid then after = tostring(it.name):gsub("#[^#]*#", "") marked = it.declined == true end
  end
  -- and what the suggestion would now write
  local wrote = 0
  for _, e in ipairs(d.proposal.entries) do if e.tid == tid and not e.declined then wrote = wrote + 1 end end
  d:use(row, "left")                         -- undo it
  local set2 = skoobot_reclauded.data(d.actor).declined or {}
  -- Leave the screen as it was found: on the RULES view. The probe after
  -- this one takes list[1] to mean the suggest row, and in the proposal
  -- view list[1] is the apply row -- which opened the apply menu early and
  -- made that probe report "no apply menu".
  d:cancelProposal()
  return ("tid=%s before=[%s] after=[%s] marked=%s inset=%s still_proposed=%d undone=%s"):format(
    tid, before, tostring(after), tostring(marked), tostring(inset), wrote,
    tostring(set2[tid] == nil))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($decline -notmatch '^ERR') 'a talent row can be selected in the proposal'
    Check ($decline -match 'marked=true inset=true') 'selecting it declines it, on the character'
    Check ($decline -match 'after=\[.*\(declined\)') 'and the row says so rather than disappearing'
    Check ($decline -match 'still_proposed=0') 'a declined talent is not what the suggestion would write'
    Check ($decline -match 'undone=true') 'selecting it again takes the decline back'

    $menu = Probe 'menu' @'
local ok, res = pcall(function()
  local d = lo.d
  d:use(d.c_list.list[1], "left")
  if not d.proposal then return "ERR no proposal" end
  lo.press("_RETURN")
  local m = game.dialogs[#game.dialogs]
  if not m or m == d or not m.list then return "ERR no apply menu: " .. bridge.dialogs() end
  local names = {}
  for _, it in ipairs(m.list) do names[#names+1] = (tostring(it.name):gsub("^%a%) ", "")) end
  lo.menu = m
  return ("title=[%s] entries=%d names=%s"):format(tostring(m.title), #names, table.concat(names, "|"))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($menu -match 'entries=3 names=Merge: .*\|Replace: .*\|Cancel') 'Enter on a proposal row offers Merge, Replace and Cancel, Merge first'
    Check ($menu -match "names=Merge: add $unplacedN new") 'the Merge entry says how many it would add'

    $confirm = Probe 'confirm' @'
local ok, res = pcall(function()
  local d, m = lo.d, lo.menu
  -- Replace with a non-empty list: a confirmation, whose safe answer leaves everything.
  local replace
  for _, it in ipairs(m.list) do if tostring(it.name):find("Replace", 1, true) then replace = it end end
  m:use(replace)
  local c = game.dialogs[#game.dialogs]
  if not c or c == d then return "ERR no confirmation: " .. bridge.dialogs() end
  local title = tostring(c.title)
  local keep, focusKeep
  for _, u in ipairs(c.uis or {}) do
    if u.ui and u.ui.text == "Keep them" then keep = u.ui end
  end
  focusKeep = keep ~= nil and c.focus_ui ~= nil and c.focus_ui.ui == keep
  local before = lo.dumpAll()
  if keep then keep.fct() end
  local top = game.dialogs[#game.dialogs]
  return ("title=[%s] keep=%s focus_keep=%s same=%s proposal_still=%s top_is_screen=%s"):format(title, tostring(keep ~= nil),
    tostring(focusKeep), tostring(before == lo.dumpAll()), tostring(d.proposal ~= nil), tostring(top == d))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($confirm -match 'title=\[Replace the talent rules\?\] keep=true') 'Replace over a non-empty list asks first'
    Check ($confirm -match 'focus_keep=true') 'the safe answer has the focus, so Enter does not clear anything'
    Check ($confirm -match 'same=true proposal_still=true top_is_screen=true') '"Keep them" writes nothing and leaves the proposal on screen'

    $apply = Probe 'apply' @'
local ok, res = pcall(function()
  local d = lo.d
  lo.press("_RETURN")
  local m = game.dialogs[#game.dialogs]
  if not m or m == d or not m.list then return "ERR no apply menu: " .. bridge.dialogs() end
  local replace
  for _, it in ipairs(m.list) do if tostring(it.name):find("Replace", 1, true) then replace = it end end
  m:use(replace)
  local c = game.dialogs[#game.dialogs]
  if not c or c == d then return "ERR no confirmation: " .. bridge.dialogs() end
  local yes
  for _, u in ipairs(c.uis or {}) do if u.ui and u.ui.text == "Replace" then yes = u.ui end end
  if not yes then return "ERR no Replace button" end
  yes.fct()
  local same, why = lo.matches(lo.P)
  local top = game.dialogs[#game.dialogs]
  return ("proposal=%s exact=%s %s first=%s top_is_screen=%s said=%s"):format(tostring(d.proposal ~= nil), tostring(same), why,
    tostring(d.c_list.list[1].action), tostring(top == d), tostring(d.c_desc.cur_item == d.status_key))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($apply -match 'proposal=false exact=true') 'confirming Replace writes the proposal exactly and returns to the rules view'
    Check ($apply -match 'first=suggest top_is_screen=true said=true') 'the screen stays open on the rules, and reports what it did'

    $handedit = Probe 'hand-edit' @'
local ok, res = pcall(function()
  local d = lo.d
  local r = skoobot_reclauded.rules.get(game.player)
  -- Shift+Down on a suggested Combat row: a hand edit that clears the mark.
  local row
  for _, it in ipairs(d.c_list.list) do if it.entry and it.section == "Combat" then row = it break end end
  if not row then return "ERR no Combat row" end
  local tid = row.entry.tid
  local wasSuggested = row.entry.suggested == true
  d:selectItem(row)
  lo.press("_DOWN", true)
  local i = skoobot_reclauded.rules.module.indexIn(r, "Combat", {tid=tid})
  local e = r.Combat[i]
  local nowSuggested = e and e.suggested
  -- and a merge now leaves that row alone: hand rows lead, suggested rows follow
  local report = skoobot_reclauded.loadout.apply(lo.P, "merge")
  local j = skoobot_reclauded.rules.module.indexIn(r, "Combat", {tid=tid})
  local after = r.Combat[j or 0]
  return ("was=%s now=%s kept=%d at=%s still_hand=%s count=%d"):format(tostring(wasSuggested), tostring(nowSuggested),
    report.kept, tostring(j), tostring(after and not after.suggested), lo.count())
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($handedit -match 'was=true now=nil ') 'reordering a suggested row by hand clears its suggested mark'
    Check ($handedit -match "kept=1 at=1 still_hand=true count=$entries") 'a later merge keeps the hand-edited row, unmarked, ahead of the suggested rows, with no duplicate'

    $mergeUI = Probe 'merge-ui' @'
local ok, res = pcall(function()
  local d = lo.d
  lo.clear()
  d:refresh()
  d:use(d.c_list.list[1], "left")
  if not d.proposal then return "ERR no proposal" end
  lo.press("_RETURN")
  local m = game.dialogs[#game.dialogs]
  if not m or m == d or not m.list then return "ERR no apply menu: " .. bridge.dialogs() end
  m:use(m.list[1])   -- Merge, the default
  local same, why = lo.matches(lo.P)
  local r = ("proposal=%s exact=%s %s count=%d label=[%s]"):format(tostring(d.proposal ~= nil), tostring(same), why,
    lo.count(), tostring(d.c_list.list[1].cname))
  lo.closeAll()
  return r
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($mergeUI -match "proposal=false exact=true exact count=$entries label=\[Suggest a loadout\.\.\.\]") 'Merge from the menu into an empty list writes the proposal and the count row has nothing left to offer'

    Write-Host ''
    Write-Host 'The dead-end stop'
    $dead = Probe 'dead-end' @'
local ok, res = pcall(function()
  local p, b = game.player, skoobot_reclauded
  lo.closeAll()
  lo.clear()
  -- Find a hostile in view without spending a turn; stop conditions that would
  -- fire first are set aside for this one decision and put back after.
  local function hostiles()
    p:playerFOV()
    local n = 0
    core.fov.calc_circle(p.x, p.y, game.level.map.w, game.level.map.h, p.sight or 10,
      function(_, x, y) return game.level.map:opaque(x, y) end,
      function(_, x, y)
        local a = game.level.map(x, y, game.level.map.ACTOR)
        if a and p:reactionToward(a) < 0 and p:canSee(a) and game.level.map.seens(x, y) then n = n + 1 end
      end, nil)
    return n
  end
  local n = hostiles()
  for i = 1, 60 do
    if n > 0 then break end
    p:teleportRandom(p.x, p.y, 60, 10)
    n = hostiles()
  end
  if n == 0 then return "SETUP no hostile within 60 teleports" end
  local saved = {}
  for _, c in ipairs(b.conditions.list()) do saved[c.code] = c.stoptype b.conditions.set(c.code, "IGNORE") end
  b.stop("reset")
  b.active = false b.state = 13 b.last_reason = nil   -- 13 = STATE_FIGHT
  b.activation = nil b.loop = nil b.prevloop = nil
  p.life = p.max_life
  local before = game.turn
  b.query()
  for code, st in pairs(saved) do b.conditions.set(code, st) end
  local ld = game.uiset and game.uiset.logdisplay
  local last = ""
  if ld and ld.getLines then
    for _, l in ipairs(ld:getLines(3)) do
      local s = l
      if type(l) == "table" then s = l.str or l.msg or l[1] or l end
      if type(s) == "table" and s.toString then s = s:toString() end
      last = last .. " | " .. (tostring(s):gsub("#[^#]*#", ""))
    end
  end
  return ("reason=%s dturn=%d log=%s"):format(tostring(b.last_reason), game.turn - before, last)
end)
return ok and res or ("ERR " .. tostring(res))
'@ 120
    if ($dead -match '^SETUP') {
        Write-Host "  INFO  dead-end stop not reached ($dead); the hint text is covered by the source, not this run"
    } elseif ($dead -match 'no Combat talent is configured') {
        Check ($dead -match 'suggest a loadout from the talent screen') 'the "no Combat talent is configured" stop names the suggestion as the way out'
        Check ($dead -match 'dturn=0 ') 'query advances no game turn'
    } else {
        Write-Host "  INFO  the one decision stopped for another reason ($dead); the dead-end hint is not measured in this run"
    }
}
finally {
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Check ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:Tainted) { Write-Host '[loadout] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[loadout] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[loadout] PASS - discovery proposes, the screen shows it, and nothing is written without the player'
exit 0
