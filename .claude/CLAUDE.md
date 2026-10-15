# Fork de Vorssaint : règles pour Claude

Ce dépôt est un **fork** de [vorssaint/vorssaint-utils](https://github.com/vorssaint/vorssaint-utils),
une app macOS de barre des menus en Swift (GPL-3.0-or-later). `main` = le code officiel + nos features.

Un robot fusionne l'officiel dans `main` **toutes les 2 heures** (`.github/workflows/fork-sync.yml`).
L'officiel reçoit environ 25 commits par jour : chaque ligne qu'on modifie dans un de ses fichiers
peut créer un conflit. D'où la règle d'or :

> **Le code du fork vit dans ses propres fichiers. On ne touche un fichier officiel qu'à une
> « couture » déclarée : 1 à 3 lignes, marquées `// FORK(<id>)`.**

Les règles de `CONTRIBUTING.md` et de `docs/AI-CONTRIBUTIONS.md` (celles de l'officiel) s'appliquent aussi.

## Où mettre quoi

| Quoi | Où |
|---|---|
| Code Swift d'une feature | `Sources/Vorssaint/Fork/<Feature>/`. Compilé automatiquement : `build.sh` prend `Sources/Vorssaint/**/*.swift`. |
| Textes affichés | `Sources/Vorssaint/Fork/<Feature>/<Feature>Strings.swift`, avec les 15 langues de `AppLanguage`. Modèle : `Sources/Vorssaint/Core/PortManagerStrings.swift`. |
| Réglages (UserDefaults) | Clés préfixées `fork.<feature>.`, déclarées dans `Sources/Vorssaint/Fork/Core/ForkDefaults.swift` (enregistrées au lancement, incluses dans la sauvegarde des réglages). |
| Interrupteur on/off | Catalogue `ForkFeature` du fork (page « Extras » des Réglages). **Jamais** de nouveau cas dans `AppFeature` : il faudrait modifier une quinzaine de fichiers officiels. |
| Tests | `Tests/Fork/` |
| Scripts et CI du fork | `fork/`, `.github/workflows/fork-*.yml` |

Si `ForkDefaults`, `ForkFeature` ou la page « Extras » n'existent pas encore, crée-les dans `Sources/Vorssaint/Fork/Core/`.

## Coutures (modifier un fichier officiel)

1. Seulement quand il n'y a pas d'autre moyen : le code officiel doit appeler le nôtre.
2. 1 à 3 lignes qui appellent une fonction de `Sources/Vorssaint/Fork/`. Aucune logique dans la couture.
3. Mets le marqueur `// FORK(<id>)` sur chaque ligne modifiée, et déclare `<id>  <fichier>` dans `fork/seams.txt`.
4. Ajoute une nouvelle ligne plutôt que de modifier une ligne existante, et choisis un endroit stable
   (début de fonction, fin d'un bloc qui bouge peu).
5. `fork/check-seams.sh` doit passer : il refuse toute modification d'un fichier officiel non déclarée.

## Fichiers officiels à ne JAMAIS modifier

Ce sont les plus modifiés par l'officiel, donc un conflit garanti :

- `CHANGELOG.md`, `README.md`, `Resources/Info.plist`. Nos notes de version sont générées dans les releases du fork.
- `build.sh`. Le renommage et la signature du fork sont faits par `fork/build-release.sh`.
- `Tests/generate_sources.py`, `Sources/Vorssaint/Core/Defaults.swift`, `Sources/Vorssaint/Core/Localization.swift`,
  `Sources/Vorssaint/Core/Localizations/Strings+*.swift`, `Sources/Vorssaint/Core/FeatureCatalog.swift`.
- `.github/workflows/*` (sauf `fork-*.yml`), `.github/PULL_REQUEST_TEMPLATE.md`, `LICENSE`, `TRADEMARKS.md`.
  Pour couper un workflow officiel : `gh workflow disable <nom>`. Ne supprime jamais le fichier.

## Règles de l'officiel qu'on garde

- En-tête de chaque nouveau fichier :
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  // Copyright (C) 2026 <Prénom Nom>
  ```
- Chaque texte visible existe dans toutes les langues de `AppLanguage.allCases`.
- Chaque feature vérifie sa disponibilité et ses permissions à chaque point d'entrée, et s'arrête vraiment
  (timers, event taps, observateurs) quand on la désactive.
- Les réglages utilisateur font partie de la sauvegarde. L'état propre à une machine en est exclu.
- Compile sans warning. Cible : macOS 14+, Apple Silicon, compatible Swift 6.0.3 (le CI officiel le vérifie).
- Titre de commit et de PR : `type(scope): phrase à l'impératif en minuscules`, par exemple `feat(gestures): add pinch to close`.
- Distingue ce que tu as vraiment vérifié (compilé, testé sur un vrai Mac) de ce que tu as seulement lu.

## Vérifier avant de proposer

```sh
./build.sh --dev && ./build/VorssaintDeveloper --selftest
./build.sh --test
fork/check-seams.sh
./build.sh --dev --install    # test en vrai : installe « Vorssaint (Developer) », à côté des autres apps
```

## Git

- Une branche par feature, partie de `main` à jour : `feat/<prenom>-<sujet>` ou `fix/<prenom>-<sujet>`.
- Les PR vont vers `main` **du fork**. `gh repo set-default` doit pointer sur le fork, jamais sur vorssaint/vorssaint-utils.
- Interdit : push direct sur `main`, `push --force` sur une branche partagée, `rebase` de `main`, commit de `*.p12` ou de clés.

## Résoudre un conflit avec l'officiel

1. Le code officiel fait foi : garde ses changements.
2. Ré-applique chaque couture `FORK(...)` à l'endroit équivalent. Si le code a été déplacé ou renommé,
   suis-le et mets à jour `fork/seams.txt`. Ne supprime jamais une couture sans le signaler.
3. Adapte le code de `Sources/Vorssaint/Fork/` aux changements d'API de l'officiel.
4. Vérifie : `fork/check-seams.sh`, `./build.sh`, `./build/Vorssaint --selftest`, `./build.sh --test`.
5. Termine par un commit de merge. Jamais de rebase, jamais de squash.
