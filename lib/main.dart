import 'package:flutter/material.dart';

import 'app.dart';
import 'state/home_store.dart';
import 'state/repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = HomeStore(repository: LocalHomeRepository());
  await store.load();
  runApp(SmartMenuApp(store: store));
}
