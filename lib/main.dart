import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart' as provider;
import 'package:redis/redis.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();

const String _nearbyChannelId = 'nearby_terpiez_channel';
const String _backgroundLocationsKey = 'background_available_locations';

Future<bool> _initializeNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

  const iosSettings = DarwinInitializationSettings(
    requestSoundPermission: true,
    requestAlertPermission: true,
    requestBadgePermission: true,
  );

  const settings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  final launchDetails = await _notifications.getNotificationAppLaunchDetails();

  await _notifications.initialize(settings);

  final androidPlugin = _notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  await androidPlugin?.requestNotificationsPermission();

  const channel = AndroidNotificationChannel(
    _nearbyChannelId,
    'Nearby Terpiez',
    description: 'Alerts when you are near an uncaught Terpiez.',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('nearby_chime'),
  );

  await androidPlugin?.createNotificationChannel(channel);

  return launchDetails?.didNotificationLaunchApp ?? false;
}

Future<void> _initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  final running = await service.isRunning();
  if (running) return;

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _backgroundServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: _nearbyChannelId,
      initialNotificationTitle: 'Terpiez',
      initialNotificationContent: 'Watching for nearby Terpiez',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: _backgroundServiceStart,
      onBackground: _backgroundIosHandler,
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
Future<bool> _backgroundIosHandler(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void _backgroundServiceStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final notifications = FlutterLocalNotificationsPlugin();

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

  const settings = InitializationSettings(android: androidSettings);

  await notifications.initialize(settings);

  final androidPlugin = notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  const channel = AndroidNotificationChannel(
    _nearbyChannelId,
    'Nearby Terpiez',
    description: 'Alerts when you are near an uncaught Terpiez.',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('nearby_chime'),
  );

  await androidPlugin?.createNotificationChannel(channel);

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  DateTime? lastNotificationTime;

  Timer.periodic(const Duration(seconds: 5), (_) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawLocations = prefs.getString(_backgroundLocationsKey);

      if (rawLocations == null || rawLocations.isEmpty) return;

      final decoded = jsonDecode(rawLocations);
      if (decoded is! List || decoded.isEmpty) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      );

      double? closestDistance;

      for (final item in decoded) {
        if (item is! Map) continue;

        final lat = item['lat'];
        final lon = item['lon'];

        if (lat is! num || lon is! num) continue;

        final distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          lat.toDouble(),
          lon.toDouble(),
        );

        if (closestDistance == null || distance < closestDistance) {
          closestDistance = distance;
        }
      }

      if (closestDistance == null) return;

      if (closestDistance <= 20.0) {
        final now = DateTime.now();

        if (lastNotificationTime != null &&
            now.difference(lastNotificationTime!).inSeconds < 20) {
          return;
        }

        lastNotificationTime = now;

        await notifications.show(
          1001,
          'A Terpiez is near',
          'There is a Terpiez ${closestDistance.round()}m away!',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _nearbyChannelId,
              'Nearby Terpiez',
              channelDescription:
                  'Alerts when you are near an uncaught Terpiez.',
              importance: Importance.high,
              priority: Priority.high,
              playSound: true,
              sound: RawResourceAndroidNotificationSound('nearby_chime'),
            ),
          ),
          payload: 'finder',
        );
      }
    } catch (_) {
      // Background service should stay alive even if one location check fails.
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final launchFinder = await _initializeNotifications();
  await _initializeBackgroundService();

  runApp(
    provider.ChangeNotifierProvider(
      create: (_) => TerpiezModel()..initialize(),
      child: TerpiezApp(initialTabIndex: launchFinder ? 1 : 0),
    ),
  );
}

class TerpiezApp extends StatelessWidget {
  const TerpiezApp({super.key, required this.initialTabIndex});

  final int initialTabIndex;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Terpiez',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
      ),
      home: RootGate(initialTabIndex: initialTabIndex),
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key, required this.initialTabIndex});

  final int initialTabIndex;

  @override
  Widget build(BuildContext context) {
    return provider.Consumer<TerpiezModel>(
      builder: (context, model, child) {
        if (!model.isInitialized) {
          return const Scaffold(
            body: SafeArea(child: Center(child: CircularProgressIndicator())),
          );
        }

        if (!model.hasCredentials) {
          return const CredentialsScreen();
        }

        return TerpiezHomePage(initialTabIndex: initialTabIndex);
      },
    );
  }
}

class TerpiezHomePage extends StatefulWidget {
  const TerpiezHomePage({super.key, required this.initialTabIndex});

  final int initialTabIndex;

  @override
  State<TerpiezHomePage> createState() => _TerpiezHomePageState();
}

class _TerpiezHomePageState extends State<TerpiezHomePage> {
  bool? _lastConnectionState;

  @override
  Widget build(BuildContext context) {
    return provider.Consumer<TerpiezModel>(
      builder: (context, model, child) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;

          if (_lastConnectionState == null) {
            _lastConnectionState = model.isConnected;
            return;
          }

          if (_lastConnectionState != model.isConnected) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  model.isConnected
                      ? 'Redis connection restored'
                      : 'Redis connection lost',
                ),
                backgroundColor: model.isConnected ? Colors.green : Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );

