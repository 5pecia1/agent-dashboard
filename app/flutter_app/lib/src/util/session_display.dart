import 'package:my_dashboard/src/util/project_path.dart';

String sessionDisplayName({
  required String? project,
  required String fallback,
  String? displayTitle,
}) {
  final projectText = project != null && project.isNotEmpty
      ? projectBasename(project)
      : fallback;
  final title = displayTitle?.trim();
  return title == null || title.isEmpty || title == projectText
      ? projectText
      : '$projectText · $title';
}
