local api, stdpath, uv, if_nil = vim.api, vim.fn.stdpath, vim.uv, vim.F.if_nil
local repos, INSTALL = {}, 0
local create_autocmd = api.nvim_create_autocmd
local packadd = vim.cmd.packadd
local exec_autocmds = api.nvim_exec_autocmds
local data_dir = stdpath('data')
---@diagnostic disable-next-line: param-type-mismatch
local STARTDIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'start')
---@diagnostic disable-next-line: param-type-mismatch
local OPTDIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'opt')
---@diagnostic disable-next-line: param-type-mismatch
vim.opt.packpath:prepend(vim.fs.joinpath(data_dir, 'site'))
local window, TaskQueue = require('minpm.win'), require('minpm.task')

local function as_table(data)
  return type(data) ~= 'table' and { data } or data
end

local use_meta = {}
use_meta.__index = use_meta

function use_meta:handle_event()
  self.auid = create_autocmd(self.event, {
    pattern = self.ft or nil,
    callback = function(args)
      if not self.remote then
        return
      end

      api.nvim_del_autocmd(self.auid)
      packadd(self.tail)
      local module = self.tail:gsub('%.nvim$', ''):gsub('-nvim$', ''):gsub('^nvim%-', '')
      local m_setup = vim.tbl_get(require(module), 'setup')
      if type(m_setup) == 'function' then
        m_setup(self.setup_config)
      end

      if self.after_config then
        self.after_config()
      end

      exec_autocmds(self.event, {
        modeline = false,
        data = args.data,
      })
    end,
  })
end

function use_meta:when(e)
  self.event = as_table(e)
  self.islazy = true
  self:handle_event()
  return self
end

function use_meta:lang(ft)
  self.ft = as_table(ft)
  self.event = 'FileType'
  self:handle_event()
  self.islazy = true
  return self
end

function use_meta:dev()
  self.isdev = true
  self.remote = false
  return self
end

function use_meta:setup(setup_config)
  self.setup_config = setup_config
  return self
end

function use_meta:config(config)
  assert(type(config) == 'function')
  self.after_config = config
  return self
end

local MAX_CONCURRENT_TASKS = if_nil(vim.g.minpm_max_concurrent_tasks, 2)
local tsq = TaskQueue:new(MAX_CONCURRENT_TASKS)

function use_meta:do_action(action, winobj)
  tsq:queue_task(function(task_done)
    local path = vim.fs.joinpath(self.islazy and OPTDIR or STARTDIR, self.tail)
    local url = ('https://github.com/%s'):format(self.name)
    local cmd = action == INSTALL and { 'git', 'clone', '--progress', url, path }
      or { 'git', '-C', path, 'pull', '--progress' }
    uv.fs_stat(path, function(_, stat)
      if stat and stat.type == 'directory' then
        task_done()
        return
      end
      coroutine.resume(coroutine.create(function()
        local co = assert(coroutine.running())
        vim.system(cmd, {
          timeout = 5000,
          stderr = function(err, data)
            coroutine.resume(co, err, data)
          end,
        })
        while true do
          local err, data = coroutine.yield()
          local lines = err and err or data
          if not lines then
            task_done()
            break
          end
          lines = lines:gsub('\r', '\n'):gsub('\n+', '\n')
          lines = vim.split(lines, '\n', { trimempty = true })
          winobj:write_output(self.name, lines[#lines])
        end
      end))
    end)
  end)
end

local function action_wrapper(act)
  act = act or INSTALL
  return function()
    local winobj = window:new()
    vim.iter(repos):map(function(repo)
      if not repo.remote or repo.isdev then
        return
      end
      repo:do_action(act, winobj)
    end)
  end
end

if if_nil(vim.g.minpm_auto_install, true) then
  create_autocmd('UIEnter', {
    callback = function()
      action_wrapper(INSTALL)()
    end,
  })
end

local function use(name)
  name = vim.fs.normalize(name)
  local parts = vim.split(name, '/', { trimempty = true })
  repos[#repos + 1] = setmetatable({
    name = name,
    remote = not name:find(vim.env.HOME),
    tail = parts[#parts],
  }, use_meta)
  return repos[#repos]
end

return setmetatable({}, {
  __index = function(_, k)
    local t = { use = use, complete = { 'install', 'update' } }
    return t[k] or action_wrapper(k:upper())
  end,
})
