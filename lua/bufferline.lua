local lazy = require("bufferline.lazy")
--- @module "bufferline.ui"
local ui = lazy.require("bufferline.ui")
--- @module "bufferline.utils"
local utils = lazy.require("bufferline.utils")
--- @module "bufferline.state"
local state = lazy.require("bufferline.state")
--- @module "bufferline.groups"
local groups = lazy.require("bufferline.groups")
--- @module "bufferline.config"
local config = lazy.require("bufferline.config")
--- @module "bufferline.sorters"
local sorters = lazy.require("bufferline.sorters")
--- @module "bufferline.buffers"
local buffers = lazy.require("bufferline.buffers")
--- @module "bufferline.commands"
local commands = lazy.require("bufferline.commands")
--- @module "bufferline.tabpages"
local tabpages = lazy.require("bufferline.tabpages")
--- @module "bufferline.constants"
local constants = lazy.require("bufferline.constants")
--- @module "bufferline.highlights"
local highlights = lazy.require("bufferline.highlights")

local api = vim.api

local positions_key = constants.positions_key
local BUFFERLINE_GROUP = "BufferlineCmds"

local M = {
  move = commands.move,
  exec = commands.exec,
  go_to = commands.go_to,
  cycle = commands.cycle,
  sort_by = commands.sort_by,
  pick_buffer = commands.pick,
  handle_close = commands.handle_close,
  handle_click = commands.handle_click,
  close_with_pick = commands.close_with_pick,
  close_in_direction = commands.close_in_direction,
  handle_group_click = commands.handle_group_click,
  -- @deprecate
  go_to_buffer = commands.go_to,
  sort_buffers_by = commands.sort_by,
  close_buffer_with_pick = commands.close_with_pick,
}
-----------------------------------------------------------------------------//
-- Helpers
-----------------------------------------------------------------------------//
local function restore_positions()
  local str = vim.g[positions_key]
  if not str then
    return str
  end
  local ids = vim.split(str, ",")
  if ids and #ids > 0 then
    -- these are converted to strings when stored
    -- so have to be converted back before usage
    state.custom_sort = vim.tbl_map(tonumber, ids)
  end
end

---------------------------------------------------------------------------//
-- User commands
---------------------------------------------------------------------------//

---Handle a user "command" which can be a string or a function
---@param command string|function
---@param buf_id string
local function handle_user_command(command, buf_id)
  if not command then
    return
  end
  if type(command) == "function" then
    command(buf_id)
  elseif type(command) == "string" then
    vim.cmd(fmt(command, buf_id))
  end
end

---@param group_id number
function M.handle_group_click(group_id)
  require("bufferline.groups").toggle_hidden(group_id)
  ui.refresh()
end

---@param buf_id number
function M.handle_close_buffer(buf_id)
  local options = require("bufferline.config").get("options")
  local close = options.close_command
  handle_user_command(close, buf_id)
end

---@param id number
function M.handle_win_click(id)
  local win_id = vim.fn.bufwinid(id)
  vim.fn.win_gotoid(win_id)
end

---Handler for each type of mouse click
---@param id number
---@param button string
function M.handle_click(id, button)
  local options = require("bufferline.config").get("options")
  local cmds = {
    r = "right_mouse_command",
    l = "left_mouse_command",
    m = "middle_mouse_command",
  }
  if id then
    handle_user_command(options[cmds[button]], id)
  end
end

---Execute an arbitrary user function on a visible by it's position buffer
---@param index number
---@param func fun(num: number)
function M.buf_exec(index, func)
  local target = state.visible_components[index]
  if target and type(func) == "function" then
    func(target, state.visible_components)
  end
end

-- Prompts user to select a buffer then applies a function to the buffer
---@param func fun(buf_id: number)
local function select_buffer_apply(func)
  state.is_picking = true
  ui.refresh()

  local char = vim.fn.getchar()
  local letter = vim.fn.nr2char(char)
  for _, item in ipairs(state.components) do
    local buf = item:as_buffer()
    if buf and letter == buf.letter then
      func(buf.id)
    end
  end

  state.is_picking = false
  ui.refresh()
end

function M.pick_buffer()
  select_buffer_apply(function(buf_id)
    vim.cmd("buffer " .. buf_id)
  end)
end

