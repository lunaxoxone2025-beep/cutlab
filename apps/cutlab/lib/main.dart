import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.create();
  runApp(CutlabApp(services: services));
}
