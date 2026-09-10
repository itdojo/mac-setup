#!/usr/bin/env bash
#
# bootstrap.sh
#
# Takes a factory-fresh Mac to a working toolchain, then hands off to the
# student-setup engine: Xcode Command Line Tools, Homebrew, uv, a pinned
# interpreter, and a verified tarball of the tool itself.
#
# Targets:
#   - macOS on Apple Silicon      (Homebrew)
#
# Apple Silicon only. Homebrew's prefix differs on Intel and no Intel path is
# in scope, so this refuses rather than installing into the wrong place. The
# engine's `preflight` Module checks the same thing again for the Ledger's
# sake; this check exists because Homebrew arrives before the engine does.
#
# Usage:  ./bootstrap.sh [flags]
#         ./bootstrap.sh --help
# Do not run as root.
#
# What this project's README tells a student to type, which is the two
# deliberate steps this whole design turns on:
#
#   curl -fLO https://raw.githubusercontent.com/itdojo/mac-setup/main/bootstrap.sh
#   less bootstrap.sh
#   bash bootstrap.sh
#
# This first download is the one fetch nothing here can help with — the
# script is not on the machine yet. Everything downloaded after it comes from
# one place: this build's GitHub Release, reached over HTTPS at a fixed
# address with nothing to resolve and no second address to try. The
# classroom's DNS name and its Ethernet fallback have no counterpart here — a
# public release has one origin.
#
# The middle one is not decoration. HTTPS proves this came from GitHub; it
# says nothing about whether the bytes are worth running, so reading it first
# is still the discipline, and the script checks everything it fetches after
# that.
#
# Nothing here is piped from the network into a shell. The tool arrives as a
# versioned tarball whose sha256 is fetched beside it and checked before
# anything is unpacked, and Homebrew's own installer is downloaded to a file,
# its digest printed, and then run from disk. `curl | bash` is ruled out in
# this project on purpose: a tool whose whole claim is that nothing is hidden
# cannot begin by asking a student to run code they were given no chance to
# read.
#
# `git` is deliberately unused. On a factory Mac it is a stub that triggers
# the Command Line Tools dialog, and the Command Line Tools are what this
# installs.
#
# The script is idempotent: rerunning it should not duplicate config or fail.
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# `-E` is a deliberate departure from the qol house style's `set -eo pipefail`.
# Without errtrace an ERR trap is not inherited by shell functions, and every
# command in this script runs inside one — so a failed `curl`, `tar` or `mv`
# exits silently with no diagnostic at all, which is the worst thing that can
# happen on a Day-1 machine. `scripts/vm.sh` and the house style itself have
# the same gap; see docs/working-notes.md.
set -Eeo pipefail

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                       GLOBALS
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
OS="$(uname -s)"
ARCH="$(uname -m)"

# Everything below is overridable from the environment, so a second course or
# a second build does not need a second copy of this script. The flags in
# `parse_args` override the environment in turn.
TOOL_VERSION="${STUDENT_SETUP_VERSION:-2026.09.05}"

# The public Releases are this script's mirror. Two files live there, the tool
# tarball and Homebrew's installer, each with a .sha256 beside it. That is the
# whole reason this is a mirror rather than nothing: Homebrew publishes no
# digest of its own, so a direct fetch can only print what it got, and the one
# fetch this tool cannot verify would become the ordinary case.
#
# The Profile is a separate matter. `takehome-core.toml` names no [mirror], so
# the engine resolves DIRECT and pulls bottles, casks and everything else from
# upstream.
#
# TOOL_VERSION above and the release tag below are two copies of the same
# pin. Overriding STUDENT_SETUP_VERSION without also overriding
# STUDENT_SETUP_MIRROR asks the old tag's release for a filename it never
# published — a loud 404, not a silently wrong build, but a coupling worth
# knowing about before typing either override alone.
MIRROR="${STUDENT_SETUP_MIRROR:-https://github.com/itdojo/mac-setup/releases/download/2026.09.05}"

# Seconds to wait for the mirror to answer. A GitHub Release that is there
# answers at once; this bounds how long a run waits on one that is not, since
# there is no second address to fall back to — a public release has one
# origin, unlike the classroom's DNS name with its Ethernet fallback.
MIRROR_TIMEOUT="${STUDENT_SETUP_MIRROR_TIMEOUT:-3}"

# Whether anyone actually named a mirror, as against taking the default. It
# decides one thing: whether `--mirror` is passed on to the engine.
# `takehome-core.toml` names no `[mirror]`, so with nothing typed the engine
# resolves DIRECT on its own; handing it this script's own default would
# hand it a mirror the Profile never asked for. Only an address a person
# typed is worth overriding that with.
MIRROR_EXPLICIT="${STUDENT_SETUP_MIRROR:+1}"
PYTHON_VERSION="${STUDENT_SETUP_PYTHON:-3.12}"
PROFILE="${STUDENT_SETUP_PROFILE:-takehome-core}"

# The macOS floor. A policy floor rather than a compatibility one: nothing
# installed here is known to need it, and what would actually break on an
# older macOS is undefined. It exists so a genuinely ancient machine cannot
# start a run. Stated here as well as in `takehome-core.toml` so the refusal
# arrives before the Command Line Tools, Homebrew and uv are on the machine
# rather than after — the two copies have to agree, and a test holds them
# together. It was the kit image's exact patch level until 2026-08-30, which
# refused students one patch release behind for no technical reason; never
# pin it to whatever build the current hardware ships.
MACOS_MINIMUM="${STUDENT_SETUP_MACOS_MINIMUM:-26}"
DEST="${STUDENT_SETUP_DEST:-$HOME/student-setup}"
TOOL_URL=""
ASSUME_YES="${ASSUME_YES:-}"
RUN_ENGINE=1

# Where the mirror keeps each thing. Empty, here: a GitHub Release's assets
# are flat, `<tag>/<asset-name>` with no directory in between, and an asset
# name cannot itself contain a slash. `tool_url` and `homebrew_installer_url`
# both collapse an empty path rather than joining in a segment that no
# release asset actually has.
TOOL_PATH=""
HOMEBREW_INSTALLER_PATH="install.sh"

# Homebrew publishes no digest for its installer, so a direct fetch can only
# print what it got. The Release serves a `.sha256` beside its copy and that
# one is checked, which is the whole reason fetching from it is the default.
# `--direct` is for pointing this script at some other build entirely — the
# tool tarball still needs `--tool-url` alongside it.
HOMEBREW_INSTALLER_UPSTREAM="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
USE_MIRROR=1

# The prefix Homebrew uses on Apple Silicon. Not detected — `require_apple_
# silicon` has already refused every machine where it would be anything else
# — but overridable, because a student who already keeps Homebrew somewhere
# unusual should not have a second copy installed underneath them.
BREW_PREFIX="${STUDENT_SETUP_BREW_PREFIX:-/opt/homebrew}"

