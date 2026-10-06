import 'package:archive/archive.dart';

List<int> inflate(List<int> bytes) => GZipDecoder().decodeBytes(bytes);