            _lastConnectionState = model.isConnected;
          }
        });

        return DefaultTabController(
          length: 3,
          initialIndex: widget.initialTabIndex,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Terpiez'),
              backgroundColor: Theme.of(context).colorScheme.inversePrimary,
              bottom: const TabBar(
                tabs: [
                  Tab(icon: Icon(Icons.query_stats), text: 'Stats'),
                  Tab(icon: Icon(Icons.map), text: 'Finder'),
                  Tab(icon: Icon(Icons.list), text: 'List'),
                ],
              ),
            ),
            drawer: Drawer(
              child: provider.Consumer<TerpiezModel>(
                builder: (context, model, child) {
                  return ListView(
                    children: [
                      DrawerHeader(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              'Terpiez Settings',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Customize your experience',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),

                      SwitchListTile(
                        secondary: const Icon(Icons.volume_up),
                        title: const Text('Enable Sounds'),
                        subtitle: const Text('Controls in-app sound effects'),
                        value: model.soundEnabled,
                        onChanged: (value) {
                          model.setSoundEnabled(value);
                        },
                      ),

                      ListTile(
                        leading: const Icon(Icons.music_note),
                        title: const Text('Test Catch Sound'),
                        onTap: () async {
                          final pool = await AudioPool.create(
                            source: AssetSource('sounds/catch_ping.mp3'),
                            maxPlayers: 1,
                          );

                          await pool.start(volume: 1.0);
                        },
                      ),

                      const Divider(),

                      ListTile(
                        leading: const Icon(
                          Icons.delete_forever,
                          color: Colors.red,
                        ),
                        title: const Text(
                          'Reset All Data',
                          style: TextStyle(color: Colors.red),
                        ),
                        subtitle: const Text('Deletes all catches and stats'),
                        onTap: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) {
                              return AlertDialog(
                                title: const Text('Reset Data?'),
                                content: const Text(
                                  'This will permanently delete all Terpiez catches, statistics, and your current user ID.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(dialogContext, false);
                                    },
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () {
                                      Navigator.pop(dialogContext, true);
                                    },
                                    child: const Text('Reset'),
                                  ),
                                ],
                              );
                            },
                          );

                          if (confirm == true) {
                            await model.resetAllData();

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('All Terpiez data reset'),
                                ),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            body: const SafeArea(
              child: TabBarView(
                children: [StatsTab(), FinderTab(), TerpiezListTab()],
              ),
            ),
          ),
        );
      },
    );
  }
}

/* =========================
   MODEL
   ========================= */

class TerpiezModel extends ChangeNotifier {
  static const String _prefsUserIdKey = 'user_id';
  static const String _prefsFirstRunKey = 'first_run_iso';
  static const String _prefsCatchCountKey = 'catch_count';

  static const String _secureRedisUserKey = 'redis_username';
  static const String _secureRedisPassKey = 'redis_password';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final RedisRepository _redis = RedisRepository();

  SharedPreferences? _prefs;
  Directory? _docsDir;

  bool _isInitialized = false;
  bool _hasCredentials = false;
  bool _isRefreshingLocations = false;
  bool _isConnected = true;
  bool _soundEnabled = true;

  String? _userId;
  DateTime? _firstRun;
  int _totalCaught = 0;

  String? _redisUsername;
  String? _redisPassword;

  String? _statusMessage;

  Timer? _connectionTimer;

  List<RemoteTerpiezLocation> _availableLocations = [];
  final Map<String, CaughtSpecies> _caughtSpecies = {};
  final Set<String> _caughtLocationFingerprints = {};

  bool get isInitialized => _isInitialized;
  bool get hasCredentials => _hasCredentials;
  bool get isRefreshingLocations => _isRefreshingLocations;
  bool get isConnected => _isConnected;
  bool get soundEnabled => _soundEnabled;

  String get userId => _userId ?? '';
  int get terpiezCaught => _totalCaught;
  String? get statusMessage => _statusMessage;

