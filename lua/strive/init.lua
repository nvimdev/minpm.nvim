-- Strive: Minimalist Plugin Manager for Neovim
-- A lightweight, feature-rich plugin manager with support for lazy loading,
-- dependencies, and asynchronous operations.

local api, uv, fs, joinpath = vim.api, vim.uv, vim.fs, vim.fs.joinpath

-- =====================================================================
-- 1. Configuration and Constants
-- =====================================================================
local M = {}
local plugins = {}
local plugin_map = {}

-- Data paths
local data_dir = vim.fn.stdpath('data')
local START_DIR = joinpath(data_dir, 'site', 'pack', 'strive', 'start')
local OPT_DIR = joinpath(data_dir, 'site', 'pack', 'strive', 'opt')

-- Add to packpath
vim.opt.packpath:prepend(joinpath(data_dir, 'site'))
vim.g.strive_loaded = 0
vim.g.strive_count = 0

local DEFAULT_SETTINGS = {
  max_concurrent_tasks = vim.g.strive_max_concurrent_tasks or 10,
  auto_install = vim.g.strive_auto_install or true,
  log_level = vim.g.strive_log_level or 'warn',
  git_timeout = vim.g.strive_git_timeout or 60000,
  git_depth = vim.g.strive_git_depth or 1,
  install_retry = vim.g.strive_install_with_retry or false,
}

-- Plugin status constants
local STATUS = {
  PENDING = 'pending',
  LOADING = 'loading',
  LOADED = 'loaded',
  INSTALLING = 'installing',
  INSTALLED = 'installed',
  UPDATING = 'updating',
  UPDATED = 'updated',
  ERROR = 'error',
}

local function isdir(dir)
  return (uv.fs_stat(dir) or {}).type == 'directory'
end

-- =====================================================================
-- 2. Async Utilities
-- =====================================================================
local Async = {}

-- Result type to handle errors properly
local Result = {}

local success_meta = { success = true, error = nil }
local failure_meta = { success = false, value = nil }

success_meta.__index = success_meta
failure_meta.__index = failure_meta

function Result.success(value)
  return setmetatable({ value = value }, success_meta)
end

function Result.failure(err)
  return setmetatable({ error = err }, failure_meta)
end

-- Wrap a function to return a promise
function Async.wrap(func)
  return function(...)
    local args = { ... }
    return function(callback)
      local function handle_result(...)
        local results = { ... }
        if #results == 0 then
          -- No results
          callback(Result.success(nil))
        elseif #results == 1 then
          -- Single result
          callback(Result.success(results[1]))
        else
          -- Multiple results
          callback(Result.success(results))
        end
      end

      -- Handle any errors in the wrapped function
      local status, err = pcall(function()
        table.insert(args, handle_result)
        func(unpack(args))
      end)

      if not status then
        callback(Result.failure(err))
      end
    end
  end
end

-- Wrap vim.system to provide better error handling and cleaner usage
function Async.system(cmd, opts)
  opts = opts or {}
  return function(callback)
    local progress_data = {}
    local error_data = {}
    local stderr_callback = opts.stderr

    -- Setup options
    local system_opts = vim.deepcopy(opts)

    -- Capture stderr for progress if requested
    if stderr_callback then
      system_opts.stderr = function(_, data)
        if data then
          table.insert(error_data, data)
          stderr_callback(_, data)
        end
      end
    end

    -- Call vim.system with proper error handling
    vim.system(cmd, system_opts, function(obj)
      -- Success is 0 exit code
      local success = obj.code == 0

      if success then
        callback(Result.success({
          stdout = obj.stdout,
          stderr = obj.stderr,
          code = obj.code,
          signal = obj.signal,
          progress = progress_data,
        }))
      else
        callback(Result.failure({
          message = 'Command failed with exit code: ' .. obj.code,
          stdout = obj.stdout,
          stderr = obj.stderr,
          code = obj.code,
          signal = obj.signal,
          progress = progress_data,
        }))
      end
    end)
  end
end

-- Await a promise - execution is paused until promise resolves
function Async.await(promise)
  local co = coroutine.running()
  if not co then
    error('Cannot await outside of an async function')
  end

  promise(function(result)
    vim.schedule(function()
      local ok = coroutine.resume(co, result)
      if not ok then
        vim.notify(debug.traceback(co), vim.log.levels.ERROR)
      end
    end)
  end)

  local result = coroutine.yield()

  -- Propagate errors by throwing them
  if not result.success then
    error(result.error)
  end

  return result.value
end

-- Safely await a promise, returning a result instead of throwing
function Async.try_await(promise)
  local co = coroutine.running()
  if not co then
    error('Cannot await outside of an async function')
  end

  promise(function(result)
    vim.schedule(function()
      local ok = coroutine.resume(co, result)
      if not ok then
        vim.notify(debug.traceback(co), vim.log.levels.ERROR)
      end
    end)
  end)

  return coroutine.yield()
end

-- Create an async function that can use await
function Async.async(func)
  return function(...)
    local args = { ... }
    local co = coroutine.create(function()
      local status, result = pcall(function()
        return func(unpack(args))
      end)

      if not status then
        vim.schedule(function()
          vim.notify('Async error: ' .. tostring(result), vim.log.levels.ERROR)
        end)
      end

      return status and result or nil
    end)

    local function step(...)
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        vim.schedule(function()
          vim.notify('Coroutine error: ' .. debug.traceback(co, err), vim.log.levels.ERROR)
        end)
      end
    end

    step()
  end
end

