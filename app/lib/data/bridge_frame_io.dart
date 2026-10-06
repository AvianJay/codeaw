import 'dart:io';

List<int> inflate(List<int> bytes) => gzip.decode(bytes);
