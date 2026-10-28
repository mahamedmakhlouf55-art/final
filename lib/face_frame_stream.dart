import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Live 240x240 little-endian RGB565 frame from the robot's /frame endpoint.
class CelyahLiveFace extends StatefulWidget {
  final String baseUrl;
  final Widget fallback;
  const CelyahLiveFace({super.key, required this.baseUrl, required this.fallback});
  @override State<CelyahLiveFace> createState() => _CelyahLiveFaceState();
}
class _CelyahLiveFaceState extends State<CelyahLiveFace> {
  final http.Client _client = http.Client();
  Timer? _timer;
  ui.Image? _image;
  String? _error;
  bool _busy = false;
  @override void initState() {super.initState();_start();}
  @override void didUpdateWidget(covariant CelyahLiveFace old) {
    super.didUpdateWidget(old);
    if(old.baseUrl != widget.baseUrl) {_timer?.cancel();_image?.dispose();_image=null;_start();}
  }
  void _start() {
    _fetch();
    _timer=Timer.periodic(const Duration(milliseconds:500),(_)=>_fetch());
  }
  Future<void> _fetch() async {
    if(_busy || !mounted) return;
    _busy=true;
    try {
      final base=widget.baseUrl.trim().replaceAll(RegExp(r'/$'),'');
      final response=await _client.get(Uri.parse('$base/frame'))
        .timeout(const Duration(seconds:3));
      if(response.statusCode!=200 || response.bodyBytes.length!=115200) {
        throw Exception('HTTP ${response.statusCode} / ${response.bodyBytes.length} bytes');
      }
      final src=response.bodyBytes;
      final rgba=Uint8List(240*240*4);
      for(var i=0,j=0;i<src.length;i+=2,j+=4) {
        final rgb=src[i] | (src[i+1]<<8);
        final r=(rgb>>11)&31,g=(rgb>>5)&63,b=rgb&31;
        rgba[j]=(r<<3)|(r>>2);
        rgba[j+1]=(g<<2)|(g>>4);
        rgba[j+2]=(b<<3)|(b>>2);
        rgba[j+3]=255;
      }
      final completer=Completer<ui.Image>();
      ui.decodeImageFromPixels(rgba,240,240,ui.PixelFormat.rgba8888,
        (image)=>completer.complete(image));
      final next=await completer.future;
      if(!mounted){next.dispose();return;}
      final old=_image;
      setState((){_image=next;_error=null;});
      // Defer disposal until the previous frame is no longer painted.
      if(old!=null) WidgetsBinding.instance.addPostFrameCallback((_){old.dispose();});
    } catch(e) {
      if(mounted)setState(()=>_error='$e');
    } finally {_busy=false;}
  }
  @override void dispose() {_timer?.cancel();_client.close();_image?.dispose();super.dispose();}
  @override Widget build(BuildContext context) => Stack(fit:StackFit.expand,children:[
    if(_image==null) widget.fallback else RawImage(image:_image,fit:BoxFit.contain,filterQuality:FilterQuality.none),
    if(_error!=null) Positioned(bottom:8,left:8,right:8,child:Container(
      padding:const EdgeInsets.all(6),color:Colors.black87,
      child:Text('الوش غير متصل بالـ Wi-Fi: $_error',maxLines:2,
        style:const TextStyle(color:Colors.orangeAccent,fontSize:10))))
  ]);
}
