import 'dart:convert';
import 'package:http/http.dart' as http;

/// Development-only direct API call.
/// Production: use a backend proxy to keep the key out of the APK and network logs.
class GeminiClient {
  final http.Client _client = http.Client();
  final List<Map<String, dynamic>> _history = [];
  Future<String> reply(String message, String apiKey) async {
    final contents = <Map<String,dynamic>>[
      ..._history,
      {'role':'user','parts':[{'text':message}]},
    ];
    final uri=Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent');
    final response=await _client.post(uri,
      headers:{'Content-Type':'application/json','x-goog-api-key':apiKey},
      body:jsonEncode({
        'systemInstruction':{'parts':[{'text':
          'أنت سيليا، روبوت صغير مرح وودود. تحدثي بالمصرية بإجابات قصيرة ومناسبة للأطفال. '
          'لا تدعي أنك تستطيعين تحريك الروبوت أو رؤية الكاميرا إذا لم تتلقي بيانات حقيقية.'
        }]},
        'contents':contents,
        'generationConfig':{'maxOutputTokens':320,'temperature':0.75}
      })).timeout(const Duration(seconds:35));
    if(response.statusCode!=200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length>160?response.body.substring(0,160):response.body}');
    }
    final obj=jsonDecode(response.body) as Map<String,dynamic>;
    final candidates=obj['candidates'] as List?;
    final content=candidates?.isNotEmpty==true ? candidates!.first['content'] : null;
    final parts=(content is Map ? content['parts'] : null) as List?;
    final text=parts?.whereType<Map>().map((p)=>p['text']??'').join('').trim()??'';
    if(text.isEmpty) throw Exception('Gemini لم يرجع نصًا');
    _history.add({'role':'user','parts':[{'text':message}]});
    _history.add({'role':'model','parts':[{'text':text}]});
    if(_history.length>12) _history.removeRange(0,_history.length-12);
    return text;
  }
}
