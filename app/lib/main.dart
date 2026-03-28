import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/docker_provider.dart';
import 'providers/github_provider.dart';
import 'providers/stacks_provider.dart';
import 'screens/login_screen.dart';
import 'screens/server_setup_screen.dart';
import 'utils/server_config.dart';
import 'widgets/main_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the persisted server URL before any provider is instantiated so that
  // ApiService and WebSocketService can pick it up synchronously.
  await ServerConfig.init();
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

    // Mobile platforms require the user to enter the server URL on first launch.
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    return MaterialApp(
      title: 'Ondes',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          // Step 1 (mobile only): server URL not configured yet.
          if (isMobile && !ServerConfig.isConfigured) {
            return const ServerSetupScreen();
          }

          // Step 2: waiting for the session-restore check.
          if (auth.isLoading) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            );
          }

          // Step 3: authenticated → main shell; otherwise → login.
          return auth.isAuthenticated ? const MainShell() : const LoginScreen();
        },
      ),
    );
  }
}
