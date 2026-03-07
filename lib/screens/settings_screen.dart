import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/background_refresh_service.dart';

import '../api/gpodder_api.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/conflict_resolution_dialog.dart';
import '../models/sync_conflict.dart';
import '../models/queue_sync_change.dart';
import '../models/server_profile.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';

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
  bool _isLocalAccount = false; // New state for local account creation
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
            'YourPods is designed to work best with a gPodder-compatible sync server (like Nextcloud), but you can also use it locally without syncing.',
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
      _isLocalAccount = profile.isLocal; // Load local state
    }
  }

  Future<void> _saveAndConnect() async {
    final baseUrl = _urlController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text.trim();
    final deviceId = _deviceIdController.text.trim();



    if (_isLocalAccount) {
         if (deviceId.isEmpty) {
             ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please enter a Device ID')),
            );
            return;
         }
         // Skip other checks
    } else {
        if (baseUrl.isEmpty || username.isEmpty || deviceId.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please fill all required fields')),
            );
            return;
        }
    }

    // Warn if using HTTP — credentials will be sent in cleartext
    if (baseUrl.toLowerCase().startsWith('http://')) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1E27),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 28),
              SizedBox(width: 8),
              Text('Insecure Connection', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: const Text(
            'You are connecting over HTTP (not HTTPS). '
            'Your username and password will be sent in cleartext and could be intercepted.\n\n'
            'Are you sure you want to continue?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Connect Anyway', style: TextStyle(color: Colors.orangeAccent)),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }



    // 1. Create API and verify (simple verification by creating access)
    GPodderApi? api;
    if (!_isLocalAccount) {
        api = GPodderApi(
          baseUrl: baseUrl,
          username: username,
          password: password,
        );
    }
    
    // 2. Update Providers
    final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
    final tempId = const Uuid().v4(); 
    // Always force refresh on manual connect/test, or just set API
    if (api != null) {
        podcastProvider.setApi(api, tempId); 
    } else if (_isLocalAccount) {
        // Activate local profile in PodcastProvider so it knows the profile ID
        podcastProvider.setApi(null, tempId);
    }
    
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    if (!_isLocalAccount) {
        playerProvider.setApi(api!, deviceId, profileId: podcastProvider.currentProfileId);
    } else {
        // Pass null API for local account to prevent server sync from happening,
        // but still pass profileId so the background audio service queue is correctly scoped.
        playerProvider.setApi(null, deviceId, profileId: podcastProvider.currentProfileId);
    }

    // 3. Save Profile if requested
    if (_saveConnection) {
        String profileName = _nameController.text.trim();
        if (profileName.isEmpty) {
            profileName = _isLocalAccount ? 'Local User' : username;
        }

        final profile = ServerProfile(
            id: _editingProfileId, // Pass ID to update existing
            name: profileName,
            baseUrl: _isLocalAccount ? 'local://' : baseUrl,
            username: _isLocalAccount ? 'Local User' : username,
            deviceId: deviceId,
            savePassword: _rememberPassword,
            password: _rememberPassword ? password : null,
            isLocal: _isLocalAccount,
        );
        
        await Provider.of<ProfileProvider>(context, listen: false).saveProfile(profile);
    }
    
    // 4. Test connection via refresh
    // Show loading overlay while syncing
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const PopScope(
          canPop: false,
          child: Center(
            child: Card(
              color: Color(0xFF1F1E27),
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.deepPurpleAccent),
                    SizedBox(height: 16),
                    Text('Syncing...', style: TextStyle(color: Colors.white70, fontSize: 16)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    try {
      if (!_isLocalAccount) {
          await podcastProvider.refreshSubscriptions(deviceId);
      } else {
          // For local, we just set the API (which sets profile ID and loads local storage)
          // We need to actually "Activate" this profile fully
          // The Save Profile above just saves it to list. 
          // Use selectProfile to activate it
          if (_editingProfileId != null) {
             // We are editing, so we might need to re-select?
          }
          // The logic below just exits. The user will select it from list or we can auto-select.
      }
      
      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading overlay
        Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Dismiss loading overlay
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
      // Sync subscriptions
      await provider.pullFromServer(deviceId);
      
      // Sync playback state with Conflict Resolution
      if (mounted) {
          final settings = Provider.of<SettingsProvider>(context, listen: false);
          final conflicts = await provider.syncEpisodeActions(deviceId, force: true, strategy: settings.syncConflictStrategy);
          
          if (conflicts.isNotEmpty && mounted) {
               // Show Conflict Dialog
               final decisions = await showDialog<Map<String, bool>>(
                   context: context,
                   barrierDismissible: false,
                   builder: (ctx) => ConflictResolutionDialog(conflicts: conflicts),
               );
               
               if (decisions != null) {
                   // Apply resolutions
                   for (var conflict in conflicts) {
                       final keepRemote = decisions[conflict.episodeGuid];
                       if (keepRemote != null) {
                           await provider.applyConflictResolution(conflict, keepRemote);
                       }
                   }
               }
          }
      
          // Refresh Player/Queue UI from the (now resolved) cache
          await Provider.of<PlayerProvider>(context, listen: false).syncPlaybackState(force: false);
      }
      
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
                        Column(
                          children: [
                              // Toggle Account Type
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                margin: const EdgeInsets.only(bottom: 24),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _isLocalAccount = false;
                                              if (_deviceIdController.text == 'yourpods-local' || _deviceIdController.text.isEmpty) {
                                                _deviceIdController.text = 'yourpods-ios';
                                              }
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            decoration: BoxDecoration(
                                              color: !_isLocalAccount ? Colors.deepPurple : Colors.transparent,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              'Sync Account',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: !_isLocalAccount ? Colors.white : Colors.white70,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    Expanded(
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _isLocalAccount = true;
                                            if (_deviceIdController.text == 'yourpods-ios' || _deviceIdController.text.isEmpty) {
                                              _deviceIdController.text = 'yourpods-local';
                                            }
                                          });
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          decoration: BoxDecoration(
                                            color: _isLocalAccount ? Colors.teal : Colors.transparent,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            'Local Account',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: _isLocalAccount ? Colors.white : Colors.white70,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            
                              _buildTextField(
                                _nameController, 
                                'Account Name (Optional)',
                                autofillHints: [AutofillHints.name],
                                textInputAction: TextInputAction.next,
                              ),
                              const SizedBox(height: 16),
                              
                              if (!_isLocalAccount) ...[
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
                              ] else ...[
                                  const Text(
                                      'Local accounts do not sync with any server. Your data is stored only on this device.',
                                      style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic),
                                      textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                              ],
                              
                              _buildTextField(
                                _deviceIdController, 
                                'Device ID',
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _saveAndConnect(),
                              ),
                          ],
                        ),
                        
                        if (!_isLocalAccount) ...[
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
                        ],
                        const SizedBox(height: 32),
                        ElevatedButton(
                          onPressed: _saveAndConnect,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text(_isLocalAccount ? 'Create Local Account' : 'Save & Sync', style: const TextStyle(fontSize: 18)),
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

                                if (!_isLocalAccount) ...[
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
                                  ),
                                  const Padding(
                                      padding: EdgeInsets.only(top: 4, left: 4),
                                      child: Text('Default: 30s. Minimum: 10s', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                  ), // End Sync Interval
                                  
                                  const SizedBox(height: 16),
                                  const Divider(color: Colors.white24),
                                  ListTile(
                                      title: const Text('Conflict Strategy', style: TextStyle(color: Colors.white)),
                                      subtitle: Text(
                                          _getStrategyLabel(settings.syncConflictStrategy),
                                          style: const TextStyle(color: Colors.white54),
                                      ),
                                      trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 16),
                                      onTap: () => _showStrategyPicker(context, settings),
                                  ),
                                  ListTile(
                                      title: const Text('Queue Sync', style: TextStyle(color: Colors.white)),
                                      subtitle: Text(
                                          _getQueueSyncLabel(settings.queueSyncStrategy),
                                          style: const TextStyle(color: Colors.white54),
                                      ),
                                      trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 16),
                                      onTap: () => _showQueueSyncPicker(context, settings),
                                  ),
                                ],
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
                                    subtitle: const Text('Automatically transfer downloaded episodes to your watch\nNote: The watch will sync with the last profile used on this device.', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                    value: settings.autoSyncToWatch,
                                    onChanged: (val) => settings.setAutoSyncToWatch(val),
                                    activeThumbColor: Colors.deepPurpleAccent,
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
                                    const SizedBox(height: 12),
                                    SwitchListTile(
                                        title: const Text('Download on WiFi Only', style: TextStyle(color: Colors.white70)),
                                        subtitle: const Text(
                                          'Restrict auto-downloads to WiFi to save battery and data',
                                          style: TextStyle(color: Colors.white38, fontSize: 12),
                                        ),
                                        value: settings.watchDownloadWiFiOnly,
                                        onChanged: (val) => settings.setWatchDownloadWiFiOnly(val),
                                        activeThumbColor: Colors.deepPurpleAccent,
                                        contentPadding: EdgeInsets.zero,
                                    ),
                                ],
                                const SizedBox(height: 24),
                                const Divider(color: Colors.white24),
                                const SizedBox(height: 16),
                                const Text(
                                  'Background Refresh',
                                  style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),

                                SwitchListTile(
                                    title: const Text('Enable Background Refresh', style: TextStyle(color: Colors.white70)),
                                    subtitle: const Text(
                                      'Refresh podcast feeds in the background to detect new episodes.\nNote: Background refresh automatically skips local-only profiles.',
                                      style: TextStyle(color: Colors.white38, fontSize: 12),
                                    ),
                                    value: settings.backgroundRefreshEnabled,
                                    onChanged: (val) {
                                      settings.setBackgroundRefreshEnabled(val);
                                      if (val) {
                                        BackgroundRefreshService().start(
                                          intervalMinutes: settings.backgroundRefreshInterval,
                                        );
                                      } else {
                                        BackgroundRefreshService().stop();
                                      }
                                    },
                                    activeThumbColor: Colors.deepPurpleAccent,
                                    contentPadding: EdgeInsets.zero,
                                ),
                                if (settings.backgroundRefreshEnabled) ...[
                                    const SizedBox(height: 12),
                                    const Text('Refresh Interval', style: TextStyle(color: Colors.white70)),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.05),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<int>(
                                          value: settings.backgroundRefreshInterval,
                                          dropdownColor: const Color(0xFF1F1E27),
                                          isExpanded: true,
                                          style: const TextStyle(color: Colors.white),
                                          icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                          items: const [
                                            DropdownMenuItem(value: 15, child: Text('Every 15 minutes')),
                                            DropdownMenuItem(value: 30, child: Text('Every 30 minutes')),
                                            DropdownMenuItem(value: 60, child: Text('Every hour')),
                                            DropdownMenuItem(value: 360, child: Text('Every 6 hours')),
                                            DropdownMenuItem(value: 720, child: Text('Every 12 hours')),
                                            DropdownMenuItem(value: 1440, child: Text('Daily')),
                                          ],
                                          onChanged: (val) {
                                            if (val != null) {
                                              settings.setBackgroundRefreshInterval(val);
                                              BackgroundRefreshService().updateInterval(val);
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                    const Padding(
                                        padding: EdgeInsets.only(top: 4, left: 4),
                                        child: Text(
                                          'iOS may adjust the actual interval based on app usage patterns. Minimum 15 minutes.',
                                          style: TextStyle(color: Colors.white38, fontSize: 12),
                                        ),
                                    ),
                                ],
                                const SizedBox(height: 24),
                                const Divider(color: Colors.white24),
                                const SizedBox(height: 16),
                                const Text(
                                  'Podcast Search',
                                  style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                const Text('Search Provider', style: TextStyle(color: Colors.white70)),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: settings.searchProviderId,
                                      dropdownColor: const Color(0xFF1F1E27),
                                      isExpanded: true,
                                      style: const TextStyle(color: Colors.white),
                                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                      items: const [
                                        DropdownMenuItem(value: 'itunes', child: Text('iTunes (Apple)')),
                                        DropdownMenuItem(value: 'podcastindex', child: Text('PodcastIndex (Open Source)')),
                                      ],
                                      onChanged: (val) {
                                        if (val != null) settings.setSearchProviderId(val);
                                      },
                                    ),
                                  ),
                                ),
                                const Padding(
                                    padding: EdgeInsets.only(top: 4, left: 4),
                                    child: Text(
                                      'iTunes requires no setup. PodcastIndex is open-source and requires a free API key.',
                                      style: TextStyle(color: Colors.white38, fontSize: 12),
                                    ),
                                ),
                                if (settings.searchProviderId == 'podcastindex') ...[
                                    const SizedBox(height: 16),
                                    TextField(
                                        controller: TextEditingController(text: settings.podcastIndexApiKey),
                                        obscureText: true,
                                        style: const TextStyle(color: Colors.white),
                                        decoration: InputDecoration(
                                            labelText: 'PodcastIndex API Key',
                                            labelStyle: const TextStyle(color: Colors.white60),
                                            filled: true,
                                            fillColor: Colors.white.withOpacity(0.05),
                                            border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(12),
                                                borderSide: BorderSide.none,
                                            ),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                        ),
                                        onSubmitted: (val) => settings.setPodcastIndexApiKey(val.trim()),
                                        onChanged: (val) => settings.setPodcastIndexApiKey(val.trim()),
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                        controller: TextEditingController(text: settings.podcastIndexApiSecret),
                                        style: const TextStyle(color: Colors.white),
                                        obscureText: true,
                                        decoration: InputDecoration(
                                            labelText: 'PodcastIndex API Secret',
                                            labelStyle: const TextStyle(color: Colors.white60),
                                            filled: true,
                                            fillColor: Colors.white.withOpacity(0.05),
                                            border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(12),
                                                borderSide: BorderSide.none,
                                            ),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                        ),
                                        onSubmitted: (val) => settings.setPodcastIndexApiSecret(val.trim()),
                                        onChanged: (val) => settings.setPodcastIndexApiSecret(val.trim()),
                                    ),
                                    const Padding(
                                        padding: EdgeInsets.only(top: 8, left: 4),
                                        child: Text(
                                          'Get your free API key at podcastindex.org/signup',
                                          style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 12),
                                        ),
                                    ),
                                ],
                                const SizedBox(height: 24),
                                const Divider(color: Colors.white24),
                                const SizedBox(height: 16),
                                const Text(
                                  'Privacy & Stats',
                                  style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                SwitchListTile(
                                    title: const Text('Enable Listening Stats', style: TextStyle(color: Colors.white70)),
                                    subtitle: const Text(
                                      'Compute listening hours, streaks, and top shows. Stats are derived from all history synced via the gPodder server.',
                                      style: TextStyle(color: Colors.white38, fontSize: 12),
                                    ),
                                    value: settings.enableListenerStats,
                                    onChanged: (val) => settings.setEnableListenerStats(val),
                                    activeThumbColor: Colors.tealAccent,
                                    contentPadding: EdgeInsets.zero,
                                ),
                              ],
                            );
                          },
                        ),
                        
                        const SizedBox(height: 24),
                        const Divider(color: Colors.white24),
                        const SizedBox(height: 16),
                        const Text(
                          'Data Management',
                          style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          leading: const Icon(Icons.file_download, color: Colors.deepPurpleAccent),
                          title: const Text('Import Podcasts', style: TextStyle(color: Colors.white)),
                          subtitle: Text(
                            _isLocalAccount
                                ? 'Import from another podcast app (OPML)'
                                : 'Import feeds not on your gPodder server',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 16),
                          onTap: () => Navigator.pushNamed(context, '/import'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        ListTile(
                          leading: const Icon(Icons.file_upload, color: Colors.deepPurpleAccent),
                          title: const Text('Export Subscriptions', style: TextStyle(color: Colors.white)),
                          subtitle: const Text(
                            'Save subscriptions as OPML file',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 16),
                          onTap: () => _exportOpml(context),
                          contentPadding: EdgeInsets.zero,
                        ),
                        const SizedBox(height: 24),
                        const SizedBox(height: 16),
                        
                        if (!_isLocalAccount) ...[
                            const SizedBox(height: 24),
                            Consumer<PodcastProvider>(
                              builder: (context, provider, _) {
                                final lastSync = provider.lastSyncedAt;
                                final label = lastSync != null
                                    ? _formatTimeAgo(lastSync)
                                    : 'Never';
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.sync, color: Colors.white38, size: 18),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Last synced: $label',
                                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
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
                        ] else ...[
                            const SizedBox(height: 24),
                            Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                    color: Colors.teal.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.teal.withOpacity(0.3)),
                                ),
                                child: const Row(
                                    children: [
                                        Icon(Icons.perm_device_information, color: Colors.tealAccent),
                                        SizedBox(width: 16),
                                        Expanded(
                                            child: Text(
                                                'Local Account Mode\nSyncing is disabled.',
                                                style: TextStyle(color: Colors.tealAccent),
                                            ),
                                        ),
                                    ],
                                ),
                            ),
                        ],
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

  String _getStrategyLabel(SyncStrategy strategy) {
      switch (strategy) {
          case SyncStrategy.serverWins: return 'Always use Server';
          case SyncStrategy.deviceWins: return 'Always use Device';
          case SyncStrategy.ask: return 'Ask me';
      }
  }

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return '$m ${m == 1 ? 'minute' : 'minutes'} ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return '$h ${h == 1 ? 'hour' : 'hours'} ago';
    }
    final d = diff.inDays;
    return '$d ${d == 1 ? 'day' : 'days'} ago';
  }

  void _showStrategyPicker(BuildContext context, SettingsProvider settings) {
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1F1E27),
          builder: (context) {
              return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      const SizedBox(height: 16),
                      const Text('Conflict Strategy', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 16),
                      _buildStrategyOption(context, settings, SyncStrategy.serverWins, 'Always use Server'),
                      _buildStrategyOption(context, settings, SyncStrategy.deviceWins, 'Always use Device'),
                      _buildStrategyOption(context, settings, SyncStrategy.ask, 'Ask me'),
                      const SizedBox(height: 32),
                  ],
              );
          }
      );
  }
  
  Widget _buildStrategyOption(BuildContext context, SettingsProvider settings, SyncStrategy strategy, String label) {
      final isSelected = settings.syncConflictStrategy == strategy;
      return ListTile(
          title: Text(label, style: TextStyle(color: isSelected ? Colors.deepPurpleAccent : Colors.white)),
          trailing: isSelected ? const Icon(Icons.check, color: Colors.deepPurpleAccent) : null,
          onTap: () {
              settings.setSyncConflictStrategy(strategy);
              Navigator.pop(context);
          },
      );
  }

  String _getQueueSyncLabel(QueueSyncStrategy strategy) {
      switch (strategy) {
          case QueueSyncStrategy.serverWins:
              return 'Always update from server';
          case QueueSyncStrategy.deviceWins:
              return 'Keep device queue';
          case QueueSyncStrategy.ask:
              return 'Ask me';
      }
  }

  void _showQueueSyncPicker(BuildContext context, SettingsProvider settings) {
      showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1F1E27),
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (context) {
              return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      const SizedBox(height: 16),
                      const Text('Queue Sync Strategy', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                              'When other devices have queue changes, how should this device handle them?',
                              style: TextStyle(color: Colors.white54, fontSize: 12),
                              textAlign: TextAlign.center,
                          ),
                      ),
                      const SizedBox(height: 16),
                      _buildQueueSyncOption(context, settings, QueueSyncStrategy.ask, 'Ask me', 'Review changes before applying (recommended)'),
                      _buildQueueSyncOption(context, settings, QueueSyncStrategy.serverWins, 'Always update from server', 'Automatically merge queue from server'),
                      _buildQueueSyncOption(context, settings, QueueSyncStrategy.deviceWins, 'Keep device queue', 'Ignore server queue changes'),
                      const SizedBox(height: 32),
                  ],
              );
          }
      );
  }

  Widget _buildQueueSyncOption(BuildContext context, SettingsProvider settings, QueueSyncStrategy strategy, String label, String subtitle) {
      final isSelected = settings.queueSyncStrategy == strategy;
      return ListTile(
          title: Text(label, style: TextStyle(color: isSelected ? Colors.deepPurpleAccent : Colors.white)),
          subtitle: Text(subtitle, style: TextStyle(color: isSelected ? Colors.deepPurpleAccent.withValues(alpha: 0.7) : Colors.white38, fontSize: 12)),
          trailing: isSelected ? const Icon(Icons.check, color: Colors.deepPurpleAccent) : null,
          onTap: () {
              settings.setQueueSyncStrategy(strategy);
              Navigator.pop(context);
          },
      );
  }

  void _exportOpml(BuildContext context) async {
    final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
    final opmlContent = podcastProvider.exportToOpml();
    final bytes = utf8.encode(opmlContent);

    try {
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save OPML File',
        fileName: 'yourpods_subscriptions.opml',
        type: FileType.custom,
        allowedExtensions: ['opml'],
        bytes: Uint8List.fromList(bytes),
      );

      if (outputPath != null) {
        // On desktop, saveFile returns a path but doesn't write bytes,
        // so we need to write the file ourselves.
        if (!Platform.isIOS && !Platform.isAndroid) {
          final file = File(outputPath);
          await file.writeAsString(opmlContent);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Subscriptions exported successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
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
