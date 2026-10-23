import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF09090D),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ApexLeaderApp());
}

class ApexLeaderApp extends StatelessWidget {
  const ApexLeaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HARVARD 25-SOAT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070B16),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          surface: Color(0xFF0E1528),
        ),
      ),
      home: const ApexWebViewScreen(),
    );
  }
}

class ApexWebViewScreen extends StatefulWidget {
  const ApexWebViewScreen({super.key});

  @override
  State<ApexWebViewScreen> createState() => _ApexWebViewScreenState();
}

class _ApexWebViewScreenState extends State<ApexWebViewScreen> {
  WebViewController? _controller;
  HttpServer? _server;
  bool _isLoading = true;
  int _port = 0;
  DateTime? _lastBackPressTime;

  @override
  void initState() {
    super.initState();
    _startServerAndLoad();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<File> _getStorageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/apex_user_data.json');
  }

  Future<void> _startServerAndLoad() async {
    try {
      // Bind local HTTP server to a FIXED port so LocalStorage and IndexedDB NEVER get wiped on restart!
      const int kApexFixedPort = 28492;
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, kApexFixedPort, shared: true);
        _port = _server!.port;
      } catch (bindErr) {
        debugPrint('Could not bind to fixed port $kApexFixedPort ($bindErr), falling back to ephemeral port.');
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        _port = _server!.port;
      }

      _server!.listen((HttpRequest request) async {
        // Native Dart Persistent Storage Save Endpoint (Writes directly to physical flash storage)
        if (request.uri.path == '/api/storage/save') {
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
          request.response.headers.add('Access-Control-Allow-Headers', '*');

          if (request.method == 'OPTIONS') {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            return;
          }

          try {
            final bodyBytes = await request.fold<List<int>>([], (prev, element) => prev..addAll(element));
            final file = await _getStorageFile();
            await file.writeAsBytes(bodyBytes, flush: true);
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"success": true}');
            await request.response.close();
            return;
          } catch (storageErr) {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"error": "${storageErr.toString()}"}');
            await request.response.close();
            return;
          }
        }

