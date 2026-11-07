class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, {this.details = const {}});

  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  @override
  String toString() => '$code: $message';
}
