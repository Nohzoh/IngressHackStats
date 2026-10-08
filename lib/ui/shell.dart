import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'capture_tab.dart';
import 'catalog_screen.dart';
import 'stats_tab.dart';

/// Three tabs: Capture (in the field), Stats (analysis), Objets (catalog).
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _controller = AppController();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final repo = _controller.repository;
        return Scaffold(
          body: repo == null
              ? Center(
                  child: _controller.error != null
                      ? Padding(padding: const EdgeInsets.all(24), child: Text('${_controller.error}'))
                      : const CircularProgressIndicator(),
                )
              : IndexedStack(
                  index: _tab,
                  children: [
                    CaptureTab(controller: _controller),
                    StatsTab(controller: _controller),
                    CatalogScreen(repository: repo, controller: _controller),
                  ],
                ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: _controller.running,
                  smallSize: 8,
                  child: const Icon(Icons.radio_button_checked_outlined),
                ),
                label: 'Capture',
              ),
              const NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Stats'),
              const NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'Objets'),
            ],
          ),
        );
      },
    );
  }
}
