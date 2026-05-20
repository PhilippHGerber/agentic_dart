/// Example: start pubdev_context and query it with an in-process MCP client.
///
/// Run from the package root:
/// ```bash
/// dart run example/pubdev_context.dart
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/config/config.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/server.dart';
import 'package:stream_channel/stream_channel.dart';

Future<void> main() async {
  // Wire an in-process channel pair so server and client share a process.
  final clientCtrl = StreamController<String>();
  final serverCtrl = StreamController<String>();
  serverCtrl.stream.listen(null, onDone: () {});

  final serverChannel = StreamChannel<String>.withCloseGuarantee(
    clientCtrl.stream,
    serverCtrl.sink,
  );
  final clientChannel = StreamChannel<String>.withCloseGuarantee(
    serverCtrl.stream,
    clientCtrl.sink,
  );

  // Start the server.
  final server = PubMcpServer(
    serverChannel,
    config: const PubMcpConfig(),
    client: PubDevClient(),
    searchCache: ResponseCache<List<PackageSummary>>(),
    packageCache: ResponseCache<PackageDetail>(),
    changelogCache: ResponseCache<List<ChangelogEntry>>(),
  );

  // Connect an MCP client and initialise.
  final mcpClient = _ExampleClient();
  final connection = mcpClient.connectServer(clientChannel);
  await connection.initialize(
    InitializeRequest(
      protocolVersion: ProtocolVersion.latestSupported,
      capabilities: mcpClient.capabilities,
      clientInfo: mcpClient.implementation,
    ),
  );
  connection.notifyInitialized(InitializedNotification());
  await server.initialized;

  // Call search_packages.
  final result = await connection.callTool(
    CallToolRequest(
      name: 'search_packages',
      arguments: {'query': 'http', 'limit': 3, 'sort': 'likes'},
    ),
  );

  final text = (result.content.first as TextContent).text;
  stdout.writeln(text);

  await mcpClient.shutdown();
  await server.shutdown();
}

base class _ExampleClient extends MCPClient {
  _ExampleClient() : super(Implementation(name: 'example-client', version: '0.0.1'));
}
