# IngressHackStats

Application Android (Flutter) qui collecte des statistiques sur les loots de hacks Ingress, en lisant le popup de résultat à l'écran (capture d'écran + OCR local).

L'app ne touche ni au client du jeu ni à son trafic réseau : elle lit uniquement ce qui est affiché à l'écran.

## Premier lancement

Le dépôt ne contient que le code propre au projet. Les fichiers générés par Flutter (wrapper Gradle, `settings.gradle.kts`, ressources Android…) se créent avec :

```bash
flutter create --org io.nohzoh --project-name ingress_hack_stats --platforms android .
flutter pub get
flutter test
flutter run
```

`flutter create` ne remplace pas les fichiers existants : il ajoute seulement ceux qui manquent. Vérifie avec `git status` que seuls des fichiers nouveaux apparaissent.

Android 10 (API 29) minimum.

## Signature de l'APK (CI)

Pour qu'une nouvelle version s'installe par-dessus l'ancienne, tous les APK doivent être signés avec la même clé. Le CI la lit dans les secrets du repo :

```bash
keytool -genkeypair -v -keystore ingress-hack-stats.jks -alias ingresshackstats \
  -keyalg RSA -keysize 2048 -validity 10000

base64 -w0 ingress-hack-stats.jks | gh secret set ANDROID_KEYSTORE_BASE64   # macOS : base64 -i ingress-hack-stats.jks
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS --body ingresshackstats
gh secret set ANDROID_KEY_PASSWORD
```

Garde le fichier `.jks` et ses mots de passe en lieu sûr, hors du repo : sans eux, plus aucune mise à jour ne pourra s'installer sans désinstaller l'app (et perdre ses données).

## Utilisation

L'app a trois onglets :
- **Capture** (sur le terrain) : gros bouton Démarrer/Arrêter, compteurs de la session, dernières récompenses captées (la preuve que ça marche), alertes en cas de problème (capture coupée, aucune image, rien de reconnu, OCR lent), et au premier lancement une liste « Pour bien démarrer » (autorisations, tuile, première récompense).
- **Stats** : type de récompense (Normale / Bonus / Hack + glyph), filtres repliés dans une puce (Ito En, niveau du portail, qualité du glyph), taille d'échantillon, puis objets groupés par famille (Armes, Résonateurs, Cubes, Mods, Clés, Spéciaux). Chaque objet se déplie par niveau ou rareté et mène à sa fiche par niveau de portail.
- **Objets** : catalogue avec recherche (abréviations comprises), vers la fiche de chaque objet.

La roue dentée ouvre les **Réglages** : fréquence d'analyse, tuile, autorisations, mode calibration, **historique des récompenses** (pour supprimer une récompense mal lue, qui ne reviendra pas après une ré-analyse), images brutes, et le diagnostic avec son journal (bouton Copier).

1. Appuie sur **Démarrer** (ou la tuile « Capture hacks » depuis le jeu), accepte le partage d'écran en choisissant **Écran entier**.
2. Passe sur Ingress et hacke normalement.
3. Les récompenses apparaissent dans l'onglet Capture ; les stats se mettent à jour.

L'OCR est mis en pause tant que l'app elle-même est à l'écran, pour ne pas lire ses propres statistiques.

## Format du popup de hack

Calibré sur de vraies captures (Ingress Prime, interface en anglais) :

```
Szlama Ejzman                         ← nom du portail
ITO EN (-) applied.                   ← seulement avec un transmuter
L1 x1 Power Cube   |  L1 x1 Resonator ← deux colonnes : niveau, quantité, nom
```

Si le portail porte un Ito En, une ligne « ITO EN (+) applied. » ou « ITO EN (-) applied. » s'intercale entre le titre et les items (dans les deux popups) : elle alimente le filtre Ito En.

Un glyph hack affiche ensuite un second popup, intitulé « Bonus items: », avec la même mise en forme.

## Modèle : la récompense

