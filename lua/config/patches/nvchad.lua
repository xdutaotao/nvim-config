-- Local patches for third-party plugins whose bugs have not been fixed upstream.
--
-- Applied automatically via each plugin's Lazy `build` hook, so they survive
-- `:Lazy update`. Each patch is idempotent: re-running it on an already
-- patched file is a no-op.

local M = {}

---Replace `old` with `new` in `path` if `old` is present.
---@param path string absolute file path
---@param old string exact text to find
---@param new string replacement text
---@return boolean changed, string? reason
local function replace_in_file(path, old, new)
  local fd = io.open(path, "r")
  if not fd then
    return false, "cannot read " .. path
  end
  local content = fd:read("*a")
  fd:close()

  if content:find(new, 1, true) then
    return false, "already patched"
  end
  if not content:find(old, 1, true) then
    return false, "pattern not found (upstream may have changed)"
  end

  local out = io.open(path, "w")
  if not out then
    return false, "cannot write " .. path
  end
  out:write((content:gsub(old:gsub("%p", "%%%0"), (new:gsub("%%", "%%%%")))))
  out:close()
  return true
end

---nvchad/ui: guard `bufs[1]` before reading its name.
---Without the guard, `BufAdd` on a stale/wiped bufnr raises
---"Invalid buffer id" from nvim_buf_get_name.
function M.apply()
  local path = vim.fs.joinpath(
    vim.fn.stdpath("data"),
    "lazy/ui/lua/nvchad/tabufline/lazyload.lua"
  )

  local old = 'if args.event == "BufAdd" then'
  local new = 'if args.event == "BufAdd" and bufs[1] and api.nvim_buf_is_valid(bufs[1]) then'

  local changed, reason = replace_in_file(path, old, new)
  if changed then
    vim.notify("[patch] nvchad/ui tabufline: guarded stale bufs[1]", vim.log.levels.INFO)
  elseif reason ~= "already patched" then
    vim.notify("[patch] nvchad/ui tabufline: " .. reason, vim.log.levels.WARN)
  end
end

return M
