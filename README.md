# IngressHackStats

Application Android (Flutter) qui collecte des statistiques sur les loots de hacks Ingress, en lisant le popup de résultat à l'écran (capture d'écran + OCR local).

L'app ne touche ni au client du jeu ni à son trafic réseau : elle lit uniquement ce qui est affiché à l'écran.

## Premier lancement

Le dépôt ne contient que le code propre au projet. Les fichiers générés par Flutter (wrapper Gradle, `settings.gradle.kts`, ressources Android…) se créent avec :

```bash
flutter create --org com.nohzoh --project-name ingress_hack_stats --platforms android .
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

## Calibration (à faire en premier)

Le parseur a été écrit sans captures réelles du popup de hack : les noms d'items, le format des quantités (`x2`, `×2`…) et la façon dont ML Kit découpe les lignes doivent être vérifiés sur de vrais hacks.

1. Active le **mode calibration** : tout texte lu à l'écran est enregistré, même s'il n'est pas reconnu comme un hack.
2. Fais quelques hacks (normaux et glyph), puis ouvre l'écran **Captures** (icône liste) pour voir le texte brut et ce que le parseur en a tiré.
3. Ajuste `lib/parsing/item_catalog.dart` (alias, marqueurs d'écrans à ignorer) et `lib/parsing/hack_parser.dart` (quantités, niveaux, ligne « bonus »), en ajoutant les cas réels dans `test/hack_parser_test.dart`.
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

Un même popup lu sur plusieurs images n'est compté qu'une fois, grâce à deux filtres : côté natif (texte identique sous 10 s), puis côté Dart (même loot sous 20 s, marqué `duplicate`).

## Limites connues

- Batterie : OCR plein écran une fois par seconde, plus le GPS. À mesurer ; on pourra limiter l'OCR à la zone du popup une fois sa position connue.
- Les CGU de Niantic interdisent largement les « logiciels tiers ». Cette app reste passive (lecture d'écran), mais mieux vaut la garder pour un usage personnel ou la présenter comme un outil de prise de notes.
