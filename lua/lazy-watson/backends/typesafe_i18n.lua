-- Lazy Watson - typesafe-i18n backend
-- Reads translations from TypeScript source files via treesitter.

local M = {
  name = "typesafe-i18n",
}

local CONFIG_FILE = ".typesafe-i18n.json"
local I18N_DIR = "src/i18n"
local DEFAULT_BASE_LOCALE = "en"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function strip_quotes(raw)
  if not raw or #raw < 2 then
    return raw or ""
  end
  local q = raw:sub(1, 1)
  if q == "'" or q == '"' or q == "`" then
    return raw:sub(2, -2)
  end
  return raw
end

local function find_closing_paren(line, start_pos)
  local depth = 1
  local pos = start_pos + 1
  while pos <= #line and depth > 0 do
    local char = line:sub(pos, pos)
    if char == "(" then
      depth = depth + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        return pos
      end
    elseif char == '"' or char == "'" or char == "`" then
      local quote = char
      pos = pos + 1
      while pos <= #line do
        local c = line:sub(pos, pos)
        if c == quote and line:sub(pos - 1, pos - 1) ~= "\\" then
          break
        end
        pos = pos + 1
      end
    end
    pos = pos + 1
  end
  return nil
end

--- Walk an `object` treesitter node, flattening keys into `result`.
local function walk_object(node, source, prefix, result)
  for child in node:iter_children() do
    if child:type() == "pair" then
      local key_node = child:field("key")[1]
      local value_node = child:field("value")[1]
      if key_node and value_node then
        local key_text
        local kt = key_node:type()
        if kt == "property_identifier" then
          key_text = vim.treesitter.get_node_text(key_node, source)
        elseif kt == "string" then
          key_text = strip_quotes(vim.treesitter.get_node_text(key_node, source))
        end

        if key_text then
          local full_key = prefix == "" and key_text or (prefix .. "." .. key_text)
          local vt = value_node:type()
          if vt == "string" or vt == "template_string" then
            result[full_key] = strip_quotes(vim.treesitter.get_node_text(value_node, source))
          elseif vt == "object" then
            walk_object(value_node, source, full_key, result)
          end
          -- arrow_function / call_expression (formatters) are skipped intentionally
        end
      end
    end
  end
end

--- Walk up/down common TS wrappers (`satisfies`, `as`, parentheses) to find
--- the underlying object literal, and also extract the annotated type name.
---@param value_node userdata|nil
---@param type_ann_node userdata|nil
---@param source string
---@return userdata|nil object, string|nil type_name
local function unwrap_value(value_node, type_ann_node, source)
  local type_name
  if type_ann_node then
    for child in type_ann_node:iter_children() do
      if child:type() == "type_identifier" then
        type_name = vim.treesitter.get_node_text(child, source)
        break
      end
    end
  end

  local node = value_node
  while node do
    local t = node:type()
    if t == "object" then
      return node, type_name
    elseif t == "satisfies_expression" or t == "as_expression" or t == "parenthesized_expression" then
      local inner_object
      for child in node:iter_children() do
        local ct = child:type()
        if ct == "type_identifier" and not type_name then
          type_name = vim.treesitter.get_node_text(child, source)
        elseif ct == "object" or ct == "satisfies_expression" or ct == "as_expression" or ct == "parenthesized_expression" then
          inner_object = child
        end
      end
      node = inner_object
    else
      return nil, type_name
    end
  end
  return nil, type_name
end

local function load_messages_from_ts(path)
  local content = read_file(path)
  if not content then
    return {}
  end

  local ok, ts_parser = pcall(vim.treesitter.get_string_parser, content, "typescript")
  if not ok or not ts_parser then
    vim.notify(
      "lazy-watson: typescript treesitter parser unavailable (install via :TSInstall typescript)",
      vim.log.levels.WARN
    )
    return {}
  end

  local trees = ts_parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return {}
  end
  local root = tree:root()

  local query_ok, query = pcall(
    vim.treesitter.query.parse,
    "typescript",
    "(variable_declarator) @decl"
  )
  if not query_ok or not query then
    return {}
  end

  local result = {}
  local fallback_object -- first object literal encountered, used if no typed decl matches

  for _, node in query:iter_captures(root, content, 0, -1) do
    local value = node:field("value")[1]
    local type_ann = node:field("type")[1]
    local obj, type_name = unwrap_value(value, type_ann, content)
    if obj then
      if type_name == "BaseTranslation" or type_name == "Translation" then
        walk_object(obj, content, "", result)
        return result
      end
      if not fallback_object then
        fallback_object = obj
      end
    end
  end

  if fallback_object then
    walk_object(fallback_object, content, "", result)
  end

  return result
