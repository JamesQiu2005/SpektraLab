# Develop

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · **Français** · [Português (Brasil)](README.pt-BR.md)

> *« Je photographie à la fois en hybride et en argentique, et je peux dire honnêtement que les résultats de Develop
> ressemblent à du vrai film. Il ne peint pas un rendu film par-dessus une photo avec des courbes et des LUT : il expose
> les couches de colorants du film à la lumière de la scène, les développe et tire le négatif sur papier, comme en
> chambre noire. Ce qui en sort n'est pas une imitation du film. C'est ce que ce film aurait fait de la même lumière. »*
> **jegly**, photographe et auteur de Develop

Une chambre noire d'émulation argentique pour Linux. Ouvrez un RAW ou un JPEG, choisissez un film et un papier, et
obtenez un tirage modélisé physiquement : la lumière est suivie à travers les couches de colorants du film et du papier,
avec le grain, le halo, les coupleurs DIR et le jeu de filtres de l'agrandisseur, rendue sur votre GPU via Vulkan.

**Develop est un fork Linux non officiel de [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)**,
dont le moteur dérive de [spektrafilm](https://github.com/andreavolpato/spektrafilm), d'Andrea Volpato. Il n'est affilié
à aucun de ces deux projets ni approuvé par eux. Le modèle de film, les profils mesurés et le modèle de tirage et de scan
sont les leurs ; Develop est le portage Linux et l'application construite dessus.

**Sur Mac, iPhone ou iPad ? Utilisez [SpektraLab](https://github.com/JamesQiu2005/SpektraLab).** Develop est fait pour
Linux et Android ; SpektraLab est l'application d'origine, conçue pour les appareils Apple.

![Develop sous Ubuntu : une photo de rue sur Ilford Delta 100, tirée sur Ilford Multigrade IV RC](screenshots/develop.png)

## Ce qu'il fait

- **130 films et papiers** : négatifs couleur, diapositives, films cinéma et noir et blanc, tirés sur papier couleur ou
  Multigrade, ou scannés. Triés par marque.
- **Tout le moteur sur Vulkan** : chaque effet de l'application Mac est rendu sous Linux, y compris le bord de film et le
  dos dateur, les aberrations d'objectif et les filtres de diffusion, les fuites de lumière, le Digital Intermediate, les
  calques de scène locaux et le scan HDR de diapositives.
- **L'éditeur montre ce qui est exporté** : l'image à l'écran est le fichier que vous obtenez.
- Paires demi-format, doubles expositions, TSL, mélangeur de couches, vibrance, filigranes, fuites de lumière, caractères
  d'objectif et bord de film, comme dans l'application Mac de SpektraLab.
- Export en JPEG, PNG et TIFF 16 bits en sRGB, Display P3, Adobe RGB ou ProPhoto.

## En quoi Develop diffère de SpektraLab

SpektraLab est une application Mac sur Metal. Son dépôt contient aussi des visionneuses Windows et un moteur qui se compile
sous Linux, mais sous Linux et Windows ce moteur refusait de nombreux effets du Mac. Develop est un éditeur Linux complet
construit sur ce moteur.

**Ce que Develop ajoute**

| | Develop | SpektraLab |
|---|---|---|
| Éditeur de bureau Linux | oui, avec un `.deb` et un snap | moteur et hôte seulement |
| Effets du moteur sur Vulkan (Linux, Windows) | tous : bord de film et dos dateur, Digital Intermediate, latitude de scène, masque de contraste, aberrations d'objectif et filtres de diffusion, fuites de lumière, calques de scène, scan HDR de diapositives | la plupart refusés |
| Couleur sur Vulkan | corrigée : une dominante rouge sur chaque rendu Vulkan depuis la 2.4.0 (un mode de flou absent des noyaux Vulkan) | dominante rouge |
| Films et papiers | 130, dont 93 nouveaux profils de film construits à partir des fiches techniques publiées par les fabricants | 38 |
| Réseau | aucun : bloqué par un filtre seccomp, pas de recherche de mises à jour | recherche les mises à jour |
| Correction d'objectif | la base de données de lensfun, plus « Mes objectifs » pour les objectifs manuels qu'elle ne connaît pas | sur Mac seulement |
| Calques locaux | masques dégradés, radiaux et image entière pour l'exposition et la chaleur, sur les calques de scène du moteur | (fonction du moteur) |
| Mises en page multi-photos | diptyques, triptyques, grilles et photogrammes de cinéma, avec espacements et bordures | non |
| Bordures | une marge de tirage de n'importe quel gris | non |
| Panneau avancé | contraste de développement, douceur de l'objectif et du scanner, réserve dans les hautes lumières, points blanc et noir du scanner | non exposé |

**Ce que SpektraLab a et que Develop n'a pas**

- La photothèque, la lecture des catalogues Capture One et la Light Table.
- Le HDR : afficher une image sur un écran HDR et exporter des fichiers HDR (gain map). Le scan HDR de diapositives du
  moteur est porté, mais la vue web de Linux ne peut pas afficher le HDR.
- La recherche de mises à jour. Omise volontairement : Develop n'a pas d'accès réseau.
- L'application iPhone et iPad, et les versions Mac et Windows.

## Comment les nouveaux films ont été faits

SpektraLab fournit les 28 profils mesurés de spektrafilm et quelques profils à lui. Develop ajoute 93 profils de film, la
plupart pour des films arrêtés depuis longtemps, reconstitués à partir des fiches techniques publiées par leurs fabricants :
le *Professional Data Guide* de Fujifilm (2005), les publications techniques de Kodak sur les négatifs cinéma VISION, les
diapositives EKTACHROME, ELITE Chrome et KODACHROME et ses négatifs photo, et les fiches noir et blanc d'Ilford/HARMAN et de
Fujifilm.

1. **Lire les courbes sur les fiches.** Pour chaque film : sa sensibilité spectrale (la réponse de chaque couche à chaque
   longueur d'onde), ses courbes caractéristiques (densité en fonction de l'exposition) et ses densités spectrales de
   colorants (la couleur que chaque colorant absorbe). La plupart des fiches sont des PDF qui stockent leurs graphiques
   sous forme de tracés vectoriels, donc les numériseurs de `engine/tools/fujifilm_data_guide/` lisent les courbes
   directement dans ces tracés. Chaque axe est calé sur les lignes de grille et les étiquettes du graphique lui-même, ce
   qui ne laisse que l'erreur de dessin de l'éditeur. Les graphiques qui ne sont que des images sont décalqués à 600 dpi.
2. **En faire des profils.** Les courbes passent par la propre fabrique de profils de spektrafilm, puis par les mêmes
   règles que les profils publiés de spektrafilm. Chaque ajustement qui dépend du moteur (le jeu de filtres du papier, la
   rampe de gris, le grain) est calculé par le moteur lui-même. Quand une fiche omet quelque chose (certaines fiches VISION
   n'ont pas de courbe neutre ni de courbe D-min), c'est déduit des propres données du film, et le `metadata` du profil
   l'indique.
3. **Vérifier la méthode sur des films comparables.** La même chaîne a été appliquée aux données brutes de spektrafilm
   pour des films qu'il possède déjà. Pro 400H, Velvia 100, Vision3 500T, Kodachrome 64 et Ektachrome 100 se situent entre
   ΔE2000 1,0 et 2,1 (moyenne, sur un ColorChecker) des profils mesurés de spektrafilm. Le numériseur reproduit aussi les
   courbes brutes du Kodachrome 64 de spektrafilm à partir de la fiche Kodak à 0,009 près.

Chaque profil indique sa publication source et ses erreurs d'ajustement dans son `metadata`, et
`engine/resources_product/NOTICE.md` les liste tous. Ce sont des reconstitutions à partir de données publiées, pas des
mesures de vrai film. Elles sont aussi proches de chaque film que la fiche de son fabricant le permet.

## Pas de réseau, par conception

Develop ne peut pas accéder à Internet. Un filtre seccomp installé avant que quoi que ce soit d'autre ne démarre n'autorise
que les sockets locaux, et l'application refuse de se lancer si le filtre ne peut pas être mis en place. Il s'applique à la
fenêtre, à sa vue web et au moteur. Il n'y a ni recherche de mises à jour, ni télémétrie, ni polices distantes, ni comptes.
Vos photos ne quittent jamais votre machine.

## Branches

| Branche | Ce que c'est |
|---|---|
| `main` | Develop pour Linux, et le moteur sur lequel reposent toutes les applications |
| `camera` | Develop Camera : un appareil photo argentique pour Android, dans `camera/` |
| `android` | L'éditeur de Develop sur Android (en cours) |

Chaque branche d'application part de `main`, donc les corrections du moteur les atteignent toutes.

## Develop Camera (Android)

Un appareil photo argentique pour Android 17 qui photographie à travers les modèles de film de Develop. Choisissez l'un des
121 films de Develop et voyez-le en direct dans le viseur. Chaque photo est ensuite développée par le même moteur, sur le
GPU du téléphone : le film, son papier, le grain, le halo et le reste, comme dans l'application de bureau.

- Développé à partir des données RAW du capteur, avec les corrections propres à l'appareil pour chaque image.
- Grain, halo, filtres de diffusion, caractères d'objectif, filtres noir et blanc, poussé et retenu, fuites de lumière,
  bord de film et dos dateur.
- 35 mm, paires demi-format, XPan, triptyques et expositions multiples, et le 120 de 6×4,5 à 6×17.
- Auto avec mémorisation de l'exposition, ou vitesse et ISO manuels.
- Ne demande que l'autorisation d'accès à l'appareil photo et n'a pas d'accès réseau. Les photos vont dans
  `DCIM/Develop Camera`.

Testé sur un Pixel 11 Pro Fold. Son GPU sautait trois des noyaux d'objectif du moteur, ce qui rendait noir chaque rendu
avec diffusion ; ces noyaux sont corrigés sur `main`. Les étapes de compilation sont dans `camera/BUILD.md`.

## L'éditeur de Develop sur Android

Un portage de l'éditeur Linux sur Android, sur la branche `android`. Il garde la disposition de bureau, avec des
corrections pour le tactile. Il n'est pas encore prêt à l'emploi.

## Installation

Téléchargez le `.deb` ou le snap depuis la [dernière version](https://github.com/jegly/Develop/releases/latest), puis installez l'un des deux :

```sh
sudo apt install ./Develop_1.0.0_amd64.deb
sudo snap install --dangerous ./develop_1.0.0_amd64.snap
```

Le snap a besoin de `--dangerous` parce qu'il est installé depuis un fichier, et non depuis le Snap Store. Vous pouvez aussi le compiler depuis les sources (ci-dessous).

Develop a besoin d'un GPU avec un pilote Vulkan. Il a été développé sous Ubuntu 26.04 avec une carte graphique Intel
(Mesa). Le `.deb` installe `libvulkan1`, `liblensfun1`, `liblensfun-data-v1`, `fonts-urw-base35`,
`fonts-liberation-sans-narrow` et `fonts-dejavu-core`. Le snap embarque ses propres copies.

## Compilation

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

La compilation demande un compilateur C++20, CMake, Ninja, les en-têtes Vulkan et `glslangValidator`, Node 22 avec npm,
Rust (stable), les paquets de développement WebKitGTK 4.1 que demande Tauri, et `liblensfun-dev` pour la correction
d'objectif (il compile sans, moins cette fonction).

## Tests

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

Les vérifications du moteur du projet d'origine (`engine/tests/*_checks.py`) tournent aussi sur le moteur Linux.

## Crédits et licence

**Develop est basé sur SpektraLab, dont le moteur dérive de spektrafilm, d'Andrea Volpato (GPL-3.0-or-later).** Les 28
profils mesurés de films et de papiers de spektrafilm et les LUT de tirage sont utilisés sans modification. Les autres
profils sont construits à partir des fiches techniques publiées par les fabricants (`engine/resources_product/NOTICE.md`).
Les noms de films et de papiers sont des marques de leurs propriétaires ; ils indiquent à partir de quelles données
publiées un profil a été construit.

| | |
|---|---|
| l'application et le moteur | GPL-3.0-or-later (`license/LICENSE`) |
| les profils de films et de papiers de spektrafilm, les LUT de tirage | CC BY-SA 4.0 (`license/SPEKTRAFILM_LICENSE.txt`) |
| lensfun (lié, et sa base de données d'objectifs) | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | domaine public / MIT |

SpektraLab™ et son icône appartiennent à leurs propriétaires. Develop utilise son propre nom et sa propre icône, comme les
termes de la licence de SpektraLab le demandent aux forks publiés.
