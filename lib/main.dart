import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:dartssh2/dartssh2.dart'; // SFTP desteği için eklendi

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FtpProApp());
}

class FtpProApp extends StatelessWidget {
  const FtpProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FTP Master',
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
  String privateKey; // SFTP private key yolu için eklendi
  bool savePassword;
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
        port: json['port'] ?? '21',
        localPath: json['localPath'] ?? '',
        remotePath: json['remotePath'] ?? '',
        charset: json['charset'] ?? 'UTF-8',
      );
}

// FTP ve SFTP listelemelerini ortak kullanmak için ara model
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

// --- GİRİŞ EKRANI (LOGIN) ---
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  List<FtpProfile> profiles = [];
  FtpProfile? selectedProfile;
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

  void _connect() {
    if (selectedProfile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DualFileManagerScreen(profile: selectedProfile!)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.public, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Ftp Master'), // İsim güncellendi
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
                      onPressed: _connect,
                      child: const Text('Connect', style: TextStyle(fontSize: 16)),
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
            const Spacer(), // Alttaki büyük dünya ikonları kaldırıldı
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
  late TextEditingController privateKeyCtrl; // Özel anahtar controllerı
  late TextEditingController portCtrl;
  late TextEditingController localPathCtrl;
  late TextEditingController remotePathCtrl;
  
  String selectedMode = 'FTP';
  String selectedCharset = 'UTF-8';
  bool savePass = true;

  final List<String> ftpModes = [
    'FTP',
    'FTPES (Explicit secure FTP)',
    'FTPS (Implicit secure FTP)',
    'SFTP (FTP over SSH)', // SFTP eklendi
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
    portCtrl = TextEditingController(text: widget.profile?.port ?? '21');
    localPathCtrl = TextEditingController(text: widget.profile?.localPath ?? '');
    remotePathCtrl = TextEditingController(text: widget.profile?.remotePath ?? '');
    
    if (widget.profile != null) {
      selectedMode = widget.profile!.mode;
      if (!ftpModes.contains(selectedMode)) selectedMode = 'FTP';
      savePass = widget.profile!.savePassword;
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
      port: portCtrl.text,
      localPath: localPathCtrl.text,
      remotePath: remotePathCtrl.text,
      charset: selectedCharset,
    );
    Navigator.pop(context, newProfile);
  }

  // --- BROWSER: KLASÖR SEÇİCİ (Local Path İçin) ---
  Future<void> _showDirectoryPicker() async {
    await Permission.manageExternalStorage.request();
    await Permission.storage.request();

    String currentPath = localPathCtrl.text.isNotEmpty ? localPathCtrl.text : '/storage/emulated/0';
    if (!Directory(currentPath).existsSync()) {
      currentPath = '/storage/emulated/0';
    }
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
                        onTap: () {
                          final parent = Directory(currentPath).parent.path;
                          loadDirs(parent, setDialogState);
                        },
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: dirs.length,
                        itemBuilder: (context, index) {
                          final dir = dirs[index];
                          final name = dir.path.split('/').last;
                          final isSelected = selectedPath == dir.path;
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder, color: Colors.blueAccent),
                            title: Text(name),
                            trailing: Checkbox(
                              activeColor: Colors.blueAccent,
                              value: isSelected,
                              onChanged: (val) {
                                setDialogState(() => selectedPath = dir.path);
                              },
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

  // --- BROWSER: DOSYA SEÇİCİ (Private Key İçin) ---
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
            if (entities.isEmpty && Directory(currentPath).existsSync()) {
              loadEntities(currentPath, setDialogState);
            }
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
                          final isSelected = selectedFile == entity.path;

                          return ListTile(
                            dense: true,
                            leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: Colors.blueAccent),
                            title: Text(name),
                            trailing: isDir ? null : Checkbox(
                              activeColor: Colors.blueAccent,
                              value: isSelected,
                              onChanged: (val) {
                                setDialogState(() => selectedFile = entity.path);
                              },
                            ),
                            onTap: () {
                              if (isDir) {
                                loadEntities(entity.path, setDialogState);
                              } else {
                                setDialogState(() => selectedFile = entity.path);
                              }
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
                    if (selectedFile.isNotEmpty) {
                      privateKeyCtrl.text = selectedFile;
                    }
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
                            if (selectedMode == 'SFTP (FTP over SSH)') {
                              portCtrl.text = '22'; // SFTP varsayılan port
                            } else if (portCtrl.text == '22') {
                              portCtrl.text = '21';
                            }
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
                    
                    // SADECE SFTP SEÇİLİYSE PRIVATE KEY ALANINI GÖSTER
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

  // FTP ve SFTP İstemcileri
  FTPConnect? _ftpConnect;
  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  bool get _isSftp => widget.profile.mode.contains('SFTP');

  List<RemoteEntry> remoteFiles = []; // Ortak liste modeli kullanılıyor
  bool remoteLoading = true;
  String remotePath = '/';
  String remoteError = '';
  final Set<String> _selectedRemoteNames = {};

  @override
  void initState() {
    super.initState();
    if (widget.profile.localPath.isNotEmpty) {
      localPath = widget.profile.localPath;
    } else {
      localPath = '/storage/emulated/0';
    }
    
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

  // --- SORTING LOGIC ---
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
      files.sort((a, b) => b.size.compareTo(a.size));
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
                  _tabController.index == 0 ? _loadLocal(localPath) : _loadRemote();
                },
              );
            }).toList(),
          ),
        );
      }
    );
  }

  // --- PATH NAVIGATION LOGIC ---
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

  // --- LOCAL LOGIC ---
  Future<void> _initLocal() async {
    await Permission.manageExternalStorage.request();
    await Permission.storage.request();
    
    if (localPath.isEmpty) {
      localPath = '/storage/emulated/0';
    }
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
          if (e is Directory) {
            folders.add(e);
          } else {
            files.add(e);
          }
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

  // --- REMOTE LOGIC (FTP & SFTP DESTEĞİ) ---
  Future<void> _initRemote() async {
    setState(() { remoteLoading = true; remoteError = ''; });
    try {
      if (_isSftp) {
        // SFTP BAĞLANTISI (dartssh2)
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
        );
        
        _sftpClient = await _sshClient!.sftp();
        
      } else {
        // NORMAL FTP/FTPS/FTPES BAĞLANTISI (ftpconnect)
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
        if (remotePath != '/') {
          await _ftpConnect!.changeDirectory(remotePath);
        }
      }
      _loadRemote();
    } catch (e) {
      setState(() { remoteLoading = false; remoteError = e.toString(); });
    }
  }

  Future<void> _loadRemote() async {
    setState(() => remoteLoading = true);
    try {
      List<RemoteEntry> folders = [];
      List<RemoteEntry> files = [];

      if (_isSftp) {
        // SFTP DOSYA LİSTELEME
        final content = await _sftpClient!.listdir(remotePath == '/' ? '.' : remotePath);
        for (var e in content) {
          if (e.filename == '.' || e.filename == '..') continue;
          final isDir = e.attr.isDirectory;
          final entry = RemoteEntry(name: e.filename, isDir: isDir, size: e.attr.size ?? 0);
          if (isDir) folders.add(entry); else files.add(entry);
        }
      } else {
        // FTP DOSYA LİSTELEME
        final content = await _ftpConnect!.listDirectoryContent();
        for (var e in content) {
          final isDir = e.type == FTPEntryType.dir;
          final entry = RemoteEntry(name: e.name, isDir: isDir, size: e.size ?? 0);
          if (isDir) folders.add(entry); else files.add(entry);
        }
      }
      
      _sortRemoteFiles(folders, files);

      setState(() {
        remoteFiles = [...folders, ...files];
        remoteLoading = false;
        _selectedRemoteNames.clear();
      });
    } catch (e) {
      setState(() { remoteLoading = false; remoteError = 'Error: $e'; });
    }
  }

  Future<void> _changeRemoteDirectory(String dirName) async {
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
      await _loadRemote();
    } catch (e) {
      setState(() => remoteLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  // --- ACTION LOGIC (CREATE, RENAME, DELETE) ---
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
              Navigator.pop(c);
              String name = ctrl.text.trim();
              if (name.isEmpty) return;

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
                  _loadRemote();
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
              Navigator.pop(c);
              String newName = ctrl.text.trim();
              if (newName.isEmpty || newName == (isLocal ? oldName.split('/').last : oldName)) return;

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
                  _loadRemote();
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
        _loadRemote();
      }
    }
  }

  // --- UZUN BASMA (LONG PRESS) MENÜSÜ ---
  void _showContextMenu(String itemName, String sizeStr, bool isLocal, bool isDir) {
    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(itemName.split('/').last, style: const TextStyle(fontSize: 16, color: Colors.blueAccent)),
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
                  _selectedLocalPaths.add(itemName);
                } else {
                  _selectedRemoteNames.add(itemName);
                }
                _transferSelectedItems();
              }, 
              child: Text(isLocal ? 'Upload' : 'Download')
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context);
                _renameItem(itemName, isLocal);
              }, 
              child: const Text('Rename')
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context);
                _deleteItems([itemName], isLocal);
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
          ],
        );
      }
    );
  }

  // --- TRANSFER LOGIC (SFTP DESTEKLİ) ---
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
          // UPLOAD YAPIYORUZ
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
          // DOWNLOAD YAPIYORUZ
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
      _loadRemote();
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

  // --- 3-NOKTA MENÜ FONKSİYONLARI ---
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

    return Scaffold(
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
                isLocal ? _loadLocal(localPath) : _loadRemote();
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
                      final parent = Directory(localPath).parent.path;
                      if (parent != localPath) _loadLocal(parent);
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
