#include "include/flutter_inappwebview_windows/in_app_web_view_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_inappwebview_windows_plugin.h"

void InAppWebViewCApiRegisterWithRegistrar(
  FlutterDesktopPluginRegistrarRef registrar)
{
  flutter_inappwebview_plugin::FlutterInappwebviewWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarManager::GetInstance()
    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
