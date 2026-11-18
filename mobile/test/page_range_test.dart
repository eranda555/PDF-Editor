import 'dart:io';
import 'package:hundred_percent_pdf/services/page_range.dart';

void expectPages(String input, int count, List<int> expected) {
  final actual = parsePageRange(input, count);
  if (actual.toString() != expected.toString()) {
    throw StateError('$input produced $actual; expected $expected');
  }
}

void main() {
  expectPages('1-3,5,8-end', 10, [0, 1, 2, 4, 7, 8, 9]);
  expectPages('end-2', 4, [3, 2, 1]);
  expectPages('1,1,2', 2, [0, 0, 1]);
  expectPages(' 1 - 2 , END ', 3, [0, 1, 2]);
  for (final invalid in ['', '0', '21', '../1', '1--3', '1,', '1-z']) {
    var rejected = false;
    try {
      parsePageRange(invalid, 20);
    } on FormatException {
      rejected = true;
    }
    if (!rejected) throw StateError('Accepted invalid range: $invalid');
  }
  stdout.writeln('Passed 11 page-range regression cases.');
}
