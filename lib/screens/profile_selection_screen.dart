import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/profile_provider.dart';

class ProfileSelectionScreen extends StatelessWidget {
  const ProfileSelectionScreen({super.key});

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
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                const Text(
                  'Who is listening?',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                Expanded(
                  flex: 3,
                  child: Consumer<ProfileProvider>(
                    builder: (context, provider, child) {
                      if (provider.isLoading) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      
                      if (provider.profiles.isEmpty) {
                         // Empty state for first run or no accounts
                         return Center(
                           child: Column(
                             mainAxisSize: MainAxisSize.min,
                             children: [
                               Icon(Icons.account_circle, size: 64, color: Colors.white24),
                               SizedBox(height: 16),
                               Text(
                                 'Welcome to YourPods',
                                 style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                               ),
                               SizedBox(height: 8),
                               Text(
                                 'Please add an account to get started.',
                                 style: TextStyle(color: Colors.white54),
                               ),
                             ],
                           ),
                         );
                      }

                      return ReorderableListView.builder(
                        itemCount: provider.profiles.length,
                        proxyDecorator: (child, index, animation) {
                            return Material(
                                color: Colors.transparent,
                                shadowColor: Colors.black26,
                                elevation: 12,
                                child: child,
                            );
                        },
                        onReorder: (oldIndex, newIndex) {
                            provider.reorderProfiles(oldIndex, newIndex);
                        },
                        itemBuilder: (context, index) {
                          final profile = provider.profiles[index];
                          return Container(
                            key: ValueKey(profile.id),
                            margin: const EdgeInsets.only(bottom: 16),
                            child: Card(
                              color: const Color(0xFF1F1E27),
                              elevation: 4,
                              margin: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              child: InkWell(
                                onTap: () => _selectProfile(context, profile.id),
                                borderRadius: BorderRadius.circular(16),
                                child: Padding(
                                  padding: const EdgeInsets.all(24.0),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.drag_handle, color: Colors.white24),
                                      const SizedBox(width: 16),
                                      CircleAvatar(
                                        backgroundColor: Colors.deepPurple,
                                        child: Text(profile.name[0].toUpperCase(), style: const TextStyle(color: Colors.white)),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              profile.name,
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            Text(
                                              profile.baseUrl,
                                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                          onPressed: () => _confirmDelete(context, profile),
                                      ),
                                      const Icon(Icons.arrow_forward_ios, color: Colors.white24, size: 16),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () {
                     // Navigate to settings in "Add Mode" (effectively just cleared settings)
                     // Does NOT set a current profile yet
                     Navigator.pushNamed(context, '/settings', arguments: {'isAdding': true});
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Account'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectProfile(BuildContext context, String profileId) async {
      final provider = Provider.of<ProfileProvider>(context, listen: false);
      await provider.selectProfile(profileId);
      
      if (context.mounted) {
          // If password is saved, we are good. 
          // If not, we might need to prompt (For now assuming "Connect" step handles this or we trust saved)
          // The current plan is simple: Select -> Home. 
          // If password was NOT saved, the app might fail to sync later or prompt. 
          // A robust app would check here.
          Navigator.pushReplacementNamed(context, '/home');
      }
  }


  void _confirmDelete(BuildContext context, dynamic profile) {
      showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1F1E27),
              title: const Text('Delete Account', style: TextStyle(color: Colors.white)),
              content: Text(
                  'How would you like to delete "${profile.name}"?',
                  style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                  TextButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.pop(ctx),
                  ),
                  TextButton(
                      child: const Text('App Only', style: TextStyle(color: Colors.orangeAccent)),
                      onPressed: () async {
                          Navigator.pop(ctx);
                          await _deleteAccount(context, profile.id, false);
                      },
                  ),
                  TextButton(
                      child: const Text('App & Server', style: TextStyle(color: Colors.redAccent)),
                      onPressed: () async {
                          Navigator.pop(ctx);
                          await _deleteAccount(context, profile.id, true);
                      },
                  ),
              ],
          ),
      );
  }

  Future<void> _deleteAccount(BuildContext context, String id, bool fromServer) async {
      try {
          await Provider.of<ProfileProvider>(context, listen: false).deleteProfile(id, deleteFromServer: fromServer);
          if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Account deleted successfully')),
              );
          }
      } catch (e) {
          if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error deleting account: $e')),
              );
          }
      }
  }
}
