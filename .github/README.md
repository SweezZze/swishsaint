# Swishsaint : Vorssaint + les features de la bande

Version **non officielle** de [Vorssaint](https://github.com/vorssaint/vorssaint-utils), l'app libre de
barre des menus pour macOS. Tout le mérite de l'app revient à Vorssaint. Ce fork suit l'officiel
automatiquement et y ajoute quelques features entre amis. Il n'est ni signé par Apple ni lié à
l'équipe de Vorssaint.

## Installer

Il faut un Mac Apple Silicon et macOS 14 ou plus récent.

1. Télécharge le `.zip` de la [dernière version](https://github.com/hectorpasserat2004-create/swishsaint/releases/latest) (rubrique « Assets ») et glisse l'app dans **Applications**.
2. Si tu utilises le Vorssaint officiel : **Réglages › Avancé › Sauvegarde › Exporter les réglages…**, puis quitte-le (les deux ne doivent pas tourner en même temps).
3. Premier lancement : macOS le bloque. **Réglages Système › Confidentialité et sécurité › Ouvrir quand même**.
4. **Réglages › Avancé › Sauvegarde › Importer les réglages…**, puis accorde **Accessibilité** quand l'app le demande.

## Mises à jour

L'app vérifie toute seule et propose la nouvelle version en un clic. Une nouvelle version sort
automatiquement quand une feature est mergée, quand l'officiel publie une version, et la nuit s'il y a du nouveau.

## Contribuer (les copains)

```sh
gh repo clone hectorpasserat2004-create/swishsaint && cd swishsaint
gh repo set-default hectorpasserat2004-create/swishsaint       # sinon gh enverrait tes PR à l'officiel
git config rerere.enabled true
git remote set-url --push upstream DISABLED                     # on ne pousse jamais chez Vorssaint

# pour chaque feature :
git switch main && git pull --ff-only
git switch -c feat/<prenom>-<sujet>                             # une feature = une branche = une PR
# … demande à Claude Code (il lit .claude/CLAUDE.md), teste avec ./build.sh --dev --install …
git fetch origin && git merge origin/main                       # récupère les MAJ officielles (jamais de rebase)
git push -u origin HEAD && gh pr create --base main --fill
```

Process complet, étape par étape, pour toi et pour Claude : [`.claude/CLAUDE.md`](../.claude/CLAUDE.md),
section « Process des copains ».

## Licence

GPL-3.0-or-later, comme Vorssaint. Le code source complet est dans ce dépôt.
