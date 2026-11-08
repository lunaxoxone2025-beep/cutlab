import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'theme.dart';

class CutlabApp extends StatelessWidget {
  const CutlabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CUTLAB',
      debugShowCheckedModeBanner: false,
      theme: buildCutlabTheme(),
      home: const HomeScreen(),
    );
  }
}
