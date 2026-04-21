-- Lazy Watson - Paraglide / inlang backend

local loader = require("lazy-watson.loader")
local parser = require("lazy-watson.parser")

local M = {
  name = "paraglide",
}

local PROJECT_PATTERN = "project.inlang/settings.json"

function M.detect(filepath)
  return loader.find_project_root(filepath, PROJECT_PATTERN)
end

function M.load_project(root)
  local settings = loader.load_settings(root, PROJECT_PATTERN)
  if not settings then
    return nil
  end

  local messages = {}
  local watch_paths = {}
  for _, locale in ipairs(settings.locales) do
    messages[locale] = loader.load_messages(root, settings.pathPattern, locale)
    local path = loader.get_message_path(root, settings.pathPattern, locale)
    if vim.fn.filereadable(path) == 1 then
      table.insert(watch_paths, { locale = locale, path = path })
    end
  end

  return {
    base_locale = settings.baseLocale,
    locales = settings.locales,
    messages = messages,
    watch_paths = watch_paths,
    _data = { pathPattern = settings.pathPattern },
  }
end

function M.reload_locale(root, project, locale)
  return loader.load_messages(root, project._data.pathPattern, locale)
end

M.find_message_calls = parser.find_message_calls

return M