# macOS opens its own window for the Command Line Tools and this script can
# only wait for it. Twenty minutes is long enough for a slow network and
# short enough that a student who closed the window finds out.
CLT_TIMEOUT="${STUDENT_SETUP_CLT_TIMEOUT:-1200}"
CLT_POLL="${STUDENT_SETUP_CLT_POLL:-5}"
CLT_NARRATE_EVERY="${STUDENT_SETUP_CLT_NARRATE_EVERY:-60}"

# What the engine reads on its first run, because the engine did not exist
# while any of the work above was happening.
HANDOFF_DIR="$HOME/.student-setup"
HANDOFF="$HANDOFF_DIR/bootstrap.json"

# The shell file that has to learn where Homebrew is. A login-shell file, not
# .zshrc: `brew shellenv` sets PATH, and PATH belongs in the file that runs
# once per login rather than once per prompt.
SHELL_PROFILE="$HOME/.zprofile"
SENTINEL_OPEN="# >>> student-setup (homebrew) >>>"
SENTINEL_CLOSE="# <<< student-setup (homebrew) <<<"

# Filled in as the run goes, and written to the handoff at the end. The split
# is load-bearing: "the tool installed Homebrew" and "Homebrew was already
# here" are different claims, and only the first is the tool's to undo.
INSTALLED=()
ALREADY_PRESENT=()
TARBALL_SHA256=""
TOOL_SOURCE=""
SCRATCH=""

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                   PRETTY OUTPUT — (KEEP IN SYNC WITH LINUX/BASE_FUNCTIONS.SH)
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Verified identical to qol's linux/base_functions.sh by tests/test-theme-sync.sh
# in that repo. Copied whole on purpose: a partial copy is a restyle.
# shellcheck disable=SC2034
qol_init_color() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        QOL_COLOR=""
    elif [[ -n "${QOL_FORCE_COLOR:-}" || -t 1 ]]; then
        QOL_COLOR=1
    else
        QOL_COLOR=""
    fi

    case "${QOL_COLOR_DEPTH:-truecolor}" in
        256)  QOL_DEPTH=256 ;;
        8)    QOL_DEPTH=8 ;;
        none) QOL_DEPTH=none ;;
        *)    QOL_DEPTH=truecolor ;;
    esac
    [[ -z "$QOL_COLOR" ]] && QOL_DEPTH=none

# ‒‒ generated by build-design-tokens.py --emit-bash
# ‒‒ do not hand-edit; edit tokens/colors.css and re-emit.
    case "$QOL_DEPTH" in
        truecolor)
            QOL_STEP=$'\033[38;2;188;176;232m'
            QOL_PASS=$'\033[38;2;78;206;106m'
            QOL_INFO=$'\033[38;2;122;160;216m'
            QOL_WARN=$'\033[38;2;224;180;90m'
            QOL_STOP=$'\033[38;2;224;107;130m'
            QOL_FG=$'\033[38;2;228;222;245m'
            QOL_META=$'\033[38;2;154;147;181m'
            QOL_RULE=$'\033[38;2;74;65;112m'
            QOL_SEL=$'\033[48;2;36;29;61m'
            QOL_OKBG=$'\033[48;2;21;50;31m'
            ;;
        256)
            QOL_STEP=$'\033[38;5;140m'
            QOL_PASS=$'\033[38;5;77m'
            QOL_INFO=$'\033[38;5;110m'
            QOL_WARN=$'\033[38;5;179m'
            QOL_STOP=$'\033[38;5;168m'
            QOL_FG=$'\033[38;5;189m'
            QOL_META=$'\033[38;5;103m'
            QOL_RULE=$'\033[38;5;60m'
            QOL_SEL=$'\033[48;5;235m'
            QOL_OKBG=$'\033[48;5;22m'
            ;;
        8)
            QOL_STEP=$'\033[94m'
            QOL_PASS=$'\033[92m'
            QOL_INFO=$'\033[94m'
            QOL_WARN=$'\033[93m'
            QOL_STOP=$'\033[91m'
            QOL_FG=$'\033[97m'
            QOL_META=$'\033[90m'
            QOL_RULE=$'\033[90m'
            QOL_SEL=$'\033[7m'
            QOL_OKBG=$'\033[7m'
            ;;
        *)
            QOL_STEP="" QOL_PASS="" QOL_INFO="" QOL_WARN="" QOL_STOP="" QOL_FG="" QOL_META="" QOL_RULE="" QOL_SEL="" QOL_OKBG=""
            ;;
    esac
# ‒‒ end generated block

    if [[ "$QOL_DEPTH" == "none" ]]; then
        QOL_BOLD="" QOL_DIM="" QOL_RESET=""
    else
        QOL_BOLD=$'\033[1m'; QOL_DIM=$'\033[2m'; QOL_RESET=$'\033[0m'
    fi
}
qol_init_color

# Terminal width, falling back to 80 with no TTY (cron, CI, pipes).
#
# Ask the terminal, not terminfo. `tput cols 2>/dev/null` inside a command
# substitution answers 80 however wide the window is: with stdout captured,
# ncurses reads the window size off stderr instead, and that redirect throws
# the only usable fd away. Every rule, bookend and selection bar in this file
# was pinned to 80 columns by it. stty asks /dev/tty directly, so no amount of
# nesting can hide the answer. COLUMNS still wins when set, as an override.
#
# **Both the redirect order and the `|| true` are load-bearing, and neither is
# style.** With no controlling terminal — cron, CI, an agent, `ssh host cmd` —
# opening /dev/tty fails. Bash applies redirections left to right and reports a
# failed one on its own stderr, so `</dev/tty 2>/dev/null` prints
# `/dev/tty: Device not configured` past a suppression that is not in effect
# yet; putting `2>/dev/null` first silences it. That is only the noise. The
# failure is that the pipeline still exits non-zero, and a script running under
# `set -E` inherits its ERR trap into this command substitution and dies here —
# at its opening banner, before doing anything. Measured 2026-08-20:
# student-setup's `bootstrap.sh` (`set -Eeo pipefail`) reported
# `Failed at line 239` and stopped; the scripts in this repo use `set -eo` and
# only printed the message, which is why it read as cosmetic for a week.
# `|| true` is what makes the fallback to 80 a fallback rather than a fatality.
# With a real terminal nothing changes: stty answers, the pipeline exits 0, and
# `|| true` never fires.
_term_cols() {
    local cols="${COLUMNS:-}"
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols <= 0 )); then
        cols="$(stty size 2>/dev/null </dev/tty | cut -d' ' -f2 || true)"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols <= 0 )); then
        cols=80
    fi
    printf '%s' "$cols"
}

