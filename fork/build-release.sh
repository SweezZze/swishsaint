#!/bin/bash
# Construit l'app du fork, prête à distribuer :
#   1. compile la version optimisée avec le build.sh officiel, sans le modifier ;
#   2. la renomme d'après fork/config.env (nom, bundle id, icône, textes d'autorisation) ;
#   3. la signe avec le certificat stable du fork (les autorisations survivent aux MAJ) ;
#   4. lance son selftest, puis produit dist/<Nom>-build-<N>.zip, son SHA-256 et dist/build-info.env.
#
#   fork/build-release.sh                 build complet (CI de release)
#   fork/build-release.sh --skip-build    réutilise build/stage après un ./build.sh
#   fork/build-release.sh --adhoc         sans certificat : pour vérifier, jamais pour distribuer
#
# BUILD_NUMBER (optionnel) : numéro de build ; par défaut le nombre de commits de HEAD,
# qui ne fait que croître puisque main n'est jamais réécrite.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$FORK_ROOT"

SKIP_BUILD=0
ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --adhoc) ADHOC=1 ;;
        *) die "Option inconnue : $arg" ;;
    esac
done

case "$FORK_APP_NAME|$FORK_BUNDLE_ID|$FORK_SIGNING_IDENTITY" in
    *CHANGE_MOI* | *change-moi*) die "Renseigne d'abord fork/config.env (nom, bundle id, certificat)." ;;
esac
case "$FORK_BUNDLE_ID" in
    *.dev) die "FORK_BUNDLE_ID ne doit pas finir par .dev : l'app se prendrait pour un build de développement." ;;
esac
case "$FORK_APP_NAME" in
    *[Vv]orssaint*) die "FORK_APP_NAME ne doit pas contenir « Vorssaint » (TRADEMARKS.md de l'officiel)." ;;
esac

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
COMMIT="$(git rev-parse --short=12 HEAD)"
REPO="${FORK_REPO:-${GITHUB_REPOSITORY:-}}"
if [ -z "$REPO" ] && command -v gh >/dev/null 2>&1; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi

if [ "$SKIP_BUILD" = 0 ]; then
    note "Compilation de la version optimisée (build.sh officiel)…"
    ./build.sh
fi
SRC="$(find build/stage -maxdepth 1 -name '*.app' -print 2>/dev/null | head -1)"
[ -n "$SRC" ] && [ -d "$SRC" ] || die "Aucune app dans build/stage : lance ./build.sh (ou retire --skip-build)."

# Hors du dépôt : un dossier synchronisé (iCloud, ~/Documents) ajoute des attributs qui cassent codesign.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$FORK_APP_NAME.app"
ditto --noextattr --noqtn "$SRC" "$APP"
PLIST="$APP/Contents/Info.plist"
RES="$APP/Contents/Resources"
UPSTREAM_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$PLIST")"

note "Renommage : $FORK_APP_NAME ($FORK_BUNDLE_ID) · build $BUILD_NUMBER · base officielle $UPSTREAM_VERSION"
plutil -replace CFBundleIdentifier -string "$FORK_BUNDLE_ID" "$PLIST"
plutil -replace CFBundleName -string "$FORK_APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$FORK_APP_NAME" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace ForkUpstreamVersion -string "$UPSTREAM_VERSION" "$PLIST"
plutil -replace ForkSourceCommit -string "$COMMIT" "$PLIST"
if [ -n "$REPO" ]; then
    plutil -replace ForkUpdateRepository -string "$REPO" "$PLIST"
fi

# Dictée vocale (Fork/Dictation) : sans ce texte, macOS ferme l'app dès qu'elle demande la
# reconnaissance vocale. L'Info.plist officiel n'est jamais modifié : on l'ajoute ici.
plutil -replace NSSpeechRecognitionUsageDescription -string \
    "Vorssaint turns your voice into text only while you hold the dictation key you chose, then types it where your cursor is." "$PLIST"

