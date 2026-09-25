import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'; 

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MobileAds.instance.initialize(); 
  NativeFtpClient.init();
  runApp(const FtpProApp());
}

class FtpProApp extends StatelessWidget {
  const FtpProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ftp Core',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF10131A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF000000),
          foregroundColor: Colors.white,
          elevation: 2,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2A2E35),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            disabledBackgroundColor: const Color(0xFF1E2229),
            disabledForegroundColor: Colors.grey,
          ),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}

class FtpProfile {
  String name;
  String mode;
  String host;
  String user;
  String password;
  String privateKey;
  bool savePassword;
  bool passiveMode;
  bool binaryMode;
  String port;
  String localPath;
  String remotePath;
  String charset;

  FtpProfile({
    required this.name,
    this.mode = 'FTP',
    this.host = '',
    this.user = '',
    this.password = '',
    this.privateKey = '',
    this.savePassword = true,
    this.passiveMode = true,
    this.binaryMode = true,
    this.port = '21',
    this.localPath = '',
    this.remotePath = '',
    this.charset = 'UTF-8',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'mode': mode,
        'host': host,
        'user': user,
        'password': savePassword ? password : '',
        'privateKey': privateKey,
        'savePassword': savePassword,
        'passiveMode': passiveMode,
        'binaryMode': binaryMode,
        'port': port,
        'localPath': localPath,
        'remotePath': remotePath,
        'charset': charset,
      };

  factory FtpProfile.fromJson(Map<String, dynamic> json) => FtpProfile(
        name: json['name'],
        mode: json['mode'] ?? 'FTP',
        host: json['host'] ?? '',
        user: json['user'] ?? '',
        password: json['password'] ?? '',
        privateKey: json['privateKey'] ?? '',
        savePassword: json['savePassword'] ?? true,
        passiveMode: json['passiveMode'] ?? true,
        binaryMode: json['binaryMode'] ?? true,
        port: json['port'] ?? '21',
        localPath: json['localPath'] ?? '',
        remotePath: json['remotePath'] ?? '',
        charset: json['charset'] ?? 'UTF-8',
      );
}

class RemoteEntry {
  final String name;
  final bool isDir;
  final int size;

  RemoteEntry({required this.name, required this.isDir, required this.size});
}

String formatBytes(int bytes) {
  if (bytes <= 0) return "0 B";
  const suffixes = ["B", "KB", "MB", "GB", "TB"];
  var i = (log(bytes) / log(1024)).floor();
  return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
}

class NativeFtpClient {
  static const platform = MethodChannel('ftp_native');
  static Function(int transferred, int total)? onProgress;

