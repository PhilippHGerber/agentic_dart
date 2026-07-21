/// Pure line-range slicing shared by every tool handler that extracts an
/// exact line range from a file's content — `get_source_slice`'s line-range
/// mode and `get_sdk_source_slice`'s line-range mode.
library;

import 'package:analyzer/source/line_info.dart';

/// The result of slicing a file's content to an inclusive 1-based line range.
final class LineRangeSlice {
  /// Creates a [LineRangeSlice].
  const LineRangeSlice({
    required this.lineStart,
    required this.effectiveLineEnd,
    required this.content,
  });

  /// 1-based inclusive first line of the returned region.
  final int lineStart;

  /// 1-based inclusive last line of the returned region.
  final int effectiveLineEnd;

  /// The sliced source text, with the single trailing line terminator that
  /// separates the last requested line from the following line stripped.
  final String content;
}

/// Slices [content] to the inclusive 1-based line range [lineStart]..[lineEnd].
///
/// When both bounds are `null`, returns the whole file verbatim (line 1
/// through the last line). An out-of-range [lineStart] or [lineEnd] is
/// clamped to the file's bounds rather than rejected.
LineRangeSlice sliceLineRange(String content, int? lineStart, int? lineEnd) {
  final lineInfo = LineInfo.fromContent(content);
  final lastLine = _lastLineNumber(content, lineInfo);

  if (lineStart == null && lineEnd == null) {
    return LineRangeSlice(lineStart: 1, effectiveLineEnd: lastLine, content: content);
  }

  var start = lineStart ?? 1;
  var end = lineEnd ?? lastLine;
  if (start < 1) start = 1;
  if (start > lastLine) start = lastLine;
  if (end > lastLine) end = lastLine;
  if (end < start) end = start;

  final startOffset = lineInfo.getOffsetOfLine(start - 1);
  final endOffset = end < lineInfo.lineCount ? lineInfo.getOffsetOfLine(end) : content.length;
  var slice = content.substring(startOffset, endOffset);
  // Strip the single trailing line terminator that separates the last
  // requested line from the following line.
  if (slice.endsWith('\n')) slice = slice.substring(0, slice.length - 1);
  if (slice.endsWith('\r')) slice = slice.substring(0, slice.length - 1);

  return LineRangeSlice(lineStart: start, effectiveLineEnd: end, content: slice);
}

/// The 1-based line number of the last content character.
///
/// Ignores the phantom trailing empty line produced when [content] ends with
/// a newline, so a file of N text lines reports N.
int _lastLineNumber(String content, LineInfo lineInfo) {
  if (content.isEmpty) return 1;
  return lineInfo.getLocation(content.length - 1).lineNumber;
}
