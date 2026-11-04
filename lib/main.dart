import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'ui/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InfinityCastApp());
}

class InfinityCastApp extends StatelessWidget {
  const InfinityCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InfinityCast',
      debugShowCheckedModeBanner: false,
      theme: AppleCastTheme.darkTheme,
      home: const HomeScreen(),
    );
  }
}
