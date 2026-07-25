#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATH="$repo_dir/test/bin:$PATH"
export PATH
cd "$repo_dir"
exec vim -Nu NONE -i NONE -n -es -S test/test_run.vim
