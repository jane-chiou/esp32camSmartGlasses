// ════════════════════════════════════════════════════════════════
//  ESP32-CAM 盲人輔助 App
//  Flutter (Android + iOS)
//
//  功能：
//    · 連接 ESP32-CAM AP 熱點後自動偵測裝置
//    · 按下「拍照辨識」→ 觸發 ESP32-CAM 拍照 → 取得 JPEG
//    · 上傳至 Gemini Vision API 進行場景描述
//    · 結果顯示於畫面並自動 TTS 語音朗讀（輔助盲人）
//    · 支援 Android / iOS
//
//  pubspec.yaml 需加入的套件：
//    dependencies:
//      http: ^1.2.1
//      flutter_tts: ^4.0.2
//      permission_handler: ^11.3.1
//      connectivity_plus: ^6.0.3
//
//  iOS 需在 ios/Runner/Info.plist 加入：
//    <key>NSMicrophoneUsageDescription</key>
//    <string>Used for TTS playback</string>
//    <key>NSSpeechRecognitionUsageDescription</key>
//    <string>Used for TTS playback</string>
//
//  Android 需在 android/app/src/main/AndroidManifest.xml 加入：
//    <uses-permission android:name="android.permission.INTERNET"/>
//    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
// ════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:math';
import 'package:gal/gal.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
//StatelessWidget
void main() {
  runApp(const VisionAssistApp());
}

// 畫質設定
String _frameSize   = 'VGA';   // 預設 VGA
int    _jpegQuality = 12;       // 1~63，數字越小越好

// 預設放好的 API Key（使用者可一鍵複製）
final String _presetApiKey = 'AIzaSyDydYbEUYRg9LvbHxtufz6Oaf44j_pbeN0';  // ← 填入

// ── App 入口 ──────────────────────────────────────────────────────
class VisionAssistApp extends StatelessWidget {
  const VisionAssistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '視覺輔助',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: const TextTheme(
          bodyLarge:  TextStyle(fontSize: 20),
          bodyMedium: TextStyle(fontSize: 18),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
//  狀態機
// ══════════════════════════════════════════════════════════════════
enum AppState {
  idle,          // 等待操作
  //connecting,    // 檢查 ESP32-CAM 連線
  capturing,     // 拍照中
  analyzing,     // Gemini 分析中
  speaking,      // TTS 朗讀中
  error,         // 錯誤
}

// ══════════════════════════════════════════════════════════════════
//  主畫面
// ══════════════════════════════════════════════════════════════════
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {

  // ── 設定（可在設定頁修改）──────────────────────────────────────
  String _espHost      = '172.20.10.2';   // ESP32-CAM AP 預設 IP
  String _geminiApiKey = '';  // ← 填入你的 API Key
  String _promptText = '請用繁體中文簡短描述這張照片最重要的內容，50字以內，直接描述不要分點。';

  // ── 狀態 ───────────────────────────────────────────────────────
  AppState _state      = AppState.idle;
  String   _resultText = '按下「拍照辨識」開始使用';
  String   _statusText = '等待中';
  Uint8List? _photoBytes;
  bool _deviceOnline   = false;

  // ── 電池狀態（方案 B：純顯示）─────────────────────────────────
  // 透過偵測 ESP32 連線時間來推算：
  // 剛連上 = 充電中（假設剛開機插著電）
  // 連線超過 30 分鐘 = 使用中
  //bool   _isCharging     = false;
  DateTime? _connectedTime;

  //照片旋轉角度
  int _rotationDegrees = 0;  // 維持 int，0~360 都可以輸入

  // ── TTS ────────────────────────────────────────────────────────
  late FlutterTts _tts;
  bool _isSpeaking = false;

  // ── 動畫 ───────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  // ══════════════════════════════════════════════════════════════
  //  Init / Dispose
  // ══════════════════════════════════════════════════════════════
  @override
  void initState() {
    super.initState();
    _initTts();
    _initAnimation();
    _checkDeviceConnection();
    _startPolling();  // ← 加這行
  }

  @override
  void dispose() {
    _tts.stop();
    _pulseController.dispose();
    super.dispose();
  }

  // ── TTS 初始化 ─────────────────────────────────────────────────
  Future<void> _initTts() async {
    _tts = FlutterTts();
    await _tts.setLanguage('zh-TW');
    await _tts.setSpeechRate(0.45);   // 語速（0.0~1.0），盲人建議 0.4~0.5
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      setState(() { _isSpeaking = true; _state = AppState.speaking; });
    });
    _tts.setCompletionHandler(() {
      setState(() { _isSpeaking = false; _state = AppState.idle; });
    });
    _tts.setErrorHandler((msg) {
      setState(() { _isSpeaking = false; _state = AppState.idle; });
      debugPrint('[TTS] 錯誤: $msg');
    });
  }

