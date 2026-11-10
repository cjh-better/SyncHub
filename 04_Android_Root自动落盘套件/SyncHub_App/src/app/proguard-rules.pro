# LSPosed 入口与激活检测：不得重命名 / 内联（否则 hook 不到）
-keep class xyz.synchub.android.xposed.** { *; }
# Root 兼容模式：由 app_process 通过类名启动
-keep class xyz.synchub.android.root.ClipHelper { public static void main(java.lang.String[]); }
-keep class xyz.synchub.android.root.ClipHelper$* { *; }
-dontwarn de.robv.android.xposed.**
-keepattributes SourceFile,LineNumberTable
-dontwarn com.google.errorprone.annotations.**
