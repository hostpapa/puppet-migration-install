#!/bin/bash
# install.sh
# Orchestrates the secure validation, retrieval, and execution of the infrastructure bootstrap sequence.
#
# install.sh is a launcher. It does three things:
#   1. validates the GitHub PAT against the REST API,
#   2. downloads bootstrap.sh from the repository,
#   3. invokes bootstrap.sh under sudo with the supplied environment.
# Anything after `--` on the command line is forwarded verbatim to bootstrap.sh.
# install.sh has no knowledge of bootstrap.sh's options and should not be edited
# when those options change.

set -euo pipefail

# --- Default Variables ---
DRY_RUN=false
SHOW_SECRETS=false
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TOKEN_SOURCE=""  # tracks where token came from, for predictable precedence
BOOTSTRAP_ARGS=()  # arguments to forward to bootstrap.sh after `--`
REPO_API_URL="https://api.github.com/repos/hostpapa/puppet-migration/contents/bootstrap.sh"

# --- Helpers ---
usage() {
    cat <<EOF
Usage: $0 [--token <token> | <token>] [--dry-run] [--secrets] [-- <bootstrap args>...]

Options:
  --token <token>   GitHub PAT (overrides positional and env)
  <token>           Positional token (overrides env, but not --token)
  --dry-run         Print the bootstrap command instead of running it
  --secrets         In dry-run mode, print the literal token (use with care)
  --                End of install.sh options. All subsequent arguments are
                    forwarded verbatim to bootstrap.sh.
  -h, --help        Show this help

Token precedence (highest to lowest):
  1. --token flag
  2. Positional argument
  3. GITHUB_TOKEN environment variable

Examples:
  $0 --token ghp_xxx
  $0 --token ghp_xxx -- --priv-key id_ed25519
  $0 --token ghp_xxx -- --save --priv-key id_ed25519
EOF
}

set_token() {
    # $1 = value, $2 = source label, $3 = precedence (higher wins)
    local value="$1" source="$2" precedence="$3"
    local current_precedence=0
    case "$TOKEN_SOURCE" in
        env)        current_precedence=1 ;;
        positional) current_precedence=2 ;;
        flag)       current_precedence=3 ;;
    esac
    if (( precedence >= current_precedence )); then
        GITHUB_TOKEN="$value"
        TOKEN_SOURCE="$source"
    fi
}

[ -n "$GITHUB_TOKEN" ] && TOKEN_SOURCE="env"

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --token)
            if [ -z "${2:-}" ]; then
                echo "Critical: --token requires a value." >&2
                exit 1
            fi
            set_token "$2" "flag" 3
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --secrets)
            SHOW_SECRETS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            # Everything after `--` belongs to bootstrap.sh.
            shift
            BOOTSTRAP_ARGS=("$@")
            break
            ;;
        -*)
            echo "Critical: Unrecognized parameter '$1'. Use '--' to pass options to bootstrap.sh." >&2
            exit 1
            ;;
        *)
            set_token "$1" "positional" 2
            shift
            ;;
    esac
done

# --- Pre-flight Checks ---
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Critical: GitHub authentication token is absent. Provision it via the --token flag, a positional argument, or the GITHUB_TOKEN environment variable." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Critical: 'curl' is required but not installed." >&2
    exit 1
fi

echo "Info: Validating token against the GitHub REST API."
HTTP_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    https://api.github.com/user || echo "000")

if [ "$HTTP_STATUS" = "000" ]; then
    echo "Critical: Could not reach GitHub API (network error)." >&2
    exit 1
