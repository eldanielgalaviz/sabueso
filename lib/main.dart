import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'sabueso_channel',
      channelName: 'Sabueso Scanner',
      channelDescription: 'Servicio de escaneo en segundo plano',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: true,
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

class LocationRecord {
  final double latitude;
  final double longitude;
  final int timestamp;
  final String deviceAddress;

  LocationRecord({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.deviceAddress,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
        'deviceAddress': deviceAddress,
      };

  factory LocationRecord.fromJson(Map<String, dynamic> json) => LocationRecord(
        latitude: json['latitude'],
        longitude: json['longitude'],
        timestamp: json['timestamp'],
        deviceAddress: json['deviceAddress'],
      );
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


  List<DeviceData> devicesList = [];
  List<LocationRecord> locationHistory = [];
  bool isScanning = false;
  int previousRssi = 0;
  int lastDirectionUpdate = 0;
  int lastDeviceDetectionTime = 0;
  SharedPreferences? prefs;
  StreamSubscription<Position>? positionStream;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  Timer? vibrationTimer;
  bool showPermissionsDialog = false;
  Map<String, int> deviceRssiHistory = {}; // Historial de RSSI por dispositivo
  Map<String, int> lastAnnouncementTime = {}; // Control de anuncios por dispositivo

  static const int directionUpdateInterval = 500; // Medio segundo
  static const int deviceTimeoutMs = 10000;

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
    flutterTts.stop();
    saveLocationHistory();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      saveLocationHistory();
    }
  }

  Future<void> initializeApp() async {
    prefs = await SharedPreferences.getInstance();
    await loadLocationHistory();
    await initializeTTS();
    await checkPermissions();
    await startBackgroundService();
    // ELIMINADO: No iniciar escaneo automáticamente
  }

  Future<void> initializeTTS() async {
    await flutterTts.setLanguage("es-ES");
    await flutterTts.setSpeechRate(0.7); // Más rápido
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.1); // Tono ligeramente más alto para mejor claridad
  }



  Future<void> startBackgroundService() async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Sabueso',
      notificationText: 'Escaneando dispositivos...',
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
      debugPrint('Guardado exitoso: ${locationHistory.length} registros');
    } catch (e) {
      debugPrint('Error al guardar el historial: $e');
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
        debugPrint('Historial cargado: ${locationHistory.length} registros');
      }
    } catch (e) {
      debugPrint('Error al cargar el historial: $e');
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

      // Función interna para realizar escaneo ultra rápido
      Future<void> performScan() async {
        if (!isScanning) return;
        
        try {
          // Escaneo MUY corto (200ms) para actualizaciones casi instantáneas
          await FlutterBluePlus.startScan(timeout: const Duration(milliseconds: 200));
          
          // Esperar muy poco antes de reiniciar
          await Future.delayed(const Duration(milliseconds: 50));
          
          // Reiniciar el escaneo inmediatamente si sigue activo
          if (isScanning) {
            performScan(); // Recursión para escaneo continuo
          }
        } catch (e) {
          debugPrint('Error en ciclo de escaneo: $e');
          if (isScanning) {
            // Reintentar inmediatamente
            await Future.delayed(const Duration(milliseconds: 50));
            performScan();
          }
        }
      }

      // Escuchar resultados del escaneo continuamente
      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName == 'Rastreador Sabueso') {
            addDeviceToList(result);
            lastDeviceDetectionTime = DateTime.now().millisecondsSinceEpoch;
          }
        }
      });

      // Iniciar el ciclo de escaneo ultra rápido
      performScan();

      await startLocationUpdates();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escaneo ultra rápido iniciado')),
        );
      }
    } catch (e) {
      debugPrint('Error al iniciar escaneo: $e');
      setState(() {
        isScanning = false;
      });
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
    
    // Guardar RSSI anterior específico del dispositivo
    final previousDeviceRssi = deviceRssiHistory[deviceAddress] ?? rssi;
    deviceRssiHistory[deviceAddress] = rssi;
    
    final direction = getDirectionForDevice(rssi, previousDeviceRssi, deviceAddress);
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

    vibrateBasedOnDistance(distance, deviceAddress: deviceAddress);
  }

  double calculateDistance(int rssi) {
    // Ajustado para mejor precisión con ESP32
    // txPower es la potencia de transmisión a 1 metro
    const int txPower = -59;
    const double n = 2.0; // Factor de propagación (2.0 = espacio libre)
    
    if (rssi == 0) {
      return -1.0; // Distancia desconocida
    }
    
    // Fórmula: d = 10 ^ ((txPower - rssi) / (10 * n))
    final double ratio = (txPower - rssi) / (10.0 * n);
    return pow(10.0, ratio).toDouble();
  }

  String getDirectionForDevice(int rssi, int previousDeviceRssi, String deviceAddress) {
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    
    // Verificar si ha pasado suficiente tiempo para actualizar
    if (currentTime - lastDirectionUpdate < directionUpdateInterval) {
      return '';
    }

    lastDirectionUpdate = currentTime;
    String direction;

    // Más sensible a cambios pequeños
    final rssiDiff = rssi - previousDeviceRssi;
    
    if (rssiDiff > 5) {
      direction = 'Acercándote, continúa';
    } else if (rssiDiff < -5) {
      direction = 'Te alejas, regresa';
    } else if (rssiDiff > 2) {
      direction = 'Bien, sigue así';
    } else if (rssiDiff < -2) {
      direction = 'Cambia de dirección';
    } else if (rssiDiff >= -1 && rssiDiff <= 1) {
      direction = 'Muy cerca';
    } else {
      direction = 'Mantén rumbo';
    }

    previousRssi = rssi;
    announceDirection(direction, deviceAddress: deviceAddress);
    return direction;
  }

  void vibrateBasedOnDistance(double distance, {String? deviceAddress}) {
    if (!isScanning) {
      Vibration.cancel();
      return;
    }

    List<int> pattern;
    String message;

    if (distance <= 0.5) {
      pattern = [0, 50, 50, 50]; // Vibración muy rápida
      message = 'Muy cerca';
    } else if (distance <= 1.0) {
      pattern = [0, 100, 100, 100];
      message = 'Un metro';
    } else if (distance <= 2.0) {
      pattern = [0, 150, 150, 150];
      message = 'Dos metros';
    } else if (distance <= 3.0) {
      pattern = [0, 200, 200, 200];
      message = 'Tres metros';
    } else if (distance <= 4.0) {
      pattern = [0, 250, 250, 250];
      message = 'Cuatro metros';
    } else if (distance <= 6.0) {
      pattern = [0, 300, 300, 300];
      message = 'Seis metros';
    } else if (distance <= 10.0) {
      pattern = [0, 400, 400, 400];
      message = 'Diez metros';
    } else {
      // No vibrar si está muy lejos
      return;
    }

    // Vibrar con patrón corto para respuesta rápida
    Vibration.vibrate(pattern: pattern);
    announceDistance(message, deviceAddress: deviceAddress);
  }

  void announceDistance(String message, {String? deviceAddress}) {
    // Control de tiempo para evitar spam de voz
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    final key = deviceAddress ?? 'general';
    final lastTime = lastAnnouncementTime[key] ?? 0;
    
    // Anunciar cada medio segundo para actualizaciones rápidas
    if (currentTime - lastTime >= 500) {
      flutterTts.speak(message);
      lastAnnouncementTime[key] = currentTime;
    }
  }

  void announceDirection(String direction, {String? deviceAddress}) {
    // Control de tiempo para evitar spam de voz
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    final key = deviceAddress ?? 'general_direction';
    final lastTime = lastAnnouncementTime[key] ?? 0;
    
    // Anunciar cada medio segundo para actualizaciones rápidas
    if (currentTime - lastTime >= 500) {
      flutterTts.speak(direction);
      lastAnnouncementTime[key] = currentTime;
    }
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
        locationHistory.add(LocationRecord(
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          deviceAddress: device.address,
        ));
      }

      positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        if (isScanning) {
          for (var device in devicesList) {
            setState(() {
              locationHistory.add(LocationRecord(
                latitude: position.latitude,
                longitude: position.longitude,
                timestamp: DateTime.now().millisecondsSinceEpoch,
                deviceAddress: device.address,
              ));
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

  void checkDeviceTimeout() {
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    if (currentTime - lastDeviceDetectionTime > deviceTimeoutMs) {
      // showOutOfRangeNotification();
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sabueso'),
      ),
      body: showPermissionsDialog
          ? _buildPermissionsDialog()
          : _buildMainContent(),
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
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('Background service started');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    debugPrint('Background task repeat event');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('Background service destroyed');
  }
}
