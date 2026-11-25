import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import '../connection/remote_link.dart';
import '../storage/paired_pcs.dart';
import 'pebbles.dart';
import 'theme.dart';

/// The sheet behind the PC chip: switch PCs, pair another, forget this one.
Future<void> showPcChooser(BuildContext context, AppModel model) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => ListenableBuilder(
    listenable: model,
    // The current PC's line follows its connection as it goes ("Connecting…", "Connected…").
    builder: (context, _) => ListenableBuilder(
      listenable: model.connection ?? model,
      builder: (context, _) => _PcChooser(model: model),
    ),
  ),
);

class _PcChooser extends StatelessWidget {
  const _PcChooser({required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final current = model.currentPcId;
    final connection = model.connection;
    return SafeArea(
      // Many PCs, a sideways phone or large text scroll rather than overflow.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 5,
                decoration: BoxDecoration(color: const Color(0xFF3A433D), borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('Your PCs', style: display(22)),
            ),
            const SizedBox(height: 10),
            for (final pc in model.pcs)
              _PcRow(
                pc: pc,
                selected: pc.pcId == current,
                status: pc.pcId == current && connection != null ? connection.status : null,
                onTap: () {
                  Navigator.of(context).pop();
                  if (pc.pcId != current) model.select(pc);
                },
                // Any PC can be forgotten from its own row, without switching to it first. Forgetting the one in use
                // closes the sheet, as the remote moves on to another PC or to pairing; another one just leaves the list.
                onForget: () async {
                  final confirmed = await _confirmForget(context, pc);
                  if (confirmed != true || !context.mounted) return;
                  if (pc.pcId == current) Navigator.of(context).pop();
                  await model.forget(pc);
                },
              ),
            const SizedBox(height: 12),
            PebbleButton(
              label: 'Pair another PC',
              icon: Icons.qr_code_scanner_rounded,
              onTap: () {
                Navigator.of(context).pop();
                model.requestPairing();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmForget(BuildContext context, PairedPc pc) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Forget ${pc.name}?', style: display(22)),
      content: const Text(
        'This phone stops controlling it. To use it again, pair it again with a new code. '
        'The PC keeps listing this phone until you remove it there.',
        style: TextStyle(color: Palette.muted, height: 1.4),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Pebble(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onTap: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        Pebble(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          onTap: () => Navigator.of(context).pop(true),
          child: const Text('Forget', style: TextStyle(color: Palette.danger)),
        ),
      ],
    ),
  );
}

class _PcRow extends StatelessWidget {
  const _PcRow({required this.pc, required this.selected, required this.status, required this.onTap, required this.onForget});
  final PairedPc pc;
  final bool selected;
  final LinkStatus? status;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final line = switch (status?.phase) {
      null => 'Tap to connect',
      LinkPhase.connected => describePath(status!.path),
      LinkPhase.waitingForPc => "Isn't online",
      LinkPhase.failed => status!.message ?? "Couldn't connect",
      LinkPhase.idle => 'Not connected',
      _ => 'Connecting…',
    };
    return Material(
      color: selected ? Palette.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
          child: Row(
            children: [
              Icon(Icons.desktop_windows_outlined, color: selected ? Palette.accent : Palette.muted, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pc.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: selected ? Palette.accent : Palette.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Palette.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              if (selected) const Icon(Icons.check_rounded, color: Palette.accent, size: 20),
              PopupMenuButton<String>(
                tooltip: 'More for ${pc.name}',
                icon: const Icon(Icons.more_vert_rounded, color: Palette.muted),
                color: Palette.elevated,
                onSelected: (_) => onForget(),
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'forget',
                    child: Row(
                      children: [
                        const Icon(Icons.link_off_rounded, size: 20, color: Palette.danger),
                        const SizedBox(width: 12),
                        Flexible(child: Text('Forget ${pc.name}', overflow: TextOverflow.ellipsis, style: const TextStyle(color: Palette.danger))),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
