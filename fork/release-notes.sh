#!/bin/bash
# Écrit les notes de la prochaine release (markdown) sur la sortie standard :
# features mergées depuis la dernière release + résumé de ce qui vient de l'officiel.
# À lancer après fork/build-release.sh (lit dist/build-info.env).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$FORK_ROOT"

BUILD_NUMBER="" UPSTREAM_VERSION="" SHA256=""
if [ -f dist/build-info.env ]; then
    # shellcheck disable=SC1091
    . dist/build-info.env
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
LAST="$(git tag -l 'build-*' --sort=-v:refname | head -1)"

fetch_upstream 2>/dev/null || warn "Officiel injoignable : résumé officiel incomplet."
UP="$(upstream_ref)"
UP_HEAD=""
LATEST_TAG=""
if git rev-parse -q --verify "$UP" >/dev/null; then
    UP_HEAD="$(git merge-base HEAD "$UP")"
    LATEST_TAG="$(git for-each-ref --merged HEAD --sort=-creatordate --count=1 \
        --format='%(refname:lstrip=2)' refs/upstream-tags/)"
fi

printf '**%s build %s** — base officielle Vorssaint %s' "$FORK_APP_NAME" "$BUILD_NUMBER" "${UPSTREAM_VERSION:-?}"
if [ -n "$LATEST_TAG" ] && [ -n "$UP_HEAD" ]; then
    ahead="$(git rev-list --count "refs/upstream-tags/$LATEST_TAG..$UP_HEAD")"
    if [ "$ahead" -gt 0 ]; then
        printf ' (%s + %s commits)' "$LATEST_TAG" "$ahead"
    else
        printf ' (%s)' "$LATEST_TAG"
    fi
fi
printf '\n\n'

if [ -z "$LAST" ]; then
    printf 'Première version publiée par le robot de release.\n\n'
else
    # Commits de premier niveau de main depuis la dernière release, sans les synchros automatiques.
    features=""
    for commit in $(git rev-list --first-parent "$LAST..HEAD"); do
        subject="$(git log -1 --format=%s "$commit")"
        case "$subject" in
            "sync(upstream):"*) continue ;;
            "Merge pull request #"*)
                number="${subject#Merge pull request #}"
                number="${number%% *}"
                branch="${subject##* from }"
                case "$branch" in */sync/*) continue ;; esac
                title="$(git log -1 --format=%b "$commit" | sed '/^[[:space:]]*$/d' | head -1)"
                features="$features- ${title:-$branch} (#$number)
"
                ;;
            *) features="$features- $subject
" ;;
        esac
    done
    if [ -n "$features" ]; then
        printf '### Nouveau chez nous\n%s\n' "$features"
    fi

    if [ -n "$UP_HEAD" ]; then
        last_up="$(git merge-base "$LAST" "$UP" 2>/dev/null || true)"
        if [ -n "$last_up" ] && [ "$last_up" != "$UP_HEAD" ]; then
            count="$(git rev-list --count "$last_up..$UP_HEAD")"
            printf '### Côté officiel\n- %s commit(s) intégré(s) depuis %s : https://github.com/%s/compare/%s...%s\n\n' \
                "$count" "$LAST" "$UPSTREAM_REPO" "$(git rev-parse --short=12 "$last_up")" "$(git rev-parse --short=12 "$UP_HEAD")"
        fi
    fi
fi

if [ -n "$SHA256" ]; then
    printf 'SHA256: %s\n' "$SHA256"
fi
