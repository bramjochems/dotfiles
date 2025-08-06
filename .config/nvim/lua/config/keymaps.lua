-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("n", "<C-z>", "<Nop>")

vim.keymap.set("n", "<leader>fd", function()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end
  local dir = vim.fn.fnamemodify(file, ":h")
  vim.cmd("cd " .. dir)
  vim.notify("Changed cwd to: " .. dir)
end, { desc = "Change CWD to current file's directory" })

vim.keymap.set("n", "<leader>fD", function()
  vim.notify("CWD: " .. vim.fn.getcwd())
end, { desc = "Show current working directory" })

-- Keep search results centered
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- Keep half-page jumps centered
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")

-- Keep cursor centered when jumping to next match of *
vim.keymap.set("n", "*", "*zzzv")
vim.keymap.set("n", "#", "#zzzv")

-- Move lines in visual mode
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv") -- move selected block down
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv") -- move selected block up
