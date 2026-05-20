#!/usr/bin/env bash
# Bulk-dismiss Dependabot alerts on magneta-finance-contracts
#
# Categorises every open alert by package name and applies a consistent
# dismissal reason + comment per category. Anything outside the known
# categories is SKIPPED and must be triaged manually — that way new,
# unrecognised vulnerabilities (e.g., a fresh CVE on a Solidity-touching
# dep) don't get swept under the rug.
#
# Reasons documented in the policy below are aligned with what we
# discussed in INCIDENT_RUNBOOK.md and SECURITY.md:
#
#   • OpenZeppelin contracts (direct + upgradeable): our package.json
#     pins @openzeppelin/contracts to 4.9.6 which patches every listed
#     CVE. The older versions Dependabot sees are transitive node deps
#     that are NOT compiled into our Solidity bytecode. On-chain code
#     is safe.
#
#   • Node tooling (axios / undici / serialize-javascript / ws / vite /
#     esbuild / fast-uri / tmp / elliptic / cookie): transitive dev
#     dependencies via hardhat-deploy, hardhat-toolbox, or LayerZero peers.
#     They run inside the deployer's local Node process during compile /
#     deploy / verify, NEVER inside production smart contracts. The
#     exact-version pinning + committed lockfile mitigate the supply-
#     chain attack vector this would otherwise expose.
#
# Usage:
#   ./scripts/security/dismiss-dependabot-alerts.sh             # DRY-RUN (default)
#   ./scripts/security/dismiss-dependabot-alerts.sh --execute   # actually dismiss
#   ./scripts/security/dismiss-dependabot-alerts.sh --list      # list categories + counts
#
# Pre-requisite: `gh` CLI must be authenticated (gh auth login) with the
# `repo` and `security_events` scopes on Bosacks/magneta-finance-contracts.
set -euo pipefail

REPO="Bosacks/magneta-finance-contracts"
MODE="dry"
case "${1:-}" in
    --execute) MODE="execute" ;;
    --list)    MODE="list" ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    "") ;;
    *) echo "Unknown arg: $1 — see --help" >&2; exit 1 ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Dismissal policy — package → (reason, comment)
# ─────────────────────────────────────────────────────────────────────────────
declare -A REASON
declare -A COMMENT

# OpenZeppelin direct pins.
# GitHub dismissed_comment is capped at 280 chars — keep these short.
COMMENT_OZ="Direct pin @openzeppelin/contracts 4.9.6 patches all listed CVEs. Older versions are transitive node deps only, NOT compiled into our Solidity bytecode. On-chain code safe. See SECURITY.md."
for pkg in "@openzeppelin/contracts" "@openzeppelin/contracts-upgradeable"; do
    REASON["$pkg"]="tolerable_risk"
    COMMENT["$pkg"]="$COMMENT_OZ"
done

# Node tooling — pure dev exposure.
COMMENT_TOOLING="Transitive dev dep via hardhat-deploy / hardhat-toolbox / LayerZero peers / mocha. Not shipped in production smart contracts. Exact-version pinning + lockfile mitigate supply-chain. Will re-evaluate when upstream bumps."
for pkg in axios undici fast-uri ws vite esbuild serialize-javascript tmp elliptic cookie; do
    REASON["$pkg"]="tolerable_risk"
    COMMENT["$pkg"]="$COMMENT_TOOLING"
done

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI not installed. https://cli.github.com/" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not installed: sudo apt install jq" >&2
    exit 2
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "gh CLI not authenticated. Run: gh auth login" >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fetch + group
# ─────────────────────────────────────────────────────────────────────────────
echo "Fetching open Dependabot alerts from $REPO …"
ALERTS=$(gh api "repos/$REPO/dependabot/alerts?state=open&per_page=100" --paginate)
TOTAL=$(echo "$ALERTS" | jq 'length')
echo "Open alerts: $TOTAL"
echo ""

if [ "$MODE" = "list" ]; then
    echo "Distribution by package (known categories marked ★):"
    echo "$ALERTS" | jq -r '.[] | .dependency.package.name' | sort | uniq -c | sort -rn | \
        while read -r count pkg; do
            mark=" "
            [ -n "${REASON[$pkg]:-}" ] && mark="★"
            printf "  %s  %4d  %s\n" "$mark" "$count" "$pkg"
        done
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Iterate alerts
# ─────────────────────────────────────────────────────────────────────────────
dismissed=0
skipped=0
errors=0

# Use process substitution so the loop runs in the parent shell and counters persist.
while IFS=$'\t' read -r num pkg sev; do
    if [ -z "${REASON[$pkg]:-}" ]; then
        printf "  %s  #%-5s %-7s %-40s  no category → manual review needed\n" \
            "SKIP" "$num" "$sev" "$pkg"
        skipped=$((skipped + 1))
        continue
    fi

    reason="${REASON[$pkg]}"
    comment="${COMMENT[$pkg]}"

    if [ "$MODE" = "dry" ]; then
        printf "  %s  #%-5s %-7s %-40s  → %s\n" \
            "DRY " "$num" "$sev" "$pkg" "$reason"
    else
        if gh api "repos/$REPO/dependabot/alerts/$num" -X PATCH \
            -f state=dismissed \
            -f dismissed_reason="$reason" \
            -f dismissed_comment="$comment" >/dev/null 2>&1; then
            printf "  %s  #%-5s %-7s %-40s\n" "✓   " "$num" "$sev" "$pkg"
            dismissed=$((dismissed + 1))
        else
            printf "  %s  #%-5s %-7s %-40s  API call failed\n" "✗   " "$num" "$sev" "$pkg"
            errors=$((errors + 1))
        fi
        # Light throttle so we stay well below the GitHub abuse-detection ceiling.
        sleep 0.3
    fi
done < <(echo "$ALERTS" | jq -r '.[] | [.number, .dependency.package.name, .security_advisory.severity] | @tsv')

echo ""
if [ "$MODE" = "dry" ]; then
    echo "DRY-RUN summary: $TOTAL alerts seen, $skipped would be skipped, $((TOTAL - skipped)) would be dismissed."
    echo "Re-run with --execute when ready."
else
    echo "Dismissed: $dismissed | Skipped (manual review): $skipped | Errors: $errors"
fi