# Repeat a character n times. Emits nothing for n <= 0.
_repeat() {
    local ch="$1" n="$2" line
    [[ "$n" =~ ^-?[0-9]+$ ]] || return 0
    (( n <= 0 )) && return 0
    printf -v line '%*s' "$n" ''
    printf '%s' "${line// /$ch}"
}

# One milestone line. The prefix is exactly 9 columns: gutter, space,
# 4-char badge, 3 spaces. Message text therefore starts at column 10.
_log_line() {
    local ink="$1" badge="$2" text="$3"
    printf '%s%s▌ %-4s   %s%s\n' "$QOL_BOLD" "$ink" "$badge" "$text" "$QOL_RESET"
}

log_step() { _log_line "$QOL_STEP" STEP "$1"; }
log_ok()   { _log_line "$QOL_PASS" PASS "$1"; }
log_info() { _log_line "$QOL_INFO" INFO "$1"; }
log_warn() { _log_line "$QOL_WARN" WARN "$1"; }
log_err()  { _log_line "$QOL_STOP" STOP "$1" >&2; }
log_ask()  { _log_line "$QOL_STEP" ASK  "$1"; }
log_next() { _log_line "$QOL_INFO" NEXT "$1"; }

# Phase boundary: a gray rule carrying the phase name in violet. A rule now
# means "new phase", which is information; a rule per line meant nothing.
log_phase() {
    local title="$1" cols fill
    cols="$(_term_cols)"
    fill=$(( cols - ${#title} - 4 ))
    printf '\n%s──%s %s%s%s%s %s%s\n\n' \
        "$QOL_RULE" "$QOL_RESET" \
        "$QOL_BOLD$QOL_STEP" "$title" "$QOL_RESET" \
        "$QOL_RULE" "$(_repeat '─' "$fill")" "$QOL_RESET"
}

# Run bookends. Jade rules, so a run's edges are findable when scrolling
# back through screens of package-manager output; phase rules are gray.
banner() {
    local title="$1" sub="${2:-}" cols
    cols="$(_term_cols)"
    printf '%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
    printf '  %s%s⛩ %s ⛩%s' "$QOL_BOLD" "$QOL_PASS" "$title" "$QOL_RESET"
    [[ -n "$sub" ]] && printf '   %s%s%s' "$QOL_META" "$sub" "$QOL_RESET"
    printf '\n%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
}

# NOTE: not named `complete` — that is a bash builtin.
log_complete() {
    local title="$1" cols
    cols="$(_term_cols)"
    printf '\n%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
    printf '  %s%s%s ⛩ %s ⛩ %s\n' "$QOL_OKBG" "$QOL_BOLD" "$QOL_PASS" "$title" "$QOL_RESET"
    printf '%s%s%s\n\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
}

# ‒‒ Back-compat ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Eight other scripts call these. Kept working, not kept identical: printline
# no longer appears in any log_* line, because the design uses phase rules.

# Print a separator line the width of the terminal.
# Usage: printline [solid|bullet|ibeam|star|plus|diamond|dentistry]
printline() {
    local sep
    case "${1:-solid}" in
        bullet)    sep="•" ;;
        ibeam)     sep="⌶" ;;
        star)      sep="★" ;;
        plus)      sep="✛" ;;
        diamond)   sep="◆" ;;
        dentistry) sep="⏥" ;;
        *)         sep="─" ;;
    esac
    printf '%s%s%s\n' "$QOL_RULE" "$(_repeat "$sep" "$(_term_cols)")" "$QOL_RESET"
}

# Print styled text with no separator. Also usable inline via command
# substitution: echo "I am a $(style_text "Raspberry Pi" bold wine)."
# Usage: style_text "text" [normal|bold|light] [brand or legacy color name]
# Brand names:  violet jade steel saffron wine prose meta rule
# Legacy names: blue   green  —     yellow  red   —     —    —
style_text() {
    local text="$1" weight="${2:-normal}" color="${3:-}"
    local wt="" ink=""
    case "$weight" in
        bold)  wt="$QOL_BOLD" ;;
        light) wt="$QOL_DIM" ;;
    esac
    case "$color" in
        violet)        ink="$QOL_STEP" ;;
        jade|green)    ink="$QOL_PASS" ;;
        steel|blue)    ink="$QOL_INFO" ;;
        saffron|yellow) ink="$QOL_WARN" ;;
        wine|red)      ink="$QOL_STOP" ;;
        prose)         ink="$QOL_FG" ;;
        meta)          ink="$QOL_META" ;;
        rule)          ink="$QOL_RULE" ;;
    esac
    if [[ -z "$QOL_COLOR" ]] || [[ -z "$ink" && -z "$wt" ]]; then
        printf '%s\n' "$text"
        return 0
    fi
    printf '%s%s%s%s\n' "$wt" "$ink" "$text" "$QOL_RESET"
}

# Separator + styled text. Retained for callers that predate log_phase;
# new code should use log_phase or a log_* helper instead.
format_font() {
    printline
    style_text "$1" "${2:-bold}" "${3:-saffron}"
}

# Banner for script titles. Prefer banner/log_complete in new code.
log_title() {
    local cols
    cols="$(_term_cols)"
    printf '%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
    style_text "$1" bold jade
    printf '%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
}

# ‒‒ Interactive ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Three question shapes, sharing gotime's chrome. Prompts go to stderr so
# ask_value and ask_choice can be captured with $(...). All three skip the
# prompt and return the default when ASSUME_YES is set or stdin is not a
# TTY — the priority order install_nano.sh already follows.

# Decode one keypress into _KEY (and _KEYCH for digits). Bash 3.2 safe:
# no read -N, no fractional -t. Arrows arrive as ESC then "[A"/"OA".
_read_key() {
    local k s
    _KEY=""; _KEYCH=""
    IFS= read -rsn1 k || { _KEY="QUIT"; return 0; }
    if [[ -z "$k" ]]; then _KEY="ENTER"; return 0; fi
    case "$k" in
        $'\r'|$'\n') _KEY="ENTER" ;;
        $'\x1b')
            s=""
            IFS= read -rsn2 -t 1 s
            case "$s" in
                '[A'|'OA') _KEY="UP" ;;
                '[B'|'OB') _KEY="DOWN" ;;
                '')        _KEY="QUIT" ;;
                *)         _KEY="OTHER" ;;
            esac ;;
        [0-9]) _KEY="DIGIT"; _KEYCH="$k" ;;
        k|K)   _KEY="UP" ;;
        j|J)   _KEY="DOWN" ;;
        q|Q)   _KEY="QUIT" ;;
        *)     _KEY="OTHER" ;;
    esac
    return 0
}

