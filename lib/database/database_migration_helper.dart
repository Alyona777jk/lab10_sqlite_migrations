import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

typedef DbRow = Map<String, Object?>;

class DatabaseMigrationHelper {
  static final DatabaseMigrationHelper instance = DatabaseMigrationHelper._init();
  static Database? _database;

  static const int currentVersion = 4;

  void Function(String)? onLog;

  DatabaseMigrationHelper._init();

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final formatted = '[$timestamp] $message';
    debugPrint(formatted);
    onLog?.call(formatted);
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('app_v$currentVersion.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: currentVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      onDowngrade: onDatabaseDowngradeDelete,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    _log('Створення нової БД версії $version...');

    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL
      )
    ''');

    await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');

    await db.execute('''
      CREATE TABLE preferences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        userId INTEGER NOT NULL,
        theme TEXT NOT NULL DEFAULT 'light',
        language TEXT NOT NULL DEFAULT 'uk',
        FOREIGN KEY (userId) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('CREATE INDEX idx_users_email ON users (email)');
    await db.execute('CREATE INDEX idx_pref_user ON preferences (userId)');

    final userId = await db.insert('users', {
      'name': 'Іван Коваленко',
      'email': 'ivan@example.com',
      'phone': '+380501234567',
    });
    await db.insert('preferences', {
      'userId': userId,
      'theme': 'dark',
      'language': 'uk',
    });

    _log('БД успішно створена на версії $version.');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    _log('Початок міграції: v$oldVersion -> v$newVersion');
    await db.execute('SAVEPOINT migration_sp');

