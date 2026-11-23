import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../protocol/pair_link.dart';
import 'pebbles.dart';
import 'theme.dart';

/// Whether this platform can scan with a camera (mobile_scanner has no Windows support).
bool get cameraScanningAvailable => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Connect to BlackPearl: scan the PC's code, or paste its link.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.onLink, this.onCancel, this.error, this.scanner});

  final ValueChanged<PairLink> onLink;

  /// Shown when there's somewhere to go back to.
  final VoidCallback? onCancel;

  /// A message from a previous attempt, such as an expired code.
  final String? error;

  /// Replaces the camera view; for previews and tests.
  final Widget? scanner;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final TextEditingController _text = TextEditingController();
  String? _error;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _error = widget.error;
  }

  @override
  void dispose() {
    _text.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _use(String text, {bool fromCamera = false}) {
    if (_handled) return;
    try {
      final link = PairLinkParser.parse(text);
      _handled = true;
      HapticFeedback.mediumImpact();
      widget.onLink(link);
    } on PairLinkException catch (e) {
      // The camera sees every QR code in view; only complain about one that looks like ours.
      if (fromCamera && !text.trim().toLowerCase().startsWith('blackpearl:')) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _error = 'The clipboard is empty. Copy the link on the PC first.');
      return;
    }
    _text.text = text;
    _use(text);
  }

  @override
  Widget build(BuildContext context) {
    // With somewhere to go back to, the system's Back does what the back arrow does, rather than close the app.
    return PopScope(
      canPop: widget.onCancel == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onCancel?.call();
      },
      child: _page(context),
    );
  }

  Widget _page(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scannerSize = (constraints.maxWidth - 96).clamp(200.0, 280.0);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 40,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: widget.onCancel == null
                            ? null
                            : Pebble(
                                width: 40,
                                height: 40,
                                onTap: widget.onCancel,
                                semanticLabel: 'Back',
                                child: const Icon(Icons.arrow_back_rounded, size: 20),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Connect to BlackPearl', textAlign: TextAlign.center, style: display(28)),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text.rich(
                        const TextSpan(
                          children: [
                            TextSpan(text: 'On your PC, open '),
                            TextSpan(
                              text: 'Settings › Profile › Phone remote',
                              style: TextStyle(color: Palette.ink, fontWeight: FontWeight.w600),
                            ),
                            TextSpan(text: ' and point the camera at its code.'),
                          ],
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Palette.muted, fontSize: 14.5, height: 1.4),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Center(
                      child: _ScannerWell(size: scannerSize, child: widget.scanner ?? _camera()),
                    ),
                    const SizedBox(height: 26),
                    const Text(
                      'Or paste the link the PC shows',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Palette.muted, fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    Well(
                      height: 52,
                      radius: 26,
                      padding: const EdgeInsets.only(left: 18, right: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _text,
                              style: const TextStyle(color: Palette.ink, fontSize: 14),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                hintText: 'blackpearl://pair?…',
                                hintStyle: TextStyle(color: Color(0xFF6B776F), fontSize: 14),
                              ),
                              autocorrect: false,
                              enableSuggestions: false,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.go,
                              onSubmitted: _use,
                              onChanged: (_) {
                                if (_error != null) setState(() => _error = null);
                              },
                            ),
                          ),
                          const SizedBox(width: 6),
                          Pebble(
                            height: 40,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            onTap: _paste,
                            semanticLabel: 'Paste the link',
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.content_paste_rounded, size: 17),
                                SizedBox(width: 6),
                                Text('Paste', style: TextStyle(fontSize: 13.5)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListenableBuilder(
                      listenable: _text,
                      builder: (context, _) =>
                          PebbleButton(label: 'Connect', lit: true, onTap: _text.text.trim().isEmpty ? null : () => _use(_text.text)),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 1),
                            child: Icon(Icons.error_outline_rounded, size: 18, color: Palette.danger),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!, style: const TextStyle(color: Palette.danger, fontSize: 13.5, height: 1.35)),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _camera() {
    if (!cameraScanningAvailable) {
      return const _ScannerMessage(
        icon: Icons.no_photography_outlined,
        text: "There's no camera scanner on this device. Paste the link instead.",
      );
    }
    return MobileScanner(
      controller: _controller ??= MobileScannerController(formats: const [BarcodeFormat.qrCode]),
      onDetect: (capture) {
        for (final code in capture.barcodes) {
          final value = code.rawValue;
          if (value != null) _use(value, fromCamera: true);
        }
      },
      errorBuilder: (context, error) => _ScannerMessage(
        icon: Icons.no_photography_outlined,
        text: error.errorCode == MobileScannerErrorCode.permissionDenied
            ? 'BlackPearl needs the camera to scan the code. Allow it in Android Settings, or paste the link.'
            : "The camera didn't start. Paste the link instead.",
      ),
    );
  }

  MobileScannerController? _controller;
}

class _ScannerWell extends StatelessWidget {
  const _ScannerWell({required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      children: [
        Positioned.fill(
          child: Well(
            radius: 28,
            child: ClipRRect(borderRadius: BorderRadius.circular(28), child: child),
          ),
        ),
        // Corner brackets mark where the code goes, instead of an outline round the whole well.
        Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _Corners())),
        ),
      ],
    ),
  );
}

class _Corners extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.accent.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const inset = 22.0, arm = 26.0, r = 12.0;
    final w = size.width, h = size.height;
    for (final (x, y, sx, sy) in [
      (inset, inset, 1.0, 1.0),
      (w - inset, inset, -1.0, 1.0),
      (inset, h - inset, 1.0, -1.0),
      (w - inset, h - inset, -1.0, -1.0),
    ]) {
      final path = Path()
        ..moveTo(x, y + sy * arm)
        ..lineTo(x, y + sy * r)
        ..arcToPoint(Offset(x + sx * r, y), radius: const Radius.circular(r), clockwise: sx * sy > 0)
        ..lineTo(x + sx * arm, y);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_Corners oldDelegate) => false;
}

class _ScannerMessage extends StatelessWidget {
  const _ScannerMessage({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(40),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 34, color: Palette.muted),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Palette.muted, fontSize: 13, height: 1.35),
        ),
      ],
    ),
  );
}
