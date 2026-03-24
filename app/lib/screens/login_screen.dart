import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
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
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Logo ────────────────────────────────────────────────────
              SizedBox(
                width: 70,
                height: 70,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: Image.asset(
                    'assets/images/icon.png',
                    fit: BoxFit.contain,
                  )
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Ondes Host',
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in to your infrastructure dashboard',
                style: GoogleFonts.inter(
                    fontSize: 14, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              // ── Card ────────────────────────────────────────────────────
              Container(
                width: 380,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Label('Username'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _usernameCtrl,
                        style: GoogleFonts.inter(
                            color: AppColors.textPrimary, fontSize: 14),
                        decoration: const InputDecoration(hintText: 'admin'),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Required' : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 16),
                      _Label('Password'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscure,
                        style: GoogleFonts.inter(
                            color: AppColors.textPrimary, fontSize: 14),
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
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Required' : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 40,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          child: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(
                                        AppColors.background),
                                  ),
                                )
                              : const Text('Sign in'),
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
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondary,
        ),
      );
}
