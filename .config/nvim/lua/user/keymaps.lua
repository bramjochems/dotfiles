-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
-- Supress vim from being suspended by Ctrl-Z since I hit it too often
vim.keymap.set("n", "<C-z>", "<Nop>")
