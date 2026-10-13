import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'ui/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppleCastApp());
}

class AppleCastApp extends StatelessWidget {
  const AppleCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AppleCast',
      debugShowCheckedModeBanner: false,
      theme: AppleCastTheme.darkTheme,
      home: const HomeScreen(),
    );
  }
}