-- Run multiple promises concurrently and wait for all to complete
function Async.all(promises)
  return function(callback)
    if #promises == 0 then
      callback(Result.success({}))
      return
    end

    local results = {}
    local completed = 0
    local had_errors = false
    local first_error = nil

    for i, promise in ipairs(promises) do
      promise(function(result)
        results[i] = result
        completed = completed + 1

        -- Keep track of first error
        if not result.success and not had_errors then
          had_errors = true
          first_error = result.error
        end

        if completed == #promises then
          if had_errors then
            callback(Result.failure(first_error))
          else
            -- Extract values from results
            local values = {}
            for j, res in ipairs(results) do
              values[j] = res.value
            end
            callback(Result.success(values))
          end
        end
      end)
    end
  end
end

-- Simple delay function (sleep)
function Async.delay(ms)
  return function(callback)
    vim.defer_fn(function()
      callback(Result.success(nil))
    end, ms)
  end
end

-- Retry a promise with exponential backoff
function Async.retry(promise_fn, max_retries, initial_delay)
  max_retries = max_retries or 3
  initial_delay = initial_delay or 100

  return function(callback)
    local attempt = 0

    local function try()
      attempt = attempt + 1
      promise_fn()(function(result)
        if result.success or attempt >= max_retries then
          callback(result)
        else
          -- Exponential backoff
          local delay = initial_delay * (2 ^ (attempt - 1))
          vim.defer_fn(try, delay)
        end
      end)
    end

    try()
  end
end

function Async.scandir(dir)
  return function(callback)
    uv.fs_scandir(dir, function(err, handle)
      callback(err and Result.failure(err) or Result.success(handle))
    end)
  end
end

function Async.safe_schedule(callback)
  if vim.in_fast_event() then
    vim.schedule(function()
      callback()
    end)
  else
    callback()
  end
end

-- =====================================================================
-- 3. Task Queue
-- =====================================================================
local TaskQueue = {}
TaskQueue.__index = TaskQueue

-- Create a new task queue with a maximum number of concurrent tasks
function TaskQueue.new(max_concurrent)
  local self = setmetatable({
    active_tasks = 0,
    max_concurrent = max_concurrent,
    queue = {},
    on_empty = nil,
  }, TaskQueue)

  return self
end

-- Process the queue, starting as many tasks as allowed
function TaskQueue:process()
  M.log(
    'debug',
    string.format('TaskQueue status: %d queued, %d active', #self.queue, self.active_tasks)
  )

  if #self.queue == 0 and self.active_tasks == 0 and self.on_empty then
    M.log('debug', 'All tasks completed, calling on_empty callback')
    self.on_empty()
    return
  end
  M.log(
    'debug',
    string.format('Starting new task, active: %d, queued: %d', self.active_tasks, #self.queue)
  )
  while self.active_tasks < self.max_concurrent and #self.queue > 0 do
    local task = table.remove(self.queue, 1)
    self.active_tasks = self.active_tasks + 1

    task(function()
      self.active_tasks = self.active_tasks - 1
      self:process()
    end)
  end
end

-- Add a task to the queue and start processing
function TaskQueue:enqueue(task)
  table.insert(self.queue, task)
  self:process()
  return self
end

-- Set a callback for when the queue becomes empty
function TaskQueue:on_complete(callback)
  self.on_empty = callback
  -- Check immediately in case the queue is already empty
  if #self.queue == 0 and self.active_tasks == 0 and self.on_empty then
    self.on_empty()
  end
  return self
end

-- Get the current queue status
function TaskQueue:status()
  return {
    queued = #self.queue,
    active = self.active_tasks,
    total = #self.queue + self.active_tasks,
  }
end

-- =====================================================================
-- 4. UI Window
-- =====================================================================
local ProgressWindow = {}
ProgressWindow.__index = ProgressWindow

function ProgressWindow.new()
  local self = setmetatable({
    bufnr = nil,
    winid = nil,
    entries = {},
    visible = false,
    title = 'Strive Plugin Manager',
  }, ProgressWindow)

  return self
end

-- Create the buffer for the window
function ProgressWindow:create_buffer()
  self.bufnr = api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.bo[self.bufnr].buftype = 'nofile'
  vim.bo[self.bufnr].bufhidden = 'wipe'
  vim.bo[self.bufnr].swapfile = false
  vim.bo[self.bufnr].modifiable = false

  -- Set buffer name
  api.nvim_buf_set_name(self.bufnr, 'strive-Progress')

  -- Set key mappings for the buffer
  self:set_keymaps()

  return self
end

-- Set key mappings for the window
function ProgressWindow:set_keymaps()
  local opts = { buffer = self.bufnr }
  local mapset = vim.keymap.set
  for _, key in ipairs({ 'q', '<ESC>' }) do
    mapset('n', key, function()
      self:close()
    end, opts)
  end

  -- Add other useful keymaps
  mapset('n', 'r', function()
    self:refresh()
  end, vim.tbl_extend('force', opts, { desc = 'Refresh display' }))
end

-- Create and open the window
function ProgressWindow:open()
  if self.visible and api.nvim_win_is_valid(self.winid) then
    api.nvim_set_current_win(self.winid)
    return self
  end

  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
    self:create_buffer()
  end

  -- Calculate window dimensions (50% of screen)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.5)

  -- Create the window
  self.winid = api.nvim_open_win(self.bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = self.title,
    title_pos = 'center',
  })
  self.ns = api.nvim_create_namespace('Strive')

  -- Set window options
  vim.wo[self.winid].wrap = false
  vim.wo[self.winid].foldenable = false
  vim.wo[self.winid].cursorline = true

  self.visible = true
  self:refresh()

  return self
end

-- Close the window
function ProgressWindow:close()
  if self.visible and self.winid and api.nvim_win_is_valid(self.winid) then
    api.nvim_win_close(self.winid, true)
    self.visible = false
  end
  return self
end

