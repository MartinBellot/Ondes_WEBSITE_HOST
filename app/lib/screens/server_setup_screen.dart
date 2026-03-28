import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

/// First-launch screen shown on mobile (iOS / Android) before the login screen.
/// The user enters the base URL of their self-hosted Ondes HOST instance,
/// which is then persisted via [AuthProvider.configureServerUrl].
class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();
  bool _loading = false;
  String? _errorMsg;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  /// Validates that [url] is a well-formed http(s) URL.
  String? _validateUrl(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    final cleaned = value.trim();
    final uri = Uri.tryParse(cleaned);
    if (uri == null || (!uri.scheme.startsWith('http'))) {
      return 'Enter a valid URL starting with http:// or https://';
    }
    if (uri.host.isEmpty) return 'URL must include a host';
    return null;
  }

  /// Pings the server's health endpoint to confirm it is reachable.
  Future<bool> _testConnection(String baseUrl) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));
      // Try both /api/ and /api/auth/ — any 2xx or 4xx means the server is up.
      final res = await dio.get('$baseUrl/api/auth/login/');
      return res.statusCode != null;
    } on DioException catch (e) {
      // 405 Method Not Allowed from a GET on the login endpoint = server is there.
      if (e.response?.statusCode != null) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _errorMsg = null;
    });

    var url = _urlCtrl.text.trim();
    // Strip trailing slashes for clean storage.
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    final reachable = await _testConnection(url);
    if (!mounted) return;

    if (!reachable) {
      setState(() {
        _loading = false;
        _errorMsg =
            'Cannot reach the server. Check the URL and your internet connection.';
      });
      return;
    }

    await context.read<AuthProvider>().configureServerUrl(url);
    if (!mounted) return;

    // The root Consumer<AuthProvider> in main.dart will rebuild and route the
    // user to LoginScreen (or MainShell if already authenticated).
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // ── Background gradient ────────────────────────────────────────
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF0D1117),
                    Color(0xFF0D1520),
                    Color(0xFF0D1117),
                  ],
                ),
              ),
            ),
          ),
          // Accent blobs
          Positioned(
            top: -100,
            right: -100,
            child: _Blob(
              size: 400,
              color: AppColors.accentBlue.withValues(alpha: 0.07),
            ),
          ),
          Positioned(
            bottom: -60,
            left: -60,
            child: _Blob(
              size: 300,
              color: AppColors.accentPurple.withValues(alpha: 0.05),
            ),
          ),

          // ── Content ───────────────────────────────────────────────────
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
                        child: Image.asset(
                          'assets/images/icon.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
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
                      'Connect to your instance',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 36),

                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: GlassCard(
                        padding: const EdgeInsets.all(32),
                        borderRadius: const BorderRadius.all(
                          Radius.circular(GlassTokens.radiusLg),
                        ),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // ── Header text inside card ──────────────
                              Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: AppColors.accentBlue
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(
                                      Icons.dns_rounded,
                                      size: 18,
                                      color: AppColors.accentBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Server URL',
                                          style: GoogleFonts.poppins(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          'Enter the address of your Ondes HOST installation',
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),

                              // ── URL field ────────────────────────────
                              const _FieldLabel('Server URL'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _urlCtrl,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                style: GoogleFonts.inter(
                                  color: AppColors.textPrimary,
                                  fontSize: 14,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'https://host.example.com',
                                  prefixIcon: Icon(
                                    Icons.link_rounded,
                                    size: 18,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                validator: _validateUrl,
                                onFieldSubmitted: (_) => _submit(),
                                textInputAction: TextInputAction.go,
                              ),
                              const SizedBox(height: 12),

                              // ── Hint ─────────────────────────────────
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.accentBlue
                                      .withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: AppColors.accentBlue
                                        .withValues(alpha: 0.15),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(
                                      Icons.info_outline_rounded,
                                      size: 14,
                                      color: AppColors.accentBlue,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'This is the public address of the server where Ondes HOST is running, e.g. https://host.example.com',
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          color: AppColors.accent
                                              .withValues(alpha: 0.8),
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // ── Error message ────────────────────────
                              if (_errorMsg != null) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.accentRed
                                        .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: AppColors.accentRed
                                          .withValues(alpha: 0.25),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.error_outline_rounded,
                                        size: 14,
                                        color: AppColors.accentRed,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _errorMsg!,
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            color: AppColors.accentRed,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              const SizedBox(height: 24),

                              // ── Connect button ───────────────────────
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _loading ? null : _submit,
                                  child: _loading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            const Icon(
                                              Icons.arrow_forward_rounded,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Connect',
                                              style: GoogleFonts.poppins(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 15,
                                              ),
                                            ),
                                          ],
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Private helpers ────────────────────────────────────────────────────────────

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
        gradient: RadialGradient(
          colors: [color, Colors.transparent],
        ),
      ),
    );
  }
}
