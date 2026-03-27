import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/docker_provider.dart';
import 'providers/github_provider.dart';
import 'providers/stacks_provider.dart';
import 'screens/login_screen.dart';
import 'widgets/main_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => DockerProvider()),
        ChangeNotifierProvider(create: (_) => GitHubProvider()),
        ChangeNotifierProvider(create: (_) => StacksProvider()),
      ],
      child: const OndesApp(),
    ),
  );
}

class OndesApp extends StatelessWidget {
  const OndesApp({super.key});

  @override
  Widget build(BuildContext context) {
    // On macOS the NSVisualEffectView (MainFlutterWindow.swift) provides the
    // frosted-glass window background; Flutter's scaffold must be transparent
    // so the native vibrancy shows through.
    final isMacOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final theme = AppTheme().ultraDarkTheme.copyWith(
      scaffoldBackgroundColor:
          isMacOS ? Colors.transparent : AppColors.background,
    );

    return MaterialApp(
      title: 'Ondes',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          if (auth.isLoading) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            );
          }
          return auth.isAuthenticated ? const MainShell() : const LoginScreen();
        },
      ),
    );
  }
}