-- Update entry for a plugin
function ProgressWindow:update_entry(plugin_name, status, message)
  self.entries[plugin_name] = {
    status = status,
    message = message,
    time = os.time(),
  }

  if self.visible then
    Async.safe_schedule(function()
      self:refresh()
    end)
  end

  return self
end

-- Refresh the window content
function ProgressWindow:refresh()
  -- Ensure we're not in a fast event context
  if not self.visible then
    return self
  end

  -- Check buffer validity safely
  local buf_valid = false
  if self.bufnr then
    -- This could throw in a fast event context, so we need to handle it safely
    local ok, result = pcall(api.nvim_buf_is_valid, self.bufnr)
    buf_valid = ok and result
  end

  if not buf_valid then
    return self
  end

  -- Convert entries to sorted list
  local lines = {}
  local sorted_plugins = {}

  for name, _ in pairs(self.entries) do
    table.insert(sorted_plugins, name)
  end
  table.sort(sorted_plugins)

  local width = api.nvim_win_get_width(self.winid)
  -- Header
  table.insert(lines, string.rep('=', width))
  table.insert(lines, string.format('%-40s %-10s %s', 'Plugin', 'Status', 'Message'))
  table.insert(lines, string.rep('=', width))
  -- Plugin entries
  for _, name in ipairs(sorted_plugins) do
    local entry = self.entries[name]
    table.insert(
      lines,
      string.format('%-40s %-10s %s', name:sub(1, 40), entry.status, entry.message or '')
    )
  end

  -- Update buffer content
  vim.bo[self.bufnr].modifiable = true
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.bo[self.bufnr].modifiable = false

  vim.hl.range(self.bufnr, self.ns, 'Comment', { 0, 0 }, { 2, -1 })
  return self
end

-- Clear all entries
function ProgressWindow:clear()
  self.entries = {}

  if self.visible then
    self:refresh()
  end

  return self
end

-- Create a singleton UI window
local ui = ProgressWindow.new()

-- =====================================================================
-- 5. Plugin Class
-- =====================================================================
local Plugin = {}
Plugin.__index = Plugin

