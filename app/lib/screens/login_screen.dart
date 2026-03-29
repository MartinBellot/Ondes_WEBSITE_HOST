import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:universal_platform/universal_platform.dart';
import '../theme/app_theme.dart';
import '../utils/server_config.dart';
import '../widgets/glass_card.dart';
import '../providers/auth_provider.dart';
import 'server_setup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final ok = await context.read<AuthProvider>().login(
      _usernameCtrl.text.trim(),
      _passwordCtrl.text,
    );
    if (mounted && !ok) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.read<AuthProvider>().error ?? 'Login failed'),
          backgroundColor: AppColors.accentRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMacOS = UniversalPlatform.isMacOS;

    return Scaffold(
      backgroundColor: isMacOS ? Colors.transparent : null,
      body: Stack(
        children: [
          // ── Background gradient (non-macOS) ─────────────────────────
          if (!isMacOS)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF0D1117), Color(0xFF0D1520), Color(0xFF0D1117)],
                  ),
                ),
              ),
            ),
          // Accent blobs
          if (!isMacOS) ...[
            Positioned(
              top: -100, right: -100,
              child: _Blob(size: 400, color: AppColors.accentBlue.withValues(alpha: 0.07)),
            ),
            Positioned(
              bottom: -60, left: -60,
              child: _Blob(size: 300, color: AppColors.accentPurple.withValues(alpha: 0.05)),
            ),
          ],
          // ── Content ─────────────────────────────────────────────────
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo
                    SizedBox(
                      width: 68,
                      height: 68,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.asset('assets/images/icon.png', fit: BoxFit.contain),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Title
                    Text(
                      'Ondes Host',
                      style: GoogleFonts.poppins(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in to your infrastructure dashboard',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 36),
                    // Glass login card
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: GlassCard(
                        padding: const EdgeInsets.all(32),
                        borderRadius: const BorderRadius.all(Radius.circular(GlassTokens.radiusLg)),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const _FieldLabel('Username'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _usernameCtrl,
                                style: GoogleFonts.inter(
                                  color: AppColors.textPrimary,
                                  fontSize: 14,
                                ),
                                decoration: const InputDecoration(hintText: 'admin'),
                                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                                onFieldSubmitted: (_) => _submit(),
                              ),
                              const SizedBox(height: 20),
                              const _FieldLabel('Password'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _passwordCtrl,
                                obscureText: _obscure,
                                style: GoogleFonts.inter(
                                  color: AppColors.textPrimary,
                                  fontSize: 14,
                                ),
                                decoration: InputDecoration(
                                  hintText: '••••••••',
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 18,
                                      color: AppColors.textMuted,
                                    ),
                                    onPressed: () => setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                                onFieldSubmitted: (_) => _submit(),
                              ),
                              const SizedBox(height: 28),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _loading ? null : _submit,
                                  child: _loading
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation(Colors.white),
                                          ),
                                        )
                                      : const Text('Sign In'),
                                ),
                              ),
                              // Mobile only: allow the user to change the server URL.
                              if (!kIsWeb) ...[
                                const SizedBox(height: 16),
                                _ServerChip(serverUrl: ServerConfig.serverUrl),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mobile: server chip with "change" affordance ─────────────────────────────
class _ServerChip extends StatelessWidget {
  final String? serverUrl;
  const _ServerChip({this.serverUrl});

  @override
  Widget build(BuildContext context) {
    final label = serverUrl != null
        ? serverUrl!.replaceFirst(RegExp(r'^https?://'), '')
        : '—';

    return GestureDetector(
      onTap: () async {
        // Clear the stored URL so main.dart's Consumer routes back to setup.
        await ServerConfig.clear();
        if (context.mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => const ServerSetupScreen(),
            ),
            (_) => false,
          );
        }
      },
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.dns_rounded,
              size: 12,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.edit_rounded,
              size: 11,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Field label ──────────────────────────────────────────────────────────────
class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.textMuted,
        letterSpacing: 0.5,
      ),
    );
  }
}

// ─── Radial accent blob ───────────────────────────────────────────────────────
class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  const _Blob({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, Colors.transparent]),
      ),
    );
  }
}
