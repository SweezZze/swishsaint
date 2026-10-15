#!/bin/bash
# Fusionne la dernière version de l'officiel (UPSTREAM_REPO@UPSTREAM_BRANCH) dans la branche courante.
#
#   fork/sync-upstream.sh                     fusionne ; en cas de conflit, annule proprement
#   KEEP_CONFLICTS=1 fork/sync-upstream.sh    laisse les conflits en place (pour Claude ou un humain)
#
# Codes de sortie : 0 fusion faite · 10 déjà à jour · 20 conflit · autre = erreur.
# Dans GitHub Actions, écrit aussi target, short, count, new_tags et conflicts dans $GITHUB_OUTPUT.
#
# Toujours un merge (jamais de rebase) : main est partagée, on ne réécrit pas son historique.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$FORK_ROOT"

[ -z "$(git status --porcelain --untracked-files=no)" ] \
    || die "Des modifications non commitées traînent : commit ou stash d'abord."
[ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] || die "Une fusion est déjà en cours (git merge --abort pour repartir)."

note "Récupération de ${UPSTREAM_REPO}@${UPSTREAM_BRANCH}…"
fetch_upstream

TARGET="$(git rev-parse "$(upstream_ref)^{commit}")"
SHORT="$(git rev-parse --short=7 "$TARGET")"
gh_output target "$TARGET"
gh_output short "$SHORT"

if git merge-base --is-ancestor "$TARGET" HEAD; then
    note "Déjà à jour avec $UPSTREAM_REPO@$SHORT."
    exit 10
fi

COUNT="$(git rev-list --count "HEAD..$TARGET")"
# Versions officielles (tags v…) que cette fusion apporte : sert à décider d'une release.
NEW_TAGS="$(git for-each-ref --sort=creatordate --format='%(refname:lstrip=2)' \
    --merged "$TARGET" --no-merged HEAD refs/upstream-tags/ | tr '\n' ' ' | sed 's/ *$//')"
gh_output count "$COUNT"
gh_output new_tags "$NEW_TAGS"

MSG="sync(upstream): merge $UPSTREAM_REPO@$SHORT ($COUNT commits)"
if [ -n "$NEW_TAGS" ]; then
    MSG="$MSG, includes $NEW_TAGS"
fi

note "Fusion de $COUNT commit(s) officiel(s)${NEW_TAGS:+ (versions : $NEW_TAGS)}…"
if git merge --no-ff --no-edit -m "$MSG" "$TARGET"; then
    note "Fusion propre ✓"
    exit 0
fi

CONFLICTS="$(git diff --name-only --diff-filter=U | tr '\n' ' ' | sed 's/ *$//')"
gh_output conflicts "$CONFLICTS"
printf '⚠ Conflits dans : %s\n' "$CONFLICTS" >&2
if [ "${KEEP_CONFLICTS:-0}" != 1 ]; then
    git merge --abort
fi
exit 20
