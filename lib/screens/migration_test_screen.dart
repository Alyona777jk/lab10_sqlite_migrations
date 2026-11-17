import 'package:flutter/material.dart';
import '../database/database_migration_helper.dart';

class MigrationTestScreen extends StatefulWidget {
  const MigrationTestScreen({super.key});

  @override
  State<MigrationTestScreen> createState() => _MigrationTestScreenState();
}

class _MigrationTestScreenState extends State<MigrationTestScreen> {
  final _dbHelper = DatabaseMigrationHelper.instance;

  int? _currentVersion;
  int _selectedStartVersion = 1;
  String _schema = '';
  List<DbRow> _usersTableInfo = [];
  List<DbRow> _indexes = [];
  DbRow? _lastVerificationResult;
  final List<String> _logs = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _dbHelper.onLog = (msg) {
      if (mounted) {
        setState(() {
          _logs.insert(0, msg);
        });
      }
    };
    _loadDatabaseInfo();
  }

  Future<void> _loadDatabaseInfo() async {
    setState(() => _isLoading = true);
    try {
      final version = await _dbHelper.getDatabaseVersion();
      final schema = await _dbHelper.exportSchema();
      final tableInfo = await _dbHelper.getTableInfo('users');
      final userIndexes = await _dbHelper.getIndexList('users');
      final prefIndexes = await _dbHelper.getIndexList('preferences');

      setState(() {
        _currentVersion = version;
        _schema = schema;
        _usersTableInfo = tableInfo;
        _indexes = [...userIndexes, ...prefIndexes];
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('Помилка завантаження БД: $e', isError: true);
    }
  }

  Future<void> _runMigrationTest() async {
    try {
      final result = await _dbHelper.runFullMigrationTest(
        startVersion: _selectedStartVersion,
      );
      setState(() {
        _lastVerificationResult = result;
      });
      _showSnack('Міграція v$_selectedStartVersion -> v4 успішна!');
    } catch (e) {
      _showSnack('Помилка міграції: $e', isError: true);
    }
  }

  Future<void> _runRollbackTest() async {
    try {
      await _dbHelper.testRollbackOnFailure();
      _showSnack('Тест Rollback при помилці пройдено!');
    } catch (e) {
      _showSnack('Помилка тесту Rollback: $e', isError: true);
    }
  }

  void _showSnack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SQLite Міграції (Варіант 1)'),
        actions: [
          IconButton(
            tooltip: 'Очистити логи',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: Colors.blue.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.storage, color: Colors.blue, size: 32),
                    title: const Text('Активна база даних', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Поточна версія схеми: v$_currentVersion'),
                  ),
                ),
                const SizedBox(height: 16),

                const Text('Тестування міграцій та Rollback:',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Початкова версія: '),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _selectedStartVersion,
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('Версія 1 (users)')),
                        DropdownMenuItem(value: 2, child: Text('Версія 2 (+phone)')),
                        DropdownMenuItem(value: 3, child: Text('Версія 3 (+preferences)')),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedStartVersion = val);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _runMigrationTest,
                        icon: const Icon(Icons.upgrade),
                        label: Text('Мігрувати v$_selectedStartVersion → v4'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _runRollbackTest,
                        icon: const Icon(Icons.undo, color: Colors.orange),
                        label: const Text('Тест Rollback'),
                      ),
                    ),
                  ],
                ),

                if (_lastVerificationResult != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: Colors.green.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Перевірка даних після міграції v${_lastVerificationResult!['startVersion']} → v${_lastVerificationResult!['endVersion']}:',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                          ),
                          const SizedBox(height: 4),
                          Text('User: ${_lastVerificationResult!['user']}'),
                          Text('Preferences: ${_lastVerificationResult!['preferences']}'),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                const Text('Логи процесу міграції:',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  height: 180,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _logs.isEmpty
                      ? const Center(
                          child: Text('Натисніть кнопку міграції для запуску...',
                              style: TextStyle(color: Colors.white54)),
                        )
                      : ListView.builder(
                          itemCount: _logs.length,
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              _logs[index],
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                ),

                const SizedBox(height: 16),
                const Text('Структура таблиці users:',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ..._usersTableInfo.map(
                  (col) => Card(
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.table_rows),
                      title: Text('${col['name'] ?? ''}'),
                      subtitle: Text('${col['type']} ${col['notnull'] == 1 ? 'NOT NULL' : ''}'),
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                const Text('Активні індекси:',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ..._indexes.map(
                  (idx) => Card(
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.speed, color: Colors.deepPurple),
                      title: Text('${idx['name'] ?? ''}'),
                      subtitle: Text('Unique: ${idx['unique'] == 1}'),
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                const Text('Експортована схема БД (SQL):',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _schema,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadDatabaseInfo,
        tooltip: 'Оновити інформацію про БД',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
