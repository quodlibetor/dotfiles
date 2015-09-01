if filereadable(expand("~/.vim/autoload/pathogen.vim"))
    runtime! autoload/pathogen.vim
    if exists("g:loaded_pathogen")
       execute pathogen#infect()
    endif
endif

set ignorecase
set smartcase
set incsearch
set showcmd		" Show (partial) command in status line.
set showmatch	" Show matching brackets.
set wildmenu
set wildmode=longest:full,full

filetype plugin indent on
syntax on
set tabstop=4
set shiftwidth=4
set expandtab

let mapleader=","
set background=dark
if filereadable(expand("~/.vim/colors/distinguished.vim"))
    colorscheme distinguished
endif

" jump to the last position when reopening a file
if has("autocmd")
  au BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif

if filereadable(expand("~/.vim/bundle/nose.vim"))
    autocmd BufNewFile,BufRead *.py compiler nose
endif

nnoremap <leader>ta :MakeGreen<CR>
nnoremap <leader>tm :MakeGreen %<CR>
nnoremap <leader>tc :MakeCurrentClassGreen %<CR>
nnoremap <leader>t. :MakeCurrentFunctionGreen %<CR>

nnoremap ; :

function! s:DiffWithSaved()
  let filetype=&ft
  diffthis
  vnew | r # | normal! 1Gdd
  diffthis
  exe "setlocal bt=nofile bh=wipe nobl noswf ro ft=" . filetype
endfunction
com! DiffSaved call s:DiffWithSaved()

""""""""""""""""""""""""""""""""""""""""""""""""""
" these "find" functions are from pytest.vim
" https://github.com/alfredodeza/pytest.vim/blob/master/ftplugin/python/pytest.vim
" these MakeCurrent*Green functions are my jokes at vimscript

" Always goes back to the first instance
" and returns that if found
function! s:FindPythonObject(obj)
    let orig_line = line('.')
    let orig_col = col('.')
    let orig_indent = indent(orig_line)

    if (a:obj == "class")
        let objregexp = '\v^\s*(.*class)\s+(\w+)\s*'
    else
        let objregexp = '\v^\s*(.*def)\s+(\w+)'
    endif

    let flag = "Wb"

    while search(objregexp, flag) > 0
        "
        " Very naive, but if the indent is less than or equal to four
        " keep on going because we assume you are nesting.
        "
        if indent(line('.')) <= 4
            return 1
        endif
    endwhile

endfunction

function! s:NameOfCurrentClass()
    let save_cursor = getpos(".")
    normal! $<cr>
    let find_object = s:FindPythonObject('class')
    if (find_object)
        let line = getline('.')
        call setpos('.', save_cursor)
        let match_result = matchlist(line, ' *class \+\(\w\+\)')
        return match_result[1]
    endif
endfunction

function! MakeCurrentClassGreen(currentfile)
    let currentclass = s:NameOfCurrentClass()
    let full = bufname(a:currentfile) . ":" . currentclass
    call MakeGreen(full)
endfunction

:command -nargs=1 MakeCurrentClassGreen :call MakeCurrentClassGreen(<f-args>)

function! s:NameOfCurrentFunction()
    let save_cursor = getpos(".")
    normal! $<cr>
    let find_object = s:FindPythonObject('function')
    if (find_object)
        let line = getline('.')
        call setpos('.', save_cursor)
        let match_result = matchlist(line, ' *def \+\(\w\+\)\((self\)\?')
        let result =  match_result[1]
        if (match_result[2] == '(self')
            let class = s:NameOfCurrentClass()
            let result = class . "." . result
        endif
        return result
    endif
endfunction

function! MakeCurrentFunctionGreen(currentfile)
    let currentfunction = s:NameOfCurrentFunction()
    let full = bufname(a:currentfile) . ":" . currentfunction
    call MakeGreen(full)
endfunction

:command -nargs=1 MakeCurrentFunctionGreen :call MakeCurrentFunctionGreen(<f-args>)
