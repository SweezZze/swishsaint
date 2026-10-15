# shellcheck shell=bash
# Fonctions partagées par les scripts fork/*.sh. Compatible bash 3.2 (celui de macOS).

# CDPATH vidé : sinon cd affiche le dossier et pollue la valeur.
FORK_ROOT="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=fork/config.env
. "$FORK_ROOT/fork/config.env"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '▸ %s\n' "$*"; }
warn() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::warning::%s\n' "$*"
    else
        printf '⚠ %s\n' "$*" >&2
    fi
}

# Écrit key=value dans $GITHUB_OUTPUT quand on tourne dans GitHub Actions.
gh_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
    return 0
}

# Chemins qui appartiennent au fork : l'officiel n'y touche jamais, donc jamais de conflit.
is_fork_owned() {
    case "$1" in
        fork/* | Sources/Vorssaint/Fork/* | Tests/Fork/* | .claude/* | .github/README.md | .github/workflows/fork-*)
            return 0 ;;
    esac
    return 1
}

upstream_url() { printf '%s' "${UPSTREAM_URL:-https://github.com/$UPSTREAM_REPO.git}"; }
upstream_ref() { printf 'refs/remotes/upstream/%s' "$UPSTREAM_BRANCH"; }

ensure_upstream_remote() {
    if git remote get-url upstream >/dev/null 2>&1; then
        git remote set-url upstream "$(upstream_url)"
    else
        git remote add upstream "$(upstream_url)"
    fi
}

# Branche officielle + ses tags de version (rangés à part, dans refs/upstream-tags/,
# pour ne jamais se mélanger aux tags build-N du fork).
fetch_upstream() {
    ensure_upstream_remote
    git fetch --quiet --no-tags upstream \
        "+refs/heads/$UPSTREAM_BRANCH:$(upstream_ref)" \
        "+refs/tags/v*:refs/upstream-tags/v*"
}

# codesign sait-il signer avec cette identité ? (find-identity -v ignore les certificats
# auto-signés, donc on essaie pour de vrai sur une copie jetable de /bin/echo.)
identity_can_sign() {
    local probe ok=1
    security unlock-keychain -p fork-signing "$HOME/Library/Keychains/fork-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    codesign --force --sign "$1" "$probe" >/dev/null 2>&1 && ok=0
    rm -f "$probe"
    return $ok
}
