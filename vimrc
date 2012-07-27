set ignorecase
set smartcase
set incsearch
set showcmd		" Show (partial) command in status line.
set showmatch		" Show matching brackets.

filetype plugin indent on
set tabstop=4
set shiftwidth=4
set expandtab

" jump to the last position when reopening a file
if has("autocmd")
  au BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif
