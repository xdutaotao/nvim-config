" Vim syntax file: archive browser listing (see lua/config/archive.lua)
"
" The browse view is a synthetic listing, so this file highlights by
" position: the leading size column, then the member name. Directories and
" known archive/compression suffixes get their own groups.

if exists("b:current_syntax")
  finish
endif

syn clear

" Header block emitted by render_browse(): every line starts with a quote.
syn match archiveHeader /^".*$/ contains=archiveHeaderUri,archiveHeaderKey
syn match archiveHeaderUri /archive:\/\/\S\+/ contained
syn match archiveHeaderKey /<CR>\|-  up\|x  extract\|q  close/ contained

" " 465.4K    path/to/member"  — the size column is fixed-width.
syn match archiveSize /^\s*\zs\d\+\.\?\d*[KMG]\?\ze\s\{2,}/
syn match archiveEmpty /^\s*\zs(empty archive)\ze\s*$/

" A trailing slash means directory; it is how both tar -tv and unzip -l
" report subdirectories.
syn match archiveDir /^\s*\d*\.\?\d*[KMG]\?\s\+\zs.*\/\ze\s*$/

" Members that are themselves archives or compressed files: these are the
" ones worth opening recursively.
" `:syntax match` ignores `\zs` in the *first* position but honours a literal
" start offset, so the match begins at the member name via the `\S` anchor.
syn match archiveNested /\S\+\.\(tar\|tar\.gz\|tar\.bz2\|tar\.xz\|tar\.zst\|tar\.lz4\|tgz\|tbz2\?\|txz\|tzst\|tlz4\|gz\|bz2\|xz\|zst\|lz4\|zip\|7z\|rar\)\s*$/

hi def link archiveHeader     Comment
hi def link archiveHeaderUri  Underlined
hi def link archiveHeaderKey  Special
hi def link archiveSize       Number
hi def link archiveEmpty      Comment
hi def link archiveDir        Directory
hi def link archiveNested     Identifier

let b:current_syntax = "archive"