  //調畫質
  Future<void> _applyQualitySettings() async {
    if (!_deviceOnline) return;
    try {
      await http.get(
        Uri.parse('http://$_espHost/set_quality'
            '?framesize=$_frameSize&quality=$_jpegQuality'),
      ).timeout(const Duration(seconds: 5));
      debugPrint('[Quality] 已套用：$_frameSize, quality=$_jpegQuality');
    } catch (e) {
      debugPrint('[Quality] 設定失敗：$e');
    }
  }

  // ── 脈衝動畫（拍照按鈕）──────────────────────────────────────
  void _initAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 5)); // 原本2秒改成5秒
      if (_state != AppState.idle || !_deviceOnline) return true;
      try {
        final resp = await http
            .get(Uri.parse('http://$_espHost/status'))
            .timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) {
          final json = jsonDecode(resp.body);
          if (json['photo_ready'] == true) {
            await _fetchAndAnalyze();
          }
        }
      } catch (_) {}
      return true;
    });
  }

// 從 /capture 取照片並送 Gemini 分析
  Future<void> _fetchAndAnalyze() async {
    // 立即鎖定狀態，防止輪詢重複觸發
    if (_state != AppState.idle) return;

    setState(() {
      _state      = AppState.capturing;
      _statusText = '取得實體按鈕照片...';
    });

    try {
      final resp = await http
          .get(Uri.parse('http://$_espHost/capture'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        _handleError('取得照片失敗', 'HTTP ${resp.statusCode}');
        return;
      }
      setState(() { _photoBytes = resp.bodyBytes; });
      // 旋轉照片
      final rotated = await _rotateImage(resp.bodyBytes, _rotationDegrees);
      setState(() { _photoBytes = rotated; });


      setState(() {
        _state      = AppState.analyzing;
        _statusText = '分析中...';
      });
      final description = await _callGeminiVision(rotated);

      setState(() {
        _state      = AppState.speaking;
        _statusText = '朗讀中...';
        _resultText = description;
      });
      await _speak(description);

    } catch (e) {
      if (e.toString().contains('429')) {
        _handleError('請求太頻繁，請稍後再試', e);
      } else if (e.toString().contains('Camera')) {
        _handleError('拍照失敗，請確認裝置連線', e);
      } else {
        _handleError('AI 分析失敗，請檢查 API Key 或網路', e);
      }
    } finally {
      setState(() { _state = AppState.idle; });
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  裝置連線檢查
  // ══════════════════════════════════════════════════════════════
  Future<void> _checkDeviceConnection() async {
    setState(() { _statusText = '檢查裝置連線...'; });
    try {
      final resp = await http
          .get(Uri.parse('http://$_espHost/ping'))
          .timeout(const Duration(seconds: 3));
      setState(() {
        _deviceOnline = resp.statusCode == 200;
        _statusText   = _deviceOnline ? '裝置已連線 ✓' : '裝置離線';
      });
      if (_deviceOnline) {
        await _speak('裝置已連線，可以開始使用');
      }
    } catch (_) {
      setState(() { _deviceOnline = false; _statusText = '裝置離線，請連接熱點'; });
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  核心流程：拍照 → Gemini 分析 → TTS
  // ══════════════════════════════════════════════════════════════
  Future<void> _captureAndAnalyze() async {
    if (_state != AppState.idle) return;

    // Step 1: 拍照
    setState(() {
      _state      = AppState.capturing;
      _statusText = '拍照中...';
      _resultText = '';
      _photoBytes = null;
    });
    await _speak('正在拍照');

    Uint8List? imageBytes;
    try {
      final resp = await http
          .get(Uri.parse('http://$_espHost/capture_now'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        imageBytes = resp.bodyBytes;
        setState(() { _photoBytes = imageBytes; });
        // 旋轉照片
        final rotated = await _rotateImage(imageBytes!, _rotationDegrees);
        setState(() { _photoBytes = rotated; });
        imageBytes = rotated;  // 傳給 Gemini 的也是旋轉後的版本
        debugPrint('[HTTP] 取得照片 ${imageBytes.length} bytes');
      } else {
        throw Exception('HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (e.toString().contains('429')) {
        _handleError('請求太頻繁，請稍後再試', e);
      } else if (e.toString().contains('Camera')) {
        _handleError('拍照失敗，請確認裝置連線', e);
      } else {
        _handleError('AI 分析失敗，請檢查 API Key 或網路', e);
      }
      return;
    }

    // Step 2: Gemini 分析
    setState(() {
      _state      = AppState.analyzing;
      _statusText = '分析中...';
    });
    await _speak('正在分析畫面');

    String? description;
    try {
      description = await _callGeminiVision(imageBytes);
    } catch (e) {
      _handleError('AI 分析失敗，請檢查 API Key 或網路', e);
      return;
    }

    // Step 3: 顯示 + TTS
    setState(() {
      _state      = AppState.speaking;
      _statusText = '朗讀中...';
      _resultText = description ?? '無法取得描述';
    });
    //await _speak(description ?? '無法取得描述');
  }

  // 旋轉照片（回傳旋轉後的 Uint8List）
  Future<Uint8List> _rotateImage(Uint8List bytes, int degrees) async {
    if (degrees == 0) return bytes;

    final codec    = await ui.instantiateImageCodec(bytes);
    final frame    = await codec.getNextFrame();
    final image    = frame.image;
    final recorder = ui.PictureRecorder();

    final double w   = image.width.toDouble();
    final double h   = image.height.toDouble();
    final double rad = degrees * pi / 180;

    // 計算旋轉後的邊界大小
    final double cos = (pi / 180 * degrees).abs();
    final double newW = (w * cos + h * (1 - cos)).abs();
    final double newH = (h * cos + w * (1 - cos)).abs();

    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, newW, newH));
    canvas.translate(newW / 2, newH / 2);
    canvas.rotate(rad);
    canvas.translate(-w / 2, -h / 2);
    canvas.drawImage(image, Offset.zero, Paint());

    final picture  = recorder.endRecording();
    final rotated  = await picture.toImage(newW.toInt(), newH.toInt());
    final byteData = await rotated.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  //  下載 / 分享照片
  // ══════════════════════════════════════════════════════════════
  Future<void> _downloadPhoto() async {
    if (_photoBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('沒有可下載的照片，請先拍照')));
      return;
    }

    // 顯示選擇方式
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('儲存照片',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),

            // 儲存到相簿
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.photo_library),
                label: const Text('儲存到相簿', style: TextStyle(fontSize: 16)),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _saveToGallery();
                },
              ),
            ),
            const SizedBox(height: 8),

            // 分享
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF21262D),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.share),
                label: const Text('分享', style: TextStyle(fontSize: 16)),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _sharePhotoFile();
                },
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.white60)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveToGallery() async {
    try {
      final now      = DateTime.now();
      final filename = 'esp32cam_'
          '${now.year}${now.month.toString().padLeft(2,'0')}'
          '${now.day.toString().padLeft(2,'0')}_'
          '${now.hour.toString().padLeft(2,'0')}'
          '${now.minute.toString().padLeft(2,'0')}'
          '${now.second.toString().padLeft(2,'0')}.jpg';

      // gal 需要先寫成檔案再存入相簿
      final tempDir = await getTemporaryDirectory();
      final file    = File('${tempDir.path}/$filename');
      await file.writeAsBytes(_photoBytes!);

      await Gal.putImage(file.path);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已儲存到相簿！')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('儲存失敗：$e')));
      }
    }
  }

  Future<void> _sharePhotoFile() async {
    try {
      final now      = DateTime.now();
      final filename = 'esp32cam_'
          '${now.year}${now.month.toString().padLeft(2,'0')}'
          '${now.day.toString().padLeft(2,'0')}_'
          '${now.hour.toString().padLeft(2,'0')}'
          '${now.minute.toString().padLeft(2,'0')}'
          '${now.second.toString().padLeft(2,'0')}.jpg';

      final tempDir = await getTemporaryDirectory();
      final file    = File('${tempDir.path}/$filename');
      await file.writeAsBytes(_photoBytes!);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/jpeg')],
        text: '來自 ESP32-CAM 的照片',
        sharePositionOrigin: Rect.fromLTWH(0, 0, 390, 100),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('分享失敗：$e')));
      }
    }
  }

  // ── 呼叫 Gemini Vision API ─────────────────────────────────────
  Future<String> _callGeminiVision(Uint8List imageBytes) async {
    const model = 'gemini-2.5-flash-lite';  // 速度快且支援圖片
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$_geminiApiKey',
    );

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(imageBytes),
              },
            },
            {'text': _promptText},
          ],
        },
      ],
      'generationConfig': {
        'temperature':     0.4,
        'maxOutputTokens': 150,  // 原本 500，改成 150，描述更短更快念完
      },
    });

    final resp = await http
        .post(url,
            headers: {'Content-Type': 'application/json'},
            body: body)
        .timeout(const Duration(seconds: 30));

    if (resp.statusCode != 200) {
      debugPrint('[Gemini] 錯誤回應: ${resp.body}');
      throw Exception('Gemini API 錯誤 ${resp.statusCode}');
    }

    final json   = jsonDecode(resp.body) as Map<String, dynamic>;
    final text   = json['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;
    return text ?? '（Gemini 未回傳文字）';
  }

  // ── TTS 朗讀 ──────────────────────────────────────────────────
  Future<void> _speak(String text) async {
    if (text.isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> _stopSpeaking() async {
    await _tts.stop();
    setState(() { _isSpeaking = false; _state = AppState.idle; });
  }

  // ── 錯誤處理 ──────────────────────────────────────────────────
  void _handleError(String message, Object? err) {
    debugPrint('[Error] $message: $err');
    setState(() {
      _state      = AppState.error;
      _statusText = '發生錯誤';
      _resultText = message;
    });
    _speak(message).then((_) {
      setState(() { _state = AppState.idle; });
    });
  }

  // ══════════════════════════════════════════════════════════════
  //  UI
  // ══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    //final theme  = Theme.of(context);
    //final isbusy = _state != AppState.idle && _state != AppState.error;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('阿瑪特拉斯', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          // 連線狀態指示
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              _deviceOnline ? Icons.wifi : Icons.wifi_off,
              color: _deviceOnline ? Colors.greenAccent : Colors.redAccent,
            ),
          ),
          // 設定
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '設定',
            onPressed: () => _openSettings(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── 狀態列 ──
            _StatusBar(text: _statusText, state: _state),

            // ── 照片預覽 ──
            Expanded(
              flex: 3,
              child: _PhotoPreview(
                photoBytes:  _photoBytes,
                isCapturing: _state == AppState.capturing,
                onDownload:  _photoBytes != null ? _downloadPhoto : null,  // ← 加這行
              ),
            ),

            // ── 結果文字 ──
            Expanded(
              flex: 4,
              child: _ResultPanel(text: _resultText, state: _state),
            ),

            // ── 提示詞快速編輯 ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: TextEditingController(text: _promptText),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 2,
                onChanged: (value) => setState(() { _promptText = value; }),
                decoration: InputDecoration(
                  labelText: '提示詞',
                  labelStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                  hintText: '請用繁體中文描述...',
                  hintStyle: const TextStyle(color: Colors.white24),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF30363D)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF1565C0)),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF161B22),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ── 控制按鈕 ──
            _ControlPanel(
              state: _state,
              isSpeaking: _isSpeaking,
              deviceOnline: _deviceOnline,
              onCapture: _captureAndAnalyze,
              onStop: _stopSpeaking,
              onRepeat: () => _speak(_resultText),
              onRefresh: _checkDeviceConnection,
            ),

            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // ── 設定頁 ────────────────────────────────────────────────────
  void _openSettings() {
    final hostCtrl   = TextEditingController(text: _espHost);
    final apiCtrl    = TextEditingController(text: _geminiApiKey);
    final promptCtrl = TextEditingController(text: _promptText);



    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (_, sc) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: ListView(
            controller: sc,
            children: [
              const Text('設定', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              _SettingField(controller: hostCtrl,   label: 'ESP32-CAM IP',  hint: '192.168.4.1'),
              // ── 1. 金鑰複製區（在 API Key 輸入框上方）──
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1117),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF30363D)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('預設 API Key',
                        style: TextStyle(color: Colors.white60, fontSize: 13)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _presetApiKey.length > 20
                                ? '${_presetApiKey.substring(0, 20)}...'
                                : _presetApiKey,
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF21262D),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('複製'),
                          onPressed: () {
                            apiCtrl.text = _presetApiKey;
                            setState(() { _geminiApiKey = _presetApiKey; });
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已複製到 API Key 欄位')));
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

// ── 2. API Key 輸入框（原本就有）──
              _SettingField(controller: apiCtrl,
                  label: 'Gemini API Key', hint: 'AIza...'),
              const SizedBox(height: 12),
              //_SettingField(controller: apiCtrl,    label: 'Gemini API Key', hint: 'AIza...'),
              const SizedBox(height: 12),
              _SettingField(controller: promptCtrl, label: '提示詞', maxLines: 4,
                hint: '請用繁體中文描述...'),
              const SizedBox(height: 20),
              const SizedBox(height: 12),
              const Text('照片旋轉角度（0～360）',
                  style: TextStyle(color: Colors.white60, fontSize: 14)),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: _rotationDegrees.toString(),
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '輸入旋轉角度，例如 90',
                  hintStyle: const TextStyle(color: Colors.white30),
                  suffixText: '°',
                  suffixStyle: const TextStyle(color: Colors.white60),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF30363D)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF1565C0)),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0D1117),
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 0 && parsed <= 360) {
                    setState(() { _rotationDegrees = parsed; });
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text('鏡頭解析度',
                  style: TextStyle(color: Colors.white60, fontSize: 14)),
              const SizedBox(height: 8),
              StatefulBuilder(
                builder: (context, setModalState) => Column(
                  children: [
                    // 解析度選擇
                    Row(
                      children: ['QVGA', 'VGA', 'SVGA', 'UXGA'].map((fs) {
                        final selected = _frameSize == fs;
                        final label = {
                          'QVGA': '320×240\n(快)',
                          'VGA':  '640×480\n(預設)',
                          'SVGA': '800×600',
                          'UXGA': '1600×1200\n(慢)',
                        }[fs]!;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: GestureDetector(
                              onTap: () {
                                setModalState(() {});
                                setState(() { _frameSize = fs; });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFF1565C0)
                                      : const Color(0xFF21262D),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: selected
                                          ? const Color(0xFF1565C0)
                                          : const Color(0xFF30363D)),
                                ),
                                child: Center(
                                  child: Text(label,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: selected ? Colors.white : Colors.white60,
                                        fontWeight: selected
                                            ? FontWeight.bold : FontWeight.normal,
                                      )),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    // JPEG 品質滑桿
                    Row(
                      children: [
                        const Text('JPEG 品質',
                            style: TextStyle(color: Colors.white60, fontSize: 13)),
                        const SizedBox(width: 8),
                        Text('$_jpegQuality（${_jpegQuality <= 15 ? "高" : _jpegQuality <= 30 ? "中" : "低"}品質）',
                            style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
                    Slider(
                      value: _jpegQuality.toDouble(),
                      min: 4, max: 63,
                      divisions: 59,
                      activeColor: const Color(0xFF1565C0),
                      onChanged: (v) {
                        setModalState(() {});
                        setState(() { _jpegQuality = v.toInt(); });
                      },
                    ),
                    const Text('數字越小畫質越好但速度越慢',
                        style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: () {
                  setState(() {
                    _espHost      = hostCtrl.text.trim();
                    _geminiApiKey = apiCtrl.text.trim();
                    // 提示詞已在主畫面即時更新，不需再設定
                  });
                  Navigator.pop(ctx);
                  _checkDeviceConnection();
                  // 發送畫質設定
                  _applyQualitySettings();
                },
                child: const Text('儲存', style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

//  照片預覽（含下載按鈕）
// ══════════════════════════════════════════════════════════════════
class _PhotoPreview extends StatelessWidget {
  final Uint8List? photoBytes;
  final bool isCapturing;
  final VoidCallback? onDownload;

  const _PhotoPreview({
    required this.photoBytes,
    required this.isCapturing,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Stack(
          children: [
            SizedBox.expand(
              child: isCapturing
                  ? const Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.blue),
                  SizedBox(height: 12),
                  Text('拍照中...',
                      style: TextStyle(color: Colors.white70)),
                ],
              ))
                  : photoBytes != null
                  ? Image.memory(photoBytes!, fit: BoxFit.contain)
                  : const Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.camera_alt, size: 64, color: Colors.white24),
                  SizedBox(height: 8),
                  Text('尚未拍照',
                      style: TextStyle(color: Colors.white38, fontSize: 16)),
                ],
              )),
            ),

            // 下載按鈕（右上角）
            if (photoBytes != null && onDownload != null)
              Positioned(
                top: 8, right: 8,
                child: GestureDetector(
                  onTap: onDownload,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download, color: Colors.white, size: 18),
                        SizedBox(width: 4),
                        Text('下載',
                            style: TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
//  子元件
// ══════════════════════════════════════════════════════════════════

class _StatusBar extends StatelessWidget {
  final String text;
  final AppState state;
  const _StatusBar({required this.text, required this.state});

  Color get _color => switch (state) {
    AppState.idle      => Colors.greenAccent,
    AppState.error     => Colors.redAccent,
    AppState.speaking  => Colors.cyanAccent,
    _                  => Colors.orangeAccent,
  };

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    color: const Color(0xFF161B22),
    child: Row(children: [
      Container(width: 10, height: 10,
        decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Text(text, style: TextStyle(color: _color, fontSize: 16)),
    ]),
  );
}

class _ResultPanel extends StatelessWidget {
  final String text;
  final AppState state;
  const _ResultPanel({required this.text, required this.state});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF161B22),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF30363D)),
    ),
    child: state == AppState.analyzing
      ? const Center(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.cyanAccent),
            SizedBox(height: 12),
            Text('AI 分析中...', style: TextStyle(color: Colors.white70, fontSize: 16)),
          ],
        ))
      : SingleChildScrollView(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              height: 1.6,
            ),
          ),
        ),
  );
}



