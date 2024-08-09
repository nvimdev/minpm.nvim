local api, stdpath, uv = vim.api, vim.fn.stdpath, vim.uv
local repos, INSTALL, UPDATE = {}, 0, 1
local buf_set_lines, create_autocmd = api.nvim_buf_set_lines, api.nvim_create_autocmd
local packadd = vim.cmd.packadd
local exec_autocmds = api.nvim_exec_autocmds
local data_dir = stdpath('data')
---@diagnostic disable-next-line: param-type-mismatch
local STARTDIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'start')
---@diagnostic disable-next-line: param-type-mismatch
local OPTDIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'opt')
---@diagnostic disable-next-line: param-type-mismatch
vim.opt.packpath:prepend(vim.fs.joinpath(data_dir, 'site'))
local if_nil = vim.F.if_nil

local function as_table(data)
  return type(data) ~= 'table' and { data } or data
end

local use_meta = {}
use_meta.__index = use_meta
function use_meta:when(e)
  self.event = as_table(e)
  self.islazy = true
  local id
  id = create_autocmd(e, {
    callback = function(args)
      if self.remote then
        api.nvim_del_autocmd(id)
        packadd(self.tail)
        exec_autocmds(e, {
          modeline = false,
          data = args.data,
        })
        if self.setup_config then
          module = self.tail:gsub('%.nvim', '') or self.tail:gsub('-nvim', '')
          require(module).setup(self.setup_config)
        end
      end
    end,
  })
  return self
end

function use_meta:lang(ft)
  self.ft = as_table(ft)
  self.islazy = true
  return self
end

function use_meta:setup(config)
  self.setup_config = config
  return self
end

function use_meta:config(config)
  assert(type(config) == 'function')
  self.config = config
  return self
end

local window = {}
function window:new()
  local o = {}
  setmetatable(o, self)
  self.__index = self
  self.content = {}
  self.last_row = -1
  return o
end

function window:creaet()
  self.bufnr = api.nvim_create_buf(false, false)
  self.win = api.nvim_open_win(self.bufnr, true, {
    relative = 'editor',
    height = math.floor(vim.o.lines * 0.5),
    width = math.floor(vim.o.columns * 0.8),
    row = 3,
    col = 10,
    border = 'rounded',
    noautocmd = true,
    style = 'minimal',
    hide = true,
  })
  vim.wo[self.win].wrap = false
  vim.bo[self.bufnr].buftype = 'nofile'
end

function window:get_row(repo_name)
  if not vim.list_contains(self.content, repo_name) then
    self.content[#self.content + 1] = repo_name
    return #self.content
  end
  for k, v in ipairs(self.content) do
    if v == repo_name then
      return k
    end
  end
end

function window:write_output(name, data)
  local row = self:get_row(name) - 1
  vim.schedule(function()
    if not self.bufnr then
      self:create_window()
    end
    buf_set_lines(self.bufnr, row, row + 1, false, { ('%s: %s'):format(name, data) })
  end)
end

function use_meta:do_action(action, winobj)
  local path = vim.fs.joinpath(self.islazy and OPTDIR or STARTDIR, self.tail)
  local url = ('https://github.com/%s'):format(self.name)
  local cmd = action == INSTALL and { 'git', 'clone', '--progress', url, path }
    or { 'git', '-C', '--progress', path, 'pull' }
  uv.fs_stat(path, function(_, stat)
    if stat and stat.type == 'directory' then
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
        if not data then
          break
        end
        local lines = err and err or data
        lines = lines:gsub('\r', '\n'):gsub('\n+', '\n')
        lines = vim.split(lines, '\n', { trimempty = true })
        winobj:write_output(self.name, lines[#lines])
      end
    end))
  end)
end

local function action_wrapper(act)
  return function()
    local winobj = window:new()
    vim.iter(repos):map(function(repo)
      if not repo.remote then
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
