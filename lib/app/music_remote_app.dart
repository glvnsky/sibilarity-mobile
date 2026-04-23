import 'package:flutter/material.dart';

import 'package:music_remote_app/features/home/presentation/remote_home_page.dart';

class MusicRemoteApp extends StatelessWidget {
  const MusicRemoteApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Sibilarity Music Remote',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0B57D0),
          ),
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: const RemoteHomePage(),
      );
}