function M.close_buffer_with_pick()
  select_buffer_apply(function(buf_id)
    M.handle_close_buffer(buf_id)
  end)
end

--- Open a buffer based on it's visible position in the list
--- unless absolute is specified in which case this will open it based on it place in the full list
--- this is significantly less helpful if you have a lot of buffers open
---@param num number | string
---@param absolute boolean whether or not to use the buffers absolute position or visible positions
function M.go_to_buffer(num, absolute)
  num = type(num) == "string" and tonumber(num) or num
  local list = absolute and state.components or state.visible_components
  local buf = list[num]
  if buf then
    vim.cmd(fmt("buffer %d", buf.id))
  end
end

---@param opts table
---@return number
---@return Buffer
local function get_current_buf_index(opts)
  opts = opts or { include_hidden = false }
  local list = opts.include_hidden and state.__components or state.components
  local current = api.nvim_get_current_buf()
  for index, item in ipairs(list) do
    local buf = item:as_buffer()
    if buf and buf.id == current then
      return index, buf
    end
  end
end

--- @param bufs Buffer[]
--- @return number[]
local function get_buf_ids(bufs)
  return vim.tbl_map(function(buf)
    return buf.id
  end, bufs)
end

--- @param direction number
function M.move(direction)
  local index = get_current_buf_index()
  if not index then
    return utils.echoerr("Unable to find buffer to move, sorry")
  end
  local next_index = index + direction
  if next_index >= 1 and next_index <= #state.components then
    local cur_buf = state.components[index]
    local destination_buf = state.components[next_index]
    state.components[next_index] = cur_buf
    state.components[index] = destination_buf
    state.custom_sort = get_buf_ids(state.components)
    local opts = require("bufferline.config").get("options")
    if opts.persist_buffer_sort then
      commands.save_positions(state.custom_sort)
    end
    ui.refresh()
  end
end

function M.cycle(direction)
  local index = get_current_buf_index()
  if not index then
    return
  end
  local length = #state.components
  local next_index = index + direction

  if next_index <= length and next_index >= 1 then
    next_index = index + direction
  elseif index + direction <= 0 then
    next_index = length
  else
    next_index = 1
  end

  local item = state.components[next_index]
  local next = item:as_buffer()

  if not next then
    return utils.echoerr("This buffer does not exist")
  end

  vim.cmd("buffer " .. next.id)
end

---@alias direction "'left'" | "'right'"
---Close all buffers to the left or right of the current buffer
---@param direction direction
function M.close_in_direction(direction)
  local index = get_current_buf_index()
  if not index then
    return
  end
  local length = #state.components
  if
    not (index == length and direction == "right") and not (index == 1 and direction == "left")
  then
    local start = direction == "left" and 1 or index + 1
    local _end = direction == "left" and index - 1 or length
    ---@type Buffer[]
    local bufs = vim.list_slice(state.components, start, _end)
    for _, buf in ipairs(bufs) do
      api.nvim_buf_delete(buf.id, { force = true })
    end
  end
end

--- sorts all buffers
--- @param sort_by string|function
function M.sort_buffers_by(sort_by)
  if next(state.components) == nil then
    return utils.echoerr("Unable to find buffers to sort, sorry")
  end

  require("bufferline.sorters").sort_buffers(sort_by, state.components)
  state.custom_sort = get_buf_ids(state.components)
  local opts = require("bufferline.config").get("options")
  if opts.persist_buffer_sort then
    commands.save_positions(state.custom_sort)
  end
  ui.refresh()
end

-----------------------------------------------------------------------------//
-- UI
-----------------------------------------------------------------------------//

local function get_marker_size(count, element_size)
  return count > 0 and ui.strwidth(count) + element_size or 0
end


