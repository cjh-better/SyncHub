import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Light, flat, macOS-like look (same visual spec as the existing SyncHub web
/// center): white / light-grey surfaces, hairline dividers, one blue accent.
const kAccent = Color(0xFF007AFF);
const kBg = Color(0xFFF5F5F7);
const kCard = Colors.white;
const kHair = Color(0xFFE5E5EA);
const kText2 = Color(0xFF6E6E73);
const kGreen = Color(0xFF34C759);
const kOrange = Color(0xFFFF9500);
const kRed = Color(0xFFFF3B30);

const kLightOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.white,
  systemNavigationBarIconBrightness: Brightness.dark,
);

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: kAccent, primary: kAccent, surface: kCard),
    scaffoldBackgroundColor: kBg,
    fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei UI', 'Noto Sans CJK SC', 'sans-serif'],
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: kLightOverlayStyle,
    ),
    cardTheme: CardThemeData(
      color: kCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kHair)),
    ),
    dividerTheme: const DividerThemeData(color: kHair, thickness: 0.6, space: 0.6),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kHair)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kHair)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    ),
    navigationRailTheme: const NavigationRailThemeData(backgroundColor: kBg, indicatorColor: Color(0x1F007AFF)),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: Color(0x1F007AFF)),
  );
}

IconData platformIcon(String platform) => switch (platform) {
      'windows' => Icons.desktop_windows_outlined,
      'macos' => Icons.laptop_mac_outlined,
      'android' => Icons.phone_android_outlined,
      'ios' => Icons.phone_iphone_outlined,
      'web' => Icons.language,
      _ => Icons.devices_other_outlined,
    };
