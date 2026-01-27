import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/profile_provider.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../api/gpodder_api.dart';
import 'history_screen.dart';
import '../widgets/now_playing_bar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initProviders();
    });
  }

  void _initProviders() {
    final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
    final profile = profileProvider.currentProfile;
    
    if (profile != null) {
      if (profile.password == null) {
          // Password wasn't saved or loaded. 
          // Ideally redirect to Settings to re-enter, or show dialog.
          // For now, let's assume if it is null, we might need to ask user.
          // But our model has 'password' field. 'savePassword' just flags if we persist it.
          // If we loaded from storage and savePassword=false, password field is null.
          if (profile.savePassword == false) {
             ScaffoldMessenger.of(context).showSnackBar(
                 const SnackBar(content: Text('Please re-enter password in Settings')),
             );
             Navigator.pushNamed(context, '/settings');
             return;
          }
      }

      final api = GPodderApi(
        baseUrl: profile.baseUrl,
        username: profile.username,
        password: profile.password ?? '',
      );
      
      
      final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
      
      // Check if we need to switch/refresh
      if (podcastProvider.currentProfileId != profile.id) {
          podcastProvider.setApi(api, profile.id);
          
          final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
          playerProvider.setApi(api, profile.deviceId);

          // Refresh subscriptions ONLY if we switched profile
          podcastProvider.refreshSubscriptions(profile.deviceId);
      } else {
         // Even if profile ID matches, ensure API client is fresh (e.g. token updates)
         // But passing same ID prevents data clearing.
         podcastProvider.setApi(api, profile.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YourPods'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.switch_account),
            onPressed: () {
               // Switch profile / Logout
               _showProfileMenu(context);
            },
            tooltip: 'Switch Account',
          ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(left: 24.0, right: 24.0, top: 24.0, bottom: 120.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Consumer<ProfileProvider>(
                  builder: (context, provider, child) {
                    final name = provider.currentProfile?.name ?? 'User';
                    return Text(
                      'Welcome, $name',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 32),
                _buildMenuCard(
                  context,
                  'In Progress',
                  Icons.history,
                  Colors.blueAccent,
                  () => Navigator.pushNamed(context, '/inprogress'),
                ),
                const SizedBox(height: 16),
                _buildMenuCard(
                  context,
                  'Library',
                  Icons.podcasts,
                  Colors.deepPurple,
                  () => Navigator.pushNamed(context, '/library'),
                ),
                const SizedBox(height: 16),
                _buildMenuCard(
                  context,
                  'Listening History',
                  Icons.list_alt,
                  Colors.orangeAccent,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen())),
                ),
                const SizedBox(height: 16),
                _buildMenuCard(
                  context,
                  'Settings',
                  Icons.settings,
                  Colors.grey,
                  () => Navigator.pushNamed(context, '/settings'),
                ),
              ],
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: NowPlayingBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard(BuildContext context, String title, IconData icon, Color color, VoidCallback onTap) {
    return Card(
      color: const Color(0xFF1F1E27),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 32),
              ),
              const SizedBox(width: 24),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              const Icon(Icons.arrow_forward_ios, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }

  void _showProfileMenu(BuildContext context) {
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1F1E27),
          builder: (context) {
              return SafeArea(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                          ListTile(
                              leading: const Icon(Icons.exit_to_app, color: Colors.redAccent),
                              title: const Text('Switch / Logout', style: TextStyle(color: Colors.redAccent)),
                              onTap: () async {
                                  Navigator.pop(context);
                                  await Provider.of<ProfileProvider>(context, listen: false).logout();
                                  if (context.mounted) {
                                      Navigator.pushNamedAndRemoveUntil(context, '/profile_selection', (route) => false);
                                  }
                              },
                          ),
                      ],
                  ),
              );
          },
      );
  }
}
