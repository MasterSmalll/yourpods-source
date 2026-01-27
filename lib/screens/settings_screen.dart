import 'package:flutter/material.dart';
import 'package:provider/provider.dart';


import '../api/gpodder_api.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/settings_provider.dart';
import '../models/server_profile.dart';
import 'package:uuid/uuid.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  final _deviceIdController = TextEditingController(text: 'yourpods-ios');
  bool _saveConnection = true;
  bool _rememberPassword = true;
  String? _editingProfileId; // Track ID for updates

  bool _isInit = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isInit) {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      final isAdding = args?['isAdding'] == true;

      if (!isAdding) {
          _loadCurrentProfile();
      } else {
          // If adding, show the Welcome/Info dialog
          // We delay slightly to ensure context is ready for dialog
          WidgetsBinding.instance.addPostFrameCallback((_) => _showWelcomeDialog());
      }
      _isInit = false;
    }
  }

  Future<void> _showWelcomeDialog() async {
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1E27),
          title: const Text('Welcome to YourPods', style: TextStyle(color: Colors.white)),
          content: const Text(
            'YourPods is intended to connect to your existing installed GPodder Sync compatable server. That functionality is not included with this app.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('OK', style: TextStyle(color: Colors.deepPurpleAccent)),
            ),
          ],
        ),
      );
  }

  void _loadCurrentProfile() {
    final profileProvider = Provider.of<ProfileProvider>(context, listen: false);
    final profile = profileProvider.currentProfile;
    if (profile != null) {
      _editingProfileId = profile.id; // Capture ID
      _nameController.text = profile.name;
      _urlController.text = profile.baseUrl;
      _userController.text = profile.username;
      _deviceIdController.text = profile.deviceId;
      _passwordController.text = profile.password ?? '';
      _saveConnection = true; // Assumed since it exists
      _rememberPassword = profile.savePassword;
    }
  }

  Future<void> _saveAndConnect() async {
    final baseUrl = _urlController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text.trim();
    final deviceId = _deviceIdController.text.trim();

    if (baseUrl.isEmpty || username.isEmpty || deviceId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please fill all required fields')),
        );
        return;
    }

    // 1. Create API and verify (simple verification by creating access)
    final api = GPodderApi(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    
    // 2. Update Providers
    final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
    final tempId = const Uuid().v4(); 
    podcastProvider.setApi(api, tempId); // Always force refresh on manual connect/test
    
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    playerProvider.setApi(api, deviceId);

    // 3. Save Profile if requested
    if (_saveConnection) {
        String profileName = _nameController.text.trim();
        if (profileName.isEmpty) {
            profileName = username;
        }

        final profile = ServerProfile(
            id: _editingProfileId, // Pass ID to update existing
            name: profileName,
            baseUrl: baseUrl,
            username: username,
            deviceId: deviceId,
            savePassword: _rememberPassword,
            password: _rememberPassword ? password : null,
        );
        
        await Provider.of<ProfileProvider>(context, listen: false).saveProfile(profile);
    }
    
    // 4. Test connection via refresh
    try {
      await podcastProvider.refreshSubscriptions(deviceId);
      if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false);
      }
    } catch (e) {
      if (mounted) {
        String message = 'Connection failed: $e';
        if (e is GPodderAuthException) {
            message = 'Incorrect username or password.';
        } else if (e is GPodderServerException) {
            message = 'Server error. Please check URL and try again.';
        } else if (e is GPodderException) {
            message = 'Sync error: ${e.message}';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _pushSync(BuildContext context) async {
    final provider = Provider.of<PodcastProvider>(context, listen: false);
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) return;

    try {
      await provider.pushToServer(deviceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Push successful')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Push failed: $e')),
        );
      }
    }
  }

  Future<void> _pullSync(BuildContext context) async {
    final provider = Provider.of<PodcastProvider>(context, listen: false);
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) return;

    try {
      await provider.pullFromServer(deviceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pull successful')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pull failed: $e')),
        );
      }
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F0E17), Color(0xFF2E2D38)],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 48), // Space for back button
                        const Text(
                          'YourPods',
                          style: TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const Text(
                          'Your podcasts, self-hosted.',
                          style: TextStyle(fontSize: 16, color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 48),
                        AutofillGroup(
                          child: Column(
                            children: [
                              _buildTextField(
                                _nameController, 
                                'Account Name (Optional)',
                                autofillHints: [AutofillHints.name],
                                textInputAction: TextInputAction.next,
                              ),
                              const SizedBox(height: 16),
                              _buildTextField(
                                _urlController, 
                                'Nextcloud URL (e.g. https://cloud.com)',
                                autofillHints: [AutofillHints.url],
                                textInputAction: TextInputAction.next,
                              ),
                              const SizedBox(height: 16),
                              _buildTextField(
                                _userController, 
                                'Username',
                                autofillHints: [AutofillHints.username],
                                textInputAction: TextInputAction.next,
                              ),
                              const SizedBox(height: 16),
                              _buildTextField(
                                _passwordController, 
                                'Password', 
                                obscureText: true,
                                autofillHints: [AutofillHints.password],
                                textInputAction: TextInputAction.next,
                              ),
                              const SizedBox(height: 16),
                              _buildTextField(
                                _deviceIdController, 
                                'Device ID',
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _saveAndConnect(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        CheckboxListTile(
                            title: const Text('Save Connection Details', style: TextStyle(color: Colors.white)),
                            value: _saveConnection,
                            onChanged: (val) => setState(() => _saveConnection = val ?? true),
                            activeColor: Colors.deepPurple,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                        ),
                        CheckboxListTile(
                            title: const Text('Remember Password', style: TextStyle(color: Colors.white)),
                            value: _rememberPassword,
                            enabled: _saveConnection,
                            onChanged: (val) => setState(() => _rememberPassword = val ?? true),
                            activeColor: Colors.deepPurple,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                        ),
                        const SizedBox(height: 32),
                        ElevatedButton(
                          onPressed: _saveAndConnect,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Save & Sync', style: TextStyle(fontSize: 18)),
                        ),
                        const SizedBox(height: 24),
                        const Divider(color: Colors.white24),
                        const SizedBox(height: 16),
                        const Text(
                          'Interface Settings',
                          style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                          Consumer<SettingsProvider>(
                          builder: (context, settings, _) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Action Button Style', style: TextStyle(color: Colors.white70)),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<ActionButtonStyle>(
                                      value: settings.actionButtonStyle,
                                      dropdownColor: const Color(0xFF1F1E27),
                                      isExpanded: true,
                                      style: const TextStyle(color: Colors.white),
                                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                      items: const [
                                        DropdownMenuItem(
                                          value: ActionButtonStyle.textAndIcon,
                                          child: Text('Text & Icon'),
                                        ),
                                        DropdownMenuItem(
                                          value: ActionButtonStyle.iconOnly,
                                          child: Text('Icon Only'),
                                        ),
                                        DropdownMenuItem(
                                          value: ActionButtonStyle.textOnly,
                                          child: Text('Text Only'),
                                        ),
                                      ],
                                      onChanged: (val) {
                                        if (val != null) settings.setActionButtonStyle(val);
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text('Sync Interval (seconds)', style: TextStyle(color: Colors.white70)),
                                const SizedBox(height: 8),
                                TextField(
                                    controller: TextEditingController(text: settings.syncInterval.toString()),
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                        filled: true,
                                        fillColor: Colors.white.withOpacity(0.05),
                                        border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            borderSide: BorderSide.none,
                                        ),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                        hintText: 'Minimum 10 seconds',
                                        hintStyle: const TextStyle(color: Colors.white30),
                                    ),
                                    onSubmitted: (val) {
                                        final seconds = int.tryParse(val);
                                        if (seconds != null) {
                                            settings.setSyncInterval(seconds);
                                        }
                                    },
                                    // Also update on focus lost if possible, but onSubmitted is good for now
                                ),
                                const Padding(
                                    padding: EdgeInsets.only(top: 4, left: 4),
                                    child: Text('Default: 30s. Minimum: 10s', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                ),
                                const SizedBox(height: 24),
                                Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                        const Text('Feed Cache Duration', style: TextStyle(color: Colors.white70)),
                                        Text('${settings.feedCacheDuration} hours', style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold)),
                                    ],
                                ),
                                Slider(
                                    value: settings.feedCacheDuration.toDouble(),
                                    min: 1,
                                    max: 48,
                                    divisions: 47,
                                    activeColor: Colors.deepPurpleAccent,
                                    inactiveColor: Colors.white24,
                                    onChanged: (val) {
                                        settings.setFeedCacheDuration(val.round());
                                    },
                                ),
                                const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4.0),
                                    child: Text(
                                        'How long to keep podcast metadata before refreshing automatically. Pull-to-refresh always forces an update.',
                                        style: TextStyle(color: Colors.white38, fontSize: 12),
                                    ),
                                ),
                                const SizedBox(height: 24),
                                SwitchListTile(
                                    title: const Text('Sync to Apple Watch', style: TextStyle(color: Colors.white70)),
                                    subtitle: const Text('Automatically transfer downloaded episodes to your watch', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                    value: settings.autoSyncToWatch,
                                    onChanged: (val) => settings.setAutoSyncToWatch(val),
                                    activeColor: Colors.deepPurpleAccent,
                                    contentPadding: EdgeInsets.zero,
                                ),
                                if (settings.autoSyncToWatch) ...[
                                    const SizedBox(height: 16),
                                    Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                            const Text('Episodes to download', style: TextStyle(color: Colors.white70)),
                                            Text('${settings.watchSyncCount}', style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold)),
                                        ],
                                    ),
                                    Slider(
                                        value: settings.watchSyncCount.toDouble(),
                                        min: 1,
                                        max: 10,
                                        divisions: 9,
                                        label: settings.watchSyncCount.toString(),
                                        activeColor: Colors.deepPurpleAccent,
                                        inactiveColor: Colors.white24,
                                        onChanged: (val) {
                                            settings.setWatchSyncCount(val.round());
                                        },
                                    ),
                                    const Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 4.0),
                                        child: Text(
                                            'Number of top queue items to automatically download to the watch. The entire queue list will still be synced.',
                                            style: TextStyle(color: Colors.white38, fontSize: 12),
                                        ),
                                    ),
                                ],
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 24),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => _pushSync(context),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blueAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text('Push to Server', style: TextStyle(fontSize: 16)),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => _pullSync(context),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text('Pull from Server', style: TextStyle(fontSize: 16)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
              // Always show Home button (logic inside handles empty state)
              Positioned(
                  top: 16,
                  left: 16,
                  child: IconButton(
                    icon: const Icon(Icons.home, color: Colors.white),
                    onPressed: () {
                       final provider = Provider.of<ProfileProvider>(context, listen: false);
                       if (provider.profiles.isNotEmpty) {
                           // Navigate to "Who is listening" (Profile Selection)
                           Navigator.pushNamedAndRemoveUntil(context, '/profile_selection', (route) => false);
                       } else {
                           showDialog(
                               context: context,
                               builder: (context) => AlertDialog(
                                   title: const Text('Account Required'),
                                   content: const Text('Please add an account first to continue.'),
                                   backgroundColor: const Color(0xFF1F1E27),
                                   titleTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                   contentTextStyle: const TextStyle(color: Colors.white70),
                                   actions: [
                                       TextButton(
                                           onPressed: () => Navigator.pop(context),
                                           child: const Text('OK', style: TextStyle(color: Colors.deepPurpleAccent)),
                                       ),
                                   ],
                               ),
                           );
                       }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
      TextEditingController controller, 
      String label, 
      {
        bool obscureText = false,
        Iterable<String>? autofillHints,
        TextInputAction? textInputAction,
        Function(String)? onSubmitted,
      }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}