  List<CaughtSpecies> get caughtSpeciesList {
    final list = _caughtSpecies.values.toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<RemoteTerpiezLocation> get availableLocations =>
      List.unmodifiable(_availableLocations);

  int get daysActive {
    final firstRun = _firstRun;
    if (firstRun == null) return 0;
    final now = DateTime.now();
    final start = DateTime(firstRun.year, firstRun.month, firstRun.day);
    final today = DateTime(now.year, now.month, now.day);
    return today.difference(start).inDays;
  }

  Future<void> initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _docsDir = await getApplicationDocumentsDirectory();
      _soundEnabled = _prefs!.getBool('sound_enabled') ?? true;

      await _initializeIdentity();
      await _loadSecureCredentials();
      await _loadLocalCaughtData();

      if (_hasCredentials) {
        await refreshLocations();
      }
    } catch (e) {
      _statusMessage = 'Startup error: $e';
    } finally {
      _isInitialized = true;
      _startConnectionMonitor();
      notifyListeners();
    }
  }

  void _startConnectionMonitor() {
    _connectionTimer?.cancel();

    _connectionTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_hasCredentials) return;

      final previous = _isConnected;

      try {
        final success = await _redis.validateCredentials(
          username: _redisUsername!,
          password: _redisPassword!,
        );

        _isConnected = success;
      } catch (_) {
        _isConnected = false;
      }

      if (previous != _isConnected) {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    super.dispose();
  }

  Future<void> setSoundEnabled(bool value) async {
    _soundEnabled = value;
    await _prefs!.setBool('sound_enabled', value);
    notifyListeners();
  }

  Future<void> resetAllData() async {
    final oldUserId = _userId;
    final newUserId = const Uuid().v4();
    final now = DateTime.now();

    _caughtSpecies.clear();
    _caughtLocationFingerprints.clear();
    _availableLocations = [];

    _totalCaught = 0;
    _firstRun = now;
    _userId = newUserId;

    await _prefs!.setString(_prefsUserIdKey, newUserId);
    await _prefs!.setString(_prefsFirstRunKey, now.toIso8601String());
    await _prefs!.setInt(_prefsCatchCountKey, 0);

    final cacheFile = await _speciesCacheFile;
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }

    try {
      if (_hasCredentials && _isConnected && oldUserId != null) {
        await _redis.registerUser(
          username: _redisUsername!,
          password: _redisPassword!,
          oldUserId: oldUserId,
          newUserId: newUserId,
        );
      }
    } catch (_) {}

    await refreshLocations();
    await _syncBackgroundLocationData();

    notifyListeners();
  }

  Future<void> _initializeIdentity() async {
    final prefs = _prefs!;
    final storedUserId = prefs.getString(_prefsUserIdKey);
    final storedFirstRun = prefs.getString(_prefsFirstRunKey);
    final storedCatchCount = prefs.getInt(_prefsCatchCountKey);

    if (storedUserId == null) {
      _userId = const Uuid().v4();
      await prefs.setString(_prefsUserIdKey, _userId!);
    } else {
      _userId = storedUserId;
    }

    if (storedFirstRun == null) {
      _firstRun = DateTime.now();
      await prefs.setString(_prefsFirstRunKey, _firstRun!.toIso8601String());
    } else {
      _firstRun = DateTime.tryParse(storedFirstRun) ?? DateTime.now();
    }

    _totalCaught = storedCatchCount ?? 0;
    if (storedCatchCount == null) {
      await prefs.setInt(_prefsCatchCountKey, _totalCaught);
    }
  }

  Future<void> _loadSecureCredentials() async {
    _redisUsername = await _secureStorage.read(key: _secureRedisUserKey);
    _redisPassword = await _secureStorage.read(key: _secureRedisPassKey);
    _hasCredentials =
        (_redisUsername != null && _redisUsername!.isNotEmpty) &&
        (_redisPassword != null && _redisPassword!.isNotEmpty);
  }

  Future<void> _loadLocalCaughtData() async {
    final file = await _speciesCacheFile;
    if (!await file.exists()) {
      return;
    }

    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;

      final speciesMap = decoded['species'];
      final fingerprints = decoded['caughtLocationFingerprints'];

      if (speciesMap is Map<String, dynamic>) {
        for (final entry in speciesMap.entries) {
          final value = entry.value;
          if (value is Map<String, dynamic>) {
            _caughtSpecies[entry.key] = CaughtSpecies.fromJson(value);
          }
        }
      }

      if (fingerprints is List) {
        for (final item in fingerprints) {
          if (item is String) {
            _caughtLocationFingerprints.add(item);
          }
        }
      }
    } catch (e) {
      _statusMessage = 'Local cache read error: $e';
    }
  }

  Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    final isValid = await _redis.validateCredentials(
      username: username,
      password: password,
    );

    if (!isValid) {
      throw Exception('Redis login failed. Check VPN/network and credentials.');
    }

    await _secureStorage.write(key: _secureRedisUserKey, value: username);
    await _secureStorage.write(key: _secureRedisPassKey, value: password);

    _redisUsername = username;
    _redisPassword = password;
    _hasCredentials = true;
    _statusMessage = null;
    notifyListeners();

    await refreshLocations();
  }

  Future<void> refreshLocations() async {
    if (!_isConnected) return;
    if (!_hasCredentials) return;

    _isRefreshingLocations = true;
    _statusMessage = null;
    notifyListeners();

    try {
      final locations = await _redis.fetchLocations(
        username: _redisUsername!,
        password: _redisPassword!,
      );

      _availableLocations = locations
          .where(
            (location) =>
                !_caughtLocationFingerprints.contains(location.fingerprint),
          )
          .toList();
      await _syncBackgroundLocationData();
    } catch (e) {
      final wasConnected = _isConnected;
      _isConnected = false;

      if (wasConnected != _isConnected) {
        _statusMessage = null;
      } else {
        _statusMessage = 'Could not refresh locations: $e';
      }
    } finally {
      _isRefreshingLocations = false;
      notifyListeners();
    }
  }

  Future<void> _syncBackgroundLocationData() async {
    final prefs = _prefs;
    if (prefs == null) return;

    final payload = _availableLocations.map((location) {
      return {
        'id': location.speciesId,
        'lat': location.location.latitude,
        'lon': location.location.longitude,
      };
    }).toList();

    await prefs.setString(_backgroundLocationsKey, jsonEncode(payload));
  }

  RemoteTerpiezLocation? closestUncaughtTo(Position? position) {
    if (position == null || _availableLocations.isEmpty) return null;

    RemoteTerpiezLocation? closest;
    double minDistance = double.infinity;

    for (final location in _availableLocations) {
      final d = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        location.location.latitude,
        location.location.longitude,
      );

      if (d < minDistance) {
        minDistance = d;
        closest = location;
      }
    }

    return closest;
  }

  double? distanceToClosest(Position? position) {
    final closest = closestUncaughtTo(position);
    if (closest == null || position == null) return null;

    return Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      closest.location.latitude,
      closest.location.longitude,
    );
  }

  bool canCatch(Position? position) {
    final d = distanceToClosest(position);
    return d != null && d <= 10.0;
  }

  Future<CaughtSpecies> catchClosest(Position position) async {
    if (!_isConnected) {
      throw Exception('No Redis connection.');
    }

    final closest = closestUncaughtTo(position);
    if (closest == null) {
      throw Exception('No Terpiez available to catch.');
    }

    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      closest.location.latitude,
      closest.location.longitude,
    );

    if (distance > 10.0) {
      throw Exception('You are not close enough to catch this Terpiez.');
    }

    if (!_hasCredentials) {
      throw Exception('Missing Redis credentials.');
    }

    final speciesId = closest.speciesId;

    RemoteSpeciesData remoteSpecies;
    if (_caughtSpecies.containsKey(speciesId)) {
      remoteSpecies = RemoteSpeciesData.fromCaught(_caughtSpecies[speciesId]!);
    } else {
      remoteSpecies = await _redis.fetchSpecies(
        username: _redisUsername!,
        password: _redisPassword!,
        speciesId: speciesId,
      );

      final thumbBytes = await _redis.fetchImageBytes(
        username: _redisUsername!,
        password: _redisPassword!,
        imageKey: remoteSpecies.thumbnailKey,
      );

      final imageBytes = await _redis.fetchImageBytes(
        username: _redisUsername!,
        password: _redisPassword!,
        imageKey: remoteSpecies.imageKey,
      );

      final thumbPath = await _saveImageBytes(
        fileName: 'thumb_$speciesId.png',
        bytes: thumbBytes,
      );

      final imagePath = await _saveImageBytes(
        fileName: 'image_$speciesId.png',
        bytes: imageBytes,
      );

      _caughtSpecies[speciesId] = CaughtSpecies(
        speciesId: speciesId,
        name: remoteSpecies.name,
        description: remoteSpecies.description,
        stats: remoteSpecies.stats,
        thumbnailPath: thumbPath,
        imagePath: imagePath,
        catches: [],
      );
    }

    final species = _caughtSpecies[speciesId]!;
    species.catches.add(
      CatchRecord(
        latitude: closest.location.latitude,
        longitude: closest.location.longitude,
        caughtAtIso: DateTime.now().toIso8601String(),
      ),
    );

    _caughtLocationFingerprints.add(closest.fingerprint);
    _availableLocations.removeWhere(
      (location) => location.fingerprint == closest.fingerprint,
    );
    await _syncBackgroundLocationData();
    await _notifications.cancel(1001);

    _totalCaught++;
    await _prefs?.setInt(_prefsCatchCountKey, _totalCaught);

    await _writeLocalCaughtData();
    await _backupUserStateToRedis();

    notifyListeners();

    return species;
  }

  Future<String> _saveImageBytes({
    required String fileName,
    required List<int> bytes,
  }) async {
    final dir = _docsDir!;
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _writeLocalCaughtData() async {
    final file = await _speciesCacheFile;

    final payload = <String, dynamic>{
      'species': _caughtSpecies.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'caughtLocationFingerprints': _caughtLocationFingerprints.toList(),
    };

    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  Future<void> _backupUserStateToRedis() async {
    if (!_hasCredentials) return;

    final backup = <String, dynamic>{
      'userId': _userId,
      'firstRunIso': _firstRun?.toIso8601String(),
      'catchCount': _totalCaught,
      'species': _caughtSpecies.map(
        (key, value) => MapEntry(key, value.toBackupJson()),
      ),
      'caughtLocationFingerprints': _caughtLocationFingerprints.toList(),
      'lastUpdatedIso': DateTime.now().toIso8601String(),
    };

    await _redis.storeUserBackup(
      username: _redisUsername!,
      password: _redisPassword!,
      userId: _userId!,
      backupJson: backup,
    );
  }

  Future<File> get _speciesCacheFile async {
    final dir = _docsDir!;
    return File('${dir.path}/caught_species.json');
  }
}

/* =========================
   REDIS
   ========================= */

class RedisRepository {
  static const Duration _timeout = Duration(seconds: 1);
  static const String _host = 'cmsc436-0101-redis.cs.umd.edu';
  static const int _port = 6380;

  Future<T> _withCommand<T>({
    required String username,
    required String password,
    required Future<T> Function(Command command) action,
  }) async {
    final conn = RedisConnection();
    try {
      final command = await conn.connect(_host, _port).timeout(_timeout);
      await _sendWithTimeout(command, ['AUTH', username, password]);
      return await action(command).timeout(_timeout);
    } finally {
      await conn.close();
    }
  }

  Future<dynamic> _sendWithTimeout(Command command, List<dynamic> object) {
    return command.send_object(object).timeout(_timeout);
  }

  Future<bool> validateCredentials({
    required String username,
    required String password,
  }) async {
    try {
      return await _withCommand<bool>(
        username: username,
        password: password,
        action: (command) async {
          await _sendWithTimeout(command, ['JSON.ARRLEN', 'locations', '.']);
          return true;
        },
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> registerUser({
    required String username,
    required String password,
    required String oldUserId,
    required String newUserId,
  }) async {
    await _withCommand<void>(
      username: username,
      password: password,
      action: (command) async {
        await _sendWithTimeout(command, ['JSON.DEL', 'users', '.$oldUserId']);

        await _sendWithTimeout(command, [
          'JSON.SET',
          'users',
          '.$newUserId',
          '{}',
        ]);
      },
    );
  }

  Future<List<RemoteTerpiezLocation>> fetchLocations({
    required String username,
    required String password,
  }) async {
    return _withCommand<List<RemoteTerpiezLocation>>(
      username: username,
      password: password,
      action: (command) async {
        final raw = await _sendWithTimeout(command, [
          'JSON.GET',
          'locations',
          '.',
        ]);
        final decoded = _decodeRedisJson(raw);

        final locations = <RemoteTerpiezLocation>[];

        if (decoded is List) {
          for (final item in decoded) {
            final location = RemoteTerpiezLocation.tryParse(item);
            if (location != null) {
              locations.add(location);
            }
          }
        }

        return locations;
      },
    );
  }

  Future<RemoteSpeciesData> fetchSpecies({
    required String username,
    required String password,
    required String speciesId,
  }) async {
    return _withCommand<RemoteSpeciesData>(
      username: username,
      password: password,
      action: (command) async {
        final raw = await _sendWithTimeout(command, [
          'JSON.GET',
          'terpiez',
          '.$speciesId',
        ]);
        final decoded = _decodeRedisJson(raw);

        if (decoded is! Map<String, dynamic>) {
          throw Exception('Unexpected species format for $speciesId.');
        }

        return RemoteSpeciesData.fromRedis(speciesId, decoded);
      },
    );
  }

  Future<List<int>> fetchImageBytes({
    required String username,
    required String password,
    required String imageKey,
  }) async {
    return _withCommand<List<int>>(
      username: username,
      password: password,
      action: (command) async {
        final raw = await _sendWithTimeout(command, [
          'JSON.GET',
          'images',
          '.$imageKey',
        ]);
        final decoded = _decodeRedisJson(raw);

        if (decoded is String) {
          return base64Decode(decoded);
        }

        if (decoded is Map<String, dynamic>) {
          final candidate = _stringFromAny([
            decoded['data'],
            decoded['image'],
            decoded['bytes'],
            decoded['base64'],
            decoded['content'],
          ]);

          if (candidate != null) {
            return base64Decode(candidate);
          }
        }

        throw Exception('Unexpected image format for $imageKey.');
      },
    );
  }

  Future<void> storeUserBackup({
    required String username,
    required String password,
    required String userId,
    required Map<String, dynamic> backupJson,
  }) async {
    await _withCommand<void>(
      username: username,
      password: password,
      action: (command) async {
        final existing = await _sendWithTimeout(command, [
          'JSON.GET',
          username,
          '.',
        ]);
        if (existing == null) {
          await _sendWithTimeout(command, ['JSON.SET', username, '.', '{}']);
        }

        await _sendWithTimeout(command, [
          'JSON.SET',
          username,
          '.$userId',
          jsonEncode(backupJson),
        ]);
      },
    );
  }

  static dynamic _decodeRedisJson(dynamic raw) {
    if (raw == null) return null;
    if (raw is num || raw is bool) return raw;

    final text = raw.toString();
    if (text == 'null') return null;

    try {
      final decoded = jsonDecode(text);
      return _normalizeDecoded(decoded);
    } catch (_) {
      return text;
    }
  }

  static dynamic _normalizeDecoded(dynamic decoded) {
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), _normalizeDecoded(value)),
      );
    }
    if (decoded is List) {
      return decoded.map(_normalizeDecoded).toList();
    }
    return decoded;
  }
}