    try {
      if (oldVersion < 2) {
        _log('Крок 1 -> 2: Додавання колонки phone до таблиці users');
        await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');
      }

      if (oldVersion < 3) {
        _log('Крок 2 -> 3: Створення таблиці preferences та перенесення користувачів');
        await db.execute('''
          CREATE TABLE preferences (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            userId INTEGER NOT NULL,
            theme TEXT NOT NULL DEFAULT 'light',
            language TEXT NOT NULL DEFAULT 'uk',
            FOREIGN KEY (userId) REFERENCES users (id) ON DELETE CASCADE
          )
        ''');

        await db.rawInsert('''
          INSERT INTO preferences (userId, theme, language)
          SELECT id, 'light', 'uk' FROM users
        ''');
      }

      if (oldVersion < 4) {
        _log('Крок 3 -> 4: Створення індексів для оптимізації пошуку');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_pref_user ON preferences (userId)');
      }

      await _verifyIntegrity(db);

      await db.execute('RELEASE SAVEPOINT migration_sp');
      _log('Міграцію v$oldVersion -> v$newVersion успішно зафіксовано.');
    } catch (e) {
      _log('ПОМИЛКА міграції: $e. Виконується ROLLBACK...');
      await db.execute('ROLLBACK TO SAVEPOINT migration_sp');
      await db.execute('RELEASE SAVEPOINT migration_sp');
      _log('ROLLBACK завершено. Дані відновлено до стану v$oldVersion.');
      rethrow;
    }
  }

  Future<void> _verifyIntegrity(Database db) async {
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    if (integrity.first['integrity_check'] != 'ok') {
      throw Exception('Помилка цілісності БД: ${integrity.first}');
    }

    final fkCheck = await db.rawQuery('PRAGMA foreign_key_check');
    if (fkCheck.isNotEmpty) {
      throw Exception('Порушення зовнішніх ключів: $fkCheck');
    }

    _log('Перевірка цілісності (PRAGMA integrity_check & foreign_key_check): OK');
  }

  void _expect(bool condition, String errorMessage) {
    if (!condition) throw Exception(errorMessage);
  }

  Future<DbRow> runFullMigrationTest({int startVersion = 1}) async {
    _log('=== ЗАПУСК ТЕСТУ МІГРАЦІЇ (v$startVersion -> v$currentVersion) ===');
    final dbDir = await getDatabasesPath();
    final testPath = join(dbDir, 'test_migration_v$startVersion.db');

    await deleteDatabase(testPath);

    var testDb = await openDatabase(
      testPath,
      version: startVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL
          )
        ''');

        if (version >= 2) {
          await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');
          await db.insert('users', {
            'name': 'Олена Петренко',
            'email': 'olena@test.com',
            'phone': '+380670001122',
          });
        } else {
          await db.insert('users', {
            'name': 'Олена Петренко',
            'email': 'olena@test.com',
          });
        }

        if (version >= 3) {
          await db.execute('''
            CREATE TABLE preferences (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              userId INTEGER NOT NULL,
              theme TEXT NOT NULL DEFAULT 'light',
              language TEXT NOT NULL DEFAULT 'uk',
              FOREIGN KEY (userId) REFERENCES users (id) ON DELETE CASCADE
            )
          ''');
          await db.insert('preferences', {
            'userId': 1,
            'theme': 'dark',
            'language': 'en',
          });
        }
      },
    );
    _log('Створено тестову БД версії $startVersion з тестовим користувачем.');
    await testDb.close();

    testDb = await openDatabase(
      testPath,
      version: currentVersion,
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
      onUpgrade: _upgradeDB,
    );

    final users = await testDb.query('users');
    _expect(users.isNotEmpty, 'Дані користувачів втрачено після міграції!');
    _expect(users.first['name'] == 'Олена Петренко', 'Імʼя користувача пошкоджено!');
    _log('Перевірка даних users: OK (${users.first})');

    final tableInfo = await testDb.rawQuery('PRAGMA table_info(users)');
    final columns = tableInfo.map((c) => c['name']).toList();
    _expect(columns.contains('phone'), 'Колонка phone відсутня після міграції!');

    final prefs = await testDb.query('preferences');
    _expect(prefs.isNotEmpty, 'Записи preferences не створені для існуючих користувачів!');
    _log('Перевірка даних preferences: OK (${prefs.first})');

    final indexes = await testDb.rawQuery('PRAGMA index_list(users)');
    _expect(
      indexes.any((idx) => idx['name'] == 'idx_users_email'),
      'Індекс idx_users_email не створено!',
    );
    _log('Перевірка індексів: OK');

    final resultData = <String, Object?>{
      'startVersion': startVersion,
      'endVersion': await testDb.getVersion(),
      'user': users.first,
      'preferences': prefs.first,
    };

    await testDb.close();
    await deleteDatabase(testPath);
    _log('=== ТЕСТ v$startVersion -> v$currentVersion УСПІШНО ПРОЙДЕНО ===');

    return resultData;
  }

  Future<void> testRollbackOnFailure() async {
    _log('=== ТЕСТ ROLLBACK ПРИ ПОМИЛЦІ МІГРАЦІЇ ===');
    final dbDir = await getDatabasesPath();
    final rollbackPath = join(dbDir, 'test_rollback.db');
    await deleteDatabase(rollbackPath);

    var db = await openDatabase(
      rollbackPath,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)');
        await db.insert('users', {'id': 1, 'name': 'Критичний Користувач', 'email': 'safe@db.ua'});
      },
    );
    await db.close();

    try {
      db = await openDatabase(
        rollbackPath,
        version: 2,
        onUpgrade: (db, oldV, newV) async {
          await db.execute('SAVEPOINT fail_sp');
          try {
            await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');
            await db.execute('INSERT INTO non_existent_table VALUES (1)');
            await db.execute('RELEASE SAVEPOINT fail_sp');
          } catch (e) {
            _log('Спіймано збій міграції: $e');
            await db.execute('ROLLBACK TO SAVEPOINT fail_sp');
            await db.execute('RELEASE SAVEPOINT fail_sp');
            rethrow;
          }
        },
      );
    } catch (_) {
      _log('Міграцію скасовано. Перевіряємо збереження початкової схеми v1...');
    }

    db = await openDatabase(rollbackPath, version: 1);
    final users = await db.query('users');
    final cols = (await db.rawQuery('PRAGMA table_info(users)')).map((e) => e['name']).toList();

    _expect(users.length == 1 && users.first['name'] == 'Критичний Користувач', 'Дані пошкоджено!');
    _expect(!cols.contains('phone'), 'Rollback не скасував часткову зміну схеми!');

    await db.close();
    await deleteDatabase(rollbackPath);
    _log('=== ROLLBACK ПРАЦЮЄ КОРЕКТНО: БД залишилась у стабільному стані v1 ===');
  }

  Future<int> getDatabaseVersion() async {
    final db = await database;
    return await db.getVersion();
  }

  Future<List<DbRow>> getTableInfo(String tableName) async {
    final db = await database;
    return await db.rawQuery('PRAGMA table_info($tableName)');
  }

  Future<List<DbRow>> getIndexList(String tableName) async {
    final db = await database;
    return await db.rawQuery('PRAGMA index_list($tableName)');
  }

  Future<String> exportSchema() async {
    final db = await database;
    final tables = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    final indexes = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'",
    );

    final schema = StringBuffer()
      ..writeln('-- Database Version: $currentVersion')
      ..writeln('-- Generated: ${DateTime.now().toIso8601String()}\n')
      ..writeln('-- Tables');

    for (var table in tables) {
      schema.writeln('${table['sql']};\n');
    }

    schema.writeln('-- Indexes');
    for (var index in indexes) {
      if (index['sql'] != null) {
        schema.writeln('${index['sql']};\n');
      }
    }
    return schema.toString();
  }
}
