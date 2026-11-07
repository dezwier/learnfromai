class AppConfig {
  const AppConfig({this.baseUrl = const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8000')});

  final String baseUrl;
}
