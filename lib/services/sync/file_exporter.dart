/// Network-free hand-off of the sync document as a `.json` file, picked per
/// platform: the real reader/writer where `dart:io` exists, and a refusing stub
/// on the web, where there is no file system to write to.
library;

export 'file_exporter_stub.dart'
    if (dart.library.io) 'file_exporter_io.dart';
