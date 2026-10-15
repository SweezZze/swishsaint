#!/bin/bash
# À lancer UNE SEULE FOIS, par le mainteneur, sur son Mac.
#
# Crée le certificat de signature auto-signé du fork (valable 10 ans), l'installe pour les
# builds locaux et affiche les commandes pour le mettre dans les secrets GitHub.
#
# Garde signing.p12 + password.txt dans un gestionnaire de mots de passe partagé avec un
# 2e admin. Si on les perd, un nouveau certificat change la signature de l'app : les MAJ
# automatiques refuseront de s'installer et tout le monde devra réinstaller une fois.
#
#   fork/setup-signing.sh [dossier de sortie]     (défaut : ~/fork-signing)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

case "$FORK_SIGNING_IDENTITY" in
    *CHANGE_MOI*) die "Renseigne FORK_SIGNING_IDENTITY dans fork/config.env." ;;
esac

OUT="${1:-$HOME/fork-signing}"
P12="$OUT/signing.p12"
KC="$HOME/Library/Keychains/fork-signing.keychain-db"
KCPASS="fork-signing"

[ ! -e "$P12" ] || die "$P12 existe déjà. Ne recrée pas le certificat : ça casserait les MAJ de tout le monde."
mkdir -p "$OUT"
chmod 700 "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"

note "Création du certificat « $FORK_SIGNING_IDENTITY »…"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -nodes \
    -subj "/CN=$FORK_SIGNING_IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
# Mêmes algorithmes que Tools/setup-signing.sh de l'officiel : acceptés par LibreSSL (macOS),
# OpenSSL 3 et security(1).
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$P12" \
    -passout pass:"$PASS" -name "$FORK_SIGNING_IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
chmod 600 "$P12"
printf '%s\n' "$PASS" > "$OUT/password.txt"
chmod 600 "$OUT/password.txt"

note "Installation dans un trousseau dédié (pour les builds locaux)…"
[ -f "$KC" ] || security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$P12" -k "$KC" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
if ! security list-keychains -d user | grep -q 'fork-signing.keychain-db'; then
    EXISTING="$(security list-keychains -d user | sed 's/"//g' | xargs)"
    # shellcheck disable=SC2086 # une entrée par trousseau, voulu
    security list-keychains -d user -s "$KC" $EXISTING
fi
identity_can_sign "$FORK_SIGNING_IDENTITY" || die "Certificat importé mais codesign ne peut pas signer avec."

SHA1="$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
cat <<EOF

✓ Certificat « $FORK_SIGNING_IDENTITY » prêt (empreinte SHA-1 : $SHA1)
  À ranger dans un gestionnaire de mots de passe : $P12 et $OUT/password.txt

Secrets GitHub, dans l'environnement « release » du fork :
  base64 -i "$P12" | gh secret set SIGNING_CERT_P12 --env release
  gh secret set SIGNING_CERT_PASSWORD --env release < "$OUT/password.txt"
EOF
