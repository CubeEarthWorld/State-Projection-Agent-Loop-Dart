/// An MCP client as a [ToolProvider].
///
/// One server over stdio; every tool it lists becomes a capability
/// `mcp.<server>.<tool>`. MCP's tool annotations map onto the contract the
/// policy engine and the runtime reason about, and a tool that declares
/// nothing lands in the most restrictive class — an external, never-retried
/// effect — exactly as an undeclared local capability would.
///
/// Standard library only (the wire format is newline-delimited JSON-RPC).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../capability.dart';
import '../registry.dart';

const String protocolVersion = '2025-06-18';
final RegExp _segmentRe = RegExp(r'[^a-z0-9_]+');

/// An MCP tool name as one dotted-name segment.
String segment(String name) {
  var seg = name.toLowerCase().replaceAll(_segmentRe, '_');
  seg = seg.replaceAll(RegExp(r'^_+|_+$'), '');
  if (seg.isEmpty) seg = 'tool';
  return RegExp(r'^[a-z]').hasMatch(seg) ? seg : 't_$seg';
}

/// MCP annotations -> (effects, retry_safety). Absent hints are read the
/// conservative way round: not read-only, destructive, not idempotent.
(List<Map<String, String>>, String) contract(Map<String, Object?> annotations) {
  final readOnly = annotations['readOnlyHint'] == true;
  final destructive = annotations['destructiveHint'] != false;
  final idempotent = annotations['idempotentHint'] == true;
  if (readOnly) {
    return ([{'kind': 'read', 'resource': 'mcp:*'}], idempotent ? 'idempotent' : 'check_then_retry');
  }
  return ([{'kind': destructive ? 'external' : 'write', 'resource': 'mcp:*'}], idempotent ? 'idempotent' : 'never_retry');
}

/// `registry.attachProvider(McpProvider('fs', ['npx', '-y', '@modelcontextprotocol/server-filesystem', '.']))`.
///
/// The subprocess starts on first use and lives until [close].
class McpProvider implements ToolProvider {
  McpProvider(String name, this.command, {this.environment, this.timeoutS = 30.0}) : name = segment(name);

  final String name;
  final List<String> command;
  final Map<String, String>? environment;
  final double timeoutS;
  Process? _proc;
  StreamIterator<String>? _lines;
  var _nextId = 0;
  Future<void> _turn = Future.value(); // requests go one at a time

  Future<void> _start() async {
    if (_proc != null) return;
    final proc = await Process.start(command.first, command.skip(1).toList(), environment: environment);
    _proc = proc;
    _lines = StreamIterator(proc.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    await _request('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'state-projection-loop', 'version': '0.5.0'},
    });
    _send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
  }

  void _send(Map<String, Object?> message) {
    _proc!.stdin.writeln(jsonEncode(message));
  }

  Future<Object?> _request(String method, Map<String, Object?> params) async {
    final requestId = ++_nextId;
    _send({'jsonrpc': '2.0', 'id': requestId, 'method': method, 'params': params});
    while (true) {
      if (!await _lines!.moveNext()) {
        throw StateError('MCP server "$name" closed the connection during $method');
      }
      final reply = (jsonDecode(_lines!.current) as Map).cast<String, Object?>();
      if (reply['id'] != requestId) continue; // a notification or an unrelated message
      final error = reply['error'];
      if (error != null) {
        throw StateError('MCP $method failed: ${(error as Map)['message'] ?? error}');
      }
      return reply['result'];
    }
  }

  Future<Object?> call(String method, Map<String, Object?> params) {
    final result = _turn.then((_) async {
      await _start();
      return _request(method, params);
    });
    _turn = result.then((_) {}, onError: (_) {});
    return result;
  }

  void close() {
    _proc?.kill();
    _proc = null;
    _lines = null;
  }

  // -- ToolProvider -----------------------------------------------------------

  /// The server's tools as capabilities. Synchronous by the [ToolProvider]
  /// contract, so call [refresh] (which talks to the server) first; the
  /// registry then syncs what it fetched.
  @override
  Iterable<Object> provide() => _tools.map(_capability);

  List<Map<String, Object?>> _tools = const [];

  /// Fetch the tool list from the server, then have [registry] sync it.
  Future<void> refresh(Registry registry) async {
    final result = (await call('tools/list', {})) as Map;
    _tools = [for (final t in result['tools'] as List) (t as Map).cast<String, Object?>()];
    registry.refreshProviders();
  }

  Capability _capability(Map<String, Object?> tool) {
    final (effects, retrySafety) = contract((tool['annotations'] as Map?)?.cast<String, Object?>() ?? {});
    final mcpName = tool['name'] as String;
    final description = (tool['description'] as String?) ?? 'MCP tool $mcpName of server $name';

    Future<Object?> handler(Map<String, Object?> arguments) async {
      final result = ((await call('tools/call', {'name': mcpName, 'arguments': arguments})) as Map)
          .cast<String, Object?>();
      final content = (result['content'] as List?) ?? const [];
      final texts = [for (final c in content) if ((c as Map)['type'] == 'text') (c['text'] as String?) ?? ''];
      if (result['isError'] == true) {
        throw StateError(texts.isNotEmpty ? texts.join('\n') : 'MCP tool reported an error');
      }
      return result['structuredContent'] ?? (texts.isNotEmpty ? texts.join('\n') : content);
    }

    return Capability.fromDict({
      'name': 'mcp.$name.${segment(mcpName)}',
      'category': 'mcp/$name',
      'spec': {
        'description': description,
        'parameters': tool['inputSchema'] ?? {'type': 'object', 'properties': <String, Object?>{}},
      },
      'execution': {'timeout_s': timeoutS, 'retry_safety': retrySafety},
      'effects': effects,
    }, handler: handler);
  }
}
