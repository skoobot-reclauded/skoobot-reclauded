<#
    Build dist/tome-skoobot_reclauded-<a.b.c>.teaa from the contents of src/.
    A development build (no -Release) is named
    tome-skoobot_reclauded-<a.b.c>-g<sha7>[-dirty].teaa so that two builds of
    the same version can be told apart afterwards (T-055).

    A .teaa is an ordinary ZIP that the engine mounts. Three properties of the
    shipped v1 artifacts are load-bearing, and all three are easy to get wrong
    with the obvious tools:

      * the archive name must match ^tome- (engine/Module.lua:409), or the
        engine does not even look at it;
      * init.lua must be at the ZIP ROOT, not under src/ -- an archive without
        one is skipped silently at Module.lua:416, with no error;
      * entry names must use FORWARD slashes. physfs mounts subdirectories as
        subdir:/hooks/|... (Module.lua:501-533); an entry literally named
        "hooks\load.lua" is a root-level file with a backslash in its name, so
        the mount finds nothing and the addon lists as installed while
        contributing nothing at all.

    On this host (PowerShell 5.1 / .NET Framework) both Compress-Archive and
    ZipFile::CreateFromDirectory emit backslash entry names plus directory
    entries; tar.exe emits ./-prefixed ones. So the archive is built entry by
    entry through ZipArchive.CreateEntry with names we control, and then
    reopened and checked against all three rules before it is allowed to
    survive.

    What gets in: the contents of src/, minus dot-files and editor/merge
    detritus. Packing src/ rather than the repo is itself the main protection
    -- it is structurally impossible for tools/ (which executes arbitrary Lua
    from disk) or docs/ to reach a build. v1's 0.0.10 shipped .github/,
    CONTRIBUTING.md, readme.md and superload/mod/class/Actor.lua.orig because
    it was zipped by hand; that is the failure mode this replaces.

    Run:
        powershell -ExecutionPolicy Bypass -File .\tools\pack.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\pack.ps1 -Release

    -Release additionally refuses to build from a dirty tree or an untagged
    HEAD, so a released artifact always corresponds to a commit you can name.

    T-050.
#>
[CmdletBinding()]
param(
    [switch]$Release,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

$SHORT_NAME = 'skoobot_reclauded'

# Extensions that are never part of an addon: merge leftovers, editor files,
# backups. A .orig is exactly what v1 shipped by accident.
$DenyExt = @('.orig', '.rej', '.bak', '.swp', '.swo', '.tmp', '.log', '.ps1', '.sh', '.bat', '.cmd')
# Everything an addon plausibly ships. Anything else is reported, and refused
# outright under -Release, rather than being quietly included.
$AllowExt = @('.lua', '.png', '.jpg', '.jpeg', '.ogg', '.wav', '.ttf', '.otf', '.txt', '.json', '.glsl', '.frag', '.vert')

function Die($msg) {
    Write-Host ''
    Write-Host "[pack] FAILED - $msg"
    exit 1
}

# --------------------------------------------------------------------------
# Version, from the manifest the engine reads.
# --------------------------------------------------------------------------
$initPath = Join-Path $SrcDir 'init.lua'
if (-not (Test-Path $initPath)) { Die "no manifest at $initPath" }
$initText = Get-Content $initPath -Raw
if ($initText -notmatch 'addon_version\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}') {
    Die 'could not read addon_version from src/init.lua'
}
$Version = '{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]

# Development builds carry the commit in the name (T-055). Two artifacts from
# different commits are otherwise both "0.1.0" and indistinguishable after the
# fact -- the owner lost the provenance of a crash to exactly that. The engine
# only needs the ^tome- prefix and the .teaa suffix (engine/Module.lua:409)
# and takes the addon's identity from init.lua, so the stamp is inert at load
# time; it does appear in the engine log's "Binding addon" line, and so in
# every error report. Releases keep the canonical name. No stderr redirect on
# the git calls: under 'Stop' a redirected native stderr line throws (see
# OPERATIONS 2.1.1); an unstamped name is the graceful outcome outside a repo.
$Stamp = ''
if (-not $Release) {
    $sha = & git -C $RepoRoot rev-parse --short=7 HEAD
    if ($LASTEXITCODE -eq 0 -and $sha) {
        $Stamp = "-g$sha"
        $dirtySrc = & git -C $RepoRoot status --porcelain -- src
        if ($LASTEXITCODE -eq 0 -and $dirtySrc) { $Stamp += '-dirty' }
    }
}
$ArchiveName = "tome-$SHORT_NAME-$Version$Stamp.teaa"
$ArchivePath = Join-Path $OutDir $ArchiveName

Write-Host ''
Write-Host "[pack] $ArchiveName"
Write-Host "[pack] from $SrcDir"

# --------------------------------------------------------------------------
# -Release preconditions
# --------------------------------------------------------------------------
if ($Release) {
    $dirty = & git -C $RepoRoot status --porcelain
    if ($LASTEXITCODE -ne 0) { Die 'git status failed' }
    if ($dirty) {
        Write-Host '[pack] working tree is dirty:'
        foreach ($d in $dirty) { Write-Host "         $d" }
        Die 'refusing to build a release from a dirty tree'
    }
    $tag = & git -C $RepoRoot describe --exact-match --tags HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tag) {
        Die 'refusing to build a release from an untagged HEAD (see T-052)'
    }
    Write-Host "[pack] release tag $tag"
}

