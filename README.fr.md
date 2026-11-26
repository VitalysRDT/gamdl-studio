<p align="center">
  <img src="docs/icon.png" width="128" alt="Icône de Gamdl Studio">
</p>

<h1 align="center">Gamdl Studio</h1>

<p align="center">
  Une app macOS native pour <a href="https://github.com/glomatico/gamdl">gamdl</a>, l'outil de téléchargement Apple Music.
  <br>
  <a href="README.md">English version</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift" alt="SwiftUI">
  <img src="https://img.shields.io/github/license/VitalysRDT/gamdl-studio" alt="Licence">
  <img src="https://img.shields.io/github/v/release/VitalysRDT/gamdl-studio" alt="Version">
</p>

<p align="center">
  <img src="docs/screenshots/download.png" width="820" alt="Écran de téléchargement">
</p>

Gamdl Studio donne une interface Mac à la ligne de commande gamdl : on colle un lien, on
vérifie ce qu'il contient, on suit le téléchargement piste par piste, puis on parcourt et on
écoute ce qui a été téléchargé. gamdl tourne sur ta machine, avec ta propre session Apple
Music ; rien ne passe par un serveur tiers. L'interface existe en français et en anglais et
suit la langue de macOS.

## Fonctionnalités

- **Aperçu avant téléchargement.** Pour les morceaux, albums, artistes et clips, l'API
  publique iTunes Search fournit pochette, liste des pistes, durée et année. Pour les
  playlists, l'app lit les balises Open Graph de la page. Aucun compte n'est nécessaire.
- **File d'attente.** Progression piste par piste lue en direct dans la sortie de gamdl, débit,
  temps restant, journal brut, annulation et nouvelle tentative. Plusieurs liens collés ou
  déposés d'un coup partent tous en file.
- **Bibliothèque.** Tout le dossier de sortie, regroupé par album, avec recherche, tri,
  lecteur intégré, paroles synchronisées (LRC) et « Ouvrir dans Musique ».
- **Diagnostic.** Vérifie gamdl, ffmpeg (gamdl 3 seulement), le fichier de cookies et le dossier de sortie. Les
  cookies s'importent par glisser-déposer : seuls les cookies Apple sont conservés, avec des
  droits `600`. gamdl se met à jour depuis l'app (`pipx upgrade gamdl`).
- **Réglages de téléchargement.** Codec, format des paroles, taille de pochette, `Cover.jpg`,
  réécriture, et ce qu'il faut prendre sur une page d'artiste.

<p align="center">
  <img src="docs/screenshots/queue.png" width="410" alt="File d'attente">
  <img src="docs/screenshots/diagnostics.png" width="410" alt="Diagnostic">
</p>

## Prérequis

