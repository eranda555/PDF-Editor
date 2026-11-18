import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../../core/database/app_database.dart';
import '../../core/security/file_sanitizer.dart';
import '../../core/theme/app_theme.dart';
import '../../services/api_client.dart';
import '../../services/pdf_operations.dart';
import '../../services/recipe_runner.dart';
import 'recipe_editor.dart';

class WorkflowRecipesScreen extends StatefulWidget {
  const WorkflowRecipesScreen({
    super.key,
    required this.database,
    required this.operations,
  });
  final AppDatabase database;
  final PdfOperations operations;
  @override
  State<WorkflowRecipesScreen> createState() => _RecipesState();
}

class _RecipesState extends State<WorkflowRecipesScreen> {
  List<Map<String, dynamic>> recipes = [];
  bool busy = false;
  String status = '';
  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final rows = await widget.database.recipes();
    if (mounted) setState(() => recipes = rows);
  }

  Future<void> create() async {
    final result = await Navigator.push<({String name, List<String> steps})>(
      context,
      MaterialPageRoute(builder: (context) => const RecipeEditor()),
    );
    if (result == null) return;
    await widget.database.saveRecipe(
      const Uuid().v4(),
      result.name,
      result.steps,
    );
    await reload();
  }

  Future<void> run(Map<String, dynamic> recipe) async {
    final steps = (jsonDecode(recipe['steps'] as String) as List)
        .cast<String>();
    ApiClient? api;
    String? input;
    try {
      if (steps.any((step) => step == 'Cloud OCR' || step == 'Export PDF/A')) {
        const endpoint = String.fromEnvironment('PDF_API_URL');
        if (endpoint.isEmpty) {
          throw StateError('Configure the cloud service to run this recipe');
        }
        final consent = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Allow cloud recipe steps?'),
            content: const Text(
              'This recipe uploads the document for OCR or archival conversion. The service reads the document. Cloud copies are deleted after each completed step; outages can delay deletion.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Allow this run'),
              ),
            ],
          ),
        );
        if (consent != true) return;
        api = ApiClient(endpoint);
      }
      if (steps.isEmpty || steps.first != 'Scan document') {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
        if (result == null || result.files.single.path == null) return;
        input = (await FileSanitizer.importFile(
          result.files.single.path!,
        )).path;
      }
      if (!mounted) return;
      setState(() => busy = true);
      final outputs = await RecipeRunner(widget.database, api: api).run(
        steps,
        input,
        (value) {
          if (mounted) setState(() => status = value);
        },
      );
      for (final path in outputs) {
        await widget.database.addDocument(
          const Uuid().v4(),
          '${recipe['name']}.pdf',
          path,
        );
      }
      await SharePlus.instance.share(
        ShareParams(files: outputs.map(XFile.new).toList()),
      );
      if (mounted) setState(() => status = 'Recipe complete');
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'Recipe failed or was cancelled. Check the input, cloud configuration and quota.',
        );
      }
    } finally {
      api?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Workflow recipes')),
    floatingActionButton: FloatingActionButton(
      onPressed: busy ? null : create,
      child: const Icon(Icons.add),
    ),
    body: Column(
      children: [
        const Padding(padding: EdgeInsets.all(16), child: ExecutionBadge()),
        if (busy) const LinearProgressIndicator(),
        if (status.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(status)),
        Expanded(
          child: recipes.isEmpty
              ? const Center(
                  child: Text(
                    'Create a recipe to chain scan, local and cloud steps.',
                  ),
                )
              : ListView.builder(
                  itemCount: recipes.length,
                  itemBuilder: (context, index) {
                    final recipe = recipes[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: const Icon(
                          Icons.auto_awesome,
                          color: AppColors.coral,
                        ),
                        title: Text(recipe['name'] as String),
                        subtitle: Text(
                          (jsonDecode(recipe['steps'] as String) as List).join(
                            ' > ',
                          ),
                        ),
                        onTap: busy ? null : () => run(recipe),
                        trailing: IconButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  await widget.database.deleteRecipe(
                                    recipe['id'] as String,
                                  );
                                  await reload();
                                },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
