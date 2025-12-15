import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

class WeatherService {
  // API gratuita de OpenWeatherMap (necesitas registrarte en openweathermap.org)
  static const String _apiKey = 'TU_API_KEY_AQUI'; // Reemplazar con tu API key
  static const String _baseUrl = 'https://api.openweathermap.org/data/2.5';

  // Singleton
  static final WeatherService _instance = WeatherService._internal();
  factory WeatherService() => _instance;
  WeatherService._internal();

  // Obtener clima actual por coordenadas
  Future<Map<String, dynamic>?> getCurrentWeather({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final url = Uri.parse(
        '$_baseUrl/weather?lat=$latitude&lon=$longitude&appid=$_apiKey&units=metric&lang=es',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'temperature': data['main']['temp'].round(),
          'feelsLike': data['main']['feels_like'].round(),
          'description': data['weather'][0]['description'],
          'humidity': data['main']['humidity'],
          'windSpeed': data['wind']['speed'],
          'cityName': data['name'],
          'icon': data['weather'][0]['icon'],
        };
      } else {
        print('❌ Error en API del clima: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ Error al obtener clima: $e');
      return null;
    }
  }

  // Obtener clima usando la ubicación actual del dispositivo
  Future<Map<String, dynamic>?> getCurrentWeatherByLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );
      
      return await getCurrentWeather(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (e) {
      print('❌ Error al obtener ubicación para clima: $e');
      return null;
    }
  }

  // Generar mensaje de voz del clima
  String generateWeatherAnnouncement(Map<String, dynamic> weather) {
    final temp = weather['temperature'];
    final description = weather['description'];
    final cityName = weather['cityName'];
    final humidity = weather['humidity'];
    
    String message = 'Buenos días. ';
    message += 'El clima actual en $cityName es: $description. ';
    message += 'La temperatura es de $temp grados centígrados. ';
    
    // Recomendaciones según temperatura
    if (temp > 30) {
      message += 'Hace mucho calor. Recuerda mantenerte hidratado y usar protección solar. ';
    } else if (temp > 25) {
      message += 'Hace calor. Es un buen día para salir. ';
    } else if (temp > 15) {
      message += 'La temperatura es agradable. ';
    } else if (temp > 10) {
      message += 'Hace un poco de frío. Considera llevar una chamarra ligera. ';
    } else {
      message += 'Hace frío. Abrígate bien antes de salir. ';
    }
    
    // Información adicional sobre humedad
    if (humidity > 80) {
      message += 'La humedad es alta, del $humidity por ciento. ';
    }
    
    return message;
  }

  // Obtener pronóstico de 5 días
  Future<List<Map<String, dynamic>>> getForecast({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final url = Uri.parse(
        '$_baseUrl/forecast?lat=$latitude&lon=$longitude&appid=$_apiKey&units=metric&lang=es',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<Map<String, dynamic>> forecast = [];

        for (var item in data['list']) {
          forecast.add({
            'dateTime': DateTime.fromMillisecondsSinceEpoch(
              item['dt'] * 1000,
            ),
            'temperature': item['main']['temp'].round(),
            'description': item['weather'][0]['description'],
            'icon': item['weather'][0]['icon'],
          });
        }

        return forecast;
      } else {
        print('❌ Error en pronóstico: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('❌ Error al obtener pronóstico: $e');
      return [];
    }
  }
}