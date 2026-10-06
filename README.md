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

## Utilisation

1. Ouvre l'app et appuie sur **Démarrer**. Accepte les autorisations (notifications, localisation), puis le partage d'écran. Sur Android 14+, choisis « Tout l'écran » ou l'app Ingress.
2. Passe sur Ingress et hacke normalement. Une notification indique que la capture tourne ; elle permet aussi de l'arrêter.
3. Reviens dans l'app : les captures sont analysées et les statistiques s'affichent.

L'OCR est mis en pause tant que l'app elle-même est à l'écran, pour ne pas lire ses propres statistiques.

## Format du popup de hack

Calibré sur de vraies captures (Ingress Prime, interface en anglais) :

```
Szlama Ejzman                         ← nom du portail
L1 x1 Power Cube   |  L1 x1 Resonator ← deux colonnes : niveau, quantité, nom
```

Un glyph hack affiche ensuite un second popup, intitulé « Bonus items: », avec la même mise en forme. L'app le rattache au hack précédent (moins de 60 s) : ses items sont comptés comme bonus et le hack est marqué « glyph ».

Le popup n'indique pas le niveau du portail : il est estimé comme le niveau le plus fréquent parmi les items reçus (bonus compris, pondéré par la quantité), avec un tirage déterministe en cas d'égalité. Attention au biais : filtrer sur « P5 » sélectionne les hacks où le L5 domine, donc la répartition des niveaux d'items sous ce filtre est biaisée par construction. Le filtre reste fiable pour les items sans niveau (mods, clés…).

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
  data/hack_repository.dart      SQLite : captures brutes + items, statistiques
  ui/                            écran principal et écran des captures
```

Les captures brutes (texte et positions) sont conservées, ce qui permet de ré-analyser tout l'historique quand le parseur s'améliore.

Un même popup lu sur plusieurs images n'est compté qu'une fois, grâce à deux filtres : côté natif (texte identique sous 10 s), puis côté Dart (même portail et même loot sous 20 s, marqué `duplicate`).

## Limites connues

- Batterie : OCR plein écran une fois par seconde, plus le GPS. À mesurer ; on pourra limiter l'OCR à la zone du popup une fois sa position connue.
- Les CGU de Niantic interdisent largement les « logiciels tiers ». Cette app reste passive (lecture d'écran), mais mieux vaut la garder pour un usage personnel ou la présenter comme un outil de prise de notes.
