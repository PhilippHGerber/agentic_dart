/// The Wire Trace subsystem: a human-readable, chronological file log of every
/// message crossing the server's two boundaries.
///
/// This library owns the trace *file* only — the per-session sink, the session
/// header, correlation-id allocation, body-preview truncation, and retention.
/// Wiring it into the server (the central dispatch wrapper and the pub.dev
/// client) lives elsewhere; a [WireTrace] is fully usable and testable on its
/// own against a directory.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Number of `═` characters in the session-header rules.
const int _kHeaderBarWidth = 72;

/// The [Zone] key under which the central LLM-boundary wrapper stores the
/// active request's Correlation Id.
///
/// The wrapper enters a [Zone] carrying this value around the entire async tool
/// call or resource read, so code deeper in the stack — notably the long-lived
/// `PubDevClient` singleton — can read the current id from [Zone.current] at
/// call time without any change to method signatures. See [currentCorrelationId].
const Object wireTraceZoneIdKey = #pubdevContextWireTraceCorrelationId;

/// Returns the Correlation Id of the LLM request currently on the stack, or
/// `null` when no traced request is in flight.
///
/// Reads the value the central wrapper placed on the [Zone] (see
/// [wireTraceZoneIdKey]). Returns `null` outside a traced request — for example
/// when tracing is disabled and no wrapper/Zone was installed.
String? currentCorrelationId() =>
    Zone.current[wireTraceZoneIdKey] as String?;

/// Column at which continuation lines (`args:`, `body:`, `error:`) begin,
/// chosen to sit just past the boundary/marker area of a primary line.
///
/// The width (23) is tuned to the primary-line prefix — `_formatClock` (12
/// chars) + two spaces + a 4-char id (`#001`) + two spaces — so continuations
/// align under the boundary content. If the clock format or id width changes,
/// re-tune this constant to match; alignment is cosmetic and will not break
/// correctness.
const String _kContinuationIndent = '                       '; // 23 spaces.

/// Number of session files kept by retention; older files are pruned.
const int kWireTraceRetentionCount = 10;

/// A destination for individual wire-trace lines.
///
/// Production uses a file-backed sink that appends and flushes per line so that
/// `tail -f` is live and the last line before a crash survives. The interface
/// is exposed so tests can inject a fake — for example one that throws — to
/// exercise the best-effort failure paths without real I/O.
abstract interface class WireTraceSink {
  /// Writes [line] followed by a newline and flushes it to durable storage.
  ///
  /// May throw; [WireTrace] treats any throw as a mid-session write failure and
  /// silently disables further tracing.
  void writeLine(String line);

  /// Releases the underlying resource. Best-effort; must not throw.
  void close();
}

/// A [WireTraceSink] backed by an appended, per-line-flushed file.
final class _FileWireTraceSink implements WireTraceSink {
  _FileWireTraceSink(this._file);

  final RandomAccessFile _file;

  @override
  void writeLine(String line) {
    _file
      ..writeStringSync('$line\n')
      ..flushSync();
  }

  @override
  void close() {
    try {
      _file.closeSync();
    } on FileSystemException {
      // Best-effort close.
    }
  }
}

/// A [WireTraceSink] that discards everything, used when tracing is disabled.
final class _NullWireTraceSink implements WireTraceSink {
  const _NullWireTraceSink();

  @override
  void writeLine(String line) {}

  @override
  void close() {}
}

/// Owns one session's human-readable Wire Trace file.
///
/// Construct with [WireTrace.open] against a directory: it creates the
/// directory if needed, opens a per-session file named by timestamp and pid,
/// writes the session-header block, and prunes old session files to the last
/// [kWireTraceRetentionCount].
///
/// Every `log*` method formats one event from the authoritative trace format
/// and writes it immediately (flushed per line). All writes are strictly
/// best-effort: a failure to open the directory yields exactly one stderr
/// warning and a disabled instance; a mid-session write failure silently
/// disables tracing. A tracing failure never propagates to the caller.
final class WireTrace {
  WireTrace._({
    required WireTraceSink sink,
    required DateTime Function() clock,
    required int maxPreviewBytes,
    required bool enabled,
  }) : _sink = sink,
       _clock = clock,
       _maxPreviewBytes = maxPreviewBytes,
       _enabled = enabled;

