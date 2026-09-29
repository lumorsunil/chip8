nnoremap <F5> <Cmd>vnew \| term zig build run -Dtarget=x86_64-windows<CR>
"nnoremap <F6> <Cmd>vnew \| term zig build run -Dtarget=x86_64-windows -- "IBM Logo.ch8"<CR>
nnoremap <F6> <Cmd>vnew \| term zig build run -Dtarget=x86_64-windows -- ./src/test.ch8asm <CR>
