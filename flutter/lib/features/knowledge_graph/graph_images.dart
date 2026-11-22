part of 'graph_controller.dart';

/// Image cache / upload / generate helpers for [GraphController].
extension GraphControllerImages on GraphController {
  /// Request shared topic image generation (or regeneration when [regenerate] is true).
  Future<bool> enqueueImage(String id, {String? title, bool regenerate = false}) async {
    if (isJobTypeActive(id, 'generate_image')) {
      _ensurePoller();
      return true;
    }
    try {
      final body = regenerate ? {'regenerate': true} : {'generate': true};
      final payload = await _post('/knowledge/nodes/$id/image', body: body);
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        final imageUrl = payload['image_url']?.toString();
        if (imageUrl != null && imageUrl.isNotEmpty) {
          patchNodeImageUrl(id, imageUrl);
        }
        return true;
      }
      _trackJobFromPayload(payload, id: id, title: title, type: 'generate_image');
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  /// Upload a user-picked image for the topic (replaces any existing iconic image).
  Future<bool> uploadImage(
    String id, {
    required List<int> bytes,
    required String filename,
    String? contentType,
  }) async {
    try {
      final payload = await _upload(
        '/knowledge/nodes/$id/image',
        bytes: bytes,
        filename: filename,
        contentType: contentType,
      );
      final imageUrl = payload['image_url']?.toString();
      final thumbUrl = payload['image_thumb_url']?.toString();
      if (imageUrl != null && imageUrl.isNotEmpty) {
        patchNodeImageUrl(id, imageUrl, imageThumbUrl: thumbUrl);
      }
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  /// Request pack-level image generation (or regeneration when [regenerate] is true).
  Future<Map<String, String?>?> enqueuePackImage(
    String id, {
    required int packIndex,
    String? title,
    bool regenerate = false,
  }) async {
    if (isPackImageJobActive(id, packIndex)) {
      _ensurePoller();
      return null;
    }
    try {
      final body = regenerate ? {'regenerate': true} : {'generate': true};
      final payload = await _post(
        '/knowledge/nodes/$id/packs/$packIndex/image',
        body: body,
      );
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        final imageUrl = payload['image_url']?.toString();
        final thumbUrl = payload['image_thumb_url']?.toString();
        if (imageUrl != null && imageUrl.isNotEmpty) {
          cachePackImageUrls(
            id,
            packIndex: packIndex,
            imageUrl: imageUrl,
            imageThumbUrl: thumbUrl,
          );
        }
        return {'image_url': imageUrl, 'image_thumb_url': thumbUrl};
      }
      _trackJobFromPayload(
        payload,
        id: id,
        title: title,
        type: 'generate_pack_image',
        packIndex: packIndex,
      );
      return null;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Upload a user-picked image for one pack (replaces any existing pack image).
  Future<Map<String, String?>?> uploadPackImage(
    String id, {
    required int packIndex,
    required List<int> bytes,
    required String filename,
    String? contentType,
  }) async {
    try {
      final payload = await _upload(
        '/knowledge/nodes/$id/packs/$packIndex/image',
        bytes: bytes,
        filename: filename,
        contentType: contentType,
      );
      final imageUrl = payload['image_url']?.toString();
      final thumbUrl = payload['image_thumb_url']?.toString();
      if (imageUrl != null && imageUrl.isNotEmpty) {
        cachePackImageUrls(
          id,
          packIndex: packIndex,
          imageUrl: imageUrl,
          imageThumbUrl: thumbUrl,
        );
      }
      return {'image_url': imageUrl, 'image_thumb_url': thumbUrl};
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Bust cache and preload pack image paths after generate/upload.
  void cachePackImageUrls(
    String nodeId, {
    required int packIndex,
    required String imageUrl,
    String? imageThumbUrl,
  }) {
    imageBytesByUrl.removeWhere(
      (key, _) => key.contains('/nodes/$nodeId/packs/$packIndex/image'),
    );
    ensureImageCached(imageThumbUrl ?? imageUrl);
    ensureImageCached(imageUrl);
    lastCompletedNodeId = nodeId;
    lastCompletedJobType = 'generate_pack_image';
    lastCompletedPackIndex = packIndex;
    notifyListeners();
  }

  /// Authenticated image bytes for a topic image path from the graph payload.
  ///
  /// Concurrent callers share one in-flight request per path. Pass [notify] false
  /// when the caller will update its own widget (avoids a second hero rebuild).
  Future<List<int>?> fetchImageBytes(String imageUrl, {bool notify = true}) async {
    final path = _apiPathFromImageUrl(imageUrl);
    if (path == null) return null;
    final cached = imageBytesByUrl[path] ?? imageBytesByUrl[imageUrl];
    if (cached != null) return cached;

    final existing = _imageFetchesInFlight[path];
    if (existing != null) {
      final shared = await existing;
      if (notify && shared != null) notifyListeners();
      return shared;
    }

    final future = _downloadImageBytes(path, imageUrl);
    _imageFetchesInFlight[path] = future;
    try {
      final stored = await future;
      if (notify) notifyListeners();
      return stored;
    } finally {
      _imageFetchesInFlight.remove(path);
    }
  }

  Future<Uint8List?> _downloadImageBytes(String path, String imageUrl) async {
    try {
      final bytes = await _getBytes(path);
      final stored = Uint8List.fromList(bytes);
      imageBytesByUrl[path] = stored;
      imageBytesByUrl[imageUrl] = stored;
      return stored;
    } on ApiException catch (exc) {
      error = exc.message;
      return null;
    }
  }

  Uint8List? cachedImageBytes(String? imageUrl) {
    if (imageUrl == null || imageUrl.trim().isEmpty) return null;
    final path = _apiPathFromImageUrl(imageUrl) ?? imageUrl;
    return imageBytesByUrl[path] ?? imageBytesByUrl[imageUrl];
  }

  /// Fire-and-forget load; notifies when bytes arrive (hex tiles / warm cache).
  void ensureImageCached(String? imageUrl) {
    if (imageUrl == null || imageUrl.trim().isEmpty) return;
    if (cachedImageBytes(imageUrl) != null) return;
    final path = _apiPathFromImageUrl(imageUrl) ?? imageUrl;
    if (!_imageLoadsInFlight.add(path)) return;
    unawaited(() async {
      try {
        await fetchImageBytes(imageUrl, notify: true);
      } finally {
        _imageLoadsInFlight.remove(path);
      }
    }());
  }

  void preloadGraphImages() {
    final nodes = categoryGraph?['nodes'];
    if (nodes is! List) return;
    for (final raw in nodes) {
      if (raw is! Map) continue;
      final thumb = raw['image_thumb_url']?.toString();
      final full = raw['image_url']?.toString();
      ensureImageCached((thumb != null && thumb.isNotEmpty) ? thumb : full);
    }
  }

  void patchNodeImageUrl(String nodeId, String? imageUrl, {String? imageThumbUrl}) {
    final graph = categoryGraph;
    if (graph == null) return;
    final nodes = graph['nodes'];
    if (nodes is! List) return;
    var changed = false;
    final next = <dynamic>[];
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == nodeId) {
        final copy = Map<String, dynamic>.from(raw);
        copy['image_url'] = imageUrl;
        copy['image_thumb_url'] = imageThumbUrl ??
            (imageUrl == null
                ? null
                : '/knowledge/nodes/$nodeId/image/file?variant=thumb');
        next.add(copy);
        changed = true;
      } else {
        next.add(raw);
      }
    }
    if (!changed) return;
    categoryGraph = {...graph, 'nodes': next};
    if (imageUrl != null) {
      imageBytesByUrl.removeWhere((key, _) => key.contains(nodeId));
      ensureImageCached(imageThumbUrl ?? '/knowledge/nodes/$nodeId/image/file?variant=thumb');
      ensureImageCached(imageUrl);
    }
    notifyListeners();
  }

  static String? _apiPathFromImageUrl(String imageUrl) {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('/api/v1/')) {
      return trimmed.substring('/api/v1'.length);
    }
    if (trimmed.startsWith('/knowledge/')) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.path.contains('/api/v1/')) {
      final idx = uri.path.indexOf('/api/v1/');
      final path = uri.path.substring(idx + '/api/v1'.length);
      return uri.hasQuery ? '$path?${uri.query}' : path;
    }
    if (uri.path.startsWith('/knowledge/')) {
      return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    }
    return null;
  }
}
