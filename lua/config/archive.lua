-- Archive browser for Neovim.
--
-- Replaces the builtin tar.vim (which is disabled via lazy.nvim's
-- `disabled_plugins`). tar.vim models a member as
-- `tarfile:<archive>::<member>`, a shape that cannot express an archive
-- inside an archive: the second `::` is ambiguous. It also never checks
-- `bufexists()`, so reopening a member raises E95.
--
-- This module uses a JAR-style URI instead:
--
--   archive:///abs/outer.tar.gz!/inner.tar.gz!/userdata/milog/monitor.log
--
-- Nesting is just another `!/` segment, and every buffer is a plain
-- `nofile` buffer, so neither the ambiguity nor the E95 conflict exists.
--
-- Supported containers: tar (optionally .gz/.bz2/.xz/.zst/.lz4 compressed)
-- and zip. Single-file compressors (.gz, .xz, …) open as their decompressed
-- content unless the payload turns out to be a tar, in which case the buffer
-- becomes a browse view.

local M = {}

local api = vim.api

-- ---------------------------------------------------------------------------
-- Shell helpers
-- ---------------------------------------------------------------------------

---@param s string
---@return string
local function q(s)
  return vim.fn.shellescape(s)
end

---@param cmd string
---@return boolean
function M.sh(cmd)
  vim.fn.system({ "sh", "-c", cmd })
  return vim.v.shell_error == 0
end

-- ---------------------------------------------------------------------------
-- Temporary files
-- ---------------------------------------------------------------------------

---@type table<string, true>
M._tmp = {}

---@param suffix? string
---@return string
local function tmpfile(suffix)
  local path = vim.fn.tempname() .. (suffix or "")
  M._tmp[path] = true
  return path
end

local function cleanup_tmp()
  for path in pairs(M._tmp) do
    pcall(vim.fn.delete, path)
  end
  M._tmp = {}
end

-- ---------------------------------------------------------------------------
-- URI handling
-- ---------------------------------------------------------------------------

