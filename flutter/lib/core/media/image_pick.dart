import 'package:image_picker/image_picker.dart';

class PickedImageBytes {
  const PickedImageBytes({
    required this.bytes,
    required this.filename,
    this.mimeType,
  });

  final List<int> bytes;
  final String filename;
  final String? mimeType;
}

/// Opens the system gallery picker. Returns null if the user cancels.
Future<PickedImageBytes?> pickImageBytes() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 2048,
    maxHeight: 2048,
    imageQuality: 92,
    // Avoid needing full photo-library permission just to read pixels.
    requestFullMetadata: false,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final name = file.name.trim().isNotEmpty ? file.name : 'image.jpg';
  // iOS often reports HEIC even after imageQuality re-encodes to JPEG.
  final mime = _normalizedMime(file.mimeType, name, bytes);
  return PickedImageBytes(bytes: bytes, filename: _filenameForMime(name, mime), mimeType: mime);
}

String? _normalizedMime(String? reported, String filename, List<int> bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  final lower = (reported ?? '').split(';').first.trim().toLowerCase();
  if (lower == 'image/jpg' || lower == 'image/jpeg') return 'image/jpeg';
  if (lower == 'image/png' || lower == 'image/webp' || lower == 'image/gif') return lower;
  final name = filename.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.gif')) return 'image/gif';
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
  return reported;
}

String _filenameForMime(String name, String? mime) {
  final trimmed = name.trim();
  if (mime == 'image/jpeg' &&
      (trimmed.toLowerCase().endsWith('.heic') || trimmed.toLowerCase().endsWith('.heif'))) {
    final base = trimmed.contains('.') ? trimmed.substring(0, trimmed.lastIndexOf('.')) : trimmed;
    return '$base.jpg';
  }
  return trimmed.isNotEmpty ? trimmed : 'image.jpg';
}
