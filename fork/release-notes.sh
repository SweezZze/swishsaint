#!/bin/bash
# Écrit les notes de la prochaine release (markdown) sur la sortie standard :
#   - les notes de mise à jour écrites par les auteurs des PR mergées (bloc update-note du corps
#     de chaque PR, voir .claude/CLAUDE.md), rangées par prénom (fork/authors.tsv) ;
#   - « Autres changements » : PR sans note (titre de la PR) et commits directs ;
#   - le résumé de ce qui vient de l'officiel ;
#   - une ligne machine, invisible sur GitHub, que l'app lit pour sa fenêtre de mise à jour
#     (Sources/Vorssaint/Fork/Update/ForkUpdateNotes.swift) ;
#   - la ligne SHA256 que l'app vérifie avant d'installer.
# À lancer après fork/build-release.sh (lit dist/build-info.env).
#
#   fork/release-notes.sh                        depuis la dernière release (tag build-*) jusqu'à HEAD
#   fork/release-notes.sh build-2153 origin/main  une autre plage, pour vérifier à la main
#   RELEASE_NOTES_OFFLINE=1 fork/release-notes.sh sans GitHub : titres des PR seulement
#
# Lit les PR avec gh (GH_TOKEN en CI, permission pull-requests: read). Sans réseau ni gh, les notes
# restent publiables : chaque PR y figure par son titre, dans « Autres changements ».
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$FORK_ROOT"

BUILD_NUMBER="" UPSTREAM_VERSION="" SHA256=""
if [ -f dist/build-info.env ]; then
    # shellcheck disable=SC1091
    . dist/build-info.env
fi
LAST="${1:-$(git tag -l 'build-*' --sort=-v:refname | head -1)}"
TO="${2:-HEAD}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count "$TO")}"
UPSTREAM_VERSION="${UPSTREAM_VERSION:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist 2>/dev/null || true)}"

# Avertissements sur stderr : la sortie standard, c'est dist/notes.md.
fetch_upstream 2>/dev/null || warn "Officiel injoignable : résumé officiel incomplet." >&2
UP="$(upstream_ref)"
UP_HEAD=""
LATEST_TAG=""
if git rev-parse -q --verify "$UP" >/dev/null; then
    UP_HEAD="$(git merge-base "$TO" "$UP")"
    LATEST_TAG="$(git for-each-ref --merged "$TO" --sort=-creatordate --count=1 \
        --format='%(refname:lstrip=2)' refs/upstream-tags/)"
fi

# Le dépôt du fork, jamais l'officiel : fork/lib.sh vient d'ajouter le remote « upstream ».
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
if [ -z "$REPO" ]; then
    REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
fi
CAN_ASK_GITHUB=0
if [ "${RELEASE_NOTES_OFFLINE:-0}" != 1 ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
    CAN_ASK_GITHUB=1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '**%s build %s** — Vorssaint officiel %s' "$FORK_APP_NAME" "$BUILD_NUMBER" "${UPSTREAM_VERSION:-?}"
if [ -n "$LATEST_TAG" ] && [ -n "$UP_HEAD" ]; then
    ahead="$(git rev-list --count "refs/upstream-tags/$LATEST_TAG..$UP_HEAD")"
    if [ "$ahead" -gt 0 ]; then
        printf ' (%s + %s commits)' "$LATEST_TAG" "$ahead"
    else
        printf ' (%s)' "$LATEST_TAG"
    fi
fi
printf '\n\n'

# Une ligne par changement de main, du plus ancien au plus récent (premier parent, sans les
# synchros automatiques) : « pr<TAB>numéro<TAB>branche<TAB>titre » ou « commit<TAB>-<TAB>-<TAB>sujet ».
# La réponse de GitHub pour la PR N est dans $WORK/pr-N.json.
: > "$WORK/entries.tsv"
if [ -z "$LAST" ]; then
    printf 'Première version publiée par le robot de release.\n\n'
else
    for commit in $(git rev-list --reverse --first-parent "$LAST..$TO"); do
        subject="$(git log -1 --format=%s "$commit")"
        case "$subject" in
            "sync(upstream):"*) continue ;;
            "Merge pull request #"*)
                number="${subject#Merge pull request #}"
                number="${number%% *}"
                branch="${subject##* from }"
                case "$branch" in */sync/* | *sync-upstream*) continue ;; esac
                branch="${branch#*/}"
                title="$(git log -1 --format=%b "$commit" | sed '/^[[:space:]]*$/d' | head -1)"
                if [ "$CAN_ASK_GITHUB" = 1 ]; then
                    gh pr view "$number" --repo "$REPO" --json author,body,title,labels,headRefName \
                        > "$WORK/pr-$number.json" 2>/dev/null \
                        || { rm -f "$WORK/pr-$number.json"; warn "PR #$number illisible : son titre servira de note." >&2; }
                fi
                printf 'pr\t%s\t%s\t%s\n' "$number" "$branch" "${title:-$branch}" >> "$WORK/entries.tsv"
                ;;
            *) printf 'commit\t-\t-\t%s\n' "$subject" >> "$WORK/entries.tsv" ;;
        esac
    done
