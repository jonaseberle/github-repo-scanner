# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: Log file, messages to the terminal and the progress line.

# Prepare the log file and keep it below LOG_MAX_BYTES.
# Short options only: BSD wc, tail and mkdir (macOS) have no long options.
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(wc -c < "$LOG_FILE")
        if [[ $size -ge $LOG_MAX_BYTES ]]; then
            # Drop the first line: the cut can be in the middle of it.
            tail -c $((size / 2)) "$LOG_FILE" | sed '1d' >| "$LOG_FILE.tmp.$$"
            mv -f "$LOG_FILE.tmp.$$" "$LOG_FILE"
            log INFO "Log was $size bytes: cut to the newer half."
        fi
    fi
}

# Arguments: severity (DEBUG, INFO, WARN, ERROR), message.
# One line per message: time (UTC), process id, severity, message.
log() {
    local severity="$1"
    shift
    local message="$*"
    message="${message//$'\n'/ }"
    if [[ $LOG_TIME_BUILTIN -eq 1 ]]; then
        # A TZ for this command only: "local TZ" does not change the time zone.
        TZ=UTC printf -v LOG_TIME '%(%Y-%m-%dT%H:%M:%S)T' -1
    elif [[ $SECONDS -ne $LOG_TIME_SECOND ]]; then
        # Short option: BSD date (macOS) has no --utc.
        LOG_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S')
        LOG_TIME_SECOND=$SECONDS
    fi
    printf '%s [%s] %-5s %s\n' "$LOG_TIME" "$$" "$severity" "$message" >> "$LOG_FILE"
}

print_error() {
    log ERROR "$1"
    # The progress line has no line break at its end.
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        echo "" >&2
    fi
    printf '%s\n' "${RED}Error: $1${NC}" >&2
}

# A warning during the scan, on stderr: the caller may capture stdout.
print_warning_line() {
    log WARN "$1"
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        echo "" >&2
    fi
    printf '%s\n' "${YELLOW}Warning: $1${NC}" >&2
}

print_success() {
    printf '%s\n' "${GREEN}$1${NC}"
}

print_info() {
    printf '%s\n' "${BLUE}$1${NC}"
}

print_warning() {
    printf '%s\n' "${YELLOW}$1${NC}"
}

PROGRESS_SHOWN=0

# Arguments: pairs of color and text.
# On stderr and only on a terminal, like the dots: stdout can go to a file.
# Cut the line to the terminal width: a wrapped line is not cleared by "\r".
# Keep room for the dots of the network requests.
print_progress() {
    if [[ ! -t 2 ]]; then
        return 0
    fi
    PROGRESS_SHOWN=1
    local max=$((TERM_COLUMNS - 12)) used=0 out="" color text keep
    while [[ $# -ge 2 ]]; do
        color="$1"
        text="$2"
        shift 2
        if [[ $((used + ${#text})) -gt $max ]]; then
            keep=$((max - used - 3))
            if [[ $keep -lt 0 ]]; then
                keep=0
            fi
            out+="$color${text:0:$keep}...$NC"
            break
        fi
        out+="$color$text$NC"
        used=$((used + ${#text}))
    done
    printf '\r\033[K%s ' "$out" >&2
}

clear_progress() {
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        printf '\r\033[K' >&2
        PROGRESS_SHOWN=0
    fi
}

format_age() {
    local seconds="$1"
    if [[ $seconds -ge 86400 ]]; then
        echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
    elif [[ $seconds -ge 3600 ]]; then
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    elif [[ $seconds -ge 60 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "${seconds}s"
    fi
}
