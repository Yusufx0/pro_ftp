import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:dartssh2/dartssh2.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FtpProApp());
}

class FtpProApp extends StatelessWidget {
  const FtpProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ftp Master',
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
          ),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}

// --- VERİ MODELİ ---
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

// --- YARDIMCI FONKSİYONLAR ---
String formatBytes(int bytes) {
  if (bytes <= 0) return "0 B";
  const suffixes = ["B", "KB", "MB", "GB", "TB"];
  var i = (log(bytes) / log(1024)).floor();
  return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
}

// Güvenlik: Girdi temizleme (Path Traversal engeli)
bool isValidName(String name) {
  if (name.isEmpty || name.contains('/') || name.contains('\\') || name.contains('..')) {
    return false;
  }
  return true;
}

// --- GİRİŞ EKRANI (LOGIN) ---
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
        if (profiles.isNotEmpty) selectedProfile = profiles.first;
      });
    } else {
      final defaultProfile = FtpProfile(name: 'DefaultProfile');
      setState(() {
        profiles = [defaultProfile];
        selectedProfile = defaultProfile;
      });
      _saveProfiles();
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
    if (profiles.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('At least one profile must remain.')));
      return;
    }
    
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
        selectedProfile = profiles.first;
      });
      _saveProfiles();
    }
  }

  Future<void> _connect() async {
    if (selectedProfile == null || _isConnecting) return;

    // Güvenlik Uyarısı: Düz FTP kullanımı tespiti
    if (selectedProfile!.mode == 'FTP') {
      bool proceed = await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("Security Warning", style: TextStyle(color: Colors.orangeAccent)),
          content: const Text("You are connecting via plain FTP. Your password and data will be sent UNENCRYPTED over the network. It is highly recommended to use SFTP or FTPS.\n\nDo you still want to connect?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Cancel")),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Connect Anyway", style: TextStyle(color: Colors.redAccent))),
          ],
        )
      ) ?? false;
      
      if (!proceed) return;
    }

    setState(() {
      _isConnecting = true;
    });

    String errorMessage = "";

    try {
      if (selectedProfile!.mode.contains('SFTP')) {
        final socket = await SSHSocket.connect(
          selectedProfile!.host, 
          int.tryParse(selectedProfile!.port) ?? 22
        ).timeout(const Duration(seconds: 10));

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
          identities: identities,
          onPasswordRequest: () => selectedProfile!.password,
          // GÜVENLİK KATI: SFTP Host Key (MITM) Doğrulaması
          onBadHostKey: (String host, int port, String fingerprint) async {
            final String storageKey = 'trusted_host_${host}_$port';
            final String? trustedFingerprint = await _secureStorage.read(key: storageKey);

            if (trustedFingerprint == fingerprint) {
              return true; // Anahtar daha önce onaylanmış ve eşleşiyor
            }

            // Anahtar eşleşmedi veya ilk bağlantı, kullanıcıya sor
            Completer<bool> completer = Completer<bool>();
            if (context.mounted) {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text("Security: Unknown Host Key", style: TextStyle(color: Colors.orangeAccent)),
                    content: Text(
                      "The server's host key is unknown or has changed.\n\n"
                      "Fingerprint:\n$fingerprint\n\n"
                      "Do you trust this server? (If you don't recognize this, you might be under a Man-in-the-Middle attack)."
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          completer.complete(false);
                        },
                        child: const Text("Reject & Disconnect", style: TextStyle(color: Colors.redAccent)),
                      ),
                      TextButton(
                        onPressed: () async {
                          await _secureStorage.write(key: storageKey, value: fingerprint);
                          Navigator.pop(context);
                          completer.complete(true);
                        },
                        child: const Text("Trust & Connect"),
                      ),
                    ],
                  );
                },
              );
            } else {
              completer.complete(false);
            }
            return completer.future;
          },
        );
        
        await client.authenticated;
        await client.sftp();
        client.close();
      } else {
        // FTP/FTPS/FTPES Bağlantısı (Dart default SecureSocket TLS 1.2/1.3 kullanır)
        SecurityType secType = SecurityType.ftp;
        if (selectedProfile!.mode.contains('FTPES')) secType = SecurityType.ftpes;
        if (selectedProfile!.mode.contains('FTPS')) secType = SecurityType.ftps;
        
        final ftp = FTPConnect(
          selectedProfile!.host,
          user: selectedProfile!.user,
          pass: selectedProfile!.password,
          port: int.tryParse(selectedProfile!.port) ?? 21,
          securityType: secType,
        );
        
        await ftp.connect().timeout(const Duration(seconds: 10));
        await ftp.disconnect();
      }
    } catch (e) {
      String errStr = e.toString().toLowerCase();
      // GÜVENLİK KATI: FTPS/FTPES Sertifika Hatalarını Yakalama (Strict Root CA Validation)
      if (errStr.contains('handshake') || errStr.contains('certificate')) {
        errorMessage = "Security Alert: Invalid or untrusted SSL/TLS certificate. The connection was blocked to protect your data.";
      } else if (errStr.contains('530') || errStr.contains('auth') || errStr.contains('permission') || errStr.contains('credential') || errStr.contains('login')) {
        errorMessage = "Invalid user name or password.";
      } else if (errStr.contains('socket') || errStr.contains('failed host lookup') || errStr.contains('connection refused')) {
        errorMessage = "Could not connect to server. Check host or port.";
      } else if (errStr.contains('timeout')) {
        errorMessage = "Connection timed out. Server is not responding.";
      } else {
        errorMessage = "Connection error: ${e.toString()}";
      }
    }

    setState(() {
      _isConnecting = false;
    });

    if (errorMessage.isNotEmpty) {
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("Login error", style: TextStyle(color: Colors.lightBlueAccent)),
          content: Text(errorMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text("OK", style: TextStyle(color: Colors.blueAccent)),
            ),
          ],
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DualFileManagerScreen(profile: selectedProfile!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Ftp Master Secure'),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
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
                          items: profiles.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => selectedProfile = val);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 45,
                    child: ElevatedButton(
                      onPressed: _isConnecting ? null : _connect,
                      child: _isConnecting 
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Connect Securely', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: ElevatedButton(onPressed: _deleteSelectedProfile, child: const Text('Delete'))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton(onPressed: () => _openEditor(profileToEdit: selectedProfile), child: const Text('Edit'))),
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

// --- PROFİL DÜZENLEME EKRANI ---
class EditProfileScreen extends StatefulWidget {
  final FtpProfile? profile;
  const EditProfileScreen({super.key, this.profile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController nameCtrl;
  late TextEditingController hostCtrl;
  late TextEditingController userCtrl;
  late TextEditingController passCtrl;
  late TextEditingController privateKeyCtrl;
  late TextEditingController portCtrl;
  late TextEditingController localPathCtrl;
  late TextEditingController remotePathCtrl;
  
  String selectedMode = 'SFTP (FTP over SSH)'; // Varsayılan olarak en güvenli yöntem seçili gelir
  String selectedCharset = 'UTF-8';
  bool savePass = true;
  bool isPassive = true;
  bool isBinary = true;

  final List<String> ftpModes = [
    'FTP',
    'FTPES (Explicit secure FTP)',
    'FTPS (Implicit secure FTP)',
    'SFTP (FTP over SSH)',
  ];

  final List<String> charsets = ['UTF-8', 'ISO-8859-1', 'Windows-1254'];

  @override
  void initState() {
    super.initState();
    nameCtrl = TextEditingController(text: widget.profile?.name ?? '');
    hostCtrl = TextEditingController(text: widget.profile?.host ?? '');
    userCtrl = TextEditingController(text: widget.profile?.user ?? '');
    passCtrl = TextEditingController(text: widget.profile?.password ?? '');
    privateKeyCtrl = TextEditingController(text: widget.profile?.privateKey ?? '');
    portCtrl = TextEditingController(text: widget.profile?.port ?? '22');
    localPathCtrl = TextEditingController(text: widget.profile?.localPath ?? '');
    remotePathCtrl = TextEditingController(text: widget.profile?.remotePath ?? '');
    
    if (widget.profile != null) {
      selectedMode = widget.profile!.mode;
      if (!ftpModes.contains(selectedMode)) selectedMode = 'SFTP (FTP over SSH)';
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
    final newProfile = FtpProfile(
      name: nameCtrl.text.trim(),
      mode: selectedMode,
      host: hostCtrl.text.trim(),
      user: userCtrl.text.trim(),
      password: passCtrl.text,
      privateKey: privateKeyCtrl.text.trim(),
      savePassword: savePass,
      passiveMode: isPassive,
      binaryMode: isBinary,
      port: portCtrl.text,
      localPath: localPathCtrl.text,
      remotePath: remotePathCtrl.text,
      charset: selectedCharset,
    );
    Navigator.pop(context, newProfile);
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
          dirs = dir.listSync().whereType<Directory>().toList();
          dirs.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
          currentPath = path;
        }
      } catch (_) {}
      setDialogState(() {});
    }

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            if (dirs.isEmpty && Directory(currentPath).existsSync()) {
               try {
                 dirs = Directory(currentPath).listSync().whereType<Directory>().toList();
                 dirs.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
               } catch(_) {}
            }
            return AlertDialog(
              title: Text('Local path:\n$currentPath', style: const TextStyle(fontSize: 14, color: Colors.blueAccent)),
              contentPadding: const EdgeInsets.all(8),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    if (currentPath != '/storage/emulated/0' && currentPath != '/')
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder, color: Colors.blueAccent),
                        title: const Text('..'),
                        onTap: () => loadDirs(Directory(currentPath).parent.path, setDialogState),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: dirs.length,
                        itemBuilder: (context, index) {
                          final dir = dirs[index];
                          final name = dir.path.split('/').last;
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder, color: Colors.blueAccent),
                            title: Text(name),
                            trailing: Checkbox(
                              activeColor: Colors.blueAccent,
                              value: selectedPath == dir.path,
                              onChanged: (val) => setDialogState(() => selectedPath = dir.path),
                            ),
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
                TextButton(
                  onPressed: () {
                    localPathCtrl.text = selectedPath;
                    Navigator.pop(context);
                  },
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      },
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
          entities = dir.listSync();
          entities.sort((a, b) {
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
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            if (entities.isEmpty && Directory(currentPath).existsSync()) loadEntities(currentPath, setDialogState);
            return AlertDialog(
              title: Text('Select Key File:\n$currentPath', style: const TextStyle(fontSize: 14, color: Colors.blueAccent)),
              contentPadding: const EdgeInsets.all(8),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    if (currentPath != '/storage/emulated/0' && currentPath != '/')
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder, color: Colors.blueAccent),
                        title: const Text('..'),
                        onTap: () => loadEntities(Directory(currentPath).parent.path, setDialogState),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: entities.length,
                        itemBuilder: (context, index) {
                          final entity = entities[index];
                          final isDir = FileSystemEntity.isDirectorySync(entity.path);
                          final name = entity.path.split('/').last;

                          return ListTile(
                            dense: true,
                            leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: Colors.blueAccent),
                            title: Text(name),
                            trailing: isDir ? null : Checkbox(
                              activeColor: Colors.blueAccent,
                              value: selectedFile == entity.path,
                              onChanged: (val) => setDialogState(() => selectedFile = entity.path),
                            ),
                            onTap: () {
                              if (isDir) loadEntities(entity.path, setDialogState);
                              else setDialogState(() => selectedFile = entity.path);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                TextButton(
                  onPressed: () {
                    if (selectedFile.isNotEmpty) privateKeyCtrl.text = selectedFile;
                    Navigator.pop(context);
                  },
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.profile == null ? 'New Profile' : 'Edit Profile'),
          bottom: const TabBar(
            indicatorColor: Colors.lightBlueAccent,
            tabs: [
              Tab(text: 'PROFILE PROPERTIES'),
              Tab(text: 'MORE PROPERTIES'),
            ],
          ),
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
                      isExpanded: true,
                      value: selectedMode,
                      items: ftpModes.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            selectedMode = val;
                            if (selectedMode == 'SFTP (FTP over SSH)') portCtrl.text = '22';
                            else if (portCtrl.text == '22') portCtrl.text = '21';
                          });
                        }
                      },
                    )),
                    const SizedBox(height: 16),
                    _buildLabelRow('* Host:', TextField(controller: hostCtrl, decoration: const InputDecoration(isDense: true))),
                    const SizedBox(height: 16),
                    _buildLabelRow('User:', TextField(controller: userCtrl, decoration: const InputDecoration(isDense: true, hintText: 'blank for anonymous'))),
                    const SizedBox(height: 16),
                    _buildLabelRow('Password:', Row(
                      children: [
                        Expanded(child: TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(isDense: true))),
                        Checkbox(value: savePass, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => savePass = v ?? true)),
                        const Text('Save'),
                      ],
                    )),
                    const SizedBox(height: 16),
                    _buildLabelRow('Transfer:', Row(
                      children: [
                        Checkbox(value: isPassive, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => isPassive = v ?? true)),
                        const Text('Passive'),
                        const SizedBox(width: 16),
                        Checkbox(value: isBinary, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => isBinary = v ?? true)),
                        const Text('Binary'),
                      ],
                    )),
                    if (selectedMode == 'SFTP (FTP over SSH)') ...[
                      const SizedBox(height: 16),
                      _buildLabelRow('Private key:', Row(
                        children: [
                          Expanded(child: TextField(controller: privateKeyCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Key path'))),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _showFilePicker,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              minimumSize: const Size(0, 36)
                            ),
                            child: const Text('Browse...', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      )),
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
                    _buildLabelRow('Local path:', Row(
                      children: [
                        Expanded(child: TextField(controller: localPathCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Optional local path'))),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _showDirectoryPicker,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            minimumSize: const Size(0, 36)
                          ),
                          child: const Text('Browser', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    )),
                    const SizedBox(height: 16),
                    _buildLabelRow('Remote path:', TextField(controller: remotePathCtrl, decoration: const InputDecoration(isDense: true, hintText: 'Optional remote path'))),
                    const SizedBox(height: 16),
                    _buildLabelRow('Charset:', DropdownButton<String>(
                      isExpanded: true,
                      value: selectedCharset,
                      items: charsets.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                      onChanged: (val) { if (val != null) setState(() => selectedCharset = val); },
                    )),
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
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('* mandatory fields', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(onPressed: _save, child: const Text('Save'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabelRow(String label, Widget child) {
    return Row(
      children: [
        Expanded(flex: 2, child: Text(label, textAlign: TextAlign.right, style: const TextStyle(color: Colors.grey))),
        const SizedBox(width: 16),
        Expanded(flex: 5, child: child),
      ],
    );
  }
}

// --- DOSYA YÖNETİCİSİ EKRANI ---
class DualFileManagerScreen extends StatefulWidget {
  final FtpProfile profile;
  const DualFileManagerScreen({super.key, required this.profile});

  @override
  State<DualFileManagerScreen> createState() => _DualFileManagerScreenState();
}

class _DualFileManagerScreenState extends State<DualFileManagerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  String _sortMethod = 'Name'; 
  String localPath = '/storage/emulated/0';
  List<FileSystemEntity> localFiles = [];
  bool localLoading = true;
  final Set<String> _selectedLocalPaths = {};

  FTPConnect? _ftpConnect;
  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  bool get _isSftp => widget.profile.mode.contains('SFTP');

  List<RemoteEntry> remoteFiles = [];
  bool remoteLoading = true;
  String remotePath = '/';
  String remoteError = '';
  final Set<String> _selectedRemoteNames = {};
  
  // HIZ İYİLEŞTİRMESİ: Jet hızında gezinmek için önbellek mekanizması
  final Map<String, List<RemoteEntry>> _remoteCache = {};
  final _secureStorage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    if (widget.profile.localPath.isNotEmpty) localPath = widget.profile.localPath;
    else localPath = '/storage/emulated/0';
    
    if (widget.profile.remotePath.isNotEmpty) remotePath = widget.profile.remotePath;
    
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
    _initLocal();
    _initRemote();
  }

  @override
  void dispose() {
    _ftpConnect?.disconnect();
    _sshClient?.close();
    _tabController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    if (_tabController.index == 0) {
      if (localPath.isNotEmpty && localPath != '/storage/emulated/0' && localPath != '/') {
        final parent = Directory(localPath).parent.path;
        _loadLocal(parent);
        return false;
      }
    } else {
      if (remotePath.isNotEmpty && remotePath != '/') {
        _changeRemoteDirectory('..');
        return false;
      }
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
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Sort by'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: ['Name', 'Size'].map((mode) {
              return RadioListTile<String>(
                title: Text(mode),
                value: mode,
                groupValue: _sortMethod,
                onChanged: (val) {
                  setState(() => _sortMethod = val!);
                  Navigator.pop(context);
                  // Önbelleği temizle ve yeniden yükle ki sıralama güncellensin
                  if (_tabController.index == 1) {
                    _remoteCache.remove(remotePath); 
                  }
                  _tabController.index == 0 ? _loadLocal(localPath) : _loadRemote(forceRefresh: true);
                },
              );
            }).toList(),
          ),
        );
      }
    );
  }

  void _openPathInputDialog(bool isLocal) {
    TextEditingController pathCtrl = TextEditingController(text: isLocal ? localPath : remotePath);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(isLocal ? 'Go to Local Path' : 'Go to Remote Path'),
        content: TextField(
          controller: pathCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter path'),
          onSubmitted: (val) {
            Navigator.pop(c);
            _navigateToPath(val.trim(), isLocal);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              _navigateToPath(pathCtrl.text.trim(), isLocal);
            },
            child: const Text('Go'),
          ),
        ],
      )
    );
  }

  Future<void> _navigateToPath(String newPath, bool isLocal) async {
    if (newPath.isEmpty) return;
    if (isLocal) {
      if (Directory(newPath).existsSync()) {
        _loadLocal(newPath);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Path does not exist.')));
      }
    } else {
      setState(() => remoteLoading = true);
      try {
        if (_isSftp) {
          remotePath = newPath;
        } else {
          await _ftpConnect!.changeDirectory(newPath);
          remotePath = newPath;
        }
        await _loadRemote();
      } catch (e) {
        setState(() => remoteLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _initLocal() async {
    await Permission.manageExternalStorage.request();
    await Permission.storage.request();
    if (localPath.isEmpty) localPath = '/storage/emulated/0';
    _loadLocal(localPath);
  }

  void _loadLocal(String path) {
    setState(() => localLoading = true);
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        final entities = dir.listSync(recursive: false);
        List<FileSystemEntity> folders = [];
        List<FileSystemEntity> files = [];
        
        for (var e in entities) {
          if (e is Directory) folders.add(e);
          else files.add(e);
        }
        
        _sortLocalFiles(folders, files);
        setState(() {
          localFiles = [...folders, ...files];
          localPath = path;
          _selectedLocalPaths.clear();
          localLoading = false;
        });
      } else {
        setState(() => localLoading = false);
      }
    } catch (_) {
      setState(() => localLoading = false);
    }
  }

  Future<void> _initRemote() async {
    setState(() { remoteLoading = true; remoteError = ''; });
    try {
      if (_isSftp) {
        final socket = await SSHSocket.connect(widget.profile.host, int.tryParse(widget.profile.port) ?? 22);
        List<SSHKeyPair> identities = [];
        if (widget.profile.privateKey.isNotEmpty) {
          final keyFile = File(widget.profile.privateKey);
          if (keyFile.existsSync()) {
            identities = SSHKeyPair.fromPem(keyFile.readAsStringSync());
          }
        }
        _sshClient = SSHClient(
          socket,
          username: widget.profile.user,
          identities: identities,
          onPasswordRequest: () => widget.profile.password,
          // İç ekran için de parmak izi doğrulamasını ekliyoruz
          onBadHostKey: (String host, int port, String fingerprint) async {
             final String storageKey = 'trusted_host_${host}_$port';
             final String? trustedFingerprint = await _secureStorage.read(key: storageKey);
             if (trustedFingerprint == fingerprint) return true;
             return false; // Login ekranında onaylandığı için burada sadece kontrol ediyoruz
          }
        );
        _sftpClient = await _sshClient!.sftp();
      } else {
        SecurityType secType = SecurityType.ftp;
        if (widget.profile.mode.contains('FTPES')) secType = SecurityType.ftpes;
        if (widget.profile.mode.contains('FTPS')) secType = SecurityType.ftps;
        
        _ftpConnect = FTPConnect(
          widget.profile.host,
          user: widget.profile.user,
          pass: widget.profile.password,
          port: int.tryParse(widget.profile.port) ?? 21,
          securityType: secType, 
        );
        
        await _ftpConnect!.connect();
        if (remotePath != '/') await _ftpConnect!.changeDirectory(remotePath);
      }
      _loadRemote();
    } catch (e) {
      setState(() { remoteLoading = false; remoteError = e.toString(); });
    }
  }

  // Hız İyileştirmesi: forceRefresh true gelmezse önce önbelleğe (cache) bakar
  Future<void> _loadRemote({bool forceRefresh = false}) async {
    if (!forceRefresh && _remoteCache.containsKey(remotePath)) {
      setState(() {
        remoteFiles = _remoteCache[remotePath]!;
        remoteLoading = false;
        _selectedRemoteNames.clear();
      });
      // Arka planda listeyi güncelle, değişiklik varsa yansıt (jet hızı hissi)
      _fetchRemoteDataAndCache();
      return;
    }

    setState(() => remoteLoading = true);
    await _fetchRemoteDataAndCache();
  }

  Future<void> _fetchRemoteDataAndCache() async {
    try {
      List<RemoteEntry> folders = [];
      List<RemoteEntry> files = [];

      if (_isSftp) {
        final content = await _sftpClient!.listdir(remotePath == '/' ? '.' : remotePath);
        for (var e in content) {
          if (e.filename == '.' || e.filename == '..') continue;
          final isDir = e.attr.isDirectory;
          final entry = RemoteEntry(name: e.filename, isDir: isDir, size: e.attr.size ?? 0);
          if (isDir) folders.add(entry); else files.add(entry);
        }
      } else {
        final content = await _ftpConnect!.listDirectoryContent();
        for (var e in content) {
          final isDir = e.type == FTPEntryType.dir;
          final entry = RemoteEntry(name: e.name, isDir: isDir, size: e.size ?? 0);
          if (isDir) folders.add(entry); else files.add(entry);
        }
      }
      
      _sortRemoteFiles(folders, files);
      List<RemoteEntry> resultList = [...folders, ...files];
      
      _remoteCache[remotePath] = resultList;

      if (mounted) {
        setState(() {
          remoteFiles = resultList;
          remoteLoading = false;
          _selectedRemoteNames.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { remoteLoading = false; remoteError = 'Error: $e'; });
      }
    }
  }

  Future<void> _changeRemoteDirectory(String dirName) async {
    // UI tepkiselliği için anında yükleme durumuna geç
    setState(() => remoteLoading = true);
    try {
      if (_isSftp) {
        if (dirName == '..') {
          if (remotePath != '/') {
            int lastIdx = remotePath.lastIndexOf('/');
            remotePath = lastIdx <= 0 ? '/' : remotePath.substring(0, lastIdx);
          }
        } else {
          remotePath = remotePath == '/' ? '/$dirName' : '$remotePath/$dirName';
        }
      } else {
        await _ftpConnect!.changeDirectory(dirName);
        if (dirName == '..') {
          if (remotePath != '/') {
            int lastIdx = remotePath.lastIndexOf('/');
            remotePath = lastIdx == 0 ? '/' : remotePath.substring(0, lastIdx);
          }
        } else {
          remotePath = remotePath == '/' ? '/$dirName' : '$remotePath/$dirName';
        }
      }
      await _loadRemote(); // Önbellekli yükleme
    } catch (e) {
      setState(() => remoteLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _createDirectory() {
    TextEditingController ctrl = TextEditingController();
    bool isLocal = _tabController.index == 0;

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Create dir.'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Folder name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              String name = ctrl.text.trim();
              if (!isValidName(name)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid folder name.')));
                return;
              }
              Navigator.pop(c);

              if (isLocal) {
                Directory('$localPath/$name').createSync();
                _loadLocal(localPath);
              } else {
                try {
                  if (_isSftp) {
                    await _sftpClient!.mkdir('$remotePath/$name');
                  } else {
                    await _ftpConnect!.makeDirectory(name);
                  }
                  _loadRemote(forceRefresh: true); // Değişiklik oldu, zorunlu yenile
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              }
            },
            child: const Text('OK'),
          ),
        ],
      )
    );
  }

  void _renameItem(String oldName, bool isLocal) {
    TextEditingController ctrl = TextEditingController(text: isLocal ? oldName.split('/').last : oldName);

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              String newName = ctrl.text.trim();
              if (!isValidName(newName) || newName == (isLocal ? oldName.split('/').last : oldName)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid or unchanged name.')));
                return;
              }
              Navigator.pop(c);

              if (isLocal) {
                File(oldName).renameSync('$localPath/$newName');
                _loadLocal(localPath);
              } else {
                try {
                  if (_isSftp) {
                    await _sftpClient!.rename('$remotePath/$oldName', '$remotePath/$newName');
                  } else {
                    await _ftpConnect!.rename(oldName, newName);
                  }
                  _loadRemote(forceRefresh: true);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              }
            },
            child: const Text('OK'),
          ),
        ],
      )
    );
  }

  Future<void> _deleteItems(List<String> items, bool isLocal) async {
    if (items.isEmpty) return;
    bool confirm = await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Delete Warning"),
        content: Text("Are you sure you want to delete ${items.length} item(s)?\nThis action cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("No")),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Yes", style: TextStyle(color: Colors.red))),
        ],
      )
    ) ?? false;

    if (confirm) {
      if (isLocal) {
        for (String path in items) {
          try {
            if (Directory(path).existsSync()) Directory(path).deleteSync(recursive: true);
            else File(path).deleteSync();
          } catch (_) {}
        }
        _loadLocal(localPath);
      } else {
        for (String name in items) {
          try {
            if (_isSftp) {
              try { await _sftpClient!.remove('$remotePath/$name'); } catch(_) {
                try { await _sftpClient!.rmdir('$remotePath/$name'); } catch(_) {}
              }
            } else {
              await _ftpConnect!.deleteFile(name);
            }
          } catch (_) {}
        }
        _loadRemote(forceRefresh: true);
      }
    }
  }

  void _showProperties(String pathOrName, String size, bool isDir, bool isLocal) {
    String name = isLocal ? pathOrName.split('/').last : pathOrName;
    String modified = 'N/A';
    
    if (isLocal) {
      try {
        final stat = FileStat.statSync(pathOrName);
        modified = stat.modified.toString().split('.').first;
      } catch (_) {}
    }

    bool oR = true, oW = true, oX = false;
    bool gR = true, gW = false, gX = false;
    bool otR = true, otW = false, otX = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              contentPadding: EdgeInsets.zero,
              titlePadding: const EdgeInsets.all(16),
              title: const Text('File properties', style: TextStyle(color: Colors.lightBlueAccent)),
              content: Container(
                width: double.maxFinite,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Name: $name'),
                    const SizedBox(height: 4),
                    Text('Type: ${isDir ? "Directory" : "File"}'),
                    const SizedBox(height: 4),
                    Text('Size: $size'),
                    const SizedBox(height: 4),
                    Text('Modified: $modified'),
                    const SizedBox(height: 16),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [Text('Owner:'), Text('Group:'), SizedBox(width: 20)],
                    ),
                    const Divider(),
                    _buildPermissionRow('Owner', oR, oW, oX, (val, type) {
                      setDialogState(() {
                        if (type == 'R') oR = val!;
                        if (type == 'W') oW = val!;
                        if (type == 'X') oX = val!;
                      });
                    }),
                    _buildPermissionRow('Group', gR, gW, gX, (val, type) {
                      setDialogState(() {
                        if (type == 'R') gR = val!;
                        if (type == 'W') gW = val!;
                        if (type == 'X') gX = val!;
                      });
                    }),
                    _buildPermissionRow('Other', otR, otW, otX, (val, type) {
                      setDialogState(() {
                        if (type == 'R') otR = val!;
                        if (type == 'W') otW = val!;
                        if (type == 'X') otX = val!;
                      });
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
              ],
            );
          }
        );
      }
    );
  }

  Widget _buildPermissionRow(String label, bool r, bool w, bool x, Function(bool?, String) onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        SizedBox(width: 60, child: Text(label)),
        Row(children: [Checkbox(value: r, onChanged: (v) => onChanged(v, 'R'), activeColor: Colors.lightBlueAccent), const Text('R')]),
        Row(children: [Checkbox(value: w, onChanged: (v) => onChanged(v, 'W'), activeColor: Colors.lightBlueAccent), const Text('W')]),
        Row(children: [Checkbox(value: x, onChanged: (v) => onChanged(v, 'X'), activeColor: Colors.lightBlueAccent), const Text('X')]),
      ],
    );
  }

  void _showContextMenu(String pathOrName, String sizeStr, bool isLocal, bool isDir) {
    String name = isLocal ? pathOrName.split('/').last : pathOrName;
    
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(name, style: const TextStyle(fontSize: 16, color: Colors.blueAccent)),
          children: [
            SimpleDialogOption(
              onPressed: () { 
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Check functionality active.')));
              }, 
              child: const Text('Check')
            ),
            SimpleDialogOption(
              onPressed: () { 
                Navigator.pop(context); 
                _selectedLocalPaths.clear();
                _selectedRemoteNames.clear();
                if(isLocal) {
                  _selectedLocalPaths.add(pathOrName);
                } else {
                  _selectedRemoteNames.add(pathOrName);
                }
                _transferSelectedItems();
              }, 
              child: Text(isLocal ? 'Upload' : 'Download')
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context);
                _renameItem(pathOrName, isLocal);
              }, 
              child: const Text('Rename')
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context);
                _deleteItems([pathOrName], isLocal);
              }, 
              child: const Text('Delete')
            ),
            SimpleDialogOption(
              onPressed: () { 
                Navigator.pop(context); 
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied to clipboard.')));
              }, 
              child: const Text('Share link')
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context);
                _showProperties(pathOrName, sizeStr, isDir, isLocal);
              }, 
              child: const Text('Properties')
            ),
          ],
        );
      }
    );
  }

  Future<void> _transferSelectedItems() async {
    bool isLocal = _tabController.index == 0;
    List<String> itemsToTransfer = isLocal ? _selectedLocalPaths.toList() : _selectedRemoteNames.toList();
    if (itemsToTransfer.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No items selected.')));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(color: Colors.lightBlueAccent),
            const SizedBox(width: 20),
            Text(isLocal ? 'Uploading files...' : 'Downloading files...'),
          ],
        ),
      )
    );

    int successCount = 0;

    for (String item in itemsToTransfer) {
      try {
        if (isLocal) {
          File file = File(item);
          if (await file.exists()) {
            if (_isSftp) {
              final remoteFile = await _sftpClient!.open('$remotePath/${file.path.split('/').last}', mode: SftpFileOpenMode.create | SftpFileOpenMode.write);
              await remoteFile.write(file.openRead().cast<Uint8List>());
              await remoteFile.close();
              successCount++;
            } else {
              bool res = await _ftpConnect!.uploadFile(file);
              if (res) successCount++;
            }
          }
        } else {
          if (_isSftp) {
             final remoteFile = await _sftpClient!.open('$remotePath/$item');
             final localFile = File('$localPath/$item');
             final sink = localFile.openWrite();
             await for (var chunk in remoteFile.read()) {
               sink.add(chunk);
             }
             await sink.close();
             successCount++;
          } else {
            bool res = await _ftpConnect!.downloadFile(item, File('$localPath/$item'));
            if (res) successCount++;
          }
        }
      } catch (_) {}
    }

    if (isLocal) {
      _selectedLocalPaths.clear();
      _loadRemote(forceRefresh: true);
    } else {
      _selectedRemoteNames.clear();
      _loadLocal(localPath);
    }

    if (mounted) Navigator.pop(context); 

    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Transfer Complete', style: TextStyle(color: Colors.lightBlueAccent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Successfully transferred: $successCount / ${itemsToTransfer.length} items'),
            const SizedBox(height: 10),
            const LinearProgressIndicator(value: 1.0, color: Colors.lightBlueAccent, backgroundColor: Colors.grey),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      )
    );
  }

  void _handleFilterSelect(bool isLocal) {
    TextEditingController extCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Filter Select'),
        content: TextField(
          controller: extCtrl,
          decoration: const InputDecoration(hintText: 'e.g. .txt, .php, .jpg'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              String ext = extCtrl.text.trim();
              if (ext.isEmpty) return;
              
              setState(() {
                if (isLocal) {
                  _selectedLocalPaths.addAll(
                    localFiles.where((e) => e.path.endsWith(ext)).map((e) => e.path)
                  );
                } else {
                  _selectedRemoteNames.addAll(
                    remoteFiles.where((e) => e.name.endsWith(ext)).map((e) => e.name)
                  );
                }
              });
            },
            child: const Text('Select'),
          ),
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
          title: GestureDetector(
            onTap: () => _openPathInputDialog(isLocal),
            child: Text(
              isLocal ? localPath : remotePath, 
              style: const TextStyle(fontSize: 14, decoration: TextDecoration.underline),
            ),
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'Download') {
                  _transferSelectedItems();
                } else if (value == 'Rename') {
                  if ((isLocal ? _selectedLocalPaths.length : _selectedRemoteNames.length) == 1) {
                    _renameItem(isLocal ? _selectedLocalPaths.first : _selectedRemoteNames.first, isLocal);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select exactly one item to rename')));
                  }
                } else if (value == 'Delete') {
                  _deleteItems(isLocal ? _selectedLocalPaths.toList() : _selectedRemoteNames.toList(), isLocal);
                } else if (value == 'CreateDir') {
                  _createDirectory();
                } else if (value == 'Sort') {
                  _showSortDialog();
                } else if (value == 'Refresh') {
                  isLocal ? _loadLocal(localPath) : _loadRemote(forceRefresh: true); // Gerçek yenileme
                } else if (value == 'SelectAll') {
                  setState(() {
                    if (isLocal) {
                      if (_selectedLocalPaths.length == localFiles.length) {
                        _selectedLocalPaths.clear();
                      } else {
                        _selectedLocalPaths.addAll(localFiles.map((e) => e.path));
                      }
                    } else {
                      if (_selectedRemoteNames.length == remoteFiles.length) {
                        _selectedRemoteNames.clear();
                      } else {
                        _selectedRemoteNames.addAll(remoteFiles.map((e) => e.name));
                      }
                    }
                  });
                } else if (value == 'FilterSelect') {
                  _handleFilterSelect(isLocal);
                } else if (value == 'Logout') {
                  _ftpConnect?.disconnect();
                  _sshClient?.close();
                  Navigator.pop(context);
                }
              },
              itemBuilder: (BuildContext context) {
                return const [
                  PopupMenuItem(value: 'Download', child: Text('Download/Upload')),
                  PopupMenuItem(value: 'Rename', child: Text('Rename')),
                  PopupMenuItem(value: 'Delete', child: Text('Delete')),
                  PopupMenuItem(value: 'CreateDir', child: Text('Create dir.')),
                  PopupMenuItem(value: 'Sort', child: Text('Sort')),
                  PopupMenuItem(value: 'Refresh', child: Text('Refresh')),
                  PopupMenuItem(value: 'SelectAll', child: Text('Select all/none')),
                  PopupMenuItem(value: 'FilterSelect', child: Text('Filter Select')),
                  PopupMenuItem(value: 'Logout', child: Text('Logout')),
                ];
              },
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: Colors.lightBlueAccent,
            tabs: const [
              Tab(icon: Icon(Icons.home), text: 'LOCAL'),
              Tab(icon: Icon(Icons.public), text: 'REMOTE'),
            ],
          ),
        ),
        body: Column(
          children: [
            Container(
              color: const Color(0xFF1E2229),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: Colors.greenAccent),
                    onPressed: () {
                      if (isLocal) {
                        if (localPath != '/storage/emulated/0' && localPath != '/') {
                          final parent = Directory(localPath).parent.path;
                          _loadLocal(parent);
                        }
                      } else {
                        _changeRemoteDirectory('..');
                      }
                    },
                  ),
                  const Text("Up", style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: (isLocal ? _selectedLocalPaths.isEmpty : _selectedRemoteNames.isEmpty) 
                        ? null 
                        : _transferSelectedItems,
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38404B)),
                    child: Text(isLocal ? 'Upload' : 'Download'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLocalList(),
                  _buildRemoteList(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalList() {
    if (localLoading) return const Center(child: CircularProgressIndicator());
    return ListView.separated(
      itemCount: localFiles.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
      itemBuilder: (context, index) {
        final entity = localFiles[index];
        final isDir = entity is Directory;
        final name = entity.path.split('/').last;
        
        String sizeStr = "";
        if (!isDir) {
          try { sizeStr = formatBytes(File(entity.path).lengthSync()); } catch (_) {}
        }

        return ListTile(
          dense: true,
          leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: isDir ? Colors.blue[300] : Colors.white70),
          title: Text(name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDir) Text(sizeStr, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              Checkbox(
                activeColor: Colors.blueAccent,
                value: _selectedLocalPaths.contains(entity.path),
                onChanged: (bool? value) {
                  setState(() {
                    if (value == true) _selectedLocalPaths.add(entity.path);
                    else _selectedLocalPaths.remove(entity.path);
                  });
                },
              ),
            ],
          ),
          onTap: () {
            if (isDir) _loadLocal(entity.path);
            else {
              setState(() {
                if (_selectedLocalPaths.contains(entity.path)) _selectedLocalPaths.remove(entity.path);
                else _selectedLocalPaths.add(entity.path);
              });
            }
          },
          onLongPress: () {
             _showContextMenu(entity.path, sizeStr, true, isDir);
          },
        );
      },
    );
  }

  Widget _buildRemoteList() {
    if (remoteLoading) return const Center(child: CircularProgressIndicator());
    if (remoteError.isNotEmpty) return Center(child: Text(remoteError, style: const TextStyle(color: Colors.red)));
    
    return ListView.separated(
      itemCount: remoteFiles.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
      itemBuilder: (context, index) {
        final entry = remoteFiles[index];
        final isDir = entry.isDir;
        
        String sizeStr = isDir ? "" : formatBytes(entry.size);

        return ListTile(
          dense: true,
          leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: isDir ? Colors.blue[300] : Colors.white70),
          title: Text(entry.name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDir) Text(sizeStr, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              Checkbox(
                activeColor: Colors.blueAccent,
                value: _selectedRemoteNames.contains(entry.name),
                onChanged: (bool? value) {
                  setState(() {
                    if (value == true) _selectedRemoteNames.add(entry.name);
                    else _selectedRemoteNames.remove(entry.name);
                  });
                },
              ),
            ],
          ),
          onTap: () {
            if (isDir) _changeRemoteDirectory(entry.name);
            else {
              setState(() {
                if (_selectedRemoteNames.contains(entry.name)) _selectedRemoteNames.remove(entry.name);
                else _selectedRemoteNames.add(entry.name);
              });
            }
          },
          onLongPress: () {
            _showContextMenu(entry.name, sizeStr, false, isDir);
          },
        );
      },
    );
  }
}