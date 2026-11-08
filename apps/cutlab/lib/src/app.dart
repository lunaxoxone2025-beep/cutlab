import 'package:flutter/material.dart';

import 'screens/library_screen.dart';
import 'services.dart';
import 'theme.dart';

class CutlabApp extends StatelessWidget {
  const CutlabApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CUTLAB',
      debugShowCheckedModeBanner: false,
      theme: buildCutlabTheme(),
      home: LibraryScreen(services: services),
    );
  }
}
