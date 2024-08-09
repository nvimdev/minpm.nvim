if vim.g.minpm_loaded then
  return
end

local api = vim.api

api.nvim_create_user_command('Minpm', function(args)
  local sub = args.args
end, {
  nargs = '?',
  complete = function()
    return require('minpm').complete
  end,
})
