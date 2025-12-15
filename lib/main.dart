import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Servicios
import 'services/firebase_service.dart';
import 'services/weather_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inicializar Firebase
  await Firebase.initializeApp();
  
  // Inicializar servicio en segundo plano
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'sabueso_channel',
      channelName: 'Sabueso Scanner',
      channelDescription: 'Servicio de escaneo en segundo plano',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      interval: 5000,
      isOnceEvent: false,
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
  final FirebaseService _firebaseService = FirebaseService();
  final WeatherService _weatherService = WeatherService();

  List<DeviceData> devicesList = [];
  List<LocationRecord> locationHistory = [];
  bool isScanning = false;
  bool isInitialized = false;
  Map<String, int> deviceRssiHistory = {}; // Historial de RSSI por dispositivo
  Map<String, int> lastDirectionUpdate = {}; // Último update de dirección por dispositivo
  int lastDeviceDetectionTime = 0;
  SharedPreferences? prefs;
  StreamSubscription<Position>? positionStream;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  Timer? periodicTimer;
  bool showPermissionsDialog = false;

  static const int directionUpdateInterval = 3000; // 3 segundos entre actualizaciones de voz
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
    periodicTimer?.cancel();
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
    try {
      prefs = await SharedPreferences.getInstance();
      await _firebaseService.initializeAuth();
      await loadLocationHistory();
      await initializeTTS();
      await checkPermissions();
      
      // Anunciar el clima al inicio
      await announceWeather();
      
      setState(() {
        isInitialized = true;
      });
      
      debugPrint('✅ Aplicación inicializada correctamente');
    } catch (e) {
      debugPrint('❌ Error en inicialización: $e');
    }
  }

  Future<void> initializeTTS() async {
    await flutterTts.setLanguage("es-MX"); // Español de México
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
    
    // Configurar callbacks para saber cuándo termina de hablar
    flutterTts.setCompletionHandler(() {
      debugPrint('🔊 TTS completado');
    });
  }

  Future<void> announceWeather() async {
    try {
      await speak('Obteniendo información del clima');
      
      final weather = await _weatherService.getCurrentWeatherByLocation();
      
      if (weather != null) {
        final announcement = _weatherService.generateWeatherAnnouncement(weather);
        await speak(announcement);
      } else {
        await speak('No se pudo obtener información del clima en este momento');
      }
    } catch (e) {
      debugPrint('❌ Error al anunciar clima: $e');
    }
  }

  Future<void> speak(String message) async {
    try {
      // Detener cualquier anuncio anterior
      await flutterTts.stop();
      // Pequeña pausa para evitar cortes
      await Future.delayed(const Duration(milliseconds: 100));
      await flutterTts.speak(message);
      debugPrint('🔊 Hablando: $message');
    } catch (e) {
      debugPrint('❌ Error en TTS: $e');
    }
  }

  Future<void> checkPermissions() async {
    final permissions = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    if (permissions.values.any((status) => !status.isGranted)) {
      setState(() {
        showPermissionsDialog = true;
      });
      await speak('Se requieren permisos para que la aplicación funcione correctamente');
    } else {
      await Permission.locationAlways.request();
      await speak('Permisos otorgados correctamente');
    }

    final isLocationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isLocationEnabled && mounted) {
      await speak('Por favor activa el GPS');
      await Geolocator.openLocationSettings();
    }
  }

  Future<void> saveLocationHistory() async {
    try {
      final jsonList = locationHistory.map((e) => e.toJson()).toList();
      await prefs?.setString('location_history', jsonEncode(jsonList));
      debugPrint('💾 Guardado local: ${locationHistory.length} registros');
    } catch (e) {
      debugPrint('❌ Error al guardar localmente: $e');
    }
  }

  Future<void> syncWithFirebase() async {
    try {
      if (locationHistory.isEmpty) return;
      
      // Subir ubicaciones en lotes
      List<Map<String, dynamic>> batch = [];
      for (var location in locationHistory) {
        batch.add(location.toJson());
        
        if (batch.length >= 50) {
          await _firebaseService.saveLocationsBatch(batch);
          batch.clear();
        }
      }
      
      if (batch.isNotEmpty) {
        await _firebaseService.saveLocationsBatch(batch);
      }
      
      debugPrint('☁️ Sincronización con Firebase completada');
    } catch (e) {
      debugPrint('❌ Error en sincronización: $e');
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
        debugPrint('📂 Historial cargado: ${locationHistory.length} registros');
      }
    } catch (e) {
      debugPrint('❌ Error al cargar historial: $e');
    }
  }

  Future<void> startScan() async {
    if (isScanning) {
      await speak('El escaneo ya está en progreso');
      return;
    }

    try {
      setState(() {
        isScanning = true;
        devicesList.clear(); // Limpiar lista al iniciar
        deviceRssiHistory.clear(); // Limpiar historial
      });

      await speak('Iniciando búsqueda de dispositivos');
      
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 0), // Escaneo continuo
        androidUsesFineLocation: true,
      );

      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName == 'Rastreador Sabueso') {
            updateDeviceData(result);
            lastDeviceDetectionTime = DateTime.now().millisecondsSinceEpoch;
          }
        }
      }, onError: (e) {
        debugPrint('❌ Error en escaneo: $e');
      });

      await startLocationUpdates();
      
      // Timer periódico para anuncios
      periodicTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        if (isScanning && devicesList.isNotEmpty) {
          checkAndAnnounceDevice();
        }
      });

      if (mounted) {
        await speak('Escaneo iniciado correctamente');
      }
    } catch (e) {
      debugPrint('❌ Error al iniciar escaneo: $e');
      if (mounted) {
        await speak('Error al iniciar escaneo');
      }
    }
  }

  void updateDeviceData(ScanResult result) {
    final deviceAddress = result.device.remoteId.toString();
    final rssi = result.rssi;
    final distance = calculateDistance(rssi);
    
    // Obtener o crear historial de RSSI
    if (!deviceRssiHistory.containsKey(deviceAddress)) {
      deviceRssiHistory[deviceAddress] = rssi;
    }
    
    final previousRssi = deviceRssiHistory[deviceAddress]!;
    final direction = getDirection(deviceAddress, rssi, previousRssi);
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
      
      deviceRssiHistory[deviceAddress] = rssi;
    });

    vibrateBasedOnDistance(distance);
  }

  void checkAndAnnounceDevice() {
    if (devicesList.isEmpty) return;
    
    final closestDevice = devicesList.reduce(
      (a, b) => a.distance < b.distance ? a : b
    );
    
    announceDevice(closestDevice);
  }

  void announceDevice(DeviceData device) {
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    final lastUpdate = lastDirectionUpdate[device.address] ?? 0;
    
    if (currentTime - lastUpdate >= directionUpdateInterval) {
      String message = 'Dispositivo ${device.name}. ';
      message += 'Distancia: ${device.distance.toStringAsFixed(1)} metros. ';
      if (device.direction.isNotEmpty) {
        message += device.direction;
      }
      
      speak(message);
      lastDirectionUpdate[device.address] = currentTime;
    }
  }

  double calculateDistance(int rssi) {
    const int txPower = -59;
    if (rssi == 0) return -1.0;
    
    final ratio = rssi * 1.0 / txPower;
    if (ratio < 1.0) {
      return pow(ratio, 10).toDouble();
    } else {
      return (0.89976 * pow(ratio, 7.7095) + 0.111).toDouble();
    }
  }

  String getDirection(String deviceAddress, int currentRssi, int previousRssi) {
    final rssiDiff = currentRssi - previousRssi;
    
    if (rssiDiff > 5) {
      return 'Te acercas rápidamente';
    } else if (rssiDiff > 2) {
      return 'Te acercas';
    } else if (rssiDiff < -5) {
      return 'Te alejas rápidamente';
    } else if (rssiDiff < -2) {
      return 'Te alejas';
    } else {
      return 'Mantén esta dirección';
    }
  }

  void vibrateBasedOnDistance(double distance) {
    if (!isScanning) {
      Vibration.cancel();
      return;
    }

    List<int> pattern;

    if (distance <= 0.5) {
      pattern = [0, 100, 50, 100]; // Vibración rápida y corta
    } else if (distance <= 1.0) {
      pattern = [0, 200, 100, 200];
    } else if (distance <= 2.0) {
      pattern = [0, 300, 200, 300];
    } else if (distance <= 3.0) {
      pattern = [0, 400, 300, 400];
    } else if (distance <= 5.0) {
      pattern = [0, 500, 400, 500];
    } else {
      Vibration.cancel();
      return;
    }

    Vibration.vibrate(pattern: pattern);
  }

  Future<void> startLocationUpdates() async {
    final isLocationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!isLocationEnabled) {
      await speak('El GPS está desactivado');
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition();
      
      positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) async {
        if (isScanning && devicesList.isNotEmpty) {
          for (var device in devicesList) {
            final record = LocationRecord(
              latitude: position.latitude,
              longitude: position.longitude,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              deviceAddress: device.address,
            );
            
            setState(() {
              locationHistory.add(record);
            });
            
            // Guardar en Firebase inmediatamente
            await _firebaseService.saveLocationToFirebase(
              latitude: position.latitude,
              longitude: position.longitude,
              deviceAddress: device.address,
              deviceName: device.name,
            );
          }
          
          // Guardar localmente cada 10 ubicaciones
          if (locationHistory.length % 10 == 0) {
            await saveLocationHistory();
          }
        }
      });

      await speak('Seguimiento de ubicación activado');
    } catch (e) {
      debugPrint('❌ Error al iniciar ubicación: $e');
      await speak('Error al acceder a la ubicación');
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      await scanSubscription?.cancel();
      await stopLocationUpdates();
      periodicTimer?.cancel();
      Vibration.cancel();
      await flutterTts.stop();

      setState(() {
        isScanning = false;
      });

      await syncWithFirebase();
      await speak('Escaneo detenido');
    } catch (e) {
      debugPrint('❌ Error al detener escaneo: $e');
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
    await speak('Nombre guardado: $newName');
  }

  @override
  Widget build(BuildContext context) {
    if (!isInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sabueso'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_sync),
            onPressed: () async {
              await speak('Sincronizando con la nube');
              await syncWithFirebase();
            },
          ),
          IconButton(
            icon: const Icon(Icons.wb_sunny),
            onPressed: () async {
              await announceWeather();
            },
          ),
        ],
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
                onPressed: startScan,
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
                    onStartScan: startScan,
                    onStopScan: stopScan,
                    onSpeak: speak,
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
  final Function(String) onSpeak;

  const DeviceCard({
    super.key,
    required this.device,
    required this.locationHistory,
    required this.isScanning,
    required this.onEditName,
    required this.onStartScan,
    required this.onStopScan,
    required this.onSpeak,
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      widget.device.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  SizedBox(
                    width: 105,
                    height: 45,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          isEditing = true;
                        });
                        widget.onSpeak('Modo de edición activado');
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
              const SizedBox(height: 8),
              Text(
                'Distancia: ${widget.device.distance.toStringAsFixed(1)} metros',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              Text(
                'Señal: ${widget.device.rssi} dBm',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.device.direction.isNotEmpty)
                Text(
                  'Dirección: ${widget.device.direction}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: widget.isScanning
                      ? widget.onStopScan
                      : widget.onStartScan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        widget.isScanning ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    widget.isScanning ? 'Detener Escaneo' : 'Iniciar Escaneo',
                    style: const TextStyle(fontSize: 16),
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
                    widget.onSpeak(
                        'Mostrando ${widget.locationHistory.length} ubicaciones guardadas');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    'Ver Historial (${widget.locationHistory.length})',
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
                  onSpeak: widget.onSpeak,
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
  final Function(String) onSpeak;

  const LocationHistoryDialog({
    super.key,
    required this.locationHistory,
    required this.onDismiss,
    required this.onSpeak,
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
                          'Fecha: ${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                        ),
                        Text('Lat: ${record.latitude.toStringAsFixed(6)}'),
                        Text('Long: ${record.longitude.toStringAsFixed(6)}'),
                        TextButton(
                          onPressed: () async {
                            final url = Uri.parse(
                              'https://www.google.com/maps/search/?api=1&query=${record.latitude},${record.longitude}',
                            );
                            if (await canLaunchUrl(url)) {
                              await launchUrl(url);
                              onSpeak('Abriendo mapa en el navegador');
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
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('🔄 Servicio en segundo plano iniciado');
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    debugPrint('⏰ Evento periódico del servicio');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('🛑 Servicio en segundo plano detenido');
  }
}