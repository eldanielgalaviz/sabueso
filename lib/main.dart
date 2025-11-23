import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart'; // ✅ Este archivo se crea con flutterfire configure
import 'firebase_service.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inicializar Firebase
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('✅ Firebase inicializado correctamente');
  } catch (e) {
    debugPrint('❌ Error al inicializar Firebase: $e');
  }
  
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'sabueso_channel',
      channelName: 'Sabueso Scanner',
      channelDescription: 'Servicio de escaneo en segundo plano',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
      icon: const NotificationIconData( // ✅ CORREGIDO
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions( // ✅ CORREGIDO
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
  int lastDeviceDetectionTime = 0;
  SharedPreferences? prefs;
  StreamSubscription<Position>? positionStream;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  Timer? vibrationTimer;
  Timer? autoSyncTimer;
  bool showPermissionsDialog = false;

  static const int directionUpdateInterval = 2000;
  static const int deviceTimeoutMs = 10000;
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
    vibrationTimer?.cancel();
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
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
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
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${locationHistory.length} ubicaciones sincronizadas'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error en sincronización: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Error al sincronizar con Firebase'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        isSyncing = false;
      });
    }
  }

  Future<void> startBackgroundService() async {
    await FlutterForegroundTask.startService(
      serviceId: 256, // ✅ AGREGADO
      notificationTitle: 'Sabueso',
      notificationText: 'Escaneando dispositivos...',
      notificationIcon: null, // ✅ AGREGADO
      notificationButtons: [], // ✅ AGREGADO
      callback: startBackgroundCallback,
    );
  }

  Future<void> checkPermissions() async {
    final bluetoothStatus = await Permission.bluetooth.status;
    final bluetoothScanStatus = await Permission.bluetoothScan.status;
    final bluetoothConnectStatus = await Permission.bluetoothConnect.status;
    final locationStatus = await Permission.location.status;

    if (!bluetoothStatus.isGranted ||
        !bluetoothScanStatus.isGranted ||
        !bluetoothConnectStatus.isGranted ||
        !locationStatus.isGranted) {
      await requestPermissions();
    }

    final isLocationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isLocationEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Por favor activa el GPS'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      await Geolocator.openLocationSettings();
    }
  }

  Future<void> requestPermissions() async {
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    if (statuses.values.any((status) => !status.isGranted)) {
      setState(() {
        showPermissionsDialog = true;
      });
    } else {
      await Permission.locationAlways.request();
    }
  }

  Future<void> saveLocationHistory() async {
    try {
      final jsonList = locationHistory.map((e) => e.toJson()).toList();
      await prefs?.setString('location_history', jsonEncode(jsonList));
      debugPrint('Guardado local exitoso: ${locationHistory.length} registros');
    } catch (e) {
      debugPrint('Error al guardar el historial local: $e');
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
        debugPrint('Historial local cargado: ${locationHistory.length} registros');
      }
    } catch (e) {
      debugPrint('Error al cargar el historial local: $e');
    }
  }

  Future<void> startScan() async {
    if (isScanning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El escaneo ya está en progreso')),
      );
      return;
    }

    try {
      setState(() {
        isScanning = true;
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName == 'Rastreador Sabueso') {
            addDeviceToList(result);
            lastDeviceDetectionTime = DateTime.now().millisecondsSinceEpoch;
          }
        }
      });

      await startLocationUpdates();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Iniciando escaneo...')),
        );
      }
    } catch (e) {
      debugPrint('Error al iniciar escaneo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al iniciar escaneo: $e')),
        );
      }
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      await scanSubscription?.cancel();
      await stopLocationUpdates();
      Vibration.cancel();

      setState(() {
        isScanning = false;
      });

      await syncWithFirebase();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escaneo detenido')),
        );
      }
    } catch (e) {
      debugPrint('Error al detener escaneo: $e');
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
    if (currentTime - lastDirectionUpdate < directionUpdateInterval) {
      return '';
    }

    lastDirectionUpdate = currentTime;
    String direction;

    if (rssi > previousRssi + 8) {
      direction = 'sigue avanzando';
    } else if (rssi < previousRssi - 8) {
      direction = 'Te estás alejando';
    } else if (rssi > previousRssi + 3) {
      direction = 'continúa';
    } else if (rssi < previousRssi - 3) {
      direction = 'Te alejas';
    } else {
      direction = 'Mantén esta dirección';
    }

    previousRssi = rssi;
    announceDirection(direction);
    return direction;
  }

  void vibrateBasedOnDistance(double distance) {
    if (!isScanning) {
      Vibration.cancel();
      return;
    }

    List<int> pattern;
    String message;

    if (distance <= 0.5) {
      pattern = [0, 200];
      message = 'Muy cerca';
    } else if (distance <= 1.0) {
      pattern = [0, 100, 100, 100];
      message = 'A un metro';
    } else if (distance <= 2.0) {
      pattern = [0, 200, 200, 200];
      message = 'A dos metros';
    } else if (distance <= 3.0) {
      pattern = [0, 300, 300, 300];
      message = 'A tres metros';
    } else if (distance <= 4.0) {
      pattern = [0, 400, 400, 400];
      message = 'A cuatro metros';
    } else if (distance <= 6.0) {
      pattern = [0, 500, 500, 500];
      message = 'A seis metros';
    } else {
      Vibration.cancel();
      return;
    }

    Vibration.vibrate(pattern: pattern, repeat: 0);
    announceDistance(message);
  }

  void announceDistance(String message) {
    flutterTts.speak(message);
  }

  void announceDirection(String direction) {
    flutterTts.speak(direction);
  }

  Future<void> startLocationUpdates() async {
    final isLocationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isLocationEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('El GPS está desactivado. Por favor actívalo.')),
        );
      }
      return;
    }

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Se requieren permisos de ubicación')),
        );
      }
      await requestPermissions();
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition();
      for (var device in devicesList) {
        final locationRecord = LocationRecord(
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          deviceAddress: device.address,
        );
        
        locationHistory.add(locationRecord);
        
        _firebaseService.saveLocation(locationRecord).catchError((e) {
          debugPrint('Error al guardar en Firebase: $e');
        });
      }

      positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        if (isScanning) {
          for (var device in devicesList) {
            final locationRecord = LocationRecord(
              latitude: position.latitude,
              longitude: position.longitude,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              deviceAddress: device.address,
            );
            
            setState(() {
              locationHistory.add(locationRecord);
            });
            
            _firebaseService.saveLocation(locationRecord).catchError((e) {
              debugPrint('Error al guardar en Firebase: $e');
            });
          }
          saveLocationHistory();
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Seguimiento de ubicación iniciado')),
        );
      }
    } catch (e) {
      debugPrint('Error al acceder a la ubicación: $e');
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
        title: Row(
          children: [
            const Text('Sabueso'),
            const SizedBox(width: 8),
            if (isSyncing)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            onPressed: syncWithFirebase,
            tooltip: 'Sincronizar con Firebase',
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showFirebaseInfo(context),
            tooltip: 'Info de Firebase',
          ),
        ],
      ),
      body: showPermissionsDialog
          ? _buildPermissionsDialog()
          : _buildMainContent(),
    );
  }

  void _showFirebaseInfo(BuildContext context) async {
    final stats = await _firebaseService.getLocationStats();
    final user = _firebaseService.currentUser;
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Información de Firebase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Usuario: ${user?.uid ?? "No autenticado"}'),
            const SizedBox(height: 8),
            Text('Total de ubicaciones: ${stats['totalLocations'] ?? 0}'),
            const SizedBox(height: 8),
            Text('Dispositivos rastreados: ${(stats['devices'] as List?)?.length ?? 0}'),
            const SizedBox(height: 8),
            Text('Ubicaciones locales: ${locationHistory.length}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionsDialog() {
    return Center(
      child: AlertDialog(
        title: const Text('Permisos Requeridos'),
        content: const Text(
          'Esta aplicación necesita permisos de Bluetooth y ubicación para funcionar. '
          'Por favor, otorga los permisos en la configuración de la aplicación.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                showPermissionsDialog = false;
              });
            },
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              await openAppSettings();
              setState(() {
                showPermissionsDialog = false;
              });
            },
            child: const Text('Ir a Configuración'),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          if (devicesList.isEmpty) ...[
            const SizedBox(height: 32),
            const Text(
              'No se encontraron dispositivos',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              height: 48,
              child: ElevatedButton(
                onPressed: () async {
                  await startScan();
                  await startLocationUpdates();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Iniciar Búsqueda'),
              ),
            ),
          ] else
            Expanded(
              child: ListView.builder(
                itemCount: devicesList.length,
                itemBuilder: (context, index) {
                  return DeviceCard(
                    device: devicesList[index],
                    locationHistory: locationHistory
                        .where((loc) =>
                            loc.deviceAddress == devicesList[index].address)
                        .toList(),
                    isScanning: isScanning,
                    onEditName: (newName) {
                      final device = devicesList[index];
                      setState(() {
                        devicesList[index] = device.copyWith(name: newName);
                      });
                      saveDeviceName(device.address, newName);
                    },
                    onStartScan: () async {
                      await startScan();
                      await startLocationUpdates();
                    },
                    onStopScan: () async {
                      await stopScan();
                      await stopLocationUpdates();
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class DeviceCard extends StatefulWidget {
  final DeviceData device;
  final List<LocationRecord> locationHistory;
  final bool isScanning;
  final Function(String) onEditName;
  final VoidCallback onStartScan;
  final VoidCallback onStopScan;

  const DeviceCard({
    super.key,
    required this.device,
    required this.locationHistory,
    required this.isScanning,
    required this.onEditName,
    required this.onStartScan,
    required this.onStopScan,
  });

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool isEditing = false;
  bool showLocationHistory = false;
  late TextEditingController nameController;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.device.name);
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 8,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isEditing) ...[
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Nombre del Dispositivo',
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    widget.onEditName(nameController.text);
                    setState(() {
                      isEditing = false;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Guardar'),
                ),
              ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 105,
                    height: 45,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          isEditing = true;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Editar'),
                    ),
                  ),
                ],
              ),
              Text(
                widget.device.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Distancia estimada: ${widget.device.distance.toStringAsFixed(2)} metros',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                'Dirección: ${widget.device.direction}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 40,
                child: ElevatedButton(
                  onPressed:
                      widget.isScanning ? widget.onStopScan : widget.onStartScan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        widget.isScanning ? Colors.red : Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    widget.isScanning ? 'Detener Escaneo' : 'Iniciar Escaneo',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    setState(() {
                      showLocationHistory = true;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    'Ver Historial de Ubicaciones (${widget.locationHistory.length})',
                  ),
                ),
              ),
              if (showLocationHistory)
                LocationHistoryDialog(
                  locationHistory: widget.locationHistory,
                  onDismiss: () {
                    setState(() {
                      showLocationHistory = false;
                    });
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class LocationHistoryDialog extends StatelessWidget {
  final List<LocationRecord> locationHistory;
  final VoidCallback onDismiss;

  const LocationHistoryDialog({
    super.key,
    required this.locationHistory,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Historial de Ubicaciones',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: locationHistory.length,
                  itemBuilder: (context, index) {
                    final record = locationHistory[index];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                        record.timestamp);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Fecha: ${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}',
                        ),
                        Text('Lat: ${record.latitude}'),
                        Text('Long: ${record.longitude}'),
                        TextButton(
                          onPressed: () async {
                            final url = Uri.parse(
                              'https://www.google.com/maps/search/?api=1&query=${record.latitude},${record.longitude}',
                            );
                            if (await canLaunchUrl(url)) {
                              await launchUrl(url);
                            }
                          },
                          child: const Text(
                            'Ver en Google Maps',
                            style: TextStyle(color: Colors.blue),
                          ),
                        ),
                        const Divider(),
                      ],
                    );
                  },
                ),
              ),
              TextButton(
                onPressed: onDismiss,
                child: const Text('Cerrar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

@pragma('vm:entry-point')
void startBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundTaskHandler());
}

class BackgroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async { // ✅ CORREGIDO
    debugPrint('Background service started');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async { // ✅ CORREGIDO
    debugPrint('Background task repeat event');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('Background service destroyed');
  }
  
  // ✅ MÉTODOS AGREGADOS (requeridos)
  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('Notification button pressed: $id');
  }
  
  @override
  void onNotificationPressed() {
    debugPrint('Notification pressed');
  }
}