L'unité de base est la **récompense** : un popup = une récompense, normale ou bonus de glyph. Les deux popups d'un glyph hack ne sont pas regroupés : chacun est une récompense avec ses propres propriétés (portail, Ito En, niveau estimé).

Statistiques par item, pour le type de récompense choisi :
- **chance** qu'une récompense contienne l'item, avec sa marge à 95 % (intervalle de Wilson) ;
- **part** de l'item parmi tous les items reçus : comparable même si la taille des récompenses varie (un bonus contient d'autant plus d'items que la séquence de glyphes est réussie) ;
- **quantité moyenne** par récompense.

La vue **Hack + glyph** est calculée : ce qu'un joueur reçoit en tout sur un glyph hack (une récompense normale + une bonus), en supposant les deux tirages indépendants. Chance d'avoir l'item : 1 − (1 − p_normale)(1 − p_bonus).

**Fiche d'un objet** (en touchant une ligne des stats, ou depuis le catalogue « Objets ») : une grille avec le niveau du portail en lignes et, en colonnes, le niveau de l'objet (ou sa rareté) × type de récompense (Normale, Bonus, Hack + glyph). Colonnes masquables, défilement horizontal. Chaque case affiche « x / réc. » si l'objet sort au moins une fois sur deux, sinon « 1/N » (une récompense sur N en moyenne) ; grisée sous 30 récompenses. Ici, le niveau du portail est estimé **sans l'objet étudié** (leave-one-out), pour éviter qu'un « XMP L8 » ne classe lui-même sa récompense en P8.

Le niveau du portail n'est pas affiché dans le popup. **Quand la récompense contient un Power Cube, son niveau est celui du portail** (contrairement aux résonateurs et armes, qui s'étalent à ±2) : le niveau est alors certain. Sinon, il est estimé comme le niveau le plus fréquent parmi les objets reçus (pondéré par la quantité), avec un tirage déterministe en cas d'égalité. Réglages → « Fiabilité du niveau de portail » compare, sur les récompenses avec un cube, le vrai niveau à l'estimation faite sans le cube : c'est la précision de l'estimation pour les récompenses sans cube. Attention au biais de l'estimation : filtrer sur « P5 » sélectionne les récompenses où le L5 domine, donc la répartition des niveaux d'items sous ce filtre est biaisée (sauf quand le niveau vient d'un cube).

La qualité des glyphes vient de l'écran de fin de séquence (« HACKING BONUS / SPEED BONUS », avec la commande éventuelle, ex. MORE), rattaché à la récompense bonus qui suit (moins de 90 s) :
- vitesse > 0 % : séquence parfaite ;
- hacking > 0 % mais vitesse à 0 % : partielle ;
- hacking à 0 % : ratée ;
- écran non capté : inconnue.

**Rareté des mods** (bouclier, heat sink, multi-hack…) : elle n'est pas écrite mais dessinée, avec trois barres obliques à gauche de la quantité, dont 1 (commun), 2 (rare) ou 3 (très rare) sont colorées. Le service lit les pixels de cette zone (repérée grâce à la position du mot « x1 » donnée par l'OCR) et compte les barres vives. Le résultat est inséré dans le texte sous la forme `§r<barres>:<teinte>` (ex. `§r1:160 x1 Portal Shield`), visible dans l'écran Captures pour vérifier le comptage et la couleur. Les captures enregistrées avant cette version n'ont pas cette information.

Seul le texte de la forme `[niveau|rareté] x<quantité> <nom>` est retenu, ce qui écarte le COMM et les alertes affichés autour.

Points encore à vérifier sur de vrais hacks : le format des items sans niveau (mods, clés, capsules) et la lecture de la rareté.

## Calibration

