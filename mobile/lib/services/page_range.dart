List<int> parsePageRange(String value, int pageCount) {
  if (pageCount < 1) throw const FormatException('Document has no pages');
  final result = <int>[];
  for (final token in value.toLowerCase().replaceAll(' ', '').split(',')) {
    final match = RegExp(r'^(\d+|end)(?:-(\d+|end))?$').firstMatch(token);
    if (match == null) {
      throw const FormatException('Use ranges such as 1-3,5,8-end');
    }
    int number(String text) => text == 'end' ? pageCount : int.parse(text);
    final first = number(match[1]!);
    final last = match[2] == null ? first : number(match[2]!);
    if (first < 1 || first > pageCount || last < 1 || last > pageCount) {
      throw const FormatException('Page is outside this document');
    }
    for (
      var page = first;
      first <= last ? page <= last : page >= last;
      page += first <= last ? 1 : -1
    ) {
      result.add(page - 1);
      if (result.length > 10000) {
        throw const FormatException('At most 10,000 selected pages');
      }
    }
  }
  return result;
}
