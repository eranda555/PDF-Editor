import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class PdfGoWordmark extends StatelessWidget {
  const PdfGoWordmark({super.key});
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleLarge!.copyWith(
      fontWeight: FontWeight.w800,
      color: AppColors.slate,
    );
    return Semantics(
      label: 'PDF Go',
      header: true,
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                style: style,
                children: [
                  const TextSpan(text: 'PDF '),
                  TextSpan(
                    text: 'Go',
                    style: style.copyWith(color: AppColors.red),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Ui.xs),
            const DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.red,
              ),
              child: Padding(
                padding: EdgeInsets.all(3),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 16,
                  color: AppColors.surface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppSearchBar extends StatelessWidget {
  const AppSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hint,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      borderRadius: BorderRadius.all(Radius.circular(32)),
      boxShadow: [Ui.shadow],
    ),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search),
        border: Ui.search,
        enabledBorder: Ui.search,
        focusedBorder: Ui.search.copyWith(
          borderSide: const BorderSide(color: AppColors.slate, width: 2),
        ),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    ),
  );
}

class CategoryFilterBar extends StatelessWidget {
  const CategoryFilterBar({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  final String selected;
  final ValueChanged<String> onChanged;
  static const categories = [
    'All',
    'Workflows',
    'Organize PDF',
    'Optimize PDF',
    'Convert PDF',
    'Edit PDF',
    'PDF Security',
  ];
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final category in categories)
          Padding(
            padding: const EdgeInsets.only(right: Ui.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: Ui.touch,
                minHeight: Ui.touch,
              ),
child: ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(category),
                labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected == category
                      ? AppColors.surface
                      : AppColors.slate,
                ),
                selected: selected == category,
                onSelected: (_) => onChanged(category),
              ),           
            ),
          ),
      ],
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Ui.sm,
    runSpacing: Ui.xs,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      ?trailing,
    ],
  );
}

class DashboardTool {
  const DashboardTool(
    this.title,
    this.description,
    this.icon,
    this.color,
    this.categories,
    this.action, {
    this.cloud = false,
    this.keywords = '',
  });
  final String title, description, keywords;
  final IconData icon;
  final Color color;
  final List<String> categories;
  final VoidCallback action;
  final bool cloud;
  bool matches(String category, String query) =>
      (category == 'All' || categories.contains(category)) &&
      '$title $description $keywords'.toLowerCase().contains(
        query.trim().toLowerCase(),
      );
}

class ToolCard extends StatelessWidget {
  const ToolCard(this.tool, {super.key, this.enabled = true});
  final DashboardTool tool;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: Ui.card,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: Ui.cardRadius,
          onTap: enabled ? tool.action : null,
          child: Padding(
            padding: const EdgeInsets.all(Ui.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tool.color,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(Ui.gutter),
                    ),
                  ),
                  child: SizedBox.square(
                    dimension: 44,
                    child: Icon(tool.icon, color: AppColors.surface),
                  ),
                ),
                const SizedBox(height: Ui.gutter),
                Text(
                  tool.title,
                  style: text.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Ui.xs),
                Text(
                  tool.description,
                  style: text.bodySmall,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Ui.sm),
                ExecutionBadge(cloud: tool.cloud),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Rows take the height of their tallest card, including at large text scales.
class ToolGrid extends StatelessWidget {
  const ToolGrid(this.tools, {super.key, required this.enabled});
  final List<DashboardTool> tools;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < tools.length; i += 2)
        Padding(
          padding: const EdgeInsets.only(bottom: Ui.gutter),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: ToolCard(tools[i], enabled: enabled)),
                const SizedBox(width: Ui.gutter),
                Expanded(
                  child: i + 1 < tools.length
                      ? ToolCard(tools[i + 1], enabled: enabled)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
