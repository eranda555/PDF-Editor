import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppDatabase extends GeneratedDatabase {
  AppDatabase()
    : super(
        LazyDatabase(() async {
          final directory = await getApplicationSupportDirectory();
          return NativeDatabase(
            File(p.join(directory.path, 'pdf-suite.sqlite')),
          );
        }),
      );
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement(
        'CREATE TABLE documents (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, created_at TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL, created_at TEXT NOT NULL, payload TEXT NOT NULL DEFAULT \'{}\')',
      );
      await customStatement(
        'CREATE TABLE workflow_recipes (id TEXT PRIMARY KEY, name TEXT NOT NULL, steps TEXT NOT NULL)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await customStatement(
          "ALTER TABLE jobs ADD COLUMN payload TEXT NOT NULL DEFAULT '{}'",
        );
      }
    },
  );
  Future<void> addDocument(String id, String name, String path) =>
      customStatement('INSERT INTO documents VALUES(?,?,?,?)', [
        id,
        name,
        path,
        DateTime.now().toUtc().toIso8601String(),
      ]);
  Future<List<Map<String, dynamic>>> documents() async => (await customSelect(
    'SELECT * FROM documents ORDER BY created_at DESC',
  ).get()).map((row) => row.data).toList();
  Future<List<Map<String, dynamic>>> recipes() async => (await customSelect(
    'SELECT * FROM workflow_recipes ORDER BY name',
  ).get()).map((row) => row.data).toList();
  Future<void> saveRecipe(String id, String name, List<String> steps) =>
      customStatement('INSERT OR REPLACE INTO workflow_recipes VALUES(?,?,?)', [
        id,
        name,
        jsonEncode(steps),
      ]);
  Future<void> deleteRecipe(String id) =>
      customStatement('DELETE FROM workflow_recipes WHERE id=?', [id]);
  Future<void> trackJob(
    String id,
    String state,
    Map<String, dynamic> payload,
  ) => customStatement('INSERT OR REPLACE INTO jobs VALUES(?,?,?,?)', [
    id,
    state,
    DateTime.now().toUtc().toIso8601String(),
    jsonEncode(payload),
  ]);
  Future<void> updateJob(String id, String state) =>
      customStatement('UPDATE jobs SET state=? WHERE id=?', [state, id]);
  Future<List<Map<String, dynamic>>> jobs() async => (await customSelect(
    'SELECT * FROM jobs ORDER BY created_at DESC',
  ).get()).map((row) => row.data).toList();
}
