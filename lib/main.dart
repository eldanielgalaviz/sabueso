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
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

class ESP32Config {
  static const String deviceName = "Rastreador Sabueso";
  static const String serviceUUID = "12345678-1234-1234-1234-123456789abc";
  static const String characteristicUUID = "87654321-4321-4321-4321-cba987654321";
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

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
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
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
  final String? documentId;

  LocationRecord({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.deviceAddress,
    this.documentId,
  });

  // Para Firestore (con serverTimestamp)
  Map<String, dynamic> toFirestore() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
        'deviceAddress': deviceAddress,
        'createdAt': FieldValue.serverTimestamp(),
      };

  // Para SharedPreferences (sin FieldValue)
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

  factory LocationRecord.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data()!;
    return LocationRecord(
      latitude: data['latitude'],
      longitude: data['longitude'],
      timestamp: data['timestamp'],
      deviceAddress: data['deviceAddress'],
      documentId: snapshot.id,
    );
  }
}

class DeviceData {
  final String name;
  final String address;
  final int rssi;
  final double distance;
  final String direction;
  final bool isESP32Sabueso;

  DeviceData({
    required this.name,
    required this.address,
    required this.rssi,
    required this.distance,
    required this.direction,
    this.isESP32Sabueso = false,
  });

  DeviceData copyWith({
    String? name,
    String? address,
    int? rssi,
    double? distance,
    String? direction,
    bool? isESP32Sabueso,
  }) {
    return DeviceData(
      name: name ?? this.name,
      address: address ?? this.address,
      rssi: rssi ?? this.rssi,
      distance: distance ?? this.distance,
      direction: direction ?? this.direction,
      isESP32Sabueso: isESP32Sabueso ?? this.isESP32Sabueso,
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
  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  List<DeviceData> devicesList = [];
  List<LocationRecord> locationHistory = [];
  bool isScanning = false;
  bool isScanningForESP32 = false;
  bool isFirestoreConnected = false;
  
  List<int> rssiHistory = []; 
  int lastRssiUpdate = 0;
  double currentDistance = 0.0;
  String currentDirection = 'Calculando...';
  
  int updateCounter = 0; 
  DateTime? lastUpdateTime; 
  
  int lastDeviceDetectionTime = 0;
  SharedPreferences? prefs;
  StreamSubscription<Position>? positionStream;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  Timer? vibrationTimer;
  Timer? scanRestartTimer; 
  bool showPermissionsDialog = false;
  String? activeDeviceAddress;

  static const int deviceTimeoutMs = 10000;
  static const int rssiHistorySize = 5; 

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
    scanRestartTimer?.cancel(); 
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

  Future<void> testFirestoreConnection() async {
    try {
      await firestore.collection('_test_connection').add({
        'test': 'Prueba de conexión',
        'timestamp': FieldValue.serverTimestamp(),
      });
      
      setState(() {
        isFirestoreConnected = true;
      });
      
      debugPrint('✅ Firebase conectado exitosamente');
      
      final testDocs = await firestore.collection('_test_connection').get();
      for (var doc in testDocs.docs) {
        await doc.reference.delete();
      }
      
    } catch (e) {
      setState(() {
        isFirestoreConnected = false;
      });
      debugPrint('❌ Error de conexión a Firebase: $e');
    }
  }

  Future<bool> saveLocationToFirestore(LocationRecord record) async {
    try {
      await firestore.collection('ubicaciones').add(record.toFirestore());
      debugPrint('✅ Guardado en Firestore: ${record.latitude}, ${record.longitude}');
      return true;
    } catch (e) {
      debugPrint('❌ Error al guardar en Firestore: $e');
      return false;
    }
  }

  Future<String> fetchWeatherAndAnnounce(Position position) async {
    const apiKey = '5318481fd8a6f506fd7319722062cae3';
    final lat = position.latitude;
    final lon = position.longitude;
    String city = 'tu ubicación';
    String weatherMessage;

    try {
      List<geocoding.Placemark> placemarks =
          await geocoding.placemarkFromCoordinates(lat, lon);
      if (placemarks.isNotEmpty) {
        city = placemarks.first.locality ?? placemarks.first.name ?? city;
      }

      final url = Uri.parse(
          'https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=es');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final description = data['weather'][0]['description'];
        final temp = data['main']['temp'].toStringAsFixed(0);
        weatherMessage =
            'Bienvenido a Sabueso. El pronóstico del clima en $city es de $temp grados Celsius con $description.';
      } else {
        weatherMessage =
            'Bienvenido a Sabueso. No se pudo obtener el pronóstico del clima para $city.';
      }
    } catch (e) {
      debugPrint('Error al obtener el clima: $e');
      weatherMessage = 'Bienvenido a Sabueso.';
    }

    await flutterTts.speak(weatherMessage);
    return weatherMessage;
  }

  Future<void> searchForESP32Sabueso() async {
    setState(() {
      isScanningForESP32 = true;
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      scanSubscription =
          FlutterBluePlus.scanResults.listen((List<ScanResult> results) {
        for (ScanResult result in results) {
          if (result.device.platformName == ESP32Config.deviceName) {
            debugPrint(
                'ESP32 Sabueso encontrado: ${result.device.remoteId}');

            final exists = devicesList
                .any((d) => d.address == result.device.remoteId.toString());

            if (!exists) {
              final newDevice = DeviceData(
                name: ESP32Config.deviceName,
                address: result.device.remoteId.toString(),
                rssi: result.rssi,
                distance: calculateDistance(result.rssi),
                direction: 'Dispositivo encontrado',
                isESP32Sabueso: true,
              );

              setState(() {
                devicesList.insert(0, newDevice);
              });

              saveDevices();
              flutterTts.speak('Rastreador Sabueso encontrado');
              FlutterBluePlus.stopScan();
              setState(() {
                isScanningForESP32 = false;
              });

              return;
            }
          }
        }
      });

      await Future.delayed(const Duration(seconds: 10));
      await FlutterBluePlus.stopScan();

      setState(() {
        isScanningForESP32 = false;
      });

      if (!devicesList.any((d) => d.isESP32Sabueso)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No se encontró el Rastreador Sabueso ESP32. Asegúrate de que esté encendido.'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error al buscar ESP32: $e');
      setState(() {
        isScanningForESP32 = false;
      });
    }
  }

  Future<void> initializeApp() async {
    prefs = await SharedPreferences.getInstance();
    await loadLocationHistory();
    await loadDevices();
    await initializeTTS();
    await checkPermissions();
    await testFirestoreConnection();

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );
      await fetchWeatherAndAnnounce(position);
    } catch (e) {
      debugPrint('No se pudo obtener el clima: $e');
    }
  }

