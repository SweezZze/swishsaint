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
6. Jamais de couture dans un fichier de la liste `TEST_SOURCES` de `build.sh` (compilé par `./build.sh --test`
   sans le code du fork), sauf si elle ne nomme aucun type du fork : sinon les tests officiels ne compilent plus
   et le CI officiel, contrôle obligatoire, passe au rouge. Exemple : la couture `backup` est dans
   `Services/SettingsBackup.swift`, pas dans `Core/SettingsBackupSupport.swift`.

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
fork/test.sh
fork/check-seams.sh --fetch
./build.sh --dev --install    # test en vrai : installe « Vorssaint (Developer) », à côté des autres apps
```

## Process des copains : une feature = une branche = une PR

Valable pour les humains comme pour Claude. Claude : si la demande arrive alors que tu es sur `main`,
commence par l'étape 2 ; si elle concerne une autre feature que la branche en cours, demande avant de mélanger.

### 1. Une seule fois, sur ton Mac

```sh
gh repo clone hectorpasserat2004-create/swishsaint ~/Developer/swishsaint && cd ~/Developer/swishsaint
gh repo set-default hectorpasserat2004-create/swishsaint   # sinon gh peut envoyer tes PR à l'officiel
git config rerere.enabled true                             # git retient tes résolutions de conflit
git remote set-url --push upstream DISABLED                # on ne pousse jamais chez Vorssaint
```

Il faut être collaborateur du dépôt (demande à Hector) : sans ça, pas de push ni de `@claude`.

### 2. Démarrer une feature

```sh
git switch main && git pull --ff-only          # toujours partir de main à jour
git switch -c feat/<prenom>-<sujet>            # ou fix/<prenom>-<sujet>, docs/<prenom>-<sujet>
```

- **Une branche par feature, une feature par branche.** Deux idées = deux branches = deux PR, même petites.
  Une PR courte est relue, mergée et publiée vite ; une grosse PR accumule les conflits.
- Nom en minuscules avec tirets : `feat/martial-dictation-toggle`, `fix/louis-preview-flicker`.
- Avant de toucher une zone où quelqu'un travaille déjà (regarde `gh pr list`), ouvre une issue ou parle-lui :
  deux branches sur les mêmes fichiers finissent en conflit (c'est arrivé avec la PR #4).
- Ne travaille jamais sur la branche d'un autre sans son accord. Pour l'aider : commente sa PR, ou pars de sa
  branche (`git switch -c feat/<toi>-<sujet> origin/feat/<lui>-<sujet>`) et propose une PR vers la sienne.

### 3. Coder et committer

- Code dans `Sources/Vorssaint/Fork/<Feature>/`, interrupteur dans la page « Extras », réglages `fork.<feature>.*`,
  textes dans les 15 langues, tests dans `Tests/Fork/` (voir « Où mettre quoi » et « Coutures » plus haut).
- Committe souvent, un commit = un pas cohérent : `feat(<feature>): add …`, `fix(<feature>): stop …`.
- Pousse ta branche dès le premier commit (`git push -u origin HEAD`) : elle est sauvegardée et visible des autres.

### 4. Récupérer les mises à jour officielles pendant que tu codes

Le robot fusionne Vorssaint officiel dans `main` toutes les 2 h. Ta branche, elle, ne bouge pas toute seule :

```sh
git fetch origin && git merge origin/main      # au moins tous les 2-3 jours, et toujours avant d'ouvrir la PR
```

- **Merge, jamais rebase** d'une branche déjà poussée, jamais `push --force`.
- Merge `origin/main`, **jamais `upstream/main`** directement : la synchro avec l'officiel est le travail du robot,
  sinon ta PR embarque des centaines de commits officiels et double la synchro.
- En cas de conflit : section « Résoudre un conflit avec l'officiel » ci-dessous, puis relance les vérifications.

### 5. Vérifier puis ouvrir la PR

```sh
fork/test.sh && fork/check-seams.sh --fetch && ./build.sh --test
./build.sh --dev --install     # essai en vrai dans « Vorssaint (Developer) » ; quitte Swishsaint pendant l'essai
git push && gh pr create --base main --fill
```

Le corps de la PR dit : **ce que fait la feature**, **les réglages ou coutures ajoutés**, **ce qui a vraiment été
vérifié** (commandes lancées, essai sur un vrai Mac ou non). Une PR = une feature ; si tu as besoin d'une autre
PR avant, dis-le (« dépend de #12 »).

### 6. Merge et release

- Les contrôles obligatoires doivent être verts : `Fork seams`, `Build & selftest`, `Swift 6.0.3 compatibility`.
  Si un échec vient aussi de `main` de l'officiel (pas de ta PR), écris-le dans la PR : Hector décide du contournement.
- Merge par le bouton **« Create a merge commit »** (seul mode autorisé), par l'auteur une fois les contrôles verts,
  ou par Hector. Supprime la branche ensuite.
- Le workflow `Fork · Release` publie alors `build-<N>` ; l'app de chacun propose la mise à jour toute seule.
- Chez toi : `git switch main && git pull --ff-only && git branch -d feat/<prenom>-<sujet>`, et la feature suivante
  repart de l'étape 2.

### 7. Les branches et PR du robot

- `sync/upstream-*` : synchro avec l'officiel qui a besoin d'aide (conflit ou casse). Elle passe avant les features ;
  n'y mets jamais de feature. Tant qu'elle est ouverte, les synchros suivantes attendent.
- `claude/*` : créées par `@claude` dans une issue ou une PR. Même process : relue, contrôles verts, merge commit.

### Interdits

Push direct sur `main` ; `push --force` sur une branche partagée ; `rebase` de `main` ou d'une branche poussée ;
squash ; merger `upstream/main` à la main ; PR vers `vorssaint/vorssaint-utils` ; committer `*.p12`, clés ou jetons ;
deux features dans une même PR.

## Résoudre un conflit avec l'officiel

1. Le code officiel fait foi : garde ses changements.
2. Ré-applique chaque couture `FORK(...)` à l'endroit équivalent. Si le code a été déplacé ou renommé,
   suis-le et mets à jour `fork/seams.txt`. Ne supprime jamais une couture sans le signaler.
3. Adapte le code de `Sources/Vorssaint/Fork/` aux changements d'API de l'officiel.
4. Vérifie : `fork/check-seams.sh`, `./build.sh`, `./build/Vorssaint --selftest`, `./build.sh --test`.
5. Termine par un commit de merge. Jamais de rebase, jamais de squash.
