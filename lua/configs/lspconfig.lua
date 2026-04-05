local nvlsp = require("nvchad.configs.lspconfig")
nvlsp.defaults()

vim.lsp.config("ts_ls", {
	on_init = nvlsp.on_init,
	capabilities = nvlsp.capabilities,
	filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
	init_options = {
		hostInfo = "neovim",
		preferences = {
			includeCompletionsForModuleExports = true,
			includeCompletionsForImportStatements = true,
			includeCompletionsWithInsertText = true,
		},
	},
})

vim.lsp.enable({ "lua_ls", "html", "cssls", "ts_ls" })

vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if not client or client.name ~= "ts_ls" then
			return
		end

		local opts = { buffer = args.buf, desc = "Add missing imports" }
		vim.keymap.set("n", "<leader>li", function()
			vim.lsp.buf.code_action({
				apply = true,
				context = {
					only = { "source.addMissingImports.ts", "source.organizeImports.ts" },
					diagnostics = {},
				},
			})
		end, opts)
	end,
})

-- read :h vim.lsp.config for changing options of lsp servers 