  static void init() {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        if (onProgress != null) {
          int transferred = call.arguments['transferred'] ?? 0;
          int total = call.arguments['total'] ?? 0;
          onProgress!(transferred, total);
        }
      }
    });
  }

  static Future<void> connect(String mode, String host, int port, String user, String pass, {bool passive = true, bool binary = true}) async {
    await platform.invokeMethod('connect', {
      'mode': mode, 'host': host, 'port': port, 'user': user, 'pass': pass,
      'passive': passive, 'binary': binary
    });
  }
  
  static Future<bool> noop() async {
    try {
      final result = await platform.invokeMethod('noop');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> disconnect() async {
    try {
      await platform.invokeMethod('disconnect');
    } catch (_) {}
  }

  static Future<void> cancel() async {
    await platform.invokeMethod('cancel');
  }

  static Future<List<RemoteEntry>> list(String path) async {
    final List<dynamic> res = await platform.invokeMethod('list', {'path': path});
    return res.map((e) => RemoteEntry(
      name: e['name'],
      isDir: e['isDir'],
      size: e['size'],
    )).where((e) => e.name != '.' && e.name != '..' && e.name.trim().isNotEmpty).toList();
  }

  static Future<void> changeDirectory(String path) async {
    await platform.invokeMethod('cd', {'path': path});
  }

  static Future<void> makeDirectory(String path) async {
    await platform.invokeMethod('mkdir', {'name': path});
  }

  static Future<void> rename(String oldPath, String newPath) async {
    await platform.invokeMethod('rename', {'old': oldPath, 'new': newPath});
  }

  static Future<void> delete(String path, bool isDir) async {
    await platform.invokeMethod('delete', {'name': path, 'isDir': isDir});
  }

  static Future<void> upload(String localPath, String remotePath) async {
    await platform.invokeMethod('upload', {'localPath': localPath, 'remotePath': remotePath});
  }

  static Future<void> download(String remotePath, String localPath) async {
    await platform.invokeMethod('download', {'remotePath': remotePath, 'localPath': localPath});
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  List<FtpProfile> profiles = [];
  FtpProfile? selectedProfile;
  bool _isConnecting = false;
  final _secureStorage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final String? profilesJson = await _secureStorage.read(key: 'profiles_data');
    if (profilesJson != null) {
      final List<dynamic> decoded = json.decode(profilesJson);
      setState(() {
        profiles = decoded.map((e) => FtpProfile.fromJson(e)).toList();
        if (profiles.isNotEmpty) {
          selectedProfile = profiles.first;
        } else {
          selectedProfile = null;
        }
      });
    } else {
      setState(() {
        profiles = [];
        selectedProfile = null;
      });
    }
  }

  Future<void> _saveProfiles() async {
    final String encoded = json.encode(profiles.map((p) => p.toJson()).toList());
    await _secureStorage.write(key: 'profiles_data', value: encoded);
  }

  void _openEditor({FtpProfile? profileToEdit}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: profileToEdit)),
    );

    if (result != null && result is FtpProfile) {
      setState(() {
        if (profileToEdit != null) {
          int index = profiles.indexOf(profileToEdit);
          if (index != -1) profiles[index] = result;
        } else {
          profiles.add(result);
        }
        selectedProfile = result;
      });
      _saveProfiles();
    }
  }

  void _deleteSelectedProfile() async {
    bool confirm = await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Delete Profile"),
        content: const Text("Are you sure you want to delete this profile?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("No")),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Yes", style: TextStyle(color: Colors.red))),
        ],
      )
    ) ?? false;

    if (confirm) {
      setState(() {
        profiles.remove(selectedProfile);
        selectedProfile = profiles.isNotEmpty ? profiles.first : null;
      });
      _saveProfiles();
    }
  }

  Future<void> _connect() async {
    if (selectedProfile == null || _isConnecting) return;

    setState(() { _isConnecting = true; });
    String errorMessage = "";
    int portToUse = int.tryParse(selectedProfile!.port) ?? 21;

    if (selectedProfile!.mode.contains('FTPS') && portToUse == 21) portToUse = 990;
    else if (selectedProfile!.mode.contains('SFTP') && portToUse == 21) portToUse = 22;

    try {
      if (selectedProfile!.mode.contains('SFTP')) {
        final socket = await SSHSocket.connect(selectedProfile!.host, portToUse).timeout(const Duration(seconds: 15));
        List<SSHKeyPair> identities = [];
        if (selectedProfile!.privateKey.isNotEmpty) {
          final keyFile = File(selectedProfile!.privateKey);
          if (keyFile.existsSync()) {
            identities = SSHKeyPair.fromPem(keyFile.readAsStringSync());
          }
        }
        final client = SSHClient(
          socket,
          username: selectedProfile!.user,
          identities: identities.isNotEmpty ? identities : null,
          onPasswordRequest: selectedProfile!.password.isNotEmpty ? () => selectedProfile!.password : null,
        );
        await client.authenticated;
        await client.sftp();
        client.close();
      } else {
        await NativeFtpClient.connect(
          selectedProfile!.mode,
          selectedProfile!.host,
          portToUse,
          selectedProfile!.user,
          selectedProfile!.password,
          passive: selectedProfile!.passiveMode,
          binary: selectedProfile!.binaryMode,
        );
      }
    } catch (e) {
      String errStr = e.toString().toLowerCase();
      if (errStr.contains('530') || errStr.contains('auth') || errStr.contains('login failed')) {
        errorMessage = "Invalid user name or password.";
      } else if (errStr.contains('socket') || errStr.contains('failed host lookup') || errStr.contains('connection refused') || errStr.contains('host not found')) {
        errorMessage = "Could not connect to server. Check host or port.";
      } else if (errStr.contains('timeout')) {
        errorMessage = "Connection timed out. Server is not responding.";
      } else {
        errorMessage = "Connection error: ${e.toString()}";
      }
    }

    setState(() { _isConnecting = false; });

    if (errorMessage.isNotEmpty) {
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("Login error", style: TextStyle(color: Colors.lightBlueAccent)),
          content: Text(errorMessage),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text("OK", style: TextStyle(color: Colors.blueAccent)))],
        ),
      );
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DualFileManagerScreen(profile: selectedProfile!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [Icon(Icons.public, color: Colors.blueAccent), SizedBox(width: 8), Text('Ftp Core')]),
        actions: [IconButton(icon: const Icon(Icons.more_vert), onPressed: () {})],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text('Profile:', style: TextStyle(fontSize: 16, color: Colors.grey)),
                      const SizedBox(width: 20),
                      Expanded(
                        child: DropdownButton<FtpProfile>(
                          value: selectedProfile,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF2A2E35),
                          underline: Container(height: 1, color: Colors.grey),
                          items: profiles.isEmpty 
                              ? [const DropdownMenuItem<FtpProfile>(value: null, child: Text('', style: TextStyle(color: Colors.grey)))]
                              : profiles.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
                          onChanged: profiles.isEmpty ? null : (val) { if (val != null) setState(() => selectedProfile = val); },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity, height: 45,
                    child: ElevatedButton(
                      onPressed: (_isConnecting || selectedProfile == null) ? null : _connect,
                      child: _isConnecting 
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Connect', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: ElevatedButton(onPressed: selectedProfile == null ? null : _deleteSelectedProfile, child: const Text('Delete'))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton(onPressed: selectedProfile == null ? null : () => _openEditor(profileToEdit: selectedProfile), child: const Text('Edit'))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton(onPressed: () => _openEditor(), child: const Text('New'))),
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  final FtpProfile? profile;
  const EditProfileScreen({super.key, this.profile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController nameCtrl, hostCtrl, userCtrl, passCtrl, privateKeyCtrl, portCtrl, localPathCtrl, remotePathCtrl;
  String selectedMode = 'FTP';
  String selectedCharset = 'UTF-8';
  bool savePass = true, isPassive = true, isBinary = true;

  final List<String> ftpModes = ['FTP', 'FTPES (Explicit secure FTP)', 'FTPS (Implicit secure FTP)', 'SFTP (FTP over SSH)'];
  final List<String> charsets = ['UTF-8', 'ISO-8859-1', 'Windows-1254'];

  @override
  void initState() {
    super.initState();
    nameCtrl = TextEditingController(text: widget.profile?.name ?? '');
    hostCtrl = TextEditingController(text: widget.profile?.host ?? '');
    userCtrl = TextEditingController(text: widget.profile?.user ?? '');
    passCtrl = TextEditingController(text: widget.profile?.password ?? '');
    privateKeyCtrl = TextEditingController(text: widget.profile?.privateKey ?? '');
    portCtrl = TextEditingController(text: widget.profile?.port ?? '21');
    localPathCtrl = TextEditingController(text: widget.profile?.localPath ?? '');
    remotePathCtrl = TextEditingController(text: widget.profile?.remotePath ?? '');
    
    if (widget.profile != null) {
      selectedMode = widget.profile!.mode;
      if (!ftpModes.contains(selectedMode)) selectedMode = 'FTP';
      savePass = widget.profile!.savePassword;
      isPassive = widget.profile!.passiveMode;
      isBinary = widget.profile!.binaryMode;
      selectedCharset = charsets.contains(widget.profile!.charset) ? widget.profile!.charset : 'UTF-8';
    }
  }

  void _save() {
    if (nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile name is mandatory!')));
      return;
    }
    Navigator.pop(context, FtpProfile(
      name: nameCtrl.text.trim(), mode: selectedMode, host: hostCtrl.text.trim(),
      user: userCtrl.text.trim(), password: passCtrl.text, privateKey: privateKeyCtrl.text.trim(),
      savePassword: savePass, passiveMode: isPassive, binaryMode: isBinary,
      port: portCtrl.text, localPath: localPathCtrl.text, remotePath: remotePathCtrl.text, charset: selectedCharset,
    ));
  }

  Future<void> _showDirectoryPicker() async {
    await Permission.manageExternalStorage.request();
    await Permission.storage.request();
    String currentPath = localPathCtrl.text.isNotEmpty ? localPathCtrl.text : '/storage/emulated/0';
    if (!Directory(currentPath).existsSync()) currentPath = '/storage/emulated/0';
    String selectedPath = currentPath;
    List<FileSystemEntity> dirs = [];

    void loadDirs(String path, StateSetter setDialogState) {
      try {
        final dir = Directory(path);
        if (dir.existsSync()) {
          dirs = dir.listSync().where((e) => FileSystemEntity.isDirectorySync(e.path)).toList();
          dirs.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
          currentPath = path;
        }
      } catch (_) {}
      setDialogState(() {});
    }

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (dirs.isEmpty && Directory(currentPath).existsSync()) {
             try { dirs = Directory(currentPath).listSync().where((e) => FileSystemEntity.isDirectorySync(e.path)).toList()..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase())); } catch(_) {}
          }
          return AlertDialog(
            title: Text('Local path:\n$currentPath', style: const TextStyle(fontSize: 14, color: Colors.blueAccent)),
            contentPadding: const EdgeInsets.all(8),
            content: SizedBox(
              width: double.maxFinite, height: 400,
              child: Column(
                children: [
                  if (currentPath != '/storage/emulated/0' && currentPath != '/')
                    ListTile(dense: true, leading: const Icon(Icons.folder, color: Colors.blueAccent), title: const Text('..'), onTap: () => loadDirs(Directory(currentPath).parent.path, setDialogState)),
                  Expanded(
                    child: ListView.builder(
                      itemCount: dirs.length,
                      itemBuilder: (context, index) {
                        final dir = dirs[index];
                        return ListTile(
                          dense: true, leading: const Icon(Icons.folder, color: Colors.blueAccent), title: Text(dir.path.split('/').last),
                          trailing: Checkbox(activeColor: Colors.blueAccent, value: selectedPath == dir.path, onChanged: (val) => setDialogState(() => selectedPath = dir.path)),
                          onTap: () => loadDirs(dir.path, setDialogState),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(onPressed: () { localPathCtrl.text = selectedPath; Navigator.pop(context); }, child: const Text('OK')),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showFilePicker() async {
    await Permission.manageExternalStorage.request();
    await Permission.storage.request();
    String currentPath = '/storage/emulated/0';
    String selectedFile = '';
    List<FileSystemEntity> entities = [];

    void loadEntities(String path, StateSetter setDialogState) {
      try {
        final dir = Directory(path);
        if (dir.existsSync()) {
          entities = dir.listSync()..sort((a, b) {
            bool aIsDir = FileSystemEntity.isDirectorySync(a.path);
            bool bIsDir = FileSystemEntity.isDirectorySync(b.path);
            if (aIsDir && !bIsDir) return -1;
            if (!aIsDir && bIsDir) return 1;
            return a.path.toLowerCase().compareTo(b.path.toLowerCase());
          });
          currentPath = path;
        }
      } catch (_) {}
      setDialogState(() {});
    }

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (entities.isEmpty && Directory(currentPath).existsSync()) loadEntities(currentPath, setDialogState);
          return AlertDialog(
            title: Text('Select Key File:\n$currentPath', style: const TextStyle(fontSize: 14, color: Colors.blueAccent)),
            contentPadding: const EdgeInsets.all(8),
            content: SizedBox(
              width: double.maxFinite, height: 400,
              child: Column(
                children: [
                  if (currentPath != '/storage/emulated/0' && currentPath != '/')
                    ListTile(dense: true, leading: const Icon(Icons.folder, color: Colors.blueAccent), title: const Text('..'), onTap: () => loadEntities(Directory(currentPath).parent.path, setDialogState)),
                  Expanded(
                    child: ListView.builder(
                      itemCount: entities.length,
                      itemBuilder: (context, index) {
                        final entity = entities[index];
                        final isDir = FileSystemEntity.isDirectorySync(entity.path);
                        return ListTile(
                          dense: true, leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: Colors.blueAccent), title: Text(entity.path.split('/').last),
                          trailing: isDir ? const SizedBox.shrink() : Checkbox(activeColor: Colors.blueAccent, value: selectedFile == entity.path, onChanged: (val) => setDialogState(() => selectedFile = entity.path)),
                          onTap: () { if (isDir) loadEntities(entity.path, setDialogState); else setDialogState(() => selectedFile = entity.path); },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(onPressed: () { if (selectedFile.isNotEmpty) privateKeyCtrl.text = selectedFile; Navigator.pop(context); }, child: const Text('OK')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.profile == null ? 'New Profile' : 'Edit Profile'),
          bottom: const TabBar(indicatorColor: Colors.lightBlueAccent, tabs: [Tab(text: 'PROFILE PROPERTIES'), Tab(text: 'MORE PROPERTIES')]),
        ),
        body: TabBarView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _buildLabelRow('* Profile:', TextField(controller: nameCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Profile Name'))),
                    const SizedBox(height: 16),
                    _buildLabelRow('FTP Mode:', DropdownButton<String>(
                      isExpanded: true, value: selectedMode,
                      items: ftpModes.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            selectedMode = val;
                            if (selectedMode == 'SFTP (FTP over SSH)') portCtrl.text = '22';
                            else if (selectedMode == 'FTPS (Implicit secure FTP)') portCtrl.text = '990'; 
                            else if (portCtrl.text == '22' || portCtrl.text == '990') portCtrl.text = '21';
                          });
                        }
                      },
                    )),
                    const SizedBox(height: 16),
                    _buildLabelRow('* Host:', TextField(controller: hostCtrl, decoration: const InputDecoration(isDense: true))),
                    const SizedBox(height: 16),
                    _buildLabelRow('User:', TextField(controller: userCtrl, decoration: const InputDecoration(isDense: true, hintText: 'blank for anonymous'))),
                    const SizedBox(height: 16),
                    _buildLabelRow('Password:', Row(children: [Expanded(child: TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(isDense: true))), Checkbox(value: savePass, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => savePass = v ?? true)), const Text('Save')])),
                    const SizedBox(height: 16),
                    _buildLabelRow('Transfer:', Row(children: [Checkbox(value: isPassive, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => isPassive = v ?? true)), const Text('Passive'), const SizedBox(width: 16), Checkbox(value: isBinary, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => isBinary = v ?? true)), const Text('Binary')])),
                    if (selectedMode == 'SFTP (FTP over SSH)') ...[
                      const SizedBox(height: 16),
                      _buildLabelRow('Private key:', Row(children: [Expanded(child: TextField(controller: privateKeyCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Key path'))), const SizedBox(width: 8), ElevatedButton(onPressed: _showFilePicker, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), minimumSize: const Size(0, 36)), child: const Text('Browse...', style: TextStyle(fontSize: 12)))])),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _buildLabelRow('Port:', TextField(controller: portCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true))),
                    const SizedBox(height: 16),
                    _buildLabelRow('Local path:', Row(children: [Expanded(child: TextField(controller: localPathCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Optional local path'))), const SizedBox(width: 8), ElevatedButton(onPressed: _showDirectoryPicker, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), minimumSize: const Size(0, 36)), child: const Text('Browser', style: TextStyle(fontSize: 12)))])),
                    const SizedBox(height: 16),
                    _buildLabelRow('Remote path:', TextField(controller: remotePathCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Optional remote path'))),
                    const SizedBox(height: 16),
                    _buildLabelRow('Charset:', DropdownButton<String>(isExpanded: true, value: selectedCharset, items: charsets.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(), onChanged: (val) { if (val != null) setState(() => selectedCharset = val); })),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('* mandatory fields', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 8),
                Row(children: [Expanded(child: ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))), const SizedBox(width: 8), Expanded(child: ElevatedButton(onPressed: _save, child: const Text('Save')))]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabelRow(String label, Widget child) {
    return Row(children: [Expanded(flex: 2, child: Text(label, textAlign: TextAlign.right, style: const TextStyle(color: Colors.grey))), const SizedBox(width: 16), Expanded(flex: 5, child: child)]);
  }
}

class DualFileManagerScreen extends StatefulWidget {
  final FtpProfile profile;
  const DualFileManagerScreen({super.key, required this.profile});

  @override
  State<DualFileManagerScreen> createState() => _DualFileManagerScreenState();
}

class _DualFileManagerScreenState extends State<DualFileManagerScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  String _sortMethod = 'Name'; 
  String localPath = '/storage/emulated/0';
  List<FileSystemEntity> localFiles = [];
  bool localLoading = true;
  final Set<String> _selectedLocalPaths = {};

  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  bool get _isSftp => widget.profile.mode.contains('SFTP');

  List<RemoteEntry> remoteFiles = [];
  bool remoteLoading = true;
  String remotePath = '/';
  String remoteError = '';
  final Set<String> _selectedRemoteNames = {};
  
  bool _isNetworkBusy = false;
  int _currentNetworkRequestId = 0;
  bool _isDisconnectDialogShowing = false;
  Timer? _keepAliveTimer;
  bool _isAppPaused = false;

  BannerAd? _bannerAd;
  bool _isBannerAdLoaded = false;
  final String _adUnitId = 'ca-app-pub-3940256099942544/6300978111'; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); 
    if (widget.profile.localPath.isNotEmpty) localPath = widget.profile.localPath;
    else localPath = '/storage/emulated/0';
    if (widget.profile.remotePath.isNotEmpty) remotePath = widget.profile.remotePath;
    
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
    _initLocal();
    _initRemote();
    
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pingServer());
    _loadAd(); 
  }

  void _loadAd() {
    _bannerAd = BannerAd(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      size: AdSize.banner,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted) {
            setState(() { _isBannerAdLoaded = true; });
          }
        },
        onAdFailedToLoad: (ad, err) {
          ad.dispose();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); 
    _keepAliveTimer?.cancel();
    _sshClient?.close();
    if (!_isSftp) NativeFtpClient.disconnect();
    _tabController.dispose();
    _bannerAd?.dispose(); 
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isAppPaused = true;
    } else if (state == AppLifecycleState.resumed) {
      _isAppPaused = false;
      _pingServer(); 
    }
  }
  
  Future<void> _pingServer() async {
    if (_isAppPaused || _isDisconnectDialogShowing || remoteLoading || remoteError.isNotEmpty) return;
    try {
      bool isAlive = false;
      if (_isSftp) {
        await _sftpClient?.stat('.'); 
        isAlive = true;
      } else {
        isAlive = await NativeFtpClient.noop(); 
      }
      
      if (!isAlive) {
        _initRemote(silent: true);
      }
    } catch (_) {
      _initRemote(silent: true);
    }
  }

  bool _isConnectionError(dynamic e) {
    String err = e.toString().toLowerCase();
    return err.contains('socket') || err.contains('closed') || err.contains('pipe') || 
           err.contains('disconnect') || err.contains('connection') || err.contains('timeout') ||
           err.contains('handshake') || err.contains('wrong_version') || err.contains('tls') ||
           err.contains('reset') || err.contains('broken');
  }

  void _showDisconnectDialog() {
    if (_isDisconnectDialogShowing) return;
    _isDisconnectDialogShowing = true;
    showDialog(
      context: context, barrierDismissible: false, 
      builder: (c) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.redAccent), SizedBox(width: 8), Text('Connection Lost', style: TextStyle(color: Colors.redAccent))]),
        content: const Text('The connection to the server has been lost or timed out.\n\nWould you like to stay offline on this screen or logout?'),
        actions: [
          TextButton(onPressed: () { _isDisconnectDialogShowing = false; Navigator.pop(c); }, child: const Text('Stay', style: TextStyle(color: Colors.white))),
          TextButton(onPressed: () { _isDisconnectDialogShowing = false; Navigator.pop(c); if(!_isSftp) NativeFtpClient.disconnect(); _sshClient?.close(); Navigator.pop(context); }, child: const Text('Logout', style: TextStyle(color: Colors.redAccent))),
        ],
      )
    ).then((_) => _isDisconnectDialogShowing = false);
  }

  Future<bool> _onWillPop() async {
    if (_tabController.index == 0) {
      if (localPath.isNotEmpty && localPath != '/storage/emulated/0' && localPath != '/') {
        if (!localLoading) _loadLocal(Directory(localPath).parent.path);
        return false;
      }
    } else {
      if (remotePath.isNotEmpty && remotePath != '/') { _changeRemoteDirectory('..'); return false; }
    }
    return true;
  }

  void _sortLocalFiles(List<FileSystemEntity> folders, List<FileSystemEntity> files) {
    if (_sortMethod == 'Name') {
      folders.sort((a, b) => a.path.split('/').last.toLowerCase().compareTo(b.path.split('/').last.toLowerCase()));
      files.sort((a, b) => a.path.split('/').last.toLowerCase().compareTo(b.path.split('/').last.toLowerCase()));
    } else if (_sortMethod == 'Size') {
      files.sort((a, b) {
        int aSize = 0, bSize = 0;
        try { aSize = File(a.path).lengthSync(); } catch (_) {}
        try { bSize = File(b.path).lengthSync(); } catch (_) {}
        return bSize.compareTo(aSize); 
      });
    }
  }

  void _sortRemoteFiles(List<RemoteEntry> folders, List<RemoteEntry> files) {
    if (_sortMethod == 'Name') {
      folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (_sortMethod == 'Size') {
      folders.sort((a, b) => b.size.compareTo(a.size));
    }
  }

  void _showSortDialog() {
    showDialog(context: context, builder: (context) {
        return AlertDialog(
          title: const Text('Sort by'),
          content: Column(
            mainAxisSize: min(2, 2) == 2 ? MainAxisSize.min : MainAxisSize.max,
            children: ['Name', 'Size'].map((mode) {
              return RadioListTile<String>(title: Text(mode), value: mode, groupValue: _sortMethod, onChanged: (val) {
                  setState(() => _sortMethod = val!); Navigator.pop(context);
                  if (_tabController.index == 0) _loadLocal(localPath); else { _goToRemotePath(remotePath); }
              });
            }).toList(),
          ),
        );
      }
    );
  }

  void _openPathInputDialog(bool isLocal) {
    TextEditingController pathCtrl = TextEditingController(text: isLocal ? localPath : remotePath);
    showDialog(context: context, builder: (c) => AlertDialog(
        title: Text(isLocal ? 'Go to Local Path' : 'Go to Remote Path'),
        content: TextField(controller: pathCtrl, autofocus: true, decoration: const InputDecoration(hintText: 'Enter path'), onSubmitted: (val) { Navigator.pop(c); _navigateToPath(val.trim(), isLocal); }),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), TextButton(onPressed: () { Navigator.pop(c); _navigateToPath(pathCtrl.text.trim(), isLocal); }, child: const Text('Go'))],
    ));
  }

  Future<void> _navigateToPath(String newPath, bool isLocal) async {
    if (newPath.isEmpty) return;
    if (isLocal) {
      if (Directory(newPath).existsSync()) _loadLocal(newPath); else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Path does not exist.')));
    } else _goToRemotePath(newPath);
  }

  Future<void> _initLocal() async {
    await Permission.manageExternalStorage.request(); await Permission.storage.request();
    if (localPath.isEmpty) localPath = '/storage/emulated/0';
    _loadLocal(localPath);
  }

  void _loadLocal(String path) {
    setState(() => localLoading = true);
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        final entities = dir.listSync(recursive: false);
        List<FileSystemEntity> folders = []; List<FileSystemEntity> files = [];
        for (var e in entities) { if (FileSystemEntity.isDirectorySync(e.path)) folders.add(e); else files.add(e); }
        _sortLocalFiles(folders, files);
        setState(() { localFiles = [...folders, ...files]; localPath = path; _selectedLocalPaths.clear(); localLoading = false; });
      } else setState(() => localLoading = false);
    } catch (_) { setState(() => localLoading = false); }
  }

  Future<void> _initRemote({bool silent = false}) async {
    setState(() { remoteLoading = true; remoteError = ''; });
    int portToUse = int.tryParse(widget.profile.port) ?? 21;
    if (widget.profile.mode.contains('FTPS') && portToUse == 21) portToUse = 990;
    if (widget.profile.mode.contains('SFTP') && portToUse == 21) portToUse = 22;

    try {
      if (_isSftp) {
        final socket = await SSHSocket.connect(widget.profile.host, portToUse).timeout(const Duration(seconds: 15));
        List<SSHKeyPair> identities = [];
        if (widget.profile.privateKey.isNotEmpty) {
          final keyFile = File(widget.profile.privateKey);
          if (keyFile.existsSync()) identities = SSHKeyPair.fromPem(keyFile.readAsStringSync());
        }
        _sshClient = SSHClient(socket, username: widget.profile.user, identities: identities.isNotEmpty ? identities : null, onPasswordRequest: widget.profile.password.isNotEmpty ? () => widget.profile.password : null);
        _sftpClient = await _sshClient!.sftp();
      } else {
        await NativeFtpClient.disconnect();
        await NativeFtpClient.connect(
          widget.profile.mode, 
          widget.profile.host, 
          portToUse, 
          widget.profile.user, 
          widget.profile.password,
          passive: widget.profile.passiveMode,
          binary: widget.profile.binaryMode,
        );
      }
      _goToRemotePath(remotePath, silent: silent);
    } catch (e) {
      if (silent) {
        _showDisconnectDialog();
        if (mounted) setState(() { remoteLoading = false; remoteError = ''; });
      } else {
        if (_isConnectionError(e)) _showDisconnectDialog();
        if (mounted) setState(() { remoteLoading = false; remoteError = e.toString(); });
      }
    }
  }

  void _goToRemotePath(String targetPath, {bool silent = false}) {
    setState(() {
      remotePath = targetPath;
      remoteFiles = []; 
      remoteLoading = true; 
      remoteError = '';
    });
    _fetchRemoteData(targetPath, silent: silent);
  }

  Future<void> _fetchRemoteData(String fetchPath, {bool silent = false}) async {
    int myRequestId = ++_currentNetworkRequestId;
    while (_isNetworkBusy) { await Future.delayed(const Duration(milliseconds: 10)); if (myRequestId != _currentNetworkRequestId) return; }
    _isNetworkBusy = true;
    
    try {
      List<RemoteEntry> folders = []; List<RemoteEntry> files = [];

      if (_isSftp) {
        final content = await _sftpClient!.listdir(fetchPath == '/' ? '.' : fetchPath).timeout(const Duration(seconds: 15));
        for (var e in content) {
          if (e.filename == '.' || e.filename == '..') continue;
          final isDir = e.attr.isDirectory;
          final entry = RemoteEntry(name: e.filename, isDir: isDir, size: e.attr.size ?? 0);
          if (isDir) folders.add(entry); else files.add(entry);
        }
      } else {
        final content = await NativeFtpClient.list(fetchPath);
        for (var e in content) {
          if (e.isDir) folders.add(e); else files.add(e);
        }
      }
      
      _sortRemoteFiles(folders, files);
      final resultList = [...folders, ...files];

      if (mounted && remotePath == fetchPath) {
        setState(() { remoteFiles = resultList; remoteLoading = false; _selectedRemoteNames.clear(); });
      }
    } catch (e) {
      if (!silent && _isConnectionError(e)) _showDisconnectDialog(); 
      if (mounted && remotePath == fetchPath) {
        setState(() { remoteLoading = false; remoteError = 'Error: $e'; });
      }
    } finally { _isNetworkBusy = false; }
  }

  void _changeRemoteDirectory(String dirName) {
    String targetPath = remotePath;
    if (dirName == '..') {
      if (remotePath != '/' && remotePath.isNotEmpty) {
        List<String> parts = remotePath.split('/').where((e) => e.isNotEmpty).toList();
        if (parts.isNotEmpty) parts.removeLast();
        targetPath = parts.isEmpty ? '/' : '/${parts.join('/')}';
      } else targetPath = '/';
    } else targetPath = remotePath.endsWith('/') ? '$remotePath$dirName' : '$remotePath/$dirName';
    
    _goToRemotePath(targetPath, silent: false); 
  }

  void _createDirectory() {
    TextEditingController ctrl = TextEditingController(); 
    bool isLocal = _tabController.index == 0;
    
    showDialog(context: context, builder: (c) => AlertDialog(
        title: const Text('Create Directory'), 
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Type name for new directory')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () async {
              Navigator.pop(c); 
              String name = ctrl.text.trim(); 
              if (name.isEmpty) return;
              
              if (isLocal) { 
                try {
                  Directory newDir = Directory('$localPath/$name');
                  if (newDir.existsSync()) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create "$name"')));
                  } else {
                    newDir.createSync();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Directory "$name" created')));
                    _loadLocal(localPath); 
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create "$name"')));
                }
              } else {
                try {
                  String newDirPath = remotePath == '/' ? '/$name' : '$remotePath/$name';
                  if (_isSftp) await _sftpClient!.mkdir(newDirPath); 
                  else await NativeFtpClient.makeDirectory(newDirPath);
                  
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Directory "$name" created')));
                  _goToRemotePath(remotePath);
                } catch (e) { 
                  if (_isConnectionError(e)) {
                    _showDisconnectDialog(); 
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create "$name"')));
                  }
                }
              }
            }, child: const Text('OK')),
        ],
      )
    );
  }

  void _renameItem(String oldName, bool isLocal) {
    String baseOldName = isLocal ? oldName.split('/').last : oldName;
    TextEditingController ctrl = TextEditingController(text: baseOldName);
    showDialog(context: context, builder: (c) => AlertDialog(
        title: const Text('Rename'), content: TextField(controller: ctrl),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () async {
              Navigator.pop(c); 
              String newName = ctrl.text.trim(); 
              if (newName.isEmpty || newName == baseOldName) return;
              
              if (isLocal) { 
                try {
                  if (FileSystemEntity.isDirectorySync(oldName)) {
                    Directory(oldName).renameSync('$localPath/$newName');
                  } else {
                    File(oldName).renameSync('$localPath/$newName');
                  }
                  _loadLocal(localPath); 
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"$newName" renamed successfully')));
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              } else {
                try {
                  String remoteOldPath = remotePath == '/' ? '/$oldName' : '$remotePath/$oldName';
                  String remoteNewPath = remotePath == '/' ? '/$newName' : '$remotePath/$newName';
                  if (_isSftp) await _sftpClient!.rename(remoteOldPath, remoteNewPath); 
                  else await NativeFtpClient.rename(remoteOldPath, remoteNewPath);
                  
                  _goToRemotePath(remotePath);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"$newName" renamed successfully')));
                } catch (e) { 
                  if (_isConnectionError(e)) _showDisconnectDialog(); 
                  else ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'))); 
                }
              }
            }, child: const Text('OK')),
        ],
      )
    );
  }

  Future<void> _deleteItems(List<String> items, bool isLocal) async {
    if (items.isEmpty) return;
    
    String dialogText;
    if (items.length == 1) {
      String itemName = isLocal ? items.first.split('/').last : items.first;
      dialogText = 'Deleting "$itemName"\nAre you sure?';
    } else {
      dialogText = 'Deleting selected files. (${items.length})\nAre you sure?';
    }

    bool confirm = await showDialog(context: context, builder: (c) => AlertDialog(
        title: const Text("Delete file(s)"), 
        content: Text(dialogText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Cancel")), 
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("OK", style: TextStyle(color: Colors.red)))
        ],
    )) ?? false;

    if (confirm) {
      if (isLocal) {
        for (String path in items) { 
          try { 
            if (Directory(path).existsSync()) {
              Directory(path).deleteSync(recursive: true); 
            } else if (File(path).existsSync()) {
              File(path).deleteSync(); 
            }
          } catch (_) {} 
        }
        _loadLocal(localPath);
      } else {
        bool connectionLost = false;
        for (String name in items) {
          try {
            String remoteItemPath = remotePath == '/' ? '/$name' : '$remotePath/$name';
            bool isDir = remoteFiles.any((e) => e.name == name && e.isDir);
            
            if (_isSftp) {
              if (isDir) {
                await _sftpClient!.rmdir(remoteItemPath);
              } else {
                await _sftpClient!.remove(remoteItemPath);
              }
            } else {
              await NativeFtpClient.delete(remoteItemPath, isDir);
            }
          } catch (e) { 
            if (_isConnectionError(e)) connectionLost = true; 
          }
        }
        if (connectionLost) _showDisconnectDialog();
        _goToRemotePath(remotePath);
      }
    }
  }

  void _showProperties(String pathOrName, String size, bool isDir, bool isLocal) {
    String name = isLocal ? pathOrName.split('/').last : pathOrName; String modified = 'N/A';
    if (isLocal) { try { modified = FileStat.statSync(pathOrName).modified.toString().split('.').first; } catch (_) {} }
    showDialog(context: context, builder: (context) {
        return AlertDialog(
          title: const Text('File properties', style: TextStyle(color: Colors.lightBlueAccent)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Name: $name'), const SizedBox(height: 4), Text('Type: ${isDir ? "Directory" : "File"}'), const SizedBox(height: 4), Text('Size: $size'), const SizedBox(height: 4), Text('Modified: $modified')]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        );
      }
    );
  }

  void _showContextMenu(String pathOrName, String sizeStr, bool isLocal, bool isDir) {
    showDialog(context: context, builder: (context) {
        return SimpleDialog(
          title: Text(isLocal ? pathOrName.split('/').last : pathOrName, style: const TextStyle(fontSize: 16, color: Colors.blueAccent)),
          children: [
            SimpleDialogOption(onPressed: () { Navigator.pop(context); _selectedLocalPaths.clear(); _selectedRemoteNames.clear(); if(isLocal) { _selectedLocalPaths.add(pathOrName); } else { _selectedRemoteNames.add(pathOrName); } _transferSelectedItems(); }, child: Text(isLocal ? 'Upload' : 'Download')),
            SimpleDialogOption(onPressed: () { Navigator.pop(context); _renameItem(pathOrName, isLocal); }, child: const Text('Rename')),
            SimpleDialogOption(onPressed: () { Navigator.pop(context); _deleteItems([pathOrName], isLocal); }, child: const Text('Delete')),
            SimpleDialogOption(onPressed: () { Navigator.pop(context); _showProperties(pathOrName, sizeStr, isDir, isLocal); }, child: const Text('Properties')),
          ],
        );
      }
    );
  }

  Future<void> _transferSelectedItems() async {
    bool isLocal = _tabController.index == 0;
    List<String> itemsToTransfer = isLocal ? _selectedLocalPaths.toList() : _selectedRemoteNames.toList();
    if (itemsToTransfer.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No items selected.'))); return; }

    bool isTransferCancelled = false;
    int successCount = 0; 
    bool connectionLost = false;
    
    String currentFileName = "";
    int currentFileIndex = 0;
    int currentTransferred = 0;
    int currentTotal = 0;
    DateTime startTime = DateTime.now();
    StateSetter? dialogSetState;

    void updateDialog(int transferred, int total) {
      if (mounted && dialogSetState != null) {
        dialogSetState!(() {
          currentTransferred = transferred;
          currentTotal = total;
        });
      }
    }

    NativeFtpClient.onProgress = updateDialog;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (context, setState) {
          dialogSetState = setState;
          double speedKBps = 0;
          String speedStr = "0 KB/s";
          String elapsedStr = "0s";
          String etaStr = "Calculating...";
          String sizeStr = "0 / 0 MB";
          double percent = 0.0;
          String percentStr = "0%";

          if (currentTotal > 0) {
            final elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
            if (elapsedSeconds > 0) {
              speedKBps = (currentTransferred / 1024) / elapsedSeconds;
              speedStr = "${speedKBps.toStringAsFixed(2)} KB/s";
              if (speedKBps > 0) {
                 double remainingSeconds = ((currentTotal - currentTransferred) / 1024) / speedKBps;
                 etaStr = "<${remainingSeconds.ceil()}s";
              }
            }
            elapsedStr = "${elapsedSeconds}s";
            percent = currentTransferred / currentTotal;
            percentStr = "${(percent * 100).toStringAsFixed(0)}%";
            sizeStr = "${(currentTransferred / (1024*1024)).toStringAsFixed(2)} / ${(currentTotal / (1024*1024)).toStringAsFixed(2)} MB";
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF2A2E35),
            titlePadding: EdgeInsets.zero,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
                  child: Text('Transfer Status', style: TextStyle(color: Colors.lightBlueAccent, fontSize: 18)),
                ),
                Container(height: 2, color: Colors.lightBlueAccent),
              ],
            ),
            contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(isLocal ? Icons.upload : Icons.download, color: isLocal ? Colors.orange : Colors.lightBlueAccent, size: 28),
                      const SizedBox(width: 10),
                      Expanded(child: Text(currentFileName, style: const TextStyle(color: Colors.white, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('$currentFileIndex/${itemsToTransfer.length}', style: const TextStyle(color: Colors.white70)),
                      Text(speedStr, style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: currentTotal > 0 ? (currentTransferred / currentTotal).clamp(0.0, 1.0) : 0.0,
                    color: Colors.lightBlueAccent,
                    backgroundColor: Colors.grey[700],
                    minHeight: 4,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(percentStr, style: const TextStyle(color: Colors.white70)),
                      Text(sizeStr, style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Elapsed: $elapsedStr', style: const TextStyle(color: Colors.white70)),
                      Text('ETA: $etaStr', style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  const SizedBox(height: 25),
                  Center(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38404B), padding: const EdgeInsets.symmetric(horizontal: 30)),
                      onPressed: () {
                        isTransferCancelled = true;
                        if (!_isSftp) NativeFtpClient.cancel();
                      },
                      child: const Text('Cancel', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    for (int i = 0; i < itemsToTransfer.length; i++) {
      if (isTransferCancelled) break;
      String item = itemsToTransfer[i];
      
      startTime = DateTime.now();
      currentTransferred = 0;
      currentTotal = 0;
      currentFileName = isLocal ? File(item).path.split('/').last : item;
      currentFileIndex = i + 1;
      updateDialog(0, 0);

      try {
        if (isLocal) {
          File file = File(item);
          if (await file.exists()) {
            currentTotal = file.lengthSync();
            updateDialog(0, currentTotal);

            String fileName = file.path.split('/').last;
            String remoteItemPath = remotePath == '/' ? '/$fileName' : '$remotePath/$fileName';

            if (_isSftp) {
              final remoteFile = await _sftpClient!.open(remoteItemPath, mode: SftpFileOpenMode.create | SftpFileOpenMode.write);
              Stream<Uint8List> progressStream(Stream<List<int>> source) async* {
                 await for (var chunk in source) {
                    if (isTransferCancelled) throw Exception("CANCELLED");
                    currentTransferred += chunk.length;
                    updateDialog(currentTransferred, currentTotal);
                    yield Uint8List.fromList(chunk);
                 }
              }
              await remoteFile.write(progressStream(file.openRead()));
              await remoteFile.close(); 
              successCount++;
            } else {
              await NativeFtpClient.upload(file.path, remoteItemPath);
              if(!isTransferCancelled) successCount++;
            }
          }
        } else {
          String remoteItemPath = remotePath == '/' ? '/$item' : '$remotePath/$item';
          
          if (_isSftp) {
             final fileStat = await _sftpClient!.stat(remoteItemPath);
             currentTotal = fileStat.size ?? 0;
             updateDialog(0, currentTotal);

             final remoteFile = await _sftpClient!.open(remoteItemPath); 
             final localFile = File('$localPath/$item'); 
             final sink = localFile.openWrite();
             
             await for (var chunk in remoteFile.read()) { 
                if (isTransferCancelled) throw Exception("CANCELLED");
                sink.add(chunk); 
                currentTransferred += chunk.length;
                updateDialog(currentTransferred, currentTotal);
             } 
             await sink.close(); 
             await remoteFile.close();
             if (!isTransferCancelled) successCount++;
          } else {
             await NativeFtpClient.download(remoteItemPath, '$localPath/$item'); 
             if(!isTransferCancelled) successCount++; 
          }
        }
      } catch (e) {
        String errStr = e.toString();
        if (errStr.contains('CANCELLED')) {
           isTransferCancelled = true;
        } else if (_isConnectionError(e)) {
           connectionLost = true;
        } else {
           if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(errStr, style: const TextStyle(color: Colors.white)),
                backgroundColor: Colors.redAccent,
                duration: const Duration(seconds: 4),
              ));
           }
        }
      }
    }

    if (mounted) Navigator.pop(context);

    if (isLocal) { _selectedLocalPaths.clear(); _goToRemotePath(remotePath); } 
    else { _selectedRemoteNames.clear(); _loadLocal(localPath); }
    
    if (connectionLost) {
      _showDisconnectDialog();
    } else if (isTransferCancelled) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transfer cancelled')));
    } else if (successCount > 0) {
      showDialog(context: context, builder: (c) => AlertDialog(
          title: const Text('Transfer Complete', style: TextStyle(color: Colors.lightBlueAccent)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Successfully transferred: $successCount / ${itemsToTransfer.length} items'), const SizedBox(height: 10), const LinearProgressIndicator(value: 1.0, color: Colors.lightBlueAccent, backgroundColor: Colors.grey)]),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        )
      );
    }
  }

  void _handleFilterSelect(bool isLocal) {
    TextEditingController extCtrl = TextEditingController();
    showDialog(context: context, builder: (c) => AlertDialog(
        title: const Text('Filter Select'), content: TextField(controller: extCtrl, decoration: const InputDecoration(hintText: 'e.g. .txt, .php, .jpg')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () {
              Navigator.pop(c); String ext = extCtrl.text.trim(); if (ext.isEmpty) return;
              setState(() { if (isLocal) { _selectedLocalPaths.addAll(localFiles.where((e) => e.path.endsWith(ext)).map((e) => e.path)); } else { _selectedRemoteNames.addAll(remoteFiles.where((e) => e.name.endsWith(ext)).map((e) => e.name)); } });
            }, child: const Text('Select')),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isLocal = _tabController.index == 0;
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(onTap: () => _openPathInputDialog(isLocal), child: Text(isLocal ? localPath : remotePath, style: const TextStyle(fontSize: 14, decoration: TextDecoration.underline))),
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'Download') _transferSelectedItems();
                else if (value == 'Rename') { if ((isLocal ? _selectedLocalPaths.length : _selectedRemoteNames.length) == 1) _renameItem(isLocal ? _selectedLocalPaths.first : _selectedRemoteNames.first, isLocal); else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select exactly one item to rename'))); }
                else if (value == 'Delete') _deleteItems(isLocal ? _selectedLocalPaths.toList() : _selectedRemoteNames.toList(), isLocal);
                else if (value == 'CreateDir') _createDirectory();
                else if (value == 'Sort') _showSortDialog();
                else if (value == 'Refresh') { if (isLocal) _loadLocal(localPath); else { _goToRemotePath(remotePath); } }
                else if (value == 'SelectAll') { setState(() { if (isLocal) { if (_selectedLocalPaths.length == localFiles.length) _selectedLocalPaths.clear(); else _selectedLocalPaths.addAll(localFiles.map((e) => e.path)); } else { if (_selectedRemoteNames.length == remoteFiles.length) _selectedRemoteNames.clear(); else _selectedRemoteNames.addAll(remoteFiles.map((e) => e.name)); } }); }
                else if (value == 'FilterSelect') _handleFilterSelect(isLocal);
                else if (value == 'Logout') { if(!_isSftp) NativeFtpClient.disconnect(); _sshClient?.close(); Navigator.pop(context); }
              },
              itemBuilder: (BuildContext context) { return const [PopupMenuItem(value: 'Download', child: Text('Download/Upload')), PopupMenuItem(value: 'Rename', child: Text('Rename')), PopupMenuItem(value: 'Delete', child: Text('Delete')), PopupMenuItem(value: 'CreateDir', child: Text('Create dir.')), PopupMenuItem(value: 'Sort', child: Text('Sort')), PopupMenuItem(value: 'Refresh', child: Text('Refresh')), PopupMenuItem(value: 'SelectAll', child: Text('Select all/none')), PopupMenuItem(value: 'FilterSelect', child: Text('Filter Select')), PopupMenuItem(value: 'Logout', child: Text('Logout'))]; },
            ),
          ],
          // TabBar BURADAN KALDIRILDI VE ALT TARAFA EKLENDİ
        ),
        
        body: Column(
          children: [
            // 1. REKLAM YÜKLENDİYSE EN ÜSTTE (SEKMELERİN ÜZERİNDE) GÖSTERİLECEK
            if (_isBannerAdLoaded && _bannerAd != null)
              Container(
                color: Colors.black, // Arayüzle uyumlu arkaplan
                width: double.infinity,
                height: _bannerAd!.size.height.toDouble(),
                alignment: Alignment.center,
                child: AdWidget(ad: _bannerAd!),
              ),
              
            // 2. SEKMELER REKLAMIN ALTINA TAŞINDI VE İKONLAR YANA HİZALANDI
            Container(
              color: const Color(0xFF000000), // AppBar rengiyle uyumlu
              child: TabBar(
                controller: _tabController, 
                indicatorColor: Colors.lightBlueAccent, 
                labelPadding: EdgeInsets.zero,
                tabs: [
                  Tab(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.home, size: 18), 
                        SizedBox(width: 6), 
                        Text('LOCAL')
                      ],
                    ),
                  ), 
                  Tab(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.public, size: 18), 
                        SizedBox(width: 6), 
                        Text('REMOTE')
                      ],
                    ),
                  )
                ]
              ),
            ),
            
            // 3. MEVCUT KONTROL ÇUBUĞUN
            Container(color: const Color(0xFF1E2229), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Row(children: [IconButton(icon: const Icon(Icons.arrow_upward, color: Colors.greenAccent), onPressed: () { if (isLocal) { if (!localLoading && localPath != '/storage/emulated/0' && localPath != '/') _loadLocal(Directory(localPath).parent.path); } else _changeRemoteDirectory('..'); }), const Text("Up", style: TextStyle(fontWeight: FontWeight.bold)), const Spacer(), ElevatedButton(onPressed: (isLocal ? _selectedLocalPaths.isEmpty : _selectedRemoteNames.isEmpty) ? null : _transferSelectedItems, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38404B)), child: Text(isLocal ? 'Upload' : 'Download'))])),
            
            // 4. DOSYA LİSTELERİ
            Expanded(
              child: TabBarView(
                controller: _tabController, 
                physics: const NeverScrollableScrollPhysics(), 
                children: [_buildLocalList(), _buildRemoteList()]
              )
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalList() {
    if (localLoading) return const Center(child: CircularProgressIndicator());
    return ListView.separated(
      key: PageStorageKey<String>('local_list_$localPath'),
      itemCount: localFiles.length, separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
      itemBuilder: (context, index) {
        final entity = localFiles[index]; final isDir = FileSystemEntity.isDirectorySync(entity.path); final name = entity.path.split('/').last; String sizeStr = ""; if (!isDir) try { sizeStr = formatBytes(File(entity.path).lengthSync()); } catch (_) {}
        return ListTile(
          dense: true, leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: isDir ? Colors.blue[300] : Colors.white70), title: Text(name),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [if (!isDir) Text(sizeStr, style: const TextStyle(color: Colors.grey, fontSize: 12)), isDir ? const SizedBox.shrink() : Checkbox(activeColor: Colors.blueAccent, value: _selectedLocalPaths.contains(entity.path), onChanged: (bool? value) { setState(() { if (value == true) _selectedLocalPaths.add(entity.path); else _selectedLocalPaths.remove(entity.path); }); })]),
          onTap: () { if (isDir) _loadLocal(entity.path); else { setState(() { if (_selectedLocalPaths.contains(entity.path)) _selectedLocalPaths.remove(entity.path); else _selectedLocalPaths.add(entity.path); }); } },
          onLongPress: () { _showContextMenu(entity.path, sizeStr, true, isDir); },
        );
      },
    );
  }

  Widget _buildRemoteList() {
    if (remoteLoading) return const Center(child: CircularProgressIndicator());
    if (remoteError.isNotEmpty) return Center(child: Text(remoteError, style: const TextStyle(color: Colors.red)));
    return ListView.separated(
      key: PageStorageKey<String>('remote_list_$remotePath'),
      itemCount: remoteFiles.length, separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
      itemBuilder: (context, index) {
        final entry = remoteFiles[index]; final isDir = entry.isDir; String sizeStr = isDir ? "" : formatBytes(entry.size);
        return ListTile(
          dense: true, leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: isDir ? Colors.blue[300] : Colors.white70), title: Text(entry.name),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [if (!isDir) Text(sizeStr, style: const TextStyle(color: Colors.grey, fontSize: 12)), isDir ? const SizedBox.shrink() : Checkbox(activeColor: Colors.blueAccent, value: _selectedRemoteNames.contains(entry.name), onChanged: (bool? value) { setState(() { if (value == true) _selectedRemoteNames.add(entry.name); else _selectedRemoteNames.remove(entry.name); }); })]),
          onTap: () { if (isDir) _changeRemoteDirectory(entry.name); else { setState(() { if (_selectedRemoteNames.contains(entry.name)) _selectedRemoteNames.remove(entry.name); else _selectedRemoteNames.add(entry.name); }); } },
          onLongPress: () { _showContextMenu(entry.name, sizeStr, false, isDir); },
        );
      },
    );
  }
}
