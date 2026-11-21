import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_route_observer.dart';
import 'app_state.dart';
import 'screens/home_screen.dart';
import 'services/build_info.dart';
import 'services/legal_notices.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final buildInfo = await BuildInfo.load();
  await registerLegalNotices();
  runApp(ProxyApp(buildInfo: buildInfo));
}

class ProxyApp extends StatelessWidget {
  const ProxyApp({super.key, required this.buildInfo, this.createState});

  final BuildInfo buildInfo;
  final AppViewState Function()? createState;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppViewState>(
      create: (_) =>
          createState?.call() ??
          (AppState(buildInfo: buildInfo)..loadIdentities()),
      child: MaterialApp(
        title: 'MeshChameleon',
        theme: MeshChameleonTheme.light(),
        darkTheme: MeshChameleonTheme.dark(),
        themeMode: ThemeMode.system,
        navigatorObservers: [appRouteObserver],
        home: const HomeScreen(),
      ),
    );
  }
}
