import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

class LocationRecord {
  final double latitude;
  final double longitude;
  final int timestamp;
  final String deviceAddress;
  final String? userId;

  LocationRecord({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.deviceAddress,
    this.userId,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
        'deviceAddress': deviceAddress,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
      };

  factory LocationRecord.fromJson(Map<String, dynamic> json) => LocationRecord(
        latitude: json['latitude'] ?? 0.0,
        longitude: json['longitude'] ?? 0.0,
        timestamp: json['timestamp'] ?? 0,
        deviceAddress: json['deviceAddress'] ?? '',
        userId: json['userId'],
      );

  factory LocationRecord.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return LocationRecord.fromJson(data);
  }
}

class FirebaseLocationService {
  static final FirebaseLocationService _instance = FirebaseLocationService._internal();
  factory FirebaseLocationService() => _instance;
  FirebaseLocationService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Obtener el ID del usuario actual (anónimo o autenticado)
  Future<String> _getUserId() async {
    User? user = _auth.currentUser;
    
    if (user == null) {
      // Crear usuario anónimo si no existe
      final userCredential = await _auth.signInAnonymously();
      user = userCredential.user;
    }
    
    return user?.uid ?? 'unknown';
  }

  // Guardar una ubicación en Firebase
  Future<void> saveLocation(LocationRecord location) async {
    try {
      final userId = await _getUserId();
      final locationWithUser = LocationRecord(
        latitude: location.latitude,
        longitude: location.longitude,
        timestamp: location.timestamp,
        deviceAddress: location.deviceAddress,
        userId: userId,
      );

      await _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .add(locationWithUser.toJson());
      
      print('✅ Ubicación guardada en Firebase');
    } catch (e) {
      print('❌ Error al guardar ubicación: $e');
      rethrow;
    }
  }

  // Guardar múltiples ubicaciones en lote
  Future<void> saveLocationsBatch(List<LocationRecord> locations) async {
    try {
      final userId = await _getUserId();
      final batch = _firestore.batch();

      for (var location in locations) {
        final locationWithUser = LocationRecord(
          latitude: location.latitude,
          longitude: location.longitude,
          timestamp: location.timestamp,
          deviceAddress: location.deviceAddress,
          userId: userId,
        );

        final docRef = _firestore
            .collection('users')
            .doc(userId)
            .collection('locations')
            .doc();
        
        batch.set(docRef, locationWithUser.toJson());
      }

      await batch.commit();
      print('✅ ${locations.length} ubicaciones guardadas en Firebase');
    } catch (e) {
      print('❌ Error al guardar ubicaciones en lote: $e');
      rethrow;
    }
  }

  // Obtener ubicaciones del usuario
  Stream<List<LocationRecord>> getLocationsStream({String? deviceAddress}) {
    return _auth.authStateChanges().asyncExpand((user) async* {
      if (user == null) {
        yield [];
        return;
      }

      Query query = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('locations')
          .orderBy('timestamp', descending: true);

      if (deviceAddress != null) {
        query = query.where('deviceAddress', isEqualTo: deviceAddress);
      }

      yield* query.snapshots().map((snapshot) {
        return snapshot.docs
            .map((doc) => LocationRecord.fromFirestore(doc))
            .toList();
      });
    });
  }

  // Obtener ubicaciones por rango de fechas
  Future<List<LocationRecord>> getLocationsByDateRange({
    required DateTime startDate,
    required DateTime endDate,
    String? deviceAddress,
  }) async {
    try {
      final userId = await _getUserId();
      
      Query query = _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .where('timestamp', 
              isGreaterThanOrEqualTo: startDate.millisecondsSinceEpoch)
          .where('timestamp', 
              isLessThanOrEqualTo: endDate.millisecondsSinceEpoch)
          .orderBy('timestamp', descending: true);

      if (deviceAddress != null) {
        query = query.where('deviceAddress', isEqualTo: deviceAddress);
      }

      final snapshot = await query.get();
      return snapshot.docs
          .map((doc) => LocationRecord.fromFirestore(doc))
          .toList();
    } catch (e) {
      print('❌ Error al obtener ubicaciones por fecha: $e');
      return [];
    }
  }

  // Eliminar ubicaciones antiguas (por ejemplo, más de 30 días)
  Future<void> deleteOldLocations({int daysToKeep = 30}) async {
    try {
      final userId = await _getUserId();
      final cutoffDate = DateTime.now()
          .subtract(Duration(days: daysToKeep))
          .millisecondsSinceEpoch;

      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .where('timestamp', isLessThan: cutoffDate)
          .get();

      final batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      print('✅ Ubicaciones antiguas eliminadas');
    } catch (e) {
      print('❌ Error al eliminar ubicaciones antiguas: $e');
    }
  }

  // Obtener estadísticas de ubicaciones
  Future<Map<String, dynamic>> getLocationStats() async {
    try {
      final userId = await _getUserId();
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .get();

      final locations = snapshot.docs
          .map((doc) => LocationRecord.fromFirestore(doc))
          .toList();

      if (locations.isEmpty) {
        return {
          'totalLocations': 0,
          'devices': <String>[],
          'oldestLocation': null,
          'newestLocation': null,
        };
      }

      final devices = locations
          .map((loc) => loc.deviceAddress)
          .toSet()
          .toList();

      return {
        'totalLocations': locations.length,
        'devices': devices,
        'oldestLocation': locations.last.timestamp,
        'newestLocation': locations.first.timestamp,
      };
    } catch (e) {
      print('❌ Error al obtener estadísticas: $e');
      return {};
    }
  }

  // Sincronizar ubicaciones locales con Firebase
  Future<void> syncLocalLocations(List<LocationRecord> localLocations) async {
    try {
      if (localLocations.isEmpty) return;

      // Guardar en lotes de 500 (límite de Firestore)
      const batchSize = 500;
      for (var i = 0; i < localLocations.length; i += batchSize) {
        final end = (i + batchSize < localLocations.length)
            ? i + batchSize
            : localLocations.length;
        final batch = localLocations.sublist(i, end);
        await saveLocationsBatch(batch);
      }

      print('✅ Sincronización completa: ${localLocations.length} ubicaciones');
    } catch (e) {
      print('❌ Error al sincronizar ubicaciones: $e');
      rethrow;
    }
  }

  // Cerrar sesión (útil para testing)
  Future<void> signOut() async {
    await _auth.signOut();
  }

  // Obtener el usuario actual
  User? get currentUser => _auth.currentUser;

  // Stream del estado de autenticación
  Stream<User?> get authStateChanges => _auth.authStateChanges();
}
