import 'package:flutter/material.dart';
import '../../services/recipe_runner.dart';

class RecipeEditor extends StatefulWidget {
  const RecipeEditor({super.key});
  @override
  State<RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends State<RecipeEditor> {
  final name = TextEditingController();
  final steps = <String>[];
  String selected = recipeSteps.first;
  String error = '';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Build recipe')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: name,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Recipe name'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: selected,
                  items: recipeSteps
                      .map(
                        (step) =>
                            DropdownMenuItem(value: step, child: Text(step)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => selected = value!),
                ),
              ),
              IconButton(
                onPressed: steps.length >= 20
                    ? null
                    : () => setState(() => steps.add(selected)),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: steps.length,
            onReorderItem: (old, next) => setState(() {
              steps.insert(next, steps.removeAt(old));
            }),
            itemBuilder: (context, index) => ListTile(
              key: ValueKey(index),
              title: Text('${index + 1}. ${steps[index]}'),
              trailing: IconButton(
                onPressed: () => setState(() => steps.removeAt(index)),
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ),
          ),
        ),
        if (error.isNotEmpty) Text(error),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty ||
                    steps.isEmpty ||
                    (steps.contains('Scan document') &&
                        steps.indexOf('Scan document') != 0) ||
                    (steps.contains('Burst pages') &&
                        steps.indexOf('Burst pages') != steps.length - 1)) {
                  setState(
                    () => error =
                        'Name the recipe, add steps, place Scan first and Burst last.',
                  );
                  return;
                }
                Navigator.pop(context, (
                  name: name.text.trim(),
                  steps: List<String>.of(steps),
                ));
              },
              child: const Text('Save recipe'),
            ),
          ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }
}
