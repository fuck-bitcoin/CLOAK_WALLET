// CLOAK Database Manager
// Creates a SQLite database with the same structure as Zcash/Ycash
// This allows the UI to work identically for all coins
//
// Uses SQLCipher for encryption (same pattern as Anino/Zcash wallet)

import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import '../pages/utils.dart';

class CloakDb {
  static Database? _db;
  static String? _dbPath;
  static String _password = '';
  static bool _sqlCipherAvailable = false;

  /// Initialize SQLCipher library for encrypted databases
  static void _initSqlCipher() {
    try {
      // Override the sqlite library loader to use sqlcipher
      open.overrideFor(OperatingSystem.linux, () {
        // Try to load SQLCipher library
        try {
          return DynamicLibrary.open('libsqlcipher.so');
        } catch (_) {
          // Fall back to bundled library from sqlcipher_flutter_libs
          try {
            return DynamicLibrary.open('libsqlcipher.so.0');
          } catch (_) {
            // Last resort: use regular sqlite3
            print('CloakDb: SQLCipher not found, falling back to sqlite3');
            return DynamicLibrary.open('libsqlite3.so.0');
          }
        }
      });
      _sqlCipherAvailable = true;
      print('CloakDb: SQLCipher library override configured');
    } catch (e) {
      print('CloakDb: Failed to configure SQLCipher: $e');
      _sqlCipherAvailable = false;
    }
  }

