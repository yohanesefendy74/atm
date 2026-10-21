import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'models.dart';
import 'theme.dart';

/// Header putih di atas layar: tombol kembali, eyebrow berwarna, judul, isi tambahan.
class Header extends StatelessWidget {
  const Header({super.key, required this.title, this.eyebrow, this.accent = C.inbound, this.trailing, this.bottom, this.back = true});
  final String title;
  final String? eyebrow;
  final Color accent;
  final Widget? trailing;
  final Widget? bottom;
  final bool back;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: C.line))),
      padding: EdgeInsets.fromLTRB(back ? 8 : 20, MediaQuery.of(context).padding.top + 12, 20, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (back)
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.chevron_left, size: 28),
              tooltip: 'Kembali',
            ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (eyebrow != null)
                Text(eyebrow!.toUpperCase(),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accent, letterSpacing: 0.7)),
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.ink)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
        if (bottom != null) Padding(padding: EdgeInsets.only(left: back ? 12 : 0, top: 10), child: bottom!),
      ]),
    );
  }
}

/// Indikator langkah 1-2-3.
class Steps extends StatelessWidget {
  const Steps({super.key, required this.labels, required this.current, required this.accent});
  final List<String> labels;
  final int current;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(height: 4, decoration: BoxDecoration(color: i <= current ? accent : C.line, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 6),
              Text('${i + 1} ${labels[i]}',
                  style: TextStyle(fontSize: 12, fontWeight: i == current ? FontWeight.w600 : FontWeight.w500, color: i == current ? accent : C.muted)),
            ]),
          ),
        ]
      ],
    );
  }
}

class Footer extends StatelessWidget {
  const Footer({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: C.line))),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 10), children[i]],
      ]),
    );
  }
}

class BigButton extends StatelessWidget {
  const BigButton({super.key, required this.label, required this.onPressed, this.color = C.ink, this.icon, this.busy = false, this.outlined = false});
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final IconData? icon;
  final bool busy;
  final bool outlined;
  @override
  Widget build(BuildContext context) {
    final child = busy
        ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: outlined ? color : Colors.white))
        : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
          ]);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    if (outlined) {
      return SizedBox(
        height: 52,
        child: OutlinedButton(
          onPressed: busy ? null : onPressed,
          style: OutlinedButton.styleFrom(foregroundColor: color, side: BorderSide(color: color, width: 1.5), shape: shape),
          child: child,
        ),
      );
    }
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, shape: shape, disabledBackgroundColor: color.withOpacity(0.4)),
        child: child,
      ),
    );
  }
}

class Box extends StatelessWidget {
  const Box({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.border = C.line, this.borderWidth = 1, this.color = Colors.white, this.radius = 16, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final Color border;
  final double borderWidth;
  final Color color;
  final double radius;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius), border: Border.all(color: border, width: borderWidth)),
      child: child,
    );
    if (onTap == null) return box;
    return Material(color: Colors.transparent, child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: box));
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.bg = C.inboundTint, this.fg = C.inbound, this.monoFont = false});
  final String text;
  final Color bg;
  final Color fg;
  final bool monoFont;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg, fontFamily: monoFont ? mono : null)),
      );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key, this.accent = C.inbound});
  final String status;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'Selesai':
        return Pill(status, bg: C.greenTint, fg: C.greenText);
      case 'Siap cetak':
        return Pill(status, bg: accent == C.inbound ? C.inboundTint : C.outboundTint, fg: accent);
      case 'Menunggu PT':
      case 'Menunggu DO':
        return Pill(status, bg: C.amberTint, fg: C.amberText);
      default:
        return Pill(status, bg: C.lineSoft, fg: C.muted);
    }
  }
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.required = false, this.hint});
  final String text;
  final bool required;
  final String? hint;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: C.ink)),
          if (hint != null) TextSpan(text: ' $hint', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: C.muted)),
          if (required) const TextSpan(text: ' *', style: TextStyle(fontWeight: FontWeight.w600, color: C.outbound)),
        ])),
      );
}

class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.color = C.muted});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(top: 6), child: Text(text, style: TextStyle(fontSize: 12, color: color)));
}

class KV extends StatelessWidget {
  const KV(this.label, this.value, {super.key, this.monoValue = true, this.light = false});
  final String label;
  final String value;
  final bool monoValue;
  final bool light;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: light ? const Color(0xFFC5CAD1) : C.muted)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, fontFamily: monoValue ? mono : null, color: light ? Colors.white : C.ink)),
      ]);
}

