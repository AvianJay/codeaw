/// Bytes transferred by the HTTP transport. Success still requires its response.
typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);
