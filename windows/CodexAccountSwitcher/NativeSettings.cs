using System;
using Microsoft.Win32;

namespace CodexAccountSwitcher;

public sealed class NativeSettings
{
    private const string Run = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public string Version => typeof(NativeSettings).Assembly.GetName().Version?.ToString(3) ?? "0.1.12";
    public bool LaunchAtLogin {
        get { using var key = Registry.CurrentUser.OpenSubKey(Run); return key?.GetValue("CodexAccountSwitcher") is string; }
        set { using var key = Registry.CurrentUser.CreateSubKey(Run);
            if (value) key.SetValue("CodexAccountSwitcher", "\"" + Environment.ProcessPath + "\" --background");
            else key.DeleteValue("CodexAccountSwitcher", false); }
    }
}
