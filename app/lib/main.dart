import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InventoryApp());
}

class InventoryApp extends StatelessWidget {
  const InventoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mon Stock',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const InventoryPage(),
    );
  }
}

class Product {
  final int? id;
  final String barcode;
  final String name;
  final String brand;
  final String unit;
  final int quantity;
  final int createdAtMs;

  Product({
    this.id,
    required this.barcode,
    required this.name,
    this.brand = '',
    this.unit = 'pcs',
    this.quantity = 0,
    int? createdAtMs,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;

  Product copyWith({
    int? id,
    String? barcode,
    String? name,
    String? brand,
    String? unit,
    int? quantity,
    int? createdAtMs,
  }) {
    return Product(
      id: id ?? this.id,
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      unit: unit ?? this.unit,
      quantity: quantity ?? this.quantity,
      createdAtMs: createdAtMs ?? this.createdAtMs,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'barcode': barcode,
        'name': name,
        'brand': brand,
        'unit': unit,
        'quantity': quantity,
        'createdAtMs': createdAtMs,
      };

  static Product fromMap(Map<String, Object?> m) => Product(
        id: m['id'] as int?,
        barcode: m['barcode'] as String,
        name: m['name'] as String,
        brand: (m['brand'] ?? '') as String,
        unit: (m['unit'] ?? 'pcs') as String,
        quantity: (m['quantity'] ?? 0) as int,
        createdAtMs: (m['createdAtMs'] ?? 0) as int,
      );
}

class InventoryDb {
  static final InventoryDb _instance = InventoryDb._internal();
  factory InventoryDb() => _instance;
  InventoryDb._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'inventory.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            barcode TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            brand TEXT DEFAULT '',
            unit TEXT DEFAULT 'pcs',
            quantity INTEGER NOT NULL DEFAULT 0,
            createdAtMs INTEGER NOT NULL
          );
        ''');
        await db.execute("CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode);");
        await db.execute("CREATE INDEX IF NOT EXISTS idx_products_name ON products(name);");
      },
    );
  }

  Future<List<Product>> all({String? query}) async {
    final db = await database;
    if (query != null && query.trim().isNotEmpty) {
      final like = '%${query.trim()}%';
      final rows = await db.query(
        'products',
        where: 'name LIKE ? OR barcode LIKE ?',
        whereArgs: [like, like],
        orderBy: 'name COLLATE NOCASE',
      );
      return rows.map(Product.fromMap).toList();
    }
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE');
    return rows.map(Product.fromMap).toList();
  }

  Future<Product?> findByBarcode(String barcode) async {
    final db = await database;
    final rows = await db.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  Future<Product> upsert(Product p) async {
    final db = await database;
    final id = await db.insert('products', p.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    return p.copyWith(id: id);
  }

  Future<void> update(Product p) async {
    final db = await database;
    await db.update('products', p.toMap(), where: 'id = ?', whereArgs: [p.id]);
  }

  Future<void> delete(int id) async {
    final db = await database;
    await db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> adjustQuantity({required int id, required int delta}) async {
    final db = await database;
    await db.rawUpdate('UPDATE products SET quantity = MAX(0, quantity + ?) WHERE id = ?', [delta, id]);
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final _db = InventoryDb();
  String _query = '';
  late Future<List<Product>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = _db.all(query: _query);
    });
  }

  Future<void> _openScanner() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (!mounted || code == null) return;

    final existing = await _db.findByBarcode(code);
    if (existing != null) {
      final delta = await showModalBottomSheet<int>(
        context: context,
        isScrollControlled: true,
        builder: (_) => QuantitySheet(name: existing.name),
      );
      if (delta != null) {
        await _db.adjustQuantity(id: existing.id!, delta: delta);
        _reload();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Quantité mise à jour (${delta >= 0 ? "+" : ""}$delta)')),
        );
      }
      return;
    }

    final created = await showDialog<Product?>(
      context: context,
      builder: (_) => ProductDialog(barcode: code),
    );
    if (created != null) {
      await _db.upsert(created);
      _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Produit ajouté au stock')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon Stock'),
        actions: [
          IconButton(
            tooltip: 'Scanner',
            onPressed: _openScanner,
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scanner'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Rechercher par nom ou code-barres',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                _query = v;
                _reload();
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Product>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final items = snap.data!;
                if (items.isEmpty) {
                  return const Center(
                    child: Text('Aucun produit. Appuie sur "Scanner" pour commencer.'),
                  );
                }
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final p = items[i];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(p.quantity.toString()),
                      ),
                      title: Text(p.name),
                      subtitle: Text('${p.brand.isNotEmpty ? '${p.brand} • ' : ''}${p.barcode}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          switch (value) {
                            case 'add':
                              await _db.adjustQuantity(id: p.id!, delta: 1);
                              break;
                            case 'remove':
                              await _db.adjustQuantity(id: p.id!, delta: -1);
                              break;
                            case 'edit':
                              final updated = await showDialog<Product?>(
                                context: context,
                                builder: (_) => ProductDialog(editing: p),
                              );
                              if (updated != null) {
                                await _db.update(updated.copyWith(id: p.id));
                              }
                              break;
                            case 'delete':
                              await _db.delete(p.id!);
                              break;
                          }
                          _reload();
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'add', child: Text('Ajouter 1')),
                          PopupMenuItem(value: 'remove', child: Text('Retirer 1')),
                          PopupMenuItem(value: 'edit', child: Text('Modifier')),
                          PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    formats: [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upca,
      BarcodeFormat.upce,
      BarcodeFormat.code128,
      BarcodeFormat.qrCode,
    ],
  );
  bool _handled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner un code'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              if (_handled) return;
              final barcode = capture.barcodes.firstOrNull;
              final value = barcode?.rawValue;
              if (value != null && value.trim().isNotEmpty) {
                _handled = true;
                Navigator.of(context).pop(value.trim());
              }
            },
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : this[0];
}

class ProductDialog extends StatefulWidget {
  final String? barcode;
  final Product? editing;
  const ProductDialog({super.key, this.barcode, this.editing});

  @override
  State<ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends State<ProductDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _barcodeCtrl;
  final _nameCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: 'pcs');
  final _qtyCtrl = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    _barcodeCtrl = TextEditingController(text: widget.editing?.barcode ?? widget.barcode ?? '');
    if (widget.editing != null) {
      final p = widget.editing!;
      _nameCtrl.text = p.name;
      _brandCtrl.text = p.brand;
      _unitCtrl.text = p.unit;
      _qtyCtrl.text = p.quantity.toString();
    }
  }

  @override
  void dispose() {
    _barcodeCtrl.dispose();
    _nameCtrl.dispose();
    _brandCtrl.dispose();
    _unitCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.editing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Modifier le produit' : 'Nouveau produit'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _barcodeCtrl,
                decoration: const InputDecoration(labelText: 'Code-barres'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Nom du produit'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _brandCtrl,
                decoration: const InputDecoration(labelText: 'Marque (optionnel)'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _unitCtrl,
                      decoration: const InputDecoration(labelText: 'Unité (pcs, kg, etc.)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _qtyCtrl,
                      decoration: const InputDecoration(labelText: 'Quantité'),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 0) return 'Nombre entier requis';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final p = Product(
              id: widget.editing?.id,
              barcode: _barcodeCtrl.text.trim(),
              name: _nameCtrl.text.trim(),
              brand: _brandCtrl.text.trim(),
              unit: _unitCtrl.text.trim().isEmpty ? 'pcs' : _unitCtrl.text.trim(),
              quantity: int.parse(_qtyCtrl.text.trim()),
            );
            Navigator.pop(context, p);
          },
          child: Text(isEditing ? 'Enregistrer' : 'Ajouter'),
        ),
      ],
    );
  }
}

class QuantitySheet extends StatefulWidget {
  final String name;
  const QuantitySheet({super.key, required this.name});

  @override
  State<QuantitySheet> createState() => _QuantitySheetState();
}

class _QuantitySheetState extends State<QuantitySheet> {
  int _delta = 1;

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Mettre à jour: ${widget.name}', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => _delta = (_delta - 1).clamp(1, 9999)),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Expanded(
                    child: TextField(
                      textAlign: TextAlign.center,
                      controller: TextEditingController(text: '$_delta'),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n > 0) setState(() => _delta = n);
                      },
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _delta = (_delta + 1).clamp(1, 9999)),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context, -_delta),
                      icon: const Icon(Icons.remove),
                      label: const Text('Retirer'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, _delta),
                      icon: const Icon(Icons.add),
                      label: const Text('Ajouter'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