1. Active le **mode calibration** : tout texte lu à l'écran est enregistré, même s'il n'est pas reconnu comme un hack.
2. Fais quelques hacks, puis ouvre l'écran **Captures** (icône liste) pour voir le texte brut et ce que le parseur en a tiré.
3. Ajuste `lib/parsing/item_catalog.dart` (alias, marqueurs d'écrans à ignorer) et `lib/parsing/hack_parser.dart`, en ajoutant les cas réels dans `test/hack_parser_test.dart`.
4. Bouton **Ré-analyser** : relance le parseur sur toutes les captures stockées, sans avoir à refaire les hacks.

Désactive le mode calibration ensuite : il enregistre tout ce qui s'affiche à l'écran.

Le jeu doit être en anglais pour l'instant (le catalogue ne contient que les noms anglais).

## Architecture

```
android/app/src/main/kotlin/…/
  MainActivity.kt                canal Flutter, autorisations, consentement, tuile
  CaptureService.kt              service de premier plan : MediaProjection → ImageReader
                                 → OCR ML Kit sur une bande d'écran → pré-filtre
                                 → dédoublonnage → GPS → file d'attente
  RarityMarks.kt                 rareté des mods lue sur les pixels (barres colorées)
  CaptureTileService.kt          tuile des réglages rapides
  ProjectionRequestActivity.kt   consentement de capture par-dessus le jeu
  PendingStore.kt                file JSONL sur disque entre le service et Dart
  ServiceLog.kt, Diagnostics.kt  journal persistant et compteurs

lib/
  capture/capture_channel.dart   MethodChannel vers le natif
  models/ocr_capture.dart        capture OCR (lignes + positions + GPS)
  parsing/                       catalogue, parseur des popups, niveau du portail
  data/reward_repository.dart    SQLite : images brutes, récompenses et leurs items
  data/popup_linker.dart         doublons et liens entre écrans (fin de glyph → bonus)
  stats/                         chances, marges, fiche objet (grille)
  ui/app_controller.dart         état partagé (service, base, synchronisation)
  ui/shell.dart                  onglets Capture / Stats / Objets
  ui/…                           onglets, fiche objet, réglages, historique, images brutes
```

Les captures brutes (texte et positions) sont conservées, ce qui permet de ré-analyser tout l'historique quand le parseur s'améliore.

Un même popup est lu sur plusieurs images, et l'OCR ne le lit pas toujours à l'identique (un « L8 » manqué change le contenu). Il est donc reconnu à son contexte plutôt qu'à son contenu exact (`lib/data/popup_linker.dart`) :
- récompense normale : même portail relu dans les 60 s ;
- récompense bonus : aucune nouvelle récompense normale ni écran de fin de glyph depuis le bonus précédent, relu dans les 30 s.

Parmi les lectures d'un même popup, la plus complète (items, niveaux, raretés) est gardée.

## Dépannage

La carte **Diagnostic** de l'écran principal montre les compteurs de la chaîne (images, OCR, texte lu, captures gardées) et un **journal du service** conservé même si l'app plante : consentement, démarrage, arrêt par le système, erreurs avec leur origine.

## Limites connues

- Zone analysée : seule la bande entre 20 % et 65 % de la hauteur de l'écran passe à l'OCR (popups, fin de glyph, gain d'AP), ce qui le rend 2 à 3 fois plus rapide. En mode calibration, tout l'écran est lu.
- Verrouiller l'écran coupe le partage d'écran (Android 15+) : une notification « Capture interrompue » permet de relancer d'un toucher.
- Batterie : OCR plein écran jusqu'à 4 fois par seconde (réglable : ¼, ½ ou 1 s), plus le GPS. Une seule analyse tourne à la fois, donc la cadence réelle est aussi plafonnée par la vitesse de l'OCR (visible dans le diagnostic). Piste : limiter l'OCR à la zone du popup.
- Biais de capture : les popups fermés très vite sont plus souvent manqués. Si tu restes plus longtemps sur un loot intéressant, il a plus de chances d'être capturé : c'est pour réduire ce biais que la fréquence d'analyse est élevée.
- Les CGU de Niantic interdisent largement les « logiciels tiers ». Cette app reste passive (lecture d'écran), mais mieux vaut la garder pour un usage personnel ou la présenter comme un outil de prise de notes.
