import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'firebase_service.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('✅ Firebase inicializado correctamente');
  } catch (e) {
    debugPrint('❌ Error al inicializar Firebase: $e');
  }
  
  // ✅ Configuración correcta para flutter_foreground_task v9.1.0
  // En la v9.1.0, iconData fue REMOVIDO de AndroidNotificationOptions
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'sabueso_channel',
      channelName: 'Sabueso Scanner',
      channelDescription: 'Servicio de escaneo en segundo plano',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
      onlyAlertOnce: true, // Evita alertas múltiples
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sabueso',
      theme: ThemeData(
        primarySwatch: Colors.grey,
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class DeviceData {
  final String name;
  final String address;
  final int rssi;
  final double distance;
  final String direction;

  DeviceData({
    required this.name,
    required this.address,
    required this.rssi,
    required this.distance,
    required this.direction,
  });

  DeviceData copyWith({
    String? name,
    String? address,
    int? rssi,
    double? distance,
    String? direction,
  }) {
    return DeviceData(
      name: name ?? this.name,
      address: address ?? this.address,
      rssi: rssi ?? this.rssi,
      distance: distance ?? this.distance,
      direction: direction ?? this.direction,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final FlutterTts flutterTts = FlutterTts();
  final FirebaseLocationService _firebaseService = FirebaseLocationService();

  List<DeviceData> devicesList = [];
  List<LocationRecord> locationHistory = [];
  bool isScanning = false;
  bool isSyncing = false;
  int previousRssi = 0;
  int lastDirectionUpdate = 0;
  SharedPreferences? prefs;
  StreamSubscription<Position>? positionStream;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  Timer? autoSyncTimer;
  bool showPermissionsDialog = false;

  static const int directionUpdateInterval = 2000;
  static const int autoSyncIntervalMinutes = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopScan();
    stopLocationUpdates();
    autoSyncTimer?.cancel();
    flutterTts.stop();
    saveLocationHistory();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      saveLocationHistory();
      syncWithFirebase();
    }
  }

  Future<void> initializeApp() async {
    prefs = await SharedPreferences.getInstance();
    await loadLocationHistory();
    await initializeTTS();
    await checkPermissions();
    await startBackgroundService();
    
    startAutoSync();
    await syncWithFirebase();
    
    await Future.delayed(const Duration(milliseconds: 1));
    if (mounted) {
      await startScan();
      await Future.delayed(const Duration(milliseconds: 1));
      await stopScan();
    }
  }

  Future<void> initializeTTS() async {
    await flutterTts.setLanguage("es-ES");
    await flutterTts.setSpeechRate(0.5);
  }

  void startAutoSync() {
    autoSyncTimer = Timer.periodic(
      const Duration(minutes: autoSyncIntervalMinutes),
      (_) => syncWithFirebase(),
    );
  }

  Future<void> syncWithFirebase() async {
    if (isSyncing || locationHistory.isEmpty) return;

    setState(() {
      isSyncing = true;
    });

    try {
      await _firebaseService.syncLocalLocations(locationHistory);
      
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ ${locationHistory.length} ubicaciones sincronizadas'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint('Error en sincronización: $e');
      
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Error al sincronizar con Firebase'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSyncing = false;
        });
      }
    }
  }

  Future<void> startBackgroundService() async {
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Sabueso',
      notificationText: 'Escaneando dispositivos...',
      callback: startBackgroundCallback,
    );
  }

  Future<void> checkPermissions() async {
    // ✅ CORRECCIÓN: Verificar y usar el resultado de los permisos
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    // Verificar si algún permiso fue denegado
    bool allGranted = statuses.values.every(
      (status) => status == PermissionStatus.granted
    );

    if (!allGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Algunos permisos no fueron concedidos'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }

    final isLocationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isLocationEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Por favor activa el GPS')),
        );
      }
      await Geolocator.openLocationSettings();
    }
  }

  Future<void> saveLocationHistory() async {
    try {
      final jsonList = locationHistory.map((e) => e.toJson()).toList();
      await prefs?.setString('location_history', jsonEncode(jsonList));
    } catch (e) {
      debugPrint('Error al guardar historial: $e');
    }
  }

  Future<void> loadLocationHistory() async {
    try {
      final json = prefs?.getString('location_history');
      if (json != null) {
        final List<dynamic> decoded = jsonDecode(json);
        setState(() {
          locationHistory =
              decoded.map((e) => LocationRecord.fromJson(e)).toList();
        });
      }
    } catch (e) {
      debugPrint('Error al cargar historial: $e');
    }
  }

  Future<void> startScan() async {
    if (isScanning) return;

    try {
      setState(() => isScanning = true);

      // Usando FlutterBluePlus actualizado
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName == 'Rastreador Sabueso') {
            addDeviceToList(result);
          }
        }
      });

      await startLocationUpdates();
    } catch (e) {
      debugPrint('Error scan: $e');
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      await scanSubscription?.cancel();
      await stopLocationUpdates();
      Vibration.cancel();
      if (mounted) setState(() => isScanning = false);
      await syncWithFirebase();
    } catch (e) {
      debugPrint('Error stop scan: $e');
    }
  }

  void addDeviceToList(ScanResult result) {
    final deviceAddress = result.device.remoteId.toString();
    final rssi = result.rssi;
    final distance = calculateDistance(rssi);
    final direction = getDirection(rssi);
    final savedName = getSavedDeviceName(deviceAddress);

    final device = DeviceData(
      name: savedName,
      address: deviceAddress,
      rssi: rssi,
      distance: distance,
      direction: direction,
    );

    setState(() {
      final existingIndex =
          devicesList.indexWhere((d) => d.address == deviceAddress);
      if (existingIndex != -1) {
        devicesList[existingIndex] = device;
      } else {
        devicesList.add(device);
      }
    });

    vibrateBasedOnDistance(distance);
  }

  double calculateDistance(int rssi) {
    const int txPower = -59;
    return pow(10.0, (txPower - rssi) / 20.0).toDouble();
  }

  String getDirection(int rssi) {
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    if (currentTime - lastDirectionUpdate < directionUpdateInterval) return '';

    lastDirectionUpdate = currentTime;
    String direction;

    if (rssi > previousRssi + 5) {
      direction = 'Acercándose';
    } else if (rssi < previousRssi - 5) {
      direction = 'Alejándose';
    } else {
      direction = 'Estable';
    }

    previousRssi = rssi;
    return direction;
  }

  void vibrateBasedOnDistance(double distance) {
    if (!isScanning) return;
    // Lógica de vibración simplificada para evitar errores
    if (distance < 2.0) {
       Vibration.vibrate(duration: 500);
       flutterTts.speak("Muy cerca");
    }
  }

  Future<void> startLocationUpdates() async {
    try {
      positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        if (isScanning) {
          for (var device in devicesList) {
            final rec = LocationRecord(
              latitude: position.latitude,
              longitude: position.longitude,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              deviceAddress: device.address,
            );
            locationHistory.add(rec);
            _firebaseService.saveLocation(rec);
          }
        }
      });
    } catch (e) {
      debugPrint("Error GPS: $e");
    }
  }

  Future<void> stopLocationUpdates() async {
    await positionStream?.cancel();
    positionStream = null;
  }

  String getSavedDeviceName(String deviceAddress) {
    return prefs?.getString(deviceAddress) ?? 'Rastreador Sabueso';
  }

  Future<void> saveDeviceName(String deviceAddress, String newName) async {
    await prefs?.setString(deviceAddress, newName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sabueso'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            onPressed: syncWithFirebase,
          ),
          IconButton(
            icon: const Icon(Icons.info),
            onPressed: () => _showFirebaseInfo(context),
          ),
        ],
      ),
      body: _buildMainContent(),
    );
  }

  void _showFirebaseInfo(BuildContext context) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Firebase Info'),
        content: Text('Ubicaciones guardadas localmente: ${locationHistory.length}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), 
            child: const Text('OK')
          )
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        if (devicesList.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: ElevatedButton(
              onPressed: () {
                startScan();
              }, 
              child: const Text("Buscar Dispositivos")
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: devicesList.length,
            itemBuilder: (context, index) {
              final device = devicesList[index];
              return ListTile(
                title: Text(device.name),
                subtitle: Text("${device.distance.toStringAsFixed(1)}m - ${device.direction}"),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () {
                    // Mostrar diálogo para editar el nombre
                    _showEditNameDialog(device.address, device.name);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showEditNameDialog(String deviceAddress, String currentName) {
    final TextEditingController controller = TextEditingController(text: currentName);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar nombre del dispositivo'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Nombre',
            hintText: 'Ingresa un nuevo nombre',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                saveDeviceName(deviceAddress, newName);
                setState(() {
                  final index = devicesList.indexWhere((d) => d.address == deviceAddress);
                  if (index != -1) {
                    devicesList[index] = devicesList[index].copyWith(name: newName);
                  }
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}

// Manejador de tareas en segundo plano
@pragma('vm:entry-point')
void startBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundTaskHandler());
}

class BackgroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('Background service started');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // Código que se repite cada 5 segundos
    debugPrint('Background task executing...');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, [Object? sendPort]) async {
    debugPrint('Background service destroyed');
  }
  
  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('Notification button pressed: $id');
  }
  
  @override
  void onNotificationPressed() {
    debugPrint('Notification pressed');
  }
}