; What the Windows installer does beyond Tauri's own (bundle > windows > nsis > installerHooks in
; tauri.installer.conf.json).
;
; Tauri's uninstaller offers to delete the app's data, but knows only the folders named after its
; bundle identifier, where the webview keeps its own. The app's are named after the app, as on
; Linux (crates/app/src/paths.rs): the speech models, a gigabyte or more, and OpenVINO's cache in
; %LOCALAPPDATA%\live-transcribe, and the settings in %APPDATA%\live-transcribe. With "Delete the
; application data" ticked, they go too; an update, which uninstalls the old version first, keeps
; them, as it keeps Tauri's. $DeleteAppDataCheckboxState and $UpdateMode are the uninstaller's own
; (Tauri's installer.nsi, for the Tauri CLI release.yml installs).

!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    SetShellVarContext current
    RmDir /r "$LOCALAPPDATA\live-transcribe"
    RmDir /r "$APPDATA\live-transcribe"
  ${EndIf}
!macroend
