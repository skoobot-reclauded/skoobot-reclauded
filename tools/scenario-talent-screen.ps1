<#
    #56 regression: the talent screen is a sectioned, ordered list.

    Drives the rebuilt TalentDialog through the bridge, without a mouse:
      * a v1-shaped rule list migrates on read -- priority order kept, the add
        chain's placeholder and the duplicate dropped, an item rule re-keyed on
        the item's name (#55);
      * the screen lists every usable talent and the worn item under its own
        name, never as "Activate Object" (#55);
      * the keyboard path (1-4, Delete, Shift+Up/Down) and the drop handler
        move rules between and within sections under the typing rule
        (sustained talents only in Sustain, and nothing else there);
      * the action menu opens on a row and has a Cancel entry (#48);
      * the bot reads the result back in order and skips a rule whose item is
        not carried.
    No game.turn advances -- deterministic. Mouse drag itself is not driven;
    the drop handler is called the way the engine calls it.

    Exit codes:  0 pass   1 fail   2 tainted   3 inconclusive

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\scenario-talent-screen.ps1

    #56, #55.
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
        Write-Host "[talent-screen] INCONCLUSIVE at '$label': $txt"
        Stop-Game
        exit 3
    }
    return $txt
}

Write-Host ''
Write-Host '[talent-screen] the sectioned, ordered talent screen (#56)'

