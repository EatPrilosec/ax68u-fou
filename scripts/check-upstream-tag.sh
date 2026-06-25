#!/bin/bash
# check-upstream-tag.sh — Query the Merlin repo for the latest 3004.388.x tag
# and compare it against our repo's latest release.
#
# Outputs (GitHub Actions):
#   should_build=true|false
#   upstream_tag=<tag_name>
#
# Environment:
#   GITHUB_TOKEN       — (optional) GitHub token for higher API rate limits
#   GITHUB_OUTPUT      — GitHub Actions output file
#   GITHUB_EVENT_NAME  — "workflow_dispatch" forces should_build=true

set -euo pipefail

readonly UPSTREAM_REPO="RMerl/asuswrt-merlin.ng"
readonly OWN_REPO="${GITHUB_REPOSITORY:-}"
readonly TAG_PATTERN="^3004\.388\."
readonly API_BASE="https://api.github.com"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "::notice::$*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; >&2 echo "ERROR: $*"; }

# Authenticated curl wrapper with retry logic
gh_api() {
    local url="$1"
    local attempt=0
    local auth_header=()

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    while (( attempt < MAX_RETRIES )); do
        attempt=$((attempt + 1))
        local http_code
        local response

        response=$(curl -sS -w "\n%{http_code}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${auth_header[@]+"${auth_header[@]}"}" \
            "$url" 2>&1) || true

        http_code=$(echo "$response" | tail -1)
        response=$(echo "$response" | sed '$d')

        if [[ "$http_code" =~ ^2 ]]; then
            echo "$response"
            return 0
        fi

        if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
            warn "Rate limited (HTTP $http_code), retry $attempt/$MAX_RETRIES in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
            continue
        fi

        if [[ "$http_code" =~ ^5 ]]; then
            warn "Server error (HTTP $http_code), retry $attempt/$MAX_RETRIES in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
            continue
        fi

        # 404 or other client error — don't retry
        err "API request failed: HTTP $http_code for $url"
        echo "$response"
        return 1
    done

    err "Exhausted $MAX_RETRIES retries for $url"
    return 1
}

# Extract the latest 3004.388.x tag from the upstream repo.
# Paginates through tags to find all matching ones, then picks the highest version.
get_latest_upstream_tag() {
    local page=1
    local all_tags=""

    while true; do
        local response
        response=$(gh_api "${API_BASE}/repos/${UPSTREAM_REPO}/tags?per_page=100&page=${page}") || {
            err "Failed to fetch tags page $page"
            return 1
        }

        local tags
        tags=$(echo "$response" | jq -r '.[].name' 2>/dev/null) || {
            err "Failed to parse tags JSON"
            return 1
        }

        # Break if no more tags
        if [[ -z "$tags" ]]; then
            break
        fi

        all_tags+=$'\n'"$tags"
        page=$((page + 1))

        # Safety valve: don't paginate forever
        if (( page > 10 )); then
            warn "Stopped pagination at page 10"
            break
        fi
    done

    if [[ -z "$all_tags" ]]; then
        err "No tags found in upstream repository"
        return 1
    fi

    # Filter for 3004.388.x tags, exclude betas/alphas/rcs, and sort by version number
    local latest
    latest=$(echo "$all_tags" \
        | grep -E "$TAG_PATTERN" \
        | grep -v -i -E "beta|alpha|rc" \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1 \
        | tr -d '[:space:]')

    if [[ -z "$latest" ]]; then
        err "No tags matching pattern '$TAG_PATTERN' found upstream"
        return 1
    fi

    echo "$latest"
}

# Get the latest release tag from our own repo
get_own_latest_tag() {
    if [[ -z "$OWN_REPO" ]]; then
        warn "GITHUB_REPOSITORY not set, cannot check own releases"
        echo ""
        return 0
    fi

    local response
    response=$(gh_api "${API_BASE}/repos/${OWN_REPO}/releases?per_page=10" 2>/dev/null) || {
        # If we have no releases yet, that's fine
        warn "Could not fetch own releases (repo may be new)"
        echo ""
        return 0
    }

    # Extract the upstream tag from our release tag format: <upstream_tag>_fou_module
    local latest
    latest=$(echo "$response" \
        | jq -r '.[].tag_name' 2>/dev/null \
        | grep '_fou_module$' \
        | head -1 \
        | sed 's/_fou_module$//' \
        | tr -d '[:space:]')

    echo "${latest:-}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Checking upstream Asuswrt-Merlin tags..."

    local upstream_tag
    upstream_tag=$(get_latest_upstream_tag) || exit 1
    log "Latest upstream tag matching '${TAG_PATTERN}': ${upstream_tag}"

    local own_tag
    own_tag=$(get_own_latest_tag) || true
    log "Our latest built tag: ${own_tag:-<none>}"

    local should_build="false"

    # Always build on manual dispatch
    if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
        log "Manual dispatch detected — forcing build"
        should_build="true"
    elif [[ -z "$own_tag" ]]; then
        log "No previous builds found — will build"
        should_build="true"
    elif [[ "$upstream_tag" != "$own_tag" ]]; then
        log "New upstream tag detected ($own_tag → $upstream_tag) — will build"
        should_build="true"
    else
        log "Already up to date ($upstream_tag) — skipping build"
        should_build="false"
    fi

    # Write outputs
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "should_build=${should_build}" >> "$GITHUB_OUTPUT"
        echo "upstream_tag=${upstream_tag}" >> "$GITHUB_OUTPUT"
    else
        echo "should_build=${should_build}"
        echo "upstream_tag=${upstream_tag}"
    fi
}

main "$@"
