// Aggregate Dart VM and LCOV coverage, then compare per-file line coverage
// against the checked-in baseline.
//
// This intentionally has no package dependencies so it can run from the repo
// root without a pubspec.
import 'dart:convert';
import 'dart:io';

const _baselineFormat = 1;
const _newFileMinimumPercent = 80.0;
// A file may lose this many covered lines without failing the gate; see the
// regression check below for why a single line is not a reliable signal.
const _lineNoiseAllowance = 1;
const _productionPath = r'^(packages/[^/]+/lib|app/lib)/';

final _packageLibDirs = <String, String>{};

Future<void> main(List<String> args) async {
  var baselinePath = 'coverage_baseline.json';
  var writeBaseline = false;
  var tolerance = 0.05;
  final inputs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--baseline':
        if (++i >= args.length) _usage('missing value for --baseline');
        baselinePath = args[i];
      case '--write':
        writeBaseline = true;
      case '--tolerance':
        if (++i >= args.length) _usage('missing value for --tolerance');
        final value = double.tryParse(args[i]);
        if (value == null || value < 0) {
          _usage('invalid --tolerance value: ${args[i]}');
        }
        tolerance = value;
      default:
        if (arg.startsWith('-')) _usage('unknown option: $arg');
        inputs.add(arg);
    }
  }

  if (inputs.isEmpty) {
    _usage('pass at least one coverage directory or lcov file');
  }

  await _loadPackageConfigs();

  final files = <String, _FileCoverage>{};
  for (final input in inputs) {
    await _collect(input, files);
  }
  if (files.isEmpty) {
    stderr.writeln('No production coverage found in: ${inputs.join(', ')}');
    exitCode = 1;
    return;
  }

  final totalCovered = files.values.fold<int>(
    0,
    (sum, file) => sum + file.covered,
  );
  final totalLines = files.values.fold<int>(0, (sum, file) => sum + file.total);
  _printSummary(files, totalCovered, totalLines);

  if (writeBaseline) {
    final data = <String, Object?>{
      'format': _baselineFormat,
      'files': <String, Object?>{
        for (final entry in _sortedEntries(files))
          entry.key: <String, Object?>{
            'covered': entry.value.covered,
            'total': entry.value.total,
          },
      },
    };
    await File(baselinePath)
        .writeAsString('${const JsonEncoder.withIndent('  ').convert(data)}\n');
    stdout.writeln('Wrote baseline to $baselinePath');
    return;
  }

  final baselineFile = File(baselinePath);
  if (!await baselineFile.exists()) {
    stderr.writeln(
      'Coverage baseline not found at $baselinePath; '
      'run scripts/coverage.sh --write-baseline',
    );
    exitCode = 1;
    return;
  }
  final decoded = jsonDecode(await baselineFile.readAsString());
  if (decoded is! Map || decoded['format'] != _baselineFormat) {
    stderr.writeln('Unsupported coverage baseline format: $baselinePath');
    exitCode = 1;
    return;
  }
  final rawFiles = decoded['files'];
  if (rawFiles is! Map) {
    stderr.writeln('Coverage baseline has no files map: $baselinePath');
    exitCode = 1;
    return;
  }
  final baseline = <String, _FileCoverage>{};
  for (final entry in rawFiles.entries) {
    final value = entry.value;
    if (value is! Map) continue;
    final covered = value['covered'];
    final fileTotal = value['total'];
    if (covered is! int || fileTotal is! int || fileTotal <= 0) continue;
    final file = _FileCoverage();
    file.setTotals(covered: covered, total: fileTotal);
    baseline[entry.key as String] = file;
  }

  final regressions = <String>[];
  final missing = <String>[];
  final newTooLow = <String>[];

  for (final entry in _sortedEntries(baseline)) {
    final current = files[entry.key];
    if (current == null) {
      if (await File(entry.key).exists()) missing.add(entry.key);
      continue;
    }
    final before = entry.value.percent;
    final after = current.percent;
    // One line's hit count is not stable between runs: the VM attributes
    // compiler-generated positions (a `const` constructor, for example) to a
    // source line, and whether that line registers a hit depends on how the
    // constant was materialized. A file may therefore lose one covered line
    // without failing the gate. Growth is still held to the baseline: a source
    // change that adds an uncovered line has to stay above the old percentage.
    final lostLines = entry.value.covered - current.covered;
    final gainedLines = current.total - entry.value.total;
    final percentRegressed = after + tolerance < before;
    if (lostLines > _lineNoiseAllowance ||
        (gainedLines > 0 && percentRegressed)) {
      final uncovered =
          current._lines.entries
              .where((entry) => entry.value == 0)
              .map((entry) => entry.key)
              .toList()
            ..sort();
      final detail = uncovered.isEmpty
          ? ''
          : ' (uncovered lines: ${uncovered.join(', ')})';
      regressions.add(
        '${entry.key}: '
        '${_percent(before)}% -> ${_percent(after)}%$detail',
      );
    }
  }

  for (final entry in _sortedEntries(files)) {
    if (baseline.containsKey(entry.key)) continue;
    if (entry.value.percent + tolerance < _newFileMinimumPercent) {
      newTooLow.add('${entry.key}: ${_percent(entry.value.percent)}%');
    }
  }

  if (regressions.isEmpty && missing.isEmpty && newTooLow.isEmpty) {
    stdout.writeln(
      'Coverage matches the baseline '
      '(${_percent(_percentOf(totalCovered, totalLines))}% overall).',
    );
    return;
  }

  if (regressions.isNotEmpty) {
    stderr.writeln('Coverage regressions:');
    for (final line in regressions) {
      stderr.writeln('  - $line');
    }
  }
  if (missing.isNotEmpty) {
    stderr.writeln('Baseline files with no current coverage:');
    for (final line in missing) {
      stderr.writeln('  - $line');
    }
  }
  if (newTooLow.isNotEmpty) {
    stderr.writeln(
      'New files below ${_percent(_newFileMinimumPercent)}% coverage:',
    );
    for (final line in newTooLow) {
      stderr.writeln('  - $line');
    }
  }
  exitCode = 1;
}