elif [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Critical: Token validation failed (HTTP $HTTP_STATUS). Ensure the token is valid and has the required scopes." >&2
    exit 1
fi
echo "Debug: Token successfully authenticated."

# --- Secure Artifact Retrieval ---
TMP_SCRIPT=$(mktemp)
chmod 700 "$TMP_SCRIPT"
# Ensure cleanup on any exit path (success, failure, signal).
trap 'rm -f "$TMP_SCRIPT"' EXIT

echo "Info: Provisioning temporary execution payload at [$TMP_SCRIPT]."

if ! curl -sSL --fail \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3.raw" \
        "$REPO_API_URL" \
        -o "$TMP_SCRIPT"; then
    echo "Critical: Failed to download bootstrap script from $REPO_API_URL." >&2
    exit 1
fi

if [ ! -s "$TMP_SCRIPT" ]; then
    echo "Critical: Downloaded bootstrap script is empty." >&2
    exit 1
fi

# Sanity check: must look like a shell script, not a JSON error blob.
if ! head -n1 "$TMP_SCRIPT" | grep -q '^#!'; then
    echo "Critical: Downloaded payload does not appear to be a shell script (no shebang). Aborting." >&2
    exit 1
fi

echo "Debug: Bootstrap payload retrieved and validated."

# --- Execution Phase ---
if [ "$DRY_RUN" = true ]; then
    # Move the payload to a stable, predictable location so the printed
    # command actually works after this script exits. Disarm the trap
    # so EXIT cleanup doesn't delete the file we just told the user about.
    PERSISTENT_SCRIPT="/tmp/bootstrap-$(date +%Y%m%d-%H%M%S)-$$.sh"
    mv "$TMP_SCRIPT" "$PERSISTENT_SCRIPT"
    chmod 700 "$PERSISTENT_SCRIPT"
    trap - EXIT

    echo "Notice: Dry-run mode engaged. Skipping host-level execution."
    echo "Bootstrap payload preserved at: $PERSISTENT_SCRIPT"
    echo "Execute the following to manually run the bootstrap sequence:"
    echo "----------------------------------------------------------------------"

    # Render forwarded args safely for display. printf '%q' produces a shell-
    # quoted form that the user can paste back without re-quoting.
    rendered_args=""
    if (( ${#BOOTSTRAP_ARGS[@]} > 0 )); then
        rendered_args=" $(printf ' %q' "${BOOTSTRAP_ARGS[@]}")"
    fi

    if [ "$SHOW_SECRETS" = true ]; then
        echo "Warning: token is shown in clear text below. Do not paste this anywhere shared." >&2
        if [ "$EUID" -eq 0 ]; then
            echo "GITHUB_TOKEN='$GITHUB_TOKEN' $PERSISTENT_SCRIPT$rendered_args"
        else
            echo "sudo GITHUB_TOKEN='$GITHUB_TOKEN' $PERSISTENT_SCRIPT$rendered_args"
        fi
    else
        if [ "$EUID" -eq 0 ]; then
            echo "GITHUB_TOKEN=\"\$GITHUB_TOKEN\" $PERSISTENT_SCRIPT$rendered_args"
        else
            echo "sudo -E GITHUB_TOKEN=\"\$GITHUB_TOKEN\" $PERSISTENT_SCRIPT$rendered_args"
        fi
    fi
    echo "----------------------------------------------------------------------"
    echo "When finished, remove the payload: rm -f $PERSISTENT_SCRIPT"
    exit 0
fi

echo "Info: Initiating the primary infrastructure bootstrap sequence."
# Caller is either already root (some hosts have sudo disabled — e.g. a
# Puppet-managed nsswitch.conf with `sudoers: sss` and no central rule for
# root) or a regular user who needs sudo escalation. Branch accordingly.
#
# In both branches the token is passed via the environment, not argv, to
# keep it out of `ps` output, sudo's audit log, and shell history. Any
# post-`--` arguments are forwarded verbatim to bootstrap.sh.
if [ "$EUID" -eq 0 ]; then
    echo "Notice: Running as root; invoking bootstrap directly without sudo."
    GITHUB_TOKEN="$GITHUB_TOKEN" "$TMP_SCRIPT" "${BOOTSTRAP_ARGS[@]}"
else
    sudo GITHUB_TOKEN="$GITHUB_TOKEN" "$TMP_SCRIPT" "${BOOTSTRAP_ARGS[@]}"
fi

echo "Info: Bootstrap sequence completed; temporary artifacts will be purged on exit."