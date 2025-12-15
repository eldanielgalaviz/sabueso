import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  String? _userId;

  // Singleton
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  // Inicializar autenticación anónima
  Future<void> initializeAuth() async {
    try {
      UserCredential userCredential = await _auth.signInAnonymously();
      _userId = userCredential.user?.uid;
      print('✅ Usuario autenticado: $_userId');
    } catch (e) {
      print('❌ Error en autenticación: $e');
    }
  }

  String get userId => _userId ?? 'offline_user';

  // Guardar ubicación en Firestore
  Future<void> saveLocationToFirebase({
    required double latitude,
    required double longitude,
    required String deviceAddress,
    required String deviceName,
  }) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .add({
        'latitude': latitude,
        'longitude': longitude,
        'deviceAddress': deviceAddress,
        'deviceName': deviceName,
        'timestamp': FieldValue.serverTimestamp(),
        'localTimestamp': DateTime.now().millisecondsSinceEpoch,
      });
      print('📍 Ubicación guardada en Firebase');
    } catch (e) {
      print('❌ Error al guardar ubicación: $e');
    }
  }

  // Guardar múltiples ubicaciones (batch)
  Future<void> saveLocationsBatch(List<Map<String, dynamic>> locations) async {
    try {
      WriteBatch batch = _firestore.batch();
      
      for (var location in locations) {
        DocumentReference docRef = _firestore
            .collection('users')
            .doc(userId)
            .collection('locations')
            .doc();
        
        batch.set(docRef, {
          ...location,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }
      
      await batch.commit();
      print('📍 ${locations.length} ubicaciones guardadas en lote');
    } catch (e) {
      print('❌ Error en batch: $e');
    }
  }

  // Obtener historial de ubicaciones de Firebase
  Stream<QuerySnapshot> getLocationHistory({int limit = 100}) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('locations')
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots();
  }

  // Obtener ubicaciones por dispositivo
  Stream<QuerySnapshot> getLocationsByDevice(String deviceAddress) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('locations')
        .where('deviceAddress', isEqualTo: deviceAddress)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  // Eliminar ubicaciones antiguas (más de 30 días)
  Future<void> cleanOldLocations() async {
    try {
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
      
      QuerySnapshot oldDocs = await _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .where('localTimestamp', isLessThan: thirtyDaysAgo.millisecondsSinceEpoch)
          .get();

      WriteBatch batch = _firestore.batch();
      for (var doc in oldDocs.docs) {
        batch.delete(doc.reference);
      }
      
      await batch.commit();
      print('🗑️ ${oldDocs.docs.length} ubicaciones antiguas eliminadas');
    } catch (e) {
      print('❌ Error al limpiar ubicaciones: $e');
    }
  }

  // Obtener estadísticas
  Future<Map<String, dynamic>> getStatistics() async {
    try {
      QuerySnapshot snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('locations')
          .get();

      Map<String, int> deviceCounts = {};
      for (var doc in snapshot.docs) {
        String device = doc.get('deviceAddress');
        deviceCounts[device] = (deviceCounts[device] ?? 0) + 1;
      }

      return {
        'totalLocations': snapshot.docs.length,
        'deviceCounts': deviceCounts,
        'lastUpdate': snapshot.docs.isNotEmpty 
            ? snapshot.docs.first.get('timestamp') 
            : null,
      };
    } catch (e) {
      print('❌ Error al obtener estadísticas: $e');
      return {};
    }
  }
}