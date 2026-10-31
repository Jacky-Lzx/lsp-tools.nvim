local config = assert(vim.env.LSP_TOOLS_NVIM_CONFIG)
vim.env.NVIM_CONFIG_ROOT, vim.env.NVIM_SMOKE_TEST = config, "1"
vim.env.NVIM_LAZY_LOCKFILE = vim.env.LSP_TOOLS_TEST_TMP .. "/lock.json"
vim.opt.rtp:prepend(config)
require("config.context").initialize({ profiles = {}, features = {} })
vim.g.loaded_wakatime = true
vim.o.loadplugins = true
dofile(config .. "/init.lua")
vim.env.LSP_TOOLS_CONFIG = "1"
vim.env.LSP_TOOLS_REAL_LSP = "1"
dofile(vim.env.LSP_TOOLS_ROOT .. "/tests/rename_integration.lua")