  /// Initialize the database
  /// @param password The encryption password for SQLCipher
  static Future<void> init({String password = ''}) async {
    if (_db != null) return;

    _password = password;

    // Initialize SQLCipher if password provided
    if (_password.isNotEmpty) {
      _initSqlCipher();
    }

    // Initialize FFI for desktop
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final dbDir = await getDbPath();
    _dbPath = p.join(dbDir, 'cloak.db');

    _db = await databaseFactory.openDatabase(
      _dbPath!,
      options: OpenDatabaseOptions(
        version: 7, // v7 adds vault_index column + next_vault_index property
        onConfigure: (db) async {
          // Enable SQLCipher encryption if password provided
          if (_password.isNotEmpty && _sqlCipherAvailable) {
            // Escape single quotes in password
            final escapedPassword = _password.replaceAll("'", "''");
            await db.rawQuery("PRAGMA key = '$escapedPassword'");
            print('CloakDb: Database encryption enabled');
          }
        },
        onCreate: (db, version) async {
          // Match exact Zcash schema for accounts
          await db.execute('''
            CREATE TABLE accounts (
              id_account INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              seed TEXT,
              aindex INTEGER NOT NULL,
              sk TEXT,
              ivk TEXT NOT NULL UNIQUE,
              address TEXT NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX i_account ON accounts(address)');

          // Properties table for settings
          await db.execute('''
            CREATE TABLE properties (
              name TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');

          // Schema version tracking
          await db.execute('''
            CREATE TABLE schema_version (
              id INTEGER PRIMARY KEY NOT NULL,
              version INTEGER NOT NULL
            )
          ''');
          await db.insert('schema_version', {'id': 1, 'version': version});

          // Contacts table (v2)
          await _createContactsTable(db);

          // Messages table (v2)
          await _createMessagesTable(db);

          // Vaults table (v4)
          await _createVaultsTable(db);

          // Burn events table (v6) — persists vault burn timestamps for TX history labeling
          await _createBurnEventsTable(db);

          // Initialize next_vault_index property (v7)
          await db.insert('properties', {'name': 'next_vault_index', 'value': '0'});
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          print('CloakDb: Upgrading from v$oldVersion to v$newVersion');
          if (oldVersion < 2) {
            await _createContactsTable(db);
            await _createMessagesTable(db);
          }
          if (oldVersion < 3) {
            // v3: Fix schema to match Zcash exactly
            // Drop and recreate tables with correct schema
            await db.execute('DROP TABLE IF EXISTS contacts');
            await db.execute('DROP TABLE IF EXISTS messages');
            await _createContactsTable(db);
            await _createMessagesTable(db);
          }
          if (oldVersion < 4) {
            // v4: Add vaults table for CLOAK vault management
            await _createVaultsTable(db);
          }
          if (oldVersion < 5) {
            // v5: Add status column to vaults table for filtering
            // Statuses: created, published, funded, active, empty, burned
            await db.execute("ALTER TABLE vaults ADD COLUMN status TEXT NOT NULL DEFAULT 'created'");
            print('CloakDb: Added status column to vaults table');
          }
          if (oldVersion < 6) {
            // v6: Add burn_events table for persistent vault burn TX labeling
            await _createBurnEventsTable(db);
          }
          if (oldVersion < 7) {
            // v7: Add vault_index column for deterministic vault derivation
            await db.execute("ALTER TABLE vaults ADD COLUMN vault_index INTEGER");
            // Initialize next_vault_index property for deterministic vault creation
            await db.execute("INSERT OR IGNORE INTO properties(name, value) VALUES('next_vault_index', '0')");
            print('CloakDb: v7 migration — added vault_index column + next_vault_index property');
          }
          await db.update('schema_version', {'version': newVersion}, where: 'id = 1');
        },
      ),
    );

    final encStatus = _password.isNotEmpty && _sqlCipherAvailable ? 'encrypted' : 'unencrypted';
    print('CloakDb: Initialized at $_dbPath ($encStatus)');
  }

  /// Get database instance
  static Database get db {
    if (_db == null) throw StateError('CloakDb not initialized. Call init() first.');
    return _db!;
  }

  /// Check if database exists
  static Future<bool> exists() async {
    final dbDir = await getDbPath();
    final path = p.join(dbDir, 'cloak.db');
    return File(path).existsSync();
  }

  /// Create a new account
  /// Returns the account ID, or -1 if account with same name exists
  static Future<int> newAccount({
    required String name,
    required String seed,
    required String ivk,
    required String address,
    String? sk,
    int aindex = 0,
  }) async {
    await init();

    // Check if account with same name exists
    final existing = await _db!.query(
      'accounts',
      where: 'name = ?',
      whereArgs: [name],
    );
    if (existing.isNotEmpty) {
      print('CloakDb: Account "$name" already exists');
      return -1;
    }

    // Insert new account
    final id = await _db!.insert('accounts', {
      'name': name,
      'seed': seed,
      'aindex': aindex,
      'sk': sk,
      'ivk': ivk,
      'address': address,
    });

    print('CloakDb: Created account "$name" with id=$id');
    return id;
  }

  /// Get account by ID
  static Future<Map<String, dynamic>?> getAccount(int id) async {
    await init();
    final results = await _db!.query(
      'accounts',
      where: 'id_account = ?',
      whereArgs: [id],
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// Get all accounts
  static Future<List<Map<String, dynamic>>> getAllAccounts() async {
    await init();
    return await _db!.query('accounts');
  }

  /// Get first account (for initial load)
  static Future<Map<String, dynamic>?> getFirstAccount() async {
    await init();
    final results = await _db!.query('accounts', limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  /// Update account name
  static Future<void> updateAccountName(int id, String name) async {
    await init();
    await _db!.update(
      'accounts',
      {'name': name},
      where: 'id_account = ?',
      whereArgs: [id],
    );
  }

  /// Delete account
  static Future<void> deleteAccount(int id) async {
    await init();
    await _db!.delete(
      'accounts',
      where: 'id_account = ?',
      whereArgs: [id],
    );
  }

  /// Count accounts
  static Future<int> countAccounts() async {
    await init();
    final result = await _db!.rawQuery('SELECT COUNT(*) as count FROM accounts');
    return result.first['count'] as int;
  }

  /// Get property
  static Future<String?> getProperty(String name) async {
    await init();
    final results = await _db!.query(
      'properties',
      where: 'name = ?',
      whereArgs: [name],
    );
    return results.isNotEmpty ? results.first['value'] as String : null;
  }

  /// Set property
  static Future<void> setProperty(String name, String value) async {
    await init();
    await _db!.insert(
      'properties',
      {'name': name, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Close database
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ============== Schema Helpers ==============

  static Future<void> _createContactsTable(Database db) async {
    // Match Zcash contacts schema exactly
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        address TEXT NOT NULL,
        dirty BOOL NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS i_contact ON contacts(address)');
    print('CloakDb: Created contacts table');
  }

  static Future<void> _createMessagesTable(Database db) async {
    // Match Zcash messages schema exactly (v13)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY,
        account INTEGER NOT NULL,
        sender TEXT,
        recipient TEXT NOT NULL,
        subject TEXT NOT NULL,
        body TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        height INTEGER NOT NULL,
        read BOOL NOT NULL DEFAULT 0,
        id_tx INTEGER,
        incoming BOOL NOT NULL DEFAULT 1,
        vout INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS i_message_account ON messages(account)');
    await db.execute('CREATE INDEX IF NOT EXISTS i_message_timestamp ON messages(timestamp)');
    print('CloakDb: Created messages table');
  }

  static Future<void> _createVaultsTable(Database db) async {
    // Vaults table for CLOAK vault/auth token management
    // Each vault has a seed (used to derive commitment hash) and contract
    // Status tracks lifecycle: created → published → funded → active → empty/burned
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vaults (
        id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL,
        seed TEXT NOT NULL,
        commitment_hash TEXT NOT NULL UNIQUE,
        contract TEXT NOT NULL DEFAULT 'thezeostoken',
        label TEXT,
        status TEXT NOT NULL DEFAULT 'created',
        vault_index INTEGER,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        FOREIGN KEY (account_id) REFERENCES accounts(id_account)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS i_vault_account ON vaults(account_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS i_vault_hash ON vaults(commitment_hash)');
    print('CloakDb: Created vaults table');
  }

  static Future<void> _createBurnEventsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS burn_events (
        id INTEGER PRIMARY KEY,
        vault_hash TEXT NOT NULL,
        timestamp_ms INTEGER NOT NULL
      )
    ''');
    print('CloakDb: Created burn_events table');
  }

  // ============== Burn Events ==============

  /// In-memory cache for synchronous access from txs.read()
  static Set<int> _burnTimestampsCache = {};

  /// Synchronous getter for use in accounts.dart txs.read() (which is @action void)
  static Set<int> get burnTimestampsSync => _burnTimestampsCache;

  /// Load burn timestamps from DB into cache (call at startup)
  static Future<void> refreshBurnTimestampsCache() async {
    _burnTimestampsCache = await getBurnTimestamps();
  }

  /// Record a vault burn event for TX history labeling.
  /// Also updates the in-memory cache for immediate availability.
  static Future<void> addBurnEvent(String vaultHash, int timestampMs) async {
    await init();
    await _db!.insert('burn_events', {
      'vault_hash': vaultHash,
      'timestamp_ms': timestampMs,
    });
    _burnTimestampsCache.add(timestampMs);
    print('CloakDb: Recorded burn event for ${vaultHash.substring(0, 16)}... at $timestampMs');
  }

  /// Get all burn event timestamps (for relabeling TX history)
  static Future<Set<int>> getBurnTimestamps() async {
    await init();
    final rows = await _db!.query('burn_events', columns: ['timestamp_ms']);
    return rows.map((r) => r['timestamp_ms'] as int).toSet();
  }

  // ============== Contacts CRUD ==============

  /// Add a new contact
  /// Returns the contact ID, or -1 if contact with same address exists
  static Future<int> addContact({
    required String name,
    required String address,
  }) async {
    await init();
    try {
      final id = await _db!.insert('contacts', {
        'name': name,
        'address': address,
      });
      print('CloakDb: Added contact "$name" with id=$id');
      return id;
    } catch (e) {
      // Likely unique constraint violation
      print('CloakDb: Failed to add contact: $e');
      return -1;
    }
  }

  /// Update a contact
  static Future<void> updateContact(int id, {String? name, String? address}) async {
    await init();
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (address != null) updates['address'] = address;
    if (updates.isNotEmpty) {
      await _db!.update('contacts', updates, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// Delete a contact
  static Future<void> deleteContact(int id) async {
    await init();
    await _db!.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  /// Get all contacts
  static Future<List<Map<String, dynamic>>> getContacts() async {
    await init();
    return await _db!.query('contacts', orderBy: 'name ASC');
  }

  /// Get contact by address
  static Future<Map<String, dynamic>?> getContactByAddress(String address) async {
    await init();
    final results = await _db!.query('contacts', where: 'address = ?', whereArgs: [address]);
    return results.isNotEmpty ? results.first : null;
  }

  /// Get contact by ID
  static Future<Map<String, dynamic>?> getContactById(int id) async {
    await init();
    final results = await _db!.query('contacts', where: 'id = ?', whereArgs: [id]);
    return results.isNotEmpty ? results.first : null;
  }

  // ============== Messages CRUD ==============

  /// Store a message (matches Zcash schema)
  static Future<int> storeMessage({
    required int account,
    int? idTx,
    required bool incoming,
    String? sender,
    required String recipient,
    required String subject,
    required String body,
    required int timestamp,
    required int height,
    bool read = false,
    int vout = 0,
  }) async {
    await init();
    final id = await _db!.insert('messages', {
      'account': account,
      'id_tx': idTx,
      'incoming': incoming ? 1 : 0,
      'sender': sender,
      'recipient': recipient,
      'subject': subject,
      'body': body,
      'timestamp': timestamp,
      'height': height,
      'read': read ? 1 : 0,
      'vout': vout,
    });
    return id;
  }

  /// Get messages for an account
  static Future<List<Map<String, dynamic>>> getMessages(int account) async {
    await init();
    return await _db!.query(
      'messages',
      where: 'account = ?',
      whereArgs: [account],
      orderBy: 'timestamp DESC',
    );
  }

  /// Mark message as read/unread
  static Future<void> markMessageRead(int id, bool read) async {
    await init();
    await _db!.update('messages', {'read': read ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  /// Mark all messages as read for an account
  static Future<void> markAllMessagesRead(int account, bool read) async {
    await init();
    await _db!.update('messages', {'read': read ? 1 : 0}, where: 'account = ?', whereArgs: [account]);
  }

  /// Delete a message
  static Future<void> deleteMessage(int id) async {
    await init();
    await _db!.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  /// Check if message exists by id_tx (to avoid duplicates)
  static Future<bool> messageExistsByIdTx(int idTx) async {
    await init();
    final results = await _db!.query('messages', where: 'id_tx = ?', whereArgs: [idTx]);
    return results.isNotEmpty;
  }

  /// Check if message exists by body content (for deduplication by header)
  static Future<bool> messageExistsByBody(int account, String body) async {
    await init();
    final results = await _db!.query('messages', where: 'account = ? AND body = ?', whereArgs: [account, body]);
    return results.isNotEmpty;
  }

  /// Get unread message count for account
  static Future<int> getUnreadMessageCount(int account) async {
    await init();
    final result = await _db!.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE account = ? AND read = 0',
      [account],
    );
    return result.first['count'] as int;
  }

  // ============== Vaults CRUD ==============

  /// Add a new vault
  /// Returns the vault ID, or -1 if vault with same commitment hash exists
  static Future<int> addVault({
    required int accountId,
    required String seed,
    required String commitmentHash,
    String contract = 'thezeostoken',
    String? label,
    String status = 'created',
    int? vaultIndex,
  }) async {
    await init();
    try {
      final id = await _db!.insert('vaults', {
        'account_id': accountId,
        'seed': seed,
        'commitment_hash': commitmentHash,
        'contract': contract,
        'label': label,
        'status': status,
        'vault_index': vaultIndex,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      print('CloakDb: Added vault "${label ?? commitmentHash.substring(0, 16)}..." with id=$id');
      return id;
    } catch (e) {
      // Likely unique constraint violation (duplicate commitment hash)
      print('CloakDb: Failed to add vault: $e');
      return -1;
    }
  }

  /// Get vault by ID
  static Future<Map<String, dynamic>?> getVaultById(int id) async {
    await init();
    final results = await _db!.query('vaults', where: 'id = ?', whereArgs: [id]);
    return results.isNotEmpty ? results.first : null;
  }

  /// Get vault by commitment hash
  static Future<Map<String, dynamic>?> getVaultByHash(String commitmentHash) async {
    await init();
    final results = await _db!.query('vaults', where: 'commitment_hash = ?', whereArgs: [commitmentHash]);
    return results.isNotEmpty ? results.first : null;
  }

  /// Get all vaults for an account
  static Future<List<Map<String, dynamic>>> getVaultsForAccount(int accountId) async {
    await init();
    return await _db!.query('vaults', where: 'account_id = ?', whereArgs: [accountId], orderBy: 'created_at DESC');
  }

  /// Get all vaults
  static Future<List<Map<String, dynamic>>> getAllVaults() async {
    await init();
    return await _db!.query('vaults', orderBy: 'created_at DESC');
  }

  /// Update vault label
  static Future<void> updateVaultLabel(int id, String label) async {
    await init();
    await _db!.update('vaults', {'label': label}, where: 'id = ?', whereArgs: [id]);
  }

  /// Delete a vault
  static Future<void> deleteVault(int id) async {
    await init();
    await _db!.delete('vaults', where: 'id = ?', whereArgs: [id]);
  }

  /// Check if vault exists by commitment hash
  static Future<bool> vaultExistsByHash(String commitmentHash) async {
    await init();
    final results = await _db!.query('vaults', where: 'commitment_hash = ?', whereArgs: [commitmentHash]);
    return results.isNotEmpty;
  }

  /// Count vaults for an account
  static Future<int> countVaultsForAccount(int accountId) async {
    await init();
    final result = await _db!.rawQuery(
      'SELECT COUNT(*) as count FROM vaults WHERE account_id = ?',
      [accountId],
    );
    return result.first['count'] as int;
  }

  /// Update vault status
  /// Valid statuses: created, published, funded, active, empty, burned
  static Future<void> updateVaultStatus(int id, String status) async {
    await init();
    await _db!.update('vaults', {'status': status}, where: 'id = ?', whereArgs: [id]);
    print('CloakDb: Updated vault $id status to $status');
  }

  /// Update vault status by commitment hash
  static Future<void> updateVaultStatusByHash(String commitmentHash, String status) async {
    await init();
    final count = await _db!.update(
      'vaults',
      {'status': status},
      where: 'commitment_hash = ?',
      whereArgs: [commitmentHash],
    );
    if (count > 0) {
      print('CloakDb: Updated vault ${commitmentHash.substring(0, 16)}... status to $status');
    }
  }

  /// Update vault commitment hash (for fixing hashes computed with wrong address)
  static Future<void> updateVaultCommitmentHash(int id, String newHash) async {
    await init();
    await _db!.update('vaults', {'commitment_hash': newHash}, where: 'id = ?', whereArgs: [id]);
    print('CloakDb: Updated vault $id commitment_hash to ${newHash.substring(0, 16)}...');
  }

  /// Get all vaults with a specific status
  static Future<List<Map<String, dynamic>>> getVaultsByStatus(String status) async {
    await init();
    return await _db!.query('vaults', where: 'status = ?', whereArgs: [status], orderBy: 'created_at DESC');
  }

  /// Get the next vault index for deterministic vault creation
  static Future<int> getNextVaultIndex() async {
    final value = await getProperty('next_vault_index');
    return int.tryParse(value ?? '0') ?? 0;
  }

  /// Increment and persist the next vault index
  static Future<void> incrementNextVaultIndex() async {
    final current = await getNextVaultIndex();
    await setProperty('next_vault_index', '${current + 1}');
  }

  /// Set the next vault index to a specific value (used by discovery)
  static Future<void> setNextVaultIndex(int index) async {
    await setProperty('next_vault_index', '$index');
  }

  /// Get all vault commitment hashes that should be visible to the web app
  /// Returns hashes for vaults with status: funded, active (i.e., have on-chain deposits)
  static Future<Set<String>> getActiveVaultHashes() async {
    await init();
    final results = await _db!.query(
      'vaults',
      columns: ['commitment_hash'],
      where: "status IN ('funded', 'active')",
    );
    return results.map((r) => r['commitment_hash'] as String).toSet();
  }
}
