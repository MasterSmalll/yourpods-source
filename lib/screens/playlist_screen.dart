import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../widgets/queue_list.dart';

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Up Next'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
               showDialog(
                 context: context,
                 builder: (BuildContext context) {
                   return AlertDialog(
                     title: const Text('Clear Queue?'),
                     content: const Text('Are you sure you want to remove all episodes from the queue?'),
                     backgroundColor: const Color(0xFF1F1E27),
                     titleTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                     contentTextStyle: const TextStyle(color: Colors.white70),
                     actions: [
                       TextButton(
                         child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                         onPressed: () {
                           Navigator.of(context).pop();
                         },
                       ),
                       TextButton(
                         child: const Text('Clear All', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                         onPressed: () {
                           Provider.of<PlayerProvider>(context, listen: false).clearQueue();
                           Navigator.of(context).pop();
                         },
                       ),
                     ],
                   );
                 },
               );
            },
            tooltip: 'Clear Queue',
          ),
        ],
      ),
      body: const QueueList(currentFilter: 'All'),
    );
  }
}