class TotalsBar extends StatelessWidget {
  const TotalsBar(this.items, {super.key});
  final List<(String, String)> items;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: C.ink, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [for (final i in items) Expanded(child: KV(i.$1, i.$2, light: true))]),
      );
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 40, color: C.muted),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
            if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Coba lagi'))],
          ]),
        ),
      );
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: const Color(0xFF8A1C1C)));
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Dropdown warehouse dari USR9 (hak akses user) dengan penanda TITIPAN.
class WarehouseField extends StatelessWidget {
  const WarehouseField({super.key, required this.items, required this.value, required this.onChanged});
  final List<Warehouse> items;
  final Warehouse? value;
  final ValueChanged<Warehouse> onChanged;
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: DropdownButtonFormField<String>(
          value: value?.code,
          isExpanded: true,
          items: [
            for (final w in items)
              DropdownMenuItem(value: w.code, child: Text('${w.code} · ${w.name}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (code) {
            if (code == null) return;
            onChanged(items.firstWhere((w) => w.code == code));
          },
        ),
      ),
      if (value?.isTitipan ?? false) ...[const SizedBox(width: 8), const Pill('TITIPAN')],
    ]);
  }
}

final _upper = TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase()));
TextInputFormatter get upperCase => _upper;

/// Form satu baris barang curah (Item Code, UOM, Brand, Origin, Qty KG, Qty2 sak, Qty Palet).
/// Dipakai di Inbound detail dan Item Inbound (KR/RP).
class LineForm extends StatefulWidget {
  const LineForm({super.key, required this.accent, required this.onAdd, this.sakLabel = 'Karung'});
  final Color accent;
  final ValueChanged<LineDraft> onAdd;
  final String sakLabel;
  @override
  State<LineForm> createState() => _LineFormState();
}

class _LineFormState extends State<LineForm> {
  Map<String, dynamic>? _item;
  String _uom = 'KG';
  String? _brand;
  List<String> _brands = [];
  final _origin = TextEditingController();
  final _qty = TextEditingController();
  final _qty2 = TextEditingController();
  final _palet = TextEditingController();
  TextEditingController? _itemCtl;

  @override
  void initState() {
    super.initState();
    _loadBrands();
  }