Future<void> _collect(String input, Map<String, _FileCoverage> files) async {
  final type = FileSystemEntity.typeSync(input);
  if (type == FileSystemEntityType.directory) {
    await for (final entity in Directory(input).list(recursive: true)) {
      if (entity is! File) continue;
      await _collectFile(entity, files);
    }
    return;
  }
  if (type == FileSystemEntityType.file) {
    await _collectFile(File(input), files);
    return;
  }
  stderr.writeln('Coverage input not found: $input');
  exitCode = 1;
}

Future<void> _collectFile(File file, Map<String, _FileCoverage> files) async {
  if (file.path.endsWith('.vm.json')) {
    _mergeVmJson(await file.readAsString(), files);
  } else if (file.path.endsWith('.info')) {
    _mergeLcov(await file.readAsString(), files, baseDir: _lcovBaseDir(file));
  }
}

Directory _lcovBaseDir(File file) {
  final parent = file.parent;
  final segments = parent.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isNotEmpty && segments.last == 'coverage') {
    return parent.parent;
  }
  return parent;
}

void _mergeVmJson(String raw, Map<String, _FileCoverage> files) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map || decoded['coverage'] is! List) return;
  for (final rawEntry in decoded['coverage'] as List) {
    if (rawEntry is! Map) continue;
    final source = rawEntry['source'];
    final hits = rawEntry['hits'];
    if (source is! String || hits is! List) continue;
    final path = _productionPathFor(source);
    if (path == null) continue;
    final file = files.putIfAbsent(path, _FileCoverage.new);
    for (var i = 0; i + 1 < hits.length; i += 2) {
      final line = hits[i];
      final count = hits[i + 1];
      if (line is! int || count is! int) continue;
      file.mergeLine(line, count);
    }
  }
}

void _mergeLcov(
  String raw,
  Map<String, _FileCoverage> files, {
  required Directory baseDir,
}) {
  String? currentPath;
  for (final line in const LineSplitter().convert(raw)) {
    if (line.startsWith('SF:')) {
      currentPath = _productionPathFor(
        line.substring(3).trim(),
        baseDir: baseDir,
      );
      continue;
    }
    final path = currentPath;
    if (path == null) continue;
    if (line.startsWith('DA:')) {
      final parts = line.substring(3).split(',');
      if (parts.length < 2) continue;
      final lineNo = int.tryParse(parts[0]);
      final count = int.tryParse(parts[1]);
      if (lineNo == null || count == null) continue;
      files.putIfAbsent(path, _FileCoverage.new).mergeLine(lineNo, count);
    } else if (line == 'end_of_record') {
      currentPath = null;
    }
  }
}