---Split `archive://<root>!/<a>!/<b>` into root + members.
---@param uri string
---@return { path: string, members: string[] }|nil
function M.parse(uri)
  local rest = uri:match("^archive://(.+)$")
  if not rest then
    return nil
  end

  local parts = {}
  local pos = 1
  while true do
    local s, e = rest:find("!/", pos, true)
    if not s then
      parts[#parts + 1] = rest:sub(pos)
      break
    end
    parts[#parts + 1] = rest:sub(pos, s - 1)
    pos = e + 1
  end

  if #parts == 0 or parts[1] == "" then
    return nil
  end

  return { path = parts[1], members = vim.list_slice(parts, 2) }
end

---@param path string
---@param members? string[]
---@return string
function M.build(path, members)
  local uri = "archive://" .. path
  for _, m in ipairs(members or {}) do
    uri = uri .. "!/" .. m
  end
  return uri
end

---Name of the deepest member in `uri`, or the archive's basename.
---@param uri string
---@return string
function M.leaf(uri)
  local parsed = M.parse(uri)
  if not parsed then
    return uri
  end
  if #parsed.members == 0 then
    return vim.fn.fnamemodify(parsed.path, ":t")
  end
  return parsed.members[#parsed.members]
end

-- ---------------------------------------------------------------------------
-- Format detection
-- ---------------------------------------------------------------------------

---@type table<string, string>
local DECOMP = {
  gzip = "gzip -d -c",
  bzip2 = "bzip2 -d -c",
  xz = "xz -d -c",
  zstd = "zstd -d -c",
  lz4 = "lz4 -d -c",
}

---Identify a file by magic bytes. Reads two offsets so a plain tar is
---recognised by the POSIX header at byte 257 rather than by its name.
---@param path string
---@return string kind  one of gzip|bzip2|xz|zstd|lz4|zip|tar|plain
local function sniff(path)
  local fd = io.open(path, "rb")
  if not fd then
    return "plain"
  end

  local head = fd:read(6) or ""
  fd:seek("set", 257)
  local tar_magic = fd:read(5) or ""
  fd:close()

  local hex = head:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end)

  if hex:sub(1, 4) == "1f8b" then
    return "gzip"
  elseif hex:sub(1, 6) == "425a68" then
    return "bzip2"
  elseif hex:sub(1, 12) == "fd377a585a00" then
    return "xz"
  elseif hex:sub(1, 8) == "28b52ffd" then
    return "zstd"
  elseif hex:sub(1, 8) == "04224d18" then
    return "lz4"
  elseif hex:sub(1, 8) == "504b0304" or hex:sub(1, 8) == "504b0506" then
    return "zip"
  elseif hex:sub(1, 12) == "377abcaf271c" then
    return "7z"
  elseif hex:sub(1, 8) == "52617221" then
    return "rar"
  elseif tar_magic == "ustar" then
    return "tar"
  end
  return "plain"
end

-- ---------------------------------------------------------------------------
-- Resolution: URI -> a plain local file plus its container kind
-- ---------------------------------------------------------------------------

---@class Archive.Resolved
---@field kind "tar"|"zip"|"plain"
---@field file string     local path holding the resolved payload
---@field peeled string[] compression layers removed, outermost first

---@type table<string, { key: string, resolved: Archive.Resolved }>
M._cache = {}

---@param path string
---@return string
local function stat_key(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    return "missing"
  end
  return ("%d:%d"):format(st.mtime.sec, st.size)
end

---Extract `member` from an already-resolved container.
---@param container Archive.Resolved
---@param member string
---@param out string
---@return boolean
local function extract_one(container, member, out)
  if container.kind == "tar" then
    return M.sh(("tar -xf %s -O -- %s > %s"):format(q(container.file), q(member), q(out)))
  elseif container.kind == "zip" then
    return M.sh(("unzip -p %s %s > %s"):format(q(container.file), q(member), q(out)))
  elseif container.kind == "7z" then
    return M.sh(("7z e -so %s %s > %s 2>/dev/null"):format(q(container.file), q(member), q(out)))
  elseif container.kind == "rar" then
    return M.sh(("unrar p -inul %s %s > %s"):format(q(container.file), q(member), q(out)))
  end
  return false
end

---Materialise the member chain to a local file (still possibly compressed).
---@param parsed { path: string, members: string[] }
---@return string|nil
local function materialize(parsed)
  if #parsed.members == 0 then
    return parsed.path
  end

  local parent_uri = M.build(parsed.path, vim.list_slice(parsed.members, 1, #parsed.members - 1))
  local parent = M.resolve(parent_uri)
  if not parent or parent.kind == "plain" then
    return nil
  end

  local member = parsed.members[#parsed.members]
  local out = tmpfile("__" .. vim.fn.fnamemodify(member, ":t"))
  if not extract_one(parent, member, out) then
    return nil
  end
  return out
end

---Resolve a URI to a local file, peeling compression until a container or
---plain bytes appear.
---@param uri string
---@return Archive.Resolved|nil, string? err
function M.resolve(uri)
  local parsed = M.parse(uri)
  if not parsed then
    return nil, "not an archive URI: " .. uri
  end

  local key = stat_key(parsed.path)
  local hit = M._cache[uri]
  if hit and hit.key == key then
    return hit.resolved
  end

  local file = materialize(parsed)
  if not file then
    return nil, "cannot extract " .. uri
  end
  if vim.fn.filereadable(file) == 0 then
    return nil, "no such archive: " .. file
  end

  local peeled = {}
  local kind
  -- Cap the peel depth: a decade of nested compression would be a bug, and
  -- an unbounded loop here would hang the editor.
  for _ = 1, 4 do
    kind = sniff(file)
    local cmd = DECOMP[kind]
    if not cmd then
      break
    end
    local out = tmpfile(".plain")
    if not M.sh(("%s -- %s > %s"):format(cmd, q(file), q(out))) then
      return nil, "cannot decompress " .. file
    end
    peeled[#peeled + 1] = kind
    file = out
    kind = nil
  end
  kind = kind or sniff(file)

  local resolved = { kind = kind, file = file, peeled = peeled }
  M._cache[uri] = { key = key, resolved = resolved }
  return resolved
end

---Drop cached extractions so the next render re-reads from disk.
function M.invalidate()
  M._cache = {}
end

-- ---------------------------------------------------------------------------
-- Listings
-- ---------------------------------------------------------------------------

---@class Archive.Item
---@field name string
---@field size number
---@field dir boolean

---@param file string
---@return Archive.Item[]|nil
local function list_tar(file)
  local out = vim.fn.system({ "tar", "-tvf", file })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local items = {}
  for line in out:gmatch("[^\r\n]+") do
    -- "-rw-r--r-- user/group 465412 2026-10-02 10:32 path/to/file"
    local perms, size, name = line:match("^(%S+)%s+%S+%s+(%d+)%s+%S+%s+%S+%s+(.+)$")
    if name then
      name = name:gsub("%s+%->%s+.*$", "")
      items[#items + 1] = {
        name = name,
        size = tonumber(size) or 0,
        dir = perms:sub(1, 1) == "d",
      }
    end
  end
  return items
end

---@param file string
---@return Archive.Item[]|nil
local function list_zip(file)
  local out = vim.fn.system({ "unzip", "-l", file })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local items = {}
  for line in out:gmatch("[^\r\n]+") do
    local size, name = line:match("^%s*(%d+)%s+%S+%s+%S+%s+(.+)$")
    if name then
      items[#items + 1] = {
        name = name,
        size = tonumber(size) or 0,
        dir = name:sub(-1) == "/",
      }
    end
  end
  return items
end

---`7z l -slt` emits `Field = value` blocks separated by blank lines, which is
---far more robust to parse than the fixed-width table.
---@param file string
---@return Archive.Item[]|nil
local function list_7z(file)
  local out = vim.fn.system({ "7z", "l", "-slt", file })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local items = {}
  local current

  ---@param entry table|nil
  local function flush(entry)
    -- The archive's own `Path = /abs/arch.7z` appears in the metadata block
    -- before the `----------` separator; real members are relative.
    if entry and entry.name and not entry.name:match("^/") then
      items[#items + 1] = entry
    end
  end

  for line in (out .. "\n\n"):gmatch("([^\n]*)\n") do
    local key, value = line:match("^(%w[%w ]*) = ?(.*)$")
    if key == "Path" then
      flush(current)
      current = { name = value, size = 0, dir = false }
    elseif key == "Size" and current then
      current.size = tonumber(value) or 0
    elseif key == "Attributes" and current then
      current.dir = value:find("D", 1, true) ~= nil
    elseif line == "" then
      -- block separator: the entry is complete
      flush(current)
      current = nil
    end
  end
  flush(current)

  return items
end

---`unrar l` prints `Attributes  Size  Date  Time  Name`, with `D` in the
---attribute field marking a directory:
---  "    .......      1243  2024-06-19 16:42  6/stereo_cali.dat"
---  "    ...D...         0  2024-07-15 17:19  6"
---@param file string
---@return Archive.Item[]|nil
local function list_rar(file)
  local out = vim.fn.system({ "unrar", "l", file })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local items = {}
  for line in out:gmatch("[^\r\n]+") do
    local attrs, size, name = line:match("^%s*([%.%a]+)%s+(%d+)%s+%d%d%d%d%-%d%d%-%d%d%s+%d%d:%d%d%s+(.+)$")
    if name then
      items[#items + 1] = {
        name = name,
        size = tonumber(size) or 0,
        dir = attrs:find("D", 1, true) ~= nil,
      }
    end
  end
  return items
end

---@param resolved Archive.Resolved
---@return Archive.Item[]|nil
function M.list(resolved)
  if resolved.kind == "tar" then
    return list_tar(resolved.file)
  elseif resolved.kind == "zip" then
    return list_zip(resolved.file)
  elseif resolved.kind == "7z" then
    return list_7z(resolved.file)
  elseif resolved.kind == "rar" then
    return list_rar(resolved.file)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

---Line -> item maps for browse buffers, keyed by buffer number.
---
---Kept in Lua rather than in a `b:` variable: assigning a sparse table to
---`vim.b` round-trips it through Vimscript, turning holes into `vim.NIL`.
---@type table<integer, table<integer, Archive.Item>>
local browse_items = {}

---@param n number
---@return string
local function fmt_size(n)
  if n >= 1024 * 1024 then
    return ("%.1fM"):format(n / 1024 / 1024)
  elseif n >= 1024 then
    return ("%.1fK"):format(n / 1024)
  end
  return tostring(n)
end

---@param buf integer
---@param uri string
---@param items Archive.Item[]
local function render_browse(buf, uri, items)
  local lines = {
    '" ' .. uri,
    '" <CR> open   -  up   x  extract   q  close',
    '" ' .. #items .. " entries",
    "",
  }
  ---@type table<integer, Archive.Item>
  local by_line = {}

  for _, item in ipairs(items) do
    local size = item.dir and "" or fmt_size(item.size)
    lines[#lines + 1] = ("%-9s %s"):format(size, item.name)
    by_line[#lines] = item
  end

  if #items == 0 then
    lines[#lines + 1] = '" (empty archive)'
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.b[buf].archive_uri = uri
  browse_items[buf] = by_line
end

---@param buf integer
---@param uri string
---@param resolved Archive.Resolved
local function render_content(buf, uri, resolved)
  local lines = vim.fn.readfile(resolved.file)

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.b[buf].archive_uri = uri
  browse_items[buf] = nil

  -- Peeling strips the compression extension, so match the filetype on the
  -- payload name rather than on the URI's `.gz` tail.
  local name = M.leaf(uri)
  for _, ext in ipairs({ "%.gz$", "%.xz$", "%.bz2$", "%.zst$", "%.lz4$", "%.Z$" }) do
    name = name:gsub(ext, "")
  end
  local ft = vim.filetype.match({ filename = name })
  if ft then
    vim.bo[buf].filetype = ft
  end
end

-- ---------------------------------------------------------------------------
-- Buffer management
-- ---------------------------------------------------------------------------

---@param name string
---@return integer|nil
local function find_buf(name)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) and api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return nil
end

---@param buf integer
local function setup_maps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    M.enter()
  end, opts)
  vim.keymap.set("n", "-", function()
    M.up()
  end, opts)
  vim.keymap.set("n", "x", function()
    M.extract()
  end, opts)
  vim.keymap.set("n", "q", function()
    api.nvim_win_close(0, true)
  end, opts)
end

---Fill `buf` with the view for `uri`.
---@param buf integer
---@param uri string
---@return boolean ok
function M.fill(buf, uri)
  local resolved, err = M.resolve(uri)
  if not resolved then
    vim.notify("Archive: " .. (err or "cannot read " .. uri), vim.log.levels.ERROR)
    return false
  end

  local browse = resolved.kind == "tar"
    or resolved.kind == "zip"
    or resolved.kind == "7z"
    or resolved.kind == "rar"
  if browse then
    local items = M.list(resolved)
    if not items then
      vim.notify("Archive: cannot list " .. uri, vim.log.levels.ERROR)
      return false
    end
    render_browse(buf, uri, items)
    vim.bo[buf].filetype = "archive"
  else
    render_content(buf, uri, resolved)
  end

  vim.bo[buf].buftype = "nofile"
  -- Keep the buffer alive when it leaves its window: archive listings and
  -- extracted members are views you switch back to, so wiping them would
  -- force a re-extraction every time. `:bd` still removes them on demand.
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = true
  vim.bo[buf].buflisted = true
  setup_maps(buf)
  return true
end

---Open `uri`, reusing an existing buffer when one is already showing it.
---@param uri string
---@param buf? integer buffer to repurpose; defaults to a new one
---@return boolean ok
function M.open(uri, buf)
  local existing = find_buf(uri)
  if existing and existing ~= buf then
    api.nvim_set_current_buf(existing)
    if buf and api.nvim_buf_is_valid(buf) then
      vim.schedule(function()
        pcall(api.nvim_buf_delete, buf, { force = true })
      end)
    end
    return true
  end

  local target = buf or api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(target, uri)
  if not M.fill(target, uri) then
    return false
  end
  if api.nvim_get_current_buf() ~= target then
    api.nvim_set_current_buf(target)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

---@param uri string
---@param name string
---@return string
function M.child_uri(uri, name)
  return uri .. "!/" .. name
end

---Entry under the cursor in the current browse buffer.
---@return Archive.Item|nil
local function current_item()
  local items = browse_items[api.nvim_get_current_buf()]
  if not items then
    return nil
  end
  return items[api.nvim_win_get_cursor(0)[1]]
end

---Open the entry under the cursor.
function M.enter()
  local item = current_item()
  local uri = vim.b.archive_uri
  if not item or not uri then
    return
  end
  if item.dir then
    vim.notify("Archive: directories are not browsable on their own", vim.log.levels.INFO)
    return
  end
  M.open(M.child_uri(uri, item.name))
end

---Go up one level, or close the window at the archive root.
function M.up()
  local uri = vim.b.archive_uri
  local parsed = uri and M.parse(uri)
  if not parsed then
    return
  end

  if #parsed.members == 0 then
    -- At the archive root: leave the browse view for the most recent
    -- non-archive buffer. `#` is unreliable here because the placeholders
    -- created by BufReadCmd would win. The archive buffer is kept either way,
    -- so it stays reachable from the buffer list.
    local root = api.nvim_get_current_buf()
    local fallback
    for _, b in ipairs(api.nvim_list_bufs()) do
      if b ~= root
        and api.nvim_buf_is_valid(b)
        and vim.bo[b].buflisted
        and vim.bo[b].buftype == ""
        and not vim.b[b].archive_uri
      then
        fallback = b
      end
    end

    if fallback then
      vim.cmd("buffer " .. fallback)
    else
      vim.cmd.edit(vim.fn.fnameescape(vim.fn.fnamemodify(parsed.path, ":h")))
    end
    return
  end

  M.open(M.build(parsed.path, vim.list_slice(parsed.members, 1, #parsed.members - 1)))
end

---Extract the entry under the cursor into the working directory.
function M.extract()
  local item = current_item()
  local uri = vim.b.archive_uri
  local parsed = uri and M.parse(uri)
  if not item or not parsed or item.dir then
    return
  end

  local container = M.resolve(uri)
  if not container or container.kind == "plain" then
    vim.notify("Archive: cannot extract from this buffer", vim.log.levels.ERROR)
    return
  end

  local out = vim.fn.fnamemodify(item.name, ":t")
  if vim.uv.fs_stat(out) then
    vim.notify("Archive: " .. out .. " already exists", vim.log.levels.WARN)
    return
  end

  if not extract_one(container, item.name, out) then
    vim.notify("Archive: failed to extract " .. item.name, vim.log.levels.ERROR)
    return
  end
  vim.notify("Archive: extracted " .. out, vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

---Suffixes handled by the BufReadCmd below. `*.tar` alone would not match
---`foo.tar.gz`, so every combination is listed explicitly.
local ARCHIVE_PATTERNS = {
  "*.tar", "*.tar.gz", "*.tar.bz2", "*.tar.xz", "*.tar.zst", "*.tar.lz4",
  "*.tgz", "*.tbz", "*.tbz2", "*.txz", "*.tzst", "*.tlz4",
  "*.zip", "*.7z", "*.rar", "*.cb7", "*.cbr",
}

function M.setup()
  local group = api.nvim_create_augroup("ArchiveBrowser", { clear = true })

  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = ARCHIVE_PATTERNS,
    callback = function(args)
      M.open(M.build(vim.fn.fnamemodify(args.file, ":p"), {}), args.buf)
    end,
  })

  -- Explicit `:edit archive://…`, mostly useful for :ArchiveRefresh.
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "archive://*",
    callback = function(args)
      M.open(args.file, args.buf)
    end,
  })

  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = cleanup_tmp,
  })

  -- Drop the line -> item map when a browse buffer goes away, so the Lua
  -- table does not outlive the buffers it describes.
  api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(args)
      browse_items[args.buf] = nil
    end,
  })

  api.nvim_create_user_command("ArchiveRefresh", function()
    M.invalidate()
    local uri = vim.b.archive_uri
    if uri then
      M.fill(api.nvim_get_current_buf(), uri)
    end
  end, { desc = "Re-read the current archive from disk" })
end

return M
