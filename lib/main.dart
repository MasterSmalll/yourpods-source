import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'services/audio_handler.dart';
import 'services/carplay_service.dart';
import 'services/siri_service.dart';
import 'services/background_refresh_service.dart';
import 'package:background_fetch/background_fetch.dart';
import 'services/live_activity_service.dart';
import 'providers/podcast_provider.dart';
import 'providers/player_provider.dart';
import 'providers/profile_provider.dart';
import 'providers/download_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/in_progress_screen.dart';
import 'screens/profile_selection_screen.dart';
import 'screens/home_screen.dart';
import 'screens/podcast_import_screen.dart';
import 'services/watch_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Background Refresh Service
  await BackgroundRefreshService().init();
  
  // Initialize AudioHandler
  final audioHandler = await AudioService.init(
    builder: () => PodcastAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.asecretcompany.yourpods.channel.audio',
      androidNotificationChannelName: 'YourPods Audio',
      androidNotificationOngoing: true,
      fastForwardInterval: Duration(seconds: 30),
      rewindInterval: Duration(seconds: 15),
    ),
  );

  // Create PodcastProvider early
  final podcastProvider = PodcastProvider();
  
  // AudioHandler needs provider for browsing
  audioHandler.setPodcastProvider(podcastProvider);

  // Configure Services with AudioHandler and Provider
  CarPlayService().setAudioHandler(audioHandler);
  CarPlayService().init(podcastProvider); // Early init for CarPlay
  SiriService().setAudioHandler(audioHandler);

  final watchService = WatchService();

  // Initialize Live Activity Service for Dynamic Island support
  final liveActivityService = LiveActivityService();
  await liveActivityService.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProfileProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        
        // Inject Settings into PodcastProvider
        ChangeNotifierProxyProvider<SettingsProvider, PodcastProvider>(
            create: (_) => podcastProvider,
            update: (_, settings, provider) => provider!..updateSettings(settings),
        ),

        ChangeNotifierProvider(create: (_) => DownloadProvider()),
        
        // Use ProxyProvider to inject SettingsProvider and PodcastProvider into PlayerProvider


        ChangeNotifierProxyProvider3<SettingsProvider, PodcastProvider, DownloadProvider, PlayerProvider>(
            create: (_) => PlayerProvider(audioHandler),
            update: (_, settings, podcastProvider, downloadProvider, player) {
              player!.updateSettings(settings);
              player.updatePodcastProvider(podcastProvider);
              player.updateDownloadProvider(downloadProvider);
              // B7: Only set services once to avoid redundant re-initialization
              if (!player.hasWatchService) player.setWatchService(watchService);
              if (!player.hasLiveActivityService) player.setLiveActivityService(liveActivityService);
              return player;
            },
        ),
      ],
      child: const PodcastApp(),
    ),
  );

  // Register headless task for background fetch (must be after runApp)
  BackgroundFetch.registerHeadlessTask(backgroundFetchHeadlessTask);
}

class PodcastApp extends StatefulWidget {
  const PodcastApp({super.key});

  @override
  State<PodcastApp> createState() => _PodcastAppState();
}

class _PodcastAppState extends State<PodcastApp> with WidgetsBindingObserver {
  bool _servicesInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
        // App going to background or closing — persist to disk first,
        // then sync to server. Disk save is critical because force-quit
        // can happen before the server upload completes.
        playerProvider.forceSaveState();
        playerProvider.forceSync(action: 'play');
    } else if (state == AppLifecycleState.resumed) {
        // App coming to foreground
        playerProvider.forceSync(action: 'play');
        playerProvider.syncPlaybackState();
        // Drain any episodes queued by background refresh while suspended
        playerProvider.drainPendingAutoQueue();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Initialize Services once we have context with providers
    if (!_servicesInitialized) {
      // CarPlayService init moved to main()
      SiriService().init(context);
      
      // Load Initial Player State
      final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
      final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
      
      CarPlayService().setPlayerProvider(playerProvider);
      final settingsProvider = Provider.of<SettingsProvider>(context, listen: false);
      CarPlayService().setSettingsProvider(settingsProvider);
      final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
      CarPlayService().setDownloadProvider(downloadProvider);
      
      // Wait for build to finish? Actually this is just async logic fire-and-forget
      playerProvider.loadInitialState(podcastProvider);
      
      _servicesInitialized = true;
    }

    return Consumer<ProfileProvider>(
      builder: (context, profileProvider, child) {
        return MaterialApp(
          title: 'YourPods',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            primarySwatch: Colors.deepPurple,
            scaffoldBackgroundColor: const Color(0xFF0F0E17),
            cardColor: const Color(0xFF1F1E27),
            useMaterial3: true,
          ), 
          home: _getHomeWidget(profileProvider),
          routes: {
            '/settings': (context) => const SettingsScreen(),
            '/library': (context) => const LibraryScreen(),
            '/inprogress': (context) => const InProgressScreen(),
            '/profile_selection': (context) => const ProfileSelectionScreen(),
            '/home': (context) => const HomeScreen(),
            '/import': (context) => const PodcastImportScreen(),
          },
        );
      },
    );
  }

  Widget _getHomeWidget(ProfileProvider provider) {
      if (provider.isLoading) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (provider.currentProfile != null) {
          return const HomeScreen();
      }
      return const ProfileSelectionScreen();
  }
}
