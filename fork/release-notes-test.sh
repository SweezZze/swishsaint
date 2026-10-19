#!/bin/bash
# Teste fork/release-notes.sh hors réseau : un petit dépôt git jetable avec des merges de PR,
# une doublure de gh qui répond pour chaque PR, et une de python3 qui échoue.
# Lancé par fork/test.sh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
BIN="$TMP/bin"
mkdir -p "$REPO/fork" "$REPO/Resources" "$BIN"
cp "$FORK_ROOT"/fork/{lib.sh,config.env,release-notes.sh,authors.tsv} "$REPO/fork/"
cp "$FORK_ROOT/Resources/Info.plist" "$REPO/Resources/Info.plist"
mkdir -p "$REPO/dist"
printf 'BUILD_NUMBER=42\nUPSTREAM_VERSION=3.4.2-beta.1\n' > "$REPO/dist/build-info.env"

git_quiet() { git -C "$REPO" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false "$@" >/dev/null; }
git_quiet init -q -b main
git_quiet commit -q --allow-empty -m "first"
git_quiet tag build-1
merge() { # merge <n> <owner/branche> <titre>
    git_quiet switch -q -c "${2#*/}"
    git_quiet commit -q --allow-empty -m "$3"
    git_quiet switch -q main
    git_quiet merge -q --no-ff "${2#*/}" -m "Merge pull request #$1 from $2" -m "$3"
}
merge 31 owner/feat/martial-a "feat(dictation): first"
merge 32 owner/feat/louis-b "fix(x): second"
merge 33 owner/feat/martial-c "feat(y): third"
merge 34 owner/docs/hector-d "docs: fourth"
merge 35 owner/sync/upstream-2026 "sync(upstream): merge"
merge 36 owner/feat/zoe-e "feat(z): ping @hector <now>"
merge 37 owner/feat/martial-f "feat(w): done by someone else"
git_quiet commit -q --allow-empty -m "fix: a direct commit"

cat > "$BIN/gh" <<'EOF'
#!/bin/bash
case "$3" in
  31) printf '%s' '{"author":{"login":"Martial4034"},"title":"feat(dictation): first","labels":[],"headRefName":"feat/martial-a","body":"Texte.\n\n## Note de mise à jour\n<!-- update-note -->\n<!-- écris ici -->\n- J’ai corrigé un bug, merci @louis.\n- J’ai corrigé un bug, merci @louis.\n<!-- /update-note -->"}' ;;
  32) printf '%s' '{"author":{"login":"SweezZze"},"title":"fix(x): second","labels":[],"headRefName":"feat/louis-b","body":"<!-- update-note -->\nJ’ai rendu l’aperçu <plus> fluide --> vraiment.\n<!-- /update-note -->"}' ;;
  33) printf '%s' '{"author":{"login":"Martial4034"},"title":"feat(y): third","labels":[],"headRefName":"feat/martial-c","body":"<!-- update-note -->\nJ’ai ajouté un réglage.\n<!-- /update-note -->"}' ;;
  34) printf '%s' '{"author":{"login":"hectorpasserat2004-create"},"title":"docs: fourth","labels":[{"name":"pas-de-note"}],"headRefName":"docs/hector-d","body":""}' ;;
  36) printf '%s' '{"author":{"login":"zoe-gh"},"title":"feat(z): ping @hector <now>","labels":[],"headRefName":"feat/zoe-e","body":"pas de bloc"}' ;;
  37) printf '%s' '{"author":{"login":"Martial4034"},"title":"feat(w): done","labels":[],"headRefName":"feat/martial-f","body":"<!-- update-note -->\nPar : Hector\nJ’ai accéléré les vérifications.\n<!-- /update-note -->"}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/gh"

failures=0
expect() { # expect <description> <commande…>
    local what="$1"
    shift
    if "$@"; then return 0; fi
    printf '✗ release-notes : %s\n' "$what" >&2
    failures=$((failures + 1))
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

run() { # run <sortie> [env…]
    local out="$1"
    shift
    (cd "$REPO" && env PATH="$BIN:$PATH" GH_REPO=owner/repo UPSTREAM_URL="$TMP/no-upstream" "$@" \
        fork/release-notes.sh build-1 > "$out" 2> "$out.err")
}

OUT="$TMP/notes.md"
run "$OUT"
ZWSP=$'\xe2\x80\x8b'
expect "en-tête" has "$OUT" "**Swishsaint build 42** — Vorssaint officiel 3.4.2-beta.1"
expect "section Martial" has "$OUT" "### Martial"
expect "phrase de Martial, une fois, @ neutralisé" has "$OUT" "- J’ai corrigé un bug, merci @${ZWSP}louis. (#31)"
expect "phrase en double retirée" test "$(grep -c "^- J’ai corrigé un bug" "$OUT")" = 1
expect "deux PR du même auteur sous un seul titre" test "$(grep -c '^### Martial$' "$OUT")" = 1
expect "phrase de Louis échappée" has "$OUT" "- J’ai rendu l’aperçu &lt;plus&gt; fluide vraiment. (#32)"
expect "Par : remplace le prénom" has "$OUT" "### Hector"
expect "Par : n'est pas une phrase" lacks "$OUT" "Par :"
expect "PR sans bloc dans Autres changements" has "$OUT" "- Ping @${ZWSP}hector &lt;now&gt; (#36)"
expect "commit direct dans Autres changements" has "$OUT" "- A direct commit"
expect "label pas-de-note ignoré" lacks "$OUT" "ourth"
expect "synchro ignorée" lacks "$OUT" "sync(upstream)"
expect "commentaire du bloc ignoré" lacks "$OUT" "écris ici"

expect "ligne machine" has "$OUT" "<!-- swishsaint-meta v1 {\"build\":42,\"notes\":[{\"pr\":31,\"author\":\"Martial\",\"items\":[\"J’ai corrigé un bug, merci @louis.\"]}"
expect "ligne machine : Par" has "$OUT" "{\"pr\":37,\"author\":\"Hector\",\"items\":[\"J’ai accéléré les vérifications.\"]}"
expect "ligne machine sans < ni >" test "$(grep 'swishsaint-meta' "$OUT" | sed 's/^<!--//; s/-->$//' | tr -d -c '<>' | wc -c | tr -d ' ')" = 0
expect "rien sur stdout que les notes" lacks "$OUT" "::warning::"
expect "avertissement sur stderr" has "$OUT.err" "Officiel injoignable"

# Sans GitHub : les titres des PR.
run "$OUT" RELEASE_NOTES_OFFLINE=1
expect "hors ligne : titres" has "$OUT" "- First (#31)"
expect "hors ligne : pas de section d'auteur" lacks "$OUT" "### Martial"

# python3 en panne : la release part quand même, sans ligne machine.
printf '#!/bin/sh\nexit 1\n' > "$BIN/python3"
chmod +x "$BIN/python3"
run "$OUT"
expect "python en panne : titres" has "$OUT" "- feat(dictation): first (#31)"
expect "python en panne : @ et < neutralisés" has "$OUT" "- feat(z): ping @${ZWSP}hector &lt;now&gt; (#36)"
expect "python en panne : pas de ligne machine" lacks "$OUT" "swishsaint-meta"
expect "python en panne : averti" has "$OUT.err" "python3 a échoué"

if [ "$failures" -gt 0 ]; then
    printf 'release-notes: FAILED (%s)\n' "$failures"
    exit 1
fi
printf 'release-notes: OK\n'