# ask_confirm "question" [Y|N]  ->  exit 0 for yes, 1 for no
ask_confirm() {
    local q="$1" def="${2:-N}" hint reply
    if [[ -n "${ASSUME_YES:-}" ]]; then return 0; fi
    if [[ ! -t 0 ]]; then [[ "$def" == "Y" ]]; return $?; fi
    if [[ "$def" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
    _log_line "$QOL_STEP" ASK "$q" >&2
    printf '    %s❯%s %s[%s]%s ' "$QOL_PASS" "$QOL_RESET" "$QOL_META" "$hint" "$QOL_RESET" >&2
    read -r reply
    reply="${reply:-$def}"
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ask_value "question" "default" ["hint"]  ->  echoes the answer
ask_value() {
    local q="$1" def="$2" hint="${3:-}" reply
    if [[ -n "${ASSUME_YES:-}" || ! -t 0 ]]; then printf '%s' "$def"; return 0; fi
    _log_line "$QOL_STEP" ASK "$q" >&2
    [[ -n "$hint" ]] && printf '         %s%s%s\n' "$QOL_META" "$hint" "$QOL_RESET" >&2
    printf '    %s❯%s [%s%s%s] ' "$QOL_PASS" "$QOL_RESET" "$QOL_PASS" "$def" "$QOL_RESET" >&2
    read -r reply
    printf '%s' "${reply:-$def}"
}

# Draw the choice list. Emits exactly (count + 3) lines so the caller knows
# how far to move the cursor back up when redrawing.
_ask_choice_draw() {
    local heading="$1" sel="$2"; shift 2
    local i=0 item label hint plain pad cols
    cols="$(_term_cols)"
    printf '\n %s%s%s%s\n' "$QOL_BOLD" "$QOL_STEP" "$heading" "$QOL_RESET"
    for item in "$@"; do
        label="${item%%|*}"
        hint="${item#*|}"; [[ "$hint" == "$item" ]] && hint=""
        # Pad every row out to the full width with real spaces. The selection
        # bar has to reach the right edge, and CLR_EOL cannot carry it there:
        # screen and tmux report no `bce`, so ESC[K erases to the default
        # background and cuts the bar off where the text ended. Padding the
        # unselected rows is what paints over the bar as it moves away.
        # Three leading columns in both branches: " ❯ " when selected, three
        # spaces when not. Measure the same shape the row actually prints.
        printf -v plain '   %2d   %-18s %s' "$(( i + 1 ))" "$label" "$hint"
        pad=$(( cols - ${#plain} ))
        (( pad < 0 )) && pad=0
        if (( i == sel )); then
            printf '%s%s%s ❯ %2d   %-18s %s%*s%s\n' \
                "$QOL_SEL" "$QOL_BOLD" "$QOL_PASS" "$(( i + 1 ))" "$label" "$hint" \
                "$pad" '' "$QOL_RESET"
        else
            printf '   %s%2d%s   %s%-18s%s %s%s%s%*s\n' \
                "$QOL_META" "$(( i + 1 ))" "$QOL_RESET" \
                "$QOL_FG" "$label" "$QOL_RESET" "$QOL_META" "$hint" "$QOL_RESET" \
                "$pad" ''
        fi
        i=$(( i + 1 ))
    done
    printf ' %s↑/↓%s or %sj/k%s move   %s1-9%s jump   %s⏎%s select\n' \
        "$QOL_PASS" "$QOL_RESET" "$QOL_PASS" "$QOL_RESET" \
        "$QOL_PASS" "$QOL_RESET" "$QOL_PASS" "$QOL_RESET"
}

# ask_choice "HEADING" default_index "label|hint" [...]  ->  echoes 1-based index
# Redraws in place rather than taking the alternate screen: an installer that
# blanks the scrollback has destroyed the record of what it just did.
ask_choice() {
    local heading="$1" def="$2"; shift 2
    local n=$#
    local sel=$(( def - 1 ))
    if [[ -n "${ASSUME_YES:-}" || ! -t 0 ]]; then printf '%s' "$def"; return 0; fi
    _ask_choice_draw "$heading" "$sel" "$@" >&2
    while true; do
        _read_key
        case "$_KEY" in
            ENTER) break ;;
            QUIT)  sel=$(( def - 1 )); break ;;
            UP)    sel=$(( (sel - 1 + n) % n )) ;;
            DOWN)  sel=$(( (sel + 1) % n )) ;;
            DIGIT) if (( 10#$_KEYCH >= 1 && 10#$_KEYCH <= n )); then sel=$(( 10#$_KEYCH - 1 )); fi ;;
        esac
        printf '\033[%dA' $(( n + 3 )) >&2
        _ask_choice_draw "$heading" "$sel" "$@" >&2
    done
    printf '%s' "$(( sel + 1 ))"
}
# ‒‒ end theme block

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                        SAFETY
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
handle_ctrl_c() {
    echo
    log_err "Interrupted. Nothing further was installed."
    log_next "Run this script again when you are ready; it picks up where it stopped."
    exit 130
}

handle_err() {
    local exit_code=$?
    log_err "Failed at line $1 (exit $exit_code)."
    log_err "Note that line number and what the last STEP line said — worth"
    log_err "having if you search for the error or file a bug."
    exit "$exit_code"
}

cleanup_scratch() {
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH"
    return 0
}

check_for_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        log_err "Do not run this as root or with sudo."
        log_err "Run it as yourself: ./bootstrap.sh"
        exit 1
    fi
}

trap handle_ctrl_c INT
trap 'handle_err $LINENO' ERR
trap cleanup_scratch EXIT

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                     ARGUMENTS
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
usage() {
    cat <<'USAGE'
bootstrap.sh — take a factory-fresh Mac to a working toolchain, then run the
student-setup engine.

Usage:  ./bootstrap.sh [flags]

  --mirror <url>     Where the release assets are
                     (default this build's GitHub Release). An address given
                     here is used as typed: it answers, or the run stops. It
                     is also passed on to the engine, which otherwise uses
                     the addresses the Profile names.
  --direct           Fetch Homebrew's installer from brew.sh instead of the
                     Release, and run the engine with --direct so the rest of
                     the setup does the same. For fetching the tool tarball
                     from somewhere other than GitHub Releases. The tarball
                     still needs --tool-url.
  --tool-url <url>   Fetch this exact tarball instead of building the address
                     from --mirror and --version
  --version <v>      Which published build to fetch
  --python <v>       Which interpreter to pin (default 3.12)
  --profile <name>   Which Profile the engine runs (default takehome-core)
  --dest <dir>       Where to unpack the tool (default ~/student-setup)
  --no-run           Stop after unpacking and print the command instead of
                     handing off to the engine
  --yes              Do not ask before starting
  -h, --help         This message

Most flags have an environment equivalent, and the flag wins where both are
set: STUDENT_SETUP_MIRROR, STUDENT_SETUP_VERSION, STUDENT_SETUP_PYTHON,
STUDENT_SETUP_MACOS_MINIMUM,
STUDENT_SETUP_PROFILE, STUDENT_SETUP_DEST, ASSUME_YES. --direct and
--tool-url have none: pointing this script somewhere other than the Release
should be a decision someone typed.

STUDENT_SETUP_BREW_PREFIX moves where Homebrew is looked for, and
STUDENT_SETUP_CLT_TIMEOUT, _CLT_POLL and _CLT_NARRATE_EVERY change how long
it waits on the Command Line Tools window. Neither has a flag; both exist so
an unusual machine and the test harness do not need a second copy of this
script. STUDENT_SETUP_MIRROR_TIMEOUT moves how long the mirror is given to
answer before the run stops. There is no second address to fall back to,
unlike a mirror with a DNS name and an Ethernet fallback behind it.
USAGE
}

# A flag typed without its value has to say so. Without this the `shift 2`
# below fails on a one-element list and `set -e` kills the run before any
# usage error is printed — the student gets an empty screen and an exit code.
need_value() {
    if [[ $# -lt 2 ]]; then
        log_err "$1 needs a value after it."
        usage >&2
        exit 2
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mirror)    need_value "$@"; MIRROR="$2"; MIRROR_EXPLICIT=1; shift 2 ;;
            --direct)    USE_MIRROR=0; shift ;;
            --tool-url)  need_value "$@"; TOOL_URL="$2"; shift 2 ;;
            --version)   need_value "$@"; TOOL_VERSION="$2"; shift 2 ;;
            --python)    need_value "$@"; PYTHON_VERSION="$2"; shift 2 ;;
            --profile)   need_value "$@"; PROFILE="$2"; shift 2 ;;
            --dest)      need_value "$@"; DEST="$2"; shift 2 ;;
            --no-run)    RUN_ENGINE=0; shift ;;
            --yes)       ASSUME_YES=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)
                log_err "Unknown option: $1"
                usage >&2
                exit 2
                ;;
        esac
    done

    if (( ! USE_MIRROR )) && [[ -z "$TOOL_URL" ]]; then
        log_err "--direct has no Release to fetch the tool from."
        log_err "Add --tool-url <url> naming the tarball to download."
        exit 2
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                 PREREQUISITES
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
require_apple_silicon() {
    if [[ "$OS" != "Darwin" ]]; then
        log_err "This runs on macOS. This machine reports $OS."
        exit 1
    fi
    if [[ "$ARCH" != "arm64" ]]; then
        log_err "This runs on Apple Silicon. This machine reports $ARCH."
        log_err "Homebrew installs to a different prefix on Intel, and no Intel"
        log_err "path is supported. This tool needs an Apple Silicon Mac."
        exit 1
    fi
    log_ok "This is an Apple Silicon Mac running macOS."
}

