// A minimal MCP server over stdio for the McpProvider tests: two tools, one
// read-only and one destructive, plus an error case. Mirrors the Python
// package's tests/fake_mcp_server.py.
import 'dart:convert';
import 'dart:io';

const tools = [
  {
    'name': 'echo',
    'description': 'Echo the text back.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
    'annotations': {'readOnlyHint': true, 'idempotentHint': true},
  },
  {
    'name': 'delete-all',
    'description': 'Delete everything.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
];

void main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final message = (jsonDecode(line) as Map).cast<String, Object?>();
    final method = message['method'];
    final requestId = message['id'];
    if (requestId == null) continue; // a notification
    Object? result;
    switch (method) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'fake', 'version': '0'},
        };
      case 'tools/list':
        result = {'tools': tools};
      case 'tools/call':
        final params = (message['params'] as Map).cast<String, Object?>();
        final arguments = ((params['arguments'] as Map?) ?? const {}).cast<String, Object?>();
        if (params['name'] == 'echo') {
          result = arguments['text'] == 'boom'
              ? {'content': [{'type': 'text', 'text': 'echo refused'}], 'isError': true}
              : {'content': [{'type': 'text', 'text': 'echo: ${arguments['text']}'}]};
        } else {
          result = {'content': [{'type': 'text', 'text': 'deleted'}]};
        }
      default:
        stdout.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'id': requestId,
          'error': {'code': -32601, 'message': 'unknown method'},
        }));
        continue;
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': requestId, 'result': result}));
  }
}