  Future<void> _loadBrands() async {
    try {
      final b = await Api.brands();
      if (mounted) setState(() => _brands = b);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  void dispose() {
    _origin.dispose();
    _qty.dispose();
    _qty2.dispose();
    _palet.dispose();
    super.dispose();
  }

  double _n(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.')) ?? 0;

  void _add() {
    if (_item == null) return showError(context, 'Pilih Item Code dulu');
    if (_n(_qty) <= 0) return showError(context, 'Qty (KG) harus diisi');
    if (_n(_qty2) <= 0) return showError(context, 'Qty 2 (${widget.sakLabel}) harus diisi');
    if (_n(_palet) <= 0) return showError(context, 'Qty Palet harus diisi');
    widget.onAdd(LineDraft(
      itemCode: _item!['itemCode'].toString(),
      itemName: (_item!['itemName'] ?? '').toString(),
      groupName: (_item!['groupName'] ?? '').toString(),
      uom: _uom,
      brand: _brand,
      origin: _origin.text.trim().isEmpty ? null : _origin.text.trim(),
      qty: _n(_qty),
      qty2: _n(_qty2),
      qtyPalet: _n(_palet),
    ));
    setState(() {
      _item = null;
      _itemCtl?.clear();
      _qty.clear();
      _qty2.clear();
      _palet.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final numStyle = const TextStyle(fontFamily: mono, fontSize: 18, fontWeight: FontWeight.w600);
    return Box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const FieldLabel('Item Code', required: true),
        Autocomplete<Map<String, dynamic>>(
          displayStringForOption: (o) => o['itemCode'].toString(),
          optionsBuilder: (v) async {
            if (v.text.trim().length < 2) return const Iterable<Map<String, dynamic>>.empty();
            try {
              return await Api.items(v.text.trim());
            } catch (_) {
              return const Iterable<Map<String, dynamic>>.empty();
            }
          },
          onSelected: (o) => setState(() => _item = o),
          fieldViewBuilder: (context, ctl, focus, onSubmit) {
            _itemCtl = ctl;
            return TextField(
              controller: ctl,
              focusNode: focus,
              inputFormatters: [upperCase],
              style: const TextStyle(fontFamily: mono, fontSize: 17, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Ketik kode / nama item'),
            );
          },
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260, maxWidth: 340),
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  children: [
                    for (final o in options)
                      ListTile(
                        dense: true,
                        title: Text(o['itemCode'].toString(), style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600)),
                        subtitle: Text('${o['itemName'] ?? ''} · ${o['groupName'] ?? ''}'),
                        onTap: () => onSelected(o),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_item != null) Hint('${_item!['itemName']} · Grup: ${_item!['groupName'] ?? '-'}'),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const FieldLabel('UOM'),
              DropdownButtonFormField<String>(
                value: _uom,
                items: const [DropdownMenuItem(value: 'KG', child: Text('KG')), DropdownMenuItem(value: 'TON', child: Text('TON'))],
                onChanged: (v) => setState(() => _uom = v ?? 'KG'),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const FieldLabel('Brand'),
              DropdownButtonFormField<String>(
                value: _brand,
                isExpanded: true,
                hint: const Text('Pilih'),
                items: [for (final b in _brands) DropdownMenuItem(value: b, child: Text(b, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _brand = v),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        const FieldLabel('Origin'),
        TextField(controller: _origin, decoration: const InputDecoration(hintText: 'Negara asal')),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FieldLabel('Qty', hint: '($_uom)'),
              TextField(controller: _qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: numStyle),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FieldLabel('Qty 2', hint: '(${widget.sakLabel})'),
              TextField(controller: _qty2, keyboardType: TextInputType.number, style: numStyle),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const FieldLabel('Qty Palet'),
              TextField(controller: _palet, keyboardType: TextInputType.number, style: numStyle),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        BigButton(label: 'Tambah baris', icon: Icons.add, color: widget.accent, onPressed: _add),
      ]),
    );
  }
}

/// Baris ringkas barang yang sudah ditambahkan.
class LineTile extends StatelessWidget {
  const LineTile(this.line, {super.key, this.onDelete, this.badge, this.sakLabel = 'krg'});
  final LineDraft line;
  final VoidCallback? onDelete;
  final Widget? badge;
  final String sakLabel;
  @override
  Widget build(BuildContext context) => Box(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        radius: 12,
        child: Row(children: [
          if (badge != null) ...[badge!, const SizedBox(width: 10)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.itemCode, style: const TextStyle(fontFamily: mono, fontSize: 14, fontWeight: FontWeight.w600)),
              Text([line.itemName, line.brand, line.origin].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 12, color: C.muted)),
              if (line.kodeRuangan != null) Text('Ruangan ${line.kodeRuangan}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
          Text('${fmt(line.qty)} ${line.uom}\n${fmt(line.qty2)} $sakLabel · ${fmt(line.qtyPalet)} plt',
              textAlign: TextAlign.right, style: const TextStyle(fontFamily: mono, fontSize: 13)),
          if (onDelete != null) IconButton(onPressed: onDelete, icon: const Icon(Icons.close, size: 20), tooltip: 'Hapus baris'),
        ]),
      );
}


/// Ruangan dari master (per gudang). Cari lalu pilih dari daftar; teks bebas tidak diterima.
/// [titipan]: null = semua, true/false = hanya ruangan titipan / non-titipan.
class RuanganField extends StatefulWidget {
  const RuanganField({super.key, required this.whs, required this.value, required this.onChanged, this.titipan, this.label = 'Ruangan'});
  final String whs;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool? titipan;
  final String label;
  @override
  State<RuanganField> createState() => _RuanganFieldState();
}

class _RuanganFieldState extends State<RuanganField> {
  static final _cache = <String, List<Map<String, dynamic>>>{};
  List<Map<String, dynamic>> _rooms = [];
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RuanganField old) {
    super.didUpdateWidget(old);
    if (old.whs != widget.whs) _load();
  }

  Future<void> _load() async {
    try {
      final list = _cache[widget.whs] ??
          (await Api.get('/api/master/ruangan', {'whs': widget.whs}) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _cache[widget.whs] = list;
      if (!mounted) return;
      setState(() {
        _err = null;
        _rooms = list.where((r) => widget.titipan == null || (r['titipan'] == true) == widget.titipan).toList();
      });
      if (widget.value == null && _rooms.length == 1) widget.onChanged(_rooms.first['kodeRuangan'].toString());
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  String _label(Map<String, dynamic> r) => '${r['kodeRuangan']} · ${r['namaRuangan'] ?? ''}${r['titipan'] == true ? ' (titipan)' : ''}';

  @override
  Widget build(BuildContext context) {
    if (_err != null) return Hint('Gagal memuat ruangan: $_err', color: C.outbound);
    final cur = _rooms.where((r) => r['kodeRuangan'].toString() == widget.value).firstOrNull;
    return Autocomplete<Map<String, dynamic>>(
      key: ValueKey('${widget.whs}|${widget.value}|${_rooms.length}'),
      initialValue: TextEditingValue(text: cur == null ? '' : _label(cur)),
      displayStringForOption: _label,
      optionsBuilder: (v) {
        final q = v.text.trim().toUpperCase();
        if (cur != null && v.text == _label(cur)) return _rooms;
        return _rooms.where((r) => q.isEmpty || _label(r).toUpperCase().contains(q));
      },
      onSelected: (r) => widget.onChanged(r['kodeRuangan'].toString()),
      fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
        controller: ctrl,
        focusNode: focus,
        decoration: InputDecoration(
          labelText: '${widget.label} (wajib)',
          helperText: widget.value == null ? 'Ketik untuk mencari, lalu pilih dari daftar' : null,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        onChanged: (_) {
          if (widget.value != null) widget.onChanged(null);
        },
      ),
    );
  }
}
