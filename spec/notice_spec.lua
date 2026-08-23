-- luacheck: std luajit+busted

-- data/notice.lua is the one place a stop is worded and coloured (#58). These
-- specs pin the contract the call sites, the harness and the popup rely on:
-- one prefix, one colour per severity, a reason string with nothing but the
-- label and the text in it, and no formatting of the text on the way through.

local manifest = require "spec.support.manifest"

local function loadNotice()
  local chunk = assert(loadfile(manifest.path("src/data/notice.lua")))
  return chunk()
end

describe("data/notice.lua compose()", function()
  local notice

  setup(function() notice = loadNotice() end)

  it("has three severities with distinct labels and colours", function()
    local seen_label, seen_colour = {}, {}
    for _, sev in ipairs({ notice.STOPPED, notice.HANDED_BACK, notice.CANNOT_ACT }) do
      local n = notice.compose(sev, "x")
      assert.equals(sev, n.severity)
      assert.is_nil(seen_label[n.label], "label reused: " .. n.label)
      assert.is_nil(seen_colour[n.colour], "colour reused: " .. n.colour)
      seen_label[n.label], seen_colour[n.colour] = true, true
    end
  end)

  it("words a stop as Stopped / Handed back / Cannot act", function()
    assert.equals("Stopped: stunned", notice.compose(notice.STOPPED, "stunned").reason)
    assert.equals("Handed back: a glowing chest is nearby",
      notice.compose(notice.HANDED_BACK, "a glowing chest is nearby").reason)
    assert.equals("Cannot act: no path to the nearest enemy",
      notice.compose(notice.CANNOT_ACT, "no path to the nearest enemy").reason)
  end)

  it("keeps the reason free of colour codes, prefix and hint", function()
    local n = notice.compose(notice.STOPPED, "low life", "restart with Shift+F3")
    assert.equals("Stopped: low life", n.reason)
    assert.is_nil(n.reason:find("#", 1, true))
    assert.is_nil(n.reason:find("[SkooBot]", 1, true))
  end)

  it("puts the prefix, in bold, and the hint on the log line", function()
    local n = notice.compose(notice.STOPPED, "low life", "restart with Shift+F3")
    assert.equals(n.colour .. "#{bold}#[SkooBot]#{normal}# Stopped: low life (restart with Shift+F3)", n.line)
  end)

  it("omits the parentheses when there is no hint", function()
    assert.equals("#GOLD##{bold}#[SkooBot]#{normal}# Handed back: level change found",
      notice.compose(notice.HANDED_BACK, "level change found").line)
    assert.equals("#GOLD##{bold}#[SkooBot]#{normal}# Handed back: level change found",
      notice.compose(notice.HANDED_BACK, "level change found", "").line)
  end)

  it("starts every log line with the same prefix, so the log has one thing to scan for", function()
    for _, sev in ipairs({ notice.STOPPED, notice.HANDED_BACK, notice.CANNOT_ACT }) do
      local plain = notice.compose(sev, "x").line:gsub("#[^#]*#", "")
      assert.equals("[SkooBot] ", plain:sub(1, 10))
    end
  end)

  it("makes the banner a coloured one-liner without the prefix", function()
    local n = notice.compose(notice.CANNOT_ACT, "all Combat talents are on cooldown", "open the menu")
    assert.equals("#ORANGE#SkooBot cannot act: all Combat talents are on cooldown", n.banner)
  end)

  it("puts the hint on its own line in the popup body", function()
    local n = notice.compose(notice.STOPPED, "stunned", "restart with Shift+F3")
    assert.equals("#LIGHT_RED#Stopped: stunned#WHITE#\n\nrestart with Shift+F3", n.popup)
    assert.equals("#LIGHT_RED#Stopped: stunned#WHITE#", notice.compose(notice.STOPPED, "stunned").popup)
  end)

  it("treats an unknown severity as STOPPED, the loud one", function()
    local n = notice.compose("whatever", "x")
    assert.equals(notice.STOPPED, n.severity)
    assert.equals("Stopped", n.label)
    assert.equals("Stopped", notice.compose(nil, "x").label)
  end)

  it("does not format the text: a percent sign passes through untouched", function()
    local n = notice.compose(notice.STOPPED, "lost more than 25% life in one turn")
    assert.equals("Stopped: lost more than 25% life in one turn", n.reason)
    assert.is_truthy(n.line:find("25% life", 1, true))
    assert.is_truthy(n.banner:find("25% life", 1, true))
  end)

  it("tolerates a missing text", function()
    assert.equals("Stopped: ", notice.compose(notice.STOPPED, nil).reason)
  end)
end)
