/*  =========================
    miam9 — Suggestions & Courses
    - Scan + OFF (photo) + Stock SQLite ?
    - Recettes auto-suggérées selon le stock ?
    - Portions 1..6 ?
    - Onglet Courses (ingrédients manquants) ?
    - Build CI Android inchangé ?
   ========================= */

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
          children: const [InventoryPage(), SuggestionsPage(), ShoppingPage()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: "Stock"),
            NavigationDestination(icon: Icon(Icons.restaurant_menu_outlined), selectedIcon: Icon(Icons.restaurant_menu), label: "Recettes"),
            NavigationDestination(icon: Icon(Icons.shopping_cart_outlined), selectedIcon: Icon(Icons.shopping_cart), label: "Courses"),
          ],
        ),
      ),
    );
  }
}

/* ======================
   Modèles & base de données
   ====================== */

class Product {
  final int? id;
  final String barcode;
  final String name;
  final String brand;
  final String unit;     // "pcs", "g", "kg", "ml", "L"
  final int quantity;    // nombre ou quantité (arrondi au plus proche)
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
  final int qty; // pour les recettes créées à la main (inchangé)
  RecipeItem({this.id, required this.recipeId, required this.productId, required this.qty});
  Map<String, Object?> toMap() => {"id": id, "recipeId": recipeId, "productId": productId, "qty": qty};
  static RecipeItem fromMap(Map<String, Object?> m) => RecipeItem(
    id: m["id"] as int?, recipeId: m["recipeId"] as int, productId: m["productId"] as int, qty: m["qty"] as int);
}

/* Shopping list */
class ShoppingItem {
  final int? id;
  final String name;
  final String unit; // "pcs","g","kg","ml","L"
  final int qty;
  final bool checked;
  ShoppingItem({this.id, required this.name, this.unit = "pcs", this.qty = 1, this.checked = false});
  Map<String, Object?> toMap() => {"id": id, "name": name, "unit": unit, "qty": qty, "checked": checked ? 1 : 0};
  static ShoppingItem fromMap(Map<String, Object?> m) => ShoppingItem(
    id: m["id"] as int?,
    name: m["name"] as String,
    unit: (m["unit"] ?? "pcs") as String,
    qty: (m["qty"] ?? 1) as int,
    checked: ((m["checked"] ?? 0) as int) == 1,
  );
}