  /// Opens a Wire Trace session in [directoryPath].
  ///
  /// Writes the session header recording [serverVersion], [pid] (defaults to
  /// the current process id), the session start ([clock] defaults to
  /// [DateTime.now]), and the effective config ([maxPreviewBytes],
  /// [concurrency], [cacheDir]).
  ///
  /// If the directory cannot be created or the file cannot be opened, calls
  /// [onWarning] (defaulting to a single line on stderr) exactly once and
  /// returns a disabled instance whose methods are no-ops. This constructor
  /// never throws.
  factory WireTrace.open({
    required String directoryPath,
    required String serverVersion,
    required int maxPreviewBytes,
    required int concurrency,
    required String cacheDir,
    int? pid,
    DateTime Function()? clock,
    int retentionCount = kWireTraceRetentionCount,
    void Function(String message)? onWarning,
  }) {
    final effectiveClock = clock ?? DateTime.now;
    final effectivePid = pid ?? _currentPid;
    final warn = onWarning ?? (String message) => stderr.writeln(message);
    final start = effectiveClock();

    final WireTraceSink sink;
    try {
      Directory(directoryPath).createSync(recursive: true);
      final file = File(_joinPath(directoryPath, _sessionFileName(start, effectivePid)));
      sink = _FileWireTraceSink(file.openSync(mode: FileMode.writeOnly));
    } on FileSystemException {
      warn(
        '[pubdev_context] Wire Trace disabled: cannot write to "$directoryPath".',
      );
      return WireTrace._(
        sink: const _NullWireTraceSink(),
        clock: effectiveClock,
        maxPreviewBytes: maxPreviewBytes,
        enabled: false,
      );
    }

    final trace = WireTrace._(
      sink: sink,
      clock: effectiveClock,
      maxPreviewBytes: maxPreviewBytes,
      enabled: true,
    ).._writeHeader(
      serverVersion: serverVersion,
      pid: effectivePid,
      start: start,
      concurrency: concurrency,
      cacheDir: cacheDir,
    );
    _pruneOldSessions(directoryPath, retentionCount);
    return trace;
  }

  /// Creates a [WireTrace] writing through an injected [sink].
  ///
  /// Exposed for tests: it bypasses directory/file handling so a fake sink can
  /// drive formatting and failure-path assertions. Writes the session header
  /// through [sink] on construction.
  factory WireTrace.withSink(
    WireTraceSink sink, {
    required String serverVersion,
    required int maxPreviewBytes,
    required int concurrency,
    required String cacheDir,
    int pid = 0,
    DateTime Function()? clock,
  }) {
    final effectiveClock = clock ?? DateTime.now;
    return WireTrace._(
      sink: sink,
      clock: effectiveClock,
      maxPreviewBytes: maxPreviewBytes,
      enabled: true,
    ).._writeHeader(
      serverVersion: serverVersion,
      pid: pid,
      start: effectiveClock(),
      concurrency: concurrency,
      cacheDir: cacheDir,
    );
  }

  final WireTraceSink _sink;
  final DateTime Function() _clock;
  final int _maxPreviewBytes;

  bool _enabled;
  int _correlationCounter = 0;
  bool _inboundCallWritten = false;

  /// Whether tracing is currently active. Becomes `false` after an open failure
  /// or a mid-session write failure, after which every method is a no-op.
  bool get isEnabled => _enabled;

  /// The configured body-preview cap in bytes (`0` means metadata-only).
  int get maxPreviewBytes => _maxPreviewBytes;

  /// Allocates the next per-session Correlation Id (`#001`, `#002`, …).
  ///
  /// The counter is monotonic and never repeats within a session. Ids remain
  /// short and zero-padded to three digits; sessions with more than 999
  /// requests widen naturally (`#1000`).
  String nextCorrelationId() {
    _correlationCounter++;
    return '#${_correlationCounter.toString().padLeft(3, '0')}';
  }

  /// Builds the body-preview text for a continuation line using this session's
  /// [maxPreviewBytes], or `null` when no body should be shown.
  ///
  /// See [formatBodyPreview] for the rules.
  String? bodyPreview(String text, {bool isTarball = false}) =>
      formatBodyPreview(text, maxPreviewBytes: _maxPreviewBytes, isTarball: isTarball);

  /// Logs an inbound LLM-boundary call: `← LLM  {method}  {name}`.
  ///
  /// A blank line is written immediately before the primary line so each
  /// top-level LLM request visually separates from the last — including when it
  /// lands inside another still-open request's interleaved pub.dev lines. The
  /// very first inbound call of a session is the exception: it follows the
  /// header's own trailing blank line, so no extra one is written.
  ///
  /// When [argsJson] is non-null an `args:` continuation line carrying it is
  /// written beneath the primary line. Pass `null` to omit it — for a resource
  /// read the [name] already carries the full request (the URI), so there are
  /// no separate arguments to show.
  void logInboundCall({
    required String id,
    required String method,
    required String name,
    String? argsJson,
  }) {
    if (!_enabled) return;
    if (_inboundCallWritten) _write('');
    _inboundCallWritten = true;
    _write('${_prefix(id)}  ← LLM   $method  $name');
    if (argsJson != null) {
      _writeContinuation('args', argsJson);
    }
  }