Future<void> _loadPackageConfigs() async {
  final configs = <File>[];
  final appConfig = File('app/.dart_tool/package_config.json');
  if (await appConfig.exists()) configs.add(appConfig);
  final packages = Directory('packages');
  if (await packages.exists()) {
    await for (final entity in packages.list()) {
      if (entity is! Directory) continue;
      final config = File('${entity.path}/.dart_tool/package_config.json');
      if (await config.exists()) configs.add(config);
    }
  }

  for (final config in configs) {
    final decoded = jsonDecode(await config.readAsString());
    if (decoded is! Map || decoded['packages'] is! List) continue;
    final base = config.absolute.uri;
    for (final raw in decoded['packages'] as List) {
      if (raw is! Map) continue;
      final name = raw['name'];
      final rootUri = raw['rootUri'];
      if (name is! String || rootUri is! String) continue;
      final packageUri = raw['packageUri'];
      final resolved = base.resolve(rootUri);
      final root = resolved.path.endsWith('/')
          ? resolved
          : resolved.replace(path: '${resolved.path}/');
      final lib = root.resolve(packageUri is String ? packageUri : 'lib/');
      var libPath = Directory.fromUri(lib).absolute.path;
      while (libPath.endsWith('/') || libPath.endsWith('\\')) {
        libPath = libPath.substring(0, libPath.length - 1);
      }
      _packageLibDirs[name] = libPath;
    }
  }
}

String? _productionPathFor(String source, {Directory? baseDir}) {
  String path;
  if (source.startsWith('package:')) {
    final uri = Uri.parse(source);
    if (uri.pathSegments.isEmpty) return null;
    final lib = _packageLibDirs[uri.pathSegments.first];
    if (lib == null) return null;
    path = '$lib/${uri.pathSegments.skip(1).join('/')}';
  } else if (source.startsWith('file://')) {
    try {
      path = Uri.parse(source).toFilePath();
    } on FormatException {
      return null;
    }
  } else if (source.startsWith('/')) {
    path = source;
  } else if (baseDir != null) {
    // LCOV paths from `flutter test --coverage` are relative to the package
    // root, e.g. `lib/services/identity_store.dart`.
    final base = baseDir.path;
    final separator = base.endsWith(Platform.pathSeparator)
        ? ''
        : Platform.pathSeparator;
    path = '$base$separator$source';
  } else {
    return null;
  }
  final root = Directory.current.absolute.path;
  final absolute = File(path).absolute.path;
  if (!absolute.startsWith('$root/')) return null;
  final relative = absolute.substring(root.length + 1).replaceAll('\\', '/');
  if (!RegExp(_productionPath).hasMatch(relative)) return null;
  return relative;
}

List<MapEntry<String, _FileCoverage>> _sortedEntries(
  Map<String, _FileCoverage> files,
) {
  final entries = files.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries;
}

void _printSummary(
  Map<String, _FileCoverage> files,
  int totalCovered,
  int totalLines,
) {
  stdout.writeln(
    'Covered $totalCovered/$totalLines lines '
    '(${_percent(_percentOf(totalCovered, totalLines))}%) '
    'across ${files.length} files.',
  );
}

double _percentOf(int covered, int total) =>
    total == 0 ? 0 : covered * 100 / total;

String _percent(double value) => value.toStringAsFixed(2);

Never _usage(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage: dart tool/coverage.dart [--write] '
    '[--baseline <file>] [--tolerance <points>] <coverage inputs...>',
  );
  exit(64);
}

class _FileCoverage {
  final Map<int, int> _lines = {};
  int? _baselineCovered;
  int? _baselineTotal;

  int get covered =>
      _baselineCovered ?? _lines.values.where((count) => count > 0).length;

  int get total => _baselineTotal ?? _lines.length;

  double get percent => total == 0 ? 0 : covered * 100 / total;

  void mergeLine(int line, int count) {
    final previous = _lines[line];
    if (previous == null || count > previous) _lines[line] = count;
  }

  void setTotals({required int covered, required int total}) {
    _baselineCovered = covered;
    _baselineTotal = total;
  }
}
