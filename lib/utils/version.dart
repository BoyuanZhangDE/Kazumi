import 'dart:math';

/// Strips this fork's tag namespacing (e.g. `autosource/v2.2.6.2` ->
/// `2.2.6.2`) so version segments can be compared numerically: an optional
/// leading `autosource/` path prefix, then an optional leading `v`.
String _normalizeVersionTag(String version) {
  var normalized = version;
  if (normalized.startsWith('autosource/')) {
    normalized = normalized.substring('autosource/'.length);
  }
  if (normalized.startsWith('v')) {
    normalized = normalized.substring(1);
  }
  return normalized;
}

bool needUpdate(String localVersion, String remoteVersion) {
  final localVersionList = _normalizeVersionTag(localVersion).split('.');
  final remoteVersionList = _normalizeVersionTag(remoteVersion).split('.');
  final maxLength = max(localVersionList.length, remoteVersionList.length);
  for (var i = 0; i < maxLength; i++) {
    final localSegment = i < localVersionList.length
        ? int.tryParse(localVersionList[i])
        : 0;
    final remoteSegment = i < remoteVersionList.length
        ? int.tryParse(remoteVersionList[i])
        : 0;
    if (localSegment == null || remoteSegment == null) {
      return false;
    }
    if (remoteSegment > localSegment) {
      return true;
    } else if (remoteSegment < localSegment) {
      return false;
    }
  }
  return false;
}