# Textes des demandes d'autorisation : « Vorssaint utilise… » → « <Nom> utilise… ».
# (Le copyright « © Vorssaint » reste : la GPL impose de conserver les mentions d'auteur.)
rename_product() { FORK_APP_NAME="$FORK_APP_NAME" perl -pe 's/\bVorssaint\b/$ENV{FORK_APP_NAME}/g'; }
for key in $(plutil -p "$PLIST" | sed -n 's/^ *"\(NS[A-Za-z]*UsageDescription\)".*/\1/p'); do
    value="$(plutil -extract "$key" raw "$PLIST" | rename_product)"
    plutil -replace "$key" -string "$value" "$PLIST"
done
for strings in "$RES"/*.lproj/InfoPlist.strings; do
    [ -f "$strings" ] || continue
    FORK_APP_NAME="$FORK_APP_NAME" perl -pi -e 's/\bVorssaint\b/$ENV{FORK_APP_NAME}/g' "$strings"
done

# Icônes du fork (fork/brand/). Sans elles, l'app garderait l'icône officielle.
BRAND=fork/brand
if [ -f "$BRAND/AppIcon.icns" ]; then
    cp "$BRAND/AppIcon.icns" "$RES/AppIcon.icns"
    if [ -f "$BRAND/Assets.car" ]; then
        cp "$BRAND/Assets.car" "$RES/Assets.car"
    else
        # Assets.car contient l'icône adaptative officielle : on la retire pour que macOS prenne AppIcon.icns.
        rm -f "$RES/Assets.car"
        plutil -remove CFBundleIconName "$PLIST" 2>/dev/null || true
    fi
else
    warn "fork/brand/AppIcon.icns absent : l'app garde l'icône officielle (à remplacer, cf. TRADEMARKS.md)."
fi
for image in MenuBarIcon.png MenuBarIcon@2x.png BrandMark.png; do
    if [ -f "$BRAND/$image" ]; then
        cp "$BRAND/$image" "$RES/$image"
    fi
done

xattr -cr "$APP" 2>/dev/null || true
if [ "$ADHOC" = 1 ]; then
    SIGN="-"
    warn "Signature ad hoc : pour vérifier seulement, ne pas distribuer."
else
    identity_can_sign "$FORK_SIGNING_IDENTITY" \
        || die "Certificat « $FORK_SIGNING_IDENTITY » introuvable. En local : fork/setup-signing.sh. En CI : secrets SIGNING_CERT_P12 et SIGNING_CERT_PASSWORD."
    SIGN="$FORK_SIGNING_IDENTITY"
fi

# Binaires imbriqués d'abord (assistant ventilateurs, adaptateur Now Playing), en gardant leur identifiant.
sign_nested() {
    local file="$1" ident
    ident="$(codesign -dv "$file" 2>&1 | sed -n 's/^Identifier=//p')"
    [ -n "$ident" ] || ident="$(basename "$file")"
    codesign --force --strip-disallowed-xattrs --identifier "$ident" --sign "$SIGN" "$file"
}
note "Signature avec : $([ "$SIGN" = - ] && echo 'ad hoc' || echo "$SIGN")"
for dir in "$APP/Contents/Library/LaunchServices" "$APP/Contents/Frameworks"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
        sign_nested "$file"
    done < <(find "$dir" -type f -print0)
done
codesign --force --strip-disallowed-xattrs --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"

REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
note "Exigence de signature : $REQUIREMENT"
if [ "$ADHOC" = 0 ]; then
    case "$REQUIREMENT" in
        *"certificate "*) ;;
        *) die "Signature instable (aucun certificat dans l'exigence) : les autorisations sauteraient à chaque MAJ." ;;
    esac
fi

note "Selftest de l'app finale…"
"$APP/Contents/MacOS/$EXECUTABLE" --selftest

mkdir -p dist
SAFE_NAME="$(printf '%s' "$FORK_APP_NAME" | tr -c 'A-Za-z0-9._-' '-')"
ZIP="dist/$SAFE_NAME-build-$BUILD_NUMBER.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
printf '%s  %s\n' "$SHA256" "$(basename "$ZIP")" > "$ZIP.sha256"
cat > dist/build-info.env <<EOF
BUILD_NUMBER=$BUILD_NUMBER
UPSTREAM_VERSION=$UPSTREAM_VERSION
COMMIT=$COMMIT
ZIP=$ZIP
SHA256=$SHA256
EOF
note "✓ $ZIP ($SHA256)"
