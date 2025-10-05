import "dart:async";
import "dart:convert";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:mobile_scanner/mobile_scanner.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "package:sqflite/sqflite.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Miam9App());
}

class Miam9App extends StatefulWidget {
  const Miam9App({super.key});
  @override
  State<Miam9App> createState() => _Miam9AppState();
}

class _Miam9AppState extends State<Miam9App> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Miam9",
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: IndexedStack(
          index: _index,
          children: const [InventoryPage(), RecipesPage()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: "Stock"),
            NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: "Recettes"),
          ],
        ),
      ),
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
  final String? imageUrl;
  final int createdAtMs;

  Product({
    this.id,
    required this.barcode,
    required this.name,
    this.brand = "",
    this.unit = "pcs",
    this.quantity = 0,
    this.imageUrl,
    int? createdAtMs,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;

  Product copyWith({
    int? id,
    String? barcode,
    String? name,
    String? brand,
    String? unit,
    int? quantity,
    String? imageUrl,
    int? createdAtMs,
  }) {
    return Product(
      id: id ?? this.id,
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      unit: unit ?? this.unit,
      quantity: quantity ?? this.quantity,
      imageUrl: imageUrl ?? this.imageUrl,
      createdAtMs: createdAtMs ?? this.createdAtMs,
    );
  }

  Map<String, Object?> toMap() => {
        "id": id,
        "barcode": barcode,
        "name": name,
        "brand": brand,
        "unit": unit,
        "quantity": quantity,
        "imageUrl": imageUrl,
        "createdAtMs": createdAtMs,
      };

  static Product fromMap(Map<String, Object?> m) => Product(
        id: m["id"] as int?,
        barcode: m["barcode"] as String,
        name: m["name"] as String,
        brand: (m["brand"] ?? "") as String,
        unit: (m["unit"] ?? "pcs") as String,
        quantity: (m["quantity"] ?? 0) as int,
        imageUrl: m["imageUrl"] as String?,
        createdAtMs: (m["createdAtMs"] ?? 0) as int,
      );
}

class Recipe {
  final int? id;
  final String name;
  Recipe({this.id, required this.name});
  Map<String, Object?> toMap() => {"id": id, "name": name};
  static Recipe fromMap(Map<String, Object?> m) => Recipe(id: m["id"] as int?, name: m["name"] as String);
}

class RecipeItem {
  final int? id;
  final int recipeId;
  final int productId;
  final int qty;
  RecipeItem({this.id, required this.recipeId, required this.productId, required this.qty});
  Map<String, Object?> toMap() => {"id": id, "recipeId": recipeId, "productId": productId, "qty": qty};
  static RecipeItem fromMap(Map<String, Object?> m) => RecipeItem(
    id: m["id"] as int?, recipeId: m["recipeId"] as int, productId: m["productId"] as int, qty: m["qty"] as int);
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
    final path = p.join(dir.path, "inventory.db");
    return openDatabase(
      path,
      version: 2, // v2: add imageUrl + recipes tables
      onCreate: (db, version) async {
        await db.execute("""
          CREATE TABLE products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            barcode TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            brand TEXT DEFAULT '',
            unit TEXT DEFAULT 'pcs',
            quantity INTEGER NOT NULL DEFAULT 0,
            imageUrl TEXT,
            createdAtMs INTEGER NOT NULL
          );
        """);
        await db.execute("CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode);");
        await db.execute("CREATE INDEX IF NOT EXISTS idx_products_name ON products(name);");
        await _createRecipeTables(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          // add imageUrl column if missing
          await db.execute("ALTER TABLE products ADD COLUMN imageUrl TEXT;");
          await _createRecipeTables(db);
        }
      },
    );
  }

  static Future<void> _createRecipeTables(Database db) async {
    await db.execute("""
      CREATE TABLE IF NOT EXISTS recipes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      );
    """);
    await db.execute("""
      CREATE TABLE IF NOT EXISTS recipe_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipeId INTEGER NOT NULL,
        productId INTEGER NOT NULL,
        qty INTEGER NOT NULL,
        FOREIGN KEY(recipeId) REFERENCES recipes(id) ON DELETE CASCADE,
        FOREIGN KEY(productId) REFERENCES products(id) ON DELETE CASCADE
      );
    """);
    await db.execute("CREATE INDEX IF NOT EXISTS idx_recipe_items_recipe ON recipe_items(recipeId);");
  }

  // PRODUCTS
  Future<List<Product>> all({String? query}) async {
    final db = await database;
    if (query != null && query.trim().isNotEmpty) {
      final like = "%${query.trim()}%";
      final rows = await db.query(
        "products",
        where: "name LIKE ? OR barcode LIKE ?",
        whereArgs: [like, like],
        orderBy: "name COLLATE NOCASE",
      );
      return rows.map(Product.fromMap).toList();
    }
    final rows = await db.query("products", orderBy: "name COLLATE NOCASE");
    return rows.map(Product.fromMap).toList();
  }

  Future<Product?> findByBarcode(String barcode) async {
    final db = await database;
    final rows = await db.query("products", where: "barcode = ?", whereArgs: [barcode], limit: 1);
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  Future<Product?> findById(int id) async {
    final db = await database;
    final rows = await db.query("products", where: "id = ?", whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  Future<Product> upsert(Product p) async {
    final db = await database;
    final id = await db.insert("products", p.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    return p.copyWith(id: id);
  }

  Future<void> update(Product p) async {
    final db = await database;
    await db.update("products", p.toMap(), where: "id = ?", whereArgs: [p.id]);
  }

  Future<void> delete(int id) async {
    final db = await database;
    await db.delete("products", where: "id = ?", whereArgs: [id]);
  }

  Future<void> adjustQuantity({required int id, required int delta}) async {
    final db = await database;
    await db.rawUpdate("UPDATE products SET quantity = MAX(0, quantity + ?) WHERE id = ?", [delta, id]);
  }

  // RECIPES
  Future<List<Recipe>> recipes() async {
    final db = await database;
    final rows = await db.query("recipes", orderBy: "name COLLATE NOCASE");
    return rows.map(Recipe.fromMap).toList();
  }

  Future<int> addRecipe(String name) async {
    final db = await database;
    return db.insert("recipes", {"name": name});
  }

  Future<void> updateRecipe(Recipe r) async {
    final db = await database;
    await db.update("recipes", r.toMap(), where: "id = ?", whereArgs: [r.id]);
  }

  Future<void> deleteRecipe(int id) async {
    final db = await database;
    await db.delete("recipes", where: "id = ?", whereArgs: [id]);
    await db.delete("recipe_items", where: "recipeId = ?", whereArgs: [id]);
  }

  Future<List<RecipeItem>> recipeItems(int recipeId) async {
    final db = await database;
    final rows = await db.query("recipe_items", where: "recipeId = ?", whereArgs: [recipeId]);
    return rows.map(RecipeItem.fromMap).toList();
  }

  Future<void> addRecipeItem({required int recipeId, required int productId, required int qty}) async {
    final db = await database;
    await db.insert("recipe_items", {"recipeId": recipeId, "productId": productId, "qty": qty});
  }

  Future<void> deleteRecipeItem(int id) async {
    final db = await database;
    await db.delete("recipe_items", where: "id = ?", whereArgs: [id]);
  }

  Future<void> cookRecipe(int recipeId) async {
    final db = await database;
    final items = await recipeItems(recipeId);
    for (final it in items) {
      await adjustQuantity(id: it.productId, delta: -it.qty);
    }
  }
}

// ------- OpenFoodFacts ----------
class OffAutofill {
  final String name;
  final String brand;
  final String unit;
  final String? imageUrl;
  OffAutofill({this.name = "", this.brand = "", this.unit = "pcs", this.imageUrl});
}

class OffClient {
  static Future<OffAutofill?> fetch(String barcode) async {
    try {
      final uri = Uri.parse("https://world.openfoodfacts.org/api/v0/product/$barcode.json");
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      if ((map["status"] ?? 0) != 1) return null;
      final p = map["product"] as Map<String, dynamic>?;
      if (p == null) return null;
      final name = (p["product_name"] ?? "") as String;
      final brand = (p["brands"] ?? "") as String;
      final q = (p["quantity"] ?? "") as String;
      final image = (p["image_url"] ?? "") as String;
      String unit = "pcs";
      final qLower = q.toLowerCase();
      if (qLower.contains("kg")) unit = "kg";
      else if (qLower.contains("g")) unit = "g";
      else if (qLower.contains("l")) unit = "L";
      return OffAutofill(name: name, brand: brand, unit: unit, imageUrl: image.isEmpty ? null : image);
    } catch (_) {
      return null;
    }
  }
}

// ------- UI: Stock ----------
class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});
  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final _db = InventoryDb();
  String _query = "";
  late Future<List<Product>> _future;

  @override
  void initState() { super.initState(); _reload(); }

  void _reload() {
    setState(() { _future = _db.all(query: _query); });
  }

  Future<void> _openScanner() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
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
          SnackBar(content: Text("Quantité mise à jour (${delta >= 0 ? "+" : ""}$delta)")),
        );
      }
      return;
    }

    OffAutofill? off;
    try { off = await OffClient.fetch(code); } catch (_) {}

    final created = await showDialog<Product?>(
      context: context,
      builder: (_) => ProductDialog(
        barcode: code,
        initialName: off?.name ?? "",
        initialBrand: off?.brand ?? "",
        initialUnit: off?.unit ?? "pcs",
        initialImageUrl: off?.imageUrl,
      ),
    );
    if (created != null) {
      await _db.upsert(created);
      _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Produit ajouté au stock")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Mon Stock"),
        actions: [
          IconButton(tooltip: "Scanner", onPressed: _openScanner, icon: const Icon(Icons.qr_code_scanner_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner, icon: const Icon(Icons.qr_code_scanner), label: const Text("Scanner"),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: "Rechercher par nom ou code-barres", border: OutlineInputBorder()),
              onChanged: (v) { _query = v; _reload(); },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Product>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final items = snap.data!;
                if (items.isEmpty) return const Center(child: Text('Aucun produit. Appuie sur "Scanner" pour commencer.'));
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final p = items[i];
                    Widget leading;
                    if (p.imageUrl != null && p.imageUrl!.isNotEmpty) {
                      leading = ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.network(p.imageUrl!, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) {
                          return CircleAvatar(child: Text(p.quantity.toString()));
                        }),
                      );
                    } else {
                      leading = CircleAvatar(child: Text(p.quantity.toString()));
                    }
                    return ListTile(
                      leading: leading,
                      title: Text(p.name),
                      subtitle: Text("${p.brand.isNotEmpty ? "${p.brand} • " : ""}${p.barcode}"),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          switch (value) {
                            case "add": await _db.adjustQuantity(id: p.id!, delta: 1); break;
                            case "remove": await _db.adjustQuantity(id: p.id!, delta: -1); break;
                            case "edit":
                              final updated = await showDialog<Product?>(
                                context: context,
                                builder: (_) => ProductDialog(editing: p),
                              );
                              if (updated != null) { await _db.update(updated.copyWith(id: p.id)); }
                              break;
                            case "delete": await _db.delete(p.id!); break;
                          }
                          _reload();
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: "add", child: Text("Ajouter 1")),
                          PopupMenuItem(value: "remove", child: Text("Retirer 1")),
                          PopupMenuItem(value: "edit", child: Text("Modifier")),
                          PopupMenuItem(value: "delete", child: Text("Supprimer")),
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