/* =========================
   DATA CLASSES
   ========================= */

class RemoteTerpiezLocation {
  const RemoteTerpiezLocation({
    required this.speciesId,
    required this.location,
  });

  final String speciesId;
  final LatLng location;

  String get fingerprint =>
      '$speciesId|${location.latitude.toStringAsFixed(6)}|${location.longitude.toStringAsFixed(6)}';

  static RemoteTerpiezLocation? tryParse(dynamic raw) {
    if (raw is List && raw.length >= 3) {
      final lat = _doubleFromAny(raw[0]);
      final lon = _doubleFromAny(raw[1]);
      final id = _stringFromAny([raw[2]]);

      if (lat != null && lon != null && id != null) {
        return RemoteTerpiezLocation(speciesId: id, location: LatLng(lat, lon));
      }
    }

    if (raw is Map<String, dynamic>) {
      final lat = _doubleFromAny([raw['lat'], raw['latitude'], raw['y']]);

      final lon = _doubleFromAny([
        raw['lon'],
        raw['lng'],
        raw['long'],
        raw['longitude'],
        raw['x'],
      ]);

      final id = _stringFromAny([
        raw['id'],
        raw['terpiez'],
        raw['terpiez_id'],
        raw['species'],
        raw['species_id'],
        raw['identifier'],
      ]);

      if (lat != null && lon != null && id != null) {
        return RemoteTerpiezLocation(speciesId: id, location: LatLng(lat, lon));
      }
    }

    return null;
  }
}

