-- Lazy Watson - Backend dispatcher
-- Picks the appropriate i18n backend for a given file path.

local M = {}

M.backends = {
  require("lazy-watson.backends.paraglide"),
  require("lazy-watson.backends.typesafe_i18n"),
}

--- Detect which backend to use for a given file path
---@param filepath string
---@return table|nil backend
---@return string|nil root
function M.detect(filepath)
  for _, backend in ipairs(M.backends) do
    local root = backend.detect(filepath)
    if root then
      return backend, root
    end
  end
  return nil, nil
end

return M
