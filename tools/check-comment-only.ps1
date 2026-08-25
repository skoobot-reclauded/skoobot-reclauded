<#
    Prove an edit changed only comments, by compiling both versions and
    comparing normalised LuaJIT bytecode listings (#125).

    Identical listings mean the instruction stream and the constant table are
    identical, so nothing but comments and whitespace moved. `luacheck` and the
    parse check both pass a file that parses; neither can tell you the code is
    the code you started with. The mistake this was written for -- an
    off-by-one delete whose range ran into src/init.lua's `description = [[ ]]`
    long string -- parses, lints, and ships a broken addon.

    Not part of clean-build.ps1: it is only meaningful when the AUTHOR intends
    a comment-only change. Run it by hand, next to luacheck.

        powershell -ExecutionPolicy Bypass -File .\tools\check-comment-only.ps1 HEAD
        powershell -ExecutionPolicy Bypass -File .\tools\check-comment-only.ps1 abc1234 src/data/score.lua

    -Base is the commit the pass STARTED from, not HEAD-once-committed: after
    the work is committed HEAD is the edit and the check passes trivially.

    Exit codes:  0 every file identical   1 at least one differs or failed to
    compile   2 bad usage / nothing to check

    Three mechanics that are not optional, all learned the hard way (#105):

      * `luajit -b -s` (strip) does NOT work. The prototype header still
        carries `firstline` and `numline`, so deleting a comment line changes
        the bytes even though no instruction moved. The `-bl` LISTING is the
        right input.
      * The listing carries line numbers in two places -- the `-- BYTECODE --
        file:N-M` headers and the `; file:N` operand comments on FNEW. Both
        must be normalised away or every deletion looks like a change.
      * The chunk NAME is part of the output, so the two versions must be
        compiled under the SAME basename, from two different directories.
#>
[CmdletBinding()]
param(
    # The commit the comment-only pass started from.
    [Parameter(Position = 0)][string]$Base = 'HEAD',
    # Files to check. Default: every tracked Lua file under src/.
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Path
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Fail($msg) { Write-Host "[comment-only] $msg"; exit 2 }

$luajit = (Get-Command luajit -ErrorAction SilentlyContinue)
if (-not $luajit) { Fail 'luajit is not on PATH' }

# Resolve the base ref once, so the report names a commit and not a symbol
# whose meaning moves while the check runs.
$baseSha = & git -C $RepoRoot rev-parse --verify "$Base^{commit}" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $baseSha) { Fail "not a commit: $Base" }
$baseSha = "$baseSha".Trim()

if ($Path -and $Path.Count -gt 0) {
    $files = @($Path | ForEach-Object { ($_ -replace '\\', '/') -replace '^\./', '' })
} else {
    $files = @(& git -C $RepoRoot ls-files 'src/*.lua' 'src/**/*.lua')
    if ($LASTEXITCODE -ne 0) { Fail 'git ls-files failed' }
}
$files = @($files | Where-Object { $_ })
if ($files.Count -eq 0) { Fail 'no files to check' }

$work = Join-Path ([IO.Path]::GetTempPath()) ("skoobot-comment-only-" + [guid]::NewGuid().ToString('N'))
$dirA = Join-Path $work 'base'
$dirB = Join-Path $work 'head'
$null = New-Item -ItemType Directory -Force -Path $dirA, $dirB

#--- The normalised listing of one file, or $null and the compiler's complaint.
#    Compiled from $dir under $name so the chunk name matches in both copies.
function Get-Listing($dir, $name) {
    Push-Location $dir
    try {
        # No 2>&1: in PS 5.1 that wraps each stderr line in an ErrorRecord and
        # throws under -ErrorAction Stop even when the exe exited 0.
        $out = & luajit -bl $name
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    if ($code -ne 0) { return $null }
    return @($out |
        Where-Object { $_ -notmatch '^-- BYTECODE' } |
        ForEach-Object { $_ -replace ';\s*\S+\.lua:\d+\s*$', '; @L' })
}

$differ = @()
$broken = @()
$new    = @()
$same   = 0

try {
    foreach ($rel in $files) {
        $name = Split-Path -Leaf $rel
        $live = Join-Path $RepoRoot $rel
        if (-not (Test-Path $live)) {
            Write-Host ("  GONE   {0}" -f $rel)
            $differ += "$rel (deleted in the working tree)"
            continue
        }

        # The base version. A file that did not exist then has nothing to
        # compare against and is reported rather than silently passed.
        $baseText = & git -C $RepoRoot show "${baseSha}:${rel}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("  NEW    {0} (not in {1})" -f $rel, $baseSha.Substring(0, 7))
            $new += $rel
            continue
        }

        # WriteAllText, not Set-Content -Encoding utf8: the latter writes a BOM
        # in PS 5.1, and the working copy has none. LuaJIT happens to skip a
        # BOM, so the comparison survives it -- but a difference that only
        # works by luck is not one to leave in a checker.
        [IO.File]::WriteAllText((Join-Path $dirA $name), (@($baseText) -join "`n") + "`n")
        Copy-Item -Path $live -Destination (Join-Path $dirB $name) -Force

        $a = Get-Listing $dirA $name
        $b = Get-Listing $dirB $name
        if ($null -eq $a) { Write-Host ("  ERR    {0} (the BASE version does not compile)" -f $rel); $broken += $rel; continue }
        if ($null -eq $b) { Write-Host ("  ERR    {0} (does not compile)" -f $rel); $broken += $rel; continue }

        $diff = Compare-Object -ReferenceObject $a -DifferenceObject $b -SyncWindow 0
        if ($diff) {
            Write-Host ("  DIFF   {0} ({1} listing line(s) differ)" -f $rel, @($diff).Count)
            $differ += $rel
        } else {
            Write-Host ("  ok     {0}" -f $rel)
            $same++
        }

        Remove-Item (Join-Path $dirA $name), (Join-Path $dirB $name) -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("[comment-only] base {0}: {1} identical, {2} differ, {3} would not compile, {4} new" -f
    $baseSha.Substring(0, 7), $same, $differ.Count, $broken.Count, $new.Count)

if ($broken.Count -gt 0) {
    Write-Host '[comment-only] FAILED - a file does not compile:'
    foreach ($f in $broken) { Write-Host "               $f" }
    exit 1
}
if ($differ.Count -gt 0) {
    Write-Host '[comment-only] FAILED - the code changed, not only the comments:'
    foreach ($f in $differ) { Write-Host "               $f" }
    exit 1
}
Write-Host '[comment-only] PASS - every file compiles to the same bytecode as the base'
exit 0