        // Native Dart Persistent Storage Load Endpoint (Reads directly from physical flash storage)
        if (request.uri.path == '/api/storage/load') {
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
          request.response.headers.add('Access-Control-Allow-Headers', '*');

          if (request.method == 'OPTIONS') {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            return;
          }

          try {
            final file = await _getStorageFile();
            if (await file.exists()) {
              final bytes = await file.readAsBytes();
              request.response.statusCode = HttpStatus.ok;
              request.response.headers.contentType = ContentType.json;
              request.response.add(bytes);
            } else {
              request.response.statusCode = HttpStatus.ok;
              request.response.headers.contentType = ContentType.json;
              request.response.write('{}');
            }
            await request.response.close();
            return;
          } catch (loadErr) {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"error": "${loadErr.toString()}"}');
            await request.response.close();
            return;
          }
        }

        // Native Dart Gemini Proxy to bypass any Android WebView CORS or network restrictions
        if (request.uri.path == '/api/gemini-proxy' || request.uri.path == '/api/gemini') {
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
          request.response.headers.add('Access-Control-Allow-Headers', '*');

          if (request.method == 'OPTIONS') {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            return;
          }

          try {
            final targetUrl = request.uri.queryParameters['url'];
            if (targetUrl == null || targetUrl.isEmpty) {
              request.response.statusCode = HttpStatus.badRequest;
              request.response.headers.contentType = ContentType.json;
              request.response.write('{"error": {"message": "Missing target url"}}');
              await request.response.close();
              return;
            }

            final bodyBytes = await request.fold<List<int>>([], (prev, element) => prev..addAll(element));
            final httpClient = HttpClient();
            httpClient.connectionTimeout = const Duration(seconds: 30);
            final clientReq = await httpClient.postUrl(Uri.parse(targetUrl));
            clientReq.headers.contentType = ContentType.json;
            clientReq.add(bodyBytes);

            final clientRes = await clientReq.close();
            final resBytes = await clientRes.fold<List<int>>([], (prev, element) => prev..addAll(element));
            httpClient.close();

            request.response.statusCode = clientRes.statusCode;
            request.response.headers.contentType = ContentType.json;
            request.response.add(resBytes);
            await request.response.close();
            return;
          } catch (proxyErr) {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"error": {"message": "${proxyErr.toString()}"}}');
            await request.response.close();
            return;
          }
        }

        String path = request.uri.path;
        if (path == '/' || path.isEmpty) {
          path = '/index.html';
        }

        // Normalize path
        if (path.startsWith('/')) {
          path = path.substring(1);
        }

        final assetPath = 'assets/web/$path';

        try {
          final byteData = await rootBundle.load(assetPath);
          final bytes = byteData.buffer.asUint8List();

          _setContentType(request.response, path);
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Cache-Control', 'no-cache');
          request.response.add(bytes);
          await request.response.close();
        } catch (_) {
          // Fallback to index.html for client-side routing
          try {
            final fallbackData = await rootBundle.load('assets/web/index.html');
            _setContentType(request.response, 'index.html');
            request.response.headers.add('Access-Control-Allow-Origin', '*');
            request.response.add(fallbackData.buffer.asUint8List());
            await request.response.close();
          } catch (e) {
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('Not found');
            await request.response.close();
          }
        }
      });

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF09090D))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) {
              debugPrint('Page started loading: $url');
            },
            onPageFinished: (String url) {
              if (mounted) {
                setState(() {
                  _isLoading = false;
                });
              }
            },
            onWebResourceError: (WebResourceError error) {
              debugPrint('WebView error: ${error.description}');
            },
          ),
        );

      // Enable Android specific settings if running on Android
      if (controller.platform is AndroidWebViewController) {
        AndroidWebViewController.enableDebugging(false);
        final androidController = controller.platform as AndroidWebViewController;
        androidController.setMediaPlaybackRequiresUserGesture(false);

        androidController.setOnPlatformPermissionRequest((request) {
          request.grant();
        });

        androidController.setOnShowFileSelector((FileSelectorParams params) async {
          try {
            final ImagePicker picker = ImagePicker();
            final ImageSource source = params.isCaptureEnabled ? ImageSource.camera : ImageSource.gallery;
            final XFile? image = await picker.pickImage(
              source: source,
              maxWidth: 1024,
              maxHeight: 1024,
              imageQuality: 85,
            );
            if (image != null) {
              return [Uri.file(image.path).toString()];
            }
          } catch (e) {
            debugPrint('File chooser picker error: $e');
          }
          return <String>[];
        });
      }

      await controller.loadRequest(Uri.parse('http://127.0.0.1:$_port/index.html'));

      if (mounted) {
        setState(() {
          _controller = controller;
        });
      }
    } catch (e) {
      debugPrint('Local server failed, falling back to direct asset: $e');
      // Direct asset fallback
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF09090D))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (mounted) setState(() => _isLoading = false);
            },
          ),
        );

      if (controller.platform is AndroidWebViewController) {
        final androidController = controller.platform as AndroidWebViewController;
        androidController.setMediaPlaybackRequiresUserGesture(false);
        androidController.setOnPlatformPermissionRequest((request) => request.grant());
        androidController.setOnShowFileSelector((FileSelectorParams params) async {
          try {
            final ImagePicker picker = ImagePicker();
            final ImageSource source = params.isCaptureEnabled ? ImageSource.camera : ImageSource.gallery;
            final XFile? image = await picker.pickImage(source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 85);
            if (image != null) {
              return [Uri.file(image.path).toString()];
            }
          } catch (e) {
            debugPrint('Fallback picker error: $e');
          }
          return <String>[];
        });
      }

      await controller.loadFlutterAsset('assets/web/index.html');

      if (mounted) {
        setState(() {
          _controller = controller;
        });
      }
    }
  }

  void _setContentType(HttpResponse response, String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.html')) {
      response.headers.contentType = ContentType.html;
    } else if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
      response.headers.contentType = ContentType('application', 'javascript', charset: 'utf-8');
    } else if (lower.endsWith('.css')) {
      response.headers.contentType = ContentType('text', 'css', charset: 'utf-8');
    } else if (lower.endsWith('.svg')) {
      response.headers.contentType = ContentType('image', 'svg+xml');
    } else if (lower.endsWith('.png')) {
      response.headers.contentType = ContentType('image', 'png');
    } else if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      response.headers.contentType = ContentType('image', 'jpeg');
    } else if (lower.endsWith('.json')) {
      response.headers.contentType = ContentType.json;
    } else if (lower.endsWith('.wasm')) {
      response.headers.contentType = ContentType('application', 'wasm');
    } else {
      response.headers.contentType = ContentType.binary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        if (_controller != null && await _controller!.canGoBack()) {
          await _controller!.goBack();
          return;
        }

        final now = DateTime.now();
        if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          if (mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Chiqish uchun yana bir marta bosing',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                backgroundColor: const Color(0xFF1E2030),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF2D3047), width: 1),
                ),
                duration: const Duration(seconds: 2),
                margin: const EdgeInsets.only(bottom: 28, left: 48, right: 48),
              ),
            );
          }
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF09090D),
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              if (_controller != null)
                WebViewWidget(controller: _controller!),
              if (_isLoading)
                Container(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.9,
                      colors: [
                        Color(0xFF14172B),
                        Color(0xFF090A10),
                        Color(0xFF05060A),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Elite Glowing Emblem
                          Container(
                            width: 104,
                            height: 104,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [Color(0xFFEF4444), Color(0xFF06B6D4), Color(0xFF6366F1)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFEF4444).withValues(alpha: 0.4),
                                  blurRadius: 36,
                                  spreadRadius: 4,
                                ),
                                BoxShadow(
                                  color: const Color(0xFF06B6D4).withValues(alpha: 0.3),
                                  blurRadius: 48,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(3.0),
                              child: Container(
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF0D0F1A),
                                ),
                                child: const Center(
                                  child: Text(
                                    '👑',
                                    style: TextStyle(fontSize: 46),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          const Text(
                            'APEX LEADER OS',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                            ),
                            child: const Text(
                              'UNIVERSITET & DIPLOMATIYA ELITASI',
                              style: TextStyle(
                                color: Color(0xFFF87171),
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Google Gemini 2.0 AI · HEMIS 5.0 GPA · Harvard BATNA',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 36),
                          const SizedBox(
                            width: 140,
                            child: ClipRRect(
                              borderRadius: BorderRadius.all(Radius.circular(10)),
                              child: LinearProgressIndicator(
                                minHeight: 3.5,
                                backgroundColor: Color(0xFF1E2238),
                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF06B6D4)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Liderlik kokpiti ishga tushirilmoqda...',
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
