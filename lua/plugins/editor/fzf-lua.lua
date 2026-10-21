---@type LazySpec
-- NOTE: Debian's fzf is 0.44.1, which predates the `transform(...)` action
-- (needs fzf >= 0.48). LazyVim's `editor.fzf` extra wires `ctrl-t` to
-- `require("trouble.sources.fzf").actions.open`, whose `prefix` is
-- `transform([ $FZF_SELECT_COUNT -eq 0 ] && echo select-all)`.
-- fzf rejects that at startup with "unknown action: transform(...)" and exits
-- (status 2), so the picker opens and closes immediately.
-- Use trouble's plain `open_selected` action instead, which sends no prefix.
return {
  "ibhagwan/fzf-lua",
  opts = function(_, opts)
    local ok, trouble_fzf = pcall(require, "trouble.sources.fzf")
    if not ok then
      return opts
    end

    -- Replace the transform-prefixed action, keeping the same behavior otherwise.
    opts.actions = opts.actions or {}
    opts.actions.files = opts.actions.files or {}
    opts.actions.files["ctrl-t"] = trouble_fzf.actions.open_selected
    return opts
  end,
}