// ------- UI: Scanner ----------
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}
class _ScanPageState extends State<ScanPage> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _handled = false;

  @override
  void dispose() { controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scanner un code"), actions: [
        IconButton(icon: const Icon(Icons.flash_on), onPressed: () => controller.toggleTorch()),
        IconButton(icon: const Icon(Icons.cameraswitch), onPressed: () => controller.switchCamera()),
      ]),
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
                width: 260, height: 260,
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension<T> on List<T> { T? get firstOrNull => isEmpty ? null : this[0]; }

// ------- Dialogs ----------
class ProductDialog extends StatefulWidget {
  final String? barcode;
  final Product? editing;
  final String initialName;
  final String initialBrand;
  final String initialUnit;
  final String? initialImageUrl;
  const ProductDialog({
    super.key,
    this.barcode,
    this.editing,
    this.initialName = "",
    this.initialBrand = "",
    this.initialUnit = "pcs",
    this.initialImageUrl,
  });

  @override
  State<ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends State<ProductDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _barcodeCtrl;
  final _nameCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: "pcs");
  final _qtyCtrl = TextEditingController(text: "1");
  final _imgCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _barcodeCtrl = TextEditingController(text: widget.editing?.barcode ?? widget.barcode ?? "");
    if (widget.editing != null) {
      final p = widget.editing!;
      _nameCtrl.text = p.name;
      _brandCtrl.text = p.brand;
      _unitCtrl.text = p.unit;
      _qtyCtrl.text = p.quantity.toString();
      _imgCtrl.text = p.imageUrl ?? "";
    } else {
      _nameCtrl.text = widget.initialName;
      _brandCtrl.text = widget.initialBrand;
      _unitCtrl.text = widget.initialUnit.isEmpty ? "pcs" : widget.initialUnit;
      _imgCtrl.text = widget.initialImageUrl ?? "";
    }
  }

  @override
  void dispose() {
    _barcodeCtrl.dispose(); _nameCtrl.dispose(); _brandCtrl.dispose(); _unitCtrl.dispose(); _qtyCtrl.dispose(); _imgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.editing != null;
    final imageUrl = _imgCtrl.text.trim();
    return AlertDialog(
      title: Text(isEditing ? "Modifier le produit" : "Nouveau produit"),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (imageUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(imageUrl, height: 140, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
              ),
            TextFormField(
              controller: _barcodeCtrl, decoration: const InputDecoration(labelText: "Code-barres"),
              validator: (v) => (v == null || v.trim().isEmpty) ? "Champ requis" : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _nameCtrl, decoration: const InputDecoration(labelText: "Nom du produit"),
              validator: (v) => (v == null || v.trim().isEmpty) ? "Champ requis" : null,
            ),
            const SizedBox(height: 8),
            TextFormField(controller: _brandCtrl, decoration: const InputDecoration(labelText: "Marque (optionnel)")),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextFormField(controller: _unitCtrl, decoration: const InputDecoration(labelText: "Unité (pcs, kg, etc.)"))),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _qtyCtrl, decoration: const InputDecoration(labelText: "Quantité"),
                  keyboardType: TextInputType.number,
                  validator: (v) { final n = int.tryParse(v ?? ""); if (n == null || n < 0) return "Nombre entier requis"; return null; },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            TextFormField(controller: _imgCtrl, decoration: const InputDecoration(labelText: "Image URL (optionnel)")),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Annuler")),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final p = Product(
              id: widget.editing?.id,
              barcode: _barcodeCtrl.text.trim(),
              name: _nameCtrl.text.trim(),
              brand: _brandCtrl.text.trim(),
              unit: _unitCtrl.text.trim().isEmpty ? "pcs" : _unitCtrl.text.trim(),
              quantity: int.parse(_qtyCtrl.text.trim()),
              imageUrl: _imgCtrl.text.trim().isEmpty ? null : _imgCtrl.text.trim(),
            );
            Navigator.pop(context, p);
          },
          child: Text(isEditing ? "Enregistrer" : "Ajouter"),
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
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Mettre à jour: ${widget.name}", style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(children: [
              IconButton(onPressed: () => setState(() => _delta = (_delta - 1).clamp(1, 9999)), icon: const Icon(Icons.remove_circle_outline)),
              Expanded(
                child: TextField(
                  textAlign: TextAlign.center,
                  controller: TextEditingController(text: "$_delta"),
                  keyboardType: TextInputType.number,
                  onChanged: (v) { final n = int.tryParse(v); if (n != null && n > 0) setState(() => _delta = n); },
                ),
              ),
              IconButton(onPressed: () => setState(() => _delta = (_delta + 1).clamp(1, 9999)), icon: const Icon(Icons.add_circle_outline)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, -_delta), icon: const Icon(Icons.remove), label: const Text("Retirer"))),
              const SizedBox(width: 12),
              Expanded(child: FilledButton.icon(onPressed: () => Navigator.pop(context, _delta), icon: const Icon(Icons.add), label: const Text("Ajouter"))),
            ]),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }
}

