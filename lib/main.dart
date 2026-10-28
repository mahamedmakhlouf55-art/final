
import 'dart:async';
import 'dart:convert';
import 'gemini_client.dart';
import 'face_frame_stream.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/material.dart';
import 'robot_link.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const CelyahApp()); }
const bg = Color(0xFF0D0B15), panel = Color(0xFF1B1629);
const lavender = Color(0xFFF08DEB), soft = Color(0xFFB9AEC9);

class CelyahApp extends StatelessWidget {
  const CelyahApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner:false, title:'Celyah Robot',
    theme:ThemeData(useMaterial3:true,brightness:Brightness.dark,
      scaffoldBackgroundColor:bg,colorScheme:ColorScheme.fromSeed(seedColor:lavender,brightness:Brightness.dark),
      fontFamily:'sans-serif', inputDecorationTheme:InputDecorationTheme(
      filled:true,fillColor:panel,border:OutlineInputBorder(borderRadius:BorderRadius.circular(22),borderSide:BorderSide.none))),
    home:const Dashboard());
}
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override State<Dashboard> createState()=>_DashboardState();
}
class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  final RobotLink link=RobotLink();
  Timer? _driveKeepAlive;
  String? _heldDirection;
  bool _driveSending = false;
  bool _manualReady = false;

  Future<void> _sendDrivePulse() async {
    final direction = _heldDirection;
    if (direction == null || !link.connected || _driveSending) return;
    _driveSending = true;
    try {
      if (!_manualReady) {
        await link.send('MODE:MANUAL');
        _manualReady = true;
      }
      if (_heldDirection == direction) await link.send('DRIVE:$direction');
    } finally {
      _driveSending = false;
    }
  }

  void _startDrive(String direction) {
    if (!link.connected) { _notice('وصّل الروبوت بالبلوتوث الأول'); return; }
    if (_heldDirection == direction) return;
    _driveKeepAlive?.cancel();
    _heldDirection = direction;
    _manualReady = false;
    _sendDrivePulse();
    // The ESP32 has an 800ms watchdog; refresh at 200ms while held.
    _driveKeepAlive = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!link.connected) { _stopDrive(); return; }
      _sendDrivePulse();
    });
  }

  void _stopDrive() {
    _heldDirection = null;
    _driveKeepAlive?.cancel();
    _driveKeepAlive = null;
    if (link.connected) link.send('STOP');
  }

  Widget _driveKey(String label, IconData icon, String direction) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (_) => _startDrive(direction),
    onPointerUp: (_) => _stopDrive(),
    onPointerCancel: (_) => _stopDrive(),
    child: Container(
      constraints: const BoxConstraints(minWidth: 112, minHeight: 70),
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: lavender.withValues(alpha: .5))),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: lavender, size: 32),
        Text(label, style: const TextStyle(color: Colors.white)),
      ]),
    ),
  );

  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopDrive();
  }

  final TextEditingController chat=TextEditingController();
  final TextEditingController geminiKey=TextEditingController();
  final GeminiClient gemini=GeminiClient();
  bool useGemini=true;
  bool chatBusy=false;
  final TextEditingController faceHost=TextEditingController(text:'http://192.168.4.1');
  final TextEditingController wifiSsid=TextEditingController();
  final TextEditingController wifiPassword=TextEditingController();
  final List<String> wifiNetworks=[];
  String wifiInfo='لم يتم الاستعلام عن الشبكة';
  bool wifiScanning=false;
  final TextEditingController camera=TextEditingController(text:'http://192.168.1.100');
  StreamSubscription<String>? incoming;
  Timer? visionTimer;
  int visionFrame = 0;
  bool visionEnabled = false;
  String visionUrl = '';
  int tab=0;
  bool busy=false;
  final stt.SpeechToText speech = stt.SpeechToText();
  final FlutterTts tts = FlutterTts();
  bool listening=false;
  String robotState='idle';
  bool speakReplies=true;
  bool showFullChat=false;
  String lastRobotMessage='جاهزة للكلام 💜';
  Future<void> listen() async {
    if(listening){await speech.stop();if(mounted)setState(()=>listening=false);return;}
    final ok=await speech.initialize(onError:(e){if(mounted){setState(()=>listening=false);_notice('الميكروفون: $e');}},
      onStatus:(status){if(mounted&&status=='done')setState(()=>listening=false);});
    if(!ok){_notice('التعرف على الكلام غير متاح على الجهاز');return;}
    if(link.connected) await link.sendState('listening');
    setState((){listening=true;face='curious';robotState='listening';});
    await speech.listen(localeId:'ar_EG',onResult:(r){
      if(mounted){setState(()=>chat.text=r.recognizedWords);}
      if(r.finalResult){setState(()=>listening=false);_chat();}
    });
  }
  Future<void> readAloud(String text) async {
    if(!speakReplies)return;
    final languages = await tts.getLanguages;
    final available = (languages is List) ? languages.map((e)=>e.toString().toLowerCase()).toList() : <String>[];
    await tts.setLanguage(available.contains('ar-eg') ? 'ar-EG' : 'ar');
    await tts.setSpeechRate(.44);
    await tts.setPitch(1.05);
    await tts.speak(text);
  }

  final List<(bool,String)> messages=[(false,'أهلاً! أنا Celyah 💜 اتصلي بيا عشان نبدأ مغامرتنا.')];
  String face='normal';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);link.addListener(_refresh);
    incoming=link.lines.listen((line){if(!mounted)return;
      if(line.startsWith('OK:') || line.startsWith('ERR:')) return;
      if(line.startsWith('WIFI:')) {
        setState(() {
          if(line=='WIFI:SCANNING') {wifiScanning=true;wifiNetworks.clear();wifiInfo='جار البحث عن الشبكات...';}
          else if(line=='WIFI:SCAN_DONE') {wifiScanning=false;wifiInfo='اختار الشبكة واكتب الباسورد';}
          else if(line.startsWith('WIFI:AP:')) {
            final parts=line.substring(8).split('|');
            if(parts.isNotEmpty) {
              try {
                final ssid=utf8.decode(base64.decode(parts.first));
                if(!wifiNetworks.contains(ssid))wifiNetworks.add(ssid);
              } catch (_) {}
            }
          } else if(line.startsWith('WIFI:CONNECTED:')) {
            final ip=line.substring('WIFI:CONNECTED:'.length);
            wifiInfo='متصل - IP: $ip';
            faceHost.text='http://$ip';
          } else if(line=='WIFI:FAILED')wifiInfo='فشل الاتصال. راجع الشبكة والباسورد';
          else if(line=='WIFI:DISCONNECTED')wifiInfo='الروبوت غير متصل براوتر';
          else if(line=='WIFI:ACCEPTED')wifiInfo='جار محاولة الاتصال...';
          else if(line=='WIFI:INVALID')wifiInfo='اسم الشبكة أو الباسورد غير صالح';
        });
        return;
      }
      setState((){
        if(line.startsWith('CHAT:')) {
          messages.add((false,line.substring(5)));
          lastRobotMessage=line.substring(5);
          face='happy';
          return;
        }
        if(line.startsWith('OK:') || line.startsWith('ERR:') || line.startsWith('BAT:')) return;
        messages.add((false,line));
        if(line.startsWith('FACE:')) { face=line.substring(5).trim().toLowerCase(); }
        else if(!line.startsWith('VISION:') && !line.startsWith('BAT:')) {
          lastRobotMessage=line; robotState='speaking';
          if(!line.startsWith('APP:') && !line.startsWith('WiFi:')) face='happy';
        }
      });
      if(line.startsWith('VISION:URL ')) {
        final url=line.substring('VISION:URL '.length).trim();
        camera.text=url;
        visionTimer?.cancel();
        visionTimer=Timer.periodic(const Duration(milliseconds:900),(_){
          if(mounted && tab==2 && visionEnabled) setState(()=>visionFrame++);
        });
        setState(() {visionUrl=url;visionEnabled=true;visionFrame++;});
      }
      if(line=='VISION:OFF') {visionTimer?.cancel();setState(()=>visionEnabled=false);}
      if(line.startsWith('CHAT:')) readAloud(line.substring(5));
      else if(!line.startsWith('OK:') && !line.startsWith('ERR:') && !line.startsWith('BAT:') && !line.startsWith('VISION:')) readAloud(line);
    });}
  void _refresh(){if(mounted)setState((){});}
  Future<void> command(String cmd) async {
    if(!link.connected){_notice('وصّلي الروبوت بالبلوتوث الأول');return;}
    try{await link.send(cmd);}
    catch(e){_notice('فشل إرسال الأمر: $e');}
  }
  Widget _brand()=>Row(mainAxisSize:MainAxisSize.min,children:[
    const Text('Celyah',style:TextStyle(fontSize:31,fontWeight:FontWeight.w800,letterSpacing:-1.8)),
    const Text('♡',style:TextStyle(color:lavender,fontSize:29)),
    const SizedBox(width:9),
    const Text('R O B O T',style:TextStyle(color:soft,fontSize:9,letterSpacing:1.2))
  ]);
  void _notice(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
  Future<void> _chat() async {
    final s=chat.text.trim();
    if(s.isEmpty || chatBusy)return;
    // Movement words must never reach Gemini, CHAT, TTS, or expressions.
    // For safety, only on-screen hold buttons can initiate wheel motion.
    final movement = s.toLowerCase().replaceAll(RegExp(r'[\s\u064b-\u065f]'), '');
    const silentMotion = <String>{
      'قدام','امام','أمام','للأمام','لقدام','اتقدم','تقدم',
      'ورا','وراء','خلف','لورا','ارجع','للخلف',
      'يمين','لليمين','شمال','يسار','لليسار',
      'قف','وقف','توقف','ستوب','stop','forward','back','left','right'
    };
    if (silentMotion.contains(movement)) {
      chat.clear();
      await tts.stop();
      if (movement == 'قف' || movement == 'وقف' || movement == 'توقف' ||
          movement == 'ستوب' || movement == 'stop') {
        _stopDrive();
      }
      return;
    }
    setState((){chatBusy=true;messages.add((true,s));chat.clear();lastRobotMessage='Celyah بتفكر...';face='thinking';});
    try {
      if(useGemini && geminiKey.text.trim().isNotEmpty) {
        final answer=await gemini.reply(s,geminiKey.text.trim());
        if(!mounted)return;
        setState((){messages.add((false,answer));lastRobotMessage=answer;face='happy';});
        await readAloud(answer);
        if(link.connected) {
          // Only face/mood command goes to the robot, not uncontrolled movement.
          try { await link.say('happy',answer); } catch (_) {}
        }
      } else {
        if(!link.connected) {
          const reply='وصّليني بالبلوتوث للردود المحلية، أو اكتبي مفتاح Gemini للرد الذكي.';
          if(mounted)setState((){messages.add((false,reply));lastRobotMessage=reply;});
        } else {
          await link.send('CHAT:$s');
        }
      }
    } catch(e) {
      if(mounted)setState((){messages.add((false,'تعذر الاتصال بـ Gemini: $e'));});
    } finally {
      if(mounted)setState(()=>chatBusy=false);
    }
  }
  @override void dispose(){_stopDrive();WidgetsBinding.instance.removeObserver(this);speech.cancel();tts.stop();visionTimer?.cancel();incoming?.cancel();link.removeListener(_refresh);link.dispose();chat.dispose();geminiKey.dispose();wifiSsid.dispose();wifiPassword.dispose();faceHost.dispose();camera.dispose();super.dispose();}
  Widget _card(Widget child,{EdgeInsets? pad})=>Container(
    padding:pad??const EdgeInsets.all(20),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(26),
      border:Border.all(color:lavender.withValues(alpha:.12))),child:child);
  Widget _button(String label,IconData icon,VoidCallback tap,{bool primary=false})=>FilledButton.icon(
    onPressed:tap,icon:Icon(icon,size:19),label:Text(label),
    style:FilledButton.styleFrom(backgroundColor:primary?lavender:const Color(0xFF30253F),
      foregroundColor:primary?bg:Colors.white,padding:const EdgeInsets.symmetric(horizontal:17,vertical:14)));
  Widget _title(String t,String subtitle)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text(t,style:const TextStyle(fontSize:25,fontWeight:FontWeight.w700)),
    const SizedBox(height:5),Text(subtitle,style:const TextStyle(color:soft)),const SizedBox(height:20)]);
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(backgroundColor:bg,toolbarHeight:76,
      title:_brand(),
      actions:[Padding(padding:const EdgeInsets.only(right:16),child:Icon(link.connected?Icons.bluetooth_connected:Icons.bluetooth_disabled,
        color:link.connected?lavender:soft))]),
    body:SafeArea(child:IndexedStack(index:tab,children:[_home(),_vision(),_settings()])),
    bottomNavigationBar:NavigationBar(backgroundColor:panel,indicatorColor:lavender.withValues(alpha:.22),
      selectedIndex:tab,onDestinationSelected:(v){_stopDrive();setState(()=>tab=v);},
      destinations:const [
        NavigationDestination(icon:Icon(Icons.chat_bubble_outline),selectedIcon:Icon(Icons.chat_bubble),label:'Celyah'),
        NavigationDestination(icon:Icon(Icons.videocam_outlined),selectedIcon:Icon(Icons.videocam),label:'الكاميرا والتحكم'),
        NavigationDestination(icon:Icon(Icons.settings_outlined),selectedIcon:Icon(Icons.settings),label:'الإعدادات'),
      ]));
  Widget _home()=>LayoutBuilder(builder:(context,constraints){
    final height=constraints.maxHeight;
    return Column(children:[
      SizedBox(height:height*.37,child:Padding(padding:const EdgeInsets.fromLTRB(12,6,12,5),child:Container(
        width:double.infinity,decoration:BoxDecoration(color:Colors.black,
          borderRadius:BorderRadius.circular(30),border:Border.all(color:lavender.withValues(alpha:.25))),
        child:LayoutBuilder(builder:(context,box)=>CelyahLiveFace(
          baseUrl:faceHost.text.trim(),
          fallback:CustomPaint(painter:EyePainter(face),size:Size(box.maxWidth,box.maxHeight))))))),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[
        Icon(Icons.circle,size:9,color:link.connected?Colors.greenAccent:Colors.orangeAccent),
        const SizedBox(width:7),Expanded(child:Text(link.status,maxLines:1,overflow:TextOverflow.ellipsis,
          style:const TextStyle(fontSize:11,color:soft))),
        IconButton(onPressed:()async{if(link.connected){await link.disconnect();}else{await link.connect();}},
          icon:Icon(link.connected?Icons.bluetooth_connected:Icons.bluetooth,color:lavender))
      ])),
      AnimatedContainer(duration:const Duration(milliseconds:200),
        height:height*.37,
        margin:const EdgeInsets.symmetric(horizontal:12),padding:const EdgeInsets.all(10),
        decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(19)),
        child:ListView.builder(reverse:true,itemCount:messages.length,
          itemBuilder:(context,i){final m=messages[messages.length-1-i];
            return Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Text(
              '${m.$1?'أنت':'Celyah'}: ${m.$2}',maxLines:3,overflow:TextOverflow.ellipsis,
              style:TextStyle(fontSize:13,color:m.$1?lavender:Colors.white)));})),
      Padding(padding:const EdgeInsets.fromLTRB(12,7,12,8),child:Row(children:[
        Expanded(child:TextField(controller:chat,onSubmitted:(_)=>_chat(),
          textInputAction:TextInputAction.send,maxLines:1,
          decoration:const InputDecoration(hintText:'اتكلم مع Celyah...',
            isDense:true,contentPadding:EdgeInsets.symmetric(horizontal:16,vertical:14)))),
        const SizedBox(width:6),IconButton.filledTonal(onPressed:listen,
          icon:Icon(listening?Icons.stop:Icons.mic,color:lavender)),
        IconButton.filled(onPressed:_chat,icon:const Icon(Icons.send))
      ])),
    ]);
  });
  Widget _quickTile(String label,IconData icon,VoidCallback action)=>InkWell(
    onTap:action,borderRadius:BorderRadius.circular(20),
    child:Container(padding:const EdgeInsets.symmetric(vertical:18,horizontal:5),
      decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(20)),
      child:Column(children:[Icon(icon,color:lavender,size:27),const SizedBox(height:8),Text(label)])));
  Widget _messages()=>Column(children:[
    Padding(padding:const EdgeInsets.symmetric(horizontal:14,vertical:6),
      child:Column(children:[
        SwitchListTile(
          dense:true,contentPadding:EdgeInsets.zero,
          title:const Text('Gemini عبر الإنترنت'),
          subtitle:Text(useGemini?'لو المفتاح فاضي، تستخدم سيليا الردود المحلية':'وضع الردود المحلية عبر BLE'),
          value:useGemini,onChanged:(v)=>setState(()=>useGemini=v)),
        if(useGemini) TextField(
          controller:geminiKey,obscureText:true,
          decoration:const InputDecoration(
            isDense:true,labelText:'Gemini API key (تجربة فقط)',
            hintText:'الصقي المفتاح هنا - لا يُحفظ في التطبيق')),
      ])),

    Padding(padding:const EdgeInsets.fromLTRB(18,8,18,4),
      child:Row(children:[
        Container(width:55,height:55,decoration:BoxDecoration(color:Colors.black,borderRadius:BorderRadius.circular(16)),
          child:CustomPaint(painter:EyePainter(face))),
        const SizedBox(width:12),
        Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Celyah ♡',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
          Text(listening?'بتسمعك دلوقتي...':robotState=='speaking'?'بترد عليك...':'جاهزة للكلام',
            style:const TextStyle(color:soft,fontSize:12))]),
      ])),
    Expanded(child:ListView.builder(reverse:true,padding:const EdgeInsets.all(18),itemCount:messages.length,
      itemBuilder:(context,i){final m=messages[messages.length-1-i];
        return Align(alignment:m.$1?Alignment.centerRight:Alignment.centerLeft,
          child:Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(15),
            constraints:BoxConstraints(maxWidth:MediaQuery.sizeOf(context).width*.8),
            decoration:BoxDecoration(color:m.$1?const Color(0xFF503467):panel,
              borderRadius:BorderRadius.circular(20)),child:Text(m.$2)));})),
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[
      Expanded(child:TextField(controller:chat,onSubmitted:(_)=>_chat(),textInputAction:TextInputAction.send,
        decoration:const InputDecoration(hintText:'اكتبي رسالة لـ Celyah...'))),
      const SizedBox(width:5),
      IconButton.filledTonal(onPressed:listen,icon:Icon(listening?Icons.stop:Icons.mic,color:lavender)),
      IconButton.filled(onPressed:_chat,icon:const Icon(Icons.send))
    ]))
  ]);
  bool manualMode = true;
  double speedValue = 60;
  Widget _vision()=>ListView(padding:const EdgeInsets.fromLTRB(14,12,14,20),children:[
    const Text('Live Camera & Control',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold)),
    const SizedBox(height:8),
    Container(height:MediaQuery.sizeOf(context).height*.31,clipBehavior:Clip.antiAlias,
      decoration:BoxDecoration(color:Colors.black,borderRadius:BorderRadius.circular(24),
        border:Border.all(color:lavender.withValues(alpha:.4))),
      child:visionEnabled && visionUrl.isNotEmpty
        ? Image.network('$visionUrl?t=$visionFrame',fit:BoxFit.cover,gaplessPlayback:true,
            errorBuilder:(_,error,stack)=>const Center(child:Text('البث غير متاح — راجع اتصال الكاميرا',style:TextStyle(color:soft))))
        : const Center(child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
            Icon(Icons.videocam_off_outlined,color:lavender,size:48),
            SizedBox(height:8),Text('الكاميرا غير متصلة',style:TextStyle(color:soft))]))),
    const SizedBox(height:10),
    Row(children:[
      Expanded(child:_button('تشغيل الكاميرا',Icons.play_arrow,(){
        final url=camera.text.trim();
        if(!url.startsWith('http://')&&!url.startsWith('https://')){_notice('حدد رابط الكاميرا في الإعدادات');return;}
        visionTimer?.cancel();
        visionTimer=Timer.periodic(const Duration(milliseconds:900),(_){
          if(mounted && tab==1 && visionEnabled)setState(()=>visionFrame++);
        });
        setState((){visionUrl=url;visionEnabled=true;visionFrame++;});
        if(link.connected)command('STREAM:ON');
      },primary:true)),
      const SizedBox(width:8),
      IconButton.filledTonal(onPressed:(){visionTimer?.cancel();setState(()=>visionEnabled=false);},icon:const Icon(Icons.videocam_off)),
    ]),
    const SizedBox(height:12),
    SegmentedButton<bool>(segments:const [
      ButtonSegment(value:false,label:Text('Auto'),icon:Icon(Icons.smart_toy_outlined)),
      ButtonSegment(value:true,label:Text('Manual'),icon:Icon(Icons.gamepad_outlined)),
    ],selected:{manualMode},onSelectionChanged:(values){
      _stopDrive();
      final v=values.first;
      setState(()=>manualMode=v);
      command(v?'MODE:MANUAL':'MODE:OFF');
    }),
    const SizedBox(height:12),
    if(manualMode) ...[
      const Text('اضغط باستمرار للحركة، وسيقف الروبوت عند الإفلات',textAlign:TextAlign.center,style:TextStyle(color:soft,fontSize:12)),
      const SizedBox(height:10),
      Center(child:_driveKey('أمام',Icons.keyboard_arrow_up,'F')),
      const SizedBox(height:7),
      Row(mainAxisAlignment:MainAxisAlignment.center,children:[
        _driveKey('شمال',Icons.keyboard_arrow_left,'L'),
        const SizedBox(width:8),
        _driveKey('يمين',Icons.keyboard_arrow_right,'R'),
      ]),
      const SizedBox(height:7),
      Center(child:_driveKey('خلف',Icons.keyboard_arrow_down,'B')),
      Row(children:[const Icon(Icons.speed,color:lavender),Expanded(child:Slider(value:speedValue,min:20,max:100,divisions:16,
        label:'${speedValue.round()}%',onChanged:(v)=>setState(()=>speedValue=v),
        onChangeEnd:(v)=>command('SPEED:${v.round()}'))),Text('${speedValue.round()}%')]),
      Wrap(alignment:WrapAlignment.center,spacing:8,children:[
        _button('الذراع 45°',Icons.pan_tool_outlined,()=>command('SERVO:45')),
        _button('الذراع 90°',Icons.front_hand_outlined,()=>command('SERVO:90')),
        _button('الذراع 135°',Icons.back_hand_outlined,()=>command('SERVO:135')),
      ]),
    ] else ...[
      const Padding(padding:EdgeInsets.all(10),child:Text('الوضع التلقائي يحتاج حساسات عوائق وحواف موثوقة قبل تشغيله على الأرض.',textAlign:TextAlign.center,style:TextStyle(color:soft))),
      _button('بدء الوضع التلقائي (تجريبي)',Icons.play_arrow,()=>command('MODE:AUTO')),
    ],
    const SizedBox(height:12),
    FilledButton.icon(onPressed:(){_stopDrive();command('MODE:OFF');},
      style:FilledButton.styleFrom(backgroundColor:const Color(0xFFE63852),minimumSize:const Size.fromHeight(52)),
      icon:const Icon(Icons.stop_circle),label:const Text('STOP — إيقاف فوري')),
    const SizedBox(height:10),
    const Text('التحكم الحالي عبر Bluetooth فقط. التحكم عبر الإنترنت من خارج المنزل يحتاج خادم اتصال آمن وتحديث Firmware.',textAlign:TextAlign.center,style:TextStyle(color:soft,fontSize:11)),
  ]);
  Widget _control()=>ListView(padding:const EdgeInsets.all(18),children:[
    _title('Celyah Control','لوحة التحكم في الحركة والتعبيرات'),
    _card(Column(children:[
      const Icon(Icons.smart_toy_outlined,color:lavender,size:38),
      const SizedBox(height:10),
      const Text('حركة Celyah V14',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
      const SizedBox(height:8),
      const Text('AUTO فقط في مساحة أرضية محاطة بحواجز وتحت إشراف؛ لا توجد حساسات حواف أو عوائق.',textAlign:TextAlign.center,style:TextStyle(color:soft)),
      const SizedBox(height:16),
      Wrap(spacing:8,runSpacing:8,alignment:WrapAlignment.center,children:[
        _button('AUTO',Icons.shuffle,()=>command('MODE:AUTO')),
        _button('MANUAL',Icons.gamepad,()=>command('MODE:MANUAL')),
        _button('OFF',Icons.pause_circle,()=>command('MODE:OFF')),
        _button('STOP',Icons.stop_circle,()=>command('STOP'),primary:true),
      ]),
      const SizedBox(height:12),
      const Text('اضغط باستمرار للتحرك، وارفع صباعك للتوقف فورًا.',
        style: TextStyle(color:soft), textAlign:TextAlign.center),
      const SizedBox(height:12),
      Center(child:_driveKey('أمام',Icons.keyboard_arrow_up,'F')),
      const SizedBox(height:8),
      Row(mainAxisAlignment:MainAxisAlignment.center,children:[
        _driveKey('شمال',Icons.keyboard_arrow_left,'L'),
        const SizedBox(width:10),
        _driveKey('يمين',Icons.keyboard_arrow_right,'R'),
      ]),
      const SizedBox(height:8),
      Center(child:_driveKey('خلف',Icons.keyboard_arrow_down,'B')),
      const SizedBox(height:12),
      _button('إلغاء المحادثة',Icons.cancel_outlined,()=>command('CANCEL')),
      const SizedBox(height:15),
      _button('اختبار الذراع 45°',Icons.front_hand_outlined,()=>command('SERVO:45')),
      const SizedBox(height:10),
      _button('الذراع 90°',Icons.back_hand_outlined,()=>command('SERVO:90')),
      const SizedBox(height:10),
      _button('الذراع 135°',Icons.pan_tool_outlined,()=>command('SERVO:135')),
    ]))
  ]);
  Widget _settings()=>ListView(padding:const EdgeInsets.all(18),children:[
    _title('إعدادات Celyah','الربط والتشخيص'),
    _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Gemini AI',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      TextField(controller:geminiKey,obscureText:true,decoration:const InputDecoration(labelText:'Gemini API Key',hintText:'أدخل مفتاح Gemini')),
      SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('استخدام Gemini في الشات'),value:useGemini,onChanged:(v)=>setState(()=>useGemini=v)),
      SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('الرد الصوتي على المحادثة'),value:speakReplies,onChanged:(v)=>setState(()=>speakReplies=v)),
      const Text('المفتاح محفوظ في ذاكرة التطبيق أثناء الجلسة فقط. لا تستخدم مفتاحًا إنتاجيًا هنا؛ الأفضل خادم آمن.',style:TextStyle(color:soft,fontSize:12)),
    ])),
    const SizedBox(height:12),
    _card(Column(children:[
      TextField(controller:camera,decoration:const InputDecoration(labelText:'رابط كاميرا الروبوت',hintText:'http://192.168.1.100:81/jpg')),
      const SizedBox(height:8),
      TextField(controller:faceHost,decoration:const InputDecoration(labelText:'عنوان بث الوجه الحي',hintText:'http://192.168.4.1')),
    ])),
    const SizedBox(height:12),
    _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Bluetooth: ${link.status}'),
      const SizedBox(height:16),
      _button(link.connected?'قطع الاتصال':'البحث والاتصال',Icons.bluetooth,
        ()async{if(link.connected){await link.disconnect();}else{await link.connect();}}),
      const Divider(height:32),
      const Text('إعداد إنترنت الروبوت عبر Bluetooth',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      Text(wifiInfo,style:const TextStyle(color:soft)),
      const SizedBox(height:8),
      _button(wifiScanning?'جار البحث...':'البحث عن شبكات Wi-Fi',Icons.wifi_find,()async {
        if(!link.connected){_notice('وصل البلوتوث الأول');return;}
        await link.send('WIFI:SCAN');
      }),
      if(wifiNetworks.isNotEmpty) ...[
        const SizedBox(height:8),
        DropdownButtonFormField<String>(
          items:wifiNetworks.map((e)=>DropdownMenuItem(value:e,child:Text(e,overflow:TextOverflow.ellipsis))).toList(),
          onChanged:(v){if(v!=null)wifiSsid.text=v;},
          decoration:const InputDecoration(labelText:'الشبكات القريبة من الروبوت'),
        ),
      ],
      const SizedBox(height:8),
      TextField(controller:wifiSsid,decoration:const InputDecoration(labelText:'اسم الشبكة SSID')),
      const SizedBox(height:8),
      TextField(controller:wifiPassword,obscureText:true,decoration:const InputDecoration(labelText:'باسورد Wi-Fi')),
      const SizedBox(height:8),
      _button('اتصال وحفظ الشبكة',Icons.wifi,()async {
        if(!link.connected){_notice('وصل البلوتوث الأول');return;}
        final ssid=wifiSsid.text.trim();
        final pass=wifiPassword.text;
        if(ssid.isEmpty){_notice('اكتب اسم الشبكة');return;}
        await link.send('WIFI:SET:${base64.encode(utf8.encode(ssid))}|${base64.encode(utf8.encode(pass))}');
        if(mounted)setState(()=>wifiInfo='جار إرسال إعدادات الشبكة...');
      }),
      const SizedBox(height:8),
      _button('معرفة IP الروبوت',Icons.info_outline,()async {
        if(!link.connected){_notice('وصل البلوتوث الأول');return;}
        await link.send('WIFI:STATUS');
      }),
      const Text('الإعدادات تُرسل عبر BLE وتحفظ في الروبوت. يُفضل إجراء الإعداد في مكان موثوق، لأن BLE NUS هنا ليس قناة مشفرة على مستوى التطبيق.',style:TextStyle(color:soft)),
      const Divider(height:32),
      const Text('الوش المباشر عبر Wi-Fi',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      TextField(controller:faceHost,keyboardType:TextInputType.url,
        decoration:const InputDecoration(labelText:'عنوان الروبوت',hintText:'http://192.168.4.1')),
      const SizedBox(height:8),
      _button('تحديث عنوان الوش',Icons.refresh,()=>setState((){})),
      const Text('على شبكة CelYah استخدم http://192.168.4.1؛ وعلى شبكة البيت استخدم عنوان IP الذي يظهر في Serial Monitor. يجب أن يكون الهاتف والروبوت على نفس الشبكة.',style:TextStyle(color:soft)),
      const Divider(height:32),
      const Text('Gemini',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('قراءة ردود الروبوت بصوت'),
        subtitle:const Text('استخدام تحويل النص إلى كلام على الموبايل',style:TextStyle(color:soft)),
        value:speakReplies,onChanged:(v)=>setState(()=>speakReplies=v)),
      const Text('هذه النسخة ترسل الرسائل إلى firmware عبر BLE. '
        'لا تحفظ مفاتيح API داخل التطبيق أو الكود. أضف إدارة آمنة للمفتاح في مرحلة التكامل.',
        style:TextStyle(color:soft)),
      const Divider(height:32),
      const Text('إصدار V14 — وجه ومحادثة في شاشة واحدة',style:TextStyle(color:soft)),
      const Text('تم الحفاظ على بروتوكول Nordic UART الخاص بـ V7.',style:TextStyle(color:soft))
    ]))
  ]);
}
class EyePainter extends CustomPainter {
  final String face;
  EyePainter(this.face);
  @override void paint(Canvas canvas,Size size){
    final scale=(size.width/360).clamp(.5,2.0);
    final center=Offset(size.width/2,size.height/2);
    canvas.save();canvas.translate(center.dx,center.dy);
    canvas.scale(scale,scale);
    final paint=Paint()..color=lavender..isAntiAlias=true;
    final glow=Paint()..color=lavender.withValues(alpha:.22)
      ..maskFilter=const MaskFilter.blur(BlurStyle.normal,12);
    final stroke=Paint()..color=const Color(0xFFD9A4FF)..style=PaintingStyle.stroke
      ..strokeWidth=5..strokeCap=StrokeCap.round;
    final f=face.toLowerCase();
    final closed=['happy','laugh','laughing','satisfied','sleepy','sleep','dancing','blink','blinking'].contains(f);
    final hearts=['love','heart','heart_big'].contains(f);
    final sad=['sad','crying','scared','shy'].contains(f);
    final angry=['angry','annoyed','determined'].contains(f);
    final winkL=['wink','wink_left','cheeky'].contains(f);
    final winkR=['wink_right'].contains(f);
    final looking=['curious','thinking','confused'].contains(f);
    final eyesY=-4.0;
    for(var i=0;i<2;i++){
      final x=i==0?-82.0:82.0;
      final brow=Path()..moveTo(x-33,-80)
        ..quadraticBezierTo(x,-104+(sad?15:0)+(angry?20:0),x+33,-80+(angry?-10:0));
      canvas.drawPath(brow,stroke);
      if(hearts){
        final heart=Path()..moveTo(x,eyesY+40)
          ..cubicTo(x-70,eyesY-6,x-31,eyesY-51,x,eyesY-24)
          ..cubicTo(x+31,eyesY-51,x+70,eyesY-6,x,eyesY+40);
        canvas.drawPath(heart,glow);canvas.drawPath(heart,paint);continue;
      }
      if(closed || (i==0&&winkL) || (i==1&&winkR)){
        final arc=Path()..moveTo(x-35,eyesY+20)
          ..quadraticBezierTo(x,eyesY-31,x+35,eyesY+20);
        canvas.drawPath(arc,Paint()..color=lavender..style=PaintingStyle.stroke
          ..strokeWidth=10..strokeCap=StrokeCap.round);continue;
      }
      // Soft rounded vertical eyes, not plain ellipses: tapered top and rounded bottom.
      final eye=Path()..moveTo(x,eyesY-52)
        ..cubicTo(x-35,eyesY-52,x-44,eyesY-20,x-42,eyesY+10)
        ..cubicTo(x-40,eyesY+49,x-19,eyesY+54,x,eyesY+54)
        ..cubicTo(x+19,eyesY+54,x+40,eyesY+49,x+42,eyesY+10)
        ..cubicTo(x+44,eyesY-20,x+35,eyesY-52,x,eyesY-52)..close();
      canvas.drawPath(eye,glow);canvas.drawPath(eye,paint);
      final shift=looking?(i==0?10.0:-10.0):0.0;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(
        center:Offset(x+shift,eyesY+7),width:32,height:60),const Radius.circular(16)),
        Paint()..color=const Color(0xFF16091F));
      canvas.drawOval(Rect.fromCenter(center:Offset(x+shift-9,eyesY-21),width:15,height:20),
        Paint()..color=Colors.white);
      canvas.drawCircle(Offset(x+shift+11,eyesY+24),5,
        Paint()..color=const Color(0xFFFFE3FF));
    }
    final mouth=Path()..moveTo(-13,86)..quadraticBezierTo(0,96,13,86);
    if(['excited','laugh','laughing','playful','surprised'].contains(f)){
      canvas.drawOval(Rect.fromCenter(center:const Offset(0,89),width:28,height:25),paint);
    } else if(sad){
      final down=Path()..moveTo(-14,96)..quadraticBezierTo(0,79,14,96);
      canvas.drawPath(down,stroke);
    } else if(!['sleepy','sleep','bored','angry'].contains(f)){
      canvas.drawPath(mouth,stroke);
    }
    if(['shy','embarrassed','cute','playful'].contains(f)){
      for(final x in [-133.0,133.0]){
        for(var j=0;j<3;j++)canvas.drawLine(Offset(x+j*6-6,62),Offset(x+j*6-12,75),
          Paint()..color=const Color(0xFFFF83D9)..strokeWidth=3..strokeCap=StrokeCap.round);
      }
    }
    canvas.restore();
  }
  @override bool shouldRepaint(covariant EyePainter old)=>old.face!=face;
}
