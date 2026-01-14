#!/usr/bin/env bash
set -uo pipefail  # No -e to support write to canary file after cancel

. "$EXTENSION_PATH/shared.sh"

# Get the file path passed as argument (always expects exactly one file)
FILE_PATH="$1"
# Get the directory containing the file
SINGLE_DIR_ROOT=$(dirname "$FILE_PATH")
# Get just the filename (basename) for ripgrep and bat
FILENAME="$(basename "$FILE_PATH")"
cd "$SINGLE_DIR_ROOT" || exit

# 1. Search for text in files using Ripgrep
# 2. Interactively restart Ripgrep with reload action
# 3. Open the file
# shellcheck disable=SC2207
RG_PREFIX=(rg
    --column
    --hidden
    $(array_join ${USE_GITIGNORE_OPT+"${USE_GITIGNORE_OPT[@]}"})
    --line-number
    --no-heading
    --with-filename
    --color=always
    --smart-case
    --colors 'match:fg:green'
    --colors 'path:fg:white'
    --colors 'path:style:nobold'
    $(array_join "${GLOBS[@]+"${GLOBS[@]}"}")
)
if [[ ${#TYPE_FILTER_ARR[@]} -gt 0 ]]; then
    RG_PREFIX+=("$(printf "%s " "${TYPE_FILTER_ARR[@]}")")
fi
RG_PREFIX+=(" 2> /dev/null")

PREVIEW_ENABLED=${FIND_IN_ACTIVE_FILE_PREVIEW_ENABLED:-1}
# For single file search, we use the basename since we've cd'd into the directory
# {1} is the line number (since we use --no-filename, there's no filename field)
# Need to escape the filename properly for fzf preview execution
# make command use filename:linenum:char again
PREVIEW_COMMAND=${FIND_IN_ACTIVE_FILE_PREVIEW_COMMAND:-'line={2} && begin=$( if [[ $line -lt 7 ]]; then echo $((line-1)); else echo 6; fi ) && bat --style=plain --highlight-line={2} --color=always --line-range $((line-begin)):$((line+50)) {1}'}
PREVIEW_WINDOW=${FIND_IN_ACTIVE_FILE_PREVIEW_WINDOW_CONFIG:-'right:border-left:50%:+{1}+3/3:~3'}
HAS_SELECTION=${HAS_SELECTION:-}
RESUME_SEARCH=${RESUME_SEARCH:-}
FUZZ_RG_QUERY=${FUZZ_RG_QUERY:-}
# We match against the beginning of the line so everything matches but nothing gets highlighted...
QUERY='^'
INITIAL_QUERY=''  # Don't show initial "^" regex in fzf
INITIAL_POS='1'
if [[ "$RESUME_SEARCH" -eq 1 ]]; then
    # ... or we resume the last search if that is desired
    if [[ -f "$LAST_QUERY_FILE" ]]; then
        QUERY="$(tail -n 1 "$LAST_QUERY_FILE")"
        INITIAL_QUERY="$QUERY"  # Do show the initial query when it's not "^"
        if [[ -f "$LAST_POS_FILE" ]]; then
            read -r pos < "$LAST_POS_FILE"
            ((pos++)) # convert index to position
            INITIAL_POS="$pos"
        fi
    fi
elif [[ "$HAS_SELECTION" -eq 1 ]]; then
    # ... or against the selection if we have one
    QUERY="$(cat "$SELECTION_FILE")"
    INITIAL_QUERY="$QUERY"  # Do show the initial query when it's not "^"
fi

# Some backwards compatibility stuff
if [[ $FZF_VER_PT1 == "0.2" && $FZF_VER_PT2 -lt 7 ]]; then
    if [[ "$PREVIEW_COMMAND" != "$FIND_IN_ACTIVE_FILE_PREVIEW_COMMAND" ]]; then
        PREVIEW_COMMAND='line={2} && begin=$( if [[ $line -lt 7 ]]; then echo $((line-1)); else echo 6; fi ) && bat --highlight-line={2} --color=always --line-range $((line-begin)):$((line+50)) {1}'
    fi
    if [[ "$PREVIEW_WINDOW" != "$FIND_IN_ACTIVE_FILE_PREVIEW_WINDOW_CONFIG" ]]; then
        PREVIEW_WINDOW='right:50%'
    fi
fi

PREVIEW_STR=()
if [[ "$PREVIEW_ENABLED" -eq 1 ]]; then
    PREVIEW_STR=(--preview "$PREVIEW_COMMAND" --preview-window "$PREVIEW_WINDOW")
fi

# dummy fallback binding because fzf v<0.36 does not support `load` and I did not figure out how to
# conditionally set the entire binding string (i.e., with the "--bind" part)
RESUME_POS_BINDING="backward-eof:ignore"
if [[ "$(printf '%s\n' "$FZF_VER_NUM" "0.36" | sort -V | head -n 1)" == "0.36" ]]; then
    # fzf version is greater or equal 0.36, so the `load` trigger is supported
    RESUME_POS_BINDING="load:pos($INITIAL_POS)"
fi

RG_QUERY_PARSING="{q}"
if [[ "$FUZZ_RG_QUERY" -eq 1 ]]; then
    RG_QUERY_PARSING="\$(echo {q} | sed 's/ /.*/g')"
    QUERY="$(echo $QUERY | sed 's/ /.*/g')"
fi

RG_PREFIX_STR=$(array_join "${RG_PREFIX+"${RG_PREFIX[@]}"}")
RG_PREFIX_STR="${RG_PREFIX+"${RG_PREFIX[@]}"}"
FZF_CMD="${RG_PREFIX+"${RG_PREFIX[@]}"} '$QUERY' '$FILENAME'"

# echo $FZF_CMD
echo "$RG_PREFIX_STR"
# exit 1
# IFS sets the delimiter
# -r: raw
# -a: array
# Quick note on ${PREVIEW_STR[@]+"${PREVIEW_STR[@]}"}: Don't ask.
# https://stackoverflow.com/q/7577052/888916
IFS=: read -ra VAL < <(
  FZF_DEFAULT_COMMAND="$FZF_CMD" \
  fzf --ansi \
      --cycle \
      --bind "change:reload:sleep 0.1; $RG_PREFIX_STR $RG_QUERY_PARSING '$FILENAME' || true" \
      --delimiter : \
      --history $LAST_QUERY_FILE \
      --bind "enter:execute(echo {n} > $LAST_POS_FILE)+accept" \
      --bind "$RESUME_POS_BINDING" \
      --phony --query "$INITIAL_QUERY" \
      ${PREVIEW_STR[@]+"${PREVIEW_STR[@]}"} \
)
# Output is filename, line number, character, contents

if [[ ${#VAL[@]} -eq 0 ]]; then
    echo canceled
    echo "1" > "$CANARY_FILE"
    exit 1
else
    FILENAME=${VAL[0]}:${VAL[1]}:${VAL[2]}
    if [[ -n "$SINGLE_DIR_ROOT" ]]; then
        echo "$SINGLE_DIR_ROOT/$FILENAME" > "$CANARY_FILE"
    else
        echo "$FILENAME" > "$CANARY_FILE"
    fi
fi