/* ---- DB ---- */
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
      version: 3, // v3: add shopping_items
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

        await db.execute("""
          CREATE TABLE recipes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL
          );
        """);
        await db.execute("""
          CREATE TABLE recipe_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recipeId INTEGER NOT NULL,
            productId INTEGER NOT NULL,
            qty INTEGER NOT NULL,
            FOREIGN KEY(recipeId) REFERENCES recipes(id) ON DELETE CASCADE,
            FOREIGN KEY(productId) REFERENCES products(id) ON DELETE CASCADE
          );
        """);
        await db.execute("CREATE INDEX IF NOT EXISTS idx_recipe_items_recipe ON recipe_items(recipeId);");

        await db.execute("""
          CREATE TABLE shopping_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            unit TEXT DEFAULT 'pcs',
            qty INTEGER NOT NULL DEFAULT 1,
            checked INTEGER NOT NULL DEFAULT 0
          );
        """);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute("ALTER TABLE products ADD COLUMN imageUrl TEXT;");
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
              qty INTEGER NOT NULL
            );
          """);
          await db.execute("CREATE INDEX IF NOT EXISTS idx_recipe_items_recipe ON recipe_items(recipeId);");
        }
        if (oldV < 3) {
          await db.execute("""
            CREATE TABLE IF NOT EXISTS shopping_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              unit TEXT DEFAULT 'pcs',
              qty INTEGER NOT NULL DEFAULT 1,
              checked INTEGER NOT NULL DEFAULT 0
            );
          """);
        }
      },
    );
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

  // SHOPPING
  Future<List<ShoppingItem>> shoppingList({bool onlyOpen = false}) async {
    final db = await database;
    final rows = await db.query("shopping_items", where: onlyOpen ? "checked = 0" : null, orderBy: "checked ASC, name COLLATE NOCASE");
    return rows.map(ShoppingItem.fromMap).toList();
  }
  Future<void> addShopping(String name, {String unit = "pcs", int qty = 1}) async {
    final db = await database;
    await db.insert("shopping_items", {"name": name, "unit": unit, "qty": qty, "checked": 0});
  }
  Future<void> toggleShopping(int id, bool checked) async {
    final db = await database;
    await db.update("shopping_items", {"checked": checked ? 1 : 0}, where: "id = ?", whereArgs: [id]);
  }
  Future<void> deleteShopping(int id) async {
    final db = await database;
    await db.delete("shopping_items", where: "id = ?", whereArgs: [id]);
  }
  Future<void> clearCheckedShopping() async {
    final db = await database;
    await db.delete("shopping_items", where: "checked = 1");
  }

  // RECIPES (manuelles, conservées)
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

  Future<void> cookUsing({required List<_UseProduct> uses}) async {
    final db = await database;
    for (final u in uses) {
      await adjustQuantity(id: u.productId, delta: -u.qtyToUse);
    }
  }
}

/* ======================
   OFF autofill (nom, marque, image, unité)
   ====================== */
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
      // Normalise en HTTPS pour Android 9+ (bloque le HTTP clair)
      String img = image;
      if (img.startsWith("http://")) { img = img.replaceFirst("http://", "https://"); }
      String unit = "pcs";
      final qLower = q.toLowerCase();
      if (qLower.contains("kg")) unit = "kg";
      else if (qLower.contains("g")) unit = "g";
      else if (qLower.contains("ml")) unit = "ml";
      else if (qLower.contains("l")) unit = "L"; // we keep unit=pcs unless L/ml for info
      return OffAutofill(name: name, brand: brand, unit: unit, imageUrl: img.isEmpty ? null : img);
    } catch (_) {
      return null;
    }
  }
}

/* ======================
   Suggestions de recettes (catalogue embarqué)
   ====================== */

class IngredientNeed {
  final List<String> keywords; // ex: ["pâte","spaghetti","penne"]
  final double qty;            // quantité pour servingsBase (en "unit")
  final String unit;           // "pcs","g","kg","ml","L"
  final bool optional;         // ingrédients optionnels (ex. herbes)
  const IngredientNeed(this.keywords, this.qty, this.unit, {this.optional = false});
}

class RecipeTemplate {
  final String name;
  final int servingsBase;                // nombre de personnes pour lequel qty est définie
  final List<IngredientNeed> needs;
  const RecipeTemplate(this.name, this.servingsBase, this.needs);
}

/* ?? Pack de base ~25 recettes (extensible)
   Tu peux en ajouter très facilement : même structure.
   Astuce: keywords multi-synonymes pour matcher le nom produit. */
const List<RecipeTemplate> kTemplates = [
  RecipeTemplate("Pâtes à la tomate", 2, [
    IngredientNeed(["pâte","spaghetti","penne","coquillettes"], 200, "g"),
    IngredientNeed(["tomate","passata","coulis","sauce tomate"], 200, "g"),
    IngredientNeed(["oignon"], 1, "pcs", optional: true),
    IngredientNeed(["ail"], 1, "pcs", optional: true),
  ]),
  RecipeTemplate("Omelette", 2, [
    IngredientNeed(["oeuf","œuf"], 4, "pcs"),
    IngredientNeed(["lait","crème"], 50, "ml", optional: true),
    IngredientNeed(["fromage","gruyère","emmental"], 40, "g", optional: true),
  ]),
  RecipeTemplate("Crêpes", 2, [
    IngredientNeed(["farine"], 150, "g"),
    IngredientNeed(["lait"], 300, "ml"),
    IngredientNeed(["oeuf","œuf"], 2, "pcs"),
  ]),
  RecipeTemplate("Riz au lait", 2, [
    IngredientNeed(["riz rond","riz dessert","riz"], 120, "g"),
    IngredientNeed(["lait"], 600, "ml"),
    IngredientNeed(["sucre"], 40, "g"),
  ]),
  RecipeTemplate("Salade thon maïs", 2, [
    IngredientNeed(["thon"], 140, "g"),
    IngredientNeed(["maïs"], 140, "g"),
    IngredientNeed(["salade","laitue","mâche"], 100, "g", optional: true),
  ]),
  RecipeTemplate("Poulet curry riz", 2, [
    IngredientNeed(["poulet"], 300, "g"),
    IngredientNeed(["riz"], 140, "g"),
    IngredientNeed(["crème","lait coco","coco"], 150, "ml"),
    IngredientNeed(["curry"], 10, "g", optional: true),
  ]),
  RecipeTemplate("Soupe de légumes", 2, [
    IngredientNeed(["carotte"], 200, "g"),
    IngredientNeed(["pomme de terre","patate"], 200, "g"),
    IngredientNeed(["poireau","courgette","oignon"], 150, "g"),
  ]),
  RecipeTemplate("Pâtes carbonara (FR style)", 2, [
    IngredientNeed(["pâte","spaghetti","penne"], 200, "g"),
    IngredientNeed(["lardons","bacon"], 150, "g"),
    IngredientNeed(["crème"], 150, "ml"),
    IngredientNeed(["fromage","parmesan"], 40, "g", optional: true),
  ]),
  RecipeTemplate("Gratin dauphinois", 2, [
    IngredientNeed(["pomme de terre","patate"], 600, "g"),
    IngredientNeed(["crème","lait"], 200, "ml"),
    IngredientNeed(["ail"], 1, "pcs", optional: true),
    IngredientNeed(["fromage"], 50, "g", optional: true),
  ]),
  RecipeTemplate("Salade de riz", 2, [
    IngredientNeed(["riz"], 150, "g"),
    IngredientNeed(["thon","jambon"], 120, "g", optional: true),
    IngredientNeed(["maïs","poivron","olives"], 120, "g", optional: true),
  ]),
  // ... (tu pourras facilement en ajouter d'autres ou charger un pack JSON)
];

/* ============ Matching & scaling ============ */

class _StockView {
  final Product product;
  _StockView(this.product);
  bool matches(List<String> kws) {
    final n = (product.name + " " + product.brand).toLowerCase();
    for (final kw in kws) {
      if (n.contains(kw.toLowerCase())) return true;
    }
    return false;
  }
}

int _toBaseUnitInt(int qty, String unit) {
  // On simplifie: "kg"-> g*1000 ; "L"-> ml*1000
  switch (unit) {
    case "kg": return qty * 1000;
    case "L": return qty * 1000;
    default: return qty;
  }
}

double _scaleRequired(double baseQty, int baseServ, int people) {
  return baseQty * (people / baseServ);
}

class _UseProduct {
  final int productId;
  final int qtyToUse; // en unité de stockage du produit
  const _UseProduct({required this.productId, required this.qtyToUse});
}

class SuggestResult {
  final RecipeTemplate template;
  final int people;
  final int ok;
  final int total;
  final List<String> missingLabels; // ex: "oeuf x2", "lait 200ml"
  final List<_UseProduct> uses;     // ce qu'on va décrémenter si on cuisine
  SuggestResult({
    required this.template,
    required this.people,
    required this.ok,
    required this.total,
    required this.missingLabels,
    required this.uses,
  });
  bool get cookable => ok == total;
  double get score => total == 0 ? 0 : ok / total;
}

class SuggestEngine {
  // Calcule la suggestion pour un template et un stock donné
  static SuggestResult evaluate({
    required RecipeTemplate tpl,
    required List<Product> stock,
    required int people,
  }) {
    final views = stock.map(_StockView.new).toList();
    int ok = 0;
    final total = tpl.needs.where((n) => !n.optional).length;
    final missing = <String>[];
    final uses = <_UseProduct>[];

    for (final need in tpl.needs) {
      if (need.optional) {
        // on ignore dans le score, mais on peut consommer si présent
        final match = views.where((v) => v.matches(need.keywords)).toList();
        if (match.isNotEmpty) {
          final best = match..sort((a,b) => b.product.quantity.compareTo(a.product.quantity));
          final picked = best.first.product;
          final req = _scaleRequired(need.qty, tpl.servingsBase, people);
          final reqInt = req.ceil();
          if (picked.quantity >= reqInt) {
            uses.add(_UseProduct(productId: picked.id!, qtyToUse: reqInt));
          }
        }
        continue;
      }
      // obligatoire
      final match = views.where((v) => v.matches(need.keywords)).toList();
      if (match.isEmpty) {
        final unitLbl = need.unit;
        final req = _scaleRequired(need.qty, tpl.servingsBase, people).ceil();
        missing.add("${need.keywords.first} ${unitLbl == "pcs" ? "x$req" : "$req$unitLbl"}");
        continue;
      }
      // pick the product with highest quantity
      final best = match..sort((a,b) => b.product.quantity.compareTo(a.product.quantity));
      final picked = best.first.product;

      // On suppose même unité logique (pcs/g/ml…). Pour un app plus avancée, prévoir conversions.
      final req = _scaleRequired(need.qty, tpl.servingsBase, people);
      final reqInt = req.ceil();
      if (picked.quantity >= reqInt) {
        ok += 1;
        uses.add(_UseProduct(productId: picked.id!, qtyToUse: reqInt));
      } else {
        final lack = reqInt - picked.quantity;
        final unitLbl = picked.unit;
        missing.add("${need.keywords.first} ${unitLbl == "pcs" ? "x$lack" : "$lack$unitLbl"}");
      }
    }

    return SuggestResult(
      template: tpl,
      people: people,
      ok: ok,
      total: total,
      missingLabels: missing,
      uses: uses,
    );
  }

  static List<SuggestResult> compute({
    required List<RecipeTemplate> templates,
    required List<Product> stock,
    required int people,
  }) {
    final out = <SuggestResult>[];
    for (final t in templates) {
      out.add(evaluate(tpl: t, stock: stock, people: people));
    }
    // Tri: cuisinnables d'abord, sinon score décroissant
    out.sort((a,b) {
      if (a.cookable && !b.cookable) return -1;
      if (!a.cookable && b.cookable) return 1;
      return b.score.compareTo(a.score);
    });
    return out;
  }
}

/* ======================
   UI — Stock (identique à ta base stable)
   ====================== */

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
  void _reload() { setState(() { _future = _db.all(query: _query); }); }

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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Quantité mise à jour (${delta >= 0 ? "+" : ""}$delta)")));
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

/* ======================
   UI — Suggestions (onglet Recettes)
   ====================== */

class SuggestionsPage extends StatefulWidget {
  const SuggestionsPage({super.key});
  @override
  State<SuggestionsPage> createState() => _SuggestionsPageState();
}

class _SuggestionsPageState extends State<SuggestionsPage> {
  final _db = InventoryDb();
  int _people = 2;
  late Future<List<Product>> _stockF = _db.all();

  Future<void> _recompute() async {
    setState(() { _stockF = _db.all(); });
  }

  Future<void> _cook(SuggestResult res) async {
    await _db.cookUsing(uses: res.uses);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Cuisiné: ${res.template.name} pour ${res.people}")));
    _recompute();
  }

  Future<void> _addMissingToShopping(List<String> missing) async {
    for (final m in missing) {
      // m ex: "oeuf x2" ou "lait 200ml"
      final parts = m.split(" ");
      final name = parts.first;
      // parse quantité si possible
      int qty = 1;
      String unit = "pcs";
      final last = parts.isNotEmpty ? parts.last : "";
      final ml = RegExp(r"^(\d+)(ml|g)$");
      final pcs = RegExp(r"^x(\d+)$");
      if (ml.hasMatch(last)) {
        final g = ml.firstMatch(last)!;
        qty = int.parse(g.group(1)!);
        unit = g.group(2)! == "ml" ? "ml" : "g";
      } else if (pcs.hasMatch(last)) {
        qty = int.parse(pcs.firstMatch(last)!.group(1)!);
        unit = "pcs";
      }
      await _db.addShopping(name, unit: unit, qty: qty);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ajouté aux courses")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Recettes suggérées"),
        actions: [
          IconButton(
            tooltip: "Rafraîchir",
            onPressed: _recompute,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text("Portions: "),
                Expanded(
                  child: Slider(
                    min: 1, max: 6, divisions: 5,
                    value: _people.toDouble(),
                    label: "${_people.toString()}",
                    onChanged: (v) => setState(() => _people = v.round()),
                  ),
                ),
                Text("${_people}"),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Product>>(
              future: _stockF,
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final stock = snap.data!;
                final results = SuggestEngine.compute(templates: kTemplates, stock: stock, people: _people);
                final cookables = results.where((r) => r.cookable).toList();
                final almost = results.where((r) => !r.cookable).toList();

                return ListView(
                  children: [
                    _SectionHeader(title: "Cuisinables maintenant", count: cookables.length, icon: Icons.check_circle),
                    if (cookables.isEmpty)
                      const ListTile(title: Text("Rien pour l’instant — scanne un produit ou baisse le nombre de portions.")),
                    ...cookables.map((r) => _RecipeCard(
                      res: r,
                      onCook: () => _cook(r),
                      onAddMissing: () {}, // rien à ajouter (complet)
                    )),

                    const Divider(height: 24),
                    _SectionHeader(title: "Presque (ingrédients manquants)", count: almost.length, icon: Icons.hourglass_bottom),
                    ...almost.map((r) => _RecipeCard(
                      res: r,
                      onCook: null,
                      onAddMissing: () => _addMissingToShopping(r.missingLabels),
                    )),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title; final int count; final IconData icon;
  const _SectionHeader({required this.title, required this.count, required this.icon, super.key});
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      trailing: Text("$count"),
    );
  }
}

class _RecipeCard extends StatelessWidget {
  final SuggestResult res;
  final VoidCallback? onCook;
  final VoidCallback onAddMissing;
  const _RecipeCard({required this.res, required this.onAddMissing, this.onCook, super.key});

  @override
  Widget build(BuildContext context) {
    final badge = "${res.ok}/${res.total} ok";
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("${res.template.name} — ${res.people} pers.", style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                Chip(label: Text(badge)),
                const SizedBox(width: 8),
                if (res.cookable) const Chip(label: Text("Prêt à cuisiner")),
              ],
            ),
            if (!res.cookable) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: res.missingLabels.map((m) => Chip(avatar: const Icon(Icons.shopping_cart, size: 16), label: Text(m))).toList(),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (res.cookable)
                  FilledButton.icon(onPressed: onCook, icon: const Icon(Icons.restaurant), label: const Text("Cuisiner")),
                const Spacer(),
                OutlinedButton.icon(onPressed: onAddMissing, icon: const Icon(Icons.add_shopping_cart), label: const Text("Ajouter aux courses")),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/* ======================
   UI — Courses (onglet)
   ====================== */

class ShoppingPage extends StatefulWidget {
  const ShoppingPage({super.key});
  @override
  State<ShoppingPage> createState() => _ShoppingPageState();
}
class _ShoppingPageState extends State<ShoppingPage> {
  final _db = InventoryDb();
  late Future<List<ShoppingItem>> _future = _db.shoppingList();

  void _reload() => setState(() => _future = _db.shoppingList());

  Future<void> _addItem() async {
    final name = await showDialog<String>(context: context, builder: (_) => const _TextPrompt(title: "Ajouter un article", hint: "ex. oeuf"));
    if (name == null || name.trim().isEmpty) return;
    await _db.addShopping(name.trim());
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Mes courses"),
        actions: [
          IconButton(onPressed: _addItem, icon: const Icon(Icons.add)),
          IconButton(onPressed: () async { await _db.clearCheckedShopping(); _reload(); }, icon: const Icon(Icons.delete_sweep)),
        ],
      ),
      body: FutureBuilder<List<ShoppingItem>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text("Ta liste de courses est vide."));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final it = items[i];
              return CheckboxListTile(
                value: it.checked,
                onChanged: (v) async { await _db.toggleShopping(it.id!, v ?? false); _reload(); },
                title: Text(it.name),
                subtitle: Text("${it.qty} ${it.unit}"),
                secondary: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await _db.deleteShopping(it.id!); _reload(); }),
              );
            },
          );
        },
      ),
    );
  }
}

/* ======================
   Scanner & Dialogs (repris)
   ====================== */

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
        FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: const Text("OK")),
      ],
    );
  }
}



