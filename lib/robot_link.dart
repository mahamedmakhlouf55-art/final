import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

// The robot talks through the Nordic UART service (same one the serial Bluetooth apps use).
const String nusService = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const String nusRx = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'; // phone -> robot
const String nusTx = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E'; // robot -> phone

/// Bluetooth link to the robot. Every message is one line of text ending with a new line.
class RobotLink extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _retry;
  String? _deviceId;
  int _mtu = 23;
  bool _connecting = false;
  final List<int> _rxBuf = [];

  bool connected = false;
  bool wantConnected = false;
  String status = 'غير متصل';
  int? batteryPercent;
  double? batteryVolts;

  /// The robot we connected to last time (saved by the app controller).
  String? lastDeviceId;
  void Function(String id)? onDeviceSaved;

  final StreamController<String> _lines = StreamController<String>.broadcast();
  Stream<String> get lines => _lines.stream;

  QualifiedCharacteristic _char(String id, String characteristic) => QualifiedCharacteristic(
        serviceId: Uuid.parse(nusService),
        characteristicId: Uuid.parse(characteristic),
        deviceId: id,
      );

  void _setStatus(String s) {
    status = s;
    notifyListeners();
  }

  Future<void> _ensurePermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<String?> _scan() async {
    final done = Completer<String?>();
    late StreamSubscription<DiscoveredDevice> sub;
    sub = _ble.scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency).listen(
      (d) {
        final hasService = d.serviceUuids.contains(Uuid.parse(nusService));
        final looksLikeRobot = d.name.toLowerCase().contains('celyah');
        if ((hasService || looksLikeRobot) && !done.isCompleted) done.complete(d.id);
      },
      onError: (Object e) {
        if (!done.isCompleted) done.complete(null);
      },
    );
    final id = await done.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
    await sub.cancel();
    return id;
  }

  Future<void> connect() async {
    if (_connecting || connected) return;
    _connecting = true;
    wantConnected = true;
    _retry?.cancel();
    try {
      _setStatus('جاري طلب الأذونات...');
      await _ensurePermissions();
      String? id = lastDeviceId;
      if (id == null) {
        _setStatus('جاري البحث عن الروبوت...');
        id = await _scan();
      }
      if (id == null) {
        _connecting = false;
        _setStatus('مش لاقي الروبوت. اتأكد إنه شغال وقريب');
        _scheduleRetry();
        return;
      }
      final String deviceId = id;
      _setStatus('جاري الاتصال...');
      await _connSub?.cancel();
      _connSub = _ble
          .connectToDevice(id: deviceId, connectionTimeout: const Duration(seconds: 12))
          .listen(
        (u) {
          if (u.connectionState == DeviceConnectionState.connected) {
            _onConnected(deviceId);
          } else if (u.connectionState == DeviceConnectionState.disconnected) {
            _onDisconnected();
          }
        },
        onError: (Object e) => _onDisconnected(failed: true),
      );
    } catch (e) {
      _connecting = false;
      _setStatus('فشل الاتصال');
      _scheduleRetry();
    }
  }

  Future<void> _onConnected(String id) async {
    if (connected) return;
    _deviceId = id;
    try {
      try {
        _mtu = await _ble.requestMtu(deviceId: id, mtu: 185);
      } catch (_) {
        _mtu = 23;
      }
      await _notifySub?.cancel();
      _notifySub = _ble.subscribeToCharacteristic(_char(id, nusTx)).listen(_onBytes, onError: (Object e) {});
      connected = true;
      _connecting = false;
      lastDeviceId = id;
      onDeviceSaved?.call(id);
      _setStatus('متصل');
      await send('APP:1'); // tell the robot the app is in charge
      await send('BATQ'); // ask for the battery level (silently)
    } catch (e) {
      _setStatus('فشل: $e');
    }
  }

  void _onDisconnected({bool failed = false}) {
    final was = connected;
    connected = false;
    _connecting = false;
    _notifySub?.cancel();
    _notifySub = null;
    if (failed && !was) lastDeviceId = null; // the saved robot may be gone: search again next time
    _setStatus(was ? 'انقطع الاتصال' : (failed ? 'فشل الاتصال' : 'غير متصل'));
    if (wantConnected) _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 6), () {
      if (wantConnected && !connected) connect();
    });
  }

  Future<void> disconnect() async {
    wantConnected = false;
    _retry?.cancel();
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel(); // cancelling the connection stream disconnects
    _connSub = null;
    connected = false;
    _connecting = false;
    _setStatus('غير متصل');
  }

  /// Sends one line to the robot (long lines are split to fit the Bluetooth packet size).
  Future<void> send(String line) async {
    final id = _deviceId;
    if (!connected || id == null) return;
    final data = utf8.encode('$line\n');
    final chunk = (_mtu - 3) < 20 ? 20 : (_mtu - 3);
    var i = 0;
    while (i < data.length) {
      var end = i + chunk;
      if (end >= data.length) {
        end = data.length;
      } else {
        while (end > i + 1 && (data[end] & 0xC0) == 0x80) {
          end--; // never cut an Arabic letter in half
        }
      }
      try {
        await _ble.writeCharacteristicWithResponse(_char(id, nusRx), value: data.sublist(i, end));
      } catch (e) {
        _setStatus('تعذر الإرسال');
        return;
      }
      i = end;
    }
  }

  /// Face + subtitle on the robot screen.
  Future<void> say(String mood, String text) => send('SAY:$mood|${text.replaceAll('\n', ' ')}');

  /// listening | thinking | idle
  Future<void> sendState(String state) => send('STATE:$state');

  void _onBytes(List<int> d) {
    _rxBuf.addAll(d);
    while (true) {
      final nl = _rxBuf.indexOf(10);
      if (nl < 0) break;
      final lineBytes = _rxBuf.sublist(0, nl);
      _rxBuf.removeRange(0, nl + 1);
      final line = utf8.decode(lineBytes, allowMalformed: true).trim();
      if (line.isEmpty) continue;
      _handleLine(line);
      _lines.add(line);
    }
    if (_rxBuf.length > 4000) _rxBuf.clear();
  }

  void _handleLine(String l) {
    if (l.startsWith('BAT:')) {
      final p = l.substring(4).split(':');
      if (p.length >= 2) {
        batteryPercent = int.tryParse(p[0]);
        batteryVolts = double.tryParse(p[1]);
      } else {
        batteryPercent = null;
        batteryVolts = null;
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _lines.close();
    super.dispose();
  }
}