# Is $1 at least $2? `versions.meets_floor` written a second time in bash,
# because this runs before a single line of the Python exists. A shorter
# version is the same version with zeroes after it, so `26.5` is `26.5.0`
# and sits below `26.5.1`. Anything that is not a dotted number is not new
# enough: unreadable must never pass for current. `10#` so a zero-padded
# field is read as decimal rather than octal.
version_meets() {
    local found="$1" floor="$2"
    local -a have want
    local index left right

    if [[ ! "$found" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        return 1
    fi
    if [[ ! "$floor" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        return 1
    fi

    IFS=. read -r -a have <<< "$found"
    IFS=. read -r -a want <<< "$floor"

    for (( index = 0; index < ${#have[@]} || index < ${#want[@]}; index++ )); do
        left="${have[index]:-0}"
        right="${want[index]:-0}"
        if (( 10#$left > 10#$right )); then
            return 0
        fi
        if (( 10#$left < 10#$right )); then
            return 1
        fi
    done

    return 0
}

# The height requirement: you must be at least this macOS to ride. Said
# before anything is installed, so a student who has to upgrade learns it
# while their machine is still untouched. It names the version found, the
# version needed and the menu that fixes it, because a refusal carrying two
# numbers and no remedy is a dead end — that is what the first class run
# walked into. This never runs the upgrade itself: that is the student's
# choice, their bandwidth and their reboot.
require_macos_floor() {
    local found
    found="$(sw_vers -productVersion 2>/dev/null || true)"

    if version_meets "$found" "$MACOS_MINIMUM"; then
        log_ok "This Mac runs macOS $found."
        return 0
    fi

    log_err "This tool needs macOS $MACOS_MINIMUM or newer."
    if [[ -n "$found" ]]; then
        log_err "This Mac runs macOS $found."
    else
        log_err "This Mac did not report a macOS version."
    fi
    log_err "Update it in System Settings > General > Software Update, then"
    log_err "run this again. Nothing has been installed, and nothing on this"
    log_err "Mac has been changed."
    exit 1
}

# Homebrew's installer needs a password to create its prefix. Asking here,
# narrated, rather than letting the installer surprise the student mid-run:
# the Plan promises one password prompt near the start, and this is it.
take_password() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    log_ask "macOS needs your password so Homebrew can create $BREW_PREFIX."
    log_info "It is your Mac login password. Nothing is stored and nothing"
    log_info "leaves this machine; macOS holds the permission for a few minutes."
    sudo -v
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                DOWNLOADING (verified, never piped to a shell)
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# One place that touches the network, so there is one place to read if a
# download is what went wrong.
fetch() {
    local url="$1" into="$2"
    curl -fsSL --retry 3 --retry-delay 2 -o "$into" "$url"
}

# A miss is an answer here, not a failure — the caller decides what an absent
# file means. The `|| return 1` keeps curl's exit off the ERR trap.
fetch_optional() {
    local url="$1" into="$2"
    curl -fsSL --retry 2 -o "$into" "$url" 2>/dev/null || return 1
}

# Is anything answering at this address? A HEAD, and any HTTP answer counts:
# a server that refuses the method has still proved it is there. No `-f`, so
# a 404 reads as "the host is up" rather than "no mirror". `|| return 1`
# keeps curl's exit off the ERR trap.
mirror_answers() {
    curl -sS --max-time "$MIRROR_TIMEOUT" -o /dev/null -I "$1" >/dev/null 2>&1 || return 1
}

# Pick the address the rest of this run fetches from.
#
# A public release has one origin, not a name with a zone behind it and an
# Ethernet fallback if the zone is down. There is no second suffix to try here
# — only whether the one address answers. This is the half that has to happen
# before an engine exists, because the two fetches it covers — this script's
# own tarball and Homebrew's installer — are the first two of the run.
#
# The Profile is a separate matter: `takehome-core.toml` names no `[mirror]`,
# so once the engine exists it resolves DIRECT on its own — there is no pair
# here for it to agree with.
#
# An address someone typed is a decision, so `--mirror` is never second-
# guessed: it answers or the run stops.
resolve_mirror() {
    (( USE_MIRROR )) || return 0

    if mirror_answers "$MIRROR"; then
        log_ok "The mirror answered at $MIRROR."
        return 0
    fi

    if [[ -n "$MIRROR_EXPLICIT" ]]; then
        log_err "The mirror did not answer at $MIRROR."
        log_err "You named that address yourself, so nothing else was tried."
        exit 1
    fi

    # No fallback to try, unconditionally: a public release has one origin,
    # so a miss on the default is the whole answer, not a retry. `exit`, not
    # `return` — this is the last statement in the function, so a bare
    # `return 1` would surface as the generic ERR-trap message from
    # `handle_err` rather than the specific reason printed below.
    log_err "$MIRROR did not answer."
    log_err "Check your network connection, then try again. If it still"
    log_err "does not answer, confirm a release exists for $TOOL_VERSION at"
    log_err "https://github.com/itdojo/mac-setup/releases."
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# Compare what arrived against what was published, and refuse on a mismatch.
# Both digests are printed: a student who has to report what went wrong
# should not have to re-derive either one. Sets VERIFIED_SHA256.
VERIFIED_SHA256=""
verify_sha256() {
    local file="$1" expected="$2" what="$3" actual
    actual="$(sha256_of "$file")"
    VERIFIED_SHA256="$actual"
    log_info "sha256  $actual"

    if [[ -z "$expected" ]]; then
        log_warn "No published sha256 for $what; there is nothing to check it against."
        return 0
    fi
    if [[ "$actual" != "$expected" ]]; then
        log_err "$what does not match its published sha256."
        log_err "  expected  $expected"
        log_err "  received  $actual"
        log_err "Nothing was unpacked and nothing was installed from it. Try"
        log_err "running this again — a corrupted download is the common cause."
        exit 1
    fi
    log_ok "$what matches its published sha256."
}

tool_url() {
    if [[ -n "$TOOL_URL" ]]; then
        printf '%s\n' "$TOOL_URL"
        return 0
    fi
    # An empty TOOL_PATH is this build's case: GitHub Releases assets are
    # flat (`<tag>/<asset-name>`, no directory in between), so joining the
    # mirror and the filename directly is what a real asset URL looks like.
    # A build whose mirror nests the tarball under a path segment sets a
    # non-empty TOOL_PATH and takes the branch below instead — this build's
    # Release assets sit flat, so it never does.
    if [[ -n "$TOOL_PATH" ]]; then
        printf '%s/%s/student-setup-%s.tar.gz\n' "$MIRROR" "$TOOL_PATH" "$TOOL_VERSION"
    else
        printf '%s/student-setup-%s.tar.gz\n' "$MIRROR" "$TOOL_VERSION"
    fi
}

homebrew_installer_url() {
    if (( USE_MIRROR )); then
        printf '%s/%s\n' "$MIRROR" "$HOMEBREW_INSTALLER_PATH"
    else
        printf '%s\n' "$HOMEBREW_INSTALLER_UPSTREAM"
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                   XCODE COMMAND LINE TOOLS — MUST HAPPEN BEFORE ANYTHING ELSE
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Selected and present, which are two different questions. `xcode-select -p`
# still names a directory on a machine whose tools have been deleted, and a
# re-run has to notice that rather than trust the answer.
#
# The `|| true` is inside the substitution, not after it. A `$(...)` runs in
# a subshell which inherits the ERR trap, so a probe that answers "no" — the
# ordinary state of a factory Mac — would otherwise print a STOP line for a
# question that was answered rather than a failure. Every probe below that
# can legitimately fail is written the same way, for the same reason.
clt_installed() {
    local path
    path="$(xcode-select -p 2>/dev/null || true)"
    [[ -n "$path" && -d "$path" ]]
}

# `xcode-select --install` exits non-zero when the tools are already there and
# when its window is already open. Neither is a failure worth stopping for, so
# the exit code is discarded and `clt_installed` is what decides.
ensure_clt() {
    if clt_installed; then
        log_ok "The Xcode Command Line Tools are already installed."
        ALREADY_PRESENT+=("command-line-tools")
        return 0
    fi

    log_step "Installing the Xcode Command Line Tools..."
    log_info "macOS opens its own window for this one. Click Install and accept"
    log_info "the licence; this script waits for it and continues on its own."
    xcode-select --install >/dev/null 2>&1 || true

    # macOS opens the installer behind whichever window started it, and on
    # 2026-08-24 a room of students read that as a hung script. `open -a` is
    # not an Apple Event, so it raises no TCC automation prompt; `osascript`
    # would, and the 2026-08-14 terminal-font decision rejected exactly that.
    # Failure here is cosmetic, so it never stops the run.
    open -a "Install Command Line Developer Tools" >/dev/null 2>&1 || true

    wait_for_clt
    INSTALLED+=("command-line-tools")
    log_ok "The Xcode Command Line Tools are installed."
}

wait_for_clt() {
    local waited=0
    while ! clt_installed; do
        if (( waited >= CLT_TIMEOUT )); then
            log_err "The Command Line Tools did not finish within $(( CLT_TIMEOUT / 60 )) minutes."
            log_err "If you closed the installer window, run this script again."
            exit 1
        fi
        sleep "$CLT_POLL"
        waited=$(( waited + CLT_POLL ))
        if (( waited % CLT_NARRATE_EVERY == 0 )); then
            log_info "Still waiting for the Command Line Tools ($(( waited / 60 )) min)."
        fi
    done
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                             HOMEBREW — MUST HAPPEN BEFORE ANYTHING CALLS BREW
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Where brew is, or nothing. Always succeeds — "it is not installed" is an
# answer, and a non-zero exit out of a `$(...)` would reach the ERR trap.
brew_command() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
    elif [[ -x "$BREW_PREFIX/bin/brew" ]]; then
        printf '%s\n' "$BREW_PREFIX/bin/brew"
    fi
}

ensure_homebrew() {
    local brew
    brew="$(brew_command)"
    if [[ -n "$brew" ]]; then
        log_ok "Homebrew is already installed."
        ALREADY_PRESENT+=("homebrew")
    else
        install_homebrew
        brew="$(brew_command)"
        if [[ -z "$brew" ]]; then
            log_err "Homebrew's installer finished but left no brew executable."
            log_err "Nothing further can be installed. Check the output above"
            log_err "for what Homebrew's own installer reported, then retry."
            exit 1
        fi
        INSTALLED+=("homebrew")
        log_ok "Homebrew is installed."
    fi

    # This shell, and every later login shell.
    eval "$("$brew" shellenv)"
    ensure_shellenv_block "$brew"
}

# Downloaded to a file, digest printed, then run from disk. Not piped: the
# whole project rules out `curl | bash`, and Homebrew's installer is the one
# place where the temptation is strongest.
install_homebrew() {
    local installer digest expected=""
    installer="$SCRATCH/homebrew-install.sh"
    digest="$SCRATCH/homebrew-install.sh.sha256"

    log_step "Fetching Homebrew's installer..."
    fetch "$(homebrew_installer_url)" "$installer"
    if fetch_optional "$(homebrew_installer_url).sha256" "$digest"; then
        expected="$(awk '{print $1}' "$digest")"
    fi

    # A missing digest is fatal here, not a warning, because this is the
    # verified path: `--mirror` can be pointed at anything, and continuing
    # without a digest would make an unverified fetch indistinguishable from
    # a checked one. Only `--direct` may go unverified, because brew.sh
    # publishes no digest to check against.
    if (( USE_MIRROR )) && [[ -z "$expected" ]]; then
        log_err "The mirror published no sha256 beside Homebrew's installer."
        log_err "Nothing will be run from it. This release is missing a file"
        log_err "it should publish — worth filing as a bug."
        exit 1
    fi

    verify_sha256 "$installer" "$expected" "Homebrew's installer"
    log_info "It is on disk at $installer if you want to read it first."

    take_password
    log_step "Installing Homebrew..."
    NONINTERACTIVE=1 bash "$installer"
}

# A sentinel-fenced block, because a block without markers cannot be removed
# cleanly later and hand-editing a dotfile is the recovery nobody wants.
ensure_shellenv_block() {
    local brew="$1"

    if [[ -f "$SHELL_PROFILE" ]] && grep -qF "$SENTINEL_OPEN" "$SHELL_PROFILE"; then
        log_ok "$SHELL_PROFILE already points at Homebrew."
        return 0
    fi

    backup_once "$SHELL_PROFILE"
    # SC2016: the `$(...)` is written to the file literally on purpose. It is
    # the login shell that must evaluate it, at every login, not this script
    # once — a baked-in PATH goes stale the moment Homebrew moves.
    # shellcheck disable=SC2016
    {
        printf '\n%s\n' "$SENTINEL_OPEN"
        printf 'eval "$(%s shellenv)"\n' "$brew"
        printf '%s\n' "$SENTINEL_CLOSE"
    } >> "$SHELL_PROFILE"
    log_ok "$SHELL_PROFILE now points at Homebrew."
}

# One backup, ever, timestamped, never clobbering an earlier one.
backup_once() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if ls "$file".prebootstrap.* >/dev/null 2>&1; then
        return 0
    fi
    cp "$file" "$file.prebootstrap.$(date +%Y%m%d-%H%M%S)"
    log_info "Copied $file aside before editing it."
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                 UV AND THE PINNED INTERPRETER
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# From Homebrew, not from `curl … | sh`. Homebrew exists by this point, and
# the piped installer is the shape this project has ruled out everywhere.
ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        log_ok "uv is already installed."
        ALREADY_PRESENT+=("uv")
        return 0
    fi

    log_step "Installing uv..."
    brew install uv
    INSTALLED+=("uv")
    log_ok "uv is installed."
}

# One machine still needs the exact interpreter this project tested against,
# not whatever Homebrew's python3 formula currently resolves to — that formula
# moves on its own schedule, on nobody's review here. uv's own build rather
# than Homebrew's python3, so the version is the tool's to pin and not
# Homebrew's to move.
ensure_interpreter() {
    if uv python find "$PYTHON_VERSION" >/dev/null 2>&1; then
        log_ok "Python $PYTHON_VERSION is already installed."
        ALREADY_PRESENT+=("python-$PYTHON_VERSION")
        return 0
    fi

    log_step "Installing Python $PYTHON_VERSION..."
    uv python install "$PYTHON_VERSION"
    log_ok "Python $PYTHON_VERSION is installed."
    INSTALLED+=("python-$PYTHON_VERSION")
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                               THE TOOL ITSELF
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
fetch_tool() {
    local url tarball digest expected=""
    url="$(tool_url)"
    tarball="$SCRATCH/student-setup-$TOOL_VERSION.tar.gz"
    digest="$tarball.sha256"

    # The published digest is fetched before the standing unpack is judged,
    # because `already_unpacked` runs before any download and so has nothing
    # fresh to compare against. It is a 64-byte file and costs nothing.
    if fetch_optional "$url.sha256" "$digest"; then
        expected="$(awk '{print $1}' "$digest")"
    fi

    if already_unpacked "$expected"; then
        return 0
    fi

    log_step "Fetching student-setup $TOOL_VERSION..."
    log_info "from $url"
    fetch "$url" "$tarball"

    if [[ -z "$expected" ]]; then
        log_err "No sha256 was published beside $url."
        log_err "The download cannot be checked, so nothing will be unpacked."
        log_err "This release is missing a file it should publish — worth"
        log_err "filing as a bug."
        exit 1
    fi

    verify_sha256 "$tarball" "$expected" "student-setup $TOOL_VERSION"
    TARBALL_SHA256="$VERIFIED_SHA256"
    TOOL_SOURCE="$url"
    unpack_tool "$tarball"
}

# The build marker is what makes a re-run cheap and a version change safe.
# It records what is standing in DEST now, so this run can tell "the same
# build is already here" from "a different one is, and it is not mine to
# delete".
#
# The digest decides, not the version string. Until 2026-08-28 only the
# version was compared, so a re-cut tarball published at an unchanged version
# left the old tree standing and then reported the old digest in the handoff
# — a sha256 attesting bytes nothing had checked. The published digest is
# fetched before this is called; it is a 64-byte file and costs nothing.
already_unpacked() {
    local published="$1"
    local marker="$DEST/.student-setup-build"
    [[ -f "$marker" ]] || return 1
    grep -qxF "version=$TOOL_VERSION" "$marker" || return 1

    local recorded
    recorded="$(awk -F= '/^sha256=/ {print $2}' "$marker")"
    if [[ -n "$published" && "$recorded" != "$published" ]]; then
        log_warn "A different build of $TOOL_VERSION is unpacked at $DEST."
        log_info "  standing  $recorded"
        log_info "  published $published"
        return 1
    fi

    log_ok "student-setup $TOOL_VERSION is already unpacked at $DEST."
    TARBALL_SHA256="$recorded"
    TOOL_SOURCE="$(awk -F= '/^source=/ {print substr($0, index($0, "=") + 1)}' "$marker")"
    return 0
}

unpack_tool() {
    local tarball="$1" staging root

    staging="$SCRATCH/unpack"
    mkdir -p "$staging"
    tar -xzf "$tarball" -C "$staging"

    root="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -z "$root" ]]; then
        log_err "The tarball unpacked to no directory. It is not a build of this tool."
        exit 1
    fi

    displace_existing
    mkdir -p "$(dirname "$DEST")"
    mv "$root" "$DEST"
    {
        printf 'version=%s\n' "$TOOL_VERSION"
        printf 'sha256=%s\n' "$TARBALL_SHA256"
        printf 'source=%s\n' "$TOOL_SOURCE"
    } > "$DEST/.student-setup-build"
    log_ok "student-setup $TOOL_VERSION is unpacked at $DEST."
}

# A different build is standing where this one goes. It is moved aside, never
# deleted: no operation in this project may cost a student work, and whatever
# they put in that directory is theirs.
displace_existing() {
    local aside
    [[ -e "$DEST" ]] || return 0
    aside="$DEST.pre-$TOOL_VERSION.$(date +%Y%m%d-%H%M%S)"
    mv "$DEST" "$aside"
    log_warn "$DEST already existed. It was moved to $aside, not deleted."
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                     THE HANDOFF TO THE ENGINE
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# The engine did not exist while any of the work above happened, so it cannot
# have recorded it. This is how it finds out: the `bootstrap` Module reads
# this file on the first run and turns it into Ledger records, which is what
# lets a Receipt name the build that produced the machine.
write_handoff() {
    local installed already
    installed="$(merged_entries installed ${INSTALLED[@]+"${INSTALLED[@]}"})"
    already="$(merged_entries already_present ${ALREADY_PRESENT[@]+"${ALREADY_PRESENT[@]}"})"
    already="$(printf '%s\n' "$already" | without "$installed")"

    mkdir -p "$HANDOFF_DIR"
    cat > "$HANDOFF" <<JSON
{
  "tool_version": $(json_string "$TOOL_VERSION"),
  "tarball": $(json_string "student-setup-$TOOL_VERSION.tar.gz"),
  "tarball_sha256": $(json_string "$TARBALL_SHA256"),
  "source": $(json_string "$TOOL_SOURCE"),
  "mirror": $(json_string "$(mirror_recorded)"),
  "bootstrapped_at": $(json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),
  "python_version": $(json_string "$PYTHON_VERSION"),
  "shell_profile": $(json_string "$SHELL_PROFILE"),
  "installed": $(printf '%s\n' "$installed" | json_array_of_lines),
  "already_present": $(printf '%s\n' "$already" | json_array_of_lines)
}
JSON
    log_ok "What this bootstrap did is recorded in $HANDOFF."
}

# `INSTALLED` and `ALREADY_PRESENT` describe this run only, and the handoff
# has to outlive it. Without the merge below, a second run rewrites "the tool
# installed Homebrew" as "the machine came with Homebrew" — which is the one
# distinction the record exists to make, and the one the reversal steps are
# generated from. Re-running is the documented path, so this is the common
# case rather than an edge.
#
# `prior_entries` reads back an array this script itself wrote, in a layout
# this script fixes three lines above. It is not general JSON parsing and must
# not be made into any.
prior_entries() {
    local key="$1"
    [[ -f "$HANDOFF" ]] || return 0
    sed -n "s/^  \"$key\": \[\(.*\)\],\{0,1\}\$/\1/p" "$HANDOFF" \
        | tr ',' '\n' \
        | tr -d '" '
}

# Everything this key has ever held, plus what this run adds. First-seen order.
merged_entries() {
    local key="$1"
    shift
    {
        prior_entries "$key"
        # An `if`, not `[[ … ]] &&`: an empty list is the ordinary case on a
        # factory machine, and a compound that ends non-zero is what `set -e`
        # kills the run for.
        if [[ $# -gt 0 ]]; then
            printf '%s\n' "$@"
        fi
    } | awk 'NF && !seen[$0]++'
}

# Drop the lines named in the argument. Anything this tool ever installed is
# not something the machine came with, however a later run finds it sitting
# there.
without() {
    awk 'NR == FNR { drop[$0] = 1; next } NF && !($0 in drop)' \
        <(printf '%s\n' "$1") -
}

mirror_recorded() {
    if (( USE_MIRROR )); then
        printf '%s\n' "$MIRROR"
    fi
}

json_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

# A newline-separated list as a JSON array. Blank input is `[]`, which is a
# positive claim — "this run installed nothing" — and not the same as the key
# being absent.
json_array_of_lines() {
    awk '
        NF {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            items[n++] = "\"" $0 "\""
        }
        END {
            out = ""
            for (i = 0; i < n; i++) out = out (i ? ", " : "") items[i]
            printf "[%s]", out
        }'
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                          MAIN
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
announce() {
    log_info "This installs, in order:"
    log_info "  the Xcode Command Line Tools, Homebrew, uv, Python $PYTHON_VERSION,"
    log_info "  then student-setup $TOOL_VERSION itself, checked against its sha256."
    log_info "If it has to install Homebrew, it asks for your password once."
    log_info "It edits one file of yours, $SHELL_PROFILE, in a marked block, and"
    log_info "copies it aside first."
    if (( RUN_ENGINE )); then
        log_info "It then hands off to the tool, which shows you its Plan before"
        log_info "it changes anything else."
    fi
}

main() {
    parse_args "$@"

    banner "STUDENT-SETUP BOOTSTRAP" "$TOOL_VERSION"
    check_for_root
    require_apple_silicon
    require_macos_floor
    announce
    if ! ask_confirm "Start?" Y; then
        log_ok "Nothing was installed."
        echo
        exit 0
    fi

    SCRATCH="$(mktemp -d)"
    resolve_mirror

    log_phase "TOOLCHAIN"
    ensure_clt
    ensure_homebrew
    ensure_uv
    ensure_interpreter

    log_phase "THE TOOL"
    fetch_tool
    write_handoff

    log_complete "BOOTSTRAP COMPLETE"

    if (( RUN_ENGINE )); then
        log_phase "SETUP"
        log_info "Handing off to student-setup. Everything from here is recorded"
        log_info "in the Ledger and appears in your Receipt."
        echo
        cleanup_scratch
        cd "$DEST" || exit 1
        # Only a choice someone actually typed crosses to the engine:
        # `--direct` if that is what was typed, `--mirror $MIRROR` if that is
        # what was typed, and neither flag otherwise. This script's own
        # default Release address is not the engine's business — the same rule
        # `MIRROR_EXPLICIT` already enforces above. With nothing typed,
        # `takehome-core.toml` names no `[mirror]` either, so the engine
        # resolves DIRECT on its own; there is no pair of addresses here for
        # it to agree with.
        engine_args=(apply --profile "profiles/$PROFILE.toml")
        if (( ! USE_MIRROR )); then
            engine_args+=(--direct)
        elif [[ -n "$MIRROR_EXPLICIT" ]]; then
            engine_args+=(--mirror "$MIRROR")
        fi
        exec uv run student-setup "${engine_args[@]}"
    fi

    log_next "Read what the tool will do:"
    log_next "  cd $DEST && uv run student-setup plan --profile profiles/$PROFILE.toml"
    log_next "Then run it:"
    log_next "  uv run student-setup apply --profile profiles/$PROFILE.toml"
    echo
}

main "$@"