-- Create a new plugin instance
function Plugin.new(spec)
  spec = type(spec) == 'string' and { name = spec } or spec

  -- Extract plugin name from repo
  local name = fs.normalize(spec.name)
  if vim.startswith(name, vim.env.HOME) then
    spec.is_local = true
  end
  local parts = vim.split(name, '/', { trimempty = true })
  local plugin_name = parts[#parts]:gsub('%.git$', '')

  local self = setmetatable({
    id = 0,
    -- Basic properties
    name = name, -- Full repo name (user/repo)
    plugin_name = plugin_name, -- Just the repo part (for loading)
    is_remote = not name:find(vim.env.HOME), -- Is it a remote or local plugin
    is_local = spec.is_local or false, -- Development mode flag
    is_lazy = spec.is_lazy or false, -- Whether to lazy load
    local_path = nil, -- Local path to load
    remote_branch = spec._branch, -- Git branch to use

    -- States
    status = STATUS.PENDING, -- Current plugin status
    loaded = false, -- Is the plugin loaded

    -- Loading options
    events = {}, -- Events to trigger loading
    filetypes = {}, -- Filetypes to trigger loading
    commands = {}, -- Commands to trigger loading
    mappings = {}, -- Keys to trigger loading

    -- Configuration
    setup_opts = spec.setup or {}, -- Options for plugin setup()
    init_opts = spec.init, -- Options for before load plugin
    config_opts = spec.config, -- Config function to run after loading
    after_fn = spec.after, -- Function to run after dependencies load
    colorscheme = spec.theme, -- Theme to apply if this is a colorscheme

    -- Dependencies
    dependencies = spec.depends or {}, -- Dependencies

    user_commands = {}, -- Created user commands
    run_action = spec.build or nil,
    need_build = false,
  }, Plugin)

  return self
end

-- Get the plugin installation path
function Plugin:get_path()
  return (not self.is_local and not self.local_path)
      and joinpath(self.is_lazy and OPT_DIR or START_DIR, self.plugin_name)
    or (joinpath(self.local_path, self.plugin_name) or self.name)
end

-- Check if plugin is installed (async version)
function Plugin:is_installed()
  return Async.wrap(function(callback)
    uv.fs_stat(self:get_path(), function(err, stat)
      callback(not err and stat and stat.type == 'directory')
    end)
  end)()
end

-- Only string or function can be used for init and config opt
local function load_opts(opt)
  return type(opt) == 'string' and vim.cmd(opt) or opt()
end

-- return a Promise
function Plugin:load_scripts()
  return function(callback)
    local plugin_path = self:get_path()
    local plugin_dir = joinpath(plugin_path, 'plugin')

    if not isdir(plugin_dir) then
      callback(Result.success(false))
      return
    end

    Async.scandir(plugin_dir)(function(result)
      if not result.success or not result.value then
        M.log('debug', string.format('Plugin directory not found: %s', plugin_dir))
        callback(Result.success(false))
        return
      end

      local scripts = {}
      while true do
        local name, type = uv.fs_scandir_next(result.value)
        if not name then
          break
        end
        if type == 'file' and (name:match('%.lua$') or name:match('%.vim$')) then
          scripts[#scripts + 1] = joinpath(plugin_dir, name)
        end
      end

      if #scripts > 0 then
        Async.safe_schedule(function()
          for _, file_path in ipairs(scripts) do
            vim.cmd.source(vim.fn.fnameescape(file_path))
          end
          callback(Result.success(true))
        end)
      else
        callback(Result.success(false))
      end
    end)
  end
end

-- Load a plugin and its dependencies
function Plugin:load(do_action, callback)
  if self.loaded then
    return true
  end

  Async.async(function()
    local plugin_path = self:get_path()
    local stat = uv.fs_stat(plugin_path)
    if not stat or stat.type ~= 'directory' then
      self.status = STATUS.ERROR
      return false
    end

    if self.init_opts then
      load_opts(self.init_opts)
    end

    if self.is_local then
      vim.opt.rtp:append(plugin_path)

      local after_path = joinpath(plugin_path, 'after')
      if isdir(after_path) then
        vim.opt.rtp:append(after_path)
      end

      local result = Async.try_await(self:load_scripts())
      if result.error then
        M.log(
          'error',
          string.format('Failed to load scripts for %s: %s', self.name, tostring(result.error))
        )
        return
      end
    elseif self.is_lazy then
      vim.cmd.packadd(self.plugin_name)
    end

    self.loaded = true
    vim.g.strive_loaded = vim.g.strive_loaded + 1

    self:call_setup()

    self.status = STATUS.LOADED
    if self.group_ids and #self.group_ids > 0 then
      for _, id in ipairs(self.group_ids) do
        api.nvim_del_augroup_by_id(id)
      end
      self.group_ids = {}
    end

    local deps_to_load = {}
    for _, dep in ipairs(self.dependencies) do
      if not dep.loaded then
        table.insert(deps_to_load, dep)
      end
    end

    if #deps_to_load > 0 then
      local promises = {}
      for _, dep in ipairs(deps_to_load) do
        table.insert(promises, function(cb)
          Async.async(function()
            dep:load()
            cb(Result.success(true))
          end)()
        end)
      end

      Async.await(Async.all(promises))
    end

    if self.config_opts then
      load_opts(self.config_opts)
    end

    if do_action and self.run_action and self.loaded then
      if type(self.run_action) == 'string' then
        vim.cmd(self.run_action)
      else
        self.run_action()
      end
    end

    if callback then
      callback()
    end

    return true
  end)()

  return true
end

-- Set up lazy loading on specific events
function Plugin:on(events)
  self.is_lazy = true
  self.events = type(events) ~= 'table' and { events } or events
  self.group_ids = self.group_id or {}
  local id = api.nvim_create_augroup('strive_' .. self.plugin_name, { clear = true })
  table.insert(self.group_ids, id)

  -- Create autocmds for each event within this group
  for _, event in ipairs(self.events) do
    event = event == 'StriveDone' and 'User StriveDone' or event
    local pattern
    if event:find('%s') then
      local t = vim.split(event, '%s')
      event, pattern = t[1], t[2]
    end

    api.nvim_create_autocmd(event, {
      group = id,
      pattern = pattern,
      once = true,
      callback = function()
        if not self.loaded then
          self:load()
        end
      end,
    })
  end

  return self
end

local function _split(s, sep)
  local t = {}
  for c in vim.gsplit(s, sep, { trimempty = true }) do
    if #c > 0 then
      table.insert(t, c)
    end
  end
  return t
end

-- Set up lazy loading for specific filetypes
function Plugin:ft(filetypes)
  self.is_lazy = true
  self.filetypes = type(filetypes) ~= 'table' and { filetypes } or filetypes
  self.group_ids = self.group_ids or {}
  local id = api.nvim_create_augroup('strive_' .. self.plugin_name, { clear = true })
  self.group_ids[#self.group_ids + 1] = id
  api.nvim_create_autocmd('FileType', {
    group = id,
    pattern = self.filetypes,
    once = true,
    callback = function(args)
      if not self.loaded then
        return self:load(false, function()
          local res = api.nvim_exec2('autocmd FileType', { output = true })
          if not res.output then
            return
          end
          res = { unpack(vim.split(res.output, '\n'), 1) }
          local group_start = nil
          for i, item in ipairs(res) do
            if item:find('FileType$') then
              group_start = i
            end
            if item:find(self.plugin_name, 1, true) then
              local data = _split(item, '%s')
              local g = res[group_start]:match('^(.-)%s+FileType$')
              if g and (data[1] == '*' or data[1] == vim.bo[args.buf].filetype) then
                api.nvim_exec_autocmds('FileType', {
                  group = g,
                  modeline = false,
                  buffer = args.buf,
                  data = args.data,
                })
                break
              end
            end
          end
        end)
      end
    end,
  })

  return self
end

-- Set up lazy loading for specific commands
function Plugin:cmd(commands)
  self.is_lazy = true
  self.commands = type(commands) == 'table' and commands or { commands }

  -- Helper to execute a given command string
  local function execute(name, bang, args)
    if vim.fn.exists(':' .. name) ~= 2 then
      return
    end
    local cmd_str = name .. (bang and '!' or '') .. (args or '')
    ---@diagnostic disable-next-line: param-type-mismatch
    local ok, err = pcall(vim.cmd, cmd_str)
    if not ok then
      vim.notify(string.format('execute %s wrong: %s', name, err), vim.log.levels.ERROR)
    end
  end

  for _, name in ipairs(self.commands) do
    api.nvim_create_user_command(name, function(opts)
      -- Remove this command to avoid recursion
      pcall(api.nvim_del_user_command, name)
      local args = opts.args ~= '' and (' ' .. opts.args) or ''
      local bang = opts.bang

      Async.async(function()
        self:load()
        if self.is_local then
          Async.await(Async.delay(5))
        end
        Async.safe_schedule(function()
          execute(name, bang, args)
        end)
      end)()
    end, {
      nargs = '*',
      bang = true,
      complete = function(_, cmd_line)
        if not self.loaded then
          self:load()
        end
        local ok, result = pcall(vim.fn.getcompletion, cmd_line, 'cmdline')
        return ok and result or {}
      end,
    })

    table.insert(self.user_commands, name)
  end

  return self
end

function Plugin:cond(condition)
  self.is_lazy = true
  if
    (type(condition) == 'string' and api.nvim_eval(condition))
    or (type(condition) == 'function' and condition())
  then
    self:load(true)
  end
  return self
end

-- Set up lazy loading for specific keymaps
function Plugin:keys(mappings)
  self.is_lazy = true
  self.mappings = type(mappings) ~= 'table' and { mappings } or mappings

  for _, mapping in ipairs(self.mappings) do
    local mode, lhs, rhs, opts

    if type(mapping) == 'table' then
      mode = mapping[1] or 'n'
      lhs = mapping[2]
      rhs = mapping[3]
      opts = mapping[4] or {}
    else
      mode, lhs = 'n', mapping
      opts = {}
    end

    -- Create a keymap that loads the plugin first
    vim.keymap.set(mode, lhs, function()
      if type(rhs) == 'function' then
        self:load(nil, rhs)
      elseif type(rhs) == 'string' then
        self:load(nil, function()
          vim.cmd(rhs)
        end)
      elseif type(rhs) == 'nil' then
        -- If rhs not specified, it should be defined in plugin config
        -- In this case, we need to pass a callback
        self:load(nil, function()
          vim.schedule(function()
            vim.fn.feedkeys(lhs)
          end)
        end)
      end
    end, opts)
  end

  return self
end

-- Mark plugin as a development plugin
function Plugin:load_path(path)
  path = path or vim.g.strive_dev_path
  self.is_local = true
  self.local_path = fs.normalize(path)
  self.is_remote = false
  return self
end

-- Set plugin configuration options
function Plugin:setup(opts)
  self.setup_opts = opts
  return self
end

function Plugin:init(opts)
  self.init_opts = opts
  return self
end

-- Set a function to run after plugin loads
function Plugin:config(opts)
  self.config_opts = opts
  return self
end

-- Set a function to run after dependencies load
function Plugin:after(fn)
  assert(type(fn) == 'function', 'After must be a function')
  self.after_fn = fn
  return self
end

function Plugin:branch(branch_name)
  assert(
    type(branch_name) == 'string' and branch_name ~= '',
    'Branch name must be a non-empty string'
  )
  self._branch = branch_name
  return self
end

-- Set plugin as a theme
function Plugin:theme(name)
  self.colorscheme = name or self.plugin_name

  -- If already installed, apply the theme
  Async.async(function()
    local installed = Async.await(self:is_installed())
    if installed then
      vim.schedule(function()
        vim.opt.rtp:append(joinpath(START_DIR, self.plugin_name))
        vim.cmd.colorscheme(self.colorscheme)
      end)
    end
  end)()

  return self
end

function Plugin:call_setup()
  local module_name = self.plugin_name:gsub('%.nvim$', ''):gsub('-nvim$', ''):gsub('^nvim%-', '')
  for _, mod in ipairs({ module_name, self.plugin_name }) do
    -- Try to load the module
    local ok, module = pcall(require, mod)
    if ok and type(module) == 'table' then
      local setup = rawget(module, 'setup')
      if setup and type(setup) == 'function' then
        setup(self.setup_opts)
        break
      end
    end
  end
end

function Plugin:run(action)
  assert(type(action) == 'string' or type(action) == 'function')
  self.run_action = action
  return self
end

-- Add dependency to a plugin
function Plugin:depends(deps)
  deps = type(deps) == 'string' and { deps } or deps
  -- Extend the current dependencies
  for _, dep in ipairs(deps) do
    if not plugins[dep] then
      local d = M.use(dep)
      d.is_lazy = true
      table.insert(self.dependencies, d)
    end
  end
  return self
end

-- Install the plugin
function Plugin:install()
  if self.is_local or not self.is_remote then
    return Async.wrap(function(cb)
      cb(true)
    end)()
  end

  return Async.wrap(function(callback)
    -- Try to install with proper error handling
    local path = self:get_path()
    local url = ('https://github.com/%s'):format(self.name)
    local cmd = {
      'git',
      'clone',
      '--depth=' .. DEFAULT_SETTINGS.git_depth,
      '--single-branch',
      '--progress',
    }

    -- Add branch specification if provided
    if self._branch then
      table.insert(cmd, '--branch=' .. self._branch)
      M.log('debug', string.format('Installing %s from branch: %s', self.name, self._branch))
    end

    -- Add URL and path at the end
    table.insert(cmd, url)
    table.insert(cmd, path)

    -- Update status
    self.status = STATUS.INSTALLING
    local install_msg = self._branch and ('Installing from branch: ' .. self._branch)
      or 'Starting installation...'
    ui:update_entry(self.name, self.status, install_msg)

    -- Use our new Async.system wrapper
    local result = Async.try_await(Async.system(cmd, {
      timeout = DEFAULT_SETTINGS.git_timeout,
      stderr = function(_, data)
        if data then
          -- Update progress in UI
          local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
          lines = vim.split(lines, '\n', { trimempty = true })

          if #lines > 0 then
            vim.schedule(function()
              ui:update_entry(self.name, self.status, lines[#lines])
            end)
          end
        end
      end,
    }))

    if result.success then
      self.status = STATUS.INSTALLED
      local success_msg = self._branch and ('Installed from branch: ' .. self._branch)
        or 'Installation complete'
      ui:update_entry(self.name, self.status, success_msg)

      -- Apply colorscheme if this is a theme
      if self.colorscheme then
        self:theme(self.colorscheme)
      end

      -- need build command if specified
      if self.run_action then
        self.need_build = true
      end
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Failed: ' .. (result.error.stderr or 'Unknown error') .. ' code: ' .. result.error.code
      )
    end
    callback(result.success)
  end)()
end

function Plugin:has_updates()
  return Async.wrap(function(callback)
    if self.is_local or not self.is_remote then
      callback(false)
      return
    end

    local path = self:get_path()
    local fetch_cmd = {
      'git',
      '-C',
      path,
      'fetch',
      '--quiet',
      'origin',
    }

    -- If a specific branch is set, fetch that branch
    if self._branch then
      table.insert(fetch_cmd, self._branch .. ':refs/remotes/origin/' .. self._branch)
    end

    local result = Async.try_await(Async.system(fetch_cmd))
    if not result.success then
      callback(false)
      return
    end

    -- Compare with the appropriate upstream
    local upstream_ref = self._branch and '@{upstream}' or '@{upstream}'
    local rev_cmd = {
      'git',
      '-C',
      path,
      'rev-list',
      '--count',
      'HEAD..' .. upstream_ref,
    }

    result = Async.try_await(Async.system(rev_cmd))
    if not result.success then
      callback(false)
      return
    end

    local count = tonumber(result.value.stdout and result.value.stdout:match('%d+') or '0')
    local has_updates = count and count > 0

    callback(has_updates)
  end)()
end

function Plugin:update(skip_check)
  if self.is_local or not self.is_remote then
    return Async.wrap(function(cb)
      cb(true, 'skip')
    end)()
  end

  return Async.wrap(function(callback)
    local installed
    local install_result = Async.try_await(self:is_installed())

    if install_result.success then
      installed = install_result.value
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Error checking installation: ' .. tostring(install_result.error)
      )
      callback(false, 'error_checking')
      return
    end

    if not installed then
      callback(true, 'not_installed')
      return
    end

    -- Skip update check if requested
    local has_updates = true
    if not skip_check then
      -- Check for updates
      local updates_result = Async.try_await(self:has_updates())

      if updates_result.success then
        has_updates = updates_result.value
      else
        self.status = STATUS.ERROR
        ui:update_entry(
          self.name,
          self.status,
          'Error checking updates: ' .. tostring(updates_result.error)
        )
        callback(false, 'error_checking_updates')
        return
      end

      if not has_updates then
        self.status = STATUS.UPDATED
        local up_to_date_msg = self._branch and ('Up to date on branch: ' .. self._branch)
          or 'Already up to date'
        ui:update_entry(self.name, self.status, up_to_date_msg)
        callback(true, 'up_to_date')
        return
      end
    end

    -- Update the plugin
    self.status = STATUS.UPDATING
    local updating_msg = self._branch and ('Updating branch: ' .. self._branch)
      or 'Starting update...'
    ui:update_entry(self.name, self.status, updating_msg)

    local path = self:get_path()
    local cmd = { 'git', '-C', path, 'pull', '--progress' }

    -- If specific branch is set, pull from that branch
    if self._branch then
      table.insert(cmd, 'origin')
      table.insert(cmd, self._branch)
    end

    -- Use our new Async.system wrapper
    local result = Async.try_await(Async.system(cmd, {
      timeout = DEFAULT_SETTINGS.git_timeout,
      stderr = function(_, data)
        if data then
          -- Update progress in UI
          local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
          lines = vim.split(lines, '\n', { trimempty = true })

          if #lines > 0 then
            vim.schedule(function()
              ui:update_entry(self.name, self.status, lines[#lines])
            end)
          end
        end
      end,
    }))

    -- Handle result
    if result.success then
      self.status = STATUS.UPDATED
      local stdout = result.value.stdout or ''
      local update_info = 'Update complete'
      local commit_info = stdout:match('([a-f0-9]+)%.%.([a-f0-9]+)')

      if stdout:find('Already up to date') then
        update_info = self._branch and ('Already up to date on branch: ' .. self._branch)
          or 'Already up to date'
      elseif commit_info then
        local branch_info = self._branch and (' on branch: ' .. self._branch) or ''
        update_info = string.format('Updated to %s%s', commit_info, branch_info)
      elseif self._branch then
        update_info = 'Updated on branch: ' .. self._branch
      end

      ui:update_entry(self.name, self.status, update_info)
      if self.run_action then
        self:load(true)
      end
      callback(true, 'updated')
    else
      self.status = STATUS.ERROR
      local error_msg = result.error.stderr or 'Unknown error'
      ui:update_entry(self.name, self.status, 'Failed: ' .. error_msg)
      callback(false, error_msg)
    end
  end)()
end

function Plugin:install_with_retry()
  if self.is_local or not self.is_remote then
    return Async.wrap(function(cb)
      cb(true)
    end)()
  end

  return Async.wrap(function(callback)
    -- Check if already installed
    local installed = Async.await(self:is_installed())
    if installed then
      callback(true)
      return
    end

    self.status = STATUS.INSTALLING
    local install_msg = self._branch and ('Installing from branch: ' .. self._branch)
      or 'Starting installation...'
    ui:update_entry(self.name, self.status, install_msg)

    local path = self:get_path()
    local url = ('https://github.com/%s'):format(self.name)
    local cmd = { 'git', 'clone', '--progress' }

    -- Add branch specification if provided
    if self._branch then
      table.insert(cmd, '--branch=' .. self._branch)
    end

    table.insert(cmd, url)
    table.insert(cmd, path)

    -- Use retry with the system command (3 retries with exponential backoff)
    local result = Async.try_await(Async.retry(function()
      return Async.system(cmd, {
        timeout = DEFAULT_SETTINGS.git_timeout,
        stderr = function(_, data)
          if data then
            -- Update progress in UI
            local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
            lines = vim.split(lines, '\n', { trimempty = true })

            if #lines > 0 then
              vim.schedule(function()
                ui:update_entry(self.name, self.status, lines[#lines])
              end)
            end
          end
        end,
      })
    end, 3, 1000)) -- 3 retries, starting with 1000ms delay

    -- Handle result
    if result.success then
      self.status = STATUS.INSTALLED
      local success_msg = self._branch and ('Installed from branch: ' .. self._branch)
        or 'Installation complete'
      ui:update_entry(self.name, self.status, success_msg)

      -- Apply colorscheme if this is a theme
      if self.colorscheme then
        self:theme(self.colorscheme)
      end

      -- Run command if specified
      if self.run_action then
        self:load(true)
      end
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Failed after retries: '
          .. (result.error.stderr or 'Unknown error')
          .. ' code: '
          .. result.error.code
      )
    end
    callback(result.success)
  end)()
end
-- =====================================================================
-- 6. Manager Functions
-- =====================================================================

-- Log a message
function M.log(level, message)
  local levels = { debug = 1, info = 2, warn = 3, error = 4 }
  local current_level = levels[DEFAULT_SETTINGS.log_level] or 2

  if levels[level] and levels[level] >= current_level then
    vim.notify(
      string.format('[strive] %s', message),
      level == 'error' and vim.log.levels.ERROR
        or level == 'warn' and vim.log.levels.WARN
        or level == 'info' and vim.log.levels.INFO
        or vim.log.levels.DEBUG
    )
  end
end

-- Register a plugin
function M.use(spec)
  local plugin = Plugin.new(spec)

  -- Check for duplicate
  if plugin_map[plugin.name] then
    M.log('warn', string.format('Plugin %s is already registered, skipping duplicate', plugin.name))
    return plugin_map[plugin.name]
  end
  plugin.id = #plugins + 1
  -- Add to collections
  table.insert(plugins, plugin)
  plugin_map[plugin.name] = plugin
  vim.g.strive_count = vim.g.strive_count + 1

  return plugin
end

-- Get plugin from registry
function M.get_plugin(name)
  return plugin_map[name]
end

-- Install all plugins
function M.install()
  Async.async(function()
    local plugins_to_install = {}

    -- Find plugins that need installation
    for _, plugin in ipairs(plugins) do
      if plugin.is_remote and not plugin.is_local then
        local result = Async.try_await(plugin:is_installed())

        if result.success and not result.value then
          table.insert(plugins_to_install, plugin)
        elseif not result.success then
          M.log(
            'error',
            string.format(
              'Error checking if %s is installed: %s',
              plugin.name,
              tostring(result.error)
            )
          )
        end
      end
    end

    if #plugins_to_install == 0 then
      M.log('info', 'No plugins to install.')
      return
    end

    M.log('info', string.format('Installing %d plugins...', #plugins_to_install))
    ui:open()

    local task_queue = TaskQueue.new(DEFAULT_SETTINGS.max_concurrent_tasks)
    local plugins_with_build = {}

    -- Create installation tasks with proper error handling
    local install_tasks = {}
    for _, plugin in ipairs(plugins_to_install) do
      table.insert(install_tasks, function(done)
        Async.async(function()
          local result = Async.try_await(
            DEFAULT_SETTINGS.install_retry and plugin:install_with_retry() or plugin:install()
          )
          if not result.success then
            M.log(
              'error',
              string.format('Failed to install %s: %s', plugin.name, tostring(result.error))
            )
          end

          if plugin.need_build then
            plugins_with_build[#plugins_with_build + 1] = plugin
          end

          done()
        end)()
      end)
    end

    -- Queue all tasks
    for _, task in ipairs(install_tasks) do
      task_queue:enqueue(task)
    end

    -- Set completion callback
    task_queue:on_complete(function()
      M.log('info', 'Installation completed.')
      -- Close UI after a delay
      Async.await(Async.delay(2000))
      ui:close()

      for _, p in ipairs(plugins_with_build) do
        p:load(true)
      end
    end)
  end)()
end

-- Update all plugins with concurrent operations
function M.update()
  Async.async(function()
    M.log('info', 'Checking for updates...')
    local plugins_to_update = {}

    local strive_plugin = Plugin.new({
      name = 'nvimdev/strive',
      plugin_name = 'strive',
      is_lazy = true,
      is_remote = true,
    })

    for _, plugin in ipairs(vim.list_extend(plugins, { strive_plugin })) do
      if plugin.is_remote and not plugin.is_local then
        local installed = Async.await(plugin:is_installed())
        if installed then
          table.insert(plugins_to_update, plugin)
        end
      end
    end

    if #plugins_to_update == 0 then
      M.log('info', 'No plugins to update.')
      return
    end

    ui:open()
    -- Initialize UI entries for all plugins immediately
    for _, plugin in ipairs(plugins_to_update) do
      plugin.status = STATUS.PENDING
      ui:update_entry(plugin.name, plugin.status, 'Queued for update...')
    end

    -- Process updates through TaskQueue
    local task_queue = TaskQueue.new(DEFAULT_SETTINGS.max_concurrent_tasks)

    for _, plugin in ipairs(plugins_to_update) do
      task_queue:enqueue(function(done)
        Async.async(function()
          plugin.status = STATUS.UPDATING
          ui:update_entry(plugin.name, plugin.status, 'Checking for updates...')

          -- Process one plugin at a time with UI feedback
          local has_updates = Async.await(plugin:has_updates())

          if has_updates then
            ui:update_entry(plugin.name, plugin.status, 'Updates available, pulling changes...')
            Async.await(plugin:update(true)) -- Skip redundant check
          else
            plugin.status = STATUS.UPDATED
            ui:update_entry(plugin.name, plugin.status, 'Already up to date')
          end

          done()
        end)()
      end)
    end

    task_queue:on_complete(function()
      M.log('info', 'Update completed')
      Async.await(Async.delay(2000))
      ui:close()
    end)
  end)()
end

-- Clean unused plugins
function M.clean()
  Async.async(function()
    M.log('debug', 'Starting clean operation')

    -- Get all installed plugins in both directories
    local installed_dirs = {}

    local function scan_directory(dir)
      M.log('debug', string.format('Scanning directory: %s', dir))
      if not isdir(dir) then
        M.log('debug', string.format('Directory does not exist: %s', dir))
        return
      end

      local result = Async.try_await(Async.scandir(dir))
      if not result.success or not result.value then
        M.log(
          'error',
          string.format('Error scanning directory %s: %s', dir, tostring(result.error))
        )
        return
      end

      while true do
        local name, type = uv.fs_scandir_next(result.value)
        if not name then
          break
        end

        if type == 'directory' then
          local full_path = joinpath(dir, name)
          M.log('debug', string.format('Found installed plugin: %s at %s', name, full_path))
          installed_dirs[name] = dir
        end
      end
    end

    -- Scan both start and opt directories
    scan_directory(START_DIR)
    scan_directory(OPT_DIR)

    local strive_plugin = Plugin.new({
      name = 'nvimdev/strive',
      plugin_name = 'strive',
      is_lazy = true,
      is_remote = true,
    })

    local p = vim.list_extend(plugins, { strive_plugin })
    -- Find plugins not in our registry
    local to_remove = {}
    for name, dir in pairs(installed_dirs) do
      local found = false
      for _, plugin in ipairs(p) do
        M.log(
          'debug',
          string.format('Comparing %s with registered plugin %s', name, plugin.plugin_name)
        )
        if plugin.plugin_name == name then
          found = true
          M.log('debug', string.format('Plugin %s is registered, keeping it', name))
          break
        end
      end

      if not found then
        M.log('debug', string.format('Plugin %s is not registered, marking for removal', name))
        table.insert(to_remove, { name = name, dir = dir })
      end
    end
    if #to_remove == 0 then
      vim.notify('[Strive]: no plugins to remove')
    end

    -- Show plugins that will be removed
    M.log('info', string.format('Found %d unused plugins to clean:', #to_remove))
    ui:open()
    for _, item in ipairs(to_remove) do
      local path = joinpath(item.dir, item.name)
      M.log('info', string.format('Will remove: %s', path))
      ui:update_entry(item.name, 'PENDING', 'Marked to removal')
    end

    -- Perform the actual deletion
    M.log('info', 'Starting deletion process...')

    vim.ui.select(
      { 'Yes', 'No' },
      { prompt = string.format('Remove %d unused plugins?', #to_remove) },
      function(choice)
        if choice and choice:lower():match('^y') then
          -- Process deletions through TaskQueue
          local task_queue = TaskQueue.new(DEFAULT_SETTINGS.max_concurrent_tasks)

          for _, item in ipairs(to_remove) do
            task_queue:enqueue(function(done)
              Async.async(function()
                local path = joinpath(item.dir, item.name)
                ui:update_entry(item.name, 'CLEANING', 'Removing...')

                -- Delete and handle errors
                local ok, result = pcall(vim.fn.delete, path, 'rf')
                if not ok or result ~= 0 then
                  ui:update_entry(item.name, 'ERROR', 'Failed to remove')
                else
                  ui:update_entry(item.name, 'REMOVED', 'Successfully removed')
                end
                done()
              end)()
            end)
          end

          task_queue:on_complete(function()
            Async.await(Async.delay(2000))
            ui:close()
          end)
        else
          ui:close()
        end
      end
    )
  end)()
end

function M.remove(plugin)
  local path = vim.fs.joinpath(OPT_DIR, plugin)
  if not isdir(path) then
    path = vim.fs.joinpath(START_DIR, plugin)
    if not isdir(path) then
      return
    end
  end

  local ok, result = pcall(vim.fn.delete, path, 'rf')
  if not ok or result ~= 0 then
    return M.log('Info', 'Failed to remove')
  end
  M.log('warn', ('Plugin %s removed successful'):format(plugin))
end

-- use uv instead of calling clock_time with ffi
local function startuptime()
  if vim.g.strive_startup_time ~= nil then
    return
  end
  vim.g.strive_startup_time = 0
  local usage = vim.uv.getrusage()
  if usage then
    -- Calculate time in milliseconds (user + system time)
    local user_time = (usage.utime.sec * 1000) + (usage.utime.usec / 1000)
    local sys_time = (usage.stime.sec * 1000) + (usage.stime.usec / 1000)
    vim.g.strive_startup_time = user_time + sys_time
  end
end

-- Set up auto-install with better event handling
if DEFAULT_SETTINGS.auto_install then
  -- Check if Neovim startup is already complete
  -- When using strive in plugin folder
  if vim.v.vim_did_enter == 1 then
    -- UI has already initialized, schedule installation directly
    vim.schedule(function()
      M.log('debug', 'UI already initialized, installing plugins now')
      M.install()
    end)
    startuptime()
  end
end

api.nvim_create_autocmd('UIEnter', {
  group = api.nvim_create_augroup('strive', { clear = false }),
  once = true,
  callback = function()
    if DEFAULT_SETTINGS.auto_install then
      vim.schedule(function()
        M.log('debug', 'UIEnter triggered, installing plugins')
        M.install()
      end)
      startuptime()
    end

    vim.schedule(function()
      api.nvim_exec_autocmds('User', {
        pattern = 'StriveDone',
        modeline = false,
      })
    end)
  end,
})

local t = { install = 1, update = 2, clean = 3, remove = 4 }
api.nvim_create_user_command('Strive', function(args)
  if #args.fargs == 0 then
    return
  end

  if t[args.fargs[1]] then
    M[args.fargs[1]](args.fargs[2])
  end
end, {
  desc = 'Install plugins',
  nargs = '+',
  complete = function()
    return vim.tbl_keys(t)
  end,
})

return { use = M.use }