try {
    $g = Load-Save -Name $SaveName
    if (-not $g.Ready) { Write-Host "[talent-screen] FAILED - could not load '$SaveName' ($($g.Reason))"; exit 1 }
    Check ($g.Addons -match 'skoobot_reclauded') 'the product is loaded'

    # Fixture: three activated talents, a sustained one if the character has
    # one, and a worn charm -- charms get their object talent only when worn
    # (ActorObjectUse.useObjectEnable).
    $seed = Probe 'seed' @'
local ok, res = pcall(function()
  local p = game.player
  _G.ts = {}
  local acts, sus = {}, nil
  for tid, _ in pairs(p.talents) do
    local t = p:getTalentFromId(tid)
    if t and not t.is_object_use then
      if t.mode == "activated" then acts[#acts+1] = tid
      elseif t.mode == "sustained" and not sus then sus = tid end
    end
  end
  table.sort(acts)
  if #acts < 3 then return "ERR need 3 activated talents, have " .. #acts end
  ts.A, ts.B, ts.C, ts.S = acts[1], acts[2], acts[3], sus
  for i = 1, 20 do
    local o = game.zone:makeEntity(game.level, "object", {type="charm"}, nil, true)
    if o then
      o:identify(true)
      local okw = pcall(function() p:wearObject(o, true, false) end)
      local d = okw and p.object_talent_data and p.object_talent_data[o]
      if d and d.tid and p:knowTalent(d.tid) then
        ts.obj, ts.objtid, ts.objname = o, d.tid, skoobot_reclauded.rules.itemName(o)
        break
      end
    end
  end
  if not ts.objtid then return "ERR no charm could be worn" end
  return ("A=%s B=%s C=%s S=%s item=[%s] tid=%s"):format(ts.A, ts.B, ts.C, tostring(ts.S), ts.objname, ts.objtid)
end)
return ok and res or ("ERR " .. tostring(res))
'@
    $hasSustain = $seed -notmatch 'S=nil'
    $A = ($seed -replace '^.*A=(\S+).*$','$1'); $B = ($seed -replace '^.*B=(\S+).*$','$1'); $C = ($seed -replace '^.*C=(\S+).*$','$1')
    $S = ($seed -replace '^.*S=(\S+).*$','$1'); $OBJ = ($seed -replace '^.*tid=(\S+).*$','$1')
    $rx = { param($s) [regex]::Escape($s) }

    # A helper every later probe uses: one section as "tid,tid,@item".
    $null = Probe 'helpers' @'
function ts.dump(section)
  local r = skoobot_reclauded.rules.get(game.player)
  local out = {}
  for _, e in ipairs(r[section]) do out[#out+1] = e.tid or ("@" .. tostring(e.object)) end
  return table.concat(out, ",")
end
function ts.typech(ch)
  local Key = require "engine.Key"
  local h = Key.current
  bridge.injecting = true
  local ok, err = pcall(h.receiveKey, h, Key["_" .. ch] or 0, false, false, false, false, ch, false, ch)
  bridge.injecting = false
  if not ok then error(err) end
end
function ts.press(sym, shift)
  local Key = require "engine.Key"
  local h = Key.current
  bridge.injecting = true
  local ok, err = pcall(h.receiveKey, h, Key[sym], false, shift or false, false, false, nil, false, sym)
  bridge.injecting = false
  if not ok then error(err) end
end
function ts.row(tid, obj)
  for _, it in ipairs(ts.d.c_list.list) do
    if it.entry and ((tid and it.entry.tid == tid) or (obj and it.entry.object == obj)) then return it end
  end
end
function ts.header(section)
  for _, it in ipairs(ts.d.c_list.list) do
    if it.nodes and it.section == section then return it end
  end
end
return "ok"
'@

    Write-Host ''
    Write-Host 'Migration of a v1-shaped list'
    $mig = Probe 'migrate' @'
local ok, res = pcall(function()
  local p = game.player
  local d = skoobot_reclauded.data(p)
  local list = {}
  list[#list+1] = {tid=ts.A, usetype="Combat",   priority=1}
  list[#list+1] = {tid=ts.B, usetype="Combat",   priority=5}
  list[#list+1] = {tid=ts.C, usetype="",         priority=1}   -- the add chain's placeholder
  list[#list+1] = {tid=ts.B, usetype="Recovery", priority=1}   -- the same rule in a second section: kept
  if ts.S then list[#list+1] = {tid=ts.S, usetype="Sustain", priority=1} end
  list[#list+1] = {tid=ts.objtid, usetype="Recovery", priority=2}   -- an item by its slot id
  d.autotalents = list
  local r = skoobot_reclauded.rules.get(p)
  return ("same=%s array=%d combat=%s recovery=%s sustain=%s dp=%s"):format(
    tostring(r == d.autotalents), #r, ts.dump("Combat"), ts.dump("Recovery"), ts.dump("Sustain"), ts.dump("DamagePrevention"))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($mig -match 'same=true') 'the rules table keeps its identity (normalised in place)'
    Check ($mig -match 'array=0') 'the v1 array part is emptied'
    Check ($mig -match "combat=$(&$rx $B),$(&$rx $A) ") 'Combat keeps priority order (B before A), the placeholder dropped'
    Check ($mig -match 'recovery=@') 'the item rule is re-keyed on the item, not its slot id'
    Check ($mig -match "recovery=@[^,/]+,$(&$rx $B) ") 'the same rule may be in two sections (B in Combat and Recovery), in priority order'
    if ($hasSustain) { Check ($mig -match 'sustain=\S') 'the sustained rule lands in Sustain' }
    Check ($mig -match 'dp=$') 'Damage Prevention is empty'

    Write-Host ''
    Write-Host 'The screen'
    $open = Probe 'open' @'
local ok, res = pcall(function()
  bridge.key("MENU_SKOOBOT_RECLAUDED")
  local m = game.dialogs[#game.dialogs]
  if not m or tostring(m.title) ~= "SkooBot: Reclauded" then return "ERR menu not on top: " .. bridge.dialogs() end
  m:use(m.list[1])
  local d = game.dialogs[#game.dialogs]
  if not d or not d.c_list then return "ERR talent screen not on top: " .. bridge.dialogs() end
  ts.d = d
  local headers, rows, generic, itemrow = 0, 0, 0, nil
  for _, it in ipairs(d.c_list.list) do
    if it.nodes then headers = headers + 1 else rows = rows + 1 end
    if it.cname and it.cname:find("Activate Object", 1, true) then generic = generic + 1 end
    -- the item is listed twice: in its section and in the Available palette; take the section row
    if it.entry and it.entry.object == ts.objname and (not itemrow or it.section) then itemrow = it end
  end
  return ("class=%s headers=%d rows=%d generic=%d item=%s itemsection=%s itemlive=%s itemname=[%s]"):format(
    tostring(d.__CLASSNAME), headers, rows, generic, tostring(itemrow ~= nil), tostring(itemrow and itemrow.section),
    tostring(itemrow and itemrow.live), tostring(itemrow and itemrow.cname))
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($open -match 'class=mod\.dialogs\.skoobot_reclauded\.TalentDialog') 'the menu opens the rebuilt talent screen'
    Check ($open -match 'headers=5') 'four sections plus Unassigned'
    Check ($open -match 'rows=([1-9]\d*)') 'the sections have rows'
    Check ($open -match 'generic=0') 'no row reads "Activate Object" (#55)'
    Check ($open -match 'item=true itemsection=Recovery itemlive=true') 'the worn item is a live rule in Recovery'
    Check ($open -match 'itemname=\[Activate: ') 'the item row carries the item name (#55)'

    Write-Host ''
    Write-Host 'Keyboard'
    $keys = Probe 'keys' @'
local ok, res = pcall(function()
  local d, p = ts.d, game.player
  local out = {}
  d:selectItem(assert(ts.row(ts.C), "no row for C"))
  ts.typech("1")
  out[#out+1] = "c1=" .. ts.dump("Combat")
  ts.typech("4")
  out[#out+1] = "c4=" .. ts.dump("Combat") .. " refused=" .. tostring(d.c_desc.cur_item == d.status_key)
  ts.press("_UP", true)
  out[#out+1] = "up=" .. ts.dump("Combat")
  ts.press("_DOWN", true)
  out[#out+1] = "down=" .. ts.dump("Combat")
  ts.press("_DELETE")
  out[#out+1] = "del=" .. ts.dump("Combat")
  if ts.S then
    d:selectItem(assert(ts.row(ts.S), "no row for S"))
    ts.press("_DELETE")
    ts.typech("1")
    out[#out+1] = "s1=" .. ts.dump("Combat") .. "/" .. ts.dump("Sustain")
    ts.typech("4")
    out[#out+1] = "s4=" .. ts.dump("Sustain")
  end
  d:selectItem(assert(ts.row(ts.A), "no row for A"))
  ts.typech("0")
  out[#out+1] = "zero=" .. ts.dump("Combat")
  ts.typech("1")
  out[#out+1] = "back=" .. ts.dump("Combat")
  return table.concat(out, " ")
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($keys -match "c1=$(&$rx $B),$(&$rx $A),$(&$rx $C) ") '"1" on an Available row adds the talent at the end of Combat'
    Check ($keys -match "c4=$(&$rx $B),$(&$rx $A),$(&$rx $C) refused=true") '"4" on an activated talent is refused, with the reason shown'
    Check ($keys -match "up=$(&$rx $B),$(&$rx $C),$(&$rx $A) ") 'Shift+Up moves it up one place'
    Check ($keys -match "down=$(&$rx $B),$(&$rx $A),$(&$rx $C) ") 'Shift+Down moves it back down'
    Check ($keys -match "del=$(&$rx $B),$(&$rx $A) ") 'Delete unassigns it'
    if ($hasSustain) {
        Check ($keys -match "s1=$(&$rx $B),$(&$rx $A)/ ") '"1" on a sustained talent is refused (Combat and Sustain unchanged)'
        Check ($keys -match "s4=$(&$rx $S) ") '"4" puts the sustained talent in Sustain'
    }
    Check ($keys -match "zero=$(&$rx $B) ") '"0" unassigns the selected rule'
    Check ($keys -match "back=$(&$rx $B),$(&$rx $A)$") '"1" re-adds it at the end'

    Write-Host ''
    Write-Host 'Drop handler and action menu'
    $drop = Probe 'drop' @'
local ok, res = pcall(function()
  local d = ts.d
  local Mouse = require "engine.Mouse"
  local out = {}
  -- `from` is the section the drag started in; nil means the Available list,
  -- and a drop from there is an add that keeps the rule's other placements.
  local function drop(entry, target, from)
    Mouse.dragged = {payload={kind="skoobot_reclauded_rule", entry=entry, from=from}}
    d:use(target, "drag-end")
    local used = Mouse.dragged.used
    Mouse.dragged = nil
    return used
  end
  local u1 = drop({tid=ts.C}, assert(ts.row(ts.A), "no row for A"))
  out[#out+1] = ("onrow=%s used=%s"):format(ts.dump("Combat"), tostring(u1))
  local u2 = drop({tid=ts.C}, assert(ts.header("Recovery"), "no Recovery header"), "Combat")
  out[#out+1] = ("onheader=%s/%s used=%s"):format(ts.dump("Combat"), ts.dump("Recovery"), tostring(u2))
  local u3 = drop({tid=ts.C}, assert(ts.header(nil), "no Available header"), "Recovery")
  out[#out+1] = ("unassign=%s/%s used=%s"):format(ts.dump("Combat"), ts.dump("Recovery"), tostring(u3))
  -- a sustained rule dropped on Combat is refused
  if ts.S then
    local u4 = drop({tid=ts.S}, assert(ts.header("Combat"), "no Combat header"), "Sustain")
    out[#out+1] = ("typed=%s/%s used=%s"):format(ts.dump("Combat"), ts.dump("Sustain"), tostring(u4))
  end
  -- a foreign drag is ignored
  Mouse.dragged = {payload={kind="talent", id=ts.C}}
  d:use(assert(ts.header("Combat")), "drag-end")
  local foreign = tostring(Mouse.dragged.used)
  Mouse.dragged = nil
  out[#out+1] = "foreign_used=" .. foreign .. " combat=" .. ts.dump("Combat")
  return table.concat(out, " ")
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($drop -match "onrow=$(&$rx $B),$(&$rx $C),$(&$rx $A) used=true") 'a drop on a row inserts before that row'
    # Item names carry spaces ("iron torque of mindblast"): match up to the next comma or slash.
    Check ($drop -match "onheader=$(&$rx $B),$(&$rx $A)/@[^,/]+,$(&$rx $B),$(&$rx $C) used=true") 'a drop from a section onto another header moves it to the end of that section'
    Check ($drop -match "unassign=$(&$rx $B),$(&$rx $A)/@[^,/]+,$(&$rx $B) used=true") 'a drop from a section onto Available removes it from that section only'
    if ($hasSustain) { Check ($drop -match "typed=$(&$rx $B),$(&$rx $A)/$(&$rx $S) used=true") 'a sustained rule dropped on Combat is refused and stays put' }
    Check ($drop -match "foreign_used=nil combat=$(&$rx $B),$(&$rx $A)") 'a drag of another kind is ignored'

    $menu = Probe 'menu' @'
local ok, res = pcall(function()
  local d = ts.d
  local row = assert(ts.row(ts.B), "no row for B")
  d:use(row, "left")
  local m = game.dialogs[#game.dialogs]
  if not m or m == d or not m.list then return "ERR no action menu: " .. bridge.dialogs() end
  local names, cancel = {}, nil
  for _, it in ipairs(m.list) do
    local n = tostring(it.name)
    names[#names+1] = n
    if n:find("Cancel", 1, true) then cancel = it end
  end
  local title = tostring(m.title)
  if cancel then m:use(cancel) end
  return ("title=[%s] entries=%d cancel=%s top=%s combat=%s"):format(title, #names, tostring(cancel ~= nil),
    tostring(game.dialogs[#game.dialogs] == d), ts.dump("Combat")) .. " names=" .. table.concat(names, "|")
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($menu -match 'cancel=true top=true') 'the action menu has a Cancel entry that closes it (#48)'
    Check ($menu -match "combat=$(&$rx $B),$(&$rx $A) ") 'Cancel changes nothing'
    Check ($menu -match 'Move up' -and $menu -match 'Move down' -and $menu -match 'Remove from Combat' -and $menu -match 'Move to Recovery') 'the menu offers moves, reorder and remove-from-section for a placed rule'
    Check ($menu -match 'Also add to Damage Prevention' -and $menu -notmatch 'Also add to Recovery') 'the menu offers a second placement only where the rule is not already'
    Check ($menu -notmatch 'Move to Sustain') 'the menu does not offer Sustain to an activated talent'

    Write-Host ''
    Write-Host 'What the bot reads'
    $bot = Probe 'bot' @'
local ok, res = pcall(function()
  local p, R = game.player, skoobot_reclauded.rules
  local r = R.get(p)
  R.module.place(r, {object="no such thing as this"}, "Recovery")
  ts.d:refresh()
  local ghost = ts.row(nil, "no such thing as this")
  local out = ("combat=%s recovery_live=%s ghost_row=%s ghost_kind=[%s] ghost_live=%s"):format(
    table.concat(R.tids(p, "Combat"), ","), table.concat(R.tids(p, "Recovery"), ","),
    tostring(ghost ~= nil), tostring(ghost and ghost.kind), tostring(ghost and ghost.live))
  while #game.dialogs > 0 do game:unregisterDialog(game.dialogs[#game.dialogs]) end
  return out
end)
return ok and res or ("ERR " .. tostring(res))
'@
    Check ($bot -match "combat=$(&$rx $B),$(&$rx $A) ") 'the bot reads Combat in list order'
    Check ($bot -match "recovery_live=$(&$rx $OBJ),$(&$rx $B) ") 'the item rule resolves to its live talent id, and the second placement of B is read in Recovery too'
    Check ($bot -match 'ghost_row=true ghost_kind=\[Item \(not carried\)\] ghost_live=false') 'a rule for an item not carried is shown dormant'
}
finally {
    Stop-Game
}

Start-Sleep -Seconds 1
$errs = @((Get-Content $script:LogPath -Raw -ErrorAction Ignore) -split "`r?`n" | Where-Object { $_ -match 'Lua Error' })
Check ($errs.Count -eq 0) 'no Lua Error in the run'
foreach ($e in ($errs | Select-Object -First 3)) { Write-Host "         $e" }

Write-Host ''
if ($script:Tainted) { Write-Host '[talent-screen] TAINTED - void, re-run.'; exit 2 }
if ($script:Fail.Count -gt 0) {
    Write-Host "[talent-screen] FAILED - $($script:Fail.Count) check(s):"
    foreach ($f in $script:Fail) { Write-Host "                 $f" }
    exit 1
}
Write-Host '[talent-screen] PASS - the talent screen edits, types and orders rules, and the bot reads them back'
exit 0