class RemoteSpeciesData {
  RemoteSpeciesData({
    required this.speciesId,
    required this.name,
    required this.description,
    required this.stats,
    required this.thumbnailKey,
    required this.imageKey,
  });

  final String speciesId;
  final String name;
  final String description;
  final Map<String, dynamic> stats;
  final String thumbnailKey;
  final String imageKey;

  factory RemoteSpeciesData.fromRedis(
    String speciesId,
    Map<String, dynamic> raw,
  ) {
    final name =
        _stringFromAny([raw['name'], raw['species'], raw['title']]) ??
        'Unknown Terpiez';

    final description =
        _stringFromAny([
          raw['description'],
          raw['desc'],
          raw['details'],
          raw['flavor'],
        ]) ??
        'No description available.';

    final thumbnailKey =
        _stringFromAny([
          raw['thumbnail'],
          raw['thumb'],
          raw['thumbnail_key'],
        ]) ??
        '';

    final imageKey =
        _stringFromAny([
          raw['image'],
          raw['image_key'],
          raw['full'],
          raw['full_image'],
        ]) ??
        '';

    final statsMap = <String, dynamic>{};

    if (raw['stats'] is Map<String, dynamic>) {
      statsMap.addAll(raw['stats'] as Map<String, dynamic>);
    } else {
      for (final entry in raw.entries) {
        if ({
          'name',
          'species',
          'title',
          'description',
          'desc',
          'details',
          'flavor',
          'thumbnail',
          'thumb',
          'thumbnail_key',
          'image',
          'image_key',
          'full',
          'full_image',
        }.contains(entry.key)) {
          continue;
        }

        if (entry.value is num ||
            entry.value is String ||
            entry.value is bool) {
          statsMap[entry.key] = entry.value;
        }
      }
    }

    return RemoteSpeciesData(
      speciesId: speciesId,
      name: name,
      description: description,
      stats: statsMap,
      thumbnailKey: thumbnailKey,
      imageKey: imageKey,
    );
  }

  factory RemoteSpeciesData.fromCaught(CaughtSpecies caught) {
    return RemoteSpeciesData(
      speciesId: caught.speciesId,
      name: caught.name,
      description: caught.description,
      stats: caught.stats,
      thumbnailKey: '',
      imageKey: '',
    );
  }
}

class CatchRecord {
  CatchRecord({
    required this.latitude,
    required this.longitude,
    required this.caughtAtIso,
  });

  final double latitude;
  final double longitude;
  final String caughtAtIso;

  LatLng get latLng => LatLng(latitude, longitude);

  factory CatchRecord.fromJson(Map<String, dynamic> json) {
    return CatchRecord(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      caughtAtIso: json['caughtAtIso'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'caughtAtIso': caughtAtIso,
    };
  }
}

class CaughtSpecies {
  CaughtSpecies({
    required this.speciesId,
    required this.name,
    required this.description,
    required this.stats,
    required this.thumbnailPath,
    required this.imagePath,
    required this.catches,
  });

  final String speciesId;
  final String name;
  final String description;
  final Map<String, dynamic> stats;
  final String thumbnailPath;
  final String imagePath;
  final List<CatchRecord> catches;