- macOS 26 (Tahoe) ou plus récent, Mac Apple silicon ou Intel
- Un abonnement Apple Music actif
- [gamdl](https://github.com/glomatico/gamdl) 3.9 ou plus récent. gamdl 3 et gamdl 4 sont tous
  deux pris en charge : l'app lit `gamdl --version` et pilote celui qui est installé.
- [FFmpeg](https://ffmpeg.org), avec gamdl 3 seulement (gamdl 4 ne l'utilise plus)
- Un fichier `cookies.txt` exporté depuis [music.apple.com](https://music.apple.com) en étant connecté

## Installation et configuration

### 1. Installer gamdl

Avec [Homebrew](https://brew.sh) :

```bash
brew install pipx
pipx ensurepath
pipx install gamdl
```

Cela installe le gamdl actuel, en 4.x. Si tu restes sur gamdl 3, installe aussi FFmpeg
(`brew install ffmpeg`). gamdl 4 n'a plus de mode « Paroles seules » : l'option n'est proposée
qu'avec gamdl 3.

Gamdl Studio cherche `gamdl` dans `~/.local/bin` (pipx), `/opt/homebrew/bin` et
`/usr/local/bin`. S'il est ailleurs, indique son chemin dans **Réglages → Avancé**.

### 2. Exporter les cookies Apple Music

1. Ouvre [music.apple.com](https://music.apple.com) et connecte-toi.
2. Installe une extension d'export :
   [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) (Chrome)
   ou [Export Cookies](https://addons.mozilla.org/addon/export-cookies-txt) (Firefox).
3. Sur l'onglet music.apple.com, exporte les cookies au format **Netscape**.

### 3. Installer l'app

1. Télécharge `GamdlStudio-x.y.z.dmg` depuis la [dernière version](https://github.com/VitalysRDT/gamdl-studio/releases/latest).
2. Ouvre-le et glisse **Gamdl Studio** dans **Applications**. L'app est signée et notarisée.
3. Lance-la, ouvre **Diagnostic** et dépose ton `cookies.txt` dans la zone prévue.

Quand tout est au vert dans Diagnostic, colle un lien dans l'onglet **Télécharger** et appuie
sur <kbd>⌘</kbd><kbd>↩</kbd>.

### Emplacements

| Quoi | Par défaut | À changer dans |
|---|---|---|
| Téléchargements | `~/Music/Gamdl Studio` | Réglages → Général |
| Cookies | `~/Library/Application Support/Gamdl Studio/cookies.txt` | Réglages → Général |
| Fichiers temporaires | `~/Library/Caches/Gamdl Studio/temp` | Réglages → Avancé |

Les noms de dossiers et de fichiers suivent les modèles de gamdl : ta configuration gamdl
existante reste prise en compte (`~/.gamdl/config.ini` pour gamdl 3, `~/.gamdl/config.yml`
pour gamdl 4).

## Liens pris en charge

| Lien | Exemple |
|---|---|
| Morceau | `https://music.apple.com/fr/album/…/1624945511?i=1624945512` |
| Album | `https://music.apple.com/fr/album/…/1624945511` |
| Playlist | `https://music.apple.com/fr/playlist/…/pl.u-…` |
| Artiste | `https://music.apple.com/fr/artist/…/669771` |
| Clip | `https://music.apple.com/fr/music-video/…/…` |

Les playlists personnalisées (`pl.pm-…`, comme « En boucle » ou « Mix favoris ») sont refusées
par gamdl. Gamdl Studio lit leur liste de morceaux avec ta session Apple Music, via le client API
de gamdl, puis passe chaque morceau à gamdl. Les stations de radio ne sont pas téléchargeables.

## Codecs

L'app propose les deux codecs que gamdl obtient avec de simples cookies navigateur :
**AAC 256 kb/s** (`aac-web`) et **HE-AAC 64 kb/s** (`aac-he-web`). L'ALAC sans perte et le
Dolby Atmos exigent le [wrapper](https://github.com/glomatico/wrapper-v2) de gamdl, que l'app
ne pilote pas.

## Raccourcis clavier

| Raccourci | Action |
|---|---|
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>V</kbd> | Coller un lien Apple Music |
| <kbd>⌘</kbd><kbd>↩</kbd> | Lancer le téléchargement |
| <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>4</kbd> | Changer de section |
| <kbd>⌘</kbd><kbd>R</kbd> | Relire la bibliothèque |
| <kbd>⌘</kbd><kbd>,</kbd> | Réglages |

## Compiler depuis les sources

```bash
brew install xcodegen
git clone https://github.com/VitalysRDT/gamdl-studio.git
cd gamdl-studio
xcodegen generate
open GamdlStudio.xcodeproj
```

Il faut Xcode 26 ou plus récent. Le projet Xcode est généré depuis `project.yml` et n'est pas
versionné. L'icône est dessinée par `scripts/make-icon.swift`.

Tests : <kbd>⌘</kbd><kbd>U</kbd> dans Xcode, ou :

```bash
xcodebuild test -project GamdlStudio.xcodeproj -scheme GamdlStudio -destination 'platform=macOS'
```

Les tests (Swift Testing) ne contactent jamais Apple Music. Les tests d'intégration font
tourner la vraie file de téléchargement contre un faux script `gamdl` qui rejoue une sortie
de gamdl enregistrée, et lancent les scripts Python de l'app (`gamdl_bridge.py`,
`resolve_playlist.py`) contre des paquets `gamdl` factices, avec le Python 3 présent sur le
Mac. Ces tests-là sont ignorés s'il n'y en a pas.

Pour produire un DMG signé et notarisé, voir [`scripts/release.sh`](scripts/release.sh).

## Fonctionnement

- L'app lance gamdl comme processus enfant, avec les options qu'on lui passerait à la main, et
  lit sa sortie ligne par ligne. Chaque journal propose de copier la commande exacte.
- gamdl 4 a remplacé la commande unique de gamdl 3 par des sous-commandes et renommé la plupart
  des options : la commande est donc construite selon la version majeure installée (lue avec
  `gamdl --version`, mise en cache par exécutable) :
  - gamdl 3 : `gamdl --cookies-path … --output-path … --song-codec-priority … URL`
  - gamdl 4 : `gamdl rip --auth-mode cookies --cookies-path … --output-dir … URL`, avec
    `--concurrent-downloads 1` pour recevoir les morceaux un par un, et `--no-progress`.
- Une app lancée depuis le Finder n'hérite pas du `PATH` du terminal : gamdl et ffmpeg sont
  donc localisés explicitement.
- gamdl tourne avec `PYTHONUNBUFFERED=1` pour une progression en temps réel, et stdin fermé :
  une question interactive échoue au lieu de bloquer.
- Avec gamdl 3, la progression se base sur le compteur de fragments HLS de yt-dlp plutôt que
  sur son pourcentage, qui recule à chaque révision de l'estimation de taille.
- gamdl 4 dessine sa progression avec un affichage éphémère qui n'écrit rien dans un pipe.
  L'app le lance donc via `GamdlStudio/Resources/gamdl_bridge.py`, avec le Python de gamdl :
  le script se branche sur cet affichage, écrit chaque début de morceau, transfert et échec en
  JSON, puis passe les arguments au point d'entrée de gamdl. Si un gamdl ultérieur renomme cet
  affichage, gamdl tourne tel quel et l'app se rabat sur les lignes que gamdl écrit à la fin de
  chaque morceau.
- L'annulation envoie `SIGINT` à gamdl et à ses processus enfants, puis `SIGTERM` et `SIGKILL`
  s'ils tournent encore.
- Les playlists personnalisées sont dépliées par `GamdlStudio/Resources/resolve_playlist.py`,
  lancé avec l'interpréteur Python de ton installation de gamdl : l'authentification reste
  l'affaire de gamdl.

## Crédits

- [**gamdl**](https://github.com/glomatico/gamdl), par [glomatico](https://github.com/glomatico),
  fait tout le travail de téléchargement, de déchiffrement et de tags. Gamdl Studio n'en est
  que l'interface : les problèmes de téléchargement sont à signaler à gamdl.
- [FFmpeg](https://ffmpeg.org) et [yt-dlp](https://github.com/yt-dlp/yt-dlp), utilisés par gamdl 3.

## Avertissement

Gamdl Studio est un projet indépendant, sans lien avec Apple Inc. ni avec le projet gamdl, qui
ne l'approuvent ni ne le soutiennent. Apple Music est une marque d'Apple Inc.

À utiliser uniquement avec ton propre abonnement Apple Music, pour un usage personnel, dans le
respect des conditions d'utilisation d'Apple et du droit d'auteur de ton pays. Ne redistribue
pas les contenus téléchargés.

## Licence

[MIT](LICENSE)