class _ControlPanel extends StatelessWidget {
  final AppState state;
  final bool isSpeaking;
  final bool deviceOnline;
  final VoidCallback onCapture;
  final VoidCallback onStop;
  final VoidCallback onRepeat;
  final VoidCallback onRefresh;

  const _ControlPanel({
    required this.state,
    required this.isSpeaking,
    required this.deviceOnline,
    required this.onCapture,
    required this.onStop,
    required this.onRepeat,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final bool busy = state == AppState.capturing || state == AppState.analyzing;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(children: [
        // ── 主按鈕：拍照辨識 ──
        SizedBox(
          width: double.infinity,
          height: 72,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: busy
                  ? Colors.grey.shade800
                  : (deviceOnline ? const Color(0xFF1565C0) : Colors.grey.shade700),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: busy || !deviceOnline ? null : onCapture,
            icon: busy
              ? const SizedBox(width: 24, height: 24,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.camera_alt, size: 28),
            label: Text(
              busy ? '處理中...' : '拍照辨識',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ── 次要按鈕列 ──
        Row(children: [
          // 停止朗讀
          Expanded(child: _SecondaryBtn(
            icon: Icons.stop,
            label: '停止',
            color: Colors.redAccent,
            onTap: isSpeaking ? onStop : null,
          )),
          const SizedBox(width: 8),
          // 重播
          Expanded(child: _SecondaryBtn(
            icon: Icons.volume_up,
            label: '重播',
            color: Colors.cyanAccent,
            onTap: (!busy && state != AppState.speaking) ? onRepeat : null,
          )),
          const SizedBox(width: 8),
          // 重新連線
          Expanded(child: _SecondaryBtn(
            icon: Icons.refresh,
            label: '重新連線',
            color: Colors.greenAccent,
            onTap: !busy ? onRefresh : null,
          )),
        ]),
      ]),
    );
  }
}

class _SecondaryBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _SecondaryBtn({
    required this.icon, required this.label,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF21262D),
      foregroundColor: onTap != null ? color : Colors.grey,
      padding: const EdgeInsets.symmetric(vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    onPressed: onTap,
    icon: Icon(icon, size: 20),
    label: Text(label, style: const TextStyle(fontSize: 13)),
  );
}

class _SettingField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  const _SettingField({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    maxLines: maxLines,
    style: const TextStyle(color: Colors.white),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30),
      labelStyle: const TextStyle(color: Colors.white60),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF30363D)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF1565C0)),
      ),
      filled: true,
      fillColor: const Color(0xFF0D1117),
    ),
  );
}
