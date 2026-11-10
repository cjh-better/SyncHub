package xyz.synchub.android.xposed;

/**
 * LSPosed 激活检测：模块在本应用进程内把 isActive() 改为返回 true。
 * 未启用模块（或作用域未勾选本应用）时返回 false。
 */
public final class ModuleStatus {
    private ModuleStatus() {}

    private static volatile int sentinel = 0;

    public static boolean isActive() {
        // 非常量返回，避免被内联/常量折叠导致 hook 失效
        return sentinel == Integer.MIN_VALUE;
    }

    public static int frameworkVersion() {
        return sentinel == Integer.MIN_VALUE ? 1 : 0;
    }
}
