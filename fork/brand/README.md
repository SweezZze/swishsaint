# Icônes du fork

`fork/build-release.sh` remplace les icônes officielles par celles de ce dossier (TRADEMARKS.md de
l'officiel : un fork redistribué doit avoir sa propre icône).

| Fichier | Rôle | Obligatoire |
|---|---|---|
| `AppIcon.icns` | Icône de l'app (Finder, Dock) | oui |
| `Assets.car` | Icône adaptative macOS 26 (compilée avec `actool` depuis un `.icon` d'Icon Composer) | non : sans lui, macOS utilise `AppIcon.icns` |
| `MenuBarIcon.png`, `MenuBarIcon@2x.png` | Icône de la barre des menus (modèle noir sur transparent, 18 pt / 36 px) | conseillé |
| `BrandMark.png` | Logo affiché dans l'app (À propos, onboarding) | conseillé |

Créer un `.icns` depuis un PNG 1024×1024 :

```sh
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o fork/brand/AppIcon.icns
```
