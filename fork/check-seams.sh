#!/bin/bash
# Garde-fou du fork. Vérifie que :
#   1. chaque couture déclarée dans fork/seams.txt est toujours là (marqueur FORK(<id>) dans le fichier) ;
#   2. aucun marqueur FORK(...) ne traîne dans un fichier officiel sans être déclaré ;
#   3. le fork ne modifie aucun fichier officiel en dehors des coutures déclarées.
#
#   fork/check-seams.sh            utilise refs/remotes/upstream/<branche> s'il existe
#   fork/check-seams.sh --fetch    récupère d'abord l'officiel (CI)
#
# Tourne sur chaque PR, après chaque synchro avec l'officiel, et avant d'ouvrir une PR.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$FORK_ROOT"

if [ "${1:-}" = "--fetch" ]; then
    fetch_upstream
fi

SEAMS=fork/seams.txt
errors=0
fail() { printf '✗ %s\n' "$*" >&2; errors=$((errors + 1)); }

# "id chemin" pour chaque couture déclarée (commentaires et lignes vides ignorés).
DECLARED="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$SEAMS" | awk '{ print $1, $2 }')"

is_declared_path() {
    printf '%s\n' "$DECLARED" | awk -v p="$1" '$2 == p { found = 1 } END { exit found ? 0 : 1 }'
}

# 1. Les coutures déclarées existent toujours.
seam_count=0
while read -r id path; do
    [ -n "$id" ] || continue
    seam_count=$((seam_count + 1))
    if [ -z "$path" ]; then
        fail "fork/seams.txt : la couture « $id » n'indique pas de fichier."
    elif [ ! -f "$path" ]; then
        fail "Couture « $id » : $path n'existe plus (l'officiel l'a déplacé ou supprimé ?)."
    elif ! grep -qF "FORK($id)" "$path"; then
        fail "Couture « $id » perdue : plus de marqueur FORK($id) dans $path (écrasée pendant une fusion ?)."
    fi
done <<EOF
$DECLARED
EOF

# 2. Pas de marqueur non déclaré dans les fichiers officiels.
MARKERS="$(git grep -oE 'FORK\([A-Za-z0-9_-]+\)' -- . \
    ':(exclude)fork/' ':(exclude)Sources/Vorssaint/Fork/' ':(exclude)Tests/Fork/' \
    ':(exclude).claude/' ':(exclude).github/' || true)"
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    path="${hit%%:FORK(*}"
    id="${hit##*:FORK(}"
    id="${id%)}"
    if ! printf '%s\n' "$DECLARED" | awk -v i="$id" -v p="$path" '$1 == i && $2 == p { f = 1 } END { exit f ? 0 : 1 }'; then
        fail "Marqueur FORK($id) dans $path non déclaré : ajoute « $id  $path » à fork/seams.txt."
    fi
done <<EOF
$MARKERS
EOF

# 3. Le fork ne touche aux fichiers officiels qu'aux coutures déclarées.
UP="$(upstream_ref)"
if git rev-parse -q --verify "$UP" >/dev/null; then
    BASE="$(git merge-base HEAD "$UP")"
    fork_files=0
    while IFS="$(printf '\t')" read -r status path; do
        [ -n "$path" ] || continue
        if is_fork_owned "$path"; then
            fork_files=$((fork_files + 1))
        elif [ "$status" = "D" ]; then
            fail "Fichier officiel supprimé par le fork : $path (désactive-le plutôt, ex. gh workflow disable)."
        elif ! is_declared_path "$path"; then
            fail "Fichier officiel modifié hors couture déclarée : $path"
        fi
    done <<EOF
$(git diff --name-status --no-renames "$BASE" HEAD)
EOF
    official_lines="$(git diff --numstat "$BASE" HEAD | awk -F '\t' '
        $3 !~ /^(fork\/|Sources\/Vorssaint\/Fork\/|Tests\/Fork\/|\.claude\/|\.github\/README\.md|\.github\/workflows\/fork-)/ { n += $1 + $2 }
        END { print n + 0 }')"
    note "Base officielle : $(git rev-parse --short=7 "$BASE") · $fork_files fichier(s) du fork · $seam_count couture(s) · $official_lines ligne(s) modifiée(s) dans des fichiers officiels"
else
    warn "Pas de référence officielle ($UP) : vérification 3 sautée (lance avec --fetch)."
fi

if [ "$errors" -gt 0 ]; then
    printf '\n%d problème(s). Règles : .claude/CLAUDE.md, section « Coutures ».\n' "$errors" >&2
    exit 1
fi
note "Coutures OK ✓"
