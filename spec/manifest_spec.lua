-- luacheck: std luajit+busted

-- src/init.lua is the one file that ships in every build, and the engine reads
-- it before anything else exists to catch a mistake. These assertions are the
-- only thing standing between a typo here and a module that refuses to load.
--
-- T-040.

local manifest = require "spec.support.manifest"

describe("src/init.lua", function()
  local m, err

  setup(function()
    m, err = manifest.load("src/init.lua")
  end)

  it("evaluates as a Lua chunk", function()
    assert.is_nil(err)
    assert.is_table(m)
  end)

  it("identifies the addon", function()
    assert.are.equal("skoobot_reclauded", m.short_name)
    assert.are.equal("SkooBot: Reclauded", m.long_name)
  end)

  it("is a tome addon", function()
    assert.are.equal("tome", m.for_module)
  end)

  -- ToME addons are version-stamped and the game refuses mismatches, so this
  -- is the field that decides whether the addon is installable at all.
  it("targets game version 1.7.6", function()
    assert.are.same({ 1, 7, 6 }, m.version)
  end)

  it("carries a three-part addon_version for the packer to name builds with", function()
    assert.is_table(m.addon_version)
    assert.are.equal(3, #m.addon_version)
    for i, part in ipairs(m.addon_version) do
      assert.is_number(part, "addon_version[" .. i .. "] is not a number")
    end
  end)

  -- The engine ignores homepage, but every packed build and the te4.org
  -- listing carry it, so a dead link there is shipped to users. Checked
  -- against the actual remote rather than a constant, which cannot rot apart
  -- from the repo it names.
  describe("homepage", function()
    it("is an https URL", function()
      assert.is_string(m.homepage)
      assert.is_truthy(m.homepage:match("^https://"),
        "homepage is not an https URL: " .. tostring(m.homepage))
    end)

    it("points at the repository this code is in", function()
      local origin = manifest.originUrl()
      if not origin then
        pending("no git origin remote available to check against")
        return
      end
      assert.are.equal(origin, m.homepage)
    end)
  end)

  -- The load-bearing one.
  --
  -- `hooks = true` makes the engine loadfile() <addon>/hooks/load.lua and
  -- error(err) on failure, outside any pcall (engine/Module.lua:697-698), so a
  -- flag set over a directory with no load.lua aborts module load the first
  -- time the addon is enabled. data/overload/superload over an empty directory
  -- are mount-only and harmless, but they are held to the same rule so the
  -- manifest describes the tree rather than an intention.
  describe("directory flags", function()
    local dirs = {
      hooks     = "src/hooks",
      overload  = "src/overload",
      superload = "src/superload",
      data      = "src/data",
    }

    for flag, dir in pairs(dirs) do
      it("declares " .. flag .. " only if " .. dir .. " has real content", function()
        if m[flag] then
          assert.is_true(manifest.hasRealFiles(dir),
            flag .. " = true but " .. dir .. " holds nothing but placeholders")
        end
      end)
    end

    it("ships a hooks/load.lua whenever hooks is declared", function()
      if m.hooks then
        local f = io.open(manifest.path("src/hooks/load.lua"), "r")
        assert.is_truthy(f,
          "hooks = true but src/hooks/load.lua does not exist; " ..
          "engine/Module.lua:697-698 raises outside any pcall and module load aborts")
        if f then f:close() end
      end
    end)
  end)
end)
