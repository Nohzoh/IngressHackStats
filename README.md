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

1. Ouvre l'app et appuie sur **Démarrer**. Accepte les autorisations (notifications, localisation), puis le partage d'écran en choisissant **Écran entier**. Si tu choisis une seule app, Android l'ouvre aussitôt et la capture ne démarre qu'à ton retour dans Ingress Hack Stats.
2. Passe sur Ingress et hacke normalement. Une notification indique que la capture tourne ; elle permet aussi de l'arrêter.
3. Reviens dans l'app : les captures sont analysées et les statistiques s'affichent.

**Sans quitter le jeu** : la tuile « Capture hacks » des réglages rapides (le volet déroulé du haut de l'écran) démarre ou arrête la capture. Sur Android 13+, le bouton « Ajouter » de l'app la place directement ; sinon, l'ajouter en modifiant les réglages rapides. Android demande quand même son accord de partage d'écran à chaque démarrage : la fenêtre s'ouvre par-dessus le jeu puis se referme.

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

Le niveau du portail n'est pas affiché : il est estimé, pour chaque récompense, comme le niveau le plus fréquent parmi ses items (pondéré par la quantité), avec un tirage déterministe en cas d'égalité. Attention au biais : filtrer sur « P5 » sélectionne les récompenses où le L5 domine, donc la répartition des niveaux d'items sous ce filtre est biaisée par construction. Le filtre reste fiable pour les items sans niveau (mods, clés…).

La qualité des glyphes vient de l'écran de fin de séquence (« HACKING BONUS / SPEED BONUS », avec la commande éventuelle, ex. MORE), rattaché à la récompense bonus qui suit (moins de 90 s) :
- vitesse > 0 % : séquence parfaite ;
- hacking > 0 % mais vitesse à 0 % : partielle ;
- hacking à 0 % : ratée ;
- écran non capté : inconnue.

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
  MainActivity.kt     canal Flutter, autorisations, consentement de capture
  CaptureService.kt   service de premier plan : MediaProjection → ImageReader
                      → OCR ML Kit (1 image/s max) → pré-filtre par mots-clés
                      → dédoublonnage → GPS → file d'attente
  PendingStore.kt     file JSONL sur disque entre le service et Dart

lib/
  capture/capture_channel.dart   MethodChannel vers le natif
  models/ocr_capture.dart        capture OCR (lignes + positions + GPS)
  parsing/item_catalog.dart      catalogue des items et de leurs alias
  parsing/hack_parser.dart       lignes OCR → items (niveau, rareté, quantité, bonus)
  data/reward_repository.dart    SQLite : images brutes, récompenses et leurs items
  stats/reward_stats.dart        chances, parts, marges, vue Hack + glyph calculée
  ui/                            écran principal et écran des captures
```

Les captures brutes (texte et positions) sont conservées, ce qui permet de ré-analyser tout l'historique quand le parseur s'améliore.

Un même popup est lu sur plusieurs images, et l'OCR ne le lit pas toujours à l'identique (un « L8 » manqué change le contenu). Il est donc reconnu à son contexte plutôt qu'à son contenu exact (`lib/data/popup_linker.dart`) :
- récompense normale : même portail relu dans les 60 s ;
- récompense bonus : aucune nouvelle récompense normale ni écran de fin de glyph depuis le bonus précédent, relu dans les 30 s.

Parmi les lectures d'un même popup, la plus complète (items, niveaux, raretés) est gardée.

## Dépannage

La carte **Diagnostic** de l'écran principal montre les compteurs de la chaîne (images, OCR, texte lu, captures gardées) et un **journal du service** conservé même si l'app plante : consentement, démarrage, arrêt par le système, erreurs avec leur origine.

## Limites connues

- Batterie : OCR plein écran jusqu'à 4 fois par seconde (réglable : ¼, ½ ou 1 s), plus le GPS. Une seule analyse tourne à la fois, donc la cadence réelle est aussi plafonnée par la vitesse de l'OCR (visible dans le diagnostic). Piste : limiter l'OCR à la zone du popup.
- Biais de capture : les popups fermés très vite sont plus souvent manqués. Si tu restes plus longtemps sur un loot intéressant, il a plus de chances d'être capturé : c'est pour réduire ce biais que la fréquence d'analyse est élevée.
- Les CGU de Niantic interdisent largement les « logiciels tiers ». Cette app reste passive (lecture d'écran), mais mieux vaut la garder pour un usage personnel ou la présenter comme un outil de prise de notes.
