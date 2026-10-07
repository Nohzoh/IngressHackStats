import 'package:flutter/material.dart';

import '../data/reward_repository.dart';
import '../parsing/item_catalog.dart';
import 'item_detail_screen.dart';

/// Every known item (catalog + items seen), to open its detail.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.repository});

  final RewardRepository repository;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  late final Future<List<(String, int)>> _items = widget.repository.knownItems();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Objets')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Rechercher (ex. MH, heat sink)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<(String, int)>>(
              future: _items,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
                final items = snapshot.data;
                if (items == null) return const Center(child: CircularProgressIndicator());
                final shown = [for (final i in items) if (matchesQuery(i.$1, _query)) i];
                return ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final (name, count) = shown[index];
                    return ListTile(
                      title: Text(name),
                      subtitle: Text(count == 0 ? 'jamais vu' : 'dans $count récompenses'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ItemDetailScreen(repository: widget.repository, item: name),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Search on the name, its OCR aliases and its initials, so the usual
/// abbreviations work: "mh" finds Multi-hack, "hs" Heat Sink, "us" Ultra Strike.
bool matchesQuery(String name, String query) {
  if (query.isEmpty) return true;
  final q = query.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '');
  if (q.isEmpty) return true;
  final lower = name.toLowerCase();
  if (lower.contains(query.toLowerCase())) return true;
  final words = lower.split(RegExp(r'[\s-]+')).where((w) => w.isNotEmpty);
  final initials = words.map((w) => w[0]).join();
  if (initials.startsWith(q)) return true;
  if (_abbreviations[q] == name) return true;
  for (final type in kItemCatalog) {
    if (type.name == name && type.aliases.any((a) => a.replaceAll('-', ' ').contains(q))) return true;
  }
  return false;
}

/// Abbreviations that are not plain initials.
const _abbreviations = {
  'sbul': 'SoftBank Ultra Link',
  'ul': 'SoftBank Ultra Link',
  'frack': 'Portal Fracker',
  'cube': 'Power Cube',
  'hc': 'Hypercube',
};
