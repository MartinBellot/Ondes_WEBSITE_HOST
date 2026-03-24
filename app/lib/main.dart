import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/docker_provider.dart';
import 'providers/sites_provider.dart';
import 'providers/github_provider.dart';
import 'screens/login_screen.dart';
import 'widgets/main_shell.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => DockerProvider()),
        ChangeNotifierProvider(create: (_) => SitesProvider()),
        ChangeNotifierProvider(create: (_) => GitHubProvider()),
      ],
      child: const OndesApp(),
    ),
  );
}

class OndesApp extends StatelessWidget {
  const OndesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ondes',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
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