  factory CaughtSpecies.fromJson(Map<String, dynamic> json) {
    final catchList = (json['catches'] as List<dynamic>? ?? [])
        .map((e) => CatchRecord.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    return CaughtSpecies(
      speciesId: json['speciesId'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      stats: Map<String, dynamic>.from(json['stats'] as Map),
      thumbnailPath: json['thumbnailPath'] as String,
      imagePath: json['imagePath'] as String,
      catches: catchList,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'speciesId': speciesId,
      'name': name,
      'description': description,
      'stats': stats,
      'thumbnailPath': thumbnailPath,
      'imagePath': imagePath,
      'catches': catches.map((e) => e.toJson()).toList(),
    };
  }

  Map<String, dynamic> toBackupJson() => toJson();
}

/* =========================
   CREDENTIALS SCREEN
   ========================= */

class CredentialsScreen extends StatefulWidget {
  const CredentialsScreen({super.key});

  @override
  State<CredentialsScreen> createState() => _CredentialsScreenState();
}

class _CredentialsScreenState extends State<CredentialsScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final state = _formKey.currentState;
    if (state == null || !state.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await provider.Provider.of<TerpiezModel>(
        context,
        listen: false,
      ).saveCredentials(
        username: _userController.text.trim(),
        password: _passController.text,
      );
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 56,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Redis Login Required',
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Enter your Phase 4 Redis username and password to continue.',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _userController,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter your Redis username';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _passController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Enter your Redis password';
                            }
                            return null;
                          },
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: _saving ? null : _submit,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: Text(
                            _saving ? 'Checking...' : 'Save and Continue',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* =========================
   STATS TAB
   ========================= */

class StatsTab extends StatelessWidget {
  const StatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return provider.Consumer<TerpiezModel>(
      builder: (context, model, child) {
        return OrientationBuilder(
          builder: (context, orientation) {
            final isPortrait = orientation == Orientation.portrait;
            final spacing = isPortrait ? 15.0 : 12.0;

            return Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                children: [
                  Text(
                    'Statistics',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: spacing),
                  Expanded(
                    child: isPortrait
                        ? Column(
                            children: [
                              Expanded(
                                child: _StatCard(
                                  title: 'Terpiez Found',
                                  value: '${model.terpiezCaught}',
                                  icon: Icons.catching_pokemon,
                                ),
                              ),
                              SizedBox(height: spacing),
                              Expanded(
                                child: _StatCard(
                                  title: 'Days Active',
                                  value: '${model.daysActive}',
                                  icon: Icons.calendar_today,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: _StatCard(
                                  title: 'Terpiez Found',
                                  value: '${model.terpiezCaught}',
                                  icon: Icons.catching_pokemon,
                                ),
                              ),
                              SizedBox(width: spacing),
                              Expanded(
                                child: _StatCard(
                                  title: 'Days Active',
                                  value: '${model.daysActive}',
                                  icon: Icons.calendar_today,
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'User ID: ${model.userId}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortest = constraints.biggest.shortestSide;
            final iconSize = shortest * 0.22;
            final titleSize = shortest * 0.10;
            final valueSize = shortest * 0.18;

            return Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: iconSize.clamp(28.0, 70.0)),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: titleSize.clamp(16.0, 26.0),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontSize: valueSize.clamp(28.0, 48.0),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/* =========================
   FINDER TAB
   ========================= */

class FinderTab extends StatefulWidget {
  const FinderTab({super.key});

  @override
  State<FinderTab> createState() => _FinderTabState();
}

class _FinderTabState extends State<FinderTab> {
  static const LatLng _defaultCenter = LatLng(38.985998, -76.942539);

  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionSubscription;
  AudioPool? _catchPool;

  Position? _currentPosition;
  String? _locationStatus;
  bool _hasCenteredOnUser = false;
  bool _catchDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _initLocation();
    AudioPool.create(
      source: AssetSource('sounds/catch_ping.mp3'),
      maxPlayers: 1,
    ).then((pool) {
      _catchPool = pool;
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _catchPool?.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _locationStatus = 'Location services are disabled.';
      });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      setState(() {
        _locationStatus = 'Location permission denied.';
      });
      return;
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _locationStatus = 'Location permission permanently denied.';
      });
      return;
    }

    try {
      final initialPosition = await Geolocator.getCurrentPosition();
      if (!mounted) return;

      setState(() {
        _currentPosition = initialPosition;
        _locationStatus = null;
      });

      _moveMapToUser(initialPosition);

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 1,
            ),
          ).listen((position) {
            if (!mounted) return;
            setState(() {
              _currentPosition = position;
            });
            _moveMapToUser(position);
          });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locationStatus = 'Unable to get current location.';
      });
    }
  }

  void _moveMapToUser(Position position) {
    final userLatLng = LatLng(position.latitude, position.longitude);
    if (!_hasCenteredOnUser) {
      _mapController.move(userLatLng, 17.5);
      _hasCenteredOnUser = true;
    } else {
      _mapController.move(userLatLng, _mapController.camera.zoom);
    }
  }

  List<Marker> _buildMarkers(TerpiezModel model) {
    final markers = <Marker>[];

    final closest = model.closestUncaughtTo(_currentPosition);

    if (closest != null) {
      markers.add(
        Marker(
          point: closest.location,
          width: 90,
          height: 76,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on, color: Colors.red, size: 36),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Closest',
                  style: const TextStyle(fontSize: 9),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentPosition != null) {
      markers.add(
        Marker(
          point: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          width: 28,
          height: 28,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blue,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
        ),
      );
    }

    return markers;
  }

  Future<void> _catchAndShowDialog(TerpiezModel model) async {
    if (_currentPosition == null || _catchDialogOpen) return;

    _catchDialogOpen = true;

    try {
      if (model.soundEnabled) {
        await _catchPool?.start(volume: 1.0);
      }

      final caught = await model.catchClosest(_currentPosition!);

      if (!mounted) return;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          final screenHeight = MediaQuery.of(dialogContext).size.height;

          return AlertDialog(
            title: const Text(
              'You caught a Terpiez!',
              textAlign: TextAlign.center,
            ),

            content: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: screenHeight * 0.55),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      caught.name,
                      style: Theme.of(dialogContext).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Image.file(
                      File(caught.imagePath),
                      height: screenHeight < 450 ? 110 : 180,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Great!'),
              ),
            ],
          );
        },
      );
    } finally {
      _catchDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return provider.Consumer<TerpiezModel>(
      builder: (context, model, child) {
        final closestDistance = model.distanceToClosest(_currentPosition);
        final catchable = model.canCatch(_currentPosition);
        final closest = model.closestUncaughtTo(_currentPosition);

        return OrientationBuilder(
          builder: (context, orientation) {
            final isPortrait = orientation == Orientation.portrait;
            final spacing = isPortrait ? 15.0 : 12.0;

            return Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                children: [
                  Text(
                    'Terpiez Finder',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: spacing),
                  Expanded(
                    child: isPortrait
                        ? Column(
                            children: [
                              Expanded(
                                flex: 3,
                                child: _FinderMapCard(
                                  mapController: _mapController,
                                  markers: _buildMarkers(model),
                                ),
                              ),
                              SizedBox(height: spacing),
                              Expanded(
                                flex: 2,
                                child: _ClosestCard(
                                  distanceMeters: closestDistance,
                                  catchable: catchable,
                                  statusMessage:
                                      _locationStatus ?? model.statusMessage,
                                  hasRemainingTerpiez: closest != null,
                                  onCatch:
                                      (closest != null &&
                                          _currentPosition != null &&
                                          model.isConnected)
                                      ? () async {
                                          await _catchAndShowDialog(model);
                                        }
                                      : null,
                                  onRefresh: model.refreshLocations,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: _FinderMapCard(
                                  mapController: _mapController,
                                  markers: _buildMarkers(model),
                                ),
                              ),
                              SizedBox(width: spacing),
                              Expanded(
                                flex: 2,
                                child: _ClosestCard(
                                  distanceMeters: closestDistance,
                                  catchable: catchable,
                                  statusMessage:
                                      _locationStatus ?? model.statusMessage,
                                  hasRemainingTerpiez: closest != null,
                                  onCatch:
                                      (closest != null &&
                                          _currentPosition != null &&
                                          model.isConnected)
                                      ? () async {
                                          await _catchAndShowDialog(model);
                                        }
                                      : null,
                                  onRefresh: model.refreshLocations,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _FinderMapCard extends StatelessWidget {
  const _FinderMapCard({required this.mapController, required this.markers});

  final MapController mapController;
  final List<Marker> markers;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: FlutterMap(
        mapController: mapController,
        options: const MapOptions(
          initialCenter: _FinderTabState._defaultCenter,
          initialZoom: 16.5,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.terpiez',
          ),
          MarkerLayer(markers: markers),
        ],
      ),
    );
  }
}

class _ClosestCard extends StatefulWidget {
  const _ClosestCard({
    required this.distanceMeters,
    required this.catchable,
    required this.statusMessage,
    required this.hasRemainingTerpiez,
    required this.onCatch,
    required this.onRefresh,
  });

  final double? distanceMeters;
  final bool catchable;
  final String? statusMessage;
  final bool hasRemainingTerpiez;
  final Future<void> Function()? onCatch;
  final Future<void> Function() onRefresh;

  @override
  State<_ClosestCard> createState() => _ClosestCardState();
}

class _ClosestCardState extends State<_ClosestCard>
    with TickerProviderStateMixin {
  late final AnimationController _shakeController;
  late final AnimationController _successController;
  late final Animation<double> _shakeAnimation;

  bool _showFailedFlash = false;
  bool _busy = false;
  String? _localError;

  StreamSubscription? _accelerometerSub;

  @override
  void initState() {
    super.initState();

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );

    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 140),
    );

    _shakeAnimation = TweenSequence<double>(
      [
        TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
        TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
        TweenSequenceItem(tween: Tween(begin: 10, end: -8), weight: 2),
        TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 2),
        TweenSequenceItem(tween: Tween(begin: 8, end: -4), weight: 2),
        TweenSequenceItem(tween: Tween(begin: -4, end: 4), weight: 2),
        TweenSequenceItem(tween: Tween(begin: 4, end: 0), weight: 1),
      ],
    ).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeOut));

    _accelerometerSub = userAccelerometerEventStream().listen((event) {
      final strongEnough =
          event.x.abs() >= 10 || event.y.abs() >= 10 || event.z.abs() >= 10;

      if (strongEnough) {
        _handleCatchTap();
      }
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _successController.dispose();
    _accelerometerSub?.cancel();
    super.dispose();
  }

  String get _distanceText {
    if (widget.statusMessage != null) {
      return widget.statusMessage!;
    }
    if (!widget.hasRemainingTerpiez) {
      return 'No uncaught Terpiez remaining';
    }
    if (widget.distanceMeters == null) {
      return 'Locating...';
    }
    return '${widget.distanceMeters!.toStringAsFixed(2)} meters';
  }

  Future<void> _handleCatchTap() async {
    if (_busy) return;

    setState(() {
      _localError = null;
    });

    if (!widget.catchable || widget.onCatch == null) {
      setState(() {
        _showFailedFlash = true;
      });

      await _shakeController.forward(from: 0);

      if (mounted) {
        setState(() {
          _showFailedFlash = false;
        });
      }
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      await _successController.forward(from: 0);
      await _successController.reverse();
      await widget.onCatch!.call();
    } catch (e) {
      setState(() {
        _localError = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.of(context).size.shortestSide;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.near_me, size: shortest.clamp(40.0, 56.0)),
                const SizedBox(height: 10),
                Text(
                  'Closest Terpiez',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  _distanceText,
                  textAlign: TextAlign.center,
                  style: widget.statusMessage != null
                      ? Theme.of(context).textTheme.bodyMedium
                      : Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  !widget.hasRemainingTerpiez
                      ? 'Everything nearby is already caught'
                      : widget.catchable
                      ? 'A Terpiez is in range'
                      : 'No Terpiez in range',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 14),
                AnimatedBuilder(
                  animation: Listenable.merge([
                    _shakeController,
                    _successController,
                  ]),
                  builder: (context, child) {
                    final successScale =
                        1.0 - (_successController.value * 0.08);
                    final successOpacity = widget.catchable
                        ? 0.85 + (_successController.value * 0.15)
                        : 0.55;
                    final glowOpacity = widget.catchable
                        ? 0.18 + (_successController.value * 0.22)
                        : 0.0;

                    return Transform.translate(
                      offset: Offset(_shakeAnimation.value, 0),
                      child: Transform.scale(
                        scale: successScale,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              if (widget.catchable)
                                BoxShadow(
                                  color: Theme.of(context).colorScheme.primary
                                      .withValues(alpha: glowOpacity),
                                  blurRadius: 18,
                                  spreadRadius: 2,
                                ),
                            ],
                          ),
                          child: Opacity(
                            opacity: successOpacity,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                color: _showFailedFlash
                                    ? Colors.red
                                    : (widget.catchable
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    widget.catchable
                                        ? Icons.vibration
                                        : Icons.block,
                                    color: widget.catchable || _showFailedFlash
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _busy
                                        ? 'Catching...'
                                        : widget.catchable
                                        ? 'Shake To Catch!'
                                        : 'No Terpiez Nearby',
                                    style: TextStyle(
                                      color:
                                          widget.catchable || _showFailedFlash
                                          ? Colors.white
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh Locations'),
                ),
                if (_localError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _localError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 12),
                provider.Consumer<TerpiezModel>(
                  builder: (context, model, child) {
                    return Text(
                      'Caught: ${model.terpiezCaught}',
                      style: Theme.of(context).textTheme.titleMedium,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* =========================
   LIST TAB
   ========================= */

class TerpiezListTab extends StatelessWidget {
  const TerpiezListTab({super.key});

  @override
  Widget build(BuildContext context) {
    return provider.Consumer<TerpiezModel>(
      builder: (context, model, child) {
        final species = model.caughtSpeciesList;

        if (species.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No Terpiez caught yet.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: species.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final t = species[index];
            return ListTile(
              leading: Hero(
                tag: 'terpiez-${t.speciesId}',
                child: Material(
                  color: Colors.transparent,
                  child: _SpeciesThumbnail(species: t, radius: 22),
                ),
              ),
              title: Text(t.name),
              subtitle: Text(
                '${t.catches.length} catch${t.catches.length == 1 ? '' : 'es'} of this species',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TerpiezDetailView(species: t),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _SpeciesThumbnail extends StatelessWidget {
  const _SpeciesThumbnail({required this.species, required this.radius});

  final CaughtSpecies species;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final file = File(species.thumbnailPath);

    if (file.existsSync()) {
      return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
    }

    return CircleAvatar(
      radius: radius,
      child: const Icon(Icons.image_not_supported),
    );
  }
}

/* =========================
   DETAIL VIEW
   ========================= */

class TerpiezDetailView extends StatelessWidget {
  const TerpiezDetailView({super.key, required this.species});

  final CaughtSpecies species;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(species.name),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: AnimatedDetailBackground(
        child: SafeArea(
          child: OrientationBuilder(
            builder: (context, orientation) {
              final isPortrait = orientation == Orientation.portrait;
              final spacing = isPortrait ? 15.0 : 12.0;

              return Padding(
                padding: const EdgeInsets.all(15),
                child: isPortrait
                    ? Column(
                        children: [
                          Expanded(
                            flex: 2,
                            child: _DetailImageCard(species: species),
                          ),
                          SizedBox(height: spacing),
                          Expanded(
                            flex: 3,
                            child: _DetailInfoCard(species: species),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: _DetailImageCard(species: species),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            flex: 3,
                            child: _DetailInfoCard(species: species),
                          ),
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DetailImageCard extends StatelessWidget {
  const _DetailImageCard({required this.species});

  final CaughtSpecies species;

  @override
  Widget build(BuildContext context) {
    final file = File(species.imagePath);

    return Card(
      elevation: 4,
      color: Colors.white.withValues(alpha: 0.90),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Hero(
            tag: 'terpiez-${species.speciesId}',
            child: Material(
              color: Colors.transparent,
              child: file.existsSync()
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(file, fit: BoxFit.contain),
                    )
                  : const Icon(Icons.image_not_supported, size: 80),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailInfoCard extends StatelessWidget {
  const _DetailInfoCard({required this.species});

  final CaughtSpecies species;

  @override
  Widget build(BuildContext context) {
    final catchLocations = species.catches.map((e) => e.latLng).toList();

    return Card(
      elevation: 4,
      color: Colors.white.withValues(alpha: 0.90),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      species.name,
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Stats',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    if (species.stats.isEmpty)
                      const Text('No stats available.')
                    else
                      ...species.stats.entries.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '${_prettyLabel(entry.key)}: ${entry.value}',
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      'Description',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      species.description,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Caught Locations',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 220,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: catchLocations.isNotEmpty
                                ? catchLocations.first
                                : const LatLng(38.985998, -76.942539),
                            initialZoom: 15.5,
                            interactionOptions: const InteractionOptions(
                              flags: InteractiveFlag.none,
                            ),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.example.terpiez',
                            ),
                            MarkerLayer(
                              markers: [
                                for (final location in catchLocations)
                                  Marker(
                                    point: location,
                                    width: 34,
                                    height: 34,
                                    child: const Icon(
                                      Icons.location_on,
                                      color: Colors.red,
                                      size: 34,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${species.catches.length} catch${species.catches.length == 1 ? '' : 'es'} recorded',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/* =========================
   ANIMATED DETAIL BACKGROUND
   ========================= */

class AnimatedDetailBackground extends StatefulWidget {
  const AnimatedDetailBackground({super.key, required this.child});

  final Widget child;

  @override
  State<AnimatedDetailBackground> createState() =>
      _AnimatedDetailBackgroundState();
}

class _AnimatedDetailBackgroundState extends State<AnimatedDetailBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _DiagonalStripePainter(_controller.value),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _DiagonalStripePainter extends CustomPainter {
  _DiagonalStripePainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    final backgroundPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Colors.red.shade900, Colors.red.shade700, Colors.red.shade400],
      ).createShader(rect);

    canvas.drawRect(rect, backgroundPaint);

    const stripeWidth = 36.0;
    const gap = 28.0;
    final spacing = stripeWidth + gap;
    final shift = (t * spacing * 6) % spacing;

    final stripePaint1 = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.28);

    final stripePaint2 = Paint()..color = Colors.white.withValues(alpha: 0.12);

    canvas.save();

    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-pi / 4);
    canvas.translate(-size.width / 2, -size.height / 2);

    final totalWidth = size.width + size.height * 2;

    for (
      double x = -size.height * 2 - spacing + shift;
      x < totalWidth + spacing;
      x += spacing
    ) {
      canvas.drawRect(
        Rect.fromLTWH(x, -size.height, stripeWidth, size.height * 3),
        stripePaint1,
      );

      canvas.drawRect(
        Rect.fromLTWH(x + stripeWidth * 0.35, -size.height, 6, size.height * 3),
        stripePaint2,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DiagonalStripePainter oldDelegate) {
    return oldDelegate.t != t;
  }
}

/* =========================
   HELPERS
   ========================= */

String _prettyLabel(String raw) {
  return raw
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String? _stringFromAny(List<dynamic> values) {
  for (final value in values) {
    if (value is String && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

double? _doubleFromAny(dynamic source) {
  if (source is List) {
    for (final value in source) {
      final parsed = _doubleFromAny(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  if (source is num) {
    return source.toDouble();
  }

  if (source is String) {
    return double.tryParse(source);
  }

  return null;
}