// ------- UI: Recettes ----------
class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});
  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  final _db = InventoryDb();
  late Future<List<Recipe>> _future;

  @override
  void initState() { super.initState(); _reload(); }
  void _reload() { setState(() { _future = _db.recipes(); }); }

  Future<void> _addRecipe() async {
    final name = await showDialog<String>(context: context, builder: (_) => const _TextPrompt(title: "Nouvelle recette", hint: "Nom de la recette"));
    if (name != null && name.trim().isNotEmpty) { await _db.addRecipe(name.trim()); _reload(); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Recettes"), actions: [
        IconButton(onPressed: _addRecipe, icon: const Icon(Icons.add)),
      ]),
      body: FutureBuilder<List<Recipe>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text("Aucune recette. Ajoute-en une avec +"));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = items[i];
              return ListTile(
                title: Text(r.name),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RecipeDetailPage(recipe: r))),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case "rename":
                        final name = await showDialog<String>(context: context, builder: (_) => _TextPrompt(title: "Renommer", initial: r.name));
                        if (name != null && name.trim().isNotEmpty) { await _db.updateRecipe(Recipe(id: r.id, name: name.trim())); _reload(); }
                        break;
                      case "delete":
                        await _db.deleteRecipe(r.id!); _reload();
                        break;
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: "rename", child: Text("Renommer")),
                    PopupMenuItem(value: "delete", child: Text("Supprimer")),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class RecipeDetailPage extends StatefulWidget {
  final Recipe recipe;
  const RecipeDetailPage({super.key, required this.recipe});
  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  final _db = InventoryDb();
  late Future<List<RecipeItem>> _future;

  @override
  void initState() { super.initState(); _reload(); }
  void _reload() { setState(() { _future = _db.recipeItems(widget.recipe.id!); }); }

  Future<void> _addIngredient() async {
    final prod = await showDialog<Product?>(context: context, builder: (_) => const _ProductPickerDialog());
    if (prod == null) return;
    final qtyStr = await showDialog<String>(context: context, builder: (_) => const _TextPrompt(title: "Quantité", hint: "ex. 1"));
    final qty = int.tryParse(qtyStr ?? "");
    if (qty == null || qty <= 0) return;
    await _db.addRecipeItem(recipeId: widget.recipe.id!, productId: prod.id!, qty: qty);
    _reload();
  }

  Future<void> _cook() async {
    await _db.cookRecipe(widget.recipe.id!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Recette cuisinée: stock décrémenté")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recipe.name),
        actions: [IconButton(onPressed: _addIngredient, icon: const Icon(Icons.add))],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _cook, icon: const Icon(Icons.restaurant), label: const Text("Cuisiner")),
      body: FutureBuilder<List<RecipeItem>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text("Aucun ingrédient. Ajoute-en avec +"));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final it = items[i];
              return FutureBuilder<Product?>(
                future: _db.findById(it.productId),
                builder: (context, psnap) {
                  final p = psnap.data;
                  if (p == null) return const ListTile(title: Text("…"));
                  return ListTile(
                    leading: (p.imageUrl != null && p.imageUrl!.isNotEmpty)
                        ? ClipRRect(borderRadius: BorderRadius.circular(20), child: Image.network(p.imageUrl!, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 40)))
                        : const Icon(Icons.fastfood),
                    title: Text(p.name),
                    subtitle: Text("x${it.qty} ${p.unit} • en stock: ${p.quantity}"),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await _db.deleteRecipeItem(it.id!); _reload(); }),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ------- Helpers ----------
class _TextPrompt extends StatefulWidget {
  final String title;
  final String? initial;
  final String? hint;
  const _TextPrompt({required this.title, this.initial, this.hint, super.key});
  @override
  State<_TextPrompt> createState() => _TextPromptState();
}
class _TextPromptState extends State<_TextPrompt> {
  final _c = TextEditingController();
  @override
  void initState() { super.initState(); _c.text = widget.initial ?? ""; }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(controller: _c, decoration: InputDecoration(hintText: widget.hint ?? "")),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Annuler")),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text("OK")),
      ],
    );
  }
}

class _ProductPickerDialog extends StatefulWidget {
  const _ProductPickerDialog({super.key});
  @override
  State<_ProductPickerDialog> createState() => _ProductPickerDialogState();
}
class _ProductPickerDialogState extends State<_ProductPickerDialog> {
  final _db = InventoryDb();
  String _q = "";
  late Future<List<Product>> _f = _db.all();
  void _reload() => setState(() { _f = _db.all(query: _q); });
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Choisir un produit"),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: "Rechercher"), onChanged: (v) { _q = v; _reload(); }),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: FutureBuilder<List<Product>>(
              future: _f,
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final items = snap.data!;
                if (items.isEmpty) return const Center(child: Text("Aucun produit"));
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final p = items[i];
                    return ListTile(
                      leading: (p.imageUrl != null && p.imageUrl!.isNotEmpty)
                          ? ClipRRect(borderRadius: BorderRadius.circular(20), child: Image.network(p.imageUrl!, width: 36, height: 36, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported)))
                          : const Icon(Icons.inventory_2),
                      title: Text(p.name),
                      subtitle: Text("${p.brand.isNotEmpty ? "${p.brand} • " : ""}${p.barcode}"),
                      onTap: () => Navigator.pop(context, p),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Fermer"))],
    );
  }
}