--- PREREQUISITE: active buffer always remains in view
--- 1. Find amount of available space in the window
--- 2. Find the amount of space the bufferline will take up
--- 3. If the bufferline will be too long remove one tab from the before or after
--- section
--- 4. Re-check the size, if still too long truncate recursively till it fits
--- 5. Add the number of truncated buffers as an indicator
---@param before Section
---@param current Section
---@param after Section
---@param available_width number
---@param marker table
---@return string
---@return table
---@return Buffer[]
local function truncate(before, current, after, available_width, marker, visible)
  visible = visible or {}
  local line = ""

  local left_trunc_marker = get_marker_size(marker.left_count, marker.left_element_size)
  local right_trunc_marker = get_marker_size(marker.right_count, marker.right_element_size)

  local markers_length = left_trunc_marker + right_trunc_marker

  local total_length = before.length + current.length + after.length + markers_length

  if available_width >= total_length then
    visible = utils.array_concat(before.items, current.items, after.items)
    for index, item in ipairs(visible) do
      line = line .. item.component(index, visible[index + 1])
    end
    return line, marker, visible
    -- if we aren't even able to fit the current buffer into the
    -- available space that means the window is really narrow
    -- so don't show anything
  elseif available_width < current.length then
    return "", marker, visible
  else
    if before.length >= after.length then
      before:drop(1)
      marker.left_count = marker.left_count + 1
    else
      after:drop(#after.items)
      marker.right_count = marker.right_count + 1
    end
    -- drop the markers if the window is too narrow
    -- this assumes we have dropped both before and after
    -- sections since if the space available is this small
    -- we have likely removed these
    if (current.length + markers_length) > available_width then
      marker.left_count = 0
      marker.right_count = 0
    end
    return truncate(before, current, after, available_width, marker, visible)
  end
end

---@param list Component[]
---@return Component[]
local function filter_invisible(list)
  return utils.fold({}, function(accum, item)
    if item.focusable ~= false and not item.hidden then
      table.insert(accum, item)
    end
    return accum
  end, list)
end

---sort a list of components using a sort function
---@param list Component[]
---@return Component[]
local function sorter(list)
  -- if the user has reshuffled the buffers manually don't try and sort them
  if state.custom_sort then
    return list
  end
  return sorters.sort(list, nil, state)
end

---Get the index of the current element
---@param current_state BufferlineState
---@return number
local function get_current_index(current_state)
  for index, component in ipairs(current_state.components) do
    if component:current() then
      return index
    end
  end
end

--- @return string
local function bufferline()
  local conf = config.get()
  local tabs = tabpages.get()
  local is_tabline = conf:is_tabline()
  local components = is_tabline and tabpages.get_components(state) or buffers.get_components(state)

  --- NOTE: this cannot be added to state as a metamethod since
  --- state is not actually set till after sorting and component creation is done
  state.set({ current_element_index = get_current_index(state) })
  components = not is_tabline and groups.render(components, sorter) or sorter(components)
  local tabline, visible_components = ui.render(components, tabs)

  state.set({
    --- store the full unfiltered lists
    __components = components,
    --- Store copies without focusable/hidden elements
    components = filter_invisible(components),
    visible_components = filter_invisible(visible_components),
  })
  return tabline
end

--- If the item count has changed and the next tabline status is different then update it
local function toggle_bufferline()
  local item_count = config:is_tabline() and utils.get_tab_count() or utils.get_buf_count()
  local status = (config.options.always_show_bufferline or item_count > 1) and 2 or 0
  if vim.o.showtabline ~= status then
    vim.o.showtabline = status
  end
end

local function apply_colors()
  local current_prefs = config.update_highlights()
  highlights.set_all(current_prefs)
end

---@alias group_actions '"close"' | '"toggle"'
---Execute an action on a group of buffers
---@param name string
---@param action group_actions | fun(b: Buffer)
function M.group_action(name, action)
  assert(name, "A name must be passed to execute a group action")
  if action == "close" then
    groups.command(name, function(b)
      api.nvim_buf_delete(b.id, { force = true })
    end)
  elseif action == "toggle" then
    groups.toggle_hidden(nil, name)
    ui.refresh()
  elseif type(action) == "function" then
    groups.command(name, action)
  end
end

function M.toggle_pin()
  local _, buffer = commands.get_current_element_index(state)
  if groups.is_pinned(buffer) then
    groups.remove_from_group("pinned", buffer)
  else
    groups.add_to_group("pinned", buffer)
  end
  ui.refresh()
end

local function handle_group_enter()
  local options = config.options
  local _, element = commands.get_current_element_index(state, { include_hidden = true })
  if not element or not element.group then
    return
  end
  local current_group = groups.get_by_id(element.group)
  if options.groups.options.toggle_hidden_on_enter then
    if current_group.hidden then
      groups.set_hidden(current_group.id, false)
    end
  end
  utils.for_each(state.components, function(tab)
    local group = groups.get_by_id(tab.group)
    if group and group.auto_close and group.id ~= current_group.id then
      groups.set_hidden(group.id, true)
    end
  end)
end

---@param conf BufferlineConfig
local function setup_autocommands(conf)
  local options = conf.options
  api.nvim_create_augroup(BUFFERLINE_GROUP, { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    group = BUFFERLINE_GROUP,
    callback = function()
      apply_colors()
    end,
  })
  if not options or vim.tbl_isempty(options) then
    return
  end
  if options.persist_buffer_sort then
    api.nvim_create_autocmd("SessionLoadPost", {
      pattern = "*",
      group = BUFFERLINE_GROUP,
      callback = function()
        restore_positions()
      end,
    })
  end
  if not options.always_show_bufferline then
    -- toggle tabline
    api.nvim_create_autocmd({ "BufAdd", "TabEnter" }, {
      pattern = "*",
      group = BUFFERLINE_GROUP,
      callback = function()
        toggle_bufferline()
      end,
    })
  end

  api.nvim_create_autocmd("BufRead", {
    pattern = "*",
    once = true,
    callback = function()
      vim.schedule(handle_group_enter)
    end,
  })

  api.nvim_create_autocmd("BufEnter", {
    pattern = "*",
    callback = function()
      handle_group_enter()
    end,
  })
end

---@param arg_lead string
---@param cmd_line string
---@param cursor_pos number
---@return string[]
---@diagnostic disable-next-line: unused-local
local function complete_groups(arg_lead, cmd_line, cursor_pos)
  return groups.names()
end

local function setup_commands()
  local cmd = api.nvim_create_user_command

  cmd("BufferLinePick", function()
    M.pick_buffer()
  end, {})

  cmd("BufferLinePickClose", function()
    M.close_buffer_with_pick()
  end, {})

  cmd("BufferLineCycleNext", function()
    M.cycle(1)
  end, {})

  cmd("BufferLineCyclePrev", function()
    M.cycle(-1)
  end, {})

  cmd("BufferLineCloseRight", function()
    M.close_in_direction("right")
  end, {})

  cmd("BufferLineCloseLeft", function()
    M.close_in_direction("left")
  end, {})

  cmd("BufferLineMoveNext", function()
    M.move(1)
  end, {})

  cmd("BufferLineMovePrev", function()
    M.move(-1)
  end, {})

  cmd("BufferLineSortByExtension", function()
    M.sort_buffers_by("extension")
  end, {})

  cmd("BufferLineSortByDirectory", function()
    M.sort_buffers_by("directory")
  end, {})

  cmd("BufferLineSortByRelativeDirectory", function()
    M.sort_buffers_by("relative_directory")
  end, {})

  cmd("BufferLineSortByTabs", function()
    M.sort_buffers_by("tabs")
  end, {})

  cmd("BufferLineGoToBuffer", function(opts)
    M.go_to_buffer(opts.args)
  end, { nargs = 1 })

  cmd("BufferLineGroupClose", function(opts)
    M.group_action(opts.args, "close")
  end, { nargs = 1, complete = complete_groups })

  cmd("BufferLineGroupToggle", function(opts)
    M.group_action(opts.args, "toggle")
  end, { nargs = 1, complete = complete_groups })

  cmd("BufferLineTogglePin", function()
    M.toggle_pin()
  end, { nargs = 0 })
end

---@private
function _G.nvim_bufferline()
  -- Always populate state regardless of if tabline status is less than 2 #352
  toggle_bufferline()
  return bufferline()
end

---@param conf BufferlineConfig
function M.setup(conf)
  if not utils.is_current_stable_release() then
    utils.notify(
      "bufferline.nvim requires Neovim 0.7 or higher, please use tag 1.* or update your neovim",
      utils.E,
      { once = true }
    )
    return
  end
  config.set(conf or {})
  local preferences = config.apply()
  -- on loading (and reloading) the plugin's config reset all the highlights
  highlights.set_all(preferences)
  setup_commands()
  setup_autocommands(preferences)
  vim.o.tabline = "%!v:lua.nvim_bufferline()"
  toggle_bufferline()
end

return M