fi

# Les notes : sections markdown dans $WORK/sections.md, ligne machine dans $WORK/meta.txt.
# Si python3 échoue, la release part quand même : les PR par leur titre, sans ligne machine
# (l'app lit alors les puces des sections, comme pour une release d'avant les notes d'auteur).
if ! python3 - "$WORK" fork/authors.tsv "$BUILD_NUMBER" "${UPSTREAM_VERSION:-}" > "$WORK/sections.md" <<'PY'
import json, os, re, sys

work, authors_path, build, upstream = sys.argv[1:5]

names = {}
with open(authors_path, encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("#") or "\t" not in line:
            continue
        login, name = line.rstrip("\n").split("\t", 1)
        if login.strip() and name.strip():
            names[login.strip().lower()] = name.strip()

CONVENTIONAL = re.compile(r"^(feat|fix|docs|chore|refactor|perf|test|build|ci|style|revert|sync)(\([^)]*\))?!?: ")

def cleaned(text):
    """Un titre de commit sans son préfixe conventionnel ni son numéro de PR, en majuscule."""
    text = text.strip()
    if CONVENTIONAL.match(text):
        text = CONVENTIONAL.sub("", text, count=1).strip()
        text = text[:1].upper() + text[1:]
    return re.sub(r" \(#\d+\)$", "", text)

def safe(text):
    """Une phrase d'auteur ne peut ni ouvrir ni fermer un commentaire HTML."""
    return " ".join(text.replace("<!--", "").replace("-->", "").split())

def shown(text):
    """La même phrase dans le markdown de GitHub, où < ouvrirait une balise et @pseudo
    notifierait quelqu'un (un espace sans chasse après @ l'en empêche)."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return text.replace("@", "@\u200b")

BY = re.compile(r"^par\s*:\s*(.+)$", re.I)

def note_lines(body):
    """(prénom donné par « Par : <Prénom> » ou None, phrases) du bloc
    <!-- update-note --> … <!-- /update-note --> ; None sans bloc."""
    match = re.search(r"<!--\s*update-note\s*-->(.*?)<!--\s*/update-note\s*-->", body or "", re.S)
    if not match:
        return None
    by = None
    lines = []
    # Un commentaire laissé dans le bloc (« <!-- ta phrase ici --> ») n'est pas une note.
    for raw in re.sub(r"<!--.*?-->", "", match.group(1), flags=re.S).splitlines():
        line = raw.strip()
        for bullet in ("- ", "* ", "• "):
            if line.startswith(bullet):
                line = line[len(bullet):].strip()
        line = safe(line)
        override = BY.match(line)
        if override:
            by = by or override.group(1).strip()
            continue
        if line and line not in lines:
            lines.append(line)
    return by, lines

def author_name(login, branch):
    if login and login.lower() in names:
        return names[login.lower()]
    match = re.match(r"^(?:feat|fix|docs|chore|refactor|perf|test|ci)/([a-z]+)-", branch or "")
    if match:
        return match.group(1).capitalize()
    return login or "?"

sections = {}   # prénom -> [(phrase, pr)]
order = []
notes = []
other = []      # (texte affiché, texte pour l'app)

with open(os.path.join(work, "entries.tsv"), encoding="utf-8") as handle:
    for line in handle:
        kind, number, branch, title = line.rstrip("\n").split("\t", 3)
        if kind == "commit":
            item = safe(cleaned(title))
            if item:
                other.append((shown(item), item))
            continue
        path = os.path.join(work, "pr-%s.json" % number)
        pr = None
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as pr_handle:
                    pr = json.load(pr_handle)
            except ValueError:
                pr = None
        if pr is None:
            item = safe(cleaned(title))
            other.append(("%s (#%s)" % (shown(item), number), item))
            continue
        labels = {label.get("name", "") for label in pr.get("labels") or []}
        if "pas-de-note" in labels:
            continue
        by, lines = note_lines(pr.get("body")) or (None, [])
        if not lines:
            item = safe(cleaned(pr.get("title") or title))
            other.append(("%s (#%s)" % (shown(item), number), item))
            continue
        author = pr.get("author") or {}
        # Le prénom vient de qui ouvre la PR ; « Par : <Prénom> » dans le bloc le remplace.
        name = by or author_name(author.get("login", ""), pr.get("headRefName") or branch)
        if name not in sections:
            sections[name] = []
            order.append(name)
        for item in lines:
            if item not in [existing for existing, _ in sections[name]]:
                sections[name].append((item, number))
        notes.append({"pr": int(number), "author": name, "items": lines})

out = []
for name in order:
    out.append("### %s" % name)
    out.extend("- %s (#%s)" % (shown(item), number) for item, number in sections[name])
    out.append("")
if other:
    out.append("### Autres changements")
    out.extend("- %s" % text for text, _ in other)
    out.append("")
if out:
    print("\n".join(out))

meta = {"build": int(build), "notes": notes, "other": [plain for _, plain in other]}
if upstream:
    meta["upstream"] = upstream
text = json.dumps(meta, ensure_ascii=False, separators=(",", ":"))
# Ni < ni > dans le JSON : rien ne peut y fermer le commentaire (« --> ») avant l'heure.
text = text.replace("<", "\\u003c").replace(">", "\\u003e")
with open(os.path.join(work, "meta.txt"), "w", encoding="utf-8") as handle:
    handle.write("<!-- swishsaint-meta v1 %s -->\n" % text)
PY
then
    warn "Notes d'auteur illisibles (python3 a échoué) : les PR sont listées par leur titre." >&2
    rm -f "$WORK/meta.txt"
    ZWSP=$'\xe2\x80\x8b'
    while IFS=$'\t' read -r kind number _ title; do
        line="$(printf '%s' "$title" | sed "s/&/\\&amp;/g; s/</\\&lt;/g; s/>/\\&gt;/g; s/@/@$ZWSP/g")"
        if [ "$kind" = pr ]; then
            printf -- '- %s (#%s)\n' "$line" "$number"
        else
            printf -- '- %s\n' "$line"
        fi
    done < "$WORK/entries.tsv" > "$WORK/items.md"
    if [ -s "$WORK/items.md" ]; then
        { printf '### Autres changements\n'; cat "$WORK/items.md"; printf '\n'; } > "$WORK/sections.md"
    else
        : > "$WORK/sections.md"
    fi
fi
cat "$WORK/sections.md"

if [ -n "$LAST" ] && [ -n "$UP_HEAD" ]; then
    last_up="$(git merge-base "$LAST" "$UP" 2>/dev/null || true)"
    if [ -n "$last_up" ] && [ "$last_up" != "$UP_HEAD" ]; then
        count="$(git rev-list --count "$last_up..$UP_HEAD")"
        printf '### Côté officiel\n- %s commit(s) intégré(s) depuis %s : https://github.com/%s/compare/%s...%s\n\n' \
            "$count" "$LAST" "$UPSTREAM_REPO" "$(git rev-parse --short=12 "$last_up")" "$(git rev-parse --short=12 "$UP_HEAD")"
    fi
fi

if [ -f "$WORK/meta.txt" ]; then
    cat "$WORK/meta.txt"
fi
if [ -n "$SHA256" ]; then
    printf '\nSHA256: %s\n' "$SHA256"
fi