  Future<void> initializeTTS() async {
    await flutterTts.setLanguage('es-ES');
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
  }

  Future<void> checkPermissions() async {
    final bluetoothStatus = await Permission.bluetoothScan.status;
    final locationStatus = await Permission.locationWhenInUse.status;
    final notificationStatus = await Permission.notification.status;

    if (!bluetoothStatus.isGranted ||
        !locationStatus.isGranted ||
        !notificationStatus.isGranted) {
      setState(() {
        showPermissionsDialog = true;
      });
    }
  }

  Future<void> requestPermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
    await Permission.notification.request();

    setState(() {
      showPermissionsDialog = false;
    });
  }

  double calculateDistance(int rssi) {
    const int txPower = -59;
    if (rssi == 0) return -1.0;
    double ratio = rssi * 1.0 / txPower;
    if (ratio < 1.0) {
      return pow(ratio, 10).toDouble();
    } else {
      return (0.89976) * pow(ratio, 7.7095) + 0.111;
    }
  }

  String calculateDirectionImproved(int currentRssi) {
    final now = DateTime.now().millisecondsSinceEpoch;

    rssiHistory.add(currentRssi);
    
    if (rssiHistory.length > rssiHistorySize) {
      rssiHistory.removeAt(0);
    }
    
    if (rssiHistory.length < 3) {
      return 'Calibrando...';
    }
    
    final int mid = rssiHistory.length ~/ 2;
    final double firstHalf = rssiHistory.sublist(0, mid).reduce((a, b) => a + b) / mid;
    final double secondHalf = rssiHistory.sublist(mid).reduce((a, b) => a + b) / (rssiHistory.length - mid);
    
    final double trend = secondHalf - firstHalf;
    
    String direction;
    if (trend > 3) {
      direction = 'Te estás acercando ↑';
    } else if (trend < -3) {
      direction = 'Te estás alejando ↓';
    } else {
      direction = 'Distancia estable →';
    }
    
    lastRssiUpdate = now;
    return direction;
  }

  void handleVibrationProportional(double distance) {
    vibrationTimer?.cancel();

    if (distance < 0) return;

    int duration;
    int amplitude;
    int intervalMs;

    if (distance < 0.5) {
      duration = 200;
      amplitude = 255; 
      intervalMs = 100; 
    } else if (distance < 1.0) {
      duration = 150;
      amplitude = 240;
      intervalMs = 200;
    } else if (distance < 2.0) {
      duration = 120;
      amplitude = 220;
      intervalMs = 400;
    } else if (distance < 3.0) {
      duration = 100;
      amplitude = 200;
      intervalMs = 600;
    } else if (distance < 5.0) {
      duration = 80;
      amplitude = 160;
      intervalMs = 1000;
    } else if (distance < 8.0) {
      duration = 60;
      amplitude = 120;
      intervalMs = 1500;
    } else if (distance < 12.0) {
      duration = 40;
      amplitude = 80;
      intervalMs = 2000;
    } else {
      duration = 30;
      amplitude = 50;
      intervalMs = 3000;
    }

    Vibration.vibrate(duration: duration, amplitude: amplitude);
    
    vibrationTimer = Timer(Duration(milliseconds: intervalMs), () {
      handleVibrationProportional(distance);
    });
  }

  Future<void> startScan(String deviceAddress) async {
    if (isScanning) return;

    rssiHistory.clear();
    updateCounter = 0;
    scanRestartTimer?.cancel();

    setState(() {
      isScanning = true;
      activeDeviceAddress = deviceAddress;
    });

    debugPrint('Iniciando escaneo con auto-reinicio para: $deviceAddress');

    try {
      scanRestartTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
        if (!isScanning) {
          timer.cancel();
          return;
        }

        debugPrint('Auto-reiniciando escaneo para actualizar RSSI...');
        
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 100));
        
        await FlutterBluePlus.startScan();
        debugPrint('Escaneo reiniciado');
      });

      await FlutterBluePlus.startScan();
      debugPrint('Escaneo BLE iniciado (con auto-reinicio cada 5s)');

      scanSubscription =
          FlutterBluePlus.scanResults.listen((List<ScanResult> results) {
        debugPrint('Escaneando... ${results.length} dispositivos detectados');
        
        for (ScanResult result in results) {
          if (result.device.remoteId.toString() == deviceAddress) {
            final distance = calculateDistance(result.rssi);
            final direction = calculateDirectionImproved(result.rssi);

            updateCounter++;
            lastUpdateTime = DateTime.now();

            debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
            debugPrint('RSSI actualizado: ${result.rssi}');
            debugPrint('Distancia calculada: ${distance.toStringAsFixed(2)}m');
            debugPrint('Dirección: $direction');
            debugPrint('Histórico RSSI: $rssiHistory');
            debugPrint('Actualización #$updateCounter');
            debugPrint('Timestamp: ${lastUpdateTime?.toString().substring(11, 19)}');
            debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

            if (mounted) {
              setState(() {
                currentDistance = distance;
                currentDirection = direction;
                
                devicesList = List.from(devicesList.map((device) {
                  if (device.address == deviceAddress) {
                    return DeviceData(
                      name: device.name,
                      address: device.address,
                      rssi: result.rssi,
                      distance: distance,
                      direction: direction,
                      isESP32Sabueso: device.isESP32Sabueso,
                    );
                  }
                  return device;
                }));
              });
              debugPrint('setState() ejecutado - UI actualizado');
            }

            handleVibrationProportional(distance);
            debugPrint('Vibrando: distancia ${distance.toStringAsFixed(2)}m');
            
            lastDeviceDetectionTime = DateTime.now().millisecondsSinceEpoch;
          }
        }
      });

      startLocationUpdates(deviceAddress);
    } catch (e) {
      debugPrint('Error al iniciar escaneo: $e');
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      scanSubscription?.cancel();
      vibrationTimer?.cancel();
      scanRestartTimer?.cancel(); 
      rssiHistory.clear();
      setState(() {
        isScanning = false;
        activeDeviceAddress = null;
      });
      debugPrint('Escaneo detenido completamente');
    } catch (e) {
      debugPrint('Error al detener escaneo: $e');
    }
  }

  void startLocationUpdates(String deviceAddress) {
    stopLocationUpdates();

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastDeviceDetectionTime < deviceTimeoutMs) {
        final record = LocationRecord(
          latitude: position.latitude,
          longitude: position.longitude,
          timestamp: now,
          deviceAddress: deviceAddress,
        );

        final savedToFirestore = await saveLocationToFirestore(record);
        
        if (savedToFirestore && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: const [
                  Icon(Icons.cloud_done, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Text('Guardado en Firebase'),
                ],
              ),
              duration: const Duration(seconds: 1),
              backgroundColor: Colors.green,
            ),
          );
        }

        setState(() {
          locationHistory.add(record);
        });

        saveLocationHistory();
      }
    });
  }

  void stopLocationUpdates() {
    positionStream?.cancel();
  }

  Future<void> saveLocationHistory() async {
    if (prefs == null) return;
    final jsonData =
        locationHistory.map((record) => jsonEncode(record.toJson())).toList();
    await prefs!.setStringList('locationHistory', jsonData);
  }

  Future<void> loadLocationHistory() async {
    if (prefs == null) return;
    final jsonData = prefs!.getStringList('locationHistory') ?? [];
    setState(() {
      locationHistory = jsonData
          .map((json) => LocationRecord.fromJson(jsonDecode(json)))
          .toList();
    });
  }

  Future<void> addDevice(String name, String address, {bool isESP32 = false}) async {
    final newDevice = DeviceData(
      name: name,
      address: address,
      rssi: 0,
      distance: 0.0,
      direction: 'Desconocida',
      isESP32Sabueso: isESP32,
    );

    setState(() {
      devicesList.add(newDevice);
    });

    await saveDevices();
  }

  Future<void> removeDevice(String address) async {
    setState(() {
      devicesList.removeWhere((device) => device.address == address);
      locationHistory.removeWhere((record) => record.deviceAddress == address);
    });

    await saveDevices();
    await saveLocationHistory();
  }

  Future<void> saveDevices() async {
    if (prefs == null) return;
    final deviceNames = devicesList
        .map((device) =>
            '${device.name}|${device.address}|${device.isESP32Sabueso}')
        .toList();
    await prefs!.setStringList('devices', deviceNames);
  }

  Future<void> loadDevices() async {
    if (prefs == null) return;
    final deviceNames = prefs!.getStringList('devices') ?? [];
    setState(() {
      devicesList = deviceNames.map((nameAddress) {
        final parts = nameAddress.split('|');
        final isESP32 = parts.length > 2 ? parts[2] == 'true' : false;
        return DeviceData(
          name: parts[0],
          address: parts[1],
          rssi: 0,
          distance: 0.0,
          direction: 'Desconocida',
          isESP32Sabueso: isESP32,
        );
      }).toList();
    });
  }

  Future<void> editDeviceName(String address, String newName) async {
    setState(() {
      devicesList = devicesList.map((device) {
        if (device.address == address) {
          return device.copyWith(name: newName);
        }
        return device;
      }).toList();
    });

    await saveDevices();
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          elevation: 0,
          backgroundColor: Colors.blue.shade700,
          title: Row(
            children: [
              const Icon(Icons.pets, size: 28),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sabueso',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        isFirestoreConnected
                            ? Icons.cloud_done
                            : Icons.cloud_off,
                        size: 14,
                        color: isFirestoreConnected
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isFirestoreConnected ? 'Firebase OK' : 'Sin conexión',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          actions: [
            if (!isFirestoreConnected)
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: testFirestoreConnection,
                tooltip: 'Reintentar conexión',
              ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.blue.shade700, Colors.blue.shade500],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.bluetooth_searching,
                        size: 56,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'ESP32 Rastreador Sabueso',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed:
                            isScanningForESP32 ? null : searchForESP32Sabueso,
                        icon: Icon(isScanningForESP32
                            ? Icons.hourglass_empty
                            : Icons.search),
                        label: Text(
                          isScanningForESP32
                              ? 'Buscando...'
                              : 'Buscar Mi ESP32',
                          style: const TextStyle(fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.blue.shade700,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 14),
                          elevation: 4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Detecta automáticamente tu rastreador',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: devicesList.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.bluetooth_disabled,
                                    size: 64, color: Colors.grey.shade400),
                                const SizedBox(height: 16),
                                Text(
                                  'No hay dispositivos agregados',
                                  style: TextStyle(
                                    fontSize: 18,
                                    color: Colors.grey.shade600,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Busca tu ESP32 arriba o agrega dispositivos con el botón +',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: devicesList.length,
                          itemBuilder: (context, index) {
                            final device = devicesList[index];
                            final deviceLocationHistory = locationHistory
                                .where((record) =>
                                    record.deviceAddress == device.address)
                                .toList();

                            return DeviceCard(
                              device: device,
                              locationHistory: deviceLocationHistory,
                              isScanning: isScanning &&
                                  activeDeviceAddress == device.address,
                              onStartScan: () => startScan(device.address),
                              onStopScan: stopScan,
                              onRemove: () => removeDevice(device.address),
                              onEditName: (newName) =>
                                  editDeviceName(device.address, newName),
                            );
                          },
                        ),
                ),
              ],
            ),
            if (showPermissionsDialog)
              Container(
                color: Colors.black54,
                child: Center(
                  child: Card(
                    margin: const EdgeInsets.all(32),
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.warning,
                              size: 48, color: Colors.orange),
                          const SizedBox(height: 16),
                          const Text(
                            'Permisos Necesarios',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Esta aplicación necesita permisos de Bluetooth, Ubicación y Notificaciones para funcionar correctamente.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton(
                            onPressed: requestPermissions,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 32, vertical: 14),
                            ),
                            child: const Text('Otorgar Permisos'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            final result = await showDialog<Map<String, String>>(
              context: context,
              builder: (context) => const AddDeviceDialog(),
            );

            if (result != null) {
              await addDevice(result['name']!, result['address']!);
            }
          },
          backgroundColor: Colors.blue.shade700,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class AddDeviceDialog extends StatefulWidget {
  const AddDeviceDialog({super.key});

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  final nameController = TextEditingController();
  final addressController = TextEditingController();
  List<ScanResult> scanResults = [];
  bool isScanning = false;

  @override
  void dispose() {
    nameController.dispose();
    addressController.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> startScan() async {
    setState(() {
      isScanning = true;
      scanResults.clear();
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          scanResults = results;
        });
      });

      await Future.delayed(const Duration(seconds: 4));
      await FlutterBluePlus.stopScan();

      setState(() {
        isScanning = false;
      });
    } catch (e) {
      debugPrint('Error al escanear: $e');
      setState(() {
        isScanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agregar Dispositivo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Nombre del Dispositivo',
                hintText: 'Ej: Mi AirTag',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: 'Dirección MAC',
                hintText: 'XX:XX:XX:XX:XX:XX',
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: isScanning ? null : startScan,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
              ),
              child: Text(isScanning ? 'Escaneando...' : 'Escanear Dispositivos'),
            ),
            if (scanResults.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Dispositivos Encontrados:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: scanResults.length,
                  itemBuilder: (context, index) {
                    final result = scanResults[index];
                    final deviceName = result.device.platformName.isNotEmpty
                        ? result.device.platformName
                        : 'Dispositivo Desconocido';

                    return ListTile(
                      title: Text(deviceName),
                      subtitle: Text(result.device.remoteId.toString()),
                      trailing: deviceName == ESP32Config.deviceName
                          ? const Icon(Icons.star, color: Colors.blue)
                          : null,
                      onTap: () {
                        nameController.text = deviceName;
                        addressController.text =
                            result.device.remoteId.toString();
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () {
            if (nameController.text.isNotEmpty &&
                addressController.text.isNotEmpty) {
              Navigator.pop(context, {
                'name': nameController.text,
                'address': addressController.text,
              });
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue.shade700,
            foregroundColor: Colors.white,
          ),
          child: const Text('Agregar'),
        ),
      ],
    );
  }
}

class DeviceCard extends StatefulWidget {
  final DeviceData device;
  final List<LocationRecord> locationHistory;
  final bool isScanning;
  final VoidCallback onStartScan;
  final VoidCallback onStopScan;
  final VoidCallback onRemove;
  final Function(String) onEditName;

  const DeviceCard({
    super.key,
    required this.device,
    required this.locationHistory,
    required this.isScanning,
    required this.onRemove,
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
      elevation: 6,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: widget.device.isESP32Sabueso ? Colors.blue.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.device.isESP32Sabueso)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade600, Colors.blue.shade400],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'ESP32 Oficial',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.device.isESP32Sabueso) const SizedBox(height: 12),

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
                    backgroundColor: Colors.blue.shade700,
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
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 36,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          isEditing = true;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Editar'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.straighten, size: 20, color: Colors.blue),
                        const SizedBox(width: 8),
                        Text(
                          'Distancia: ${widget.device.distance.toStringAsFixed(2)} m',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.navigation, size: 20, color: Colors.blue),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.device.direction,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.radio_button_checked, size: 20, color: Colors.orange),
                        const SizedBox(width: 8),
                        Text(
                          'RSSI: ${widget.device.rssi} dBm',
                          style: const TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: widget.isScanning
                      ? widget.onStopScan
                      : widget.onStartScan,
                  icon: Icon(widget.isScanning ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    widget.isScanning ? 'Detener Rastreo' : 'Iniciar Rastreo',
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        widget.isScanning ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      showLocationHistory = true;
                    });
                  },
                  icon: const Icon(Icons.history),
                  label: Text(
                    'Ver Historial (${widget.locationHistory.length})',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
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
                    return Card(
                      elevation: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text('Lat: ${record.latitude}'),
                            Text('Long: ${record.longitude}'),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: () async {
                                final url = Uri.parse(
                                  'https://www.google.com/maps?q=${record.latitude},${record.longitude}',
                                );
                                
                                try {
                                  final mapsUrl = Uri.parse(
                                    'geo:${record.latitude},${record.longitude}?q=${record.latitude},${record.longitude}',
                                  );
                                  
                                  if (await canLaunchUrl(mapsUrl)) {
                                    await launchUrl(
                                      mapsUrl,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  } else {
                                    await launchUrl(
                                      url,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  }
                                } catch (e) {
                                  debugPrint('Error al abrir Maps: $e');
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('No se pudo abrir Google Maps'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(Icons.map, size: 16),
                              label: const Text('Ver en Maps'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue.shade700,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onDismiss,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                ),
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
    debugPrint('Background service started at $timestamp');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    debugPrint('Background task repeat event at $timestamp');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('Background service destroyed at $timestamp');
  }
}