  /// Logs an outbound pub.dev request: `→ pub  {httpMethod} {path}` with an
  /// optional `[{context}]` tag (for example `cache miss` or `retry 1`).
  void logRequest({
    required String id,
    required String httpMethod,
    required String path,
    String? context,
  }) {
    if (!_enabled) return;
    final tag = context == null ? '' : '  [$context]';
    _write('${_prefix(id)}    → pub  $httpMethod $path$tag');
  }

  /// Logs an inbound pub.dev response: `← pub  {status} {path}` with a
  /// `({latency} ms[, {size} {contentType}])` trailer, and an optional `body:`
  /// continuation line carrying [preview].
  ///
  /// For an HTML endpoint whose body is logged as converted markdown, pass the
  /// raw HTML size as [sizeBytes] and the markdown size as [markdownSizeBytes];
  /// the trailer then renders `{html} HTML → {md} md` and [preview] should carry
  /// the markdown (never the raw HTML). For a tarball download pass [fileCount]
  /// so the trailer records the extracted file count as metadata; a tarball
  /// carries no [preview] (its content is never dumped).
  void logResponse({
    required String id,
    required int status,
    required String path,
    required Duration latency,
    int? sizeBytes,
    String? contentType,
    int? markdownSizeBytes,
    int? fileCount,
    String? preview,
  }) {
    if (!_enabled) return;
    _write('${_prefix(id)}    ← pub  $status $path  '
        '(${_metrics(
          latency: latency,
          sizeBytes: sizeBytes,
          contentType: contentType,
          markdownSizeBytes: markdownSizeBytes,
          fileCount: fileCount,
        )})');
    if (preview != null) {
      _writeContinuation('body', preview);
    }
  }

  /// Logs a transient pub.dev failure and its backoff:
  /// `⚠ pub  {status} {path}  ({latency} ms) — retry {attempt}/{maxAttempts} in
  /// {backoff} ms`.
  void logRetry({
    required String id,
    required int status,
    required String path,
    required Duration latency,
    required int attempt,
    required int maxAttempts,
    required Duration backoff,
  }) {
    if (!_enabled) return;
    _write('${_prefix(id)}    ⚠ pub  $status $path  '
        '(${latency.inMilliseconds} ms) — '
        'retry $attempt/$maxAttempts in ${backoff.inMilliseconds} ms');
  }

  /// Logs a cache hit that avoided a pub.dev call:
  /// `⚡ cache hit  {key}   (age {age}, no pub.dev call)`.
  void logCacheHit({
    required String id,
    required String key,
    required Duration age,
  }) {
    if (!_enabled) return;
    _write('${_prefix(id)}    ⚡ cache hit  $key   '
        '(age ${_formatAge(age)}, no pub.dev call)');
  }

  /// Logs an outbound LLM-boundary result: `→ LLM  result  {name}  {status}`.
  ///
  /// When [isError] is `true` the status renders as `ERROR {errorCode}` and the
  /// continuation line is `error: {errorPreview}`; otherwise the status is `ok`
  /// and the continuation line is `body: {bodyPreview}`. The trailer composes
  /// the optional [summary] (for example `5 results`), the [duration], and the
  /// optional [sizeBytes].
  void logResult({
    required String id,
    required String name,
    required Duration duration,
    required bool isError,
    String? errorCode,
    String? summary,
    int? sizeBytes,
    String? bodyPreview,
    String? errorPreview,
  }) {
    if (!_enabled) return;
    if (isError) {
      _write('${_prefix(id)}  → LLM   result  $name   '
          'ERROR ${errorCode ?? 'UNKNOWN'}  (${duration.inMilliseconds} ms)');
      if (errorPreview != null) {
        _writeContinuation('error', errorPreview);
      }
    } else {
      _write('${_prefix(id)}  → LLM   result  $name   ok   '
          '(${_resultMetrics(summary, duration, sizeBytes)})');
      if (bodyPreview != null) {
        _writeContinuation('body', bodyPreview);
      }
    }
  }

  /// Closes the underlying sink. Best-effort; never throws.
  void close() {
    _sink.close();
    _enabled = false;
  }

  void _writeHeader({
    required String serverVersion,
    required int pid,
    required DateTime start,
    required int concurrency,
    required String cacheDir,
  }) {
    final bar = '═' * _kHeaderBarWidth;
    _write(bar);
    _write(' Wire Trace — pubdev_context $serverVersion');
    _write(' session started ${_formatTimestampDate(start)}   pid $pid');
    _write(' config: max-preview=${maxPreviewBytes}B  '
        'concurrency=$concurrency  cache=$cacheDir');
    _write(bar);
    _write('');
  }

  String _prefix(String id) => '${_formatClock(_clock())}  $id';

  static String _metrics({
    required Duration latency,
    required int? sizeBytes,
    required String? contentType,
    required int? markdownSizeBytes,
    required int? fileCount,
  }) {
    final buffer = StringBuffer('${latency.inMilliseconds} ms');
    if (sizeBytes != null) {
      buffer.write(', ${humanBytes(sizeBytes)}');
      if (markdownSizeBytes != null) {
        // HTML endpoint: annotate both the raw HTML size and the converted
        // markdown size so the operator sees the conversion, never raw HTML.
        buffer.write(' HTML → ${humanBytes(markdownSizeBytes)} md');
      } else if (contentType != null) {
        buffer.write(' $contentType');
      }
      if (fileCount != null) {
        buffer.write(', $fileCount file${fileCount == 1 ? '' : 's'}');
      }
    }
    return buffer.toString();
  }

  static String _resultMetrics(String? summary, Duration duration, int? sizeBytes) {
    final parts = <String>[
      ?summary,
      '${duration.inMilliseconds} ms',
      if (sizeBytes != null) humanBytes(sizeBytes),
    ];
    return parts.join(', ');
  }

  void _write(String line) {
    if (!_enabled) return;
    try {
      _sink.writeLine(line);
    } on Object {
      // Mid-session write failure: drop tracing silently and keep functioning
      // as a no-op. A tracing failure must never surface to a caller.
      _enabled = false;
      _sink.close();
    }
  }

  /// Writes a `{label}: {value}` continuation line at the standard indent.
  void _writeContinuation(String label, String value) =>
      _write('$_kContinuationIndent$label: $value');

  /// Prunes session files in [directoryPath] to the newest [retentionCount].
  ///
  /// Best-effort: any I/O error is swallowed so retention can never disturb a
  /// live session.
  static void _pruneOldSessions(String directoryPath, int retentionCount) {
    if (retentionCount < 1) return;
    try {
      final files = <File>[];
      for (final entity in Directory(directoryPath).listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (name.startsWith('wire-trace-') && name.endsWith('.log')) {
          files.add(entity);
        }
      }
      if (files.length <= retentionCount) return;

      // Filenames embed a fixed-width timestamp, so a lexicographic sort is
      // chronological. Delete the oldest beyond the retention window.
      files.sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));
      for (final file in files.take(files.length - retentionCount)) {
        try {
          file.deleteSync();
        } on FileSystemException {
          // Best-effort prune.
        }
      }
    } on FileSystemException {
      // Best-effort prune.
    }
  }

  static String _sessionFileName(DateTime t, int pid) {
    final date = '${t.year.toString().padLeft(4, '0')}'
        '${_two(t.month)}${_two(t.day)}';
    final time = '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
    return 'wire-trace-$date-$time-${_three(t.millisecond)}-pid$pid.log';
  }

  static String _formatClock(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${_three(t.millisecond)}';

  static String _formatTimestampDate(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)} '
      '${_formatClock(t)}';

  static String _formatAge(Duration age) {
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    return '${age.inHours}h';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _three(int value) => value.toString().padLeft(3, '0');

  static int get _currentPid => pid;

  static String _joinPath(String base, String child) {
    final separator = Platform.pathSeparator;
    if (base.endsWith(separator)) return '$base$child';
    return '$base$separator$child';
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index < 0 ? path : path.substring(index + 1);
  }
}

