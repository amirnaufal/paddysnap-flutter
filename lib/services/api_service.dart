import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ApiService {
  // Hugging Face token (for private spaces)
  static const hfToken = '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'; // 🔒 Replace with your actual token

  // Hugging Face private Space endpoints
  static const modelUrl = 'https://amirnaufal-paddysnap-api.hf.space/predict';
  static const rasaUrl = 'https://your-private-rasa-space.hf.space/webhooks/rest/webhook';

  // CNN prediction + log result to Firestore
  static Future<Map<String, dynamic>> getDiseaseFromImage(File image, String imageUrl) async {
    var request = http.MultipartRequest('POST', Uri.parse(modelUrl));
    request.headers['Authorization'] = 'Bearer $hfToken'; // ✅ Include auth token
    request.files.add(await http.MultipartFile.fromPath('image', image.path));

    var response = await request.send();

    if (response.statusCode == 200) {
      final body = await response.stream.bytesToString();
      final data = json.decode(body);

      final prediction = data['prediction'] ?? 'unknown';
      final confidence = data['confidence'] ?? 0.0;
      final filename = data['filename'] ?? 'unknown.jpg';

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await FirebaseFirestore.instance.collection('predictions').add({
          'uid': uid,
          'disease': prediction,
          'confidence': confidence,
          'image_url': imageUrl,
          'filename': filename,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }

      return {
        'prediction': prediction,
        'confidence': confidence,
        'filename': filename,
      };
    } else {
      throw Exception('❌ CNN model failed with status code ${response.statusCode}');
    }
  }

  // Send normal text query to Rasa chatbot
  static Future<String> getRasaResponse(String message) async {
    final response = await http.post(
      Uri.parse(rasaUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $hfToken', // ✅ Include auth token
      },
      body: jsonEncode({"sender": "user", "message": message}),
    );

    if (response.statusCode == 200) {
      final List data = json.decode(response.body);
      return data.isNotEmpty ? data[0]['text'] ?? "No reply." : "No response.";
    } else {
      throw Exception("❌ Failed to contact Rasa backend: ${response.statusCode}");
    }
  }
}

// ✅ Firestore disease data fetch
class DiseaseService {
  static Future<Map<String, dynamic>?> getDiseaseDetails(String diseaseId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('diseases')
          .doc(diseaseId)
          .get();

      if (doc.exists) {
        return doc.data();
      } else {
        return null;
      }
    } catch (e) {
      print('❌ Failed to fetch disease info: $e');
      return null;
    }
  }
}
