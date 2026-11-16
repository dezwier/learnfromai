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
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final name = file.name.trim().isNotEmpty ? file.name : 'image.jpg';
  final mime = file.mimeType;
  return PickedImageBytes(bytes: bytes, filename: name, mimeType: mime);
}