end

local function list_locales(root)
  local i18n_path = root .. "/" .. I18N_DIR
  local locales = {}
  local handle = vim.uv.fs_scandir(i18n_path)
  if not handle then
    return locales
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "directory" then
      local index_path = i18n_path .. "/" .. name .. "/index.ts"
      if vim.fn.filereadable(index_path) == 1 then
        table.insert(locales, name)
      end
    end
  end
  table.sort(locales)
  return locales
end

local function read_base_locale(root)
  local content = read_file(root .. "/" .. CONFIG_FILE)
  if not content then
    return nil
  end
  local ok, cfg = pcall(vim.json.decode, content)
  if not ok or type(cfg) ~= "table" then
    return nil
  end
  return cfg.baseLocale
end

local function message_path(root, locale)
  return root .. "/" .. I18N_DIR .. "/" .. locale .. "/index.ts"
end

function M.detect(filepath)
  local path = vim.fn.fnamemodify(filepath, ":p:h")
  while path and path ~= "/" and path ~= "" do
    if vim.fn.filereadable(path .. "/" .. CONFIG_FILE) == 1 then
      return path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then
      break
    end
    path = parent
  end
  return nil
end

function M.load_project(root)
  local locales = list_locales(root)
  if #locales == 0 then
    vim.notify(
      "lazy-watson: no locales found under " .. root .. "/" .. I18N_DIR,
      vim.log.levels.WARN
    )
    return nil
  end

  local base_locale = read_base_locale(root) or DEFAULT_BASE_LOCALE
  local has_base = false
  for _, l in ipairs(locales) do
    if l == base_locale then
      has_base = true
      break
    end
  end
  if not has_base then
    base_locale = locales[1]
  end

  local messages = {}
  local watch_paths = {}
  for _, locale in ipairs(locales) do
    local path = message_path(root, locale)
    messages[locale] = load_messages_from_ts(path)
    table.insert(watch_paths, { locale = locale, path = path })
  end

  return {
    base_locale = base_locale,
    locales = locales,
    messages = messages,
    watch_paths = watch_paths,
    _data = {},
  }
end

function M.reload_locale(root, _project, locale)
  return load_messages_from_ts(message_path(root, locale))
end

--- Find `LL.foo.bar.baz(...)` call sites in a buffer.
function M.find_message_calls(bufnr)
  local matches = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for line_idx, line in ipairs(lines) do
    local line_num = line_idx - 1
    local pos = 1
    while pos <= #line do
      local s = line:find("LL%.", pos)
      if not s then
        break
      end

      local prev = s > 1 and line:sub(s - 1, s - 1) or ""
      local start_pos = s
      -- Allow `$LL.` (Svelte stores) by including the `$` as part of the match start.
      if prev == "$" then
        start_pos = s - 1
        prev = s > 2 and line:sub(s - 2, s - 2) or ""
      end
      -- Reject if preceded by an identifier char or a `.` (e.g. `foo.LL.bar` is a property access, not an LL call).
      local is_boundary = start_pos == 1 or not prev:match("[%w_$.]")

      if is_boundary then
        local cursor = s + 3 -- past "LL."
        local first = line:sub(cursor):match("^([%a_$][%w_$]*)")
        if first then
          local chain = first
          cursor = cursor + #first

          while true do
            local nxt = line:sub(cursor):match("^%.([%a_$][%w_$]*)")
            if not nxt then
              break
            end
            chain = chain .. "." .. nxt
            cursor = cursor + 1 + #nxt
          end

          local paren_ws = line:sub(cursor):match("^(%s*)%(")
          if paren_ws then
            local paren_start = cursor + #paren_ws
            local col_end = find_closing_paren(line, paren_start)
            if col_end then
              table.insert(matches, {
                key = chain,
                line = line_num,
                col_start = start_pos - 1,
                col_end = col_end - 1,
              })
            end
          end
        end
      end

      pos = s + 3
    end
  end

  return matches
end

return M
