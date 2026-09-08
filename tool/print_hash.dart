// Prints the canonical content hash of one entity, for building the shared
// merge fixtures. Usage:
//   dart run tool/print_hash.dart '{"id":"must-work","name":"仕事"}'
import 'dart:convert';
import 'dart:io';

import 'package:frelocator/core/content_hash.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/print_hash.dart <entity-json>');
    exitCode = 64;
    return;
  }
  stdout.writeln(contentHash(jsonDecode(args.first) as Map<String, dynamic>));
}