/// Builds the body-preview text for a trace continuation line, or `null` when
/// no body should be shown.
///
/// - A tarball payload ([isTarball]) is never previewed — metadata only —
///   regardless of the cap.
/// - A [maxPreviewBytes] of `0` (or less) suppresses all bodies.
/// - Text whose UTF-8 size is at or under the cap is returned whole, collapsed
///   to a single line.
/// - Larger text is truncated to the cap and annotated with `…  (truncated,
///   {size} total)` carrying the true total size.
String? formatBodyPreview(
  String text, {
  required int maxPreviewBytes,
  bool isTarball = false,
}) {
  if (isTarball || maxPreviewBytes <= 0) return null;

  final totalBytes = utf8.encode(text).length;
  final oneLine = text
      .replaceAll('\r\n', ' ')
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ');

  if (totalBytes <= maxPreviewBytes) return oneLine;

  final head = _truncateToBytes(oneLine, maxPreviewBytes);
  return '$head…  (truncated, ${humanBytes(totalBytes)} total)';
}

/// Formats [bytes] as a compact human-readable size (`940 B`, `4.1 KB`,
/// `2.3 MB`) using binary (1024) steps.
String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// Returns the longest prefix of [text] whose UTF-8 encoding does not exceed
/// [maxBytes], never splitting a multi-byte code point.
String _truncateToBytes(String text, int maxBytes) {
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final encoded = utf8.encode(String.fromCharCode(rune)).length;
    if (used + encoded > maxBytes) break;
    buffer.writeCharCode(rune);
    used += encoded;
  }
  return buffer.toString();
}
