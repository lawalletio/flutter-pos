# shared_preferences_android 2.5+ calls its Kotlin API from Dart over JNI.
# R8 sees no Java caller, so it strips or renames that API and the coroutine
# classes its suspend methods use; every prefs read then throws in release.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Result** { *; }
