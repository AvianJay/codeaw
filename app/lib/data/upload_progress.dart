/// Bytes transferred by the HTTP transport. Success still requires its response.
typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);

const maxUploadBytes = 512 * 1024 * 1024;
const uploadLimitLabel = '512 MiB';
const uploadTimeout = Duration(hours: 1);
