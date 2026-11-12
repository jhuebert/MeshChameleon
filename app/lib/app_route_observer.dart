import 'package:flutter/material.dart';

/// Shared route observer so Home can pause its visibility-aware sampler when
/// any route (screen or modal) covers it, and resume on return.
final RouteObserver<ModalRoute<dynamic>> appRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();
