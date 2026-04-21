-- Lazy Watson - i18n preview for Neovim
-- Supports Paraglide (inlang) and typesafe-i18n via pluggable backends.

local backends = require("lazy-watson.backends")
local display = require("lazy-watson.display")

local M = {}

-- Default configuration
M.config = {
  enabled = true,
  debounce_ms = 150,
  virtual_text = {
    prefix = " -> ",
    hl_group = "Comment",
    hl_missing_key = "DiagnosticError",
    hl_missing_locale = "DiagnosticWarn",
    max_length = 50,
    show_missing = true,
    missing_prefix = "  X ",
    hl_missing_locales = "DiagnosticError",
  },
  hover = {
    enabled = true,
    delay = 300,
  },
  project_pattern = "project.inlang/settings.json", -- kept for back-compat (unused)
}

-- State
local state = {
  enabled = true,
  current_locale = nil,
  project_root = nil,
  backend = nil,
  project = nil, -- { base_locale, locales, messages, watch_paths, _data }
  messages = {}, -- mirror of project.messages for quick access
  attached_buffers = {},
  namespace = nil,
  file_watchers = {},
  debounce_timers = {},
}

local supported_filetypes = {
  javascript = true,
  typescript = true,
  svelte = true,
  javascriptreact = true,
  typescriptreact = true,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  state.enabled = M.config.enabled
  state.namespace = vim.api.nvim_create_namespace("lazy_watson")

  local augroup = vim.api.nvim_create_augroup("LazyWatson", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = { "javascript", "typescript", "svelte", "javascriptreact", "typescriptreact" },
    callback = function(args)
      M._attach_buffer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    callback = function(args)
      if state.attached_buffers[args.buf] then
        M._debounced_update(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      M._detach_buffer(args.buf)
    end,
  })

  if M.config.hover.enabled then
    local hover_delay = M.config.hover.delay or 300
    if hover_delay < vim.o.updatetime then
      vim.o.updatetime = hover_delay
    end

    vim.api.nvim_create_autocmd("CursorHold", {
      group = augroup,
      callback = function(args)
        if state.attached_buffers[args.buf] and state.enabled then
          M._trigger_hover()
        end
      end,
    })
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  if supported_filetypes[ft] then
    M._attach_buffer(bufnr)
  end
end

function M.toggle()
  state.enabled = not state.enabled
  if state.enabled then
    vim.notify("Lazy Watson enabled", vim.log.levels.INFO)
    for bufnr, _ in pairs(state.attached_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        M._update_buffer(bufnr)
      end
    end
  else
    vim.notify("Lazy Watson disabled", vim.log.levels.INFO)
    for bufnr, _ in pairs(state.attached_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        display.clear(bufnr, state.namespace)
      end
    end
  end
end

function M.refresh()
  if not state.backend or not state.project_root then
    vim.notify("Lazy Watson: no active i18n project", vim.log.levels.WARN)
    return
  end

  local project = state.backend.load_project(state.project_root)
  if not project then
    vim.notify("Lazy Watson: failed to reload project", vim.log.levels.ERROR)
    return
  end

  state.project = project
  state.messages = project.messages
  if not state.current_locale or not project.messages[state.current_locale] then
    state.current_locale = project.base_locale
  end

  for bufnr, _ in pairs(state.attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M._update_buffer(bufnr)
    end
  end

  vim.notify(
    "Lazy Watson translations refreshed (" .. state.backend.name .. ")",
    vim.log.levels.INFO
  )
end

function M.select_locale()
  if not state.project or not state.project.locales then
    vim.notify("No i18n project loaded", vim.log.levels.WARN)
    return
  end

  local locales = state.project.locales
  if type(locales) ~= "table" or #locales == 0 then
    vim.notify("No locales available", vim.log.levels.WARN)
    return
  end

  vim.ui.select(locales, {
    prompt = "Select locale:",
    format_item = function(locale)
      if not locale then
        return ""
      end
      local marker = ""
      if locale == state.current_locale then
        marker = " (current)"
      elseif locale == state.project.base_locale then
        marker = " (base)"
      end
      return locale .. marker
    end,
  }, function(choice)
    if not choice then
      return
    end

    local ok, err = pcall(function()
      state.current_locale = choice

      if not state.messages[choice] and state.backend and state.project_root then
        state.messages[choice] = state.backend.reload_locale(state.project_root, state.project, choice)
        state.project.messages[choice] = state.messages[choice]
      end

      vim.schedule(function()
        for bufnr, _ in pairs(state.attached_buffers) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            M._update_buffer(bufnr)
          end
        end
      end)
    end)

    if not ok then
      vim.notify("Error setting locale: " .. tostring(err), vim.log.levels.ERROR)
      return
    end

    vim.notify("Locale set to: " .. choice, vim.log.levels.INFO)
  end)
end

function M.get_key_at_cursor()
  if not state.backend then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1] - 1
  local col = cursor[2]

  local matches = state.backend.find_message_calls(bufnr)
  for _, match in ipairs(matches) do
    if match.line == line_num and col >= match.col_start and col <= match.col_end then
      return match.key
    end
  end
  return nil
end

function M.show_hover()
  local key = M.get_key_at_cursor()
  if not key then
    return false
  end
  if not state.project or not state.project.locales then
    return false
  end

  display.show_hover(key, state.messages, state.project.locales, {
    max_length = M.config.virtual_text.max_length,
  })
  return true
end

function M._trigger_hover()
  M.show_hover()
end

function M._attach_buffer(bufnr)
  if state.attached_buffers[bufnr] then
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return
  end

  if not state.backend then
    local backend, root = backends.detect(filepath)
    if backend and root then
      local project = backend.load_project(root)
      if project then
        state.backend = backend
        state.project_root = root
        state.project = project
        state.messages = project.messages
        state.current_locale = project.base_locale
        M._setup_file_watchers()
      end
    end
  end

  state.attached_buffers[bufnr] = true

  if state.enabled then
    M._update_buffer(bufnr)
  end
end

function M._detach_buffer(bufnr)
  state.attached_buffers[bufnr] = nil
  if state.debounce_timers[bufnr] then
    state.debounce_timers[bufnr]:stop()
    state.debounce_timers[bufnr]:close()
    state.debounce_timers[bufnr] = nil
  end
end

function M._debounced_update(bufnr)
  if state.debounce_timers[bufnr] then
    state.debounce_timers[bufnr]:stop()
  else
    state.debounce_timers[bufnr] = vim.uv.new_timer()
  end

  state.debounce_timers[bufnr]:start(
    M.config.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) and state.enabled then
        M._update_buffer(bufnr)
      end
    end)
  )
end

function M._update_buffer(bufnr)
  if not state.enabled or not state.backend then
    return
  end

  local locale = state.current_locale
  local messages = state.messages[locale] or {}
  local locales = state.project and state.project.locales or {}

  local matches = state.backend.find_message_calls(bufnr)
  display.render(
    bufnr,
    state.namespace,
    matches,
    messages,
    state.messages,
    locales,
    M.config.virtual_text
  )
end

function M._setup_file_watchers()
  for _, watcher in ipairs(state.file_watchers) do
    watcher:stop()
    watcher:close()
  end
  state.file_watchers = {}

  if not state.project or not state.project.watch_paths then
    return
  end

  for _, entry in ipairs(state.project.watch_paths) do
    local locale = entry.locale
    local path = entry.path
    if path and vim.fn.filereadable(path) == 1 then
      local watcher = vim.uv.new_fs_event()
      if watcher then
        watcher:start(
          path,
          {},
          vim.schedule_wrap(function(err, _, _)
            if err or not state.backend or not state.project then
              return
            end
            state.messages[locale] = state.backend.reload_locale(state.project_root, state.project, locale)
            state.project.messages[locale] = state.messages[locale]

            for bufnr, _ in pairs(state.attached_buffers) do
              if vim.api.nvim_buf_is_valid(bufnr) then
                M._update_buffer(bufnr)
              end
            end
          end)
        )
        table.insert(state.file_watchers, watcher)
      end
    end
  end
end

return M
