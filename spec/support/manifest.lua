-- Load an addon manifest the way the engine does: as a plain Lua chunk whose
-- globals ARE the manifest (engine/Module.lua reads short_name, hooks, ... off
-- the chunk's environment). Evaluating the real file in a sandbox, rather than
-- parsing it with a regex, means the spec tests what the engine will see.
--
-- Deliberately dialect-agnostic. The suite is pinned to LuaJIT/5.1 (.busted,
-- spec/dialect_spec.lua) because that is the game's dialect, but a sandbox
-- loader is exactly the sort of helper that should not itself be the thing
-- that breaks if someone runs it elsewhere.

local M = {}

local SEP = "[/" .. string.char(92) .. "]"   -- char(92) is a backslash

--- Repo root, derived from this file's own location rather than from cwd, so
--- the suite works from any working directory.
function M.root()
  local here = debug.getinfo(1, "S").source:match("^@(.*)$")
  if not here then return "." end
  local dir = here:gsub(SEP .. "[^/" .. string.char(92) .. "]*$", "")  -- .../spec/support
  dir = dir:gsub(SEP .. "[^/" .. string.char(92) .. "]*$", "")         -- .../spec
  dir = dir:gsub(SEP .. "[^/" .. string.char(92) .. "]*$", "")         -- repo root
  if dir == "" then return "." end
  return dir
end

function M.path(rel)
  return M.root() .. "/" .. rel
end

--- Evaluate a manifest file and return its globals as a table.
function M.load(rel)
  local file = M.path(rel)
  local env  = {}
  local chunk, err

  if setfenv then                                        -- Lua 5.1 / LuaJIT
    chunk, err = loadfile(file)
    if not chunk then return nil, err end
    setfenv(chunk, env)
  else                                                   -- Lua 5.2+
    chunk, err = loadfile(file, "t", env)
    if not chunk then return nil, err end
  end

  local ok, ferr = pcall(chunk)
  if not ok then return nil, ferr end
  return env
end

--- Does `rel` hold at least one file that is not a .gitkeep placeholder?
--- This is the question the directory flags make load-bearing, so it counts
--- files rather than testing that the directory exists.
function M.hasRealFiles(rel)
  local dir = M.path(rel)

  local ok, lfs = pcall(require, "lfs")
  if ok and lfs then
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return false end
    for entry in lfs.dir(dir) do
      if entry ~= "." and entry ~= ".." and entry ~= ".gitkeep" then
        local a = lfs.attributes(dir .. "/" .. entry)
        if a and a.mode == "directory" then
          if M.hasRealFiles(rel .. "/" .. entry) then return true end
        else
          return true
        end
      end
    end
    return false
  end

  -- No LuaFileSystem: fall back to the shell, and fail loudly if even that is
  -- unavailable. Silently reporting "empty" would turn the assertion that
  -- depends on this into a no-op, which is worse than an error.
  local windows = package.config:sub(1, 1) == string.char(92)
  local cmd
  if windows then
    cmd = 'dir /b /s /a-d "' .. dir:gsub("/", string.char(92)) .. '" 2>nul'
  else
    cmd = 'find "' .. dir .. '" -type f 2>/dev/null'
  end
  local pipe = io.popen(cmd)
  if not pipe then
    error("cannot list " .. dir .. ": no lfs and no io.popen")
  end
  local found = false
  for line in pipe:lines() do
    if line ~= "" and not line:match(SEP .. "%.gitkeep$") then
      found = true
      break
    end
  end
  pipe:close()
  return found
end

--- The origin remote's URL, normalised to a bare https GitHub URL, or nil.
--- Used to check the manifest's homepage against where the code actually
--- lives, rather than against a constant that can rot in place.
--- SKOOBOT_GIT_ROOT lets a caller point this at the real working tree when the
--- files under test are somewhere else. The pre-commit hook runs the suite
--- against an extracted copy of the index, which is not a git repository, so
--- without this the homepage check would quietly downgrade to "pending" in the
--- one place it is supposed to be enforced.
function M.originUrl()
  local root = os.getenv("SKOOBOT_GIT_ROOT") or M.root()
  local pipe = io.popen('git -C "' .. root .. '" remote get-url origin 2>&1')
  if not pipe then return nil end
  local out = pipe:read("*a") or ""
  local ok = pipe:close()
  if not ok then return nil end
  local url = out:gsub("%s+$", "")
  if url == "" or url:match("^fatal") then return nil end
  url = url:gsub("%.git$", "")
  url = url:gsub("^git@github%.com:", "https://github.com/")
  url = url:gsub("^ssh://git@github%.com/", "https://github.com/")
  return url
end

return M