# --------------------------------------------------------------------------
# Choose the files
# --------------------------------------------------------------------------
$srcFull = (Get-Item $SrcDir).FullName.TrimEnd('\')
$all = Get-ChildItem $SrcDir -Recurse -File -Force

$entries = @()
$skipped = @()
$unknown = @()

foreach ($f in $all) {
    $rel = $f.FullName.Substring($srcFull.Length + 1) -replace '\\', '/'

    # Any dot-prefixed path segment: .gitkeep, .github, .DS_Store, ...
    $isDot = @($rel -split '/') | Where-Object { $_.StartsWith('.') }
    if ($isDot.Count -gt 0) { $skipped += "$rel  (dot-file)"; continue }

    $ext = [IO.Path]::GetExtension($f.Name).ToLowerInvariant()
    if ($DenyExt -contains $ext) { $skipped += "$rel  ($ext)"; continue }
    if ($f.Name.EndsWith('~'))   { $skipped += "$rel  (backup)"; continue }

    if ($AllowExt -notcontains $ext) { $unknown += $rel }
    $entries += [pscustomobject]@{ Rel = $rel; Full = $f.FullName }
}

if ($entries.Count -eq 0) { Die 'nothing to pack' }
if (-not ($entries.Rel -contains 'init.lua')) {
    Die 'src/init.lua would not be at the archive root'
}

# Refused in every build, not just -Release. If a dev build could contain a
# file a release build would not, then the clean-build gate (T-035) proves a
# different artifact from the one users receive, which is most of the value
# gone. Adding a genuinely new asset type is a deliberate one-line change to
# $AllowExt, and should be.
if ($unknown.Count -gt 0) {
    Write-Host ''
    Write-Host '[pack] unrecognised file types under src/:'
    foreach ($u in $unknown) { Write-Host "         $u" }
    Write-Host '       Addons ship code and assets. If this really belongs in a build,'
    Write-Host '       add its extension to $AllowExt in this script.'
    Die 'refusing to guess whether these should ship'
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (Test-Path $ArchivePath) { Remove-Item $ArchivePath -Force }

$zip = [IO.Compression.ZipFile]::Open($ArchivePath, 'Create')
try {
    foreach ($e in ($entries | Sort-Object Rel)) {
        # CreateEntry takes the name verbatim -- this is the only way to be
        # sure of the separator. No directory entries are created at all;
        # v1's artifacts have none either.
        $entry  = $zip.CreateEntry($e.Rel, [IO.Compression.CompressionLevel]::Optimal)
        $stream = $entry.Open()
        try {
            $bytes = [IO.File]::ReadAllBytes($e.Full)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    }
} finally { $zip.Dispose() }

# --------------------------------------------------------------------------
# Verify the artifact, not the intention
# --------------------------------------------------------------------------
$problems = @()
$listing  = @()
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    foreach ($e in $zip.Entries) {
        $n = $e.FullName
        $listing += [pscustomobject]@{ Name = $n; Length = $e.Length }
        if ($n -match '\\')            { $problems += "backslash in entry name: $n" }
        if ($n.StartsWith('./'))       { $problems += "leading ./ in entry name: $n" }
        if ($n.StartsWith('/'))        { $problems += "absolute entry name: $n" }
        if ($n.EndsWith('/'))          { $problems += "directory entry: $n" }
        if ($n -match '(^|/)\.gitkeep$') { $problems += "placeholder shipped: $n" }
        if ($n -match '^(tools|spec|docs)/') { $problems += "development tree shipped: $n" }
        if ($n -match '^src/')         { $problems += "src/ prefix not stripped: $n" }
    }
    if (-not ($zip.Entries.FullName -contains 'init.lua')) {
        $problems += 'no init.lua at the archive root (the engine skips such an archive silently)'
    }
} finally { $zip.Dispose() }

Write-Host ''
Write-Host "[pack] $($listing.Count) entries:"
foreach ($l in ($listing | Sort-Object Name)) {
    Write-Host ('         {0,-52} {1,8}' -f $l.Name, $l.Length)
}

if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host '[pack] excluded:'
    foreach ($s in $skipped) { Write-Host "         $s" }
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host '[pack] the archive is malformed:'
    foreach ($p in $problems) { Write-Host "         $p" }
    Remove-Item $ArchivePath -Force -ErrorAction Ignore
    Die 'archive deleted rather than left to be installed'
}

$size = (Get-Item $ArchivePath).Length
Write-Host ''
Write-Host "[pack] PASS - $ArchivePath ($size bytes)"
Write-Host '       Loading it standalone is a separate check: tools/clean-build.ps1 (T-035)'
exit 0
